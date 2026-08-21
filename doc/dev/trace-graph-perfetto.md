# Graph trace: Perfetto export redesign

Status: phases 1–8 **implemented**. This document started as the working
plan, executed phase by phase over multiple agent sessions, and serves as
the reference for the converter's design and plugin-facing schema. The
"Plugin-facing schema (v1)" section is the contract; bump `version` on
breaking change once it has shipped to the plugin (phase 8's dep-set
factoring is a breaking change to the blob, but predates that, so it was
folded into v1 rather than bumped onto a v2).

## Motivation

The `graph` trace category records build-graph events (see
`src/dune_engine/graph_trace.ml` and the `Graph` module in
`src/dune_trace/event.ml`), and `dune trace perfetto` (`bin/trace.ml`,
module `Perfetto_conv`) converts them to Perfetto protobuf. A Perfetto UI
plugin (separate codebase) consumes the result to integrate build-graph
exploration with trace exploration; today it scrapes graph data out of
slice debug annotations.

On monorepo-scale builds the converted traces are multi-gigabyte and
impractical for Perfetto. Measured on a synthetic 2000-rule project with
fan-in 50 (~100k dep edges):

- csexp trace: 2.24 MB total; `exec-rule` events 52%, `build-dep` 21%,
  `intern` 17%. The `deps` arrays on exec-rule ends alone are 26% and grow
  linearly with fan-in.
- Perfetto protobuf: 1.41 MB, with **4008 track descriptors for 2002
  spans** (one track per async span). Track count and args-table rows
  (one-plus per dep-array element) are what break the Perfetto UI, well
  before raw bytes.
- Both formats compress ~10:1 with gzip.

## Design summary

All changes are in the **converter** (`bin/trace.ml`). The on-disk csexp
format keeps its per-event begin/end pairs — that is what makes it
crash-safe and streamable — except for one dune-side addition
(`exec-rule-action`, phase 3). Decisions:

1. **Graph data moves out of slice debug annotations into a chunked blob**
   emitted as instants on a dedicated `dune-graph` track, one string arg
   per chunk. This turns O(edges) args-table rows into O(chunks). The
   plugin reads the blob with one SQL query instead of scraping every
   slice.
2. **exec-rule / build-dep / gen-rules / dynamic-includes spans become
   start/finish instant pairs** on one shared track per kind. Instants
   have no nesting semantics, so unrelated events can share a track;
   per-span tracks disappear. Demand-to-completion intervals were mostly
   waiting, so duration bars overstated work anyway.
3. **Finish instants carry `dur_ns`** so the interval is one click away in
   the UI and reconstructable in SQL without pairing joins (enables the
   debug-track recipe below).
4. **Near-zero spans collapse to a single instant** (cache hits,
   source-file deps, and only when the span took under 1ms) — the
   overwhelming majority of events in incremental monorepo builds.
5. **One flow per span chains its lifecycle**: for executed rules,
   `exec-rule-start` → `exec-rule-action-start` → `exec-rule-action-finish`
   → `exec-rule-finish` (a flow id's consecutive appearances link in
   timestamp order, so a single id per rule produces exactly this chain;
   the middle two are skipped when no action ran); for other non-collapsed
   spans, start → finish. Collapsed instants carry no flow. Measured cost
   on a cold build (worst case — nothing collapses): ~6.5% of total wire
   output; incremental builds pay proportionally less. Flows for graph
   *edges* are rejected: fan-out would need one id per edge patched onto
   already-emitted forcer instants; the blob carries those edges instead.
6. **New dune-side `exec-rule-action` span** wrapping the action execution
   (Step IV in `build_system.ml`, `execute_action_for_rule`), sharing the
   rule's `async_id`, rendered as start/finish instants on its own track
   like the other kinds (phase 6; phase 3 originally rendered pooled
   duration lanes). Note its extent is *not* bounded by `-j`: the `-j`
   throttle is per-process (`Scheduler.with_job_slot`, acquired inside
   `Process.run`, below this hook), so the span includes scheduler
   queueing and peak concurrency is the ready set — the observation that
   forced the phase 6 revision. Cache-hit rules have no action span.
7. **An instant carries only its blob record's key and `dur_ns`** (phase 7).
   The key is `rule_id` for the rule kinds and `dep_id` (an intern id) for
   `build-dep`; `dur_ns` is the one thing the blob does not hold, being
   timing rather than structure. Outcomes, resolutions, and the paths behind
   the ids are one blob lookup away, so repeating them per instant only buys
   args-table rows. The csexp `async_id` is not emitted at all: it is
   converter-internal pairing state, and the plugin joins on the blob keys.
   `gen-rules`/`dynamic-includes` have no blob record and so keep the path
   that identifies them.
8. **Dep sets are factored into "core + adds"** (phase 8) instead of being
   spelled out per rule: a rule names its dep set by id, and the set is a
   shared core plus the ids it adds. Cores are flat, so a consumer
   reconstructs membership with one join. On a monorepo trace this is 15.6%
   of the (rule, dep) rows the literal lists cost.

Perfetto ground rules this design leans on:

- Slices on one track have stack semantics; any temporal containment
  nests. Only share a track between spans when nesting is intended or
  impossible (instants have no extent, so any number share a track
  safely — after phase 6 every graph track is instants-only).
- Same-named child tracks of a process are merged and lane-packed by the
  UI; distinctly-named tracks each get a row. Identity therefore lives in
  args, not track names.
- A UI plugin can only see what trace_processor ingests into SQL tables.
  Debug annotations are the most expensive route (rows per element);
  a single string arg is the cheapest (one row, one string-pool entry).

## Target Perfetto model

Track layout (uuids are converter-internal; names are the contract):

