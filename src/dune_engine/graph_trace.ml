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
  let dep ~dep = Forced_by_dep (dep_to_string dep)
  let dynamic_includes ~dune_file = Forced_by_dynamic_includes dune_file
  let gen_rules ~dir = Forced_by_gen_rules dir
  let pform ~dune_file = Forced_by_pform dune_file
  let configurator = Forced_by_configurator
  let request = Forced_by_request
end

module Build_dep = struct
  module Resolution = Graph.Build_dep.Resolution

  let expanded deps = Resolution.Expanded (Dep.Set.to_list_map deps ~f:dep_to_string)

  (* Trace building [dep] as an async span: [f] runs with [forced_by] set to
     this dep and a [report] callback for its resolution, and the span ends
     once [f] returns. *)
  let start ~(dep : Dep.t) ~resolution_of (f : ('b -> unit) -> 'a Memo.t) : 'a Memo.t =
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
       let resolved = ref Resolution.Unknown in
       let report x = resolved := resolution_of x in
       let+ result = Forced_by.set ~new_forcer f report in
       Dune_trace.emit_all ~buffered:true Category.Graph (fun () ->
         Graph.Build_dep.finish ~async_id ~resolution:!resolved);
       result)
      |> Memo.of_reproducible_fiber)
    else f ignore
  ;;

  let file (path : Path.t) f =
    start
      ~dep:(Dep.file path)
      ~resolution_of:(function
        | None -> Resolution.Source
        | Some (rule : Rule.t) -> Resolution.Rule (Rule.Id.to_int rule.id))
      f
  ;;

  let alias (alias : Alias.t) f =
    start
      ~dep:(Dep.alias alias)
      ~resolution_of:(fun (facts : Dep.Facts.t list) ->
        facts |> List.map ~f:Dep.Set.of_keys |> Dep.Set.union_all |> expanded)
      f
  ;;

  let file_selector (file_selector : File_selector.t) f =
    start
      ~dep:(Dep.file_selector file_selector)
      ~resolution_of:(fun (files : Filename_set.t) ->
        Resolution.Expanded (Filename_set.to_list files |> List.map ~f:path_to_string))
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

  let conv_deps ~deps ~dyn_deps : Graph.Exec_rule.Deps.t =
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
          deps_resolved:(Dep.Facts.t -> unit)
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
       let resolved = ref Dep.Set.empty in
       let deps_resolved facts = resolved := Dep.Set.of_keys facts in
       let finish ~dyn_deps outcome =
         Dune_trace.emit_all ~buffered:true Category.Graph (fun () ->
           Graph.Exec_rule.finish
             ~async_id
             ~rule_id
             ~deps:(conv_deps ~deps:!resolved ~dyn_deps)
             ~outcome:(conv_outcome outcome))
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
       Forced_by.set ~new_forcer (fun () -> f ~deps_resolved ~finish ~trace_action) ())
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
