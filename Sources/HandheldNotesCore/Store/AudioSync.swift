import AVFoundation
import Foundation

/// Moves recording bytes between the local `Audio/<id>.<ext>` files (what
/// `NotesStore`/`AudioPlayerView` use) and a `NoteEntity.audioData` blob (what
/// rides along in the user's private iCloud). Two directions:
///
///   • **encode** — read a note's local audio file into `Data` for storing on the
///     entity so it syncs. WAV is transcoded to AAC/m4a where practical (smaller
///     over the wire, and m4a is already the watch's native format); anything
///     else is stored as-is.
///   • **materialize** — on a device that received a note over iCloud but doesn't
///     have the local file yet, write the synced blob back out to
///     `Audio/<id>.<ext>` so `NotesStore.audioURL(for:)` resolves and the player
///     just works.
///
/// All operations are best-effort: a failure here must never break a note (the
/// transcript is the durable part), so callers treat a `nil`/`false` result as
/// "no audio synced this time" and move on.
public enum AudioSync {

    /// Outcome of encoding a local audio file for sync: the bytes plus the file
    /// name they should be stored under (which may have flipped `.wav` → `.m4a`
    /// if we transcoded). Callers persist BOTH onto the entity so every device
    /// agrees on the on-disk extension when it materializes the blob.
    public struct Encoded: Sendable {
        public let data: Data
        public let fileName: String
    }

    /// Read the local audio for `note` into a blob suitable for `audioData`.
    /// Transcodes WAV → m4a/AAC when possible; falls back to the raw bytes (under
    /// the original file name) if transcoding isn't available or fails. Returns
    /// nil if the note has no resolvable local audio file.
    public static func encode(for note: Note) async -> Encoded? {
        guard let localURL = NotesStore.audioURL(for: note),
              let fileName = note.audioFileName else { return nil }

        let isWAV = localURL.pathExtension.lowercased() == "wav"
        if isWAV {
            if let m4a = try? await transcodeToM4A(localURL) {
                // Store under an .m4a name so materialize writes a matching file.
                let base = (fileName as NSString).deletingPathExtension
                return Encoded(data: m4a, fileName: "\(base).m4a")
            }
            // Transcode unavailable/failed → fall through to raw bytes.
        }

        guard let raw = try? Data(contentsOf: localURL) else { return nil }
        return Encoded(data: raw, fileName: fileName)
    }

    /// If `entity` carries an `audioData` blob but its local `Audio/<id>.<ext>`
    /// file is missing, write the blob out so the player can find it. Returns the
    /// resolved local URL (existing or freshly written), or nil if there's
    /// nothing to do / it couldn't be written. Idempotent and cheap when the file
    /// already exists.
    @discardableResult
    public static func materialize(_ entity: NoteEntity) -> URL? {
        guard let fileName = entity.audioFileName,
              let dir = try? NotesStore.audioDirectory() else { return nil }
        let url = dir.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard let data = entity.audioData else { return nil }
        do {
            try data.write(to: url, options: [.atomic])
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Transcode

    /// Transcode an audio file to AAC in an .m4a container via AVFoundation.
    /// Throws on any failure so the caller can fall back to raw bytes. Uses the
    /// modern `export(to:as:)` async API (the completion-handler form is
    /// deprecated and trips Sendable-capture checks under Swift 6).
    private static func transcodeToM4A(_ sourceURL: URL) async throws -> Data {
        let asset = AVURLAsset(url: sourceURL)
        guard let export = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw CocoaError(.featureUnsupported)
        }
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hn-transcode-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: outURL) }

        try await export.export(to: outURL, as: .m4a)
        return try Data(contentsOf: outURL)
    }
}
