open Import

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

(* The "async_id" and "async_phase" of an async span, split off from the rest
   of the event's arguments. *)
let to_async_args rest =
  let phase =
    List.find_map rest ~f:(function
      | Sexp.List [ Atom "async_phase"; Atom phase ] -> Some phase
      | _ -> None)
  in
  let id =
    List.find_map rest ~f:(function
      | Sexp.List [ Atom "async_id"; Atom id ] -> int_of_string_opt id
      | _ -> None)
  in
  let rest =
    List.filter rest ~f:(function
      | Sexp.List [ Atom ("async_phase" | "async_id"); _ ] -> false
      | _ -> true)
  in
  phase, id, rest
;;

(* Identifies one async span. [async_id] counts spans within a single dune
   invocation, and a nested dune's events are folded into the same stream
   tagged with its action digest, so it takes both to tell spans apart. *)
let span_id ~digest ~async_id = sprintf "%s/%d" (Option.value digest ~default:"") async_id

(* The command a process ran is on the begin of its span, the outcome of
   running it on the end. *)
type spawned =
  { prog : string
  ; args : string list
  ; dir : string option
  }

type process_info =
  { spawned : spawned
  ; exit_code : int
  ; error : string option
  ; stderr : string
  }

let field key rest =
  List.find_map rest ~f:(function
    | Sexp.List [ Atom k; v ] when String.equal k key -> Some v
    | _ -> None)
;;

let atom key rest =
  match field key rest with
  | Some (Sexp.Atom s) -> Some s
  | _ -> None
;;

(* A begin without a "prog" says nothing about what ran, so its span is
   dropped: the end will then find nothing held for it and drop too. *)
let parse_begin rest =
  Option.map (atom "prog" rest) ~f:(fun prog ->
    let args =
      match field "process_args" rest with
      | Some (List args) ->
        List.filter_map args ~f:(function
          | Sexp.Atom s -> Some s
          | _ -> None)
      | _ -> []
    in
    { prog; args; dir = atom "dir" rest })
;;

let parse_end spawned rest =
  let exit_code =
    match Option.bind (atom "exit" rest) ~f:int_of_string_opt with
    | None -> 0
    | Some code -> code
  in
  { spawned
  ; exit_code
  ; error = atom "error" rest
  ; stderr = Option.value (atom "stderr" rest) ~default:""
  }
;;

let format_shell_command ({ prog; args; dir } : spawned) : string =
  let module Escape = Escape0 in
  let cmd =
    let quoted_prog = Escape.quote_if_needed prog in
    let quoted_args = List.map args ~f:Escape.quote_if_needed in
    String.concat ~sep:" " (quoted_prog :: quoted_args)
  in
  match dir with
  | None -> sprintf "(%s)" cmd
  | Some dir ->
    let dir = Escape.quote_if_needed dir in
    Printf.sprintf "(cd %s && %s)" dir cmd
;;

let format_output (info : process_info) : string =
  let cmd_line = format_shell_command info.spawned in
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

let json_of_event ~chrome (sexp : Sexp.t) =
  let cat, name, ts, rest, _ = base_of_sexp sexp in
  let ts, dur = times_of_sexp ts in
  let async_phase, async_id, rest = to_async_args rest in
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
      | Some _, _ | None, None -> "i"
      | None, Some _ -> "X"
    in
    let id_field =
      match async_phase, async_id with
      | Some _, Some id -> [ "id", Json.int id ]
      | _ -> []
    in
    Json.assoc
      (base @ [ "ph", Json.string kind; "pid", Json.int (Lazy.force pid) ] @ id_field)
;;

let cat =
  let info = Cmd.info "cat" in
  let term =
    let+ debug_backtraces = Common.No_build.debug_backtraces
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
    and+ action_events =
      Arg.(
        value
        & vflag
            `All
            [ ( `Exclude
              , info [ "no-actions" ] ~doc:(Some "exclude events emitted by actions") )
            ; ( `Only
              , info [ "only-actions" ] ~doc:(Some "print only events emitted by actions")
              )
            ])
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
    let first_chrome_event = ref true in
    let print =
      match mode with
      | `Sexp -> fun sexp -> print_endline (Sexp.to_string sexp)
      | `Json ->
        fun sexp -> print_endline (Json.to_string (json_of_event ~chrome:false sexp))
      | `Chrome ->
        fun sexp ->
          let char =
            if !first_chrome_event
            then (
              let () = first_chrome_event := false in
              '[')
            else ','
          in
          print_char char;
          print_endline (Json.to_string (json_of_event ~chrome:true sexp))
    in
    let print_if_selected sexp =
      let selected =
        match action_events with
        | `All -> true
        | (`Exclude | `Only) as action_events ->
          let _, _, _, _, digest = base_of_sexp sexp in
          let is_action = Option.is_some digest in
          (match action_events with
           | `Exclude -> not is_action
           | `Only -> is_action)
      in
      if selected
      then (
        print sexp;
        if follow then flush stdout)
    in
    let trace_file =
      match trace_file with
      | Some s -> s
      | None -> Common.find_default_trace_file ()
    in
    if follow
    then iter_sexps_follow trace_file ~f:print_if_selected
    else iter_sexps trace_file ~f:print_if_selected;
    match mode with
    | `Chrome -> print_endline (if !first_chrome_event then "[]" else "]")
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
    let+ debug_backtraces = Common.No_build.debug_backtraces
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
    (* Begins are held until their end arrives, so a process is printed once it
       has finished -- and one that never finished is not printed at all. *)
    let open_spans = String.Table.create 256 in
    iter_sexps trace_file ~f:(fun sexp ->
      match base_of_sexp sexp with
      | "process", "process", _ts, rest, digest ->
        let async_phase, async_id, rest = to_async_args rest in
        (match async_phase, async_id with
         | Some "begin", Some async_id ->
           (match parse_begin rest with
            | None -> ()
            | Some spawned ->
              String.Table.set open_spans (span_id ~digest ~async_id) spawned)
         | Some "end", Some async_id ->
           let span_id = span_id ~digest ~async_id in
           (match String.Table.find open_spans span_id with
            | None -> ()
            | Some spawned ->
              String.Table.remove open_spans span_id;
              print_endline (format_output (parse_end spawned rest)))
         | _ -> ())
      | _ -> ())
  in
  Cmd.v info term
;;

let group =
  let info =
    let doc = "Commands to view dune's event trace" in
    Cmd.info "trace" ~doc
  in
  Cmd.group info [ cat; commands ]
;;
