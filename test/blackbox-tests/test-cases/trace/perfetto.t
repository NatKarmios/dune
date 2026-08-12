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

Each async span gets its own track, named by the event's category:

  $ dune trace perfetto --text | grep -q 'name: "graph"' && echo yes
  yes

Repeated strings are interned. Event names and categories are referenced from
track events by id (`name_iid` / `category_iids`), and defined once in an
`interned_data` table:

  $ dune trace perfetto --text | grep -q 'name_iid:' && echo yes
  yes
  $ dune trace perfetto --text | grep -q 'category_iids:' && echo yes
  yes
  $ dune trace perfetto --text | grep -q 'event_names {' && echo yes
  yes
  $ dune trace perfetto --text | grep -q 'name: "exec-rule"' && echo yes
  yes

The structural graph fields become debug annotations, with their interned target
and dep ids resolved to readable paths. The annotation names and string values
are themselves interned (`name_iid` / `string_value_iid`):

  $ dune trace perfetto --text | grep -q 'debug_annotation_names {' && echo yes
  yes
  $ dune trace perfetto --text | grep -q 'debug_annotation_string_values {' && echo yes
  yes
  $ dune trace perfetto --text | grep -q 'name: "targets"' && echo yes
  yes
  $ dune trace perfetto --text | grep -q 'name: "dep"' && echo yes
  yes
  $ dune trace perfetto --text | grep -q 'name: "rule_id"' && echo yes
  yes
  $ dune trace perfetto --text | grep -q 'str: "_build/default/out.txt"' && echo yes
  yes
  $ dune trace perfetto --text | grep -q 'str: "_build/default/dep.txt"' && echo yes
  yes

Recognised structural fields are grouped under a "dune" dict (surfacing as e.g.
`debug.dune.targets` in Trace Processor), while unrecognised fields (such as the
`config` event's own `build_dir`) stay at the top level:

  $ dune trace perfetto --text | grep -q 'name: "dune"' && echo yes
  yes
  $ dune trace perfetto --text | grep -q 'name: "build_dir"' && echo yes
  yes

Tagged unions become nested dicts: `forced_by` carries a `kind` tag plus its
payload, and build-dep's `dep_outcome` is distinct from exec-rule's plain
`rule_outcome` string:

  $ dune trace perfetto --text | grep -q 'name: "forced_by"' && echo yes
  yes
  $ dune trace perfetto --text | grep -q 'name: "kind"' && echo yes
  yes
  $ dune trace perfetto --text | grep -q 'name: "dep_outcome"' && echo yes
  yes
  $ dune trace perfetto --text | grep -q 'name: "rule_outcome"' && echo yes
  yes

Interning is incremental over one sequence: the first participating packet clears
prior state (`sequence_flags: 3`), the rest only announce they need it
(`sequence_flags: 2`), and each string is defined exactly once however many
events reference it:

  $ dune trace perfetto --text | grep -c 'sequence_flags: 3'
  1
  $ dune trace perfetto --text | grep -c 'str: "_build/default/out.txt"'
  1
  $ dune trace perfetto --text | grep -c 'str: "_build/default/dep.txt"'
  1

Without `--text` it writes the binary protobuf. The output is a stream of
length-delimited Trace.packet fields, so it begins with the tag for field 1,
wire type 2 (0x0a):

  $ dune trace perfetto -o out.perfetto-trace
  $ test -s out.perfetto-trace && echo non-empty
  non-empty
  $ head -c 1 out.perfetto-trace | od -An -tx1 | tr -d ' '
  0a
