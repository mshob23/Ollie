import Foundation

/// Which speech-to-text engine turns a recording into a transcript. Stored by
/// raw value; unknown values fall back to `.appleSpeech` (the zero-install path).
enum TranscriptionEngine: String, CaseIterable, Sendable, Codable {
    case appleSpeech
    case whisper

    var displayName: String {
        switch self {
        case .appleSpeech: return "Apple Speech"
        case .whisper:     return "whisper.cpp"
        }
    }

    var subtitle: String {
        switch self {
        case .appleSpeech: return "On-device, no setup. Best on macOS 26+."
        case .whisper:     return "Local whisper-cli + ffmpeg (Homebrew)."
        }
    }
}

/// Errors surfaced from any transcription path. Mirrors the old app's taxonomy
/// so messages stay familiar.
enum TranscriptionError: Error, LocalizedError {
    case emptyRecording
    case noResult
    case missingTool(String)
    case appleSpeechUnavailable(String)
    case engineFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyRecording:
            return "The recording was empty — no audio to transcribe."
        case .noResult:
            return "No transcript was produced."
        case .missingTool(let path):
            return "Missing transcription tool: \(path)"
        case .appleSpeechUnavailable(let message):
            return "Apple Speech unavailable: \(message)"
        case .engineFailed(let message):
            return "Transcription failed: \(message)"
        }
    }
}

/// The result of transcribing one audio file.
struct TranscriptionResult: Sendable {
    var text: String
    var engineUsed: String
}

/// Anything that can turn an audio file into text. Two real implementations
/// (Apple Speech, whisper.cpp) plus the ability to swap in a stub for tests.
protocol Transcribing: Sendable {
    func transcribe(url: URL) async throws -> TranscriptionResult
}

/// Dispatches to the chosen engine, with a safety net: whisper falls back to
/// Apple Speech if its CLI/model aren't installed, and Apple Speech falls back
/// to a clearly-labelled placeholder transcript so a note still gets saved even
/// on a machine with neither path available (keeps the demo unbreakable).
struct TranscriptionService: Sendable {
    var engine: TranscriptionEngine

    private let apple = AppleSpeechTranscriber()
    private let whisper = WhisperCppTranscriber()

    init(engine: TranscriptionEngine = .appleSpeech) {
        self.engine = engine
    }

    func transcribe(url: URL) async throws -> TranscriptionResult {
        switch engine {
        case .appleSpeech:
            return try await appleOrStub(url: url)
        case .whisper:
            if whisper.isAvailable {
                do { return try await whisper.transcribe(url: url) }
                catch { return try await appleOrStub(url: url) }
            }
            return try await appleOrStub(url: url)
        }
    }

    /// Apple Speech, or — if it throws (older OS, asset trouble) — a placeholder
    /// transcript so the pipeline always yields a saveable note in the demo.
    private func appleOrStub(url: URL) async throws -> TranscriptionResult {
        do {
            return try await apple.transcribe(url: url)
        } catch {
            let seconds = (try? AudioInfo.duration(of: url)) ?? 0
            let placeholder = "[Transcription engine unavailable on this machine — "
                + "audio captured (\(String(format: "%.1f", seconds))s) and saved. "
                + "Install whisper-cli/ffmpeg or run on macOS 26+ to get a real transcript.]"
            return TranscriptionResult(text: placeholder, engineUsed: "demo")
        }
    }
}
