open Stdune
open Dune_trace
module Graph = Event.Graph

module Lane = struct
  (* A single global free-list allocator for Chrome-trace lanes (tids). Each
     Graph scope holds a lane for its [start, finish] interval and releases it at
     finish, so overlapping scopes get distinct lanes. Lanes are numbered from 1;
     tid 0 stays reserved for all non-Graph events (which carry no [tid]). Safe
     under dune's cooperative single-threaded fibers (alloc/release never yield). *)
  let free = ref []
  let next = ref 1

  let alloc () =
    match !free with
    | l :: rest ->
      free := rest;
      l
    | [] ->
      let l = !next in
      incr next;
      l
  ;;

  let release l = free := l :: !free
end

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
    let start ~(rule : Rule.t) ~forced_by ~start ~tid =
      Dune_trace.emit_all ~buffered:true Category.Graph
      @@ fun () ->
      Graph.Exec_rule.start
        ~id:(Rule.Id.to_int rule.id)
        ~targets:(conv_targets rule.targets)
        ~forced_by
        ~start
        ~tid
    ;;

    let deps ~(rule : Rule.t) ~tid ?(dyn = false) (deps : Dep.Set.t) =
      Dune_trace.emit_all ~buffered:true Category.Graph
      @@ fun () ->
      let deps = Dep.Set.to_list_map ~f:Dep.to_dyn deps in
      Graph.Exec_rule.deps ~id:(Rule.Id.to_int rule.id) ~tid ~dyn ~deps
    ;;

    (* Emits the finish event (which captures its stop time), then releases the
       lane held since [start] so a later scope can reuse it. *)
    let finish ~(rule : Rule.t) ~forced_by ~start ~tid outcome =
      Dune_trace.emit_all ~buffered:true Category.Graph (fun () ->
        Graph.Exec_rule.finish
          ~id:(Rule.Id.to_int rule.id)
          ~targets:(conv_targets rule.targets)
          ~outcome
          ~forced_by
          ~start
          ~tid);
      Lane.release tid
    ;;
  end

  module Other_events = struct
    type t =
      { deps : ?dyn:bool -> Dep.Set.t -> unit
      ; finish : outcome -> unit
      }

    let empty = { deps = (fun ?dyn _ -> ignore dyn); finish = ignore }

    let make ~(rule : Rule.t) ~forced_by ~start ~tid =
      { deps = Emit.deps ~rule ~tid; finish = Emit.finish ~rule ~forced_by ~start ~tid }
    ;;
  end

  let start ~(rule : Rule.t) (f : Other_events.t -> 'a Memo.t) : 'a Memo.t =
    if enabled Category.Graph
    then (
      let start = Time.now () in
      let tid = Lane.alloc () in
      let open Fiber.O in
      (let* forcer = Fiber.Var.get forced_by in
       Emit.start ~rule ~forced_by:forcer ~start ~tid;
       let other_events = Other_events.make ~rule ~forced_by:forcer ~start ~tid in
       let new_forcer = Rule (Rule.Id.to_int rule.id) in
       Fiber.Var.set forced_by new_forcer (fun () -> Memo.run (f other_events)))
      |> Memo.of_reproducible_fiber)
    else f Other_events.empty
  ;;
end

module Dune_dyn = struct
  (* Ids paired between the [dune-dyn-start] and [dune-dyn-finish] events. *)
  let next_id = ref 0

  (* Wraps the reading and processing of the dune file at [path]. Emits a
     [dune-dyn-start] / [dune-dyn-finish] pair around [f] and sets [forced_by] to
     [Dune_dyn path] so that work done while processing the file is attributed to
     the load. *)
  let start ~(path : Path.Source.t) (f : unit -> 'a Memo.t) : 'a Memo.t =
    if enabled Category.Graph
    then (
      let id = !next_id in
      incr next_id;
      let start = Time.now () in
      let tid = Lane.alloc () in
      Dune_trace.emit ~buffered:true Category.Graph (fun () ->
        Graph.Dune_dyn.start ~id ~start ~tid);
      let open Fiber.O in
      (let+ result =
         Fiber.Var.set forced_by (Dune_dyn path) (fun () -> Memo.run (f ()))
       in
       Dune_trace.emit ~buffered:true Category.Graph (fun () ->
         Graph.Dune_dyn.finish ~id ~start ~tid);
       Lane.release tid;
       result)
      |> Memo.of_reproducible_fiber)
    else f ()
  ;;
end

module Gen_rules = struct
  (* Ids paired between the [gen-rules-*-start] and [gen-rules-*-finish] events. *)
  let next_id = ref 0

  (* Wraps the generation of rules for [dir]. Emits a [gen-rules-dir-start] /
     [gen-rules-dir-finish] pair around [f] and sets [forced_by] to
     [Gen_rules { dir }] so that builds forced while generating the directory's
     rules are attributed to it. *)
  let dir ~(dir : Path.Build.t) (f : unit -> 'a Memo.t) : 'a Memo.t =
    if enabled Category.Graph
    then (
      let id = !next_id in
      incr next_id;
      let start = Time.now () in
      let tid = Lane.alloc () in
      Dune_trace.emit ~buffered:true Category.Graph (fun () ->
        Graph.Gen_rules.dir_start ~id ~dir ~start ~tid);
      let open Fiber.O in
      (let+ result =
         Fiber.Var.set
           forced_by
           (Gen_rules { dir; source_dir = None })
           (fun () -> Memo.run (f ()))
       in
       Dune_trace.emit ~buffered:true Category.Graph (fun () ->
         Graph.Gen_rules.dir_finish ~id ~start ~tid);
       Lane.release tid;
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
      let id = !next_id in
      incr next_id;
      let start = Time.now () in
      let tid = Lane.alloc () in
      Dune_trace.emit ~buffered:true Category.Graph (fun () ->
        Graph.Gen_rules.dune_file_start ~id ~dir ~source_dir ~start ~tid);
      let open Fiber.O in
      (let+ result =
         Fiber.Var.set
           forced_by
           (Gen_rules { dir; source_dir = Some source_dir })
           (fun () -> Memo.run (f ()))
       in
       Dune_trace.emit ~buffered:true Category.Graph (fun () ->
         Graph.Gen_rules.dune_file_finish ~id ~start ~tid);
       Lane.release tid;
       result)
      |> Memo.of_reproducible_fiber)
    else f ()
  ;;
end
