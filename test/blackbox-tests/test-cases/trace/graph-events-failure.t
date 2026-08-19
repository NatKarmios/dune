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
because the process is terminated. That is the least portable thing here, so if
it proves flaky off Linux, move it to its own file and gate it in the "dune"
file alongside the watch-mode tests rather than weakening the synchronisation.

  $ rm -rf _build
  $ marker="$TMPDIR/slow-started"
  $ rm -f "$marker"

The two rules must be independent, so that they run concurrently:

  $ cat >dune <<EOF
  > (rule
  >  (target slow.txt)
  >  (action (bash "touch $marker; sleep 1000")))
  > (rule
  >  (target fails.txt)
  >  (action (bash "dune_cmd wait-for-file-to-appear $marker; exit 1")))
  > EOF

The failure message names the marker's absolute path, which varies between
runs, so it is dropped here: the outcomes below are what this test is about.

  $ DUNE_TRACE=+graph dune build slow.txt fails.txt --stop-on-first-error -j2 \
  >   2>/dev/null
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
