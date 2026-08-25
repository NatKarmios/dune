Dune closes a rule's "exec-rule" span even when the rule never completes, so a
failing build still produces a dependency graph rather than spans that never
end. The end event's outcome says how the rule ended: "dep-fail" for a failure
raised before the rule's dependencies were resolved, "action-fail" for one
raised after (i.e. in its action), and "cancelled" when the build was torn down
around the rule.

  $ make_directory_targets_project 3.21

Two rules: the one producing dep.txt fails in its action, and the one producing
out.txt therefore fails while building that dependency.

  $ cat >dune <<EOF
  > (rule
  >  (target dep.txt)
  >  (action (with-stdout-to dep.txt (bash "exit 1"))))
  > (rule
  >  (target out.txt)
  >  (deps dep.txt)
  >  (action (with-stdout-to out.txt (cat dep.txt))))
  > EOF

  $ DUNE_TRACE=+graph dune build out.txt
  File "dune", lines 1-3, characters 0-75:
  1 | (rule
  2 |  (target dep.txt)
  3 |  (action (with-stdout-to dep.txt (bash "exit 1"))))
  Command exited with code 1.
  [1]

Every exec-rule span still has exactly one begin and one end, even though no
rule completed:

  $ dune trace cat | jq -sr '
  >   [ .[] | select(.cat == "graph" and .name == "exec-rule") ]
  >   | group_by(.async_id)
  >   | map(([ .[] | select(.async_phase == "begin") ] | length) == 1
  >         and ([ .[] | select(.async_phase == "end") ] | length) == 1)
  >   | all
  > '
  true

