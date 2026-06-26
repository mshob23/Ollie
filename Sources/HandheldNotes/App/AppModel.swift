import AVFoundation
import Combine
import Foundation
import SwiftUI

/// App-wide settings persisted as JSON next to the notes.
struct NotesSettings: Codable, Equatable, Sendable {
    var transcriptionEngineID: String = TranscriptionEngine.appleSpeech.rawValue
    var hasSeededDemo: Bool = false

    var engine: TranscriptionEngine {
        TranscriptionEngine(rawValue: transcriptionEngineID) ?? .appleSpeech
    }

    static func load() -> NotesSettings {
        guard let url = try? Self.url(), let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(NotesSettings.self, from: data) else {
            return NotesSettings()
        }
        return s
    }

    func save() {
        guard let url = try? Self.url() else { return }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(self).write(to: url, options: [.atomic])
    }

    private static func url() throws -> URL {
        try NotesStore.baseDirectory().appendingPathComponent("settings.json")
    }
}

/// What kind of capture is currently happening, for the capture bar UI.
enum RecordingState: Equatable {
    case idle
    case recording          // mic is live (Computer mode)
    case transcribing       // a capture is being turned into a note
    case error(String)
}

/// The single source of truth the SwiftUI views observe. Owns the store, the
/// services, and the app's mutable state. Everything the UI triggers funnels
/// through here.
@MainActor
final class AppModel: ObservableObject {

    // Notes + selection + search.
    @Published var notes: [Note] = []
    @Published var selectedNoteID: Note.ID?
    @Published var searchText: String = ""

    // Capture state.
    @Published var recordingState: RecordingState = .idle
    @Published var micLevel: Float = 0

    // Device sync state + log.
    @Published var syncState: DeviceSyncState = .idle
    @Published var deviceFiles: [DeviceFile] = []
    @Published var syncLog: [String] = []

    // Settings.
    @Published var settings: NotesSettings {
        didSet {
            if oldValue != settings { settings.save() }
            if oldValue.transcriptionEngineID != settings.transcriptionEngineID {
                rebuildPipeline()
            }
        }
    }

    // Banner for transient, non-fatal messages (permission denied, etc.).
    @Published var banner: String?

    // Services.
    private let mic = MicCaptureService()
    private var hotKey: HotKeyManager?
    private(set) var deviceSync: DeviceSyncService
    private var pipeline: NotesPipeline
    private var micLevelTimer: Timer?
    private var captureURL: URL?

    init() {
        let loaded = NotesSettings.load()
        self.settings = loaded
        self.pipeline = NotesPipeline(engine: loaded.engine)
        self.deviceSync = MockDeviceSyncService()

        self.notes = NotesStore.load()
        seedDemoNotesIfNeeded()
        if selectedNoteID == nil { selectedNoteID = filteredNotes.first?.id }

        wireDeviceSync()
        registerHotKey()
    }

    // MARK: Derived

