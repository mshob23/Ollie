import Foundation

/// **Arrival-time coverage** (M13): a small persisted map `noteId → firstSeenAt`, the
/// timestamp a note first became visible to *this Mac's* store — its **arrival** at the
/// hub, not its capture (`createdAt`) time.
///
/// ## Why this exists (the late-sync coverage hole)
/// The agent runner walks new notes with `list_notes(since: lastRunAt)`, and
/// `list_notes` filters on **`createdAt`** — *event* time. A note spoken into the watch
/// on the sidewalk carries the moment it was spoken; but its CloudKit sync to the Mac
/// can land **hours** later. By then every future `since` window has already swept past
/// that old `createdAt`, so the late arrival falls outside all of them and is **never
/// seen** — silently. (The capture-bar `createdAt` stamp bug is fixed, but *late sync*
/// is inherent to a multi-device store; there is no capture-time fix for it.) Coverage
/// must therefore key on when a note **arrived here**, and that is exactly what this
/// index records. The exporter stamps each exported note's `ingestedAt` from it, and
/// the runner switches to `list_notes(ingested_since: lastRunAt)` — a window that a
/// late arrival lands *inside*, so it gets tagged.
///
/// ## Where it lives — deliberately NOT under `~/Ollie`
/// The app's private **Application Support** directory
/// (`~/Library/Application Support/Ollie/ingest-index.json`), the same home as
/// `EmbeddingIndex`. It must **never** be written under `~/Ollie/`: this map keys on
/// note **UUIDs**, and a *restricted* note's id lands in here just like any other (the
/// index is populated before — and independently of — the export gate). "Restriction is
/// contagious" covers a restricted note *and anything derived from it, including its
/// bare UUID* (CLAUDE.md invariant 4 / contract §0): even an opaque id must not cross
/// the export boundary. So the index stays on the private side of the boundary; only the
/// exporter reads it, and only to stamp `ingestedAt` on notes that **already** passed
/// the gate (`CorpusGate.exportableNotes`) — a restricted note's arrival time is looked
/// up but, since the note itself is dropped, never emitted.
///
/// ## Behavior
/// - **First-seen wins.** `firstSeen(for:)` records `now` for an id only if it is not
///   already present — an id re-observed on a later pass keeps its original stamp.
///   (A note deleted long enough for `prune` to drop its entry and then re-arriving is
///   stamped anew at that arrival — correct: it genuinely re-arrived.) `seed(_:)`
///   records a supplied timestamp (see below).
/// - **Seeding the pre-existing corpus.** On the very first `reloadNotes` pass the
///   store already holds the whole historical corpus; stamping all of them with `now`
///   would make the entire corpus look "ingested today" and the runner would re-read
///   everything on its next `ingested_since` window. So the first pass **seeds each
///   existing note with its own `createdAt`** (`seedIfAbsent`), placing old notes in
///   the past where they belong; only notes that *arrive after* the seed get `now`.
/// - **Pruning.** `prune(keeping:)` drops entries whose note id is no longer in the
///   store, so the map cannot grow without bound as notes are deleted. Wired to
///   piggyback the exporter's existing orphan-prune trigger in `reloadNotes`.
/// - **Tolerant persistence.** A missing or corrupt file loads as **empty** and
///   self-heals on the next save — never throws, never blocks a reload. Saves are
///   atomic (temp write + rename, via `Data.write(options: .atomic)`). Note the
///   recovery direction (review, Jul 2026): if the index FILE is lost mid-life, the
///   next (non-first) pass re-stamps every current note at `now` — not `createdAt` —
///   a deliberate over-cover: the next runner window re-reads the corpus once
///   (idempotent) rather than risking a silent miss.
///
/// ## Concurrency
/// Not an actor: like `EmbeddingIndex`, it is driven entirely from `AppModel`
/// (`@MainActor`) on the reload path, so it stays single-threaded by use. The clock and
/// file URL are injectable so tests drive arrivals deterministically and never touch the
/// real Application Support file.
public final class IngestIndex {

    /// `noteId.uuidString → firstSeenAt`. String keys → clean JSON on disk (and a
    /// stable, human-greppable file), mirroring `EmbeddingIndex`.
    private var entries: [String: Date]
    private let fileURL: URL
    private let clock: () -> Date

