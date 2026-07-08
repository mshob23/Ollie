"""Tests for `ollie_layers` — the agent-layer read/overlay/write logic.

Covers what the M4 plan calls out: overlay correctness (read-your-writes), op-file
shape + delivery (temp+rename, envelope), client-side cap enforcement (reject before
writing), and vocabulary counting. Plus the derived read shapes the tools serve.

Everything runs against an isolated `OLLIE_CORPUS`-redirected directory (the
`ollie_dir` fixture) — no test touches the real `~/Ollie`.
"""
from __future__ import annotations

import json
import re

import pytest

import ollie_layers as L


ISO = "%Y-%m-%dT%H:%M:%SZ"
UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
                     r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")

N1 = "799D4F47-8632-48FF-A4AC-C5DF1DFAB1ED"
N2 = "11111111-2222-3333-4444-555555555555"


def _note(nid: str, text: str, created: str = "2026-07-06T05:00:00Z",
          source: str = "phone") -> dict:
    return {"id": nid, "createdAt": created, "source": source, "kind": "text",
            "text": text}


# ── Path derivation ──────────────────────────────────────────────────────────────

def test_paths_derive_from_corpus(ollie_dir):
    assert L.tags_path() == ollie_dir / "tags.jsonl"
    assert L.memory_path() == ollie_dir / "memory.jsonl"
    assert L.views_path() == ollie_dir / "views.jsonl"
    assert L.instructions_path() == ollie_dir / "instructions.md"
    assert L.inbox_dir() == ollie_dir / "inbox"


# ── Readers degrade gracefully on missing/blank/garbage files ─────────────────────

def test_readers_missing_files_empty(ollie_dir):
    assert L.load_tags() == []
    assert L.load_memory() == []
    assert L.load_views() == []
    assert L.load_instructions() == ""
    assert L.pending_ops() == []
    assert L.pending_count() == 0


def test_load_jsonl_skips_blank_and_garbage(ollie_dir, write_jsonl):
    (ollie_dir / "tags.jsonl").write_text(
        json.dumps({"noteId": N1, "tag": "a", "agentId": "claude-mac",
                    "createdAt": "2026-07-06T05:00:00Z"}) + "\n"
        "\n"                      # blank line
        "not json at all\n",     # garbage line
        encoding="utf-8",
    )
    tags = L.load_tags()
    assert len(tags) == 1 and tags[0]["tag"] == "a"


def test_load_instructions(ollie_dir):
    (ollie_dir / "instructions.md").write_text("Be terse.\nTag heat-pump notes.",
                                               encoding="utf-8")
    assert L.load_instructions() == "Be terse.\nTag heat-pump notes."


# ── Overlay: tags (read-your-writes) ─────────────────────────────────────────────

def _tag_op(note_id: str, tag: str, agent: str = "claude-mac",
            ts: str = "2026-07-06T06:00:00Z") -> dict:
    return {"op": "tag", "agent": agent, "via": "inbox", "ts": ts,
            "requestId": "r1", "payload": {"noteId": note_id, "tag": tag}}


def _untag_op(note_id: str, tag: str, ts: str = "2026-07-06T06:00:00Z") -> dict:
    return {"op": "untag", "agent": "claude-mac", "via": "inbox", "ts": ts,
            "requestId": "r2", "payload": {"noteId": note_id, "tag": tag}}


def test_overlay_tags_adds_pending(ollie_dir, write_jsonl):
    write_jsonl(ollie_dir / "tags.jsonl",
                [{"noteId": N1, "tag": "existing", "agentId": "claude-mac",
                  "createdAt": "2026-07-06T05:00:00Z"}])
    merged = L.overlay_tags(L.load_tags(), [_tag_op(N1, "fresh")])
    tags = {(t["noteId"], t["tag"]) for t in merged}
    assert (N1, "existing") in tags
    assert (N1, "fresh") in tags


