`dune trace perfetto` converts the trace file to Perfetto's native protobuf
format. It reuses the same event stream as `dune trace cat`, mapping graph
async spans to lifecycle instants on one fixed track per span kind and flat
events onto a main thread track.

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
  > (rule
  >  (target copy.txt)
  >  (deps /etc/hosts out.txt)
  >  (action (copy /etc/hosts copy.txt)))
  > EOF

  $ DUNE_TRACE=+graph dune build out.txt copy.txt

The `--text` flag emits a human-readable, protobuf-text-format-style dump.
Cram runs commands under pipefail, and the dump is large enough that a
`grep -q` closing the pipe early would kill the producer with SIGPIPE, so
capture it to a file once per build and grep that:

  $ dune trace perfetto --text > dump.textpb

A single process track named "dune" holds a "main" thread track:

  $ grep -c 'process_name: "dune"' dump.textpb
  1
  $ grep -c 'thread_name: "main"' dump.textpb
  1

Flat events with a duration (e.g. spawned processes) still become slices
(begin/end pairs) on the main thread track:

  $ grep -q 'type: TYPE_SLICE_BEGIN' dump.textpb && echo yes
  yes
  $ grep -q 'type: TYPE_SLICE_END' dump.textpb && echo yes
  yes

Graph async spans (exec-rule, exec-rule-action, build-dep, gen-rules,
dynamic-includes) become instants instead: unrelated spans of the same kind
share one fixed track, so track descriptors no longer scale with the number
of spans. This project only exercises four of the five kinds (no subdirectory
means no dynamic-includes span), for seven tracks in total -- the process, the
main thread, the graph blob, and the four kind tracks:

  $ grep -c 'track_descriptor {' dump.textpb
  7
  $ grep -q 'name: "exec-rule"' dump.textpb && echo yes
  yes
  $ grep -c 'name: "exec-rule-action"' dump.textpb
  1
  $ grep -q 'name: "build-dep"' dump.textpb && echo yes
  yes
  $ grep -q 'name: "gen-rules"' dump.textpb && echo yes
  yes

Each kind's lifecycle is a start instant (at the begin timestamp) and a
finish instant carrying `dur_ns`, paired by a shared `async_id`:

  $ grep -q 'type: TYPE_INSTANT' dump.textpb && echo yes
  yes
  $ grep -q 'name: "exec-rule-start"' dump.textpb && echo yes
  yes
  $ grep -q 'name: "exec-rule-finish"' dump.textpb && echo yes
  yes
  $ grep -q 'name: "build-dep-start"' dump.textpb && echo yes
  yes
  $ grep -q 'name: "build-dep-finish"' dump.textpb && echo yes
  yes
  $ grep -q 'name: "gen-rules-start"' dump.textpb && echo yes
  yes
  $ grep -q 'name: "gen-rules-finish"' dump.textpb && echo yes
  yes
  $ grep -q 'name: "async_id"' dump.textpb && echo yes
  yes
  $ grep -q 'name: "dur_ns"' dump.textpb && echo yes
  yes

The graph tracks carry nothing but instants -- the slices seen above are all
on the main thread track. (Anything else would nest: slices on one track have
stack semantics, and unrelated spans of the same kind overlap freely.)

  $ graph_slice_count() {
  >   awk '
  >     $1 == "track_descriptor" { td = 1 }
  >     td && $1 == "uuid:" { uuid = $2 }
  >     td && $1 == "name:" && $2 ~ /^"(exec-rule|exec-rule-action|build-dep|gen-rules|dynamic-includes|dune-graph)"$/ { graph[uuid] = 1 }
  >     td && $1 == "}" { td = 0 }
  >     /^    type: / { type = $2 }
  >     /^    track_uuid: / { if (($2 in graph) && type ~ /SLICE/) n++ }
  >     END { print n + 0 }
  >   ' dump.textpb
  > }
  $ graph_slice_count
  0

