import Foundation
import SwiftData
import XCTest
@testable import HandheldNotesCore

/// Exercises `AgentLayerStore` — the single write choke point for the agent layer —
/// over an in-memory container: tag set semantics (idempotent apply + untag, case
/// -insensitive dedup), memory append/retire, view publish (latest-wins ordering,
/// multi-agent interleave on one name), the mechanical caps (rejected with the right
/// `AgentLayerError`, never a meaning check), instructions singleton upsert, and the
/// user-delete paths. Plus the `Note` legacy-decode guard for the new `isRestricted`
/// field (contract §2).
@MainActor
final class AgentLayerStoreTests: XCTestCase {

    // MARK: - Fixture

    /// A fresh in-memory store + an `AgentLayerStore` over it, with one seeded note
    /// (agent ops that touch a note require it to exist).
    private func makeStore() -> (AgentLayerStore, ModelContext, UUID) {
        let container = NotesDataStore.makeContainerForTesting()
        let context = ModelContext(container)
        let noteId = UUID()
        context.insert(NoteEntity(note: Note(id: noteId, transcript: "Subject note.", source: .phone)))
        try? context.save()
        return (AgentLayerStore(context: context), context, noteId)
    }

    // MARK: - Tags: idempotency + untag

    func testTagApplyIsIdempotent() throws {
        let (store, _, noteId) = makeStore()

        try store.apply(.tag(noteId: noteId, tag: "project:ollie", agent: "claude-mac"))
        try store.apply(.tag(noteId: noteId, tag: "project:ollie", agent: "claude-mac"))
        // A different agent re-applying the same pair is still a no-op (set per note).
        try store.apply(.tag(noteId: noteId, tag: "project:ollie", agent: "claude-runner"))

        let tags = store.tags(forNote: noteId)
        XCTAssertEqual(tags.count, 1, "same (noteId, tag) must not duplicate")
        XCTAssertEqual(tags.first?.tag, "project:ollie")
    }

    func testTagDedupIsCaseInsensitive() throws {
        let (store, _, noteId) = makeStore()

        try store.apply(.tag(noteId: noteId, tag: "Heat-Pump", agent: "claude-mac"))
        try store.apply(.tag(noteId: noteId, tag: "heat-pump", agent: "claude-mac"))

        XCTAssertEqual(store.tags(forNote: noteId).count, 1,
                       "case-insensitive duplicate must be a no-op")
        // The FIRST spelling is retained (the second apply is dropped).
        XCTAssertEqual(store.tags(forNote: noteId).first?.tag, "Heat-Pump")
    }

    func testUntagRemovesMatchingRecordCaseInsensitively() throws {
        let (store, _, noteId) = makeStore()
        try store.apply(.tag(noteId: noteId, tag: "todo", agent: "claude-mac"))
        try store.apply(.tag(noteId: noteId, tag: "idea", agent: "claude-mac"))

        // Untag with a different case still deletes the record.
        try store.apply(.untag(noteId: noteId, tag: "TODO", agent: "claude-mac"))

        let tags = store.tags(forNote: noteId).map(\.tag)
        XCTAssertEqual(tags, ["idea"])
    }

    func testUntagAbsentTagIsNoOp() throws {
        let (store, _, noteId) = makeStore()
        try store.apply(.tag(noteId: noteId, tag: "keep", agent: "claude-mac"))
        // Untagging something that was never applied does not throw and changes nothing.
        try store.apply(.untag(noteId: noteId, tag: "never-applied", agent: "claude-mac"))
        XCTAssertEqual(store.tags(forNote: noteId).map(\.tag), ["keep"])
    }

    func testTagOnMissingNoteThrows() throws {
        let (store, _, _) = makeStore()
        let ghost = UUID()
        XCTAssertThrowsError(try store.apply(.tag(noteId: ghost, tag: "x", agent: "claude-mac"))) {
            XCTAssertEqual($0 as? AgentLayerError, AgentLayerError.noteNotFound(ghost))
        }
    }

