open Stdune
open Dune_trace
module Graph = Event.Graph

type forced_by = Graph.forced_by =
  | Top_level
  | Rule of int
  | Dune_dyn of Path.Source.t
  | Gen_rules of
      { dir : Path.Build.t
      ; source_dir : Path.Source.t option
      }

(* The forcer of the current dynamic context. Each scope sets it while running
   its body; [Exec_rule] reads it and records it on the rule's events so the
   trace shows what forced each rule. *)
let forced_by = Fiber.Var.create Top_level

module Exec_rule = struct
  type outcome = Graph.Exec_rule.outcome =
    | Executed
    | Local_cache_hit
    | Shared_cache_hit

  let conv_targets { Import.Targets.Validated.root; files; dirs } =
    { Dune_trace.Event.root; files; dirs }
  ;;

  module Emit = struct
    let start ~(rule : Rule.t) ~async_id ~rule_id ~forced_by ~start =
      Dune_trace.emit_all ~buffered:true Category.Graph
      @@ fun () ->
      Graph.Exec_rule.start
        ~async_id
        ~rule_id
        ~targets:(conv_targets rule.targets)
        ~forced_by
        ~start
    ;;

    let deps ~async_id ~rule_id ?(dyn = false) (deps : Dep.Set.t) =
      Dune_trace.emit_all ~buffered:true Category.Graph
      @@ fun () ->
      let deps = Dep.Set.to_list_map ~f:Dep.to_dyn deps in
      Graph.Exec_rule.deps ~async_id ~rule_id ~dyn ~deps
    ;;

    let finish ~async_id ~rule_id outcome =
      Dune_trace.emit ~buffered:true Category.Graph (fun () ->
        Graph.Exec_rule.finish ~async_id ~rule_id ~outcome)
    ;;
  end

  module Other_events = struct
    type t =
      { deps : ?dyn:bool -> Dep.Set.t -> unit
      ; finish : outcome -> unit
      }

    let empty = { deps = (fun ?dyn _ -> ignore dyn); finish = ignore }

    let make ~async_id ~rule_id =
      { deps = Emit.deps ~async_id ~rule_id; finish = Emit.finish ~async_id ~rule_id }
    ;;
  end

  let start ~(rule : Rule.t) (f : Other_events.t -> 'a Memo.t) : 'a Memo.t =
    if enabled Category.Graph
    then (
      let start = Time.now () in
      let async_id = Event.gen_async_id () in
      let rule_id = Rule.Id.to_int rule.id in
      let open Fiber.O in
      (let* forcer = Fiber.Var.get forced_by in
       Emit.start ~rule ~async_id ~rule_id ~forced_by:forcer ~start;
       let other_events = Other_events.make ~async_id ~rule_id in
       Fiber.Var.set forced_by (Rule rule_id) (fun () -> Memo.run (f other_events)))
      |> Memo.of_reproducible_fiber)
    else f Other_events.empty
  ;;
end

module Dune_dyn = struct
  (* Wraps the reading and processing of the dune file at [path]. Emits a
     [dune-dyn-start] / [dune-dyn-finish] pair around [f] and sets [forced_by] to
     [Dune_dyn path] so that work done while processing the file is attributed to
     the load. *)
  let start ~(path : Path.Source.t) (f : unit -> 'a Memo.t) : 'a Memo.t =
    if enabled Category.Graph
    then (
      let async_id = Event.gen_async_id () in
      let start = Time.now () in
      Dune_trace.emit ~buffered:true Category.Graph (fun () ->
        Graph.Dune_dyn.start ~async_id ~start);
      let open Fiber.O in
      (let+ result =
         Fiber.Var.set forced_by (Dune_dyn path) (fun () -> Memo.run (f ()))
       in
       Dune_trace.emit ~buffered:true Category.Graph (fun () ->
         Graph.Dune_dyn.finish ~async_id);
       result)
      |> Memo.of_reproducible_fiber)
    else f ()
  ;;
end

module Gen_rules = struct
  (* Wraps the generation of rules for [dir]. Emits a [gen-rules-dir-start] /
     [gen-rules-dir-finish] pair around [f] and sets [forced_by] to
     [Gen_rules { dir }] so that builds forced while generating the directory's
     rules are attributed to it. *)
  let dir ~(dir : Path.Build.t) (f : unit -> 'a Memo.t) : 'a Memo.t =
    if enabled Category.Graph
    then (
      let async_id = Event.gen_async_id () in
      let start = Time.now () in
      Dune_trace.emit ~buffered:true Category.Graph (fun () ->
        Graph.Gen_rules.dir_start ~async_id ~dir ~start);
      let open Fiber.O in
      (let+ result =
         Fiber.Var.set
           forced_by
           (Gen_rules { dir; source_dir = None })
           (fun () -> Memo.run (f ()))
       in
       Dune_trace.emit ~buffered:true Category.Graph (fun () ->
         Graph.Gen_rules.dir_finish ~async_id);
       result)
      |> Memo.of_reproducible_fiber)
    else f ()
  ;;

  (* Like [dir] but also attributes the [source_dir] (the standalone/root
     case). *)
  let dune_file
        ~(dir : Path.Build.t)
        ~(source_dir : Path.Source.t)
        (f : unit -> 'a Memo.t)
    : 'a Memo.t
    =
    if enabled Category.Graph
    then (
      let async_id = Event.gen_async_id () in
      let start = Time.now () in
      Dune_trace.emit ~buffered:true Category.Graph (fun () ->
        Graph.Gen_rules.dune_file_start ~async_id ~dir ~source_dir ~start);
      let open Fiber.O in
      (let+ result =
         Fiber.Var.set
           forced_by
           (Gen_rules { dir; source_dir = Some source_dir })
           (fun () -> Memo.run (f ()))
       in
       Dune_trace.emit ~buffered:true Category.Graph (fun () ->
         Graph.Gen_rules.dune_file_finish ~async_id);
       result)
      |> Memo.of_reproducible_fiber)
    else f ()
  ;;
end