| track            | kind                    | contents                          |
|------------------|-------------------------|-----------------------------------|
| `dune`           | process                 | —                                 |
| `main`           | thread                  | flat complete/instant events (unchanged) |
| `exec-rule`      | child of process        | exec-rule lifecycle instants      |
| `build-dep`      | child of process        | build-dep lifecycle instants      |
| `gen-rules`      | child of process        | gen-rules lifecycle instants      |
| `dynamic-includes` | child of process      | dynamic-includes lifecycle instants |
| `dune-graph`     | child of process        | graph blob chunks (instants)      |
| `exec-rule-action` | child of process      | action lifecycle instants         |

Converter mechanics: buffer begin events in a table keyed by `async_id`
(begin timestamp + parsed args); emit nothing at begin time. At the
matching end, emit the start instant (at the begin timestamp — Perfetto
does not require monotonic packet order), the finish instant (with
`dur_ns`), and the linking flow — or a single collapsed instant. At EOF,
flush unmatched begins as bare `-start` instants (crash/interrupt case).

## Plugin-facing schema (v1)

All args below are debug annotations nested under the `dune` dict, i.e.
they surface in trace_processor as `debug.dune.<name>` keys (verify the
exact prefix against the plugin's current scraping; it is unchanged from
today's converter output).

### Lifecycle instants

An instant carries the key of its span's blob record and, once an interval
has been measured, `dur_ns` (int, nanoseconds) — nothing else. The csexp's
`async_id` is not emitted; it pairs begin with end inside the converter only.
An id that fails to parse as an int (malformed trace) is omitted, and an
instant left with no args emits no `dune` dict at all.

On track `exec-rule`:

- `exec-rule-start`: `rule_id` (int).
- `exec-rule-finish`: `rule_id`, `dur_ns`.
- `exec-rule-resolved`: collapsed form used when the outcome is a cache hit
  *and* the span took less than 1ms; placed at the begin timestamp;
  `rule_id`, `dur_ns`. Which outcome it was is in `graph-rules`. A rule that
  failed or was cancelled keeps the `exec-rule-start`/`-finish` pair, since it
  occupied that span of time — and so does a cache hit that took 1ms or more
  (a contended shared cache), whose interval is worth seeing.

On track `build-dep`:

- `build-dep-start`: `dep_id` (int) — the dep's intern id, resolved via
  `graph-dict`, and the key its `graph-deps` record starts with.
- `build-dep-finish`: `dep_id`, `dur_ns`.
- `build-dep-resolved`: collapsed form used when the dep is a source file
  *and* the span took less than 1ms; `dep_id`, `dur_ns`. What the dep resolved
  to — producing rule, expansion contents, or source — is in `graph-deps`. A
  source dep that took 1ms or more (a cold page cache) keeps the
  `build-dep-start`/`-finish` pair.

On track `exec-rule-action` (executed rules only):

- `exec-rule-action-start`: `rule_id` (int) — the join key between an action
  and its rule (they share an `async_id` in the csexp, which is not
  emitted).
- `exec-rule-action-finish`: `rule_id`, `dur_ns`.

Note the action interval includes scheduler queueing (`-j` is enforced
per-process, below this span), so it measures "action in flight", not
worker occupancy; the `process` events carry the throttled run intervals
and per-process `queued` durations.

On tracks `gen-rules` / `dynamic-includes` (no blob record, so these keep the
path that identifies them; both are plain paths in the csexp event, not
intern ids):

- `gen-rules-start`: `dir` (string). `gen-rules-finish`: `dune_file`
  (string, when known), `dur_ns`.
- `dynamic-includes-start`: `dune_file` (string).
  `dynamic-includes-finish`: `dur_ns`.

`target_files`, `target_dirs`, `deps`, `dyn_deps`, `forced_by`, expansion
lists, `outcome`, `outcome_kind`, and the resolved `dir`/`dep` paths **no
longer appear on instants**; they are in the blob.

A fresh `flow_ids` value per non-collapsed span chains its lifecycle:
`exec-rule-start` → `exec-rule-action-start` → `exec-rule-action-finish`
→ `exec-rule-finish` for executed rules; plain start → finish for
`build-dep`, `gen-rules`, and `dynamic-includes` (and for exec-rule
spans where no action ran). Collapsed instants carry no flow. The flow
is a stock-UI affordance; the plugin pairs via the `rule_id`/`dep_id` args
and should not depend on flows.

### Graph blob

Instants on track `dune-graph`, timestamped at the last event seen. Five
event names, each carrying args: `version` (int, `1`), `seq` (int,
0-based per name), `total` (int, chunk count per name), `data` (string,
≤ 4 MB, split only on record boundaries). A section with no records emits
no instant at all, so a build whose dep sets are all too small to factor
has no `graph-cores` event (and one with no graph data has none of them).

Payloads are line-oriented (`\n`-*terminated* records, `\t`-separated
fields). Every record carries its terminator, including the last record of
a chunk, so a consumer reassembles a section by concatenating its `data`
values in `seq` order — the result is the payload byte for byte, and each
chunk taken alone holds a whole number of records. Nothing has to be
stitched back together across a seam. Strings escape `\\`, `\t`, `\n` C-style. Integer lists are
`,`-separated. All `<*_id>` values referring to paths/deps are intern ids
resolved via `graph-dict`; `rule_id` is the rule's own id. Each record's
leading id is also the arg its span's instants carry (`rule_id` /
`dep_id`) — that is the join key between timeline and graph.

- `graph-dict` — the intern table:

      <id>\t<string>

