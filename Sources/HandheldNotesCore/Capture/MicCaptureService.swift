@preconcurrency import AVFoundation
import Foundation

/// Captures the Mac microphone to a 16 kHz mono WAV. Built on `AVCaptureSession`
/// (not `AVAudioEngine`) so it can record from a *specific* input device — the
/// user's Settings choice — while defaulting to the current system microphone.
///
/// Why `AVCaptureSession`: it supports per-device capture directly via
/// `AVCaptureDeviceInput`, whereas selecting a device on `AVAudioEngine`'s input
/// unit (`kAudioOutputUnitProperty_CurrentDevice`) fails with -10868 on real
/// setups. (Ported from HandheldCompanionMac's AudioCaptureEngine, which learned
/// this the hard way.) One capture stream feeds both the WAV file and the live
/// level meter, so the overlay can never show speech that isn't being recorded.
///
/// The Speech/Capture frameworks don't exist on watchOS; the whole engine is
/// compiled out there (`#if !os(watchOS)`) — the watch has its own recorder and
/// never touches this. On watchOS the stub throws so the package still builds.
#if !os(watchOS)
@MainActor
final class MicCaptureService {
    enum CaptureError: LocalizedError {
        case permissionDenied
        case noInputDevice
        case engineFailed(String)
        case nothingCaptured

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Microphone access is off. Enable it in System Settings ▸ Privacy & Security ▸ Microphone, then try again."
            case .noInputDevice:
                return "No microphone was found. Connect one (or pick a different mic in Settings) and try again."
            case .engineFailed(let m):
                return "Couldn't start the microphone: \(m)"
            case .nothingCaptured:
                return "No audio was captured — the recording was empty."
            }
        }
    }

    /// The device name to record from — `nil` follows the current system default.
    /// Set by `AppModel` from `settings.microphoneName` before each `start()`.
    var preferredMicrophoneName: String?

    private var session: AVCaptureSession?
    private var sink: RecordingSink?
    private var currentURL: URL?
    private(set) var isRecording = false
    private let captureQueue = DispatchQueue(label: "com.mohammadshobaki.ollie.AudioCapture")

    /// Live input level 0…1 for the UI meter. The capture queue publishes into the
    /// sink; the UI reads this via `level` on the main thread.
    var level: Float { sink?.level ?? 0 }

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
            }
        default:
            return false
        }
    }

    /// All selectable input devices, by display name (for the Settings picker).
    nonisolated static func availableInputDevices() -> [String] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone], mediaType: .audio, position: .unspecified
        ).devices.map(\.localizedName)
    }

    /// Resolve the configured name to a device; nil if the name doesn't match one.
    nonisolated private static func device(named name: String) -> AVCaptureDevice? {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices
        if let exact = devices.first(where: { $0.localizedName == name }) { return exact }
        return devices.first {
            name.localizedCaseInsensitiveContains($0.localizedName)
                || $0.localizedName.localizedCaseInsensitiveContains(name)
        }
    }

    /// Start recording into a fresh temp WAV from the preferred (or default) mic.
    func start() async throws -> URL {
        guard !isRecording else { throw CaptureError.engineFailed("already recording") }
        guard await Self.requestPermission() else { throw CaptureError.permissionDenied }

        // Preferred device if named + present; otherwise the current system default.
        let device = preferredMicrophoneName.flatMap { Self.device(named: $0) }
            ?? AVCaptureDevice.default(for: .audio)
        guard let device else { throw CaptureError.noInputDevice }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hn-capture-\(UUID().uuidString).wav")

        let sink: RecordingSink
        do {
            sink = try RecordingSink(url: url)
        } catch {
            throw CaptureError.engineFailed(error.localizedDescription)
        }

        let session = AVCaptureSession()
        do {
            session.beginConfiguration()
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                throw CaptureError.engineFailed("the microphone could not be attached (it may be in exclusive use).")
            }
            session.addInput(input)
            let output = AVCaptureAudioDataOutput()
            output.setSampleBufferDelegate(sink, queue: captureQueue)
            guard session.canAddOutput(output) else {
                throw CaptureError.engineFailed("audio output could not be attached.")
            }
            session.addOutput(output)
            session.commitConfiguration()
        } catch let e as CaptureError {
            sink.close(); try? FileManager.default.removeItem(at: url)
            throw e
        } catch {
            sink.close(); try? FileManager.default.removeItem(at: url)
            throw CaptureError.engineFailed(error.localizedDescription)
        }

        // startRunning() blocks tens of ms — do it off the main actor so
        // push-to-talk stays snappy. (The session is handed to its own serial
        // queue and never touched concurrently.)
        let box = UncheckedSendableBox(session)
        captureQueue.async { box.value.startRunning() }

        self.session = session
        self.sink = sink
        self.currentURL = url
        isRecording = true
        return url
    }

    /// Stop recording and return the finished WAV. Throws if nothing was captured.
    func stop() throws -> URL {
        guard isRecording, let url = currentURL, let sink else {
            throw CaptureError.nothingCaptured
        }
        teardown()
        let frames = sink.close()
        self.sink = nil
        currentURL = nil

        if frames < 800 {   // < ~0.05s of 16 kHz audio → device produced nothing
            try? FileManager.default.removeItem(at: url)
            throw CaptureError.nothingCaptured
        }
        return url
    }

    func cancel() {
        guard isRecording else { return }
        teardown()
        sink?.close()
        sink = nil
        let url = currentURL
        currentURL = nil
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    private func teardown() {
        sink?.detach()
        if let session, session.isRunning { session.stopRunning() }
        session = nil
        isRecording = false
    }
}

