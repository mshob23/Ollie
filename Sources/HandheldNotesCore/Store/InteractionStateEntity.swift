import Foundation
import SwiftData

/// The durable, synced **interaction state** for a single interactive block inside a
/// view — today only a checklist checkbox. When the user taps a `- [ ]` box in a
/// rendered view, the app upserts one of these records; the Mac agent reads them on
/// its next run and acknowledges by republishing the view. Kept separate from the
/// public ``ViewInteraction`` value type, mirroring the `NoteEntity`↔``Note`` split.
///
/// **Semantics (Views v2 interaction spec §1–§2):**
/// - The **logical key is `(viewName, blockId)`** — the record is *upserted by that
///   pair in code* (CloudKit forbids unique constraints, so identity is enforced by
///   fetch-then-update-or-insert in `AgentLayerStore.setInteraction`), NOT by `id`.
///   `revisionId` is *provenance only* (which body the user was looking at); keying on
///   it would wipe every checkmark at each republish.
/// - Rendered checked-state is resolved through three layers, top wins: the in-memory
///   optimistic *pending* value, then this durable *overlay* **iff
///   `updatedAt > displayedRevision.createdAt`**, then the `- [ ]`/`- [x]` body
///   default. The *iff* is load-bearing: **a newer revision supersedes older
///   interaction state — publishing is the acknowledgment.**
/// - `blockText` is a *snapshot* stored at toggle time (provenance + agent ergonomics
///   so agents never recompute the id hash), not derived at export — the item may be
///   gone from the latest revision by then.
/// - `kind`/`value` are **strings** on purpose: future kinds (`metric`, slider,
///   `select`) reuse this entity with **no further schema change** — that is the whole
///   point of not typing `value` as a `Bool`.
///
/// User interaction **never** creates or mutates a ``ViewRevisionEntity``; this layer
/// is user-authored, app-written only — there is no `AgentOp` case and no inbox op for
/// it (spec §6, contract §0).
///
/// **CloudKit constraints baked in (do not relax), same as `NoteEntity`:** every
/// stored property has a default value; no `.unique` / `#Unique`; flat fields only.
@Model
public final class InteractionStateEntity {
    public var id: UUID = UUID()
    /// Join key — the view identity, exact match, like ``ViewRevisionEntity/viewName``.
    public var viewName: String = ""
    /// Join key — the content-derived block id (`cl1:<hash16>:<occ>`, spec §3).
    public var blockId: String = ""
    /// Snapshot of the item text as the classifier captured it at toggle time
    /// (provenance + agent ergonomics; truncated to ``AgentLayerStore/Caps/interactionBlockTextMax``).
    public var blockText: String = ""
    /// Raw-string enum of the kind of interaction this row records. `"checkbox"` — a
    /// checklist toggle — is the agent-facing default. `"seen"` (M16, contract §7) is a
    /// per-view **read stamp**: an app-internal row under the sentinel
    /// `blockId "__view__"` whose `value` is the seen revision's UUID, driving the
    /// unread-dot state. A `"seen"` row is never exported to `interactions.jsonl`, never
    /// returned by `get_view.interactions`, and never enters the checkbox overlay —
    /// every one of those boundaries filters on this `kind` (see
    /// `AgentLayerStore.SeenStamp` / `.allInteractions(kinds:)`). Future kinds reuse this
    /// entity with no further schema change (spec §2, decision #5).
    public var kind: String = "checkbox"
    /// Kind-specific value; for a checkbox: `"true"` / `"false"`.
    public var value: String = ""
    /// Provenance: the id of the revision that was displayed at toggle time. NOT part
    /// of the logical key — see the type doc.
    public var revisionId: UUID = UUID()
    /// Provenance: which surface wrote it — `"mac"` | `"ios"`.
    public var surface: String = ""
    public var updatedAt: Date = Date.distantPast

    public init(
        id: UUID = UUID(),
        viewName: String = "",
        blockId: String = "",
        blockText: String = "",
        kind: String = "checkbox",
        value: String = "",
        revisionId: UUID = UUID(),
        surface: String = "",
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.viewName = viewName
        self.blockId = blockId
        self.blockText = blockText
        self.kind = kind
        self.value = value
        self.revisionId = revisionId
        self.surface = surface
        self.updatedAt = updatedAt
    }
}

/// The public value-type projection of ``InteractionStateEntity`` — the shape the
/// interaction model, the exporter, and the panes pass around (`NoteEntity`↔``Note``
/// in miniature). `Codable` so the export layer serializes it to `interactions.jsonl`
/// directly.
public struct ViewInteraction: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var viewName: String
    public var blockId: String
    public var blockText: String
    public var kind: String
    public var value: String
    public var revisionId: UUID
    public var surface: String
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        viewName: String,
        blockId: String,
        blockText: String,
        kind: String = "checkbox",
        value: String,
        revisionId: UUID = UUID(),
        surface: String,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.viewName = viewName
        self.blockId = blockId
        self.blockText = blockText
        self.kind = kind
        self.value = value
        self.revisionId = revisionId
        self.surface = surface
        self.updatedAt = updatedAt
    }

    /// Convenience for the only kind today: the checkbox's boolean value, parsed from
    /// the raw `value` string (`"true"` → true, anything else → false).
    public var boolValue: Bool { value == "true" }
}

// MARK: - ViewInteraction ↔ InteractionStateEntity mapping

public extension ViewInteraction {
    /// Project a stored entity into the public value type.
    init(entity: InteractionStateEntity) {
        self.init(
            id: entity.id,
            viewName: entity.viewName,
            blockId: entity.blockId,
            blockText: entity.blockText,
            kind: entity.kind,
            value: entity.value,
            revisionId: entity.revisionId,
            surface: entity.surface,
            updatedAt: entity.updatedAt)
    }
}

public extension InteractionStateEntity {
    /// Build a fresh entity from a ``ViewInteraction`` value.
    convenience init(interaction value: ViewInteraction) {
        self.init(
            id: value.id,
            viewName: value.viewName,
            blockId: value.blockId,
            blockText: value.blockText,
            kind: value.kind,
            value: value.value,
            revisionId: value.revisionId,
            surface: value.surface,
            updatedAt: value.updatedAt)
    }
}
