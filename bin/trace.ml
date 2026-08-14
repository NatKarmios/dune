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

(* Perfetto native-protobuf export. Consumes the same csexp event stream as
   [json_of_event], mapping each graph async span (matched by its "id") to a
   Perfetto slice on its own track, flat complete/instant events to
   slices/instants on a main thread track, and the intern tables to readable
   target/dep names. *)
module Perfetto_conv = struct
  module P = Dune_perfetto

  (* Track uuids: a single process track, one main thread track under it, and
     one child track per async span id (offset past the two fixed uuids). *)
  let process_uuid = 1
  let main_thread_uuid = 2
  let async_uuid id = id + 3

  type t =
    { mutable declared_process : bool
    ; seen_async : (int, unit) Table.t
    ; (* Interned strings (targets and deps share one table, see the [intern]
         event). Maps id -> readable value. *)
      names : (int, string) Table.t
    ; mutable rev_packets : P.packet list
    }

  let create () =
    { declared_process = false
    ; seen_async = Table.create (module Int) 256
    ; names = Table.create (module Int) 2048
    ; rev_packets = []
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
    match name with
    | "intern" -> record_interns t rest
    | _ ->
      let ts, dur = times_of_sexp ts_sexp in
      let ts_ns = Time.to_ns ts in
      ensure_process t;
      let async_phase, rest = async_phase_of_sexp rest in
      let async_id, rest = async_id_of_sexp rest in
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

  let to_packets t = List.rev t.rev_packets
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
