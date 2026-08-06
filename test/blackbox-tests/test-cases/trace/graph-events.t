Dune emits graph events around rule execution as a Chrome async span keyed by a
generated id: an "exec-rule" async begin (carrying the rule's targets) and a
matching "exec-rule" async end (carrying the execution outcome) bracket each
execution. Both share the span's "async_id" and are told apart by their
"async_phase".

Within that span, async-instant events (sharing the same "async_id", and also
carrying the "rule_id") mark the two phases of execution: "exec-rule-deps-start"
/ "exec-rule-deps-finish" around dependency resolution (the finish carrying the
resolved "deps"), and "exec-rule-action-start" / "exec-rule-action-finish"
around running the action (the finish carrying the "dyn_deps", one dep list per
dynamic-deps stage).

Targets and dependencies are interned to integer ids: the first time some are
seen an "intern-targets" / "intern-deps" event records their id -> value
mappings, and the exec events refer to them by id thereafter.

  $ make_dune_project 3.21

  $ touch foo.src bar.src

  $ cat >dune <<EOF
  > (rule
  >  (target dep.txt)
  >  (action (with-stdout-to dep.txt (echo "hi"))))
  > (rule
  >  (alias my-alias)
  >  (action (progn)))
  > (rule
  >  (target out.txt)
  >  (deps dep.txt (glob_files *.src) (alias my-alias))
  >  (action (with-stdout-to out.txt (cat dep.txt))))
  > EOF

  $ DUNE_TRACE=+graph dune build out.txt

The category emits these event kinds (the "gen-rules-*" events span rule
generation for a directory and its dune file):

  $ dune trace cat | jq -r 'select(.cat == "graph") | .name' | sort -u
  exec-rule
  exec-rule-action-finish
  exec-rule-action-start
  exec-rule-deps-finish
  exec-rule-deps-start
  gen-rules-dir
  gen-rules-dune-file
  intern-deps
  intern-targets

Every exec-rule event shares its rule's async id: the "exec-rule" begin/end
bracket the async-instant phase markers (deps-start/finish, and action-start/
finish for rules that run an action). Each async id has exactly one begin and
one end:

  $ dune trace cat | jq -sr '
  >   [ .[] | select(.cat == "graph" and (.name | startswith("exec-"))) ]
  >   | group_by(.async_id)
  >   | map(([ .[] | select(.async_phase == "begin") ] | length) == 1
  >         and ([ .[] | select(.async_phase == "end") ] | length) == 1)
  >   | all
  > '
  true

Each target and dependency is interned exactly once (ids are not re-emitted):

  $ dune trace cat | jq -sr '
  >   def unique_ids($name; $field):
  >     [ .[] | select(.name == $name) | .args[$field][].id ]
  >     | length == (unique | length);
  >   unique_ids("intern-targets"; "targets") and unique_ids("intern-deps"; "deps")
  > '
  true

Resolving the target ids of the rule that produces out.txt against the
intern-targets table gives back its target path:

  $ dune trace cat | jq -sr '
  >   (reduce (.[] | select(.name == "intern-targets") | .args.targets[]) as $e
  >     ({}; .[$e.id | tostring] = $e.path)) as $targets
  >   | [ .[] | select(.name == "exec-rule" and .async_phase == "begin")
  >       | { rule: .async_id, paths: [ (.args.target_files // [])[] | $targets[tostring] ] } ]
  >   | map(select(.paths | any(endswith("out.txt")))) | .[0].paths
  > '
  [
    "_build/default/out.txt"
  ]

The end event carries only the shared id and the outcome, so we find the begin
event producing out.txt, take its id, and read the outcome off the end event
sharing that id:

  $ dune trace cat | jq -sr '
  >   (reduce (.[] | select(.name == "intern-targets") | .args.targets[]) as $e
  >     ({}; .[$e.id | tostring] = $e.path)) as $targets
  >   | ([ .[] | select(.name == "exec-rule" and .async_phase == "begin")
  >        | select([ (.args.target_files // [])[] | $targets[tostring] ] | any(endswith("out.txt")))
  >        | .async_id ][0]) as $rule
  >   | [ .[] | select(.name == "exec-rule" and .async_phase == "end" and .async_id == $rule)
  >       | .args.outcome ][0]
  > '
  executed

Resolving that rule's dep ids against the intern-deps table gives back its
dependencies (rendered via [Dep.to_dyn]). The glob is a single "File_selector"
entry, not expanded into the files it matches:

  $ dune trace cat | jq -sc '
  >   (reduce (.[] | select(.name == "intern-targets") | .args.targets[]) as $e
  >     ({}; .[$e.id | tostring] = $e.path)) as $targets
  >   | (reduce (.[] | select(.name == "intern-deps") | .args.deps[]) as $e
  >     ({}; .[$e.id | tostring] = $e.dep)) as $deps
  >   | ([ .[] | select(.name == "exec-rule" and .async_phase == "begin")
  >        | select([ (.args.target_files // [])[] | $targets[tostring] ] | any(endswith("out.txt")))
  >        | .async_id ][0]) as $rule
  >   | [ .[] | select(.name == "exec-rule-deps-finish" and .async_id == $rule)
  >       | .args.deps[] | $deps[tostring] ]
  > '
  [["File",["In_build_dir","default/dep.txt"]],["Alias",{"dir":"default","name":"my-alias"}],["File_selector",{"dir":["In_build_dir","default"],"predicate":["Element",["Glob","*.src"]],"only_generated_files":false}]]
