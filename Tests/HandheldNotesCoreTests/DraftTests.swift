import Foundation
import XCTest
@testable import HandheldNotesCore

/// The capture-bar draft flow: a `Draft` accumulates content from bar-open until the
/// user explicitly concludes it, then `makeNote()` materializes a saved `Note`.
///
/// The load-bearing invariant here is the **timestamp**: a concluded note's
/// `createdAt` must be *send time*, not *draft-session start*. A draft can sit open
/// for minutes (the bar auto-expands the moment there's content or a recording), so
/// stamping the note at draft-start made its `createdAt` predate the actual send.
/// That broke the agent layer: `list_notes(since: lastRunAt)` would silently miss a
/// just-sent note whose stamp fell before the run window. Observed live twice
/// (a note sent 02:39 stamped 02:30:55). These pin the fix.
final class DraftTests: XCTestCase {

    /// The regression test: build a draft, let wall-clock time pass between opening it
    /// and concluding it, and prove the note is stamped at conclude (send) time — not
    /// at the draft's construction time.
    func testMakeNoteStampsCreatedAtAtSendTimeNotDraftStart() {
        // Draft opened ~8 minutes before the user actually sends (the live-observed gap).
        let draftStart = Date(timeIntervalSince1970: 1_700_000_000)          // "bar open"
        let sendTime   = draftStart.addingTimeInterval(8 * 60 + 5)           // 8m05s later

        var draft = Draft(createdAt: draftStart)
        draft.transcript = "call the dentist back about the appointment"

        let note = draft.makeNote(now: sendTime)

        XCTAssertEqual(note.createdAt, sendTime,
                       "createdAt must be the send/conclude time, not the draft-session start")
        XCTAssertNotEqual(note.createdAt, draftStart,
                          "createdAt must NOT carry the stale draft-start stamp")
        // updatedAt is likewise the send moment — the note is born at send.
        XCTAssertEqual(note.updatedAt, sendTime)
    }

    /// `createdAt == updatedAt` at birth: a freshly concluded note has never been
    /// edited, so both stamps are the single send moment (real callers pass no `now:`
    /// and both come from the same `Date()`).
    func testConcludedNoteIsBornAtSendMoment() {
        var draft = Draft(createdAt: Date(timeIntervalSince1970: 1_600_000_000))
        draft.transcript = "  grocery list: eggs, oats, coffee  "

        let note = draft.makeNote()

        XCTAssertEqual(note.createdAt, note.updatedAt,
                       "a just-concluded note's createdAt and updatedAt are the same send moment")
        // Body is trimmed on conclude (unchanged behavior, guarded so the fix didn't regress it).
        XCTAssertEqual(note.transcript, "grocery list: eggs, oats, coffee")
        XCTAssertEqual(note.source, .computer)
    }

    /// Source/kind semantics the capture bar depends on are preserved by the fix:
    /// a text-only draft concludes as `.text`, an audio-bearing draft as `.voice`.
    func testMakeNotePreservesKindAndCarriesAudio() {
        var textDraft = Draft()
        textDraft.transcript = "a typed thought"
        XCTAssertEqual(textDraft.makeNote().kind, .text)
        XCTAssertNil(textDraft.makeNote().audioFileName)

        var voiceDraft = Draft()
        voiceDraft.transcript = "a spoken thought"
        voiceDraft.audioFileName = "clip-123.m4a"
        voiceDraft.durationSeconds = 4.2
        let voiceNote = voiceDraft.makeNote()
        XCTAssertEqual(voiceNote.kind, .voice)
        XCTAssertEqual(voiceNote.audioFileName, "clip-123.m4a")
        XCTAssertEqual(voiceNote.durationSeconds, 4.2)
    }
}
