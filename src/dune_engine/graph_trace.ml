open Stdune
open Dune_trace
module Graph = Event.Graph

module Forced_by = struct
  type t' =
    | Forced_by_rule of Rule.Id.t
    | Forced_by_dep of Dep.t
    | Forced_by_dynamic_includes of Path.Source.t
    | Forced_by_rule_gen of
        { dir : Path.Build.t
        ; source_dir : Path.Source.t option
        }

  type t = t'

  let conv : t -> Graph.forced_by = function
    | Forced_by_rule id -> Forced_by_rule (Rule.Id.to_int id)
    | Forced_by_dep dep -> Forced_by_dep (Dep.to_dyn dep)
    | Forced_by_dynamic_includes path -> Forced_by_dynamic_includes path
    | Forced_by_rule_gen { dir; source_dir } -> Forced_by_rule_gen { dir; source_dir }
  ;;

  (* The forcer of the current dynamic context. Each scope sets it while running
   its body; [Exec_rule] reads it and records the forcer on the rule's events so
   the trace shows what forced each rule. *)
  let var = Fiber.Var.create (None : t option)
  let set ~new_forcer f x = Fiber.Var.set var (Some new_forcer) (fun () -> Memo.run (f x))
  let get = Fiber.Var.get var
  let rule ~rule:{ Rule.id; _ } = Forced_by_rule id
  let dep ~dep = Forced_by_dep dep
  let dynamic_includes ~path = Forced_by_dynamic_includes path
  let rule_gen ~dir ?source_dir () = Forced_by_rule_gen { dir; source_dir }
end

