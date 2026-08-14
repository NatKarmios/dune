open Import

let debug_backtraces =
  Arg.(
    value
    & flag
    & info
        [ "debug-backtraces" ]
        ~docs:"COMMON OPTIONS"
        ~doc:(Some "Always print exception backtraces."))
;;

let iter_sexps file ~f =
  Io.String_path.with_file_in ~binary:true file ~f:(fun chan ->
    let rec loop () =
      match Csexp.input_opt chan with
      | Error _ | Ok None -> ()
      | Ok (Some sexp) ->
        f sexp;
        loop ()
    in
    loop ())
;;

let rec json_of_sexp : Sexp.t -> Json.t = function
  | Atom "true" -> Json.bool true
  | Atom "false" -> Json.bool false
  | Atom s ->
    (match int_of_string s with
     | s -> Json.int s
     | exception _ ->
       (match float_of_string s with
        | s -> Json.float s
        | exception _ -> Json.string s))
  | List [] -> Json.list []
  | List xs ->
    if
      List.for_all xs ~f:(function
        | Sexp.List [ Atom _; _ ] -> true
        | _ -> false)
    then
      List.map xs ~f:(function
        | Sexp.List [ Atom k; v ] -> k, json_of_sexp v
        | _ -> assert false)
      |> Json.assoc
    else Json.list (List.map xs ~f:json_of_sexp)
;;

let invalid_sexp sexp = User_error.raise [ Pp.text "invalid sexp"; Sexp.pp sexp ]

let base_of_sexp (sexp : Sexp.t) =
  match sexp with
  | List (Atom cat :: Atom name :: ts :: rest) ->
    let digest =
      List.find_map rest ~f:(function
        | Sexp.List [ Atom "digest"; Atom d ] -> Some d
        | _ -> None)
    in
    cat, name, ts, rest, digest
  | _ -> invalid_sexp sexp
;;

type process_info =
  { prog : string
  ; args : string list
  ; dir : string option
  ; exit_code : int
  ; error : string option
  ; stderr : string
  }

let parse_process_event (sexp : Sexp.t) : process_info option =
  match base_of_sexp sexp with
  | "process", "finish", _ts, rest, _ ->
    let rec extract_fields prog args dir exit error stderr = function
      | [] -> prog, args, dir, exit, error, stderr
      | Sexp.List [ Atom "process_args"; List arg_sexps ] :: rest ->
        let args =
          List.filter_map arg_sexps ~f:(function
            | Sexp.Atom s -> Some s
            | _ -> None)
        in
        extract_fields prog (Some args) dir exit error stderr rest
      | List [ Atom "prog"; Atom p ] :: rest ->
        extract_fields (Some p) args dir exit error stderr rest
      | List [ Atom "dir"; Atom d ] :: rest ->
        extract_fields prog args (Some d) exit error stderr rest
      | List [ Atom "exit"; Atom e ] :: rest ->
        let exit_code =
          try int_of_string e with
          | Failure _ -> 0
        in
        extract_fields prog args dir (Some exit_code) error stderr rest
      | List [ Atom "error"; Atom err ] :: rest ->
        extract_fields prog args dir exit (Some err) stderr rest
      | List [ Atom "stderr"; Atom s ] :: rest ->
        extract_fields prog args dir exit error (Some s) rest
      | _ :: rest -> extract_fields prog args dir exit error stderr rest
    in
    let prog, args, dir, exit, error, stderr =
      extract_fields None None None None None None rest
    in
    Option.map prog ~f:(fun prog ->
      { prog
      ; args = Option.value args ~default:[]
      ; dir
      ; exit_code = Option.value exit ~default:0
      ; error
      ; stderr = Option.value stderr ~default:""
      })
  | _ -> None
;;

let format_shell_command (info : process_info) : string =
  let module Escape = Escape0 in
  let cmd =
    let quoted_prog = Escape.quote_if_needed info.prog in
    let quoted_args = List.map info.args ~f:Escape.quote_if_needed in
    String.concat ~sep:" " (quoted_prog :: quoted_args)
  in
  match info.dir with
  | None -> sprintf "(%s)" cmd
  | Some dir ->
    let dir = Escape.quote_if_needed dir in
    Printf.sprintf "(cd %s && %s)" dir cmd
;;

let format_output (info : process_info) : string =
  let cmd_line = format_shell_command info in
  if info.exit_code = 0
  then cmd_line
  else (
    let error_line =
      match info.error with
      | Some err -> Printf.sprintf "# %s" err
      | None -> Printf.sprintf "# Exit code: %d" info.exit_code
    in
    let lines = [ cmd_line; error_line ] in
    let lines =
      if info.stderr <> "" then lines @ [ "# Stderr:"; info.stderr ] else lines
    in
    String.concat ~sep:"\n" lines)