/// Receives capture sample buffers on the capture queue, converts each to 16 kHz
/// mono int16 WAV, and reports the level. NOT actor-isolated — delegate callbacks
/// arrive on the capture queue and must never assert main-actor isolation.
private final class RecordingSink: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let file: AVAudioFile
    private let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var framesWritten: Int64 = 0
    private var attached = true
    private var _level: Float = 0

    var level: Float {
        lock.lock(); defer { lock.unlock() }
        return _level
    }

    init(url: URL) throws {
        // On-disk format: 16 kHz mono int16 WAV (what Apple Speech wants).
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings,
                               commonFormat: .pcmFormatInt16, interleaved: true)
        outputFormat = file.processingFormat
    }

    /// Stop forwarding buffers (a buffer already in flight may still land; writes
    /// are guarded by `attached`).
    func detach() {
        lock.lock(); attached = false; lock.unlock()
    }

    /// Flush + close; returns the frame count written (0 on a dead device).
    @discardableResult
    func close() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        attached = false
        _level = 0
        if #available(macOS 15, iOS 18, *) { file.close() }
        return framesWritten
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }
        let rms = Self.rmsLevel(of: pcm)

        lock.lock()
        defer { lock.unlock() }
        guard attached else { return }
        _level = rms

        if converter == nil || converter?.inputFormat != pcm.format {
            converter = AVAudioConverter(from: pcm.format, to: outputFormat)
        }
        guard let converter else { return }
        let ratio = outputFormat.sampleRate / pcm.format.sampleRate
        let capacity = AVAudioFrameCount(Double(pcm.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        let feed = SingleBufferFeed(pcm)
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            guard let next = feed.take() else { status.pointee = .noDataNow; return nil }
            status.pointee = .haveData
            return next
        }
        if err == nil, out.frameLength > 0 {
            try? file.write(from: out)
            framesWritten += Int64(out.frameLength)
        }
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0,
              let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
              let format = AVAudioFormat(streamDescription: asbd),
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return nil }
        pcm.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        return status == noErr ? pcm : nil
    }

    private static func rmsLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let samples = channelData[0]
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
        let rms = sqrt(sum / Float(buffer.frameLength))
        return min(1, rms * 6)
    }
}

/// Hands exactly one buffer to an `AVAudioConverter` input block (synchronous;
/// wrapper exists only to satisfy strict concurrency).
private final class SingleBufferFeed: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? { defer { buffer = nil }; return buffer }
}

/// Wraps a non-Sendable value whose cross-thread use is externally synchronized
/// (the session handed to its own serial capture queue).
private final class UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

#else   // watchOS stub — the watch never records via this service.
@MainActor
final class MicCaptureService {
    enum CaptureError: LocalizedError {
        case permissionDenied, noInputDevice, engineFailed(String), nothingCaptured
        var errorDescription: String? { "Microphone capture isn't available here." }
    }
    var preferredMicrophoneName: String?
    private(set) var isRecording = false
    var level: Float { 0 }
    static func requestPermission() async -> Bool { false }
    nonisolated static func availableInputDevices() -> [String] { [] }
    func start() async throws -> URL { throw CaptureError.noInputDevice }
    func stop() throws -> URL { throw CaptureError.nothingCaptured }
    func cancel() {}
}
#endif
