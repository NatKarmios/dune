open Import

(* The build graph is emitted in chunked blobs on special "dune-graph" instant
   events at the end of the trace. *)
module Graph_blob = struct
  let version = 1
  let default_chunk_size = 4 * 1024 * 1024

  let chunk_size =
    lazy
      (match Sys.getenv_opt "DUNE_TRACE_GRAPH_CHUNK_SIZE" with
       | None -> default_chunk_size
       | Some s ->
         (match int_of_string_opt s with
          | Some n when n > 0 -> n
          | _ -> default_chunk_size))
  ;;

  (* Escape characters that would break the blob's line- and tab-separation *)
  let escape s =
    let buf = Buffer.create (String.length s) in
    String.iter s ~f:(fun c ->
      match c with
      | '\\' -> Buffer.add_string buf "\\\\"
      | '\t' -> Buffer.add_string buf "\\t"
      | '\n' -> Buffer.add_string buf "\\n"
      | c -> Buffer.add_char buf c);
    Buffer.contents buf
  ;;

  let chunks records =
    let limit = Lazy.force chunk_size in
    let flush chunks cur =
      match cur with
      | [] -> chunks
      | _ :: _ -> String.concat ~sep:"" (List.rev cur) :: chunks
    in
    let chunks, cur, _cur_len =
      List.fold_left records ~init:([], [], 0) ~f:(fun (chunks, cur, cur_len) r ->
        let r = r ^ "\n" in
        let r_len = String.length r in
        match cur with
        | [] -> chunks, [ r ], r_len
        | _ :: _ when cur_len + r_len > limit -> flush chunks cur, [ r ], r_len
        | _ :: _ -> chunks, r :: cur, cur_len + r_len)
    in
    List.rev (flush chunks cur)
  ;;

  let forced_by_code = function
    | Sexp.List [] -> "u"
    | Sexp.List (Atom "rule" :: Atom id :: _) -> "r" ^ id
    | Sexp.List (Atom "dep-recovery" :: Atom id :: _) -> "v" ^ id
    | Sexp.List (Atom "dep" :: Atom id :: _) -> "d" ^ id
    | Sexp.List (Atom "dynamic-includes" :: Atom id :: _) -> "i" ^ id
    | Sexp.List (Atom "gen-rules" :: Atom id :: _) -> "g" ^ id
    | Sexp.List (Atom "pform" :: Atom id :: _) -> "p" ^ id
    | Sexp.List (Atom "configurator" :: _) -> "c"
    | Sexp.List (Atom "request" :: _) -> "q"
    | _ -> "u"
  ;;

  let dep_resolution = function
    | Some (Sexp.List (Atom "rule" :: Atom id :: _)) -> "r" ^ id
    | Some (Sexp.List (Atom "is-source" :: _)) -> "s"
    | Some (Sexp.List (Atom "unknown" :: _)) -> "u"
    | Some (Sexp.List (Atom "expanded" :: ids)) ->
      "x"
      ^ String.concat
          ~sep:","
          (List.filter_map ids ~f:(function
             | Sexp.Atom s -> Some s
             | _ -> None))
    | _ -> "?"
  ;;

  let rule_outcome_code = function
    | Some "executed" -> "X"
    | Some "local-cache-hit" -> "L"
    | Some "shared-cache-hit" -> "S"
    | Some "dep-fail" -> "D"
    | Some "action-fail" -> "A"
    | Some "cancelled" -> "C"
    | _ -> "?"
  ;;

  let dep_status_code = function
    | Some (Sexp.Atom "failed") -> "f"
    | Some (Sexp.Atom "cancelled") -> "c"
    | _ -> ""
  ;;

  let ids_field ids = String.concat ~sep:"," ids

  (* Rule deps are optimised by finding "cores" of common deps and describing a
     rule's deps as additions to a core. *)
  module Dep_sets = struct
    let window_size = 32
    let pool_size = 64
    let min_core_size = 16
    let of_ids ids = List.sort_uniq ids ~compare:String.compare

    let rec is_subset a ~of_:b =
      match a, b with
      | [], _ -> true
      | _ :: _, [] -> false
      | x :: a', y :: b' ->
        (match String.compare x y with
         | Eq -> is_subset a' ~of_:b'
         | Gt -> is_subset a ~of_:b'
         | Lt -> false)
    ;;

    let rec inter a b =
      match a, b with
      | [], _ | _, [] -> []
      | x :: a', y :: b' ->
        (match String.compare x y with
         | Eq -> x :: inter a' b'
         | Lt -> inter a' b
         | Gt -> inter a b')
    ;;

    let rec diff a b =
      match a, b with
      | [], _ -> []
      | _ :: _, [] -> a
      | x :: a', y :: b' ->
        (match String.compare x y with
         | Eq -> diff a' b'
         | Lt -> x :: diff a' b
         | Gt -> diff a b')
    ;;

    (* [l] truncated to its first [n] elements (used on the window and the
       pool, both tiny). *)
    let keep n l = List.filteri l ~f:(fun i _ -> i < n)

    type t =
      { set_ids : (string, int) Table.t
      ; core_ids : (string, int) Table.t
      ; mutable rev_set_lines : string list
      ; mutable rev_core_lines : string list
      ; mutable next_set_id : int
      ; mutable next_core_id : int
      ; (* The last [window_size] distinct sets, newest first: the
           candidates a new core is created from. *)
        mutable window : string list list
      ; (* The last [pool_size] registered cores (id and members), newest
           first: the candidates a set can reuse a core from. *)
        mutable pool : (int * string list) list
      }

    let create () =
      { set_ids = Table.create (module String) 2048
      ; core_ids = Table.create (module String) 256
      ; rev_set_lines = []
      ; rev_core_lines = []
      ; next_set_id = 0
      ; next_core_id = 0
      ; window = []
      ; pool = []
      }
    ;;

    let core_lines t = List.rev t.rev_core_lines
    let set_lines t = List.rev t.rev_set_lines

    let largest_contained_core t s =
      List.fold_left t.pool ~init:None ~f:(fun best (id, c) ->
        if not (is_subset c ~of_:s)
        then best
        else (
          match best with
          | Some (_, b) when List.length b > List.length c -> best
          | _ -> Some (id, c)))
    ;;

    let compute_core t s ~min_overlap =
      List.fold_left t.window ~init:None ~f:(fun best b ->
        let candidate = inter s b in
        let size = List.length candidate in
        if size < min_overlap
        then best
        else (
          match best with
          | Some b when List.length b > size -> best
          | _ -> Some candidate))
    ;;

    let register_core t c =
      let key = ids_field c in
      match Table.find t.core_ids key with
      | Some id -> id
      | None ->
        let id = t.next_core_id in
        t.next_core_id <- id + 1;
        Table.set t.core_ids key id;
        t.rev_core_lines <- sprintf "%d\t%s" id key :: t.rev_core_lines;
        t.pool <- keep pool_size ((id, c) :: t.pool);
        id
    ;;

    let core_of t s ~size =
      let core =
        match largest_contained_core t s with
        | Some (id, c) when 2 * List.length c >= size -> Some (id, c)
        | _ ->
          (match compute_core t s ~min_overlap:(max min_core_size ((size + 1) / 2)) with
           | Some c -> Some (register_core t c, c)
           | None -> None)
      in
      match core with
      | None -> None
      | Some (_, c) ->
        let n = List.length c in
        if n >= min_core_size && n < size then core else None
    ;;

    let encode t ids =
      match of_ids ids with
      | [] -> None
      | s ->
        let key = ids_field s in
        (match Table.find t.set_ids key with
         | Some id -> Some id
         | None ->
           let core = core_of t s ~size:(List.length s) in
           let id = t.next_set_id in
           t.next_set_id <- id + 1;
           Table.set t.set_ids key id;
           let core_field, adds =
             match core with
             | None -> "", key
             | Some (core_id, c) -> string_of_int core_id, ids_field (diff s c)
           in
           t.rev_set_lines <- sprintf "%d\t%s\t%s" id core_field adds :: t.rev_set_lines;
           t.window <- keep window_size (s :: t.window);
           Some id)
    ;;

    let field t ids =
      match encode t ids with
      | None -> ""
      | Some id -> string_of_int id
    ;;

    let stages_field t stages =
      String.concat ~sep:"|" (List.map stages ~f:(fun stage -> field t stage))
    ;;
  end
end

module P = Dune_perfetto
module Span_id = Trace_common.Span_id

(* The open spans of one kind, keyed by the span they belong to. *)
module Span_table = struct
  include Hashtbl.Make (Span_id)

  (* Spans in a deterministic order, for the flushes at EOF. *)
  let sorted tbl =
    to_list tbl |> List.sort ~compare:(fun (a, _) (b, _) -> Span_id.compare a b)
  ;;
end

module Async_phase = struct
  type t =
    | Begin
    | End

  let of_string = function
    | "begin" -> Some Begin
    | "end" -> Some End
    | _ -> None
  ;;
end

module P_arg = struct
  include P.Arg

  let int_opt ~name s =
    match int_of_string_opt s with
    | Some n -> [ int ~name n ]
    | None -> []
  ;;

  let string_array ~name strings =
    array ~name (List.map strings ~f:(fun s -> string ~name:"" s))
  ;;

  let rule_id s = int_opt ~name:"rule_id" s
  let dep_id s = int_opt ~name:"dep_id" s
  let dur_ns n = int ~name:"dur_ns" n

  let scalar key = function
    | Sexp.Atom s ->
      if String.equal s "true"
      then bool ~name:key true
      else if String.equal s "false"
      then bool ~name:key false
      else (
        match int_of_string s with
        | i -> int ~name:key i
        | exception _ ->
          (match float_of_string s with
           | f -> float ~name:key f
           | exception _ -> string ~name:key s))
    | v -> json ~name:key (Json.to_string (Trace_common.Event_sexp.to_json v))
  ;;

  let wrap_dune args =
    match args with
    | [] -> []
    | _ :: _ -> [ dict ~name:"dune" args ]
  ;;

  (* Massage particular fields on non-Graph events *)
  let classify ~name key v =
    match key, v with
    | "targets", Sexp.List xs when String.equal name "targets" ->
      (* The user-requested build targets, rendered as real paths, so no id
         resolution is needed. *)
      `Dune
        (string_array
           ~name:key
           (List.filter_map xs ~f:(function
              | Sexp.Atom s -> Some s
              | _ -> None)))
    | "process_args", Sexp.List xs ->
      `Dune
        (string_array
           ~name:key
           (List.filter_map xs ~f:(function
              | Sexp.Atom s -> Some s
              | _ -> None)))
    | "forced_by", Sexp.List parts ->
      (* For process slices *)
      `Dune
        (string
           ~name:key
           (String.concat
              ~sep:" "
              (List.filter_map parts ~f:(function
                 | Sexp.Atom s -> Some s
                 | _ -> None))))
    | _ -> `Top (scalar key v)
  ;;

  (* Maps an event's [rest] fields to Perfetto debug annotations.
     Recognised structural fields are grouped under a "dune" dict. *)
  let map_rest ~name rest =
    let dune, top =
      List.filter_map rest ~f:(function
        | Sexp.List [ Atom key; v ] -> Some (classify ~name key v)
        | _ -> None)
      |> List.partition_map ~f:(function
        | `Dune arg -> Left arg
        | `Top arg -> Right arg)
    in
    match dune with
    | [] -> top
    | _ :: _ -> dict ~name:"dune" dune :: top
  ;;
end

module Track_uuid = struct
  let process = 1
  let main_thread = 2
  let graph = 3
  let exec_rule = 4
  let build_dep = 5
  let gen_rules = 6
  let dynamic_includes = 7
  let exec_rule_action = 8
  let processes = 9

  (* Slot tracks are allocated as needed, so their uuids cannot be fixed. *)
  let first_dynamic = 10
end

(* One track of the "job-NNN" pool that process slices are laid out on. *)
module Process_slot = struct
  type t =
    { uuid : int
    ; name : string
    ; mutable busy : bool
    ; mutable last_ts : int
    }
end

(* The begin side of a span, held until its end arrives. *)
module Span = struct
  module Rule = struct
    type t =
      { rule_id : string
      ; dir : string
      ; target_files : string list
      ; target_dirs : string list
      ; forced_by : Sexp.t
      ; begin_ts : int
      ; flow_id : int
      }
  end

  module Action = struct
    type t =
      { rule_id : string
      ; begin_ts : int
      ; flow_ids : int list
      }
  end

  module Dep = struct
    type t =
      { dep : string
      ; forced_by : Sexp.t
      ; begin_ts : int
      ; flow_id : int
      }
  end

  module Gen_rules = struct
    type t =
      { dir : string
      ; begin_ts : int
      ; flow_id : int
      }
  end

  module Dynamic_includes = struct
    type t =
      { dune_file : string
      ; begin_ts : int
      ; flow_id : int
      }
  end

  module Process = struct
    type t =
      { slot : Process_slot.t
      ; begin_ts : int
      ; cat : string
      ; fields : Sexp.t list
      }
  end
end

type t =
  { mutable declared_process : bool
  ; declared_tracks : (int, unit) Table.t
  ; interned_strings : (int, string) Table.t
  ; mutable rev_packets : P.packet list
  ; (* Timestamp (ns) of the last event seen, including [intern] events;
       used to place the graph blob's instants. *)
    mutable last_ts : int
  ; open_rules : Span.Rule.t Span_table.t
  ; open_deps : Span.Dep.t Span_table.t
  ; open_gen_rules : Span.Gen_rules.t Span_table.t
  ; open_dynamic_includes : Span.Dynamic_includes.t Span_table.t
  ; open_actions : Span.Action.t Span_table.t
  ; open_processes : Span.Process.t Span_table.t
  ; (* Slots in allocation order, so a slot's position names its track. *)
    mutable process_slots : Process_slot.t list
  ; mutable next_track_uuid : int
  ; mutable next_flow_id : int
  ; mutable rev_rule_lines : string list (* Rule entries in the graph blob *)
  ; mutable rev_dep_lines : string list (* Dep entries in the graph blob *)
  ; dep_sets : Graph_blob.Dep_sets.t
  }

let create () =
  { declared_process = false
  ; declared_tracks = Table.create (module Int) 8
  ; interned_strings = Table.create (module Int) 2048
  ; rev_packets = []
  ; last_ts = 0
  ; open_rules = Span_table.create 256
  ; open_deps = Span_table.create 256
  ; open_gen_rules = Span_table.create 64
  ; open_dynamic_includes = Span_table.create 64
  ; open_actions = Span_table.create 64
  ; open_processes = Span_table.create 64
  ; process_slots = []
  ; next_track_uuid = Track_uuid.first_dynamic
  ; next_flow_id = 1
  ; rev_rule_lines = []
  ; rev_dep_lines = []
  ; dep_sets = Graph_blob.Dep_sets.create ()
  }
;;

let push t p = t.rev_packets <- p :: t.rev_packets

let fresh_flow_id t =
  let id = t.next_flow_id in
  t.next_flow_id <- id + 1;
  id
;;

let fresh_track_uuid t =
  let uuid = t.next_track_uuid in
  t.next_track_uuid <- uuid + 1;
  uuid
;;

let field key rest =
  List.find_map rest ~f:(function
    | Sexp.List [ Atom k; v ] when String.equal k key -> Some v
    | _ -> None)
;;

let forced_by rest = Option.value (field "forced_by" rest) ~default:(Sexp.List [])

let ids key rest =
  match field key rest with
  | Some (List ids) ->
    List.filter_map ids ~f:(function
      | Sexp.Atom s -> Some s
      | _ -> None)
  | _ -> []
;;

let ensure_root_process t =
  if not t.declared_process
  then (
    t.declared_process <- true;
    push
      t
      (P.Track_descriptor (P.Track.process ~uuid:Track_uuid.process ~pid:0 ~name:"dune"));
    push
      t
      (P.Track_descriptor
         (P.Track.thread
            ~uuid:Track_uuid.main_thread
            ~parent_uuid:Track_uuid.process
            ~pid:0
            ~tid:0
            ~name:"main")))
;;

let ensure_track t uuid ~parent_uuid ~name =
  match Table.find t.declared_tracks uuid with
  | Some () -> ()
  | None ->
    Table.set t.declared_tracks uuid ();
    push t (P.Track_descriptor (P.Track.child ~uuid ~parent_uuid ~name))
;;

let record_interns t rest =
  let entry_field entry key =
    match entry with
    | Sexp.List fields -> field key fields
    | _ -> None
  in
  match field "entries" rest with
  | Some (List entries) ->
    List.iter entries ~f:(fun entry ->
      match entry_field entry "id", entry_field entry "value" with
      | Some (Atom id), Some (Atom value) ->
        (match int_of_string id with
         | id -> Table.set t.interned_strings id value
         | exception _ -> ())
      | _ -> ())
  | _ -> ()
;;

let push_instant t ~uuid ~track_name ~name ~ts ~flow_ids ~args =
  ensure_track t uuid ~parent_uuid:Track_uuid.process ~name:track_name;
  push
    t
    (P.Track_event
       (P.Event.create
          ~name
          ~categories:[ "graph" ]
          ~args
          ~flow_ids
          P.Event.Type.Instant
          ~track_uuid:uuid
          ~ts))
;;

let default_collapse_threshold_ns = 1_000_000

let collapse_threshold_ns =
  lazy
    (match Sys.getenv_opt "DUNE_TRACE_COLLAPSE_THRESHOLD_NS" with
     | None -> default_collapse_threshold_ns
     | Some s ->
       (match int_of_string_opt s with
        | Some n when n >= 0 -> n
        | _ -> default_collapse_threshold_ns))
;;

let collapses dur_ns = dur_ns < Lazy.force collapse_threshold_ns

module Graph_span = struct
  module Exec_rule = struct
    let instant t ~name ~ts ~flow_ids ~args =
      push_instant
        t
        ~uuid:Track_uuid.exec_rule
        ~track_name:"exec-rule"
        ~name
        ~ts
        ~flow_ids
        ~args
    ;;

    let push_start t (b : Span.Rule.t) =
      instant
        t
        ~name:"exec-rule-start"
        ~ts:b.begin_ts
        ~flow_ids:[ b.flow_id ]
        ~args:(P_arg.wrap_dune (P_arg.rule_id b.rule_id))
    ;;

    let push_finish t ~ts (b : Span.Rule.t) ~rule_outcome =
      let dur_ns = ts - b.begin_ts in
      let is_cache_hit =
        match rule_outcome with
        | Some ("local-cache-hit" | "shared-cache-hit") -> true
        | _ (* "executed", a failure/cancellation, or unfinished *) -> false
      in
      if is_cache_hit && collapses dur_ns
      then
        (* If a rule execution is very short and loaded from cache, then just
           emit one instant *)
        instant
          t
          ~name:"exec-rule-resolved"
          ~ts:b.begin_ts
          ~flow_ids:[]
          ~args:(P_arg.wrap_dune (P_arg.rule_id b.rule_id @ [ P_arg.dur_ns dur_ns ]))
      else (
        push_start t b;
        instant
          t
          ~name:"exec-rule-finish"
          ~ts
          ~flow_ids:[ b.flow_id ]
          ~args:(P_arg.wrap_dune (P_arg.rule_id b.rule_id @ [ P_arg.dur_ns dur_ns ])))
    ;;

    let record_begin t ~span_id ~ts rest =
      match field "rule_id" rest, field "dir" rest with
      | Some (Atom rule_id), Some (Atom dir) ->
        Span_table.set
          t.open_rules
          span_id
          { Span.Rule.rule_id
          ; dir
          ; target_files = ids "target_files" rest
          ; target_dirs = ids "target_dirs" rest
          ; forced_by = forced_by rest
          ; begin_ts = ts
          ; flow_id = fresh_flow_id t
          }
      | _ -> ()
    ;;

    (* One [graph-rules] line, however it was produced: a span that never ended
       has no outcome and reported neither deps nor dyn-dep stages. *)
    let append_blob t (b : Span.Rule.t) ~rule_outcome ~dep_set ~dyn_dep_stages =
      let line =
        String.concat
          ~sep:"\t"
          [ b.rule_id
          ; b.dir
          ; Graph_blob.ids_field b.target_files
          ; Graph_blob.ids_field b.target_dirs
          ; Graph_blob.rule_outcome_code rule_outcome
          ; Graph_blob.forced_by_code b.forced_by
          ; dep_set
          ; dyn_dep_stages
          ]
      in
      t.rev_rule_lines <- line :: t.rev_rule_lines
    ;;

    let record_end t ~span_id ~ts rest =
      match Span_table.find t.open_rules span_id with
      | None -> ()
      | Some b ->
        Span_table.remove t.open_rules span_id;
        let rule_outcome =
          match field "rule_outcome" rest with
          | Some (Atom s) -> Some s
          | _ -> None
        in
        let dep_set =
          match field "deps_unknown" rest with
          | Some (Sexp.Atom "true") -> "?"
          | _ -> Graph_blob.Dep_sets.field t.dep_sets (ids "deps" rest)
        in
        let dyn_deps =
          match field "dyn_deps" rest with
          | Some (List stages) ->
            List.map stages ~f:(function
              | Sexp.List stage_ids ->
                List.filter_map stage_ids ~f:(function
                  | Sexp.Atom s -> Some s
                  | _ -> None)
              | _ -> [])
          | _ -> []
        in
        let dyn_dep_stages = Graph_blob.Dep_sets.stages_field t.dep_sets dyn_deps in
        append_blob t b ~rule_outcome ~dep_set ~dyn_dep_stages;
        push_finish t ~ts b ~rule_outcome
    ;;

    let flush_unmatched t =
      List.iter (Span_table.sorted t.open_rules) ~f:(fun (_span_id, b) ->
        append_blob t b ~rule_outcome:None ~dep_set:"" ~dyn_dep_stages:"";
        push_start t b)
    ;;

    module Action = struct
      let instant t ~name ~ts ~flow_ids ~args =
        push_instant
          t
          ~uuid:Track_uuid.exec_rule_action
          ~track_name:"exec-rule-action"
          ~name
          ~ts
          ~flow_ids
          ~args
      ;;

      let push_start t (b : Span.Action.t) =
        instant
          t
          ~name:"exec-rule-action-start"
          ~ts:b.begin_ts
          ~flow_ids:b.flow_ids
          ~args:(P_arg.wrap_dune (P_arg.rule_id b.rule_id))
      ;;

      let push_finish t ~ts (b : Span.Action.t) =
        push_start t b;
        instant
          t
          ~name:"exec-rule-action-finish"
          ~ts
          ~flow_ids:b.flow_ids
          ~args:
            (P_arg.wrap_dune
               (P_arg.rule_id b.rule_id @ [ P_arg.dur_ns (ts - b.begin_ts) ]))
      ;;

      let record_begin t ~span_id ~ts rest =
        match field "rule_id" rest with
        | Some (Atom rule_id) ->
          (* Chain from the respective rule *)
          let flow_ids =
            match Span_table.find t.open_rules span_id with
            | Some (b : Span.Rule.t) -> [ b.flow_id ]
            | None -> []
          in
          Span_table.set
            t.open_actions
            span_id
            { Span.Action.rule_id; begin_ts = ts; flow_ids }
        | _ -> ()
      ;;

      let record_end t ~span_id ~ts _rest =
        match Span_table.find t.open_actions span_id with
        | None -> ()
        | Some b ->
          Span_table.remove t.open_actions span_id;
          push_finish t ~ts b
      ;;

      let flush_unmatched t =
        List.iter (Span_table.sorted t.open_actions) ~f:(fun (_span_id, b) ->
          push_start t b)
      ;;
    end
  end

  module Build_dep = struct
    let instant t ~name ~ts ~flow_ids ~args =
      push_instant
        t
        ~uuid:Track_uuid.build_dep
        ~track_name:"build-dep"
        ~name
        ~ts
        ~flow_ids
        ~args
    ;;

    let push_start t (b : Span.Dep.t) =
      instant
        t
        ~name:"build-dep-start"
        ~ts:b.begin_ts
        ~flow_ids:[ b.flow_id ]
        ~args:(P_arg.wrap_dune (P_arg.dep_id b.dep))
    ;;

    let push_finish t ~ts (b : Span.Dep.t) ~dep_outcome =
      let dur_ns = ts - b.begin_ts in
      let is_source =
        match dep_outcome with
        | Some (Sexp.List (Atom "is-source" :: _)) -> true
        | _ -> false
      in
      if is_source && collapses dur_ns
      then
        (* If a dep build is trivially short and just loads a source file, then
           just emit one instant *)
        instant
          t
          ~name:"build-dep-resolved"
          ~ts:b.begin_ts
          ~flow_ids:[]
          ~args:(P_arg.wrap_dune (P_arg.dep_id b.dep @ [ P_arg.dur_ns dur_ns ]))
      else (
        push_start t b;
        instant
          t
          ~name:"build-dep-finish"
          ~ts
          ~flow_ids:[ b.flow_id ]
          ~args:(P_arg.wrap_dune (P_arg.dep_id b.dep @ [ P_arg.dur_ns dur_ns ])))
    ;;

    let record_begin t ~span_id ~ts rest =
      match field "dep" rest with
      | Some (Atom dep) ->
        Span_table.set
          t.open_deps
          span_id
          { Span.Dep.dep
          ; forced_by = forced_by rest
          ; begin_ts = ts
          ; flow_id = fresh_flow_id t
          }
      | _ -> ()
    ;;

    (* One [graph-deps] line, however it was produced: a span that never ended
       reported neither a resolution nor a status. *)
    let append_blob t (b : Span.Dep.t) ~dep_outcome ~dep_status =
      let line =
        String.concat
          ~sep:"\t"
          [ b.dep
          ; Graph_blob.dep_resolution dep_outcome
          ; Graph_blob.forced_by_code b.forced_by
          ; Graph_blob.dep_status_code dep_status
          ]
      in
      t.rev_dep_lines <- line :: t.rev_dep_lines
    ;;

    let record_end t ~span_id ~ts rest =
      match Span_table.find t.open_deps span_id with
      | None -> ()
      | Some b ->
        Span_table.remove t.open_deps span_id;
        let dep_outcome = field "dep_outcome" rest in
        let dep_status = field "dep_status" rest in
        append_blob t b ~dep_outcome ~dep_status;
        push_finish t ~ts b ~dep_outcome
    ;;

    let flush_unmatched t =
      List.iter (Span_table.sorted t.open_deps) ~f:(fun (_span_id, b) ->
        append_blob t b ~dep_outcome:None ~dep_status:None;
        push_start t b)
    ;;
  end

  module Gen_rules = struct
    let instant t ~name ~ts ~flow_ids ~args =
      push_instant
        t
        ~uuid:Track_uuid.gen_rules
        ~track_name:"gen-rules"
        ~name
        ~ts
        ~flow_ids
        ~args
    ;;

    let push_start t (b : Span.Gen_rules.t) =
      instant
        t
        ~name:"gen-rules-start"
        ~ts:b.begin_ts
        ~flow_ids:[ b.flow_id ]
        ~args:(P_arg.wrap_dune [ P_arg.string ~name:"dir" b.dir ])
    ;;

    let push_finish t ~ts (b : Span.Gen_rules.t) ~dune_file =
      let dur_ns = ts - b.begin_ts in
      push_start t b;
      instant
        t
        ~name:"gen-rules-finish"
        ~ts
        ~flow_ids:[ b.flow_id ]
        ~args:
          (P_arg.wrap_dune
             ((match dune_file with
               | Some f -> [ P_arg.string ~name:"dune_file" f ]
               | None -> [])
              @ [ P_arg.dur_ns dur_ns ]))
    ;;

    let record_begin t ~span_id ~ts rest =
      match field "dir" rest with
      | Some (Atom dir) ->
        Span_table.set
          t.open_gen_rules
          span_id
          { Span.Gen_rules.dir; begin_ts = ts; flow_id = fresh_flow_id t }
      | _ -> ()
    ;;

    let record_end t ~span_id ~ts rest =
      match Span_table.find t.open_gen_rules span_id with
      | None -> ()
      | Some b ->
        Span_table.remove t.open_gen_rules span_id;
        let dune_file =
          match field "dune_file" rest with
          | Some (Atom f) -> Some f
          | _ -> None
        in
        push_finish t ~ts b ~dune_file
    ;;

    let flush_unmatched t =
      List.iter (Span_table.sorted t.open_gen_rules) ~f:(fun (_span_id, b) ->
        push_start t b)
    ;;
  end

  module Dynamic_includes = struct
    let instant t ~name ~ts ~flow_ids ~args =
      push_instant
        t
        ~uuid:Track_uuid.dynamic_includes
        ~track_name:"dynamic-includes"
        ~name
        ~ts
        ~flow_ids
        ~args
    ;;

    let push_start t (b : Span.Dynamic_includes.t) =
      instant
        t
        ~name:"dynamic-includes-start"
        ~ts:b.begin_ts
        ~flow_ids:[ b.flow_id ]
        ~args:(P_arg.wrap_dune [ P_arg.string ~name:"dune_file" b.dune_file ])
    ;;

    let push_finish t ~ts (b : Span.Dynamic_includes.t) =
      let dur_ns = ts - b.begin_ts in
      push_start t b;
      instant
        t
        ~name:"dynamic-includes-finish"
        ~ts
        ~flow_ids:[ b.flow_id ]
        ~args:(P_arg.wrap_dune [ P_arg.dur_ns dur_ns ])
    ;;

    let record_begin t ~span_id ~ts rest =
      match field "dune_file" rest with
      | Some (Atom dune_file) ->
        Span_table.set
          t.open_dynamic_includes
          span_id
          { Span.Dynamic_includes.dune_file; begin_ts = ts; flow_id = fresh_flow_id t }
      | _ -> ()
    ;;

    let record_end t ~span_id ~ts _rest =
      match Span_table.find t.open_dynamic_includes span_id with
      | None -> ()
      | Some b ->
        Span_table.remove t.open_dynamic_includes span_id;
        push_finish t ~ts b
    ;;

    let flush_unmatched t =
      List.iter (Span_table.sorted t.open_dynamic_includes) ~f:(fun (_span_id, b) ->
        push_start t b)
    ;;
  end

  let record_begin t ~name ~span_id ~ts rest =
    match name with
    | "exec-rule" -> Exec_rule.record_begin t ~span_id ~ts rest
    | "exec-rule-action" -> Exec_rule.Action.record_begin t ~span_id ~ts rest
    | "build-dep" -> Build_dep.record_begin t ~span_id ~ts rest
    | "gen-rules" -> Gen_rules.record_begin t ~span_id ~ts rest
    | "dynamic-includes" -> Dynamic_includes.record_begin t ~span_id ~ts rest
    | _ -> ()
  ;;

  let record_end t ~name ~span_id ~ts rest =
    match name with
    | "exec-rule" -> Exec_rule.record_end t ~span_id ~ts rest
    | "exec-rule-action" -> Exec_rule.Action.record_end t ~span_id ~ts rest
    | "build-dep" -> Build_dep.record_end t ~span_id ~ts rest
    | "gen-rules" -> Gen_rules.record_end t ~span_id ~ts rest
    | "dynamic-includes" -> Dynamic_includes.record_end t ~span_id ~ts rest
    | _ -> ()
  ;;

  let record t ~name ~async_phase ~span_id ~ts rest =
    match (async_phase : Async_phase.t) with
    | Begin -> record_begin t ~name ~span_id ~ts rest
    | End -> record_end t ~name ~span_id ~ts rest
  ;;

  (* Each kind of span has a track to itself, so the order between them here is
     free. *)
  let flush_unmatched t =
    Exec_rule.flush_unmatched t;
    Exec_rule.Action.flush_unmatched t;
    Build_dep.flush_unmatched t;
    Gen_rules.flush_unmatched t;
    Dynamic_includes.flush_unmatched t
  ;;
end

let dict_lines t =
  Table.to_list t.interned_strings
  |> List.sort ~compare:(fun (a, _) (b, _) -> Int.compare a b)
  |> List.map ~f:(fun (id, value) -> sprintf "%d\t%s" id (Graph_blob.escape value))
;;

let push_graph_section t ~name records =
  let chunks = Graph_blob.chunks records in
  let total = List.length chunks in
  List.iteri chunks ~f:(fun seq data ->
    push_instant
      t
      ~uuid:Track_uuid.graph
      ~track_name:"dune-graph"
      ~name
      ~ts:t.last_ts
      ~flow_ids:[]
      ~args:
        [ P_arg.dict
            ~name:"dune"
            [ P_arg.int ~name:"version" Graph_blob.version
            ; P_arg.int ~name:"seq" seq
            ; P_arg.int ~name:"total" total
            ; P_arg.string ~name:"data" data
            ]
        ])
;;

module Process = struct
  let claim_slot t ~ts =
    match
      List.find t.process_slots ~f:(fun slot -> (not slot.busy) && slot.last_ts <= ts)
    with
    | Some slot ->
      slot.busy <- true;
      slot
    | None ->
      let slot =
        { Process_slot.uuid = fresh_track_uuid t
        ; name = sprintf "job-%03d" (List.length t.process_slots + 1)
        ; busy = true
        ; last_ts = ts
        }
      in
      t.process_slots <- t.process_slots @ [ slot ];
      slot
  ;;

  let record_begin t ~cat ~span_id ~ts rest =
    Span_table.set
      t.open_processes
      span_id
      { Span.Process.slot = claim_slot t ~ts; begin_ts = ts; cat; fields = rest }
  ;;

  let push_slice t (b : Span.Process.t) ~stop rest =
    let { Process_slot.uuid = track_uuid; name = track_name; _ } = b.slot in
    let name = "process" in
    ensure_track t Track_uuid.processes ~parent_uuid:Track_uuid.process ~name:"processes";
    ensure_track t track_uuid ~parent_uuid:Track_uuid.processes ~name:track_name;
    push
      t
      (P.Track_event
         (P.Event.create
            ~name
            ~categories:[ b.cat ]
            ~args:(P_arg.map_rest ~name (b.fields @ rest))
            P.Event.Type.Begin
            ~track_uuid
            ~ts:b.begin_ts));
    push t (P.Track_event (P.Event.create P.Event.Type.End ~track_uuid ~ts:stop))
  ;;

  let record_end t ~span_id ~ts rest =
    match Span_table.find t.open_processes span_id with
    | None -> ()
    | Some b ->
      Span_table.remove t.open_processes span_id;
      b.slot.busy <- false;
      b.slot.last_ts <- ts;
      push_slice t b ~stop:ts rest
  ;;

  let flush_unmatched t =
    List.iter
      (Span_table.sorted t.open_processes)
      ~f:(fun (_span_id, (b : Span.Process.t)) ->
        push_slice t b ~stop:(Int.max t.last_ts b.begin_ts) [])
  ;;
end

let flush_unmatched t =
  Graph_span.flush_unmatched t;
  Process.flush_unmatched t
;;

let add t sexp =
  let cat, name, ts_sexp, rest, digest = Trace_common.Event_sexp.to_base_args sexp in
  let ts, dur = Trace_common.Event_sexp.to_times ts_sexp in
  let ts_ns = Time.to_ns ts in
  t.last_ts <- ts_ns;
  match name with
  | "intern" -> record_interns t rest
  | _ ->
    ensure_root_process t;
    let async_phase, async_id, rest = Trace_common.Event_sexp.to_async_args rest in
    (match Option.bind async_phase ~f:Async_phase.of_string, async_id with
     | Some async_phase, Some async_id ->
       let span_id = Span_id.make ~digest ~async_id in
       (match cat with
        | "graph" -> Graph_span.record t ~name ~async_phase ~span_id ~ts:ts_ns rest
        | "process" ->
          (match async_phase with
           | Async_phase.Begin -> Process.record_begin t ~cat ~span_id ~ts:ts_ns rest
           | Async_phase.End -> Process.record_end t ~span_id ~ts:ts_ns rest)
        | _ -> ())
     | _ ->
       let args = P_arg.map_rest ~name rest in
       let open P.Event.Type in
       let track_uuid = Track_uuid.main_thread in
       (match dur with
        | Some dur ->
          let stop = ts_ns + Time.Span.to_ns dur in
          push
            t
            (P.Track_event
               (P.Event.create
                  ~name
                  ~categories:[ cat ]
                  ~args
                  Begin
                  ~track_uuid
                  ~ts:ts_ns));
          push t (P.Track_event (P.Event.create End ~track_uuid ~ts:stop))
        | None ->
          push
            t
            (P.Track_event
               (P.Event.create
                  ~name
                  ~categories:[ cat ]
                  ~args
                  Instant
                  ~track_uuid
                  ~ts:ts_ns))))
;;

let to_packets t =
  flush_unmatched t;
  let dict = dict_lines t in
  let rules = List.rev t.rev_rule_lines in
  let deps = List.rev t.rev_dep_lines in
  if not (List.is_empty dict && List.is_empty rules && List.is_empty deps)
  then (
    ensure_root_process t;
    push_graph_section t ~name:"graph-dict" dict;
    push_graph_section t ~name:"graph-cores" (Graph_blob.Dep_sets.core_lines t.dep_sets);
    push_graph_section t ~name:"graph-depsets" (Graph_blob.Dep_sets.set_lines t.dep_sets);
    push_graph_section t ~name:"graph-rules" rules;
    push_graph_section t ~name:"graph-deps" deps);
  List.rev t.rev_packets
;;

let info =
  let doc = "Convert the trace file to Perfetto's protobuf format" in
  Cmd.info "perfetto" ~doc
;;

let term =
  let+ trace_file = Trace_common.term
  and+ output =
    Arg.(
      value
      & opt (some string) None
      & info
          [ "o"; "output" ]
          ~docv:"FILE"
          ~doc:(Some "Write to this file instead of stdout"))
  and+ text =
    Arg.(
      value
      & flag
      & info
          [ "text" ]
          ~doc:(Some "Emit a human-readable text dump instead of binary protobuf"))
  in
  let t = create () in
  Trace_common.Event_sexp.iter trace_file ~f:(add t);
  let packets = to_packets t in
  let data = if text then P.to_text packets else P.to_bytes packets in
  match output with
  | Some file -> Io.String_path.write_file ~binary:true file data
  | None -> print_string data
;;

let cmd = Cmd.v info term
