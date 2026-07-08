import Foundation
import SwiftData
import XCTest
@testable import HandheldNotesCore

/// Exercises the **user-facing agent-layer plumbing on `AppModel`** that the M5 UI
/// surfaces (5b–5d) depend on: the restriction toggle, the standing-instructions
/// round-trip, and the published tag/memory snapshots + user-delete paths. These sit
/// between the SwiftUI views and `AgentLayerStore` (the write choke point), so they're
/// worth proving directly rather than trusting the wiring.
///
/// Pattern mirrors `AppModelRefreshTests`: an in-memory model, with layer records
/// written through a second `ModelContext` on the SAME container (the shape a CloudKit
/// import / inbox apply takes) and surfaced via `refresh()`.
@MainActor
final class AppModelAgentLayerTests: XCTestCase {

    /// An external `AgentLayerStore` over the model's container — stands in for the
    /// inbox ingestor / a synced-in record.
    private func externalStore(_ model: AppModel) -> AgentLayerStore {
        AgentLayerStore(context: ModelContext(model.modelContainerForTesting))
    }

    // MARK: - 5b: restriction toggle

    func testSetRestrictedFlipsTheNote() throws {
        let model = AppModel(inMemoryStore: true)
        let note = model.composeNote(transcript: "Sensitive thing.")
        XCTAssertFalse(model.notes.first { $0.id == note.id }?.isRestricted ?? true)

        model.setRestricted(true, for: note.id)
        XCTAssertTrue(model.notes.first { $0.id == note.id }?.isRestricted ?? false,
                      "setRestricted(true) must mark the note restricted")

        model.setRestricted(false, for: note.id)
        XCTAssertFalse(model.notes.first { $0.id == note.id }?.isRestricted ?? true,
                       "setRestricted(false) must un-restrict the note")
    }

    // MARK: - 5c: standing instructions round-trip

    func testInstructionsRoundTripThroughAppModel() throws {
        let model = AppModel(inMemoryStore: true)
        XCTAssertEqual(model.agentInstructions(), "", "no instructions yet → empty")

        model.setAgentInstructions("Prefer terse summaries.")
        XCTAssertEqual(model.agentInstructions(), "Prefer terse summaries.")

        // Upsert, not append — a second save replaces the text.
        model.setAgentInstructions("Actually, be thorough.")
        XCTAssertEqual(model.agentInstructions(), "Actually, be thorough.")
    }

    // MARK: - 5d: published tag snapshot + filter + user delete

    func testTagsSnapshotSurfacesAndFiltersByNote() throws {
        let model = AppModel(inMemoryStore: true)
        let a = model.composeNote(transcript: "Note A.")
        let b = model.composeNote(transcript: "Note B.")

        // Two agents/notes worth of tags, written externally then surfaced.
        try externalStore(model).apply(.tag(noteId: a.id, tag: "project:ollie", agent: "claude-mac"))
        try externalStore(model).apply(.tag(noteId: b.id, tag: "misc", agent: "claude-mac"))
        model.refresh()

        XCTAssertEqual(model.agentTags.count, 2, "both tags land in the published snapshot")
        XCTAssertEqual(model.tags(forNote: a.id).map(\.tag), ["project:ollie"],
                       "tags(forNote:) filters to the subject note")
        XCTAssertEqual(model.tags(forNote: b.id).map(\.tag), ["misc"])
    }

    func testUserDeleteTagRemovesItFromSnapshot() throws {
        let model = AppModel(inMemoryStore: true)
        let note = model.composeNote(transcript: "Taggable.")
        try externalStore(model).apply(.tag(noteId: note.id, tag: "remove-me", agent: "claude-mac"))
        model.refresh()
        let tag = try XCTUnwrap(model.tags(forNote: note.id).first)

        model.userDelete(tag: tag)
        XCTAssertTrue(model.tags(forNote: note.id).isEmpty,
                      "user-deleting a tag drops it from the note's chip row")
        XCTAssertFalse(model.agentTags.contains { $0.id == tag.id },
                       "and from the published snapshot")
    }

    // MARK: - 5d: published memory snapshot + retired flagging + user delete

    func testMemorySnapshotIncludesRetiredFlagged() throws {
        let model = AppModel(inMemoryStore: true)
        let store = externalStore(model)
        try store.apply(.memoryAppend(text: "‘HP’ means heat pump.", agent: "claude-mac"))
        model.refresh()
        let entry = try XCTUnwrap(model.agentMemory.first)
        XCTAssertFalse(entry.retired)

        // Retiring (an agent op) keeps the entry visible but flagged — the trust
        // screen dims it rather than hiding it.
        try store.apply(.memoryRetire(id: entry.id, agent: "claude-mac"))
        model.refresh()
        let retired = try XCTUnwrap(model.agentMemory.first { $0.id == entry.id })
        XCTAssertTrue(retired.retired, "retired entries stay in the snapshot, flagged")
    }

