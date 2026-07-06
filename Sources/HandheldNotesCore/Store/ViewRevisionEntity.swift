import Foundation
import SwiftData

/// A single immutable **revision** of a named view — one snapshot of a living
/// document ("Open loops", "This week") an agent publishes back into the store
/// (see `docs/agent-contract.md`). Kept separate from the public
/// ``AgentViewRevision`` value type, mirroring the `NoteEntity`↔``Note`` split.
///
/// **Semantics (contract §2):** a "view" is the *set of revisions sharing an exact
/// `viewName`*; the latest `createdAt` wins display. Publishing to an existing name
/// *appends* a revision (revisions are never edited in place). Users can delete a
/// whole view (all its revisions). The `body` is markdown in the §6 dialect. Every
/// revision is attributed (`agentId`) and timestamped.
///
/// **CloudKit constraints baked in (do not relax), same as `NoteEntity`:** every
/// stored property has a default value; no `.unique` / `#Unique`; flat fields only.
@Model
public final class ViewRevisionEntity {
    public var id: UUID = UUID()
    /// View identity — grouped by *exact* match. Revisions sharing this string are
    /// one view.
    public var viewName: String = ""
    /// The revision body, markdown in the view-body dialect (contract §6).
    public var body: String = ""
    /// Which agent published this revision (`provider-surface`, e.g. `claude-mac`).
    public var agentId: String = ""
    public var createdAt: Date = Date.distantPast

    public init(
        id: UUID = UUID(),
        viewName: String = "",
        body: String = "",
        agentId: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.viewName = viewName
        self.body = body
        self.agentId = agentId
        self.createdAt = createdAt
    }
}

/// The public value-type projection of ``ViewRevisionEntity``. `Codable` so the
/// export layer serializes it to `views.jsonl` directly (every revision, full body —
/// snapshots, not diffs).
public struct AgentViewRevision: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var viewName: String
    public var body: String
    public var agentId: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        viewName: String,
        body: String,
        agentId: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.viewName = viewName
        self.body = body
        self.agentId = agentId
        self.createdAt = createdAt
    }
}

// MARK: - AgentViewRevision ↔ ViewRevisionEntity mapping

public extension AgentViewRevision {
    /// Project a stored entity into the public value type.
    init(entity: ViewRevisionEntity) {
        self.init(
            id: entity.id,
            viewName: entity.viewName,
            body: entity.body,
            agentId: entity.agentId,
            createdAt: entity.createdAt)
    }
}

public extension ViewRevisionEntity {
    /// Build a fresh entity from an ``AgentViewRevision`` value.
    convenience init(revision value: AgentViewRevision) {
        self.init(
            id: value.id,
            viewName: value.viewName,
            body: value.body,
            agentId: value.agentId,
            createdAt: value.createdAt)
    }
}
