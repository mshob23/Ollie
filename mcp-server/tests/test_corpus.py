"""Tests for `ollie_corpus` — the pure note-corpus read/filter logic, focused on the
M13 arrival-time coverage filter (`ingested_since`) and how `slim` surfaces
`ingestedAt`.

Runs against the isolated `OLLIE_CORPUS`-redirected directory (`ollie_dir` fixture) —
no test touches the real `~/Ollie`.
"""
from __future__ import annotations

import ollie_corpus as c


def _note(nid: str, text: str, created: str, ingested: str | None = None,
          source: str = "watch") -> dict:
    """A corpus row. `ingested` omitted → an OLD export that predates ingestedAt."""
    row = {"id": nid, "createdAt": created, "source": source, "kind": "voice",
           "text": text}
    if ingested is not None:
        row["ingestedAt"] = ingested
    return row


A = "aaaaaaaa-0000-0000-0000-000000000001"
B = "bbbbbbbb-0000-0000-0000-000000000002"
D = "dddddddd-0000-0000-0000-000000000004"


# ── ingested_since: the coverage-correct filter ──────────────────────────────────

def test_ingested_since_catches_late_synced_note_that_since_would_miss():
    """The core M13 scenario. A watch note CREATED before the last run but that ARRIVED
    after it (late sync). `since` (createdAt) drops it — the coverage hole. But
    `ingested_since` at the same boundary keeps it, because its arrival is recent."""
    last_run = "2026-07-06T00:00:00Z"
    late = _note(A, "spoken on the sidewalk",
                 created="2026-07-05T09:00:00Z",       # before last run
                 ingested="2026-07-06T14:00:00Z")      # arrived AFTER last run
    notes = [late]

    # createdAt filter misses it (this is the bug being fixed).
    assert c.in_range(notes, since=last_run) == []
    # arrival filter catches it.
    got = c.in_range(notes, ingested_since=last_run)
    assert [n["id"] for n in got] == [A]


def test_ingested_since_excludes_note_that_arrived_before_boundary():
    last_run = "2026-07-06T00:00:00Z"
    old_arrival = _note(B, "already seen last run",
                        created="2026-07-04T10:00:00Z",
                        ingested="2026-07-05T10:00:00Z")   # arrived before last run
    assert c.in_range([old_arrival], ingested_since=last_run) == []


def test_ingested_since_falls_back_to_created_at_for_old_exports():
    """A note from an OLD export has no `ingestedAt`. The arrival filter falls back to
    `createdAt`, so such notes still filter sensibly (they're all we have)."""
    boundary = "2026-07-06T00:00:00Z"
    # No ingestedAt field; createdAt is AFTER the boundary → included via fallback.
    new_old_export = _note(A, "no arrival field, recent createdAt",
                           created="2026-07-06T12:00:00Z")
    # No ingestedAt; createdAt BEFORE the boundary → excluded via fallback.
    stale_old_export = _note(B, "no arrival field, old createdAt",
                             created="2026-07-01T12:00:00Z")
    got = c.in_range([new_old_export, stale_old_export], ingested_since=boundary)
    assert [n["id"] for n in got] == [A], "fallback to createdAt when ingestedAt absent"


def test_ingested_since_composes_with_source_filter():
    boundary = "2026-07-06T00:00:00Z"
    watch_late = _note(A, "watch late", created="2026-07-05T09:00:00Z",
                       ingested="2026-07-06T14:00:00Z", source="watch")
    phone_late = _note(B, "phone late", created="2026-07-05T09:00:00Z",
                       ingested="2026-07-06T15:00:00Z", source="phone")
    got = c.in_range([watch_late, phone_late], ingested_since=boundary, source="watch")
    assert [n["id"] for n in got] == [A], "ingested_since and source both apply"


def test_plain_since_still_bounds_on_created_at():
    """Regression: the existing `since`/`until` semantics (createdAt) are unchanged."""
    n_new = _note(A, "new", created="2026-07-07T00:00:00Z",
                  ingested="2026-07-07T00:00:00Z")
    n_old = _note(B, "old", created="2026-07-01T00:00:00Z",
                  ingested="2026-07-07T00:00:00Z")   # recent arrival, but old createdAt
    # since bounds on createdAt → the old-createdAt note is excluded even though it
    # arrived recently (that's what `since` means; `ingested_since` is the other tool).
    got = c.in_range([n_new, n_old], since="2026-07-05T00:00:00Z")
    assert [n["id"] for n in got] == [A]


# ── slim: ingestedAt surfaced when present, omitted for old exports ───────────────

def test_slim_carries_ingested_at_when_present():
    row = _note(A, "has arrival", created="2026-07-05T09:00:00Z",
                ingested="2026-07-06T14:00:00Z")
    out = c.slim(row)
    assert out["ingestedAt"] == "2026-07-06T14:00:00Z"
    assert out["createdAt"] == "2026-07-05T09:00:00Z"
    assert out["text"] == "has arrival"


def test_slim_omits_ingested_at_for_old_export():
    row = _note(B, "no arrival field", created="2026-07-05T09:00:00Z")  # no ingestedAt
    out = c.slim(row)
    assert "ingestedAt" not in out, "omit the field for exports that predate it"
    assert out["createdAt"] == "2026-07-05T09:00:00Z"


def test_in_range_results_include_ingested_at_in_slim_rows():
    row = _note(A, "arrival visible in results", created="2026-07-05T09:00:00Z",
                ingested="2026-07-06T14:00:00Z")
    got = c.in_range([row], ingested_since="2026-07-06T00:00:00Z")
    assert got and got[0]["ingestedAt"] == "2026-07-06T14:00:00Z"
