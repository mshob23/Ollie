import Foundation
import SwiftData
import XCTest
@testable import HandheldNotesCore

/// Exercises the M7 (Views v2) interaction-state layer on `AgentLayerStore` over an
/// in-memory container: upsert-by-`(viewName, blockId)` (a second `setInteraction`
/// rewrites the record, never duplicates), duplicate-key collapse on read (two
/// concurrent offline inserts of the same key → latest `updatedAt` wins and the loser
/// is pruned on the next write), the mechanical caps (`blockText` **truncated** not
/// rejected; `blockId`/`value`/`kind` clamped), and the view-delete cascade (deleting
/// a view deletes its interaction state).
///
/// Interaction state is user-authored / app-written — there is **no** `AgentOp` case
/// and no inbox op for it (spec §6), so these go through `setInteraction`/`userDelete`
/// directly, not `apply(_:)`.
@MainActor
final class InteractionStateStoreTests: XCTestCase {

    private func makeStore() -> (AgentLayerStore, ModelContext) {
        let container = NotesDataStore.makeContainerForTesting()
        let context = ModelContext(container)
        return (AgentLayerStore(context: context), context)
    }

    private func interaction(
        view: String = "Open loops",
        block: String = "cl1:9f2ab34c11de08a7:0",
        text: String = "Call the plumber",
        value: String,
        surface: String = "mac",
        revision: UUID = UUID(),
        at t: TimeInterval
    ) -> ViewInteraction {
        ViewInteraction(
            viewName: view,
            blockId: block,
            blockText: text,
            value: value,
            revisionId: revision,
            surface: surface,
            updatedAt: Date(timeIntervalSince1970: t))
    }

    // MARK: - Upsert-by-key (rewrite, never duplicate)

    func testSetInteractionUpsertsByKeyNotById() {
        let (store, context) = makeStore()

        store.setInteraction(interaction(value: "true", at: 100))
        // A second set for the SAME (viewName, blockId) — even with a different `id`
        // and surface — must rewrite the one record, not append a second.
        store.setInteraction(interaction(value: "false", surface: "ios", at: 200))

        let live = store.interactions(viewName: "Open loops")
        XCTAssertEqual(live.count, 1, "same (viewName, blockId) must not duplicate")
        XCTAssertEqual(live.first?.value, "false", "second set wins")
        XCTAssertEqual(live.first?.surface, "ios")
        XCTAssertEqual(live.first?.updatedAt, Date(timeIntervalSince1970: 200))

        // Confirm at the storage level: exactly one row exists.
        let rows = (try? context.fetch(FetchDescriptor<InteractionStateEntity>())) ?? []
        XCTAssertEqual(rows.count, 1, "upsert keeps a single row per key")
    }

    func testDistinctBlockIdsCoexist() {
        let (store, _) = makeStore()
        store.setInteraction(interaction(block: "cl1:aaaa:0", value: "true", at: 100))
        store.setInteraction(interaction(block: "cl1:bbbb:0", value: "true", at: 100))

        XCTAssertEqual(store.interactions(viewName: "Open loops").count, 2,
                       "different blockIds are different keys")
    }

    func testDistinctViewNamesCoexist() {
        let (store, _) = makeStore()
        store.setInteraction(interaction(view: "A", value: "true", at: 100))
        store.setInteraction(interaction(view: "B", value: "true", at: 100))

        XCTAssertEqual(store.interactions(viewName: "A").count, 1)
        XCTAssertEqual(store.interactions(viewName: "B").count, 1)
    }

    // MARK: - Duplicate-key collapse (latest updatedAt wins)

    func testDuplicateKeyCollapsePicksLatestUpdatedAt() {
        let (store, context) = makeStore()

        // Two records with the SAME (viewName, blockId) inserted directly — the shape
        // of two devices inserting the same key offline, then CloudKit importing both
        // (it merges same-record edits but not concurrent inserts). Insert the OLDER
        // one last to prove the read collapses by updatedAt, not by insertion order.
        context.insert(InteractionStateEntity(interaction:
            interaction(value: "true", surface: "ios", at: 300)))     // newer
        context.insert(InteractionStateEntity(interaction:
            interaction(value: "false", surface: "mac", at: 100)))    // older
        try? context.save()

        let live = store.interactions(viewName: "Open loops")
        XCTAssertEqual(live.count, 1, "duplicate keys collapse to one on read")
        XCTAssertEqual(live.first?.value, "true", "latest updatedAt wins")
        XCTAssertEqual(live.first?.surface, "ios")
    }

