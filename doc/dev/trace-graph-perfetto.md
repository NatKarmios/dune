# Graph trace: Perfetto export redesign

Status: phases 1-4 implemented; phase 5 planned. This document is the
working plan; it is intended to be executed phase by phase over multiple
agent sessions. Each phase is independently committable and must pass
`dune build @check @fmt @runtest` (scope test runs to
`test/blackbox-tests/test-cases/trace/` during development).

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
(`exec-rule-action`, phase 4). Decisions:

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
   source-file deps) — the overwhelming majority of events in incremental
   monorepo builds.
5. **One flow per span chains its lifecycle**: for executed rules,
   `exec-rule-start` → `exec-rule-action` slice → `exec-rule-finish`
   (a flow id's consecutive appearances link in timestamp order, so a
   single id per span produces exactly this chain); for other
   non-collapsed spans, start → finish. Collapsed instants carry no flow.
   Measured cost on a cold build (worst case — nothing collapses): ~6.5%
   of total wire output; incremental builds pay proportionally less.
   Flows for graph *edges* are rejected: fan-out would need one id per
   edge patched onto already-emitted forcer instants; the blob carries
   those edges instead.
6. **New dune-side `exec-rule-action` span** wrapping only the action
   execution (Step IV in `build_system.ml`, `execute_action_for_rule`),
   i.e. real work, bounded by `-j`. The converter renders these as true
   duration slices on a small pool of lanes (track uuids reused after a
   span ends; all lanes share one name so the UI merges them). This gives
   a worker-occupancy timeline. Cache-hit rules have no action, so the
   noise problem solves itself structurally.

Perfetto ground rules this design leans on:

- Slices on one track have stack semantics; any temporal containment
  nests. Only share a track between spans when nesting is intended
  (`exec-rule-action` and things genuinely inside it) or impossible
  (pooled lanes reused strictly after end; instants).
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
| `exec-rule-action` (×N lanes) | children of process | action duration slices (phase 4) |

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

On track `exec-rule`:

- `exec-rule-start`: `rule_id` (int), `async_id` (int), `dir` (string,
  resolved path).
- `exec-rule-finish`: `rule_id`, `async_id`, `outcome`
  (`"executed" | "local-cache-hit" | "shared-cache-hit"`), `dur_ns` (int).
- `exec-rule-resolved`: collapsed form used when outcome is a cache hit;
  placed at the begin timestamp; carries the union of the above args.

On track `build-dep`:

- `build-dep-start`: `dep` (string, resolved), `async_id`.
- `build-dep-finish`: `async_id`, `dur_ns`, and the outcome kind:
  `rule_id` (int) when the dep resolved to a rule; `outcome_kind`
  (`"rule" | "expanded" | "is-source"`). Expansion contents are in the
  blob (`graph-deps`), not on the slice.
- `build-dep-resolved`: collapsed form used when the dep is a source
  file; union of the above args.

On the pooled `exec-rule-action` lanes (executed rules only):

- `exec-rule-action`: true duration slice (Begin/End); `rule_id` (int),
  `async_id` (int, **same value as the rule's lifecycle instants** — the
  join key between an action slice and its rule).

On tracks `gen-rules` / `dynamic-includes`:

- `gen-rules-start` / `-finish`: `dir` (string), `dune_file` (string, on
  finish when known), `dur_ns` (on finish), `async_id`.
- `dynamic-includes-start` / `-finish`: `dune_file` (string), `dur_ns`
  (on finish), `async_id`.

`target_files`, `target_dirs`, `deps`, `dyn_deps`, `forced_by`, and
expansion lists **no longer appear on slices**; they are in the blob.

A fresh `flow_ids` value per non-collapsed span chains its lifecycle:
`exec-rule-start` → `exec-rule-action` slice (executed rules only) →
`exec-rule-finish`; plain start → finish for `build-dep`, `gen-rules`,
and `dynamic-includes` (and for exec-rule spans with no action slice).
Collapsed instants carry no flow. The flow is a stock-UI affordance; the
plugin pairs via `async_id`/`rule_id` args and should not depend on
flows.

### Graph blob

Instants on track `dune-graph`, timestamped at the last event seen. Three
event names, each carrying args: `version` (int, `1`), `seq` (int,
0-based per name), `total` (int, chunk count per name), `data` (string,
≤ 4 MB, split only on line boundaries).

Payloads are line-oriented (`\n`-separated records, `\t`-separated
fields). Strings escape `\\`, `\t`, `\n` C-style. Integer lists are
`,`-separated. All `<*_id>` values referring to paths/deps are intern ids
resolved via `graph-dict`; `rule_id` is the rule's own id (same value as
the slice arg — this is the join key between timeline and graph).

- `graph-dict` — the intern table:

      <id>\t<string>

