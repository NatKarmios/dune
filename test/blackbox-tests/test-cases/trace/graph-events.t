Dune emits graph events around rule execution as a Chrome async span keyed by a
generated id: an "exec-rule" async begin (carrying the rule's targets) and a
matching "exec-rule" async end bracket each execution. Both share the span's
"async_id" and are told apart by their "async_phase", and both carry the
"rule_id". The end event carries the execution outcome, the resolved "deps", and
the "dyn_deps" (one dep list per dynamic-deps stage).

Targets and dependencies are rendered to strings and interned to integer ids:
the first time some are seen an "intern" event records their id -> value
mappings, and the other events refer to them by id thereafter.

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
  build-dep
  exec-rule
  gen-rules-dir
  gen-rules-dune-file
  intern

Every exec-rule event shares its rule's async id, with exactly one begin and one
end:

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
  >   [ .[] | select(.name == "intern") | .args.entries[].id ]
  >   | length == (unique | length)
  > '
  true

Resolving the target ids of the rule that produces out.txt against the intern
table gives back its target path:

  $ dune trace cat | jq -sr '
  >   (reduce (.[] | select(.name == "intern") | .args.entries[]) as $e
  >     ({}; .[$e.id | tostring] = $e.value)) as $names
  >   | [ .[] | select(.name == "exec-rule" and .async_phase == "begin")
  >       | { rule: .async_id, paths: [ (.args.targets // [])[] | $names[tostring] ] } ]
  >   | map(select(.paths | any(endswith("out.txt")))) | .[0].paths
  > '
  [
    "_build/default/out.txt"
  ]

The end event carries the outcome (along with the deps and dyn_deps), so we find
the begin event producing out.txt, take its id, and read the outcome off the end
event sharing that id:

  $ dune trace cat | jq -sr '
  >   (reduce (.[] | select(.name == "intern") | .args.entries[]) as $e
  >     ({}; .[$e.id | tostring] = $e.value)) as $names
  >   | ([ .[] | select(.name == "exec-rule" and .async_phase == "begin")
  >        | select([ (.args.targets // [])[] | $names[tostring] ] | any(endswith("out.txt")))
  >        | .async_id ][0]) as $rule
  >   | [ .[] | select(.name == "exec-rule" and .async_phase == "end" and .async_id == $rule)
  >       | .args.rule_outcome ][0]
  > '
  executed

Resolving that rule's dep ids against the intern table gives back its
dependencies, each rendered as a string: a file as its path, an alias as
"dir@name", and a glob (file selector) as "dir/<predicate>". The glob is a
single entry, not expanded into the files it matches:

  $ dune trace cat | jq -sc '
  >   (reduce (.[] | select(.name == "intern") | .args.entries[]) as $e
  >     ({}; .[$e.id | tostring] = $e.value)) as $names
  >   | ([ .[] | select(.name == "exec-rule" and .async_phase == "begin")
  >        | select([ (.args.targets // [])[] | $names[tostring] ] | any(endswith("out.txt")))
  >        | .async_id ][0]) as $rule
  >   | [ .[] | select(.name == "exec-rule" and .async_phase == "end" and .async_id == $rule)
  >       | .args.deps[] | $names[tostring] ]
  > '
  ["_build/default/dep.txt","_build/default@my-alias","_build/default/*.src"]
