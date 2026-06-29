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
///     `AppModel.insert`). `id` is just a plain UUID here.
///   • Enums (`source`, `kind`) are stored as their `String` rawValue (CloudKit has
///     no notion of our Swift enums); the mappers round-trip them.
///   • The opt-in geotag is stored **flat** (`placeLabel`/`latitude`/`longitude`)
///     rather than as a nested type — flat optional attributes mirror cleanly and
///     dodge a CloudKit relationship. `location` projects them back to a `PlaceStamp`.
///   • `audioData` uses `.externalStorage` so the recording rides along in the
///     user's private database as a blob rather than bloating the row.
///
/// **Migration note:** new fields (`kindRaw`, the geotag columns, `schemaVersion`)
/// all carry defaults, so this is a purely additive lightweight migration. The
/// former `title` column is gone from the model; its data was always *derived* from
/// the transcript, so nothing real is lost (a stale CloudKit column, if any, is
/// simply unused).
@Model
public final class NoteEntity {
    /// The note's stable identity. Mirrors `Note.id`. Not a SwiftData unique
    /// constraint (CloudKit forbids those) — uniqueness is maintained by always
    /// upserting by this id (fetch-then-update-or-insert) rather than appending.
    public var id: UUID = UUID()
    public var transcript: String = ""
    /// `CaptureKind` stored as its `String` rawValue (see `kind`).
    public var kindRaw: String = CaptureKind.voice.rawValue
    public var createdAt: Date = Date.distantPast
    public var updatedAt: Date = Date.distantPast
    /// `NoteSource` stored as its `String` rawValue (see `noteSource`).
    public var sourceRaw: String = NoteSource.seed.rawValue
    /// Opt-in geotag, stored flat (see `location`). All nil unless the user enabled
    /// geotagging and a fix was captured.
    public var placeLabel: String?
    public var latitude: Double?
    public var longitude: Double?
    /// File name (not path) of the recording inside the store's local `Audio/`
    /// dir; nil if there is no audio. Same semantics as `Note.audioFileName`.
    public var audioFileName: String?
    public var durationSeconds: Double?
    public var engineUsed: String?
    public var isFavorite: Bool = false
    public var schemaVersion: Int = Note.currentSchemaVersion

    /// The recording bytes, synced via iCloud and stored outside the main row.
    /// Optional + external so a note with no audio (or before its blob syncs)
    /// costs nothing. Materialized back to a local `Audio/<id>.<ext>` file on
    /// demand by `AppModel.audioURL(for:)`.
    @Attribute(.externalStorage) public var audioData: Data?

    public init(
        id: UUID = UUID(),
        transcript: String = "",
        kindRaw: String = CaptureKind.voice.rawValue,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        sourceRaw: String = NoteSource.seed.rawValue,
        placeLabel: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        audioFileName: String? = nil,
        durationSeconds: Double? = nil,
        engineUsed: String? = nil,
        isFavorite: Bool = false,
        schemaVersion: Int = Note.currentSchemaVersion,
        audioData: Data? = nil
    ) {
        self.id = id
        self.transcript = transcript
        self.kindRaw = kindRaw
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.sourceRaw = sourceRaw
        self.placeLabel = placeLabel
        self.latitude = latitude
        self.longitude = longitude
        self.audioFileName = audioFileName
        self.durationSeconds = durationSeconds
        self.engineUsed = engineUsed
        self.isFavorite = isFavorite
        self.schemaVersion = schemaVersion
        self.audioData = audioData
    }

    /// The typed source, tolerating an unknown rawValue (falls back to `.seed`).
    public var noteSource: NoteSource {
        get { NoteSource(rawValue: sourceRaw) ?? .seed }
        set { sourceRaw = newValue.rawValue }
    }

    /// The typed capture kind, tolerating an unknown rawValue (falls back to
    /// `.voice`, matching `Note`'s tolerant decode).
    public var kind: CaptureKind {
        get { CaptureKind(rawValue: kindRaw) ?? .voice }
        set { kindRaw = newValue.rawValue }
    }

    /// The opt-in geotag projected from the flat columns. Nil when no place label
    /// was stored; setting it splits the stamp back across the columns.
    public var location: PlaceStamp? {
        get {
            guard let placeLabel else { return nil }
            return PlaceStamp(label: placeLabel, latitude: latitude, longitude: longitude)
        }
        set {
            placeLabel = newValue?.label
            latitude = newValue?.latitude
            longitude = newValue?.longitude
        }
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
            transcript: entity.transcript,
            kind: entity.kind,
            createdAt: entity.createdAt,
            updatedAt: entity.updatedAt,
            source: entity.noteSource,
            location: entity.location,
            audioFileName: entity.audioFileName,
            durationSeconds: entity.durationSeconds,
            engineUsed: entity.engineUsed,
            isFavorite: entity.isFavorite,
            schemaVersion: entity.schemaVersion)
    }
}

public extension NoteEntity {
    /// Build a fresh entity from a `Note` value. Used by the one-time legacy
    /// import and any `Note`-shaped insert. `audioData` is filled separately by
    /// the audio-sync step (it reads the local file and attaches the bytes).
    convenience init(note: Note, audioData: Data? = nil) {
        self.init(
            id: note.id,
            transcript: note.transcript,
            kindRaw: note.kind.rawValue,
            createdAt: note.createdAt,
            updatedAt: note.updatedAt,
            sourceRaw: note.source.rawValue,
            placeLabel: note.location?.label,
            latitude: note.location?.latitude,
            longitude: note.location?.longitude,
            audioFileName: note.audioFileName,
            durationSeconds: note.durationSeconds,
            engineUsed: note.engineUsed,
            isFavorite: note.isFavorite,
            schemaVersion: note.schemaVersion,
            audioData: audioData)
    }

    /// Overwrite this entity's mutable fields from a `Note` (used when upserting
    /// an existing id). Does not touch `audioData` — audio is managed by the
    /// audio-sync step so a re-import never drops an already-synced blob.
    func apply(_ note: Note) {
        transcript = note.transcript
        kind = note.kind
        createdAt = note.createdAt
        updatedAt = note.updatedAt
        sourceRaw = note.source.rawValue
        location = note.location
        audioFileName = note.audioFileName
        durationSeconds = note.durationSeconds
        engineUsed = note.engineUsed
        isFavorite = note.isFavorite
        schemaVersion = note.schemaVersion
    }
}
