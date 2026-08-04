Dune emits graph events around rule execution: an "exec-rule-start" (instant,
carrying the rule's targets) and "exec-rule-finish" (complete, carrying the
targets and the execution outcome) event bracketing each execution, and an
"exec-rule-deps" event listing the rule's dependencies.

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
  exec-rule-deps
  exec-rule-finish
  exec-rule-start
  gen-rules-dir-finish
  gen-rules-dir-start
  gen-rules-dune-file-finish
  gen-rules-dune-file-start
  intern-deps
  intern-targets

Every rule id emits exactly a start, a deps and a finish event (they share the
rule's id):

  $ dune trace cat | jq -sr '
  >   [ .[] | select(.cat == "graph" and (.name | startswith("exec-"))) ]
  >   | group_by(.args.id)
  >   | map(map(.name) | sort)
  >   | all(. == ["exec-rule-deps", "exec-rule-finish", "exec-rule-start"])
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
  >   | [ .[] | select(.name == "exec-rule-start")
  >       | { rule: .args.id, paths: [ (.args.target_files // [])[] | $targets[tostring] ] } ]
  >   | map(select(.paths | any(endswith("out.txt")))) | .[0].paths
  > '
  [
    "_build/default/out.txt"
  ]

That rule's finish event reports how the rule was run:

  $ dune trace cat | jq -sr '
  >   (reduce (.[] | select(.name == "intern-targets") | .args.targets[]) as $e
  >     ({}; .[$e.id | tostring] = $e.path)) as $targets
  >   | [ .[] | select(.name == "exec-rule-finish")
  >       | { paths: [ (.args.target_files // [])[] | $targets[tostring] ], outcome: .args.outcome } ]
  >   | map(select(.paths | any(endswith("out.txt")))) | .[0].outcome
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
  >   | ([ .[] | select(.name == "exec-rule-start")
  >        | select([ (.args.target_files // [])[] | $targets[tostring] ] | any(endswith("out.txt")))
  >        | .args.id ][0]) as $rule
  >   | [ .[] | select(.name == "exec-rule-deps" and .args.id == $rule)
  >       | .args.deps[] | $deps[tostring] ]
  > '
  [["File",["In_build_dir","default/dep.txt"]],["Alias",{"dir":"default","name":"my-alias"}],["File_selector",{"dir":["In_build_dir","default"],"predicate":["Element",["Glob","*.src"]],"only_generated_files":false}]]