`copy.txt` depends on `/etc/hosts`, a path outside the workspace entirely
rather than a project source file (which would resolve through dune's
implicit copy-to-build-dir rule, i.e. the "rule" outcome, not this one) --
so its build-dep resolves as `is-source`, the other collapsed case besides
an exec-rule cache hit, producing a single `build-dep-resolved` instant
instead of a start/finish pair:

  $ grep -q 'name: "build-dep-resolved"' dump.textpb && echo yes
  yes
  $ grep -q 'str: "is-source"' dump.textpb && echo yes
  yes

An executed rule's action execution is its own span (exec-rule-action,
sharing the rule's async_id), and gets a lifecycle pair like the other kinds.
It is not bounded by -j -- the throttle is acquired per-process, below this
span -- so an arbitrary number of actions can be open at once, and instants
are what lets them all share one track (see doc/dev/trace-graph-perfetto.md,
phase 6).

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

Both action instants are on the graph track as instants, joined to their rule
by the `async_id` they share with it, and the finish carries `dur_ns`:

  $ event_args | sort -u | grep '^exec-rule-action-'
  exec-rule-action-finish TYPE_INSTANT async_id,dur_ns,rule_id
  exec-rule-action-start TYPE_INSTANT async_id,rule_id

Starts and finishes balance (the exact count isn't stable: besides the three
project rules, a fresh build also executes internal rules such as the
context's configurator probes and the copy-to-build-dir rules for the .src
sources):

  $ starts=$(event_args | grep -c '^exec-rule-action-start ')
  $ finishes=$(event_args | grep -c '^exec-rule-action-finish ')
  $ test "$starts" -gt 0 && test "$starts" -eq "$finishes" && echo yes
  yes

