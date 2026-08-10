open Stdune

module Arg = struct
  type t = Sexp.t

  let string s = Sexp.Atom s
  let sexp t = t
  let dyn dyn = sexp (Sexp.of_dyn dyn)
  let path p = string (Path.to_string p)
  let source_path p = string (Path.Source.to_string p)
  let build_path p = string (Path.Build.to_string p)
  let float x = string (string_of_float x)
  let list xs = Sexp.List xs
  let int x = Sexp.Atom (string_of_int x)
  let bool x = Sexp.Atom (string_of_bool x)
  let record xs = List.map xs ~f:(fun (k, v) -> list [ string k; v ])
  let time ts = int (Time.to_ns ts)
  let span span = int (Time.Span.to_ns span)
end

let gc_args () =
  (* CR-someday rgrinberg: find a way to include all new fields in recent
     versions of OCaml *)
  let stat = Gc.quick_stat () in
  [ "stack_size", Arg.int stat.stack_size
  ; "heap_words", Arg.int stat.heap_words
  ; "top_heap_words", Arg.int stat.top_heap_words
  ; "minor_words", Arg.float stat.minor_words
  ; "major_words", Arg.float stat.major_words
  ; "promoted_words", Arg.float stat.promoted_words
  ; "compactions", Arg.int stat.compactions
  ; "major_collections", Arg.int stat.major_collections
  ; "minor_collections", Arg.int stat.minor_collections
  ]
;;