- `graph-rules` — one line per exec-rule span occurrence, ordered by span
  *end* (watch mode can produce several lines per target; `rule_id` values
  are per-process and may differ across watch iterations for the same target
  — the plugin should key nodes on resolved target paths when merging):

      <rule_id>\t<dir_id>\t<target_file_ids>\t<target_dir_ids>\t<outcome>\t<forced_by>\t<dep_set>\t<dyn_dep_stages>

  `<outcome>`: `X` executed, `L` local cache hit, `S` shared cache hit, `D`
  failed before its deps were resolved, `A` failed after its deps were
  resolved (i.e. in its action), `C` cancelled because the build was torn
  down around it, `?` unfinished (see below). A `D` line carries the deps dune
  recovered for the rule (or `?`, below, if it could not); `A` carries the deps
  it had resolved; a `C` line carries them if the rule got as far as resolving
  them, and `?` otherwise -- a cancelled rule is never made to recover them,
  since the build is going away.
  `<forced_by>`: `r<rule_id>` | `v<rule_id>` (recovering that rule's deps
  after it failed, see `<outcome>` `D`) | `d<dep_id>` | `i<path_id>`
  (dynamic-includes) | `g<path_id>` (gen-rules) | `p<path_id>` (pform) |
  `c` (configurator) | `q` (request) | `u` (unknown).
  `<dep_set>`: the `set_id` of the rule's dep set in `graph-depsets`, empty
  when the rule has no deps, `?` when dune could not determine them (which
  an empty field would otherwise not distinguish from having none).
  `<dyn_dep_stages>`: stages separated by `|`, each stage a `set_id` of its
  own (stages go through the same dep-set table and the same factoring);
  empty when there are no stages.

- `graph-cores` — the shared parts of dep sets, one line per core:

      <core_id>\t<dep_ids>

  A core is flat: its `<dep_ids>` are intern ids, never other cores'. Absent
  entirely when nothing in the build was worth factoring.

- `graph-depsets` — one line per distinct dep set (rule dep sets and
  dyn-dep stages share this table), ordered by `set_id`:

      <set_id>\t<core_id>\t<add_ids>

  `deps(S) = core_members(<core_id>) + <add_ids>`, and that is the whole
  reconstruction: cores being flat, membership is one join deep and can be a
  plain SQL view. `<core_id>` is empty for a set with no core, in which case
  the adds are the entire set. `<add_ids>` can in principle be empty (a
  consumer must parse that), but the encoder never emits it: a core is
  always a strict subset of its set.

  Rules referring to the same set share its `set_id`; the id is per-process,
  like `rule_id`. A dep set is a *set*: the ids in a core or an adds list are
  sorted (as text) and duplicate-free, so a rule's declaration order is not
  recoverable from the blob, which the literal id lists used to preserve.

- `graph-deps` — one line per build-dep span, ordered by span end:

      <dep_id>\t<resolution>\t<forced_by>\t<status>

  `<resolution>`: `r<rule_id>` | `s` (source) | `x<id,id,...>`
  (expanded, e.g. alias/glob) | `u` (dune could not determine it: building the
  dep failed or was cancelled first) | `?` unfinished (see below). `u` and `?`
  are distinct: `u` means dune reported that it did not know, `?` that the span
  never ended at all.
  `<status>`: how building the dep itself ended -- empty (succeeded), `f`
  (failed), `c` (cancelled). This is orthogonal to `<resolution>`: a file dep
  resolves to its producing rule, and a glob to the files it matched, before
  the building that can fail, so both report a resolution whether or not that
  building went on to succeed.

  **Unfinished spans** (a crash or interrupt leaves a begin with no matching
  end — see `test/blackbox-tests/test-cases/trace/interrupted-watch-build-events.t`
  for a trace that can produce these): the converter flushes each open span
  at EOF as a `graph-rules`/`graph-deps` line with `?` in place of `<outcome>`
  /`<resolution>` and empty `<dep_set>`/`<dyn_dep_stages>`/`<status>`, appended
  after the completed lines and sorted by `async_id` for determinism. Every line
  of a given kind has the same field count however it was produced.

### Debug-track recipe (interval materialization)

To show "how long did this rule take to resolve, dependencies and all" as
a real slice, the plugin (or a user via the stock debug-tracks feature)
materializes intervals from finish instants — no pairing join needed:

```sql
SELECT s.ts - extract_arg(s.arg_set_id, 'debug.dune.dur_ns') AS ts,
       extract_arg(s.arg_set_id, 'debug.dune.dur_ns') AS dur,
       s.name AS name
FROM slice s
JOIN track t ON s.track_id = t.id
WHERE t.name = 'exec-rule'
  AND extract_arg(s.arg_set_id, 'debug.dune.rule_id') IN (<cone rule ids>)
```

The cone is computed from the blob adjacency. Demand-to-done for a rule
includes its transitive dep resolution by construction, so the single
slice answers the headline number and the cone breakdown explains it.

## Implementation phases

### Phase 1 — graph blob (converter, additive) — **implemented**

Emit the blob without removing anything, so the plugin keeps working on
intermediate commits.

- In `Perfetto_conv` (`bin/trace.ml`): accumulate, while streaming events,
  (a) the intern table (already in `t.names`), (b) per-exec-rule-span
  records from begin args (dir/targets/forced_by, keyed by `async_id`
  until the end supplies deps/dyn_deps/outcome), (c) per-build-dep-span
  records likewise.
- After `iter_sexps`, encode the three sections per the schema above,
  chunk at 4 MB on line boundaries, and append instants on a new
  `dune-graph` child track.
- Escaping helper + tests for it (paths containing tabs/newlines are
  pathological but must not corrupt the framing).
- Tests: extend `test/blackbox-tests/test-cases/trace/perfetto.t` — assert
  the `dune-graph` track exists, `graph-dict`/`graph-rules`/`graph-deps`
  events appear with `version`/`seq`/`total`, and (via `--text` output)
  that a known rule line references the dict ids of its targets.

