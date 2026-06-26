import Foundation

/// An in-progress note. Unlike a `Note`, a draft is *not* finalized when a
/// recording stops — it keeps accumulating content (appended speech, typed/edited
/// text, device-button edits) until the user explicitly concludes it. On conclude
/// it becomes a saved `Note` and a fresh empty draft takes its place.
///
/// This mirrors the handheld: hold-to-talk appends transcribed speech, Space /
/// Newline / Backspace edit the same buffer, and double-tap-middle (Enter)
/// concludes. Only Computer / live mode drafts here; Local-mode recordings arrive
/// from the device already concluded.
struct Draft: Identifiable, Equatable, Sendable {
    let id: UUID
    /// The accumulating body the user is composing.
    var transcript: String
    var createdAt: Date
    /// Audio file name (in the store's `Audio/` dir) for the most recent recording
    /// appended to this draft, retained so the concluded note keeps a recording.
    var audioFileName: String?
    var durationSeconds: Double?
    var engineUsed: String?
    /// How many recordings have been appended (drives the count chip in the UI).
    var appendCount: Int

    init(id: UUID = UUID(), transcript: String = "", createdAt: Date = Date()) {
        self.id = id
        self.transcript = transcript
        self.createdAt = createdAt
        self.audioFileName = nil
        self.durationSeconds = nil
        self.engineUsed = nil
        self.appendCount = 0
    }

    var isEmpty: Bool {
        transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var wordCount: Int {
        transcript.split { $0 == " " || $0.isNewline }.count
    }

    /// Append freshly transcribed speech, inserting a single space between the
    /// existing buffer and the new chunk when both sides need it (so successive
    /// hold-to-talks read as continuous prose).
    mutating func appendSpeech(_ chunk: String) {
        let piece = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !piece.isEmpty else { return }
        if transcript.isEmpty {
            transcript = piece
        } else if let last = transcript.last, last == " " || last == "\n" {
            transcript += piece
        } else {
            transcript += " " + piece
        }
        appendCount += 1
    }

    /// Device RIGHT-tap = Space.
    mutating func typeSpace() { transcript += " " }

    /// Device RIGHT double-tap = Shift+Enter = newline.
    mutating func typeNewline() { transcript += "\n" }

    /// Device BOTTOM = Backspace (delete the last character).
    mutating func backspace() {
        guard !transcript.isEmpty else { return }
        transcript.removeLast()
    }

    /// Materialize the draft into a finished note for the saved list. The body is
    /// trimmed of surrounding whitespace/newlines so a concluded note never carries
    /// stray leading/trailing space (and the derived title stays clean). Callers
    /// must only invoke this on a non-empty draft (see `AppModel.concludeDraft`,
    /// which treats an empty/whitespace draft as a no-op).
    func makeNote() -> Note {
        let now = Date()
        let body = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return Note(
            id: id,
            title: Note.deriveTitle(from: body, date: now),
            transcript: body,
            createdAt: createdAt,
            updatedAt: now,
            source: .computer,
            audioFileName: audioFileName,
            durationSeconds: durationSeconds,
            engineUsed: engineUsed)
    }
}
