import Foundation
import SwiftData
import XCTest
@testable import HandheldNotesCore

/// Exercises the M7 (Views v2) write-path brain, `ViewInteractionModel` (spec §4), over
/// an in-memory store. The two headline properties the spec's precedence + debounce
/// rules promise:
///
/// - **Coalesced, diffed, atomic settle** — N taps that come to rest at a changed state
///   write **one** record per changed block with **one** `ModelContext` save; a full
///   round-trip (on→off→…→original) writes **nothing**; entering/leaving without
///   toggling writes **nothing**.
/// - **Three-layer precedence** (spec §1) — pending → overlay(-iff-newer-than-revision)
///   → body default, including the load-bearing *iff*: a **newer revision supersedes**
///   older interaction state, and the **recurring-reset** case (agent republishes
///   `- [ ]`, an old checked overlay must NOT bleed back through).
///
/// The debounce interval is **injected** (`settleInterval: 0`) so a settle can be
/// awaited deterministically (`awaitSettleForTesting()`) instead of sleeping 600 ms —
/// per the plan's "inject the debounce interval rather than sleeping" instruction.
@MainActor
final class ViewInteractionModelTests: XCTestCase {

    // MARK: - Fixtures

    private func makeStore() -> (AgentLayerStore, ModelContext) {
        let container = NotesDataStore.makeContainerForTesting()
        let context = ModelContext(container)
        return (AgentLayerStore(context: context), context)
    }

    /// A revision at a fixed `createdAt` — the supersession boundary the overlay's
    /// `updatedAt` is compared against (spec §1 layer 2).
    private func revision(
        view: String = "Open loops",
        body: String = "- [ ] task",
        at t: TimeInterval = 1_000
    ) -> AgentViewRevision {
        AgentViewRevision(viewName: view, body: body, agentId: "claude-mac",
                          createdAt: Date(timeIntervalSince1970: t))
    }

    private func makeModel(
        store: AgentLayerStore,
        revision: AgentViewRevision,
        surface: String = "ios"
    ) -> ViewInteractionModel {
        ViewInteractionModel(store: store, viewName: revision.viewName,
                             revision: revision, surface: surface, settleInterval: 0)
    }

    /// The blockId for a checklist item as the shared parser derives it (spec §3), so
    /// the test keys match what the renderer would feed `toggle`/`resolved`.
    private func blockId(_ text: String, occ: Int = 0) -> String {
        "cl1:\(MarkdownLite.hash16(ofChecklistText: text)):\(occ)"
    }

    private func liveInteractions(_ store: AgentLayerStore, view: String = "Open loops") -> [ViewInteraction] {
        store.interactions(viewName: view)
    }

    // MARK: - N toggles → one save

    /// Four taps across two boxes that come to rest changed → exactly **one** save, and
    /// exactly the changed boxes are persisted (one record each). `commitNow()` stands
    /// in for the settle boundary (identical commit path as the timer).
    func testMultipleTogglesSettleToOneSave() {
        let (store, context) = makeStore()
        let rev = revision(body: "- [ ] a\n- [ ] b")
        let model = makeModel(store: store, revision: rev)
        let a = blockId("a"), b = blockId("b")

        // Prime body defaults the way the renderer does (both start unchecked).
        _ = model.resolved(blockId: a, bodyChecked: false)
        _ = model.resolved(blockId: b, bodyChecked: false)

        // Rapid burst: a on, a off, a on (net: on), b on.
        model.toggle(blockId: a, blockText: "a")
        model.toggle(blockId: a, blockText: "a")
        model.toggle(blockId: a, blockText: "a")
        model.toggle(blockId: b, blockText: "b")

        model.commitNow()

        XCTAssertEqual(model.saveCount, 1, "a burst of taps settles to a single save")
        let live = liveInteractions(store)
        XCTAssertEqual(live.count, 2, "one record per changed block")
        XCTAssertEqual(live.first(where: { $0.blockId == a })?.value, "true")
        XCTAssertEqual(live.first(where: { $0.blockId == b })?.value, "true")

        // Storage-level: exactly two rows written.
        let rows = (try? context.fetch(FetchDescriptor<InteractionStateEntity>())) ?? []
        XCTAssertEqual(rows.count, 2)
    }