def test_overlay_tags_dedups_case_insensitive(ollie_dir, write_jsonl):
    write_jsonl(ollie_dir / "tags.jsonl",
                [{"noteId": N1, "tag": "Heat-Pump", "agentId": "claude-mac",
                  "createdAt": "2026-07-06T05:00:00Z"}])
    # A pending tag that differs only by case is a no-op (set semantics, like apply).
    merged = L.overlay_tags(L.load_tags(), [_tag_op(N1, "heat-pump")])
    assert sum(1 for t in merged if t["noteId"] == N1) == 1


def test_overlay_untag_removes(ollie_dir, write_jsonl):
    write_jsonl(ollie_dir / "tags.jsonl",
                [{"noteId": N1, "tag": "gone", "agentId": "claude-mac",
                  "createdAt": "2026-07-06T05:00:00Z"}])
    merged = L.overlay_tags(L.load_tags(), [_untag_op(N1, "GONE")])  # case-insensitive
    assert all(t["tag"] != "gone" for t in merged)


# ── Overlay: memory ──────────────────────────────────────────────────────────────

def test_overlay_memory_append_and_retire(ollie_dir, write_jsonl):
    mid = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
    write_jsonl(ollie_dir / "memory.jsonl",
                [{"id": mid, "text": "old fact", "agentId": "claude-mac",
                  "createdAt": "2026-07-06T05:00:00Z", "retired": False}])
    ops = [
        {"op": "memory.append", "agent": "claude-mac", "via": "inbox",
         "ts": "2026-07-06T06:00:00Z", "requestId": "r1",
         "payload": {"text": "new fact"}},
        {"op": "memory.retire", "agent": "claude-mac", "via": "inbox",
         "ts": "2026-07-06T06:01:00Z", "requestId": "r2",
         "payload": {"id": mid}},
    ]
    merged = L.overlay_memory(L.load_memory(), ops)
    old = next(m for m in merged if m.get("id") == mid)
    assert old["retired"] is True and old["retiredAt"] == "2026-07-06T06:01:00Z"
    new = next(m for m in merged if m.get("text") == "new fact")
    assert new.get("pending") is True and "id" not in new


# ── Overlay: views ───────────────────────────────────────────────────────────────

def test_overlay_views_pending_is_newest(ollie_dir, write_jsonl):
    write_jsonl(ollie_dir / "views.jsonl",
                [{"id": "v1", "viewName": "This week", "body": "old body",
                  "agentId": "claude-mac", "createdAt": "2026-07-06T05:00:00Z"}])
    op = {"op": "view.publish", "agent": "claude-runner", "via": "inbox",
          "ts": "2026-07-06T07:00:00Z", "requestId": "r1",
          "payload": {"viewName": "This week", "body": "new body"}}
    # Drop the pending publish into the inbox so the full read path (effective_views
    # → overlay) sees it, then confirm get_view reflects it.
    _drop_raw_op(ollie_dir, op)
    view = L.get_view("This week")
    assert view["body"] == "new body"           # pending publish wins as latest
    assert view["revisionCount"] == 2
    assert view["revisions"][0].get("pending") is True


# ── pending_ops matches the ingestor's view (top-level *.json, non-hidden) ────────

def _drop_raw_op(ollie_dir, envelope: dict, name: str | None = None) -> None:
    inbox = ollie_dir / "inbox"
    inbox.mkdir(parents=True, exist_ok=True)
    fname = name or f"{envelope['agent']}-{envelope['requestId']}.json"
    (inbox / fname).write_text(json.dumps(envelope, sort_keys=True), encoding="utf-8")


def test_pending_ops_skips_hidden_and_rejected(ollie_dir):
    inbox = ollie_dir / "inbox"
    (inbox / "rejected").mkdir(parents=True, exist_ok=True)
    good = _tag_op(N1, "keep")
    _drop_raw_op(ollie_dir, good, name="claude-mac-good.json")
    # Hidden temp file — must be ignored (this is how write_op hides in-flight writes).
    (inbox / ".claude-mac-temp.json.tmp").write_text(json.dumps(good), encoding="utf-8")
    # A non-json file — ignored.
    (inbox / "notes.txt").write_text("nope", encoding="utf-8")
    # A file parked in rejected/ — ignored (it's a subdir, not top-level).
    (inbox / "rejected" / "claude-mac-bad.json").write_text(json.dumps(good),
                                                            encoding="utf-8")
    pend = L.pending_ops()
    assert len(pend) == 1
    assert pend[0]["payload"]["tag"] == "keep"
    assert L.pending_count() == 1