    func testAllTagsSpansEveryNote() throws {
        let (store, context, noteId) = makeStore()
        let other = UUID()
        context.insert(NoteEntity(note: Note(id: other, transcript: "Another.", source: .phone)))
        try? context.save()

        try store.apply(.tag(noteId: noteId, tag: "a", agent: "claude-mac"))
        try store.apply(.tag(noteId: other, tag: "b", agent: "claude-mac"))

        XCTAssertEqual(Set(store.allTags().map(\.tag)), ["a", "b"])
    }

    // MARK: - Memory: append + retire

    func testMemoryAppendThenRetireFlipsTombstone() throws {
        let (store, _, _) = makeStore()

        try store.apply(.memoryAppend(text: "‘HP’ means heat pump.", agent: "claude-mac"))
        let live = store.memory(includeRetired: false)
        XCTAssertEqual(live.count, 1)
        let entryId = try XCTUnwrap(live.first?.id)
        XCTAssertFalse(live.first!.retired)
        XCTAssertNil(live.first!.retiredAt)

        try store.apply(.memoryRetire(id: entryId, agent: "claude-mac"))

        XCTAssertEqual(store.memory(includeRetired: false).count, 0,
                       "retired entry is excluded when includeRetired: false")
        let all = store.memory(includeRetired: true)
        XCTAssertEqual(all.count, 1)
        XCTAssertTrue(all.first!.retired)
        XCTAssertNotNil(all.first!.retiredAt, "retire stamps retiredAt")
    }

    func testRetireIsIdempotentAndKeepsOriginalStamp() throws {
        let (store, _, _) = makeStore()
        try store.apply(.memoryAppend(text: "durable fact", agent: "claude-mac"))
        let id = try XCTUnwrap(store.memory(includeRetired: true).first?.id)

        try store.apply(.memoryRetire(id: id, agent: "claude-mac", ts: Date(timeIntervalSince1970: 100)))
        let firstStamp = store.memory(includeRetired: true).first?.retiredAt
        try store.apply(.memoryRetire(id: id, agent: "claude-mac", ts: Date(timeIntervalSince1970: 999)))
        let secondStamp = store.memory(includeRetired: true).first?.retiredAt

        XCTAssertEqual(firstStamp, secondStamp, "re-retiring keeps the original retiredAt")
    }

    func testRetireMissingEntryThrows() throws {
        let (store, _, _) = makeStore()
        let ghost = UUID()
        XCTAssertThrowsError(try store.apply(.memoryRetire(id: ghost, agent: "claude-mac"))) {
            XCTAssertEqual($0 as? AgentLayerError, AgentLayerError.memoryNotFound(ghost))
        }
    }

    // MARK: - Views: publish, latest-wins, multi-agent interleave

    func testPublishLatestWinsAndInterleavesAgentsOnOneName() throws {
        let (store, _, _) = makeStore()
        let name = "This week"

        // Three revisions of ONE view, from two agents, out of chronological order
        // of insertion — latest createdAt must win display regardless.
        try store.apply(.viewPublish(viewName: name, body: "v1 (mac, oldest)",
                                     agent: "claude-mac", ts: Date(timeIntervalSince1970: 100)))
        try store.apply(.viewPublish(viewName: name, body: "v3 (runner, newest)",
                                     agent: "claude-runner", ts: Date(timeIntervalSince1970: 300)))
        try store.apply(.viewPublish(viewName: name, body: "v2 (mac, middle)",
                                     agent: "claude-mac", ts: Date(timeIntervalSince1970: 200)))

        // revisions() is newest-first.
        let revs = store.revisions(viewName: name)
        XCTAssertEqual(revs.map(\.body), ["v3 (runner, newest)", "v2 (mac, middle)", "v1 (mac, oldest)"])

        // latestRevisions() collapses to one row: the newest, attributed to its agent.
        let latest = store.latestRevisions()
        XCTAssertEqual(latest.count, 1)
        XCTAssertEqual(latest.first?.body, "v3 (runner, newest)")
        XCTAssertEqual(latest.first?.agentId, "claude-runner")

        XCTAssertEqual(store.viewNames(), [name])
    }

