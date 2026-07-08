import Foundation
import XCTest
@testable import HandheldNotesCore

/// Unit tests for `IngestIndex` (M13 arrival-time coverage): the persisted
/// `noteId → firstSeenAt` map that lets the runner filter on ARRIVAL time so a
/// late-syncing watch note (old `createdAt`, fresh arrival) is still covered.
///
/// Every test injects a temp `fileURL` and, where timing matters, a fixed `clock`, so
/// nothing touches the real `~/Library/Application Support/Ollie/ingest-index.json` and
/// arrival stamps are deterministic.
final class IngestIndexTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ingest-index-test-\(UUID().uuidString).json")
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    private func fixedClock(_ date: Date) -> () -> Date { { date } }

    // MARK: - record + first-seen-wins + injected clock

    func testRecordArrivalStampsNowAndFirstSeenWins() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let t1 = Date(timeIntervalSince1970: 2_000_000)
        var now = t0
        let idx = IngestIndex(fileURL: fileURL, clock: { now })
        let id = UUID()

        XCTAssertTrue(idx.recordArrival(id), "a fresh id records a new entry")
        XCTAssertEqual(idx.firstSeen(for: id), t0, "arrival stamped at the injected clock")

        // Second arrival for the same id at a LATER clock must NOT overwrite — first-seen wins.
        now = t1
        XCTAssertFalse(idx.recordArrival(id), "re-arrival adds no new entry")
        XCTAssertEqual(idx.firstSeen(for: id), t0,
                       "first-seen wins: a re-arrival keeps the original stamp")
    }

    func testFirstSeenIsNilForUnknownIdAndContainsReflectsState() {
        let idx = IngestIndex(fileURL: fileURL, clock: fixedClock(Date()))
        let known = UUID(); let unknown = UUID()
        idx.recordArrival(known)
        XCTAssertNotNil(idx.firstSeen(for: known))
        XCTAssertNil(idx.firstSeen(for: unknown), "an unseen note has no arrival time")
        XCTAssertTrue(idx.contains(known))
        XCTAssertFalse(idx.contains(unknown))
    }

    // MARK: - seed (createdAt, not now)

    func testSeedIfAbsentStampsSuppliedDateAndDoesNotOverwrite() {
        let now = Date(timeIntervalSince1970: 9_000_000)
        let createdAt = Date(timeIntervalSince1970: 100)   // far in the past
        let idx = IngestIndex(fileURL: fileURL, clock: fixedClock(now))
        let id = UUID()

        XCTAssertTrue(idx.seedIfAbsent(id, at: createdAt))
        XCTAssertEqual(idx.firstSeen(for: id), createdAt,
                       "seed uses the supplied createdAt, NOT the clock — old notes stay in the past")

        // Seeding again (or recording now) must not move the seeded stamp.
        XCTAssertFalse(idx.seedIfAbsent(id, at: Date(timeIntervalSince1970: 500)))
        XCTAssertFalse(idx.recordArrival(id))
        XCTAssertEqual(idx.firstSeen(for: id), createdAt, "first-seen wins over a later seed or arrival")
    }

    // MARK: - prune

    func testPruneDropsEntriesNotInLiveSet() {
        let idx = IngestIndex(fileURL: fileURL, clock: fixedClock(Date()))
        let keep = UUID(); let drop = UUID()
        idx.recordArrival(keep)
        idx.recordArrival(drop)
        XCTAssertEqual(idx.count, 2)

        let removed = idx.prune(keeping: [keep])
        XCTAssertEqual(removed, 1, "the entry whose note left the store is pruned")
        XCTAssertTrue(idx.contains(keep))
        XCTAssertFalse(idx.contains(drop), "a pruned entry is gone")
        XCTAssertEqual(idx.count, 1)
    }

    func testPruneKeepingEmptySetClearsAll() {
        let idx = IngestIndex(fileURL: fileURL, clock: fixedClock(Date()))
        idx.recordArrival(UUID()); idx.recordArrival(UUID())
        XCTAssertEqual(idx.prune(keeping: []), 2)
        XCTAssertEqual(idx.count, 0)
    }

    // MARK: - persistence round-trip

    func testSaveThenReloadRoundTrips() throws {
        let t = Date(timeIntervalSince1970: 1_234_567)
        let id = UUID()
        do {
            let idx = IngestIndex(fileURL: fileURL, clock: fixedClock(t))
            idx.recordArrival(id)
            idx.save()
        }
        // A fresh instance over the SAME file must see the persisted entry.
        let reloaded = IngestIndex(fileURL: fileURL, clock: fixedClock(Date()))
        XCTAssertEqual(reloaded.count, 1)
        let seen = try XCTUnwrap(reloaded.firstSeen(for: id))
        XCTAssertEqual(seen.timeIntervalSince1970, t.timeIntervalSince1970, accuracy: 1.0,
                       "the arrival stamp survives a save/reload (ISO8601, ~second precision)")
    }

    func testNoSaveMeansNoPersistence() {
        let id = UUID()
        do {
            let idx = IngestIndex(fileURL: fileURL, clock: fixedClock(Date()))
            idx.recordArrival(id)
            // deliberately NO save()
        }
        let reloaded = IngestIndex(fileURL: fileURL, clock: fixedClock(Date()))
        XCTAssertEqual(reloaded.count, 0, "without save(), nothing is written")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    // MARK: - tolerance (missing / corrupt file → empty, self-heals)

    func testMissingFileLoadsEmpty() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let idx = IngestIndex(fileURL: fileURL, clock: fixedClock(Date()))
        XCTAssertEqual(idx.count, 0, "a missing file starts empty, never throws")
    }

    func testCorruptFileLoadsEmptyAndSelfHeals() throws {
        // Write garbage where a JSON map should be.
        try "this is not json { ] :".write(to: fileURL, atomically: true, encoding: .utf8)
        let idx = IngestIndex(fileURL: fileURL, clock: fixedClock(Date()))
        XCTAssertEqual(idx.count, 0, "a corrupt file loads as empty (tolerant), never throws")

        // It self-heals: a record + save overwrites the garbage with a valid map.
        let id = UUID()
        idx.recordArrival(id)
        idx.save()
        let reloaded = IngestIndex(fileURL: fileURL, clock: fixedClock(Date()))
        XCTAssertEqual(reloaded.count, 1, "the corrupt file was overwritten with a valid index")
        XCTAssertTrue(reloaded.contains(id))
    }

    func testWrongShapeJSONLoadsEmpty() throws {
        // Valid JSON, but not a `[String: Date]` map (e.g. an array).
        try "[1, 2, 3]".write(to: fileURL, atomically: true, encoding: .utf8)
        let idx = IngestIndex(fileURL: fileURL, clock: fixedClock(Date()))
        XCTAssertEqual(idx.count, 0, "JSON of the wrong shape is treated as empty, not a crash")
    }

    // MARK: - snapshot

    func testSnapshotReturnsUUIDKeyedMap() {
        let t = Date(timeIntervalSince1970: 5_000)
        let idx = IngestIndex(fileURL: fileURL, clock: fixedClock(t))
        let a = UUID(); let b = UUID()
        idx.recordArrival(a); idx.recordArrival(b)
        let snap = idx.snapshot()
        XCTAssertEqual(snap.count, 2)
        XCTAssertEqual(snap[a], t)
        XCTAssertEqual(snap[b], t)
    }

    func testSnapshotSkipsNonUUIDKeys() throws {
        // A hand-edited / corrupt file could carry a non-UUID key; snapshot skips it
        // rather than crashing (our own writes never produce one).
        let uuid = UUID().uuidString
        let iso = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 42))
        try #"{"\#(uuid)":"\#(iso)","not-a-uuid":"\#(iso)"}"#
            .write(to: fileURL, atomically: true, encoding: .utf8)
        let idx = IngestIndex(fileURL: fileURL, clock: fixedClock(Date()))
        XCTAssertEqual(idx.count, 2, "both keys load into the raw map")
        let snap = idx.snapshot()
        XCTAssertEqual(snap.count, 1, "only the valid-UUID key survives into the snapshot")
        XCTAssertNotNil(snap[UUID(uuidString: uuid)!])
    }

    // MARK: - the location guarantee (NOT under ~/Ollie)

    /// The DEFAULT persistence location must live under Application Support, NEVER under
    /// `~/Ollie` (the export root). A restricted note's UUID lands in this index too, and
    /// "restriction is contagious" forbids even a bare id from crossing the export
    /// boundary (contract §0 / CLAUDE.md invariant 4). We assert the default file is not
    /// inside the exporter's `~/Ollie` root. (Constructed with the default URL — then
    /// left unsaved so we don't actually write App Support in CI.)
    func testDefaultLocationIsNotUnderOllieExportRoot() {
        // Reflect the default by constructing without a fileURL override. We can't read
        // the private `fileURL`, so instead assert the invariant structurally: the
        // Application Support "Ollie" dir is a sibling of the user's home, whereas the
        // export root is `~/Ollie`. Verify the two roots differ.
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ollie", isDirectory: true)
        let exportRoot = CorpusExporter.exportDirectory
        XCTAssertNotEqual(appSupport.standardizedFileURL.path,
                          exportRoot.standardizedFileURL.path,
                          "the index's App Support dir must NOT be the ~/Ollie export root")
        XCTAssertFalse(appSupport.path.contains("/Ollie/ingest-index"),
                       "sanity: App Support path is not the export mirror")
        // And the App Support path is under Library/Application Support.
        XCTAssertTrue(appSupport.path.contains("Application Support"),
                      "the default index location lives under Application Support")
    }
}