;;

let iter_sexps_follow file ~f =
  Io.String_path.with_file_in ~binary:true file ~f:(fun chan ->
    let rec loop () =
      match Csexp.input_opt chan with
      | Ok (Some sexp) ->
        (* Check if exit event before processing *)
        let is_exit =
          match base_of_sexp sexp with
          (* Only stop on exit events without a digest (the main dune exit) *)
          | "config", "exit", _, _, None -> true
          | _ -> false
          | exception _ -> true
        in
        f sexp;
        if not is_exit then loop ()
      | Ok None | Error _ ->
        (* EOF or parse error - poll and retry *)
        Unix.sleepf 0.1;
        loop ()
    in
    loop ())
;;

let times_of_sexp (sexp : Sexp.t) =
  match sexp with
  | Atom s ->
    let ns = int_of_string s in
    Time.of_ns ns, None
  | List [ Atom ts; Atom dur ] ->
    let ts_ns = int_of_string ts in
    let dur_ns = int_of_string dur in
    Time.of_ns ts_ns, Some (Time.Span.of_ns dur_ns)
  | _ -> invalid_sexp sexp
;;

let pid = lazy (Unix.getpid ())

(* Graph events are Chrome nestable-async events (see [Dune_engine.Graph_trace]):
   they carry an "async_phase" arg ("begin"/"end"/"instant", rendered as ph
   b/e/n) and an integer "async_id" pairing a begin with its end. Both are
   removed from [rest] so they surface as top-level fields rather than in the
   event's [args]. *)
let async_phase_of_sexp rest =
  let phase =
    List.find_map rest ~f:(function
      | Sexp.List [ Atom "async_phase"; Atom phase ] -> Some phase
      | _ -> None)
  in
  let rest =
    List.filter rest ~f:(function
      | Sexp.List [ Atom "async_phase"; _ ] -> false
      | _ -> true)
  in
  phase, rest
;;

let async_id_of_sexp rest =
  let id =
    List.find_map rest ~f:(function
      | Sexp.List [ Atom "async_id"; Atom id ] -> int_of_string_opt id
      | _ -> None)
  in
  let rest =
    List.filter rest ~f:(function
      | Sexp.List [ Atom "async_id"; _ ] -> false
      | _ -> true)
  in
  id, rest
;;

let json_of_event ~chrome (sexp : Sexp.t) =
  let cat, name, ts, rest, _ = base_of_sexp sexp in
  let ts, dur = times_of_sexp ts in
  let async_phase, rest = async_phase_of_sexp rest in
  let async_id, rest = async_id_of_sexp rest in
  let rest =
    List.map rest ~f:(function
      | Sexp.List [ Atom ("process_args" as k); List v ] ->
        ( k
        , Json.list
            (List.map v ~f:(function
               | Sexp.Atom s -> Json.string s
               | _ -> invalid_sexp sexp)) )
      | Sexp.List [ Atom k; v ] -> k, json_of_sexp v
      | _ -> invalid_sexp sexp)
  in
  let base =
    [ "cat", Json.string cat
    ; "name", Json.string name
    ; ("ts", if chrome then Json.int (Time.to_us ts) else Json.float (Time.to_secs ts))
    ; "args", Json.assoc rest
    ]
    @
    match dur with
    | None -> []
    | Some k ->
      [ ( "dur"
        , if chrome
          then Json.int (Time.Span.to_us k)
          else Json.float (Time.Span.to_secs k) )
      ]
  in
  match chrome with
  | false ->
    let async_fields =
      (match async_phase with
       | None -> []
       | Some phase -> [ "async_phase", Json.string phase ])
      @
      match async_id with
      | None -> []
      | Some id -> [ "async_id", Json.int id ]
    in
    Json.assoc (base @ async_fields)
  | true ->
    let kind =
      match async_phase, dur with
      | Some "begin", _ -> "b"
      | Some "end", _ -> "e"
      | Some "instant", _ -> "n"
      | Some _, _ | None, None -> "i"
      | None, Some _ -> "X"
    in
    let id_field =
      match async_phase, async_id with
      | Some _, Some id -> [ "id", Json.int id ]
      | _ -> []
    in
    Json.assoc
      (base
       @ [ "ph", Json.string kind ]
       @ [ "pid", Json.int (Lazy.force pid); "tid", Json.int 0 ]
       @ id_field)
;;

(* The build-graph blob: a chunked dump of the graph's structure (the intern
   table, and one record per exec-rule/build-dep span), emitted as instants on
   a dedicated "dune-graph" track instead of scattering it across per-slice
   debug annotations (see doc/dev/trace-graph-perfetto.md, phase 1). Payloads
   are line-oriented, tab-separated records; this module only knows how to
   render the pieces of a single record (a forced-by tag, a dep outcome, a
   rule outcome) and how to chunk and escape the assembled lines. It has no
   converter state. *)
