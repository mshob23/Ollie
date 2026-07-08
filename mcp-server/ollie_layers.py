"""Pure agent-layer logic for the Ollie MCP server — NO mcp/SDK imports, so it's
unit-testable on its own. This is the write-back half of the corpus, mirroring
`ollie_corpus.py`'s style (fresh reads, graceful degradation, `slim` records).

The Ollie Mac app exports four agent-layer artifacts next to `ollie.jsonl`
(contract §3.3 / `docs/agent-contract.md`):

    ~/Ollie/tags.jsonl          {"noteId","tag","agentId","createdAt"}
    ~/Ollie/memory.jsonl        {"id","text","agentId","createdAt","retired","retiredAt"?}
    ~/Ollie/views.jsonl         {"id","viewName","body","agentId","createdAt"}  (every revision)
    ~/Ollie/instructions.md     plain markdown
    ~/Ollie/interactions.jsonl  {"viewName","blockId","blockText","kind","value",
                                 "revisionId","surface","updatedAt"}  (Views v2 spec §6)

…and ingests op files the *other* way, from `~/Ollie/inbox/` (contract §3.4):

    ~/Ollie/inbox/<agentId>-<requestId>.json
      {"op","agent","via":"inbox","ts":<iso8601>,"requestId":<uuid>,"payload":{…}}

This module (a) reads those exported artifacts, (b) **overlays** the ops still
sitting un-ingested in the inbox onto those reads so an agent sees its own just-
written tag/memory/view immediately (read-your-writes — the apply is async; the Mac
app may not have run the ingestor yet), and (c) **writes** new op files with the
exact temp-then-rename delivery the ingestor expects.

Everything here is deliberately dumb: it validates *mechanics* (ids, sizes) and
never meaning, exactly like the app-side `AgentLayerStore` — and it reuses the same
cap constants so a rejection is identical across doors.
"""
from __future__ import annotations

import json
import os
import unicodedata
import uuid
from datetime import datetime, timezone
from pathlib import Path

import ollie_corpus as c


# ── Caps (contract §4 table) ────────────────────────────────────────────────────
# These MIRROR `AgentLayerStore.Caps` in the Swift core exactly. We enforce them
# CLIENT-SIDE (reject before writing an op file) so the agent gets an immediate,
# specific error instead of a silent rejection line in `~/Ollie/rejected.jsonl`
# minutes later, and so a malformed op never even reaches the inbox. The app
# re-validates on apply — this is a courtesy gate, not the security boundary.
TAG_MAX = 64
MEMORY_TEXT_MAX = 2000
VIEW_NAME_MAX = 80
VIEW_BODY_MAX = 131072
#: Envelope files above this size are rejected by the ingestor unread (contract §4:
#: "file ≤ 256 KB"). We keep well under it — `body` alone is capped at 128 KiB.
MAX_FILE_BYTES = 256 * 1024

#: The door this server writes through (contract §1). Only `inbox` is live today.
VIA_INBOX = "inbox"

#: Default agent identity when `OLLIE_AGENT_ID` is unset. `provider-surface`
#: (contract §1); the Mac-hosted server is `claude-mac`.
DEFAULT_AGENT_ID = "claude-mac"


def agent_id() -> str:
    """The `agentId` stamped on every op this server writes. Overridable with the
    `OLLIE_AGENT_ID` env var (e.g. `claude-runner` for the launchd loop); defaults
    to `claude-mac`."""
    return os.environ.get("OLLIE_AGENT_ID", DEFAULT_AGENT_ID).strip() or DEFAULT_AGENT_ID


# ── Paths (all derived from the corpus path so OLLIE_CORPUS relocates everything) ─
def _ollie_dir() -> Path:
    """The `~/Ollie` directory — the parent of the corpus file. Deriving every
    agent-layer path from `ollie_corpus.corpus_path()` means setting `OLLIE_CORPUS`
    (as the tests do) redirects the layer files, the inbox, and the corpus together,
    exactly like the Swift side keys everything off `CorpusExporter.exportDirectory`."""
    return c.corpus_path().parent


