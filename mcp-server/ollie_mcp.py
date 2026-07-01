#!/usr/bin/env python3
"""Ollie MCP server — exposes your note corpus to an LLM (Claude) as tools.

NO intelligence lives here: the tools only let the model READ and FILTER your notes;
the model does the reasoning (what counts as a "to-do," what "last week" means). That's
the whole point — lend Claude your corpus and let its intelligence loose on it.

Reads ~/Ollie/ollie.jsonl (set OLLIE_CORPUS to override), which the Ollie Mac app
rewrites automatically on every change. Run the Mac app once to populate it.
"""
from mcp.server.fastmcp import FastMCP

import ollie_corpus as c

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
    """Corpus orientation: total count, date span, per-source breakdown, and export
    freshness (`staleness.exportedAt` = when the Mac app last rewrote the corpus —
    if hours old, the data may lag what's on the user's devices). Call this when
    counts matter or results look surprisingly thin."""
    return c.stats(c.load())


if __name__ == "__main__":
    mcp.run()
