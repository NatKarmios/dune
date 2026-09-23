open Import

module Reached = struct
  type t =
    { mutable started : bool
    ; mutable hidden : bool
    ; mutable deps : Dep.Set.t
    }

  let create () = { started = false; hidden = false; deps = Dep.Set.empty }

  let deps { started; hidden; deps } =
    match started, hidden with
    | true, false -> Some deps
    | false, _ | true, true -> None
  ;;

  let add t deps = t.deps <- Dep.Set.union t.deps deps
end

type 'a eval_mode =
  | Lazy : Dep.Set.t eval_mode
  | Eager : Dep.Facts.t eval_mode
  | Eager_reaching : Reached.t -> Dep.Facts.t eval_mode

module Deps_or_facts = struct
  let empty : type m. m eval_mode -> m = function
    | Lazy -> Dep.Set.empty
    | Eager -> Dep.Facts.empty
    | Eager_reaching _ -> Dep.Facts.empty
  ;;

  let return : type a m. a -> m eval_mode -> a * m = fun a mode -> a, empty mode

  let union : type m. m eval_mode -> m -> m -> m =
    fun mode a b ->
    match mode with
    | Lazy -> Dep.Set.union a b
    | Eager -> Dep.Facts.union a b
    | Eager_reaching _ -> Dep.Facts.union a b
  ;;

  let union_all : type m. m eval_mode -> m list -> m =
    fun mode list ->
    match mode with
    | Lazy -> Dep.Set.union_all list
    | Eager -> Dep.Facts.union_all list
    | Eager_reaching _ -> Dep.Facts.union_all list
  ;;
end

(* A memoized builder's [Eager_reaching] evaluation. Its errors are kept as a
   value, alongside the deps it reached, so that every caller sees those deps;
   callers re-raise the same errors. *)
