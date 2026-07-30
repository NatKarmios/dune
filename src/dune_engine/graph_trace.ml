open Stdune
open Dune_trace
module Graph = Event.Graph

let in_rule_exec = Fiber.Var.create (None : int option)

module Exec_rule = struct
  type outcome = Graph.Exec_rule.outcome =
    | Executed
    | Local_cache_hit
    | Shared_cache_hit

  let conv_targets { Import.Targets.Validated.root; files; dirs } =
    { Dune_trace.Event.root; files; dirs }
  ;;

  module Emit = struct
    let start ~(rule : Rule.t) ~start =
      Dune_trace.emit_all ~buffered:true Category.Graph
      @@ fun () ->
      Graph.Exec_rule.start
        ~id:(Rule.Id.to_int rule.id)
        ~targets:(conv_targets rule.targets)
        ~start
    ;;

    let deps ~(rule : Rule.t) (facts : Dep.Facts.t) =
      Dune_trace.emit_all ~buffered:true Category.Graph
      @@ fun () ->
      let deps = facts |> Dep.Map.keys |> List.map ~f:Dep.to_dyn in
      Graph.Exec_rule.deps ~id:(Rule.Id.to_int rule.id) ~deps
    ;;

    let finish ~(rule : Rule.t) ~start outcome =
      Dune_trace.emit_all ~buffered:true Category.Graph
      @@ fun () ->
      Graph.Exec_rule.finish
        ~id:(Rule.Id.to_int rule.id)
        ~targets:(conv_targets rule.targets)
        ~outcome
        ~start
    ;;
  end

  module Other_events = struct
    type t =
      { deps : Dep.Facts.t -> unit
      ; finish : outcome -> unit
      }

    let empty = { deps = ignore; finish = ignore }

    let make ~(rule : Rule.t) ~start =
      { deps = Emit.deps ~rule; finish = Emit.finish ~rule ~start }
    ;;
  end

  let start ~(rule : Rule.t) (f : Other_events.t -> 'a Memo.t) : 'a Memo.t =
    if enabled Category.Graph
    then (
      let start = Time.now () in
      Emit.start ~rule ~start;
      let other_events = Other_events.make ~rule ~start in
      let new_val = Some (Rule.Id.to_int rule.id) in
      (fun () -> Memo.run (f other_events))
      |> Fiber.Var.set in_rule_exec new_val
      |> Memo.of_reproducible_fiber)
    else f Other_events.empty
  ;;
end
