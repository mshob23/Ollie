import Foundation

/// Which speech-to-text engine turns a recording into a transcript. Ollie uses
/// Apple's on-device Speech exclusively (the Mac's built-in models are plenty) —
/// this single-case enum is kept only so the persisted `transcriptionEngineID`
/// setting and the `TranscriptionService(engine:)` seam stay stable. (An older
/// settings file that stored "whisper" decodes to `.appleSpeech` via the
/// unknown-value fallback in `NotesSettings.engine`.)
public enum TranscriptionEngine: String, CaseIterable, Sendable, Codable {
    case appleSpeech

    public var displayName: String { "Apple Speech" }
    public var subtitle: String { "On-device, private, no setup." }
}

/// Errors surfaced from the transcription path.
public enum TranscriptionError: Error, LocalizedError {
    case emptyRecording
    case noResult
    case appleSpeechUnavailable(String)
    case engineFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyRecording:
            return "The recording was empty — no audio to transcribe."
        case .noResult:
            return "No transcript was produced."
        case .appleSpeechUnavailable(let message):
            return "Apple Speech unavailable: \(message)"
        case .engineFailed(let message):
            return "Transcription failed: \(message)"
        }
    }
}

/// The result of transcribing one audio file.
public struct TranscriptionResult: Sendable {
    public var text: String
    public var engineUsed: String

    public init(text: String, engineUsed: String) {
        self.text = text
        self.engineUsed = engineUsed
    }
}

/// Anything that can turn an audio file into text (Apple Speech, or a test stub).
protocol Transcribing: Sendable {
    func transcribe(url: URL) async throws -> TranscriptionResult
}

/// On-device transcription via Apple Speech, with a safety net: if Apple Speech
/// throws (no on-device model yet, asset trouble), it falls back to a clearly-
/// labelled placeholder transcript so a note is always saved — and the preserved
/// audio can be re-run later via Re-transcribe.
public struct TranscriptionService: Sendable {
    public var engine: TranscriptionEngine

    private let apple = AppleSpeechTranscriber()

    public init(engine: TranscriptionEngine = .appleSpeech) {
        self.engine = engine
    }

    public func transcribe(url: URL) async throws -> TranscriptionResult {
        return try await appleOrStub(url: url)
    }

    /// Apple Speech, or — if it throws (no on-device model yet, asset trouble) — a
    /// placeholder transcript so the pipeline always yields a saveable note. The
    /// audio is preserved, so such a note is recoverable via Re-transcribe.
    private func appleOrStub(url: URL) async throws -> TranscriptionResult {
        do {
            return try await apple.transcribe(url: url)
        } catch {
            let seconds = (try? AudioInfo.duration(of: url)) ?? 0
            #if os(macOS)
            let hint = "A real transcript is produced on-device — this Mac has no speech model available yet."
            #else
            let hint = "A real transcript is produced on-device — the Simulator just has no speech models."
            #endif
            let placeholder = "[Transcription unavailable here — "
                + "audio captured (\(String(format: "%.1f", seconds))s) and saved. " + hint + "]"
            return TranscriptionResult(text: placeholder, engineUsed: "demo")
        }
    }
}