    /// The same coalescing, but driven by the injected (zero) settle **timer** rather
    /// than a manual `commitNow()` — proving the debounce path itself collapses a burst
    /// to one save (awaited deterministically, no 600 ms sleep).
    func testTimerSettleCoalescesToOneSave() async {
        let (store, _) = makeStore()
        let rev = revision(body: "- [ ] a")
        let model = makeModel(store: store, revision: rev)
        let a = blockId("a")
        _ = model.resolved(blockId: a, bodyChecked: false)

        model.toggle(blockId: a, blockText: "a")   // each restarts the single settle task;
        model.toggle(blockId: a, blockText: "a")   // only the last survives
        model.toggle(blockId: a, blockText: "a")   // net: on
        await model.awaitSettleForTesting()

        XCTAssertEqual(model.saveCount, 1, "the settle timer commits once for the burst")
        XCTAssertEqual(liveInteractions(store).first?.value, "true")
    }

    // MARK: - Round-trip → zero saves

    /// on→off back to the body default (unchecked) at rest → **nothing** is written; the
    /// diff drops the entry because `new == committed`.
    func testRoundTripToBodyDefaultWritesNothing() {
        let (store, context) = makeStore()
        let rev = revision(body: "- [ ] task")
        let model = makeModel(store: store, revision: rev)
        let id = blockId("task")
        _ = model.resolved(blockId: id, bodyChecked: false)

        model.toggle(blockId: id, blockText: "task")   // → true (optimistic)
        model.toggle(blockId: id, blockText: "task")   // → false, back to the body default
        model.commitNow()

        XCTAssertEqual(model.saveCount, 0, "a full round-trip writes nothing")
        XCTAssertTrue(liveInteractions(store).isEmpty)
        let rows = (try? context.fetch(FetchDescriptor<InteractionStateEntity>())) ?? []
        XCTAssertTrue(rows.isEmpty, "no row is inserted for a round-trip")
    }

    /// Round-trip back to an **existing overlay** value (not the body default): starting
    /// from a persisted `true`, on→off→on nets to `true` again → no new write.
    func testRoundTripToExistingOverlayWritesNothing() {
        let (store, _) = makeStore()
        let rev = revision(body: "- [ ] task", at: 1_000)
        let id = blockId("task")
        // Seed a newer overlay (checked) so the committed value is `true`, not the body.
        store.setInteraction(ViewInteraction(
            viewName: "Open loops", blockId: id, blockText: "task",
            value: "true", surface: "ios",
            updatedAt: Date(timeIntervalSince1970: 2_000)))

        let model = makeModel(store: store, revision: rev)
        _ = model.resolved(blockId: id, bodyChecked: false)   // overlay(newer) wins → true
        XCTAssertTrue(model.resolved(blockId: id, bodyChecked: false))

        model.toggle(blockId: id, blockText: "task")   // → false
        model.toggle(blockId: id, blockText: "task")   // → true, equals committed overlay
        model.commitNow()

        XCTAssertEqual(model.saveCount, 0, "round-trip back to the committed overlay writes nothing")
    }

    // MARK: - Enter / leave without toggling → zero saves

    func testBoundaryWithNoToggleWritesNothing() {
        let (store, context) = makeStore()
        let rev = revision(body: "- [ ] task")
        let model = makeModel(store: store, revision: rev)
        _ = model.resolved(blockId: blockId("task"), bodyChecked: false)   // just rendered

        model.commitNow()   // leave the pane without ever toggling

        XCTAssertEqual(model.saveCount, 0, "entering and leaving without a toggle writes nothing")
        let rows = (try? context.fetch(FetchDescriptor<InteractionStateEntity>())) ?? []
        XCTAssertTrue(rows.isEmpty)
    }

    // MARK: - Precedence layer 1: pending is optimistic and instant

    func testPendingOverridesEverythingBeforeCommit() {
        let (store, _) = makeStore()
        let rev = revision(body: "- [ ] task")
        let model = makeModel(store: store, revision: rev)
        let id = blockId("task")

        XCTAssertFalse(model.resolved(blockId: id, bodyChecked: false), "starts at body default")
        model.toggle(blockId: id, blockText: "task")
        XCTAssertTrue(model.resolved(blockId: id, bodyChecked: false),
                      "pending value shows instantly, before any write")
        XCTAssertEqual(model.saveCount, 0, "the optimistic flip persists nothing yet")
    }

    // MARK: - Precedence layer 2: overlay applies IFF newer than the revision

    func testOverlayNewerThanRevisionApplies() {
        let (store, _) = makeStore()
        let rev = revision(body: "- [ ] task", at: 1_000)
        let id = blockId("task")
        store.setInteraction(ViewInteraction(
            viewName: "Open loops", blockId: id, blockText: "task",
            value: "true", surface: "mac",
            updatedAt: Date(timeIntervalSince1970: 2_000)))   // newer than the revision

        let model = makeModel(store: store, revision: rev)
        XCTAssertTrue(model.resolved(blockId: id, bodyChecked: false),
                      "an overlay newer than the displayed revision wins over the body default")
    }

