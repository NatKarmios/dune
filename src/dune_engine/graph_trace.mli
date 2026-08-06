(** Utilities for tracing the build graph *)

open Import

module Exec_rule : sig
  type outcome = Dune_trace.Event.Graph.Exec_rule.outcome =
    | Executed
    | Local_cache_hit
    | Shared_cache_hit

  module Other_events : sig
    type t =
      { deps_start : unit -> unit
      ; deps_finish : Dep.Set.t -> unit
      ; action_start : unit -> unit
      ; action_finish : Dep.Set.t list -> unit
      ; finish : outcome -> unit
      }
  end

  val start : rule:Rule.t -> (Other_events.t -> 'a Memo.t) -> 'a Memo.t
end

module Dune_dyn : sig
  (** Trace the reading and processing of the dune file at [path], recording it
      as the [forced_by] context for any work done while [f] runs. *)
  val start : path:Path.Source.t -> (unit -> 'a Memo.t) -> 'a Memo.t
end

module Gen_rules : sig
  (** Trace rule generation for [dir], recording it as the [forced_by] context
      for any build forced while [f] runs (e.g. by pform expansion). *)
  val dir : dir:Path.Build.t -> (unit -> 'a Memo.t) -> 'a Memo.t

  (** Like {!dir} but also attributes the [source_dir] (the standalone/root
      case). *)
  val dune_file
    :  dir:Path.Build.t
    -> source_dir:Path.Source.t
    -> (unit -> 'a Memo.t)
    -> 'a Memo.t
end