Implementation notes / deviations from the schema as originally drafted:

- Chunk size is overridable via the `DUNE_TRACE_GRAPH_CHUNK_SIZE` environment
  variable (bytes; non-positive or unparseable values fall back to the 4 MB
  default), so a test can force multi-chunk framing without a
  multi-megabyte trace. Not a documented user-facing flag — it exists purely
  so `perfetto.t` can exercise the chunker's line-boundary splitting.
- Records are newline-*terminated*, not newline-separated: the chunker keeps
  the terminator on the last record of a chunk. Separator framing dropped the
  newline at every seam, so a consumer concatenating chunks silently glued the
  records either side of a split into one malformed record.
- Unmatched begins (see "Unfinished spans" above) are a v1 schema addition
  (`?` for `<outcome>`/`<resolution>`) not present in the original draft of
  this document.
- The intern table (`graph-dict`) is emitted in full, sorted by id, from the
  converter's already-reconstructed `t.names` table — it is not limited to
  ids actually referenced by `graph-rules`/`graph-deps` (harmless: `intern`
  events cover only strings the graph category actually used).

### Phase 2 — spans → instants, per-kind tracks, arg slimming — **implemented**

*The arg set kept here is slimmed further by phase 7 (`async_id`, `dir`
/`dep`, `outcome`, and `outcome_kind` all go); the track and buffering
scheme is unchanged.*

- Replace the per-span `ensure_async_track` scheme with fixed per-kind
  tracks; delete `seen_async`/`async_uuid` as such.
- Buffer begins keyed by `async_id`; emit start/finish (or collapsed)
  instants at end time per "Target Perfetto model" above; compute
  `dur_ns`; EOF-flush unmatched begins.
- Remove `deps`, `dyn_deps`, `target_files`, `target_dirs`, `forced_by`,
  and expansion args from slices (they are now blob-only); keep
  `rule_id`, `async_id`, `dir`/`dep`, `outcome`, `dur_ns`.
- Tests: `perfetto.t` — track descriptors are now O(1) count (assert the
  exact set of track names); `TYPE_INSTANT` events with the new names;
  `dur_ns` present on finishes; a cache-hit build produces `-resolved`
  instants; deps no longer appear as slice annotations.
- Note: the JSON/Chrome outputs of `dune trace cat` are untouched (they
  render the csexp events directly).

Implementation notes / deviations from the schema as originally drafted:

- Per-kind tracks are still declared lazily (the first time an instant is
  pushed to them), matching phase 1's `dune-graph` track: a trace with no
  `dynamic-includes` spans (e.g. a project with no subdirectories) simply
  never declares that track, rather than always declaring all four.
- gen-rules/dynamic-includes finish instants do not repeat their start-only
  identifying field (`dir` / `dune_file` respectively): only `dune_file` (for
  gen-rules, when known), `dur_ns`, and `async_id` (dropped by phase 7) are
  on the finish. This
  mirrors exec-rule's asymmetry (`dir` is start-only there too) and was a
  reading of the schema table's compressed "start / finish" row, which did
  not spell out which fields belong to which side.
- `build-dep-finish`/`-resolved` always carry `outcome_kind`
  (`"rule"|"expanded"|"is-source"`) rather than only conditionally
  including it; `rule_id` is additionally present when the kind is
  `"rule"`. The schema's phrasing ("the outcome kind: `rule_id` (int) when
  the dep resolved to a rule; `outcome_kind` (...)") was ambiguous between
  this and an either/or; the implemented form keeps the arg set
  self-describing without a join. *(Superseded by phase 7: the resolution is
  blob-only, so neither arg is emitted.)*
- `exec-rule`'s `rule_id`/`build-dep`'s `rule_id` (when present) degrade to
  omitting the arg (rather than a `"?"` placeholder) if the underlying
  atom fails to parse as an int; this can only happen on a malformed trace
  and mirrors other defensive fallbacks in the converter.
- A missing `dep_outcome` on a `build-dep` end (malformed trace) degrades
  to `outcome_kind: "?"` and still emits the start/finish pair, mirroring
  `exec-rule`'s `rule_outcome` fallback. An earlier version of this dropped
  the perfetto instants silently in this case while still emitting a `"?"`
  graph-blob line, so the blob and the slice track could disagree on
  whether the span existed; caught in review before landing. *(Phase 7 drops
  the arg; the "not a source dep, so emit the pair" fallback stays.)*
- `perfetto.t`'s test project depends on `/etc/hosts` (outside the
  workspace, following the precedent in
  `melange/emit-with-runtime-deps-edge-cases.t`) to exercise
  `build-dep-resolved`'s `is-source` collapse — depending on a project
  source file resolves to the `"rule"` outcome instead, via dune's
  implicit copy-to-build-dir rule, which surprised an earlier draft of
  this test that tried a plain in-project source dep. `/etc/hosts`-style
  paths are Unix-only; this is fine here since blackbox cram tests are not
  run on Windows CI (`test/blackbox-tests/test-cases/dune`'s
  `runtest-windows` alias only allowlists two unrelated tests).

### Phase 3 — `exec-rule-action` duration spans (dune-side + converter) — **implemented**

*Converter rendering (pooled duration lanes) superseded by phase 6; the
dune-side events are unchanged.*