- `graph-rules` — one line per exec-rule span occurrence, ordered by span
  *end* (watch mode can produce several lines per target; `rule_id` values
  are per-process and may differ across watch iterations for the same target
  — the plugin should key nodes on resolved target paths when merging):

      <rule_id>\t<dir_id>\t<target_file_ids>\t<target_dir_ids>\t<outcome>\t<forced_by>\t<dep_ids>\t<dyn_dep_stages>

  `<outcome>`: `X` executed, `L` local cache hit, `S` shared cache hit, `?`
  unfinished (see below).
  `<forced_by>`: `r<rule_id>` | `d<dep_id>` | `i<path_id>`
  (dynamic-includes) | `g<path_id>` (gen-rules) | `p<path_id>` (pform) |
  `c` (configurator) | `q` (request) | `u` (unknown).
  `<dyn_dep_stages>`: stages separated by `|`, ids within a stage by `,`;
  empty when none.

- `graph-deps` — one line per build-dep span, ordered by span end:

      <dep_id>\t<resolution>\t<forced_by>

  `<resolution>`: `r<rule_id>` | `s` (source) | `x<id,id,...>`
  (expanded, e.g. alias/glob) | `?` unfinished (see below).

  **Unfinished spans** (a crash or interrupt leaves a begin with no matching
  end — see `test/blackbox-tests/test-cases/trace/interrupted-watch-build-events.t`
  for a trace that can produce these): the converter flushes each open span
  at EOF as a `graph-rules`/`graph-deps` line with `?` in place of `<outcome>`
  /`<resolution>` and empty `<dep_ids>`/`<dyn_dep_stages>`, appended after the
  completed lines and sorted by `async_id` for determinism.

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
- Unmatched begins (see "Unfinished spans" above) are a v1 schema addition
  (`?` for `<outcome>`/`<resolution>`) not present in the original draft of
  this document.
- The intern table (`graph-dict`) is emitted in full, sorted by id, from the
  converter's already-reconstructed `t.names` table — it is not limited to
  ids actually referenced by `graph-rules`/`graph-deps` (harmless: `intern`
  events cover only strings the graph category actually used).

### Phase 2 — spans → instants, per-kind tracks, arg slimming — **implemented**

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
  gen-rules, when known), `dur_ns`, and `async_id` are on the finish. This
  mirrors exec-rule's asymmetry (`dir` is start-only there too) and was a
  reading of the schema table's compressed "start / finish" row, which did
  not spell out which fields belong to which side.
- `build-dep-finish`/`-resolved` always carry `outcome_kind`
  (`"rule"|"expanded"|"is-source"`) rather than only conditionally
  including it; `rule_id` is additionally present when the kind is
  `"rule"`. The schema's phrasing ("the outcome kind: `rule_id` (int) when
  the dep resolved to a rule; `outcome_kind` (...)") was ambiguous between
  this and an either/or; the implemented form keeps the arg set
  self-describing without a join.
- `exec-rule`'s `rule_id`/`build-dep`'s `rule_id` (when present) degrade to
  omitting the arg (rather than a `"?"` placeholder) if the underlying
  atom fails to parse as an int; this can only happen on a malformed trace
  and mirrors other defensive fallbacks in the converter.
- A missing `dep_outcome` on a `build-dep` end (malformed trace) degrades
  to `outcome_kind: "?"` and still emits the start/finish pair, mirroring
  `exec-rule`'s `rule_outcome` fallback. An earlier version of this dropped
  the perfetto instants silently in this case while still emitting a `"?"`
  graph-blob line, so the blob and the slice track could disagree on
  whether the span existed; caught in review before landing.
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
  the time it is pushed.
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

### Phase 5 — docs and follow-ups

- Update the trace section of `doc/hacking.rst` and this document to
  "implemented" status; record any schema deviations discovered in
  phases 1–4 (the plugin schema section above is the contract — bump
  `version` on breaking change).
- Known limitations / candidates deliberately out of scope:
  - Converter buffers all packets in memory; multi-GB csexp inputs may
    need a streaming writer eventually.
  - csexp on-disk size (compression on write, shorter framing,
    relative timestamps) — orthogonal; gzip already recovers ~10:1.
  - forced-by flows (id-per-edge, requires patching emitted instants) —
    superseded by the blob unless UI arrows are wanted.
  - Splitting exec-rule lifecycle into demand vs. execute on the dune
    side.

## Verification checklist (carry across sessions)

- [x] `debug.dune.*` is the actual args-table key prefix (phase 1, checked
      in trace_processor).
- [x] UI lane-packs the same-named `exec-rule-action` tracks into one
      merged group (phase 3).
- [x] Flow arrows render on instant endpoints in the UI, and the
      start → action → finish chain draws as expected (phase 4).
- [ ] Monorepo-scale re-measurement after phase 2: track count, pb size,
      and args-table row count vs. the baseline numbers above.