module Event = struct
  module Id = struct
    type t = string

    let int x = string_of_int x
    let string x = x
  end

  type args = (string * Arg.t) list
  type t = Sexp.t

  let common_args = ref []
  let base ~name cat : Sexp.t list = [ Atom (Category.to_string cat); Atom name ]
  let record_args args = Arg.record (args @ !common_args)
  let set_common_args args = common_args := args

  let complete ?(args = []) ~name ~start ~dur cat : t =
    List
      (base ~name cat @ [ Sexp.List [ Arg.time start; Arg.span dur ] ] @ record_args args)
  ;;

  let instant ?(args = []) ~name ts cat : t =
    List (base ~name cat @ [ Arg.time ts ] @ record_args args)
  ;;

  let async ?(args = []) id ~name ts stage cat : t =
    List
      (base ~name cat
       @ [ Arg.time ts ]
       @ Arg.record
           [ "id", Arg.string id
           ; ( "stage"
             , Arg.string
                 (match stage with
                  | `Start -> "start"
                  | `Stop -> "stop") )
           ]
       @ record_args args)
  ;;

  (* Chrome nestable-async events, keyed by an integer [id] and a [phase]
     ("begin"/"end"/"instant", rendered as ph b/e/n). Begin/end sharing an id
     form a span; an instant attaches a marker to that span's track. *)
  let async_phase ?(args = []) ~async_id ~phase ~name ts cat : t =
    List
      (base ~name cat
       @ [ Arg.time ts ]
       @ Arg.record [ "async_id", Arg.int async_id; "async_phase", Arg.string phase ]
       @ record_args args)
  ;;

  let async_begin ?args ~async_id ~name ts cat =
    async_phase ?args ~async_id ~phase:"begin" ~name ts cat
  ;;

  let async_end ?args ~async_id ~name ts cat =
    async_phase ?args ~async_id ~phase:"end" ~name ts cat
  ;;

  let async_instant ?args ~async_id ~name ts cat =
    async_phase ?args ~async_id ~phase:"instant" ~name ts cat
  ;;
end

type async_id = int

(* Fresh ids for the Chrome async events above. A single counter across all such
   events keeps ids unique, so begin/end/instant events never mis-pair. *)
let async_next_id = ref 0

let gen_async_id () =
  let id = !async_next_id in
  incr async_next_id;
  id
;;

module Async = struct
  type data =
    { args : Event.args option
    ; cat : Category.t
    ; name : string
    }

  type nonrec t =
    { event_data : data
    ; start : Time.t
    }

  let create ~event_data ~start = { event_data; start }

  let create_sandbox ~loc =
    { args = Some [ "loc", Arg.string (Loc.to_file_colon_line loc) ]
    ; name = "create-sandbox"
    ; cat = Sandbox
    }
  ;;

  let fetch ~url ~target ~checksum =
    let args =
      let args = [ "url", Arg.string url; "target", Arg.path target ] in
      match checksum with
      | None -> args
      | Some c -> ("checksum", Arg.string c) :: args
    in
    { args = Some args; cat = Pkg; name = "fetch" }
  ;;

  let pkg_load_lock_dir ~path =
    let args = [ "path", Arg.string path ] in
    { args = Some args; cat = Pkg; name = "load_lock_dir" }
  ;;
end

type t = Event.t

type alloc_source =
  { source : string
  ; estimated_words : int
  ; samples : int
  }

type alloc_entry =
  { source : string
  ; trace : string list
  ; estimated_words : int
  ; samples : int
  }

type alloc_heap =
  { total_words : int
  ; total_samples : int
  ; by_source : alloc_source list
  ; top : alloc_entry list
  }

let scan_source ~name ~start ~stop ~dir =
  let dur = Time.diff stop start in
  let args = [ "dir", Arg.source_path dir ] in
  Event.complete ~name ~start ~args ~dur Rules
;;

let evalauted_rules ~rule_total =
  let now = Time.now () in
  let args = [ "value", Arg.int rule_total ] in
  Event.instant ~name:"evalauted_rules" ~args now Rules
;;

let init ~version =
  let now = Time.now () in
  let args =
    let args =
      [ "build_dir", Arg.build_path Path.Build.root
      ; "argv", Arg.list (Array.to_list Sys.argv |> List.map ~f:Arg.string)
      ; "env", Arg.list (Env.initial |> Env.to_unix |> List.map ~f:Arg.string)
      ; "root", Arg.string Path.(to_absolute_filename root)
      ; "pid", Arg.int (Unix.getpid ())
      ; "initial_cwd", Arg.string Fpath.initial_cwd
      ; "start", Arg.time Time.start
      ]
    in
    match version with
    | None -> args
    | Some v -> ("version", Arg.string v) :: args
  in
  Event.instant ~args ~name:"init" now Config
;;

let make_rusage_args resource_usage =
  match resource_usage with
  | None -> []
  | Some
      { Proc.Resource_usage.user_cpu_time
      ; system_cpu_time
      ; maxrss
      ; minflt
      ; majflt
      ; inblock
      ; oublock
      ; nvcsw
      ; nivcsw
      } ->
    [ ( "rusage"
      , Arg.record
          [ "user_cpu_time", Arg.span user_cpu_time
          ; "system_cpu_time", Arg.span system_cpu_time
          ; "maxrss", Arg.int maxrss
          ; "minflt", Arg.int minflt
          ; "majflt", Arg.int majflt
          ; "inblock", Arg.int inblock
          ; "oublock", Arg.int oublock
          ; "nvcsw", Arg.int nvcsw
          ; "nivcsw", Arg.int nivcsw
          ]
        |> Arg.list )
    ]
;;

let make_process_times_args () =
  let args =
    [ "count", Arg.int (Metrics.Build.process_count ())
    ; "elapsed_time", Arg.span (Metrics.Build.process_time ())
    ; "user_cpu_time", Arg.span (Metrics.Build.process_user_cpu_time ())
    ; "system_cpu_time", Arg.span (Metrics.Build.process_system_cpu_time ())
    ]
  in
  [ "process_times", Arg.record args |> Arg.list ]
;;

let exit () =
  let now = Time.now () in
  let args =
    let gc = gc_args () |> Arg.record |> Arg.list in
    let double ~count ~time =
      [ "count", Arg.int (Counter.read count)
      ; "time", Arg.span (Counter.Timer.read time)
      ]
    in
    let triple (module S : Metrics.Stat) =
      let open S in
      double ~count ~time @ [ "bytes", Arg.int (Counter.read bytes) ]
      |> Arg.record
      |> Arg.list
    in
    let io =
      [ "files_read", triple (module Metrics.File_read)
      ; "files_written", triple (module Metrics.File_write)
      ; ( "directories_read"
        , double ~count:Metrics.Directory_read.count ~time:Metrics.Directory_read.time
          |> Arg.record
          |> Arg.list )
      ]
      |> Arg.record
      |> Arg.list
    in
    let digest =
      [ "files", triple (module Metrics.Digest.File)
      ; "values", triple (module Metrics.Digest.Value)
      ]
      |> Arg.record
      |> Arg.list
    in
    [ "gc", gc; "io", io; "digest", digest ]
    @ make_rusage_args (Proc.Resource_usage.get_self ())
  in
  Event.instant ~args ~name:"exit" now Config
;;

let scheduler_idle () =
  let now = Time.now () in
  Event.instant ~name:"watch mode iteration" now Scheduler
;;

let process_cleanup_start () =
  Event.instant ~name:"process-cleanup-start" (Time.now ()) Process
;;

let process_cleanup_sigkill () =
  Event.instant ~name:"process-cleanup-sigkill" (Time.now ()) Process
;;

let process_cleanup_finish () =
  Event.instant ~name:"process-cleanup-finish" (Time.now ()) Process
;;

let child_process_cleanup ~pids stage =
  let stage, extra_args =
    match stage with
    | `Started -> "started", []
    | `Sent_signal signal -> "sent-signal", [ "signal", Arg.string (Signal.name signal) ]
    | `Finished -> "finished", []
    | `Failed -> "failed", []
  in
  let args =
    [ "stage", Arg.string stage
    ; "pid_count", Arg.int (List.length pids)
    ; "pids", Arg.list (List.map pids ~f:(fun pid -> Arg.int (Pid.to_int pid)))
    ]
  in
  Event.instant
    ~args:(args @ extra_args)
    ~name:"child-process-cleanup"
    (Time.now ())
    Process
;;

let process_group_cleanup ~pid stage =
  let stage, extra_args =
    match stage with
    | `Already_exited -> "already-exited", []
    | `Sent_signal signal -> "sent-signal", [ "signal", Arg.string (Signal.name signal) ]
    | `Timed_out timeout -> "timed-out", [ "timeout", Arg.span timeout ]
    | `Finished -> "finished", []
  in
  let args = [ "pid", Arg.int (Pid.to_int pid); "stage", Arg.string stage ] in
  Event.instant
    ~args:(args @ extra_args)
    ~name:"process-group-cleanup"
    (Time.now ())
    Process
;;

let watch_build_start ~run_id ~restart ~start =
  let args =
    [ "run_id", Arg.int run_id; "restart", Arg.bool restart ]
    @ make_rusage_args (Proc.Resource_usage.get_self ())
  in
  Event.instant ~name:"build-start" ~args start Build
;;

let watch_build_restart ~run_id ~reasons ~at =
  let args =
    [ "run_id", Arg.int run_id; "reasons", Arg.list (List.map reasons ~f:Arg.string) ]
  in
  Event.instant ~name:"build-restart" ~args at Build
;;

let watch_build_finish ~run_id ~outcome ~start ~stop ~restart_duration =
  let dur = Time.diff stop start in
  let outcome =
    match outcome with
    | `Success -> "success"
    | `Failure -> "failure"
  in
  let args =
    [ "run_id", Arg.int run_id; "outcome", Arg.string outcome ]
    @ (match restart_duration with
       | None -> []
       | Some restart_duration -> [ "restart_duration", Arg.span restart_duration ])
    @ make_process_times_args ()
    @ make_rusage_args (Proc.Resource_usage.get_self ())
  in
  Event.complete ~name:"build-finish" ~args ~start ~dur Build
;;

let alloc_summary ~phase ~run_id ~minor ~major ~promoted =
  let now = Time.now () in
  let source ({ source; estimated_words; samples } : alloc_source) =
    Arg.record
      [ "source", Arg.string source
      ; "estimated_words", Arg.int estimated_words
      ; "samples", Arg.int samples
      ]
    |> Arg.list
  in
  let entry ({ source; trace; estimated_words; samples } : alloc_entry) =
    Arg.record
      [ "source", Arg.string source
      ; "trace", Arg.list (List.map trace ~f:Arg.string)
      ; "estimated_words", Arg.int estimated_words
      ; "samples", Arg.int samples
      ]
    |> Arg.list
  in
  let heap { total_words; total_samples; by_source; top } =
    Arg.record
      [ "total_words", Arg.int total_words
      ; "total_samples", Arg.int total_samples
      ; "by_source", Arg.list (List.map by_source ~f:source)
      ; "top", Arg.list (List.map top ~f:entry)
      ]
    |> Arg.list
  in
  let args =
    [ ( "phase"
      , Arg.string
          (match phase with
           | `Build -> "build"
           | `Exit -> "exit") )
    ; "minor", heap minor
    ; "major", heap major
    ; "promoted", heap promoted
    ]
    @
    match run_id with
    | None -> []
    | Some run_id -> [ "run_id", Arg.int run_id ]
  in
  Event.instant ~name:"summary" ~args now Alloc
;;

module Exit_status = struct
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

let args_of_targets =
  let paths root name set =
    if Filename.Set.is_empty set
    then []
    else
      [ ( name
        , Arg.list
            (Filename.Set.to_list_map set ~f:(fun x ->
               Arg.build_path (Path.Build.relative_fname root x))) )
      ]
  in
  fun { root; files; dirs } ->
    paths root "target_files" files @ paths root "target_dirs" dirs
;;

let make_exit exit =
  match exit with
  | Ok n -> [ "exit", Arg.int n ]
  | Error (Exit_status.Failed n) ->
    [ "exit", Arg.int n; "error", Arg.string (sprintf "exited with code %d" n) ]
  | Error (Signaled s) ->
    [ "exit", Arg.int (Signal.to_int s)
    ; "error", Arg.string (sprintf "got signal %s" (Signal.name s))
    ]
;;

let process_start
      ~extra_args
      ~pid
      ~dir
      ~prog
      ~args
      ~timeout
      ~started_at
      ~name
      ~categories
      ~targets
      ~queued
  =
  let args =
    let always =
      [ "process_args", Arg.list (List.map args ~f:Arg.string)
      ; "pid", Arg.int (Pid.to_int pid)
      ; "categories", Arg.list (List.map categories ~f:Arg.string)
      ; "queued", Arg.span queued
      ]
    in
    let extended =
      List.concat
        [ [ "prog", Arg.string prog
          ; "dir", Arg.path (Option.value dir ~default:Path.root)
          ]
        ; (match targets with
           | None -> []
           | Some targets -> args_of_targets targets)
        ; (match name with
           | None -> []
           | Some name -> [ "name", Arg.string name ])
        ; (match timeout with
           | None -> []
           | Some timeout -> [ "timeout", Arg.span timeout ])
        ]
    in
    always @ extended @ extra_args
  in
  Event.instant ~args ~name:"start" started_at Process
;;

let process
      ~extra_args
      ~name
      ~started_at
      ~targets
      ~categories
      ~pid
      ~exit
      ~prog
      ~process_args
      ~dir
      ~stdout
      ~stderr
      ~times:{ Proc.Times.elapsed_time; resource_usage }
  =
  let args =
    let always =
      [ "process_args", Arg.list (List.map process_args ~f:Arg.string)
      ; "pid", Arg.int (Pid.to_int pid)
      ; "categories", Arg.list (List.map categories ~f:Arg.string)
      ]
    in
    let extended =
      let exit = make_exit exit in
      let output name s =
        match s with
        | "" -> []
        | s -> [ name, Arg.string s ]
      in
      List.concat
        [ [ "prog", Arg.string prog
          ; "dir", Arg.path (Option.value dir ~default:Path.root)
          ]
        ; exit
        ; (match targets with
           | None -> []
           | Some targets -> args_of_targets targets)
        ; output "stdout" stdout
        ; output "stderr" stderr
        ; (match name with
           | None -> []
           | Some name -> [ "name", Arg.string name ])
        ]
    in
    let resource_usage = make_rusage_args resource_usage in
    always @ extended @ resource_usage @ extra_args
  in
  Event.complete ~args ~start:started_at ~dur:elapsed_time ~name:"finish" Process
;;

let unknown_process { Proc.Process_info.pid; status; end_time; resource_usage } =
  let now = Time.now () in
  let args =
    [ "pid", Arg.int (Pid.to_int pid); "end_time", Arg.time end_time ]
    @ make_exit
        (match status with
         | WEXITED n -> Ok n
         | WSIGNALED n -> Error (Signaled (Signal.of_int n))
         | WSTOPPED _ -> assert false)
    @ make_rusage_args resource_usage
  in
  Event.instant ~args ~name:"unknown_process" now Process
;;

let signal_received signal =
  Event.instant
    ~args:[ "signal", Arg.string (Signal.name signal) ]
    ~name:"signal_received"
    (Time.now ())
    Process
;;

type timeout =
  { pid : Pid.t
  ; group_leader : bool
  ; timeout : Time.Span.t
  }

let signal_sent signal source =
  let args =
    match source with
    | `Ui -> [ "source", Arg.string "ui" ]
    | `Timeout { pid; group_leader; timeout } ->
      [ "pid", Arg.int (Pid.to_int pid)
      ; "group_leader", Arg.bool group_leader
      ; "timeout", Arg.span timeout
      ]
  in
  Event.instant
    ~args:([ "signal", Arg.string (Signal.name signal) ] @ args)
    ~name:"signal_sent"
    (Time.now ())
    Process
;;

let persistent ~file ~module_ what ~start ~stop =
  let dur = Time.diff stop start in
  let args =
    [ "path", Arg.path file
    ; "module", Arg.string module_
    ; ( "operation"
      , Arg.string
          (match what with
           | `Save -> "save"
           | `Load -> "load") )
    ]
  in
  Event.complete ~name:"db" ~args ~start ~dur Persistent
;;

module Rpc = struct
  type stage =
    [ `Start
    | `Stop
    ]

  let server ~id ~name stage = Event.async (Event.Id.int id) (Time.now ()) stage ~name Rpc
  let session ~id stage = server ~id ~name:"rpc_session" stage

  let rec to_json : Sexp.t -> Arg.t = function
    | Atom s -> Arg.string s
    | List s -> Arg.list (List.map s ~f:to_json)
  ;;

  let message what ~meth_ ~id stage =
    let now = Time.now () in
    let name =
      match what with
      | `Notification -> "notification"
      | `Request _ -> "request"
    in
    let args =
      let args = [ "meth", Arg.string meth_ ] in
      match what with
      | `Notification -> args
      | `Request id -> ("request_id", to_json id) :: args
    in
    Event.async (Event.Id.int id) ~args ~name now stage Rpc
  ;;

  let packet_read ~id ~success ~error =
    let now = Time.now () in
    let args =
      let base = [ "id", Arg.int id; "success", Arg.bool success ] in
      match error with
      | None -> base
      | Some err -> ("error", Arg.string err) :: base
    in
    Event.instant ~args ~name:"packet_read" now Rpc
  ;;

  let packet_write ~id ~count =
    let now = Time.now () in
    let args = [ "id", Arg.int id; "count", Arg.int count ] in
    Event.instant ~name:"packet_write" ~args now Rpc
  ;;

  let accept ~id stage res =
    let args =
      match res with
      | None -> []
      | Some `Close -> [ "status", Arg.string "close" ]
      | Some `Accept -> [ "status", Arg.string "accept" ]
      | Some (`Error exn) -> [ "error", Arg.dyn (Exn_with_backtrace.to_dyn exn) ]
    in
    Event.async (Event.Id.int id) ~args ~name:"accept" (Time.now ()) stage Rpc
  ;;

  let shutdown ~id stage = server ~id ~name:"shutdown" stage

  let startup_failure exn =
    let now = Time.now () in
    let args = [ "error", Arg.dyn (Exn_with_backtrace.to_dyn exn) ] in
    Event.instant ~args ~name:"startup-failure" now Rpc
  ;;

  let registry_write ~path =
    let now = Time.now () in
    let args = [ "path", Arg.string path ] in
    Event.instant ~args ~name:"registry-write" now Rpc
  ;;

  let close ~id =
    let now = Time.now () in
    let args = [ "id", Arg.int id ] in
    Event.instant ~args ~name:"close" now Rpc
  ;;

  let dropped_write_client_disconnect exn =
    let now = Time.now () in
    let args = [ "exn", Arg.dyn (Exn.to_dyn exn) ] in
    Event.instant ~args ~name:"drop-write-client-disconnect" now Rpc
  ;;
end

let gc () =
  let now = Time.now () in
  let args = gc_args () in
  Event.instant ~name:"gc" ~args now Gc
;;

let fd_count () =
  match Fd_count.get () with
  | Unknown -> None
  | This fds ->
    let now = Time.now () in
    let args = [ "value", Arg.int fds ] in
    Some (Event.instant ~name:"fds" ~args now Fd)
;;

module Promote = struct
  let promote src dst =
    let now = Time.now () in
    let args = [ "src", Arg.build_path src; "dst", Arg.source_path dst ] in
    Event.instant ~name:"promote" ~args now Promote
  ;;

  let register kind src dst =
    let now = Time.now () in
    let args =
      [ "src", Arg.build_path src
      ; "dst", Arg.source_path dst
      ; ( "how"
        , Arg.string
            (match kind with
             | `Direct -> "direct"
             | `Staged -> "staged") )
      ]
    in
    Event.instant ~name:"promote" ~args now Promote
  ;;
end

type alias =
  { dir : Path.Source.t
  ; name : string
  ; recursive : bool
  ; contexts : string list
  }

let json_of_alias { dir; name; recursive; contexts } =
  Arg.record
    [ "dir", Arg.source_path dir
    ; "name", Arg.string name
    ; "recursive", Arg.bool recursive
    ; "contexts", Arg.list (List.map contexts ~f:Arg.string)
    ]
  |> Arg.list
;;

let resolve_targets targets aliases =
  let now = Time.now () in
  let args =
    [ "targets", List.map targets ~f:Arg.path
    ; "aliases", List.map aliases ~f:json_of_alias
    ]
    |> List.filter_map ~f:(fun (k, v) ->
      match v with
      | [] -> None
      | _ :: _ -> Some (k, Arg.list v))
  in
  Event.instant ~args ~name:"targets" now Build
;;

let load_dir dir =
  let now = Time.now () in
  let args = [ "dir", Arg.path dir ] in
  Event.instant ~name:"load-dir" ~args now Debug
;;

let error loc kind exn backtrace memo_stack =
  let now = Time.now () in
  let name =
    match kind with
    | `User -> "user"
    | `Fatal -> "fatal"
  in
  let loc =
    Option.map loc ~f:(fun loc -> "loc", Arg.string (Loc.to_file_colon_line loc))
  in
  let memo_stack =
    match memo_stack with
    | [] -> None
    | frames ->
      let frames = List.map frames ~f:Arg.dyn |> Arg.list in
      Some ("memo", frames)
  in
  let backtrace =
    Option.map backtrace ~f:(fun bt ->
      "backtrace", Arg.string (Printexc.raw_backtrace_to_string bt))
  in
  let args =
    ("exn", Arg.string (Printexc.to_string exn))
    :: List.filter_opt [ loc; memo_stack; backtrace ]
  in
  Event.instant ~name ~args now Diagnostics
;;

let log { Log.Message.level; message; args } =
  let now = Time.now () in
  let name =
    match level with
    | `Warn -> "warn"
    | `Info -> "info"
    | `Verbose -> "verbose"
  in
  let args =
    ("message", Arg.string message) :: List.map args ~f:(fun (k, s) -> k, Arg.dyn s)
  in
  Event.instant ~args ~name now Log
;;

module Cram = struct
  type times =
    { real : Time.Span.t
    ; system : Time.Span.t
    ; user : Time.Span.t
    }

  type command =
    { command : string list
    ; times : times
    }

  let test ~test commands =
    let now = Time.now () in
    let args =
      [ "test", Arg.path test
      ; ( "commands"
        , List.map commands ~f:(fun { command; times = { real; user; system } } ->
            Arg.record
              [ "command", Arg.list (List.map command ~f:Arg.string)
              ; "real", Arg.span real
              ; "user", Arg.span user
              ; "system", Arg.span system
              ]
            |> Arg.list)
          |> Arg.list )
      ]
    in
    Event.instant ~args ~name:"cram" now Cram
  ;;
end

module Action = struct
  let start ~name ~start =
    Event.instant ~args:[ "name", Arg.string name ] ~name:"start" start Action
  ;;

  let finish ~name ~start =
    let dur = Time.diff (Time.now ()) start in
    Event.complete ~args:[ "name", Arg.string name ] ~name:"finish" ~start ~dur Action
  ;;

  module Runner = struct
    type kind =
      | Spawn of Pid.t
      | Connection_start
      | Connection_established
      | Connected
      | Request_sent
      | Cancel_request_sent
      | Cancel_start
      | Disconnected

    let name_and_args = function
      | Spawn pid -> "runner-spawn", [ "pid", Arg.int (Pid.to_int pid) ]
      | Connection_start -> "runner-connection-start", []
      | Connection_established -> "runner-connection-established", []
      | Connected -> "runner-connected", []
      | Request_sent -> "runner-request-sent", []
      | Cancel_request_sent -> "runner-cancel-request-sent", []
      | Cancel_start -> "runner-cancel-start", []
      | Disconnected -> "runner-disconnected", []
    ;;

    let runner_event ~name kind =
      let event_name, extra_args = name_and_args kind in
      let args = ("name", Arg.string (Action_runner_name.to_string name)) :: extra_args in
      Event.instant ~args ~name:event_name (Time.now ()) Action
    ;;
  end

  let write_file ~start ~finish ~file ~size =
    let dur = Time.diff finish start in
    let args = [ "file", Arg.path file; "size", Arg.int size ] in
    Event.complete ~start ~dur ~args ~name:"write-file" Action
  ;;

  let trace ~digest (csexp : Sexp.t) =
    match csexp with
    | List xs -> Sexp.List (xs @ [ Sexp.List [ Atom "digest"; Atom digest ] ])
    | Atom x ->
      log
        { Log.Message.level = `Warn
        ; message = "invalid event"
        ; args = [ "payload", Dyn.string x; "digest", Dyn.string digest ]
        }
  ;;
end

module Cache = struct
  let shared what ~rule_digest ~head =
    let now = Time.now () in
    let name =
      match what with
      | `Miss _ -> "miss"
      | `Hit -> "hit"
    in
    let args =
      [ "rule_digest", Arg.string rule_digest; "head", Arg.build_path head ]
      @
      match what with
      | `Miss reason -> [ "reason", Arg.string reason ]
      | `Hit -> []
    in
    Event.instant ~args ~name now Cache
  ;;

  let workspace_local_miss ~head ~reason =
    let now = Time.now () in
    let args = [ "target", Arg.build_path head; "reason", Arg.string reason ] in
    Event.instant ~args ~name:"workspace_local_miss" now Cache
  ;;

  let fs_update ~cache_type ~path result =
    let now = Time.now () in
    let args =
      [ "cache_type", Arg.string cache_type
      ; "path", Arg.string (Path.Outside_build_dir.to_string path)
      ; ( "result"
        , Arg.string
            (match result with
             | `Skipped -> "skipped"
             | `Changed -> "changed"
             | `Unchanged -> "unchanged") )
      ]
    in
    Event.instant ~args ~name:"fs_update" now Cache
  ;;