module Build_dep = struct
  module Emit = struct
    let start ~async_id ~forced_by ~dep =
      Dune_trace.emit_all ~buffered:true Category.Graph
      @@ fun () ->
      Graph.Build_dep.start
        ~async_id
        ~forced_by:(Option.map forced_by ~f:Forced_by.conv)
        ~dep:(Dep.to_dyn dep)
    ;;

    let finish ~async_id outcome =
      Dune_trace.emit_all ~buffered:true Category.Graph
      @@ fun () -> Graph.Build_dep.finish ~async_id ~outcome
    ;;
  end

  (* Trace building a single [dep] as an async span: emit the begin (recording
     the current [forced_by]), run [f] with [forced_by] set to [Forced_by_dep
     dep] and a [finish] callback that emits the end with the outcome
     [outcome_of] derives from [f]'s argument. *)
  let start ~(dep : Dep.t) ~outcome_of (f : ('b -> unit) -> 'a Memo.t) : 'a Memo.t =
    if enabled Category.Graph
    then (
      let async_id = Event.gen_async_id () in
      let new_forcer = Forced_by.dep ~dep in
      let open Fiber.O in
      (let* forced_by = Forced_by.get in
       Emit.start ~async_id ~forced_by ~dep;
       let finish x = Emit.finish ~async_id (outcome_of x) in
       Forced_by.set ~new_forcer f finish)
      |> Memo.of_reproducible_fiber)
    else f ignore
  ;;

  (* A file dep resolves to the rule that produces it, or to a source file when
     there is no such rule. *)
  let file (path : Path.t) f =
    start
      ~dep:(Dep.file path)
      ~outcome_of:(function
        | None -> Graph.Build_dep.Dep_is_source
        | Some (rule : Rule.t) -> Graph.Build_dep.Dep_rule (Rule.Id.to_int rule.id))
      f
  ;;

  (* An alias expands to its deps *)
  let alias (alias : Alias.t) f =
    start
      ~dep:(Dep.alias alias)
      ~outcome_of:(fun (facts : Dep.Facts.t list) ->
        Graph.Build_dep.Dep_expanded
          (facts
           |> List.map ~f:Dep.Set.of_keys
           |> Dep.Set.union_all
           |> Dep.Set.to_list_map ~f:Dep.to_dyn))
      f
  ;;

  (* A file selector (glob) expands to the files it matched. *)
  let file_selector (file_selector : File_selector.t) f =
    start
      ~dep:(Dep.file_selector file_selector)
      ~outcome_of:(fun (files : Filename_set.t) ->
        Graph.Build_dep.Dep_expanded
          (Filename_set.to_list files |> List.map ~f:(fun p -> Dep.to_dyn (Dep.file p))))
      f
  ;;
end

module Exec_rule = struct
  type outcome = Graph.Exec_rule.outcome =
    | Executed
    | Local_cache_hit
    | Shared_cache_hit

  let conv_targets { Import.Targets.Validated.root; files; dirs } =
    { Dune_trace.Event.root; files; dirs }
  ;;

  module Emit = struct
    let start ~rule:{ Rule.id; targets; _ } ~async_id ~forced_by ~start =
      Dune_trace.emit_all ~buffered:true Category.Graph
      @@ fun () ->
      Graph.Exec_rule.start
        ~async_id
        ~rule_id:(Rule.Id.to_int id)
        ~targets:(conv_targets targets)
        ~forced_by:(Option.map forced_by ~f:Forced_by.conv)
        ~start
    ;;

    let finish ~async_id ~rule_id outcome =
      Dune_trace.emit ~buffered:true Category.Graph (fun () ->
        Graph.Exec_rule.finish ~async_id ~rule_id ~outcome)
    ;;

    let deps_start ~async_id ~rule_id () =
      Dune_trace.emit ~buffered:true Category.Graph (fun () ->
        Graph.Exec_rule.deps_start ~async_id ~rule_id)
    ;;

    let deps_finish ~async_id ~rule_id (deps : Dep.Set.t) =
      Dune_trace.emit_all ~buffered:true Category.Graph
      @@ fun () ->
      let deps = Dep.Set.to_list_map ~f:Dep.to_dyn deps in
      Graph.Exec_rule.deps_finish ~async_id ~rule_id ~deps
    ;;

    let action_start ~async_id ~rule_id () =
      Dune_trace.emit ~buffered:true Category.Graph (fun () ->
        Graph.Exec_rule.action_start ~async_id ~rule_id)
    ;;

    let action_finish ~async_id ~rule_id (dyn_deps : Dep.Set.t list) =
      Dune_trace.emit_all ~buffered:true Category.Graph
      @@ fun () ->
      let dyn_deps = List.map dyn_deps ~f:(Dep.Set.to_list_map ~f:Dep.to_dyn) in
      Graph.Exec_rule.action_finish ~async_id ~rule_id ~dyn_deps
    ;;
  end

  module Other_events = struct
    type t =
      { deps_start : unit -> unit
      ; deps_finish : Dep.Set.t -> unit
      ; action_start : unit -> unit
      ; action_finish : Dep.Set.t list -> unit
      ; finish : outcome -> unit
      }

    let empty =
      { deps_start = ignore
      ; deps_finish = ignore
      ; action_start = ignore
      ; action_finish = ignore
      ; finish = ignore
      }
    ;;

    let make ~async_id ~rule_id =
      { deps_start = Emit.deps_start ~async_id ~rule_id
      ; deps_finish = Emit.deps_finish ~async_id ~rule_id
      ; action_start = Emit.action_start ~async_id ~rule_id
      ; action_finish = Emit.action_finish ~async_id ~rule_id
      ; finish = Emit.finish ~async_id ~rule_id
      }
    ;;
  end

  let start ~(rule : Rule.t) (f : Other_events.t -> 'a Memo.t) : 'a Memo.t =
    if enabled Category.Graph
    then (
      let new_forcer = Forced_by.rule ~rule in
      let async_id = Event.gen_async_id () in
      let rule_id = Rule.Id.to_int rule.id in
      let open Fiber.O in
      (let* forced_by = Forced_by.get in
       let start = Time.now () in
       Emit.start ~rule ~async_id ~forced_by ~start;
       let other_events = Other_events.make ~async_id ~rule_id in
       Forced_by.set ~new_forcer f other_events)
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
      let new_forcer = Forced_by.dynamic_includes ~path in
      let start = Time.now () in
      Dune_trace.emit ~buffered:true Category.Graph (fun () ->
        Graph.Dune_dyn.start ~async_id ~start);
      let open Fiber.O in
      (let+ result = Forced_by.set ~new_forcer f () in
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
      let new_forcer = Forced_by.rule_gen ~dir () in
      let start = Time.now () in
      Dune_trace.emit ~buffered:true Category.Graph (fun () ->
        Graph.Gen_rules.dir_start ~async_id ~dir ~start);
      let open Fiber.O in
      (let+ result = Forced_by.set ~new_forcer f () in
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
      let new_forcer = Forced_by.rule_gen ~dir ~source_dir () in
      let start = Time.now () in
      Dune_trace.emit ~buffered:true Category.Graph (fun () ->
        Graph.Gen_rules.dune_file_start ~async_id ~dir ~source_dir ~start);
      let open Fiber.O in
      (let+ result = Forced_by.set ~new_forcer f () in
       Dune_trace.emit ~buffered:true Category.Graph (fun () ->
         Graph.Gen_rules.dune_file_finish ~async_id);
       result)
      |> Memo.of_reproducible_fiber)
    else f ()
  ;;
end
