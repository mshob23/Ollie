"""Tests for `ollie_layers.recent_runs` — the reader over the runner's append-only
work log `~/Ollie/agent-runs/runs.jsonl` (M13, contract §9).

Runs against the isolated `OLLIE_CORPUS`-redirected directory (`ollie_dir` fixture);
the log lives at `<ollie>/agent-runs/runs.jsonl`.
"""
from __future__ import annotations

import json

import ollie_layers as L


def _run(run_id: str, since: str, ok: bool = True, rc: int = 0) -> dict:
    """One work-log line, matching the shape the runner appends (contract §9)."""
    return {
        "runId": run_id,
        "agentId": "claude-runner",
        "startedAt": f"{run_id}-start",
        "finishedAt": f"{run_id}-end",
        "since": since,
        "corpusExportedAt": "2026-07-07T00:00:00Z",
        "rc": rc,
        "ok": ok,
        "logFile": f"{run_id}.log",
    }


def _write_runs(ollie_dir, lines: list[str]) -> None:
    """Write raw lines to the runs.jsonl path (creating agent-runs/), so a test can
    inject malformed content the append path would never itself produce."""
    d = ollie_dir / "agent-runs"
    d.mkdir(parents=True, exist_ok=True)
    (d / "runs.jsonl").write_text("".join(l + "\n" for l in lines), encoding="utf-8")


def _write_run_objs(ollie_dir, runs: list[dict]) -> None:
    _write_runs(ollie_dir, [json.dumps(r, sort_keys=True) for r in runs])


# ── path derivation ──────────────────────────────────────────────────────────────

def test_runs_path_derives_from_corpus(ollie_dir):
    assert L.runs_path() == ollie_dir / "agent-runs" / "runs.jsonl"


# ── missing file → [] ────────────────────────────────────────────────────────────

def test_recent_runs_missing_file_is_empty(ollie_dir):
    assert not (ollie_dir / "agent-runs" / "runs.jsonl").exists()
    assert L.recent_runs() == [], "no log yet → empty list, never raises"


def test_recent_runs_empty_file_is_empty(ollie_dir):
    _write_runs(ollie_dir, [])
    assert L.recent_runs() == []


# ── newest first ─────────────────────────────────────────────────────────────────

def test_recent_runs_returns_newest_first(ollie_dir):
    # Appended oldest → newest on disk (the order the runner writes).
    _write_run_objs(ollie_dir, [
        _run("20260701-000000", since="2026-06-30T00:00:00Z"),
        _run("20260705-000000", since="2026-07-01T00:00:00Z"),
        _run("20260707-000000", since="2026-07-05T00:00:00Z"),
    ])
    got = L.recent_runs()
    assert [r["runId"] for r in got] == [
        "20260707-000000", "20260705-000000", "20260701-000000",
    ], "newest (last appended) comes first"


# ── malformed line skipped, rest preserved ───────────────────────────────────────

def test_recent_runs_skips_malformed_line(ollie_dir):
    good_old = json.dumps(_run("20260701-000000", since="a"), sort_keys=True)
    good_new = json.dumps(_run("20260707-000000", since="b"), sort_keys=True)
    _write_runs(ollie_dir, [
        good_old,
        "{ this is not valid json",     # a torn / hand-mangled line
        "",                              # a blank line
        good_new,
    ])
    got = L.recent_runs()
    ids = [r["runId"] for r in got]
    assert ids == ["20260707-000000", "20260701-000000"], \
        "the malformed and blank lines are skipped; the two good rows survive newest-first"


def test_recent_runs_skips_non_object_json_line(ollie_dir):
    good = json.dumps(_run("20260707-000000", since="b"), sort_keys=True)
    _write_runs(ollie_dir, [
        "[1, 2, 3]",   # valid JSON, but not an object → not a run row
        good,
    ])
    got = L.recent_runs()
    assert [r["runId"] for r in got] == ["20260707-000000"]


# ── failure rows are included (both outcomes logged) ─────────────────────────────

def test_recent_runs_includes_failures(ollie_dir):
    _write_run_objs(ollie_dir, [
        _run("20260706-000000", since="x", ok=False, rc=7),
        _run("20260707-000000", since="y", ok=True, rc=0),
    ])
    got = L.recent_runs()
    assert got[0]["ok"] is True and got[0]["rc"] == 0
    assert got[1]["ok"] is False and got[1]["rc"] == 7, "failed runs appear too"


# ── limit ────────────────────────────────────────────────────────────────────────

def test_recent_runs_respects_limit(ollie_dir):
    _write_run_objs(ollie_dir, [
        _run(f"2026070{i}-000000", since="s") for i in range(1, 8)
    ])
    got = L.recent_runs(limit=3)
    assert len(got) == 3
    assert [r["runId"] for r in got] == [
        "20260707-000000", "20260706-000000", "20260705-000000",
    ], "limit takes the N newest"


def test_recent_runs_default_limit_is_10(ollie_dir):
    _write_run_objs(ollie_dir, [
        _run(f"run-{i:02d}", since="s") for i in range(20)
    ])
    got = L.recent_runs()
    assert len(got) == 10, "default limit caps at 10"


def test_recent_runs_zero_limit_returns_empty(ollie_dir):
    _write_run_objs(ollie_dir, [_run("20260707-000000", since="s")])
    assert L.recent_runs(limit=0) == []
