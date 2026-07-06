import Foundation
import SwiftData

/// The **single write choke point** for the agent layer. Every door — the inbox
/// ingestor, the MCP server (via the inbox), future App Intents, a future on-device
/// agent — reads and writes the tags / memory / view-revision / instructions records
/// through *this* type; agents never touch `ModelContext` directly (see
/// `docs/agent-contract.md` §3).
///
/// **Mechanical validation lives here and only here.** `apply(_:)` checks ids and
/// sizes and throws ``AgentLayerError`` — it *never* judges whether a tag is sensible
/// or a memory is true (contract §0: "validate mechanics, never meaning"). The caps
/// come from the inbox protocol table (contract §4); reusing this one implementation
/// keeps every door consistent.
///
/// **Attribution & append-only.** Every derived record is stamped with the op's
/// `agent` + a timestamp. Tags are a set per note (idempotent apply, deduped
/// case-insensitively); memory is append-only (`retire` flips a tombstone, never a
/// hard edit); views append revisions (latest `createdAt` wins). Users — never
/// agents — hard-delete via `userDelete`.
///
/// A `struct` (not a class) holding a `ModelContext`: cheap to construct per use,
/// `@MainActor` because SwiftData contexts are main-actor-bound here (same as
/// `AppModel`'s write context).
@MainActor
public struct AgentLayerStore {

    /// Length caps for the mechanically-validated string fields, straight from the
    /// inbox protocol table (contract §4). Exposed so other doors (the MCP client,
    /// the ingestor) reject with the *same* bounds before writing.
    public enum Caps {
        public static let tagMax = 64
        public static let memoryTextMax = 2000
        public static let viewNameMax = 80
        public static let viewBodyMax = 131072
    }

    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Queries

