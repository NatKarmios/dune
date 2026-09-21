open Import
module P = Perfetto
module Span_id = Trace_common.Span_id

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

module Debug_annot = struct
  include P.Debug_annot

  let atoms xs =
    List.filter_map xs ~f:(function
      | Sexp.Atom s -> Some s
      | _ -> None)
  ;;

  let string_array ~name strings =
    array ~name (List.map strings ~f:(fun s -> string ~name:"" s))
  ;;

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

  (* Massage particular fields, which would otherwise land as raw JSON *)
  let classify ~name key v =
    match key, v with
    | "targets", Sexp.List xs when String.equal name "targets" ->
      (* The user-requested build targets, rendered as real paths. *)
      `Dune (string_array ~name:key (atoms xs))
    | "process_args", Sexp.List xs -> `Dune (string_array ~name:key (atoms xs))
    | "forced_by", Sexp.List parts ->
      (* For process slices *)
      `Dune (string ~name:key (String.concat ~sep:" " (atoms parts)))
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
  let processes = 3

  (* Slot tracks are allocated as needed, so their uuids cannot be fixed. *)
  let first_dynamic = 4

  (* The order the tracks directly under [process] are shown in. *)
  let sibling_order_rank uuid =
    List.findi [ main_thread; processes ] ~f:(Int.equal uuid) |> Option.map ~f:snd
  ;;
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

(* The begin side of a process span, held until its end arrives. *)
module Process_span = struct
  type t =
    { slot : Process_slot.t
    ; begin_ts : int
    ; cat : string
    ; fields : Sexp.t list
    }
end

type t =
  { mutable declared_process : bool
  ; declared_tracks : (int, unit) Table.t
  ; mutable rev_packets : P.packet list
  ; (* Timestamp (ns) of the last event seen; used to close the spans that
       are still open at the end of the file. *)
    mutable last_ts : int
  ; open_processes : (Span_id.t, Process_span.t) Table.t
  ; (* Slots in allocation order, so a slot's position names its track. *)
    mutable process_slots : Process_slot.t list
  ; mutable next_track_uuid : int
  }

let create () =
  { declared_process = false
  ; declared_tracks = Table.create (module Int) 8
  ; rev_packets = []
  ; last_ts = 0
  ; open_processes = Table.create (module Span_id) 256
  ; process_slots = []
  ; next_track_uuid = Track_uuid.first_dynamic
  }
;;

let push t p = t.rev_packets <- p :: t.rev_packets

let fresh_track_uuid t =
  let uuid = t.next_track_uuid in
  t.next_track_uuid <- uuid + 1;
  uuid
;;

let ensure_root_process t =
  if not t.declared_process
  then (
    t.declared_process <- true;
    push
      t
      (P.Track_descriptor
         (P.Track.process
            ~uuid:Track_uuid.process
            ~pid:0
            ~name:"dune"
            ~child_ordering:Explicit
            ()));
    push
      t
      (P.Track_descriptor
         (P.Track.thread
            ~uuid:Track_uuid.main_thread
            ~parent_uuid:Track_uuid.process
            ~pid:0
            ~tid:0
            ~name:"main"
            ?sibling_order_rank:(Track_uuid.sibling_order_rank Track_uuid.main_thread)
            ())))
;;

let ensure_track t uuid ~parent_uuid ~name =
  match Table.find t.declared_tracks uuid with
  | Some () -> ()
  | None ->
    Table.set t.declared_tracks uuid ();
    push
      t
      (P.Track_descriptor
         (P.Track.child
            ~uuid
            ~parent_uuid
            ~name
            ?sibling_order_rank:(Track_uuid.sibling_order_rank uuid)
            ()))
;;

module Process = struct
  let claim_slot t ~ts =
    match
      List.find t.process_slots ~f:(fun (slot : Process_slot.t) ->
        (not slot.busy) && slot.last_ts <= ts)
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
    Table.set
      t.open_processes
      span_id
      { Process_span.slot = claim_slot t ~ts; begin_ts = ts; cat; fields = rest }
  ;;

  let push_slice t (b : Process_span.t) ~stop rest =
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
            ~debug_annots:(Debug_annot.map_rest ~name (b.fields @ rest))
            P.Event.Type.Begin
            ~track_uuid
            ~ts:b.begin_ts));
    push t (P.Track_event (P.Event.create P.Event.Type.End ~track_uuid ~ts:stop))
  ;;

  let record_end t ~span_id ~ts rest =
    match Table.find t.open_processes span_id with
    | None -> ()
    | Some b ->
      Table.remove t.open_processes span_id;
      b.slot.busy <- false;
      b.slot.last_ts <- ts;
      push_slice t b ~stop:ts rest
  ;;

  (* A trace that was cut short leaves begins with no end. Close them at the
     last timestamp seen, in span order so the output stays deterministic. *)
  let flush_unmatched t =
    Table.to_list t.open_processes
    |> List.sort ~compare:(fun (a, _) (b, _) -> Span_id.compare a b)
    |> List.iter ~f:(fun (_span_id, (b : Process_span.t)) ->
      push_slice t b ~stop:(Int.max t.last_ts b.begin_ts) [])
  ;;
end

let add t sexp =
  let cat, name, ts_sexp, rest, digest = Trace_common.Event_sexp.to_base_args sexp in
  let ts, dur = Trace_common.Event_sexp.to_times ts_sexp in
  let ts_ns = Time.to_ns ts in
  t.last_ts <- ts_ns;
  ensure_root_process t;
  let async_phase, async_id, rest = Trace_common.Event_sexp.to_async_args rest in
  match Option.bind async_phase ~f:Async_phase.of_string, async_id with
  | Some async_phase, Some async_id ->
    let span_id = Span_id.make ~digest ~async_id in
    (match cat with
     | "process" ->
       (match async_phase with
        | Async_phase.Begin -> Process.record_begin t ~cat ~span_id ~ts:ts_ns rest
        | Async_phase.End -> Process.record_end t ~span_id ~ts:ts_ns rest)
     | _ -> ())
  | _ ->
    let debug_annots = Debug_annot.map_rest ~name rest in
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
               ~debug_annots
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
               ~debug_annots
               Instant
               ~track_uuid
               ~ts:ts_ns)))
;;

let to_packets t =
  Process.flush_unmatched t;
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
  | Some file -> Io.String_path.write_file_exn ~binary:true file data
  | None -> print_string data
;;

let cmd = Cmd.v info term
