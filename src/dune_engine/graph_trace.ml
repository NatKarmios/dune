open Stdune
open Dune_trace
module Graph = Event.Graph

let path_to_string (path : Path.t) =
  path |> Path.Expert.try_localize_external |> Path.to_string
;;

(* Render a dependency to a readable string for the trace: a file to its path,
   an alias to [dir@name], a file selector (glob) to [dir/<pattern>]. *)
let dep_to_string (dep : Dep.t) =
  match dep with
  | Env var -> sprintf "env:%s" var
  | File p -> path_to_string p
  | Alias a ->
    sprintf
      "%s@%s"
      (Path.Build.to_string (Alias.dir a))
      (Alias.Name.to_string (Alias.name a))
  | File_selector fs ->
    sprintf
      "%s/%s"
      (path_to_string (File_selector.dir fs))
      (Predicate_lang.Glob.to_string (File_selector.predicate fs))
  | Universe -> "universe"
;;

module Forced_by = struct
  type t' =
    | Forced_by_rule of Rule.Id.t
    | Forced_by_dep_recovery of Rule.Id.t
    | Forced_by_dep of Dep.t
    | Forced_by_dynamic_includes of Path.Source.t
    | Forced_by_gen_rules of Path.Build.t
    | Forced_by_pform of Path.Source.t
    | Forced_by_configurator
    | Forced_by_request

  type t = t'

  let conv : t -> Graph.forced_by = function
    | Forced_by_rule id -> Forced_by_rule (Rule.Id.to_int id)
    | Forced_by_dep_recovery id -> Forced_by_dep_recovery (Rule.Id.to_int id)
    | Forced_by_dep dep -> Forced_by_dep (dep_to_string dep)
    | Forced_by_dynamic_includes path -> Forced_by_dynamic_includes path
    | Forced_by_gen_rules dir -> Forced_by_gen_rules dir
    | Forced_by_pform dune_file -> Forced_by_pform dune_file
    | Forced_by_configurator -> Forced_by_configurator
    | Forced_by_request -> Forced_by_request
  ;;

  (* The forcer of the current dynamic context. Each scope sets it while running
   its body; [Exec_rule] reads it and records the forcer on the rule's events so
   the trace shows what forced each rule. *)
  let var = Fiber.Var.create (None : t option)
  let set ~new_forcer f x = Fiber.Var.set var (Some new_forcer) (fun () -> Memo.run (f x))
  let get = Fiber.Var.get var
  let rule ~rule:{ Rule.id; _ } = Forced_by_rule id
  let dep_recovery ~rule:{ Rule.id; _ } = Forced_by_dep_recovery id
  let dep ~dep = Forced_by_dep dep
  let dynamic_includes ~dune_file = Forced_by_dynamic_includes dune_file
  let gen_rules ~dir = Forced_by_gen_rules dir
  let pform ~dune_file = Forced_by_pform dune_file
  let configurator = Forced_by_configurator
  let request = Forced_by_request
end

module Build_dep = struct
  module Emit = struct
    let start ~async_id ~forced_by ~dep =
      Dune_trace.emit_all ~buffered:true Category.Graph
      @@ fun () ->
      Graph.Build_dep.start
        ~async_id
        ~forced_by:(Option.map forced_by ~f:Forced_by.conv)
        ~dep:(dep_to_string dep)
    ;;

    let finish ~async_id outcome status =
      Dune_trace.emit_all ~buffered:true Category.Graph
      @@ fun () -> Graph.Build_dep.finish ~async_id ~outcome ~status
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
       let finish x = Emit.finish ~async_id (outcome_of x) Graph.Build_dep.Succeeded in
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
           |> Dep.Set.to_list_map ~f:dep_to_string))
      f
  ;;

  (* A file selector (glob) expands to the files it matched. *)
  let file_selector (file_selector : File_selector.t) f =
    start
      ~dep:(Dep.file_selector file_selector)
      ~outcome_of:(fun (files : Filename_set.t) ->
        Graph.Build_dep.Dep_expanded
          (Filename_set.to_list files |> List.map ~f:path_to_string))
      f
  ;;
end

