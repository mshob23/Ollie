import Foundation

/// Rung 3 of the exposability ladder: mirror the note corpus to plain, user-owned
/// files so ANY tool — Obsidian, a script, an LLM, the Ollie MCP server — can read
/// it. Two shapes from the same data:
///   • `ollie.jsonl` — the whole corpus, one JSON record per line. Machine/LLM fuel;
///     this is what the MCP server reads. Rewritten wholesale each export (cheap),
///     so it's always authoritative.
///   • `notes/<id>.md` — one Markdown file per note (frontmatter + body) for humans
///     and Obsidian.
///
/// Best-effort + non-fatal; runs off the main actor (the snapshot is a `[Note]`,
/// which is `Sendable`). **macOS-only for now** — the Mac holds the full
/// CloudKit-synced corpus and is where the MCP server runs; iOS export (into the
/// app's Files container) is a backlog item.
public enum CorpusExporter {
    /// The export root: `~/Ollie`. Visible and easy to point Obsidian / the MCP
    /// server at.
    public static var exportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Ollie", isDirectory: true)
    }

    /// Schedule an export off the main actor (best-effort). Call from anywhere.
    public static func exportInBackground(_ notes: [Note]) {
        Task.detached(priority: .utility) { export(notes) }
    }

    /// Mirror the corpus to disk. Safe on a background thread.
    public static func export(_ notes: [Note]) {
        // De-dup by id first — CloudKit mirroring can briefly surface duplicate-id
        // rows, and the corpus an LLM reads shouldn't contain the same note twice.
        var seen = Set<UUID>()
        let notes = notes.filter { seen.insert($0.id).inserted }
        let dir = exportDirectory
        let notesDir = dir.appendingPathComponent("notes", isDirectory: true)
        let fm = FileManager.default
        guard (try? fm.createDirectory(at: notesDir, withIntermediateDirectories: true)) != nil
        else { return }

        // 1) The whole corpus as JSONL (one compact record per line) — the LLM/MCP
        //    source of truth.
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]   // NOT prettyPrinted: one line each
        var lines: [String] = []
        lines.reserveCapacity(notes.count)
        for note in notes {
            if let data = try? enc.encode(ExportRecord(note)),
               let line = String(data: data, encoding: .utf8) {
                lines.append(line)
            }
        }
        let jsonl = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try? jsonl.write(to: dir.appendingPathComponent("ollie.jsonl"),
                         atomically: true, encoding: .utf8)

        // 2) One Markdown file per note (frontmatter + body) for humans / Obsidian.
        for note in notes {
            let url = notesDir.appendingPathComponent("\(note.id.uuidString).md")
            try? markdown(for: note).write(to: url, atomically: true, encoding: .utf8)
        }
        // (A deleted note leaves a stale `.md`; pruning is a backlog nicety — the
        // JSONL the MCP reads is rewritten whole each time, so it's never stale.)
    }

    // MARK: Shapes

    /// The flat record written to `ollie.jsonl` — a stable, LLM-friendly shape kept
    /// deliberately separate from `Note`'s internal `Codable` so the export format
    /// can evolve on its own.
    private struct ExportRecord: Encodable {
        let id: String
        let createdAt: Date
        let updatedAt: Date
        let source: String
        let kind: String
        let text: String
        let place: String?
        let latitude: Double?
        let longitude: Double?
        let durationSeconds: Double?
        let hasAudio: Bool

        init(_ n: Note) {
            id = n.id.uuidString
            createdAt = n.createdAt
            updatedAt = n.updatedAt
            source = n.source.rawValue
            kind = n.kind.rawValue
            text = n.transcript
            place = n.location?.label
            latitude = n.location?.latitude
            longitude = n.location?.longitude
            durationSeconds = n.durationSeconds
            hasAudio = n.hasAudio
        }
    }

    private static func markdown(for note: Note) -> String {
        let iso = ISO8601DateFormatter()
        var out = "---\n"
        out += "id: \(note.id.uuidString)\n"
        out += "date: \(iso.string(from: note.createdAt))\n"
        out += "source: \(note.source.rawValue)\n"
        out += "kind: \(note.kind.rawValue)\n"
        if let place = note.location?.label { out += "place: \(place)\n" }
        out += "---\n\n"
        out += note.transcript
        if !note.transcript.hasSuffix("\n") { out += "\n" }
        return out
    }
}
