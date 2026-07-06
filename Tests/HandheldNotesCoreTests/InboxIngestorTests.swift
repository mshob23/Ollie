import Foundation
import SwiftData
import XCTest
@testable import HandheldNotesCore

/// Exercises `InboxIngestor` — the inbox door (contract §4) — over an in-memory store
/// and a temp `~/Ollie` (via `CorpusExporter.exportDirectoryOverride`, which redirects
/// the inbox, echoes, and ledger together). Covers: a valid op of **each** type
/// applies + echoes to `applied.jsonl` + deletes its file; a **duplicate requestId**
/// is rejected via the ledger without re-applying; **oversized** and **malformed**
/// files land in `inbox/rejected/` and echo to `rejected.jsonl`; and **crash recovery**
/// — a leftover op file is re-applied on the next scan, and a re-delivered `tag` is a
/// no-op.
///
/// Processing is driven **synchronously** via `drain()` (and `start()`, whose startup
/// scan drains inline before arming the watch), so no test waits on the vnode source
/// or the 30 s timer — the file-processing, ledger, and echo logic is what's under
/// test, and it's fully deterministic.
@MainActor
final class InboxIngestorTests: XCTestCase {

    // MARK: - Fixture

    private var dir: URL!
    private var container: ModelContainer!
    private var ingestor: InboxIngestor!
    private var seededNoteId: UUID!

    override func setUp() async throws {
        try await super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ollie-inbox-test-\(UUID().uuidString)", isDirectory: true)
        CorpusExporter.exportDirectoryOverride = dir
        // The inbox dir must exist before we can drop op files into it. (`start()`
        // would create it, but the deterministic tests use `drain()` directly.)
        try? FileManager.default.createDirectory(
            at: inboxDir, withIntermediateDirectories: true)

        container = NotesDataStore.makeContainerForTesting()
        let ctx = ModelContext(container)
        seededNoteId = UUID()
        ctx.insert(NoteEntity(note: Note(id: seededNoteId, transcript: "Subject.", source: .phone)))
        try? ctx.save()

        ingestor = InboxIngestor(container: container)
    }

    override func tearDown() async throws {
        ingestor?.stop()
        ingestor = nil
        container = nil
        CorpusExporter.exportDirectoryOverride = nil
        try? FileManager.default.removeItem(at: dir)
        try await super.tearDown()
    }

    // MARK: - Paths & helpers

    private var inboxDir: URL { dir.appendingPathComponent("inbox", isDirectory: true) }
    private var rejectedDir: URL { inboxDir.appendingPathComponent("rejected", isDirectory: true) }
    private var appliedURL: URL { dir.appendingPathComponent("applied.jsonl") }
    private var rejectedURL: URL { dir.appendingPathComponent("rejected.jsonl") }
    private var ledgerURL: URL { dir.appendingPathComponent(".applied-requests.json") }

    /// A fresh store reader — a leftover-registry-free context, exactly like the app's
    /// per-reload read context, so it reflects the latest *persisted* state.
    private func store() -> AgentLayerStore { AgentLayerStore(context: ModelContext(container)) }