    /// Tags applied to one note, newest first.
    public func tags(forNote noteId: UUID) -> [AgentTag] {
        var d = FetchDescriptor<TagEntity>(
            predicate: #Predicate { $0.noteId == noteId },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        d.includePendingChanges = true
        return ((try? context.fetch(d)) ?? []).map(AgentTag.init(entity:))
    }

    /// Every tag in the store, newest first — the source for the tag vocabulary and
    /// the `tags.jsonl` export.
    public func allTags() -> [AgentTag] {
        let d = FetchDescriptor<TagEntity>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        return ((try? context.fetch(d)) ?? []).map(AgentTag.init(entity:))
    }

    /// Memory entries newest first. Retired (tombstoned) entries are excluded unless
    /// `includeRetired` is true (the export and the trust-surface UI pass true so the
    /// tombstone is visible/flagged).
    public func memory(includeRetired: Bool) -> [AgentMemory] {
        var d = FetchDescriptor<MemoryEntity>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        if !includeRetired {
            d.predicate = #Predicate { $0.retired == false }
        }
        return ((try? context.fetch(d)) ?? []).map(AgentMemory.init(entity:))
    }

    /// The distinct view names present, sorted by the view's most-recent revision
    /// (newest view first).
    public func viewNames() -> [String] {
        // One entry per name, ordered by that name's latest revision.
        var latestByName: [String: Date] = [:]
        for r in allRevisionsNewestFirst() {
            if let existing = latestByName[r.viewName] {
                if r.createdAt > existing { latestByName[r.viewName] = r.createdAt }
            } else {
                latestByName[r.viewName] = r.createdAt
            }
        }
        return latestByName.sorted { $0.value > $1.value }.map(\.key)
    }

    /// All revisions of one view, newest first.
    public func revisions(viewName: String) -> [AgentViewRevision] {
        var d = FetchDescriptor<ViewRevisionEntity>(
            predicate: #Predicate { $0.viewName == viewName },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        d.includePendingChanges = true
        return ((try? context.fetch(d)) ?? []).map(AgentViewRevision.init(entity:))
    }

    /// The latest revision of each view, newest-view first — what the Views feed
    /// renders (one row per view).
    public func latestRevisions() -> [AgentViewRevision] {
        var latest: [String: AgentViewRevision] = [:]
        for r in allRevisionsNewestFirst() {
            if let existing = latest[r.viewName] {
                if r.createdAt > existing.createdAt { latest[r.viewName] = r }
            } else {
                latest[r.viewName] = r
            }
        }
        return latest.values.sorted { $0.createdAt > $1.createdAt }
    }

    /// The user's standing instructions text, or `""` if none has been written yet.
    public func instructions() -> String {
        instructionsEntity()?.text ?? ""
    }

    // MARK: - Mutations (mechanical validation here; throws AgentLayerError)

    /// Apply one agent op. Validates mechanics (ids exist, sizes within caps) and
    /// writes the derived record attributed to the op's `agent`, then saves. Throws
    /// ``AgentLayerError`` on any mechanical failure — nothing is written on a throw.
    ///
    /// - `tag`: idempotent — an existing `(noteId, tag)` pair (matched
    ///   case-insensitively) is a no-op.
    /// - `untag`: deletes the matching record(s) (case-insensitive); absent is a no-op.
    /// - `memory.append`: appends a new entry.
    /// - `memory.retire`: flips the tombstone on an existing entry (idempotent).
    /// - `view.publish`: appends a revision under the (exact) view name.
    public func apply(_ op: AgentOp) throws {
        guard let kind = op.kind else { throw AgentLayerError.unknownOp(op.op) }
        switch kind {
        case .tag:         try applyTag(op)
        case .untag:       try applyUntag(op)
        case .memoryAppend: try applyMemoryAppend(op)
        case .memoryRetire: try applyMemoryRetire(op)
        case .viewPublish:  try applyViewPublish(op)
        }
        try? context.save()
    }

    /// The **user** path for instructions (Settings UI): upsert the single
    /// well-known record. Not an agent op — the user authors this, so it *is* edited
    /// in place (unlike append-only agent records). No validation (it's the user's
    /// own text).
    public func setInstructions(_ text: String) {
        if let existing = instructionsEntity() {
            existing.text = text
            existing.updatedAt = Date()
        } else {
            context.insert(InstructionsEntity(text: text, updatedAt: Date()))
        }
        try? context.save()
    }

    /// User hard-delete of a tag (contract §0: users may delete anything). Removes
    /// the specific record by id.
    public func userDelete(tag: AgentTag) {
        let id = tag.id
        var d = FetchDescriptor<TagEntity>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        if let e = try? context.fetch(d).first {
            context.delete(e)
            try? context.save()
        }
    }

    /// User hard-delete of a memory entry (removes it outright, distinct from an
    /// agent `retire` which only tombstones).
    public func userDelete(memory: AgentMemory) {
        let id = memory.id
        var d = FetchDescriptor<MemoryEntity>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        if let e = try? context.fetch(d).first {
            context.delete(e)
            try? context.save()
        }
    }

    /// User delete of a whole view — removes *all* revisions sharing the name.
    public func userDelete(view name: String) {
        let d = FetchDescriptor<ViewRevisionEntity>(
            predicate: #Predicate { $0.viewName == name })
        let revisions = (try? context.fetch(d)) ?? []
        guard !revisions.isEmpty else { return }
        for r in revisions { context.delete(r) }
        try? context.save()
    }

    // MARK: - Op implementations

    private func applyTag(_ op: AgentOp) throws {
        guard let noteId = op.payload.noteId else { throw AgentLayerError.missingField("noteId") }
        let raw = (op.payload.tag ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidTag(raw) else { throw AgentLayerError.invalidLength(field: "tag", limit: Caps.tagMax) }
        try requireNote(noteId)

        // Idempotent set semantics: an existing (noteId, tag) pair, matched
        // case-insensitively, is a no-op.
        let existing = fetchTags(noteId: noteId)
        if existing.contains(where: { $0.tag.caseInsensitiveCompare(raw) == .orderedSame }) {
            return
        }
        context.insert(TagEntity(noteId: noteId, tag: raw, agentId: op.agent, createdAt: op.ts))
    }

    private func applyUntag(_ op: AgentOp) throws {
        guard let noteId = op.payload.noteId else { throw AgentLayerError.missingField("noteId") }
        let raw = (op.payload.tag ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw AgentLayerError.missingField("tag") }
        try requireNote(noteId)

        // Delete the matching record(s), case-insensitively (mirrors apply's dedup).
        for e in fetchTags(noteId: noteId)
            where e.tag.caseInsensitiveCompare(raw) == .orderedSame {
            context.delete(e)
        }
    }

    private func applyMemoryAppend(_ op: AgentOp) throws {
        let text = (op.payload.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= Caps.memoryTextMax else {
            throw AgentLayerError.invalidLength(field: "text", limit: Caps.memoryTextMax)
        }
        context.insert(MemoryEntity(text: text, agentId: op.agent, createdAt: op.ts))
    }

    private func applyMemoryRetire(_ op: AgentOp) throws {
        guard let id = op.payload.id else { throw AgentLayerError.missingField("id") }
        var d = FetchDescriptor<MemoryEntity>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        guard let entry = try? context.fetch(d).first else {
            throw AgentLayerError.memoryNotFound(id)
        }
        // Idempotent: retiring an already-retired entry keeps its original stamp.
        if !entry.retired {
            entry.retired = true
            entry.retiredAt = op.ts
        }
    }

    private func applyViewPublish(_ op: AgentOp) throws {
        let name = (op.payload.viewName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= Caps.viewNameMax else {
            throw AgentLayerError.invalidLength(field: "viewName", limit: Caps.viewNameMax)
        }
        // Body is NOT trimmed (leading/trailing whitespace can be meaningful markdown);
        // only its length and non-emptiness are checked.
        let body = op.payload.body ?? ""
        guard !body.isEmpty, body.count <= Caps.viewBodyMax else {
            throw AgentLayerError.invalidLength(field: "body", limit: Caps.viewBodyMax)
        }
        context.insert(ViewRevisionEntity(viewName: name, body: body, agentId: op.agent, createdAt: op.ts))
    }

    // MARK: - Helpers

    /// A tag is valid iff it is 1–``Caps.tagMax`` characters and fully printable
    /// (no control characters / newlines). Freeform otherwise — the store never
    /// judges what the tag *means*.
    private func isValidTag(_ tag: String) -> Bool {
        guard !tag.isEmpty, tag.count <= Caps.tagMax else { return false }
        // Reject any control character (covers newlines, tabs, etc.) — "printable".
        return tag.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    private func requireNote(_ noteId: UUID) throws {
        var d = FetchDescriptor<NoteEntity>(predicate: #Predicate { $0.id == noteId })
        d.fetchLimit = 1
        guard (try? context.fetch(d).first) != nil else {
            throw AgentLayerError.noteNotFound(noteId)
        }
    }

    /// Live tag entities for a note (includes pending, uncommitted inserts so
    /// idempotency holds within a single apply batch).
    private func fetchTags(noteId: UUID) -> [TagEntity] {
        var d = FetchDescriptor<TagEntity>(predicate: #Predicate { $0.noteId == noteId })
        d.includePendingChanges = true
        return (try? context.fetch(d)) ?? []
    }

    private func allRevisionsNewestFirst() -> [AgentViewRevision] {
        let d = FetchDescriptor<ViewRevisionEntity>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        return ((try? context.fetch(d)) ?? []).map(AgentViewRevision.init(entity:))
    }

    private func instructionsEntity() -> InstructionsEntity? {
        let wellKnown = InstructionsEntity.wellKnownID
        var d = FetchDescriptor<InstructionsEntity>(predicate: #Predicate { $0.id == wellKnown })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }
}
