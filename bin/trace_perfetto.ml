open Import

(* The build-graph blob: a chunked dump of the graph's structure (the intern
   table, the factored dep-set table, and one record per exec-rule/build-dep
   span), emitted as instants on a dedicated "dune-graph" track instead of
   scattering it across per-slice debug annotations (see
   doc/dev/trace-graph-perfetto.md, phase 1). Payloads are line-oriented,
   tab-separated records; this module knows how to render the pieces of a
   single record (a forced-by tag, a dep outcome, a rule outcome) and how to
   chunk and escape the assembled lines. The only converter state it holds is
   the dep-set table ([Dep_sets], phase 8), which is inseparable from
   rendering a dep field. *)
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

  (* Split [records] into chunks of at most [chunk_size] bytes, never
     splitting inside a record (a single over-long record gets a chunk of its
     own). Records are newline-*terminated* rather than newline-separated, so
     the last record of a chunk keeps its newline: concatenating the chunks in
     order reproduces the payload byte for byte, and a chunk read on its own
     still holds a whole number of records. [] in, [] out. *)
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

  (* [forced_by] rendered as one of the short codes in the schema: "u"
     (unknown), "r<id>", "v<id>", "d<id>", "i<id>", "g<id>", "p<id>", "c",
     "q". An unrecognised shape degrades to "u" rather than failing the whole
     conversion. *)
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

  (* [Build_dep.outcome] rendered as "r<rule_id>" | "s" | "x<id,id,...>" | "u".
     "u" is a resolution dune reported it could not determine, as distinct from
     the "?" of a span that never ended. *)
  let dep_resolution = function
    | Sexp.List (Atom "rule" :: Atom id :: _) -> "r" ^ id
    | Sexp.List (Atom "is-source" :: _) -> "s"
    | Sexp.List (Atom "unknown" :: _) -> "u"
    | Sexp.List (Atom "expanded" :: ids) ->
      "x"
      ^ String.concat
          ~sep:","
          (List.filter_map ids ~f:(function
             | Sexp.Atom s -> Some s
             | _ -> None))
    | _ -> "?"
  ;;

  (* [Exec_rule.outcome_to_string]'s value rendered as a single letter. *)
  let rule_outcome_code = function
    | "executed" -> "X"
    | "local-cache-hit" -> "L"
    | "shared-cache-hit" -> "S"
    | "dep-fail" -> "D"
    | "action-fail" -> "A"
    | "cancelled" -> "C"
    | _ -> "?"
  ;;

  (* [Build_dep.status] rendered as "" (succeeded, the common case, which the
     event omits) | "f" | "c". *)
  let dep_status_code = function
    | Some (Sexp.Atom "failed") -> "f"
    | Some (Sexp.Atom "cancelled") -> "c"
    | _ -> ""
  ;;

  let ids_field ids = String.concat ~sep:"," ids

  (* Dep sets are not spelled out per rule: a [graph-rules] line names its
     dep set by id, [graph-depsets] describes each distinct set as a core
     plus the ids it adds to that core, and [graph-cores] holds the cores.
     Cores are flat -- a core never references another core -- so
     reconstructing a set is exactly one join deep:
     [deps(S) = core_members(C) + adds(S)]. On a monorepo trace this turns
     28.1M (rule, dep) pairs into ~16% as many rows; see
     doc/dev/trace-graph-perfetto.md for the measurements behind the
     constants below.

     The encoder is online: sets are encoded as their rules' spans end, and
     the only state that grows with the trace is the table of distinct sets
     (which replaces the dep ids the rule lines used to carry). *)
  module Dep_sets = struct
    (* Chosen by measurement on a real monorepo trace, not by taste: a
       larger core pool measured worse (stale cores win the "largest
       subset" test with a poor covering and displace the mining step). *)
    let window_size = 32
    let pool_size = 64
    let min_core_size = 16

    (* A dep set is a sorted, duplicate-free list of dep ids; [ids_field] of
       it is both its exact identity (no hashing: a digest collision would
       silently corrupt the graph) and what gets emitted. *)
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
           candidates a new core is mined from. *)
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

    (* The largest pooled core contained in [s]. The pool is newest first
       and a tie replaces the incumbent, so ties go to the oldest (lowest
       id) core: the output must not depend on pool churn. *)
    let largest_contained_core t s =
      List.fold_left t.pool ~init:None ~f:(fun best (id, c) ->
        if not (is_subset c ~of_:s)
        then best
        else (
          match best with
          | Some (_, b) when List.length b > List.length c -> best
          | _ -> Some (id, c)))
    ;;

    (* [s]'s intersection with the window entry it shares the most ids with,
       if that is at least [min_overlap] ids. Ties go to the older entry,
       for the same reason as above. *)
    let mine t s ~min_overlap =
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

    (* Cores are emitted as they are registered. An identical core keeps its
       id, and is not pushed onto the pool a second time. *)
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

    (* The core of a new distinct set [s] of [size] ids, if it gets one:
       either a pooled core covering at least half of [s], or, failing that,
       one mined from the window (registered as a core here whether or not
       the size test below then accepts it, so that a shape seen twice in
       the window becomes reusable). A core must have at least
       [min_core_size] ids to be worth a join, and must be a strict subset
       so that the set says something of its own. *)
    let core_of t s ~size =
      let core =
        match largest_contained_core t s with
        | Some (id, c) when 2 * List.length c >= size -> Some (id, c)
        | _ ->
          (match mine t s ~min_overlap:(max min_core_size ((size + 1) / 2)) with
           | Some c -> Some (register_core t c, c)
           | None -> None)
      in
      match core with
      | None -> None
      | Some (_, c) ->
        let n = List.length c in
        if n >= min_core_size && n < size then core else None
    ;;

    (* The id of the dep set [ids], registering it (and possibly a new core)
       on first sight. [None] for the empty set: a rule with no deps has an
       empty dep field rather than a set id of its own. *)
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

    (* A rule's dep set as its [graph-rules] field: the set id, or empty for
       a rule with no deps. ("?", for deps dune could not determine, is
       rendered by the caller.) *)
    let field t ids =
      match encode t ids with
      | None -> ""
      | Some id -> string_of_int id
    ;;

    (* The dyn-dep stages field: stages separated by "|", each stage a dep
       set of its own (so stages go through the same table and the same
       factoring); empty when there are no stages. *)
    let stages_field t stages =
      String.concat ~sep:"|" (List.map stages ~f:(fun stage -> field t stage))
    ;;
  end
end

module P = Dune_perfetto

(* Track uuids: a single process track, a main thread track, a graph-blob
   track, and one fixed track per graph-span kind, all children of the
   process. Per-span tracks are gone -- unrelated spans of the same kind now
   share one track as instants, which have no nesting semantics (see
   doc/dev/trace-graph-perfetto.md, phase 2). Exec-rule-action spans are no
   exception: phase 3 rendered them as duration slices on a pool of reused
   lane tracks, on the assumption that concurrency was bounded by -j, but
   the -j throttle is acquired per-process below the span (see phase 6), so
   the pool grew with the ready set. They are lifecycle instants too. *)
let process_uuid = 1
let main_thread_uuid = 2
let graph_uuid = 3
let exec_rule_uuid = 4
let build_dep_uuid = 5
let gen_rules_uuid = 6
let dynamic_includes_uuid = 7
let exec_rule_action_uuid = 8

(* The begin-side fields of an open exec-rule span, buffered under its
   [async_id] (with its begin timestamp, to compute [dur_ns] and place the
   start instant) until the matching end supplies the outcome/deps. *)
type rule_begin =
  { rule_id : string
  ; dir : string
  ; target_files : string list
  ; target_dirs : string list
  ; forced_by : Sexp.t
  ; begin_ts : int
  ; flow_id : int
  }

(* Likewise for an open build-dep span. *)
type dep_begin =
  { dep : string
  ; forced_by : Sexp.t
  ; begin_ts : int
  ; flow_id : int
  }

(* Likewise for an open gen-rules span. Not part of the graph blob (only
   exec-rule/build-dep spans are), so there is no [forced_by] to keep. *)
type gen_rules_begin =
  { gen_rules_dir : string
  ; gen_rules_begin_ts : int
  ; gen_rules_flow_id : int
  }

(* Likewise for an open dynamic-includes span. *)
type dynamic_includes_begin =
  { dynamic_includes_dune_file : string
  ; dynamic_includes_begin_ts : int
  ; dynamic_includes_flow_id : int
  }

(* Likewise for an open exec-rule-action span. It has no flow id of its
   own: it shares its rule's [async_id] and runs strictly inside the rule's
   span, so the rule's begin is still buffered when the action begins and
   its flow id can be borrowed then, chaining the action into the rule's
   lifecycle. [] if the rule's begin was malformed and thus not buffered. *)
type action_begin =
  { action_rule_id : string
  ; action_begin_ts : int
  ; action_flow_ids : int list
  }

type t =
  { mutable declared_process : bool
  ; declared_tracks : (int, unit) Table.t
  ; (* Interned strings (targets and deps share one table, see the [intern]
       event). Maps id -> readable value. *)
    names : (int, string) Table.t
  ; mutable rev_packets : P.packet list
  ; (* Timestamp (ns) of the last event seen, including [intern] events;
       used to place the graph blob's instants. *)
    mutable last_ts : int
  ; open_rules : (int, rule_begin) Table.t
  ; open_deps : (int, dep_begin) Table.t
  ; open_gen_rules : (int, gen_rules_begin) Table.t
  ; open_dynamic_includes : (int, dynamic_includes_begin) Table.t
  ; (* Keyed by the async_id the action shares with its rule; the rule's own
       begin lives in [open_rules] under the same key. *)
    open_actions : (int, action_begin) Table.t
  ; (* One fresh flow id per buffered span begin, chaining its lifecycle
       events (start instant, the action's two instants, finish instant) in
       timestamp order (see doc/dev/trace-graph-perfetto.md, phases 4 and
       6). Collapsed instants carry no flow, so a cache-hit/source span's id
       is simply never emitted. *)
    mutable next_flow_id : int
  ; mutable rev_rule_lines : string list
  ; mutable rev_dep_lines : string list
  ; (* The factored dep-set table the rule lines' dep fields point into
       (see [Graph_blob.Dep_sets]), filled as rule spans end. *)
    dep_sets : Graph_blob.Dep_sets.t
  }

let create () =
  { declared_process = false
  ; declared_tracks = Table.create (module Int) 8
  ; names = Table.create (module Int) 2048
  ; rev_packets = []
  ; last_ts = 0
  ; open_rules = Table.create (module Int) 256
  ; open_deps = Table.create (module Int) 256
  ; open_gen_rules = Table.create (module Int) 64
  ; open_dynamic_includes = Table.create (module Int) 64
  ; open_actions = Table.create (module Int) 64
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

(* Declare the (fixed, per-kind) track [uuid] the first time anything is
   pushed to it. *)
let ensure_track t uuid ~name =
  match Table.find t.declared_tracks uuid with
  | Some () -> ()
  | None ->
    Table.set t.declared_tracks uuid ();
    push t (P.Track_descriptor (P.Track.child ~uuid ~parent_uuid:process_uuid ~name))
;;

(* Populate the intern table from an [intern] event's [id -> value] entries.
   These are not emitted as Perfetto events; they are dumped as the blob's
   [graph-dict] section, which is what resolves the ids carried by the
   graph events and the blob's records into readable strings. *)
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

let string_array ~name strings =
  P.Arg.array ~name (List.map strings ~f:(fun s -> P.Arg.string ~name:"" s))
;;

(* Emit an instant on the fixed track [uuid]/[track_name], declaring the
   track the first time. Used for the lifecycle instants below and (via
   [push_graph_section]) the graph blob. [flow_ids] is the span's lifecycle
   flow ([] where none applies: collapsed instants and the blob). *)
let push_instant t ~uuid ~track_name ~name ~ts ~flow_ids ~args =
  ensure_track t uuid ~name:track_name;
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

(* A span's instants carry only what the blob cannot supply: the id keying
   its blob record, and the duration (which the blob does not store, being
   structure rather than timing). Everything else the end event knows -- the
   rule's outcome, the dep's resolution, the paths behind the ids -- is a
   blob lookup away, so repeating it here would only cost args-table rows
   (see doc/dev/trace-graph-perfetto.md, phase 7). An empty dict is not
   emitted at all: [rule_id_arg]/[dep_id_arg] drop a malformed (non-integer)
   id, which can leave nothing to say. *)
let dune_args args =
  match args with
  | [] -> []
  | _ :: _ -> [ P.Arg.dict ~name:"dune" args ]
;;

let int_arg ~name s =
  match int_of_string_opt s with
  | Some n -> [ P.Arg.int ~name n ]
  | None -> []
;;

let rule_id_arg s = int_arg ~name:"rule_id" s
let dep_id_arg s = int_arg ~name:"dep_id" s
let dur_ns_arg dur_ns = P.Arg.int ~name:"dur_ns" dur_ns

(* Collapsing a span to a single instant trades away its interval, which is
   only honest when there was near-zero interval to lose. A cache hit or
   source-file dep that took real time -- a contended shared cache, a cold
   page cache -- is worth seeing as a span, so the collapse is gated on the
   duration as well as the outcome. Overridable (to 0, in particular) so a
   test can pin the choice instead of racing the clock; negative or
   unparseable values are ignored. *)
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

(* The matched pair (or, for a short cache hit, the single collapsed
   instant) for an exec-rule span, per the "Lifecycle instants" schema
   (doc/dev/trace-graph-perfetto.md). [rule_outcome] is the raw
   [Graph.Exec_rule.outcome_to_string] value; only the blob records it (as a
   letter code), the instants merely collapse on it. A failed or cancelled
   rule keeps the start/finish pair: it occupied that span of time, unlike a
   cache hit, and which outcome it was is in the blob. *)
let emit_exec_rule_end t ~ts (b : rule_begin) ~rule_outcome =
  let dur_ns = ts - b.begin_ts in
  let is_cache_hit =
    match rule_outcome with
    | "local-cache-hit" | "shared-cache-hit" -> true
    | _ (* "executed", or a failure/cancellation *) -> false
  in
  if is_cache_hit && collapses dur_ns
  then
    push_instant
      t
      ~uuid:exec_rule_uuid
      ~track_name:"exec-rule"
      ~name:"exec-rule-resolved"
      ~ts:b.begin_ts
      ~flow_ids:[]
      ~args:(dune_args (rule_id_arg b.rule_id @ [ dur_ns_arg dur_ns ]))
  else (
    push_instant
      t
      ~uuid:exec_rule_uuid
      ~track_name:"exec-rule"
      ~name:"exec-rule-start"
      ~ts:b.begin_ts
      ~flow_ids:[ b.flow_id ]
      ~args:(dune_args (rule_id_arg b.rule_id));
    push_instant
      t
      ~uuid:exec_rule_uuid
      ~track_name:"exec-rule"
      ~name:"exec-rule-finish"
      ~ts
      ~flow_ids:[ b.flow_id ]
      ~args:(dune_args (rule_id_arg b.rule_id @ [ dur_ns_arg dur_ns ])))
;;

(* The action span's start instant, also used on its own by the EOF flush
   (an action left open by a crash/interrupt). *)
let push_action_start t (b : action_begin) =
  push_instant
    t
    ~uuid:exec_rule_action_uuid
    ~track_name:"exec-rule-action"
    ~name:"exec-rule-action-start"
    ~ts:b.action_begin_ts
    ~flow_ids:b.action_flow_ids
    ~args:(dune_args (rule_id_arg b.action_rule_id))
;;

(* exec-rule-action has no collapsed form: an action span means the rule
   actually executed, which is real work and comparatively rare. *)
let emit_action_end t ~ts (b : action_begin) =
  push_action_start t b;
  push_instant
    t
    ~uuid:exec_rule_action_uuid
    ~track_name:"exec-rule-action"
    ~name:"exec-rule-action-finish"
    ~ts
    ~flow_ids:b.action_flow_ids
    ~args:
      (dune_args (rule_id_arg b.action_rule_id @ [ dur_ns_arg (ts - b.action_begin_ts) ]))
;;

(* Likewise for a build-dep span: collapsed to [build-dep-resolved] when the
   dep is a source file resolved inside [collapse_threshold_ns], otherwise a
   [build-dep-start]/[build-dep-finish] pair. [dep_outcome] is the end
   event's raw [Build_dep.outcome] sexp; as
   with a rule's outcome, only the blob records what the dep resolved to
   (including the producing rule's id), so the instants use it only to pick
   the collapsed form. *)
let emit_build_dep_end t ~ts (b : dep_begin) ~dep_outcome =
  let dur_ns = ts - b.begin_ts in
  let is_source =
    match dep_outcome with
    | Sexp.List (Atom "is-source" :: _) -> true
    | _ -> false
  in
  if is_source && collapses dur_ns
  then
    push_instant
      t
      ~uuid:build_dep_uuid
      ~track_name:"build-dep"
      ~name:"build-dep-resolved"
      ~ts:b.begin_ts
      ~flow_ids:[]
      ~args:(dune_args (dep_id_arg b.dep @ [ dur_ns_arg dur_ns ]))
  else (
    push_instant
      t
      ~uuid:build_dep_uuid
      ~track_name:"build-dep"
      ~name:"build-dep-start"
      ~ts:b.begin_ts
      ~flow_ids:[ b.flow_id ]
      ~args:(dune_args (dep_id_arg b.dep));
    push_instant
      t
      ~uuid:build_dep_uuid
      ~track_name:"build-dep"
      ~name:"build-dep-finish"
      ~ts
      ~flow_ids:[ b.flow_id ]
      ~args:(dune_args (dep_id_arg b.dep @ [ dur_ns_arg dur_ns ])))
;;

(* gen-rules has no collapsed form: always a [gen-rules-start]/[-finish]
   pair. [dune_file] is only known once the finish arrives (the directory
   may turn out not to be standalone/group-root). *)
let emit_gen_rules_end t ~ts (b : gen_rules_begin) ~dune_file =
  let dur_ns = ts - b.gen_rules_begin_ts in
  push_instant
    t
    ~uuid:gen_rules_uuid
    ~track_name:"gen-rules"
    ~name:"gen-rules-start"
    ~ts:b.gen_rules_begin_ts
    ~flow_ids:[ b.gen_rules_flow_id ]
    ~args:(dune_args [ P.Arg.string ~name:"dir" b.gen_rules_dir ]);
  push_instant
    t
    ~uuid:gen_rules_uuid
    ~track_name:"gen-rules"
    ~name:"gen-rules-finish"
    ~ts
    ~flow_ids:[ b.gen_rules_flow_id ]
    ~args:
      (dune_args
         ((match dune_file with
           | Some f -> [ P.Arg.string ~name:"dune_file" f ]
           | None -> [])
          @ [ dur_ns_arg dur_ns ]))
;;

(* Likewise for dynamic-includes: no collapsed form either. *)
let emit_dynamic_includes_end t ~ts (b : dynamic_includes_begin) =
  let dur_ns = ts - b.dynamic_includes_begin_ts in
  push_instant
    t
    ~uuid:dynamic_includes_uuid
    ~track_name:"dynamic-includes"
    ~name:"dynamic-includes-start"
    ~ts:b.dynamic_includes_begin_ts
    ~flow_ids:[ b.dynamic_includes_flow_id ]
    ~args:(dune_args [ P.Arg.string ~name:"dune_file" b.dynamic_includes_dune_file ]);
  push_instant
    t
    ~uuid:dynamic_includes_uuid
    ~track_name:"dynamic-includes"
    ~name:"dynamic-includes-finish"
    ~ts
    ~flow_ids:[ b.dynamic_includes_flow_id ]
    ~args:(dune_args [ dur_ns_arg dur_ns ])
;;

(* Buffer the begin-side fields of a graph span, keyed by [async_id], until
   [record_span_end] can pair it with its end. Fields for exec-rule/
   build-dep are taken verbatim off [rest] (still raw sexp atoms -- e.g.
   intern ids, not resolved strings): both the blob and the lifecycle
   instants carry ids, leaving resolution to the plugin via [graph-dict]. A
   malformed begin (missing a required field) is silently dropped: the
   matching end will then find nothing buffered and drop too, same as an
   end with no begin. *)
let record_span_begin t ~name ~async_id ~ts rest =
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
         ; begin_ts = ts
         ; flow_id = fresh_flow_id t
         }
     | _ -> ())
  | "exec-rule-action" ->
    (match field "rule_id" rest with
     | Some (Atom rule_id) ->
       (* The action shares its rule's [async_id] and always begins after
          the rule's begin, so the rule's lifecycle flow id is sitting in
          [open_rules]; borrowing it here chains, in timestamp order,
          exec-rule-start -> exec-rule-action-start ->
          exec-rule-action-finish -> exec-rule-finish. An action also proves
          the rule executed, so the id is guaranteed to surface on the
          rule's start/finish instants (never on a collapsed one). *)
       let action_flow_ids =
         match Table.find t.open_rules async_id with
         | Some (b : rule_begin) -> [ b.flow_id ]
         | None -> []
       in
       Table.set
         t.open_actions
         async_id
         { action_rule_id = rule_id; action_begin_ts = ts; action_flow_ids }
     | _ -> ())
  | "build-dep" ->
    (match field "dep" rest with
     | Some (Atom dep) ->
       Table.set
         t.open_deps
         async_id
         { dep; forced_by; begin_ts = ts; flow_id = fresh_flow_id t }
     | _ -> ())
  | "gen-rules" ->
    (match field "dir" rest with
     | Some (Atom dir) ->
       Table.set
         t.open_gen_rules
         async_id
         { gen_rules_dir = dir
         ; gen_rules_begin_ts = ts
         ; gen_rules_flow_id = fresh_flow_id t
         }
     | _ -> ())
  | "dynamic-includes" ->
    (match field "dune_file" rest with
     | Some (Atom dune_file) ->
       Table.set
         t.open_dynamic_includes
         async_id
         { dynamic_includes_dune_file = dune_file
         ; dynamic_includes_begin_ts = ts
         ; dynamic_includes_flow_id = fresh_flow_id t
         }
     | _ -> ())
  | _ -> ()
;;

(* Pair a matching end with its buffered begin: append the completed
   graph-blob record (exec-rule/build-dep only) and push the lifecycle
   instants for all four kinds, in trace order (i.e. ordered by end time).
   An end with no buffered begin (the begin was malformed, or predates this
   process) is dropped; a begin with no end is flushed separately at EOF
   (see [to_packets]). *)
let record_span_end t ~name ~async_id ~ts rest =
  match name with
  | "exec-rule" ->
    (match Table.find t.open_rules async_id with
     | None -> ()
     | Some b ->
       Table.remove t.open_rules async_id;
       let rule_outcome =
         match field "rule_outcome" rest with
         | Some (Atom s) -> s
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
       (* The dep set and each dyn-dep stage are registered in the
          factored dep-set table here, in span-end order -- that order is
          what the factoring's window slides over, so they are bound
          before the record is assembled rather than inline in it (the
          elements of a list expression are not evaluated left to
          right). *)
       let dep_set =
         (* [deps] is empty both for a rule with no deps and for one whose
            deps could not be determined; "?" tells them apart. *)
         match field "deps_unknown" rest with
         | Some (Sexp.Atom "true") -> "?"
         | _ -> Graph_blob.Dep_sets.field t.dep_sets (ids "deps")
       in
       let dyn_dep_stages = Graph_blob.Dep_sets.stages_field t.dep_sets dyn_deps in
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
       t.rev_rule_lines <- line :: t.rev_rule_lines;
       emit_exec_rule_end t ~ts b ~rule_outcome)
  | "exec-rule-action" ->
    (match Table.find t.open_actions async_id with
     | None -> ()
     | Some b ->
       Table.remove t.open_actions async_id;
       emit_action_end t ~ts b)
  | "build-dep" ->
    (match Table.find t.open_deps async_id with
     | None -> ()
     | Some b ->
       Table.remove t.open_deps async_id;
       (* A missing [dep_outcome] (malformed end) degrades to "?" rather
          than dropping the span, mirroring exec-rule's [rule_outcome]
          fallback above: the blob line and the perfetto instants should
          agree on which spans exist. *)
       let dep_outcome =
         Option.value (field "dep_outcome" rest) ~default:(Sexp.List [])
       in
       let line =
         String.concat
           ~sep:"\t"
           [ b.dep
           ; Graph_blob.dep_resolution dep_outcome
           ; Graph_blob.forced_by_code b.forced_by
           ; Graph_blob.dep_status_code (field "dep_status" rest)
           ]
       in
       t.rev_dep_lines <- line :: t.rev_dep_lines;
       emit_build_dep_end t ~ts b ~dep_outcome)
  | "gen-rules" ->
    (match Table.find t.open_gen_rules async_id with
     | None -> ()
     | Some b ->
       Table.remove t.open_gen_rules async_id;
       let dune_file =
         match field "dune_file" rest with
         | Some (Atom f) -> Some f
         | _ -> None
       in
       emit_gen_rules_end t ~ts b ~dune_file)
  | "dynamic-includes" ->
    (match Table.find t.open_dynamic_includes async_id with
     | None -> ()
     | Some b ->
       Table.remove t.open_dynamic_includes async_id;
       emit_dynamic_includes_end t ~ts b)
  | _ -> ()
;;

(* Dispatch a graph event's (already-extracted) phase/id to the begin/end
   recorders above; anything else (a different category, an "instant"
   phase, or a malformed async event) is not part of the graph lifecycle. *)
let record_graph_span t ~cat ~name ~async_phase ~async_id ~ts rest =
  match cat, async_phase, async_id with
  | "graph", Some "begin", Some id -> record_span_begin t ~name ~async_id:id ~ts rest
  | "graph", Some "end", Some id -> record_span_end t ~name ~async_id:id ~ts rest
  | _ -> ()
;;

(* Unmatched begins (crash/interrupt: EOF reached with a span still open) as
   graph-blob records with "?" for the fields only the end would have
   supplied, sorted by [async_id] for determinism (see
   doc/dev/trace-graph-perfetto.md, phase 1). *)
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
    String.concat ~sep:"\t" [ b.dep; "?"; Graph_blob.forced_by_code b.forced_by; "" ])
;;

(* Unmatched begins, also flushed as bare "-start" instants on their kind's
   track (see doc/dev/trace-graph-perfetto.md, phase 2): the finish never
   arrives, so there is nothing to pair with. Sorted by [async_id] like the
   blob flush above, for the same determinism reason. They keep their flow
   id: for a rule that crashed mid-action, the action's own flushed start
   instant carries it too, so the start -> action-start arrow survives
   (elsewhere the id ends up on a single event, which draws nothing). *)
let flush_open_start_instants t =
  let sorted tbl =
    Table.to_list tbl |> List.sort ~compare:(fun (a, _) (b, _) -> Int.compare a b)
  in
  List.iter (sorted t.open_rules) ~f:(fun (_async_id, (b : rule_begin)) ->
    push_instant
      t
      ~uuid:exec_rule_uuid
      ~track_name:"exec-rule"
      ~name:"exec-rule-start"
      ~ts:b.begin_ts
      ~flow_ids:[ b.flow_id ]
      ~args:(dune_args (rule_id_arg b.rule_id)));
  List.iter (sorted t.open_deps) ~f:(fun (_async_id, (b : dep_begin)) ->
    push_instant
      t
      ~uuid:build_dep_uuid
      ~track_name:"build-dep"
      ~name:"build-dep-start"
      ~ts:b.begin_ts
      ~flow_ids:[ b.flow_id ]
      ~args:(dune_args (dep_id_arg b.dep)));
  List.iter (sorted t.open_gen_rules) ~f:(fun (_async_id, (b : gen_rules_begin)) ->
    push_instant
      t
      ~uuid:gen_rules_uuid
      ~track_name:"gen-rules"
      ~name:"gen-rules-start"
      ~ts:b.gen_rules_begin_ts
      ~flow_ids:[ b.gen_rules_flow_id ]
      ~args:(dune_args [ P.Arg.string ~name:"dir" b.gen_rules_dir ]));
  List.iter
    (sorted t.open_dynamic_includes)
    ~f:(fun (_async_id, (b : dynamic_includes_begin)) ->
      push_instant
        t
        ~uuid:dynamic_includes_uuid
        ~track_name:"dynamic-includes"
        ~name:"dynamic-includes-start"
        ~ts:b.dynamic_includes_begin_ts
        ~flow_ids:[ b.dynamic_includes_flow_id ]
        ~args:(dune_args [ P.Arg.string ~name:"dune_file" b.dynamic_includes_dune_file ]));
  List.iter (sorted t.open_actions) ~f:(fun (_async_id, (b : action_begin)) ->
    push_action_start t b)
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
    push_instant
      t
      ~uuid:graph_uuid
      ~track_name:"dune-graph"
      ~name
      ~ts:t.last_ts
      ~flow_ids:[]
      ~args:
        [ P.Arg.dict
            ~name:"dune"
            [ P.Arg.int ~name:"version" Graph_blob.version
            ; P.Arg.int ~name:"seq" seq
            ; P.Arg.int ~name:"total" total
            ; P.Arg.string ~name:"data" data
            ]
        ])
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
  | v -> P.Arg.json ~name:key (Json.to_string (Trace_event.json_of_sexp v))
;;

(* Classify one [key = value] field as a recognised structural field or an
   unrecognised one. Graph async events (exec-rule/build-dep/gen-rules/
   dynamic-includes) never reach this: their fields are handled directly by
   [record_span_begin]/[record_span_end] and the [emit_*_end] functions
   above, which is also where "deps", "forced_by", "rule_outcome", and the
   like are rendered (or, per doc/dev/trace-graph-perfetto.md phases 2 and
   7, deliberately dropped from the instant in favour of the blob). [name]
   disambiguates the "targets" event's own "targets" field (see
   [Event.resolve_targets]) from an unrelated field of the same name
   elsewhere. *)
let classify_field ~name key v =
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
  | _ -> `Top (scalar_arg key v)
;;

(* Map an event's [rest] fields to Perfetto debug annotations. Recognised
   structural fields are grouped under a "dune" dict (surfacing as e.g.
   [debug.dune.target_files] in Trace Processor); unrecognised fields are
   left at the top level. Their strings are interned by [Dune_perfetto] when
   serialising. *)
let event_fields ~name rest =
  let dune, top =
    List.filter_map rest ~f:(function
      | Sexp.List [ Atom key; v ] -> Some (classify_field ~name key v)
      | _ -> None)
    |> List.partition_map ~f:(function
      | `Dune arg -> Left arg
      | `Top arg -> Right arg)
  in
  match dune with
  | [] -> top
  | _ :: _ -> P.Arg.dict ~name:"dune" dune :: top
;;

(* Graph async events (exec-rule/build-dep/gen-rules/dynamic-includes) are
   the only users of [async_phase]/[async_id] (see
   [Dune_engine.Graph_trace]) and are fully handled by [record_graph_span]:
   begins are buffered and ends emit the lifecycle instants directly, so
   nothing else need be pushed for them here. Everything else is a flat
   event on the main thread track, as before. *)
let add t sexp =
  let cat, name, ts_sexp, rest, _ = Trace_event.base_of_sexp sexp in
  let ts, dur = Trace_event.times_of_sexp ts_sexp in
  let ts_ns = Time.to_ns ts in
  t.last_ts <- ts_ns;
  match name with
  | "intern" -> record_interns t rest
  | _ ->
    ensure_process t;
    let async_phase, rest = Trace_event.async_phase_of_sexp rest in
    let async_id, rest = Trace_event.async_id_of_sexp rest in
    (match async_phase, async_id with
     | Some ("begin" | "end"), Some id ->
       record_graph_span t ~cat ~name ~async_phase ~async_id:(Some id) ~ts:ts_ns rest
     | _ ->
       let args = event_fields ~name rest in
       let open P.Event.Type in
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

(* The graph blob can only be assembled once the whole stream has been seen
   (it needs every intern entry and the EOF-time set of still-open spans),
   so it is flushed here rather than incrementally in [add]; the same is
   true of the EOF-only "-start" instants for spans left open by a
   crash/interrupt. The blob is emitted only if the trace has any [graph]
   category data, leaving existing traces (and assertions about them)
   unchanged. *)
let to_packets t =
  let dict = dict_lines t in
  let rules = List.rev t.rev_rule_lines @ flush_open_rules t in
  let deps = List.rev t.rev_dep_lines @ flush_open_deps t in
  flush_open_start_instants t;
  if not (List.is_empty dict && List.is_empty rules && List.is_empty deps)
  then (
    ensure_process t;
    push_graph_section t ~name:"graph-dict" dict;
    (* The cores and the dep sets were encoded as the rule spans ended;
       only their emission waits for EOF, like the other sections. A
       section with no records emits no instant at all, so a build whose
       dep sets are all too small to factor has no [graph-cores]. *)
    push_graph_section t ~name:"graph-cores" (Graph_blob.Dep_sets.core_lines t.dep_sets);
    push_graph_section t ~name:"graph-depsets" (Graph_blob.Dep_sets.set_lines t.dep_sets);
    push_graph_section t ~name:"graph-rules" rules;
    push_graph_section t ~name:"graph-deps" deps);
  List.rev t.rev_packets
;;
