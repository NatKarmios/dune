(** Utilities for tracing the build graph.

    Every span here is inert unless the "graph" trace category is enabled. A
    span also records itself as the {!Forced_by} context of everything that
    runs inside it, so that the spans nested within say what forced them.

    A span that raises is still ended, recording how the work it describes
    did not succeed, rather than being left without an end event. *)

open Import

module Exec_rule : sig
  (** How a rule's execution completed. A rule that never completed is
      reported by [start] itself, so those outcomes are not here. *)
  type outcome =
    | Executed
    | Local_cache_hit
    | Shared_cache_hit

  (** Trace the execution of [rule] as an "exec-rule" async span. [f] passes
      the rule's facts to [deps_resolved] as soon as it has them, then calls
      [finish] with the dynamic deps (one set per dynamic-deps stage) and the
      [outcome] to end the span. [trace_action] wraps the action's execution
      in a nested "exec-rule-action" span; cache hits never call it.

      If [f] raises, the end is emitted here instead, carrying the deps
      reported to [deps_resolved] if it got that far and otherwise deps
      recovered from [rule] without building them, or none recorded if that
      recovery fails too. A cancellation carries whatever was reported and
      recovers nothing: the build is going away. A span has at most one end
      however it is reached. *)
  val start
    :  rule:Rule.t
    -> (deps_resolved:(Dep.Facts.t -> unit)
        -> trace_action:((unit -> 'b Fiber.t) -> 'b Fiber.t)
        -> finish:(dyn_deps:Dep.Set.t list -> outcome -> unit)
        -> 'a Memo.t)
    -> 'a Memo.t
end

module Dynamic_includes : sig
  (** Trace the reading and processing of [dune_file]. *)
  val start : dune_file:Path.Source.t -> (unit -> 'a Memo.t) -> 'a Memo.t
end

module Gen_rules : sig
  (** Trace rule generation for [dir]. [f] is handed a callback to report the
      source dune file driving the directory, which is attached to the span
      end. *)
  val start : dir:Path.Build.t -> ((Path.Source.t -> unit) -> 'a Memo.t) -> 'a Memo.t
end

module Pform : sig
  (** Attribute any build forced while [f] runs to the dune file
      [dir]/[fname]. Wraps no-deps pform expansion at rule-generation time,
      whose forced build would otherwise carry no forcer. Emits no span
      event. *)
  val expand : dir:Path.Build.t -> fname:Filename.t -> (unit -> 'a Memo.t) -> 'a Memo.t
end

module Configurator : sig
  (** Attribute any build forced while [f] runs to the [configurator] forcer.
      Emits no span event. *)
  val force : (unit -> 'a Memo.t) -> 'a Memo.t
end

module Request : sig
  (** Attribute any build forced while [f] runs to the [request] forcer, so
      that a requested goal's targets are attributed to the request rather
      than to nothing. Emits no span event. *)
  val build : (unit -> 'a Memo.t) -> 'a Memo.t
end

module Build_dep : sig
  (** Trace building a single dependency as an async span. [f] is passed a
      callback reporting what the dep resolved to; it only reports -- the span
      ends when [f] does. Call it as soon as the resolution is known, ahead of
      the building that may fail, so that the span reports the resolution and
      whether building it succeeded independently. Without a report the
      resolution is [Unknown]. *)

  (** A file dep: the callback takes the rule that produces the file, or
      [None] if it is a source file. Known once the rule is looked up, so
      call it before the rule is executed. *)
  val file : Path.t -> ((Rule.t option -> unit) -> 'a Memo.t) -> 'a Memo.t

  (** An alias dep: the callback takes the facts the alias expanded to. Those
      are a product of the very building that may fail, so there is nothing
      to report ahead of it; [recover] is called instead when [f] raises, and
      should re-walk the alias's definitions to their deps without building
      them. It is not called for a cancellation, nor if the facts were
      already reported. *)
  val alias
    :  Alias.t
    -> recover:(unit -> Dep.Set.t Memo.t)
    -> ((Dep.Facts.t list -> unit) -> 'a Memo.t)
    -> 'a Memo.t

  (** A file-selector (glob) dep: the callback takes the files it matched.
      Known once the selector is evaluated, so call it before those files are
      built. *)
  val file_selector
    :  File_selector.t
    -> ((Filename_set.t -> unit) -> 'a Memo.t)
    -> 'a Memo.t
end
