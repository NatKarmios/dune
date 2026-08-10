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

  (* The structural graph-event fields are promoted from generic Perfetto
     [DebugAnnotation]s to a typed [TrackEvent] extension, [dune.DuneTrackEvent],
     so they land in Trace Processor's args table with stable names and types
     (queryable as e.g. [EXTRACT_ARG(arg_set_id, 'dune.targets')]). Perfetto
     learns the schema from an [Extension_descriptor] packet carrying a
     hand-built [FileDescriptorSet]; the field numbers below are all fixed points
     of Perfetto's / protobuf's own schemas. Any field the extension does not
     model stays a [DebugAnnotation]. *)
  module Ext = struct
    (* Our extension's field number on [TrackEvent]. Must sit in TrackEvent's
       reserved extension range and not clash with Chrome's (1000). *)
    let track_event_field = 9910

    (* DuneTrackEvent field numbers (see [descriptor] below). [forced_by] and
       [dep_outcome] are tagged unions carried as nested messages; the two kinds
       of rule/dep "outcome" event field have distinct names (rule execution vs.
       dependency resolution), so they map to distinct extension fields. *)
    let targets = 1
    let deps = 2
    let dep = 3
    let forced_by = 4
    let rule_outcome = 5
    let process_args = 6
    let dyn_deps = 7
    let rule_id = 8
    let dep_outcome = 9
    let dyn_dep_stage_deps = 1

    (* [ForcedBy] and [DepOutcome] are tagged unions where exactly one payload
       field is set, mirroring [Graph.forced_by] / [Build_dep.outcome]. In real
       protobuf these would be a [oneof], but Trace Processor's descriptor pool
       ignores [oneof_decl] / [oneof_index] entirely (it decodes purely by field
       number), so a [oneof] would buy nothing here; we model them as optional
       fields. [ForcedBy.kind] is a required enum stating which case applies
       (including [NONE], for work not attributed to any forcer). *)
    let fb_kind = 1
    let fb_rule = 2
    let fb_dep = 3
    let fb_dynamic_includes = 4
    let fb_gen_rules = 5
    let fb_pform = 6
    let kind_none = 0
    let kind_rule = 1
    let kind_dep = 2
    let kind_dynamic_includes = 3
    let kind_gen_rules = 4
    let kind_pform = 5
    let kind_configurator = 6
    let do_rule = 1
    let do_expanded = 2
    let do_is_source = 3

    (* google.protobuf.descriptor field numbers and enum values. *)
    let fds_file = 1
    let file_name = 1
    let file_package = 2
    let file_message_type = 4
    let file_extension = 7
    let file_syntax = 12
    let msg_name = 1
    let msg_field = 2
    let msg_nested_type = 3
    let msg_enum_type = 4
    let enum_name = 1
    let enum_value = 2
    let enum_value_name = 1
    let enum_value_number = 2
    let fld_name = 1
    let fld_extendee = 2
    let fld_number = 3
    let fld_label = 4
    let fld_type = 5
    let fld_type_name = 6
    let label_optional = 1
    let label_required = 2
    let label_repeated = 3
    let type_int64 = 3
    let type_bool = 8
    let type_string = 9
    let type_message = 11
    let type_enum = 14

    let field_descriptor ~name ~number ~label ~typ ?type_name () =
      P.Proto.message
        ~field:msg_field
        (P.Proto.
           [ string ~field:fld_name name
           ; varint ~field:fld_number number
           ; varint ~field:fld_label label
           ; varint ~field:fld_type typ
           ]
         @
         match type_name with
         | Some t -> [ P.Proto.string ~field:fld_type_name t ]
         | None -> [])
    ;;

    let string_field ~name ~number ~label () =
      field_descriptor ~name ~number ~label ~typ:type_string ()
    ;;

    let int64_field ~name ~number ~label () =
      field_descriptor ~name ~number ~label ~typ:type_int64 ()
    ;;

    let bool_field ~name ~number ~label () =
      field_descriptor ~name ~number ~label ~typ:type_bool ()
    ;;

    let message_field ~name ~number ~label ~type_name () =
      field_descriptor ~name ~number ~label ~typ:type_message ~type_name ()
    ;;

    let enum_field ~name ~number ~label ~type_name () =
      field_descriptor ~name ~number ~label ~typ:type_enum ~type_name ()
    ;;

    let message ~name fields =
      P.Proto.message
        ~field:msg_nested_type
        (P.Proto.string ~field:msg_name name :: fields)
    ;;

    (* A nested [EnumDescriptorProto] with the given [name] and [values]
       ([value name -> number]). *)
    let enum ~name values =
      P.Proto.message
        ~field:msg_enum_type
        (P.Proto.string ~field:enum_name name
         :: List.map values ~f:(fun (value_name, number) ->
           P.Proto.message
             ~field:enum_value
             [ P.Proto.string ~field:enum_value_name value_name
             ; P.Proto.varint ~field:enum_value_number number
             ]))
    ;;

    (* A single FileDescriptorProto describing package "dune", the message
       DuneTrackEvent (with its nested messages), and the extension of
       TrackEvent. Trace Processor resolves [.perfetto.protos.TrackEvent] against
       its own built-in pool, so we neither embed nor import perfetto_trace.proto. *)
    let descriptor =
      let dyn_dep_stage =
        message
          ~name:"DynDepStage"
          [ string_field ~name:"deps" ~number:dyn_dep_stage_deps ~label:label_repeated ()
          ]
      in
      let forced_by_msg =
        message
          ~name:"ForcedBy"
          [ enum_field
              ~name:"kind"
              ~number:fb_kind
              ~label:label_required
              ~type_name:".dune.DuneTrackEvent.ForcedBy.Kind"
              ()
          ; int64_field ~name:"rule" ~number:fb_rule ~label:label_optional ()
          ; string_field ~name:"dep" ~number:fb_dep ~label:label_optional ()
          ; string_field
              ~name:"dynamic_includes"
              ~number:fb_dynamic_includes
              ~label:label_optional
              ()
          ; string_field ~name:"gen_rules" ~number:fb_gen_rules ~label:label_optional ()
          ; string_field ~name:"pform" ~number:fb_pform ~label:label_optional ()
          ; enum
              ~name:"Kind"
              [ "NONE", kind_none
              ; "RULE", kind_rule
              ; "DEP", kind_dep
              ; "DYNAMIC_INCLUDES", kind_dynamic_includes
              ; "GEN_RULES", kind_gen_rules
              ; "PFORM", kind_pform
              ; "CONFIGURATOR", kind_configurator
              ]
          ]
      in
      let dep_outcome_msg =
        message
          ~name:"DepOutcome"
          [ int64_field ~name:"rule" ~number:do_rule ~label:label_optional ()
          ; string_field ~name:"expanded" ~number:do_expanded ~label:label_repeated ()
          ; bool_field ~name:"is_source" ~number:do_is_source ~label:label_optional ()
          ]
      in
      let dune_track_event =
        P.Proto.message
          ~field:file_message_type
          [ P.Proto.string ~field:msg_name "DuneTrackEvent"
          ; string_field ~name:"targets" ~number:targets ~label:label_repeated ()
          ; string_field ~name:"deps" ~number:deps ~label:label_repeated ()
          ; string_field ~name:"dep" ~number:dep ~label:label_optional ()
          ; message_field
              ~name:"forced_by"
              ~number:forced_by
              ~label:label_optional
              ~type_name:".dune.DuneTrackEvent.ForcedBy"
              ()
          ; string_field
              ~name:"rule_outcome"
              ~number:rule_outcome
              ~label:label_optional
              ()
          ; string_field
              ~name:"process_args"
              ~number:process_args
              ~label:label_repeated
              ()
          ; message_field
              ~name:"dyn_deps"
              ~number:dyn_deps
              ~label:label_repeated
              ~type_name:".dune.DuneTrackEvent.DynDepStage"
              ()
          ; int64_field ~name:"rule_id" ~number:rule_id ~label:label_optional ()
          ; message_field
              ~name:"dep_outcome"
              ~number:dep_outcome
              ~label:label_optional
              ~type_name:".dune.DuneTrackEvent.DepOutcome"
              ()
          ; dyn_dep_stage
          ; forced_by_msg
          ; dep_outcome_msg
          ]
      in
      let extension =
        P.Proto.message
          ~field:file_extension
          P.Proto.
            [ string ~field:fld_name "dune"
            ; string ~field:fld_extendee ".perfetto.protos.TrackEvent"
            ; varint ~field:fld_number track_event_field
            ; varint ~field:fld_label label_optional
            ; varint ~field:fld_type type_message
            ; string ~field:fld_type_name ".dune.DuneTrackEvent"
            ]
      in
      [ P.Proto.message
          ~field:fds_file
          [ P.Proto.string ~field:file_name "dune_track_event.proto"
          ; P.Proto.string ~field:file_package "dune"
          ; dune_track_event
          ; extension
          ; P.Proto.string ~field:file_syntax "proto2"
          ]
      ]
    ;;
  end

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
    ; (* The extension descriptor must precede the events that use it, so it is
         the first packet emitted. *)
      rev_packets = [ P.Extension_descriptor Ext.descriptor ]
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

  (* [Graph.forced_by] as the nested ForcedBy message: a required [kind] enum
     plus (for all but [none]) the matching payload field. The dep/path payloads
     are interned ids (the [rule] payload is a bare rule id), resolved here. *)
  let forced_by_message t = function
    | Sexp.List [] -> [ P.Proto.varint ~field:Ext.fb_kind Ext.kind_none ]
    | Sexp.List (Atom "rule" :: Atom id :: _) ->
      P.Proto.varint ~field:Ext.fb_kind Ext.kind_rule
      ::
      (match int_of_string_opt id with
       | Some n -> [ P.Proto.varint ~field:Ext.fb_rule n ]
       | None -> [])
    | Sexp.List (Atom "dep" :: Atom dep :: _) ->
      [ P.Proto.varint ~field:Ext.fb_kind Ext.kind_dep
      ; P.Proto.string ~field:Ext.fb_dep (resolve_id t.names dep)
      ]
    | Sexp.List (Atom "dynamic-includes" :: Atom path :: _) ->
      [ P.Proto.varint ~field:Ext.fb_kind Ext.kind_dynamic_includes
      ; P.Proto.string ~field:Ext.fb_dynamic_includes (resolve_id t.names path)
      ]
    | Sexp.List (Atom "gen-rules" :: Atom dir :: _) ->
      [ P.Proto.varint ~field:Ext.fb_kind Ext.kind_gen_rules
      ; P.Proto.string ~field:Ext.fb_gen_rules (resolve_id t.names dir)
      ]
    | Sexp.List (Atom "pform" :: Atom dune_file :: _) ->
      [ P.Proto.varint ~field:Ext.fb_kind Ext.kind_pform
      ; P.Proto.string ~field:Ext.fb_pform (resolve_id t.names dune_file)
      ]
    | Sexp.List (Atom "configurator" :: _) ->
      [ P.Proto.varint ~field:Ext.fb_kind Ext.kind_configurator ]
    | _ -> []
  ;;

  (* [Build_dep.outcome] as the nested DepOutcome message; the [expanded] case
     carries interned dep ids, resolved here. *)
  let dep_outcome_message t = function
    | Sexp.List (Atom "rule" :: Atom id :: _) ->
      (match int_of_string_opt id with
       | Some n -> [ P.Proto.varint ~field:Ext.do_rule n ]
       | None -> [])
    | Sexp.List (Atom "expanded" :: ids) ->
      List.map (resolve_id_strings t.names ids) ~f:(fun s ->
        P.Proto.string ~field:Ext.do_expanded s)
    | Sexp.List (Atom "is-source" :: _) -> [ P.Proto.bool ~field:Ext.do_is_source true ]
    | _ -> []
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

  (* Split an event's [rest] fields into a typed [DuneTrackEvent] extension (the
     structural graph fields, with interned ids resolved to names) and generic
     debug annotations (everything else). Fields whose shape is unexpected fall
     back to an annotation rather than being dropped. *)
  let event_fields t rest =
    let ext = ref [] in
    let annots = ref [] in
    let repeated ~field strings =
      List.iter strings ~f:(fun s -> ext := P.Proto.string ~field s :: !ext)
    in
    List.iter rest ~f:(function
      | Sexp.List [ Atom key; v ] ->
        (match key, v with
         | "targets", Sexp.List ids ->
           repeated ~field:Ext.targets (resolve_id_strings t.names ids)
         | "deps", Sexp.List ids ->
           repeated ~field:Ext.deps (resolve_id_strings t.names ids)
         | "dep", Sexp.Atom s ->
           ext := P.Proto.string ~field:Ext.dep (resolve_id t.names s) :: !ext
         | "rule_id", Sexp.Atom s ->
           (match int_of_string_opt s with
            | Some n -> ext := P.Proto.varint ~field:Ext.rule_id n :: !ext
            | None -> annots := scalar_arg key v :: !annots)
         | "forced_by", _ ->
           (match forced_by_message t v with
            | [] -> annots := scalar_arg key v :: !annots
            | fields -> ext := P.Proto.message ~field:Ext.forced_by fields :: !ext)
         | "rule_outcome", Sexp.Atom s ->
           ext := P.Proto.string ~field:Ext.rule_outcome s :: !ext
         | "dep_outcome", Sexp.List _ ->
           (match dep_outcome_message t v with
            | [] -> annots := scalar_arg key v :: !annots
            | fields -> ext := P.Proto.message ~field:Ext.dep_outcome fields :: !ext)
         | "process_args", Sexp.List xs ->
           repeated
             ~field:Ext.process_args
             (List.filter_map xs ~f:(function
                | Sexp.Atom s -> Some s
                | _ -> None))
         | "dyn_deps", Sexp.List stages ->
           List.iter stages ~f:(function
             | Sexp.List ids ->
               let deps =
                 List.map (resolve_id_strings t.names ids) ~f:(fun s ->
                   P.Proto.string ~field:Ext.dyn_dep_stage_deps s)
               in
               ext := P.Proto.message ~field:Ext.dyn_deps deps :: !ext
             | _ -> ())
         | _ -> annots := scalar_arg key v :: !annots)
      | _ -> ());
    let extension =
      match List.rev !ext with
      | [] -> None
      | fields -> Some (P.Proto.message ~field:Ext.track_event_field fields)
    in
    extension, List.rev !annots
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
      let extension, args = event_fields t rest in
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
                 ?extension
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
                    ?extension
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
                    ?extension
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
