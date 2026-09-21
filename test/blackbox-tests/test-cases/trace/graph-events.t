The "graph" trace category records the build graph dune walks: which rules
ran, what forced them, what each depended on. It is opt-in: it is not one of
the categories enabled by default, so it has to be asked for with
DUNE_TRACE=+graph.

Rule execution is recorded as a Chrome async span keyed by a generated id: an
"exec-rule" async begin (carrying the rule's target directory "dir" and the
bare names of its "target_files" and "target_dirs" within it) and a matching
"exec-rule" async end bracket each execution. Both share the span's
"async_id" and are told apart by their "async_phase", and both carry the
"rule_id". The end event carries the execution outcome and the resolved
"deps".

An executed rule additionally wraps the execution of its action proper in an
"exec-rule-action" begin/end pair. It shares the rule's "async_id", nesting
inside the rule's span, and also carries the "rule_id"; the two spans are
told apart by their name. Cache hits execute no action and so have no such
span.

Building a single dependency is an async "build-dep" span, rule generation
for a directory a "gen-rules" span, and the processing of a dune file's
dynamic includes a "dynamic-includes" span.

Targets and dependencies are rendered to strings and interned to integer ids:
the first time some are seen an "intern" event records their id -> value
mappings, and the other events refer to them by id thereafter. A rule's
"dir" is a single interned id; "target_files" and "target_dirs" are lists of
interned ids, one per bare name.

  $ make_directory_targets_project 3.21

  $ touch foo.src bar.src

  $ cat >dune <<EOF
  > (rule
  >  (target dep.txt)
  >  (action (with-stdout-to dep.txt (echo "hi"))))
  > (alias
  >  (name my-alias)
  >  (deps foo.src bar.src))
  > (rule
  >  (target out.txt)
  >  (deps dep.txt (alias my-alias))
  >  (action (with-stdout-to out.txt (cat dep.txt))))
  > (rule
  >  (target globbed.txt)
  >  (deps (glob_files *.src))
  >  (action (with-stdout-to globbed.txt (echo "globbed"))))
  > (rule
  >  (targets (dir a-dir))
  >  (action (bash "mkdir a-dir && echo hi > a-dir/f")))
  > EOF

  $ mkdir a b
  $ cat >a/dune <<EOF
  > (rule
  >  (with-stdout-to dune.inc
  >   (echo "(rule (with-stdout-to dyn.txt (echo dynamic)))")))
  > EOF
  $ cat >b/dune <<EOF
  > (dynamic_include ../a/dune.inc)
  > EOF

A build with the default categories emits nothing in the "graph" category:

  $ dune build out.txt a-dir globbed.txt b/dyn.txt
  $ dune trace cat | jq -sr '[ .[] | select(.cat == "graph") ] | length'
  0

Asking for the category turns it on. The whole build is re-run in a fresh
directory so that every rule executes:

  $ rm -rf _build
  $ DUNE_TRACE=+graph dune build out.txt a-dir globbed.txt b/dyn.txt

These are the event kinds the category emits:

  $ dune trace cat | jq -r 'select(.cat == "graph") | .name' | sort -u
  build-dep
  dynamic-includes
  exec-rule
  exec-rule-action
  gen-rules
  intern

Every exec-rule event shares its rule's async id, and so does the rule's
exec-rule-action pair; grouping by name and id, each span has exactly one
begin and one end:

  $ dune trace cat | jq -sr '
  >   [ .[] | select(.cat == "graph" and (.name | startswith("exec-"))) ]
  >   | group_by([ .name, .async_id ])
  >   | map(([ .[] | select(.async_phase == "begin") ] | length) == 1
  >         and ([ .[] | select(.async_phase == "end") ] | length) == 1)
  >   | all
  > '
  true

The same holds for the other three span kinds:

  $ dune trace cat | jq -sr '
  >   [ .[] | select(.name == "build-dep" or .name == "gen-rules"
  >                  or .name == "dynamic-includes") ]
  >   | group_by([ .name, .async_id ])
  >   | map(([ .[] | select(.async_phase == "begin") ] | length) == 1
  >         and ([ .[] | select(.async_phase == "end") ] | length) == 1)
  >   | all
  > '
  true

