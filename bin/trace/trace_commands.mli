(** [dune trace commands] prints the processes a trace file recorded as the
    shell commands that ran them, each followed by its output. *)
val cmd : unit Cmdliner.Cmd.t
