import AVFoundation
import Foundation
import Speech

/// On-device speech-to-text via Apple's frameworks. Adapted from the old app's
/// AppleSpeechTranscriptionRunner.
///
/// macOS 26+ / iOS 26+ use the new `SpeechAnalyzer` + `Speech.SpeechTranscriber`
/// stack; the file-based path needs no Speech-Recognition TCC authorization. Older
/// systems fall back to `SFSpeechRecognizer` pinned to on-device recognition.
struct AppleSpeechTranscriber: Transcribing {
    func transcribe(url: URL) async throws -> TranscriptionResult {
        let inputAttrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let inputSize = (inputAttrs?[.size] as? Int) ?? 0
        guard inputSize > 44 else { throw TranscriptionError.emptyRecording }

        let text: String
        if #available(macOS 26, iOS 26, *) {
            text = try await Self.transcribeWithSpeechAnalyzer(url: url)
        } else {
            text = try await Self.transcribeWithSFSpeechRecognizer(url: url)
        }
        return TranscriptionResult(text: text, engineUsed: TranscriptionEngine.appleSpeech.displayName)
    }

    // MARK: - macOS 26+: SpeechAnalyzer

    @available(macOS 26, iOS 26, *)
    private static func transcribeWithSpeechAnalyzer(url: URL) async throws -> String {
        guard Speech.SpeechTranscriber.isAvailable else {
            throw TranscriptionError.appleSpeechUnavailable("this Mac does not support on-device transcription.")
        }
        guard let locale = await bestSupportedLocale() else {
            throw TranscriptionError.appleSpeechUnavailable("no supported Apple Speech locale found.")
        }

        let transcriber = Speech.SpeechTranscriber(locale: locale, preset: .transcription)
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installation.downloadAndInstall()
        }

        let audioFile = try AVAudioFile(forReading: url)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        async let collected: String = collectFinalText(from: transcriber)
        do {
            if let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: lastSampleTime)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            let text = try await collected.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw TranscriptionError.noResult }
            return text
        } catch let e as TranscriptionError {
            await analyzer.cancelAndFinishNow()
            throw e
        } catch {
            await analyzer.cancelAndFinishNow()
            throw TranscriptionError.engineFailed(error.localizedDescription)
        }
    }

    @available(macOS 26, iOS 26, *)
    private static func bestSupportedLocale() async -> Locale? {
        if let match = await Speech.SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) {
            return match
        }
        if let english = await Speech.SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_US")) {
            return english
        }
        return await Speech.SpeechTranscriber.supportedLocales.first
    }

    @available(macOS 26, iOS 26, *)
    private static func collectFinalText(from transcriber: Speech.SpeechTranscriber) async throws -> String {
        var text = ""
        for try await result in transcriber.results where result.isFinal {
            let piece = String(result.text.characters)
            if let last = text.last, !last.isWhitespace,
               let first = piece.first, !first.isWhitespace {
                text += " "
            }
            text += piece
        }
        return text
    }

    // MARK: - macOS 14/15: SFSpeechRecognizer (on-device only)

    private static func transcribeWithSFSpeechRecognizer(url: URL) async throws -> String {
        let status = await requestSpeechAuthorization()
        guard status == .authorized else {
            throw TranscriptionError.appleSpeechUnavailable("speech-recognition permission was not granted.")
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else {
            throw TranscriptionError.appleSpeechUnavailable("speech recognition is not available on this Mac.")
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw TranscriptionError.appleSpeechUnavailable("this Mac has no on-device speech model.")
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.taskHint = .dictation

        let resumeOnce = ResumeOnce<String>()
        return try await withCheckedThrowingContinuation { continuation in
            resumeOnce.store(continuation)
            recognizer.recognitionTask(with: request) { result, error in
                _ = recognizer
                if let result, result.isFinal {
                    resumeOnce.resume(.success(result.bestTranscription.formattedString))
                } else if let error {
                    resumeOnce.resume(.failure(TranscriptionError.engineFailed(error.localizedDescription)))
                }
            }
        }
    }

    private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .notDetermined else { return status }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }
}

/// Guards a checked continuation so a handler that can fire more than once only
/// resumes it a single time.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    func store(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock(); self.continuation = continuation; lock.unlock()
    }

    func resume(_ result: Result<T, Error>) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(with: result)
    }
}
