#!/usr/bin/env python3
"""Ollie MCP server — exposes your note corpus AND its agent layer to an LLM (Claude)
as tools.

NO intelligence lives here: the read tools let the model READ and FILTER your notes;
the model does the reasoning (what counts as a "to-do," what "last week" means). The
write tools let the model contribute BACK — tags (cached judgment), memory (a
codebook), and published views (living documents) — but only ever *mechanically*:
the server validates ids and sizes, never whether a tag is sensible or a memory is
true. That's the whole point — lend Claude your corpus and let its intelligence loose
on it, while the data stays owned by you and every contribution is attributed and
disposable.

Reads ~/Ollie/ollie.jsonl + the agent-layer files (tags/memory/views/instructions)
the Ollie Mac app rewrites on every change (set OLLIE_CORPUS to relocate the whole
directory). Writes go through the inbox (~/Ollie/inbox/) — the app is the only store
writer; it applies queued ops on its next cycle. Run the Mac app once to populate the
corpus and to ingest anything this server queues.
"""
from mcp.server.fastmcp import FastMCP

import ollie_corpus as c
import ollie_layers as layers

mcp = FastMCP("ollie")


@mcp.tool()
def search_notes(query: str, limit: int = 20) -> list[dict]:
    """Find the user's personal notes whose text or place name contains `query`
    (case-insensitive SUBSTRING — not semantic), newest first.

    Notes are verbatim voice transcripts + typed notes, so expect filler words and
    transcription slips; try short distinctive substrings ("fridge", "sublimation")
    over long phrases. For "related to X" / fuzzy questions, DON'T search — pull
    recent_notes or list_notes and reason over the text yourself. Each result has:
    id (UUID), createdAt (ISO-8601 UTC), source (watch/phone/computer), kind
    (voice/text), place (may be null), text (full transcript)."""
    return c.search(c.load(), query, limit)


@mcp.tool()
def list_notes(since: str = "", until: str = "", source: str = "", limit: int = 50) -> list[dict]:
    """List the user's notes in a date range, newest first — the right tool for any
    time-scoped question ("this week", "yesterday", "while I was in Houston last
    month" → combine with place from the results).

    `since`/`until` accept YYYY-MM-DD or full ISO-8601, interpreted as UTC; either
    may be omitted. `source` optionally filters by capture device: "watch" (voice
    memos spoken on the Apple Watch), "phone" (typed/dictated on iPhone), or
    "computer" (dictated on the Mac). Returns the same record shape as search_notes."""
    return c.in_range(c.load(), since, until, source, limit)


@mcp.tool()
def get_note(id: str) -> dict:
    """Fetch one note's full record by its UUID `id` (as returned by the other
    tools) — use when you kept an id and need the complete text again."""
    return c.get(c.load(), id)


@mcp.tool()
def recent_notes(limit: int = 20) -> list[dict]:
    """The most recently created notes, newest first. The best FIRST CALL for
    open-ended questions ("what's on my mind lately", "any todos in my notes?"):
    grab a batch and reason over the raw text yourself."""
    return c.recent(c.load(), limit)


@mcp.tool()
def corpus_stats() -> dict:
    """Corpus orientation: total note count, date span, per-source breakdown, export
    freshness (`staleness.exportedAt` = when the Mac app last rewrote the corpus — if
    hours old, the data may lag what's on the user's devices), the agent-layer sizes
    (`layerCounts.tags/memory/viewRevisions`), and how many of your queued writes are
    still awaiting apply (`pendingOps` — the Mac app ingests them on its next cycle;
    a number that stays >0 usually means the app is closed). Call this first when
    counts matter, results look thin, or you want to confirm a write landed."""
    out = c.stats(c.load())
    # Agent-layer sizes come from the same `.ollie.meta.json` staleness already read;
    # surface them at the top level for convenience, and add the live pending count.
    meta = c.load_meta()
    layer_counts = meta.get("layerCounts")
    if isinstance(layer_counts, dict):
        out["layerCounts"] = layer_counts
    out["pendingOps"] = layers.pending_count()
    return out


# ── Agent-layer READS (the understanding surface) ────────────────────────────────

@mcp.tool()
def get_instructions() -> dict:
    """The user's standing instructions to agents — read this FIRST and honor it
    before working with their notes. Plain markdown authored by the user in-app
    (their preferences, house rules, how they want you to tag/summarize). Returns
    `{"instructions": <text>}`; the text is "" if they haven't written any."""
    return {"instructions": layers.load_instructions()}


@mcp.tool()
def tag_vocabulary() -> list[dict]:
    """The existing tag lexicon — REUSE before inventing. Each row is
    `{tag, count, lastUsed}` (count = notes carrying it; lastUsed = ISO-8601),
    most-used first. Tags are grouped case-insensitively. Consult this before
    `tag_note` so the corpus converges on a shared vocabulary instead of drifting
    into near-duplicate tags ("heat-pump" vs "heatpump"). Reflects your own
    just-queued tags too (read-your-writes)."""
    return layers.tag_vocabulary()


@mcp.tool()
def notes_by_tag(tag: str, limit: int = 50) -> list[dict]:
    """The notes carrying `tag` (case-insensitive), newest first — the inverse of
    tagging. Same slim record shape as the read tools (id, createdAt, source, kind,
    place, text). Use it to pull "everything I tagged `request:open`" or to review a
    tag before retiring it. A tag pointing at a since-deleted or restricted note is
    silently skipped (it's no longer in the corpus)."""
    return layers.notes_by_tag(tag, limit)