    func testLatestRevisionsOnePerViewNewestFirst() throws {
        let (store, _, _) = makeStore()

        try store.apply(.viewPublish(viewName: "Open loops", body: "loops",
                                     agent: "claude-mac", ts: Date(timeIntervalSince1970: 500)))
        try store.apply(.viewPublish(viewName: "This week", body: "week",
                                     agent: "claude-mac", ts: Date(timeIntervalSince1970: 900)))
        // A second, newer revision of "Open loops" must not add a second row.
        try store.apply(.viewPublish(viewName: "Open loops", body: "loops v2",
                                     agent: "claude-mac", ts: Date(timeIntervalSince1970: 1000)))

        let latest = store.latestRevisions()
        XCTAssertEqual(latest.count, 2, "one row per view")
        // Newest view first: "Open loops" latest (t=1000) precedes "This week" (t=900).
        XCTAssertEqual(latest.map(\.viewName), ["Open loops", "This week"])
        XCTAssertEqual(latest.first?.body, "loops v2")
    }

    // MARK: - Caps (mechanical validation → the right AgentLayerError)

    func testTagTooLongRejected() throws {
        let (store, _, noteId) = makeStore()
        let tooLong = String(repeating: "x", count: AgentLayerStore.Caps.tagMax + 1)
        XCTAssertThrowsError(try store.apply(.tag(noteId: noteId, tag: tooLong, agent: "claude-mac"))) {
            XCTAssertEqual($0 as? AgentLayerError, AgentLayerError.invalidLength(field: "tag", limit: AgentLayerStore.Caps.tagMax))
        }
        XCTAssertTrue(store.tags(forNote: noteId).isEmpty, "nothing written on a rejected apply")
    }

    func testEmptyTagRejected() throws {
        let (store, _, noteId) = makeStore()
        XCTAssertThrowsError(try store.apply(.tag(noteId: noteId, tag: "   ", agent: "claude-mac"))) {
            XCTAssertEqual($0 as? AgentLayerError, AgentLayerError.invalidLength(field: "tag", limit: AgentLayerStore.Caps.tagMax))
        }
    }

    func testNonPrintableTagRejected() throws {
        let (store, _, noteId) = makeStore()
        // A control char embedded mid-string is not printable → rejected.
        XCTAssertThrowsError(try store.apply(.tag(noteId: noteId, tag: "a\u{0007}b", agent: "claude-mac"))) {
            XCTAssertEqual($0 as? AgentLayerError, AgentLayerError.invalidLength(field: "tag", limit: AgentLayerStore.Caps.tagMax))
        }
    }

    func testMemoryTooLongRejected() throws {
        let (store, _, _) = makeStore()
        let tooLong = String(repeating: "m", count: AgentLayerStore.Caps.memoryTextMax + 1)
        XCTAssertThrowsError(try store.apply(.memoryAppend(text: tooLong, agent: "claude-mac"))) {
            XCTAssertEqual($0 as? AgentLayerError, AgentLayerError.invalidLength(field: "text", limit: AgentLayerStore.Caps.memoryTextMax))
        }
        XCTAssertTrue(store.memory(includeRetired: true).isEmpty)
    }

    func testViewNameTooLongRejected() throws {
        let (store, _, _) = makeStore()
        let tooLong = String(repeating: "n", count: AgentLayerStore.Caps.viewNameMax + 1)
        XCTAssertThrowsError(try store.apply(.viewPublish(viewName: tooLong, body: "b", agent: "claude-mac"))) {
            XCTAssertEqual($0 as? AgentLayerError, AgentLayerError.invalidLength(field: "viewName", limit: AgentLayerStore.Caps.viewNameMax))
        }
    }

