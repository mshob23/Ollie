import Foundation
import XCTest
@testable import HandheldNotesCore

/// Directly exercises `CorpusGate` — the pure, side-effect-free export boundary: the
/// "restriction is contagious" invariant (contract §0, §5) plus the subset-join rule
/// that a tag only exports when its note does (dropping deleted-note orphans too). The
/// end-to-end gate behavior is covered through the exporter in `CorpusExporterGuardTests`;
/// these tests pin the pure functions in isolation (no container, no I/O), including the
/// boundary cases the exporter path can't easily isolate.
final class CorpusGateTests: XCTestCase {

    private func note(_ id: UUID = UUID(), restricted: Bool = false) -> Note {
        Note(id: id, transcript: "n", source: .phone, isRestricted: restricted)
    }
    private func tag(on noteId: UUID, _ t: String = "t") -> AgentTag {
        AgentTag(noteId: noteId, tag: t, agentId: "claude-mac")
    }

    // MARK: exportableNotes

    func testExportableNotesDropsRestrictedKeepsRest() {
        let a = note(restricted: false)
        let b = note(restricted: true)
        let c = note(restricted: false)
        let out = CorpusGate.exportableNotes([a, b, c])
        XCTAssertEqual(out.map(\.id), [a.id, c.id], "only restricted notes are removed, order preserved")
    }

    func testExportableNotesEmptyAndAllRestricted() {
        XCTAssertTrue(CorpusGate.exportableNotes([]).isEmpty)
        let all = [note(restricted: true), note(restricted: true)]
        XCTAssertTrue(CorpusGate.exportableNotes(all).isEmpty,
                      "every note restricted → nothing exportable")
    }

    // MARK: exportableTags (contagion)

    func testExportableTagsOmitsTagsOfRestrictedNotes() {
        let open = note(restricted: false)
        let secret = note(restricted: true)
        let tags = [tag(on: open.id, "keep"), tag(on: secret.id, "drop"), tag(on: open.id, "keep2")]
        let out = CorpusGate.exportableTags(tags, notes: [open, secret])
        XCTAssertEqual(out.map(\.tag), ["keep", "keep2"],
                       "tags of the restricted note are dropped; the rest survive in order")
    }

    func testExportableTagsWithNoRestrictionReturnsAll() {
        let a = note(); let b = note()
        let tags = [tag(on: a.id), tag(on: b.id)]
        let out = CorpusGate.exportableTags(tags, notes: [a, b])
        XCTAssertEqual(out.count, 2, "no restricted notes → every tag is exportable")
    }

    /// The boundary, corrected (first-unattended-run orphan-tag fix): a tag whose
    /// `noteId` matches NO note in the set — an **orphan** left after a delete, since
    /// tags aren't cascade-deleted — is now **dropped**. `tags.jsonl` must be a strict
    /// subset-join of the exported notes, or `tag_vocabulary` (which counts tag rows) and
    /// `notes_by_tag` (which joins tags→notes) disagree, and the deleted note's tag text
    /// leaks out. The gate keeps a tag iff its note is in ``exportableNotes(_:)``.
    func testExportableTagsDropsOrphanTagWhoseNoteIsAbsent() {
        let present = note(restricted: false)
        let orphanNoteId = UUID()   // no matching note in `notes` → deleted
        let tags = [tag(on: present.id, "live"), tag(on: orphanNoteId, "orphan")]
        let out = CorpusGate.exportableTags(tags, notes: [present])
        XCTAssertEqual(out.map(\.tag), ["live"],
                       "an orphan tag whose note is absent (deleted) is dropped by the gate")
    }

    /// But an orphan whose (absent) note id happens to also be a *restricted* note's id
    /// is still dropped — restriction wins wherever the id appears in the note set.
    func testExportableTagsDropsTagMatchingARestrictedIdEvenIfDuplicated() {
        let secret = note(restricted: true)
        // Two tags on the same restricted note id.
        let tags = [tag(on: secret.id, "a"), tag(on: secret.id, "b")]
        XCTAssertTrue(CorpusGate.exportableTags(tags, notes: [secret]).isEmpty,
                      "all tags on a restricted note are dropped")
    }

    // MARK: restrictedNoteIDs

    func testRestrictedNoteIDsCollectsOnlyRestricted() {
        let a = note(restricted: true)
        let b = note(restricted: false)
        let c = note(restricted: true)
        XCTAssertEqual(CorpusGate.restrictedNoteIDs([a, b, c]), [a.id, c.id])
        XCTAssertTrue(CorpusGate.restrictedNoteIDs([b]).isEmpty)
    }
}
