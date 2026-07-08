import Foundation

/// The **export gate** — the one place the "restriction is contagious" invariant is
/// encoded (contract §0, §5). A note marked `isRestricted` and *everything derived
/// from it* must never leave the device boundary; these pure functions are what the
/// exporter (and any future door that writes under `~/Ollie/`) route their corpus
/// through so the rule lives in exactly one testable place.
///
/// **Pure and side-effect-free** — no I/O, no store access. Inputs are already-fetched
/// value snapshots (`[Note]`, `[AgentTag]`); outputs are the filtered subsets that are
/// safe to export. Keeping it pure means the contagion rule can be unit-tested without
/// a container and reused verbatim by later doors.
///
/// **What the gate drops (contract §5):**
///   • notes with `isRestricted` — omitted from `ollie.jsonl` and `notes/`;
///   • tags whose subject note is restricted **or deleted** — omitted from
///     `tags.jsonl` (only tags of an actually-exported note survive, so the tag file
///     is always a subset-join of the note corpus — no orphan rows).
///
/// **What the gate deliberately does NOT touch:** views and memory. They are
/// agent-authored from an *already-filtered* corpus, so a revision or a memory entry
/// can't carry a restricted transcript out; the privileged on-device tier that could
/// read restricted notes is out of scope (contract §7–§8). Those artifacts export in
/// full — the exporter does not call the gate for them.
public enum CorpusGate {

    /// The notes that are safe to export: everything that is **not** restricted.
    /// A restricted note is dropped entirely (its `.md` is additionally pruned by the
    /// exporter's orphan pass once it disappears from this set).
    public static func exportableNotes(_ notes: [Note]) -> [Note] {
        notes.filter { !$0.isRestricted }
    }

    /// The tags that are safe to export: only those whose subject note is **actually
    /// exported**. A tag is dropped when its `noteId` names a note that
    ///   • is `isRestricted` (contract §5 — "tags whose `noteId` is restricted are
    ///     omitted"; restriction is contagious, so the derived tag stays home), **or**
    ///   • is absent from `notes` entirely — an **orphan** left behind when the note was
    ///     deleted (the store links tags to notes by a bare `noteId`, with no cascade, so
    ///     `AppModel.delete` removes the `NoteEntity` but leaves its `TagEntity` rows).
    ///
    /// Both are the same boundary rule: **a tag record never leaves the device unless the
    /// note it points at is in the exported note set.** This makes `tags.jsonl` a strict
    /// subset-join of `ollie.jsonl`, so the two MCP tools that read them (`tag_vocabulary`
    /// counts tags; `notes_by_tag` joins tags→notes) can never disagree, and a deleted
    /// note's tag text (a privacy surface, identical to the restriction leak the gate
    /// exists to prevent) can't straggle out.
    ///
    /// - Parameters:
    ///   - tags: every tag in the store (the `allTags()` snapshot).
    ///   - notes: the authoritative note set — **the full set, before restriction
    ///     filtering** — from which the exportable (non-restricted, existing) note ids
    ///     are derived.
    /// - Returns: the tags whose subject note is in ``exportableNotes(_:)``.
    ///
    /// The store's own orphan prune (``AgentLayerStore/pruneOrphanedTags(existingNoteIDs:)``)
    /// hard-deletes deleted-note tags so they don't accumulate; this gate is the
    /// belt-and-suspenders boundary that also holds when a stale export races a delete.
    public static func exportableTags(_ tags: [AgentTag], notes: [Note]) -> [AgentTag] {
        let exportableIDs = Set(exportableNotes(notes).map(\.id))
        return tags.filter { exportableIDs.contains($0.noteId) }
    }

    /// The ids of the restricted notes in `notes` — the contagion source set. Exposed
    /// so future doors can reuse the same derivation rather than re-deriving it.
    public static func restrictedNoteIDs(_ notes: [Note]) -> Set<UUID> {
        Set(notes.lazy.filter(\.isRestricted).map(\.id))
    }
}
