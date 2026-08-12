module List = ListLabels
module String = StringLabels

(* Internal representation. The smart constructors below build these records;
   [to_bytes] and [to_text] both consume them (after [resolve] rewrites strings
   to interned ids). *)

module Arg = struct
  type value =
    | Bool of bool
    | Int of int
    | Float of float
    | String of string
    | Json of string
    | Dict of t list
    | Array of t list

  and t =
    { arg_name : string
    ; value : value
    }

  let bool ~name b = { arg_name = name; value = Bool b }
  let int ~name i = { arg_name = name; value = Int i }
  let float ~name f = { arg_name = name; value = Float f }
  let string ~name s = { arg_name = name; value = String s }
  let json ~name s = { arg_name = name; value = Json s }
  let dict ~name xs = { arg_name = name; value = Dict xs }
  let array ~name xs = { arg_name = name; value = Array xs }
end

module Track = struct
  type kind =
    | Process of { pid : int }
    | Thread of
        { parent_uuid : int
        ; pid : int
        ; tid : int
        }
    | Child of { parent_uuid : int }

  type t =
    { uuid : int
    ; track_name : string
    ; track_kind : kind
    }

  let process ~uuid ~pid ~name = { uuid; track_name = name; track_kind = Process { pid } }

  let thread ~uuid ~parent_uuid ~pid ~tid ~name =
    { uuid; track_name = name; track_kind = Thread { parent_uuid; pid; tid } }
  ;;

  let child ~uuid ~parent_uuid ~name =
    { uuid; track_name = name; track_kind = Child { parent_uuid } }
  ;;
end

module Event = struct
  module Type = struct
    type t =
      | Begin
      | End
      | Instant

    let enum = function
      | Begin -> 1
      | End -> 2
      | Instant -> 3
    ;;

    let name = function
      | Begin -> "TYPE_SLICE_BEGIN"
      | End -> "TYPE_SLICE_END"
      | Instant -> "TYPE_INSTANT"
    ;;
  end

  type t =
    { etype : Type.t
    ; ename : string option
    ; categories : string list
    ; eargs : Arg.t list
    ; flow_ids : int list
    ; track_uuid : int
    ; ts : int
    }

  let create ?name ?(categories = []) ?(args = []) ?(flow_ids = []) type_ ~track_uuid ~ts =
    { etype = type_; ename = name; categories; eargs = args; flow_ids; track_uuid; ts }
  ;;
end

type packet =
  | Track_descriptor of Track.t
  | Track_event of Event.t

(* All packets from a single writer share one non-zero sequence id; without it
   Perfetto silently drops track events. *)
let trusted_packet_sequence_id = 1

(* [TracePacket.sequence_flags]. The first packet participating in incremental
   (interned) state clears any prior state; every packet that defines or uses
   interned data announces that it needs it. *)
let seq_incremental_state_cleared = 1
let seq_needs_incremental_state = 2

(* Interned form of the model above: event name / categories and debug
   annotation names / string values are replaced by per-table integer ids, and
   the entries first introduced on each packet are gathered for its
   [interned_data]. See [resolve]. *)
module Iarg = struct
  type value =
    | Bool of bool
    | Int of int
    | Float of float
    | String_iid of int
    | Json of string
    | Dict of t list
    | Array of t list

  and t =
    { name_iid : int option
    ; value : value
    }
end

type interned_data =
  { event_categories : (int * string) list
  ; event_names : (int * string) list
  ; annotation_names : (int * string) list
  ; annotation_strings : (int * string) list
  }

type ievent =
  { ietype : Event.Type.t
  ; name_iid : int option
  ; category_iids : int list
  ; iargs : Iarg.t list
  ; iflow_ids : int list
  ; itrack_uuid : int
  ; its : int
  }

type ipacket =
  | ITrack_descriptor of Track.t
  | ITrack_event of
      { ievent : ievent
      ; interned : interned_data
      ; sequence_flags : int
      }

let interned_nonempty i =
  let nonempty = function
    | [] -> false
    | _ :: _ -> true
  in
  nonempty i.event_categories
  || nonempty i.event_names
  || nonempty i.annotation_names
  || nonempty i.annotation_strings
;;

(* A single-namespace interning table: string -> non-zero iid, tracking which
   ids are new since the last [take] so they can ride the packet that
   introduces them. *)