    func testViewBodyTooLongRejected() throws {
        let (store, _, _) = makeStore()
        let tooLong = String(repeating: "b", count: AgentLayerStore.Caps.viewBodyMax + 1)
        XCTAssertThrowsError(try store.apply(.viewPublish(viewName: "ok", body: tooLong, agent: "claude-mac"))) {
            XCTAssertEqual($0 as? AgentLayerError, AgentLayerError.invalidLength(field: "body", limit: AgentLayerStore.Caps.viewBodyMax))
        }
        XCTAssertTrue(store.viewNames().isEmpty, "nothing written on a rejected publish")
    }

    func testEmptyViewBodyRejected() throws {
        let (store, _, _) = makeStore()
        XCTAssertThrowsError(try store.apply(.viewPublish(viewName: "ok", body: "", agent: "claude-mac"))) {
            XCTAssertEqual($0 as? AgentLayerError, AgentLayerError.invalidLength(field: "body", limit: AgentLayerStore.Caps.viewBodyMax))
        }
    }

    func testUnknownOpRejected() throws {
        let (store, _, _) = makeStore()
        let bogus = AgentOp(op: "note.delete", agent: "claude-mac", payload: .init())
        XCTAssertThrowsError(try store.apply(bogus)) {
            XCTAssertEqual($0 as? AgentLayerError, AgentLayerError.unknownOp("note.delete"))
        }
    }

    // MARK: - Instructions: singleton upsert

    func testSetInstructionsUpsertsSingleRecord() throws {
        let (store, context, _) = makeStore()

        XCTAssertEqual(store.instructions(), "", "no instructions yet → empty string")

        store.setInstructions("Prefer terse summaries.")
        XCTAssertEqual(store.instructions(), "Prefer terse summaries.")

        store.setInstructions("Actually, be thorough.")
        XCTAssertEqual(store.instructions(), "Actually, be thorough.")

        // Upsert, not append: exactly one row, at the well-known id.
        let all = try context.fetch(FetchDescriptor<InstructionsEntity>())
        XCTAssertEqual(all.count, 1, "instructions must stay a single record")
        XCTAssertEqual(all.first?.id, InstructionsEntity.wellKnownID)
    }

    // MARK: - User deletes (users may delete anything)

    func testUserDeleteTagAndMemoryAndView() throws {
        let (store, _, noteId) = makeStore()
        try store.apply(.tag(noteId: noteId, tag: "chip", agent: "claude-mac"))
        try store.apply(.memoryAppend(text: "fact", agent: "claude-mac"))
        try store.apply(.viewPublish(viewName: "V", body: "one", agent: "claude-mac"))
        try store.apply(.viewPublish(viewName: "V", body: "two", agent: "claude-mac"))

        store.userDelete(tag: try XCTUnwrap(store.tags(forNote: noteId).first))
        XCTAssertTrue(store.tags(forNote: noteId).isEmpty)

        store.userDelete(memory: try XCTUnwrap(store.memory(includeRetired: true).first))
        XCTAssertTrue(store.memory(includeRetired: true).isEmpty)

        // Deleting a whole view removes ALL its revisions.
        store.userDelete(view: "V")
        XCTAssertTrue(store.viewNames().isEmpty)
        XCTAssertTrue(store.revisions(viewName: "V").isEmpty)
    }

    // MARK: - User restore (the "time machine" — plan §M8 8b)

    func testUserRestoreAppendsCopyingOldBodyLatestWins() throws {
        let (store, _, _) = makeStore()
        let name = "Open loops"
        try store.apply(.viewPublish(viewName: name, body: "v1 body",
                                     agent: "claude-mac", ts: Date(timeIntervalSince1970: 100)))
        try store.apply(.viewPublish(viewName: name, body: "v2 body",
                                     agent: "claude-mac", ts: Date(timeIntervalSince1970: 200)))

        // Restore the OLDEST revision (v1).
        let before = store.revisions(viewName: name)
        XCTAssertEqual(before.count, 2)
        let v1 = try XCTUnwrap(before.first(where: { $0.body == "v1 body" }))

        store.userRestore(viewName: name, revisionId: v1.id, surface: "mac")

        // Append: count + 1, history never edited/reordered.
        let after = store.revisions(viewName: name)
        XCTAssertEqual(after.count, 3, "restore appends a new revision (count + 1)")

        // Latest-wins now returns the restored body, attributed user-mac.
        let latest = try XCTUnwrap(store.latestRevisions().first(where: { $0.viewName == name }))
        XCTAssertEqual(latest.body, "v1 body", "the restored copy is now the newest")
        XCTAssertEqual(latest.agentId, "user-mac", "a restore is user-<surface>, not an agent")
        XCTAssertNotEqual(latest.id, v1.id, "the restored copy is a NEW record, not the source")
    }

