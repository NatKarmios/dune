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
