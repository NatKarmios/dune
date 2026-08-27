open Import
module Event_sexp = Trace_common.Event_sexp
module Span_id = Trace_common.Span_id

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
  match atom "prog" rest with
  | None -> None
  | Some prog ->
    let args =
      match field "process_args" rest with
      | Some (List args) ->
        List.filter_map args ~f:(function
          | Sexp.Atom s -> Some s
          | _ -> None)
      | _ -> []
    in
    Some { prog; args; dir = atom "dir" rest }
;;

let parse_end spawned rest =
  let exit_code =
    match atom "exit" rest with
    | None -> 0
    | Some e ->
      (try int_of_string e with
       | Failure _ -> 0)
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

let info =
  let doc = "Display executed processes in shell format" in
  Cmd.info "commands" ~doc
;;

let term =
  let+ trace_file = Trace_common.term in
  (* Begins are held until their end arrives, so a process is printed once it
     has finished -- and one that never finished is not printed at all. *)
  let open_spans = Table.create (module Span_id) 256 in
  Event_sexp.iter trace_file ~f:(fun sexp ->
    match Event_sexp.to_base_args sexp with
    | "process", "process", _ts, rest, digest ->
      let async_phase, async_id, rest = Event_sexp.to_async_args rest in
      (match async_phase, async_id with
       | Some "begin", Some async_id ->
         (match parse_begin rest with
          | None -> ()
          | Some spawned -> Table.set open_spans (Span_id.make ~digest ~async_id) spawned)
       | Some "end", Some async_id ->
         let span_id = Span_id.make ~digest ~async_id in
         (match Table.find open_spans span_id with
          | None -> ()
          | Some spawned ->
            Table.remove open_spans span_id;
            print_endline (format_output (parse_end spawned rest)))
       | _ -> ())
    | _ -> ())
;;

let cmd = Cmd.v info term
