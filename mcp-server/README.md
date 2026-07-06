# Ollie MCP server

Exposes your Ollie note corpus **and its agent layer** to an LLM (Claude) as tools — so
you can ask things like *"was there anything in my Ollie notes I needed to do in the last
week?"* and let Claude tag notes, keep a memory codebook, and publish living "views" back.
Claude reads, filters, and reasons; **it** supplies the intelligence. The server only ever
validates *mechanics* (ids, sizes) — never whether a tag is sensible or a memory is true.

It reads `~/Ollie/ollie.jsonl` plus the agent-layer files (`tags.jsonl`, `memory.jsonl`,
`views.jsonl`, `instructions.md`), which the **Ollie Mac app exports automatically** on
every change (Rung 3). Writes go the other way, through the **inbox** (`~/Ollie/inbox/`):
the app is the only store writer, so a write tool *queues* an op the app applies on its
next cycle (see [Writing back](#writing-back-the-agent-layer)). Run the Mac app once to
populate the corpus and to ingest anything the server queues. Override the whole directory
with the `OLLIE_CORPUS` environment variable (everything — corpus, layer files, inbox — is
derived from it).

> **The corpus only refreshes while the Ollie Mac app is running.** The export is
> driven by the app re-projecting its store; nothing updates `~/Ollie` when the app is
> closed. So if the app has been quit for a while, the corpus can be stale. The Mac app
> writes a sidecar `~/Ollie/.ollie.meta.json` (`exportedAt`, `noteCount`,
> `schemaVersion`) after each successful export; `corpus_stats()` reads it and returns a
> `staleness` block that **warns when the corpus is older than ~24h** (open the app to
> refresh). The server degrades gracefully if the meta file is missing — it falls back
> to the corpus file's modification time and never crashes.

## Tools

**Reads — notes:**

| Tool | What it does |
|---|---|
| `search_notes(query, limit)` | Case-insensitive substring search over text + place |
| `list_notes(since, until, source, limit)` | Date-range list (e.g. "the last week") |
| `recent_notes(limit)` | The newest notes |
| `get_note(id)` | One full note record |
| `corpus_stats()` | Count, date span, per-source breakdown, agent-layer sizes (`layerCounts`), and queued-write count (`pendingOps`) |

**Reads — agent layer:**

| Tool | What it does |
|---|---|
| `get_instructions()` | The user's standing instructions to agents (read first, honor it) |
| `tag_vocabulary()` | Existing tags with counts + last-used — reuse before inventing |
| `notes_by_tag(tag, limit)` | Notes carrying a tag (case-insensitive), newest first |
| `read_memory(include_retired)` | The agent codebook (durable facts); retired hidden by default |
| `list_views()` | Named views (living documents), most-recently-updated first |
| `get_view(name, revision_limit)` | A view's latest markdown body + recent revision metadata |

**Writes — agent layer** (each *queues* an op and returns `{"requestId", "status": "queued"}`; the Mac app applies it on its next cycle):

| Tool | What it does |
|---|---|
| `tag_note(id, tag)` | Attach a tag to a note (set semantics; re-applying is a no-op) |
| `untag_note(id, tag)` | Remove a tag (case-insensitive; idempotent) |
| `append_memory(text)` | Record one durable codebook fact (1–2000 chars) |
| `retire_memory(id)` | Tombstone a memory entry (idempotent; not a hard delete) |
| `publish_view(name, body)` | Publish a revision of a named view (markdown, appends) |

## Writing back (the agent layer)

The write tools never touch the store directly — the **Mac app is the only store writer**.
Instead each drops an op file into `~/Ollie/inbox/<agentId>-<requestId>.json` (written to a
hidden temp name, then atomically renamed into place) and returns immediately with a
`requestId` and `status: "queued"`. The Mac app's inbox ingestor validates and applies it,
then it syncs via CloudKit and re-exports. A **client-side cap violation** (tag > 64 chars,
memory > 2000, view name > 80, body > 128 KiB, or a missing field) returns `{"error": …}`
and queues nothing — the same bounds the app enforces on apply.

Because the apply is asynchronous, the reads **overlay** the still-queued ops onto the
exported files (*read-your-writes*): a tag you just added shows up in `tag_vocabulary()` and
`notes_by_tag()` right away, a queued view is visible in `get_view()`, etc. — even before
the app has ingested it. `corpus_stats().pendingOps` tells you how many of your writes are
still waiting; if it stays above zero, the Mac app is probably closed.

The op the server writes is stamped with an `agentId` from the `OLLIE_AGENT_ID` environment
variable (default `claude-mac`; the launchd runner sets `claude-runner`).

## Setup

```bash
cd /Users/mohammadshobaki/Desktop/Projects/Agents/HandheldNotes/mcp-server
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt
# to run the tests too:
pip install -r requirements-dev.txt   # adds pytest
pytest tests/
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

### Allowlisting the write tools

The **read** tools are safe to auto-approve. The **write** tools (`tag_note`,
`untag_note`, `append_memory`, `retire_memory`, `publish_view`) queue changes into your
corpus, so an interactive Claude session will prompt before each one unless you allowlist
them. For an unattended/headless run (e.g. the scheduled agent) they *must* be allowlisted
or the run stalls on a prompt. Add them to the `permissions.allow` list in
`~/.claude/settings.local.json`:

```json
{
  "permissions": {
    "allow": [
      "mcp__ollie__tag_note",
      "mcp__ollie__untag_note",
      "mcp__ollie__append_memory",
      "mcp__ollie__retire_memory",
      "mcp__ollie__publish_view"
    ]
  }
}
```

(Or allow the whole server with `"mcp__ollie__*"`.) These are *your* notes on *your*
machine, and every op is attributed and reversible (untag, retire, or delete in the app),
so broad approval is reasonable — but it's opt-in by design.

## Design

- `ollie_corpus.py` — pure note logic (load + filter), no MCP deps, unit-testable.
- `ollie_layers.py` — pure agent-layer logic: readers for the four layer files, the
  pending-ops reader, the read-your-writes overlays, client-side cap validation, and the
  temp+rename op-file writer. No MCP deps either.
- `ollie_mcp.py` — thin FastMCP wrapper that exposes both as tools; the docstrings are the
  agent's manual.
- Re-reads the files on every call, so reads always reflect the latest export (plus any
  ops still queued in the inbox).
- `tests/test_layers.py` — pytest suite (overlay correctness, op-file shape, client-side
  caps, vocabulary counting). Run with `pytest tests/`.
