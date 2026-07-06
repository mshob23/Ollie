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
///   • tags whose subject note is restricted — omitted from `tags.jsonl`.
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

    /// The tags that are safe to export: every tag **except** those whose subject
    /// note is restricted (contract §5 — "tags whose `noteId` is restricted are
    /// omitted"). Restriction is derived from `notes`, the authoritative note set, so
    /// a tag inherits its note's restriction (contagion) without the tag record
    /// needing its own flag.
    ///
    /// - Parameters:
    ///   - tags: every tag in the store (the `allTags()` snapshot).
    ///   - notes: the authoritative note set — **the full set, before restriction
    ///     filtering** — used only to determine which note ids are restricted.
    /// - Returns: the tags whose subject note is not restricted.
    ///
    /// A tag whose `noteId` matches *no* note (an orphan left after a note delete) is
    /// **kept** here: the rule gates on restriction, not existence, and such orphans
    /// are a separate concern the store's own deletes handle. The gate stays a narrow,
    /// literal encoding of the contagion rule.
    public static func exportableTags(_ tags: [AgentTag], notes: [Note]) -> [AgentTag] {
        let restricted = restrictedNoteIDs(notes)
        guard !restricted.isEmpty else { return tags }
        return tags.filter { !restricted.contains($0.noteId) }
    }

    /// The ids of the restricted notes in `notes` — the contagion source set. Exposed
    /// so future doors can reuse the same derivation rather than re-deriving it.
    public static func restrictedNoteIDs(_ notes: [Note]) -> Set<UUID> {
        Set(notes.lazy.filter(\.isRestricted).map(\.id))
    }
}