type 'a reaching =
  { result : ('a * Dep.Facts.t, Exn_with_backtrace.t list) result
  ; reached : Dep.Set.t option
  }

type 'a memoized =
  { lazy_ : ('a * Dep.Set.t) Memo.Lazy.t Lazy.t
  ; eager : ('a * Dep.Facts.t) Memo.Lazy.t
  ; reaching : 'a reaching Memo.Lazy.t Lazy.t
  }

type ('input, 'output) memo =
  { lazy_ : ('input, 'output * Dep.Set.t) Memo.Table.t Lazy.t
  ; eager : ('input, 'output * Dep.Facts.t) Memo.Table.t Lazy.t
  ; reaching : ('input, 'output reaching) Memo.Table.t Lazy.t
  }

module T = struct
  type _ t =
    | Return : 'a -> 'a t
    | Map : 'a t * ('a -> 'b) -> 'b t
    | Map2 : 'a t * ('a -> 'b) * ('b -> 'c) -> 'c t
    | Map3 : 'a t * ('a -> 'b) * ('b -> 'c) * ('c -> 'd) -> 'd t
    | Bind : 'a t * ('a -> 'b t) -> 'b t
    | Bind2 : 'a t * ('a -> 'b t) * ('b -> 'c t) -> 'c t
    | Bind3 : 'a t * ('a -> 'b t) * ('b -> 'c t) * ('c -> 'd t) -> 'd t
    | Map_bind : 'a t * ('a -> 'b) * ('b -> 'c t) -> 'c t
    | Bind_map : 'a t * ('a -> 'b t) * ('b -> 'c) -> 'c t
    | Both : 'a t * 'b t -> ('a * 'b) t
    | Seq : unit t * 'a t -> 'a t
    | All : 'a t list -> 'a list t
    | All_unit : unit t list -> unit t
    | Of_memo : 'a Memo.t -> 'a t
    | Map_memo : 'a Memo.t * ('a -> 'b) -> 'b t
    | Map_memo2 : 'a Memo.t * ('a -> 'b) * ('b -> 'c) -> 'c t
    | Map_memo3 : 'a Memo.t * ('a -> 'b) * ('b -> 'c) * ('c -> 'd) -> 'd t
    | Bind_memo : 'a Memo.t * ('a -> 'b t) -> 'b t
    | Bind_memo2 : 'a Memo.t * ('a -> 'b t) * ('b -> 'c t) -> 'c t
    | Bind_memo3 : 'a Memo.t * ('a -> 'b t) * ('b -> 'c t) * ('c -> 'd t) -> 'd t
    | Bind_memo_map : 'a Memo.t * ('a -> 'b t) * ('b -> 'c) -> 'c t
    | Record :
        { res : 'a
        ; deps : Dep.Set.t
        ; f : Dep.t -> Dep.Fact.t Memo.t
        }
        -> 'a t
    | Record_success : unit Memo.t -> unit t
    | Memoize : 'a memoized -> 'a t
    | Goal : 'a t -> 'a t
    | Exec_memo : ('i, 'o) memo * 'i -> 'o t
    | Push_stack_frame : (unit -> User_message.Style.t Pp.t) * (unit -> 'a t) -> 'a t
    | List_map : 'a list * ('a -> 'b t) -> 'b list t
    | List_concat_map : 'a list * ('a -> 'b list t) -> 'b list t

  let return x = Return x

  let map : type a b. a t -> f:(a -> b) -> b t =
    fun t ~f ->
    match t with
    | Of_memo memo -> Map_memo (memo, f)
    | Map_memo (memo, f1) -> Map_memo2 (memo, f1, f)
    | Map_memo2 (memo, f1, f2) -> Map_memo3 (memo, f1, f2, f)
    | Bind_memo (memo, f1) -> Bind_memo_map (memo, f1, f)
    | Map (t, f1) -> Map2 (t, f1, f)
    | Map2 (t, f1, f2) -> Map3 (t, f1, f2, f)
    | Bind (t, f1) -> Bind_map (t, f1, f)
    | t -> Map (t, f)
  ;;

  let bind : type a b. a t -> f:(a -> b t) -> b t =
    fun t ~f ->
    match t with
    | Of_memo memo -> Bind_memo (memo, f)
    | Bind_memo (memo, f1) -> Bind_memo2 (memo, f1, f)
    | Bind_memo2 (memo, f1, f2) -> Bind_memo3 (memo, f1, f2, f)
    | Bind (t, f1) -> Bind2 (t, f1, f)
    | Bind2 (t, f1, f2) -> Bind3 (t, f1, f2, f)
    | Map (t, f1) -> Map_bind (t, f1, f)
    | t -> Bind (t, f)
  ;;

  let both x y = Both (x, y)
  let all xs = All xs
  let all_unit xs = All_unit xs
  let of_memo memo = Of_memo memo
  let record res deps ~f = Record { res; deps; f }
  let record_success memo = Record_success memo
  let exec_memo m i = Exec_memo (m, i)
  let goal t = Goal t

  module O = struct
    let ( >>> ) a b = Seq (a, b)
    let ( >>= ) t f = bind t ~f
    let ( >>| ) t f = map t ~f
    let ( and+ ) = both
    let ( and* ) = both
    let ( let+ ) t f = map t ~f
    let ( let* ) t f = bind t ~f
  end
end

include T

(* A failure in a [Memo.t] run by the builder can hide deps: it may have been
   building one, as a [%{read:...}] does. *)
let watch_memo : type a m. m eval_mode -> a Memo.t -> a Memo.t =
  fun mode memo ->
  match mode with
  | Lazy | Eager -> memo
  | Eager_reaching reached ->
    Fiber.with_error_handler
      (fun () -> Memo.run memo)
      ~on_error:(fun exn ->
        reached.hidden <- true;
        Exn_with_backtrace.reraise exn)
    |> Memo.of_reproducible_fiber
;;

let reach_memoized (reached : Reached.t) (node : 'a reaching Memo.t) =
  let open Memo.O in
  let* { result; reached = node_reached } = watch_memo (Eager_reaching reached) node in
  match result with
  | Ok ((_, facts) as res) ->
    Reached.add reached (Dep.Set.of_keys facts);
    Memo.return res
  | Error exns ->
    (match node_reached with
     | Some deps -> Reached.add reached deps
     | None -> reached.hidden <- true);
    Memo.of_reproducible_fiber (Fiber.reraise_all exns)
;;

let force_memoized : type a m. m eval_mode -> a memoized -> (a * m) Memo.t =
  fun mode { lazy_; eager; reaching } ->
  match mode with
  | Lazy -> Memo.Lazy.force (Lazy.force lazy_)
  | Eager -> Memo.Lazy.force eager
  | Eager_reaching reached ->
    reach_memoized reached (Memo.Lazy.force (Lazy.force reaching))
;;

let rec eval : type a m. a t -> m eval_mode -> (a * m) Memo.t =
  fun t mode ->
  match t with
  | Return x -> Memo.return (Deps_or_facts.return x mode)
  | Map (t, f) ->
    let open Memo.O in
    let+ x, deps = eval t mode in
    f x, deps
  | Map2 (t, f1, f2) ->
    let open Memo.O in
    let+ x, deps = eval t mode in
    f2 (f1 x), deps
  | Map3 (t, f1, f2, f3) ->
    let open Memo.O in
    let+ x, deps = eval t mode in
    f3 (f2 (f1 x)), deps
  | Bind (t, f) ->
    let open Memo.O in
    let* x, deps1 = eval t mode in
    let+ y, deps2 = eval (f x) mode in
    y, Deps_or_facts.union mode deps1 deps2
  | Bind2 (t, f1, f2) ->
    let open Memo.O in
    let* x, deps1 = eval t mode in
    let* y, deps2 = eval (f1 x) mode in
    let+ z, deps3 = eval (f2 y) mode in
    let deps = Deps_or_facts.union mode deps1 deps2 in
    z, Deps_or_facts.union mode deps deps3
  | Bind3 (t, f1, f2, f3) ->
    let open Memo.O in
    let* x, deps1 = eval t mode in
    let* y, deps2 = eval (f1 x) mode in
    let* z, deps3 = eval (f2 y) mode in
    let+ res, deps4 = eval (f3 z) mode in
    let deps = Deps_or_facts.union mode deps1 deps2 in
    let deps = Deps_or_facts.union mode deps deps3 in
    res, Deps_or_facts.union mode deps deps4
  | Map_bind (t, f1, f2) ->
    let open Memo.O in
    let* x, deps1 = eval t mode in
    let+ y, deps2 = eval (f2 (f1 x)) mode in
    y, Deps_or_facts.union mode deps1 deps2
  | Bind_map (t, f1, f2) ->
    let open Memo.O in
    let* x, deps1 = eval t mode in
    let+ y, deps2 = eval (f1 x) mode in
    f2 y, Deps_or_facts.union mode deps1 deps2
  | Both (a, b) ->
    let open Memo.O in
    let+ (a, deps_a), (b, deps_b) =
      Memo.fork_and_join (fun () -> eval a mode) (fun () -> eval b mode)
    in
    (a, b), Deps_or_facts.union mode deps_a deps_b
  | Seq (a, b) ->
    let open Memo.O in
    let+ ((), deps_a), (b, deps_b) =
      Memo.fork_and_join (fun () -> eval a mode) (fun () -> eval b mode)
    in
    b, Deps_or_facts.union mode deps_a deps_b
  | All ts ->
    let open Memo.O in
    let+ res = Memo.parallel_map ts ~f:(fun t -> eval t mode) in
    let res, deps = List.split res in
    res, Deps_or_facts.union_all mode deps
  | All_unit ts ->
    let open Memo.O in
    let+ deps =
      Memo.map_reduce
        ts
        ~f:(fun t ->
          let+ (), deps = eval t mode in
          deps)
        ~empty:(Deps_or_facts.empty mode)
        ~combine:(Deps_or_facts.union mode)
    in
    (), deps
  | Of_memo memo ->
    let open Memo.O in
    let+ x = watch_memo mode memo in
    x, Deps_or_facts.empty mode
  | Map_memo (memo, f) ->
    let open Memo.O in
    let+ x = watch_memo mode memo in
    Deps_or_facts.return (f x) mode
  | Map_memo2 (memo, f1, f2) ->
    let open Memo.O in
    let+ x = watch_memo mode memo in
    Deps_or_facts.return (f2 (f1 x)) mode
  | Map_memo3 (memo, f1, f2, f3) ->
    let open Memo.O in
    let+ x = watch_memo mode memo in
    Deps_or_facts.return (f3 (f2 (f1 x))) mode
  | Bind_memo (memo, f) ->
    let open Memo.O in
    let* x = watch_memo mode memo in
    eval (f x) mode
  | Bind_memo2 (memo, f1, f2) ->
    let open Memo.O in
    let* x = watch_memo mode memo in
    let* y, deps1 = eval (f1 x) mode in
    let+ z, deps2 = eval (f2 y) mode in
    z, Deps_or_facts.union mode deps1 deps2
  | Bind_memo3 (memo, f1, f2, f3) ->
    let open Memo.O in
    let* x = watch_memo mode memo in
    let* y, deps1 = eval (f1 x) mode in
    let* z, deps2 = eval (f2 y) mode in
    let+ result, deps3 = eval (f3 z) mode in
    let deps = Deps_or_facts.union mode deps1 deps2 in
    result, Deps_or_facts.union mode deps deps3
  | Bind_memo_map (memo, f1, f2) ->
    let open Memo.O in
    let* x = watch_memo mode memo in
    let+ y, deps = eval (f1 x) mode in
    f2 y, deps
  | Record { res; deps; f } ->
    (match mode with
     | Lazy -> Memo.return (res, deps)
     | Eager ->
       let open Memo.O in
       let+ facts = Dep.Facts.record_facts deps ~f in
       res, facts
     | Eager_reaching reached ->
       Reached.add reached deps;
       let open Memo.O in
       let+ facts = Dep.Facts.record_facts deps ~f in
       res, facts)
  | Record_success memo ->
    (match mode with
     | Lazy -> Memo.return ((), Dep.Set.empty)
     | Eager | Eager_reaching _ ->
       let open Memo.O in
       let+ () = memo in
       Deps_or_facts.return () mode)
  | Memoize memoized -> force_memoized mode memoized
  | Goal t ->
    (* A goal's deps are not the builder's, so they are not reached. *)
    let open Memo.O in
    (match mode with
     | Lazy | Eager ->
       let+ a, _ = eval t mode in
       a, Deps_or_facts.empty mode
     | Eager_reaching _ ->
       let+ a, _ = eval t Eager in
       a, Dep.Facts.empty)
  | Exec_memo (m, i) -> exec_memo_eval m i mode
  | Push_stack_frame (human_readable_description, f) ->
    Memo.push_stack_frame ~human_readable_description (fun () -> eval (f ()) mode)
  | List_map (l, f) ->
    let open Memo.O in
    let+ res = Memo.parallel_map l ~f:(fun x -> eval (f x) mode) in
    let res, deps = List.split res in
    res, Deps_or_facts.union_all mode deps
  | List_concat_map (l, f) ->
    let open Memo.O in
    let+ res = Memo.parallel_map l ~f:(fun x -> eval (f x) mode) in
    let res, deps = List.split res in
    List.concat res, Deps_or_facts.union_all mode deps

and exec_memo_eval : type i o m. (i, o) memo -> i -> m eval_mode -> (o * m) Memo.t =
  fun memo i mode ->
  match mode with
  | Lazy -> Memo.exec (Lazy.force memo.lazy_) i
  | Eager -> Memo.exec (Lazy.force memo.eager) i
  | Eager_reaching reached ->
    reach_memoized reached (Memo.exec (Lazy.force memo.reaching) i)
;;

(* Errors are kept as a value only if Memo may cache them: a node holding a
   non-reproducible error must be recomputed, and one that saw a cycle has
   inaccurate deps. Errors from inner nodes arrive without their
   [Non_reproducible] marker, but those nodes always count as changed, so this
   one is recomputed with them. *)
let eval_reaching t =
  let reached = Reached.create () in
  reached.started <- true;
  let open Fiber.O in
  Fiber.collect_errors (fun () -> Memo.run (eval t (Eager_reaching reached)))
  >>= (function
   | Ok res -> Fiber.return { result = Ok res; reached = None }
   | Error exns ->
     (match
        List.exists exns ~f:(fun { Exn_with_backtrace.exn; backtrace = _ } ->
          match exn with
          | Memo.Non_reproducible _ | Memo.Cycle_error.E _ -> true
          | _ -> false)
      with
      | true -> Fiber.reraise_all exns
      | false -> Fiber.return { result = Error exns; reached = Reached.deps reached }))
  |> Memo.of_reproducible_fiber
;;

let memoize ?cutoff name t =
  let lazy_ =
    lazy
      (let cutoff =
         Option.map cutoff ~f:(fun equal x y -> Tuple.T2.equal equal Dep.Set.equal x y)
       in
       Memo.lazy_ ?cutoff ~name:(name ^ "(lazy)") (fun () -> eval t Lazy))
  in
  let eager =
    let cutoff =
      Option.map cutoff ~f:(fun equal x y -> Tuple.T2.equal equal Dep.Facts.equal x y)
    in
    Memo.lazy_ ?cutoff ~name:(name ^ "(eager)") (fun () -> eval t Eager)
  in
  let reaching =
    lazy (Memo.lazy_ ~name:(name ^ "(reaching)") (fun () -> eval_reaching t))
  in
  Memoize { lazy_; eager; reaching }
;;

module Monad_instance = struct
  module List = struct
    include Monad.List (T)

    let map l ~f = List_map (l, f)
    let concat_map l ~f = List_concat_map (l, f)
  end
end

module List = Monad_instance.List

open struct
  module List = Stdune.List
end

let evaluate_and_collect_deps t = eval t Lazy
let evaluate_and_collect_facts t = eval t Eager

let evaluate_and_collect_facts_reaching reached t =
  match reached with
  | None -> eval t Eager
  | Some (reached : Reached.t) ->
    reached.started <- true;
    eval t (Eager_reaching reached)
;;

let create_memo name ~input ?cutoff ?human_readable_description f =
  let human_readable_description =
    Option.map human_readable_description ~f:(fun f x -> Some (f x))
  in
  let lazy_ =
    lazy
      (let cutoff =
         Option.map cutoff ~f:(fun f (a, deps1) (b, deps2) ->
           f a b && Dep.Set.equal deps1 deps2)
       in
       let name = name ^ "(lazy)" in
       Memo.create name ~input ?cutoff ?human_readable_description (fun x ->
         eval (f x) Lazy))
  and eager =
    lazy
      (let cutoff =
         Option.map cutoff ~f:(fun f (a, facts1) (b, facts2) ->
           f a b && Dep.Facts.equal facts1 facts2)
       in
       Memo.create name ~input ?cutoff ?human_readable_description (fun x ->
         eval (f x) Eager))
  and reaching =
    lazy
      (Memo.create (name ^ "(reaching)") ~input ?human_readable_description (fun x ->
         eval_reaching (f x)))
  in
  { lazy_; eager; reaching }
;;

let push_stack_frame ~human_readable_description f =
  Push_stack_frame (human_readable_description, f)
;;

module Expert = struct
  let record_dep_on_source_file_exn res ~loc (src_path : Path.Source.t) =
    let path : Path.t = Path.source src_path in
    let dep = Dep.file path in
    let f _ =
      let open Memo.O in
      let+ digest =
        Fs_memo.file_digest_exn ~loc (Path.Outside_build_dir.In_source_dir src_path)
      in
      Dep.Fact.file path digest
    in
    record res (Dep.Set.singleton dep) ~f
  ;;
end
