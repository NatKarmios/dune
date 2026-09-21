# Build-graph traces and the Perfetto export

> **Experimental.** The `graph` trace category, the `dune trace perfetto`
> converter, and the blob schema below are under active development. The
> schema is versioned (`version` is `1`) but is not yet a stable contract:
> it may change without a version bump until the consuming Perfetto plugin
> has shipped against it.

Dune can record the build graph it walks — which rules ran, what forced
them, what each one depended on, and how long each step took — and export
the result as a Perfetto trace. A Perfetto UI plugin consumes that trace and
turns it into a browsable graph on top of the ordinary timeline;
[see here](https://github.com/NatKarmios/perfetto/blob/dune-graph-trace/ui/src/plugins/com.karmios.nat.DuneGraph/README.md)
for more information.

## Not supported yet: watch mode and multiple contexts

The blob schema assumes every unit of work happens exactly once per trace:
one `graph-rules` line per rule, one `graph-deps` line per dep, one
`gen-rules` span per directory. Two situations break that assumption.

In **watch mode**, each iteration re-runs the rules whose inputs changed, so a
target can appear as several `graph-rules` lines with different `rule_id`s
(and a directory as several `gen-rules` spans), with nothing in the trace
saying which iteration a line belongs to.

In a **multi-context build**, rule generation and rule execution are keyed on
the build directory, which includes the context name — `_build/default/foo`
and `_build/alt/foo` are distinct work. The ids are still distinct, so the
graph is not wrong, but nothing groups a line by its context.

Record single-shot, single-context builds until the schema carries an
iteration and a context. A consumer that sees repeats can key graph nodes on
resolved target paths, but merging across iterations is its own problem.

## Producing a trace

The `graph` category is off by default; enable it for the build you want to
record, then convert the trace:

```console
$ DUNE_TRACE=+graph dune build @all
$ dune trace perfetto --trace-file _build/trace.csexp | gzip > build.perfetto.gz
```

Load `build.perfetto.gz` in Perfetto (with the plugin installed, to
get the graph views).

Trace events land in `_build/trace.csexp` unless `dune build --trace-file
FILE` says otherwise.

`dune trace perfetto` options:

- `-o`, `--output FILE` — write there instead of stdout.
- `--text` — human-readable protobuf text dump instead of binary. Useful for
  inspection and for tests.

The `graph` category costs build time and trace size. `dune trace cat` is
unaffected by the Perfetto conversion: it renders the csexp events directly.

## What the converted trace looks like

### Tracks

| track | contents |
|-------|----------|
| `dune` | the process; parent of everything below |
| `main` | thread; every non-async event (complete events become slices, the rest instants) |
| `gen-rules` | rule-generation lifecycle instants |
| `dynamic-includes` | dune-file processing lifecycle instants |
| `build-dep` | dependency lifecycle instants |
| `exec-rule` | rule lifecycle instants |
| `exec-rule-action` | action lifecycle instants (executed rules only) |
| `processes` | parent of the process slice pool |
| `job-001`, `job-002`, … | spawned processes as real slices, one track per concurrent process |
| `dune-graph` | graph blob chunks (instants) |

The table is in display order: `dune` sets `child_ordering: EXPLICIT` and gives
each track under it a `sibling_order_rank`. Job tracks have no rank.

Every graph track holds *instants*, never slices. Instants have no extent, so
unrelated events share one track without Perfetto's stack-nesting semantics
kicking in — this is what keeps the track count constant instead of one track
per span. Tracks are declared lazily, so a build with no
`dynamic-includes` spans declares no such track.

Process spans are the exception: they are true begin/end slices, laid out on a
pool of `job-NNN` tracks. A slot is reused once the process on it has
finished, so the pool is as wide as the concurrency the build actually reached
(bounded by `-j`).

### Lifecycle instants

A span becomes two instants: a `-start` at the span's begin timestamp and a
`-finish` at its end, carrying `dur_ns`. Materializing the interval therefore
needs no pairing join (see the recipe below).

Args are debug annotations nested under a `dune` dict, i.e. they surface in
trace_processor as `debug.dune.<name>`.

On `exec-rule`:

- `exec-rule-start`: `rule_id` (int).
- `exec-rule-finish`: `rule_id`, `dur_ns`.
- `exec-rule-resolved`: the collapsed form (see below); `rule_id`, `dur_ns`,
  placed at the begin timestamp.

On `exec-rule-action`:

- `exec-rule-action-start`: `rule_id`.
- `exec-rule-action-finish`: `rule_id`, `dur_ns`.

On `build-dep`:

- `build-dep-start`: `dep_id` (int) — the dep's intern id.
- `build-dep-finish`: `dep_id`, `dur_ns`.
- `build-dep-resolved`: collapsed form; `dep_id`, `dur_ns`.

On `gen-rules` / `dynamic-includes` (no blob record, so these carry the
`graph-dict` intern id of the path that identifies them, on both ends of the
span, so that either instant on its own says which span it belongs to):

- `gen-rules-start`: `dir_path_id`. `gen-rules-finish`: `dir_path_id`,
  `dune_file_path_id` (when known), `dur_ns`.
- `dynamic-includes-start`: `dune_file_path_id`.
  `dynamic-includes-finish`: `dune_file_path_id`, `dur_ns`.

An instant carries its blob record's key and `dur_ns`, and nothing else:
outcomes, resolutions, targets, deps, and the paths behind the ids are all one
blob lookup away, and repeating them per instant would only cost args-table
rows. `dur_ns` is on the instant because timing is the one thing the blob does
not hold.

### Collapsed instants

A span collapses to a single `-resolved` instant when its outcome says it did
no work *and* it took less than 1 ms:

- `exec-rule`: a local or shared cache hit.
- `build-dep`: a source-file dep.

Everything else — including a cache hit or a source dep that took 1 ms or more
— emits the ordinary `-start`/`-finish` pair, so a contended shared cache or a
cold page cache stays visible as an interval. In an incremental build the
collapsed form is the overwhelming majority of events.

Collapsed instants carry no flow.

### Flows

Each non-collapsed span gets one flow id, chaining its lifecycle in timestamp
order:

```
exec-rule-start → exec-rule-action-start → exec-rule-action-finish → exec-rule-finish
```

Rules that ran no action, and the other span kinds, get the two-hop
`start → finish` chain. The action borrows the rule's flow id, which is what
joins the two tracks.

Flows are a stock-UI affordance. A consumer should join on `rule_id` / `dep_id`
and not depend on flows.

## The graph blob (schema v1)

Graph structure does not go on the instants. It is encoded as five
line-oriented payloads, chunked and emitted as instants on the `dune-graph`
track, one string arg per chunk. That turns O(edges) args-table rows into
O(chunks): a consumer reads the graph with one SQL query instead of scraping
every slice.

Each chunk instant carries `version` (int, `1`), `seq` (int, 0-based within
its section), `total` (int, chunk count for that section), and `data`
(string, ≤ 4 MB). A section with no records emits no instant at all.

Payload framing:

- Records are `\n`-**terminated** (not separated): the last record of a chunk
  keeps its terminator, so concatenating a section's `data` values in `seq`
  order reproduces the payload byte for byte, and each chunk on its own holds
  a whole number of records. Nothing has to be stitched across a seam.
- Fields are `\t`-separated. Strings escape `\\`, `\t`, `\n` C-style.
- Integer lists are `,`-separated.
- Every `*_id` referring to a path or a dep is an intern id resolved through
  `graph-dict`. `rule_id` is the rule's own id.
- Each record's leading id is the arg its span's instants carry — that is the
  join key between timeline and graph.

### `graph-dict` — the intern table

```
<id>\t<string>
```

Emitted in full, sorted by id.

### `graph-rules` — one line per exec-rule span, ordered by span end

```
<rule_id>\t<dir_id>\t<target_file_ids>\t<target_dir_ids>\t<outcome>\t<forced_by>\t<dep_set>\t<dyn_dep_stages>
```

`<outcome>`:

| code | meaning |
|------|---------|
| `X` | executed |
| `L` | local cache hit |
| `S` | shared cache hit |
| `D` | failed before its deps were resolved |
| `A` | failed after its deps were resolved (i.e. in its action) |
| `C` | cancelled because the build was torn down around it |
| `?` | unfinished (see below) |

A `D` line carries the deps the rule's evaluation reached before failing, or
`?` if the failure hid some of them. An `A` line carries the deps it had
resolved. A `C` line carries them if the rule got that far, and `?` otherwise.

`<forced_by>`: `r<rule_id>` | `d<dep_id>` | `i<path_id>`
(dynamic-includes) | `g<path_id>` (gen-rules) | `p<path_id>` (pform) | `c`
(configurator) | `q` (request) | `u` (unknown).

`<dep_set>`: the `set_id` of the rule's dep set in `graph-depsets`; empty when
the rule has no deps; `?` when dune could not determine them (which an empty
field would not distinguish from having none).

`<dyn_dep_stages>`: stages separated by `|`, each a `set_id` of its own;
empty when there are no stages.

### `graph-cores` — the shared parts of dep sets

```
<core_id>\t<dep_ids>
```

A core is flat: its members are intern ids, never other cores. Absent
entirely when nothing in the build was worth factoring.

### `graph-depsets` — one line per distinct dep set, ordered by `set_id`

```
<set_id>\t<core_id>\t<add_ids>
```

`deps(S) = core_members(<core_id>) + <add_ids>`, and that is the whole
reconstruction: cores being flat, membership is one join deep and can be a
plain SQL view. `<core_id>` is empty for a set with no core, in which case the
adds are the entire set. `<add_ids>` can in principle be empty (a consumer
must parse that), but the encoder never emits it: a core is always a strict
subset of its set.

Rule dep sets and dyn-dep stages share this table, so rules with the same deps
share a `set_id`.

### `graph-deps` — one line per build-dep span, ordered by span end

```
<dep_id>\t<resolution>\t<forced_by>\t<status>
```

`<resolution>`: `r<rule_id>` | `s` (source) | `x<id,id,...>` (expanded, e.g.
alias or glob) | `u` (dune could not determine it: building the dep failed or
was cancelled first) | `?` unfinished. `u` and `?` are distinct: `u` means
dune reported that it did not know, `?` that the span never ended.

`<status>`: how building the dep itself ended — empty (succeeded), `f`
(failed), `c` (cancelled). This is orthogonal to `<resolution>`: a file dep
resolves to its producing rule, and a glob to the files it matched, before the
building that can fail, so both report a resolution whether or not that
building went on to succeed.

`<forced_by>` is as in `graph-rules`.

### Unfinished spans

A crash or an interrupt leaves a begin with no matching end. The converter
flushes each still-open span at EOF: a bare `-start` instant on the timeline,
and a `graph-rules` / `graph-deps` line with `?` in place of `<outcome>` /
`<resolution>` and empty `<dep_set>` / `<dyn_dep_stages>` / `<status>`,
appended after the completed lines and ordered deterministically. Every line
of a given kind has the same field count however it was produced.

## Implementation notes

The on-disk csexp format is per-event begin/end pairs — that is what makes it
crash-safe and streamable. All the structure above is built by the converter,
`bin/trace/trace_perfetto.ml`.

- **Span pairing.** Begin events are buffered in a per-kind table keyed by
  `Trace_common.Span_id` — the pair of the event's `async_id` and its `digest`.
  An `async_id` alone is not unique: it counts spans within one dune
  invocation, and a nested dune's events are folded into the same stream,
  tagged with its action digest. Nothing is emitted at begin time; the start
  instant, the finish instant, and the flow are all emitted when the end
  arrives (Perfetto does not require monotonic packet order).
- **The `async_id` is not emitted.** It is converter-internal pairing state;
  consumers join on the blob keys.
- **Dep-set factoring** is `Graph_blob.Dep_sets`. It runs online, as each
  `exec-rule` end is handled, keeping only a window of recent sets, a pool of
  cores, and a map from set to `set_id`. For each new distinct non-empty set
  `S`: take the largest pooled core `C ⊆ S`, accepted only if
  `|C| ≥ 0.5·|S|`; failing that, take the windowed set `B` maximising
  `|S ∩ B|` subject to `|S ∩ B| ≥ max(16, 0.5·|S|)` and register `S ∩ B` as a
  core. The core is used only if `16 ≤ |C| < |S|`, and then the adds are
  `S \ C`. Constants: window 32, pool 64, minimum overlap fraction 0.5,
  minimum core size 16 — chosen by measurement over a real monorepo trace, not
  by taste; a *larger* core pool measured worse, because stale cores win the
  "largest subset" test with a poor covering and displace the mining step.
  Sets are stored as their exact sorted member lists, never digests: a hash
  collision would silently corrupt the graph. Ties break deterministically, so
  a given trace converts byte-identically.
- **Escaping.** Paths containing tabs or newlines are pathological but must
  not corrupt the framing, hence the C-style escapes.
- **Env vars** (test hooks, not user-facing flags): `DUNE_TRACE_GRAPH_CHUNK_SIZE`
  (bytes; forces multi-chunk framing without a multi-megabyte trace) and
  `DUNE_TRACE_COLLAPSE_THRESHOLD_NS` (`0` collapses nothing, which is how
  tests pin collapse behaviour instead of racing the clock). Unparseable or
  out-of-range values fall back to the defaults.

The one dune-side piece is the `exec-rule-action` span
(`src/dune_engine/graph_trace.ml`, hooked around `execute_action_for_rule` in
`src/dune_engine/build_system.ml`). It shares the rule's `async_id`, and
`Exec_rule.start` owns that id, so an action span can only open inside its
rule's span by construction.

## Gotchas

- **The action span is not bounded by `-j`.** The throttle is per-process
  (`Scheduler.with_job_slot`, acquired inside `Process.run`, *below* the
  action hook), so `exec-rule-action` measures "action in flight" — scheduler
  queueing included — not worker occupancy. Peak concurrent action spans is
  the size of the ready set. The `process` events carry the throttled run
  intervals and each process's `queued` duration.
- **`rule_id` and `set_id` are per-process.** They are not stable across
  invocations, and within one invocation they do not identify a repeated unit
  of work (see the watch-mode and multi-context note above).
- **Dep sets are sets.** Ids within a core or an adds list are sorted and
  duplicate-free, so a rule's dependency *declaration order* is not
  recoverable from the blob.
- **`graph-dict` is not filtered** to the ids the graph lines and the
  `*_path_id` instant args reference. This is harmless: `intern` events only cover strings the graph
  category actually used.
- **The converter buffers all packets in memory.** Multi-GB csexp inputs may
  eventually need a streaming writer.
- **Not every `name: "outcome"` in a dump is a rule outcome.** That one is the
  `build` category's `build-finish` event, i.e. the whole build's
  success/failure. Likewise real paths (e.g.
  `_build/default/out.txt`) do appear as interned strings — as the
  user-requested target on the `targets` event, which carries real paths
  rather than intern ids.

## Tests

- `test/blackbox-tests/test-cases/trace/perfetto.t` — the converter: track
  set, instant names and exact arg sets, flows, collapse, the blob sections
  and the joins through them. Unfinished spans are covered there too, by
  truncating a trace file rather than by interrupting a build: `Event_sexp.iter`
  stops at the first record it cannot read, which is what a writer dying
  mid-build leaves behind.
- `test/blackbox-tests/test-cases/trace/graph-events.t` and
  `graph-events-failure.t` — the csexp graph events themselves, including the
  failure and cancellation outcomes.
- `test/blackbox-tests/test-cases/trace/process-events.t` — the process spans.

## Scale

Measured on a real monorepo trace (551 MB csexp, 386,320 `exec-rule` spans):

- Dep edges spelled out literally would be 28,101,156 (rule, dep) pairs, over
  only 205,224 distinct dep sets. Factored, the graph's edge data is 386,320
  rule lines + 205,224 set lines + 3,655,880 adds + 127,399 core members =
  **4,374,823 rows, 15.6% of the literal baseline** (700 cores; 47,170 sets
  got one). Converted output: 181.4 MB, down from 333.6 MB.

