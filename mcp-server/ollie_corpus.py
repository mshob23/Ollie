"""Pure corpus logic for the Ollie MCP server — NO mcp/SDK imports, so it's
unit-testable on its own. Reads the JSONL the Ollie Mac app exports to
~/Ollie/ollie.jsonl (one note record per line)."""
from __future__ import annotations

import json
import os
from datetime import datetime, timedelta, timezone
from pathlib import Path


def corpus_path() -> Path:
    return Path(os.environ.get("OLLIE_CORPUS", Path.home() / "Ollie" / "ollie.jsonl"))


def load(path: Path | None = None) -> list[dict]:
    """Read the corpus fresh (the Mac app rewrites it whole on every change)."""
    path = path or corpus_path()
    if not path.exists():
        return []
    out: list[dict] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return out


def parse_dt(s: str, end_of_day: bool = False) -> datetime | None:
    """Parse YYYY-MM-DD or full ISO-8601 (UTC). A date-only `until` is treated as the
    END of that day so the range is inclusive."""
    s = (s or "").strip()
    if not s:
        return None
    try:
        if len(s) == 10:  # YYYY-MM-DD
            d = datetime.fromisoformat(s).replace(tzinfo=timezone.utc)
            return d + timedelta(days=1) - timedelta(microseconds=1) if end_of_day else d
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None


def _dt(note: dict) -> datetime | None:
    return parse_dt(note.get("createdAt", ""))


def slim(note: dict) -> dict:
    """Compact view for list results — full `text` included (it's the point)."""
    keep = ("id", "createdAt", "source", "kind", "place")
    return {k: note.get(k) for k in keep} | {"text": note.get("text", "")}


def search(notes: list[dict], query: str, limit: int = 20) -> list[dict]:
    q = (query or "").strip().lower()
    if q:
        hits = [n for n in notes
                if q in n.get("text", "").lower() or q in (n.get("place") or "").lower()]
    else:
        hits = list(notes)
    hits.sort(key=lambda n: n.get("createdAt", ""), reverse=True)
    return [slim(n) for n in hits[:limit]]


def in_range(notes: list[dict], since: str = "", until: str = "",
             source: str = "", limit: int = 50) -> list[dict]:
    lo, hi = parse_dt(since), parse_dt(until, end_of_day=True)
    out: list[dict] = []
    for n in notes:
        dt = _dt(n)
        if lo and (dt is None or dt < lo):
            continue
        if hi and (dt is None or dt > hi):
            continue
        if source and n.get("source") != source:
            continue
        out.append(n)
    out.sort(key=lambda n: n.get("createdAt", ""), reverse=True)
    return [slim(n) for n in out[:limit]]


def recent(notes: list[dict], limit: int = 20) -> list[dict]:
    ns = sorted(notes, key=lambda n: n.get("createdAt", ""), reverse=True)
    return [slim(n) for n in ns[:limit]]


def get(notes: list[dict], note_id: str) -> dict:
    for n in notes:
        if n.get("id") == note_id:
            return n
    return {"error": f"No note with id {note_id}"}


def stats(notes: list[dict]) -> dict:
    if not notes:
        return {"count": 0, "note": "empty or not found — run the Ollie Mac app to export"}
    dates = sorted(n.get("createdAt", "") for n in notes if n.get("createdAt"))
    by_source: dict[str, int] = {}
    for n in notes:
        by_source[n.get("source", "?")] = by_source.get(n.get("source", "?"), 0) + 1
    return {"count": len(notes), "earliest": dates[0], "latest": dates[-1], "by_source": by_source}
