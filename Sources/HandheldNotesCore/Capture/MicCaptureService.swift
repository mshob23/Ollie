@preconcurrency import AVFoundation
import Foundation

/// Captures the Mac microphone to a 16 kHz mono WAV using AVAudioEngine — the
/// format whisper.cpp and Apple Speech both want. Unlike the old app (which
/// shells out to ffmpeg for capture), this uses the native engine so Computer
/// mode has no external-binary dependency and fails with a clear message rather
/// than a missing-file error if the mic isn't available or permitted.
///
/// Concurrency: the audio render tap runs on a realtime thread, so the buffer
/// processing (file write + level RMS) is owned by a `nonisolated` `RecordingSink`
/// that the tap drives directly. The `@MainActor` service is only the controller
/// (start/stop/cancel) and never touches the tap's state while it's running.
@MainActor
final class MicCaptureService {
    enum CaptureError: LocalizedError {
        case permissionDenied
        case engineFailed(String)
        case nothingCaptured

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Microphone access is off. Enable it in System Settings ▸ Privacy & Security ▸ Microphone, then try again."
            case .engineFailed(let m):
                return "Couldn't start the microphone: \(m)"
            case .nothingCaptured:
                return "No audio was captured — the recording was empty."
            }
        }
    }

    private let engine = AVAudioEngine()
    private var sink: RecordingSink?
    private var currentURL: URL?
    private(set) var isRecording = false

    /// Live input level 0…1 for the UI meter. The audio thread publishes into the
    /// sink; the UI reads this via `level` on the main thread.
    var level: Float { sink?.level ?? 0 }

    static func requestPermission() async -> Bool {
        // `AVCaptureDevice` is the macOS/iOS capture-permission door and doesn't exist
        // on watchOS. This Mac-side capture service never runs on the watch (the watch
        // has its own recorder), but the package still compiles for the watchOS SDK
        // because it's in the watch app's project graph — so stub the permission there.
        #if os(watchOS)
        return false
        #else
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
            }
        default:
            return false
        }
        #endif
    }

    /// Start recording into a fresh temp WAV. Returns the URL being written.
    func start() async throws -> URL {
        guard !isRecording else { throw CaptureError.engineFailed("already recording") }
        guard await Self.requestPermission() else { throw CaptureError.permissionDenied }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)
        else { throw CaptureError.engineFailed("could not build 16 kHz mono format") }

        let tmpDir = FileManager.default.temporaryDirectory
        let url = tmpDir.appendingPathComponent("hn-capture-\(UUID().uuidString).wav")
        currentURL = url

        let sink: RecordingSink
        do {
            sink = try RecordingSink(url: url, inputFormat: inputFormat, targetFormat: target)
        } catch {
            throw CaptureError.engineFailed(error.localizedDescription)
        }
        self.sink = sink

        // The tap fires on a realtime audio thread. Mark the block @Sendable so it is
        // NOT inferred as @MainActor — it's written inside this @MainActor method, and an
        // inherited main-actor isolation makes Swift 6 TRAP (EXC_BREAKPOINT in
        // swift_task_checkIsolated) the instant AVAudioEngine invokes it off the main
        // thread. @Sendable keeps it nonisolated; it only touches the Sendable sink.
        inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { @Sendable buffer, _ in
            sink.consume(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            self.sink = nil
            throw CaptureError.engineFailed(error.localizedDescription)
        }
        isRecording = true
        return url
    }

    /// Stop recording and return the finished WAV. Throws if nothing was captured.
    func stop() throws -> URL {
        guard isRecording, let url = currentURL else { throw CaptureError.nothingCaptured }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        sink?.close()
        sink = nil
        currentURL = nil

        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size <= 44 {
            try? FileManager.default.removeItem(at: url)
            throw CaptureError.nothingCaptured
        }
        return url
    }

    func cancel() {
        guard isRecording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        sink?.close()
        sink = nil
        let url = currentURL
        currentURL = nil
        if let url { try? FileManager.default.removeItem(at: url) }
    }
}

/// Owns everything the audio render thread touches: the output file, the
/// converter, and the published level. `@unchecked Sendable` because the engine
/// guarantees the tap block is not called concurrently with itself, and the
/// controller never touches this object's mutable state while the tap is live
/// (start installs it, stop/cancel remove the tap *before* closing it).
private final class RecordingSink: @unchecked Sendable {
    private let outputFile: AVAudioFile
    private let converter: AVAudioConverter
    private let targetFormat: AVAudioFormat
    private let levelLock = NSLock()
    private var _level: Float = 0

    var level: Float {
        levelLock.lock(); defer { levelLock.unlock() }
        return _level
    }

    init(url: URL, inputFormat: AVAudioFormat, targetFormat: AVAudioFormat) throws {
        // On-disk format: 16 kHz mono int16 WAV (what whisper.cpp / Apple Speech want).
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        self.outputFile = file
        // CRITICAL: write buffers in the file's OWN `processingFormat`, not a hand-built
        // int16 format. `AVAudioFile(forWriting:settings:)` processes audio in a canonical
        // (float, deinterleaved) format and converts to the on-disk int16 itself — handing
        // its writer an int16 buffer trips a fatal CoreAudio assertion (CAAssertRtn inside
        // ExtAudioFileWrite) and aborts the process. So target the processing format; the
        // file still STORES 16 kHz mono int16 per `settings` above.
        let processing = file.processingFormat
        guard let conv = AVAudioConverter(from: inputFormat, to: processing) else {
            throw NSError(domain: "RecordingSink", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "could not build audio converter"])
        }
        self.converter = conv
        self.targetFormat = processing
    }

    func consume(_ buffer: AVAudioPCMBuffer) {
        // RMS level for the meter.
        if let channelData = buffer.floatChannelData {
            let frames = Int(buffer.frameLength)
            var sum: Float = 0
            let samples = channelData[0]
            for i in 0..<frames { sum += samples[i] * samples[i] }
            let rms = frames > 0 ? sqrt(sum / Float(frames)) : 0
            let normalized = min(1, rms * 6)
            levelLock.lock(); _level = normalized; levelLock.unlock()
        }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        let box = InputBox(buffer: buffer)
        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error) { _, inputStatus in
            box.next(inputStatus)
        }
        if status == .error { return }
        if outBuffer.frameLength > 0 {
            try? outputFile.write(from: outBuffer)
        }
    }

    func close() {
        levelLock.lock(); _level = 0; levelLock.unlock()
        // Dropping the AVAudioFile flushes its bytes; nothing else to do.
    }

    /// Hands the single available input buffer to the converter exactly once.
    /// `@unchecked Sendable`: `AVAudioConverter.convert`'s input block is typed
    /// `@Sendable` but is invoked synchronously on this same thread, so the
    /// single-use buffer never actually escapes or races.
    private final class InputBox: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?
        init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            guard let b = buffer else { status.pointee = .noDataNow; return nil }
            buffer = nil
            status.pointee = .haveData
            return b
        }
    }
}