    /// Encode an op the way the ingestor decodes it (ISO-8601 `ts`) and write it into
    /// `inbox/` via temp-name-then-rename (contract §4 — atomic on APFS). Returns the
    /// op file's URL.
    @discardableResult
    private func writeOp(_ op: AgentOp) -> URL {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try! enc.encode(op)
        let dest = inboxDir.appendingPathComponent("\(op.agent)-\(op.requestId.uuidString).json")
        let tmp = inboxDir.appendingPathComponent(".\(UUID().uuidString).tmp")
        try! data.write(to: tmp)
        try! FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    /// Write raw bytes as an op file directly (for malformed/oversized cases that
    /// aren't valid `AgentOp` JSON).
    @discardableResult
    private func writeRawOpFile(named name: String, bytes: Data) -> URL {
        let dest = inboxDir.appendingPathComponent(name)
        try! bytes.write(to: dest)
        return dest
    }

    private func lines(_ url: URL) -> [String] {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// Decode the echo lines of a file into dictionaries for field assertions.
    private func echoRecords(_ url: URL) -> [[String: Any]] {
        lines(url).compactMap {
            guard let d = $0.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
            else { return nil }
            return obj
        }
    }

    private func opFilesInInbox() -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: inboxDir.path)) ?? []
        return entries.filter { $0.hasSuffix(".json") }.sorted()
    }

    private func filesInRejectedDir() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: rejectedDir.path)) ?? []).sorted()
    }

    // MARK: - Valid op of each type: applies + echoes + deletes

    func testTagOpAppliesEchoesAndDeletes() throws {
        let rid = UUID()
        writeOp(.tag(noteId: seededNoteId, tag: "heat-pump", agent: "claude-mac", requestId: rid))

        ingestor.drain()

        // Applied to the store.
        XCTAssertEqual(store().tags(forNote: seededNoteId).map(\.tag), ["heat-pump"])
        // Echoed to applied.jsonl with the right envelope fields, nothing rejected.
        let applied = echoRecords(appliedURL)
        XCTAssertEqual(applied.count, 1)
        XCTAssertEqual(applied.first?["result"] as? String, "applied")
        XCTAssertEqual(applied.first?["op"] as? String, "tag")
        XCTAssertEqual(applied.first?["agent"] as? String, "claude-mac")
        XCTAssertEqual(applied.first?["requestId"] as? String, rid.uuidString)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rejectedURL.path),
                       "a clean apply writes no rejected.jsonl")
        // Op file deleted after echo.
        XCTAssertTrue(opFilesInInbox().isEmpty, "op file must be deleted after a successful apply")
    }

    func testUntagOpApplies() throws {
        // Seed a tag directly, then untag it via the inbox.
        try store().apply(.tag(noteId: seededNoteId, tag: "todo", agent: "seed"))
        XCTAssertEqual(store().tags(forNote: seededNoteId).count, 1)

        writeOp(.untag(noteId: seededNoteId, tag: "todo", agent: "claude-mac"))
        ingestor.drain()

        XCTAssertTrue(store().tags(forNote: seededNoteId).isEmpty, "untag removed the tag")
        XCTAssertEqual(echoRecords(appliedURL).first?["op"] as? String, "untag")
        XCTAssertTrue(opFilesInInbox().isEmpty)
    }

    func testMemoryAppendOpApplies() throws {
        writeOp(.memoryAppend(text: "‘HP’ means heat pump.", agent: "claude-mac"))
        ingestor.drain()

        let mem = store().memory(includeRetired: false)
        XCTAssertEqual(mem.map(\.text), ["‘HP’ means heat pump."])
        XCTAssertEqual(mem.first?.agentId, "claude-mac")
        XCTAssertEqual(echoRecords(appliedURL).first?["op"] as? String, "memory.append")
        XCTAssertTrue(opFilesInInbox().isEmpty)
    }

    func testMemoryRetireOpApplies() throws {
        try store().apply(.memoryAppend(text: "durable fact", agent: "seed"))
        let memId = try XCTUnwrap(store().memory(includeRetired: true).first?.id)

        writeOp(.memoryRetire(id: memId, agent: "claude-mac"))
        ingestor.drain()

        XCTAssertTrue(store().memory(includeRetired: false).isEmpty, "entry is retired")
        let all = store().memory(includeRetired: true)
        XCTAssertEqual(all.count, 1)
        XCTAssertTrue(all.first!.retired)
        XCTAssertEqual(echoRecords(appliedURL).first?["op"] as? String, "memory.retire")
        XCTAssertTrue(opFilesInInbox().isEmpty)
    }

    func testViewPublishOpApplies() throws {
        writeOp(.viewPublish(viewName: "Open loops", body: "- ship the door\n", agent: "claude-mac"))
        ingestor.drain()

        let revs = store().revisions(viewName: "Open loops")
        XCTAssertEqual(revs.count, 1)
        XCTAssertEqual(revs.first?.body, "- ship the door\n")
        XCTAssertEqual(echoRecords(appliedURL).first?["op"] as? String, "view.publish")
        XCTAssertTrue(opFilesInInbox().isEmpty)
    }

    /// All five op types in one batch: every one applies, each echoes exactly one
    /// applied line, and the inbox drains empty.
    func testEveryOpTypeInOneBatch() throws {
        try store().apply(.tag(noteId: seededNoteId, tag: "to-remove", agent: "seed"))
        try store().apply(.memoryAppend(text: "retire me", agent: "seed"))
        let memId = try XCTUnwrap(store().memory(includeRetired: true).first?.id)

        writeOp(.tag(noteId: seededNoteId, tag: "keep", agent: "claude-mac"))
        writeOp(.untag(noteId: seededNoteId, tag: "to-remove", agent: "claude-mac"))
        writeOp(.memoryAppend(text: "new codebook fact", agent: "claude-mac"))
        writeOp(.memoryRetire(id: memId, agent: "claude-mac"))
        writeOp(.viewPublish(viewName: "This week", body: "…", agent: "claude-mac"))

        ingestor.drain()

        XCTAssertEqual(store().tags(forNote: seededNoteId).map(\.tag), ["keep"])
        XCTAssertEqual(store().memory(includeRetired: false).map(\.text), ["new codebook fact"])
        XCTAssertEqual(store().viewNames(), ["This week"])
        XCTAssertEqual(echoRecords(appliedURL).count, 5, "five applied echoes")
        XCTAssertTrue(opFilesInInbox().isEmpty, "all five op files deleted")
    }

    // MARK: - Duplicate requestId: rejected via the ledger

    func testDuplicateRequestIdIsRejectedViaLedger() throws {
        let rid = UUID()
        writeOp(.tag(noteId: seededNoteId, tag: "once", agent: "claude-mac", requestId: rid))
        ingestor.drain()
        XCTAssertEqual(store().tags(forNote: seededNoteId).count, 1)
        XCTAssertEqual(echoRecords(appliedURL).count, 1)

        // Re-deliver the SAME requestId but with a DIFFERENT tag: if the ledger works,
        // it's rejected untouched, so the second tag must never land.
        writeOp(.tag(noteId: seededNoteId, tag: "twice", agent: "claude-mac", requestId: rid))
        ingestor.drain()

        XCTAssertEqual(store().tags(forNote: seededNoteId).map(\.tag), ["once"],
                       "a duplicate requestId must not apply, even with a different payload")
        let rejected = echoRecords(rejectedURL)
        XCTAssertEqual(rejected.count, 1)
        XCTAssertEqual(rejected.first?["result"] as? String, "rejected")
        XCTAssertEqual(rejected.first?["reason"] as? String, "duplicate requestId")
        XCTAssertEqual(rejected.first?["requestId"] as? String, rid.uuidString)
        // The duplicate op file is deleted (it decoded — cleanup by delete, not move).
        XCTAssertTrue(opFilesInInbox().isEmpty)
        XCTAssertTrue(filesInRejectedDir().isEmpty, "a duplicate is not a malformed file")
    }

    /// The ledger persists to `.applied-requests.json` and a FRESH ingestor (new
    /// process) still rejects an already-applied requestId — the dedup survives relaunch.
    func testLedgerPersistsAcrossIngestorInstances() throws {
        let rid = UUID()
        writeOp(.tag(noteId: seededNoteId, tag: "persisted", agent: "claude-mac", requestId: rid))
        ingestor.drain()
        XCTAssertTrue(FileManager.default.fileExists(atPath: ledgerURL.path),
                      "applied requestId is written to the ledger file")

        // A brand-new ingestor loads the ledger on start and rejects the re-delivery.
        let fresh = InboxIngestor(container: container)
        writeOp(.tag(noteId: seededNoteId, tag: "again", agent: "claude-mac", requestId: rid))
        fresh.start()   // start() loads the ledger, then drains (startup scan)
        fresh.stop()

        XCTAssertEqual(store().tags(forNote: seededNoteId).map(\.tag), ["persisted"],
                       "the persisted ledger blocks the re-delivery after a relaunch")
        XCTAssertEqual(echoRecords(rejectedURL).first?["reason"] as? String, "duplicate requestId")
    }

    // MARK: - Oversized / malformed: rejected.jsonl + moved file

    func testOversizedFileIsRejectedAndMoved() throws {
        // A syntactically-plausible but >256 KB file: untrusted, never parsed.
        let big = Data(count: InboxIngestor.maxFileBytes + 1)
        let name = "claude-mac-\(UUID().uuidString).json"
        writeRawOpFile(named: name, bytes: big)

        ingestor.drain()

        // Moved to rejected/, gone from the inbox top level, and echoed.
        XCTAssertEqual(filesInRejectedDir(), [name], "oversized file moved to inbox/rejected/")
        XCTAssertTrue(opFilesInInbox().isEmpty)
        let rejected = echoRecords(rejectedURL)
        XCTAssertEqual(rejected.count, 1)
        XCTAssertEqual(rejected.first?["result"] as? String, "rejected")
        XCTAssertEqual(rejected.first?["reason"] as? String,
                       "file exceeds \(InboxIngestor.maxFileBytes)-byte cap")
    }

    func testMalformedFileIsRejectedAndMoved() throws {
        let name = "claude-mac-\(UUID().uuidString).json"
        writeRawOpFile(named: name, bytes: Data("{ not json at all ".utf8))

        ingestor.drain()

        XCTAssertEqual(filesInRejectedDir(), [name], "malformed file moved to inbox/rejected/")
        XCTAssertTrue(opFilesInInbox().isEmpty)
        let rejected = echoRecords(rejectedURL)
        XCTAssertEqual(rejected.count, 1)
        XCTAssertEqual(rejected.first?["reason"] as? String, "malformed envelope")
        // No store mutation happened.
        XCTAssertTrue(store().allTags().isEmpty)
    }

    /// A well-formed envelope that FAILS mechanical validation (unknown op) is a
    /// *rejection*, not a *malformed file*: echoed to rejected.jsonl AND deleted (it
    /// decoded), never moved to rejected/.
    func testValidEnvelopeFailingValidationIsRejectedAndDeleted() throws {
        // An unknown op still decodes into an AgentOp (tolerant), but apply throws.
        let op = AgentOp(op: "frobnicate", agent: "claude-mac", payload: .init())
        writeOp(op)

        ingestor.drain()

        XCTAssertTrue(opFilesInInbox().isEmpty, "a decoded-but-rejected op file is deleted")
        XCTAssertTrue(filesInRejectedDir().isEmpty, "a decoded op is never moved to rejected/")
        let rejected = echoRecords(rejectedURL)
        XCTAssertEqual(rejected.count, 1)
        XCTAssertEqual(rejected.first?["op"] as? String, "frobnicate")
        XCTAssertEqual(rejected.first?["result"] as? String, "rejected")
        XCTAssertNotNil(rejected.first?["reason"], "the reason names the mechanical failure")
    }

    /// An op naming a note that doesn't exist is rejected (note-existence is mechanics,
    /// contract §4), echoed, and deleted.
    func testTagOnMissingNoteIsRejected() throws {
        let ghost = UUID()
        writeOp(.tag(noteId: ghost, tag: "x", agent: "claude-mac"))

        ingestor.drain()

        XCTAssertTrue(store().allTags().isEmpty)
        XCTAssertEqual(echoRecords(rejectedURL).first?["result"] as? String, "rejected")
        XCTAssertTrue(opFilesInInbox().isEmpty)
    }

    // MARK: - Crash recovery (startup rescan)

    /// Simulates a crash *after* a valid op file was written but *before* it was
    /// processed: the file is simply sitting in the inbox at launch. `start()`'s
    /// startup scan drains it, applying the op — the crash-recovery guarantee.
    func testStartupScanAppliesLeftoverFile() throws {
        writeOp(.tag(noteId: seededNoteId, tag: "recovered", agent: "claude-mac"))

        let fresh = InboxIngestor(container: container)
        fresh.start()   // startup scan runs inline before the watch is armed
        fresh.stop()

        XCTAssertEqual(store().tags(forNote: seededNoteId).map(\.tag), ["recovered"],
                       "a leftover op file is applied on the next launch's startup scan")
        XCTAssertTrue(opFilesInInbox().isEmpty)
        XCTAssertEqual(echoRecords(appliedURL).count, 1)
    }

    /// A `tag` op that was already applied (its requestId is in the persisted ledger)
    /// but whose file lingered — the exact crash window where the ledger write landed
    /// and the delete didn't — is a no-op on rescan: the tag isn't duplicated and the
    /// file is cleaned up.
    func testReappliedTagOnRescanIsNoOp() throws {
        let rid = UUID()
        writeOp(.tag(noteId: seededNoteId, tag: "dedup-me", agent: "claude-mac", requestId: rid))
        ingestor.drain()
        XCTAssertEqual(store().tags(forNote: seededNoteId).count, 1)

        // Re-drop the identical file (same requestId) to mimic a lingering leftover,
        // and rescan with a fresh ingestor (reloads the persisted ledger).
        writeOp(.tag(noteId: seededNoteId, tag: "dedup-me", agent: "claude-mac", requestId: rid))
        let fresh = InboxIngestor(container: container)
        fresh.start()
        fresh.stop()

        XCTAssertEqual(store().tags(forNote: seededNoteId).count, 1,
                       "the re-applied tag must not duplicate")
        XCTAssertTrue(opFilesInInbox().isEmpty, "the leftover file is cleaned up on rescan")
    }

    // MARK: - The real watch (async delivery, not just drain())

    /// Proves the vnode door actually fires: with `start()` arming the real
    /// `DispatchSourceFileSystemObject`, an op file **renamed** into `inbox/` (the way
    /// the contract §4 writer delivers it) is picked up and applied WITHOUT any manual
    /// `drain()` — we only wait for the batch notification. Guards the async path the
    /// synchronous tests deliberately bypass, so a broken watcher can't pass unnoticed.
    func testWatchPicksUpARenamedFileWithoutManualDrain() async throws {
        // Await the batch signal that the ingestor posts after it applies the op.
        let applied = expectation(description: "didApplyBatch posted by the watcher")
        let token = NotificationCenter.default.addObserver(
            forName: InboxIngestor.didApplyBatch, object: nil, queue: .main) { _ in
                applied.fulfill()
            }
        defer { NotificationCenter.default.removeObserver(token) }

        ingestor.start()                     // arms the real vnode source + timer
        // Deliver via temp→rename AFTER the watch is armed, so it's the watcher (not
        // start()'s inline startup scan) that observes and processes it.
        writeOp(.tag(noteId: seededNoteId, tag: "via-watcher", agent: "claude-mac"))

        await fulfillment(of: [applied], timeout: 5)
        XCTAssertEqual(store().tags(forNote: seededNoteId).map(\.tag), ["via-watcher"],
                       "the watcher applied a renamed-in op with no manual drain")
        XCTAssertTrue(opFilesInInbox().isEmpty)
    }

    // MARK: - Batch reload signal

    /// A batch with ≥1 applied op posts `InboxIngestor.didApplyBatch` exactly once
    /// (the signal AppModel observes to re-export); a batch of pure rejects posts
    /// nothing (no store state changed).
    func testDidApplyBatchPostedOncePerAppliedBatch() throws {
        // A `@MainActor` counter (the observer fires on `.main`), so mutating it from
        // the notification closure is concurrency-safe under strict checking.
        let counter = PostCounter()
        let token = NotificationCenter.default.addObserver(
            forName: InboxIngestor.didApplyBatch, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { counter.value += 1 }
            }
        defer { NotificationCenter.default.removeObserver(token) }

        // Two applied ops in one drain → exactly one post.
        writeOp(.tag(noteId: seededNoteId, tag: "a", agent: "claude-mac"))
        writeOp(.tag(noteId: seededNoteId, tag: "b", agent: "claude-mac"))
        ingestor.drain()
        XCTAssertEqual(counter.value, 1, "one batch with applies posts exactly once")

        // A drain with nothing to do posts nothing.
        ingestor.drain()
        XCTAssertEqual(counter.value, 1, "an empty drain posts no batch signal")

        // A batch of only rejects (missing note) posts nothing.
        writeOp(.tag(noteId: UUID(), tag: "ghost", agent: "claude-mac"))
        ingestor.drain()
        XCTAssertEqual(counter.value, 1, "a pure-reject batch changed no state → no re-export signal")
    }
}

