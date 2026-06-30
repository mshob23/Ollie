import Foundation
import XCTest
@testable import HandheldNotesCore

/// Safety tests for the F7 `resetSync()` lever — the in-app store-delete recovery.
///
/// The whole contract is "**back up, verify, THEN delete — never the other way**",
/// because `resetSync` is the safe replacement for the old zone-nuke that wedged
/// sync for hours. These tests pin both halves of that contract:
///
///   1. On success, a NON-EMPTY backup file lands on disk BEFORE the local store
///      files are removed, and the store files do then get removed.
///   2. On a backup failure (export dir unwritable), `resetSync` THROWS and the
///      store files are left completely untouched — nothing destructive runs.
///
/// Everything is hermetic: the export directory is redirected via
/// `CorpusExporter.exportDirectoryOverride` and the store files via the
/// `AppModel.storeFileURLsForReset` test seam, both pointed at a fresh temp dir.
/// The REAL `~/Ollie` and the REAL SwiftData store are never touched.
@MainActor
final class ResetSyncSafetyTests: XCTestCase {

    private var tmp: URL!

    /// Fresh temp dir per test, created on the main actor (the class is `@MainActor`
    /// for `AppModel`). Cleaned up at the end of each test along with the export
    /// override, so nothing leaks between cases.
    private func makeTempDir() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResetSyncSafetyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    private func cleanUpTempDir() {
        CorpusExporter.exportDirectoryOverride = nil
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
        tmp = nil
    }

    /// Three fake store files in the temp dir, standing in for the real
    /// `default.store` + `-wal` / `-shm`. Returns their URLs after writing them.
    private func makeFakeStoreFiles() throws -> [URL] {
        let names = ["default.store", "default.store-wal", "default.store-shm"]
        let urls = names.map { tmp.appendingPathComponent($0) }
        for url in urls {
            try Data("fake-store".utf8).write(to: url)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                          "precondition: fake store file should exist")
        }
        return urls
    }

    /// Happy path: backup is written and verified NON-EMPTY, then the local store
    /// files are deleted, and the lever reports `.relaunchRequired`.
    func testResetSyncBacksUpThenDeletesStoreFiles() throws {
        try makeTempDir()
        defer { cleanUpTempDir() }
        // Export (and therefore backup) goes into a WRITABLE temp dir.
        CorpusExporter.exportDirectoryOverride = tmp.appendingPathComponent("Ollie", isDirectory: true)

        let model = AppModel(inMemoryStore: true)
        // Give the corpus at least one note so the backup file is non-empty.
        model.composeNote(transcript: "A note worth backing up before reset.")

        let storeFiles = try makeFakeStoreFiles()
        model.storeFileURLsForReset = storeFiles

        let outcome = try model.resetSync()
        XCTAssertEqual(outcome, .relaunchRequired)

        // A non-empty backup landed in <override>/backups/.
        let backupsDir = CorpusExporter.exportDirectory.appendingPathComponent("backups", isDirectory: true)
        let backups = (try? FileManager.default.contentsOfDirectory(at: backupsDir,
                                                                    includingPropertiesForKeys: [.fileSizeKey])) ?? []
        XCTAssertEqual(backups.count, 1, "exactly one backup file should be written")
        let size = (try backups[0].resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        XCTAssertGreaterThan(size, 0, "the backup must be non-empty")

        // The store files were then deleted.
        for url in storeFiles {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                           "store file \(url.lastPathComponent) should be deleted after a verified backup")
        }
    }

    /// Empty-corpus path: an EMPTY store produces a valid 0-byte (header-only)
    /// backup. `resetSync` must still SUCCEED — requiring a non-empty backup here
    /// would wrongly refuse to reset an empty, possibly wedged, store. We only need
    /// the backup file to EXIST when there are no notes.
    func testResetSyncSucceedsOnEmptyCorpus() throws {
        try makeTempDir()
        defer { cleanUpTempDir() }
        CorpusExporter.exportDirectoryOverride = tmp.appendingPathComponent("Ollie", isDirectory: true)

        let model = AppModel(inMemoryStore: true)
        // No notes composed — the corpus is empty on purpose.
        XCTAssertTrue(model.notes.isEmpty, "precondition: corpus must be empty")

        let storeFiles = try makeFakeStoreFiles()
        model.storeFileURLsForReset = storeFiles

        let outcome = try model.resetSync()
        XCTAssertEqual(outcome, .relaunchRequired,
                       "resetSync must succeed on an empty corpus (existence, not >0 bytes)")

        // A backup file still landed (existence is all we require for empty).
        let backupsDir = CorpusExporter.exportDirectory.appendingPathComponent("backups", isDirectory: true)
        let backups = (try? FileManager.default.contentsOfDirectory(
            at: backupsDir, includingPropertiesForKeys: nil)) ?? []
        XCTAssertEqual(backups.count, 1, "an empty corpus still writes one backup file")

        // And the store files were deleted.
        for url in storeFiles {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                           "store file \(url.lastPathComponent) should be deleted after the empty-corpus reset")
        }
    }

    /// Failure path: the export directory is UNWRITABLE, so the backup can't be
    /// written. `resetSync` must THROW `.backupFailed` and leave the store files
    /// completely untouched — the abort-before-destroy guarantee.
    func testResetSyncThrowsAndLeavesStoreUntouchedWhenBackupFails() throws {
        try makeTempDir()
        defer { cleanUpTempDir() }
        // Point the export root at a path that cannot be created/written: a child of
        // a REGULAR FILE. `createDirectory` under it fails, so `backup()` returns nil.
        let blocker = tmp.appendingPathComponent("not-a-dir")
        try Data("x".utf8).write(to: blocker)
        CorpusExporter.exportDirectoryOverride = blocker.appendingPathComponent("Ollie", isDirectory: true)

        let model = AppModel(inMemoryStore: true)
        model.composeNote(transcript: "This must NOT be lost — the reset must abort.")

        let storeFiles = try makeFakeStoreFiles()
        model.storeFileURLsForReset = storeFiles

        XCTAssertThrowsError(try model.resetSync()) { error in
            XCTAssertEqual(error as? AppModel.ResetSyncError, .backupFailed,
                           "a failed backup must surface as .backupFailed")
        }

        // ABSOLUTELY CRITICAL: nothing was deleted.
        for url in storeFiles {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                          "store file \(url.lastPathComponent) MUST survive when the backup fails")
        }
    }
}
