include Dune_trace.Event.Forced_by

(* The forcer of the current dynamic context: each scope sets it while running
   its body, and the span events of anything happening in that body -- graph
   spans and spawned processes alike -- record it. *)
let var = Fiber.Var.create (None : t option)
let set ~new_forcer f x = Fiber.Var.set var (Some new_forcer) (fun () -> Memo.run (f x))
let get = Fiber.Var.get var
