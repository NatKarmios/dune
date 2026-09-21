(** Utilities for tracing the build graph.

    Every span here is inert unless the "graph" trace category is enabled. A
    span also records itself as the {!Forced_by} context of everything that
    runs inside it, so that the spans nested within say what forced them.

    Only the success path is traced: if the traced computation raises, the
    span is left without an end event. *)

open Import

module Exec_rule : sig
  (** How a rule's execution completed. *)
  type outcome =
    | Executed
    | Local_cache_hit
    | Shared_cache_hit

  (** Trace the execution of [rule] as an "exec-rule" async span. [f] passes
      the rule's facts to [deps_resolved] as soon as it has them, then calls
      [finish] with the dynamic deps (one set per dynamic-deps stage) and the
      [outcome] to end the span. [trace_action] wraps the action's execution
      in a nested "exec-rule-action" span; cache hits never call it. *)
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

module Build_dep : sig
  (** Trace building a single dependency as an async span. [f] is passed a
      callback reporting what the dep resolved to; it only reports -- the span
      ends when [f] does. Without a report the resolution is [Unknown]. *)

  (** A file dep: the callback takes the rule that produces the file, or
      [None] if it is a source file. *)
  val file : Path.t -> ((Rule.t option -> unit) -> 'a Memo.t) -> 'a Memo.t

  (** An alias dep: the callback takes the facts the alias expanded to. *)
  val alias : Alias.t -> ((Dep.Facts.t list -> unit) -> 'a Memo.t) -> 'a Memo.t

  (** A file-selector (glob) dep: the callback takes the files it matched. *)
  val file_selector
    :  File_selector.t
    -> ((Filename_set.t -> unit) -> 'a Memo.t)
    -> 'a Memo.t
end