module Intern_table = struct
  type t =
    { ids : (string, int) Hashtbl.t
    ; mutable next : int
    ; mutable pending : (int * string) list
    }

  let create () = { ids = Hashtbl.create 256; next = 1; pending = [] }

  let intern t s =
    match Hashtbl.find_opt t.ids s with
    | Some iid -> iid
    | None ->
      let iid = t.next in
      t.next <- iid + 1;
      Hashtbl.replace t.ids s iid;
      t.pending <- (iid, s) :: t.pending;
      iid
  ;;

  let take t =
    let entries = List.rev t.pending in
    t.pending <- [];
    entries
  ;;
end

(* Rewrite a packet stream into its interned form. A single left-to-right walk
   assigns iids on first sight and emits the new entries on the packet that
   first uses them, so interned data always precedes (or accompanies) its first
   reference in the sequence. Track descriptors carry no interned data. *)
let resolve packets =
  let event_names = Intern_table.create () in
  let event_categories = Intern_table.create () in
  let annotation_names = Intern_table.create () in
  let annotation_strings = Intern_table.create () in
  let first_event = ref true in
  let rec iarg ~named { Arg.arg_name; value } =
    let name_iid =
      if named && arg_name <> ""
      then Some (Intern_table.intern annotation_names arg_name)
      else None
    in
    let value : Iarg.value =
      match value with
      | Arg.Bool b -> Bool b
      | Arg.Int i -> Int i
      | Arg.Float f -> Float f
      | Arg.String s -> String_iid (Intern_table.intern annotation_strings s)
      | Arg.Json s -> Json s
      | Arg.Dict entries -> Dict (List.map entries ~f:(iarg ~named:true))
      | Arg.Array entries -> Array (List.map entries ~f:(iarg ~named:false))
    in
    { Iarg.name_iid; value }
  in
  List.map packets ~f:(function
    | Track_descriptor t -> ITrack_descriptor t
    | Track_event { Event.etype; ename; categories; eargs; flow_ids; track_uuid; ts } ->
      let name_iid = Option.map (Intern_table.intern event_names) ename in
      let category_iids = List.map categories ~f:(Intern_table.intern event_categories) in
      let iargs = List.map eargs ~f:(iarg ~named:true) in
      let interned =
        { event_categories = Intern_table.take event_categories
        ; event_names = Intern_table.take event_names
        ; annotation_names = Intern_table.take annotation_names
        ; annotation_strings = Intern_table.take annotation_strings
        }
      in
      let sequence_flags =
        if !first_event
        then (
          first_event := false;
          seq_incremental_state_cleared lor seq_needs_incremental_state)
        else seq_needs_incremental_state
      in
      ITrack_event
        { ievent =
            { ietype = etype
            ; name_iid
            ; category_iids
            ; iargs
            ; iflow_ids = flow_ids
            ; itrack_uuid = track_uuid
            ; its = ts
            }
        ; interned
        ; sequence_flags
        })
;;

