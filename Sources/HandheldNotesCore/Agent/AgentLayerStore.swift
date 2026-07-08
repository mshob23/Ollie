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
        /// Interaction-state caps (Views v2 spec §2). `blockText` is **truncated, not
        /// rejected** (it's a snapshot, not user-supplied content to validate); the
        /// others clamp mechanically. Interaction state is user-authored/app-written,
        /// so `setInteraction` sanitizes rather than throwing.
        public static let interactionBlockIdMax = 128
        public static let interactionBlockTextMax = 500
        public static let interactionValueMax = 64
        public static let interactionKindMax = 32
    }

    /// Well-known interaction-state constants for the **per-view "seen" stamp** (M16,
    /// contract §7 → "The `seen` kind"). A seen stamp reuses ``InteractionStateEntity``
    /// exactly as the M7 design anticipated (future kinds reuse the entity with no
    /// schema change): one durable row per view under a **sentinel** `blockId` that can
    /// never collide a real checklist item's content-hash id (those are `cl1:…`), with
    /// `value` = the seen revision's UUID string.
    ///
    /// A seen row is **app-internal UI state**: it is never exported to
    /// `interactions.jsonl`, never returned by `get_view.interactions`, and never enters
    /// the checkbox overlay. The kind string is the filter every one of those boundaries
    /// keys on — checkbox rows opt in, `seen` rows do not.
    public enum SeenStamp {
        /// The `kind` of a per-view read stamp (vs. `"checkbox"`, the agent-facing kind).
        public static let kind = "seen"
        /// The sentinel `blockId` a per-view stamp lives under — one row per
        /// `(viewName, "__view__")`. Deliberately not a `cl1:`/`cl2:` id, so it can never
        /// collide a real checklist block (contract §7: "do not collide it").
        public static let blockId = "__view__"
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

    /// The collapsed interaction state for one view — **one record per
    /// `(viewName, blockId)`**, latest `updatedAt` winning. Two devices can *insert*
    /// the same logical key while offline (CloudKit merges same-record edits but not
    /// concurrent inserts), so the read collapses duplicate keys here (spec §2, §6):
    /// the newest `updatedAt` wins and the losers are dropped from the result. Losers
    /// are pruned opportunistically elsewhere (the exporter's orphan pass); this
    /// reader never mutates.
    ///
    /// **Kind filter — checkbox-only by default (M16).** This is the checkbox-overlay
    /// feed (`ViewInteractionModel`, the renderer), so it returns only `kind:"checkbox"`
    /// rows unless a caller widens `kinds`. A per-view `"seen"` stamp lives under the
    /// sentinel `blockId "__view__"` (never a real checklist item's `cl1:` hash), so it
    /// could never *match* a real block anyway — but we filter on `kind` **explicitly**
    /// rather than relying on that: a seen row must never leak into the overlay by luck
    /// (contract §7). The default keeps every existing call site checkbox-only, unchanged.
    public func interactions(viewName: String,
                             kinds: Set<String> = ["checkbox"]) -> [ViewInteraction] {
        var d = FetchDescriptor<InteractionStateEntity>(
            predicate: #Predicate { $0.viewName == viewName },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        d.includePendingChanges = true
        let all = ((try? context.fetch(d)) ?? [])
            .filter { kinds.contains($0.kind) }
            .map(ViewInteraction.init(entity:))
        // Collapse duplicate keys: first seen wins because `all` is newest-first.
        var seen = Set<String>()
        var collapsed: [ViewInteraction] = []
        for i in all where seen.insert(i.blockId).inserted {
            collapsed.append(i)
        }
        return collapsed
    }

    /// **All** live interaction state across every view — the source for the
    /// `interactions.jsonl` export (Views v2 spec §6). Duplicate keys are collapsed
    /// per `(viewName, blockId)`, latest `updatedAt` winning (same LWW read semantics
    /// as ``interactions(viewName:)``, applied store-wide). Newest first. Never
    /// mutates — losers are pruned opportunistically by the exporter's orphan pass.
    ///
    /// **Kind filter — agent-facing kinds only (M16).** This is the export/agent feed,
    /// so it defaults to `kind:"checkbox"` and **excludes** app-internal `"seen"` stamps:
    /// a seen row is per-view read UI state that must never reach `interactions.jsonl`
    /// (contract §5, §7). This is the "belt" (the exporter also whitelists checkbox as
    /// the "braces", so a stale file from an older build still can't leak — instruction
    /// #3/#4). Future agent-facing kinds opt in by widening `kinds`.
    public func allInteractions(kinds: Set<String> = ["checkbox"]) -> [ViewInteraction] {
        let d = FetchDescriptor<InteractionStateEntity>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        let all = ((try? context.fetch(d)) ?? [])
            .filter { kinds.contains($0.kind) }
            .map(ViewInteraction.init(entity:))
        // Collapse duplicate keys — key on (viewName, blockId), first seen (newest) wins.
        var seen = Set<String>()
        var collapsed: [ViewInteraction] = []
        for i in all {
            let key = i.viewName + "\u{0}" + i.blockId   // NUL joiner — can't appear in either field
            if seen.insert(key).inserted { collapsed.append(i) }
        }
        return collapsed
    }

    /// The per-view **seen** stamps (M16) — `viewName → the stamp's `updatedAt``, the
    /// timestamp the user last opened that view. One entry per view that has ever been
    /// marked seen; a view with no stamp is simply absent (→ unread on first sight, the
    /// intended mailbox default). The snapshot builder (`AppModel.reloadNotes`) compares
    /// each entry against the view's latest-revision `createdAt`: **unread ⇔
    /// latestRevision.createdAt > stamp.updatedAt, or no stamp** (the same strictly-newer
    /// idiom as the checkbox overlay's supersession rule, spec §1).
    ///
    /// Reads only `kind:"seen"` rows (the sentinel `blockId "__view__"` gives at most one
    /// per view via the upsert key) and collapses duplicate keys latest-`updatedAt`-wins,
    /// exactly like ``interactions(viewName:)``. Never mutates.
    public func seenStamps() -> [String: Date] {
        let seenKind = SeenStamp.kind
        var d = FetchDescriptor<InteractionStateEntity>(
            predicate: #Predicate { $0.kind == seenKind },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        d.includePendingChanges = true
        let rows = (try? context.fetch(d)) ?? []
        // Newest-first, so the FIRST row seen for a view is its winning stamp.
        var stamps: [String: Date] = [:]
        for r in rows where stamps[r.viewName] == nil {
            stamps[r.viewName] = r.updatedAt
        }
        return stamps
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

    /// The **user** path for interaction state (a view checkbox toggle): upsert the
    /// single record for `(viewName, blockId)` (Views v2 spec §4). Like
    /// `setInstructions` this is user-authored/app-written — **not** an agent op, and
    /// there is no inbox op for it. Mechanical sanitization (caps) happens here:
    /// `blockText` is **truncated** to its cap (it's a snapshot, not rejected);
    /// `blockId`/`value`/`kind` are clamped defensively. Saves once.
    ///
    /// Upsert-by-key, not by `id`: CloudKit forbids unique constraints, so identity
    /// for `(viewName, blockId)` is enforced in code (contract §2). If duplicate-key
    /// records already exist (two devices inserted the same key offline), the newest
    /// `updatedAt` is updated in place and the losers are pruned opportunistically
    /// (users may delete anything — spec §6).
    public func setInteraction(_ value: ViewInteraction) {
        upsertInteraction(value)
        try? context.save()
    }

    /// Batch upsert of interaction state — the ``ViewInteractionModel`` settle path
    /// (Views v2 spec §4). Upserts every entry by `(viewName, blockId)` (same in-code
    /// key + duplicate-loser pruning as ``setInteraction(_:)``) and then **saves the
    /// `ModelContext` exactly once** for the whole batch, however many boxes changed —
    /// "one transactional save per settle" (spec §4). An empty batch is a no-op (no
    /// save), so a settle with nothing to write touches nothing.
    public func setInteractions(_ values: [ViewInteraction]) {
        guard !values.isEmpty else { return }
        for value in values { upsertInteraction(value) }
        try? context.save()
    }

    /// Mark a view **seen** at a given revision (M16, contract §7 → "The `seen` kind").
    /// Upserts the single per-view stamp row through the SAME `(viewName, blockId)`
    /// upsert path the checkbox layer uses — `blockId` is the sentinel
    /// ``SeenStamp/blockId`` (`"__view__"`), `kind` is ``SeenStamp/kind`` (`"seen"`),
    /// `value` is the seen revision's `uuidString`, `blockText` empty. The sentinel key
    /// means one durable row per view for free (a second mark rewrites it in place and
    /// advances `updatedAt`, never a second row), exactly like `setInteraction`.
    ///
    /// `updatedAt` is stamped **now** — it is the "when you read it" timestamp the unread
    /// comparison keys on (`seenStamps()`), so it must reflect the moment of marking, not
    /// the revision's age. Like every other user path (`setInteraction`, `userRestore`)
    /// this is app-written, un-attributed to an agent, no `AgentOp`, no inbox op, and it
    /// saves once. `surface` is provenance only (`"ios"`/`"mac"`/`"watch"`).
    ///
    /// A `"seen"` row is app-internal: `value` carries a bare revision UUID (≤ 64 chars,
    /// fits `Caps.interactionValueMax`) and never crosses the export boundary
    /// (`allInteractions()` + the exporter both whitelist `checkbox`).
    public func markViewSeen(viewName: String, revisionId: UUID, surface: String) {
        upsertInteraction(ViewInteraction(
            viewName: viewName,
            blockId: SeenStamp.blockId,
            blockText: "",
            kind: SeenStamp.kind,
            value: revisionId.uuidString,
            revisionId: revisionId,
            surface: surface,
            updatedAt: Date()))
        try? context.save()
    }

    /// The shared upsert-by-`(viewName, blockId)` body used by both the singular
    /// user-path ``setInteraction(_:)`` (saves) and the batch ``setInteractions(_:)``
    /// (one save for the whole batch). **Does not save** — the caller owns the
    /// transaction boundary. Mechanical sanitization (caps) happens here: `blockText`
    /// is truncated (a snapshot, not rejected), `blockId`/`value`/`kind` are clamped.
    private func upsertInteraction(_ value: ViewInteraction) {
        let key = value.viewName
        let block = value.blockId
        var d = FetchDescriptor<InteractionStateEntity>(
            predicate: #Predicate { $0.viewName == key && $0.blockId == block },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        d.includePendingChanges = true
        let matches = (try? context.fetch(d)) ?? []

        let blockText = String(value.blockText.prefix(Caps.interactionBlockTextMax))
        let blockId = String(value.blockId.prefix(Caps.interactionBlockIdMax))
        let rawValue = String(value.value.prefix(Caps.interactionValueMax))
        let kind = String(value.kind.prefix(Caps.interactionKindMax))

        if let winner = matches.first {
            // Update the newest existing record in place …
            winner.blockText = blockText
            winner.kind = kind
            winner.value = rawValue
            winner.revisionId = value.revisionId
            winner.surface = value.surface
            winner.updatedAt = value.updatedAt
            // … and prune any duplicate-key losers so the key converges to one record.
            for loser in matches.dropFirst() { context.delete(loser) }
        } else {
            context.insert(InteractionStateEntity(
                id: value.id,
                viewName: value.viewName,
                blockId: blockId,
                blockText: blockText,
                kind: kind,
                value: rawValue,
                revisionId: value.revisionId,
                surface: value.surface,
                updatedAt: value.updatedAt))
        }
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

    /// Hard-delete the tag records left **orphaned by a note deletion** — the store-side
    /// analogue of the exporter's orphan prune (Views v2 spec §6 does the same for
    /// interaction records of deleted views). Tags are linked to notes only by a bare
    /// `noteId` (no SwiftData relationship, so no delete cascade), so `AppModel.delete`
    /// removes the `NoteEntity` but leaves its `TagEntity` rows behind forever; those
    /// stragglers grow the store, sync out over CloudKit as dead records, and (until the
    /// export gate also drops them) leak the deleted note's tag text into `tags.jsonl`.
    /// This removes them so the store self-heals.
    ///
    /// **Deleted only, never restricted.** `existingNoteIDs` must be the ids of **all**
    /// notes currently in the store — *including restricted ones* (a restricted note
    /// still has a `NoteEntity`; only its export is suppressed). A tag survives iff its
    /// note still exists; a restricted note's tags are therefore **kept** (restriction is
    /// reversible — un-restricting the note must bring its tags back), while a truly
    /// deleted note's tags are pruned. This is the crucial distinction the export-time
    /// filter can't make on its own (from the exporter's vantage a restricted and a
    /// deleted note look identical — both absent from the exported set), so the hard
    /// prune keys on *store existence*, not exportability.
    ///
    /// Idempotent and save-once: no-op (no save) when nothing is orphaned. Returns the
    /// number of tag records deleted (0 when clean) so callers/tests can assert.
    @discardableResult
    public func pruneOrphanedTags(existingNoteIDs: Set<UUID>) -> Int {
        let orphans = allTagEntities().filter { !existingNoteIDs.contains($0.noteId) }
        guard !orphans.isEmpty else { return 0 }
        for e in orphans { context.delete(e) }
        try? context.save()
        return orphans.count
    }

    /// Every `TagEntity` in the store (live objects, for mutation/prune). The value-type
    /// ``allTags()`` is for reads; this returns the entities so a prune can delete them.
    private func allTagEntities() -> [TagEntity] {
        let d = FetchDescriptor<TagEntity>()
        return (try? context.fetch(d)) ?? []
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

    /// The **user** path to restore an earlier view revision (plan §M8 8b, the "time
    /// machine"). Appends a **new** revision to `viewName` copying the source
    /// revision's `body` — history is append-only, never edited or reordered, so the
    /// source revision stays byte-identical and the restored copy becomes the newest
    /// (latest-`createdAt`-wins display). Attribution is `user-<surface>`
    /// (`user-mac` / `user-ios`) — a user-initiated action, not an agent (contract §1).
    ///
    /// Follows the same append shape as `view.publish` (a fresh ``ViewRevisionEntity``,
    /// stamped `createdAt = now`), but it is a user path, so — like the other
    /// `userDelete`/`setInteraction` user methods — there is no `AgentOp`, no inbox op,
    /// and no meaning validation. A `revisionId` that isn't a revision of `viewName` is
    /// a **safe no-op** (mirrors the tolerant `userDelete` conventions): nothing is
    /// written and nothing throws.
    ///
    /// Free M7 synergy: the restored copy is newer than any earlier revision, so per the
    /// interaction precedence rule (spec §1) stale checkbox overlays anchored to older
    /// revisions stop applying automatically — exactly the desired "rewind" behavior.
    public func userRestore(viewName: String, revisionId: UUID, surface: String) {
        var d = FetchDescriptor<ViewRevisionEntity>(
            predicate: #Predicate { $0.id == revisionId && $0.viewName == viewName })
        d.fetchLimit = 1
        guard let source = try? context.fetch(d).first else { return }   // unknown id → no-op

        context.insert(ViewRevisionEntity(
            viewName: viewName,
            body: source.body,                 // copy the old body verbatim (append, never edit)
            agentId: "user-\(surface)",
            createdAt: Date()))
        try? context.save()
    }

    /// User delete of a whole view — removes *all* revisions sharing the name **and**
    /// cascades to its interaction state (deleting a view deletes its checkbox state;
    /// Views v2 spec §4). Saves once for the whole cascade.
    ///
    /// The interaction cascade joins purely on `viewName` with **no kind filter**, so it
    /// prunes a `"seen"` stamp (M16) for the deleted view identically to its `"checkbox"`
    /// rows — the deleted view leaves no interaction residue of either kind (contract §7:
    /// the same `viewName` join covers seen rows).
    public func userDelete(view name: String) {
        let dRev = FetchDescriptor<ViewRevisionEntity>(
            predicate: #Predicate { $0.viewName == name })
        let revisions = (try? context.fetch(dRev)) ?? []

        let dInter = FetchDescriptor<InteractionStateEntity>(
            predicate: #Predicate { $0.viewName == name })
        let interactions = (try? context.fetch(dInter)) ?? []

        guard !revisions.isEmpty || !interactions.isEmpty else { return }
        for r in revisions { context.delete(r) }
        for i in interactions { context.delete(i) }
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