def tags_path() -> Path:
    return _ollie_dir() / "tags.jsonl"


def memory_path() -> Path:
    return _ollie_dir() / "memory.jsonl"


def views_path() -> Path:
    return _ollie_dir() / "views.jsonl"


def instructions_path() -> Path:
    return _ollie_dir() / "instructions.md"


def interactions_path() -> Path:
    return _ollie_dir() / "interactions.jsonl"


def inbox_dir() -> Path:
    return _ollie_dir() / "inbox"


# ── Low-level readers (fresh every call — the app rewrites these files whole) ─────
def _load_jsonl(path: Path) -> list[dict]:
    """Read one-JSON-object-per-line, skipping blanks and any line that doesn't
    parse (tolerant, like `ollie_corpus.load`). Missing file → []."""
    if not path.exists():
        return []
    out: list[dict] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(obj, dict):
            out.append(obj)
    return out


def load_tags() -> list[dict]:
    """Raw exported tags: `{"noteId","tag","agentId","createdAt"}` per line. These
    are already restriction-GATED by the Mac app (tags on restricted notes never
    reach the file), so callers may treat every tag here as exportable."""
    return _load_jsonl(tags_path())


def load_memory() -> list[dict]:
    """Raw exported memory: `{"id","text","agentId","createdAt","retired","retiredAt"?}`
    per line. Retired entries ARE included and flagged (`retired: true`) — filtering
    them is the reader's choice."""
    return _load_jsonl(memory_path())


def load_views() -> list[dict]:
    """Raw exported view revisions: `{"id","viewName","body","agentId","createdAt"}`
    per line — EVERY revision, full body (snapshots, not diffs). A "view" is the set
    of revisions sharing `viewName`; latest `createdAt` wins for display."""
    return _load_jsonl(views_path())


def load_instructions() -> str:
    """The user's standing instructions to agents (plain markdown), or "" if the
    file is missing/empty. Degrades gracefully — never raises."""
    p = instructions_path()
    try:
        return p.read_text(encoding="utf-8") if p.exists() else ""
    except OSError:
        return ""


def load_interactions() -> list[dict]:
    """Raw exported interaction state (Views v2 spec §6): `{"viewName","blockId",
    "blockText","kind","value","revisionId","surface","updatedAt"}` per line — the
    user's per-block checkbox toggles on views. The Mac app already orphan-prunes this
    file (deleted-view + superseded-stale records), so every row here is live; the
    *applying* subset per view is filtered by `get_view` under the precedence rule
    (spec §1: an overlay applies iff its `updatedAt` is newer than the displayed
    revision). Interaction state has **no inbox op** — it's user-authored/app-written,
    so there is no overlay to fold; this file is the whole truth."""
    return _load_jsonl(interactions_path())