- Dune side: new begin/end async event pair in
  `src/dune_trace/event.ml`/`.mli` (`Graph.Exec_rule_action`), **sharing
  the exec-rule span's `async_id`** so the pair nests inside the rule's
  span as a Chrome nestable-async chain (this is the documented semantics
  of same-id begin/end pairs in `event.ml`, and `--chrome-trace` output
  renders the nesting with no extra work). Integrate into the existing
  `Exec_rule` helper in `src/dune_engine/graph_trace.ml` rather than
  adding a sibling module: `Exec_rule.start` owns the async_id, so extend
  what it hands to `f` with an action-wrapping function (alongside the
  existing `finish` callback) that emits the begin/end around a given
  fiber. This keeps the id encapsulated and makes the nesting invariant
  structural — an action span can only open inside its rule's span. Hook
  the wrapper in `src/dune_engine/build_system.ml` around
  `execute_action_for_rule` (Step IV — after both cache lookups, so spans
  exist only for executed rules). Args: `rule_id` (kept for direct
  SQL/plugin joins even though the shared id implies it).
- Converter: render as real Begin/End slices on pooled lanes — maintain a
  free-list of track uuids, all named `exec-rule-action`; pop on begin,
  push back on end; key the open-span table by *(event name, async_id)*
  since the id is now shared with the rule's lifecycle events. Pool size
  is bounded by `-j` in practice. Anything later added semantically
  inside the action (sandbox phases, process run) may share the lane
  track: temporal containment there is real, so stack nesting is correct.
- Tests: `graph-events.t` for the new csexp events (begin/end pairing,
  only on executed rules — rebuild from cache produces none). The
  existing pairing assertion ("exactly one begin and one end per
  async_id" over `exec-*` events) must now group by *(name, async_id)*.
  `perfetto.t` for lane reuse (track count stays small) and slice type.

Implementation notes / deviations from the schema as originally drafted:

- [f]'s handles are labeled arguments (`~finish` and `~trace_action`); the
  wrapper takes a thunk (`(unit -> 'b Fiber.t) -> 'b Fiber.t`) so the begin
  is emitted when the wrapped fiber actually starts, not when it is built.
- An action begin left unmatched at EOF (crash/interrupt mid-action) is left
  as an open `SLICE_BEGIN` on its lane — trace_processor renders unterminated
  slices to the end of the trace, which is the honest reading — rather than
  synthesised into a `-start` instant like the instant-pair kinds.
  *(Superseded by phase 6: it is a bare `-start` instant like the rest now.)*
- If the action fails (build error), neither the action end nor the rule's
  end is emitted; both surface via the unfinished-span paths above.
- `perfetto.t`'s lane assertions are invariants (begins = ends; lanes <
  slices), not exact counts: besides the project rules, a fresh build also
  executes internal rules (context configurator probes, copy-to-build-dir
  rules for in-project source deps) whose actions can overlap, so the lane
  count is only bounded by actual concurrency, not fixed. The test's project
  rules form a dep chain, guaranteeing at least one lane reuse.
- `perfetto.t` now captures `dune trace perfetto --text` to a file once per
  build and greps that: cram runs bash with `pipefail`, and the dump has
  grown past the pipe buffer, so a `grep -q` exiting early would kill the
  producer with SIGPIPE (observed as exit 141) — a latent problem this
  phase's extra output exposed.

### Phase 4 — lifecycle flows — **implemented**

*The action's participation in the chain is revised by phase 6 (two
instants instead of one Begin slice); the flow-id bookkeeping below is
otherwise unchanged.*

- Allocate a fresh flow id per non-collapsed span when its begin is
  buffered; set `flow_ids` on the start instant, the matching
  `exec-rule-action` Begin slice (trivially looked up: it shares the
  rule's `async_id`, and the action always begins after the rule's begin
  and ends before its end), and the finish instant. `Dune_perfetto.Event.create ~flow_ids` and the
  field-47 serialisation already exist.
- This requires action slices to be constructed at action-*end* time (so
  the begin can carry the flow id); the converter already buffers all
  packets in memory and Perfetto does not require monotonic packet order,
  so this is only a bookkeeping change. Flow chaining follows timestamp
  order, giving start → action → finish.
- **Verify in the Perfetto UI that flow arrows render on `TYPE_INSTANT`
  endpoints** (dur=0 is a less-traveled path). If rendering is broken,
  keep the ids (still queryable in the `flow` table) and note the
  limitation.
- Measured cost (synthetic 2000-rule cold build, worst case): ~6.5% of
  total wire output, 14.6% of the instant stream. Collapsed (cache-hit /
  source) instants carry no flow, so incremental builds pay less.
- Tests: `perfetto.t` asserts the same flow id appears on start, action
  begin, and finish for an executed rule, and on start+finish for a
  non-collapsed `build-dep` span (the other kinds without an action work
  identically).

Implementation notes / deviations from the schema as originally drafted:

- A flow id is allocated for *every* buffered begin, not only non-collapsed
  spans — collapse status is unknown until the end arrives. A collapsed
  span's id is simply never emitted, so the ids appearing in a trace are
  not contiguous.
- Deferring action-slice construction to action-end time turned out to be
  unnecessary: the flow id lives in the buffered `rule_begin`, and the
  action Begin always arrives while the rule's begin is still buffered
  (they share `async_id`), so the Begin picks the id up by table lookup at
  the time it is pushed. (Phase 6 keeps this: the action's begin is now
  buffered rather than pushed, and borrows the rule's flow id at that same
  point, for both of its instants.)
- EOF-flushed bare `-start` instants (crash/interrupt) keep their flow id:
  for a rule that crashed mid-action, the action's Begin slice already
  carries the id, so the start → action arrow survives. Elsewhere the id
  ends up on a single event, which draws nothing and is harmless.
- `perfetto.t`'s flow assertions resolve `name_iid` against the interned
  `event_names` table in the `--text` dump. Two traps documented in the
  test: a name's `interned_data` definition sits *after* the first
  track_event referencing it in the same packet (interning happens at
  first use), and debug annotations carry `name_iid:` lines from a
  *different* intern table, so event-level fields must be matched by their
  exact indentation. An earlier draft of the test ignored the second trap
  and passed on one trace by iid coincidence while failing on another.

