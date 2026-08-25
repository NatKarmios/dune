(** [dune trace cat] prints the events of a trace file, one per line, as JSON,
    as pretty-printed sexps ([--sexp]), or in the Chrome trace event format
    ([--chrome-trace]). With [--follow] it keeps reading until the trace's exit
    event. *)
val cmd : unit Cmdliner.Cmd.t
