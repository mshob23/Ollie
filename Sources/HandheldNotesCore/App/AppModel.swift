import AVFoundation
import Combine
import Foundation
import SwiftUI

/// Drives the global push-to-talk hotkey (press → record, release → stop). The
/// concrete implementation is platform-specific (macOS uses Carbon, which lives
/// in the app target), so `AppModel` depends only on this protocol and the app
/// injects a factory. iOS has no global hotkey, so it simply passes `nil`.
///
/// `@MainActor` because the only implementation (macOS Carbon `HotKeyManager`)
/// touches main-thread state, and `AppModel` (also `@MainActor`) owns it.
@MainActor
public protocol PushToTalkController: AnyObject {
    /// Begin listening for the hotkey. Returns whether the primary registration
    /// succeeded (a fallback path may still cover it). Safe to ignore.
    @discardableResult
    func register() -> Bool
}

/// App-wide settings persisted as JSON next to the notes.
public struct NotesSettings: Codable, Equatable, Sendable {
    public var transcriptionEngineID: String = TranscriptionEngine.appleSpeech.rawValue
    public var hasSeededDemo: Bool = false

    /// Manual vs. Automatic mode selection (see `ModeSelection`).
    public var modeSelectionID: String = ModeSelection.manual.rawValue
    /// The user's explicit Computer/Local choice, honored when `modeSelection`
    /// is `.manual`.
    public var manualModeID: String = CaptureMode.computer.rawValue

    public var engine: TranscriptionEngine {
        TranscriptionEngine(rawValue: transcriptionEngineID) ?? .appleSpeech
    }
    public var modeSelection: ModeSelection {
        ModeSelection(rawValue: modeSelectionID) ?? .manual
    }
    public var manualMode: CaptureMode {
        CaptureMode(rawValue: manualModeID) ?? .computer
    }

    public init() {}

    /// Tolerant decode so an older settings.json (missing the new mode keys) still
    /// loads, keeping the existing engine choice and seed flag.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fresh = NotesSettings()
        transcriptionEngineID = try c.decodeIfPresent(String.self, forKey: .transcriptionEngineID) ?? fresh.transcriptionEngineID
        hasSeededDemo = try c.decodeIfPresent(Bool.self, forKey: .hasSeededDemo) ?? fresh.hasSeededDemo
        modeSelectionID = try c.decodeIfPresent(String.self, forKey: .modeSelectionID) ?? fresh.modeSelectionID
        manualModeID = try c.decodeIfPresent(String.self, forKey: .manualModeID) ?? fresh.manualModeID
    }

    public static func load() -> NotesSettings {
        guard let url = try? Self.url(), let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(NotesSettings.self, from: data) else {
            return NotesSettings()
        }
        return s
    }

    public func save() {
        guard let url = try? Self.url() else { return }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(self).write(to: url, options: [.atomic])
    }

    private static func url() throws -> URL {
        try NotesStore.baseDirectory().appendingPathComponent("settings.json")
    }
}

/// What kind of capture is currently happening, for the capture bar UI.
public enum RecordingState: Equatable {
    case idle
    case recording          // mic is live (Computer mode)
    case transcribing       // a capture is being turned into a note
    case error(String)
}

/// The single source of truth the SwiftUI views observe. Owns the store, the
/// services, and the app's mutable state. Everything the UI triggers funnels
/// through here.
@MainActor
public final class AppModel: ObservableObject {

    // Notes + selection + search.
    @Published public var notes: [Note] = []
    @Published public var selectedNoteID: Note.ID?
    @Published public var searchText: String = ""

    // Capture state.
    @Published public var recordingState: RecordingState = .idle
    @Published public var micLevel: Float = 0

    // The active in-progress draft (Computer / live mode). Accumulates appended
    // speech + edits until the user explicitly concludes it into a saved note.
    @Published public var draft = Draft()

    // Simulated handheld connectivity. With the mock service there's no radio, so
    // this stands in for "device in range." In Automatic mode it decides the mode
    // (connected → Computer, out of range → Local); the user toggles it to watch
    // Auto flip. Persisted? No — it's runtime/session state.
    @Published public var simulatedDeviceConnected: Bool = true

    // Device sync state + log.
    @Published public var syncState: DeviceSyncState = .idle
    @Published public var deviceFiles: [DeviceFile] = []
    @Published public var syncLog: [String] = []

    // Settings.
    @Published public var settings: NotesSettings {
        didSet {
            if oldValue != settings { settings.save() }
            if oldValue.transcriptionEngineID != settings.transcriptionEngineID {
                rebuildPipeline()
            }
        }
    }

    // Banner for transient, non-fatal messages (permission denied, etc.).
    @Published public var banner: String?