### Phase 5 — docs and follow-ups — **implemented**

- Update the trace section of `doc/hacking.rst` and this document to
  "implemented" status; record any schema deviations discovered in
  phases 1–4 (the plugin schema section above is the contract — bump
  `version` on breaking change).
- Done: `doc/hacking.rst` (trace section) and
  `doc/advanced/profiling-dune.rst` now document `dune trace perfetto`
  and the `graph` category, pointing here for the plugin schema. Schema
  deviations were recorded incrementally in each phase's implementation
  notes above — none require a `version` bump; the wire format matches
  the v1 schema as annotated.
- Monorepo-scale re-measurement (last checklist item) — synthetic
  2000-rule project, fan-in 50 (sliding window over the previous 50
  targets, ~99k dep edges), cold build, measured against the baseline in
  "Motivation":
  - Track descriptors: **7** (was 4008) — process, main thread, the
    per-kind instant tracks, one `exec-rule-action` lane (the
    sliding-window topology serialises the build, so one lane sufficed;
    this measurement's "lane count is bounded by `-j`" reading was
    **wrong** — see phase 6 — the serial topology masked it), and
    `dune-graph`.
  - Perfetto pb: 1.51 MB (was 1.41 MB). The slight growth is honest
    accounting: the pb now additionally carries the graph blob (~620 KB
    of it — `graph-rules` ~503 KB, `graph-dict` ~79 KB, `graph-deps`
    ~41 KB, one chunk each), lifecycle flows, and 2000 action slices.
    Bytes were never the UI bottleneck; rows were.
  - Args-table load: ~14k debug-annotation blocks / ~30k annotation
    values total (small ints and interned strings), versus one-plus rows
    per dep-array element before (~100k+ for the dep arrays alone). Dep
    edges now cost SQL rows only via 3 blob strings.
  - csexp: 2.60 MB (was 2.24 MB; growth is the phase-3
    `exec-rule-action` begin/end pairs). gzip: csexp 271 KB (~10:1),
    pb 315 KB (~4.8:1 — the pb's varint-heavy encoding compresses less
    than the textual csexp, but is already ~40% smaller uncompressed).
- Known limitations / candidates deliberately out of scope:
  - Converter buffers all packets in memory; multi-GB csexp inputs may
    need a streaming writer eventually.
  - csexp on-disk size (compression on write, shorter framing,
    relative timestamps) — orthogonal; gzip already recovers ~10:1.
  - forced-by flows (id-per-edge, requires patching emitted instants) —
    superseded by the blob unless UI arrows are wanted.
  - Splitting exec-rule lifecycle into demand vs. execute on the dune
    side.

### Phase 6 — `exec-rule-action` as lifecycle instants (converter-only) — **implemented**

Motivation: real traces show far more concurrent action slices than `-j`.
The `-j` throttle is acquired per-process by `Scheduler.with_job_slot`
inside `Process.run_internal` (`src/dune_engine/process.ml`, where the
process event's `queued` duration is measured), i.e. *below* the
`execute_action_for_rule` hook — so an action span opens as soon as the
rule's deps are ready and includes scheduler queue wait. Peak open
actions is the ready set, not the worker pool; the phase 3 lane pool is
therefore unbounded in practice, partially resurrecting the
track-explosion problem it was meant to avoid.

Changes (dune-side events are untouched):

- Drop the lane pool and free-list entirely. Declare a single
  `exec-rule-action` child track (lazily, like the other kinds).
- Buffer action begins in the same (name, `async_id`)-keyed pending table
  as the other kinds; at action end, emit `exec-rule-action-start` (at
  the begin timestamp) and `exec-rule-action-finish` (with `dur_ns`)
  instants, args per the schema section. No collapse: executed actions
  are real work and comparatively few.
- Flows: apply the rule's flow id (already looked up via the shared
  `async_id`) to both action instants, yielding the four-hop chain
  `exec-rule-start` → `exec-rule-action-start` →
  `exec-rule-action-finish` → `exec-rule-finish`; timestamp-ordered
  chaining produces exactly this path. Rules with no action keep the
  two-hop chain.
- EOF flush: an action begin left unmatched becomes a bare
  `exec-rule-action-start` instant, uniform with the other kinds
  (supersedes phase 3's open-`SLICE_BEGIN` behavior; the flow id on it
  still draws the start → action-start arrow).
- Tests (`perfetto.t`): replace the lane-reuse invariants with: no
  `SLICE_BEGIN`/`SLICE_END` on graph tracks at all (everything is
  `TYPE_INSTANT` now); exactly one `exec-rule-action` track; the same
  flow id on all four chain points for an executed rule; `dur_ns` on
  action finishes.

Implementation notes / deviations from the schema as originally drafted:

- The pending table stays per-kind (`open_actions`, keyed by `async_id`)
  rather than becoming one table keyed by *(name, `async_id`)*: the
  converter never had the single keyed-by-pair table phase 3 described, and
  a separate table per kind already distinguishes the action from the rule
  it shares an id with.
- The action's begin no longer allocates a flow id of its own (phase 3's
  Begin slice did not either); it borrows the rule's from `open_rules` when
  it is buffered, and both instants carry it. A malformed rule begin (never
  buffered) leaves the action's instants without a flow, mirroring how the
  other kinds' malformed begins drop out of the lifecycle.
- Track count on `perfetto.t`'s project is now an exact assertion (7) rather
  than the phase 3 arithmetic over the lane count, since it no longer varies
  with action concurrency.