A fresh flow id per non-collapsed span chains its lifecycle events (see
doc/dev/trace-graph-perfetto.md, phase 4). Event names are interned, so
resolving `name_iid` against the `event_names` table gives, for each
`flow_ids` occurrence, "<flow id> <event name> <event type>". Two parsing
subtleties: a name is interned by its first user, i.e. its `interned_data`
definition sits *after* the track_event referencing it in the same packet, so
the flow records are buffered and their names resolved only at END; and debug
annotations carry `name_iid:` lines of their own (a different intern table),
so the event-level fields are matched by their exact 4-space indentation:

  $ flow_events() {
  >   awk '
  >     /^ *event_names {/ { en = 1 }
  >     en && $1 == "iid:" { iid = $2 }
  >     en && $1 == "name:" { gsub(/"/, "", $2); name[iid] = $2; en = 0 }
  >     /^    type: / { type = $2; niid = "" }
  >     /^    name_iid: / { niid = $2 }
  >     /^    flow_ids: / { n++; fid[n] = $2; fniid[n] = niid; ftype[n] = type }
  >     END { for (i = 1; i <= n; i++) print fid[i], name[fniid[i]], ftype[i] }
  >   ' dump.textpb
  > }

For an executed rule, one id links all four of its lifecycle instants -- flow
chaining follows timestamp order, so the UI draws
start -> action-start -> action-finish -> finish. (Packet order differs: the
action's instants are pushed when the action ends, the rule's only once the
rule's own end arrives.) Pick an action's flow id and list every event
carrying it:

  $ action_flow=$(flow_events | awk '$2 == "exec-rule-action-start" { print $1; exit }')
  $ flow_events | awk -v id="$action_flow" '$1 == id { print $2, $3 }'
  exec-rule-action-start TYPE_INSTANT
  exec-rule-action-finish TYPE_INSTANT
  exec-rule-start TYPE_INSTANT
  exec-rule-finish TYPE_INSTANT

For the other non-collapsed kinds there is no action span, so the flow is a
plain start -> finish pair (build-dep shown; gen-rules and dynamic-includes
work identically):

  $ dep_flow=$(flow_events | awk '$2 == "build-dep-start" { print $1; exit }')
  $ flow_events | awk -v id="$dep_flow" '$1 == id { print $2, $3 }'
  build-dep-start TYPE_INSTANT
  build-dep-finish TYPE_INSTANT

Collapsed instants carry no flow -- this build's build-dep-resolved (the
/etc/hosts dep, see above) never shows up in the flow list:

  $ flow_events | grep -q resolved && echo yes
  [1]

The event's own category ("graph") is still interned, just no longer doubles
as every async track's name:

  $ grep -q 'name: "graph"' dump.textpb && echo yes
  yes

Repeated strings are interned. Event names and categories are referenced from
track events by id (`name_iid` / `category_iids`), and defined once in an
`interned_data` table:

  $ grep -q 'name_iid:' dump.textpb && echo yes
  yes
  $ grep -q 'category_iids:' dump.textpb && echo yes
  yes
  $ grep -q 'event_names {' dump.textpb && echo yes
  yes
  $ grep -q 'name: "exec-rule"' dump.textpb && echo yes
  yes

The lifecycle instants' fields become debug annotations, with `dir`/`dep`
resolved from their interned ids to readable paths at the time the matching
end is seen. The annotation names and string values are themselves interned
(`name_iid` / `string_value_iid`):

  $ grep -q 'debug_annotation_names {' dump.textpb && echo yes
  yes
  $ grep -q 'debug_annotation_string_values {' dump.textpb && echo yes
  yes
  $ grep -q 'name: "dir"' dump.textpb && echo yes
  yes
  $ grep -q 'name: "dep"' dump.textpb && echo yes
  yes
  $ grep -q 'name: "rule_id"' dump.textpb && echo yes
  yes
  $ grep -q 'str: "_build/default"' dump.textpb && echo yes
  yes
  $ grep -q 'str: "_build/default/dep.txt"' dump.textpb && echo yes
  yes

Per the arg-slimming in doc/dev/trace-graph-perfetto.md (phase 2), `deps`,
`dyn_deps`, `target_files`, `target_dirs`, `forced_by`, and expansion lists no
longer appear on slices at all -- they are blob-only now (see below). In
particular, "out.txt" (a `target_files` entry) no longer appears anywhere in
the plain protobuf text as its own interned string; it only shows up encoded
inside the blob's `data` payload (and, since copy.txt depends on it, as the
full path "_build/default/out.txt" of a build-dep):

  $ grep -q 'name: "target_files"' dump.textpb && echo yes
  [1]
  $ grep -q 'name: "target_dirs"' dump.textpb && echo yes
  [1]
  $ grep -q 'name: "deps"' dump.textpb && echo yes
  [1]
  $ grep -q 'name: "dyn_deps"' dump.textpb && echo yes
  [1]
  $ grep -q 'name: "forced_by"' dump.textpb && echo yes
  [1]
  $ grep -q 'str: "out.txt"' dump.textpb && echo yes
  [1]

Recognised structural fields are grouped under a "dune" dict (surfacing as e.g.
`debug.dune.dir` in Trace Processor), while unrecognised fields (such as the
`config` event's own `build_dir`) stay at the top level:

  $ grep -q 'name: "dune"' dump.textpb && echo yes
  yes
  $ grep -q 'name: "build_dir"' dump.textpb && echo yes
  yes

`exec-rule-finish`'s outcome and `build-dep-finish`'s outcome kind are now
plain strings rather than nested tagged-union dicts (`forced_by`'s `kind` tag
and `dep_outcome`'s dict are gone along with the fields they tagged):

  $ grep -q 'name: "outcome"' dump.textpb && echo yes
  yes
  $ grep -q 'str: "executed"' dump.textpb && echo yes
  yes
  $ grep -q 'name: "outcome_kind"' dump.textpb && echo yes
  yes
  $ grep -q 'str: "rule"' dump.textpb && echo yes
  yes
  $ grep -q 'name: "kind"' dump.textpb && echo yes
  [1]
  $ grep -q 'name: "dep_outcome"' dump.textpb && echo yes
  [1]
  $ grep -q 'name: "rule_outcome"' dump.textpb && echo yes
  [1]

Interning is incremental over one sequence: the first participating packet clears
prior state (`sequence_flags: 3`), the rest only announce they need it
(`sequence_flags: 2`), and each string is defined exactly once however many
events reference it:

  $ grep -c 'sequence_flags: 3' dump.textpb
  1
  $ grep -c 'str: "_build/default"$' dump.textpb
  1

All rules are freshly executed, so `str: "executed"` is referenced by every
`exec-rule-finish` instant but interned only once:

  $ grep -c 'str: "executed"' dump.textpb
  1
  $ grep -c 'str: "_build/default/dep.txt"' dump.textpb
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

  $ grep -c 'name: "dune-graph"' dump.textpb
  1
  $ grep -q 'name: "graph-dict"' dump.textpb && echo yes
  yes
  $ grep -q 'name: "graph-rules"' dump.textpb && echo yes
  yes
  $ grep -q 'name: "graph-deps"' dump.textpb && echo yes
  yes
  $ grep -q 'name: "version"' dump.textpb && echo yes
  yes
  $ grep -q 'name: "seq"' dump.textpb && echo yes
  yes
  $ grep -q 'name: "total"' dump.textpb && echo yes
  yes
  $ grep -q 'name: "data"' dump.textpb && echo yes
  yes

Each chunk's payload is one `str:` debug-annotation value. Decode the first
(here: only) chunk of a named section by finding its packet and undoing the
text dump's own escaping of that value, leaving our own tab/newline/backslash
escaping of the record fields intact; real tabs (the record's field
separator) are then swapped for "~" so a record reads on one line:

  $ decode_section() {
  >   grep -A 30 "name: \"$1\"" dump.textpb \
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
  >   sed -n 's/^ *str: "\([0-9][0-9]*\\t.*\)"$/\1/p' dump.textpb \
  >   | while IFS= read -r chunk; do printf '%b\n' "$chunk"; done
  > }
  $ unsplit_chunks=$(grep -c '^ *str: "[0-9][0-9]*\\t' dump.textpb)
  $ unsplit_records=$(decode_all | wc -l)
  $ export DUNE_TRACE_GRAPH_CHUNK_SIZE=64
  $ dune trace perfetto --text > dump.textpb
  $ split_chunks=$(grep -c '^ *str: "[0-9][0-9]*\\t' dump.textpb)
  $ split_records=$(decode_all | wc -l)
  $ unset DUNE_TRACE_GRAPH_CHUNK_SIZE
  $ dune trace perfetto --text > dump.textpb
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
  $ dune trace perfetto --text > dump.textpb
  $ decode_section graph-dict | grep -c '~_build/default/back\\\\slash.src$'
  1

A no-op rebuild (nothing changed since the last build) produces a cache hit,
collapsed to a single `exec-rule-resolved` instant carrying the union of the
start/finish args (`dir`, `rule_id`, `async_id`) plus the outcome and
`dur_ns`, rather than a separate start/finish pair:

  $ DUNE_TRACE=+graph dune build out.txt
  $ dune trace perfetto --text > dump.textpb
  $ grep -q 'name: "exec-rule-resolved"' dump.textpb && echo yes
  yes
  $ grep -qE 'str: "local-cache-hit"|str: "shared-cache-hit"' dump.textpb && echo yes
  yes

The collapsed instants carry no flow here either (the rebuild's build-dep
spans still resolve to rules, so those flows remain):

  $ flow_events | grep -q resolved && echo yes
  [1]
  $ flow_events | grep -q build-dep-start && echo yes
  yes

Cache hits execute no action, so this trace has no exec-rule-action instants
-- and, the track being declared lazily, no exec-rule-action track either:

  $ grep -q 'name: "exec-rule-action"' dump.textpb && echo yes
  [1]
  $ event_args | grep -q '^exec-rule-action-' && echo yes
  [1]