@mcp.tool()
def read_memory(include_retired: bool = False) -> list[dict]:
    """The agent codebook (memory), newest first — durable facts prior runs chose to
    remember: shorthand decodings, the user's preferences, dead ends not worth
    re-deriving. Each row: `{text, agentId, createdAt, retired[, id, retiredAt,
    pending]}`. Retired entries (superseded facts) are hidden unless
    `include_retired=True`. Read this to avoid re-learning what's already known; add
    to it sparingly with `append_memory`."""
    return layers.read_memory(include_retired)


@mcp.tool()
def list_views() -> list[dict]:
    """The named views (living documents agents publish — "Open loops", "This week",
    an answer to a request-note), most-recently-updated first. Each row:
    `{name, revisionCount, latestAt, latestAgent}`. This is the feed the user reads in
    the app; call `get_view(name)` for a view's body. Publishing to an existing name
    with `publish_view` appends a new revision (views are immutable snapshots, never
    edited in place)."""
    return layers.list_views()


@mcp.tool()
def get_view(name: str, revision_limit: int = 5) -> dict:
    """One view by exact `name`: the latest revision's full markdown `body` plus
    metadata for up to `revision_limit` recent revisions. Returns
    `{name, body, latestAt, latestAgent, revisionCount, revisions:[{createdAt,
    agentId[, pending]}]}`, or `{"error": …}` if there's no such view. Read a view
    before republishing it so you extend rather than clobber it. Body dialect (§3.5):
    `ollie://note/<uuid>` links cite notes (the app makes them tappable); fenced code
    blocks render as plain monospaced panels."""
    return layers.get_view(name, revision_limit)


# ── Agent-layer WRITES (the contribution surface) ────────────────────────────────
# Every write is QUEUED, not applied inline: the tool drops an op file in the inbox
# and returns `{"requestId", "status": "queued"}` immediately. The Ollie Mac app
# (the only store writer) validates and applies it on its next ingest cycle, then the
# record syncs via CloudKit and re-exports. Your OWN reads reflect the write right
# away (read-your-writes overlay), so you can `tag_note` then `tag_vocabulary` and
# see it — but the durable record lands only once the app runs. A client-side cap
# violation returns `{"error": …}` and queues nothing (same bounds the app enforces).

@mcp.tool()
def tag_note(id: str, tag: str) -> dict:
    """Attach `tag` to the note with UUID `id` (cached judgment about the note).
    Tags are a set per note — re-applying an existing `(note, tag)` pair is a no-op.
    `tag` is freeform, 1–64 printable characters; the "key:value" convention
    (`request:open`, `topic:heat-pump`) is a habit, not enforced. Check
    `tag_vocabulary()` first to reuse an existing tag. Returns
    `{"requestId", "status": "queued"}`."""
    try:
        rid = layers.write_op("tag", {"noteId": id, "tag": tag})
    except layers.OpValidationError as e:
        return {"error": str(e)}
    return {"requestId": rid, "status": "queued"}


@mcp.tool()
def untag_note(id: str, tag: str) -> dict:
    """Remove `tag` from the note with UUID `id` (matched case-insensitively; removes
    every matching record). Idempotent — untagging an absent tag still succeeds. You
    may only remove tags (a *derived* record agents own); you can never edit or delete
    a note itself. Returns `{"requestId", "status": "queued"}`."""
    try:
        rid = layers.write_op("untag", {"noteId": id, "tag": tag})
    except layers.OpValidationError as e:
        return {"error": str(e)}
    return {"requestId": rid, "status": "queued"}


@mcp.tool()
def append_memory(text: str) -> dict:
    """Record ONE durable codebook fact (1–2000 chars) — a shorthand decoding, a
    stable user preference, a dead end worth not re-deriving. Memory is append-only
    and attributed; use it SPARINGLY for facts that will still matter next run, not
    for transient observations about a single note (tag the note instead). To correct
    a fact, append the new one and `retire_memory` the old. Returns
    `{"requestId", "status": "queued"}`."""
    try:
        rid = layers.write_op("memory.append", {"text": text})
    except layers.OpValidationError as e:
        return {"error": str(e)}
    return {"requestId": rid, "status": "queued"}


@mcp.tool()
def retire_memory(id: str) -> dict:
    """Tombstone the memory entry with UUID `id` (from `read_memory` rows' `id`) —
    marks it retired without hard-deleting, so superseded facts stay auditable.
    Idempotent (retiring an already-retired entry is a no-op). Use when a codebook
    fact is now wrong or obsolete, typically alongside an `append_memory` of the
    correction. Returns `{"requestId", "status": "queued"}`."""
    try:
        rid = layers.write_op("memory.retire", {"id": id})
    except layers.OpValidationError as e:
        return {"error": str(e)}
    return {"requestId": rid, "status": "queued"}


@mcp.tool()
def publish_view(name: str, body: str) -> dict:
    """Publish a revision of the view called `name` — a living document the user reads
    in the app's Views feed (e.g. "Open loops", "This week", or an answer to a
    request-note). `name` is 1–80 chars (exact-match identity: publishing to an
    existing name APPENDS a new revision, latest wins for display); `body` is markdown,
    1–131072 chars. Cite notes with `ollie://note/<uuid>` links so the user can tap
    through. Read `get_view(name)` first if you mean to extend an existing view.
    Returns `{"requestId", "status": "queued"}`."""
    try:
        rid = layers.write_op("view.publish", {"viewName": name, "body": body})
    except layers.OpValidationError as e:
        return {"error": str(e)}
    return {"requestId": rid, "status": "queued"}


if __name__ == "__main__":
    mcp.run()