def test_pending_ops_skips_undecodable(ollie_dir):
    inbox = ollie_dir / "inbox"
    inbox.mkdir(parents=True, exist_ok=True)
    (inbox / "claude-mac-broken.json").write_text("{ not json", encoding="utf-8")
    assert L.pending_ops() == []


# ── Vocabulary counting ──────────────────────────────────────────────────────────

def test_tag_vocabulary_counts_and_orders(ollie_dir, write_jsonl):
    # Both notes exist in the corpus so every tag resolves (vocabulary counts only tags
    # whose note is present — the same join notes_by_tag uses).
    write_jsonl(ollie_dir / "ollie.jsonl", [_note(N1, "a"), _note(N2, "b")])
    write_jsonl(ollie_dir / "tags.jsonl", [
        {"noteId": N1, "tag": "topic:heat", "agentId": "a",
         "createdAt": "2026-07-06T05:00:00Z"},
        {"noteId": N2, "tag": "topic:heat", "agentId": "a",
         "createdAt": "2026-07-06T06:00:00Z"},
        {"noteId": N1, "tag": "request:open", "agentId": "a",
         "createdAt": "2026-07-06T04:00:00Z"},
    ])
    vocab = L.tag_vocabulary()
    top = vocab[0]
    assert top["tag"] == "topic:heat"
    assert top["count"] == 2
    assert top["lastUsed"] == "2026-07-06T06:00:00Z"   # newest of the two
    names = {v["tag"] for v in vocab}
    assert names == {"topic:heat", "request:open"}


def test_tag_vocabulary_groups_case_insensitively(ollie_dir, write_jsonl):
    write_jsonl(ollie_dir / "ollie.jsonl", [_note(N1, "a"), _note(N2, "b")])
    write_jsonl(ollie_dir / "tags.jsonl", [
        {"noteId": N1, "tag": "Heat-Pump", "agentId": "a",
         "createdAt": "2026-07-06T05:00:00Z"},
        {"noteId": N2, "tag": "heat-pump", "agentId": "a",
         "createdAt": "2026-07-06T06:00:00Z"},
    ])
    vocab = L.tag_vocabulary()
    assert len(vocab) == 1
    assert vocab[0]["count"] == 2
    assert vocab[0]["tag"] == "heat-pump"   # newest spelling wins as display form


def test_tag_vocabulary_includes_pending(ollie_dir, write_jsonl):
    # A pending tag counts (read-your-writes) — but only because its note is resolvable
    # in the corpus (the note-membership join, same as notes_by_tag).
    write_jsonl(ollie_dir / "ollie.jsonl", [_note(N1, "note text")])
    _drop_raw_op(ollie_dir, _tag_op(N1, "brand-new"))
    vocab = L.tag_vocabulary()
    assert any(v["tag"] == "brand-new" and v["count"] == 1 for v in vocab)


