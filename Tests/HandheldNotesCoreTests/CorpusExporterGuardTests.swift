import Foundation
import XCTest
@testable import HandheldNotesCore

/// Guards added after the July 2026 corpus-wipe incident (a post-sleep CloudKit
/// read failure projected 0 notes and the exporter overwrote a healthy corpus with
/// an empty file), plus the exporter-consistency polish (count skew, orphan prune).
final class CorpusExporterGuardTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ollie-export-test-\(UUID().uuidString)", isDirectory: true)
        CorpusExporter.exportDirectoryOverride = dir
    }
    override func tearDown() {
        CorpusExporter.exportDirectoryOverride = nil
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func note(_ text: String = "hello", engine: String? = nil, restricted: Bool = false) -> Note {
        Note(transcript: text, source: .watch, engineUsed: engine, isRestricted: restricted)
    }
    private var jsonlURL: URL { dir.appendingPathComponent("ollie.jsonl") }
    private func jsonl() -> String { (try? String(contentsOf: jsonlURL, encoding: .utf8)) ?? "" }

    // MARK: agent-layer helpers (M2)

    private var tagsURL: URL { dir.appendingPathComponent("tags.jsonl") }
    private var memoryURL: URL { dir.appendingPathComponent("memory.jsonl") }
    private var viewsURL: URL { dir.appendingPathComponent("views.jsonl") }
    private var instructionsURL: URL { dir.appendingPathComponent("instructions.md") }
    private var interactionsURL: URL { dir.appendingPathComponent("interactions.jsonl") }
    private func text(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    /// Non-empty JSONL lines in a file (drops the trailing newline's empty tail).
    private func lines(_ url: URL) -> [String] {
        text(url).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
    private func mdExists(_ id: UUID) -> Bool {
        FileManager.default.fileExists(atPath:
            dir.appendingPathComponent("notes", isDirectory: true)
                .appendingPathComponent("\(id.uuidString).md").path)
    }
    private func tag(_ tag: String, on noteId: UUID) -> AgentTag {
        AgentTag(noteId: noteId, tag: tag, agentId: "claude-mac")
    }

    private func meta() -> [String: Any]? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent(".ollie.meta.json")),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return obj
    }
    private func metaCount() -> Int? { meta()?["noteCount"] as? Int }

    // MARK: the empty-corpus guard (the core data-safety fix)

    func testEmptyExportDoesNotOverwriteANonEmptyCorpus() {
        CorpusExporter.export([note("keep me"), note("and me")])
        XCTAssertEqual(jsonl().split(separator: "\n").count, 2)

        // Simulate the wedge: a transient empty projection tries to export.
        CorpusExporter.export([])
        XCTAssertEqual(jsonl().split(separator: "\n").count, 2,
                       "an empty export must NOT clobber the existing 2-note corpus")
    }

    func testEmptyExportIsAllowedWhenExplicitlyRequested() {
        CorpusExporter.export([note("temporary")])
        XCTAssertFalse(jsonl().isEmpty)
        CorpusExporter.export([], allowEmpty: true)   // a genuine wipe
        XCTAssertTrue(jsonl().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      "allowEmpty:true should clear the corpus for a real wipe")
    }

    func testEmptyExportOntoAnEmptyCorpusIsFine() {
        CorpusExporter.export([])   // nothing on disk yet — not a clobber
        XCTAssertTrue(jsonl().isEmpty)
    }

    // MARK: consistency polish

    func testMetaCountMatchesWrittenLines() {
        let notes = [note("a"), note("b"), note("c")]
        CorpusExporter.export(notes)
        XCTAssertEqual(jsonl().split(separator: "\n").count, 3)
        XCTAssertEqual(metaCount(), 3, "meta.noteCount must equal the JSONL line count")
    }

    func testOrphanedMarkdownIsPruned() {
        let keep = note("survivor")
        let drop = note("deleted later")
        CorpusExporter.export([keep, drop])
        let notesDir = dir.appendingPathComponent("notes", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: notesDir.appendingPathComponent("\(drop.id.uuidString).md").path))

        // Re-export without `drop` → its .md should be pruned; `keep`'s remains.
        CorpusExporter.export([keep])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: notesDir.appendingPathComponent("\(drop.id.uuidString).md").path),
            "a deleted note's Markdown must be pruned")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: notesDir.appendingPathComponent("\(keep.id.uuidString).md").path))
    }

    func testFailedTranscriptionIsFlaggedInTheCorpus() {
        CorpusExporter.export([note("[Transcription failed: boom]", engine: "error")])
        XCTAssertTrue(jsonl().contains("\"transcriptionFailed\":true"),
                      "a failed-transcription note must be flagged so an LLM ignores the placeholder")
        // A healthy note carries no such flag.
        CorpusExporter.export([note("real content", engine: "AppleSpeech")], allowEmpty: true)
        XCTAssertFalse(jsonl().contains("transcriptionFailed"))
    }

    /// The BOTH-shapes check: the "unavailable" placeholder (engineUsed=="demo") must
    /// also be caught, but a genuine demo note (real text, engineUsed=="demo") must NOT.
    func testTranscriptionFailedCatchesUnavailablePlaceholderButNotRealDemo() {
        let unavailable = note("[Transcription unavailable here — audio captured (19.3s) and saved. …]", engine: "demo")
        XCTAssertTrue(unavailable.transcriptionFailed,
                      "the 'unavailable' placeholder must be recoverable")
        let realDemo = note("Welcome to Ollie — this is a sample note.", engine: "demo")
        XCTAssertFalse(realDemo.transcriptionFailed,
                       "a genuine demo note (real text) must not be flagged as failed")
        let healthy = note("A perfectly normal transcript.", engine: "AppleSpeech")
        XCTAssertFalse(healthy.transcriptionFailed)
    }

    // MARK: - M2: the export gate (restriction is contagious)

    /// A restricted note is omitted from `ollie.jsonl` and `notes/`, while an
    /// unrestricted note in the same export lands normally.
    func testRestrictedNoteIsAbsentFromCorpusAndMarkdown() {
        let open = note("public thing")
        let secret = note("private thing", restricted: true)
        CorpusExporter.export([open, secret])

        let body = jsonl()
        XCTAssertTrue(body.contains(open.id.uuidString), "unrestricted note must be exported")
        XCTAssertFalse(body.contains(secret.id.uuidString),
                       "restricted note must be omitted from ollie.jsonl")
        XCTAssertFalse(body.contains("private thing"),
                       "restricted transcript must never reach the corpus")
        XCTAssertEqual(jsonl().split(separator: "\n").count, 1, "only the open note is written")

        XCTAssertTrue(mdExists(open.id), "unrestricted note keeps its .md")
        XCTAssertFalse(mdExists(secret.id), "restricted note must have no .md")
        XCTAssertEqual(metaCount(), 1, "meta.noteCount reflects the GATED corpus")
    }

    /// The exact contract scenario: a note exported in the clear, then marked
    /// restricted, must have its previously-exported `.md` pruned on the next export
    /// (contract §5) and drop out of the corpus.
    func testNoteBecomingRestrictedPrunesItsPreviouslyExportedMarkdown() {
        let id = UUID()
        let clear = Note(id: id, transcript: "was public", source: .watch)
        CorpusExporter.export([note("keep"), clear])
        XCTAssertTrue(mdExists(id), "note is exported in the clear first")
        XCTAssertTrue(jsonl().contains(id.uuidString))

        // Same id, now restricted → re-export must prune the stale .md and drop it.
        let restricted = Note(id: id, transcript: "was public", source: .watch, isRestricted: true)
        CorpusExporter.export([note("keep"), restricted])
        XCTAssertFalse(mdExists(id), "a note that becomes restricted has its .md pruned")
        XCTAssertFalse(jsonl().contains(id.uuidString),
                       "a newly-restricted note drops out of the corpus")
    }

    /// A tag on a restricted note is omitted from `tags.jsonl` (contagion), while a
    /// tag on an unrestricted note survives.
    func testTagsOfRestrictedNoteAreOmitted() {
        let open = note("open")
        let secret = note("secret", restricted: true)
        let layer = CorpusExporter.LayerSnapshot(tags: [
            tag("keep-me", on: open.id),
            tag("drop-me", on: secret.id),
        ])
        CorpusExporter.export([open, secret], layer: layer)

        let tagLines = lines(tagsURL)
        XCTAssertEqual(tagLines.count, 1, "only the unrestricted note's tag is exported")
        XCTAssertTrue(text(tagsURL).contains("keep-me"))
        XCTAssertFalse(text(tagsURL).contains("drop-me"),
                       "a tag whose subject note is restricted must be omitted")
        XCTAssertFalse(text(tagsURL).contains(secret.id.uuidString),
                       "the restricted note's id must not leak via tags.jsonl")
        // Gate reflected in meta.layerCounts too.
        let counts = meta()?["layerCounts"] as? [String: Any]
        XCTAssertEqual(counts?["tags"] as? Int, 1, "layerCounts.tags is the GATED count")
    }

    /// When every note is restricted, the gated corpus is legitimately empty and must
    /// write through (this is NOT the transient-empty-projection case the guard blocks).
    func testAllNotesRestrictedWritesAnEmptyCorpusThrough() {
        // Seed a healthy corpus first.
        CorpusExporter.export([note("a"), note("b")])
        XCTAssertEqual(jsonl().split(separator: "\n").count, 2)

        // Now the same two notes, both restricted → gated corpus is empty, but the
        // RAW projection is non-empty, so the transient-empty guard does NOT fire.
        CorpusExporter.export([note("a", restricted: true), note("b", restricted: true)])
        XCTAssertTrue(jsonl().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      "an all-restricted corpus legitimately writes empty (not a transient wedge)")
        XCTAssertEqual(metaCount(), 0)
    }

    /// The empty-corpus safety guard still holds when a layer is passed: a transient
    /// zero-note projection must not clobber a healthy corpus (or its tags).
    func testEmptyProjectionGuardStillHoldsWithLayer() {
        let n = note("keep me")
        let layer = CorpusExporter.LayerSnapshot(tags: [tag("t", on: n.id)])
        CorpusExporter.export([n], layer: layer)
        XCTAssertEqual(jsonl().split(separator: "\n").count, 1)
        XCTAssertEqual(lines(tagsURL).count, 1)

        // Transient empty read (no allowEmpty) → corpus preserved.
        CorpusExporter.export([], layer: .empty)
        XCTAssertEqual(jsonl().split(separator: "\n").count, 1,
                       "empty projection must not clobber the corpus even with a layer arg")
    }

    // MARK: - M2: layer files round-trip

    /// memory.jsonl carries every entry INCLUDING retired ones, flagged; a live entry
    /// omits `retiredAt`, a retired entry includes it. Shape matches contract §5.
    func testMemoryFileIncludesRetiredEntriesFlagged() throws {
        let live = AgentMemory(text: "HP means heat pump", agentId: "claude-mac")
        let dead = AgentMemory(text: "old dead end", agentId: "claude-runner",
                               retired: true, retiredAt: Date(timeIntervalSince1970: 1000))
        CorpusExporter.export([note("n")], layer: .init(memory: [live, dead]))

        let ls = lines(memoryURL)
        XCTAssertEqual(ls.count, 2, "retired entries are included, not dropped")
        let joined = text(memoryURL)
        XCTAssertTrue(joined.contains("\"retired\":true"))
        XCTAssertTrue(joined.contains("\"retired\":false"))
        XCTAssertTrue(joined.contains(live.id.uuidString), "memory record carries its id")
        // The live entry must NOT carry a retiredAt key; the retired one must.
        let liveLine = try XCTUnwrap(ls.first { $0.contains(live.id.uuidString) })
        XCTAssertFalse(liveLine.contains("retiredAt"), "a live memory entry omits retiredAt")
        let deadLine = try XCTUnwrap(ls.first { $0.contains(dead.id.uuidString) })
        XCTAssertTrue(deadLine.contains("retiredAt"), "a retired memory entry includes retiredAt")
    }

    /// views.jsonl carries every revision with its full body (snapshots, not diffs),
    /// shape per contract §5.
    func testViewsFileCarriesEveryRevisionFullBody() {
        let r1 = AgentViewRevision(viewName: "This week", body: "first body",
                                   agentId: "claude-mac", createdAt: Date(timeIntervalSince1970: 100))
        let r2 = AgentViewRevision(viewName: "This week", body: "second, newer body",
                                   agentId: "claude-runner", createdAt: Date(timeIntervalSince1970: 200))
        CorpusExporter.export([note("n")], layer: .init(viewRevisions: [r1, r2]))

        let ls = lines(viewsURL)
        XCTAssertEqual(ls.count, 2, "every revision is a line (snapshots, not diffs)")
        let joined = text(viewsURL)
        XCTAssertTrue(joined.contains("first body"))
        XCTAssertTrue(joined.contains("second, newer body"))
        XCTAssertTrue(joined.contains("This week"))
        XCTAssertTrue(joined.contains(r1.id.uuidString), "view record carries its id")
    }

    /// instructions.md is the plain instructions text; re-exporting with a new value
    /// overwrites it wholesale (never appends / never left stale).
    func testInstructionsFileRoundTripsAndOverwrites() {
        CorpusExporter.export([note("n")], layer: .init(instructions: "Be terse."))
        XCTAssertEqual(text(instructionsURL), "Be terse.")

        CorpusExporter.export([note("n")], layer: .init(instructions: "Actually, be thorough."),
                              allowEmpty: false)
        XCTAssertEqual(text(instructionsURL), "Actually, be thorough.",
                       "instructions.md is overwritten wholesale")

        // Empty instructions writes an authoritative empty file, not a stale one.
        CorpusExporter.export([note("n")], layer: .empty)
        XCTAssertEqual(text(instructionsURL), "", "empty instructions clears the file")
    }

    /// All four layer files appear (even empty) after a plain corpus export, so a
    /// reader never trips over a missing file.
    func testLayerFilesAppearEvenWhenEmpty() {
        CorpusExporter.export([note("solo")])
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: tagsURL.path))
        XCTAssertTrue(fm.fileExists(atPath: memoryURL.path))
        XCTAssertTrue(fm.fileExists(atPath: viewsURL.path))
        XCTAssertTrue(fm.fileExists(atPath: instructionsURL.path))
        XCTAssertEqual(lines(tagsURL).count, 0)
        XCTAssertEqual(lines(memoryURL).count, 0)
        XCTAssertEqual(lines(viewsURL).count, 0)
        XCTAssertEqual(text(instructionsURL), "")
    }

    // MARK: - M2: meta v3 + reserved media field

    func testMetaIsV3WithLayerCounts() {
        let n1 = note("one"); let n2 = note("two")
        let layer = CorpusExporter.LayerSnapshot(
            tags: [tag("a", on: n1.id), tag("b", on: n2.id)],
            memory: [AgentMemory(text: "m1", agentId: "x"), AgentMemory(text: "m2", agentId: "x")],
            viewRevisions: [AgentViewRevision(viewName: "V", body: "b", agentId: "x")],
            instructions: "hi")
        CorpusExporter.export([n1, n2], layer: layer)

        let m = meta()
        XCTAssertEqual(m?["schemaVersion"] as? Int, 3, "meta schemaVersion is 3")
        let counts = m?["layerCounts"] as? [String: Any]
        XCTAssertEqual(counts?["tags"] as? Int, 2)
        XCTAssertEqual(counts?["memory"] as? Int, 2)
        XCTAssertEqual(counts?["viewRevisions"] as? Int, 1)
    }

    /// The reserved `media` field is never emitted today (contract §5, §7) — the key
    /// must be absent from `ollie.jsonl` entirely until photo notes ship. (Checks the
    /// JSON *key* `"media":`, not the bare word, so a transcript mentioning media
    /// wouldn't false-positive.)
    func testReservedMediaFieldIsAbsentFromCorpus() {
        CorpusExporter.export([note("an ordinary transcript")])
        XCTAssertFalse(jsonl().contains("\"media\""),
                       "the reserved media field must be omitted until photo notes exist")
    }

    // MARK: - M7 (7d): interactions.jsonl export + prune + meta count

    /// A view + its one live checklist item, and an interaction record keyed to that
    /// item's real `blockId` (derived exactly as the renderer does — spec §3), toggled
    /// *after* the revision so it applies. `at`/`revAt` control the precedence timing.
    private func viewRevision(
        _ name: String = "Open loops",
        body: String,
        at t: TimeInterval = 100
    ) -> AgentViewRevision {
        AgentViewRevision(viewName: name, body: body, agentId: "claude-mac",
                          createdAt: Date(timeIntervalSince1970: t))
    }
    private func interaction(
        view: String = "Open loops",
        blockId: String,
        text: String = "Call the plumber",
        value: String = "true",
        at t: TimeInterval
    ) -> ViewInteraction {
        ViewInteraction(viewName: view, blockId: blockId, blockText: text,
                        value: value, surface: "ios",
                        updatedAt: Date(timeIntervalSince1970: t))
    }
    /// The `blockId` the renderer assigns to the sole checklist item in `body`.
    private func onlyBlockId(_ body: String) -> String {
        let ids = MarkdownLite.checklistBlockIds(in: body)
        return ids.first ?? "cl1:missing:0"
    }
    private func interactionCountInMeta() -> Int? {
        (meta()?["layerCounts"] as? [String: Any])?["interactions"] as? Int
    }

    /// The interactions.jsonl line shape (spec §6): denormalized `blockText`, the
    /// logical-key fields, and NO record `id` (keyed by `(viewName, blockId)`).
    func testInteractionsFileHasSpecShapeAndDenormalizedBlockText() {
        let body = "- [ ] Call the plumber — ollie://note/x"
        let rev = viewRevision(body: body, at: 100)
        let bid = onlyBlockId(body)
        let inter = interaction(blockId: bid, text: "Call the plumber — ollie://note/x",
                                value: "true", at: 200)  // toggled after the revision
        CorpusExporter.export([note("n")],
                              layer: .init(viewRevisions: [rev], interactions: [inter]))

        let ls = lines(interactionsURL)
        XCTAssertEqual(ls.count, 1)
        let line = ls[0]
        XCTAssertTrue(line.contains("\"viewName\":\"Open loops\""))
        XCTAssertTrue(line.contains("\"blockId\":\"\(bid)\""))
        XCTAssertTrue(line.contains("\"blockText\":\"Call the plumber — ollie://note/x\""),
                      "blockText is denormalized so agents never recompute the hash")
        XCTAssertTrue(line.contains("\"value\":\"true\""))
        XCTAssertTrue(line.contains("\"kind\":\"checkbox\""))
        XCTAssertTrue(line.contains("\"surface\":\"ios\""))
        XCTAssertFalse(line.contains("\"id\":"),
                       "the interaction record id is omitted (keyed by viewName+blockId)")
    }

    /// interactions.jsonl appears (empty) even with no interaction records, like the
    /// other layer files — a reader never trips over a missing file.
    func testInteractionsFileAppearsEvenWhenEmpty() {
        CorpusExporter.export([note("solo")])
        XCTAssertTrue(FileManager.default.fileExists(atPath: interactionsURL.path))
        XCTAssertEqual(lines(interactionsURL).count, 0)
        XCTAssertEqual(interactionCountInMeta(), 0, "meta.layerCounts.interactions is additive")
    }

    /// meta.layerCounts.interactions equals the exported (post-prune) line count.
    func testMetaInteractionsCountMatchesExportedLines() {
        let bodyA = "- [ ] item A"
        let bodyB = "- [ ] item B"
        let revA = viewRevision("A", body: bodyA, at: 100)
        let revB = viewRevision("B", body: bodyB, at: 100)
        let iA = interaction(view: "A", blockId: onlyBlockId(bodyA), at: 200)
        let iB = interaction(view: "B", blockId: onlyBlockId(bodyB), at: 200)
        CorpusExporter.export([note("n")],
                              layer: .init(viewRevisions: [revA, revB], interactions: [iA, iB]))

        XCTAssertEqual(lines(interactionsURL).count, 2)
        XCTAssertEqual(interactionCountInMeta(), 2)
    }

    /// PRUNE (1): a record whose view no longer exists (no revision carries its
    /// `viewName`) is dropped — the view is gone, the state can never apply.
    func testPruneDropsRecordsOfDeletedView() {
        let liveBody = "- [ ] still here"
        let liveRev = viewRevision("Live", body: liveBody, at: 100)
        let liveInter = interaction(view: "Live", blockId: onlyBlockId(liveBody), at: 200)
        // A record for a view with NO revision in this export → its view was deleted.
        let orphan = interaction(view: "Deleted", blockId: "cl1:dead:0", at: 200)
        CorpusExporter.export([note("n")],
                              layer: .init(viewRevisions: [liveRev],
                                           interactions: [liveInter, orphan]))

        let ls = lines(interactionsURL)
        XCTAssertEqual(ls.count, 1, "the deleted-view record is pruned")
        XCTAssertTrue(text(interactionsURL).contains("\"viewName\":\"Live\""),
                      "the live-view record survives")
        XCTAssertFalse(text(interactionsURL).contains("\"viewName\":\"Deleted\""),
                       "a record for a view with no revision is dropped")
    }

    /// KEEP: a record whose `blockId` is still present in the view's latest revision is
    /// always kept — the user's checkmark is live, regardless of age.
    func testPruneKeepsRecordWhoseBlockIsStillInLatestRevision() {
        let body = "- [ ] persistent task"
        // Latest revision is 40 days old; the toggle is 35 days old (older than the
        // revision AND > 30 days) — but the block is STILL in the latest body, so keep.
        let now = Date()
        let rev = viewRevision(body: body, at: now.addingTimeInterval(-40*86400).timeIntervalSince1970)
        let inter = interaction(blockId: onlyBlockId(body),
                                at: now.addingTimeInterval(-35*86400).timeIntervalSince1970)
        let kept = CorpusExporter.prunedInteractions([inter], revisions: [rev], now: now)
        XCTAssertEqual(kept.count, 1, "a block still in the latest revision is never pruned")
    }

    /// PRUNE (2): a record absent from the latest revision, older than that revision,
    /// AND older than 30 days — all three hold → pruned (superseded + stale).
    func testPruneDropsSupersededStaleRecord() {
        let now = Date()
        // Latest revision (10 days ago) NO LONGER contains the old item's block.
        let latestBody = "- [ ] a different item"
        let rev = viewRevision(body: latestBody, at: now.addingTimeInterval(-10*86400).timeIntervalSince1970)
        // The record's block isn't in `latestBody`; toggled 40 days ago (before the
        // revision AND > 30 days old).
        let staleGoneBlock = "cl1:oldoldoldoldold:0"
        let inter = interaction(blockId: staleGoneBlock,
                                at: now.addingTimeInterval(-40*86400).timeIntervalSince1970)
        let kept = CorpusExporter.prunedInteractions([inter], revisions: [rev], now: now)
        XCTAssertTrue(kept.isEmpty,
                      "absent-from-latest + superseded + >30 days → pruned")
    }

    /// KEEP: absent from the latest revision and superseded, but NOT yet 30 days old →
    /// kept (the user's recent toggle gets a grace window before we drop it).
    func testPruneKeepsRecentlyTouchedRecordEvenIfAbsentFromLatest() {
        let now = Date()
        let latestBody = "- [ ] a different item"
        let rev = viewRevision(body: latestBody, at: now.addingTimeInterval(-5*86400).timeIntervalSince1970)
        // Absent block, but toggled only 2 days ago (< 30 days) → keep.
        let inter = interaction(blockId: "cl1:recentgone:0",
                                at: now.addingTimeInterval(-2*86400).timeIntervalSince1970)
        let kept = CorpusExporter.prunedInteractions([inter], revisions: [rev], now: now)
        XCTAssertEqual(kept.count, 1, "a recent toggle is kept even if its block left the latest body")
    }

    /// KEEP: absent from latest and >30 days old, but the toggle is NEWER than the
    /// latest revision (not superseded) → kept (the user acted after the last publish).
    func testPruneKeepsRecordNewerThanLatestRevisionEvenIfAbsentAndOld() {
        let now = Date()
        // Latest revision is 60 days old; the toggle is 40 days old — older than 30
        // days, absent from the (different) latest body, but NEWER than the revision.
        let latestBody = "- [ ] a different item"
        let rev = viewRevision(body: latestBody, at: now.addingTimeInterval(-60*86400).timeIntervalSince1970)
        let inter = interaction(blockId: "cl1:userlater:0",
                                at: now.addingTimeInterval(-40*86400).timeIntervalSince1970)
        let kept = CorpusExporter.prunedInteractions([inter], revisions: [rev], now: now)
        XCTAssertEqual(kept.count, 1,
                       "a toggle newer than the latest revision still applies — never pruned")
    }
}
