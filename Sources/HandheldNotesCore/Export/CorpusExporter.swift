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
    /// Test-only override for the export root. When non-nil, `exportDirectory`
    /// returns this instead of `~/Ollie`, so tests can redirect the export at a temp
    /// dir (to assert success) or an unwritable path (to assert failure handling)
    /// without ever touching the real corpus. `nonisolated(unsafe)` is acceptable
    /// because it's set once at the top of a test, before the code under test runs,
    /// and never mutated concurrently.
    nonisolated(unsafe) public static var exportDirectoryOverride: URL?

    /// The export root: `~/Ollie` (or `exportDirectoryOverride` in tests). Visible
    /// and easy to point Obsidian / the MCP server at.
    ///
    /// The base dir is platform-aware: `homeDirectoryForCurrentUser` is macOS-only
    /// (unavailable on iOS), so iOS falls back to the app's Documents container. macOS
    /// behavior is unchanged. The test override, when set, wins on every platform.
    public static var exportDirectory: URL {
        if let override = exportDirectoryOverride { return override }
        #if os(macOS)
        let base = FileManager.default.homeDirectoryForCurrentUser
        #else
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #endif
        return base.appendingPathComponent("Ollie", isDirectory: true)
    }

    /// The sidecar metadata file `~/Ollie/.ollie.meta.json`. Written after every
    /// successful corpus export so external readers (the MCP server) can tell how
    /// fresh the corpus is and how many notes it should contain.
    public static var metaURL: URL {
        exportDirectory.appendingPathComponent(".ollie.meta.json")
    }

    /// Schedule an export off the main actor (best-effort).
    ///
    /// **Priority `.default`, not `.utility`.** The export feeds the `~/Ollie` mirror
    /// the MCP server and Obsidian read, so a user who just captured a note expects it
    /// to show up there promptly. `.utility` could sit behind other background work;
    /// default priority keeps the corpus fresh without contending with interactive UI.
    /// (Spelled `.medium` — the non-deprecated name for `TaskPriority.default`; same
    /// underlying value.)
    public static func exportInBackground(_ notes: [Note]) {
        Task.detached(priority: .medium) { export(notes) }
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
        do {
            try fm.createDirectory(at: notesDir, withIntermediateDirectories: true)
        } catch {
            // Can't even make the directory — log it (don't silently swallow) and bail.
            Diag.log("HNDIAG export FAILED to create \(notesDir.path): \(error)")
            return
        }

        // 1) The whole corpus as JSONL (one compact record per line) — the LLM/MCP
        //    source of truth. A failed write is LOGGED, not swallowed: a silently
        //    stale corpus is the exact failure this whole stage exists to prevent.
        let jsonlURL = dir.appendingPathComponent("ollie.jsonl")
        var jsonlOK = false
        do {
            try jsonlString(for: notes).write(to: jsonlURL, atomically: true, encoding: .utf8)
            jsonlOK = true
        } catch {
            Diag.log("HNDIAG export FAILED to write \(jsonlURL.path): \(error)")
        }

        // 2) One Markdown file per note (frontmatter + body) for humans / Obsidian.
        for note in notes {
            let url = notesDir.appendingPathComponent("\(note.id.uuidString).md")
            do {
                try markdown(for: note).write(to: url, atomically: true, encoding: .utf8)
            } catch {
                Diag.log("HNDIAG export FAILED to write \(url.lastPathComponent): \(error)")
            }
        }
        // (A deleted note leaves a stale `.md`; pruning is a backlog nicety — the
        // JSONL the MCP reads is rewritten whole each time, so it's never stale.)

        // 3) Only after a SUCCESSFUL JSONL write, refresh the staleness sidecar so a
        //    reader can trust it. Writing meta after a failed corpus write would
        //    falsely advertise a fresh export.
        if jsonlOK { writeMeta(noteCount: notes.count) }
    }

    /// Write `~/Ollie/.ollie.meta.json` describing the just-completed export:
    /// `{ "exportedAt": <ISO8601 now>, "noteCount": N, "schemaVersion": <current> }`.
    /// The MCP server reads this to surface staleness ("corpus older than ~24h") and
    /// to know the expected note count. Failures are logged, never swallowed.
    private static func writeMeta(noteCount: Int) {
        let meta: [String: Any] = [
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "noteCount": noteCount,
            "schemaVersion": Note.currentSchemaVersion,
        ]
        do {
            let data = try JSONSerialization.data(
                withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: metaURL, options: [.atomic])
        } catch {
            Diag.log("HNDIAG export FAILED to write \(metaURL.path): \(error)")
        }
    }

    /// Write a one-off, timestamped JSONL snapshot of the corpus to
    /// `~/Ollie/backups/ollie-backup-<stamp>.jsonl` and return its URL.
    ///
    /// Unlike `export(_:)` — which rewrites the live `ollie.jsonl` mirror in place —
    /// this lands in a dedicated file that nothing else overwrites, so it survives a
    /// subsequent empty export (e.g. the reload right after `--wipe-all-notes`). Use it
    /// as a safety net immediately before a destructive operation. Best-effort: returns
    /// `nil` if the directory or file can't be written.
    @discardableResult
    public static func backup(_ notes: [Note]) -> URL? {
        let fm = FileManager.default
        let dir = exportDirectory.appendingPathComponent("backups", isDirectory: true)
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil
        else { return nil }

        // Filesystem-safe local-time stamp (`yyyyMMdd-HHmmss`). Built locally rather
        // than as a shared static — DateFormatter isn't Sendable.
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let url = dir.appendingPathComponent("ollie-backup-\(stamp.string(from: Date())).jsonl")
        do {
            try jsonlString(for: notes).write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
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

    /// Encode notes as JSONL (one compact `ExportRecord` per line, trailing newline).
    /// Shared by the live `ollie.jsonl` mirror (`export`) and the timestamped `backup`.
    private static func jsonlString(for notes: [Note]) -> String {
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
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
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
