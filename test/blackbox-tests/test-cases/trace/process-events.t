Dune emits one event pair per process it spawns: a "process" async begin at the
moment the process starts, and a matching async end when it exits. The two
share the span's "async_id" and are told apart by their "async_phase".

The begin carries what is known at spawn time -- the command, the directory it
runs in, its pid, the targets it is producing -- and the end what the exit
reports: the status, the output, the resource usage. Neither repeats the
other's fields; the "async_id" is what ties them together.

  $ make_dune_project 3.21

  $ cat >dune <<EOF
  > (rule
  >  (target out.txt)
  >  (action (with-stdout-to out.txt (bash "echo hi"))))
  > (rule
  >  (target failed.txt)
  >  (action (with-stdout-to failed.txt (bash "echo boom >&2; exit 3"))))
  > EOF

  $ dune build out.txt
  $ spans='select(.cat == "process" and .name == "process")'

Every span has exactly one begin and exactly one end (nothing is printed, as
nothing deviates):

  $ dune trace cat | jq -c "
  >   [ .[] | $spans ]
  > | group_by(.async_id)[]
  > | { id: .[0].async_id, phases: (map(.async_phase) | sort) }
  > | select(.phases != [\"begin\", \"end\"])
  > " --slurp

The fields of the begin and of the end are disjoint:

  $ dune trace cat | jq -c "
  >   [ .[] | $spans ]
  > | group_by(.async_phase)
  > | map([ .[] | .args | keys ] | add | unique)
  > | { begin: .[0], end: .[1], both: (.[0] - (.[0] - .[1])) }
  > " --slurp
  {"begin":["categories","dir","pid","process_args","prog","queued","target_files"],"end":["exit","rusage"],"both":[]}

A process that failed reports its status and its output on the end, and only
there:

  $ dune build failed.txt 2>/dev/null
  [1]
  $ dune trace cat | jq -c "
  >   [ .[] | $spans ]
  > | .[-1]
  > | { phase: .async_phase, args: (.args | .rusage |= (keys | length)) }
  > " --slurp
  {"phase":"end","args":{"exit":3,"error":"exited with code 3","stderr":"boom\n","rusage":9}}

Without the "graph" category there is no forcer in scope to record, and the
field is left off rather than emitted empty:

  $ dune trace cat | jq -c "[ .[] | $spans | .args.forced_by ] | unique" --slurp
  [null]

With it, a process spawned to run a rule's action is attributed to that rule:

  $ rm -rf _build
  $ DUNE_TRACE=+graph dune build out.txt
  $ dune trace cat | jq -r "$spans | .args.forced_by[0] // empty" | sort -u
  rule

A nested dune numbers its own spans from zero as well, and its events are
folded into this trace file tagged with the digest of the action that ran it.
Pairing spans on the number alone can therefore cross the two invocations, so
the digest is part of the key that pairs a begin with its end.

  $ cat >dune <<EOF
  > (rule
  >  (target inner.txt)
  >  (action (with-stdout-to inner.txt (bash "echo inner"))))
  > (rule
  >  (alias outer)
  >  (deps (source_tree .))
  >  (action (run dune build ./inner.txt)))
  > EOF
  $ rm -rf _build
  $ dune build @outer

The two invocations both number a span 0, and only the nested one's events
carry a digest:

  $ dune trace cat | jq -c "
  >   [ .[] | $spans | select(.async_id == 0) ]
  > | map({ phase: .async_phase, nested: (.args.digest != null) })
  > " --slurp
  [{"phase":"begin","nested":false},{"phase":"end","nested":false},{"phase":"begin","nested":true},{"phase":"end","nested":true}]

Both invocations' commands come out whole:

  $ dune trace commands | grep -c 'echo inner'
  1