module Exec_rule = struct
  type outcome =
    | Executed
    | Local_cache_hit
    | Shared_cache_hit

  let conv_outcome : outcome -> Graph.Exec_rule.outcome = function
    | Executed -> Executed
    | Local_cache_hit -> Local_cache_hit
    | Shared_cache_hit -> Shared_cache_hit
  ;;

  (* Recover the dependencies of a rule that failed before resolving them.
     [Lazy] evaluation reports the same set as the [Eager] evaluation that
     failed -- for every [Action_builder.t] constructor, the keys of the [Eager]
     facts are exactly the [Lazy] dep set -- but reaches it without building
     anything, so it does not re-enter the failure, which lives behind the [f]
     that [Eager] passes to [Dep.Facts.record_facts]. Errors raised here are
     dropped: recovering the deps must not displace the failure being
     reported.

     [Lazy] evaluation does not build deps, but it does run the rule's
     [Of_memo] nodes, which can force a build of their own (a [%{read:...}]
     pform, say). Those run under a [dep_recovery] forcer so that they are
     attributed to recovering this rule rather than to whatever forced the
     rule, which is no longer what is running. *)
  let recover_deps (rule : Rule.t) =
    Fiber.map
      (Fiber.collect_errors (fun () ->
         Forced_by.set
           ~new_forcer:(Forced_by.dep_recovery ~rule)
           (fun () -> Action_builder.evaluate_and_collect_deps rule.action)
           ()))
      ~f:(function
        | Ok (_, deps) -> deps
        | Error (_ : Exn_with_backtrace.t list) -> Dep.Set.empty)
  ;;

  module Emit = struct
    let start
          ~rule:{ Rule.id; targets = { Import.Targets.Validated.root; files; dirs }; _ }
          ~async_id
          ~forced_by
          ~start
      =
      Dune_trace.emit_all ~buffered:true Category.Graph
      @@ fun () ->
      Graph.Exec_rule.start
        ~async_id
        ~rule_id:(Rule.Id.to_int id)
        ~dir:(Path.Build.to_string root)
        ~target_files:(Filename.Set.to_list files |> Filename.L.to_string)
        ~target_dirs:(Filename.Set.to_list dirs |> Filename.L.to_string)
        ~forced_by:(Option.map forced_by ~f:Forced_by.conv)
        ~start
    ;;

    let finish ~async_id ~rule_id ~(deps : Dep.Set.t) ~(dyn_deps : Dep.Set.t list) outcome
      =
      Dune_trace.emit_all ~buffered:true Category.Graph
      @@ fun () ->
      let deps = Dep.Set.to_list_map ~f:dep_to_string deps in
      let dyn_deps = List.map dyn_deps ~f:(Dep.Set.to_list_map ~f:dep_to_string) in
      Graph.Exec_rule.finish
        ~async_id
        ~rule_id
        ~deps
        ~deps_unknown:false
        ~dyn_deps
        ~outcome
    ;;
  end

  (* [f] reports the rule's deps to [deps_resolved] as soon as it has them, and
     calls [finish] once the execution has produced an [outcome], to emit the
     matching "exec-rule" end. It is also handed a [trace_action] wrapper that
     emits an "exec-rule-action" begin/end pair around the action's execution
     fiber; the pair shares the rule's [async_id], so it nests inside the
     rule's span. [Build_system] applies it to the action execution proper
     (Step IV, after both cache lookups), so the span exists only for executed
     rules.

     If [f] raises, the end is emitted here instead, so that a rule which never
     completes still lands in the trace with its deps rather than leaving a span
     that never ends. Which failure it was follows from how far [f] got:
     [Dep_fail] before it resolved the deps and [Action_fail] after. A
     cancellation is not the rule's own failure -- the build is being torn down
     around it -- so it is reported as [Cancelled], with no deps and no work
     spent recovering them. *)
  let start
        ~(rule : Rule.t)
        (f :
          deps_resolved:(Dep.Facts.t -> unit)
          -> finish:(dyn_deps:Dep.Set.t list -> outcome -> unit)
          -> trace_action:((unit -> 'b Fiber.t) -> 'b Fiber.t)
          -> 'a Memo.t)
    : 'a Memo.t
    =
    if enabled Category.Graph
    then (
      let new_forcer = Forced_by.rule ~rule in
      let async_id = Event.gen_async_id () in
      let rule_id = Rule.Id.to_int rule.id in
      let open Fiber.O in
      (let* forced_by = Forced_by.get in
       let start = Time.now () in
       Emit.start ~rule ~async_id ~forced_by ~start;
       (* A span has at most one end. [emit_finish] is reached both by [f]
          completing and by the error handler below, which runs once per error
          raised under the rule, so only the first call emits. *)
       let finished = ref false in
       let emit_finish ~deps ~dyn_deps outcome =
         if not !finished
         then (
           finished := true;
           Emit.finish ~async_id ~rule_id ~deps ~dyn_deps outcome)
       in
       (* The rule's deps, once [f] has resolved them. [None] until then, which
          is how a failure before that point is told from one after. *)
       let resolved = ref None in
       let deps_resolved facts = resolved := Some (Dep.Set.of_keys facts) in
       let finish ~dyn_deps outcome =
         emit_finish
           ~deps:(Option.value !resolved ~default:Dep.Set.empty)
           ~dyn_deps
           (conv_outcome outcome)
       in
       let trace_action action =
         let start = Time.now () in
         Dune_trace.emit ~buffered:true Category.Graph (fun () ->
           Graph.Exec_rule_action.start ~async_id ~rule_id ~start);
         let+ result = action () in
         Dune_trace.emit ~buffered:true Category.Graph (fun () ->
           Graph.Exec_rule_action.finish ~async_id);
         result
       in
       Fiber.with_error_handler
         (fun () ->
            Forced_by.set
              ~new_forcer
              (fun () -> f ~deps_resolved ~finish ~trace_action)
              ())
         ~on_error:(fun exn ->
           let* () =
             match Import.Scheduler.Run.caused_by_cancellation exn, !resolved with
             | true, _ ->
               emit_finish ~deps:Dep.Set.empty ~dyn_deps:[] Cancelled;
               Fiber.return ()
             | false, Some deps ->
               emit_finish ~deps ~dyn_deps:[] Action_fail;
               Fiber.return ()
             | false, None ->
               let+ deps = recover_deps rule in
               emit_finish ~deps ~dyn_deps:[] Dep_fail
           in
           Exn_with_backtrace.reraise exn))
      |> Memo.of_reproducible_fiber)
    else
      f
        ~deps_resolved:ignore
        ~finish:(fun ~dyn_deps:_ _ -> ())
        ~trace_action:(fun action -> action ())
  ;;
end

module Dynamic_includes = struct
  (* Wraps the reading and processing of the dune file at [path]. Emits a
     [dynamic-includes] begin/end pair around [f] and sets [forced_by] to
     [Forced_by_dynamic_includes path] so that work done while processing the
     file is attributed to the load. *)
  let start ~(dune_file : Path.Source.t) (f : unit -> 'a Memo.t) : 'a Memo.t =
    if enabled Category.Graph
    then (
      let async_id = Event.gen_async_id () in
      let new_forcer = Forced_by.dynamic_includes ~dune_file in
      let start = Time.now () in
      Dune_trace.emit ~buffered:true Category.Graph (fun () ->
        Graph.Dynamic_includes.start ~async_id ~dune_file ~start);
      let open Fiber.O in
      (let+ result = Forced_by.set ~new_forcer f () in
       Dune_trace.emit ~buffered:true Category.Graph (fun () ->
         Graph.Dynamic_includes.finish ~async_id);
       result)
      |> Memo.of_reproducible_fiber)
    else f ()
  ;;
end

module Gen_rules = struct
  (* Wraps the generation of rules for [dir]. Emits a [gen-rules] begin/end pair
     around [f] and sets [forced_by] to [Forced_by_rule_gen { dir }] so that
     builds forced while generating the directory's rules are attributed to it.
     [f] is handed a callback to report the source [dune_file] driving the
     directory (for a standalone/group root); it is carried on the end event. *)
  let start ~(dir : Path.Build.t) (f : (Path.Source.t -> unit) -> 'a Memo.t) : 'a Memo.t =
    if enabled Category.Graph
    then (
      let async_id = Event.gen_async_id () in
      let new_forcer = Forced_by.gen_rules ~dir in
      let start = Time.now () in
      Dune_trace.emit ~buffered:true Category.Graph (fun () ->
        Graph.Gen_rules.start ~async_id ~dir ~start);
      let dune_file = ref None in
      let report_dune_file df = dune_file := Some df in
      let open Fiber.O in
      (let+ result = Forced_by.set ~new_forcer f report_dune_file in
       Dune_trace.emit ~buffered:true Category.Graph (fun () ->
         Graph.Gen_rules.finish ~async_id ~dune_file:!dune_file);
       result)
      |> Memo.of_reproducible_fiber)
    else f ignore
  ;;
end

module Pform = struct
  (* Sets [forced_by] to [Forced_by_pform dune_file] while [f] runs, so a build
     forced by expanding a pform in [dune_file]'s stanzas (e.g. [%{read:...}] in
     an [enabled_if], evaluated at rule-generation time) is attributed to that
     dune file. Unlike the other wrappers this emits no span event: pform
     expansions are far too numerous for one span each. *)
  let expand ~(dir : Path.Build.t) ~(fname : Import.Filename.t) (f : unit -> 'a Memo.t)
    : 'a Memo.t
    =
    if enabled Category.Graph
    then (
      match Path.Build.drop_build_context dir with
      | None -> f ()
      | Some src_dir ->
        let dune_file = Path.Source.relative_fname src_dir fname in
        Forced_by.set ~new_forcer:(Forced_by.pform ~dune_file) f ()
        |> Memo.of_reproducible_fiber)
    else f ()
  ;;
end

module Configurator = struct
  (* Sets [forced_by] to [Forced_by_configurator] while [f] runs, attributing the
     eager build of the per-context configurator files to it. No span event. *)
  let force (f : unit -> 'a Memo.t) : 'a Memo.t =
    if enabled Category.Graph
    then
      Forced_by.set ~new_forcer:Forced_by.configurator f () |> Memo.of_reproducible_fiber
    else f ()
  ;;
end

module Request = struct
  (* Sets [forced_by] to [Forced_by_request] while [f] runs — the top-level build
     of a requested goal — so the requested targets themselves (first forced
     here) are attributed to the request rather than to nothing. No span event. *)
  let build (f : unit -> 'a Memo.t) : 'a Memo.t =
    if enabled Category.Graph
    then Forced_by.set ~new_forcer:Forced_by.request f () |> Memo.of_reproducible_fiber
    else f ()
  ;;
end
