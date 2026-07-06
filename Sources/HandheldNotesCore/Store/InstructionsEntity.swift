import Foundation
import SwiftData

/// The user's standing **instructions** to agents — a *single* record the user
/// authors in-app ("Agents read this before working with your notes"), synced like
/// everything else (see `docs/agent-contract.md`). Kept separate from the public
/// ``AgentInstructions`` value type, mirroring the `NoteEntity`↔``Note`` split.
///
/// **Semantics (contract §2):** there is exactly one instructions record, keyed by a
/// fixed well-known UUID (``wellKnownID``) and *upserted* — setting the text updates
/// that one record in place rather than appending. (This record is user-authored, so
/// unlike the append-only agent records it is edited in place.)
///
/// **CloudKit constraints baked in (do not relax), same as `NoteEntity`:** every
/// stored property has a default value; no `.unique` / `#Unique` — singleton-ness is
/// enforced in code via ``wellKnownID`` upsert (see `AgentLayerStore.setInstructions`).
@Model
public final class InstructionsEntity {
    public var id: UUID = UUID()
    /// The user's standing instructions to agents (plain markdown).
    public var text: String = ""
    public var updatedAt: Date = Date.distantPast

    public init(
        id: UUID = InstructionsEntity.wellKnownID,
        text: String = "",
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.text = text
        self.updatedAt = updatedAt
    }

    /// The fixed, well-known identity of the single instructions record. Because
    /// CloudKit forbids unique constraints, singleton-ness is enforced by always
    /// upserting the record with *this* id (see `AgentLayerStore.setInstructions`).
    /// A stable literal UUID (never randomly minted) so every device converges on
    /// the same row.
    public static let wellKnownID = UUID(uuidString: "0E5B7A1C-4D2F-4B6E-9C3A-000000000001")!
}

/// The public value-type projection of ``InstructionsEntity``.
public struct AgentInstructions: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var text: String
    public var updatedAt: Date

    public init(
        id: UUID = InstructionsEntity.wellKnownID,
        text: String,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.text = text
        self.updatedAt = updatedAt
    }
}

// MARK: - AgentInstructions ↔ InstructionsEntity mapping

public extension AgentInstructions {
    /// Project a stored entity into the public value type.
    init(entity: InstructionsEntity) {
        self.init(
            id: entity.id,
            text: entity.text,
            updatedAt: entity.updatedAt)
    }
}

public extension InstructionsEntity {
    /// Build a fresh entity from an ``AgentInstructions`` value.
    convenience init(instructions value: AgentInstructions) {
        self.init(
            id: value.id,
            text: value.text,
            updatedAt: value.updatedAt)
    }
}