    var filteredNotes: [Note] {
        let sorted = notes.sorted { $0.createdAt > $1.createdAt }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return sorted }
        return sorted.filter {
            $0.title.lowercased().contains(q) || $0.transcript.lowercased().contains(q)
        }
    }

    var selectedNote: Note? {
        guard let id = selectedNoteID else { return nil }
        return notes.first { $0.id == id }
    }

    var isRecording: Bool {
        if case .recording = recordingState { return true }
        return false
    }

    // MARK: Notes CRUD

    func updateTitle(_ title: String, for id: Note.ID) {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        notes[idx].title = trimmed.isEmpty ? notes[idx].title : trimmed
        notes[idx].updatedAt = Date()
        persist()
    }

    func updateTranscript(_ transcript: String, for id: Note.ID) {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[idx].transcript = transcript
        notes[idx].updatedAt = Date()
        persist()
    }

    func toggleFavorite(_ id: Note.ID) {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[idx].isFavorite.toggle()
        notes[idx].updatedAt = Date()
        persist()
    }

    func delete(_ id: Note.ID) {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        if let audio = notes[idx].audioFileName { NotesStore.deleteAudio(named: audio) }
        notes.remove(at: idx)
        if selectedNoteID == id { selectedNoteID = filteredNotes.first?.id }
        persist()
    }

    private func persist() { NotesStore.save(notes) }

    private func insert(_ note: Note, select: Bool) {
        notes.insert(note, at: 0)
        persist()
        if select { selectedNoteID = note.id }
    }

    // MARK: Computer mode (F16 push-to-talk + manual record button)

    func toggleRecording() {
        if isRecording { Task { await stopRecordingAndTranscribe() } }
        else { Task { await startRecording() } }
    }

    func startRecording() async {
        guard !isRecording else { return }
        do {
            captureURL = try await mic.start()
            recordingState = .recording
            startMicLevelPolling()
        } catch {
            banner = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            recordingState = .error(banner ?? "recording failed")
        }
    }

    func stopRecordingAndTranscribe() async {
        guard isRecording else { return }
        stopMicLevelPolling()
        let url: URL
        do {
            url = try mic.stop()
        } catch {
            recordingState = .idle
            banner = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return
        }
        await ingest(url: url, source: .computer, cleanupSource: true)
    }

    func cancelRecording() {
        guard isRecording else { return }
        stopMicLevelPolling()
        mic.cancel()
        recordingState = .idle
    }

    // MARK: Device sync (mock by default)

    func startDeviceSync() {
        syncLog.removeAll()
        deviceSync.startSync()
    }

    func stopDeviceSync() {
        deviceSync.stop()
    }

    private func wireDeviceSync() {
        deviceSync.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .stateChanged(let state):
                self.syncState = state
            case .fileListUpdated(let files):
                self.deviceFiles = files
            case .log(let line):
                self.appendLog(line)
            case .fileReceived(let fileId, let url, let source):
                Task { @MainActor in
                    let note = await self.ingest(url: url, source: source, cleanupSource: false)
                    if note != nil {
                        // Confirm the save so the (mock) device can free the slot.
                        self.deviceSync.confirmSaved(fileId: fileId)
                    }
                }
            }
        }
    }

    private func appendLog(_ line: String) {
        syncLog.append(line)
        if syncLog.count > 200 { syncLog.removeFirst(syncLog.count - 200) }
    }

    // MARK: Shared ingest

    @discardableResult
    private func ingest(url: URL, source: NoteSource, cleanupSource: Bool) async -> Note? {
        recordingState = .transcribing
        defer {
            if cleanupSource { try? FileManager.default.removeItem(at: url) }
        }
        do {
            let note = try await pipeline.ingest(audioURL: url, source: source)
            insert(note, select: source == .computer) // jump to mic notes; leave selection during a device batch
            if source != .computer, selectedNoteID == nil { selectedNoteID = note.id }
            recordingState = .idle
            return note
        } catch {
            recordingState = .idle
            banner = "Couldn't save note: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            return nil
        }
    }

    // MARK: Hotkey

    private func registerHotKey() {
        // Press = start recording, release = stop + transcribe (push-to-talk).
        hotKey = HotKeyManager { [weak self] pressed in
            guard let self else { return }
            Task { @MainActor in
                if pressed { await self.startRecording() }
                else { await self.stopRecordingAndTranscribe() }
            }
        }
        _ = hotKey?.register()
    }

    // MARK: Pipeline rebuild on engine change

    private func rebuildPipeline() {
        pipeline = NotesPipeline(engine: settings.engine)
    }

    // MARK: Mic level polling

    private func startMicLevelPolling() {
        micLevelTimer?.invalidate()
        micLevelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.micLevel = self?.mic.level ?? 0 }
        }
    }

    private func stopMicLevelPolling() {
        micLevelTimer?.invalidate()
        micLevelTimer = nil
        micLevel = 0
    }

    // MARK: Audio URL passthrough for the UI player

    func audioURL(for note: Note) -> URL? { NotesStore.audioURL(for: note) }

    // MARK: Demo seeding

    private func seedDemoNotesIfNeeded() {
        guard !settings.hasSeededDemo, notes.isEmpty else { return }
        notes = DemoSeed.makeNotes()
        persist()
        settings.hasSeededDemo = true
        settings.save()
    }
}
