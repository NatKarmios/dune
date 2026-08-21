(** Reading and rendering the csexp events of a dune trace file. *)

open Import

(** Call [f] on every event in the file, then stop at end of file. *)
val iter_sexps : string -> f:(Sexp.t -> unit) -> unit

(** Like {!iter_sexps}, but waits for the file to grow, stopping only at the
    trace's exit event. *)
val iter_sexps_follow : string -> f:(Sexp.t -> unit) -> unit

(** An event field's value as JSON. *)
val json_of_sexp : Sexp.t -> Json.t

(** The fields shared by every event: its category, its name, the timestamp
    sexp (pass to {!times_of_sexp}), the remaining fields, and the "digest"
    field if it has one. *)
val base_of_sexp : Sexp.t -> string * string * Sexp.t * Sexp.t list * string option

(** An event's timestamp, and its duration if it is a complete event. *)
val times_of_sexp : Sexp.t -> Time.t * Time.Span.t option

(** Take the "async_phase" field ("begin"/"end"/"instant") out of an event's
    fields, returning it alongside the fields that remain. *)
val async_phase_of_sexp : Sexp.t list -> string option * Sexp.t list

(** Take the "async_id" field, which pairs an async begin with its end, out of
    an event's fields. *)
val async_id_of_sexp : Sexp.t list -> int option * Sexp.t list

(** Render an event as JSON: dune's own one-object-per-event format, or with
    [~chrome:true] the Chrome trace event format. *)
val json_of_event : chrome:bool -> Sexp.t -> Json.t

(** A finished process, as recorded by the "process"/"finish" event. *)
type process_info =
  { prog : string
  ; args : string list
  ; dir : string option
  ; exit_code : int
  ; error : string option
  ; stderr : string
  }

val parse_process_event : Sexp.t -> process_info option

(** Render a finished process as the shell command that ran it, followed by its
    output and, unless it succeeded, its exit code. *)
val format_output : process_info -> string