- `perfetto.t` grew an `event_args` helper (resolves each track_event to
  "<name> <type> <arg names>" against the two intern tables, matching
  `name_iid:` by indentation as `flow_events` does) so the action instants'
  arg sets are asserted exactly, rather than by greps for individual names
  that could match any other event.
- `graph-events.t`'s prose claimed the action span is "bounded by -j"; that
  was the phase 3 misreading this phase corrects, so it is fixed there too
  (the dune-side events themselves are unchanged).

### Phase 7 — instants carry ids only (converter-only) — **implemented**

Motivation: after phase 2 the instants still repeated data the blob already
carries — a resolved `dir`/`dep` path, the rule's `outcome`, the dep's
`outcome_kind` and producing `rule_id` — plus an `async_id` nothing
downstream reads (Perfetto pairs nothing on it; the plugin joins on the blob
keys). Every one of those is an args-table row per instant, and the resolved
paths additionally pull a string-pool entry per distinct path, for data one
blob lookup already answers.

Changes (dune-side events are untouched; the blob format is unchanged, so
`version` stays `1` — the v1 contract has not shipped to the plugin yet, and
the schema section above is the contract as of landing):

- Drop `async_id` from every emitted instant. The `~async_id` parameter goes
  with it from the `emit_*_end`/`push_action_start` functions; the buffering
  tables and the EOF flush's sort-by-`async_id` are unaffected.
- Drop `dir` from exec-rule instants, `outcome` from `exec-rule-finish`
  /`-resolved`, and `outcome_kind` + the dep's `rule_id` from
  `build-dep-finish`/`-resolved`. The rule's outcome is still read at the end
  event — it decides the collapse — but only the blob records it.
- `build-dep` instants carry `dep_id` (the dep's intern id, raw as it arrives)
  instead of the resolved `dep` string: it is the key of the span's
  `graph-deps` record, so it plays the role `rule_id` plays for rules.
- `resolve_id` is gone: nothing resolves intern ids into instants any more,
  and `t.names` is used only to emit `graph-dict`.
- `dune_args` returns no dict at all for an empty arg list, reachable now
  that a malformed (non-integer) `rule_id`/`dep_id` can leave an instant with
  nothing else to say.
- Tests (`perfetto.t`): exact arg sets per event name (via the phase 6
  `event_args` helper) for all four kinds; `async_id`/`dep`/`outcome_kind`
  /`str: "executed"` absent; the outcome asserted on the blob's `graph-rules`
  record instead; and a `first_int_arg` helper checking that the `dep_id` on
  dep.txt's `build-dep-start` is the dict id its `graph-deps` record is keyed
  on.

Implementation notes:

- `name: "outcome"` still appears in the dump — it is the `build` category's
  `build-finish` event (success/failure of the whole build), unrelated to a
  rule's outcome. `perfetto.t` asserts this explicitly so the grep is not
  mistaken for a leftover graph annotation.
- `_build/default/out.txt` likewise survives as an interned string, as the
  user-requested target on the `targets` event (real paths, never intern
  ids). The phase 2 prose had attributed that string to a build-dep instant,
  which was wrong even then; the test says so now.
- gen-rules/dynamic-includes keep their path args: they have no blob record
  to look anything up in. A `gen-rules-finish` for a directory that is not
  standalone/group-root carries only `dur_ns`.
- Stock-UI cost: clicking an instant now shows an id rather than a path, so
  the raw timeline is less readable without the plugin. That is the trade the
  blob was introduced to make; the flows and `dur_ns` (see the debug-track
  recipe) are what the stock UI still answers on its own.

### Phase 8 — factored dep sets (converter-only) — **implemented**

Motivation: `graph-rules` spelled each rule's deps out as a literal id list,
so a consumer scraping the blob into a database got one edge row per
(rule, dep) pair. Measured on a real monorepo trace (551 MB, 386,320
`exec-rule` spans): **28,101,156 pairs, but only 205,224 distinct dep
sets** — the same sets over and over, and near-misses of each other.

Changes (dune-side events and `dune trace cat` are untouched — the csexp
still carries the literal dep lists):

- Two new sections, `graph-cores` and `graph-depsets`, per the schema above.
  `graph-rules`' seventh field becomes a `set_id`; the empty-vs-`?`
  distinction is unchanged, and each `<dyn_dep_stages>` stage becomes a
  `set_id` too, through the same table.
- `Graph_blob.Dep_sets` in `bin/trace.ml` holds the encoder. It runs
  **online**, as each `exec-rule` end is handled (that order is the
  emission order the window below slides over), not as a post-pass: only
  the window, the pool, and the map from set to `set_id` persist. Sets are
  stored as their exact members (sorted, deduplicated id lists), not as
  digests — a hash collision would silently corrupt the graph.

The algorithm, for each **new distinct** non-empty set `S` (an identical set
reuses its id and touches nothing else):

1. **Reuse.** Take the largest core `C` in the pool with `C ⊆ S`. Accept it
   only if `|C| ≥ 0.5·|S|`.
2. **Mine.** Failing that, take the set `B` in the window maximising
   `|S ∩ B|`, subject to `|S ∩ B| ≥ max(16, 0.5·|S|)`. If there is one,
   `C = S ∩ B` is registered as a core (reusing an existing core id if that
   exact set is already a core) and pushed onto the pool — whether or not
   step 3 then uses it, so that a shape seen twice becomes reusable.
3. `C` is used only if `16 ≤ |C| < |S|`; then the set's adds are `S \ C`.
   Otherwise the set has no core and its adds are all of `S`.
4. `S` is pushed onto the window either way.

Constants: **window 32** distinct sets, **pool 64** cores, **minimum
overlap fraction 0.5**, **minimum core size 16**. These were selected by
measurement over the monorepo trace, not by taste; in particular a *larger*
core pool measured **worse** (a big pool keeps stale cores that win the
"largest subset" test with a poor covering, displacing the mining step that
would have found a better one). Ties everywhere break deterministically —
lowest core id, oldest window entry — so a given trace converts
byte-identically.

Cores are deliberately flat: `deps(S) = core_members(C) + adds(S)`, one
join, no recursion. Chaining cores to cores would compress further and cost
the consumer the plain-SQL-view property, which is the point of the
encoding.

Measured on the same trace (converter output, cross-checked against a
reference implementation of the algorithm in Python, which it matches
exactly): **700 cores**, **127,399 core-member ids**, **47,170 of 205,224
sets with a core**, **3,655,880 add ids**. Total rows for the graph's edge
data: 386,320 rule lines + 205,224 set lines + 3,655,880 adds + 127,399
core members = **4,374,823, i.e. 15.6% of the 28.1M baseline**.
Reconstructing `core + adds` for a sample of ~4000 rules reproduces exactly
the dep sets the pre-change converter emitted, and two runs over the trace
produce byte-identical protobuf. Bytes were never the bottleneck, but they
fall too: the converted trace goes from 333.6 MB to 181.4 MB. Converter wall
time and peak RSS are unchanged to slightly better (36.0 s / 3.7 GB, versus
36.7 s / 4.4 GB before): the distinct sets it now retains cost less than the
dep ids the rule lines no longer carry.

- Tests (`perfetto.t`): the new sections' presence (and `graph-cores`'
  absence on a project whose sets never reach 16 members); a rule line's
  `set_id` resolved through `graph-depsets` — and, for a 40-file fan-in that
  does produce a core, through `graph-cores` — back to the dep paths via
  `graph-dict`; `version` still `1`; and both halves of the empty-vs-`?`
  distinction on a failing build.

