import AVFoundation
import CloudKit
import Combine
import CoreData
import Foundation
import SwiftData
import SwiftUI

// The global-hotkey seam is `CaptureHotKeyController` (see KeyShortcut.swift):
// the Mac app injects a Carbon-backed implementation; iOS passes nil.

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

    // MARK: Quick Capture (macOS global shortcuts)

    /// Hold to dictate: press = record, release = transcribe + save. Default F16
    /// (the historical push-to-talk key). `nil` = unassigned.
    public var holdToDictateShortcut: KeyShortcut? = KeyShortcut(keyCode: 106, display: "F16")
    /// Toggle dictation: tap = start, tap again = stop + save. Default F15.
    public var toggleDictationShortcut: KeyShortcut? = KeyShortcut(keyCode: 113, display: "F15")
    /// Quick note pad: pop up a small text pad (⇧↩ saves). Default F14.
    public var quickPadShortcut: KeyShortcut? = KeyShortcut(keyCode: 107, display: "F14")
    /// When ON, a finished quick capture shows a Save/Discard confirmation (↩ saves,
    /// ⇥ then ␣ discards) instead of saving immediately. Default OFF — the whole
    /// point of quick capture is zero interaction.
    public var confirmQuickCaptureBeforeSaving: Bool = false

    /// The input device to record from. `nil` = follow the current system-default
    /// microphone (the default). A stored `localizedName` overrides it; if that
    /// device is missing at record time, capture falls back to the system default.
    public var microphoneName: String? = nil

    /// The view name the user has **pinned** to the top of the Views feed, or `nil`
    /// for none (contract §5 / plan M5). Per-device (a device-local preference, not a
    /// synced record) — it lives here alongside the mic choice, not in the CloudKit
    /// store. Tolerant-decoded like every other key: an older settings file simply
    /// yields `nil` (nothing pinned).
    public var pinnedViewName: String? = nil

    public var engine: TranscriptionEngine {
        TranscriptionEngine(rawValue: transcriptionEngineID) ?? .appleSpeech
    }

    /// The current Quick Capture hotkey bindings (assigned shortcuts only).
    public var captureHotKeyBindings: [CaptureHotKeyAction: KeyShortcut] {
        var b: [CaptureHotKeyAction: KeyShortcut] = [:]
        b[.holdToDictate] = holdToDictateShortcut
        b[.toggleDictation] = toggleDictationShortcut
        b[.quickPad] = quickPadShortcut
        return b
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
        // Quick Capture: `decodeIfPresent` alone can't distinguish "older settings
        // file" (→ default binding) from "user explicitly cleared" — so shortcuts
        // are stored as an OPTIONAL-inside-a-marker: the key absent → default; the
        // key present-but-null → cleared. `decodeNil` handles the null case.
        holdToDictateShortcut = try Self.decodeShortcut(c, .holdToDictateShortcut, fallback: fresh.holdToDictateShortcut)
        toggleDictationShortcut = try Self.decodeShortcut(c, .toggleDictationShortcut, fallback: fresh.toggleDictationShortcut)
        quickPadShortcut = try Self.decodeShortcut(c, .quickPadShortcut, fallback: fresh.quickPadShortcut)
        confirmQuickCaptureBeforeSaving = try c.decodeIfPresent(Bool.self, forKey: .confirmQuickCaptureBeforeSaving) ?? fresh.confirmQuickCaptureBeforeSaving
        microphoneName = try c.decodeIfPresent(String.self, forKey: .microphoneName)
        pinnedViewName = try c.decodeIfPresent(String.self, forKey: .pinnedViewName)
    }

    private static func decodeShortcut(
        _ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys, fallback: KeyShortcut?
    ) throws -> KeyShortcut? {
        guard c.contains(key) else { return fallback }          // older file → default
        if try c.decodeNil(forKey: key) { return nil }          // explicitly cleared
        return try c.decode(KeyShortcut.self, forKey: key)
    }

    /// Explicit keys so cleared shortcuts encode as literal `null` (see
    /// `decodeShortcut`); `JSONEncoder` would otherwise omit nil optionals.
    private enum CodingKeys: String, CodingKey {
        case transcriptionEngineID, hasSeededDemo, didImportLegacyJSON,
             syncAudioOverICloud, geotagEnabled,
             holdToDictateShortcut, toggleDictationShortcut, quickPadShortcut,
             confirmQuickCaptureBeforeSaving, microphoneName, pinnedViewName
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(transcriptionEngineID, forKey: .transcriptionEngineID)
        try c.encode(hasSeededDemo, forKey: .hasSeededDemo)
        try c.encode(didImportLegacyJSON, forKey: .didImportLegacyJSON)
        try c.encode(syncAudioOverICloud, forKey: .syncAudioOverICloud)
        try c.encode(geotagEnabled, forKey: .geotagEnabled)
        try c.encode(holdToDictateShortcut, forKey: .holdToDictateShortcut)      // nil → null
        try c.encode(toggleDictationShortcut, forKey: .toggleDictationShortcut)
        try c.encode(quickPadShortcut, forKey: .quickPadShortcut)
        try c.encode(confirmQuickCaptureBeforeSaving, forKey: .confirmQuickCaptureBeforeSaving)
        try c.encodeIfPresent(microphoneName, forKey: .microphoneName)
        try c.encodeIfPresent(pinnedViewName, forKey: .pinnedViewName)
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

/// A published projection of the **views** layer (contract §5) — one immutable
/// snapshot the Views surfaces (iOS Views tab, Mac Views pane) render, refreshed on
/// every `reloadNotes()` so a revision that syncs in from CloudKit or lands via the
/// inbox appears without any extra plumbing. Value types only (`Sendable`), built
/// once per reload from the same `AgentLayerStore` read context that projects the
/// notes — no second projection pass.
///
/// The two members are the two shapes the UI needs:
///   • ``latest`` — the newest revision of each view, newest-view first: exactly the
///     Views-feed rows (one row per view).
///   • ``revisionsByView`` — every revision keyed by view name, each list newest
///     first: what the detail screen's "earlier revisions" list reads (and how the
///     feed resolves a pinned view's latest revision without re-querying the store).
public struct AgentLayerSnapshot: Equatable, Sendable {
    /// One row per view — the latest revision of each, newest view first.
    public var latest: [AgentViewRevision]
    /// All revisions of each view (key = exact `viewName`), each list newest first.
    public var revisionsByView: [String: [AgentViewRevision]]

    public init(latest: [AgentViewRevision] = [],
                revisionsByView: [String: [AgentViewRevision]] = [:]) {
        self.latest = latest
        self.revisionsByView = revisionsByView
    }

    public static let empty = AgentLayerSnapshot()

    /// All revisions of one view, newest first (empty if the view is unknown).
    public func revisions(forView name: String) -> [AgentViewRevision] {
        revisionsByView[name] ?? []
    }
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

    // MARK: Agent-layer snapshots (trust surfaces)
    //
    // Published projections of the agent layer so SwiftUI views (note-detail tag
    // chips, the AI-memory screen) stay live: they refresh on every `reloadNotes()`,
    // which already fires for our own writes (`didSave`), CloudKit imports
    // (`.NSPersistentStoreRemoteChange`), and applied inbox batches
    // (`InboxIngestor.didApplyBatch`). Mutating them goes through `AgentLayerStore`
    // (the write choke point) then re-projects — same pattern as notes.

    /// Every agent tag in the store, newest first. Note-detail filters this by
    /// `noteId` for its chip row (see ``tags(forNote:)``).
    @Published public private(set) var agentTags: [AgentTag] = []

    /// Agent memory entries (retired included, flagged), newest first — the AI-memory
    /// trust screen renders these.
    @Published public private(set) var agentMemory: [AgentMemory] = []

    /// The published views-layer snapshot (contract §5) the Views feed + detail render.
    /// Refreshed alongside `agentTags`/`agentMemory` on every `reloadNotes()`.
    @Published public private(set) var agentViews: AgentLayerSnapshot = .empty

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
            if oldValue.captureHotKeyBindings != settings.captureHotKeyBindings {
                applyHotKeyBindings()   // re-register the global shortcuts live
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
    ///
    /// **PERSISTED across launches** (UserDefaults). The July 2026 outage went
    /// unreported for ~24h because this counter was in-memory: the user's sessions
    /// were brief (open app → one failed export → close), so every launch reset the
    /// count to 0 and the 2-failure threshold was structurally unreachable. With
    /// persistence, failure #1 in one session + failure #2 in the next correctly
    /// escalates. A success still resets to 0, so the transient-launch-blip
    /// debounce behavior is unchanged.
    private var consecutiveSyncFailures: Int {
        get { UserDefaults.standard.integer(forKey: Self.syncFailuresDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.syncFailuresDefaultsKey) }
    }
    private static let syncFailuresDefaultsKey = "hcConsecutiveSyncFailures"

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
    private var hotKey: CaptureHotKeyController?
    private let captureHotKeyFactory: ((@escaping @MainActor (CaptureHotKeyAction, Bool) -> Void) -> CaptureHotKeyController)?
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
    ///   - captureHotKeys: factory that builds the platform global-hotkey controller
    ///     from an (action, pressed) handler. Pass `nil` on platforms with no global
    ///     hotkeys (e.g. iOS); the macOS app injects one wrapping its Carbon
    ///     `HotKeyManager`.
    ///   - inMemoryStore: use an in-memory SwiftData store (tests only).
    public init(
        captureHotKeys: ((@escaping @MainActor (CaptureHotKeyAction, Bool) -> Void) -> CaptureHotKeyController)? = nil,
        inMemoryStore: Bool = false
    ) {
        let loaded = NotesSettings.load()
        self.settings = loaded
        self.pipeline = NotesPipeline(engine: loaded.engine)
        self.captureHotKeyFactory = captureHotKeys

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
        observeWakeResync()

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

    /// True while a `retranscribe` is running for the given note (drives the UI's
    /// spinner / disabled state). A `Set` so several could run, though the UI runs one.
    @Published public private(set) var retranscribing: Set<Note.ID> = []

    /// Re-run transcription on a note's PRESERVED audio and replace its transcript.
    ///
    /// The ingest pipeline keeps the recording even when Apple Speech fails (the note
    /// body becomes a `[Transcription failed: …]` placeholder, `engineUsed == "error"`
    /// → `Note.transcriptionFailed`), so a failed take is always recoverable later —
    /// e.g. once the on-device speech model finishes downloading, or on a device
    /// where it's available. Reads the audio via `audioURL(for:)` (materializing a
    /// synced blob if needed), transcribes with the current engine, and on success
    /// writes the real text + clears the failure sentinel. Best-effort: a still-failing
    /// re-run surfaces a banner and leaves the note as-is.
    public func retranscribe(_ id: Note.ID) async {
        guard let note = notes.first(where: { $0.id == id }) else { return }
        guard let url = audioURL(for: note) else {
            banner = "No audio to re-transcribe for this note."
            return
        }
        retranscribing.insert(id)
        defer { retranscribing.remove(id) }
        do {
            let result = try await TranscriptionService(engine: settings.engine).transcribe(url: url)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                banner = "Still couldn't make out any speech in that recording."
                return
            }
            guard let entity = entity(for: id) else { return }
            entity.transcript = text
            entity.engineUsed = result.engineUsed   // clears the "error" sentinel
            entity.updatedAt = Date()
            saveAndReload()
        } catch {
            banner = "Re-transcribe failed: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    public func toggleFavorite(_ id: Note.ID) {
        guard let entity = entity(for: id) else { return }
        entity.isFavorite.toggle()
        entity.updatedAt = Date()
        saveAndReload()
    }

    /// Flip a note's **restriction** flag (the export gate, contract §5). Mirrors
    /// `toggleFavorite`: mutate the entity, save, re-project. Because `saveAndReload`
    /// re-runs the corpus export (macOS) through `CorpusGate`, marking a note
    /// restricted removes it — and its tag lines — from `~/Ollie/` on this same pass,
    /// and un-restricting it re-exports it. No gate wiring is needed here; the
    /// save → reload → export path already carries the change.
    public func setRestricted(_ restricted: Bool, for id: Note.ID) {
        guard let entity = entity(for: id) else { return }
        guard entity.isRestricted != restricted else { return }
        entity.isRestricted = restricted
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

    // MARK: Agent layer — user-facing reads & mutations (Settings + note detail)
    //
    // The human surfaces onto the agent layer (contract §3): the user reads their
    // standing instructions, the agent's memory, and a note's tags, and can edit
    // instructions or hard-delete any derived record (contract §0: "users may delete
    // anything"). All of it funnels through `AgentLayerStore` — the single write
    // choke point — over the app's write context, then re-projects (which, on macOS,
    // re-exports the gated `~/Ollie/` layer files so a deletion propagates promptly).

    /// The agent tags on one note, newest first — filtered from the published
    /// `agentTags` snapshot (which refreshes on every reload). Backs the note-detail
    /// chip row.
    public func tags(forNote id: Note.ID) -> [AgentTag] {
        agentTags.filter { $0.noteId == id }
    }

    /// The user's standing instructions to agents (contract §2), or "" if unset.
    /// Read on the Settings editor's appear.
    public func agentInstructions() -> String {
        AgentLayerStore(context: modelContext).instructions()
    }

    /// Save the user's standing instructions (Settings editor "done"). Upserts the
    /// single well-known record and re-projects/re-exports.
    public func setAgentInstructions(_ text: String) {
        AgentLayerStore(context: modelContext).setInstructions(text)
        saveAndReload()
    }

    /// User hard-delete of one agent tag (contract §0). Removes the record and
    /// re-projects (so the chip disappears and, on macOS, `tags.jsonl` refreshes).
    public func userDelete(tag: AgentTag) {
        AgentLayerStore(context: modelContext).userDelete(tag: tag)
        saveAndReload()
    }

    /// User hard-delete of one agent memory entry (contract §0) — distinct from an
    /// agent `retire`, which only tombstones. Removes it outright and re-projects.
    public func userDelete(memory: AgentMemory) {
        AgentLayerStore(context: modelContext).userDelete(memory: memory)
        saveAndReload()
    }

    // MARK: Views surface (the Views feed + detail, contract §5)

    /// All revisions of one view, newest first — read from the published `agentViews`
    /// snapshot so the detail's "earlier revisions" list stays live (refreshes when a
    /// new revision syncs in). Empty for an unknown view.
    public func revisions(forView name: String) -> [AgentViewRevision] {
        agentViews.revisions(forView: name)
    }

    /// Build the ``ViewInteractionModel`` for a **displayed** view revision (Views v2
    /// spec §4) — the write-path brain a pane owns while showing that revision and
    /// wires into `MarkdownLite`'s `ChecklistHook`. It reads/writes interaction state
    /// through an `AgentLayerStore` over the app's write context (the same context all
    /// other mutations use), stamps the surface (`"mac"` | `"ios"`), and — via
    /// `onCommit` — re-projects after a settle that actually wrote, so a toggle
    /// refreshes the published snapshots and, on macOS, `interactions.jsonl`. The
    /// commit's own `ModelContext.save()` has already landed by then, so `onCommit`
    /// only needs to re-read (no second save).
    ///
    /// One model per *displayed revision*: the pane rebuilds it when the shown view or
    /// revision changes (so the supersession boundary — the revision's `createdAt` —
    /// stays correct), committing the old one at that boundary first.
    public func interactionModel(for revision: AgentViewRevision) -> ViewInteractionModel {
        #if os(macOS)
        let surface = "mac"
        #else
        let surface = "ios"
        #endif
        return ViewInteractionModel(
            store: AgentLayerStore(context: modelContext),
            viewName: revision.viewName,
            revision: revision,
            surface: surface,
            onCommit: { [weak self] in self?.reloadNotes() })
    }

    /// The view name the user has pinned to the top of the Views feed, or `nil`.
    /// Backed by the per-device `NotesSettings.pinnedViewName`.
    public var pinnedViewName: String? { settings.pinnedViewName }

    /// Pin a view to the top of the Views feed (`nil` clears the pin). Per-device
    /// preference — writing `settings` persists it via the `didSet` in `settings`.
    /// No re-export/reload: pinning is a display-only device preference, not a store
    /// record, so the published snapshots are unaffected.
    public func setPinnedView(_ name: String?) {
        guard settings.pinnedViewName != name else { return }
        settings.pinnedViewName = name
    }

    /// Toggle whether a view is pinned: pins it if it isn't the current pin, else
    /// clears the pin. The Views UI's pin/unpin button target.
    public func togglePinnedView(_ name: String) {
        setPinnedView(settings.pinnedViewName == name ? nil : name)
    }

    /// User delete of a whole view (contract §0: users may delete anything) — removes
    /// every revision sharing the name, then re-projects (so the row disappears and,
    /// on macOS, `views.jsonl` refreshes). Clears the pin if the deleted view was
    /// pinned so a dangling pin can't survive.
    public func userDelete(view name: String) {
        AgentLayerStore(context: modelContext).userDelete(view: name)
        if settings.pinnedViewName == name { settings.pinnedViewName = nil }
        saveAndReload()
    }

    /// Restore an earlier view revision (plan §M8 8b, the "time machine"): append a new
    /// revision copying the given revision's body, attributed `user-<surface>` (the
    /// surface stamped from the build platform), then re-project (so the latest flips
    /// and, on macOS, `views.jsonl` refreshes). History is append-only — the source
    /// revision is untouched. An unknown `revisionId` is a safe no-op.
    public func userRestore(viewName: String, revisionId: UUID) {
        #if os(macOS)
        let surface = "mac"
        #else
        let surface = "ios"
        #endif
        AgentLayerStore(context: modelContext)
            .userRestore(viewName: viewName, revisionId: revisionId, surface: surface)
        saveAndReload()
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
        #if os(macOS)
        // A GENUINE wipe: force-clear the corpus (bypass the empty-export guard, which
        // otherwise refuses to overwrite a non-empty corpus with 0 notes). Safe here —
        // we snapshotted to ~/Ollie/backups above, so the wipe stays recoverable.
        CorpusExporter.exportInBackground(notes, allowEmpty: true)
        #endif
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
        let entities: [NoteEntity]
        do {
            entities = try readContext.fetch(descriptor)
        } catch {
            // A FETCH FAILURE is NOT "the user has zero notes." The post-sleep
            // NSPersistentCloudKitContainer wedge ("file couldn't be opened", July
            // 2026) makes the store momentarily unreadable; treating that as an
            // empty corpus is what blanked the UI and wiped the ~/Ollie export.
            // Keep the current projection and let the wake-resync retry re-read once
            // the store settles — never clobber good state with a transient failure.
            Diag.log("HNDIAG reloadNotes fetch FAILED — keeping current \(notes.count)-note projection: \(error)")
            return
        }
        notes = entities.map(Note.init(entity:))
        // Keep system Spotlight in sync with the live projection (best-effort, async).
        SpotlightIndexer.index(notes)

        // Project the agent layer from the SAME fresh read context — so a layer record
        // the inbox ingestor or a CloudKit import just persisted surfaces on this pass,
        // exactly like the notes do. Feeds the published trust-surface snapshots
        // (note-detail tag chips, the AI-memory screen) on every platform, and (macOS)
        // the ~/Ollie export. `AgentLayerStore` is MainActor (we're on it).
        let layerStore = AgentLayerStore(context: readContext)
        let allTags = layerStore.allTags()
        let allMemory = layerStore.memory(includeRetired: true)
        agentTags = allTags
        agentMemory = allMemory

        // Views layer (contract §5): gather every revision across all views (there is
        // no single all-revisions query; views are few, so flattening each view's
        // newest-first revision list is cheap). Group them by exact `viewName` and take
        // each group's head as that view's latest — the two shapes the Views feed +
        // detail read. Published on EVERY platform (the iOS Views tab consumes it too),
        // and reused below for the macOS export so there's a single projection pass.
        let viewNames = layerStore.viewNames()                  // newest-view first
        var revisionsByView: [String: [AgentViewRevision]] = [:]
        var latestRevisions: [AgentViewRevision] = []
        var allRevisions: [AgentViewRevision] = []
        for name in viewNames {
            let revs = layerStore.revisions(viewName: name)     // newest first
            revisionsByView[name] = revs
            allRevisions.append(contentsOf: revs)
            if let latest = revs.first { latestRevisions.append(latest) }
        }
        // `viewNames()` is already ordered by each view's latest revision, so
        // `latestRevisions` is newest-view first — the feed's row order.
        agentViews = AgentLayerSnapshot(latest: latestRevisions, revisionsByView: revisionsByView)

        #if os(macOS)
        // Rung 3 + agent layer: mirror the corpus AND the agent layer to ~/Ollie
        // (JSONL + Markdown) for external tools (Obsidian, the Ollie MCP server, any
        // LLM). Mac-only for now; off-main, best-effort. The gate (restricted notes +
        // their tags) is applied inside `CorpusExporter` via `CorpusGate`. The snapshot's
        // value types are all Sendable, so it rides safely into the detached export task.
        //
        // `views.jsonl` is EVERY revision, full body (contract §5) — reuse the
        // `allRevisions` gathered above rather than re-querying. `interactions.jsonl`
        // (Views v2 spec §6) is the live per-block state across all views; the exporter
        // orphan-prunes it against `allRevisions` before writing.
        let layer = CorpusExporter.LayerSnapshot(
            tags: allTags,
            memory: allMemory,
            viewRevisions: allRevisions,
            instructions: layerStore.instructions(),
            interactions: layerStore.allInteractions())
        CorpusExporter.exportInBackground(notes, layer: layer)
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
        // 3) The inbox ingestor applied a batch of external ops (contract §4). It
        //    writes through a context on the same store, so `didSave` above already
        //    fires — but the ingestor posts this explicit signal too so the re-export
        //    is a deliberate, once-per-batch consequence of ingestion rather than an
        //    incidental side effect of a save. Same handler: re-project + re-export.
        NotificationCenter.default.addObserver(
            forName: InboxIngestor.didApplyBatch,
            object: nil, queue: .main, using: refresh)
    }

    /// After the Mac wakes from sleep, re-project the store a few times with backoff.
    ///
    /// **Why (verified July 2026).** An `NSPersistentCloudKitContainer` import that
    /// is in flight when the Mac sleeps can finish on wake with "file couldn't be
    /// opened" (Cocoa 256), leaving the store handle momentarily unreadable and the
    /// model projected empty — with nothing re-triggering a read once the store
    /// settles, so the corpus stayed at 0 until a manual relaunch. On wake we retry
    /// `reloadNotes()` with backoff: the first read may still fail (kept harmless by
    /// the fetch-failure guard in `reloadNotes` + the empty-corpus guard in
    /// `CorpusExporter`), and a later retry succeeds once NSPCC recovers, so the
    /// notes reappear on their own. macOS-only (iOS apps are suspended, not "woken").
    private func observeWakeResync() {
        #if os(macOS)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak self] _ in
            Diag.log("HNDIAG wake: re-projecting notes after sleep")
            Task { @MainActor [weak self] in
                for delay: Duration in [.milliseconds(750), .seconds(3), .seconds(8)] {
                    try? await Task.sleep(for: delay)
                    guard let self else { return }
                    self.reloadNotes()
                }
            }
        }
        #endif
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
            mic.preferredMicrophoneName = settings.microphoneName
            captureURL = try await mic.start()
            captureMode = .draft
            recordingState = .recording
            startMicLevelPolling()
        } catch {
            banner = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            recordingState = .error(banner ?? "recording failed")
        }
    }

    /// Stop the mic, transcribe, and APPEND the result to the active draft.
    public func stopRecordingAndAppend() async {
        guard isRecording, captureMode == .draft else { return }
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

    // MARK: Quick Capture — dictate → transcribe → save, zero interaction
    //
    // The global-shortcut path (hold-to-dictate / toggle). Unlike the draft flow,
    // a finished quick capture SAVES ITSELF: release the key and the note lands in
    // the corpus, transcribed behind the scenes. Failure can't lose anything — a
    // failed/timed-out transcription saves the audio with a placeholder that the
    // Re-transcribe banner recovers. With `confirmQuickCaptureBeforeSaving` ON, a
    // Save/Discard confirmation (↩ / ⇥␣) is interposed instead.

    /// Which flow the live mic capture belongs to: the in-app draft (append +
    /// explicit conclude) or a quick capture (auto-save on stop).
    public enum CaptureMode: Equatable, Sendable { case draft, quick }
    @Published public private(set) var captureMode: CaptureMode = .draft

    /// A finished quick capture awaiting the user's Save/Discard choice (only when
    /// `confirmQuickCaptureBeforeSaving` is on). The Mac app observes this and
    /// presents the confirmation.
    public struct PendingQuickCapture: Equatable, Sendable {
        public let noteID: UUID
        public let text: String
        public let storedAudioName: String
        public let durationSeconds: Double?
        public let engineUsed: String?
    }
    @Published public var pendingQuickCapture: PendingQuickCapture?

    /// Incremented when the quick-pad shortcut fires; the Mac app observes it and
    /// pops the pad. A count (not a Bool) so back-to-back requests all signal.
    @Published public var quickPadRequestCount = 0

    /// Ignore accidental taps: a hold shorter than this saves nothing.
    private static let quickCaptureMinimumSeconds = 0.5
    private var quickCaptureStartedAt: Date?

    public func startQuickCapture() async {
        guard !isRecording, !isTranscribing, pendingQuickCapture == nil else { return }
        do {
            mic.preferredMicrophoneName = settings.microphoneName
            captureURL = try await mic.start()
            captureMode = .quick
            quickCaptureStartedAt = Date()
            recordingState = .recording
            startMicLevelPolling()
        } catch {
            banner = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            recordingState = .error(banner ?? "recording failed")
        }
    }

    /// Tap-to-start / tap-to-stop entry point (the toggle shortcut + menu bar).
    public func toggleQuickCapture() async {
        if isRecording {
            // Only stop a capture the QUICK flow owns — never yank a draft recording.
            guard captureMode == .quick else { return }
            await stopQuickCaptureAndSave()
        } else {
            await startQuickCapture()
        }
    }

    public func stopQuickCaptureAndSave() async {
        guard isRecording, captureMode == .quick else { return }
        stopMicLevelPolling()
        let url: URL
        do {
            url = try mic.stop()
        } catch {
            recordingState = .idle
            banner = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return
        }
        defer { try? FileManager.default.removeItem(at: url) }

        // Accidental tap: sub-half-second hold → discard silently, no junk note.
        if let started = quickCaptureStartedAt,
           Date().timeIntervalSince(started) < Self.quickCaptureMinimumSeconds {
            recordingState = .idle
            return
        }
        quickCaptureStartedAt = nil

        recordingState = .transcribing
        let noteID = UUID()
        do {
            // Imports the audio into the store FIRST (capture can't be lost), then
            // transcribes — a throw inside is already turned into placeholder text.
            let clip = try await pipeline.transcribeClip(audioURL: url, noteID: noteID)
            recordingState = .idle
            let pending = PendingQuickCapture(
                noteID: noteID, text: clip.text, storedAudioName: clip.storedAudioName,
                durationSeconds: clip.durationSeconds, engineUsed: clip.engineUsed)
            if settings.confirmQuickCaptureBeforeSaving {
                pendingQuickCapture = pending    // the app presents Save/Discard
            } else {
                save(quickCapture: pending)      // the default: it just saves
            }
        } catch {
            // transcribeClip only throws if the AUDIO IMPORT failed — nothing stored.
            recordingState = .idle
            banner = "Couldn't save the capture: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    /// Resolve a confirmation: save the pending capture or discard it (with its audio).
    public func resolveQuickCapture(save shouldSave: Bool) {
        guard let pending = pendingQuickCapture else { return }
        pendingQuickCapture = nil
        if shouldSave {
            save(quickCapture: pending)
        } else {
            NotesStore.deleteAudio(named: pending.storedAudioName)
        }
    }

    private func save(quickCapture pending: PendingQuickCapture) {
        let note = Note(
            id: pending.noteID,
            transcript: pending.text,
            kind: .voice,
            source: Self.localCaptureSource,
            audioFileName: pending.storedAudioName,
            durationSeconds: pending.durationSeconds,
            engineUsed: pending.engineUsed)
        insert(note, select: false)   // discreet: don't yank the UI's selection
        stampLocationIfEnabled(for: note)
    }

    /// Save a typed quick-pad note (the ⇧↩ path). Whitespace-only is a no-op.
    public func saveQuickTextNote(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let note = Note(transcript: trimmed, kind: .text, source: Self.localCaptureSource)
        insert(note, select: false)
        stampLocationIfEnabled(for: note)
    }

    /// What a note captured directly on THIS device is tagged as.
    private static var localCaptureSource: NoteSource {
        #if os(macOS)
        return .computer
        #else
        return .phone
        #endif
    }

    /// Input devices available to record from — for the Settings mic picker. Empty
    /// where device selection doesn't apply (iOS/watchOS follow the system route).
    public static func availableMicrophones() -> [String] {
        MicCaptureService.availableInputDevices()
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
        // Quick Capture global shortcuts (macOS). No factory (e.g. iOS) → none;
        // the in-app UI still records into the draft.
        guard let captureHotKeyFactory else { return }
        hotKey = captureHotKeyFactory { [weak self] action, pressed in
            guard let self else { return }
            switch action {
            case .holdToDictate:
                if pressed { Task { await self.startQuickCapture() } }
                else { Task { await self.stopQuickCaptureAndSave() } }
            case .toggleDictation:
                guard pressed else { return }   // act on press; ignore the release
                Task { await self.toggleQuickCapture() }
            case .quickPad:
                guard pressed else { return }
                self.quickPadRequestCount += 1
            }
        }
        applyHotKeyBindings()
    }

    /// (Re)register the current shortcut assignments — called at init and whenever
    /// a shortcut setting changes.
    private func applyHotKeyBindings() {
        hotKey?.apply(bindings: settings.captureHotKeyBindings)
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
