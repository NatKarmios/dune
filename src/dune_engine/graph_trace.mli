(** Utilities for tracing the build graph *)

open Import

module Exec_rule : sig
  (** How a rule's execution completed. Failures are reported by [start]
      itself. *)
  type outcome =
    | Executed
    | Local_cache_hit
    | Shared_cache_hit

  (** Trace the execution of [rule] as an "exec-rule" async span. [f] passes
      the rule's facts to [deps_resolved] as soon as it has them, then calls
      [finish] with the dynamic deps (one set per dynamic-deps stage) and the
      [outcome] to end the span. [trace_action] wraps the action's execution in
      a nested "exec-rule-action" span; cache hits never call it.

      If [f] raises, the end is emitted here instead, carrying the deps
      reported to [deps_resolved] if it got that far and otherwise deps
      recovered from [rule] without building them. A cancellation carries
      none. *)
  val start
    :  rule:Rule.t
    -> (deps_resolved:(Dep.Facts.t -> unit)
        -> finish:(dyn_deps:Dep.Set.t list -> outcome -> unit)
        -> trace_action:((unit -> 'b Fiber.t) -> 'b Fiber.t)
        -> 'a Memo.t)
    -> 'a Memo.t
end

module Dynamic_includes : sig
  (** Trace the reading and processing of [dune_file], recording it as the
      [forced_by] context while [f] runs. *)
  val start : dune_file:Path.Source.t -> (unit -> 'a Memo.t) -> 'a Memo.t
end

module Gen_rules : sig
  (** Trace rule generation for [dir], recording it as the [forced_by] context
      while [f] runs. [f] is handed a callback to report the source dune file
      driving the directory, which is attached to the span. *)
  val start : dir:Path.Build.t -> ((Path.Source.t -> unit) -> 'a Memo.t) -> 'a Memo.t
end

module Pform : sig
  (** Attribute any build forced while [f] runs to the dune file [dir]/[fname].
      Wraps no-deps pform expansion at rule-generation time, whose forced build
      would otherwise carry no forcer. Emits no span event. *)
  val expand
    :  dir:Path.Build.t
    -> fname:Import.Filename.t
    -> (unit -> 'a Memo.t)
    -> 'a Memo.t
end

module Configurator : sig
  (** Attribute any build forced while [f] runs to the [configurator] forcer.
      Emits no span event. *)
  val force : (unit -> 'a Memo.t) -> 'a Memo.t
end

module Request : sig
  (** Attribute any build forced while [f] runs to the [request] forcer, so a
      requested goal's targets are attributed to the request. Emits no span
      event. *)
  val build : (unit -> 'a Memo.t) -> 'a Memo.t
end

module Build_dep : sig
  (** Trace building a single dependency as an async span, recording it as the
      [forced_by] context while [f] runs. [f] is passed a callback reporting
      what the dep resolved to; it only reports -- the span ends when [f] does.
      Call it as soon as the resolution is known, ahead of the building that
      may fail, or the span ends unresolved. *)

  (** A file dep: the callback takes the rule that produces the file, or [None]
      if it is a source file. Known once the rule is looked up. *)
  val file : Path.t -> ((Rule.t option -> unit) -> 'a Memo.t) -> 'a Memo.t

  (** An alias dep: the callback takes the facts the alias expanded to. Those
      are a product of the very building that may fail, so [recover] is called
      instead when [f] raises, and should re-walk the alias's definitions to
      their deps without building them. It is not called for a cancellation,
      nor if the facts were already reported. *)
  val alias
    :  Alias.t
    -> recover:(unit -> Dep.Set.t Memo.t)
    -> ((Dep.Facts.t list -> unit) -> 'a Memo.t)
    -> 'a Memo.t

  (** A file-selector (glob) dep: the callback takes the files it matched.
      Known once the selector is evaluated. *)
  val file_selector
    :  File_selector.t
    -> ((Filename_set.t -> unit) -> 'a Memo.t)
    -> 'a Memo.t
end