def test_tag_vocabulary_excludes_orphan_tags(ollie_dir, write_jsonl):
    """Regression guard for the first-unattended-run bug: `tag_vocabulary` reported counts
    for tags (`topic:printer-enclosure`, `fitness`, …) whose notes were gone, while
    `notes_by_tag` returned EMPTY for each. Vocabulary must count only tags that resolve to
    a note in the corpus — the SAME join notes_by_tag uses — so the two can't disagree."""
    write_jsonl(ollie_dir / "ollie.jsonl", [_note(N1, "live note")])
    write_jsonl(ollie_dir / "tags.jsonl", [
        # A live tag (its note is in the corpus) — counted.
        {"noteId": N1, "tag": "kept", "agentId": "a", "createdAt": "2026-07-06T05:00:00Z"},
        # Orphan rows: notes deleted/restricted, absent from ollie.jsonl — NOT counted.
        {"noteId": N2, "tag": "topic:printer-enclosure", "agentId": "a",
         "createdAt": "2026-07-06T05:00:00Z"},
        {"noteId": N2, "tag": "fitness", "agentId": "a", "createdAt": "2026-07-06T05:00:00Z"},
    ])
    vocab = L.tag_vocabulary()
    assert {v["tag"] for v in vocab} == {"kept"}, "orphan tags must not appear in the vocabulary"
    # The two tools now agree: every vocab tag resolves via notes_by_tag, and every orphan
    # tag notes_by_tag drops is likewise absent from the vocabulary.
    for v in vocab:
        assert L.notes_by_tag(v["tag"]), f"{v['tag']!r} in vocab but notes_by_tag empty"
    assert L.notes_by_tag("topic:printer-enclosure") == []
    assert L.notes_by_tag("fitness") == []


def test_tag_vocabulary_count_is_distinct_notes_not_rows(ollie_dir, write_jsonl):
    """`count` is distinct resolvable notes (matching notes_by_tag's per-note dedup): two
    live notes carrying `topic:heat` count 2; a duplicate (noteId,tag) row doesn't inflate."""
    write_jsonl(ollie_dir / "ollie.jsonl", [_note(N1, "a"), _note(N2, "b")])
    write_jsonl(ollie_dir / "tags.jsonl", [
        {"noteId": N1, "tag": "topic:heat", "agentId": "a", "createdAt": "2026-07-06T05:00:00Z"},
        {"noteId": N2, "tag": "topic:heat", "agentId": "a", "createdAt": "2026-07-06T06:00:00Z"},
        # A duplicate row for (N1, topic:heat) must not double-count N1.
        {"noteId": N1, "tag": "topic:heat", "agentId": "a", "createdAt": "2026-07-06T07:00:00Z"},
    ])
    vocab = L.tag_vocabulary()
    assert len(vocab) == 1
    assert vocab[0]["tag"] == "topic:heat"
    assert vocab[0]["count"] == 2, "count is distinct notes, not raw tag rows"
    assert vocab[0]["lastUsed"] == "2026-07-06T07:00:00Z", "latest createdAt across rows"


# ── notes_by_tag joins to the corpus ─────────────────────────────────────────────

def test_notes_by_tag(ollie_dir, write_jsonl):
    write_jsonl(ollie_dir / "ollie.jsonl", [
        _note(N1, "heat pump note", created="2026-07-06T05:00:00Z"),
        _note(N2, "other note", created="2026-07-06T06:00:00Z"),
    ])
    write_jsonl(ollie_dir / "tags.jsonl", [
        {"noteId": N1, "tag": "hp", "agentId": "a",
         "createdAt": "2026-07-06T05:00:00Z"},
    ])
    rows = L.notes_by_tag("HP")   # case-insensitive
    assert len(rows) == 1
    assert rows[0]["id"] == N1
    assert rows[0]["text"] == "heat pump note"


def test_notes_by_tag_skips_missing_note(ollie_dir, write_jsonl):
    # Tag points at a note absent from the corpus (deleted/restricted) → skipped.
    write_jsonl(ollie_dir / "tags.jsonl", [
        {"noteId": N2, "tag": "ghost", "agentId": "a",
         "createdAt": "2026-07-06T05:00:00Z"},
    ])
    assert L.notes_by_tag("ghost") == []


# ── read_memory projection + retired filtering ───────────────────────────────────

def test_read_memory_hides_retired_by_default(ollie_dir, write_jsonl):
    write_jsonl(ollie_dir / "memory.jsonl", [
        {"id": "m1", "text": "live", "agentId": "a",
         "createdAt": "2026-07-06T06:00:00Z", "retired": False},
        {"id": "m2", "text": "dead", "agentId": "a",
         "createdAt": "2026-07-06T05:00:00Z", "retired": True,
         "retiredAt": "2026-07-06T05:30:00Z"},
    ])
    live = L.read_memory()
    assert [m["text"] for m in live] == ["live"]
    both = L.read_memory(include_retired=True)
    texts = [m["text"] for m in both]
    assert texts == ["live", "dead"]           # newest first
    dead = next(m for m in both if m["text"] == "dead")
    assert dead["retired"] is True and dead["retiredAt"] == "2026-07-06T05:30:00Z"


