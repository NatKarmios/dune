module List = ListLabels
module String = StringLabels

(* Internal representation. The smart constructors below build these records;
   [to_bytes] and [to_text] both consume them. *)

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

  (* DebugAnnotation. In an array the entries carry no name. *)
  let rec arg ~named buf { Arg.arg_name; value } =
    if named && arg_name <> "" then Wire.string_field buf ~field:10 arg_name;
    match value with
    | Bool b -> Wire.bool_field buf ~field:2 b
    | Int i -> Wire.varint_field buf ~field:4 i
    | Float f -> Wire.double_field buf ~field:5 f
    | String s -> Wire.string_field buf ~field:6 s
    | Json s -> Wire.string_field buf ~field:9 s
    | Dict entries ->
      List.iter entries ~f:(fun e ->
        Wire.message_field buf ~field:11 (fun b -> arg ~named:true b e))
    | Array entries ->
      List.iter entries ~f:(fun e ->
        Wire.message_field buf ~field:12 (fun b -> arg ~named:false b e))
  ;;

  let event buf (e : Event.t) =
    Wire.varint_field buf ~field:9 (Event.Type.enum e.etype);
    (match e.ename with
     | Some name -> Wire.string_field buf ~field:23 name
     | None -> ());
    List.iter e.categories ~f:(fun c -> Wire.string_field buf ~field:22 c);
    Wire.varint_field buf ~field:11 e.track_uuid;
    List.iter e.eargs ~f:(fun a ->
      Wire.message_field buf ~field:4 (fun b -> arg ~named:true b a));
    List.iter e.flow_ids ~f:(fun id -> Wire.fixed64_field buf ~field:47 (Int64.of_int id))
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
    | Track_descriptor t ->
      Wire.message_field buf ~field:1 (fun p ->
        Wire.varint_field p ~field:10 trusted_packet_sequence_id;
        Wire.message_field p ~field:60 (fun b -> track b t))
    | Track_event e ->
      Wire.message_field buf ~field:1 (fun p ->
        Wire.varint_field p ~field:8 e.ts;
        Wire.varint_field p ~field:10 trusted_packet_sequence_id;
        Wire.message_field p ~field:11 (fun b -> event b e))
  ;;

  let to_bytes packets =
    let buf = Buffer.create 4096 in
    List.iter packets ~f:(packet buf);
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

  let rec arg b indent { Arg.arg_name; value } =
    let line fmt = line b indent fmt in
    if arg_name <> "" then line "name: %S" arg_name;
    match value with
    | Bool x -> line "bool_value: %b" x
    | Int x -> line "int_value: %d" x
    | Float x -> line "double_value: %g" x
    | String x -> line "string_value: %S" x
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

  let event b indent (e : Event.t) =
    let line i fmt = line b i fmt in
    line indent "timestamp: %d" e.ts;
    line indent "track_event {";
    let i = indent + 1 in
    line i "type: %s" (Event.Type.name e.etype);
    (match e.ename with
     | Some name -> line i "name: %S" name
     | None -> ());
    List.iter e.categories ~f:(fun c -> line i "categories: %S" c);
    line i "track_uuid: %d" e.track_uuid;
    List.iter e.eargs ~f:(fun a ->
      line i "debug_annotations {";
      arg b (i + 1) a;
      line i "}");
    List.iter e.flow_ids ~f:(fun id -> line i "flow_ids: %d" id);
    line indent "}"
  ;;

  let to_text packets =
    let b = Buffer.create 4096 in
    List.iter packets ~f:(fun packet ->
      line b 0 "packet {";
      (match packet with
       | Track_descriptor t -> track b 1 t
       | Track_event e -> event b 1 e);
      line b 0 "}");
    Buffer.contents b
  ;;
end

let to_bytes = To_bytes.to_bytes
let to_text = To_text.to_text
