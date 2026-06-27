import Foundation
import SwiftData

/// The SwiftData persistence model that backs the app's notes, kept deliberately
/// separate from the public ``Note`` value type. ``Note`` stays the byte-for-byte
/// API the views, search, and selection use; `NoteEntity` is the on-disk +
/// CloudKit-synced record that `AppModel` projects an `[Note]` array out of.
///
/// **CloudKit constraints baked in (do not relax):**
///   • Every stored property has a default value. CloudKit mirroring requires
///     non-optional attributes to be initializable with no value (the mirror can
///     materialize a record before every field has arrived).
///   • No `.unique` / `#Unique`. CloudKit forbids unique constraints, so identity
///     is enforced in code (we fetch-by-`id` before inserting; see
///     `AppModel.upsert`/import). `id` is just a plain indexed-by-use UUID here.
///   • `source` is stored as the `NoteSource` *rawValue* `String` (CloudKit has no
///     notion of our Swift enum); the mapper round-trips it.
///   • `audioData` uses `.externalStorage` so the recording rides along in the
///     user's private database as a CKAsset-style blob rather than bloating the
///     row — the user opted into syncing audio and has the iCloud space for it.
@Model
public final class NoteEntity {
    /// The note's stable identity. Mirrors `Note.id`. Not a SwiftData unique
    /// constraint (CloudKit forbids those) — uniqueness is maintained by always
    /// upserting by this id (fetch-then-update-or-insert) rather than appending.
    public var id: UUID = UUID()
    public var title: String = ""
    public var transcript: String = ""
    public var createdAt: Date = Date.distantPast
    public var updatedAt: Date = Date.distantPast
    /// `NoteSource` stored as its `String` rawValue (see `noteSource`).
    public var sourceRaw: String = NoteSource.seed.rawValue
    /// File name (not path) of the recording inside the store's local `Audio/`
    /// dir; nil if there is no audio. Same semantics as `Note.audioFileName`.
    public var audioFileName: String?
    public var durationSeconds: Double?
    public var engineUsed: String?
    public var isFavorite: Bool = false

    /// The recording bytes, synced via iCloud and stored outside the main row.
    /// Optional + external so a note with no audio (or before its blob syncs)
    /// costs nothing. Materialized back to a local `Audio/<id>.<ext>` file on
    /// demand by `AppModel.audioURL(for:)` so `NotesStore.audioURL` keeps working
    /// on a device that received the note but not yet its local file.
    @Attribute(.externalStorage) public var audioData: Data?

    public init(
        id: UUID = UUID(),
        title: String = "",
        transcript: String = "",
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        sourceRaw: String = NoteSource.seed.rawValue,
        audioFileName: String? = nil,
        durationSeconds: Double? = nil,
        engineUsed: String? = nil,
        isFavorite: Bool = false,
        audioData: Data? = nil
    ) {
        self.id = id
        self.title = title
        self.transcript = transcript
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.sourceRaw = sourceRaw
        self.audioFileName = audioFileName
        self.durationSeconds = durationSeconds
        self.engineUsed = engineUsed
        self.isFavorite = isFavorite
        self.audioData = audioData
    }

    /// The typed source, tolerating an unknown rawValue (falls back to `.seed`,
    /// matching `Note`'s own tolerant decode).
    public var noteSource: NoteSource {
        get { NoteSource(rawValue: sourceRaw) ?? .seed }
        set { sourceRaw = newValue.rawValue }
    }
}

// MARK: - Note ↔ NoteEntity mapping

public extension Note {
    /// Project a stored entity into the public value type the UI consumes. The
    /// synced `audioData` blob is intentionally NOT carried into `Note`
    /// (`Note.audioFileName` already points at the local file; audio is
    /// materialized lazily, see `AppModel.audioURL(for:)`).
    init(entity: NoteEntity) {
        self.init(
            id: entity.id,
            title: entity.title,
            transcript: entity.transcript,
            createdAt: entity.createdAt,
            updatedAt: entity.updatedAt,
            source: entity.noteSource,
            audioFileName: entity.audioFileName,
            durationSeconds: entity.durationSeconds,
            engineUsed: entity.engineUsed,
            isFavorite: entity.isFavorite)
    }
}

public extension NoteEntity {
    /// Build a fresh entity from a `Note` value. Used by the one-time legacy
    /// import and any `Note`-shaped insert. `audioData` is filled separately by
    /// the audio-sync step (it reads the local file and attaches the bytes).
    convenience init(note: Note, audioData: Data? = nil) {
        self.init(
            id: note.id,
            title: note.title,
            transcript: note.transcript,
            createdAt: note.createdAt,
            updatedAt: note.updatedAt,
            sourceRaw: note.source.rawValue,
            audioFileName: note.audioFileName,
            durationSeconds: note.durationSeconds,
            engineUsed: note.engineUsed,
            isFavorite: note.isFavorite,
            audioData: audioData)
    }

    /// Overwrite this entity's mutable fields from a `Note` (used when upserting
    /// an existing id). Does not touch `audioData` — audio is managed by the
    /// audio-sync step so a re-import never drops an already-synced blob.
    func apply(_ note: Note) {
        title = note.title
        transcript = note.transcript
        createdAt = note.createdAt
        updatedAt = note.updatedAt
        sourceRaw = note.source.rawValue
        audioFileName = note.audioFileName
        durationSeconds = note.durationSeconds
        engineUsed = note.engineUsed
        isFavorite = note.isFavorite
    }
}
