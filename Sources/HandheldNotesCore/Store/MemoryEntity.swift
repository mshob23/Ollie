import Foundation
import SwiftData

/// A single **memory** entry — one fact in the agent layer's codebook (shorthand
/// decodings, preferences, dead ends) that agents write *back* into the store (see
/// `docs/agent-contract.md`). Kept separate from the public ``AgentMemory`` value
/// type, mirroring the `NoteEntity`↔``Note`` split.
///
/// **Semantics (contract §2):** memory is *append-only*. An agent never hard-edits
/// an entry; a correction is a new entry, and `retire` flips the tombstone
/// (`retired = true`, stamping `retiredAt`) rather than deleting. Users can
/// hard-delete from the UI. Every entry is attributed (`agentId`) and timestamped.
///
/// **CloudKit constraints baked in (do not relax), same as `NoteEntity`:** every
/// stored property has a default value; no `.unique` / `#Unique`; flat fields only.
/// `retiredAt` is optional (nil until retired) which mirrors cleanly.
@Model
public final class MemoryEntity {
    public var id: UUID = UUID()
    /// One fact per entry.
    public var text: String = ""
    /// Which agent authored this fact (`provider-surface`, e.g. `claude-mac`).
    public var agentId: String = ""
    public var createdAt: Date = Date.distantPast
    /// Tombstone: `true` once retired. Never hard-edited — a correction is a new
    /// entry; `retire` only flips this flag.
    public var retired: Bool = false
    /// When the entry was retired; nil while live.
    public var retiredAt: Date?

    public init(
        id: UUID = UUID(),
        text: String = "",
        agentId: String = "",
        createdAt: Date = Date(),
        retired: Bool = false,
        retiredAt: Date? = nil
    ) {
        self.id = id
        self.text = text
        self.agentId = agentId
        self.createdAt = createdAt
        self.retired = retired
        self.retiredAt = retiredAt
    }
}

/// The public value-type projection of ``MemoryEntity``. `Codable` so the export
/// layer serializes it to `memory.jsonl` directly (retired entries included, flagged).
public struct AgentMemory: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var text: String
    public var agentId: String
    public var createdAt: Date
    public var retired: Bool
    public var retiredAt: Date?

    public init(
        id: UUID = UUID(),
        text: String,
        agentId: String,
        createdAt: Date = Date(),
        retired: Bool = false,
        retiredAt: Date? = nil
    ) {
        self.id = id
        self.text = text
        self.agentId = agentId
        self.createdAt = createdAt
        self.retired = retired
        self.retiredAt = retiredAt
    }
}

// MARK: - AgentMemory ↔ MemoryEntity mapping

public extension AgentMemory {
    /// Project a stored entity into the public value type.
    init(entity: MemoryEntity) {
        self.init(
            id: entity.id,
            text: entity.text,
            agentId: entity.agentId,
            createdAt: entity.createdAt,
            retired: entity.retired,
            retiredAt: entity.retiredAt)
    }
}

public extension MemoryEntity {
    /// Build a fresh entity from an ``AgentMemory`` value.
    convenience init(memory value: AgentMemory) {
        self.init(
            id: value.id,
            text: value.text,
            agentId: value.agentId,
            createdAt: value.createdAt,
            retired: value.retired,
            retiredAt: value.retiredAt)
    }
}