end

module Digest = struct
  let redigest ~path ~old_digest ~new_digest ~old_stats ~new_stats =
    let now = Time.now () in
    let args =
      [ "path", Arg.path path
      ; "old_digest", Arg.string old_digest
      ; "new_digest", Arg.string new_digest
      ; "old_stats", Arg.dyn old_stats
      ; "new_stats", Arg.dyn new_stats
      ]
    in
    Event.instant ~args ~name:"redigest" now Digest
  ;;

  let reread_dir ~path ~old_contents ~new_contents ~old_stats ~new_stats =
    let now = Time.now () in
    let args =
      [ "path", Arg.path path
      ; "old_contents", Arg.dyn old_contents
      ; "new_contents", Arg.dyn new_contents
      ; "old_stats", Arg.dyn old_stats
      ; "new_stats", Arg.dyn new_stats
      ]
    in
    Event.instant ~args ~name:"reread_dir" now Digest
  ;;

  let dropped_stale_mtimes paths ~fs_now =
    let now = Time.now () in
    let args =
      [ "fs_now", Arg.time fs_now; "paths", Arg.list (List.map paths ~f:Arg.path) ]
    in
    Event.instant ~args ~name:"dropped_stale_mtimes" now Digest
  ;;
end

let debug dump =
  let now = Time.now () in
  let args = List.map dump ~f:(fun (name, dyn) -> name, Arg.dyn dyn) in
  Event.instant ~args ~name:"debug" now Diagnostics
