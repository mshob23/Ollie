# Ollie MCP server

Exposes your Ollie note corpus to an LLM (Claude) as tools — so you can ask things like
*"was there anything in my Ollie notes I needed to do in the last week?"* Claude reads
and filters your notes; **it** supplies the intelligence. The server does no reasoning.

It reads `~/Ollie/ollie.jsonl`, which the **Ollie Mac app exports automatically** on
every change (Rung 3). Run the Mac app once to populate it. Override the path with the
`OLLIE_CORPUS` environment variable.

> **The corpus only refreshes while the Ollie Mac app is running.** The export is
> driven by the app re-projecting its store; nothing updates `~/Ollie` when the app is
> closed. So if the app has been quit for a while, the corpus can be stale. The Mac app
> writes a sidecar `~/Ollie/.ollie.meta.json` (`exportedAt`, `noteCount`,
> `schemaVersion`) after each successful export; `corpus_stats()` reads it and returns a
> `staleness` block that **warns when the corpus is older than ~24h** (open the app to
> refresh). The server degrades gracefully if the meta file is missing — it falls back
> to the corpus file's modification time and never crashes.

## Tools

| Tool | What it does |
|---|---|
| `search_notes(query, limit)` | Case-insensitive substring search over text + place |
| `list_notes(since, until, source, limit)` | Date-range list (e.g. "the last week") |
| `recent_notes(limit)` | The newest notes |
| `get_note(id)` | One full note record |
| `corpus_stats()` | Count, date span, per-source breakdown |

## Setup

```bash
cd /Users/mohammadshobaki/Desktop/Projects/Agents/HandheldNotes/mcp-server
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt
```

## Add to Claude

**Claude Code:**

```bash
claude mcp add ollie -- \
  /Users/mohammadshobaki/Desktop/Projects/Agents/HandheldNotes/mcp-server/.venv/bin/python \
  /Users/mohammadshobaki/Desktop/Projects/Agents/HandheldNotes/mcp-server/ollie_mcp.py
```

**Claude Desktop** — add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "ollie": {
      "command": "/Users/mohammadshobaki/Desktop/Projects/Agents/HandheldNotes/mcp-server/.venv/bin/python",
      "args": ["/Users/mohammadshobaki/Desktop/Projects/Agents/HandheldNotes/mcp-server/ollie_mcp.py"]
    }
  }
}
```

Restart Claude, then ask: *"Using Ollie, what did I need to do in the last week?"*
Claude will call `list_notes(since=…)`, read the texts, and reason about which were
to-dos — exactly the intelligence layer we deliberately didn't hard-code.

## Design

- `ollie_corpus.py` — pure logic (load + filter), no MCP deps, unit-testable.
- `ollie_mcp.py` — thin FastMCP wrapper that exposes the logic as tools.
- Re-reads the JSONL on every call, so it always reflects the latest export.