    func testUpsertOverDuplicateKeysPrunesLosers() {
        let (store, context) = makeStore()

        // Seed two duplicate-key rows directly (concurrent offline inserts).
        context.insert(InteractionStateEntity(interaction:
            interaction(value: "true", at: 300)))
        context.insert(InteractionStateEntity(interaction:
            interaction(value: "false", at: 100)))
        try? context.save()
        XCTAssertEqual((try? context.fetch(FetchDescriptor<InteractionStateEntity>()))?.count, 2)

        // A user toggle upserts by key → updates the winner in place AND prunes the
        // loser, so the key converges to a single row.
        store.setInteraction(interaction(value: "false", surface: "mac", at: 400))

        let rows = (try? context.fetch(FetchDescriptor<InteractionStateEntity>())) ?? []
        XCTAssertEqual(rows.count, 1, "upsert prunes duplicate-key losers")
        XCTAssertEqual(rows.first?.value, "false")
        XCTAssertEqual(rows.first?.updatedAt, Date(timeIntervalSince1970: 400))
    }

    // MARK: - Caps (blockText truncates; others clamp — never reject)

    func testBlockTextTruncatedNotRejected() {
        let (store, _) = makeStore()
        let longText = String(repeating: "x", count: AgentLayerStore.Caps.interactionBlockTextMax + 50)
        store.setInteraction(interaction(text: longText, value: "true", at: 100))

        let live = store.interactions(viewName: "Open loops")
        XCTAssertEqual(live.count, 1, "over-long blockText is truncated, not rejected")
        XCTAssertEqual(live.first?.blockText.count, AgentLayerStore.Caps.interactionBlockTextMax,
                       "blockText is clamped to its cap")
    }

    func testBlockIdValueKindClamped() {
        let (store, _) = makeStore()
        let longBlock = String(repeating: "b", count: AgentLayerStore.Caps.interactionBlockIdMax + 20)
        let longValue = String(repeating: "v", count: AgentLayerStore.Caps.interactionValueMax + 20)
        let longKind = String(repeating: "k", count: AgentLayerStore.Caps.interactionKindMax + 20)

        var i = interaction(block: longBlock, value: longValue, at: 100)
        i.kind = longKind
        store.setInteraction(i)

        // Read back by the clamped key. The kind here is a synthetic (non-checkbox)
        // clamp fixture, so widen `kinds` past the checkbox-only default (M16) to the
        // CLAMPED kind — otherwise the default filter would hide this fixture row.
        let clampedKind = String(longKind.prefix(AgentLayerStore.Caps.interactionKindMax))
        let clampedBlock = String(longBlock.prefix(AgentLayerStore.Caps.interactionBlockIdMax))
        let live = store.interactions(viewName: "Open loops", kinds: [clampedKind])
        XCTAssertEqual(live.count, 1)
        let stored = try? XCTUnwrap(live.first)
        XCTAssertEqual(stored?.blockId, clampedBlock)
        XCTAssertEqual(stored?.blockId.count, AgentLayerStore.Caps.interactionBlockIdMax)
        XCTAssertEqual(stored?.value.count, AgentLayerStore.Caps.interactionValueMax)
        XCTAssertEqual(stored?.kind.count, AgentLayerStore.Caps.interactionKindMax)
    }

    // MARK: - View-delete cascade