Every exec-rule-action span belongs to an exec-rule span: same async_id, same
rule_id:

  $ dune trace cat | jq -sr '
  >   ([ .[] | select(.name == "exec-rule" and .async_phase == "begin")
  >      | { id: .async_id, rule: .args.rule_id } ]) as $rules
  >   | [ .[] | select(.name == "exec-rule-action" and .async_phase == "begin")
  >       | { id: .async_id, rule: .args.rule_id } ]
  >   | all(. as $a | $rules | index($a) != null)
  > '
  true

All rules in this fresh build executed their action, so there are exactly as
many action spans as executed rules:

  $ dune trace cat | jq -sr '
  >   ([ .[] | select(.name == "exec-rule" and .args.rule_outcome == "executed") ]
  >    | length)
  >   == ([ .[] | select(.name == "exec-rule-action" and .async_phase == "begin") ]
  >       | length)
  > '
  true

Each target and dependency is interned exactly once (ids are not re-emitted):

  $ dune trace cat | jq -sr '
  >   [ .[] | select(.name == "intern") | .args.entries[].id ]
  >   | length == (unique | length)
  > '
  true

Resolving the "dir" and "target_files" ids of the rule that produces out.txt
against the intern table and joining them back together gives its target
path:

  $ dune trace cat | jq -sr '
  >   (reduce (.[] | select(.name == "intern") | .args.entries[]) as $e
  >     ({}; .[$e.id | tostring] = $e.value)) as $names
  >   | [ .[] | select(.name == "exec-rule" and .async_phase == "begin")
  >       | ($names[.args.dir | tostring]) as $dir
  >       | { rule: .async_id
  >         , paths: [ (.args.target_files // [])[]
  >                    | $dir + "/" + $names[tostring] ] } ]
  >   | map(select(.paths | any(endswith("out.txt")))) | .[0].paths
  > '
  [
    "_build/default/out.txt"
  ]

The rule producing the directory target "a-dir" carries it under
"target_dirs" instead, alongside the same "dir":

  $ dune trace cat | jq -sr '
  >   (reduce (.[] | select(.name == "intern") | .args.entries[]) as $e
  >     ({}; .[$e.id | tostring] = $e.value)) as $names
  >   | [ .[] | select(.name == "exec-rule" and .async_phase == "begin")
  >       | ($names[.args.dir | tostring]) as $dir
  >       | { rule: .async_id
  >         , paths: [ (.args.target_dirs // [])[]
  >                    | $dir + "/" + $names[tostring] ] } ]
  >   | map(select(.paths | any(endswith("a-dir")))) | .[0].paths
  > '
  [
    "_build/default/a-dir"
  ]

The end event carries the outcome along with the deps, so we find the begin
event producing out.txt, take its id, and read the outcome and the deps off
the end event sharing that id. Each dep is rendered as a string: a file as
its path and an alias as "dir@name".

  $ dune trace cat | jq -sc '
  >   (reduce (.[] | select(.name == "intern") | .args.entries[]) as $e
  >     ({}; .[$e.id | tostring] = $e.value)) as $names
  >   | ([ .[] | select(.name == "exec-rule" and .async_phase == "begin")
  >        | ($names[.args.dir | tostring]) as $dir
  >        | select([ (.args.target_files // [])[] | $dir + "/" + $names[tostring] ]
  >                 | any(endswith("/out.txt")))
  >        | .async_id ][0]) as $span
  >   | [ .[] | select(.name == "exec-rule" and .async_phase == "end"
  >                    and .async_id == $span)
  >       | { outcome: .args.rule_outcome
  >         , deps: [ .args.deps[] | $names[tostring] ] | sort } ][0]
  > '
  {"outcome":"executed","deps":["_build/default/dep.txt","_build/default@my-alias"]}

The forcer of a span is recorded on its begin event as "forced_by". A rule is
forced by the dep on one of its targets, and the deps it builds are forced by
the rule. So the exec-rule span for dep.txt is forced by the dep on
"_build/default/dep.txt":

  $ dune trace cat | jq -sc '
  >   (reduce (.[] | select(.name == "intern") | .args.entries[]) as $e
  >     ({}; .[$e.id | tostring] = $e.value)) as $names
  >   | [ .[] | select(.name == "exec-rule" and .async_phase == "begin")
  >       | ($names[.args.dir | tostring]) as $dir
  >       | select([ (.args.target_files // [])[] | $dir + "/" + $names[tostring] ]
  >                 | any(endswith("/dep.txt")))
  >       | [ .args.forced_by[0], $names[.args.forced_by[1] | tostring] ] ]
  > '
  [["dep","_build/default/dep.txt"]]

Conversely the single build-dep span for "_build/default/dep.txt" -- dep.txt
is a dep of out.txt and of nothing else -- is forced by the rule that
produces out.txt. Rule ids are allocation order and so not stable, hence the
join against the exec-rule events rather than a literal id:

  $ dune trace cat | jq -sc '
  >   (reduce (.[] | select(.name == "intern") | .args.entries[]) as $e
  >     ({}; .[$e.id | tostring] = $e.value)) as $names
  >   | (reduce (.[] | select(.name == "exec-rule" and .async_phase == "begin")) as $r
  >       ({}; .[($names[$r.args.dir | tostring])
  >             + "/"
  >             + ($names[($r.args.target_files // [])[0] | tostring])]
  >            = $r.args.rule_id)) as $rule_of
  >   | [ .[] | select(.name == "build-dep" and .async_phase == "begin")
  >       | select($names[.args.dep | tostring] == "_build/default/dep.txt")
  >       | .args.forced_by == [ "rule", $rule_of["_build/default/out.txt"] ] ]
  > '
  [true]

and it resolves to the rule that produces dep.txt:

  $ dune trace cat | jq -sc '
  >   (reduce (.[] | select(.name == "intern") | .args.entries[]) as $e
  >     ({}; .[$e.id | tostring] = $e.value)) as $names
  >   | (reduce (.[] | select(.name == "exec-rule" and .async_phase == "begin")) as $r
  >       ({}; .[($names[$r.args.dir | tostring])
  >             + "/"
  >             + ($names[($r.args.target_files // [])[0] | tostring])]
  >            = $r.args.rule_id)) as $rule_of
  >   | ([ .[] | select(.name == "build-dep" and .async_phase == "begin")
  >        | select($names[.args.dep | tostring] == "_build/default/dep.txt")
  >        | .async_id ][0]) as $span
  >   | [ .[] | select(.name == "build-dep" and .async_phase == "end"
  >                    and .async_id == $span)
  >       | .args.dep_resolution == [ "rule", $rule_of["_build/default/dep.txt"] ] ]
  > '
  [true]

Every dep in this project either has a rule or expands to a set of paths, so
those are the only two resolutions seen here. (A file with no rule at all
resolves to "is-source"; files in the source tree do not qualify, as dune
gives each of them a rule that copies it into the build directory.)

  $ dune trace cat | jq -sc '
  >   [ .[] | select(.name == "build-dep" and .async_phase == "end")
  >       | .args.dep_resolution[0] ] | unique
  > '
  ["expanded","rule"]

An alias dep resolves to the set of deps the alias expanded to, and a glob
dep to the files it matched. Both are reported as "expanded" followed by the
interned ids of the paths:

  $ dune trace cat | jq -sc '
  >   (reduce (.[] | select(.name == "intern") | .args.entries[]) as $e
  >     ({}; .[$e.id | tostring] = $e.value)) as $names
  >   | ([ .[] | select(.name == "build-dep" and .async_phase == "begin")
  >        | select($names[.args.dep | tostring] == "_build/default@my-alias")
  >        | .async_id ][0]) as $span
  >   | [ .[] | select(.name == "build-dep" and .async_phase == "end"
  >                    and .async_id == $span)
  >       | .args.dep_resolution | .[1:] | map($names[tostring]) | sort ][0]
  > '
  ["_build/default/bar.src","_build/default/foo.src"]

A glob dep is rendered as its directory followed by the predicate in the
predicate language's own syntax, so the string reads back the way the glob
was written in the dune file. Selecting the span by that exact string is
what pins the rendering:

  $ dune trace cat | jq -sc '
  >   (reduce (.[] | select(.name == "intern") | .args.entries[]) as $e
  >     ({}; .[$e.id | tostring] = $e.value)) as $names
  >   | ([ .[] | select(.name == "build-dep" and .async_phase == "begin")
  >        | select($names[.args.dep | tostring] == "_build/default/*.src")
  >        | .async_id ][0]) as $span
  >   | [ .[] | select(.name == "build-dep" and .async_phase == "end"
  >                    and .async_id == $span)
  >       | .args.dep_resolution | .[1:] | map($names[tostring]) | sort ][0]
  > '
  ["_build/default/bar.src","_build/default/foo.src"]

Both ends of a "gen-rules" span carry the directory as an interned "dir" id,
so either event on its own says which directory it belongs to. The end event
additionally carries the interned "dune_file" that drove the directory, when
there is one:

  $ dune trace cat | jq -sr '
  >   [ .[] | select(.name == "gen-rules") ] | all(.args.dir != null)
  > '
  true

  $ dune trace cat | jq -sc '
  >   (reduce (.[] | select(.name == "intern") | .args.entries[]) as $e
  >     ({}; .[$e.id | tostring] = $e.value)) as $names
  >   | [ .[] | select(.name == "gen-rules" and .async_phase == "end")
  >       | select($names[.args.dir | tostring] == "_build/default")
  >       | $names[.args.dune_file | tostring] ]
  > '
  ["dune"]

A "dynamic-includes" span carries the dune file whose dynamic includes are
being processed on both of its ends:

  $ dune trace cat | jq -sc '
  >   (reduce (.[] | select(.name == "intern") | .args.entries[]) as $e
  >     ({}; .[$e.id | tostring] = $e.value)) as $names
  >   | [ .[] | select(.name == "dynamic-includes")
  >       | { phase: .async_phase, file: $names[.args.dune_file | tostring] } ]
  > '
  [{"phase":"begin","file":"b/dune"},{"phase":"end","file":"b/dune"}]

A rebuild with nothing changed resolves every rule from the workspace-local
cache: exec-rule spans are still emitted, with cache-hit outcomes, but no
action runs, so there are no exec-rule-action events at all:

  $ DUNE_TRACE=+graph dune build out.txt a-dir globbed.txt b/dyn.txt

  $ dune trace cat | jq -sr '
  >   [ .[] | select(.name == "exec-rule" and .async_phase == "end") ]
  >   | (length > 0) and all(.args.rule_outcome == "local-cache-hit")
  > '
  true
  $ dune trace cat | jq -sr '[ .[] | select(.name == "exec-rule-action") ] | length'
  0

Not every build is forced by a rule or a dep. Three scopes name work that
the engine cannot attribute on its own: the top-level request for a goal,
the forcing of the configurator files, and a pform expanded at
rule-generation time, which builds whatever it reads without recording a
dependency on it. The last is named after the dune file the pform was
written in.

  $ mkdir p q
  $ cat >p/dune <<EOF
  > (rule
  >  (target name.txt)
  >  (action (with-stdout-to name.txt (echo "made"))))
  > EOF
  $ cat >q/dune <<EOF
  > (rule
  >  (targets %{read:../p/name.txt})
  >  (action (with-stdout-to %{read:../p/name.txt} (echo "hi"))))
  > EOF

  $ rm -rf _build
  $ DUNE_TRACE=+graph dune build q/made

  $ dune trace cat | jq -sc '
  >   (reduce (.[] | select(.name == "intern") | .args.entries[]) as $e
  >     ({}; .[$e.id | tostring] = $e.value)) as $names
  >   | [ .[] | select(.name == "build-dep" and .async_phase == "begin")
  >       | { dep: $names[.args.dep | tostring]
  >         , by: [ .args.forced_by[0], $names[.args.forced_by[1] | tostring] ] } ]
  >   | sort_by(.dep) | .[]
  > '
  {"dep":"_build/default/.dune/configurator","by":["configurator",null]}
  {"dep":"_build/default/.dune/configurator.v2","by":["configurator",null]}
  {"dep":"_build/default/p/name.txt","by":["pform","q/dune"]}
  {"dep":"_build/default/q/made","by":["request",null]}
