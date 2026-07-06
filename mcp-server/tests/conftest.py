"""Pytest fixtures for the Ollie MCP server tests.

Puts the server package (`mcp-server/`, the parent of this `tests/` dir) on
`sys.path` so `import ollie_layers` / `import ollie_corpus` resolve without an
installed package, and provides an isolated `~/Ollie`-shaped directory keyed off
`OLLIE_CORPUS` (the same env override the modules read) so no test touches the real
one.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

# `mcp-server/` — one level up from `tests/`. Prepend so `import ollie_layers` works
# no matter what directory pytest is invoked from.
_SERVER_DIR = Path(__file__).resolve().parent.parent
if str(_SERVER_DIR) not in sys.path:
    sys.path.insert(0, str(_SERVER_DIR))


@pytest.fixture
def ollie_dir(tmp_path, monkeypatch):
    """An isolated, empty `~/Ollie`-shaped directory. Points `OLLIE_CORPUS` at
    `<tmp>/ollie.jsonl` so every path the modules derive (tags/memory/views/
    instructions/inbox + the corpus + meta) lands under `tmp_path`. Yields the
    directory `Path`."""
    corpus = tmp_path / "ollie.jsonl"
    monkeypatch.setenv("OLLIE_CORPUS", str(corpus))
    # Ensure a clean agent id unless a test overrides it.
    monkeypatch.delenv("OLLIE_AGENT_ID", raising=False)
    return tmp_path


def _write_jsonl(path: Path, rows: list[dict]) -> None:
    path.write_text(
        "".join(json.dumps(r, sort_keys=True) + "\n" for r in rows),
        encoding="utf-8",
    )


@pytest.fixture
def write_jsonl():
    """Helper to write a list of dicts as JSONL (one compact object per line), matching
    the Mac app's export shape."""
    return _write_jsonl