    // Services.
    private let mic = MicCaptureService()
    private var hotKey: PushToTalkController?
    private let pushToTalkFactory: ((@escaping @MainActor (Bool) -> Void) -> PushToTalkController)?
    public private(set) var deviceSync: DeviceSyncService
    private var pipeline: NotesPipeline
    private var micLevelTimer: Timer?
    private var captureURL: URL?

    /// - Parameters:
    ///   - deviceSync: the sync backend (defaults to the mock; the app can pass a
    ///     real `BLEDeviceSyncService`).
    ///   - pushToTalk: factory that builds the platform hotkey controller from a
    ///     press/release handler. Pass `nil` on platforms with no global hotkey
    ///     (e.g. iOS); the macOS app injects one wrapping its Carbon `HotKeyManager`.
    public init(
        deviceSync: DeviceSyncService? = nil,
        pushToTalk: ((@escaping @MainActor (Bool) -> Void) -> PushToTalkController)? = nil
    ) {
        let loaded = NotesSettings.load()
        self.settings = loaded
        self.pipeline = NotesPipeline(engine: loaded.engine)
        self.deviceSync = deviceSync ?? MockDeviceSyncService()
        self.pushToTalkFactory = pushToTalk

        self.notes = NotesStore.load()
        seedDemoNotesIfNeeded()
        if selectedNoteID == nil { selectedNoteID = filteredNotes.first?.id }

        wireDeviceSync()
        registerHotKey()
    }

    // MARK: Derived