module Graph_blob = struct
  let version = 1
  let default_chunk_size = 4 * 1024 * 1024

  (* Overridable so a test can force multi-chunk framing without a
     multi-megabyte trace. Non-positive or unparseable values are ignored. *)
  let chunk_size =
    lazy
      (match Sys.getenv_opt "DUNE_TRACE_GRAPH_CHUNK_SIZE" with
       | None -> default_chunk_size
       | Some s ->
         (match int_of_string_opt s with
          | Some n when n > 0 -> n
          | _ -> default_chunk_size))
  ;;

  (* C-style escaping of the three characters that would otherwise corrupt the
     line/tab framing. Only used on [graph-dict] values: every other field in
     a record is a digit, a comma, or one of our own fixed tags. *)
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

  (* Join [records] with newlines, splitting into chunks of at most
     [chunk_size] bytes without ever splitting inside a record (a single
     over-long record gets a chunk of its own). [] in, [] out. *)
  let chunks records =
    let limit = Lazy.force chunk_size in
    let flush chunks cur =
      match cur with
      | [] -> chunks
      | _ :: _ -> String.concat ~sep:"\n" (List.rev cur) :: chunks
    in
    let chunks, cur, _cur_len =
      List.fold_left records ~init:([], [], 0) ~f:(fun (chunks, cur, cur_len) r ->
        let r_len = String.length r in
        match cur with
        | [] -> chunks, [ r ], r_len
        | _ :: _ when cur_len + 1 + r_len > limit -> flush chunks cur, [ r ], r_len
        | _ :: _ -> chunks, r :: cur, cur_len + 1 + r_len)
    in
    List.rev (flush chunks cur)
  ;;

  (* [forced_by] rendered as one of the short codes in the schema: "u"
     (unknown), "r<id>", "d<id>", "i<id>", "g<id>", "p<id>", "c", "q". Mirrors
     [Perfetto_conv.forced_by_arg]'s pattern match; an unrecognised shape
     degrades to "u" rather than failing the whole conversion. *)
  let forced_by_code = function
    | Sexp.List [] -> "u"
    | Sexp.List (Atom "rule" :: Atom id :: _) -> "r" ^ id
    | Sexp.List (Atom "dep" :: Atom id :: _) -> "d" ^ id
    | Sexp.List (Atom "dynamic-includes" :: Atom id :: _) -> "i" ^ id
    | Sexp.List (Atom "gen-rules" :: Atom id :: _) -> "g" ^ id
    | Sexp.List (Atom "pform" :: Atom id :: _) -> "p" ^ id
    | Sexp.List (Atom "configurator" :: _) -> "c"
    | Sexp.List (Atom "request" :: _) -> "q"
    | _ -> "u"
  ;;

  (* [Build_dep.outcome] rendered as "r<rule_id>" | "s" | "x<id,id,...>". *)
  let dep_resolution = function
    | Sexp.List (Atom "rule" :: Atom id :: _) -> "r" ^ id
    | Sexp.List (Atom "is-source" :: _) -> "s"
    | Sexp.List (Atom "expanded" :: ids) ->
      "x"
      ^ String.concat
          ~sep:","
          (List.filter_map ids ~f:(function
             | Sexp.Atom s -> Some s
             | _ -> None))
    | _ -> "?"
  ;;

  (* [Exec_rule.outcome_to_string]'s value rendered as "X" | "L" | "S". *)
  let rule_outcome_code = function
    | "executed" -> "X"
    | "local-cache-hit" -> "L"
    | "shared-cache-hit" -> "S"
    | _ -> "?"
  ;;

  let ids_field ids = String.concat ~sep:"," ids

  let dyn_deps_field stages =
    String.concat ~sep:"|" (List.map stages ~f:(String.concat ~sep:","))
  ;;
end

(* Perfetto native-protobuf export. Consumes the same csexp event stream as
   [json_of_event], mapping each graph async span (matched by its "id") to a
   Perfetto slice on its own track, flat complete/instant events to
   slices/instants on a main thread track, and the intern tables to readable
   target/dep names. It also accumulates the graph blob (see [Graph_blob])
   for exec-rule/build-dep spans, flushed once at the end in [to_packets]. *)
module Perfetto_conv = struct
  module P = Dune_perfetto

  (* Track uuids: a single process track, one main thread track and one graph
     blob track under it, and one child track per async span id (offset past
     the three fixed uuids). *)
  let process_uuid = 1
  let main_thread_uuid = 2
  let graph_uuid = 3
  let async_uuid id = id + 4

  (* The begin-side fields of an open exec-rule span, buffered under its
     [async_id] until the matching end supplies the outcome/deps. *)
  type rule_begin =
    { rule_id : string
    ; dir : string
    ; target_files : string list
    ; target_dirs : string list
    ; forced_by : Sexp.t
    }

  (* Likewise for an open build-dep span. *)
  type dep_begin =
    { dep : string
    ; forced_by : Sexp.t
    }

  type t =
    { mutable declared_process : bool
    ; seen_async : (int, unit) Table.t
    ; (* Interned strings (targets and deps share one table, see the [intern]
         event). Maps id -> readable value. *)
      names : (int, string) Table.t
    ; mutable rev_packets : P.packet list
    ; (* Timestamp (ns) of the last event seen, including [intern] events;
         used to place the graph blob's instants. *)
      mutable last_ts : int
    ; open_rules : (int, rule_begin) Table.t
    ; open_deps : (int, dep_begin) Table.t
    ; mutable rev_rule_lines : string list
    ; mutable rev_dep_lines : string list
    }

  let create () =
    { declared_process = false
    ; seen_async = Table.create (module Int) 256
    ; names = Table.create (module Int) 2048
    ; rev_packets = []
    ; last_ts = 0
    ; open_rules = Table.create (module Int) 256
    ; open_deps = Table.create (module Int) 256
    ; rev_rule_lines = []
    ; rev_dep_lines = []
    }
  ;;

  let push t p = t.rev_packets <- p :: t.rev_packets

  let field key rest =
    List.find_map rest ~f:(function
      | Sexp.List [ Atom k; v ] when String.equal k key -> Some v
      | _ -> None)
  ;;

  let ensure_process t =
    if not t.declared_process
    then (
      t.declared_process <- true;
      push t (P.Track_descriptor (P.Track.process ~uuid:process_uuid ~pid:0 ~name:"dune"));
      push
        t
        (P.Track_descriptor
           (P.Track.thread
              ~uuid:main_thread_uuid
              ~parent_uuid:process_uuid
              ~pid:0
              ~tid:0
              ~name:"main")))
  ;;

  (* Declare the track for async span [id] the first time it is seen, named by
     the event's category (spans forced by another share the forcer's id, so a
     single track may hold several event kinds; the category is their common
     label). *)
  let ensure_async_track t id ~name =
    match Table.find t.seen_async id with
    | Some () -> ()
    | None ->
      Table.set t.seen_async id ();
      push
        t
        (P.Track_descriptor
           (P.Track.child ~uuid:(async_uuid id) ~parent_uuid:process_uuid ~name))
  ;;

  (* Populate the intern table from an [intern] event's [id -> value] entries.
     These are not emitted as Perfetto events; they only resolve the id lists
     carried by the other graph events into readable strings. *)
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
           | id -> Table.set t.names id value
           | exception _ -> ())
        | _ -> ())
    | _ -> ()
  ;;

  (* Resolve a single interned id [s] to its readable value, falling back to the
     id itself if it is not an integer or not in [table]. *)
  let resolve_id table s =
    match int_of_string s with
    | id ->
      (match Table.find table id with
       | Some v -> v
       | None -> s)
    | exception _ -> s
  ;;

  let resolve_id_strings table ids =
    List.filter_map ids ~f:(function
      | Sexp.Atom s -> Some (resolve_id table s)
      | _ -> None)
  ;;

  let string_array ~name strings =
    P.Arg.array ~name (List.map strings ~f:(fun s -> P.Arg.string ~name:"" s))
  ;;

  (* Buffer the begin-side fields of an exec-rule/build-dep span, keyed by
     [async_id], until [record_span_end] can pair it with its end and append
     a graph-blob record. Fields are taken verbatim off [rest] (still raw
     sexp atoms — e.g. intern ids, not resolved strings): the blob carries
     ids, leaving resolution to the plugin via [graph-dict]. A malformed begin
     (missing a required field) is silently dropped: the matching end will
     then find nothing buffered and drop too, same as an end with no begin. *)
  let record_span_begin t ~name ~async_id rest =
    let forced_by = Option.value (field "forced_by" rest) ~default:(Sexp.List []) in
    let ids key =
      match field key rest with
      | Some (List ids) ->
        List.filter_map ids ~f:(function
          | Sexp.Atom s -> Some s
          | _ -> None)
      | _ -> []
    in
    match name with
    | "exec-rule" ->
      (match field "rule_id" rest, field "dir" rest with
       | Some (Atom rule_id), Some (Atom dir) ->
         Table.set
           t.open_rules
           async_id
           { rule_id
           ; dir
           ; target_files = ids "target_files"
           ; target_dirs = ids "target_dirs"
           ; forced_by
           }
       | _ -> ())
    | "build-dep" ->
      (match field "dep" rest with
       | Some (Atom dep) -> Table.set t.open_deps async_id { dep; forced_by }
       | _ -> ())
    | _ -> ()
  ;;

  (* Pair a matching end with its buffered begin and append the completed
     graph-blob record, in trace order (i.e. ordered by end time). An end
     with no buffered begin (the begin was malformed, or predates this
     process) is dropped; a begin with no end is flushed separately at EOF
     (see [to_packets]). *)
  let record_span_end t ~name ~async_id rest =
    match name with
    | "exec-rule" ->
      (match Table.find t.open_rules async_id with
       | None -> ()
       | Some b ->
         Table.remove t.open_rules async_id;
         let outcome =
           match field "rule_outcome" rest with
           | Some (Atom s) -> Graph_blob.rule_outcome_code s
           | _ -> "?"
         in
         let ids key =
           match field key rest with
           | Some (List ids) ->
             List.filter_map ids ~f:(function
               | Sexp.Atom s -> Some s
               | _ -> None)
           | _ -> []
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
         let line =
           String.concat
             ~sep:"\t"
             [ b.rule_id
             ; b.dir
             ; Graph_blob.ids_field b.target_files
             ; Graph_blob.ids_field b.target_dirs
             ; outcome
             ; Graph_blob.forced_by_code b.forced_by
             ; Graph_blob.ids_field (ids "deps")
             ; Graph_blob.dyn_deps_field dyn_deps
             ]
         in
         t.rev_rule_lines <- line :: t.rev_rule_lines)
    | "build-dep" ->
      (match Table.find t.open_deps async_id with
       | None -> ()
       | Some b ->
         Table.remove t.open_deps async_id;
         let resolution =
           match field "dep_outcome" rest with
           | Some v -> Graph_blob.dep_resolution v
           | None -> "?"
         in
         let line =
           String.concat
             ~sep:"\t"
             [ b.dep; resolution; Graph_blob.forced_by_code b.forced_by ]
         in
         t.rev_dep_lines <- line :: t.rev_dep_lines)
    | _ -> ()
  ;;

  (* Dispatch a graph event's (already-extracted) phase/id to the begin/end
     recorders above; anything else (a different category, an "instant"
     phase, or a malformed async event) is not part of the blob. *)
  let record_graph_span t ~cat ~name ~async_phase ~async_id rest =
    match cat, async_phase, async_id with
    | "graph", Some "begin", Some id -> record_span_begin t ~name ~async_id:id rest
    | "graph", Some "end", Some id -> record_span_end t ~name ~async_id:id rest
    | _ -> ()
  ;;

  (* Unmatched begins (crash/interrupt: EOF reached with a span still open) as
     records with "?" for the fields only the end would have supplied,
     sorted by [async_id] for determinism (see doc/dev/trace-graph-perfetto.md,
     phase 1). *)
  let flush_open_rules t =
    Table.to_list t.open_rules
    |> List.sort ~compare:(fun (a, _) (b, _) -> Int.compare a b)
    |> List.map ~f:(fun (_, b) ->
      String.concat
        ~sep:"\t"
        [ b.rule_id
        ; b.dir
        ; Graph_blob.ids_field b.target_files
        ; Graph_blob.ids_field b.target_dirs
        ; "?"
        ; Graph_blob.forced_by_code b.forced_by
        ; ""
        ; ""
        ])
  ;;

  let flush_open_deps t =
    Table.to_list t.open_deps
    |> List.sort ~compare:(fun (a, _) (b, _) -> Int.compare a b)
    |> List.map ~f:(fun (_, b) ->
      String.concat ~sep:"\t" [ b.dep; "?"; Graph_blob.forced_by_code b.forced_by ])
  ;;

  (* The intern table as "id\tvalue" lines, sorted by id: the only place in
     the blob where an arbitrary (escaped) string appears. *)
  let dict_lines t =
    Table.to_list t.names
    |> List.sort ~compare:(fun (a, _) (b, _) -> Int.compare a b)
    |> List.map ~f:(fun (id, value) -> sprintf "%d\t%s" id (Graph_blob.escape value))
  ;;

  (* Emit one instant per chunk of [records], named [name], on the graph
     track, carrying [version]/[seq]/[total]/[data]. *)
  let push_graph_section t ~name records =
    let chunks = Graph_blob.chunks records in
    let total = List.length chunks in
    List.iteri chunks ~f:(fun seq data ->
      push
        t
        (P.Track_event
           (P.Event.create
              ~name
              ~categories:[ "graph" ]
              ~args:
                [ P.Arg.dict
                    ~name:"dune"
                    [ P.Arg.int ~name:"version" Graph_blob.version
                    ; P.Arg.int ~name:"seq" seq
                    ; P.Arg.int ~name:"total" total
                    ; P.Arg.string ~name:"data" data
                    ]
                ]
              P.Event.Type.Instant
              ~track_uuid:graph_uuid
              ~ts:t.last_ts)))
  ;;

  (* [Graph.forced_by] as a nested dict: a [kind] tag plus (for all but
     [unknown]/[configurator]/[request]) the matching payload. The dep/path
     payloads are interned ids (the [rule] payload is a bare rule id), resolved
     here. Unrecognised shapes yield [None] so the caller can fall back. *)
  let forced_by_arg t key = function
    | Sexp.List [] -> Some (P.Arg.dict ~name:key [ P.Arg.string ~name:"kind" "UNKNOWN" ])
    | Sexp.List (Atom "rule" :: Atom id :: _) ->
      let kind = P.Arg.string ~name:"kind" "RULE" in
      let fields =
        match int_of_string_opt id with
        | Some n -> [ kind; P.Arg.int ~name:"rule" n ]
        | None -> [ kind ]
      in
      Some (P.Arg.dict ~name:key fields)
    | Sexp.List (Atom "dep" :: Atom dep :: _) ->
      Some
        (P.Arg.dict
           ~name:key
           [ P.Arg.string ~name:"kind" "DEP"
           ; P.Arg.string ~name:"dep" (resolve_id t.names dep)
           ])
    | Sexp.List (Atom "dynamic-includes" :: Atom path :: _) ->
      Some
        (P.Arg.dict
           ~name:key
           [ P.Arg.string ~name:"kind" "DYNAMIC_INCLUDES"
           ; P.Arg.string ~name:"dynamic_includes" (resolve_id t.names path)
           ])
    | Sexp.List (Atom "gen-rules" :: Atom dir :: _) ->
      Some
        (P.Arg.dict
           ~name:key
           [ P.Arg.string ~name:"kind" "GEN_RULES"
           ; P.Arg.string ~name:"gen_rules" (resolve_id t.names dir)
           ])
    | Sexp.List (Atom "pform" :: Atom dune_file :: _) ->
      Some
        (P.Arg.dict
           ~name:key
           [ P.Arg.string ~name:"kind" "PFORM"
           ; P.Arg.string ~name:"pform" (resolve_id t.names dune_file)
           ])
    | Sexp.List (Atom "configurator" :: _) ->
      Some (P.Arg.dict ~name:key [ P.Arg.string ~name:"kind" "CONFIGURATOR" ])
    | Sexp.List (Atom "request" :: _) ->
      Some (P.Arg.dict ~name:key [ P.Arg.string ~name:"kind" "REQUEST" ])
    | _ -> None
  ;;

  (* [Build_dep.outcome] as a nested dict; the [expanded] case carries interned
     dep ids, resolved here. Unrecognised shapes yield [None]. *)
  let dep_outcome_arg t key = function
    | Sexp.List (Atom "rule" :: Atom id :: _) ->
      (match int_of_string_opt id with
       | Some n -> Some (P.Arg.dict ~name:key [ P.Arg.int ~name:"rule" n ])
       | None -> None)
    | Sexp.List (Atom "expanded" :: ids) ->
      Some
        (P.Arg.dict
           ~name:key
           [ string_array ~name:"expanded" (resolve_id_strings t.names ids) ])
    | Sexp.List (Atom "is-source" :: _) ->
      Some (P.Arg.dict ~name:key [ P.Arg.bool ~name:"is_source" true ])
    | _ -> None
  ;;

  let scalar_arg key = function
    | Sexp.Atom s ->
      if String.equal s "true"
      then P.Arg.bool ~name:key true
      else if String.equal s "false"
      then P.Arg.bool ~name:key false
      else (
        match int_of_string s with
        | i -> P.Arg.int ~name:key i
        | exception _ ->
          (match float_of_string s with
           | f -> P.Arg.float ~name:key f
           | exception _ -> P.Arg.string ~name:key s))
    | v -> P.Arg.json ~name:key (Json.to_string (json_of_sexp v))
  ;;

  (* Classify one [key = value] field as a recognised structural graph field
     (with its interned ids resolved to readable names) or an unrecognised one.
     Recognised keys with an unexpected shape fall back to a scalar but stay
     recognised. [name] (the event name) disambiguates keys that mean
     different things on different events: "exec-rule"'s "dir"/"target_files"/
     "target_dirs" are interned, while "gen-rules"'s "dir"/"dune_file" and the
     "targets" event's own "targets" (see [Event.resolve_targets]) are plain,
     uninterned strings. *)
  let classify_field t ~name key v =
    let fallback = function
      | Some arg -> arg
      | None -> scalar_arg key v
    in
    match key, v with
    | "dir", Sexp.Atom s when String.equal name "exec-rule" ->
      `Dune (P.Arg.string ~name:key (resolve_id t.names s))
    | ("target_files" | "target_dirs"), Sexp.List ids when String.equal name "exec-rule"
      -> `Dune (string_array ~name:key (resolve_id_strings t.names ids))
    | "deps", Sexp.List ids ->
      `Dune (string_array ~name:key (resolve_id_strings t.names ids))
    | "dep", Sexp.Atom s -> `Dune (P.Arg.string ~name:key (resolve_id t.names s))
    | "dir", Sexp.Atom s when String.equal name "gen-rules" ->
      `Dune (P.Arg.string ~name:key s)
    | "dune_file", Sexp.Atom s when String.equal name "gen-rules" ->
      `Dune (P.Arg.string ~name:key s)
    | "targets", Sexp.List xs when String.equal name "targets" ->
      (* [Event.resolve_targets]'s own "targets" arg: the user-requested build
         targets, rendered as real paths (unlike graph events' interned ids),
         so no id resolution is needed. *)
      `Dune
        (string_array
           ~name:key
           (List.filter_map xs ~f:(function
              | Sexp.Atom s -> Some s
              | _ -> None)))
    | "rule_id", Sexp.Atom s ->
      `Dune (fallback (Option.map (int_of_string_opt s) ~f:(P.Arg.int ~name:key)))
    | "forced_by", _ -> `Dune (fallback (forced_by_arg t key v))
    | "rule_outcome", Sexp.Atom s -> `Dune (P.Arg.string ~name:key s)
    | "dep_outcome", Sexp.List _ -> `Dune (fallback (dep_outcome_arg t key v))
    | "process_args", Sexp.List xs ->
      `Dune
        (string_array
           ~name:key
           (List.filter_map xs ~f:(function
              | Sexp.Atom s -> Some s
              | _ -> None)))
    | "dyn_deps", Sexp.List stages ->
      `Dune
        (P.Arg.array
           ~name:key
           (List.filter_map stages ~f:(function
              | Sexp.List ids ->
                Some (string_array ~name:"" (resolve_id_strings t.names ids))
              | _ -> None)))
    | _ -> `Top (scalar_arg key v)
  ;;

  (* Map an event's [rest] fields to Perfetto debug annotations. Recognised
     structural fields are grouped under a "dune" dict (surfacing as e.g.
     [debug.dune.target_files] in Trace Processor); unrecognised fields are
     left at the top level. Their strings are interned by [Dune_perfetto] when
     serialising. *)
  let event_fields t ~name rest =
    let dune, top =
      List.filter_map rest ~f:(function
        | Sexp.List [ Atom key; v ] -> Some (classify_field t ~name key v)
        | _ -> None)
      |> List.partition_map ~f:(function
        | `Dune arg -> Left arg
        | `Top arg -> Right arg)
    in
    match dune with
    | [] -> top
    | _ :: _ -> P.Arg.dict ~name:"dune" dune :: top
  ;;

  let add t sexp =
    let cat, name, ts_sexp, rest, _ = base_of_sexp sexp in
    let ts, dur = times_of_sexp ts_sexp in
    let ts_ns = Time.to_ns ts in
    t.last_ts <- ts_ns;
    match name with
    | "intern" -> record_interns t rest
    | _ ->
      ensure_process t;
      let async_phase, rest = async_phase_of_sexp rest in
      let async_id, rest = async_id_of_sexp rest in
      record_graph_span t ~cat ~name ~async_phase ~async_id rest;
      let args = event_fields t ~name rest in
      let open P.Event.Type in
      (match async_phase, async_id with
       | Some phase, Some id ->
         let kind, ev_name =
           match phase with
           | "begin" -> Begin, Some name
           | "end" -> End, None
           | _ -> Instant, Some name
         in
         ensure_async_track t id ~name:cat;
         push
           t
           (P.Track_event
              (P.Event.create
                 ?name:ev_name
                 ~categories:[ cat ]
                 ~args
                 kind
                 ~track_uuid:(async_uuid id)
                 ~ts:ts_ns))
       | _ ->
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
                    ~track_uuid:main_thread_uuid
                    ~ts:ts_ns));
            push
              t
              (P.Track_event (P.Event.create End ~track_uuid:main_thread_uuid ~ts:stop))
          | None ->
            push
              t
              (P.Track_event
                 (P.Event.create
                    ~name
                    ~categories:[ cat ]
                    ~args
                    Instant
                    ~track_uuid:main_thread_uuid
                    ~ts:ts_ns))))
  ;;

  (* The blob can only be assembled once the whole stream has been seen (it
     needs every intern entry and the EOF-time set of still-open spans), so
     it is flushed here rather than incrementally in [add]. Emits nothing if
     the trace has no [graph] category data, leaving existing traces (and
     assertions about them) unchanged. *)
  let to_packets t =
    let dict = dict_lines t in
    let rules = List.rev t.rev_rule_lines @ flush_open_rules t in
    let deps = List.rev t.rev_dep_lines @ flush_open_deps t in
    if not (List.is_empty dict && List.is_empty rules && List.is_empty deps)
    then (
      ensure_process t;
      push
        t
        (P.Track_descriptor
           (P.Track.child ~uuid:graph_uuid ~parent_uuid:process_uuid ~name:"dune-graph"));
      push_graph_section t ~name:"graph-dict" dict;
      push_graph_section t ~name:"graph-rules" rules;
      push_graph_section t ~name:"graph-deps" deps);
    List.rev t.rev_packets
  ;;
