import AVFoundation
import CloudKit
import Combine
import Foundation
import SwiftData
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

    /// One-time guard: have we already imported the legacy `notes.json` into the
    /// SwiftData store? Mirrors `hasSeededDemo` — set once the import runs so a
    /// later launch never re-imports (and the renamed `notes.json.imported`
    /// backup is left untouched).
    public var didImportLegacyJSON: Bool = false

    /// Sync recordings (the audio blobs) over iCloud alongside the transcripts.
    /// Default ON — the user has the iCloud space and wants audio synced. When
    /// off, only the lightweight note metadata/transcript syncs; audio stays
    /// local to whichever device captured it.
    public var syncAudioOverICloud: Bool = true

    /// Capture an opt-in geotag (an on-device reverse-geocoded place label; see
    /// `LocationStamper`) on notes composed/concluded on this device. Default OFF —
    /// location is the most privacy-sensitive signal, so it's explicit opt-in. When
    /// off, no location is ever requested or stored.
    public var geotagEnabled: Bool = false

    public var engine: TranscriptionEngine {
        TranscriptionEngine(rawValue: transcriptionEngineID) ?? .appleSpeech
    }

    public init() {}

    /// Tolerant decode so an older settings.json (missing newer keys, or carrying
    /// the now-removed mode keys) still loads, keeping the existing engine choice
    /// and seed flag.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fresh = NotesSettings()
        transcriptionEngineID = try c.decodeIfPresent(String.self, forKey: .transcriptionEngineID) ?? fresh.transcriptionEngineID
        hasSeededDemo = try c.decodeIfPresent(Bool.self, forKey: .hasSeededDemo) ?? fresh.hasSeededDemo
        didImportLegacyJSON = try c.decodeIfPresent(Bool.self, forKey: .didImportLegacyJSON) ?? fresh.didImportLegacyJSON
        syncAudioOverICloud = try c.decodeIfPresent(Bool.self, forKey: .syncAudioOverICloud) ?? fresh.syncAudioOverICloud
        geotagEnabled = try c.decodeIfPresent(Bool.self, forKey: .geotagEnabled) ?? fresh.geotagEnabled
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
    case recording          // mic is live
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

    // The active in-progress draft (live mic capture). Accumulates appended
    // speech + edits until the user explicitly concludes it into a saved note.
    @Published public var draft = Draft()

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
    private var pipeline: NotesPipeline
    private var micLevelTimer: Timer?
    private var captureURL: URL?
    private let locationStamper = LocationStamper()

    // Persistence. `AppModel` owns the SwiftData container + context; the public
    // `notes` array is a projection fetched out of it (see `reloadNotes`). The
    // container prefers private-iCloud and degrades to local — sync, when it
    // lights up, just flows changes into the same store this fetches from.
    private let modelContainer: ModelContainer
    private let modelContext: ModelContext

    /// Test-only seam onto the backing container, so a test can open a SECOND
    /// `ModelContext` on the SAME store and simulate an external/remote write
    /// (the shape a CloudKit import takes) before asserting `refresh()` surfaces
    /// it. Not for app use — production reads/writes go through the members above.
    internal var modelContainerForTesting: ModelContainer { modelContainer }

    /// True when the live store is CloudKit-backed (vs. the local fallback).
    /// Purely informational (e.g. a Settings indicator); behavior is identical
    /// either way.
    public var isCloudSyncActive: Bool { NotesDataStore.isCloudKitActive }

    /// - Parameters:
    ///   - pushToTalk: factory that builds the platform hotkey controller from a
    ///     press/release handler. Pass `nil` on platforms with no global hotkey
    ///     (e.g. iOS); the macOS app injects one wrapping its Carbon `HotKeyManager`.
    ///   - inMemoryStore: use an in-memory SwiftData store (tests only).
    public init(
        pushToTalk: ((@escaping @MainActor (Bool) -> Void) -> PushToTalkController)? = nil,
        inMemoryStore: Bool = false
    ) {
        let loaded = NotesSettings.load()
        self.settings = loaded
        self.pipeline = NotesPipeline(engine: loaded.engine)
        self.pushToTalkFactory = pushToTalk

        // Stand up the SwiftData store (CloudKit-preferred, local fallback). Production
        // uses the process-wide SHARED container so background-launched App Intents read
        // the SAME store; tests get an isolated in-memory one.
        let container = inMemoryStore ? NotesDataStore.makeContainer(inMemory: true) : NotesDataStore.shared
        self.modelContainer = container
        self.modelContext = ModelContext(container)
        // Coalesce our own explicit saves; we drive persistence deliberately.
        self.modelContext.autosaveEnabled = false

        // Migration + seed run against the store, THEN project into `notes`.
        importLegacyNotesIfNeeded()
        if CommandLine.arguments.contains("--wipe-all-notes") { deleteAllNotes() }
        seedDemoNotesIfNeeded()
        reloadNotes()
        if selectedNoteID == nil { selectedNoteID = filteredNotes.first?.id }

        // Pick up changes that arrive from iCloud (another device's edits) and
        // re-project them into the observable array.
        observeRemoteChanges()

        registerHotKey()
    }

    // MARK: Derived

    public var filteredNotes: [Note] {
        let sorted = notes.sorted { $0.createdAt > $1.createdAt }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return sorted }
        return sorted.filter {
            $0.transcript.lowercased().contains(q)
                || ($0.location?.label.lowercased().contains(q) ?? false)
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

    // MARK: Notes CRUD
    //
    // Every write mutates the matching `NoteEntity` and `context.save()`s, then
    // re-projects into `notes`. The public array + views/search/selection stay
    // byte-for-byte unchanged; persistence (and iCloud sync) is what moved
    // underneath. CloudKit forbids unique constraints, so identity is enforced by
    // fetching the entity for an id rather than relying on a DB constraint.

    public func updateTranscript(_ transcript: String, for id: Note.ID) {
        guard let entity = entity(for: id) else { return }
        entity.transcript = transcript
        entity.updatedAt = Date()
        saveAndReload()
    }

    public func toggleFavorite(_ id: Note.ID) {
        guard let entity = entity(for: id) else { return }
        entity.isFavorite.toggle()
        entity.updatedAt = Date()
        saveAndReload()
    }

    public func delete(_ id: Note.ID) {
        guard let entity = entity(for: id) else { return }
        if let audio = entity.audioFileName { NotesStore.deleteAudio(named: audio) }
        modelContext.delete(entity)
        if selectedNoteID == id { selectedNoteID = nil }
        saveAndReload()
        if selectedNoteID == nil { selectedNoteID = filteredNotes.first?.id }
    }

    /// Maintenance only (behind the `--wipe-all-notes` launch arg): delete every note
    /// + its audio so a shared library can be cleared of test/demo clutter. The
    /// deletions mirror out via CloudKit, so peers go empty too. Not surfaced in the UI.
    public func deleteAllNotes() {
        let all = (try? modelContext.fetch(FetchDescriptor<NoteEntity>())) ?? []
        for entity in all {
            if let audio = entity.audioFileName { NotesStore.deleteAudio(named: audio) }
            modelContext.delete(entity)
        }
        selectedNoteID = nil
        saveAndReload()
        // NSPCC's per-record deletion *exports* are slow/batched, so also delete the
        // CloudKit mirror zone outright — that clears every peer immediately. NSPCC
        // re-creates an empty zone on its next sync. Safe because the local store is
        // now empty (nothing to re-upload). Peers must have empty local stores too
        // (uninstalled / wiped) or they'll just re-populate the zone.
        let zoneID = CKRecordZone.ID(zoneName: "com.apple.coredata.cloudkit.zone")
        CKContainer(identifier: NotesDataStore.cloudKitContainerID)
            .privateCloudDatabase
            .delete(withRecordZoneID: zoneID) { _, error in
                NSLog("HNDIAG cloud zone delete: %@", error.map { "\($0)" } ?? "ok")
            }
        NSLog("HNDIAG wiped %d local notes + requested cloud zone delete", all.count)
    }

    /// Create a note from content composed on this device (the iPhone compose
    /// sheet: typed body, optionally a recorded + on-device-transcribed voice
    /// note). Routes through the same `insert()` persist path as every other
    /// write, so it lands in the store, projects into `notes`, and CloudKit-mirrors
    /// like any note — tagged `.phone`.
    ///
    /// - Parameters:
    ///   - transcript: the note body (typed and/or transcribed text). Its `kind` is
    ///     `.voice` when a recording is attached, else `.text`.
    ///   - audioURL: optional recording to keep with the note. It's imported into
    ///     the store under the new note's id (so it plays back and rides iCloud via
    ///     the normal audio-sync step); the source file is left for the caller.
    /// - Returns: the saved note (also selected and appended to `notes`).
    @discardableResult
    public func composeNote(transcript: String, audioURL: URL? = nil) -> Note {
        let id = UUID()
        let now = Date()
        let body = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        // Pull the recording into the store under this id so it plays back and
        // syncs (best-effort; a failed import just yields a text-only note).
        var storedAudioName: String?
        var durationSeconds: Double?
        if let audioURL {
            durationSeconds = try? AudioInfo.duration(of: audioURL)
            storedAudioName = try? NotesStore.importAudio(from: audioURL, noteID: id)
        }

        let note = Note(
            id: id,
            transcript: body,
            kind: storedAudioName != nil ? .voice : .text,
            createdAt: now,
            updatedAt: now,
            source: .phone,
            audioFileName: storedAudioName,
            durationSeconds: durationSeconds,
            engineUsed: storedAudioName != nil ? settings.engine.displayName : nil)
        insert(note, select: true)
        stampLocationIfEnabled(for: note)
        return note
    }

    private func insert(_ note: Note, select: Bool) {
        // Upsert by id so a re-ingest / double-import converges instead of
        // duplicating (no unique constraint to lean on under CloudKit).
        if let existing = entity(for: note.id) {
            existing.apply(note)
        } else {
            modelContext.insert(NoteEntity(note: note))
        }
        saveAndReload()
        if select { selectedNoteID = note.id }
        // Pull the recording into the synced blob (best-effort, off the hot path).
        syncAudioIfEnabled(for: note)
    }

    // MARK: SwiftData projection helpers

    /// Fetch the entity for a note id (the CloudKit-safe stand-in for a unique
    /// lookup). Returns nil if none / on error.
    private func entity(for id: Note.ID) -> NoteEntity? {
        var descriptor = FetchDescriptor<NoteEntity>(
            predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }

    /// Re-project all stored entities into the observable `notes` array. The
    /// array's own `filteredNotes` re-sorts, so the fetch order doesn't matter,
    /// but we sort newest-first to keep things predictable.
    ///
    /// **Reads through a FRESH `ModelContext`, not the long-lived write context.**
    /// SwiftData's context keeps a registry of materialized objects and can serve a
    /// fetch out of that cache — so a row CloudKit just imported into the store
    /// (under `NSPersistentStoreRemoteChange`) may not surface through the write
    /// context that never saw the insert. A short-lived context built per reload
    /// has an empty registry, so its fetch always reflects the latest *persisted*
    /// state (our own just-saved writes included, since `saveAndReload` saves
    /// first). Read-only and discarded immediately; mutations still go through the
    /// write context (`modelContext`).
    private func reloadNotes() {
        let descriptor = FetchDescriptor<NoteEntity>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        let readContext = ModelContext(modelContainer)
        let entities = (try? readContext.fetch(descriptor)) ?? []
        notes = entities.map(Note.init(entity:))
    }

    /// Save pending context changes and re-project. Used by every mutation.
    private func saveAndReload() {
        do { try modelContext.save() }
        catch { banner = "Couldn't save notes: \(error.localizedDescription)" }
        reloadNotes()
    }

    // MARK: Audio sync (read local file → entity blob)

    /// Read a note's local recording into its entity's `audioData` so it syncs
    /// over iCloud. No-op when audio sync is disabled or the note has no audio.
    /// Best-effort and asynchronous — failure never affects the saved note.
    private func syncAudioIfEnabled(for note: Note) {
        guard settings.syncAudioOverICloud, note.audioFileName != nil else { return }
        Task { [weak self] in
            guard let encoded = await AudioSync.encode(for: note) else { return }
            await MainActor.run {
                guard let self, let entity = self.entity(for: note.id) else { return }
                // Skip if an identical blob already rode along (avoids re-writing
                // and re-syncing on every reload).
                if entity.audioData == encoded.data { return }
                entity.audioData = encoded.data
                entity.audioFileName = encoded.fileName
                self.saveAndReload()
            }
        }
    }

    // MARK: Location stamping (opt-in geotag)

    /// Capture an opt-in location for a freshly-created note and patch it onto the
    /// entity. Mirrors `syncAudioIfEnabled`: guarded by the setting, asynchronous,
    /// and best-effort — a denied permission or missing fix simply leaves the note
    /// un-located and never affects the save. Only the on-device, real-time capture
    /// sites call this (compose + draft-conclude), not imports/seeds.
    private func stampLocationIfEnabled(for note: Note) {
        guard settings.geotagEnabled else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let place = await self.locationStamper.stamp() else { return }
            guard let entity = self.entity(for: note.id) else { return }
            entity.location = place
            entity.updatedAt = Date()
            self.saveAndReload()
        }
    }

    // MARK: Remote (iCloud) change observation

    /// Re-project when the store changes underneath us, from EITHER direction:
    ///
    ///   1. `ModelContext.didSave` — a LOCAL save on any context for this store
    ///      (our own writes, plus the per-reload read context's no-op saves). This
    ///      is what kept the list fresh for on-device edits.
    ///   2. `.NSPersistentStoreRemoteChange` — the store-coordinator-level signal
    ///      that the persistent store changed OUT OF BAND, which is how CloudKit
    ///      mirroring announces another device's edits after it imports them via
    ///      persistent history. `didSave` does NOT reliably fire for those imports
    ///      (no `ModelContext` on this process performed the save), so without this
    ///      second observer a synced-in note could sit invisible until the next
    ///      local write. Posting this notification is enabled automatically by the
    ///      CloudKit-mirrored `ModelConfiguration` (it turns on persistent history
    ///      + remote-change tracking) — see `NotesDataStore`.
    ///
    /// Both just call `reloadNotes()`, whose fresh-context fetch surfaces the
    /// newly-arrived rows; newly-synced audio is materialized lazily on access
    /// (see `audioURL(for:)`).
    private func observeRemoteChanges() {
        let refresh: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor [weak self] in self?.reloadNotes() }
        }
        NotificationCenter.default.addObserver(
            forName: ModelContext.didSave,
            object: nil, queue: .main, using: refresh)
        NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: nil, queue: .main, using: refresh)
    }

    /// Public manual re-projection: re-fetch the store and refresh the observable
    /// `notes` array. Backs the platform pull-to-refresh / refresh affordances so
    /// the user can force a reconciliation even if a remote-change notification was
    /// missed. Cheap and idempotent (a fresh fetch + assign).
    public func refresh() {
        reloadNotes()
    }

    // MARK: Live mic capture — record APPENDS to the active draft
    //
    // A recording no longer creates a note. Hold-to-talk transcribes and *appends*
    // the speech to `draft`; the draft is only finalized on an explicit conclude.

    public func toggleRecording() {
        if isRecording { Task { await stopRecordingAndAppend() } }
        else { Task { await startRecording() } }
    }

    public func startRecording() async {
        guard !isRecording, !isTranscribing else { return }
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
        stampLocationIfEnabled(for: note)
        draft = Draft()
    }

    /// Discard the active draft without saving (and drop its retained audio).
    public func clearDraft() {
        if let audio = draft.audioFileName { NotesStore.deleteAudio(named: audio) }
        draft = Draft()
    }

    // MARK: External ingest — recordings arrive ALREADY concluded
    //
    // Audio captured elsewhere (e.g. the Apple Watch) was composed and concluded
    // there, so it drops straight into the saved list as a finished note (no
    // Mac-side drafting). This deliberately does NOT touch `recordingState`/`draft`
    // — the live capture area is independent of a background ingest.

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

    /// Ingest a recording transferred from the Apple Watch over WatchConnectivity.
    /// The watch is a thin capture front-end: it records audio and ships the file
    /// to the iPhone, which runs the normal transcribe → save pipeline. The passed
    /// URL is a temp copy the iOS receiver made out of the WatchConnectivity inbox,
    /// so we own it and clean it up once ingested.
    public func ingestFromWatch(url: URL) async {
        await ingest(url: url, source: .watch, cleanupSource: true)
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

    /// Resolve a note's playable audio URL. On a device that received the note
    /// over iCloud but doesn't have the local `Audio/<id>.<ext>` file yet, this
    /// first **materializes** the synced `audioData` blob to disk so the player
    /// finds it. Falls back to the plain local lookup otherwise.
    public func audioURL(for note: Note) -> URL? {
        if let url = NotesStore.audioURL(for: note) { return url }
        // No local file — try to write out a synced blob, if one arrived.
        if let entity = entity(for: note.id), let url = AudioSync.materialize(entity) {
            return url
        }
        return nil
    }

    // MARK: One-time legacy JSON import (notes.json → SwiftData)

    /// On first launch after the SwiftData migration, fold any pre-existing
    /// `notes.json` into the store. Insert-if-id-absent (never blind append) so a
    /// Mac+iPhone that both still carry the same legacy file converge on one copy
    /// instead of doubling up. Tolerant-decodes (each `Note` already falls back
    /// field-by-field). Then sets `didImportLegacyJSON` and renames the file to
    /// `notes.json.imported` (kept as a backup; not deleted).
    private func importLegacyNotesIfNeeded() {
        guard !settings.didImportLegacyJSON else { return }
        guard NotesStore.legacyNotesFileExists() else {
            // Nothing to import — mark done so we don't keep checking, and a
            // future `notes.json` (there won't be one) isn't silently absorbed.
            settings.didImportLegacyJSON = true
            settings.save()
            return
        }

        let legacy = NotesStore.load() // tolerant decode of [Note]
        var importedAny = false
        for note in legacy where entity(for: note.id) == nil {
            modelContext.insert(NoteEntity(note: note))
            importedAny = true
        }
        if importedAny { try? modelContext.save() }

        // Pull each imported note's local audio into its synced blob.
        if settings.syncAudioOverICloud {
            for note in legacy where note.audioFileName != nil {
                syncAudioIfEnabled(for: note)
            }
        }

        NotesStore.archiveLegacyNotesFile()
        settings.didImportLegacyJSON = true
        settings.save()
    }

    // MARK: Demo seeding

    private func seedDemoNotesIfNeeded() {
        // Demo seeding is OFF by default. The dedup-by-id below only sees the LOCAL
        // store, but CloudKit mirroring keys records by NSPCC's internal id (not the
        // note's `id`), so two devices seeding before they first sync produce copies
        // that never merge — i.e. duplicates. Opt in with HN_SEED_DEMO=1 only for a
        // throwaway screenshot/demo build on a single device.
        guard ProcessInfo.processInfo.environment["HN_SEED_DEMO"] == "1" else {
            settings.hasSeededDemo = true
            settings.save()
            return
        }
        // Only seed an empty store, and only once (mirrors the legacy flag). The
        // store being empty after a real import means a genuinely fresh install.
        guard !settings.hasSeededDemo else { return }
        let isEmpty = (try? modelContext.fetchCount(FetchDescriptor<NoteEntity>())) == 0
        guard isEmpty else {
            // Non-empty store (e.g. imported or already synced from iCloud):
            // don't seed demo content, but record that we won't.
            settings.hasSeededDemo = true
            settings.save()
            return
        }
        // Build the deterministic demo set and insert-if-id-absent on the fixed
        // seed ids so a fresh launch shows exactly these notes once — never a
        // doubled-up list, even if two devices seed before they first sync.
        for demo in DemoSeed.makeNotes() where entity(for: demo.id) == nil {
            modelContext.insert(NoteEntity(note: demo))
        }
        try? modelContext.save()
        // Carry each seeded note's bundled audio into its synced blob so the demo
        // recording syncs too (the import path does the same for real notes).
        // Done after the save so the entities exist for the async lookup.
        if settings.syncAudioOverICloud {
            for demo in DemoSeed.makeNotes() where demo.audioFileName != nil {
                syncAudioIfEnabled(for: demo)
            }
        }
        settings.hasSeededDemo = true
        settings.save()
    }
}
