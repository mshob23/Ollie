import Foundation

/// **SHELVED (June 2026)** — see `EmbeddingService` and `docs/semantic-search.md`.
/// Built + validated, not wired into the app.
///
/// A local, on-device cache of note embeddings + the brute-force semantic search over
/// them (Rung 1a). Personal scale (hundreds–low thousands of notes), so it's just an
/// in-memory dictionary + a linear cosine scan — no vector DB. Persisted to a small
/// local file and **never synced**: embeddings are a derived, model-specific cache; the
/// transcript is the synced source of truth (see `EmbeddingService`).
///
/// An `actor` so the (potentially bulk) embedding work runs off the main actor and all
/// access is serialized — `AppModel` awaits it from a background `Task`.
public actor EmbeddingIndex {
    private struct Entry: Codable {
        var updatedAt: Date     // re-embed only when the note actually changes
        var modelID: String     // invalidate if the embedding model changes
        var vector: [Float]
    }

    /// Keyed by `note.id.uuidString` (String keys → clean JSON on disk).
    private var entries: [String: Entry] = [:]
    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultURL()
        if let data = try? Data(contentsOf: self.fileURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        }
    }

    private static func defaultURL() -> URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ollie", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("embeddings.json")
    }

    /// Bring the index in line with the current notes: embed new/changed ones, drop
    /// deleted ones, persist if anything changed. Cheap + idempotent; safe to call on
    /// every store reload. No-op when on-device embeddings are unavailable.
    public func sync(with notes: [Note]) {
        guard EmbeddingService.isAvailable else { return }
        var changed = false

        let liveKeys = Set(notes.map { $0.id.uuidString })
        for key in entries.keys where !liveKeys.contains(key) {
            entries[key] = nil
            changed = true
        }
        for note in notes {
            let key = note.id.uuidString
            // Skip trivial fragments: short notes embed to near-central vectors that match
            // *every* query (and they're usually throwaway/test noise). They stay in literal
            // search and the list — they're just kept out of semantic ranking.
            if note.transcript.split(whereSeparator: { $0 == " " || $0.isNewline }).count < 6 {
                if entries[key] != nil { entries[key] = nil; changed = true }
                continue
            }
            if let e = entries[key], e.updatedAt == note.updatedAt, e.modelID == EmbeddingService.modelID {
                continue   // already current
            }
            guard let vector = EmbeddingService.embed(note.transcript) else { continue }
            entries[key] = Entry(updatedAt: note.updatedAt, modelID: EmbeddingService.modelID, vector: vector)
            changed = true
        }
        if changed { save() }
    }

    /// Rank note ids by semantic similarity to `query` (descending), keeping scores at
    /// or above `minScore`. Empty when embeddings are unavailable — the caller then
    /// falls back to literal search.
    public func search(_ query: String, limit: Int = 25, minScore: Float = 0.5) -> [(id: UUID, score: Float)] {
        guard let qv = EmbeddingService.embed(query) else { return [] }
        let scored: [(UUID, Float)] = entries.compactMap { key, e in
            guard let id = UUID(uuidString: key) else { return nil }
            let s = EmbeddingService.similarity(qv, e.vector)
            return s >= minScore ? (id, s) : nil
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map { (id: $0.0, score: $0.1) }
    }

    public var count: Int { entries.count }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}
