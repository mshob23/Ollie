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
    """Find notes whose text or place contains `query` (case-insensitive substring),
    newest first. For "related to" / semantic questions, prefer pulling a broader set
    (recent_notes or list_notes) and reasoning over the text yourself."""
    return c.search(c.load(), query, limit)


@mcp.tool()
def list_notes(since: str = "", until: str = "", source: str = "", limit: int = 50) -> list[dict]:
    """List notes in a date range, newest first. `since`/`until` accept YYYY-MM-DD or
    full ISO-8601 (UTC); `source` optionally filters by device (computer/watch/phone).
    Use this for time questions like "the last week" — pass `since` = 7 days ago."""
    return c.in_range(c.load(), since, until, source, limit)


@mcp.tool()
def get_note(id: str) -> dict:
    """Get a single note's full record by id."""
    return c.get(c.load(), id)


@mcp.tool()
def recent_notes(limit: int = 20) -> list[dict]:
    """The most recently created notes, newest first."""
    return c.recent(c.load(), limit)


@mcp.tool()
def corpus_stats() -> dict:
    """Count, date span, and per-source breakdown — a quick orientation on the corpus."""
    return c.stats(c.load())


if __name__ == "__main__":
    mcp.run()
