Tracing the build graph must not change what a watch-mode rebuild
re-evaluates. A comment-only edit to a.ml reruns ocamldep and rebuilds A's
objects, but they come out the same, so main.exe is not relinked: its
memoized builders (e.g. the link order of its modules) are recomputed, find
their value unchanged, and cut off before reaching the link rule.

  $ make_dune_project 3.21
  $ cat >dune <<EOF
  > (library (name lib) (modules lib))
  > (executable (name main) (modules main a) (libraries lib))
  > EOF
  $ echo 'let x = 1' > lib.ml
  $ echo 'let y = Lib.x' > a.ml
  $ echo 'let () = print_int A.y' > main.ml

  $ DUNE_TRACE=+graph start_dune
  $ build ./main.exe
  Success
  $ echo 'let y = Lib.x (* edit *)' > a.ml
  $ build ./main.exe
  Success
  $ with_timeout dune shutdown

How many times each rule was executed across the two builds:

  $ dune trace cat | jq -sr '
  >   (reduce (.[] | select(.name == "intern") | .args.entries[]) as $e
  >     ({}; .[$e.id | tostring] = $e.value)) as $names
  >   | [ .[] | select(.name == "exec-rule" and .async_phase == "begin")
  >       | $names[(.args.target_files + .args.target_dirs)[0] | tostring]
  >       | select(test("A\\.cm|main\\.exe")) ]
  >   | group_by(.) | map("\(.[0]) \(length)")[]
  > '
  dune__exe__A.cmi 2
  dune__exe__A.cmx 2
  main.exe 2
