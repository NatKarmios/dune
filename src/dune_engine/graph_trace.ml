open Stdune
open Dune_trace
module Graph = Event.Graph

let path_to_string (path : Path.t) =
  path |> Path.Expert.try_localize_external |> Path.to_string
;;

(* Render a dependency for the trace. *)
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

(* Extends the top-level [Forced_by] with the constructors that need a rule
   or a dep to name the forcer. *)
module Forced_by = struct
  include Forced_by

  let rule ~rule:{ Rule.id; _ } = Forced_by_rule (Rule.Id.to_int id)
  let dep_recovery ~rule:{ Rule.id; _ } = Forced_by_dep_recovery (Rule.Id.to_int id)
  let dep ~dep = Forced_by_dep (dep_to_string dep)
  let dynamic_includes ~dune_file = Forced_by_dynamic_includes dune_file
  let gen_rules ~dir = Forced_by_gen_rules dir
  let pform ~dune_file = Forced_by_pform dune_file
  let configurator = Forced_by_configurator
  let request = Forced_by_request
end

module Build_dep = struct
  module Outcome = Graph.Build_dep.Outcome
  module Status = Graph.Build_dep.Status

  module Emit = struct
    let start ~async_id ~forced_by ~dep =
      Dune_trace.emit_all ~buffered:true Category.Graph
      @@ fun () -> Graph.Build_dep.start ~async_id ~forced_by ~dep:(dep_to_string dep)
    ;;

    let finish ~async_id outcome status =
      Dune_trace.emit_all ~buffered:true Category.Graph
      @@ fun () -> Graph.Build_dep.finish ~async_id ~outcome ~status
    ;;
  end

  let expanded deps = Outcome.Dep_expanded (Dep.Set.to_list_map deps ~f:dep_to_string)

  (* Trace building [dep] as an async span: [f] runs with [forced_by] set to
     this dep and a [report] callback for its resolution, and the span ends
     once [f] settles. If [f] raises without having reported, [on_failure]
     supplies the outcome; a cancellation goes straight to [Dep_unknown]. *)
  let start ~(dep : Dep.t) ~outcome_of ~on_failure (f : ('b -> unit) -> 'a Memo.t)
    : 'a Memo.t
    =
    if enabled Category.Graph
    then (
      let async_id = Event.gen_async_id () in
      let new_forcer = Forced_by.dep ~dep in
      let open Fiber.O in
      (let* forced_by = Forced_by.get in
       Emit.start ~async_id ~forced_by ~dep;
       (* [report] only records the resolution; the span still ends when the
          building does. A span has at most one end. *)
       let resolved = ref None in
       let report x = resolved := Some (outcome_of x) in
       let finished = ref false in
       let emit_finish outcome status =
         if not !finished
         then (
           finished := true;
           Emit.finish ~async_id outcome status)
       in
       Fiber.with_error_handler
         (fun () ->
            let+ result = Forced_by.set ~new_forcer f report in
            emit_finish
              (Option.value !resolved ~default:Outcome.Dep_unknown)
              Status.Succeeded;
            result)
         ~on_error:(fun exn ->
           let status =
             match Import.Scheduler.Run.caused_by_cancellation exn with
             | true -> Status.Cancelled
             | false -> Status.Failed
           in
           let* () =
             match !resolved, status with
             | Some outcome, _ ->
               emit_finish outcome status;
               Fiber.return ()
             | None, Status.Cancelled ->
               emit_finish Outcome.Dep_unknown status;
               Fiber.return ()
             | None, (Succeeded | Failed) ->
               let+ outcome = on_failure () in
               emit_finish outcome status
           in
           Exn_with_backtrace.reraise exn))
      |> Memo.of_reproducible_fiber)
    else f ignore
  ;;

  (* [file] and [file_selector] know their resolution before anything can
     fail, so a failure with none reported means there is none. *)
  let unknown_on_failure () = Fiber.return Outcome.Dep_unknown

  let file (path : Path.t) f =
    start
      ~dep:(Dep.file path)
      ~outcome_of:(function
        | None -> Outcome.Dep_is_source
        | Some (rule : Rule.t) -> Dep_rule (Rule.Id.to_int rule.id))
      ~on_failure:unknown_on_failure
      f
  ;;

  (* Errors from [recover] are dropped: recovering a resolution must not
     displace the failure being reported. *)
  let alias (alias : Alias.t) ~recover f =
    let dep = Dep.alias alias in
    start
      ~dep
      ~outcome_of:(fun (facts : Dep.Facts.t list) ->
        facts |> List.map ~f:Dep.Set.of_keys |> Dep.Set.union_all |> expanded)
      ~on_failure:(fun () ->
        Fiber.map
          (Fiber.collect_errors (fun () ->
             Forced_by.set ~new_forcer:(Forced_by.dep ~dep) recover ()))
          ~f:(function
            | Ok deps -> expanded deps
            | Error (_ : Exn_with_backtrace.t list) -> Outcome.Dep_unknown))
      f
  ;;

  let file_selector (file_selector : File_selector.t) f =
    start
      ~dep:(Dep.file_selector file_selector)
      ~outcome_of:(fun (files : Filename_set.t) ->
        Outcome.Dep_expanded (Filename_set.to_list files |> List.map ~f:path_to_string))
      ~on_failure:unknown_on_failure
      f
  ;;
end

module Exec_rule = struct
  type outcome =
    | Executed
    | Local_cache_hit
    | Shared_cache_hit

  let conv_outcome : outcome -> Graph.Exec_rule.Outcome.t = function
    | Executed -> Executed
    | Local_cache_hit -> Local_cache_hit
    | Shared_cache_hit -> Shared_cache_hit
  ;;

  (* [None] deps could not be determined, as opposed to a rule that genuinely
     has none -- in which case there are no dynamic deps either. *)
  let conv_deps ~deps ~dyn_deps : Graph.Exec_rule.Deps.t =
    match deps with
    | None -> Unknown
    | Some deps ->
      Known
        { static = Dep.Set.to_list_map ~f:dep_to_string deps
        ; dynamic = List.map dyn_deps ~f:(Dep.Set.to_list_map ~f:dep_to_string)
        }
  ;;

  (* Recover the deps of a rule that failed before resolving them: [Lazy]
     evaluation yields the same set as the [Eager] evaluation that failed,
     without building anything, so it does not re-enter the failure. Errors are
     dropped -- recovery must not displace the failure being reported. It does
     run the rule's [Of_memo] nodes, which can force builds of their own, hence
     the [dep_recovery] forcer. *)
  let recover_deps (rule : Rule.t) =
    Fiber.map
      (Fiber.collect_errors (fun () ->
         Forced_by.set
           ~new_forcer:(Forced_by.dep_recovery ~rule)
           (fun () -> Action_builder.evaluate_and_collect_deps rule.action)
           ()))
      ~f:(function
        | Ok (_, deps) -> Some deps
        | Error (_ : Exn_with_backtrace.t list) -> None)
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
        ~forced_by
        ~start
    ;;

    let finish ~async_id ~rule_id ~(deps : Graph.Exec_rule.Deps.t) outcome =
      Dune_trace.emit_all ~buffered:true Category.Graph
      @@ fun () -> Graph.Exec_rule.finish ~async_id ~rule_id ~deps ~outcome
    ;;
  end

  (* Which failure a raising [f] is reported as follows from how far it got:
     [Dep_fail] before it resolved the deps and [Action_fail] after. A
     cancellation is not the rule's own failure, so it is [Cancelled], with no
     deps and no work spent recovering them. *)
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
       (* A span has at most one end, and the error handler below runs once
          per error raised under the rule, so only the first call emits. *)
       let finished = ref false in
       let emit_finish ~deps ~dyn_deps outcome =
         if not !finished
         then (
           finished := true;
           Emit.finish ~async_id ~rule_id ~deps:(conv_deps ~deps ~dyn_deps) outcome)
       in
       (* [None] until [f] resolves the deps, which is how a failure before
          that point is told from one after. *)
       let resolved = ref None in
       let deps_resolved facts = resolved := Some (Dep.Set.of_keys facts) in
       let finish ~dyn_deps outcome =
         emit_finish ~deps:!resolved ~dyn_deps (conv_outcome outcome)
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
             | true, deps ->
               emit_finish ~deps ~dyn_deps:[] Cancelled;
               Fiber.return ()
             | false, (Some _ as deps) ->
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
  (* No span event: pform expansions are far too numerous for one span each. *)
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
  let force (f : unit -> 'a Memo.t) : 'a Memo.t =
    if enabled Category.Graph
    then
      Forced_by.set ~new_forcer:Forced_by.configurator f () |> Memo.of_reproducible_fiber
    else f ()
  ;;
end

module Request = struct
  let build (f : unit -> 'a Memo.t) : 'a Memo.t =
    if enabled Category.Graph
    then Forced_by.set ~new_forcer:Forced_by.request f () |> Memo.of_reproducible_fiber
    else f ()
  ;;
end
