"""Pure corpus logic for the Ollie MCP server — NO mcp/SDK imports, so it's
unit-testable on its own. Reads the JSONL the Ollie Mac app exports to
~/Ollie/ollie.jsonl (one note record per line)."""
from __future__ import annotations

import json
import os
from datetime import datetime, timedelta, timezone
from pathlib import Path


# Corpus is considered stale once it (or its recorded export time) is older than
# this. The Ollie Mac app only refreshes ~/Ollie while it is RUNNING, so a long
# gap usually means the app is closed — surface that rather than silently serving
# a stale corpus.
STALE_AFTER = timedelta(hours=24)


def corpus_path() -> Path:
    return Path(os.environ.get("OLLIE_CORPUS", Path.home() / "Ollie" / "ollie.jsonl"))


def meta_path(path: Path | None = None) -> Path:
    """The sidecar `.ollie.meta.json` the Mac app writes next to the corpus after
    every successful export. Lives in the same directory as the JSONL."""
    path = path or corpus_path()
    return path.parent / ".ollie.meta.json"


def load_meta(path: Path | None = None) -> dict:
    """Read `.ollie.meta.json` if present. Degrades gracefully: a missing or
    malformed meta file yields {} (never raises), so the server still works against
    an older corpus that predates the sidecar."""
    mp = meta_path(path)
    try:
        if not mp.exists():
            return {}
        return json.loads(mp.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def _exported_at(meta: dict) -> datetime | None:
    """Parse the meta file's ISO-8601 `exportedAt`, or None if absent/unparseable."""
    return parse_dt(str(meta.get("exportedAt", "")))


def staleness(path: Path | None = None) -> dict:
    """Describe how fresh the corpus is, for surfacing to the caller.

    Uses the most recent of (meta `exportedAt`, file mtime) as "last refreshed",
    and flags `stale` when that is older than STALE_AFTER. Degrades gracefully when
    the meta file is missing (falls back to mtime alone) and when the corpus file
    itself is missing (reports stale with a None timestamp)."""
    path = path or corpus_path()
    meta = load_meta(path)
    exported_at = _exported_at(meta)

    mtime: datetime | None = None
    try:
        if path.exists():
            mtime = datetime.fromtimestamp(path.stat().st_mtime, tz=timezone.utc)
    except OSError:
        mtime = None

    candidates = [t for t in (exported_at, mtime) if t is not None]
    last_refreshed = max(candidates) if candidates else None
    if last_refreshed is None:
        is_stale = True
        age_hours: float | None = None
    else:
        age = datetime.now(timezone.utc) - last_refreshed
        age_hours = round(age.total_seconds() / 3600, 1)
        is_stale = age > STALE_AFTER

    out: dict = {
        "exportedAt": meta.get("exportedAt"),
        "lastRefreshed": last_refreshed.isoformat() if last_refreshed else None,
        "ageHours": age_hours,
        "stale": is_stale,
    }
    if "noteCount" in meta:
        out["metaNoteCount"] = meta["noteCount"]
    if "schemaVersion" in meta:
        out["schemaVersion"] = meta["schemaVersion"]
    if is_stale:
        out["warning"] = (
            "Corpus may be stale (older than 24h). The Ollie Mac app only refreshes "
            "~/Ollie while it is running — open it to refresh."
        )
    return out


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


def stats(notes: list[dict], path: Path | None = None) -> dict:
    """Corpus summary, including freshness from `.ollie.meta.json`. The `staleness`
    block (exportedAt / lastRefreshed / stale + a warning when >24h old) is always
    present so the caller can tell the user when the corpus might be out of date —
    degrades gracefully (no crash) if the meta file is missing."""
    fresh = staleness(path)
    if not notes:
        return {
            "count": 0,
            "note": "empty or not found — run the Ollie Mac app to export",
            "staleness": fresh,
        }
    dates = sorted(n.get("createdAt", "") for n in notes if n.get("createdAt"))
    by_source: dict[str, int] = {}
    for n in notes:
        by_source[n.get("source", "?")] = by_source.get(n.get("source", "?"), 0) + 1
    return {
        "count": len(notes),
        "earliest": dates[0],
        "latest": dates[-1],
        "by_source": by_source,
        "staleness": fresh,
    }