    func testUserRestoreLeavesSourceRevisionByteIdentical() throws {
        let (store, _, _) = makeStore()
        let name = "This week"
        try store.apply(.viewPublish(viewName: name, body: "original body",
                                     agent: "claude-runner", ts: Date(timeIntervalSince1970: 100)))
        try store.apply(.viewPublish(viewName: name, body: "newer body",
                                     agent: "claude-mac", ts: Date(timeIntervalSince1970: 200)))
        let source = try XCTUnwrap(store.revisions(viewName: name).first(where: { $0.body == "original body" }))

        store.userRestore(viewName: name, revisionId: source.id, surface: "ios")

        // The source revision is untouched — same id, body, agent, timestamp.
        let stillThere = try XCTUnwrap(store.revisions(viewName: name).first(where: { $0.id == source.id }))
        XCTAssertEqual(stillThere.body, "original body")
        XCTAssertEqual(stillThere.agentId, "claude-runner")
        XCTAssertEqual(stillThere.createdAt, Date(timeIntervalSince1970: 100))
        // And the restored copy carries the ios surface.
        let latest = try XCTUnwrap(store.latestRevisions().first(where: { $0.viewName == name }))
        XCTAssertEqual(latest.agentId, "user-ios")
        XCTAssertEqual(latest.body, "original body")
    }

    func testUserRestoreUnknownRevisionIsNoOp() throws {
        let (store, _, _) = makeStore()
        let name = "Nope"
        try store.apply(.viewPublish(viewName: name, body: "only", agent: "claude-mac"))
        let before = store.revisions(viewName: name).count

        // A revisionId that isn't a revision of this view writes nothing and doesn't throw.
        store.userRestore(viewName: name, revisionId: UUID(), surface: "mac")
        XCTAssertEqual(store.revisions(viewName: name).count, before, "unknown id is a safe no-op")

        // A real revisionId but the WRONG view name is also a no-op (the predicate keys on both).
        try store.apply(.viewPublish(viewName: "Other", body: "elsewhere", agent: "claude-mac"))
        let otherRev = try XCTUnwrap(store.revisions(viewName: "Other").first)
        store.userRestore(viewName: name, revisionId: otherRev.id, surface: "mac")
        XCTAssertEqual(store.revisions(viewName: name).count, before,
                       "a revision id from a different view doesn't restore into this one")
    }

    // MARK: - Note legacy decode (the new isRestricted field)

    func testNoteDecodesLegacyJSONWithoutIsRestricted() throws {
        // A note written before the gate existed: no `isRestricted` key at all.
        let legacy = #"{"id":"11111111-1111-1111-1111-111111111111","transcript":"old","source":"phone","createdAt":0,"updatedAt":0,"isFavorite":false}"#
        let note = try JSONDecoder().decode(Note.self, from: Data(legacy.utf8))
        XCTAssertFalse(note.isRestricted, "missing isRestricted decodes as not-restricted")
        XCTAssertEqual(note.transcript, "old")
    }

    func testNoteIsRestrictedRoundTrips() throws {
        var note = Note(id: UUID(), transcript: "secret", source: .phone)
        note.isRestricted = true
        let back = try JSONDecoder().decode(Note.self, from: JSONEncoder().encode(note))
        XCTAssertTrue(back.isRestricted, "isRestricted survives an encode/decode round-trip")
        // And through the entity projection.
        let viaEntity = Note(entity: NoteEntity(note: note))
        XCTAssertTrue(viaEntity.isRestricted)
    }
}