    /// **Newer-revision supersession** (spec §1, the load-bearing *iff*): an overlay
    /// **older** than the displayed revision does NOT apply — the body default shows.
    func testOverlayOlderThanRevisionIsSuperseded() {
        let (store, _) = makeStore()
        let rev = revision(body: "- [ ] task", at: 2_000)   // newer than the overlay below
        let id = blockId("task")
        store.setInteraction(ViewInteraction(
            viewName: "Open loops", blockId: id, blockText: "task",
            value: "true", surface: "mac",
            updatedAt: Date(timeIntervalSince1970: 1_000)))   // OLDER than the revision

        let model = makeModel(store: store, revision: rev)
        XCTAssertFalse(model.resolved(blockId: id, bodyChecked: false),
                       "a newer revision supersedes older interaction state — body default wins")
    }

    /// The **recurring-reset** case (spec §1 consequence): the agent republishes a
    /// recurring item as `- [ ]` in a **newer** revision. The user's old checked overlay
    /// (from the previous revision) must NOT bleed back through — the box shows
    /// unchecked, and committing that same unchecked value writes nothing new.
    func testRecurringResetDoesNotBleedThroughOldCheck() {
        let (store, _) = makeStore()
        let id = blockId("Water the plants")

        // The user checked it against the OLD revision (overlay at t=1500).
        store.setInteraction(ViewInteraction(
            viewName: "Open loops", blockId: id, blockText: "Water the plants",
            value: "true", surface: "ios",
            updatedAt: Date(timeIntervalSince1970: 1_500)))

        // The agent then republishes the item as `- [ ]` — a NEWER revision (t=2000).
        let republished = revision(body: "- [ ] Water the plants", at: 2_000)
        let model = makeModel(store: store, revision: republished)

        XCTAssertFalse(model.resolved(blockId: id, bodyChecked: false),
                       "republishing `- [ ]` (newer revision) resets the box — the old check must not bleed through")

        // And re-checking-then-unchecking against the reset default writes nothing.
        model.toggle(blockId: id, blockText: "Water the plants")   // → true
        model.toggle(blockId: id, blockText: "Water the plants")   // → false == reset default
        model.commitNow()
        XCTAssertEqual(model.saveCount, 0)
    }

    // MARK: - Precedence layer 3: body default when no overlay

    func testBodyDefaultUsedWhenNoOverlay() {
        let (store, _) = makeStore()
        let rev = revision(body: "- [x] done\n- [ ] todo")
        let model = makeModel(store: store, revision: rev)

        XCTAssertTrue(model.resolved(blockId: blockId("done"), bodyChecked: true),
                      "a baked `- [x]` shows checked with no overlay")
        XCTAssertFalse(model.resolved(blockId: blockId("todo"), bodyChecked: false),
                       "a baked `- [ ]` shows unchecked with no overlay")
    }

    // MARK: - Provenance stamped on the settled record

    func testCommittedRecordCarriesRevisionAndSurfaceProvenance() {
        let (store, _) = makeStore()
        let rev = revision(body: "- [ ] task", at: 1_000)
        let model = makeModel(store: store, revision: rev, surface: "mac")
        let id = blockId("task")
        _ = model.resolved(blockId: id, bodyChecked: false)

        model.toggle(blockId: id, blockText: "task")
        model.commitNow()

        let written = liveInteractions(store).first(where: { $0.blockId == id })
        XCTAssertEqual(written?.revisionId, rev.id, "the settled record stamps the displayed revision")
        XCTAssertEqual(written?.surface, "mac", "and the surface")
        XCTAssertEqual(written?.blockText, "task", "and denormalizes the item text snapshot")
        XCTAssertEqual(written?.value, "true")
    }

    // MARK: - onCommit fires only on a real write

    func testOnCommitFiresOnlyWhenSomethingWrote() {
        let (store, _) = makeStore()
        let rev = revision(body: "- [ ] task")
        let id = blockId("task")

        var commits = 0
        let model = ViewInteractionModel(
            store: store, viewName: "Open loops", revision: rev,
            surface: "ios", settleInterval: 0, onCommit: { commits += 1 })
        _ = model.resolved(blockId: id, bodyChecked: false)

        // A no-op settle (nothing pending) does not fire onCommit.
        model.commitNow()
        XCTAssertEqual(commits, 0)

        // A round-trip settle (pending, but nets to committed) also does not fire it.
        model.toggle(blockId: id, blockText: "task")
        model.toggle(blockId: id, blockText: "task")
        model.commitNow()
        XCTAssertEqual(commits, 0, "a round-trip writes nothing → no reproject")

        // A real change fires it exactly once.
        model.toggle(blockId: id, blockText: "task")
        model.commitNow()
        XCTAssertEqual(commits, 1, "a settle that wrote re-projects once")
    }