;;

let artifact_substitution ~file ~placeholder ~value =
  let now = Time.now () in
  let args =
    [ "file", Arg.path file
    ; "placeholder", Arg.dyn placeholder
    ; "value", Arg.string value
    ]
  in
  Event.instant ~args ~name:"debug" now Artifact_substitution
;;

let spawn_thread ~name =
  let now = Time.now () in
  let args = [ "name", Arg.string name ] in
  Event.instant ~args ~name:"spawn_thread" now Thread
;;

let sandbox name ~start ~stop ~queued loc ~dir =
  let args =
    [ "loc", Arg.string (Loc.to_file_colon_line loc); "dir", Arg.build_path dir ]
  in
  let args =
    match queued with
    | None -> args
    | Some queued -> ("queued", Arg.span queued) :: args
  in
  let dur = Time.diff stop start in
  let name =
    match name with
    | `Destroy -> "destroy"
    | `Snapshot -> "snapshot"
    | `Create -> "create"
    | `Extract -> "extract"
    | `Corrected -> "corrected"
  in
  Event.complete ~args ~name ~start ~dur Sandbox
;;

let runtime time what phase =
  let args =
    [ "phase", Arg.string (Runtime.runtime_phase_name phase)
    ; ( "what"
      , Arg.string
          (match what with
           | `Begin -> "begin"
           | `End -> "end") )
    ]
  in
  Event.instant ~args ~name:"event" time Runtime
;;

let runtime_counter time name value =
  let args =
    [ "name", Arg.string (Runtime.runtime_counter_name name); "value", Arg.int value ]
  in
  Event.instant ~args ~name:"counter" time Runtime
;;

module Graph = struct
  (* A single global intern table mapping a string (a target or a dependency,
     both rendered to strings by [Dune_engine.Graph_trace]) to a small integer
     id. The first time a string is seen it is assigned a fresh id; an [intern]
     event records that [id -> value] mapping and thereafter events refer to it
     by id alone. Ids are never reused, so the mapping stays valid for the
     lifetime of the trace. *)
  module Intern = struct
    type t =
      { ids : int String.Table.t
      ; mutable next : int
      }

    let create () = { ids = String.Table.create 1024; next = 0 }

    (* Return the id for [key], and whether it was freshly allocated (in which
       case the caller should emit an intern event). *)
    let intern t key =
      match String.Table.find t.ids key with
      | Some id -> id, `Existing
      | None ->
        let id = t.next in
        t.next <- id + 1;
        String.Table.set t.ids key id;
        id, `New
    ;;
  end

  let intern = Intern.create ()

  (* A private [intern] event recording the strings (targets or dependencies)
     interned for the first time, each as an [id -> value] entry. Emitted ahead
     of the event that first references the new ids. *)
  let intern_event ~ts entries =
    let entries =
      List.map entries ~f:(fun (id, value) ->
        Arg.record [ "id", Arg.int id; "value", Arg.string value ] |> Arg.list)
    in
    Event.instant ~args:[ "entries", Arg.list entries ] ~name:"intern" ts Graph
  ;;

  (* Intern all of [strings], returning the intern events for the ones not seen
     before along with their ids (in the same order as [strings]). *)
  let intern_strings ~ts strings =
    let new_entries = ref [] in
    let ids =
      List.map strings ~f:(fun s ->
        let id, freshness = Intern.intern intern s in
        (match freshness with
         | `New -> new_entries := (id, s) :: !new_entries
         | `Existing -> ());
        id)
    in
    let intern_events =
      match List.rev !new_entries with
      | [] -> []
      | entries -> [ intern_event ~ts entries ]
    in
    intern_events, ids
  ;;

  let ids_arg key ids =
    match ids with
    | [] -> []
    | _ :: _ -> [ key, Arg.list (List.map ids ~f:Arg.int) ]
  ;;

  type forced_by =
    | Forced_by_rule of int
    | Forced_by_dep of string
    | Forced_by_dynamic_includes of Path.Source.t
    | Forced_by_gen_rules of Path.Build.t
    | Forced_by_pform of Path.Source.t
    | Forced_by_configurator

  (* The dep/path payloads of [forced_by] are interned like any other trace
     path, so this returns the intern events (for values seen for the first
     time) alongside the [forced_by] arg, whose payloads are the resulting ids.
     [Forced_by_rule]'s payload is a rule id, not a path, so it is left inline. *)
  let forced_by_args ~ts = function
    | None -> [], [ "forced_by", Arg.list [] ]
    | Some forced_by ->
      let tag, strings =
        match forced_by with
        | Forced_by_rule id -> `Rule id, []
        | Forced_by_dep dep -> `Paths "dep", [ dep ]
        | Forced_by_dynamic_includes path ->
          `Paths "dynamic-includes", [ Path.Source.to_string path ]
        | Forced_by_gen_rules dir -> `Paths "gen-rules", [ Path.Build.to_string dir ]
        | Forced_by_pform dune_file -> `Paths "pform", [ Path.Source.to_string dune_file ]
        | Forced_by_configurator -> `Paths "configurator", []
      in
      let intern_events, ids = intern_strings ~ts strings in
      let parts =
        match tag with
        | `Rule id -> [ Arg.string "rule"; Arg.int id ]
        | `Paths name -> Arg.string name :: List.map ids ~f:Arg.int
      in
      intern_events, [ "forced_by", Arg.list parts ]
  ;;

  module Build_dep = struct
    (* How building a dep resolved: it belonged to a [Dep_rule] (by id), it
       [Dep_expanded] to concrete deps (e.g. an alias or glob), or it was a
       source file ([Dep_is_source]). *)
    type outcome =
      | Dep_rule of int
      | Dep_expanded of string list
      | Dep_is_source

    (* Async span for building a single dep, keyed by [async_id]: [start] emits
       the begin (carrying the interned [dep]) and [finish] the matching end
       (carrying the [outcome]). Deps are interned, so each returns its event
       preceded by an [intern] event for deps seen for the first time; emit the
       whole list (e.g. with [emit_all]). *)
    let start ~async_id ~forced_by ~dep =
      let ts = Time.now () in
      let intern_events, ids = intern_strings ~ts [ dep ] in
      let dep_arg =
        match ids with
        | [ id ] -> [ "dep", Arg.int id ]
        | _ -> []
      in
      let forced_by_intern_events, forced_by_args = forced_by_args ~ts forced_by in
      let args = dep_arg @ forced_by_args in
      intern_events
      @ forced_by_intern_events
      @ [ Event.async_begin ~args ~async_id ~name:"build-dep" ts Graph ]
    ;;

    let finish ~async_id ~(outcome : outcome) =
      let ts = Time.now () in
      let expanded =
        match outcome with
        | Dep_expanded deps -> deps
        | Dep_rule _ | Dep_is_source -> []
      in
      let intern_events, expanded_ids = intern_strings ~ts expanded in
      let outcome_arg =
        match outcome with
        | Dep_rule rule_id -> Arg.list [ Arg.string "rule"; Arg.int rule_id ]
        | Dep_expanded _ ->
          Arg.list (Arg.string "expanded" :: List.map expanded_ids ~f:Arg.int)
        | Dep_is_source -> Arg.list [ Arg.string "is-source" ]
      in
      let args = [ "dep_outcome", outcome_arg ] in
      intern_events @ [ Event.async_end ~args ~async_id ~name:"build-dep" ts Graph ]
    ;;
  end

  module Exec_rule = struct
    type outcome =
      | Executed
      | Local_cache_hit
      | Shared_cache_hit

    let outcome_to_string = function
      | Executed -> "executed"
      | Local_cache_hit -> "local-cache-hit"
      | Shared_cache_hit -> "shared-cache-hit"
    ;;

    let start ~async_id ~rule_id ~targets ~forced_by ~start =
      let intern_events, target_ids = intern_strings ~ts:start targets in
      let forced_by_intern_events, forced_by_args = forced_by_args ~ts:start forced_by in
      let args =
        (("rule_id", Arg.int rule_id) :: forced_by_args) @ ids_arg "targets" target_ids
      in
      intern_events
      @ forced_by_intern_events
      @ [ Event.async_begin ~args ~async_id ~name:"exec-rule" start Graph ]
    ;;

    (* The matching end. It carries the resolved [deps] and the dynamic deps
       ([dyn_deps], one dep list per dynamic-deps stage) alongside the outcome,
       all interned; it returns the end event preceded by an [intern] event for
       any deps seen for the first time, so emit the whole list (e.g. with
       [emit_all]). *)
    let finish ~async_id ~rule_id ~deps ~dyn_deps ~outcome =
      let ts = Time.now () in
      let dep_intern_events, dep_ids = intern_strings ~ts deps in
      let per_stage = List.map dyn_deps ~f:(intern_strings ~ts) in
      let dyn_intern_events = List.concat_map per_stage ~f:fst in
      let dyn_dep_ids = List.map per_stage ~f:snd in
      let dyn_deps_arg =
        match dyn_dep_ids with
        | [] -> []
        | _ ->
          [ ( "dyn_deps"
            , Arg.list
                (List.map dyn_dep_ids ~f:(fun ids -> Arg.list (List.map ids ~f:Arg.int)))
            )
          ]
      in
      let args =
        [ "rule_id", Arg.int rule_id
        ; "rule_outcome", Arg.string (outcome_to_string outcome)
        ]
        @ ids_arg "deps" dep_ids
        @ dyn_deps_arg
      in
      dep_intern_events
      @ dyn_intern_events
      @ [ Event.async_end ~args ~async_id ~name:"exec-rule" ts Graph ]
    ;;
  end

  module Dynamic_includes = struct
    let start ~async_id ~dune_file ~start =
      Event.async_begin
        ~args:[ "dune_file", Arg.source_path dune_file ]
        ~async_id
        ~name:"dynamic-includes"
        start
        Graph
    ;;

    let finish ~async_id =
      Event.async_end ~async_id ~name:"dynamic-includes" (Time.now ()) Graph
    ;;
  end

  module Gen_rules = struct
    (* Span for generating a directory's rules, carrying the build [dir] and,
       once known (a standalone/group-root directory), the source [dune_file]
       that drives it. *)
    let start ~async_id ~dir ~start =
      Event.async_begin
        ~args:[ "dir", Arg.build_path dir ]
        ~async_id
        ~name:"gen-rules"
        start
        Graph
    ;;

    let finish ~async_id ~dune_file =
      let args =
        match dune_file with
        | None -> []
        | Some dune_file -> [ "dune_file", Arg.source_path dune_file ]
      in
      Event.async_end ~args ~async_id ~name:"gen-rules" (Time.now ()) Graph
    ;;
  end
end