The outcome of each rule, keyed by the target it produces:

  $ dune trace cat | jq -sr '
  >   (reduce (.[] | select(.name == "intern") | .args.entries[]) as $e
  >     ({}; .[$e.id | tostring] = $e.value)) as $names
  >   | (reduce (.[] | select(.name == "exec-rule" and .async_phase == "begin")) as $b
  >       ({}; .[$b.async_id | tostring] =
  >          ($names[$b.args.dir | tostring]) + "/"
  >          + $names[($b.args.target_files // [])[0] | tostring])) as $targets
  >   | [ .[] | select(.name == "exec-rule" and .async_phase == "end")
  >       | $targets[.async_id | tostring] + " " + .args.rule_outcome ]
  >   | sort[]
  > '
  _build/default/.dune/configurator executed
  _build/default/.dune/configurator.v2 executed
  _build/default/dep.txt action-fail
  _build/default/out.txt dep-fail

The rule that failed while building its dependencies still reports them: they
are recovered without building anything, so the graph records the edge that
caused the failure.

  $ dune trace cat | jq -sc '
  >   (reduce (.[] | select(.name == "intern") | .args.entries[]) as $e
  >     ({}; .[$e.id | tostring] = $e.value)) as $names
  >   | [ .[] | select(.name == "exec-rule" and .async_phase == "end"
  >                    and .args.rule_outcome == "dep-fail")
  >       | [ (.args.deps // [])[] | $names[tostring] ] ]
  > '
  [["_build/default/dep.txt"]]

A rule that is still running when the build is torn down around it reports
"cancelled" and no deps: the build is going away, so dune spends no work
recovering them. To get there without a race, the rule that fails waits for the
rule that will be cancelled to signal that it has started -- so the cancelled
rule's action is certainly running, and its span certainly open, before the
other one fails.

This part of the test relies on the scheduler killing that running action:
--stop-on-first-error fires the cancellation, and the sleep below only ends
because the process is terminated. Cancellation is not always prompt - see
test-cases/action-runner/stop-on-first-error.t - so the build below is bounded
rather than left to hang.

  $ rm -rf _build
  $ marker="$TMPDIR/slow-started"
  $ rm -f "$marker"

The two rules must be independent, so that they run concurrently:

  $ cat >dune <<EOF
  > (rule
  >  (target slow.txt)
  >  (action (bash "touch $marker; sleep 1000")))
  > (alias
  >  (name slow-alias)
  >  (deps slow.txt))
  > (rule
  >  (target fails.txt)
  >  (action (bash "dune_cmd wait-for-file-to-appear $marker; exit 1")))
  > EOF

The failure message names the marker's absolute path, which varies between
runs, so it is dropped here: the outcomes below are what this test is about.

A scheduler that does not kill the sleeping action promptly shows up as a [124]
here, rather than hanging until the cram timeout:

  $ DUNE_TRACE=+graph $timeout 30 dune build @slow-alias fails.txt \
  >   --stop-on-first-error -j2 2>/dev/null
  [1]

  $ dune trace cat | jq -sr '
  >   (reduce (.[] | select(.name == "intern") | .args.entries[]) as $e
  >     ({}; .[$e.id | tostring] = $e.value)) as $names
  >   | (reduce (.[] | select(.name == "exec-rule" and .async_phase == "begin")) as $b
  >       ({}; .[$b.async_id | tostring] =
  >          ($names[$b.args.dir | tostring]) + "/"
  >          + $names[($b.args.target_files // [])[0] | tostring])) as $targets
  >   | [ .[] | select(.name == "exec-rule" and .async_phase == "end")
  >       | select($targets[.async_id | tostring] | endswith(".txt"))
  >       | $targets[.async_id | tostring] + " " + .args.rule_outcome
  >         + " deps=" + ((.args.deps // []) | length | tostring) ]
  >   | sort[]
  > '
  _build/default/fails.txt action-fail deps=0
  _build/default/slow.txt cancelled deps=0

The alias over the cancelled rule is the one case where no resolution can be
produced: an alias's expansion is not known up front, and a cancellation
deliberately skips recovering it. That is reported as "unknown", which a
consumer can tell apart from a span that simply never ended:

  $ dune trace cat | jq -sr '
  >   (reduce (.[] | select(.name == "intern") | .args.entries[]) as $e
  >     ({}; .[$e.id | tostring] = $e.value)) as $names
  >   | (reduce (.[] | select(.name == "build-dep" and .async_phase == "begin")) as $b
  >       ({}; .[$b.async_id | tostring] = $names[$b.args.dep | tostring])) as $deps
  >   | [ .[] | select(.name == "build-dep" and .async_phase == "end")
  >       | select($deps[.async_id | tostring] | endswith("@slow-alias"))
  >       | .args.dep_outcome[0] + " (" + (.args.dep_status // "succeeded") + ")" ][0]
  > '
  unknown (cancelled)

Building a dep records what it resolved to even when building it fails. A file 
dep resolves to its producing rule (unless it is in the source tree), a glob to 
the files it matched, and an alias to its expansion; the first two are known 
before the building that fails, and the alias's is recovered by re-walking its 
definitions without building them.  

  $ rm -rf _build
  $ touch a.src b.src
  $ cat >dune <<EOF
  > (rule
  >  (target boom.txt)
  >  (action (bash "exit 1")))
  > (alias
  >  (name my-alias)
  >  (deps boom.txt))
  > (rule
  >  (target out2.txt)
  >  (deps (glob_files *.src) (alias my-alias) boom.txt)
  >  (action (with-stdout-to out2.txt (echo hi))))
  > EOF

  $ DUNE_TRACE=+graph dune build out2.txt 2>/dev/null
  [1]

Each build-dep span, with the kind of resolution it ended with and how building
it went. The two are independent: a.src and b.src resolve to rules and are built,
while boom.txt resolves to its rule and then fails -- before this the failing dep
was indistinguishable from a built one, since the resolution is all the span
carried.

  $ dune trace cat | jq -sr '
  >   (reduce (.[] | select(.name == "intern") | .args.entries[]) as $e
  >     ({}; .[$e.id | tostring] = $e.value)) as $names
  >   | (reduce (.[] | select(.name == "build-dep" and .async_phase == "begin")) as $b
  >       ({}; .[$b.async_id | tostring] = $names[$b.args.dep | tostring])) as $deps
  >   | [ .[] | select(.name == "build-dep" and .async_phase == "end")
  >       | ($deps[.async_id | tostring]) as $dep
  >       | select($dep | contains("/.dune/") | not)
  >       | $dep + " -> " + .args.dep_outcome[0]
  >         + " (" + (.args.dep_status // "succeeded") + ")" ]
  >   | sort[]
  > '
  _build/default/*.src -> expanded (succeeded)
  _build/default/a.src -> rule (succeeded)
  _build/default/b.src -> rule (succeeded)
  _build/default/boom.txt -> rule (failed)
  _build/default/out2.txt -> rule (failed)
  _build/default@my-alias -> expanded (failed)

Reporting the resolution early must not end the span early: a build-dep span
still has to cover the building it describes. For every dep that resolved to a
rule, the dep's span therefore outlives that rule's exec-rule span:

  $ dune trace cat | jq -sr '
  >   (reduce (.[] | select(.name == "exec-rule" and .async_phase == "end")) as $r
  >     ({}; .[$r.args.rule_id | tostring] = $r.ts)) as $rule_end
  >   | [ .[] | select(.name == "build-dep" and .async_phase == "end")
  >       | select(.args.dep_outcome[0] == "rule")
  >       | $rule_end[.args.dep_outcome[1] | tostring] as $end
  >       | select($end != null)
  >       | .ts >= $end ]
  >   | (length > 0) and all
  > '
  true

The alias's recovered expansion includes the dep whose build failed:

  $ dune trace cat | jq -sc '
  >   (reduce (.[] | select(.name == "intern") | .args.entries[]) as $e
  >     ({}; .[$e.id | tostring] = $e.value)) as $names
  >   | (reduce (.[] | select(.name == "build-dep" and .async_phase == "begin")) as $b
  >       ({}; .[$b.async_id | tostring] = $names[$b.args.dep | tostring])) as $deps
  >   | [ .[] | select(.name == "build-dep" and .async_phase == "end")
  >       | select($deps[.async_id | tostring] | endswith("@my-alias"))
  >       | [ .args.dep_outcome[1:][] | $names[tostring] ] ]
  > '
  [["_build/default/boom.txt"]]

When a rule's deps cannot be recovered either, the end event states
it implicitly to distinguish from a rule with no deps.  This happens
for computations that happen even under lazy evaluation (e.g. Of_memo):
a %{read:...} pform is an Of_memo that builds the file it reads, so its
failure is cached and recovery re-enters it.

  $ rm -rf _build
  $ cat >dune <<EOF
  > (rule
  >  (target r-dep.txt)
  >  (action (bash "exit 1")))
  > (rule
  >  (target r-out.txt)
  >  (action (with-stdout-to r-out.txt (echo "%{read:r-dep.txt}"))))
  > EOF

  $ DUNE_TRACE=+graph dune build r-out.txt 2>/dev/null
  [1]

A rule that fails in its action has known (empty) deps; one whose recovery
failed is marked unknown instead:

  $ dune trace cat | jq -sr '
  >   (reduce (.[] | select(.name == "intern") | .args.entries[]) as $e
  >     ({}; .[$e.id | tostring] = $e.value)) as $names
  >   | (reduce (.[] | select(.name == "exec-rule" and .async_phase == "begin")) as $b
  >       ({}; .[$b.async_id | tostring] =
  >          $names[($b.args.target_files // [])[0] | tostring])) as $targets
  >   | [ .[] | select(.name == "exec-rule" and .async_phase == "end")
  >       | ($targets[.async_id | tostring]) as $t
  >       | select($t | endswith(".txt"))
  >       | $t + " " + .args.rule_outcome
  >         + " deps_unknown=" + ((.args.deps_unknown // false) | tostring) ]
  >   | sort[]
  > '
  r-dep.txt action-fail deps_unknown=false
  r-out.txt dep-fail deps_unknown=true

Recovering a rule's deps runs its action builder without building anything, but
this still runs its Of_memo nodes, which can force a build of their own. Such a
build is attributed to the recovery rather than to the rule, so it is clear it
happened after the rule had already failed.

Reaching one takes a specific shape: Eager evaluation stops at the dep
whose build fails, so anything sequenced after it is never forced; Lazy
evaluation skips the building and carries on, reaching it for the first
time. "diff?" demonstrates this: its first argument becomes a dep, and the
continuation folds Action_builder.if_file_exists over the optional ones. For
a file under a directory target, if_file_exists builds that directory.

  $ rm -rf _build
  $ cat >dune <<EOF
  > (rule
  >  (target (dir a-dir))
  >  (action (bash "mkdir a-dir; touch a-dir/f")))
  > (rule
  >  (target bang.txt)
  >  (action (bash "exit 1")))
  > (rule
  >  (target out3.txt)
  >  (action
  >   (progn
  >    (with-stdout-to out3.txt (echo hi))
  >    (diff? %{dep:bang.txt} out3.txt)
  >    (diff? a-dir/f out3.txt))))
  > EOF

  $ DUNE_TRACE=+graph dune build out3.txt 2>/dev/null
  [1]

The directory target's build is forced by the recovery, naming the rule whose
deps were being recovered:

  $ dune trace cat | jq -sr '
  >   (reduce (.[] | select(.name == "intern") | .args.entries[]) as $e
  >     ({}; .[$e.id | tostring] = $e.value)) as $names
  >   | (reduce (.[] | select(.name == "exec-rule" and .async_phase == "begin")) as $b
  >       ({}; .[$b.args.rule_id | tostring] =
  >          $names[($b.args.target_files + $b.args.target_dirs)[0] | tostring])) as $rules
  >   | [ .[] | select(.args.forced_by[0]? == "dep-recovery")
  >       | .name + " " + $names[.args.dep | tostring]
  >         + " <- recovering " + $rules[.args.forced_by[1] | tostring] ]
  >   | sort[]
  > '
  build-dep _build/default/a-dir <- recovering out3.txt
