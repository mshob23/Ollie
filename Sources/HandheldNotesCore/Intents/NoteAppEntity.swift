import AppIntents
import Foundation
import SwiftData

/// Your `Note`, exposed to the system (Siri, Shortcuts, Spotlight, Apple
/// Intelligence) as a first-class entity it can search, hold, and pass between
/// actions — the bridge from "a note in our store" to "a thing the assistant
/// understands." This is Rung 2 of Ollie's exposability ladder.
public struct NoteAppEntity: AppEntity {
    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Note")
    }
    public static let defaultQuery = NoteEntityQuery()

    public let id: UUID

    /// The note's text — `@Property` so a Shortcut can pull it into a follow-on
    /// action ("find my note about X → copy its transcript").
    @Property(title: "Transcript") public var transcript: String
    @Property(title: "Date") public var createdAt: Date

    /// Display-only, computed in the app (Ollie has no stored title).
    public var headline: String
    public var sourceLabel: String
    public var place: String?

    public init(note: Note) {
        self.id = note.id
        self.headline = note.derivedTitle
        self.sourceLabel = note.source.label
        self.place = note.location?.label
        // @Property assignments go through the wrapper's setter, which needs `self`
        // fully initialized — so set the plain stored properties above first.
        self.transcript = note.transcript
        self.createdAt = note.createdAt
    }

    public var displayRepresentation: DisplayRepresentation {
        var bits = [sourceLabel]
        if let place, !place.isEmpty { bits.append(place) }
        return DisplayRepresentation(
            title: "\(headline)",
            subtitle: "\(bits.joined(separator: " · "))")
    }
}

/// How the system fetches `NoteAppEntity`s: by id (resolve a saved reference),
/// as suggestions (recent notes), and by free-text search.
public struct NoteEntityQuery: EntityQuery {
    public init() {}

    @MainActor
    public func entities(for identifiers: [UUID]) async throws -> [NoteAppEntity] {
        NoteIntentStore.notes(forIDs: identifiers)
    }

    @MainActor
    public func suggestedEntities() async throws -> [NoteAppEntity] {
        NoteIntentStore.recentNotes(limit: 12)
    }
}

extension NoteEntityQuery: EntityStringQuery {
    @MainActor
    public func entities(matching string: String) async throws -> [NoteAppEntity] {
        NoteIntentStore.search(string, limit: 25)
    }
}

/// The read/write path the App Intents use. Reads through the SAME shared
/// SwiftData container the app uses (`NotesDataStore.shared`), so an intent
/// invoked in the background sees the user's real notes. `@MainActor` keeps all
/// store access on one actor, matching `AppModel`. Personal-scale corpus, so a
/// fetch-all-then-filter is plenty (and dodges `#Predicate` string-method pitfalls).
@MainActor
enum NoteIntentStore {
    private static func allNotes() -> [Note] {
        let descriptor = FetchDescriptor<NoteEntity>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        let context = ModelContext(NotesDataStore.shared)
        let entities = (try? context.fetch(descriptor)) ?? []
        return entities.map(Note.init(entity:))
    }

    static func notes(forIDs ids: [UUID]) -> [NoteAppEntity] {
        let want = Set(ids)
        return allNotes().filter { want.contains($0.id) }.map(NoteAppEntity.init(note:))
    }

    static func recentNotes(limit: Int) -> [NoteAppEntity] {
        Array(allNotes().prefix(limit)).map(NoteAppEntity.init(note:))
    }

    static func search(_ query: String, limit: Int) -> [NoteAppEntity] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return recentNotes(limit: limit) }
        let hits = allNotes().filter {
            $0.transcript.localizedCaseInsensitiveContains(q)
                || ($0.location?.label.localizedCaseInsensitiveContains(q) ?? false)
        }
        return Array(hits.prefix(limit)).map(NoteAppEntity.init(note:))
    }

    @discardableResult
    static func save(text: String) -> NoteAppEntity? {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        let note = Note(transcript: body, kind: .text, source: .phone)
        let context = ModelContext(NotesDataStore.shared)
        context.insert(NoteEntity(note: note))
        try? context.save()
        return NoteAppEntity(note: note)
    }
}
