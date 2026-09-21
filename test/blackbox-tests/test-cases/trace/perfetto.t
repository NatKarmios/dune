`dune trace perfetto` converts the trace file to Perfetto's native protobuf
format.

  $ make_dune_project 3.21

  $ cat >dune <<EOF
  > (rule
  >  (target out.txt)
  >  (action (with-stdout-to out.txt (bash "echo hi"))))
  > EOF

Processes get a track each while they are running, so `-j 1` caps how many of
those tracks the build needs (see the "job-N" section below) and with it the
total track count asserted further down.

  $ dune build -j 1 out.txt

The `--text` flag emits a human-readable, protobuf-text-format-style dump.
Cram runs commands under pipefail, and the dump is large enough that a
`grep -q` closing the pipe early would kill the producer with SIGPIPE, so
we capture it to a file once per build and grep that.

  $ dune trace perfetto --text > dump.textpb

A single process track named "dune" holds a "main" thread track:

  $ grep -c 'process_name: "dune"' dump.textpb
  1
  $ grep -c 'thread_name: "main"' dump.textpb
  1

Events with a duration (e.g. sandbox creation, a persistent file load) become
slices (begin/end pairs) on the main thread track; the rest become instants.

  $ grep -q 'type: TYPE_SLICE_BEGIN' dump.textpb && echo yes
  yes
  $ grep -q 'type: TYPE_SLICE_END' dump.textpb && echo yes
  yes
  $ grep -q 'type: TYPE_INSTANT' dump.textpb && echo yes
  yes

Spawned processes are slices too, but on their own pool of tracks rather than
the main thread: slices on one perfetto track have to nest and parallel
processes do not, so each concurrent process takes a "job-N" track of its own,
under a "processes" track. A slot is reused once the process on it has
finished, so the pool is, at most, as wide as the build's concurrency -- one
track, at `-j 1` -- however many processes the build runs.

  $ grep -c 'name: "processes"' dump.textpb
  1
  $ grep -c 'name: "job-' dump.textpb
  1

Four tracks in total: the process, the main thread, the "processes" track, and
its single job track.

  $ grep -c 'track_descriptor {' dump.textpb
  4

The "dune" process orders its child tracks explicitly, by rank. Job tracks have
no rank, and keep perfetto's default order under "processes":

  $ grep -c 'child_ordering: EXPLICIT' dump.textpb
  1
  $ awk '
  >   /^    name: / { name = $2 }
  >   /^    sibling_order_rank: / { print $2, name }
  > ' dump.textpb | sort -n
  0 "main"
  1 "processes"

Names and annotation names are both interned, in separate tables, and a name
is defined by its first user (i.e. after the event referencing it), so
resolving an event to "<name> <type> <arg names>" means buffering to END and
matching each `name_iid:` by its exact indentation: 4 spaces for the event's
own name, 8 for a `dune` dict entry (6 is the dict itself):

  $ event_args() {
  >   awk '
  >     /^ *event_names \{/ { tbl = "e"; next }
  >     /^ *debug_annotation_names \{/ { tbl = "d"; next }
  >     tbl != "" && $1 == "iid:" { iid = $2; next }
  >     tbl != "" && $1 == "name:" {
  >       gsub(/"/, "", $2)
  >       if (tbl == "e") ename[iid] = $2; else dname[iid] = $2
  >       tbl = ""; next
  >     }
  >     /^  track_event \{/ { n++ }
  >     /^    type: / { etype[n] = $2 }
  >     /^    name_iid: / { eid[n] = $2 }
  >     /^        name_iid: / { args[n] = args[n] "," $2 }
  >     END {
  >       for (i = 1; i <= n; i++) {
  >         s = ""
  >         m = split(args[i], a, ",")
  >         for (j = 2; j <= m; j++) s = s (j == 2 ? "" : ",") dname[a[j]]
  >         print ename[eid[i]], etype[i], s
  >       }
  >     }
  >   ' dump.textpb
  > }

Recognised structural fields are grouped under a "dune" dict (surfacing as
e.g. `debug.dune.process_args` in Trace Processor); everything else stays at
the top level, so a process slice's one dict entry is its command line:

  $ event_args | sort -u | grep '^process '
  process TYPE_SLICE_BEGIN process_args

The process slice's other fields (its pid, its exit status, its resource
usage) are top-level annotations rather than dict entries:

  $ grep -q 'name: "pid"' dump.textpb && echo yes
  yes
  $ grep -q 'name: "rusage"' dump.textpb && echo yes
  yes

Interning is incremental over one sequence: the first participating packet
clears prior state (`sequence_flags: 3`) and the rest only announce they need
it (`sequence_flags: 2`):

  $ grep -c 'sequence_flags: 3' dump.textpb
  1

`--trace-file` reads a trace from somewhere other than the default
`_build/trace.csexp`:

  $ cp _build/trace.csexp elsewhere.csexp
  $ dune trace perfetto --trace-file elsewhere.csexp --text > copy.textpb
  $ diff dump.textpb copy.textpb && echo same
  same

Without `--text` it writes the binary protobuf. The output is a stream of
length-delimited Trace.packet fields, so it begins with the tag for field 1,
wire type 2 (0x0a):

  $ dune trace perfetto -o out.perfetto-trace
  $ test -s out.perfetto-trace && echo non-empty
  non-empty
  $ head -c 1 out.perfetto-trace | od -An -tx1 | tr -d ' '
  0a

The job-track pool widens only as far as the concurrency actually reached. Two
rules with nothing between them, run two at a time, overlap, so the second
process cannot reuse the first's track:

  $ cat >dune <<EOF
  > (rule
  >  (target slow-a.txt)
  >  (action (with-stdout-to slow-a.txt (bash "sleep 1"))))
  > (rule
  >  (target slow-b.txt)
  >  (action (with-stdout-to slow-b.txt (bash "sleep 1"))))
  > EOF
  $ dune build -j 2 slow-a.txt slow-b.txt
  $ dune trace perfetto --text > dump.textpb
  $ grep -c 'name: "job-' dump.textpb
  2
