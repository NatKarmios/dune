`dune trace perfetto` converts the trace file to Perfetto's native protobuf
format. It reuses the same event stream as `dune trace cat`, mapping graph async
spans to slices on per-span tracks and flat events onto a main thread track.

  $ make_dune_project 3.21

  $ touch foo.src bar.src

  $ cat >dune <<EOF
  > (rule
  >  (target dep.txt)
  >  (action (with-stdout-to dep.txt (echo "hi"))))
  > (rule
  >  (target out.txt)
  >  (deps dep.txt (glob_files *.src))
  >  (action (with-stdout-to out.txt (cat dep.txt))))
  > EOF

  $ DUNE_TRACE=+graph dune build out.txt

The `--text` flag emits a human-readable, protobuf-text-format-style dump. A
single process track named "dune" holds a "main" thread track:

  $ dune trace perfetto --text | grep -c 'process_name: "dune"'
  1
  $ dune trace perfetto --text | grep -c 'thread_name: "main"'
  1

Graph async spans become slices (begin/end pairs on their own tracks):

  $ dune trace perfetto --text | grep -q 'type: TYPE_SLICE_BEGIN' && echo yes
  yes
  $ dune trace perfetto --text | grep -q 'type: TYPE_SLICE_END' && echo yes
  yes
  $ dune trace perfetto --text | grep -q 'name: "exec-rule"' && echo yes
  yes

Each async span gets its own track, named by the event's category:

  $ dune trace perfetto --text | grep -q 'name: "graph"' && echo yes
  yes

The structural graph fields (targets, deps, forced_by, ...) are promoted from
generic debug annotations to a typed `TrackEvent` extension. A descriptor packet
embeds a `FileDescriptorSet` naming the schema, `dune.DuneTrackEvent` extending
`perfetto.protos.TrackEvent`, so Trace Processor decodes them into its args table
(e.g. `EXTRACT_ARG(arg_set_id, 'dune.targets')`):

  $ dune trace perfetto --text | grep -q 'field_1: "DuneTrackEvent"' && echo yes
  yes
  $ dune trace perfetto --text | grep -q 'field_2: ".perfetto.protos.TrackEvent"' && echo yes
  yes

Tagged unions are modelled as nested messages rather than flattened strings:
`forced_by` is a `ForcedBy`, and build-dep's `dep_outcome` is a `DepOutcome`
(distinct from exec-rule's plain `rule_outcome` string). Exec-rule's `rule_id` is
also included:

  $ dune trace perfetto --text | grep -q 'field_1: "ForcedBy"' && echo yes
  yes
  $ dune trace perfetto --text | grep -q 'field_1: "DepOutcome"' && echo yes
  yes
  $ dune trace perfetto --text | grep -q 'field_1: "rule_id"' && echo yes
  yes

The extension is spliced onto each graph event at field 9910, with interned
target and dep ids resolved to readable paths (targets = field 1, dep =
field 3):

  $ dune trace perfetto --text | grep -q 'field_9910 {' && echo yes
  yes
  $ dune trace perfetto --text | grep -q 'field_1: "_build/default/out.txt"' && echo yes
  yes
  $ dune trace perfetto --text | grep -q 'field_3: "_build/default/dep.txt"' && echo yes
  yes

Without `--text` it writes the binary protobuf. The output is a stream of
length-delimited Trace.packet fields, so it begins with the tag for field 1,
wire type 2 (0x0a):

  $ dune trace perfetto -o out.perfetto-trace
  $ test -s out.perfetto-trace && echo non-empty
  non-empty
  $ head -c 1 out.perfetto-trace | od -An -tx1 | tr -d ' '
  0a
