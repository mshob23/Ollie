import Foundation
import XCTest
@testable import HandheldNotesCore

/// Unit tests for `NotificationScheduler` — the reconciler between the inbox's reminders
/// and the device's pending local notifications (M24a, contract §7). The notification
/// center is a **recording fake** (`FakeCenter`) so the diff logic runs with no real
/// `UNUserNotificationCenter` (which needs an app bundle and would prompt). A fixed `now`
/// is injected so the past-due cutoff is deterministic.
///
/// Coverage (the acceptance cases):
///   • the pure `plan` diff — schedules future, cancels vanished + dismissed, skips
///     past-due, and the request identifier IS the `blockId`;
///   • `reconcile` applies that plan against the center;
///   • authorization is requested **lazily and exactly once** — never when there's
///     nothing to schedule, once across repeated reconciles that do schedule.
@MainActor
final class NotificationSchedulerTests: XCTestCase {

    /// A fake ``NotificationScheduling`` that records every call and models a pending set
    /// keyed by identifier, so a test can assert exactly what was scheduled/cancelled and
    /// how many times authorization was requested.
    private final class FakeCenter: NotificationScheduling {
        /// Currently-pending reminder requests, keyed by identifier (== blockId).
        var pending: [String: Reminder] = [:]
        /// Every reminder ever passed to `scheduleReminder`, in call order.
        private(set) var scheduled: [Reminder] = []
        /// Every identifier list ever passed to `removePendingReminders`, in call order.
        private(set) var cancelled: [[String]] = []
        /// How many times authorization was requested.
        private(set) var authorizationRequests = 0
        /// Every arrival-banner body posted, in call order.
        private(set) var banners: [String] = []

        func pendingReminderIdentifiers() async -> Set<String> { Set(pending.keys) }

        func scheduleReminder(_ reminder: Reminder) async {
            scheduled.append(reminder)
            pending[reminder.blockId] = reminder
        }

        func removePendingReminders(identifiers: [String]) {
            cancelled.append(identifiers)
            for id in identifiers { pending[id] = nil }
        }

        func requestAuthorization() async { authorizationRequests += 1 }

        func postArrivalBanner(body: String) async { banners.append(body) }
    }