/// A trivial main-actor counter for the batch-notification test — a reference type so
/// the `.main`-queue observer closure can bump it without capturing a mutable `var`.
@MainActor private final class PostCounter { var value = 0 }

/// The **full inbox→store→export chain** the Mac app wires up (contract §4, M3
/// Verify): an `InboxIngestor` sharing a real `AppModel`'s container (exactly as
/// `AppDelegate` shares `NotesDataStore.shared`) applies an op; the ingestor's
/// `didApplyBatch` drives `AppModel.reloadNotes()`, which re-exports the layer; and
/// `~/Ollie/tags.jsonl` gains the tag line. Proves the notification→reload→export
/// wiring, not just the ingestor in isolation. macOS-only (the export is Mac-only).
@MainActor
final class InboxIngestorAppModelIntegrationTests: XCTestCase {
    #if os(macOS)
    func testAppliedTagFlowsThroughAppModelExportToTagsJsonl() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ollie-inbox-e2e-\(UUID().uuidString)", isDirectory: true)
        CorpusExporter.exportDirectoryOverride = dir
        defer {
            CorpusExporter.exportDirectoryOverride = nil
            try? FileManager.default.removeItem(at: dir)
        }
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("inbox", isDirectory: true),
            withIntermediateDirectories: true)

        // A real AppModel (in-memory store, no CloudKit) with one note, and an ingestor
        // sharing its exact container — the production topology (both read the one store).
        let model = AppModel(inMemoryStore: true)
        let note = model.composeNote(transcript: "The heat pump note.")
        let ingestor = InboxIngestor(container: model.modelContainerForTesting)
        defer { ingestor.stop() }
        ingestor.start()

        // Drop a tag op the way the MCP writer will (temp → rename). Wait for AppModel's
        // reload+export to land the tag in tags.jsonl (the observer runs off the batch
        // notification, then export is a detached task — so poll with a timeout).
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let op = AgentOp.tag(noteId: note.id, tag: "heat-pump", agent: "claude-mac")
        let data = try enc.encode(op)
        let inbox = dir.appendingPathComponent("inbox", isDirectory: true)
        let tmp = inbox.appendingPathComponent(".\(UUID().uuidString).tmp")
        try data.write(to: tmp)
        try FileManager.default.moveItem(
            at: tmp, to: inbox.appendingPathComponent("claude-mac-\(op.requestId.uuidString).json"))

        let tagsURL = dir.appendingPathComponent("tags.jsonl")
        try await pollUntil(timeout: 5) {
            let text = (try? String(contentsOf: tagsURL, encoding: .utf8)) ?? ""
            return text.contains("heat-pump") && text.contains(note.id.uuidString)
        }

        // applied.jsonl echoed too.
        let applied = (try? String(contentsOf: dir.appendingPathComponent("applied.jsonl"),
                                    encoding: .utf8)) ?? ""
        XCTAssertTrue(applied.contains("\"result\":\"applied\""),
                      "the op was echoed to applied.jsonl")
    }

    /// Poll `condition` on the main actor until it's true or the timeout elapses,
    /// yielding between checks so the ingestor's Task and the detached export can run.
    private func pollUntil(timeout: TimeInterval,
                           _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)   // 50 ms
        }
        XCTFail("condition not met within \(timeout)s")
    }
    #endif
}