# ── list_views / get_view ────────────────────────────────────────────────────────

def test_list_and_get_view(ollie_dir, write_jsonl):
    write_jsonl(ollie_dir / "views.jsonl", [
        {"id": "v1", "viewName": "Open loops", "body": "rev1",
         "agentId": "claude-mac", "createdAt": "2026-07-06T05:00:00Z"},
        {"id": "v2", "viewName": "Open loops", "body": "rev2",
         "agentId": "claude-runner", "createdAt": "2026-07-06T06:00:00Z"},
        {"id": "v3", "viewName": "This week", "body": "w",
         "agentId": "claude-mac", "createdAt": "2026-07-06T04:00:00Z"},
    ])
    views = L.list_views()
    assert [v["name"] for v in views] == ["Open loops", "This week"]  # newest first
    ol = next(v for v in views if v["name"] == "Open loops")
    assert ol["revisionCount"] == 2
    assert ol["latestAgent"] == "claude-runner"

    detail = L.get_view("Open loops")
    assert detail["body"] == "rev2"            # latest revision's body
    assert detail["revisionCount"] == 2
    assert len(detail["revisions"]) == 2
    assert detail["revisions"][0]["createdAt"] == "2026-07-06T06:00:00Z"


def test_get_view_missing(ollie_dir):
    out = L.get_view("Nope")
    assert "error" in out


def test_get_view_revision_limit(ollie_dir, write_jsonl):
    rows = [{"id": f"v{i}", "viewName": "V", "body": f"b{i}", "agentId": "a",
             "createdAt": f"2026-07-06T0{i}:00:00Z"} for i in range(1, 6)]
    write_jsonl(ollie_dir / "views.jsonl", rows)
    detail = L.get_view("V", revision_limit=2)
    assert detail["revisionCount"] == 5        # count is all revisions
    assert len(detail["revisions"]) == 2       # but metadata capped


# ── get_view.interactions — precedence filtering (Views v2 spec §1, §6) ───────────

def _interaction(view: str, block: str, value: str, updated: str,
                 text: str = "the item", kind: str = "checkbox") -> dict:
    return {"viewName": view, "blockId": block, "blockText": text, "kind": kind,
            "value": value, "revisionId": "r", "surface": "ios",
            "updatedAt": updated}


def test_load_interactions_reads_file(ollie_dir, write_jsonl):
    write_jsonl(ollie_dir / "interactions.jsonl",
                [_interaction("V", "cl1:a:0", "true", "2026-07-06T06:00:00Z")])
    rows = L.load_interactions()
    assert len(rows) == 1 and rows[0]["blockId"] == "cl1:a:0"


def test_load_interactions_missing_file_empty(ollie_dir):
    assert L.load_interactions() == []


def test_get_view_includes_applying_interactions(ollie_dir, write_jsonl):
    # Revision at 05:00; a toggle at 06:00 is NEWER → it applies.
    write_jsonl(ollie_dir / "views.jsonl",
                [{"id": "v1", "viewName": "Open loops", "body": "- [ ] the item",
                  "agentId": "claude-runner", "createdAt": "2026-07-06T05:00:00Z"}])
    write_jsonl(ollie_dir / "interactions.jsonl",
                [_interaction("Open loops", "cl1:a:0", "true", "2026-07-06T06:00:00Z",
                              text="Call the plumber — ollie://note/x")])
    detail = L.get_view("Open loops")
    assert "interactions" in detail
    assert len(detail["interactions"]) == 1
    row = detail["interactions"][0]
    # Denormalized agent shape: exactly {blockId, blockText, value, updatedAt}.
    assert set(row) == {"blockId", "blockText", "value", "updatedAt"}
    assert row["blockId"] == "cl1:a:0"
    assert row["value"] == "true"
    assert row["blockText"] == "Call the plumber — ollie://note/x"
    assert row["updatedAt"] == "2026-07-06T06:00:00Z"


