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
finish instant carrying `dur_ns`. The csexp `async_id` that pairs a begin
with its end is converter bookkeeping and does not survive into the output:
what pairs the instants downstream is the id keying the span's graph-blob
record (`rule_id` / `dep_id`, see below):

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
  [1]
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
instead of a start/finish pair. The resolution itself is not on the instant
-- the collapse is the only trace of it here, and the blob records it as `s`
(asserted below):

  $ grep -q 'name: "build-dep-resolved"' dump.textpb && echo yes
  yes
  $ grep -q 'str: "is-source"' dump.textpb && echo yes
  [1]

An executed rule's action execution is its own span (exec-rule-action,
sharing the rule's async_id in the csexp), and gets a lifecycle pair like the
other kinds.
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

An instant carries only what the blob cannot supply: the id keying its blob
record, and (on a finish or a collapsed instant) `dur_ns`, which is timing
rather than structure. So the action instants are joined to their rule by
`rule_id`, and the rule's outcome and the dep's resolution -- both blob
fields -- are not repeated here:

  $ event_args | sort -u | grep '^exec-rule'
  exec-rule-action-finish TYPE_INSTANT rule_id,dur_ns
  exec-rule-action-start TYPE_INSTANT rule_id
  exec-rule-finish TYPE_INSTANT rule_id,dur_ns
  exec-rule-start TYPE_INSTANT rule_id
  $ event_args | sort -u | grep '^build-dep'
  build-dep-finish TYPE_INSTANT dep_id,dur_ns
  build-dep-resolved TYPE_INSTANT dep_id,dur_ns
  build-dep-start TYPE_INSTANT dep_id

gen-rules and dynamic-includes have no blob record, so they keep the path
that identifies them (`dir`, and the `dune_file` a standalone/group-root
directory's rules come from -- other directories' finishes have none):

  $ event_args | sort -u | grep '^gen-rules'
  gen-rules-finish TYPE_INSTANT dune_file,dur_ns
  gen-rules-finish TYPE_INSTANT dur_ns
  gen-rules-start TYPE_INSTANT dir

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

The lifecycle instants' fields become debug annotations. The annotation names
and string values are themselves interned (`name_iid` /
`string_value_iid`). The ids on exec-rule/build-dep instants are left as the
intern ids they arrive as -- the blob's dict is what resolves them -- so no
target or dep path is interned as a string of its own here; gen-rules' `dir`
is a plain path in the event, not an interned id, and stays one:

  $ grep -q 'debug_annotation_names {' dump.textpb && echo yes
  yes
  $ grep -q 'debug_annotation_string_values {' dump.textpb && echo yes
  yes
  $ grep -q 'name: "rule_id"' dump.textpb && echo yes
  yes
  $ grep -q 'name: "dep_id"' dump.textpb && echo yes
  yes
  $ grep -q 'name: "dep"' dump.textpb && echo yes
  [1]
  $ grep -q 'name: "dir"' dump.textpb && echo yes
  yes
  $ grep -q 'str: "_build/default"' dump.textpb && echo yes
  yes
  $ grep -q 'str: "_build/default/dep.txt"' dump.textpb && echo yes
  [1]

Per the arg-slimming in doc/dev/trace-graph-perfetto.md (phases 2 and 7),
`deps`, `dyn_deps`, `target_files`, `target_dirs`, `forced_by`, and expansion
lists no longer appear on instants at all -- they are blob-only now (see
below). In particular, "out.txt" (a `target_files` entry) no longer appears
anywhere in the plain protobuf text as its own interned string; it only shows
up encoded inside the blob's `data` payload. Its full path is still interned
once, but as a *user-requested* target on the `targets` event -- those are
real paths in the event, not intern ids, and are not part of the graph:

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
  $ grep -c 'str: "_build/default/out.txt"' dump.textpb
  1