    /// - Parameters:
    ///   - fileURL: where to persist. Defaults to
    ///     `~/Library/Application Support/Ollie/ingest-index.json` — **never** `~/Ollie`.
    ///     Injectable so tests point at a temp file.
    ///   - clock: the "now" source for `firstSeen`. Injectable so tests assert exact
    ///     arrival stamps; defaults to `Date.init`.
    public init(fileURL: URL? = nil, clock: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL ?? Self.defaultURL()
        self.clock = clock
        // Tolerant load: a missing OR corrupt file starts empty and self-heals on the
        // next save. An ISO8601 map on disk decodes here; anything else → empty.
        if let data = try? Data(contentsOf: self.fileURL),
           let decoded = try? Self.decoder.decode([String: Date].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    /// The default persistence location: `~/Library/Application Support/Ollie/`.
    /// Creates the directory best-effort (a failure just means the first save logs and
    /// the index stays in-memory for the session — coverage degrades to `createdAt`,
    /// never crashes). **Not** under `~/Ollie` — see the type doc.
    private static func defaultURL() -> URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ollie", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ingest-index.json")
    }

    // MARK: - Query

    /// The recorded first-arrival timestamp for `id`, or `nil` if this store has never
    /// seen the note. The exporter uses this (falling back to the note's `createdAt`)
    /// to stamp `ingestedAt`.
    public func firstSeen(for id: UUID) -> Date? {
        entries[id.uuidString]
    }

    /// Whether the index already has an entry for `id`. Lets `reloadNotes` tell a
    /// genuine new arrival (record `now`) from a note it has seen before (leave alone).
    public func contains(_ id: UUID) -> Bool {
        entries[id.uuidString] != nil
    }

    /// The number of recorded entries (test-facing).
    public var count: Int { entries.count }

    /// A `[UUID: Date]` copy of the map for handing to the exporter (which keys notes by
    /// `UUID`). Non-UUID keys — impossible from our own writes, but a hand-edited or
    /// corrupt file could carry one — are skipped. `Sendable`, so it rides safely into
    /// the detached export task.
    public func snapshot() -> [UUID: Date] {
        var out: [UUID: Date] = [:]
        out.reserveCapacity(entries.count)
        for (key, date) in entries {
            if let id = UUID(uuidString: key) { out[id] = date }
        }
        return out
    }

    // MARK: - Record

    /// Record `id`'s first arrival as **now** (the injected clock), *unless it is
    /// already present* — first-seen wins, so a re-arrival after a transient delete
    /// keeps the original stamp. Returns `true` iff a new entry was added (so the caller
    /// can decide whether to persist). Does **not** save on its own — the caller batches
    /// a single `save()` per reload.
    @discardableResult
    public func recordArrival(_ id: UUID) -> Bool {
        let key = id.uuidString
        guard entries[key] == nil else { return false }
        entries[key] = clock()
        return true
    }

    /// Seed `id` with an **explicit** timestamp only if absent — used by the first
    /// `reloadNotes` pass to stamp each pre-existing note with its own `createdAt`
    /// (NOT `now`), so the historical corpus sits in the past and the runner does not
    /// re-read all of it. Returns `true` iff a new entry was added. Never overwrites an
    /// existing (possibly earlier, real-arrival) stamp. Does not save on its own.
    @discardableResult
    public func seedIfAbsent(_ id: UUID, at date: Date) -> Bool {
        let key = id.uuidString
        guard entries[key] == nil else { return false }
        entries[key] = date
        return true
    }

    /// Drop entries whose note id is no longer among `keeping` — the store's current
    /// live set. Keeps the map from growing unbounded as notes are deleted (the same
    /// hygiene the exporter's orphan-tag prune performs, and wired to the same trigger).
    /// Returns the number of entries removed. Does not save on its own.
    @discardableResult
    public func prune(keeping liveIDs: Set<UUID>) -> Int {
        let live = Set(liveIDs.map(\.uuidString))
        let doomed = entries.keys.filter { !live.contains($0) }
        for key in doomed { entries[key] = nil }
        return doomed.count
    }

    // MARK: - Persist

    /// Atomically write the index to disk (temp file + rename, via `.atomic`). Keys are
    /// sorted so the file is stable/diff-friendly; dates encode as ISO8601 to match the
    /// exported `ingestedAt`. Best-effort: a failure is logged, never thrown — a lost
    /// save just means some arrivals re-stamp next session, and coverage degrades to
    /// `createdAt`, never a crash or a blocked reload.
    public func save() {
        do {
            let data = try Self.encoder.encode(entries)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            Diag.log("HNDIAG IngestIndex FAILED to write \(fileURL.path): \(error)")
        }
    }

    // MARK: - Coders

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
}