    // Fixed reference clock; reminders are placed relative to it.
    private let now = Date(timeIntervalSince1970: 1_780_000_000)
    private func future(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }
    private func past(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

    private func reminder(_ id: String, at date: Date, text: String = "t", dismissed: Bool = false) -> Reminder {
        Reminder(blockId: id, fireDate: date, text: text, isDismissed: dismissed)
    }

    // MARK: - Pure plan diff

    func testPlanSchedulesFutureNotYetPending() {
        let r = reminder("cl1:a:0", at: future(3600))
        let plan = NotificationScheduler.plan(reminders: [r], pending: [], now: now)
        XCTAssertEqual(plan.toSchedule.map(\.blockId), ["cl1:a:0"])
        XCTAssertTrue(plan.toCancel.isEmpty)
    }

    func testPlanSkipsPastDue() {
        let r = reminder("cl1:a:0", at: past(60))
        let plan = NotificationScheduler.plan(reminders: [r], pending: [], now: now)
        XCTAssertTrue(plan.toSchedule.isEmpty, "a past-due reminder is never scheduled")
        XCTAssertTrue(plan.toCancel.isEmpty)
    }

    func testPlanTreatsExactNowAsPastDue() {
        // fireDate == now is NOT strictly future → not scheduled (the `> now` boundary).
        let r = reminder("cl1:a:0", at: now)
        let plan = NotificationScheduler.plan(reminders: [r], pending: [], now: now)
        XCTAssertTrue(plan.toSchedule.isEmpty)
    }

    func testPlanCancelsVanishedLine() {
        // Was pending, no longer desired (not in the reminders list at all) → cancel.
        let plan = NotificationScheduler.plan(reminders: [], pending: ["cl1:gone:0"], now: now)
        XCTAssertTrue(plan.toSchedule.isEmpty)
        XCTAssertEqual(plan.toCancel, ["cl1:gone:0"])
    }

    func testPlanCancelsDismissed() {
        // A dismissed reminder that is currently pending → cancel, never reschedule.
        let r = reminder("cl1:a:0", at: future(3600), dismissed: true)
        let plan = NotificationScheduler.plan(reminders: [r], pending: ["cl1:a:0"], now: now)
        XCTAssertTrue(plan.toSchedule.isEmpty)
        XCTAssertEqual(plan.toCancel, ["cl1:a:0"])
    }

    func testPlanDismissedFutureNeverScheduled() {
        // A dismissed reminder that is NOT pending → simply not scheduled (nothing to cancel).
        let r = reminder("cl1:a:0", at: future(3600), dismissed: true)
        let plan = NotificationScheduler.plan(reminders: [r], pending: [], now: now)
        XCTAssertTrue(plan.toSchedule.isEmpty)
        XCTAssertTrue(plan.toCancel.isEmpty)
    }

    func testPlanCancelsPastDueThatWasPending() {
        // A reminder still present but now past-due, whose request is still pending → cancel
        // (it's no longer desired-pending).
        let r = reminder("cl1:a:0", at: past(60))
        let plan = NotificationScheduler.plan(reminders: [r], pending: ["cl1:a:0"], now: now)
        XCTAssertEqual(plan.toCancel, ["cl1:a:0"])
    }

    func testPlanNoOpWhenAlreadyPending() {
        // Desired-future and already pending → neither scheduled again nor cancelled (a
        // reorder republish where the id set is unchanged).
        let r = reminder("cl1:a:0", at: future(3600))
        let plan = NotificationScheduler.plan(reminders: [r], pending: ["cl1:a:0"], now: now)
        XCTAssertTrue(plan.toSchedule.isEmpty, "an already-pending reminder isn't double-scheduled")
        XCTAssertTrue(plan.toCancel.isEmpty)
    }

    func testPlanRewordReschedules() {
        // The old id vanished from desired (cancel) and a new id appeared (schedule) — the
        // reword lifecycle: identifier is the blockId, so a new hash is a new request.
        let reworded = reminder("cl1:new:0", at: future(3600))
        let plan = NotificationScheduler.plan(reminders: [reworded], pending: ["cl1:old:0"], now: now)
        XCTAssertEqual(plan.toSchedule.map(\.blockId), ["cl1:new:0"])
        XCTAssertEqual(plan.toCancel, ["cl1:old:0"])
    }

    func testPlanMixedBatchOrdersScheduleByDocumentOrder() {
        let a = reminder("cl1:a:0", at: future(100), text: "a")   // schedule
        let past = reminder("cl1:p:0", at: self.past(100), text: "p")   // skip (past)
        let b = reminder("cl1:b:0", at: future(200), text: "b")   // schedule
        let dismissed = reminder("cl1:d:0", at: future(300), dismissed: true) // skip
        let plan = NotificationScheduler.plan(
            reminders: [a, past, b, dismissed], pending: ["cl1:stale:0"], now: now)
        XCTAssertEqual(plan.toSchedule.map(\.blockId), ["cl1:a:0", "cl1:b:0"], "document order preserved")
        XCTAssertEqual(plan.toCancel, ["cl1:stale:0"])
    }

    // MARK: - reconcile against the fake center

    func testReconcileSchedulesAndCancels() async {
        let center = FakeCenter()
        center.pending["cl1:stale:0"] = reminder("cl1:stale:0", at: future(9999))
        let scheduler = NotificationScheduler(center: center)

        let keep = reminder("cl1:keep:0", at: future(3600), text: "keep")
        await scheduler.reconcile(reminders: [keep], now: now)

        XCTAssertEqual(center.scheduled.map(\.blockId), ["cl1:keep:0"])
        XCTAssertEqual(center.cancelled, [["cl1:stale:0"]], "the vanished pending id is cancelled")
        // Identifier == blockId, and the payload text rode through.
        XCTAssertEqual(center.scheduled.first?.blockId, "cl1:keep:0")
        XCTAssertEqual(center.scheduled.first?.text, "keep")
    }

    // MARK: - Lazy, once-only authorization

    func testAuthorizationNotRequestedWhenNothingToSchedule() async {
        let center = FakeCenter()
        let scheduler = NotificationScheduler(center: center)
        // No reminders → nothing to schedule → never prompt.
        await scheduler.reconcile(reminders: [], now: now)
        XCTAssertEqual(center.authorizationRequests, 0, "no schedule work ⇒ no permission prompt")
        // Even a batch that only CANCELS shouldn't prompt.
        center.pending["cl1:x:0"] = reminder("cl1:x:0", at: future(10))
        await scheduler.reconcile(reminders: [], now: now)
        XCTAssertEqual(center.authorizationRequests, 0, "a cancel-only reconcile doesn't prompt")
        XCTAssertEqual(center.cancelled, [["cl1:x:0"]])
    }

    func testAuthorizationRequestedExactlyOnceAcrossReconciles() async {
        let center = FakeCenter()
        let scheduler = NotificationScheduler(center: center)

        // First schedule → one prompt.
        await scheduler.reconcile(reminders: [reminder("cl1:a:0", at: future(10))], now: now)
        XCTAssertEqual(center.authorizationRequests, 1)

        // A later reconcile that also schedules → still only one prompt total.
        await scheduler.reconcile(reminders: [
            reminder("cl1:a:0", at: future(10)),
            reminder("cl1:b:0", at: future(20)),
        ], now: now)
        XCTAssertEqual(center.authorizationRequests, 1, "authorization is requested at most once per process")
        XCTAssertEqual(Set(center.scheduled.map(\.blockId)), ["cl1:a:0", "cl1:b:0"])
    }
}