    public var filteredNotes: [Note] {
        let sorted = notes.sorted { $0.createdAt > $1.createdAt }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return sorted }
        return sorted.filter {
            $0.title.lowercased().contains(q) || $0.transcript.lowercased().contains(q)
        }
    }

    public var selectedNote: Note? {
        guard let id = selectedNoteID else { return nil }
        return notes.first { $0.id == id }
    }

    public var isRecording: Bool {
        if case .recording = recordingState { return true }
        return false
    }

    public var isTranscribing: Bool {
        if case .transcribing = recordingState { return true }
        return false
    }

    // MARK: Mode

    /// The capture mode in effect right now. In Manual it's the user's explicit
    /// choice; in Automatic it follows simulated device connectivity (connected →
    /// Computer live transcribe, out of range → Local store-and-sync).
    public var activeMode: CaptureMode {
        switch settings.modeSelection {
        case .manual:    return settings.manualMode
        case .automatic: return simulatedDeviceConnected ? .computer : .local
        }
    }

    /// True when the active mode was chosen automatically (for the UI badge).
    public var modeIsAutomatic: Bool { settings.modeSelection == .automatic }

    /// Manual-mode toggle between Computer and Local.
    public func setManualMode(_ mode: CaptureMode) {
        settings.manualModeID = mode.rawValue
    }

    /// Flip simulated connectivity (Automatic mode). Coming back *into* range is
    /// the moment the handheld hands over anything it recorded offline, so we kick
    /// off a device sync — finished notes drop straight into the list.
    public func setSimulatedConnected(_ connected: Bool) {
        let wasConnected = simulatedDeviceConnected
        simulatedDeviceConnected = connected
        if connected && !wasConnected && settings.modeSelection == .automatic {
            startDeviceSync()
        }
    }

    // MARK: Notes CRUD

    public func updateTitle(_ title: String, for id: Note.ID) {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        notes[idx].title = trimmed.isEmpty ? notes[idx].title : trimmed
        notes[idx].updatedAt = Date()
        persist()
    }

    public func updateTranscript(_ transcript: String, for id: Note.ID) {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[idx].transcript = transcript
        notes[idx].updatedAt = Date()
        persist()
    }

    public func toggleFavorite(_ id: Note.ID) {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[idx].isFavorite.toggle()
        notes[idx].updatedAt = Date()
        persist()
    }

    public func delete(_ id: Note.ID) {
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

    // MARK: Computer / live mode — record APPENDS to the active draft
    //
    // A recording no longer creates a note. Hold-to-talk transcribes and *appends*
    // the speech to `draft`; the draft is only finalized on an explicit conclude.

    public func toggleRecording() {
        if isRecording { Task { await stopRecordingAndAppend() } }
        else { Task { await startRecording() } }
    }

    public func startRecording() async {
        guard !isRecording, !isTranscribing else { return }
        // Live capture only makes sense in Computer mode. In Local mode the device
        // is doing the recording; ignore the Mac mic.
        guard activeMode == .computer else {
            banner = "Local mode is active — the handheld records offline. Switch to Computer mode to dictate here."
            return
        }
        do {
            captureURL = try await mic.start()
            recordingState = .recording
            startMicLevelPolling()
        } catch {
            banner = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            recordingState = .error(banner ?? "recording failed")
        }
    }

    /// Stop the mic, transcribe, and APPEND the result to the active draft.
    public func stopRecordingAndAppend() async {
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
        recordingState = .transcribing
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let clip = try await pipeline.transcribeClip(audioURL: url, noteID: draft.id)
            draft.appendSpeech(clip.text)
            // Keep the most recent recording with the draft so the concluded note
            // has playable audio + an engine/duration to show.
            draft.audioFileName = clip.storedAudioName
            draft.durationSeconds = clip.durationSeconds
            draft.engineUsed = clip.engineUsed
            recordingState = .idle
        } catch {
            recordingState = .idle
            banner = "Couldn't transcribe: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    public func cancelRecording() {
        guard isRecording else { return }
        stopMicLevelPolling()
        mic.cancel()
        recordingState = .idle
    }

    // MARK: Draft editing (mirrors the device's RIGHT / BOTTOM buttons)

    public func draftSpace()    { draft.typeSpace() }
    public func draftNewline()  { draft.typeNewline() }
    public func draftBackspace(){ draft.backspace() }

    /// Direct-edit binding target for the draft transcript (typing in the field).
    public func setDraftTranscript(_ text: String) { draft.transcript = text }

    /// Explicitly conclude the active draft (device double-tap-middle = Enter, or
    /// the Send button / ⌘↩). Finalizes it into the saved list and starts a fresh
    /// empty draft.
    ///
    /// Concluding a truly empty / whitespace-only draft must be a **no-op** — it
    /// must never produce a saved note (this is the guard that keeps stray
    /// "new note"-style empty entries out of the list). `Draft.isEmpty` already
    /// trims whitespace/newlines, so a draft holding only spaces, newlines, or the
    /// products of the Space/Newline/Backspace edit keys counts as empty and is
    /// dropped here. If such an empty draft is dropped, any audio it happened to
    /// retain is cleaned up so it can't orphan a file.
    public func concludeDraft() {
        guard !draft.isEmpty else {
            // Empty/whitespace conclude: reset to a clean draft, save nothing.
            clearDraft()
            return
        }
        let note = draft.makeNote()
        insert(note, select: true)
        draft = Draft()
    }

    /// Discard the active draft without saving (and drop its retained audio).
    public func clearDraft() {
        if let audio = draft.audioFileName { NotesStore.deleteAudio(named: audio) }
        draft = Draft()
    }

    // MARK: Device sync (mock by default)

    public func startDeviceSync() {
        syncLog.removeAll()
        deviceSync.startSync()
    }

    public func stopDeviceSync() {
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
                        // Confirm the save so the device can free the slot.
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

    // MARK: Device/Local ingest — recordings arrive ALREADY concluded
    //
    // Local-mode files were composed and concluded on the device, so they drop
    // straight into the saved list as finished notes (no Mac-side drafting). This
    // deliberately does NOT touch `recordingState`/`draft` — the Computer-mode
    // capture area is independent of a background device sync.

    @discardableResult
    private func ingest(url: URL, source: NoteSource, cleanupSource: Bool) async -> Note? {
        defer {
            if cleanupSource { try? FileManager.default.removeItem(at: url) }
        }
        do {
            let note = try await pipeline.ingest(audioURL: url, source: source)
            insert(note, select: false) // don't yank selection during a device batch
            if selectedNoteID == nil { selectedNoteID = note.id }
            return note
        } catch {
            banner = "Couldn't save note: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            return nil
        }
    }

    // MARK: Hotkey

    private func registerHotKey() {
        // Press = start recording, release = stop + transcribe (push-to-talk).
        // No factory (e.g. iOS) → no global hotkey; the UI record button still works.
        guard let pushToTalkFactory else { return }
        hotKey = pushToTalkFactory { [weak self] pressed in
            guard let self else { return }
            if pressed { Task { await self.startRecording() } }
            else { Task { await self.stopRecordingAndAppend() } }
        }
        hotKey?.register()
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

    public func audioURL(for note: Note) -> URL? { NotesStore.audioURL(for: note) }

    // MARK: Demo seeding

    private func seedDemoNotesIfNeeded() {
        guard !settings.hasSeededDemo, notes.isEmpty else { return }
        // Build the deterministic demo set and de-dupe by the fixed seed ids so a
        // fresh launch shows exactly these notes once — never a doubled-up list,
        // even if this path is reached with stale leftovers in the store.
        let demos = DemoSeed.makeNotes()
        var seen = Set<Note.ID>()
        notes = demos.filter { seen.insert($0.id).inserted }
        persist()
        settings.hasSeededDemo = true
        settings.save()
    }
}
