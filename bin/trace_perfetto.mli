(** Perfetto native-protobuf export. Consumes the same csexp event stream as
    [Trace_event.json_of_event], mapping each graph async span to a pair of
    lifecycle instants (or, for a cache hit / source dep, a single collapsed
    instant) on a fixed track shared by its kind, and flat complete/instant
    events to slices/instants on a main thread track. It also accumulates the
    build-graph blob for exec-rule/build-dep spans, flushed once at the end in
    {!to_packets}; the intern table is dumped there rather than resolved into
    the instants, whose args are ids the blob explains (see
    doc/dev/trace-graph-perfetto.md, phase 7). *)

open Import

type t

val create : unit -> t

(** Feed one trace event to the converter. *)
val add : t -> Sexp.t -> unit

(** The converted trace. Call once, after the whole stream has been {!add}ed:
    the graph blob and any span left open by a crash can only be emitted at
    that point. *)
val to_packets : t -> Dune_perfetto.packet list
