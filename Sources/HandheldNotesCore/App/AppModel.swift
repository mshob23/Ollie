import AVFoundation
import CloudKit
import Combine
import CoreData
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

    // MARK: Sync health (observability backbone)
    //
    // Folded from NSPersistentCloudKitContainer phase events (see
    // `observeSyncEvents`). The UI renders an indicator/banner off `syncHealth`;
    // `lastSuccessfulSync` backs a "last synced <relative>" affordance even when
    // no event is currently in flight.

    /// Observable health of iCloud sync. Seeded at init from the construction-time
    /// CloudKit-vs-local outcome, then driven by CloudKit phase events.
    @Published public private(set) var syncHealth: SyncHealth

    /// Timestamp of the most recent successful import/export phase, or `nil` if
    /// none has completed this run. Drives a "last synced …" UI affordance and the
    /// staleness backstop.
    ///
    /// `@Published` so the "Last synced" line re-renders on its OWN mutation rather
    /// than relying on the coincidental adjacency to the `@Published syncHealth`
    /// write in `handleSyncEvent` (the staleness path and any future writer that
    /// updates this without also touching `syncHealth` must still notify the UI).
    @Published public private(set) var lastSuccessfulSync: Date?

    /// Running count of CONSECUTIVE failed CloudKit phase events with no intervening
    /// success — the debounce accumulator for the `.degraded` escalation. Lives here
    /// (not in `SyncHealth`) so the fold stays a pure function: `handleSyncEvent`
    /// feeds it into `SyncHealth.fold` and stores the count it returns. A success
    /// resets it to 0. Escalation to `.degraded` only happens once it reaches
    /// `SyncHealth.degradeFailureThreshold` (2), so a lone transient recoverable
    /// CKError (1011) on launch can't false-alarm the schema banner. See `fold`.
    private var consecutiveSyncFailures = 0

    /// Repeating staleness backstop (see `startSyncStalenessTimer`). Conservative:
    /// it never hard-errors, it only keeps the UI's "last synced" honest and logs a
    /// breadcrumb if events have gone quiet. Invalidated on deinit.
    ///
    /// Held in a small `@unchecked Sendable` box so the nonisolated `deinit` can
    /// invalidate it under Swift 6 strict concurrency (a bare `Timer?` stored
    /// property can't be touched from a nonisolated deinit). Only ever mutated on
    /// the main actor, so the box's unchecked Sendability is sound.
    private let syncStalenessTimer = TimerBox()

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

        // Seed sync health from the construction-time CloudKit-vs-local outcome.
        // `isCloudKitActive` is now settled (the container above has been built).
        // This is the SEED only — from here on, CloudKit phase events drive the
        // state (see `observeSyncEvents`). A local-only store stays `.localOnly`
        // forever (no events); a CloudKit store starts at idle-with-no-success.
        self.syncHealth = NotesDataStore.isCloudKitActive ? .idle(lastSuccess: nil) : .localOnly

        // Migration + seed run against the store, THEN project into `notes`.
        importLegacyNotesIfNeeded()
        if CommandLine.arguments.contains("--wipe-all-notes") { deleteAllNotes() }
        seedDemoNotesIfNeeded()
        reloadNotes()
        if selectedNoteID == nil { selectedNoteID = filteredNotes.first?.id }

        // Pick up changes that arrive from iCloud (another device's edits) and
        // re-project them into the observable array.
        observeRemoteChanges()

        // Fold CloudKit phase events into `syncHealth` (the observability backbone),
        // and arm the no-event staleness backstop.
        observeSyncEvents()
        startSyncStalenessTimer()

        registerHotKey()
    }

    deinit {
        // Tear down the repeating staleness backstop so it can't outlive the model.
        // (The timer captures `self` weakly, so this is belt-and-suspenders, but it
        // also stops the timer from firing into a deallocated run-loop slot.)
        syncStalenessTimer.invalidate()
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
        SpotlightIndexer.remove(ids: [id])
        if selectedNoteID == id { selectedNoteID = nil }
        saveAndReload()
        if selectedNoteID == nil { selectedNoteID = filteredNotes.first?.id }
    }

    /// Maintenance only (behind the `--wipe-all-notes` launch arg): delete every note
    /// + its audio so a shared library can be cleared of test/demo clutter.
    ///
    /// **Deletes RECORDS, never the CloudKit ZONE.** An earlier version deleted the
    /// mirror zone outright to clear peers immediately; that is exactly what wedged
    /// sync for hours (tearing the zone down out from under
    /// `NSPersistentCloudKitContainer` leaves it in a state it can't cleanly
    /// recover from). The right primitive is per-record deletion: we delete the
    /// local `NoteEntity` rows and let NSPCC mirror those deletions out as ordinary
    /// record deletes. Slower to propagate, but it never corrupts the zone.
    ///
    /// **Backs up first.** Before any deletion we snapshot the corpus to a
    /// timestamped `~/Ollie/backups/` file (all platforms — iOS sandbox included),
    /// so a wipe is always recoverable.
    /// The backup is best-effort here (this is a maintenance arg, not the in-app
    /// `resetSync` which *verifies* the backup and refuses to proceed without it).
    public func deleteAllNotes() {
        let all = (try? modelContext.fetch(FetchDescriptor<NoteEntity>())) ?? []

        // Safety net: snapshot the live corpus before destroying it. Runs on ALL
        // platforms — `CorpusExporter.backup` compiles everywhere and `~/Ollie`
        // (via `homeDirectoryForCurrentUser`) is a valid location inside the iOS
        // sandbox too. The doc above promises a backup first; this delivers it on
        // iOS as well, not just macOS. Best-effort on this maintenance path.
        let backupURL = CorpusExporter.backup(notes)
        Diag.log("HNDIAG deleteAllNotes backup: \(backupURL?.path ?? "FAILED")")

        for entity in all {
            if let audio = entity.audioFileName { NotesStore.deleteAudio(named: audio) }
            modelContext.delete(entity)
        }
        SpotlightIndexer.removeAll()
        selectedNoteID = nil
        saveAndReload()
        // The record deletions above mirror out via CloudKit as ordinary per-record
        // deletes — peers go empty as those propagate. We deliberately DO NOT delete
        // the CloudKit zone: that is the operation that previously wedged sync.
        Diag.log("HNDIAG wiped \(all.count) local notes (records deleted; zone untouched)")
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
        // Keep system Spotlight in sync with the live projection (best-effort, async).
        SpotlightIndexer.index(notes)
        #if os(macOS)
        // Rung 3: mirror the corpus to ~/Ollie (JSONL + Markdown) for external tools
        // (Obsidian, the Ollie MCP server, any LLM). Mac-only for now; off-main, best-effort.
        CorpusExporter.exportInBackground(notes)
        #endif
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

    // MARK: Sync levers (F4 syncNow / F7 resetSync)

    /// Timestamp of the last manual `syncNow()` press. Distinct from
    /// `lastSuccessfulSync` (which tracks CloudKit phase *success*): this is just
    /// "when did the user last ask us to re-reconcile", surfaced next to the manual
    /// control so a tap gives visible feedback even though there's nothing to pull.
    ///
    /// `@Published` so the "Last reconciled …" line under the Sync-now button
    /// re-renders the moment the user taps it.
    @Published public private(set) var lastManualSync: Date?

    /// Manual "sync now" lever.
    ///
    /// **What it actually does — and honestly does NOT.** This re-projects the local
    /// store into `notes` (a fresh-context fetch) and re-runs the corpus export, then
    /// stamps `lastManualSync`. That makes it a real, useful reconcile of *local*
    /// state: it surfaces any rows CloudKit already imported into the store but whose
    /// remote-change notification we might have missed, and it refreshes the `~/Ollie`
    /// mirror the MCP/Obsidian read.
    ///
    /// It does **not** — and cannot — compel CloudKit to fetch from the server *right
    /// now*. SwiftData / `NSPersistentCloudKitContainer` expose no public API to force
    /// an immediate pull; mirroring runs on its own schedule. So this is named and
    /// documented as a local re-reconcile, NOT a "pull from cloud". If the server has
    /// newer records that NSPCC hasn't imported yet, they appear when it next syncs of
    /// its own accord — `syncNow()` can't hurry that along.
    public func syncNow() {
        reloadNotes()
        lastManualSync = Date()
        Diag.log("HNDIAG syncNow: re-projected local store + re-exported corpus "
            + "(local reconcile only; no forced server pull)")
    }

    /// The outcome of `resetSync()`: a relaunch is required because the shared
    /// `ModelContainer` is a process-wide one-shot static that cannot be rebuilt
    /// live. The UI uses this to tell the user to quit and reopen.
    public enum ResetSyncOutcome: Equatable, Sendable {
        /// The local store files were deleted; the user must quit + relaunch so a
        /// fresh container is built against a clean store.
        case relaunchRequired
    }

    /// Errors `resetSync()` can throw BEFORE it touches anything destructive. If any
    /// of these is thrown, NO store file was deleted — the store is exactly as it was.
    public enum ResetSyncError: Error, Equatable {
        /// The pre-delete backup couldn't be written (or came back empty). We refuse
        /// to delete the store without a verified, non-empty backup on disk.
        case backupFailed
        /// The store directory couldn't be located, so there was nothing safe to delete.
        case storeDirectoryUnavailable
    }

    /// Posted (main thread) when `resetSync()` succeeds, carrying
    /// `ResetSyncOutcome.relaunchRequired`. A UI layer that doesn't call `resetSync()`
    /// directly can observe this to surface the "quit and reopen" prompt.
    public static let didRequireRelaunchNotification =
        Notification.Name("AppModel.didRequireRelaunch")

    /// Test-only seam onto the store files `resetSync()` deletes. Production reads
    /// the real `NotesDataStore.storeFileURLs()`; a test points this at temp files so
    /// the suite can exercise the delete path WITHOUT touching the real on-disk store.
    /// Internal (not public) so only the test target reaches it.
    internal var storeFileURLsForReset: [URL] = NotesDataStore.storeFileURLs()

    /// In-app equivalent of the CLI store-delete recovery: when sync is wedged, blow
    /// away the LOCAL SwiftData store so the next launch rebuilds a clean one and
    /// re-imports from CloudKit. The safe counterpart to the old "delete the zone"
    /// hammer.
    ///
    /// **Ordering is the safety contract:**
    ///   1. Take a backup FIRST and **verify** the backup file exists and is
    ///      non-empty. If it isn't, throw `.backupFailed` and delete NOTHING — the
    ///      store is left exactly as it was. (This is the verify-before-destroy
    ///      pattern `deleteAllNotes` only does best-effort; here it's mandatory.)
    ///   2. Only then delete the local store files (`default.store` + `-wal` / `-shm`).
    ///   3. Signal `.relaunchRequired` (and post `didRequireRelaunchNotification`) so
    ///      the UI tells the user to quit + reopen — the shared `ModelContainer` is a
    ///      one-shot static and can't be rebuilt in-process.
    ///
    /// **It NEVER touches the CloudKit zone.** Tearing the zone down is precisely what
    /// caused the prior multi-hour sync wedge. This deletes only LOCAL files; the
    /// server-side records are untouched and re-import on the clean relaunch.
    ///
    /// - Returns: `.relaunchRequired` on success.
    /// - Throws: `ResetSyncError` if the backup can't be verified or the store
    ///   directory can't be found — in either case nothing was deleted.
    @discardableResult
    public func resetSync() throws -> ResetSyncOutcome {
        // (a) Backup FIRST, and verify it landed non-empty BEFORE deleting anything.
        guard let backupURL = CorpusExporter.backup(notes) else {
            Diag.log("HNDIAG resetSync ABORTED: backup write failed (nothing deleted)")
            throw ResetSyncError.backupFailed
        }
        let fm = FileManager.default
        let size = (try? fm.attributesOfItem(atPath: backupURL.path)[.size] as? Int) ?? nil
        // An EMPTY corpus legitimately produces a valid 0-byte (or header-only)
        // backup. Requiring >0 bytes there would wrongly refuse to reset an empty —
        // possibly wedged — store. So: when there are no notes, require only that the
        // backup file EXISTS; keep the strict non-empty check when notes are present.
        let backupExists = fm.fileExists(atPath: backupURL.path)
        let backupOK = notes.isEmpty ? backupExists : (backupExists && (size ?? 0) > 0)
        guard backupOK else {
            Diag.log("HNDIAG resetSync ABORTED: backup empty/missing at \(backupURL.path) (nothing deleted)")
            throw ResetSyncError.backupFailed
        }
        Diag.log("HNDIAG resetSync backup verified: \(backupURL.path) (\(size ?? 0) bytes, notes=\(notes.count))")

        // (b) Only now delete the LOCAL store files. NEVER the CloudKit zone.
        let storeFiles = storeFileURLsForReset
        guard !storeFiles.isEmpty else {
            Diag.log("HNDIAG resetSync ABORTED: store directory unavailable (nothing deleted)")
            throw ResetSyncError.storeDirectoryUnavailable
        }
        for url in storeFiles where fm.fileExists(atPath: url.path) {
            do {
                try fm.removeItem(at: url)
                Diag.log("HNDIAG resetSync deleted \(url.lastPathComponent)")
            } catch {
                // A partial delete still requires a relaunch; log and continue so the
                // remaining companions are also removed. (The main `.store` going is
                // what forces the rebuild.)
                Diag.log("HNDIAG resetSync could not delete \(url.lastPathComponent): \(error)")
            }
        }

        // (c) Signal "relaunch required" — the shared container is a one-shot static.
        NotificationCenter.default.post(
            name: AppModel.didRequireRelaunchNotification, object: self)
        Diag.log("HNDIAG resetSync complete: local store cleared, relaunch required (zone untouched)")
        return .relaunchRequired
    }

    // MARK: Sync-health observation (CloudKit phase events)

    /// Subscribe to `NSPersistentCloudKitContainer.eventChangedNotification` and
    /// fold each phase event into `syncHealth`.
    ///
    /// **This fires in-process under SwiftData.** Pointing a `ModelConfiguration`
    /// at a CloudKit database stands up an `NSPersistentCloudKitContainer` under
    /// the hood, and it posts this notification for every sync phase. We observe
    /// with `object: nil` (we don't own the container instance) and pull the typed
    /// `Event` out of `userInfo`.
    ///
    /// Each phase (setup/import/export) posts a **START** event (`endDate == nil`)
    /// then an **END** event (`endDate != nil`, `succeeded`/`error` populated). The
    /// fold:
    ///   - **START** → show `.syncing`, but only if we're not already `.degraded`
    ///     (a degraded state is sticky until a phase actually SUCCEEDS, so an
    ///     in-flight retry doesn't flap the UI back to "syncing" and hide the
    ///     problem).
    ///   - **END + succeeded** → record `lastSuccessfulSync` and go
    ///     `.idle(lastSuccess:)`. A success CLEARS any prior `.degraded` and resets
    ///     the consecutive-failure debounce counter.
    ///   - **END + failed** → increment the consecutive-failure counter; only
    ///     escalate to `.degraded(classify(error), since: now)` on the 2nd
    ///     consecutive failure (`SyncHealth.degradeFailureThreshold`). A lone failed
    ///     event followed by a success stays healthy — this debounces the transient
    ///     recoverable CKError (1011) NSPersistentCloudKitContainer fires on a cold
    ///     launch, which would otherwise false-alarm the schema banner.
    ///
    /// A local-only store never gets a CloudKit container, so this observer simply
    /// never fires there and `syncHealth` stays `.localOnly`.
    private func observeSyncEvents() {
        NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let event = notification.userInfo?[
                NSPersistentCloudKitContainer.eventNotificationUserInfoKey
            ] as? NSPersistentCloudKitContainer.Event else { return }
            // `queue: .main` guarantees this block already runs on the main thread,
            // so we're on the main actor's executor. Extract the event's salient
            // fields HERE (the non-Sendable `NSPersistentCloudKitContainer.Event`
            // never crosses an isolation boundary) and fold from those.
            //
            // The one non-Sendable field, `error`, is reduced to a Sendable
            // `SyncDegradation` immediately via the pure classifier, so only
            // value types cross into the fold.
            let isEnd = event.endDate != nil
            let endDate = event.endDate
            let succeeded = event.succeeded
            let typeRaw = event.type.rawValue
            let degradation: SyncDegradation? = (isEnd && !succeeded)
                ? event.error.map(SyncHealth.classify)
                : nil
            let errorText = event.error.map { "\($0)" } ?? "nil"
            MainActor.assumeIsolated {
                self?.handleSyncEvent(
                    typeRaw: typeRaw, isEnd: isEnd, endDate: endDate,
                    succeeded: succeeded, degradation: degradation, errorText: errorText)
            }
        }
    }

    /// Fold one CloudKit phase event (already reduced to Sendable fields) into
    /// `syncHealth`. See `observeSyncEvents` for the state machine; the transition
    /// itself is the pure, unit-tested `SyncHealth.fold`.
    private func handleSyncEvent(
        typeRaw: Int, isEnd: Bool, endDate: Date?,
        succeeded: Bool, degradation: SyncDegradation?, errorText: String
    ) {
        // Greppable phase trail in the unified log (HNDIAG SYNCEVENT ...).
        let phase = isEnd ? "END" : "START"
        Diag.log("HNDIAG SYNCEVENT type=\(typeRaw) \(phase) "
            + "succeeded=\(succeeded) error=\(errorText)")

        let result = SyncHealth.fold(
            current: syncHealth,
            lastSuccess: lastSuccessfulSync,
            consecutiveFailures: consecutiveSyncFailures,
            isEnd: isEnd,
            succeeded: succeeded,
            degradation: degradation,
            endDate: endDate)
        lastSuccessfulSync = result.lastSuccessfulSync
        consecutiveSyncFailures = result.consecutiveFailures
        syncHealth = result.health
    }

    // MARK: Sync staleness backstop (F8)

    /// A conservative, no-event backstop. CloudKit phase events are the PRIMARY
    /// signal; this only covers the pathological "no event ever arrives" case.
    ///
    /// It deliberately does **not** hard-error on staleness — declaring a failure
    /// from silence alone produces false alarms (a quiet store with nothing to sync
    /// is perfectly healthy). Instead, every ~180s while the app is active, if
    /// CloudKit is active, we're not mid-sync, and the last success is missing or
    /// older than ~15 min, it just logs a breadcrumb. The UI keeps showing "last
    /// synced <relative>" off `lastSuccessfulSync` regardless. Invalidated on deinit.
    private func startSyncStalenessTimer() {
        syncStalenessTimer.invalidate()
        let timer = Timer.scheduledTimer(
            withTimeInterval: 180, repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkSyncStaleness() }
        }
        // Survive run-loop modes where the default timer would be starved (e.g. a
        // tracking loop), matching the app's other background timers' intent.
        timer.tolerance = 30
        syncStalenessTimer.timer = timer
    }

    private func checkSyncStaleness() {
        guard NotesDataStore.isCloudKitActive else { return }
        if case .syncing = syncHealth { return }
        let staleAfter: TimeInterval = 15 * 60
        let isStale = lastSuccessfulSync.map { Date().timeIntervalSince($0) > staleAfter } ?? true
        guard isStale else { return }
        // Breadcrumb only — never an error. Events remain the source of truth.
        let last = lastSuccessfulSync.map { "\($0)" } ?? "never"
        Diag.log("HNDIAG SYNCEVENT staleness-backstop lastSuccess=\(last) (no hard error)")
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

/// A tiny holder for the staleness `Timer` so `AppModel`'s nonisolated `deinit`
/// can invalidate it under Swift 6 strict concurrency. `@unchecked Sendable` is
/// sound here because the `timer` is only ever assigned/read on the main actor
/// (in `startSyncStalenessTimer`) and `invalidate()` is safe to call from any
/// thread.
private final class TimerBox: @unchecked Sendable {
    var timer: Timer?
    func invalidate() {
        timer?.invalidate()
        timer = nil
    }
}