    // MARK: - Second settle after a first persisted change (boundary cycling)

    /// enter → toggle → leave, twice: each exit commit is a genuine settled change and
    /// writes once (spec §4 "boundary cycling"), and the second write updates the same
    /// record in place (upsert by key) rather than duplicating it.
    func testBoundaryCyclingWritesOncePerSettledChange() {
        let (store, context) = makeStore()
        let rev = revision(body: "- [ ] task", at: 1_000)
        let id = blockId("task")

        // Cycle 1: check it, leave.
        let m1 = makeModel(store: store, revision: rev)
        _ = m1.resolved(blockId: id, bodyChecked: false)
        m1.toggle(blockId: id, blockText: "task")
        m1.commitNow()
        XCTAssertEqual(m1.saveCount, 1)

        // Cycle 2: a fresh model (as a re-entered pane builds), uncheck it, leave. The
        // committed value is now the overlay `true`, so unchecking is a real change.
        let m2 = makeModel(store: store, revision: rev)
        XCTAssertTrue(m2.resolved(blockId: id, bodyChecked: false), "overlay from cycle 1 applies")
        m2.toggle(blockId: id, blockText: "task")   // → false
        m2.commitNow()
        XCTAssertEqual(m2.saveCount, 1)

        // One record, converged to the latest value — not two.
        let rows = (try? context.fetch(FetchDescriptor<InteractionStateEntity>())) ?? []
        XCTAssertEqual(rows.count, 1, "boundary cycling rewrites one record in place")
        XCTAssertEqual(rows.first?.value, "false")
    }

    // MARK: - Overlay caching (perf regression: the 0x8BADF00D watchdog crash)

    /// `resolved` must NOT hit the store on every call. The renderer calls it for every
    /// checklist glyph on every layout pass; when it fetched SwiftData per call, opening
    /// a checklist-heavy view during a fresh-install CloudKit import blocked the main
    /// thread past iOS's scene-update watchdog and the app was SIGKILLed (0x8BADF00D).
    ///
    /// We can't count fetches (no seam), so we characterize the cache behaviorally: a
    /// record written **behind the model's back** after the cache has loaded is NOT seen
    /// by further `resolved` calls (proving no re-fetch), but IS seen by a freshly built
    /// model (proving the cache is per-model-lifetime and navigation refreshes it).
    func testResolvedCachesOverlayAndDoesNotRefetchPerCall() {
        let (store, context) = makeStore()
        let rev = revision(body: "- [ ] task", at: 1_000)
        let id = blockId("task")

        let model = makeModel(store: store, revision: rev)
        // First read loads the (empty) cache → body default.
        XCTAssertFalse(model.resolved(blockId: id, bodyChecked: false))

        // Write an applicable overlay (updatedAt newer than the revision) directly via a
        // second store on the same context — bypassing the model entirely.
        store.setInteractions([ViewInteraction(
            viewName: "Open loops", blockId: id, blockText: "task",
            value: "true", revisionId: rev.id, surface: "mac",
            updatedAt: Date(timeIntervalSince1970: 2_000))])

        // Same model, many calls: still the cached (empty) result → NOT re-fetching.
        for _ in 0..<50 {
            XCTAssertFalse(model.resolved(blockId: id, bodyChecked: false),
                           "resolved must read the cache, not re-fetch the store per call")
        }

        // A freshly built model (as a re-entered/rebuilt pane makes) DOES see it.
        let rebuilt = makeModel(store: store, revision: rev)
        XCTAssertTrue(rebuilt.resolved(blockId: id, bodyChecked: false),
                      "a rebuilt model reloads the overlay cache")
        _ = context
    }

    /// A commit that writes invalidates the cache, so the model reflects its own just-
    /// written state on the next read (read-your-writes across a settle within one model).
    func testCommitInvalidatesOverlayCacheForReadYourWrites() {
        let (store, _) = makeStore()
        let rev = revision(body: "- [ ] task", at: 1_000)
        let id = blockId("task")

        let model = makeModel(store: store, revision: rev)
        XCTAssertFalse(model.resolved(blockId: id, bodyChecked: false)) // loads cache
        model.toggle(blockId: id, blockText: "task")                    // → pending true
        model.commitNow()                                               // writes + invalidates
        XCTAssertEqual(model.saveCount, 1)
        // Pending is cleared; the value must now come from the refreshed overlay, not a
        // stale empty cache (which would fall back to the body default `false`).
        XCTAssertTrue(model.resolved(blockId: id, bodyChecked: false),
                      "post-commit read reflects the just-written overlay")
    }
}
