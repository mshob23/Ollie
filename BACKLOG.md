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

- **Rung 1 — in-app intelligence (semantic search + "ask your thoughts").** On-device
  embeddings (`NLEmbedding`) + the Foundation Models LLM = RAG over the corpus. Turns
  "find notes related to Hassan" into real semantic, spelling-tolerant, ranked results
  plus a synthesized answer. The crown jewel; a deliberate multi-session build.

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

## Consider

- **Just use it.** The app is on your devices. A couple weeks of real capture will
  reorder this list better than any guess — dogfooding is a legitimate top priority.
