open Import

module Event_sexp = struct
  let iter file ~f =
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

  let rec to_json : Sexp.t -> Json.t = function
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
          | Sexp.List [ Atom k; v ] -> k, to_json v
          | _ -> assert false)
        |> Json.assoc
      else Json.list (List.map xs ~f:to_json)
  ;;

  let invalid sexp = User_error.raise [ Pp.text "invalid sexp"; Sexp.pp sexp ]

  let to_base_args (sexp : Sexp.t) =
    match sexp with
    | List (Atom cat :: Atom name :: ts :: rest) ->
      let digest =
        List.find_map rest ~f:(function
          | Sexp.List [ Atom "digest"; Atom d ] -> Some d
          | _ -> None)
      in
      cat, name, ts, rest, digest
    | _ -> invalid sexp
  ;;

  let iter_follow file ~f =
    Io.String_path.with_file_in ~binary:true file ~f:(fun chan ->
      let rec loop () =
        match Csexp.input_opt chan with
        | Ok (Some sexp) ->
          (* Check if exit event before processing *)
          let is_exit =
            match to_base_args sexp with
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

  let to_times (sexp : Sexp.t) =
    match sexp with
    | Atom s ->
      let ns = int_of_string s in
      Time.of_ns ns, None
    | List [ Atom ts; Atom dur ] ->
      let ts_ns = int_of_string ts in
      let dur_ns = int_of_string dur in
      Time.of_ns ts_ns, Some (Time.Span.of_ns dur_ns)
    | _ -> invalid sexp
  ;;

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
end

(* Identifies one async span. [async_id] counts spans within a single dune
   invocation, and a nested dune's events are folded into the same stream
   tagged with its action digest, so it takes both to tell spans apart. *)
module Span_id = struct
  module T = struct
    (* Spans are numbered in the order they begin, so [async_id] comes first:
       the derived comparison then puts one invocation's spans in trace
       order. *)
    type t =
      { async_id : int
      ; digest : string option
      }

    let repr =
      Repr.record
        "Span_id.t"
        [ Repr.field "async_id" Repr.int ~get:(fun { async_id; _ } -> async_id)
        ; Repr.field "digest" (Repr.option Repr.string) ~get:(fun { digest; _ } -> digest)
        ]
    ;;
  end

  include T
  include Repr.Poly (T)
  include Repr.Make (T)

  let make ~digest ~async_id = { async_id; digest }
end

let term =
  let+ trace_file =
    Arg.(
      value
      & opt (some string) None
      & info
          [ "trace-file" ]
          ~docv:"FILE"
          ~doc:(Some "Read this trace file (default: _build/trace.csexp)"))
  in
  match trace_file with
  | Some s -> s
  | None -> Common.find_default_trace_file ()
;;
