import AVFoundation
import Foundation

#if os(macOS)

/// Local whisper.cpp transcription, adapted from the old app's
/// WhisperCppTranscriptionRunner. Shells out to `whisper-cli` (+ `ffmpeg` for any
/// non-WAV input). If the tools/model aren't installed, `isAvailable` is false
/// and the dispatcher falls back to Apple Speech — so this is a real path when
/// present and a no-op otherwise.
///
/// macOS-only: it depends on `Process` (subprocess spawning) and a home-directory
/// model path, neither of which exists on iOS. The non-macOS stub below keeps the
/// type's surface identical so `TranscriptionService` compiles unchanged and just
/// falls back to Apple Speech off-macOS.
struct WhisperCppTranscriber: Transcribing {
    /// Resolved lazily; checks the common Homebrew locations + a model in
    /// `~/.whisper-models`.
    var isAvailable: Bool {
        Self.resolveExecutable(candidates: Self.whisperCandidates) != nil
            && Self.resolveExecutable(candidates: Self.ffmpegCandidates) != nil
            && Self.resolveModelPath() != nil
    }

    func transcribe(url: URL) async throws -> TranscriptionResult {
        let text = try await Self.run(url: url)
        return TranscriptionResult(text: text, engineUsed: TranscriptionEngine.whisper.displayName)
    }

    private static let whisperCandidates = ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
    private static let ffmpegCandidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]

    private static func run(url: URL) async throws -> String {
        let inputAttrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let inputSize = (inputAttrs?[.size] as? Int) ?? 0
        guard inputSize > 44 else { throw TranscriptionError.emptyRecording }

        guard let whisperBinary = resolveExecutable(candidates: whisperCandidates) else {
            throw TranscriptionError.missingTool("whisper-cli")
        }
        guard let modelPath = resolveModelPath() else {
            throw TranscriptionError.missingTool("~/.whisper-models/ggml-*.bin")
        }

        let inputIsWav = url.pathExtension.lowercased() == "wav"
        let wavURL = inputIsWav ? url : url.deletingPathExtension().appendingPathExtension("wav")
        defer { if !inputIsWav { try? FileManager.default.removeItem(at: wavURL) } }

        if !inputIsWav {
            guard let ffmpeg = resolveExecutable(candidates: ffmpegCandidates) else {
                throw TranscriptionError.missingTool("ffmpeg")
            }
            let conv = runProcess(executable: ffmpeg, arguments: [
                "-y", "-v", "error", "-i", url.path,
                "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", wavURL.path,
            ])
            guard conv.exitCode == 0 else {
                throw TranscriptionError.engineFailed("ffmpeg: \(conv.stderr)")
            }
        }

        let whisper = runProcess(executable: whisperBinary, arguments: [
            "--model", modelPath, "--file", wavURL.path,
            "--no-prints", "--no-timestamps", "--output-txt",
        ])
        guard whisper.exitCode == 0 else {
            throw TranscriptionError.engineFailed("whisper-cli: \(whisper.stderr)")
        }

        let txtURL = URL(fileURLWithPath: wavURL.path + ".txt")
        defer { try? FileManager.default.removeItem(at: txtURL) }
        let text = (try? String(contentsOf: txtURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { throw TranscriptionError.noResult }
        return text
    }

    static func resolveModelPath() -> String? {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".whisper-models")
        let preferred = dir.appendingPathComponent("ggml-base.en.bin")
        if FileManager.default.fileExists(atPath: preferred.path) { return preferred.path }
        // Otherwise any ggml-*.bin in the dir.
        let contents = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return contents.first { $0.lastPathComponent.hasPrefix("ggml-") && $0.pathExtension == "bin" }?.path
    }

    static func resolveExecutable(candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func runProcess(executable: String, arguments: [String]) -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do { try process.run() } catch { return (127, "", error.localizedDescription) }
        process.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, out, err)
    }
}

#else

/// Non-macOS stub: there is no subprocess/CLI path on iOS, so whisper.cpp is never
/// available and `TranscriptionService` transparently falls back to Apple Speech.
/// Same surface as the macOS implementation so callers compile unchanged.
struct WhisperCppTranscriber: Transcribing {
    var isAvailable: Bool { false }

    func transcribe(url: URL) async throws -> TranscriptionResult {
        throw TranscriptionError.missingTool("whisper-cli (unavailable on this platform)")
    }
}

#endif

/// Small helper for reading an audio file's duration (used for note metadata and
/// the "engine unavailable" placeholder text). Cross-platform (AVFoundation).
enum AudioInfo {
    static func duration(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }
}