end

let perfetto =
  let info =
    let doc = "Convert the trace file to Perfetto's protobuf format" in
    Cmd.info "perfetto" ~doc
  in
  let term =
    let+ debug_backtraces = debug_backtraces
    and+ trace_file =
      Arg.(
        value
        & opt (some string) None
        & info [ "trace-file" ] ~docv:"FILE" ~doc:(Some "Read this trace file"))
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
    Common.No_build.set_debug_backtraces debug_backtraces;
    let trace_file =
      match trace_file with
      | Some s -> s
      | None -> Common.find_default_trace_file ()
    in
    let t = Perfetto_conv.create () in
    iter_sexps trace_file ~f:(Perfetto_conv.add t);
    let packets = Perfetto_conv.to_packets t in
    let data =
      if text then Dune_perfetto.to_text packets else Dune_perfetto.to_bytes packets
    in
    match output with
    | Some file -> Io.String_path.write_file ~binary:true file data
    | None -> print_string data
  in
  Cmd.v info term
;;

let cat =
  let info = Cmd.info "cat" in
  let term =
    let+ debug_backtraces = debug_backtraces
    and+ sexp =
      Arg.(
        value
        & flag
        & info [ "sexp" ] ~doc:(Some "print the trace file in pretty-printed sexp"))
    and+ chrome_trace =
      Arg.(
        value
        & flag
        & info
            [ "chrome-trace" ]
            ~doc:(Some "print the trace file in the chrome event format"))
    and+ trace_file =
      Arg.(
        value
        & opt (some string) None
        & info [ "trace-file" ] ~docv:"FILE" ~doc:(Some "Read this trace-file"))
    and+ follow =
      Arg.(
        value
        & flag
        & info [ "follow"; "f" ] ~doc:(Some "follow the trace file until the exit event"))
    in
    Common.No_build.set_debug_backtraces debug_backtraces;
    let mode =
      match chrome_trace, sexp with
      | true, true ->
        User_error.raise [ Pp.text "--chrome-trace and --sexp are mutually exclusive" ]
      | false, true -> `Sexp
      | true, false -> `Chrome
      | false, false -> `Json
    in
    let print =
      match mode with
      | `Sexp -> fun sexp -> print_endline (Sexp.to_string sexp)
      | `Json ->
        fun sexp -> print_endline (Json.to_string (json_of_event ~chrome:false sexp))
      | `Chrome ->
        let first = ref true in
        fun sexp ->
          let char =
            if !first
            then (
              let () = first := false in
              '[')
            else ','
          in
          print_char char;
          print_endline (Json.to_string (json_of_event ~chrome:true sexp))
    in
    let print_with_flush sexp =
      print sexp;
      if follow then flush stdout
    in
    let trace_file =
      match trace_file with
      | Some s -> s
      | None -> Common.find_default_trace_file ()
    in
    if follow
    then iter_sexps_follow trace_file ~f:print_with_flush
    else iter_sexps trace_file ~f:print;
    match mode with
    | `Chrome -> print_endline "]"
    | `Json | `Sexp -> ()
  in
  Cmd.v info term
;;

let commands =
  let info =
    let doc = "Display executed processes in shell format" in
    Cmd.info "commands" ~doc
  in
  let term =
    let+ debug_backtraces = debug_backtraces
    and+ trace_file =
      Arg.(
        value
        & opt (some string) None
        & info
            [ "trace-file" ]
            ~docv:"FILE"
            ~doc:(Some "Read this trace file (default: _build/trace.json)"))
    in
    Common.No_build.set_debug_backtraces debug_backtraces;
    let trace_file =
      match trace_file with
      | Some s -> s
      | None -> Common.find_default_trace_file ()
    in
    iter_sexps trace_file ~f:(fun sexp ->
      match parse_process_event sexp with
      | Some info ->
        let output = format_output info in
        print_endline output
      | None -> ())
  in
  Cmd.v info term
;;

let group =
  let info =
    let doc = "Commands to view dune's event trace" in
    Cmd.info "trace" ~doc
  in
  Cmd.group info [ cat; commands; perfetto ]
;;
