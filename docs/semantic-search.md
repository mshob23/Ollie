# Semantic search (Rung 1a) — built, validated, shelved (June 2026)

On-device semantic note search. **Built and working, but shelved** — the quality is
corpus-limited and **MCP + Claude already does this better**. Kept as a dormant
foundation to revive when the corpus is real or a stronger model is bundled.

> Note: this uses `NLContextualEmbedding`, which is **NOT** Apple-Intelligence-gated —
> it runs on any iOS 17+/macOS 14+ device (it ran fine on the dev Mac). The
> Apple-Intelligence requirement belongs to Rung **1b** (the Foundation Models LLM),
> which was never built.

## What's here (dormant, not wired in)

`Sources/HandheldNotesCore/Intelligence/`:

- **`EmbeddingService`** — on-device embeddings via `NLContextualEmbedding` (a
  transformer), mean-pooled over the note's token vectors, unit-normalized. Best-effort:
  `nil` → the caller falls back to literal search. (We first tried
  `NLEmbedding.sentenceEmbedding` — near-random; don't use it.)
- **`EmbeddingIndex`** — an `actor`: a local, **non-synced** cache of `{note id →
  vector}` (embeddings are *derived* data — the synced transcript is the source of
  truth), brute-force cosine search, skips trivial notes (< 6 words).

Neither is referenced by the app right now. The `AppModel` wiring lived briefly in git
history; see "How to revive."

## What we learned

| Tried | Result |
|---|---|
| `NLEmbedding.sentenceEmbedding` (basic) | Near-random — "groceries" topped every query |
| `NLContextualEmbedding` on clean notes | Excellent — "a place to live" → apartment/landlord; "writing code" → the parser-bug note |
| …on the **real** corpus | Noisy — short test recordings ("computer test now", "wooop") embed to near-central vectors and match every query |
| Mean-centering | **Worse** — amplified the tiny-note noise |
| Skip notes < 6 words | Recovered substantive queries (food → barbecue, coding → the BLE note); to-do-style queries still confused by conversational test recordings |

## Why shelved

1. **Quality is corpus-bound + B-grade.** Dragged by a test-junk corpus today, capped by
   a small on-device model. Improves as real notes accumulate and the test junk clears.
2. **MCP + Claude already does semantic search far better** — a frontier model reasoning
   over the same corpus (`mcp-server/`). On-device is the private/in-app understudy.

## How to revive (≈20 min)

1. Re-add the `AppModel` hooks: a `private let embeddingIndex = EmbeddingIndex()`; call
   `Task { await embeddingIndex.sync(with: notes) }` at the end of `reloadNotes`; on a
   `searchText` change, run an async `embeddingIndex.search(query)` into a `@Published
   semanticHits` (with a sequence token to drop stale results); blend in `filteredNotes`
   — literal matches first, then semantic by score.
2. Tune `EmbeddingIndex.search(minScore:)` and the min-word filter for the real corpus.
3. For real quality: bundle a CoreML sentence-transformer (stronger than
   `NLContextualEmbedding`), and pair with **Rung 1b** (Foundation Models generation) for
   "ask your thoughts" — that half needs Apple Intelligence.
4. First, clear the test-junk notes from the corpus — it'll look dramatically better.
