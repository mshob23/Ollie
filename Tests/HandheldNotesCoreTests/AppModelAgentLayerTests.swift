import Foundation
import SwiftData
import XCTest
@testable import HandheldNotesCore

/// Exercises the **user-facing agent-layer plumbing on `AppModel`** that the M5 UI
/// surfaces (5b–5d) depend on: the restriction toggle, the standing-instructions
/// round-trip, and the published tag/memory snapshots + user-delete paths. These sit
/// between the SwiftUI views and `AgentLayerStore` (the write choke point), so they're
/// worth proving directly rather than trusting the wiring.
///
/// Pattern mirrors `AppModelRefreshTests`: an in-memory model, with layer records
/// written through a second `ModelContext` on the SAME container (the shape a CloudKit
/// import / inbox apply takes) and surfaced via `refresh()`.
@MainActor
final class AppModelAgentLayerTests: XCTestCase {

    /// An external `AgentLayerStore` over the model's container — stands in for the
    /// inbox ingestor / a synced-in record.
    private func externalStore(_ model: AppModel) -> AgentLayerStore {
        AgentLayerStore(context: ModelContext(model.modelContainerForTesting))
    }

    // MARK: - 5b: restriction toggle

    func testSetRestrictedFlipsTheNote() throws {
        let model = AppModel(inMemoryStore: true)
        let note = model.composeNote(transcript: "Sensitive thing.")
        XCTAssertFalse(model.notes.first { $0.id == note.id }?.isRestricted ?? true)

        model.setRestricted(true, for: note.id)
        XCTAssertTrue(model.notes.first { $0.id == note.id }?.isRestricted ?? false,
                      "setRestricted(true) must mark the note restricted")

        model.setRestricted(false, for: note.id)
        XCTAssertFalse(model.notes.first { $0.id == note.id }?.isRestricted ?? true,
                       "setRestricted(false) must un-restrict the note")
    }

    // MARK: - 5c: standing instructions round-trip

    func testInstructionsRoundTripThroughAppModel() throws {
        let model = AppModel(inMemoryStore: true)
        XCTAssertEqual(model.agentInstructions(), "", "no instructions yet → empty")

        model.setAgentInstructions("Prefer terse summaries.")
        XCTAssertEqual(model.agentInstructions(), "Prefer terse summaries.")

        // Upsert, not append — a second save replaces the text.
        model.setAgentInstructions("Actually, be thorough.")
        XCTAssertEqual(model.agentInstructions(), "Actually, be thorough.")
    }

    // MARK: - 5d: published tag snapshot + filter + user delete

    func testTagsSnapshotSurfacesAndFiltersByNote() throws {
        let model = AppModel(inMemoryStore: true)
        let a = model.composeNote(transcript: "Note A.")
        let b = model.composeNote(transcript: "Note B.")

        // Two agents/notes worth of tags, written externally then surfaced.
        try externalStore(model).apply(.tag(noteId: a.id, tag: "project:ollie", agent: "claude-mac"))
        try externalStore(model).apply(.tag(noteId: b.id, tag: "misc", agent: "claude-mac"))
        model.refresh()

        XCTAssertEqual(model.agentTags.count, 2, "both tags land in the published snapshot")
        XCTAssertEqual(model.tags(forNote: a.id).map(\.tag), ["project:ollie"],
                       "tags(forNote:) filters to the subject note")
        XCTAssertEqual(model.tags(forNote: b.id).map(\.tag), ["misc"])
    }

    func testUserDeleteTagRemovesItFromSnapshot() throws {
        let model = AppModel(inMemoryStore: true)
        let note = model.composeNote(transcript: "Taggable.")
        try externalStore(model).apply(.tag(noteId: note.id, tag: "remove-me", agent: "claude-mac"))
        model.refresh()
        let tag = try XCTUnwrap(model.tags(forNote: note.id).first)

        model.userDelete(tag: tag)
        XCTAssertTrue(model.tags(forNote: note.id).isEmpty,
                      "user-deleting a tag drops it from the note's chip row")
        XCTAssertFalse(model.agentTags.contains { $0.id == tag.id },
                       "and from the published snapshot")
    }

    // MARK: - 5d: published memory snapshot + retired flagging + user delete

    func testMemorySnapshotIncludesRetiredFlagged() throws {
        let model = AppModel(inMemoryStore: true)
        let store = externalStore(model)
        try store.apply(.memoryAppend(text: "‘HP’ means heat pump.", agent: "claude-mac"))
        model.refresh()
        let entry = try XCTUnwrap(model.agentMemory.first)
        XCTAssertFalse(entry.retired)

        // Retiring (an agent op) keeps the entry visible but flagged — the trust
        // screen dims it rather than hiding it.
        try store.apply(.memoryRetire(id: entry.id, agent: "claude-mac"))
        model.refresh()
        let retired = try XCTUnwrap(model.agentMemory.first { $0.id == entry.id })
        XCTAssertTrue(retired.retired, "retired entries stay in the snapshot, flagged")
    }

    func testUserDeleteMemoryRemovesItFromSnapshot() throws {
        let model = AppModel(inMemoryStore: true)
        try externalStore(model).apply(.memoryAppend(text: "durable fact", agent: "claude-mac"))
        model.refresh()
        let entry = try XCTUnwrap(model.agentMemory.first)

        model.userDelete(memory: entry)
        XCTAssertTrue(model.agentMemory.isEmpty,
                      "user-deleting a memory hard-removes it from the snapshot")
    }
}