    func testUserDeleteMemoryRemovesItFromSnapshot() throws {
        let model = AppModel(inMemoryStore: true)
        try externalStore(model).apply(.memoryAppend(text: "durable fact", agent: "claude-mac"))
        model.refresh()
        let entry = try XCTUnwrap(model.agentMemory.first)

        model.userDelete(memory: entry)
        XCTAssertTrue(model.agentMemory.isEmpty,
                      "user-deleting a memory hard-removes it from the snapshot")
    }

    // MARK: - 5e/5f: published views snapshot (feed rows + latest-wins + revisions)

    /// Publishing several revisions across two views surfaces one feed row per view
    /// (latest revision), and the detail's `revisions(forView:)` returns every revision
    /// newest-first — the two shapes the Views surfaces read.
    func testViewsSnapshotLatestPerViewAndRevisionHistory() throws {
        let model = AppModel(inMemoryStore: true)
        let store = externalStore(model)
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        // "Open loops": two revisions (v1 then v2 later). "This week": one.
        try store.apply(.viewPublish(viewName: "Open loops", body: "loops v1",
                                     agent: "claude-mac", ts: t0))
        try store.apply(.viewPublish(viewName: "This week", body: "week v1",
                                     agent: "claude-runner", ts: t0.addingTimeInterval(10)))
        try store.apply(.viewPublish(viewName: "Open loops", body: "loops v2",
                                     agent: "claude-runner", ts: t0.addingTimeInterval(20)))
        model.refresh()

        // One row per view, newest view first: "Open loops" (latest at +20) before
        // "This week" (latest at +10).
        XCTAssertEqual(model.agentViews.latest.map(\.viewName), ["Open loops", "This week"])
        let openRow = try XCTUnwrap(model.agentViews.latest.first { $0.viewName == "Open loops" })
        XCTAssertEqual(openRow.body, "loops v2", "the feed row shows the latest revision")

        // Full revision history, newest first.
        let revs = model.revisions(forView: "Open loops")
        XCTAssertEqual(revs.map(\.body), ["loops v2", "loops v1"])
        XCTAssertEqual(model.revisions(forView: "This week").map(\.body), ["week v1"])
        XCTAssertTrue(model.revisions(forView: "does-not-exist").isEmpty)
    }

    /// Pinning is a per-device preference: it round-trips through `settings`, toggles,
    /// and does NOT create a store record.
    func testPinToggleIsPerDevicePreference() throws {
        let model = AppModel(inMemoryStore: true)
        try externalStore(model).apply(.viewPublish(viewName: "Open loops", body: "b",
                                                    agent: "claude-mac"))
        model.refresh()
        XCTAssertNil(model.pinnedViewName)

        model.togglePinnedView("Open loops")
        XCTAssertEqual(model.pinnedViewName, "Open loops")
        XCTAssertEqual(model.settings.pinnedViewName, "Open loops", "persisted in settings")

        // Toggling the same view clears it.
        model.togglePinnedView("Open loops")
        XCTAssertNil(model.pinnedViewName)
    }

    // MARK: - M16: unread lifecycle + markViewSeen bridge

    /// The core mailbox lifecycle: a freshly-published view is UNREAD; `markViewSeen`
    /// clears it (read); republishing it makes it UNREAD again (the point of the
    /// mailbox — a newer revision post-dates the seen stamp). Verified through the
    /// published `agentViews.unreadViewNames` snapshot the feeds render.
    func testUnreadLifecyclePublishSeenRepublish() throws {
        let model = AppModel(inMemoryStore: true)
        let store = externalStore(model)
        // `markViewSeen` stamps `updatedAt = Date()` (real now), so the timeline must be
        // anchored to real time for the strictly-newer comparison to be meaningful: v1 in
        // the recent past, the seen mark now, v2 in the near future (after the mark).
        let now = Date()

        // Publish v1 (slightly in the past) → the view appears UNREAD (never opened).
        try store.apply(.viewPublish(viewName: "Open loops", body: "v1",
                                     agent: "claude-runner", ts: now.addingTimeInterval(-60)))
        model.refresh()
        XCTAssertTrue(model.agentViews.isUnread("Open loops"),
                      "a newly-published, never-opened view is unread")
        XCTAssertEqual(model.agentViews.unreadCount, 1)

        // Mark seen → READ (dot clears live on the same pass). The stamp's updatedAt (now)
        // post-dates v1's createdAt (now-60s).
        model.markViewSeen("Open loops", surface: "mac")
        XCTAssertFalse(model.agentViews.isUnread("Open loops"),
                       "markViewSeen clears the unread state")
        XCTAssertEqual(model.agentViews.unreadCount, 0)

        // Republish with a revision NEWER than the seen stamp → UNREAD again (the point
        // of the mailbox). Uses a timestamp well after the mark's real `now`.
        try store.apply(.viewPublish(viewName: "Open loops", body: "v2",
                                     agent: "claude-runner", ts: now.addingTimeInterval(3600)))
        model.refresh()
        XCTAssertTrue(model.agentViews.isUnread("Open loops"),
                      "republishing a seen view makes it unread again")
    }

