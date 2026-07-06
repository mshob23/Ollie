import Foundation
import SwiftData

/// The **inbox door**: the one external write path into the agent layer (contract
/// §4). External agents (the MCP server, a launchd runner) drop op files into
/// `~/Ollie/inbox/`; this ingestor validates each one *mechanically*, applies it
/// through ``AgentLayerStore`` (the single write choke point), echoes the outcome,
/// dedupes by `requestId`, and cleans up — then nudges a re-export so the mirror
/// under `~/Ollie/` reflects the new records promptly.
///
/// **Mac-only.** The Mac app is "the only store writer" (contract §0); iOS does not
/// ingest an inbox in this plan. It is wired up in `AppDelegate` and holds a
/// reference for the app's lifetime.
///
/// ## What one file goes through
/// 1. **Size gate** — a file larger than ``maxFileBytes`` (256 KB) is untrusted;
///    it is *moved* to `inbox/rejected/` (never read into memory) and echoed.
/// 2. **Decode** — the bytes must parse as an ``AgentOp`` envelope (contract §3.4).
///    A file that isn't valid envelope JSON is **malformed**: moved to
///    `inbox/rejected/` for postmortem (contract §4 — malformed files are *moved,
///    not deleted*), and echoed best-effort.
/// 3. **Ledger** — a `requestId` already in the recent-ledger (ring buffer of the
///    last ``ledgerCapacity`` = 1000) is a duplicate; it is **rejected without
///    re-applying** (idempotency), echoed, and its op file deleted.
/// 4. **Apply** — ``AgentLayerStore/apply(_:)`` validates the payload (ids/sizes)
///    and writes the derived record, or throws ``AgentLayerError``. A throw →
///    rejected echo + delete; success → applied echo + delete + the `requestId`
///    is recorded in the ledger.
///
/// A **decoded** envelope (steps 3–4) is always echoed to `applied.jsonl` /
/// `rejected.jsonl` and its op file **deleted** (contract §4 — "deleted after
/// echo"). Only step 1/2 failures (untrusted/undecodable bytes) *move* the file to
/// `inbox/rejected/` instead, because there is nothing safe to hand `apply`.
///
/// ## When it runs
/// A `DispatchSourceFileSystemObject` fires when the inbox directory changes (a
/// rename lands), a 30 s fallback timer catches anything the vnode source missed
/// (e.g. a write that didn't register, or a source that had to be re-armed), and a
/// **full scan on start** drains whatever accumulated while the app was closed —
/// which is also the crash-recovery path: a valid op left behind by a crash mid-way
/// is simply re-applied on next launch (a re-applied `tag` is a no-op, so this is
/// safe).
///
/// `@MainActor` because ``AgentLayerStore`` (and the SwiftData context it wraps) is
/// main-actor-bound, exactly like `AppModel`'s write path. The vnode source and the
/// timer fire on a background queue but hop back here to touch the store.
@MainActor
public final class InboxIngestor {

    // MARK: - Constants (contract §4)

    /// Envelope files above this size are untrusted and never read into memory —
    /// they're moved straight to `inbox/rejected/` (contract §4: "file ≤ 256 KB").
    public static let maxFileBytes = 256 * 1024

    /// The idempotency ledger holds at most this many recent `requestId`s (contract
    /// §4: "ring buffer of the last 1000 requestIds"). Older ids age out; a duplicate
    /// within the window is rejected without re-applying.
    public static let ledgerCapacity = 1000

    /// The fallback sweep interval — a belt-and-suspenders drain in case the vnode
    /// source misses an event (contract §4 door: "DispatchSource watch + 30 s
    /// fallback timer + startup scan").
    public static let fallbackInterval: TimeInterval = 30

    /// Posted **once per batch** after at least one op applied, so `AppModel`
    /// re-exports the layer promptly (the export mirrors `~/Ollie/tags.jsonl` etc.).
    /// Mirrors how `.NSPersistentStoreRemoteChange` flows into a `reloadNotes()` —
    /// the ingestor is just another change source. Carries no payload; the observer
    /// re-reads the store wholesale.
    public static let didApplyBatch = Notification.Name("Ollie.InboxIngestor.didApplyBatch")

