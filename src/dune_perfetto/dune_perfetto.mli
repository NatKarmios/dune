(** Minimal encoder for Perfetto's native protobuf trace format
    (https://perfetto.dev).

    A trace is a list of {!packet}s: {!Track_descriptor}s declare tracks (a
    process, a thread, or a generic child track) and {!Track_event}s place
    slices and instants on them. Serialise with {!to_bytes} to load into
    [ui.perfetto.dev], or {!to_text} for a human-readable dump.

    Only the subset of the Perfetto schema needed to represent slices, instants,
    tracks, flows, and debug annotations is implemented; the protobuf wire format
    is hand-rolled (varints and length-delimited messages), so this library has
    no dependencies. *)

(** A key/value annotation attached to an event (Perfetto's
    [DebugAnnotation]). *)
module Arg : sig
  type t

  val bool : name:string -> bool -> t
  val int : name:string -> int -> t
  val float : name:string -> float -> t
  val string : name:string -> string -> t

  (** A raw JSON blob (Perfetto's [legacy_json_value]), for values with no
      natural typed representation. *)
  val json : name:string -> string -> t

  val dict : name:string -> t list -> t
  val array : name:string -> t list -> t
end

(** A hand-assembled protobuf message, used for the parts of the Perfetto schema
    that have no dedicated smart constructor: [TrackEvent] extension fields and
    the [FileDescriptorSet] that teaches Perfetto how to decode them. A value is
    one field ([number] paired with a typed value); a message is a [t list].
    Repeated fields are expressed by repeating the same [field] number. *)
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

  val process : uuid:int -> pid:int -> name:string -> t
  val thread : uuid:int -> parent_uuid:int -> pid:int -> tid:int -> name:string -> t

  (** A generic track nested under [parent_uuid], with no thread/process
      association. Used for async slices. *)
  val child : uuid:int -> parent_uuid:int -> name:string -> t
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

  (** [extension] is a message spliced onto the [TrackEvent] at its own field
      number (see {!Proto.message}); Perfetto decodes it via a matching
      {!Extension_descriptor} packet. *)
  val create
    :  ?name:string
    -> ?categories:string list
    -> ?args:Arg.t list
    -> ?flow_ids:int list
    -> ?extension:Proto.t
    -> Type.t
    -> track_uuid:int
    -> ts:int (** nanoseconds *)
    -> t
end

type packet =
  | Track_descriptor of Track.t
  | Track_event of Event.t
  | Extension_descriptor of Proto.t list
  (** The fields of a [FileDescriptorSet] describing the schema of the
          {!Event} [extension]s, so Perfetto can decode them. Emit once, before
          the events that use it. *)

(** Serialise to the binary protobuf format read by [ui.perfetto.dev]. *)
val to_bytes : packet list -> string

(** Serialise to a human-readable, protobuf-text-format-style dump. *)
val to_text : packet list -> string
