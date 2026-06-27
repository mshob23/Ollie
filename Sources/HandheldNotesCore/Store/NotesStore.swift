import AVFoundation
import Foundation

/// The notes database: a JSON array of `Note` plus an `Audio/` directory of the
/// linked recordings. Lives in its own Application Support folder, completely
/// separate from the old app's data.
///
///   ~/Library/Application Support/HandheldNotes/
///       notes.json
///       Audio/<note-id>.wav
///
/// All file access is synchronous and cheap (the dataset is tiny); the store is
/// driven from the @MainActor AppModel, so it stays single-threaded by use.
public struct NotesStore {

    // MARK: Locations

    public static func baseDirectory() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let dir = appSupport.appendingPathComponent("HandheldNotes", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func audioDirectory() throws -> URL {
        let dir = try baseDirectory().appendingPathComponent("Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func notesURL() throws -> URL {
        try baseDirectory().appendingPathComponent("notes.json")
    }

    /// Absolute URL for a note's audio file, if it has one and the file exists.
    public static func audioURL(for note: Note) -> URL? {
        guard let name = note.audioFileName,
              let dir = try? audioDirectory() else { return nil }
        let url = dir.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: Load / Save

    public static func load() -> [Note] {
        guard let url = try? notesURL(), let data = try? Data(contentsOf: url) else {
            return []
        }
        do {
            return try decoder.decode([Note].self, from: data)
        } catch {
            // Preserve an unreadable file rather than clobbering it.
            try? data.write(to: url.appendingPathExtension("bak"), options: [.atomic])
            return []
        }
    }

    public static func save(_ notes: [Note]) {
        guard let url = try? notesURL() else { return }
        guard let data = try? encoder.encode(notes) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    /// True if a legacy `notes.json` exists to import (used by the one-time
    /// SwiftData migration).
    public static func legacyNotesFileExists() -> Bool {
        guard let url = try? notesURL() else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// After importing `notes.json` into the SwiftData store, rename it to
    /// `notes.json.imported` so it's kept as a backup but never re-read by the
    /// legacy loader. Best-effort; safe to call when no file exists.
    public static func archiveLegacyNotesFile() {
        guard let url = try? notesURL() else { return }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let backup = url.appendingPathExtension("imported")
        try? FileManager.default.removeItem(at: backup) // clear any prior backup
        try? FileManager.default.moveItem(at: url, to: backup)
    }

    // MARK: Audio file management

    /// Copies an arbitrary audio file into the store under the note's id, returns
    /// the stored file name (relative). Always normalizes to `.wav` extension on
    /// the stored name (the bytes are copied as-is).
    @discardableResult
    public static func importAudio(from sourceURL: URL, noteID: UUID) throws -> String {
        let dir = try audioDirectory()
        let ext = sourceURL.pathExtension.isEmpty ? "wav" : sourceURL.pathExtension
        let fileName = "\(noteID.uuidString).\(ext)"
        let dest = dir.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: sourceURL, to: dest)
        return fileName
    }

    public static func deleteAudio(named fileName: String) {
        guard let dir = try? audioDirectory() else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(fileName))
    }

    // MARK: Codable helpers

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}
