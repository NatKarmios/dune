open Stdune

type t

val fd : t -> Fd.t
val cats : t -> Category.Set.t
val alloc : t -> Alloc.t option
val emit : ?buffered:bool -> t -> Event.t -> unit
val flush : t -> unit
val close : t -> unit
val create : [ `Path of Stdune.Path.t | `Fd of Fd.t ] -> t
val emit_runtime : t -> unit
val start : t option -> (unit -> Event.Complete.data) -> Event.Complete.t option
val finish : t -> Event.Complete.t option -> unit