    /// A fresh corpus with several views and NO seen stamps shows every view unread once
    /// (expected mailbox semantics), and marking one seen narrows the set to the rest.
    func testFreshInstallAllViewsUnreadThenNarrows() throws {
        let model = AppModel(inMemoryStore: true)
        let store = externalStore(model)
        try store.apply(.viewPublish(viewName: "A", body: "a", agent: "claude-mac"))
        try store.apply(.viewPublish(viewName: "B", body: "b", agent: "claude-mac"))
        model.refresh()

        XCTAssertEqual(model.agentViews.unreadViewNames, ["A", "B"],
                       "no stamps → everything unread once")

        model.markViewSeen("A", surface: "ios")
        XCTAssertEqual(model.agentViews.unreadViewNames, ["B"],
                       "marking one seen leaves the rest unread")
    }

    /// `markViewSeen` on an unknown view is a safe no-op: no seen stamp is written, so
    /// no phantom row can dangle (and nothing throws).
    func testMarkViewSeenUnknownViewIsNoOp() throws {
        let model = AppModel(inMemoryStore: true)
        model.markViewSeen("does-not-exist", surface: "mac")
        // Nothing to assert on the snapshot (no such view); assert no seen row exists.
        let store = externalStore(model)
        XCTAssertTrue(store.seenStamps().isEmpty,
                      "marking an unknown view writes no stamp")
    }

    /// A seen stamp that arrives via a SECOND context on the same store (the shape a
    /// CloudKit import of another device's stamp takes) clears the dot after `refresh()`
    /// — proving remote-change re-projection of unread works (the same path
    /// `observeRemoteChanges` drives). We resolve the real latest-revision id first so
    /// the stamp post-dates the revision.
    func testRemoteSeenStampClearsUnreadOnRefresh() throws {
        let model = AppModel(inMemoryStore: true)
        let store = externalStore(model)
        try store.apply(.viewPublish(viewName: "Open loops", body: "v1", agent: "claude-runner"))
        model.refresh()
        XCTAssertTrue(model.agentViews.isUnread("Open loops"))

        // Simulate the iPhone marking it seen: an external store writes the stamp
        // against the view's real latest revision, exactly as a synced-in row would.
        let latest = try XCTUnwrap(store.revisions(viewName: "Open loops").first)
        store.markViewSeen(viewName: "Open loops", revisionId: latest.id, surface: "ios")

        // The Mac re-projects (observeRemoteChanges → reloadNotes; here forced via refresh).
        model.refresh()
        XCTAssertFalse(model.agentViews.isUnread("Open loops"),
                       "a remotely-written seen stamp clears the unread state on re-projection")
    }

    /// User-deleting a whole view drops it from the snapshot AND clears a dangling pin.
    func testUserDeleteViewRemovesRevisionsAndClearsPin() throws {
        let model = AppModel(inMemoryStore: true)
        let store = externalStore(model)
        try store.apply(.viewPublish(viewName: "Doomed", body: "r1", agent: "claude-mac"))
        try store.apply(.viewPublish(viewName: "Doomed", body: "r2", agent: "claude-mac"))
        try store.apply(.viewPublish(viewName: "Keeper", body: "k1", agent: "claude-mac"))
        model.refresh()
        model.setPinnedView("Doomed")
        XCTAssertEqual(model.agentViews.latest.count, 2)

        model.userDelete(view: "Doomed")
        XCTAssertEqual(model.agentViews.latest.map(\.viewName), ["Keeper"],
                       "the deleted view leaves the feed; the other view stays")
        XCTAssertTrue(model.revisions(forView: "Doomed").isEmpty,
                      "all its revisions are gone")
        XCTAssertNil(model.pinnedViewName,
                     "deleting the pinned view clears the now-dangling pin")
    }
}
