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
            title: "Round trip",
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
        XCTAssertEqual(back.title, original.title)
        XCTAssertEqual(back.transcript, original.transcript)
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

        let first = Note(id: id, title: "First", transcript: "v1", source: .computer)
        upsert(first, in: context)

        // A second device imports the same note (same id) with a later edit.
        let second = Note(id: id, title: "Edited", transcript: "v2", source: .computer)
        upsert(second, in: context)

        let all = try context.fetch(FetchDescriptor<NoteEntity>())
        XCTAssertEqual(all.count, 1, "same id must not duplicate")
        XCTAssertEqual(all.first?.title, "Edited")
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
