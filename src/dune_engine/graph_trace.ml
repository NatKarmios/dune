open Stdune
open Dune_trace
module Graph = Event.Graph

let path_to_string (path : Path.t) =
  path |> Path.Expert.try_localize_external |> Path.to_string
;;

(* Render a dependency for the trace. *)
let dep_to_string (dep : Dep.t) =
  match dep with
  | Env var -> sprintf "env:%s" (Env.Var.to_string var)
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
  module Resolution = Graph.Build_dep.Resolution
  module Status = Graph.Build_dep.Status

  let expanded deps = Resolution.Expanded (Dep.Set.to_list_map deps ~f:dep_to_string)

  let emit_finish ~async_id resolution status =
    Dune_trace.emit_all ~buffered:true Category.Graph
    @@ fun () -> Graph.Build_dep.finish ~async_id ~resolution ~status
  ;;

  (* Trace building [dep] as an async span: [f] runs with [forced_by] set to
     this dep and a [report] callback for its resolution, and the span ends
     once [f] and everything it started have settled. If [f] raises without
     having reported, [on_failure] supplies the resolution; a cancellation goes
     straight to [Unknown], since the build is going away. *)
  let start ~(dep : Dep.t) ~resolution_of ~on_failure (f : ('b -> unit) -> 'a Memo.t)
    : 'a Memo.t
    =
    if enabled Category.Graph
    then (
      let async_id = Event.Async.gen_id () in
      let new_forcer = Forced_by.dep ~dep in
      let open Fiber.O in
      (let* forced_by = Forced_by.get in
       Dune_trace.emit_all ~buffered:true Category.Graph (fun () ->
         Graph.Build_dep.start ~async_id ~forced_by ~dep:(dep_to_string dep));
       (* [report] only records the resolution; the span still ends when the
          building does. *)
       let resolved = ref None in
       let report x = resolved := Some (resolution_of x) in
       Fiber.collect_errors (fun () -> Forced_by.set ~new_forcer f report)
       >>= function
       | Ok result ->
         emit_finish
           ~async_id
           (Option.value !resolved ~default:Resolution.Unknown)
           Status.Succeeded;
         Fiber.return result
       | Error exns ->
         let status =
           match List.for_all exns ~f:Import.Scheduler.Run.caused_by_cancellation with
           | true -> Status.Cancelled
           | false -> Status.Failed
         in
         let resolution =
           match !resolved, status with
           | Some resolution, _ -> resolution
           | None, Status.Cancelled -> Resolution.Unknown
           | None, (Succeeded | Failed) -> on_failure ()
         in
         emit_finish ~async_id resolution status;
         Fiber.reraise_all exns)
      |> Memo.of_reproducible_fiber)
    else f ignore
  ;;

  (* [file] and [file_selector] know their resolution before anything can
     fail, so a failure with none reported means there is none. *)
  let unknown_on_failure () = Resolution.Unknown

  let file (path : Path.t) f =
    start
      ~dep:(Dep.file path)
      ~resolution_of:(function
        | None -> Resolution.Source
        | Some (rule : Rule.t) -> Resolution.Rule (Rule.Id.to_int rule.id))
      ~on_failure:unknown_on_failure
      f
  ;;

  let alias (alias : Alias.t) f =
    if enabled Category.Graph
    then (
      let dep = Dep.alias alias in
      let reached = Action_builder.Reached.create ~recovery:(Forced_by.dep ~dep) in
      start
        ~dep
        ~resolution_of:(fun (facts : Dep.Facts.t list) ->
          facts |> List.map ~f:Dep.Set.of_keys |> Dep.Set.union_all |> expanded)
        ~on_failure:(fun () ->
          match Action_builder.Reached.deps reached with
          | Some deps -> expanded deps
          | None -> Resolution.Unknown)
        (f (Some reached)))
    else f None ignore
  ;;

  let file_selector (file_selector : File_selector.t) f =
    start
      ~dep:(Dep.file_selector file_selector)
      ~resolution_of:(fun (files : Filename_set.t) ->
        Resolution.Expanded (Filename_set.to_list files |> List.map ~f:path_to_string))
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

  let emit_start
        ~rule:{ Rule.id; targets = { Targets.Validated.root; files; dirs }; _ }
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

  let start
        ~(rule : Rule.t)
        (f :
          reached:Action_builder.Reached.t option
          -> deps_resolved:(Dep.Facts.t -> unit)
          -> trace_action:((unit -> 'b Fiber.t) -> 'b Fiber.t)
          -> finish:(dyn_deps:Dep.Set.t list -> outcome -> unit)
          -> 'a Memo.t)
    : 'a Memo.t
    =
    if enabled Category.Graph
    then (
      let new_forcer = Forced_by.rule ~rule in
      let async_id = Event.Async.gen_id () in
      let rule_id = Rule.Id.to_int rule.id in
      let open Fiber.O in
      (let* forced_by = Forced_by.get in
       let start = Time.now () in
       emit_start ~rule ~async_id ~forced_by ~start;
       (* A span has at most one end, and [f] can still fail after calling
          [finish], so only the first call emits. *)
       let finished = ref false in
       let emit_finish ~deps ~dyn_deps outcome =
         if not !finished
         then (
           finished := true;
           Dune_trace.emit_all ~buffered:true Category.Graph (fun () ->
             Graph.Exec_rule.finish
               ~async_id
               ~rule_id
               ~deps:(conv_deps ~deps ~dyn_deps)
               ~outcome))
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
       let reached =
         Action_builder.Reached.create ~recovery:(Forced_by.dep_recovery ~rule)
       in
       Fiber.collect_errors (fun () ->
         Forced_by.set
           ~new_forcer
           (fun () -> f ~reached:(Some reached) ~deps_resolved ~finish ~trace_action)
           ())
       >>= function
       | Ok result -> Fiber.return result
       | Error exns ->
         (match
            List.for_all exns ~f:Import.Scheduler.Run.caused_by_cancellation, !resolved
          with
          | true, deps -> emit_finish ~deps ~dyn_deps:[] Cancelled
          | false, (Some _ as deps) -> emit_finish ~deps ~dyn_deps:[] Action_fail
          | false, None ->
            emit_finish ~deps:(Action_builder.Reached.deps reached) ~dyn_deps:[] Dep_fail);
         Fiber.reraise_all exns)
      |> Memo.of_reproducible_fiber)
    else
      f
        ~reached:None
        ~deps_resolved:ignore
        ~finish:(fun ~dyn_deps:_ _ -> ())
        ~trace_action:(fun action -> action ())
  ;;
end

module Dynamic_includes = struct
  let start ~(dune_file : Path.Source.t) (f : unit -> 'a Memo.t) : 'a Memo.t =
    if enabled Category.Graph
    then (
      let async_id = Event.Async.gen_id () in
      let new_forcer = Forced_by.dynamic_includes ~dune_file in
      let start = Time.now () in
      Dune_trace.emit_all ~buffered:true Category.Graph (fun () ->
        Graph.Dynamic_includes.start ~async_id ~dune_file ~start);
      let open Fiber.O in
      (let+ result = Forced_by.set ~new_forcer f () in
       Dune_trace.emit_all ~buffered:true Category.Graph (fun () ->
         Graph.Dynamic_includes.finish ~async_id ~dune_file);
       result)
      |> Memo.of_reproducible_fiber)
    else f ()
  ;;
end

module Gen_rules = struct
  let start ~(dir : Path.Build.t) (f : (Path.Source.t -> unit) -> 'a Memo.t) : 'a Memo.t =
    if enabled Category.Graph
    then (
      let async_id = Event.Async.gen_id () in
      let new_forcer = Forced_by.gen_rules ~dir in
      let start = Time.now () in
      Dune_trace.emit_all ~buffered:true Category.Graph (fun () ->
        Graph.Gen_rules.start ~async_id ~dir ~start);
      let dune_file = ref None in
      let report_dune_file df = dune_file := Some df in
      let open Fiber.O in
      (let+ result = Forced_by.set ~new_forcer f report_dune_file in
       Dune_trace.emit_all ~buffered:true Category.Graph (fun () ->
         Graph.Gen_rules.finish ~async_id ~dir ~dune_file:!dune_file);
       result)
      |> Memo.of_reproducible_fiber)
    else f ignore
  ;;
end

module Pform = struct
  (* No span event: pform expansions are far too numerous for one span
     each. *)
  let expand ~(dir : Path.Build.t) ~(fname : Filename.t) (f : unit -> 'a Memo.t)
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
