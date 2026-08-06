open Stdune

module Category : sig
  type t =
    | Rpc
    | Gc
    | Alloc
    | Fd
    | Sandbox
    | Persistent
    | Process
    | Rules
    | Pkg
    | Scheduler
    | Promote
    | Build
    | Debug
    | Config
    | File_watcher
    | Diagnostics
    | Log
    | Cram
    | Action
    | Cache
    | Digest
    | Artifact_substitution
    | Thread
    | Runtime
    | Graph
end

module Event : sig
  module Async : sig
    type t
    type data

    val create_sandbox : loc:Loc.t -> data
    val fetch : url:string -> target:Path.t -> checksum:string option -> data
    val pkg_load_lock_dir : path:string -> data
  end

  type t
  type async_id

  (** A fresh id for Chrome async events, unique across all such events so that
      begin/end/instant events pair up correctly. *)
  val gen_async_id : unit -> async_id

  val sandbox
    :  [ `Create | `Snapshot | `Destroy | `Extract | `Corrected ]
    -> start:Time.t
    -> stop:Time.t
    -> queued:Time.Span.t option
    -> Loc.t
    -> dir:Path.Build.t
    -> t

  val evalauted_rules : rule_total:int -> t

  module Exit_status : sig
    type error =
      | Failed of int
      | Signaled of Signal.t

    type t = (int, error) result
  end

  type targets =
    { root : Path.Build.t
    ; files : Filename.Set.t
    ; dirs : Filename.Set.t
    }

  val process_start
    :  extra_args:(string * Sexp.t) list
    -> pid:Pid.t
    -> dir:Path.t option
    -> prog:string
    -> args:string list
    -> timeout:Time.Span.t option
    -> started_at:Time.t
    -> name:string option
    -> categories:string list
    -> targets:targets option
    -> queued:Time.Span.t
    -> t

  val process
    :  extra_args:(string * Sexp.t) list
    -> name:string option
    -> started_at:Time.t
    -> targets:targets option
    -> categories:string list
    -> pid:Pid.t
    -> exit:Exit_status.t
    -> prog:string
    -> process_args:string list
    -> dir:Path.t option
    -> stdout:string
    -> stderr:string
    -> times:Proc.Times.t
    -> t

  val unknown_process : Proc.Process_info.t -> t

  type timeout =
    { pid : Pid.t
    ; group_leader : bool
    ; timeout : Time.Span.t
    }

  val signal_received : Signal.t -> t
  val signal_sent : Signal.t -> [ `Ui | `Timeout of timeout ] -> t

  val persistent
    :  file:Path.t
    -> module_:string
    -> [ `Save | `Load ]
    -> start:Time.t
    -> stop:Time.t
    -> t

  val scan_source : name:string -> start:Time.t -> stop:Time.t -> dir:Path.Source.t -> t
  val scheduler_idle : unit -> t
  val process_cleanup_start : unit -> t
  val process_cleanup_sigkill : unit -> t
  val process_cleanup_finish : unit -> t

  val child_process_cleanup
    :  pids:Pid.t list
    -> [ `Started | `Sent_signal of Signal.t | `Finished | `Failed ]
    -> t

  val process_group_cleanup
    :  pid:Pid.t
    -> [ `Already_exited
       | `Sent_signal of Signal.t
       | `Timed_out of Time.Span.t
       | `Finished
       ]
    -> t

  val watch_build_start : run_id:int -> restart:bool -> start:Time.t -> t
  val watch_build_restart : run_id:int -> reasons:string list -> at:Time.t -> t

  val watch_build_finish
    :  run_id:int
    -> outcome:[ `Success | `Failure ]
    -> start:Time.t
    -> stop:Time.t
    -> restart_duration:Time.Span.t option
    -> t

  val init : version:string option -> t
  val gc : unit -> t
  val fd_count : unit -> t option
  val spawn_thread : name:string -> t

  module Promote : sig
    val promote : Path.Build.t -> Path.Source.t -> t
    val register : [ `Direct | `Staged ] -> Path.Build.t -> Path.Source.t -> t
  end

  type alias =
    { dir : Path.Source.t
    ; name : string
    ; recursive : bool
    ; contexts : string list
    }

  val resolve_targets : Path.t list -> alias list -> t
  val load_dir : Path.t -> t
  val log : Log.Message.t -> t

  val error
    :  Loc.t option
    -> [< `Fatal | `User ]
    -> Exn.t
    -> Printexc.raw_backtrace option
    -> Dyn.t list
    -> t

  module Rpc : sig
    type stage =
      [ `Start
      | `Stop
      ]

    val session : id:int -> stage -> t

    val message
      :  [ `Request of Sexp.t | `Notification ]
      -> meth_:string
      -> id:int
      -> stage
      -> t

    val packet_read : id:int -> success:bool -> error:string option -> t
    val packet_write : id:int -> count:int -> t

    val accept
      :  id:int
      -> stage
      -> [ `Close | `Error of Exn_with_backtrace.t | `Accept ] option
      -> t

    val shutdown : id:int -> stage -> t
    val startup_failure : Exn_with_backtrace.t -> t
    val registry_write : path:string -> t
    val close : id:int -> t
    val dropped_write_client_disconnect : Exn.t -> t
  end

  module Cram : sig
    type times =
      { real : Time.Span.t
      ; system : Time.Span.t
      ; user : Time.Span.t
      }

    type command =
      { command : string list
      ; times : times
      }

    val test : test:Path.t -> command list -> t
  end

  module Action : sig
    val start : name:string -> start:Time.t -> t
    val finish : name:string -> start:Time.t -> t

    module Runner : sig
      type kind =
        | Spawn of Pid.t
        | Connection_start
        | Connection_established
        | Connected
        | Request_sent
        | Cancel_request_sent
        | Cancel_start
        | Disconnected

      val runner_event : name:Action_runner_name.t -> kind -> t
    end

    val write_file : start:Time.t -> finish:Time.t -> file:Path.t -> size:int -> t
    val trace : digest:string -> Csexp.t -> t
  end

  module Cache : sig
    val shared
      :  [ `Miss of string | `Hit ]
      -> rule_digest:string
      -> head:Path.Build.t
      -> t

    val workspace_local_miss : head:Path.Build.t -> reason:string -> t

    val fs_update
      :  cache_type:string
      -> path:Path.Outside_build_dir.t
      -> [ `Skipped | `Changed | `Unchanged ]
      -> t
  end

  module Digest : sig
    val redigest
      :  path:Path.t
      -> old_digest:string
      -> new_digest:string
      -> old_stats:Dyn.t
      -> new_stats:Dyn.t
      -> t

    val reread_dir
      :  path:Path.t
      -> old_contents:Dyn.t
      -> new_contents:Dyn.t
      -> old_stats:Dyn.t
      -> new_stats:Dyn.t
      -> t

    val dropped_stale_mtimes : Path.t list -> fs_now:Time.t -> t
  end

  val debug : (string * Dyn.t) list -> t
  val artifact_substitution : file:Path.t -> placeholder:Dyn.t -> value:string -> t

  module Graph : sig
    type forced_by =
      | Forced_by_rule of int
      | Forced_by_dep of Dyn.t
      | Forced_by_dynamic_includes of Path.Source.t
      | Forced_by_rule_gen of
          { dir : Path.Build.t
          ; source_dir : Path.Source.t option
          }

    module Build_dep : sig
      (** How building a dep resolved: it belonged to a [Dep_rule] (by id), it
          [Dep_expanded] to concrete deps (e.g. an alias or glob), or it was a
          source file ([Dep_is_source]). *)
      type outcome =
        | Dep_rule of int
        | Dep_expanded of Dyn.t list
        | Dep_is_source

      (** An async "build-dep" span for building a single dep, keyed by
          [async_id]: [start] emits the begin (carrying [dep]) and [finish] the
          matching end (carrying the [outcome]). Deps are interned, so each
          returns its event preceded by an [intern-deps] event for deps seen for
          the first time; emit the whole list (e.g. with [emit_all]). *)
      val start : async_id:async_id -> forced_by:forced_by option -> dep:Dyn.t -> t list

      val finish : async_id:async_id -> outcome:outcome -> t list
    end

    module Exec_rule : sig
      type outcome =
        | Executed
        | Local_cache_hit
        | Shared_cache_hit

      (* The events are Chrome nestable-async events keyed by [async_id]:
         [start] emits a begin and [finish] the matching end, while the phase
         events below emit async-instant markers on the same track. They all
         also carry [rule_id] (the rule's own identity, distinct from the async
         chain's id). [start] returns its begin event preceded by an
         [intern-targets] event for targets seen for the first time; emit the
         whole list (e.g. with [emit_all]) so ids are declared before
         referenced. *)
      val start
        :  async_id:async_id
        -> rule_id:int
        -> targets:targets
        -> forced_by:forced_by option
        -> start:Time.t
        -> t list

      val finish : async_id:async_id -> rule_id:int -> outcome:outcome -> t

      (* Async-instant markers on the rule's span bracketing the
         dependency-resolution and action phases of its execution. [deps_finish]
         carries the resolved dependencies and [action_finish] the dynamic
         dependencies (one list per dynamic-dep node), both interned: they
         return the marker preceded by an [intern-deps] event for deps seen for
         the first time, so emit the whole list (e.g. with [emit_all]). *)
      val deps_start : async_id:async_id -> rule_id:int -> t
      val deps_finish : async_id:async_id -> rule_id:int -> deps:Dyn.t list -> t list
      val action_start : async_id:async_id -> rule_id:int -> t

      val action_finish
        :  async_id:async_id
        -> rule_id:int
        -> dyn_deps:Dyn.t list list
        -> t list
    end

    module Dune_dyn : sig
      val start : async_id:async_id -> start:Time.t -> t
      val finish : async_id:async_id -> t
    end

    module Gen_rules : sig
      val dir_start : async_id:async_id -> dir:Path.Build.t -> start:Time.t -> t
      val dir_finish : async_id:async_id -> t

      val dune_file_start
        :  async_id:async_id
        -> dir:Path.Build.t
        -> source_dir:Path.Source.t
        -> start:Time.t
        -> t

      val dune_file_finish : async_id:async_id -> t
    end
  end
end

module File_watcher_event : sig
  type kind =
    | Created
    | Deleted
    | File_changed
    | Unknown

  type t =
    [ `File of Path.t * kind
    | `Queue_overflow
    | `Sync of int
    | `Watcher_terminated
    ]

  val kind_repr : kind Repr.t
  val to_event : t -> Event.t
  val debounce_extend : files:(Path.t * kind) list -> invalidation_empty:bool -> Event.t
end

module Out : sig
  type t

  val create : [ `Path of Path.t | `Fd of Fd.t ] -> t
  val emit : ?buffered:bool -> t -> Event.t -> unit
  val start : t option -> (unit -> Event.Async.data) -> Event.Async.t option
  val finish : t -> Event.Async.t option -> unit
end

val global : unit -> Out.t option
val set_global : Out.t -> path:Path.t -> unit
val set_global_inherited_fd : ?common_args:(string * Sexp.t) list -> Fd.t -> unit
val duplicate_global_fd : unit -> Fd.t option
val always_emit : Event.t -> unit
val enabled : Category.t -> bool
val emit : ?buffered:bool -> Category.t -> (unit -> Event.t) -> unit
val emit_all : ?buffered:bool -> Category.t -> (unit -> Event.t list) -> unit
val emit_runtime : unit -> unit
val flush : unit -> unit
val reset_alloc_profile : unit -> unit
val capture_alloc_profile : [ `Build of int | `Exit ] -> Event.t option
val at_exit : At_exit.t

module Private : sig
  module Fd_count : sig
    type t =
      | Unknown
      | This of int

    val get : unit -> t
  end

  module Buffer : module type of Buffer
end
