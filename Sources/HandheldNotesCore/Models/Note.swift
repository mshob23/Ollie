import Foundation

/// Where a note came from. Drives the little source badge in the UI.
public enum NoteSource: String, Codable, Sendable, Hashable {
    case computer   // Mac mic via the F16 push-to-talk hotkey
    case watch      // recorded on the Apple Watch, transferred to iPhone over WatchConnectivity
    case phone      // composed on the iPhone — typed, or recorded + transcribed on-device
    case seed       // demo content seeded on first run

    public var label: String {
        switch self {
        case .computer: return "Computer"
        case .watch:    return "Watch"
        case .phone:    return "iPhone"
        case .seed:     return "Demo"
        }
    }

    /// SF Symbol used for the source chip.
    public var symbol: String {
        switch self {
        case .computer: return "mic.fill"
        case .watch:    return "applewatch"
        case .phone:    return "iphone"
        case .seed:     return "sparkles"
        }
    }
}

/// How a note was captured: spoken (then transcribed) or typed. `source` says
/// *which device*; `kind` says *voice vs. text*. Provenance the UI and the future
/// on-device intelligence can lean on. Set at capture for new notes; legacy notes
/// (written before `kind` existed) infer it from whether audio rode along.
public enum CaptureKind: String, Codable, Sendable, Hashable {
    case voice
    case text
}

/// An optional, opt-in capture location. `label` is an on-device reverse-geocoded
/// place name ("Gold's Gym"); the raw coordinate is optional so the user can keep
/// just the human label if they'd rather not store precise coordinates.
public struct PlaceStamp: Codable, Hashable, Sendable {
    public var label: String
    public var latitude: Double?
    public var longitude: Double?

    public init(label: String, latitude: Double? = nil, longitude: Double? = nil) {
        self.label = label
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// A single note: a transcript (spoken-then-transcribed OR typed), its metadata,
/// and (optionally) the audio it was transcribed from. The heart of the app —
/// everything the pipeline produces is one of these.
///
/// **No stored title.** Ollie deliberately has no titles: a note's identity is its
/// content + context (time, source, place). ``derivedTitle`` offers a *computed*,
/// display-only headline for the few places that still want a one-line label, and
/// is the seam a future AI `summary` slots into — but nothing stores or edits a
/// title.
public struct Note: Identifiable, Codable, Hashable, Sendable {
    /// Bump when the record's shape changes in a way a future migration branches on.
    public static let currentSchemaVersion = 2

    public let id: UUID
    public var transcript: String
    /// Voice (transcribed) vs. text (typed). See ``CaptureKind``.
    public var kind: CaptureKind
    public var createdAt: Date
    public var updatedAt: Date
    public var source: NoteSource
    /// Optional, opt-in geotag (see ``PlaceStamp``). Nil unless the user enabled
    /// geotagging and a fix was available shortly after capture.
    public var location: PlaceStamp?
    /// File name (not path) inside the store's `Audio/` directory; nil if there is
    /// no audio or it was deleted.
    public var audioFileName: String?
    public var durationSeconds: Double?
    public var engineUsed: String?
    public var isFavorite: Bool
    /// The record-shape version this note was written with (see
    /// ``currentSchemaVersion``); lets future migrations reason about old rows.
    public var schemaVersion: Int

    public init(
        id: UUID = UUID(),
        transcript: String,
        kind: CaptureKind = .voice,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        source: NoteSource,
        location: PlaceStamp? = nil,
        audioFileName: String? = nil,
        durationSeconds: Double? = nil,
        engineUsed: String? = nil,
        isFavorite: Bool = false,
        schemaVersion: Int = Note.currentSchemaVersion
    ) {
        self.id = id
        self.transcript = transcript
        self.kind = kind
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.source = source
        self.location = location
        self.audioFileName = audioFileName
        self.durationSeconds = durationSeconds
        self.engineUsed = engineUsed
        self.isFavorite = isFavorite
        self.schemaVersion = schemaVersion
    }

    /// Tolerant decode: a field missing from an older `notes.json` falls back to a
    /// sensible default instead of failing the whole load. A pre-`kind` note infers
    /// `kind` from whether audio rode along; a pre-title-removal note simply ignores
    /// its now-gone `title` key.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        transcript = try c.decodeIfPresent(String.self, forKey: .transcript) ?? ""
        let created = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        createdAt = created
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? created
        source = try c.decodeIfPresent(NoteSource.self, forKey: .source) ?? .seed
        location = try c.decodeIfPresent(PlaceStamp.self, forKey: .location)
        audioFileName = try c.decodeIfPresent(String.self, forKey: .audioFileName)
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds)
        engineUsed = try c.decodeIfPresent(String.self, forKey: .engineUsed)
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        let decodedKind = try c.decodeIfPresent(CaptureKind.self, forKey: .kind)
        kind = decodedKind ?? (audioFileName != nil ? .voice : .text)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    }

    // MARK: Derived

    /// First line of the transcript, for list previews.
    public var preview: String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "No transcript" }
        let firstLine = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
        return firstLine
    }

    public var hasAudio: Bool { audioFileName != nil }

    /// True when this note's body is a transcription-failure placeholder, so the UI
    /// can offer a re-transcribe and the corpus export can flag it (an LLM shouldn't
    /// treat the placeholder as real content). The audio is always preserved, so a
    /// failed take is recoverable later. Catches BOTH pipeline failure shapes:
    ///   • `engineUsed == "error"` + `[Transcription failed: …]` (Apple Speech threw)
    ///   • `[Transcription unavailable here — …]` (engine unavailable / no model yet —
    ///     `engineUsed == "demo"`, which is ALSO used by real demo notes, so we match
    ///     on the placeholder body, not the engine, to avoid flagging genuine demos).
    /// A prefix match on "[Transcription " covers both without false-flagging content.
    public var transcriptionFailed: Bool {
        engineUsed == "error" || transcript.hasPrefix("[Transcription ")
    }

    public var wordCount: Int {
        transcript.split { $0 == " " || $0.isNewline }.count
    }

    /// A computed, display-only headline — first sentence / few words of the
    /// transcript. **Not stored and not user-editable** (Ollie has no titles); a
    /// convenience for one-line labels and the seam a future AI `summary` replaces.
    public var derivedTitle: String { Note.deriveTitle(from: transcript, date: createdAt) }

    /// Builds a human headline from a transcript: first sentence or first handful
    /// of words, trimmed and capped. Falls back to a timestamped name. Backs
    /// ``derivedTitle``; kept as a static helper so callers can derive a label
    /// without a `Note` instance.
    public static func deriveTitle(from transcript: String, date: Date) -> String {
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