    func testUserDeleteViewCascadesToInteractions() throws {
        let (store, context) = makeStore()

        // A view with a revision plus interaction state on it, and a second, unrelated
        // view whose interaction state must survive.
        try store.apply(.viewPublish(viewName: "Open loops", body: "- [ ] item", agent: "claude-mac"))
        store.setInteraction(interaction(view: "Open loops", value: "true", at: 100))
        store.setInteraction(interaction(view: "This week", block: "cl1:cccc:0", value: "true", at: 100))

        XCTAssertEqual(store.interactions(viewName: "Open loops").count, 1)

        store.userDelete(view: "Open loops")

        XCTAssertTrue(store.interactions(viewName: "Open loops").isEmpty,
                      "deleting a view cascades to its interaction state")
        XCTAssertTrue(store.revisions(viewName: "Open loops").isEmpty)
        // The other view's state is untouched.
        XCTAssertEqual(store.interactions(viewName: "This week").count, 1,
                       "cascade is scoped to the deleted view only")

        // Storage-level: only the surviving view's row remains.
        let rows = (try? context.fetch(FetchDescriptor<InteractionStateEntity>())) ?? []
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.viewName, "This week")
    }

    func testUserDeleteViewWithOnlyInteractionsNoRevisions() {
        // Defensive: a view that somehow has interaction state but no revisions (e.g.
        // its revisions were already pruned) still gets its interaction state removed.
        let (store, _) = makeStore()
        store.setInteraction(interaction(view: "Orphaned", value: "true", at: 100))
        XCTAssertEqual(store.interactions(viewName: "Orphaned").count, 1)

        store.userDelete(view: "Orphaned")
        XCTAssertTrue(store.interactions(viewName: "Orphaned").isEmpty)
    }

    // MARK: - M16: per-view "seen" stamps

    /// Two `markViewSeen` calls for the same view produce ONE durable row (upsert by the
    /// sentinel `(viewName, "__view__")` key) whose `updatedAt` ADVANCES on the second —
    /// the idempotence + freshness the unread comparison depends on.
    func testMarkViewSeenUpsertsSingleRowAndAdvancesUpdatedAt() throws {
        let (store, context) = makeStore()
        let r1 = UUID(); let r2 = UUID()

        store.markViewSeen(viewName: "Open loops", revisionId: r1, surface: "mac")
        let firstStamp = try XCTUnwrap(store.seenStamps()["Open loops"])

        // A tiny sleep so the second `Date()` is strictly later (updatedAt is stamped now).
        Thread.sleep(forTimeInterval: 0.01)
        store.markViewSeen(viewName: "Open loops", revisionId: r2, surface: "ios")

        // Exactly ONE seen row for the view (upsert, not append).
        let seenRows = (try? context.fetch(FetchDescriptor<InteractionStateEntity>()))?
            .filter { $0.kind == AgentLayerStore.SeenStamp.kind } ?? []
        XCTAssertEqual(seenRows.count, 1, "two marks on one view keep a single seen row")
        XCTAssertEqual(seenRows.first?.blockId, AgentLayerStore.SeenStamp.blockId)
        XCTAssertEqual(seenRows.first?.value, r2.uuidString, "value is the latest seen revision id")
        XCTAssertEqual(seenRows.first?.surface, "ios")

        let secondStamp = try XCTUnwrap(store.seenStamps()["Open loops"])
        XCTAssertGreaterThan(secondStamp, firstStamp, "updatedAt advances on re-mark")
    }

    /// `seenStamps()` returns `viewName → updatedAt`, one entry per stamped view, and
    /// omits views never marked seen.
    func testSeenStampsReturnsPerViewTimestamps() {
        let (store, _) = makeStore()
        store.markViewSeen(viewName: "A", revisionId: UUID(), surface: "mac")
        store.markViewSeen(viewName: "B", revisionId: UUID(), surface: "watch")

        let stamps = store.seenStamps()
        XCTAssertEqual(Set(stamps.keys), ["A", "B"])
        XCTAssertNil(stamps["never-opened"], "an unstamped view has no entry")
    }

    /// **Overlay exclusion (the load-bearing invariant).** A seen stamp and a checkbox
    /// row for the SAME view: `interactions(viewName:)` (the checkbox-overlay feed)
    /// returns ONLY the checkbox — a seen row must never enter the overlay, and
    /// `seenStamps()` sees only the seen row.
    func testSeenRowExcludedFromCheckboxOverlay() {
        let (store, _) = makeStore()
        // A real checkbox toggle …
        store.setInteraction(interaction(block: "cl1:aaaa:0", value: "true", at: 100))
        // … and a seen stamp on the same view.
        store.markViewSeen(viewName: "Open loops", revisionId: UUID(), surface: "mac")

        let overlay = store.interactions(viewName: "Open loops")   // default kinds = checkbox
        XCTAssertEqual(overlay.count, 1, "only the checkbox row feeds the overlay")
        XCTAssertEqual(overlay.first?.blockId, "cl1:aaaa:0")
        XCTAssertEqual(overlay.first?.kind, "checkbox")
        XCTAssertFalse(overlay.contains { $0.kind == "seen" },
                       "a seen row must NEVER enter the checkbox overlay")

        // The seen stamp is still readable via its own query.
        XCTAssertNotNil(store.seenStamps()["Open loops"])

        // And the export feed (`allInteractions`, checkbox-only) excludes it too.
        let exportFeed = store.allInteractions()
        XCTAssertEqual(exportFeed.count, 1)
        XCTAssertTrue(exportFeed.allSatisfy { $0.kind == "checkbox" },
                      "seen rows never reach the export feed")
    }

    /// Widening `kinds` lets a caller read seen rows through the same query (proving the
    /// filter is explicit and parameterized, not hard-coded to hide them everywhere).
    func testInteractionsCanBeWidenedToSeenKind() {
        let (store, _) = makeStore()
        store.markViewSeen(viewName: "Open loops", revisionId: UUID(), surface: "mac")

        XCTAssertTrue(store.interactions(viewName: "Open loops").isEmpty,
                      "checkbox-only default hides the seen row")
        let seenOnly = store.interactions(viewName: "Open loops",
                                          kinds: [AgentLayerStore.SeenStamp.kind])
        XCTAssertEqual(seenOnly.count, 1)
        XCTAssertEqual(seenOnly.first?.blockId, AgentLayerStore.SeenStamp.blockId)
    }

    /// **Prune covers seen rows.** Deleting a whole view removes its seen stamp
    /// identically to its checkbox rows (same `viewName` join, no kind filter), and a
    /// second view's seen stamp survives.
    func testUserDeleteViewPrunesSeenStamp() throws {
        let (store, context) = makeStore()

        try store.apply(.viewPublish(viewName: "Doomed", body: "- [ ] item", agent: "claude-mac"))
        store.setInteraction(interaction(view: "Doomed", block: "cl1:aaaa:0", value: "true", at: 100))
        store.markViewSeen(viewName: "Doomed", revisionId: UUID(), surface: "mac")
        store.markViewSeen(viewName: "Keeper", revisionId: UUID(), surface: "mac")

        XCTAssertNotNil(store.seenStamps()["Doomed"])

        store.userDelete(view: "Doomed")

        XCTAssertNil(store.seenStamps()["Doomed"],
                     "deleting a view prunes its seen stamp (same viewName join as checkbox)")
        XCTAssertTrue(store.interactions(viewName: "Doomed").isEmpty,
                      "…and its checkbox rows")
        XCTAssertNotNil(store.seenStamps()["Keeper"], "an unrelated view's seen stamp survives")

        // Storage-level: no interaction row of EITHER kind survives for the deleted view.
        let rows = (try? context.fetch(FetchDescriptor<InteractionStateEntity>())) ?? []
        XCTAssertFalse(rows.contains { $0.viewName == "Doomed" },
                       "no residue of either kind for the deleted view")
    }

    // MARK: - Projection round-trip

    func testViewInteractionRoundTripsThroughEntityAndCodable() throws {
        let value = interaction(value: "true", at: 100)
        // Entity projection.
        let viaEntity = ViewInteraction(entity: InteractionStateEntity(interaction: value))
        XCTAssertEqual(viaEntity.viewName, value.viewName)
        XCTAssertEqual(viaEntity.blockId, value.blockId)
        XCTAssertEqual(viaEntity.value, "true")
        XCTAssertTrue(viaEntity.boolValue)
        // Codable round-trip (the shape the exporter serializes).
        let back = try JSONDecoder().decode(ViewInteraction.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(back, value)
    }
}