    // MARK: - Dependencies & state

    /// The container the per-batch ``AgentLayerStore`` writes through. The Mac app
    /// passes `NotesDataStore.shared` (the same process-wide store `AppModel` and the
    /// App Intents read), so an applied op is visible to the very next `reloadNotes`
    /// export; tests pass an isolated in-memory container.
    private let container: ModelContainer

    /// The recent-`requestId` ledger, loaded from `.applied-requests.json` on start
    /// and kept in memory (persisted after every applied op). Order is oldest→newest;
    /// the newest ``ledgerCapacity`` are retained. A `Set` alongside would be faster
    /// to query, but at N=1000 a linear `contains` is trivially cheap and keeping a
    /// single ordered array as the source of truth avoids the two drifting.
    private var ledger: [UUID] = []

    /// The live directory-watch source, retained so it isn't cancelled. `nil` until
    /// ``start()`` opens the inbox fd, and whenever the source has to be re-armed
    /// (the directory being replaced invalidates the old fd). Each source owns and
    /// closes its own fd via its cancel handler (the fd is captured by value there),
    /// so there is no shared descriptor state to double-close on teardown/re-arm.
    private var watchSource: DispatchSourceFileSystemObject?

    /// The 30 s fallback timer (a GCD timer on a utility queue; its handler hops to
    /// the main actor to drain).
    private var fallbackTimer: DispatchSourceTimer?

    /// A serialized-drain guard. A vnode event and the fallback timer can race; a
    /// re-entrant drain would double-process a file. Set for the duration of one
    /// `drain()` so overlapping triggers coalesce into one pass.
    private var isDraining = false

    /// True once ``start()`` has run — makes start idempotent and lets `stop()`/deinit
    /// tear the source down cleanly.
    private var started = false

    public init(container: ModelContainer) {
        self.container = container
    }

    deinit {
        // Can't hop to the main actor from a (nonisolated) deinit — just cancel the
        // GCD sources (thread-safe). Cancelling the watch source runs its cancel
        // handler, which closes the fd it captured; the timer holds no such resource.
        watchSource?.cancel()
        fallbackTimer?.cancel()
    }

    // MARK: - Lifecycle

    /// Begin ingesting: ensure the inbox tree exists, load the ledger, drain whatever
    /// accumulated while the app was closed (startup scan = crash recovery), then arm
    /// the directory watch + the 30 s fallback timer. Idempotent.
    public func start() {
        guard !started else { return }
        started = true
        ensureDirectories()
        loadLedger()
        drain()                 // startup scan
        armWatch()
        armFallbackTimer()
    }

    /// Tear down the watch source and timer (mirrors what `deinit` does, but on the
    /// main actor). Not required by the app — the ingestor lives for the process —
    /// but tests use it to stop the timer between cases.
    public func stop() {
        watchSource?.cancel()   // cancel handler closes the captured fd
        watchSource = nil
        fallbackTimer?.cancel()
        fallbackTimer = nil
        started = false
    }

    /// Process every op file currently in the inbox, once. Public so a test (or a
    /// future manual "check inbox now" affordance) can drive a single pass
    /// deterministically without waiting on the timer. Coalesces with any in-flight
    /// drain so overlapping triggers never double-process a file.
    public func drain() {
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }

        let files = pendingOpFiles()
        guard !files.isEmpty else { return }

        var appliedAny = false
        let layer = AgentLayerStore(context: ModelContext(container))
        for url in files {
            if process(url, layer: layer) { appliedAny = true }
        }

