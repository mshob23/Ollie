# Ollie — backlog

A living, prioritized list of what's next, ordered by **leverage, not size**.
Product thesis: *"do little, expose flexibly"* (see the exposability ladder in the
project notes). Rungs 0 (frictionless capture), 2 (App Intents + Spotlight), and the
whole agent layer (Rungs 4–8 + M7–M9, below) are shipped — currently TestFlight
build 33 (adds the watch-face complication; dropped the camera string) + the notarized
Mac `.dmg`.

## Now — cheap, high-leverage (from the July 2026 live agent-run evaluations)

- ~~**`diagram` / sketch fence widget.**~~ ✅ **Shipped (M10, 2026-07-07)** — vertical
  topological-flow renderer, contract §6.1 grammar, runbook example. **V2 polish shipped
  (M12, 2026-07-08):** wide layers wrap at 3 nodes/row, multi-label connectors render
  `from → to: label`, self-loop labels become `↺` node badges.
- ~~**Fix: capture-bar `createdAt`.**~~ ✅ **Fixed (2026-07-07)** — `Draft.makeNote()`
  now stamps at send time (also cured a spurious "edited" badge on fresh capture-bar
  notes). The runbook's skim-recent-notes workaround stays: late-syncing watch notes
  still justify it.
- ~~**Fix: feed previews leak literal `**`.**~~ ✅ **Fixed (2026-07-08)** — one shared
  `ViewPreviewSnippet` helper replaced the duplicated per-platform stripper; fence-leading
  bodies now preview their first prose line.
- ~~**`chart` min-baseline option.**~~ ✅ **Shipped (M12, 2026-07-08)** — explicit `min:`
  (over-declared clamps to data) + auto-baseline on tight all-positive spreads; any active
  baseline draws a labeled axis so a truncated chart is never silent.
- ~~**`metric` delta-sentiment hint.**~~ ✅ **Shipped (M12, 2026-07-08)** — `(-5 good)` /
  `(+2 bad)` (case-insensitive, Unicode-minus tolerant) overrides sign tinting.

- **Finish the Find result.** `FindNotesIntent` returns a count ("Found 3 notes") but
  not the notes themselves. Show the matched notes (headline + preview) in the Siri /
  Shortcuts result and let the user open one (a `SnippetView` and/or an open-note
  intent). Completes the Rung 2 feature already shipped.

- **Rung 3 remainder — human-facing Markdown mirror.** The machine half shipped (the
  `~/Ollie` JSONL export feeds the MCP server); the Obsidian-style per-note Markdown
  mirror to a user-owned iCloud Drive folder is still open.

## The home-node track — closing the loop away from the desk (2026-07-07, see VISION.md)

Goal: speak into the watch anywhere → a view lands back on the wrist minutes later, with
the always-on Mac standing in for the future on-device agent.

*Machine half shipped 2026-07-07:* `Scripts/setup-home-node.sh` + `docs/home-node.md` —
awake-on-AC/sleep-on-battery pmset profile, `caffeinate -s` LaunchAgent for clamshell
(zero third-party; Amphetamine documented as fallback — unused: clamshell lid-test
PASSED on-device 2026-07-07), native macOS 26.4 Charge Limit at 80% instead of AlDente.

*Agent half:* **C2 closed 2026-07-07** — headless `claude` authed (subscription), runtime
deployed to `~/Ollie/{bin,mcp}` (TCC blocks launchd from the Desktop repo), first
unattended launchd pass verified end-to-end (72 tags, 8 views, 2 requests answered,
wishlist tick consumed, 0 rejected ops). Next, in order:

- ~~**Event-driven runner.**~~ ✅ **Shipped (M11, 2026-07-07)** — note arrivals (CloudKit
  imports or local captures) debounce 90 s in the Mac app, then touch
  `~/Ollie/.runner-trigger`; launchd `WatchPaths` fires the guarded runner (4 h interval
  kept as backstop). Loop-safe by construction: only `NoteEntity` inserts trigger, and
  no agent path inserts a note (adversarially re-verified, incl. a live launchd
  WatchPaths probe). See docs/home-node.md §Event-driven runs.
