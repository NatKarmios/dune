open Import

module Event_sexp : sig
  (** Call [f] on every event in the file, then stop at end of file. *)
  val iter : string -> f:(Sexp.t -> unit) -> unit

  (** Like {!iter}, but waits for the file to grow, stopping only at the
      trace's exit event. *)
  val iter_follow : string -> f:(Sexp.t -> unit) -> unit

  (** Fail on an event that does not have the shape the reader expects. *)
  val invalid : Sexp.t -> 'a

  (** An event field's value as JSON. *)
  val to_json : Sexp.t -> Json.t

  (** The fields shared by every event: its category, its name, the timestamp
      sexp (pass to {!to_times}), the remaining fields, and the "digest" field
      if it has one. *)
  val to_base_args : Sexp.t -> string * string * Sexp.t * Sexp.t list * string option

  (** An event's timestamp, and its duration if it is a complete event. *)
  val to_times : Sexp.t -> Time.t * Time.Span.t option

  (** Take the async fields out of an event's fields: the "async_phase"
      ("begin"/"end"), the "async_id" pairing a begin with its end, and the
      fields that remain. *)
  val to_async_args : Sexp.t list -> string option * int option * Sexp.t list
end

(** Identifies one async span, pairing a begin event with its end. *)
val span_id : digest:string option -> async_id:int -> string
