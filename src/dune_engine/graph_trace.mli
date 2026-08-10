(** Utilities for tracing the build graph *)

open Import

module Exec_rule : sig
  type outcome = Dune_trace.Event.Graph.Exec_rule.outcome =
    | Executed
    | Local_cache_hit
    | Shared_cache_hit

  (** Trace the execution of [rule] as an "exec-rule" async span. [f] is handed
      a [finish] callback to emit the span's end, passing the resolved [deps],
      the dynamic dependencies [dyn_deps] (one dep set per dynamic-deps stage),
      and the execution [outcome]. *)
  val start
    :  rule:Rule.t
    -> ((deps:Dep.Set.t -> dyn_deps:Dep.Set.t list -> outcome -> unit) -> 'a Memo.t)
    -> 'a Memo.t
end

module Dynamic_includes : sig
  (** Trace the reading and processing of the dune file at [path], recording it
      as the [forced_by] context for any work done while [f] runs. *)
  val start : dune_file:Path.Source.t -> (unit -> 'a Memo.t) -> 'a Memo.t
end

module Gen_rules : sig
  (** Trace rule generation for [dir], recording it as the [forced_by] context
      for any build forced while [f] runs (e.g. by pform expansion). [f] is
      handed a callback to report the source [dune_file] driving the directory
      (for a standalone/group root), which is attached to the span. *)
  val start : dir:Path.Build.t -> ((Path.Source.t -> unit) -> 'a Memo.t) -> 'a Memo.t
end

module Pform : sig
  (** Attribute any build forced while [f] runs to [dune_file] (via a
      [forced_by] of the [pform] kind). Used to wrap no-deps pform expansion at
      rule-generation time — e.g. [%{read:...}] in an [enabled_if] — whose
      forced build would otherwise carry no forcer. Emits no span event. *)
  val expand
    :  dir:Path.Build.t
    -> fname:Import.Filename.t
    -> (unit -> 'a Memo.t)
    -> 'a Memo.t
end

module Configurator : sig
  (** Attribute any build forced while [f] runs to the [configurator] forcer —
      the eager per-context configurator files. Emits no span event. *)
  val force : (unit -> 'a Memo.t) -> 'a Memo.t
end

module Build_dep : sig
  (** Trace building a single dependency as an async span, recording it as the
      [forced_by] context while [f] runs. Each function starts the span for the
      relevant dep and passes [f] a callback to emit the finish once the dep's
      outcome is known. *)

  (** A file dep: the callback takes the rule that produces the file, or [None]
      if it is a source file. *)
  val file : Path.t -> ((Rule.t option -> unit) -> 'a Memo.t) -> 'a Memo.t

  (** An alias dep: the callback takes the facts the alias expanded to. *)
  val alias : Alias.t -> ((Dep.Facts.t list -> unit) -> 'a Memo.t) -> 'a Memo.t

  (** A file-selector (glob) dep: the callback takes the files it matched. *)
  val file_selector
    :  File_selector.t
    -> ((Filename_set.t -> unit) -> 'a Memo.t)
    -> 'a Memo.t
end
