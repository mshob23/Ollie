# Ollie — backlog

A living, prioritized list of what's next, ordered by **leverage, not size**.
Product thesis: *"do little, expose flexibly"* (see the exposability ladder in the
project notes). Rungs 0 (frictionless capture), 2 (App Intents + Spotlight), and the
whole agent layer (Rungs 4–8 + M7–M9, below) are shipped — currently TestFlight
build 32 + the notarized Mac `.dmg`.

## Now — cheap, high-leverage (from the July 2026 live agent-run evaluations)

- **`diagram` / sketch fence widget.** The first user-approved entry in the "Ollie
  wishlist" — agents already hit the dialect's wall wanting to draw (they fall back to
  ASCII art in the monospaced panel, which works but is a poor-man's canvas). Same
  renderer-only pattern as M9. This is the wishlist loop doing its job: build it.
- **Fix: capture-bar notes carry the draft-session start `createdAt`, not send time.**
  A note sent at 02:39 can be stamped 02:30 — agents' `list_notes(since:)` silently
  misses it (bit two of three eval runs; the runbook has a workaround, the app should
  stamp send time).
- **Fix: feed previews leak literal `**`.** The snippet helper strips markdown pairs
  incompletely; detail rendering is fine.
- **`chart` min-baseline option.** A tight-range series (183→178) renders as six
  visually identical zero-scaled bars — tracking data needs a baseline (or auto-baseline
  when the range is tight) for the story to show.
- **`metric` delta-sentiment hint.** `(-5)` tints danger-red, but in a weight cut minus
  is *good*; guidance says "write `(5 down)`" for now — an explicit sentiment hint in
  the grammar would be nicer.

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
The *agent half* is gated on **C2** (headless `claude` auth — needs the user); then, in
order:

- **Event-driven runner.** The Mac app already receives CloudKit pushes for arriving
  notes; debounce ~90 s (a walk's worth of thoughts batches into one run) and kick the
  launchd runner, keeping the schedule as backstop. Target end-to-end latency 2–5 min.
- **Arrival-time coverage, not event-time.** Stamp `ingestedAt` (when the note reached the
  Mac store) at export; the runner's since-cursor should move over `ingestedAt`, advancing
  **only on successful run completion**. This closes the whole "missed note" class in one
  move: the capture-bar `createdAt` bug *and* late-syncing watch notes (created 3 h ago,
  arriving now) both stop being coverage hazards.
- **`runs.jsonl` work log.** Each run appends `{runId, agentId, startedAt, finishedAt,
  coveredThrough, notesSeen, viewsTouched}`. Advisory context for the next agent (and
  renderable as a view for the user) — never access control (VISION.md). Prefer this over
  per-note "seen" flags: notes are immutable + append-only, so a high-water mark gives
  exact coverage without n× bookkeeping writes; idempotent writes make any re-processing
  harmless anyway.
- **Runbook: decay + reflection guidance.** A line on weighting notes by recency (an old
  note surfaces only if strongly relevant), plus a periodic reflection pass over the aging
  tail (never tagged, never cited in a view, > N days) that promotes anything durable to
  memory — after which the raw note cools out of the working window naturally. Fade by
  distillation, never deletion.

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