def test_get_view_excludes_superseded_interactions(ollie_dir, write_jsonl):
    # Revision at 07:00 is NEWER than the toggle at 06:00 → the toggle is superseded
    # (publishing acknowledges/resets interaction, spec §1) → NOT returned.
    write_jsonl(ollie_dir / "views.jsonl",
                [{"id": "v1", "viewName": "Open loops", "body": "- [ ] the item",
                  "agentId": "claude-runner", "createdAt": "2026-07-06T07:00:00Z"}])
    write_jsonl(ollie_dir / "interactions.jsonl",
                [_interaction("Open loops", "cl1:a:0", "true", "2026-07-06T06:00:00Z")])
    detail = L.get_view("Open loops")
    assert detail["interactions"] == [], "a toggle older than the latest revision is superseded"


def test_get_view_interactions_equal_timestamp_is_superseded(ollie_dir, write_jsonl):
    # Boundary: updatedAt == revision.createdAt does NOT apply (strictly-newer rule).
    write_jsonl(ollie_dir / "views.jsonl",
                [{"id": "v1", "viewName": "V", "body": "- [ ] x", "agentId": "a",
                  "createdAt": "2026-07-06T06:00:00Z"}])
    write_jsonl(ollie_dir / "interactions.jsonl",
                [_interaction("V", "cl1:a:0", "true", "2026-07-06T06:00:00Z")])
    assert L.get_view("V")["interactions"] == []


def test_get_view_interactions_filtered_by_view_name(ollie_dir, write_jsonl):
    # Only THIS view's rows are returned — another view's applying toggle is excluded.
    write_jsonl(ollie_dir / "views.jsonl", [
        {"id": "v1", "viewName": "A", "body": "- [ ] a", "agentId": "x",
         "createdAt": "2026-07-06T05:00:00Z"},
        {"id": "v2", "viewName": "B", "body": "- [ ] b", "agentId": "x",
         "createdAt": "2026-07-06T05:00:00Z"},
    ])
    write_jsonl(ollie_dir / "interactions.jsonl", [
        _interaction("A", "cl1:a:0", "true", "2026-07-06T06:00:00Z"),
        _interaction("B", "cl1:b:0", "true", "2026-07-06T06:00:00Z"),
    ])
    detail = L.get_view("A")
    assert len(detail["interactions"]) == 1
    assert detail["interactions"][0]["blockId"] == "cl1:a:0"


def test_get_view_interactions_sorted_newest_first(ollie_dir, write_jsonl):
    write_jsonl(ollie_dir / "views.jsonl",
                [{"id": "v1", "viewName": "V", "body": "b", "agentId": "x",
                  "createdAt": "2026-07-06T05:00:00Z"}])
    write_jsonl(ollie_dir / "interactions.jsonl", [
        _interaction("V", "cl1:a:0", "true", "2026-07-06T06:00:00Z"),
        _interaction("V", "cl1:b:0", "false", "2026-07-06T08:00:00Z"),
        _interaction("V", "cl1:c:0", "true", "2026-07-06T07:00:00Z"),
    ])
    order = [r["updatedAt"] for r in L.get_view("V")["interactions"]]
    assert order == ["2026-07-06T08:00:00Z", "2026-07-06T07:00:00Z", "2026-07-06T06:00:00Z"]


def test_get_view_no_interactions_when_none(ollie_dir, write_jsonl):
    write_jsonl(ollie_dir / "views.jsonl",
                [{"id": "v1", "viewName": "V", "body": "b", "agentId": "x",
                  "createdAt": "2026-07-06T05:00:00Z"}])
    assert L.get_view("V")["interactions"] == []


