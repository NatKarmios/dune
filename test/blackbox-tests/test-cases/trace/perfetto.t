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
  $ dune trace perfetto --text | grep -q 'name: "dir"' && echo yes
  yes
  $ dune trace perfetto --text | grep -q 'name: "target_files"' && echo yes
  yes
  $ dune trace perfetto --text | grep -q 'name: "dep"' && echo yes
  yes
  $ dune trace perfetto --text | grep -q 'name: "rule_id"' && echo yes
  yes
  $ dune trace perfetto --text | grep -q 'str: "_build/default"' && echo yes
  yes
  $ dune trace perfetto --text | grep -q 'str: "out.txt"' && echo yes
  yes
  $ dune trace perfetto --text | grep -q 'str: "_build/default/dep.txt"' && echo yes
  yes

Recognised structural fields are grouped under a "dune" dict (surfacing as e.g.
`debug.dune.target_files` in Trace Processor), while unrecognised fields (such
as the `config` event's own `build_dir`) stay at the top level:

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
  $ dune trace perfetto --text | grep -c 'str: "_build/default"$'
  1
  $ dune trace perfetto --text | grep -c 'str: "out.txt"'
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

The build graph itself -- rules, deps, and the intern table that resolves
their ids -- is additionally emitted as a chunked blob of line-oriented,
tab-separated records on a dedicated "dune-graph" track (see
doc/dev/trace-graph-perfetto.md), rather than as one args-table row per
dependency-array element:

  $ dune trace perfetto --text | grep -c 'name: "dune-graph"'
  1
  $ dune trace perfetto --text | grep -q 'name: "graph-dict"' && echo yes
  yes
  $ dune trace perfetto --text | grep -q 'name: "graph-rules"' && echo yes
  yes
  $ dune trace perfetto --text | grep -q 'name: "graph-deps"' && echo yes
  yes
  $ dune trace perfetto --text | grep -q 'name: "version"' && echo yes
  yes
  $ dune trace perfetto --text | grep -q 'name: "seq"' && echo yes
  yes
  $ dune trace perfetto --text | grep -q 'name: "total"' && echo yes
  yes
  $ dune trace perfetto --text | grep -q 'name: "data"' && echo yes
  yes

Each chunk's payload is one `str:` debug-annotation value. Decode the first
(here: only) chunk of a named section by finding its packet and undoing the
text dump's own escaping of that value, leaving our own tab/newline/backslash
escaping of the record fields intact; real tabs (the record's field
separator) are then swapped for "~" so a record reads on one line:

  $ decode_section() {
  >   dune trace perfetto --text \
  >   | grep -A 30 "name: \"$1\"" \
  >   | grep -m1 '^ *str: "' \
  >   | sed 's/^ *str: "\(.*\)"$/\1/' \
  >   | { IFS= read -r chunk; printf '%b' "$chunk"; } \
  >   | tr '\t' '~'
  > }

The dict maps intern ids to the same readable strings seen elsewhere in this
file:

  $ decode_section graph-dict | grep -c '~_build/default$'
  1
  $ decode_section graph-dict | grep -c '~out.txt$'
  1
  $ decode_section graph-dict | grep -c '~_build/default/dep.txt$'
  1

A graph-rules record is `<rule_id>~<dir_id>~<target_file_ids>~<target_dirs>~
<outcome>~<forced_by>~<dep_ids>~<dyn_dep_stages>`. Resolving the dict ids of
"_build/default" and "out.txt" against it finds the rule that builds out.txt:
executed (not a cache hit -- "X"), with no directory targets, depending on
dep.txt and the glob (in declaration order):

  $ dir_id=$(decode_section graph-dict | grep '~_build/default$' | cut -d~ -f1)
  $ out_id=$(decode_section graph-dict | grep '~out.txt$' | cut -d~ -f1)
  $ dep_id=$(decode_section graph-dict | grep '~_build/default/dep.txt$' | cut -d~ -f1)
  $ glob_id=$(decode_section graph-dict | grep '~_build/default/\*\.src$' | cut -d~ -f1)
  $ out_rule=$(decode_section graph-rules | grep "^[0-9]*~$dir_id~$out_id~~X~")
  $ test -n "$out_rule" && echo yes
  yes
  $ test "$(echo "$out_rule" | cut -d~ -f7)" = "$dep_id,$glob_id" && echo yes
  yes

The matching graph-deps records (`<dep_id>~<resolution>~<forced_by>`) resolve
dep.txt to the rule that produces it ("r<rule_id>"), and the glob to its
expanded members, also by dict id rather than full paths ("x<id,id,...>"):

  $ decode_section graph-deps | grep -qE "^$dep_id~r[0-9]+~" && echo yes
  yes
  $ decode_section graph-deps | grep -qE "^$glob_id~x[0-9]+(,[0-9]+)*~" && echo yes
  yes

Overriding the chunk size (bytes) via `DUNE_TRACE_GRAPH_CHUNK_SIZE` forces
several chunks per section without needing a multi-megabyte trace. The total
record count across all chunks of the graph blob must stay the same as the
unsplit run, proving the splitter never breaks a record across a chunk
boundary:

  $ decode_all() {
  >   dune trace perfetto --text \
  >   | sed -n 's/^ *str: "\([0-9][0-9]*\\t.*\)"$/\1/p' \
  >   | while IFS= read -r chunk; do printf '%b\n' "$chunk"; done
  > }
  $ unsplit_chunks=$(dune trace perfetto --text | grep -c '^ *str: "[0-9][0-9]*\\t')
  $ unsplit_records=$(decode_all | wc -l)
  $ export DUNE_TRACE_GRAPH_CHUNK_SIZE=64
  $ split_chunks=$(dune trace perfetto --text | grep -c '^ *str: "[0-9][0-9]*\\t')
  $ split_records=$(decode_all | wc -l)
  $ unset DUNE_TRACE_GRAPH_CHUNK_SIZE
  $ test "$split_chunks" -gt "$unsplit_chunks" && echo yes
  yes
  $ test "$split_records" = "$unsplit_records" && echo yes
  yes

A value containing the characters our own escaping must protect -- here, a
backslash -- is round-tripped rather than corrupting the record's framing;
resolving it against the dict still gives back exactly one line, with the
backslash still escaped in the (once-decoded) output:

  $ touch 'back\slash.src'
  $ DUNE_TRACE=+graph dune build out.txt
  $ decode_section graph-dict | grep -c '~_build/default/back\\\\slash.src$'
  1