module To_bytes = struct
  (* Protobuf wire encoding. Only the primitives we need: varints (wire type 0),
   length-delimited strings and nested messages (wire type 2), and fixed 64-bit
   values (wire type 1, used for [double] annotations and [flow_ids]). *)
  module Wire = struct
    (* Unsigned LEB128 over the full 64-bit value, so negative ints (encoded as
     two's-complement int64, 10 bytes) come out correct. *)
    let varint64 buf n =
      let n = ref n in
      let rec loop () =
        let byte = Int64.to_int (Int64.logand !n 0x7fL) in
        n := Int64.shift_right_logical !n 7;
        if Int64.equal !n 0L
        then Buffer.add_char buf (Char.chr byte)
        else (
          Buffer.add_char buf (Char.chr (byte lor 0x80));
          loop ())
      in
      loop ()
    ;;

    let varint buf n = varint64 buf (Int64.of_int n)
    let tag buf ~field ~wire = varint buf ((field lsl 3) lor wire)

    let varint_field buf ~field n =
      tag buf ~field ~wire:0;
      varint buf n
    ;;

    let bool_field buf ~field b = varint_field buf ~field (if b then 1 else 0)

    let string_field buf ~field s =
      tag buf ~field ~wire:2;
      varint buf (String.length s);
      Buffer.add_string buf s
    ;;

    let fixed64 buf n =
      for i = 0 to 7 do
        let byte =
          Int64.to_int (Int64.logand (Int64.shift_right_logical n (i * 8)) 0xffL)
        in
        Buffer.add_char buf (Char.chr byte)
      done
    ;;

    let fixed64_field buf ~field n =
      tag buf ~field ~wire:1;
      fixed64 buf n
    ;;

    let double_field buf ~field f = fixed64_field buf ~field (Int64.bits_of_float f)

    (* A nested message: serialise into a fresh buffer to learn its length, then
     write [tag | len | bytes]. *)
    let message_field buf ~field f =
      let sub = Buffer.create 64 in
      f sub;
      tag buf ~field ~wire:2;
      varint buf (Buffer.length sub);
      Buffer.add_buffer buf sub
    ;;
  end

  (* DebugAnnotation. In an array the entries carry no name; a string value is
     interned via [string_value_iid] (field 17). *)
  let rec arg buf { Iarg.name_iid; value } =
    (match name_iid with
     | Some iid -> Wire.varint_field buf ~field:1 iid
     | None -> ());
    match value with
    | Iarg.Bool b -> Wire.bool_field buf ~field:2 b
    | Int i -> Wire.varint_field buf ~field:4 i
    | Float f -> Wire.double_field buf ~field:5 f
    | String_iid iid -> Wire.varint_field buf ~field:17 iid
    | Json s -> Wire.string_field buf ~field:9 s
    | Dict entries ->
      List.iter entries ~f:(fun e -> Wire.message_field buf ~field:11 (fun b -> arg b e))
    | Array entries ->
      List.iter entries ~f:(fun e -> Wire.message_field buf ~field:12 (fun b -> arg b e))
  ;;

  let event buf (e : ievent) =
    Wire.varint_field buf ~field:9 (Event.Type.enum e.ietype);
    (match e.name_iid with
     | Some iid -> Wire.varint_field buf ~field:10 iid
     | None -> ());
    List.iter e.category_iids ~f:(fun iid -> Wire.varint_field buf ~field:3 iid);
    Wire.varint_field buf ~field:11 e.itrack_uuid;
    List.iter e.iargs ~f:(fun a -> Wire.message_field buf ~field:4 (fun b -> arg b a));
    List.iter e.iflow_ids ~f:(fun id ->
      Wire.fixed64_field buf ~field:47 (Int64.of_int id))
  ;;

  (* Each interned entry is a two-field message [iid=1, name/str=2]; the entry
     kinds differ only by their field number within [InternedData]. *)
  let interned_entry buf ~field (iid, s) =
    Wire.message_field buf ~field (fun b ->
      Wire.varint_field b ~field:1 iid;
      Wire.string_field b ~field:2 s)
  ;;

  let interned_data buf (i : interned_data) =
    List.iter i.event_categories ~f:(interned_entry buf ~field:1);
    List.iter i.event_names ~f:(interned_entry buf ~field:2);
    List.iter i.annotation_names ~f:(interned_entry buf ~field:3);
    List.iter i.annotation_strings ~f:(interned_entry buf ~field:29)
  ;;

  let track buf (t : Track.t) =
    Wire.varint_field buf ~field:1 t.uuid;
    if t.track_name <> "" then Wire.string_field buf ~field:2 t.track_name;
    match t.track_kind with
    | Process { pid } ->
      Wire.message_field buf ~field:3 (fun b ->
        Wire.varint_field b ~field:1 pid;
        if t.track_name <> "" then Wire.string_field b ~field:6 t.track_name)
    | Thread { parent_uuid; pid; tid } ->
      Wire.varint_field buf ~field:5 parent_uuid;
      Wire.message_field buf ~field:4 (fun b ->
        Wire.varint_field b ~field:1 pid;
        Wire.varint_field b ~field:2 tid;
        if t.track_name <> "" then Wire.string_field b ~field:5 t.track_name)
    | Child { parent_uuid } -> Wire.varint_field buf ~field:5 parent_uuid
  ;;

  let packet buf = function
    | ITrack_descriptor t ->
      Wire.message_field buf ~field:1 (fun p ->
        Wire.varint_field p ~field:10 trusted_packet_sequence_id;
        Wire.message_field p ~field:60 (fun b -> track b t))
    | ITrack_event { ievent = e; interned; sequence_flags } ->
      Wire.message_field buf ~field:1 (fun p ->
        Wire.varint_field p ~field:8 e.its;
        Wire.varint_field p ~field:10 trusted_packet_sequence_id;
        Wire.varint_field p ~field:13 sequence_flags;
        Wire.message_field p ~field:11 (fun b -> event b e);
        if interned_nonempty interned
        then Wire.message_field p ~field:12 (fun b -> interned_data b interned))
  ;;

  let to_bytes ipackets =
    let buf = Buffer.create 4096 in
    List.iter ipackets ~f:(packet buf);
    Buffer.contents buf
  ;;
end

module To_text = struct
  let line b indent fmt =
    Printf.ksprintf
      (fun s ->
         Buffer.add_string b (String.make (indent * 2) ' ');
         Buffer.add_string b s;
         Buffer.add_char b '\n')
      fmt
  ;;

  let rec arg b indent { Iarg.name_iid; value } =
    let line fmt = line b indent fmt in
    (match name_iid with
     | Some iid -> line "name_iid: %d" iid
     | None -> ());
    match value with
    | Iarg.Bool x -> line "bool_value: %b" x
    | Int x -> line "int_value: %d" x
    | Float x -> line "double_value: %g" x
    | String_iid iid -> line "string_value_iid: %d" iid
    | Json x -> line "legacy_json_value: %S" x
    | Dict entries ->
      List.iter entries ~f:(fun e ->
        line "dict_entries {";
        arg b (indent + 1) e;
        line "}")
    | Array entries ->
      List.iter entries ~f:(fun e ->
        line "array_values {";
        arg b (indent + 1) e;
        line "}")
  ;;

  let track b indent (t : Track.t) =
    let line i fmt = line b i fmt in
    line indent "track_descriptor {";
    let i = indent + 1 in
    line i "uuid: %d" t.uuid;
    if t.track_name <> "" then line i "name: %S" t.track_name;
    (match t.track_kind with
     | Process { pid } ->
       line i "process {";
       line (i + 1) "pid: %d" pid;
       if t.track_name <> "" then line (i + 1) "process_name: %S" t.track_name;
       line i "}"
     | Thread { parent_uuid; pid; tid } ->
       line i "parent_uuid: %d" parent_uuid;
       line i "thread {";
       line (i + 1) "pid: %d" pid;
       line (i + 1) "tid: %d" tid;
       if t.track_name <> "" then line (i + 1) "thread_name: %S" t.track_name;
       line i "}"
     | Child { parent_uuid } -> line i "parent_uuid: %d" parent_uuid);
    line indent "}"
  ;;

  let event b indent (e : ievent) =
    let line fmt = line b indent fmt in
    line "type: %s" (Event.Type.name e.ietype);
    (match e.name_iid with
     | Some iid -> line "name_iid: %d" iid
     | None -> ());
    List.iter e.category_iids ~f:(fun iid -> line "category_iids: %d" iid);
    line "track_uuid: %d" e.itrack_uuid;
    List.iter e.iargs ~f:(fun a ->
      line "debug_annotations {";
      arg b (indent + 1) a;
      line "}");
    List.iter e.iflow_ids ~f:(fun id -> line "flow_ids: %d" id)
  ;;

  let interned_data b indent (i : interned_data) =
    let group name field entries =
      List.iter entries ~f:(fun (iid, s) ->
        line b indent "%s {" name;
        line b (indent + 1) "iid: %d" iid;
        line b (indent + 1) "%s: %S" field s;
        line b indent "}")
    in
    group "event_categories" "name" i.event_categories;
    group "event_names" "name" i.event_names;
    group "debug_annotation_names" "name" i.annotation_names;
    group "debug_annotation_string_values" "str" i.annotation_strings
  ;;

  let to_text ipackets =
    let b = Buffer.create 4096 in
    List.iter ipackets ~f:(fun packet ->
      line b 0 "packet {";
      (match packet with
       | ITrack_descriptor t -> track b 1 t
       | ITrack_event { ievent = e; interned; sequence_flags } ->
         line b 1 "timestamp: %d" e.its;
         line b 1 "sequence_flags: %d" sequence_flags;
         line b 1 "track_event {";
         event b 2 e;
         line b 1 "}";
         if interned_nonempty interned
         then (
           line b 1 "interned_data {";
           interned_data b 2 interned;
           line b 1 "}"));
      line b 0 "}");
    Buffer.contents b
  ;;
end

let to_bytes packets = To_bytes.to_bytes (resolve packets)
let to_text packets = To_text.to_text (resolve packets)