def test_applying_interactions_helper_direct(ollie_dir):
    rows = [
        _interaction("V", "cl1:a:0", "true", "2026-07-06T06:00:00Z"),   # applies
        _interaction("V", "cl1:b:0", "true", "2026-07-06T04:00:00Z"),   # superseded
        _interaction("Other", "cl1:c:0", "true", "2026-07-06T09:00:00Z"),  # wrong view
    ]
    applying = L.applying_interactions("V", "2026-07-06T05:00:00Z", rows)
    assert [r["blockId"] for r in applying] == ["cl1:a:0"]


def test_get_view_interactions_survives_pending_view_publish(ollie_dir, write_jsonl):
    # A pending (un-ingested) view.publish becomes the newest revision via the overlay,
    # so its ts is the `latestAt` interactions are filtered against. A toggle older than
    # that pending publish is correctly superseded.
    write_jsonl(ollie_dir / "views.jsonl",
                [{"id": "v1", "viewName": "V", "body": "old", "agentId": "x",
                  "createdAt": "2026-07-06T05:00:00Z"}])
    write_jsonl(ollie_dir / "interactions.jsonl",
                [_interaction("V", "cl1:a:0", "true", "2026-07-06T06:00:00Z")])
    # Pending republish at 07:00 → newer than the 06:00 toggle → toggle superseded.
    _drop_raw_op(ollie_dir, {
        "op": "view.publish", "agent": "claude-runner", "via": "inbox",
        "ts": "2026-07-06T07:00:00Z", "requestId": "rp",
        "payload": {"viewName": "V", "body": "- [ ] fresh"}})
    detail = L.get_view("V")
    assert detail["latestAt"] == "2026-07-06T07:00:00Z"
    assert detail["interactions"] == [], "the pending republish supersedes the older toggle"


# ── Client-side cap validation (reject before writing) ───────────────────────────

def test_validate_tag_caps():
    with pytest.raises(L.OpValidationError):
        L.validate_op("tag", {"noteId": N1, "tag": ""})           # empty
    with pytest.raises(L.OpValidationError):
        L.validate_op("tag", {"noteId": N1, "tag": "x" * 65})     # too long
    with pytest.raises(L.OpValidationError):
        L.validate_op("tag", {"noteId": N1, "tag": "bad\ttab"})   # control char
    with pytest.raises(L.OpValidationError):
        L.validate_op("tag", {"noteId": "", "tag": "ok"})         # missing noteId
    # A 64-char printable tag is fine.
    L.validate_op("tag", {"noteId": N1, "tag": "x" * 64})


def test_validate_untag_allows_long_for_match():
    # untag only needs presence to match+delete; length isn't capped.
    L.validate_op("untag", {"noteId": N1, "tag": "x" * 200})
    with pytest.raises(L.OpValidationError):
        L.validate_op("untag", {"noteId": N1, "tag": ""})


def test_validate_memory_caps():
    with pytest.raises(L.OpValidationError):
        L.validate_op("memory.append", {"text": ""})
    with pytest.raises(L.OpValidationError):
        L.validate_op("memory.append", {"text": "x" * 2001})
    L.validate_op("memory.append", {"text": "x" * 2000})
    with pytest.raises(L.OpValidationError):
        L.validate_op("memory.retire", {"id": ""})


def test_validate_view_caps():
    with pytest.raises(L.OpValidationError):
        L.validate_op("view.publish", {"viewName": "", "body": "b"})
    with pytest.raises(L.OpValidationError):
        L.validate_op("view.publish", {"viewName": "x" * 81, "body": "b"})
    with pytest.raises(L.OpValidationError):
        L.validate_op("view.publish", {"viewName": "n", "body": ""})
    with pytest.raises(L.OpValidationError):
        L.validate_op("view.publish", {"viewName": "n", "body": "x" * 131073})
    L.validate_op("view.publish", {"viewName": "n", "body": "x" * 131072})


def test_validate_unknown_op():
    with pytest.raises(L.OpValidationError):
        L.validate_op("frobnicate", {})


# ── write_op: op-file shape + delivery ───────────────────────────────────────────

