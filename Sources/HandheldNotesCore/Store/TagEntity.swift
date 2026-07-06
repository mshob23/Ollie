import Foundation
import SwiftData

/// A single agent-authored **tag** on a note — cached judgment the agent layer
/// writes *back* into the store (see the agent-layer contract, `docs/agent-contract.md`).
/// Kept deliberately separate from the public ``AgentTag`` value type, mirroring the
/// `NoteEntity`↔``Note`` split: `AgentTag` is the byte-for-byte API that queries,
/// export, and the UI consume; `TagEntity` is the on-disk + CloudKit-synced record.
///
/// **Semantics (contract §2):** tags are a *set per note* — applying an existing
/// `(noteId, tag)` pair is a no-op (deduped case-insensitively on apply); `untag`
/// deletes the matching record(s). The tag string is freeform ("key:value" is a
/// convention, unenforced). Every record is attributed (`agentId`) and timestamped.
///
/// **CloudKit constraints baked in (do not relax), same as `NoteEntity`:** every
/// stored property has a default value (the mirror can materialize a record before
/// every field arrives); no `.unique` / `#Unique` (CloudKit forbids them — identity
/// is enforced in code by upserting/deduping by `(noteId, tag)`); flat fields only.
@Model
public final class TagEntity {
    /// Stable identity of this tag record. Not a SwiftData unique constraint
    /// (CloudKit forbids those); dedup is maintained in code (see
    /// `AgentLayerStore.apply`).
    public var id: UUID = UUID()
    /// The subject note this tag is applied to. Mirrors a `NoteEntity.id`.
    public var noteId: UUID = UUID()
    /// Freeform tag text; the `"key:value"` convention is unenforced. Deduped
    /// case-insensitively per note on apply.
    public var tag: String = ""
    /// Which agent applied this tag (`provider-surface`, e.g. `claude-mac`).
    public var agentId: String = ""
    public var createdAt: Date = Date.distantPast

    public init(
        id: UUID = UUID(),
        noteId: UUID = UUID(),
        tag: String = "",
        agentId: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.noteId = noteId
        self.tag = tag
        self.agentId = agentId
        self.createdAt = createdAt
    }
}

/// The public value-type projection of ``TagEntity`` — the shape queries, the
/// exporter, and the UI pass around (`NoteEntity`↔``Note`` in miniature). `Codable`
/// so the export layer can serialize it to `tags.jsonl` directly.
public struct AgentTag: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var noteId: UUID
    public var tag: String
    public var agentId: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        noteId: UUID,
        tag: String,
        agentId: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.noteId = noteId
        self.tag = tag
        self.agentId = agentId
        self.createdAt = createdAt
    }
}

// MARK: - AgentTag ↔ TagEntity mapping

public extension AgentTag {
    /// Project a stored entity into the public value type.
    init(entity: TagEntity) {
        self.init(
            id: entity.id,
            noteId: entity.noteId,
            tag: entity.tag,
            agentId: entity.agentId,
            createdAt: entity.createdAt)
    }
}

public extension TagEntity {
    /// Build a fresh entity from an ``AgentTag`` value.
    convenience init(tag value: AgentTag) {
        self.init(
            id: value.id,
            noteId: value.noteId,
            tag: value.tag,
            agentId: value.agentId,
            createdAt: value.createdAt)
    }
}