Recognised structural fields are grouped under a "dune" dict (surfacing as e.g.
`debug.dune.dir` in Trace Processor), while unrecognised fields (such as the
`config` event's own `build_dir`) stay at the top level:

  $ grep -q 'name: "dune"' dump.textpb && echo yes
  yes
  $ grep -q 'name: "build_dir"' dump.textpb && echo yes
  yes

A rule's outcome and a dep's resolution are blob fields, so neither the
tagged-union dicts of the csexp events (`rule_outcome`, `dep_outcome`,
`forced_by`'s `kind` tag) nor the flattened strings that replaced them in
phase 2 (`outcome`, `outcome_kind`) reach the instants:

  $ grep -q 'str: "executed"' dump.textpb && echo yes
  [1]
  $ grep -q 'name: "outcome_kind"' dump.textpb && echo yes
  [1]
  $ grep -q 'str: "rule"' dump.textpb && echo yes
  [1]
  $ grep -q 'name: "kind"' dump.textpb && echo yes
  [1]
  $ grep -q 'name: "dep_outcome"' dump.textpb && echo yes
  [1]
  $ grep -q 'name: "rule_outcome"' dump.textpb && echo yes
  [1]

The one surviving `outcome` annotation belongs to the `build` category's
`build-finish` event (success/failure of the whole build), not to a graph
instant:

  $ grep -q 'name: "outcome"' dump.textpb && echo yes
  yes
  $ grep -q 'str: "success"' dump.textpb && echo yes
  yes

Interning is incremental over one sequence: the first participating packet clears
prior state (`sequence_flags: 3`), the rest only announce they need it
(`sequence_flags: 2`), and each string is defined exactly once however many
events reference it:

  $ grep -c 'sequence_flags: 3' dump.textpb
  1
  $ grep -c 'str: "_build/default"$' dump.textpb
  1

`_build/default` above is one such string, named by every `gen-rules-start`
in the default context. Paths that arrive as intern ids (rule dirs, deps) are
no longer resolved onto instants, so they are not in the string pool at all
-- the blob's dict is their only copy:

  $ grep -c 'str: "_build/default/dep.txt"' dump.textpb
  0
  [1]

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

Dep sets are factored rather than spelled out per rule: `graph-depsets` names
each distinct set as a core plus the ids it adds to that core, and `graph-cores`
holds the cores. A core only exists once a set has at least 16 members -- this
project's rules have two deps at most, so every set here stands alone, the
section has no records at all, and a section with no records emits no instant:

  $ grep -q 'name: "graph-depsets"' dump.textpb && echo yes
  yes
  $ grep -q 'name: "graph-cores"' dump.textpb && echo yes
  [1]

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
<outcome>~<forced_by>~<dep_set>~<dyn_dep_stages>`. Resolving the dict ids of
"_build/default" and "out.txt" against it finds the rule that builds out.txt:
executed (not a cache hit -- "X"), with no directory targets:

  $ dir_id=$(decode_section graph-dict | grep '~_build/default$' | cut -d~ -f1)
  $ out_id=$(decode_section graph-dict | grep '~out.txt$' | cut -d~ -f1)
  $ dep_id=$(decode_section graph-dict | grep '~_build/default/dep.txt$' | cut -d~ -f1)
  $ glob_id=$(decode_section graph-dict | grep '~_build/default/\*\.src$' | cut -d~ -f1)
  $ out_rule=$(decode_section graph-rules | grep "^[0-9]*~$dir_id~$out_id~~X~")
  $ test -n "$out_rule" && echo yes
  yes

Its `<dep_set>` is not a dep list but the id of an entry in `graph-depsets`,
whose record is `<set_id>~<core_id>~<add_ids>`. Reconstructing a set is one
join deep: the (flat) core's members, if it has a core, plus the ids the set
adds. Here there is no core, so the adds are the whole set:

  $ dep_set_ids() {
  >   row=$(decode_section graph-depsets | grep "^$1~")
  >   core=$(echo "$row" | cut -d~ -f2)
  >   { if test -n "$core"; then
  >       decode_section graph-cores | grep "^$core~" | cut -d~ -f2 | tr ',' '\n'
  >     fi
  >     echo "$row" | cut -d~ -f3 | tr ',' '\n'; } | grep . | sort -n
  > }
  $ out_set=$(echo "$out_rule" | cut -d~ -f7)
  $ test -z "$(decode_section graph-depsets | grep "^$out_set~" | cut -d~ -f2)" \
  >   && echo yes
  yes

The set resolves back to exactly the deps the rule was declared with -- dep.txt
and the glob -- both as dict ids and, through the dict, as paths:

  $ test "$(dep_set_ids "$out_set")" \
  >   = "$(printf '%s\n' "$dep_id" "$glob_id" | sort -n)" && echo yes
  yes
  $ for id in $(dep_set_ids "$out_set"); do
  >   decode_section graph-dict | grep "^$id~" | cut -d~ -f2-
  > done | sort
  _build/default/*.src
  _build/default/dep.txt

A rule with no deps at all has an *empty* `<dep_set>`, not a set id -- set ids
start at 0, so this distinction matters. dep.txt's rule is one (and its
dyn-dep stages, also set ids when there are any, are empty too):

  $ dep_target_id=$(decode_section graph-dict | grep '~dep.txt$' | cut -d~ -f1)
  $ dep_rule=$(decode_section graph-rules | grep "^[0-9]*~$dir_id~$dep_target_id~~X~")
  $ test -n "$dep_rule" && echo yes
  yes
  $ echo "$dep_rule" | cut -d~ -f7,8
  ~

Nothing in this build has deps dune could not determine, so no record carries
the "?" that would say so (see the failing build at the end of this file):

  $ decode_section graph-rules | cut -d~ -f7 | grep -c '?'
  0
  [1]

The matching graph-deps records (`<dep_id>~<resolution>~<forced_by>`) resolve
dep.txt to the rule that produces it ("r<rule_id>"), and the glob to its
expanded members, also by dict id rather than full paths ("x<id,id,...>"):

  $ decode_section graph-deps | grep -qE "^$dep_id~r[0-9]+~" && echo yes
  yes
  $ decode_section graph-deps | grep -qE "^$glob_id~x[0-9]+(,[0-9]+)*~" && echo yes
  yes

The /etc/hosts dep, collapsed to a `build-dep-resolved` instant above, is the
"s" case:

  $ decode_section graph-deps | grep -qE '^[0-9]+~s~' && echo yes
  yes

A record's key is exactly what its instants carry: `dep_id` on a build-dep
instant is the dict id the `graph-deps` record starts with, so the timeline
and the graph join without a pairing table. Instant args are ints, and
`dep_id` is the only one on a `build-dep-start`, so the first `int_value` of
each such event is its dep:

  $ first_int_arg() {
  >   awk -v want="$1" '
  >     /^ *event_names \{/ { tbl = 1; next }
  >     tbl && $1 == "iid:" { iid = $2; next }
  >     tbl && $1 == "name:" { gsub(/"/, "", $2); ename[iid] = $2; tbl = 0; next }
  >     /^  track_event \{/ { n++ }
  >     /^    name_iid: / { eid[n] = $2 }
  >     /^        int_value: / { if (arg[n] == "") arg[n] = $2 }
  >     END { for (i = 1; i <= n; i++) if (ename[eid[i]] == want) print arg[i] }
  >   ' dump.textpb
  > }
  $ first_int_arg build-dep-start | sort -u | grep -qx "$dep_id" && echo yes
  yes

`version` is the first int arg of a section instant, and stays 1: the dep-set
sections were folded into the v1 schema rather than bumped onto a v2, the
contract not having shipped to the plugin yet (see
doc/dev/trace-graph-perfetto.md):

  $ first_int_arg graph-rules | sort -u
  1
  $ first_int_arg graph-depsets | sort -u
  1

Overriding the chunk size (bytes) via `DUNE_TRACE_GRAPH_CHUNK_SIZE` forces
several chunks per section without needing a multi-megabyte trace. Records are
newline-terminated, so [decode_all] stitches the chunks by plain concatenation
-- no rejoining of records at the seams. The total record count must stay the
same as the unsplit run, proving the splitter never breaks a record across a
chunk boundary and never drops the separator at one:

  $ decode_all() {
  >   sed -n 's/^ *str: "\([0-9][0-9]*\\t.*\)"$/\1/p' dump.textpb \
  >   | while IFS= read -r chunk; do printf '%b' "$chunk"; done
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

Every chunk ends with a record terminator, including the last one before a
split, so a consumer can concatenate a section's chunks in `seq` order and get
the payload back byte for byte:

  $ export DUNE_TRACE_GRAPH_CHUNK_SIZE=64
  $ dune trace perfetto --text > dump.textpb
  $ chunks=$(grep -c '^ *str: "[0-9][0-9]*\\t' dump.textpb)
  $ terminated=$(grep -c '^ *str: "[0-9][0-9]*\\t.*\\n"$' dump.textpb)
  $ test "$chunks" -gt 1 && test "$chunks" = "$terminated" && echo yes
  yes
  $ unset DUNE_TRACE_GRAPH_CHUNK_SIZE
  $ dune trace perfetto --text > dump.textpb

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
start/finish args (`rule_id` and `dur_ns`) rather than a separate
start/finish pair. Which kind of cache hit it was is a blob field ("L" local,
"S" shared), not an annotation:

  $ DUNE_TRACE=+graph dune build out.txt
  $ dune trace perfetto --text > dump.textpb
  $ event_args | sort -u | grep '^exec-rule-resolved'
  exec-rule-resolved TYPE_INSTANT rule_id,dur_ns
  $ grep -qE 'str: "local-cache-hit"|str: "shared-cache-hit"' dump.textpb && echo yes
  [1]
  $ decode_section graph-rules | grep -qE '~[LS]~' && echo yes
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

Cores appear once dep sets are big enough for one to pay for itself (16 ids).
Two rules with a 40-file fan-in, the second additionally depending on the
first's target: when the second set is encoded, the first is still in the
encoder's window of recent sets, so their intersection is mined into a core --
one core, holding the 40 shared ids:

  $ for i in $(seq 1 40); do touch w$i.dep; done
  $ deps=$(seq 1 40 | sed 's/.*/w&.dep/' | tr '\n' ' ')
  $ cat >dune <<EOF
  > (rule
  >  (target a.txt)
  >  (deps $deps)
  >  (action (with-stdout-to a.txt (echo hi))))
  > (rule
  >  (target b.txt)
  >  (deps $deps a.txt)
  >  (action (with-stdout-to b.txt (echo hi))))
  > EOF
  $ DUNE_TRACE=+graph dune build b.txt
  $ dune trace perfetto --text > dump.textpb
  $ decode_section graph-cores | grep -c .
  1
  $ core_id=$(decode_section graph-cores | cut -d~ -f1)
  $ decode_section graph-cores | cut -d~ -f2 | tr ',' '\n' | grep -c .
  40

The first rule's set is the one the core was mined from, so it has no core of
its own; the second's is that core plus a single add, a.txt:

  $ dir_id=$(decode_section graph-dict | grep '~_build/default$' | cut -d~ -f1)
  $ a_id=$(decode_section graph-dict | grep '~a.txt$' | cut -d~ -f1)
  $ b_id=$(decode_section graph-dict | grep '~b.txt$' | cut -d~ -f1)
  $ a_set=$(decode_section graph-rules | grep "^[0-9]*~$dir_id~$a_id~~X~" | cut -d~ -f7)
  $ b_row=$(decode_section graph-depsets | grep "^$(decode_section graph-rules \
  >   | grep "^[0-9]*~$dir_id~$b_id~~X~" | cut -d~ -f7)~")
  $ test -z "$(decode_section graph-depsets | grep "^$a_set~" | cut -d~ -f2)" \
  >   && echo yes
  yes
  $ test "$(echo "$b_row" | cut -d~ -f2)" = "$core_id" && echo yes
  yes
  $ add_id=$(echo "$b_row" | cut -d~ -f3)
  $ decode_section graph-dict | grep "^$add_id~" | cut -d~ -f2-
  _build/default/a.txt

Reconstruction stays one join deep: the core's members are exactly the first
rule's set, and the second rule's set is that plus its own add:

  $ b_set=$(echo "$b_row" | cut -d~ -f1)
  $ dep_set_ids "$a_set" | wc -l
  40
  $ dep_set_ids "$b_set" | wc -l
  41
  $ test "$(decode_section graph-cores | cut -d~ -f2 | tr ',' '\n' | sort -n)" \
  >   = "$(dep_set_ids "$a_set")" && echo yes
  yes
  $ test "$(dep_set_ids "$b_set")" \
  >   = "$(printf '%s\n' $(dep_set_ids "$a_set") "$add_id" | sort -n)" && echo yes
  yes

Finally the other half of the empty-vs-"?" distinction, on a failing build.
Three rules: one that fails in its action, one that fails building that as a
dep, and one that fails the same way but whose deps cannot even be recovered
afterwards, its dep being behind a `%{read:}` of the broken file (see
`recover_deps` in `src/dune_engine/graph_trace.ml`):

  $ cat >dune <<EOF
  > (rule
  >  (target broken.txt)
  >  (action (with-stdout-to broken.txt (bash "exit 1"))))
  > (rule
  >  (target needs-broken.txt)
  >  (deps broken.txt)
  >  (action (copy broken.txt needs-broken.txt)))
  > (rule
  >  (target reads-broken.txt)
  >  (action (with-stdout-to reads-broken.txt (echo %{read:broken.txt}))))
  > EOF
  $ DUNE_TRACE=+graph dune build needs-broken.txt reads-broken.txt 2> /dev/null
  [1]
  $ dune trace perfetto --text > dump.textpb
  $ dir_id=$(decode_section graph-dict | grep '~_build/default$' | cut -d~ -f1)
  $ broken_id=$(decode_section graph-dict | grep '~broken.txt$' | cut -d~ -f1)
  $ needs_id=$(decode_section graph-dict | grep '~needs-broken.txt$' | cut -d~ -f1)
  $ reads_id=$(decode_section graph-dict | grep '~reads-broken.txt$' | cut -d~ -f1)

The action failure ("A") had resolved no deps, so its `<dep_set>` (and its
dyn-dep stages) are empty:

  $ decode_section graph-rules | grep "^[0-9]*~$dir_id~$broken_id~~A~" | cut -d~ -f7,8
  ~

The dep failure ("D") that recovered its deps names the set holding them,
which resolves back to the file it was waiting for:

  $ needs_set=$(decode_section graph-rules \
  >   | grep "^[0-9]*~$dir_id~$needs_id~~D~" | cut -d~ -f7)
  $ for id in $(dep_set_ids "$needs_set"); do
  >   decode_section graph-dict | grep "^$id~" | cut -d~ -f2-
  > done
  _build/default/broken.txt

The one whose deps could not be recovered says "?", which an empty field would
not distinguish from having none:

  $ decode_section graph-rules | grep "^[0-9]*~$dir_id~$reads_id~~D~" | cut -d~ -f7
  ?