def test_write_op_envelope_shape(ollie_dir):
    rid = L.write_op("tag", {"noteId": N1, "tag": "shipped"})
    assert UUID_RE.match(rid)
    files = list((ollie_dir / "inbox").glob("*.json"))
    assert len(files) == 1
    f = files[0]
    # Filename is <agent>-<requestId>.json
    assert f.name == f"claude-mac-{rid}.json"
    env = json.loads(f.read_text(encoding="utf-8"))
    assert env["op"] == "tag"
    assert env["agent"] == "claude-mac"
    assert env["via"] == "inbox"
    assert env["requestId"] == rid
    assert env["payload"] == {"noteId": N1, "tag": "shipped"}
    # ts is no-fractional-seconds ISO-8601 ending in Z (what the Swift ingestor decodes)
    assert re.match(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$", env["ts"])


def test_write_op_no_temp_left_behind(ollie_dir):
    L.write_op("memory.append", {"text": "a durable fact"})
    inbox = ollie_dir / "inbox"
    # No leftover hidden temp file; exactly one final op file.
    hidden = [p for p in inbox.iterdir() if p.name.startswith(".")]
    assert hidden == []
    assert len(list(inbox.glob("*.json"))) == 1


def test_write_op_agent_from_env(ollie_dir, monkeypatch):
    monkeypatch.setenv("OLLIE_AGENT_ID", "claude-runner")
    rid = L.write_op("tag", {"noteId": N1, "tag": "t"})
    f = next((ollie_dir / "inbox").glob("*.json"))
    assert f.name.startswith("claude-runner-")
    env = json.loads(f.read_text(encoding="utf-8"))
    assert env["agent"] == "claude-runner"


def test_write_op_explicit_agent_overrides_env(ollie_dir, monkeypatch):
    monkeypatch.setenv("OLLIE_AGENT_ID", "claude-runner")
    L.write_op("tag", {"noteId": N1, "tag": "t"}, agent="claude-mac")
    f = next((ollie_dir / "inbox").glob("*.json"))
    assert f.name.startswith("claude-mac-")


def test_write_op_rejects_before_writing(ollie_dir):
    with pytest.raises(L.OpValidationError):
        L.write_op("tag", {"noteId": N1, "tag": "x" * 100})
    # Nothing was written — the inbox dir wasn't even created for a rejected op.
    inbox = ollie_dir / "inbox"
    assert not inbox.exists() or list(inbox.glob("*.json")) == []


# ── End-to-end: write then read-your-writes through the overlay ───────────────────

def test_write_then_read_your_writes_tag(ollie_dir, write_jsonl):
    write_jsonl(ollie_dir / "ollie.jsonl", [_note(N1, "note text")])
    # Before writing: vocabulary empty.
    assert L.tag_vocabulary() == []
    L.write_op("tag", {"noteId": N1, "tag": "instant"})
    # Immediately visible via the overlay, before any Mac-app ingest.
    vocab = L.tag_vocabulary()
    assert any(v["tag"] == "instant" for v in vocab)
    rows = L.notes_by_tag("instant")
    assert len(rows) == 1 and rows[0]["id"] == N1


def test_write_then_read_your_writes_view(ollie_dir):
    L.write_op("view.publish", {"viewName": "Heat pump question",
                                "body": "See ollie://note/%s" % N1})
    listed = L.list_views()
    assert any(v["name"] == "Heat pump question" for v in listed)
    detail = L.get_view("Heat pump question")
    assert "ollie://note/" in detail["body"]
    assert detail["revisions"][0].get("pending") is True


def test_write_then_read_your_writes_memory(ollie_dir):
    L.write_op("memory.append", {"text": "HP = heat pump"})
    mem = L.read_memory()
    assert any(m["text"] == "HP = heat pump" and m.get("pending") for m in mem)


# ── Overlay directly (unit, no filesystem) — tags/untag interplay ─────────────────

def test_overlay_tags_add_then_untag_same_batch(ollie_dir):
    ops = [_tag_op(N1, "temp"), _untag_op(N1, "temp")]
    merged = L.overlay_tags([], ops)
    assert all(t.get("tag") != "temp" for t in merged)
