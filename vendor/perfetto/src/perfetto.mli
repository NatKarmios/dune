(** Minimal encoder for Perfetto's native protobuf trace format
    (https://perfetto.dev).

    A trace is a list of {!packet}s: {!Track_descriptor}s declare tracks (a
    process, a thread, or a generic child track) and {!Track_event}s place
    slices and instants on them. Serialise with {!to_bytes} to load into
    [ui.perfetto.dev], or {!to_text} for a human-readable dump.

    Only the subset of the Perfetto schema needed to represent slices, instants,
    tracks, flows, and debug annotations is implemented; the protobuf wire format
    is hand-rolled (varints and length-delimited messages), so this library has
    no dependencies.

    Repeated strings are interned automatically: {!to_bytes} / {!to_text} rewrite
    event names, categories, and debug-annotation names and string values into
    per-sequence integer ids, emitting the [InternedData] and [sequence_flags]
    Perfetto needs to resolve them. Callers pass plain strings and need not know
    about interning. *)

(** A key/value annotation attached to an event (Perfetto's
    [DebugAnnotation]). *)
module Debug_annot : sig
  type t

  val bool : name:string -> bool -> t
  val int : name:string -> int -> t
  val float : name:string -> float -> t
  val string : name:string -> string -> t

  (** A raw JSON blob (Perfetto's [legacy_json_value]), for values with no
      natural typed representation. Not interned. *)
  val json : name:string -> string -> t

  val dict : name:string -> t list -> t
  val array : name:string -> t list -> t
end

(** A hand-assembled protobuf field, for the parts of the Perfetto schema with
    no dedicated constructor: [TrackEvent] extension fields and the
    [FileDescriptorSet] that tells Perfetto how to decode them. A message is a
    [t list]; express a repeated field by repeating its [field] number. *)
module Proto : sig
  type t

  val varint : field:int -> int -> t
  val bool : field:int -> bool -> t
  val string : field:int -> string -> t
  val message : field:int -> t list -> t
end

(** A track: a horizontal lane in the Perfetto UI that events are placed on.
    [uuid] is any trace-unique identifier; events reference it by
    [track_uuid]. *)
module Track : sig
  type t

  (** How the UI orders a track's children ([TrackDescriptor.child_ordering]).
      [Explicit] sorts children by their [sibling_order_rank], lowest first;
      children without a rank count as 0. *)
  module Child_ordering : sig
    type t =
      | Lexicographic
      | Chronological
      | Explicit
  end

  val process
    :  uuid:int
    -> pid:int
    -> name:string
    -> ?child_ordering:Child_ordering.t
    -> unit
    -> t

  val thread
    :  uuid:int
    -> parent_uuid:int
    -> pid:int
    -> tid:int
    -> name:string
    -> ?sibling_order_rank:int
    -> unit
    -> t

  (** A generic track nested under [parent_uuid], with no thread/process
      association. Used for async slices. *)
  val child
    :  uuid:int
    -> parent_uuid:int
    -> name:string
    -> ?child_ordering:Child_ordering.t
    -> ?sibling_order_rank:int
    -> unit
    -> t
end

(** A slice boundary or instant placed on a track. A [Begin]/[End] pair on the
    same track (matched by stack order) forms a slice; [Instant] is a
    zero-width marker. *)
module Event : sig
  module Type : sig
    type t =
      | Begin
      | End
      | Instant
  end

  type t

  (** [extensions] are fields appended to the [TrackEvent] message at their own
      field numbers. Perfetto decodes them via a matching
      {!Extension_descriptor} packet. *)
  val create
    :  ?name:string
    -> ?categories:string list
    -> ?debug_annots:Debug_annot.t list
    -> ?flow_ids:int list
    -> ?extensions:Proto.t list
    -> Type.t
    -> track_uuid:int
    -> ts:int (** nanoseconds *)
    -> t
end

type packet =
  | Track_descriptor of Track.t
  | Track_event of Event.t
  | Extension_descriptor of Proto.t list
  (** The fields of a [FileDescriptorSet] describing the {!Event} [extensions],
      so Perfetto can decode them. Emit once, before the events that use it. *)

(** Serialise to the binary protobuf format read by [ui.perfetto.dev]. *)
val to_bytes : packet list -> string

(** Serialise to a human-readable, protobuf-text-format-style dump. *)
val to_text : packet list -> string