Implementation notes / deviations:

- `version` stays `1`. This is a breaking blob change, but the v1 contract
  has not shipped to the plugin (see phase 7's open checklist item), so the
  schema section above was amended in place rather than duplicated as a v2.
- A core rejected by step 1's `0.5·|S|` test is dropped even when step 2
  then finds nothing, rather than being carried forward as a
  smaller-than-half core. The reference implementation carried it forward;
  measured difference: 47,322 vs 47,170 cored sets, 3,637,736 vs 3,655,880
  adds (0.3% and 0.5%), i.e. not worth the extra rule.
- A mined core that already exists is *not* pushed onto the pool a second
  time: duplicate pool entries would evict live cores for nothing.
- The dep set and the dyn-dep stages are bound before the `graph-rules`
  record is assembled, since the elements of an OCaml list expression are
  not evaluated left to right and the encoder's state makes that order
  observable.

### Phase 9 — collapse gated on duration (converter-only) — **implemented**

Motivation: phases 2 and 7 collapsed a span on its *outcome* alone — a cache
hit, or an `is-source` dep. The outcome is a good proxy for "this took no
time", but only a proxy: a shared-cache hit that round-trips to a contended
remote store, or a source dep whose stat misses a cold page cache, occupies a
real interval that the collapsed form throws away (a collapsed instant sits at
the begin timestamp and carries no flow, so nothing in the UI shows the wait).

Changes (dune-side events and `dune trace cat` are untouched):

- Collapse requires the outcome *and* `dur_ns < 1ms`. A cache hit or source
  dep at or above the threshold emits the ordinary `-start`/`-finish` pair,
  with its flow, like any other span.
- The threshold is overridable via `DUNE_TRACE_COLLAPSE_THRESHOLD_NS`
  (mirroring `DUNE_TRACE_GRAPH_CHUNK_SIZE`); negative or unparseable values
  fall back to the default. `0` collapses nothing, which is what lets the test
  pin the behaviour instead of racing the clock.
- Tests (`perfetto.t`): converting the cache-hit rebuild's trace with the
  threshold at `0` yields no `-resolved` instants at all, the `exec-rule` and
  `build-dep` pairs in their place, and flows on them.

Implementation notes / deviations:

- The threshold is a converter-side choice, not part of the blob or the event
  schema, so `version` stays `1` and the plugin needs no change: it already
  has to handle both forms of every collapsible span.
- The existing collapse assertions in `perfetto.t` (a `build-dep-resolved` for
  `/etc/hosts`, an `exec-rule-resolved` on the no-op rebuild) now depend on
  those spans staying under 1ms on the test machine. Sub-millisecond is a wide
  margin for a stat and a cache lookup, but if CI ever gets slow enough to
  flake, the fix is to pin those cases with a large
  `DUNE_TRACE_COLLAPSE_THRESHOLD_NS` rather than to drop the assertions.

## Verification checklist (carry across sessions)

- [x] `debug.dune.*` is the actual args-table key prefix (phase 1, checked
      in trace_processor).
- [x] UI lane-packs the same-named `exec-rule-action` tracks into one
      merged group (phase 3).
- [x] Flow arrows render on instant endpoints in the UI, and the
      start → action → finish chain draws as expected (phase 4).
- [x] Monorepo-scale re-measurement after phase 2: track count, pb size,
      and args-table row count vs. the baseline numbers above (phase 5;
      results recorded in the phase 5 notes).
- [ ] Four-hop flow chain draws as expected in the UI, and a
      parallelism-heavy trace (wide ready set) no longer multiplies
      `exec-rule-action` tracks (phase 6).
- [ ] The plugin is updated to the phase 7 arg set (`rule_id`/`dep_id` as the
      only join keys, outcomes read from the blob) before this ships as the
      v1 contract.
- [ ] The plugin reads dep sets through `graph-depsets`/`graph-cores`
      (phase 8) rather than a literal id list per rule, and its
      dep-set-membership view is the single join the flat cores allow.
