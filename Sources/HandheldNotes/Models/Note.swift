import Foundation

/// Where a note came from. Drives the little source badge in the UI.
enum NoteSource: String, Codable, Sendable, Hashable {
    case computer   // Mac mic via the F16 push-to-talk hotkey
    case device     // synced from the handheld's SD card over BLE
    case seed       // demo content seeded on first run

    var label: String {
        switch self {
        case .computer: return "Computer"
        case .device:   return "Device"
        case .seed:     return "Demo"
        }
    }

    /// SF Symbol used for the source chip.
    var symbol: String {
        switch self {
        case .computer: return "mic.fill"
        case .device:   return "dot.radiowaves.left.and.right"
        case .seed:     return "sparkles"
        }
    }
}

/// A single voice note: a transcript, its metadata, and (optionally) the audio
/// file it was transcribed from. This is the heart of the app — everything the
/// pipeline produces is one of these, and the store is just an array of them.
struct Note: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var title: String
    var transcript: String
    var createdAt: Date
    var updatedAt: Date
    var source: NoteSource
    /// File name (not path) inside the store's `Audio/` directory; nil if there
    /// is no audio or it was deleted.
    var audioFileName: String?
    var durationSeconds: Double?
    var engineUsed: String?
    var isFavorite: Bool

    init(
        id: UUID = UUID(),
        title: String,
        transcript: String,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        source: NoteSource,
        audioFileName: String? = nil,
        durationSeconds: Double? = nil,
        engineUsed: String? = nil,
        isFavorite: Bool = false
    ) {
        self.id = id
        self.title = title
        self.transcript = transcript
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.source = source
        self.audioFileName = audioFileName
        self.durationSeconds = durationSeconds
        self.engineUsed = engineUsed
        self.isFavorite = isFavorite
    }

    /// Tolerant decode: a field missing from an older notes.json falls back to a
    /// sensible default instead of failing the whole load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled note"
        transcript = try c.decodeIfPresent(String.self, forKey: .transcript) ?? ""
        let created = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        createdAt = created
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? created
        source = try c.decodeIfPresent(NoteSource.self, forKey: .source) ?? .seed
        audioFileName = try c.decodeIfPresent(String.self, forKey: .audioFileName)
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds)
        engineUsed = try c.decodeIfPresent(String.self, forKey: .engineUsed)
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
    }

    // MARK: Derived

    /// First line / sentence of the transcript, for list previews.
    var preview: String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "No transcript" }
        let firstLine = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
        return firstLine
    }

    var hasAudio: Bool { audioFileName != nil }

    var wordCount: Int {
        transcript.split { $0 == " " || $0.isNewline }.count
    }

    /// Builds a human title from a transcript: first sentence or first handful of
    /// words, trimmed and capped. Falls back to a timestamped name.
    static func deriveTitle(from transcript: String, date: Date) -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            let fmt = DateFormatter()
            fmt.dateFormat = "MMM d, h:mm a"
            return "Note · \(fmt.string(from: date))"
        }
        // Cut at the first sentence terminator if there's one reasonably early.
        var candidate = trimmed
        if let range = trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?")) {
            let sentence = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            if sentence.count >= 12 { candidate = sentence }
        }
        // Otherwise cap to the first ~9 words.
        let words = candidate.split { $0 == " " || $0.isNewline }
        if words.count > 9 {
            candidate = words.prefix(9).joined(separator: " ") + "…"
        }
        if candidate.count > 64 {
            candidate = String(candidate.prefix(63)) + "…"
        }
        return candidate
    }
}
