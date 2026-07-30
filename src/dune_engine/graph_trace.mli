(** Utilities for tracing the build graph *)

module Exec_rule : sig
  type outcome = Dune_trace.Event.Graph.Exec_rule.outcome =
    | Executed
    | Local_cache_hit
    | Shared_cache_hit

  module Other_events : sig
    type t =
      { deps : Dep.Facts.t -> unit
      ; finish : outcome -> unit
      }
  end

  val start : rule:Rule.t -> (Other_events.t -> 'a Memo.t) -> 'a Memo.t
end