        // One reload per batch (not per op): re-export so `~/Ollie/*.jsonl` reflects
        // the applied records. Only when something actually applied — a batch of pure
        // rejects/dupes changed no store state, so there's nothing new to mirror.
        if appliedAny {
            NotificationCenter.default.post(name: Self.didApplyBatch, object: nil)
        }
    }

    // MARK: - Per-file processing

    /// Handle one op file end-to-end. Returns `true` iff it resulted in an applied op
    /// (so the caller knows whether to trigger a re-export). Never throws — every
    /// failure mode is handled locally (echo + delete, or move-to-rejected).
    private func process(_ url: URL, layer: AgentLayerStore) -> Bool {
        let fm = FileManager.default

        // 1) Size gate — an oversized file is untrusted; don't even read it. Move it
        //    aside and echo best-effort (no reliable requestId to cite).
        if let size = fileSize(url), size > Self.maxFileBytes {
            echoRejected(requestId: nil, op: nil, agent: nil, ts: Date(),
                         reason: "file exceeds \(Self.maxFileBytes)-byte cap")
            moveToRejected(url)
            return false
        }

        // 2) Decode the envelope. Unreadable/undecodable bytes are MALFORMED: move to
        //    inbox/rejected/ (contract §4 — malformed files are moved, not deleted).
        guard let data = try? Data(contentsOf: url) else {
            echoRejected(requestId: nil, op: nil, agent: nil, ts: Date(), reason: "unreadable file")
            moveToRejected(url)
            return false
        }
        guard let op = decode(data) else {
            echoRejected(requestId: nil, op: nil, agent: nil, ts: Date(), reason: "malformed envelope")
            moveToRejected(url)
            return false
        }

        // 3) Ledger / idempotency — a requestId we've already applied is a duplicate.
        //    Reject WITHOUT re-applying, then delete the op file (it decoded, so it's
        //    cleanup-by-delete, not move-to-rejected).
        if ledger.contains(op.requestId) {
            echoRejected(requestId: op.requestId, op: op.op, agent: op.agent, ts: op.ts,
                         reason: "duplicate requestId")
            try? fm.removeItem(at: url)
            return false
        }

        // 4) Apply through the single write choke point. Mechanical failure → reject.
        do {
            try layer.apply(op)
        } catch {
            let reason = (error as? AgentLayerError)?.errorDescription ?? error.localizedDescription
            echoRejected(requestId: op.requestId, op: op.op, agent: op.agent, ts: op.ts, reason: reason)
            try? fm.removeItem(at: url)
            return false
        }

        // Applied: record the requestId (so a re-delivery is a no-op), echo, delete.
        remember(op.requestId)
        echoApplied(requestId: op.requestId, op: op.op, agent: op.agent, ts: op.ts)
        try? fm.removeItem(at: url)
        return true
    }

    /// Decode an ``AgentOp`` envelope from op-file bytes. ISO-8601 dates (matching the
    /// envelope's `ts` and the writer). Returns `nil` on any decode failure — the
    /// caller treats that as malformed.
    private func decode(_ data: Data) -> AgentOp? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(AgentOp.self, from: data)
    }

    // MARK: - Echoes (contract §4)

    /// Append an `applied` line to `~/Ollie/applied.jsonl`.
    private func echoApplied(requestId: UUID?, op: String?, agent: String?, ts: Date) {
        appendEcho(to: appliedURL,
                   record: EchoRecord(requestId: requestId?.uuidString, op: op, agent: agent,
                                      ts: ts, result: "applied", reason: nil))
    }

    /// Append a `rejected` line to `~/Ollie/rejected.jsonl`, with the reason.
    private func echoRejected(requestId: UUID?, op: String?, agent: String?, ts: Date, reason: String) {
        appendEcho(to: rejectedURL,
                   record: EchoRecord(requestId: requestId?.uuidString, op: op, agent: agent,
                                      ts: ts, result: "rejected", reason: reason))
    }

    /// One echo line — contract §4:
    /// `{"requestId","op","agent","ts","result":"applied"|"rejected","reason"?}`.
    /// `requestId`/`op`/`agent` are optional at the wire level because a malformed
    /// file may have none of them to cite; the encoder omits nil keys.
    private struct EchoRecord: Encodable {
        let requestId: String?
        let op: String?
        let agent: String?
        let ts: Date
        let result: String
        let reason: String?
    }

    /// Append one JSONL echo line atomically-enough for a single writer: read the
    /// existing file, append the encoded line + newline, write back. The ingestor is
    /// the sole writer of these files (contract: the app is the only store writer), so
    /// there's no concurrent-append race to guard against; a simple read-append-write
    /// keeps the whole file consistent and never truncates on a mid-write crash (the
    /// write is atomic). Best-effort: a failure is logged, never fatal.
    private func appendEcho(to url: URL, record: EchoRecord) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let lineData = try? enc.encode(record),
              let line = String(data: lineData, encoding: .utf8) else {
            Diag.log("HNDIAG inbox echo FAILED to encode a \(record.result) record")
            return
        }
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let combined = existing + line + "\n"
        do {
            try combined.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Diag.log("HNDIAG inbox echo FAILED to write \(url.lastPathComponent): \(error)")
        }
    }

    // MARK: - Ledger (contract §4: ring buffer of the last 1000 requestIds)

    /// Load the ledger from `.applied-requests.json` (an array of UUID strings,
    /// oldest→newest). A missing/corrupt file starts empty.
    ///
    /// **Crash recovery.** `process` persists a `requestId` to the ledger *before* it
    /// deletes the op file, so if a crash lands between apply and delete, the startup
    /// re-scan finds the id here and rejects the leftover file as a duplicate — the op
    /// is not applied twice. Only a crash in the narrow window *between* apply and the
    /// ledger write would re-apply; that's a no-op for the idempotent ops
    /// (`tag`/`untag`/`memory.retire`), which is the crash-recovery guarantee the
    /// contract cares about.
    private func loadLedger() {
        guard let data = try? Data(contentsOf: ledgerURL),
              let ids = try? JSONDecoder().decode([String].self, from: data) else {
            ledger = []
            return
        }
        ledger = ids.compactMap(UUID.init(uuidString:))
        trimLedger()
    }

    /// Record an applied `requestId` and persist the ledger. Appends newest-last and
    /// trims to the capacity window.
    private func remember(_ id: UUID) {
        ledger.append(id)
        trimLedger()
        saveLedger()
    }

    /// Drop the oldest ids beyond ``ledgerCapacity`` (keep the most-recent 1000).
    private func trimLedger() {
        if ledger.count > Self.ledgerCapacity {
            ledger.removeFirst(ledger.count - Self.ledgerCapacity)
        }
    }

    /// Persist the ledger to `.applied-requests.json` (atomic). Best-effort — a
    /// failure just means a duplicate could slip through on the next launch (still
    /// safe for idempotent ops).
    private func saveLedger() {
        let ids = ledger.map(\.uuidString)
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        do {
            let data = try enc.encode(ids)
            try data.write(to: ledgerURL, options: [.atomic])
        } catch {
            Diag.log("HNDIAG inbox ledger FAILED to write: \(error)")
        }
    }

    // MARK: - Filesystem watch

    /// Open the inbox directory and arm a vnode source that fires on writes/renames
    /// into it (a new op file landing shows up as `.write`). On fire, drain on the
    /// main actor. If the directory is deleted/replaced out from under us, re-arm.
    ///
    /// **fd ownership.** The fd is captured *by value* by the source's handlers and
    /// closed exactly once, in the cancel handler (GCD runs it once the source is
    /// fully torn down). `stop()` / re-arm / `deinit` only `cancel()` — they never
    /// close the fd — so there is no double-close.
    private func armWatch() {
        watchSource?.cancel()   // re-arm: retire the old source (closes its own fd)
        watchSource = nil

        let fd = open(inboxDir.path, O_EVTONLY)
        guard fd >= 0 else {
            Diag.log("HNDIAG inbox watch: could not open \(inboxDir.path) (O_EVTONLY); relying on 30s timer")
            return
        }
        // Build the source (and its GCD-queue handlers) in a `nonisolated` context so
        // the handler closures are NOT `@MainActor`-isolated — GCD invokes them on a
        // background queue, and an isolated closure would trip Swift's executor
        // assertion there (a SIGTRAP). The handlers hop back to the main actor via
        // `onEvent`, which is a `@Sendable` callback into this actor.
        let source = Self.makeWatchSource(fd: fd) { [weak self] didInvalidate in
            Task { @MainActor in
                guard let self else { return }
                if didInvalidate {          // directory replaced — fd is stale, re-arm
                    self.ensureDirectories()
                    self.armWatch()
                }
                self.drain()
            }
        }
        watchSource = source
        source.resume()
    }

    /// Construct the vnode source and install its handlers **off** the main actor, so
    /// the GCD-queue closures carry no actor isolation. `onEvent(didInvalidate:)` is
    /// called on the source's utility queue when the directory changes;
    /// `didInvalidate` is true when the directory inode itself was renamed/deleted
    /// (the caller must re-arm). The cancel handler closes the captured `fd` exactly
    /// once at teardown.
    private nonisolated static func makeWatchSource(
        fd: Int32,
        onEvent: @escaping @Sendable (_ didInvalidate: Bool) -> Void
    ) -> DispatchSourceFileSystemObject {
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: DispatchQueue.global(qos: .utility))
        source.setEventHandler { [weak source] in
            let mask = source?.data ?? []   // valid only at handler time
            onEvent(mask.contains(.delete) || mask.contains(.rename))
        }
        source.setCancelHandler { close(fd) }   // sole fd owner; runs once
        return source
    }

    /// Arm the 30 s fallback drain — a belt-and-suspenders sweep for anything the
    /// vnode source missed. GCD timer; its handler hops to the main actor to drain.
    private func armFallbackTimer() {
        fallbackTimer?.cancel()
        // Same isolation care as `armWatch`: build the timer + its handler in a
        // `nonisolated` context so the GCD closure isn't `@MainActor`-isolated.
        let timer = Self.makeFallbackTimer(interval: Self.fallbackInterval) { [weak self] in
            Task { @MainActor in self?.drain() }
        }
        fallbackTimer = timer
        timer.resume()
    }

    /// Construct the repeating fallback timer off the main actor (handler is a
    /// `@Sendable` GCD callback that hops back to the main actor to drain).
    private nonisolated static func makeFallbackTimer(
        interval: TimeInterval,
        fire: @escaping @Sendable () -> Void
    ) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler(handler: fire)
        return timer
    }

    // MARK: - Paths & directory hygiene

    /// `~/Ollie/inbox` — derived from `CorpusExporter.exportDirectory` so the test
    /// override redirects the inbox, the echoes, and the ledger together with the rest
    /// of `~/Ollie`.
    private var inboxDir: URL {
        CorpusExporter.exportDirectory.appendingPathComponent("inbox", isDirectory: true)
    }
    /// `~/Ollie/inbox/rejected` — postmortem home for malformed/oversized files.
    private var rejectedDir: URL {
        inboxDir.appendingPathComponent("rejected", isDirectory: true)
    }
    private var appliedURL: URL {
        CorpusExporter.exportDirectory.appendingPathComponent("applied.jsonl")
    }
    private var rejectedURL: URL {
        CorpusExporter.exportDirectory.appendingPathComponent("rejected.jsonl")
    }
    private var ledgerURL: URL {
        CorpusExporter.exportDirectory.appendingPathComponent(".applied-requests.json")
    }

    /// Ensure `inbox/` and `inbox/rejected/` exist (both are needed before watching /
    /// moving files). Best-effort — failures surface later as read/move failures that
    /// are themselves handled.
    private func ensureDirectories() {
        let fm = FileManager.default
        try? fm.createDirectory(at: inboxDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: rejectedDir, withIntermediateDirectories: true)
    }

    /// The op files awaiting processing: top-level `*.json` under `inbox/`, excluding
    /// the `rejected/` subdirectory. Sorted by name for deterministic order (a stable
    /// order makes tests reproducible and batch echoes ordered).
    private func pendingOpFiles() -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: inboxDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return [] }
        return entries
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Move a malformed/oversized file into `inbox/rejected/` for postmortem. If a
    /// file of the same name already sits there (a re-delivered malformed op), replace
    /// it — the latest bytes are what a human would want to inspect. Falls back to
    /// deletion only if the move is impossible (better than leaving it to loop on
    /// every drain).
    private func moveToRejected(_ url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: rejectedDir, withIntermediateDirectories: true)
        let dest = rejectedDir.appendingPathComponent(url.lastPathComponent)
        try? fm.removeItem(at: dest)          // replace any prior copy
        do {
            try fm.moveItem(at: url, to: dest)
        } catch {
            Diag.log("HNDIAG inbox: could not move malformed \(url.lastPathComponent) to rejected/: \(error); deleting")
            try? fm.removeItem(at: url)
        }
    }

    /// The byte size of a file, or `nil` if it can't be stat'd.
    private func fileSize(_ url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }
}