# ── Inbox / pending ops (the un-ingested tail the overlay reads) ─────────────────
def pending_ops(inbox: Path | None = None) -> list[dict]:
    """The op files sitting in `~/Ollie/inbox/` that the Mac app hasn't applied yet.

    Returns the decoded envelopes (contract §3.4). Matches the ingestor's own view
    of "pending" precisely: **top-level `*.json` only**, excluding the `rejected/`
    subdirectory and any hidden (dot-prefixed) file — the latter is how in-flight
    temp writes hide themselves (see `write_op`). Unreadable/undecodable files are
    skipped (the ingestor will move them to `inbox/rejected/`); they aren't ours to
    interpret. Sorted by filename for a stable, deterministic order."""
    d = inbox if inbox is not None else inbox_dir()
    if not d.exists():
        return []
    out: list[dict] = []
    for entry in sorted(d.iterdir(), key=lambda p: p.name):
        if entry.name.startswith("."):        # hidden = an in-flight temp write
            continue
        if entry.suffix.lower() != ".json":   # only op files
            continue
        if not entry.is_file():               # skips rejected/ subdir
            continue
        try:
            obj = json.loads(entry.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if isinstance(obj, dict):
            out.append(obj)
    return out


def pending_count(inbox: Path | None = None) -> int:
    """How many op files await ingestion — surfaced by `corpus_stats()` so an agent
    can tell its writes are still queued (the Mac app applies them on its next
    ingest cycle; if this stays >0 for long the app is probably closed)."""
    return len(pending_ops(inbox))


# ── Overlay: apply pending ops onto reads (read-your-writes) ──────────────────────
# The apply is asynchronous: `write_op` drops a file, and only when the Mac app runs
# does it land in tags.jsonl/memory.jsonl/views.jsonl. Between those two moments an
# agent that reads back its own just-written tag would NOT see it. These overlays
# fold the pending ops onto the exported baseline so reads reflect the agent's own
# intent immediately. Ops from *other* agents in the shared inbox are folded too —
# the inbox is the authoritative pending set regardless of author.
#
# We only overlay op kinds whose effect is a pure function of the file + the op
# (tag/untag/memory.append/memory.retire/view.publish). We do NOT re-implement the
# app's dedup/idempotency subtleties beyond what a reader needs; the app remains the
# source of truth once it applies.

def _op_kind(op: dict) -> str:
    return str(op.get("op", ""))


def _payload(op: dict) -> dict:
    p = op.get("payload")
    return p if isinstance(p, dict) else {}


def overlay_tags(base: list[dict], ops: list[dict]) -> list[dict]:
    """Fold pending `tag`/`untag` ops onto exported tag records.

    - `tag`: add `{noteId,tag,agentId,createdAt}` unless an equal `(noteId, tag)`
      pair (case-insensitive, matching the app's set semantics) is already present.
    - `untag`: drop every record whose `(noteId, tag)` matches case-insensitively.

    `agentId`/`createdAt` for a pending add come from the op envelope so the overlaid
    record looks just like what the app will write."""
    result = [dict(t) for t in base]

    def _has(note_id: str, tag: str) -> bool:
        return any(
            str(t.get("noteId")) == note_id
            and str(t.get("tag", "")).casefold() == tag.casefold()
            for t in result
        )

    for op in ops:
        kind = _op_kind(op)
        pl = _payload(op)
        note_id = pl.get("noteId")
        tag = pl.get("tag")
        if not note_id or not isinstance(tag, str) or not tag.strip():
            continue
        note_id, tag = str(note_id), tag.strip()
        if kind == "tag":
            if not _has(note_id, tag):
                result.append({
                    "noteId": note_id,
                    "tag": tag,
                    "agentId": op.get("agent", ""),
                    "createdAt": op.get("ts", ""),
                })
        elif kind == "untag":
            result = [
                t for t in result
                if not (str(t.get("noteId")) == note_id
                        and str(t.get("tag", "")).casefold() == tag.casefold())
            ]
    return result


def overlay_memory(base: list[dict], ops: list[dict]) -> list[dict]:
    """Fold pending `memory.append`/`memory.retire` ops onto exported memory records.

    - `memory.append`: append a new entry. It has no committed `id` yet (the app
      mints one on apply), so the overlaid entry carries `pending: true` and no `id`
      — enough for the agent to see the text landed.
    - `memory.retire`: flip `retired`/`retiredAt` on the entry whose `id` matches
      (idempotent — an already-retired entry is untouched)."""
    result = [dict(m) for m in base]
    for op in ops:
        kind = _op_kind(op)
        pl = _payload(op)
        if kind == "memory.append":
            text = pl.get("text")
            if isinstance(text, str) and text.strip():
                result.append({
                    "text": text.strip(),
                    "agentId": op.get("agent", ""),
                    "createdAt": op.get("ts", ""),
                    "retired": False,
                    "pending": True,
                })
        elif kind == "memory.retire":
            mid = pl.get("id")
            if not mid:
                continue
            for m in result:
                if str(m.get("id")) == str(mid) and not m.get("retired"):
                    m["retired"] = True
                    m["retiredAt"] = op.get("ts", "")
    return result


def overlay_views(base: list[dict], ops: list[dict]) -> list[dict]:
    """Fold pending `view.publish` ops onto exported view revisions.

    Each publish appends a new revision `{viewName,body,agentId,createdAt}` under the
    (exact) name — no committed `id` yet, so it carries `pending: true`. Because
    `createdAt` comes from the op's `ts` (minted just now), a pending publish sorts
    as the newest revision for its view, which is the read-your-writes behaviour an
    agent wants (its fresh view body is what `get_view` shows)."""
    result = [dict(v) for v in base]
    for op in ops:
        if _op_kind(op) != "view.publish":
            continue
        pl = _payload(op)
        name = pl.get("viewName")
        body = pl.get("body")
        if not isinstance(name, str) or not name.strip():
            continue
        if not isinstance(body, str):
            continue
        result.append({
            "viewName": name.strip(),
            "body": body,
            "agentId": op.get("agent", ""),
            "createdAt": op.get("ts", ""),
            "pending": True,
        })
    return result


# ── Effective (overlaid) reads — what the tools serve ────────────────────────────
def effective_tags(inbox: Path | None = None) -> list[dict]:
    """Exported tags with pending inbox ops folded in (read-your-writes)."""
    return overlay_tags(load_tags(), pending_ops(inbox))


def effective_memory(inbox: Path | None = None) -> list[dict]:
    """Exported memory with pending appends/retires folded in."""
    return overlay_memory(load_memory(), pending_ops(inbox))


def effective_views(inbox: Path | None = None) -> list[dict]:
    """Exported view revisions with pending publishes folded in."""
    return overlay_views(load_views(), pending_ops(inbox))


# ── Derived read shapes (the tool bodies) ────────────────────────────────────────
def tag_vocabulary(inbox: Path | None = None) -> list[dict]:
    """The tag lexicon: each distinct tag with how many notes carry it and when it
    was last used, most-used first (ties broken by most-recent). Keys per row:
    `tag`, `count`, `lastUsed`. Tags are grouped case-insensitively; the most recent
    spelling is the display form. This is the "reuse before inventing" surface — an
    agent checks it before minting a new tag.

    **Counts only tags that resolve to a note in the corpus** — the SAME note-membership
    join ``notes_by_tag`` applies. A tag record whose `noteId` is absent from
    `ollie.jsonl` (its note was deleted, or is restricted-and-gated) is an **orphan**: it
    contributes nothing here, exactly as `notes_by_tag` returns nothing for it. Defense in
    depth against a stale/racy export where an orphan row lingers in `tags.jsonl` — the
    Mac app's export gate should already drop such rows, but deriving both tools from one
    join means `tag_vocabulary` and `notes_by_tag` can **never** contradict each other
    (the bug: vocabulary reporting a count for a tag `notes_by_tag` returns empty for).
    `count` is therefore the number of **distinct resolvable notes**, not raw tag rows."""
    # The live note ids in the corpus — the membership set the join keys on.
    note_ids = {n.get("id") for n in c.load()}
    # Group case-insensitively; keep the spelling with the newest createdAt as canon.
    # De-dup per (tag, noteId) too, so `count` is distinct notes even if a note somehow
    # carries the same tag twice (matches `notes_by_tag`'s per-note dedup).
    groups: dict[str, dict] = {}
    for t in effective_tags(inbox):
        raw = str(t.get("tag", "")).strip()
        if not raw:
            continue
        nid = str(t.get("noteId", ""))
        if nid not in note_ids:      # orphan tag — no resolvable note → not counted
            continue
        key = raw.casefold()
        created = str(t.get("createdAt", ""))
        g = groups.get(key)
        if g is None:
            groups[key] = {"tag": raw, "count": 1, "lastUsed": created, "_notes": {nid}}
        elif nid not in g["_notes"]:
            g["_notes"].add(nid)
            g["count"] += 1
            if created > g["lastUsed"]:
                g["lastUsed"] = created
                g["tag"] = raw  # newest spelling wins as the display form
        elif created > g["lastUsed"]:
            g["lastUsed"] = created
            g["tag"] = raw
    rows = [{"tag": g["tag"], "count": g["count"], "lastUsed": g["lastUsed"]}
            for g in groups.values()]
    rows.sort(key=lambda r: (r["count"], r["lastUsed"]), reverse=True)
    return rows


def notes_by_tag(tag: str, limit: int = 50, inbox: Path | None = None) -> list[dict]:
    """Slim note records (newest first) for every note carrying `tag` (matched
    case-insensitively). Joins the tag layer to the note corpus and returns the same
    `slim` shape as the read tools (`id,createdAt,source,kind,place,text`). A tag
    pointing at a note that's since been deleted/restricted (absent from the corpus)
    is silently skipped."""
    want = (tag or "").strip().casefold()
    if not want:
        return []
    matched_ids: list[str] = []
    seen: set[str] = set()
    for t in effective_tags(inbox):
        if str(t.get("tag", "")).strip().casefold() != want:
            continue
        nid = str(t.get("noteId", ""))
        if nid and nid not in seen:
            seen.add(nid)
            matched_ids.append(nid)
    by_id = {n.get("id"): n for n in c.load()}
    notes = [by_id[nid] for nid in matched_ids if nid in by_id]
    notes.sort(key=lambda n: n.get("createdAt", ""), reverse=True)
    return [c.slim(n) for n in notes[:limit]]


def read_memory(include_retired: bool = False, inbox: Path | None = None) -> list[dict]:
    """The agent codebook (memory), newest first. Each row: `text`, `agentId`,
    `createdAt`, `retired` (and `retiredAt` when retired; `pending: true` for an
    entry queued but not yet applied). Retired entries are hidden unless
    `include_retired=True` — they're tombstoned decodings/preferences the agent
    superseded."""
    entries = effective_memory(inbox)
    if not include_retired:
        entries = [m for m in entries if not m.get("retired")]
    entries.sort(key=lambda m: m.get("createdAt", ""), reverse=True)
    # Return a stable, documented projection (drop nothing meaningful; keep order).
    out: list[dict] = []
    for m in entries:
        row = {
            "text": m.get("text", ""),
            "agentId": m.get("agentId", ""),
            "createdAt": m.get("createdAt", ""),
            "retired": bool(m.get("retired", False)),
        }
        if m.get("id") is not None:
            row["id"] = m.get("id")
        if row["retired"] and m.get("retiredAt"):
            row["retiredAt"] = m.get("retiredAt")
        if m.get("pending"):
            row["pending"] = True
        out.append(row)
    return out


def _group_views(revisions: list[dict]) -> dict[str, list[dict]]:
    """Group revisions by exact `viewName`, each list sorted newest `createdAt`
    first."""
    groups: dict[str, list[dict]] = {}
    for r in revisions:
        name = str(r.get("viewName", ""))
        if not name:
            continue
        groups.setdefault(name, []).append(r)
    for name in groups:
        groups[name].sort(key=lambda r: r.get("createdAt", ""), reverse=True)
    return groups


def list_views(inbox: Path | None = None) -> list[dict]:
    """One row per named view (the living documents agents publish), most-recently-
    updated first. Keys: `name`, `revisionCount`, `latestAt`, `latestAgent`. This is
    the Views feed's backing data — call `get_view(name)` for a view's body."""
    groups = _group_views(effective_views(inbox))
    rows: list[dict] = []
    for name, revs in groups.items():
        latest = revs[0]
        rows.append({
            "name": name,
            "revisionCount": len(revs),
            "latestAt": latest.get("createdAt", ""),
            "latestAgent": latest.get("agentId", ""),
        })
    rows.sort(key=lambda r: r["latestAt"], reverse=True)
    return rows


def applying_interactions(view_name: str, latest_at: str,
                          interactions: list[dict] | None = None) -> list[dict]:
    """The interaction rows that **apply** to a view's latest revision under the
    precedence rule (Views v2 spec §1): an overlay applies iff its `updatedAt` is
    strictly newer than the displayed revision's `createdAt` — a newer revision
    supersedes older interaction state (publishing is the acknowledgment). Filters
    `interactions` (defaults to `load_interactions()`) to `view_name` and to rows with
    `updatedAt > latest_at`, returning each as the denormalized agent shape
    `{blockId, blockText, value, updatedAt}` (spec §6 — `blockText` is carried so the
    agent never recomputes the hash), newest first.

    ISO-8601 UTC timestamps compare correctly as strings (fixed width, `Z` suffix),
    so a lexical `>` is the temporal `>`; an empty/absent `latest_at` (no revision)
    admits every row for the view."""
    rows = interactions if interactions is not None else load_interactions()
    out: list[dict] = []
    for r in rows:
        if str(r.get("viewName", "")) != view_name:
            continue
        updated = str(r.get("updatedAt", ""))
        if updated <= latest_at:          # not newer than the displayed revision → superseded
            continue
        out.append({
            "blockId": r.get("blockId", ""),
            "blockText": r.get("blockText", ""),
            "value": r.get("value", ""),
            "updatedAt": updated,
        })
    out.sort(key=lambda r: r["updatedAt"], reverse=True)
    return out


def get_view(name: str, revision_limit: int = 5, inbox: Path | None = None) -> dict:
    """One view by exact `name`: the latest revision's full `body`, its **applying**
    interaction state, plus metadata for up to `revision_limit` recent revisions
    (newest first). Returns `{name, body, latestAt, latestAgent, revisionCount,
    revisions:[{createdAt,agentId,pending?},…], interactions:[{blockId,blockText,
    value,updatedAt},…]}`. The `revisions` list is metadata only (no bodies — call
    again per revision if you need an older body; prior bodies live in `views.jsonl`).
    `{"error": …}` if no such view exists. The body is the §3.5 markdown dialect:
    `ollie://note/<uuid>` citations and forward-compat fenced blocks.

    `interactions` are the user's checkbox toggles that still APPLY to the latest
    revision (Views v2 spec §1 — only rows whose `updatedAt` is newer than the
    returned revision; a republish retires older state). Consume them per the runbook:
    act on each checked item, then republish this view dropping it or baking in
    `- [x]` — the republish is the acknowledgment. Never write or delete interaction
    records."""
    groups = _group_views(effective_views(inbox))
    revs = groups.get(name)
    if not revs:
        return {"error": f"No view named {name!r}"}
    latest = revs[0]
    latest_at = latest.get("createdAt", "")
    meta: list[dict] = []
    for r in revs[: max(0, revision_limit)]:
        row = {"createdAt": r.get("createdAt", ""), "agentId": r.get("agentId", "")}
        if r.get("pending"):
            row["pending"] = True
        meta.append(row)
    return {
        "name": name,
        "body": latest.get("body", ""),
        "latestAt": latest_at,
        "latestAgent": latest.get("agentId", ""),
        "revisionCount": len(revs),
        "revisions": meta,
        "interactions": applying_interactions(name, latest_at),
    }


# ── Client-side op validation (reject before writing) ────────────────────────────
def _printable(s: str) -> bool:
    """True iff `s` contains no control characters — the app's "printable" tag rule
    (`AgentLayerStore.isValidTag`). Unicode category `Cc` covers newlines, tabs, and
    other control scalars."""
    return all(unicodedata.category(ch) != "Cc" for ch in s)


class OpValidationError(ValueError):
    """A would-be op failed a MECHANICAL cap before we wrote it (contract §4). The
    message is agent-facing; the write tools return it as `{"error": …}` and never
    touch the inbox. Mirrors the app-side `AgentLayerError` bounds so the two doors
    reject identically."""


def validate_op(op: str, payload: dict) -> None:
    """Enforce the §4 caps client-side. Raises ``OpValidationError`` on the first
    violation; returns None if the op is well-formed enough to queue. Only mechanics
    are checked (presence, length, printability) — never meaning."""
    if op == "tag" or op == "untag":
        note_id = payload.get("noteId")
        tag = payload.get("tag")
        if not note_id or not str(note_id).strip():
            raise OpValidationError("noteId is required")
        if not isinstance(tag, str) or not tag.strip():
            raise OpValidationError("tag is required")
        t = tag.strip()
        if op == "tag":
            # untag only needs presence (any length) to match & delete; tag must fit.
            if len(t) > TAG_MAX or not _printable(t):
                raise OpValidationError(
                    f"tag must be 1–{TAG_MAX} printable characters")
    elif op == "memory.append":
        text = payload.get("text")
        if not isinstance(text, str) or not text.strip():
            raise OpValidationError("text is required")
        if len(text.strip()) > MEMORY_TEXT_MAX:
            raise OpValidationError(f"text must be 1–{MEMORY_TEXT_MAX} characters")
    elif op == "memory.retire":
        mid = payload.get("id")
        if not mid or not str(mid).strip():
            raise OpValidationError("id is required")
    elif op == "view.publish":
        name = payload.get("viewName")
        body = payload.get("body")
        if not isinstance(name, str) or not name.strip():
            raise OpValidationError("viewName is required")
        if len(name.strip()) > VIEW_NAME_MAX:
            raise OpValidationError(f"viewName must be 1–{VIEW_NAME_MAX} characters")
        if not isinstance(body, str) or not body:
            raise OpValidationError("body is required")
        if len(body) > VIEW_BODY_MAX:
            raise OpValidationError(f"body must be 1–{VIEW_BODY_MAX} characters")
    else:
        raise OpValidationError(f"unknown op {op!r}")


# ── The op-file writer (temp + rename, exactly what the ingestor consumes) ────────
def _now_iso() -> str:
    """ISO-8601 UTC with NO fractional seconds and a literal `Z` — byte-for-byte what
    Swift's `JSONEncoder(.iso8601)` emits and what the ingestor's `.iso8601` decoder
    accepts (its default `ISO8601DateFormatter` rejects fractional seconds). Getting
    this wrong makes every op decode as "malformed envelope"."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def build_envelope(op: str, payload: dict, agent: str, request_id: str,
                   ts: str | None = None) -> dict:
    """Assemble the §3.4 inbox envelope. Separated from `write_op` so tests can assert
    the exact wire shape without touching the filesystem."""
    return {
        "op": op,
        "agent": agent,
        "via": VIA_INBOX,
        "ts": ts or _now_iso(),
        "requestId": request_id,
        "payload": payload,
    }


def write_op(op: str, payload: dict, agent: str | None = None,
             inbox: Path | None = None) -> str:
    """Queue one agent-layer write by dropping an op file into `~/Ollie/inbox/`, and
    return its freshly-minted `requestId`.

    Delivery matches the ingestor's contract exactly (§3.4 / M3):
      • Validates caps first (`validate_op`); a violation raises ``OpValidationError``
        and NOTHING is written.
      • Mints a `requestId` (UUID) and stamps `agent` (arg, else `OLLIE_AGENT_ID`,
        else `claude-mac`) and a no-fractional-seconds ISO-8601 `ts`.
      • Writes to a **hidden temp** name (`.<agent>-<requestId>.json.tmp`) then
        `os.replace`s it onto `<agent>-<requestId>.json`. The rename is atomic on
        APFS, and the dot-prefix keeps the ingestor (which scans top-level, non-hidden
        `*.json`) from race-reading a half-written file. `os.replace` also means a
        re-queue of the same requestId overwrites rather than erroring.

    The apply is asynchronous: the Mac app ingests on its next cycle. The overlay
    readers above make the write visible immediately in the meantime."""
    validate_op(op, payload)  # raises before any filesystem effect
    who = (agent or agent_id()).strip() or DEFAULT_AGENT_ID
    request_id = str(uuid.uuid4())
    envelope = build_envelope(op, payload, who, request_id)

    d = inbox if inbox is not None else inbox_dir()
    d.mkdir(parents=True, exist_ok=True)
    final = d / f"{who}-{request_id}.json"
    tmp = d / f".{who}-{request_id}.json.tmp"
    data = json.dumps(envelope, ensure_ascii=False, sort_keys=True)
    tmp.write_text(data, encoding="utf-8")
    os.replace(tmp, final)  # atomic rename into place
    return request_id
