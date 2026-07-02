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

    private func note(_ text: String = "hello", engine: String? = nil) -> Note {
        Note(transcript: text, source: .watch, engineUsed: engine)
    }
    private var jsonlURL: URL { dir.appendingPathComponent("ollie.jsonl") }
    private func jsonl() -> String { (try? String(contentsOf: jsonlURL, encoding: .utf8)) ?? "" }
    private func metaCount() -> Int? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent(".ollie.meta.json")),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return obj["noteCount"] as? Int
    }

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
}
