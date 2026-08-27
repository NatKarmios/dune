(** The forcer of the current dynamic context, tracked in a fiber variable so
    that spans can record what forced the build they belong to.

    Only the scopes in {!Graph_trace} set it, and only when the "graph" trace
    category is enabled; {!get} is [None] otherwise. *)

include module type of struct
  include Dune_trace.Event.Forced_by
end

(** [set ~new_forcer f x] runs [f x] with [new_forcer] as the forcer. *)
val set : new_forcer:t -> ('a -> 'b Memo.t) -> 'a -> 'b Fiber.t

(** The forcer in scope, or [None] outside any of {!Graph_trace}'s scopes. *)
val get : t option Fiber.t
