import Foundation
import SwiftData
import XCTest
@testable import HandheldNotesCore

/// Covers the SwiftData layer that backs the iCloud-synced notes store: the
/// `Note ↔ NoteEntity` mapping round-trip and the id-keyed upsert that keeps a
/// double-import (Mac + iPhone carrying the same legacy file) from duplicating.
final class NoteEntityStoreTests: XCTestCase {

    /// A `Note` survives a round-trip through `NoteEntity` unchanged on every
    /// field the UI reads (audio bytes are managed separately and intentionally
    /// not part of the value type).
    func testNoteEntityRoundTripPreservesFields() throws {
        let original = Note(
            id: UUID(),
            transcript: "Body text with detail.",
            createdAt: Date(timeIntervalSince1970: 1_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_000_500),
            source: .watch,
            audioFileName: "abc.m4a",
            durationSeconds: 12.5,
            engineUsed: "Apple Speech",
            isFavorite: true)

        let entity = NoteEntity(note: original)
        let back = Note(entity: entity)

        XCTAssertEqual(back.id, original.id)
        XCTAssertEqual(back.transcript, original.transcript)
        // The headline is derived from the transcript, not stored, so it must
        // survive the round-trip identically (proving the transcript did).
        XCTAssertEqual(back.derivedTitle, original.derivedTitle)
        XCTAssertEqual(back.createdAt, original.createdAt)
        XCTAssertEqual(back.updatedAt, original.updatedAt)
        XCTAssertEqual(back.source, original.source)
        XCTAssertEqual(back.audioFileName, original.audioFileName)
        XCTAssertEqual(back.durationSeconds, original.durationSeconds)
        XCTAssertEqual(back.engineUsed, original.engineUsed)
        XCTAssertEqual(back.isFavorite, original.isFavorite)
    }

    /// An unknown source rawValue tolerantly falls back to `.seed` (matching the
    /// `Note` decoder), so a record written by a newer build never crashes an
    /// older one.
    func testUnknownSourceFallsBackToSeed() {
        let entity = NoteEntity(id: UUID(), sourceRaw: "from-the-future")
        XCTAssertEqual(entity.noteSource, .seed)
        XCTAssertEqual(Note(entity: entity).source, .seed)
    }

    /// Inserting the same id twice (the double-import scenario) must converge to a
    /// single stored entity when callers upsert by id rather than blind-append.
    func testIdKeyedUpsertDoesNotDuplicate() throws {
        let context = ModelContext(NotesDataStore.makeContainerForTesting())
        let id = UUID()

        let first = Note(id: id, transcript: "v1", source: .computer)
        upsert(first, in: context)

        // A second device imports the same note (same id) with a later edit.
        let second = Note(id: id, transcript: "v2", source: .computer)
        upsert(second, in: context)

        let all = try context.fetch(FetchDescriptor<NoteEntity>())
        XCTAssertEqual(all.count, 1, "same id must not duplicate")
        XCTAssertEqual(all.first?.transcript, "v2")
    }

    // Mirrors AppModel's private upsert: fetch by id, apply-or-insert.
    private func upsert(_ note: Note, in context: ModelContext) {
        let id = note.id
        var d = FetchDescriptor<NoteEntity>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        if let existing = try? context.fetch(d).first {
            existing.apply(note)
        } else {
            context.insert(NoteEntity(note: note))
        }
        try? context.save()
    }
}

// Test-only container factory (in-memory, no CloudKit). Lives here so the test
// target doesn't need to reach into the @MainActor production factory.
extension NotesDataStore {
    static func makeContainerForTesting() -> ModelContainer {
        let schema = Schema([NoteEntity.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try! ModelContainer(for: schema, configurations: [config])
    }
}

/// Exercises the live-refresh contract of `AppModel.refresh()` WITHOUT CloudKit
/// or iCloud: an in-memory store, with an "external" write applied through a
/// SECOND `ModelContext` on the SAME container — the shape a synced-in edit from
/// another device takes (CloudKit imports rows into the store out of band, then
/// posts `.NSPersistentStoreRemoteChange`). `refresh()` must re-project and pick
/// the new row up. Also pins that ordinary local insert + delete still reflect.
@MainActor
final class AppModelRefreshTests: XCTestCase {

    /// A row written by a SEPARATE context on the same store (simulating a remote
    /// CloudKit import) must appear in `notes` after `refresh()` — proving the
    /// re-projection reads the latest *persisted* state, not the write context's
    /// stale object cache.
    func testRefreshSurfacesExternallyWrittenNote() throws {
        let model = AppModel(inMemoryStore: true)

        // A note id that the model has never seen (no insert went through it).
        let remoteID = UUID()
        XCTAssertFalse(model.notes.contains { $0.id == remoteID },
                       "precondition: the remote note isn't present yet")

        // Simulate the CloudKit import: a DIFFERENT ModelContext on the SAME
        // container inserts the row and saves it into the store.
        let externalContext = ModelContext(model.modelContainerForTesting)
        let entity = NoteEntity(note: Note(
            id: remoteID,
            transcript: "Arrived over iCloud.",
            source: .phone))
        externalContext.insert(entity)
        try externalContext.save()

        // The manual refresh (and, in the app, the remote-change notification)
        // re-projects: the externally-written row is now in the list.
        model.refresh()
        XCTAssertTrue(model.notes.contains { $0.id == remoteID },
                      "refresh() must surface a row written by another context/device")
        XCTAssertEqual(model.notes.first { $0.id == remoteID }?.transcript,
                       "Arrived over iCloud.")
    }

    /// A normal local insert lands in `notes`, and a delete removes it — the
    /// projection tracks ordinary on-device CRUD (regression guard alongside the
    /// remote path).
    func testLocalInsertAndDeleteReflectInNotes() throws {
        let model = AppModel(inMemoryStore: true)

        let note = model.composeNote(transcript: "Typed here.")
        XCTAssertTrue(model.notes.contains { $0.id == note.id },
                      "a locally composed note must appear in notes")

        model.delete(note.id)
        XCTAssertFalse(model.notes.contains { $0.id == note.id },
                       "a deleted note must drop out of notes")
    }
}