- ~~**Arrival-time coverage.**~~ ✅ **Shipped (M13, 2026-07-08)** — `IngestIndex`
  (App Support, never `~/Ollie` — even restricted UUIDs stay behind the boundary) stamps
  first-arrival; exported rows carry `ingestedAt` (createdAt fallback); the runbook filters
  `list_notes(ingested_since=lastRunAt)`; the runner checkpoints at run **start**
  (review-caught: a completion-time cursor silently dropped mid-run arrivals to the 4 h
  backstop).
- ~~**`runs.jsonl` work log.**~~ ✅ **Shipped (M13, 2026-07-08)** — the runner appends one
  line per invocation (success and failure); agents read it via `recent_runs()` (runbook
  step 1). Advisory, never access control.
- ~~**Runbook: decay + reflection guidance.**~~ ✅ **Shipped (2026-07-08)** — the "Weight
  by recency; let the old tail fade" section: fade by distillation (promote durable facts
  to memory), never deletion.

## Next — the big bet

- **Rung 1a — on-device semantic search: BUILT + SHELVED (June 2026).** Works
  (`NLContextualEmbedding` + a local cached `EmbeddingIndex` actor), but it's
  corpus-limited / B-grade and MCP + Claude does it better — so un-wired from the app,
  engine kept dormant in `Sources/HandheldNotesCore/Intelligence/`. Full write-up +
  revival steps: `docs/semantic-search.md`.
- **Rung 1b — generative "ask your thoughts": not started.** Foundation Models LLM + RAG
  over the corpus (synthesized answers). Needs Apple Intelligence; where the real fuzz
  lives. The crown jewel, deferred.

## Polish / fixes

- **Forgiving search.** `NoteIntentStore.search` is a literal
  `localizedCaseInsensitiveContains`. Make it tokenized, diacritic-insensitive,
  match-any-word so spoken-name spellings ("Hassan"/"Hasan") still hit. (Quick.)
- **Verify Spotlight indexing.** Confirm notes surface in system Spotlight after the
  app runs on the new build (the index lags a few minutes); if a clearly-present
  literal word still won't match, dig into the CoreSpotlight setup.
- **One-breath Siri phrase.** "Find Ollie notes about ___" (param-in-phrase). The
  free-text parameter tripped a non-fatal SSU `ResolutionError`, so phrases are
  param-less for now (Siri prompts for the term). Revisit baking the term in cleanly.
- **Spotlight tap-to-open.** A Spotlight result opens the app, not the specific note.
  Handle `CSSearchableItemActionType` / `NSUserActivity` to deep-link.
- **Mac App Intents discovery.** The SPM-built Mac app compiles the intents but
  doesn't run the metadata extraction, so Mac Siri/Shortcuts discovery is limited.
  Add an extraction step (or a small Xcode project) for the Mac app. iOS is fully wired.

## The agent layer (Rungs 4–8) — ✅ SHIPPED (July 2026)

*All of it: the MCP server over the exported corpus (Rung 4), agent write-back of tags +
memory (Rung 5), the contagious restriction gate (Rung 6), views v1 with the Views
tab/pane (Rung 7), and the launchd agent runner (Rung 8) — plus what was originally
deferred: **M7** interactive checkboxes (two-way views), **M8** watch views + revision
restore, and **M9** fence widgets (`metric`/`chart`/`timeline`/`table`) + the authoring
style guide + the capability wishlist. Shipped as iOS TestFlight build 32 + the
Developer-ID Mac app, and proven end-to-end in three live agent-run evaluations (the
"Now" items above are those runs' findings). Specs + as-built notes:
[`AGENT_LAYER_PLAN.md`](./AGENT_LAYER_PLAN.md); canonical contract:
[`docs/agent-contract.md`](docs/agent-contract.md). Still deferred with names reserved:
the `checklist`/`cl2:` fence, photo notes, the on-device FoundationModels agent, watch
checkbox interaction (plan §6).*

Operational remainder: **C2 — headless `claude` auth** for the launchd runner (needs the
user; the runner otherwise guards itself).

## Consider

- **Just use it.** The app is on your devices. A couple weeks of real capture will
  reorder this list better than any guess — dogfooding is a legitimate top priority.
