open Import
module Event_sexp = Trace_common.Event_sexp

let pid = lazy (Unix.getpid ())

let json_of_event ~chrome (sexp : Sexp.t) =
  let cat, name, ts, rest, _ = Event_sexp.to_base_args sexp in
  let ts, dur = Event_sexp.to_times ts in
  let async_phase, async_id, rest = Event_sexp.to_async_args rest in
  let rest =
    List.map rest ~f:(function
      | Sexp.List [ Atom ("process_args" as k); List v ] ->
        ( k
        , Json.list
            (List.map v ~f:(function
               | Sexp.Atom s -> Json.string s
               | _ -> Event_sexp.invalid sexp)) )
      | Sexp.List [ Atom k; v ] -> k, Event_sexp.to_json v
      | _ -> Event_sexp.invalid sexp)
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

let info = Cmd.info "cat"

let term =
  let+ sexp =
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
  and+ trace_file = Trace_common.term
  and+ follow =
    Arg.(
      value
      & flag
      & info [ "follow"; "f" ] ~doc:(Some "follow the trace file until the exit event"))
  in
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
  if follow
  then Event_sexp.iter_follow trace_file ~f:print_with_flush
  else Event_sexp.iter trace_file ~f:print;
  match mode with
  | `Chrome -> print_endline "]"
  | `Json | `Sexp -> ()
;;

let cmd = Cmd.v info term
