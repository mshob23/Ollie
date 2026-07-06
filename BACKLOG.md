# Ollie — backlog

A living, prioritized list of what's next, ordered by **leverage, not size**.
Product thesis: *"do little, expose flexibly"* (see the exposability ladder in the
project notes). Rungs 0 (frictionless capture) and 2 (App Intents + Spotlight) are
shipped on TestFlight build 7 + the notarized Mac `.dmg`.

## Now — cheap, high-leverage

- **Rung 3 — export the corpus to plain files.** Mirror every note to a user-owned
  iCloud Drive folder: Markdown (frontmatter + body) for humans/Obsidian, JSONL (one
  record/line) for machines/LLMs. Cheap — `Note` is already `Codable`. This is the
  whole "you own it / expose flexibly" thesis, and it delivers *intelligent search
  today*: point ChatGPT/Claude at the folder and "notes related to Hassan" works
  semantically, with zero in-app AI. Also unblocks Rung 4 (MCP).

- **Finish the Find result.** `FindNotesIntent` returns a count ("Found 3 notes") but
  not the notes themselves. Show the matched notes (headline + preview) in the Siri /
  Shortcuts result and let the user open one (a `SnippetView` and/or an open-note
  intent). Completes the Rung 2 feature already shipped.

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

## Rung 4 — later

- **MCP server over the exported folder (Mac).** Lets Claude/agents query the corpus
  directly as a tool. Natural once Rung 3 export exists.

## The agent layer (Rungs 5–8) — in progress

*Approved July 2026. Turns rented intelligence into cached, owned understanding written
back into the store — tags + memory + views, gated so restricted notes never leave the
device. Full spec: [`AGENT_LAYER_PLAN.md`](./AGENT_LAYER_PLAN.md); the canonical data
contract is [`docs/agent-contract.md`](docs/agent-contract.md). Scope: build through
Views v1; defer watch views, Views v2 interactive blocks, photo notes, and the on-device
agent (schemas reserve room for all four).*

- **Rung 5 — agent write-back.** *In progress.* Agents write **tags** (cached judgment)
  and **memory** (a codebook of shorthand/preferences/dead-ends) back into the store as
  append-only, attributed records. New SwiftData entities + `AgentLayerStore` choke point
  (plan M1), an inbox op protocol the Mac app validates and applies (M3), and MCP write
  tools + read-your-writes overlay (M4). Notes stay immutable ground truth; the layer is
  derived and disposable.
- **Rung 6 — the gate.** *Planned.* A note can be marked *restricted*; it and everything
  derived from it (its tag lines, its `.md`) are filtered out of everything under
  `~/Ollie/`. Restriction is contagious, encoded once in `CorpusGate`. Export v3 (plan
  M2) + a restriction toggle in the apps (M5b).
- **Rung 7 — views v1.** *Planned.* Agents publish named living documents ("Open loops",
  "This week") as immutable revisions; the apps render a **Views** feed with history and
  tappable `ollie://note/<uuid>` citations. Shared `MarkdownLite` renderer + a Views tab
  on iOS and a Views pane on Mac (plan M5a/M5e/M5f).
- **Rung 8 — the agent runner (the loop).** *Planned.* A launchd-scheduled headless
  Claude session on the Mac periodically tags new notes, fulfills request-notes ("Ollie,
  look into…"), and refreshes views. Speak into the watch on the sidewalk; the answer is
  in the Views tab by the time you're home (plan M6).

## Consider

- **Just use it.** The app is on your devices. A couple weeks of real capture will
  reorder this list better than any guess — dogfooding is a legitimate top priority.
