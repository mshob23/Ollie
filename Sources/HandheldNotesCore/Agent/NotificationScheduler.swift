import Foundation

/// Reconciles the reminders declared in the `inbox` body against the **pending local
/// notification requests** on the device (M24a, contract §7). macOS **and** iOS run this
/// (a double banner is the Apple-Reminders norm; the watch mirrors the iPhone's banners
/// for free). It must NOT be referenced from the watch target's path-referenced files
/// (`MarkdownLite`/`FenceWidgets`) — it is reached only through `AppModel`, off the watch
/// build.
///
/// ## The identity rule (why reconcile, not "add on arrival")
/// A notification request's **identifier is the reminder's M7 `blockId`** (contract §7).
/// That single choice makes the whole lifecycle fall out of a set diff between *desired*
/// (future, un-dismissed reminders in the latest inbox body) and *pending* (already
/// scheduled) identifiers:
///   • a **reorder** republish keeps each line's id → the desired set is unchanged →
///     nothing is rescheduled (no double-fire);
///   • a **reword** (or a date/text edit) changes the id → the old id vanishes from
///     desired (cancelled) and the new id is scheduled (rescheduled);
///   • a **tick** (dismiss) drops the line from desired → cancelled;
///   • a line that scrolls out of the latest revision → cancelled;
///   • a **past-due** reminder is never in desired → never scheduled (and if one is
///     pending because time passed, it's harmless — the OS fired or will not).
///
/// ## Purity
/// The diff (``plan(reminders:pending:now:)``) is a pure function over value types — no
/// notification center, no clock of its own (the caller passes `now`). It is unit-tested
/// directly. Only ``reconcile(reminders:now:)`` touches the injected
/// ``NotificationScheduling`` center, and even that is fully faked in tests. Authorization
/// is requested **lazily**: the first reconcile that actually has something to schedule
/// asks once; a corpus with no future reminders never prompts.
@MainActor
public final class NotificationScheduler {

    private let center: NotificationScheduling

    /// Whether we have already asked the center for authorization this process. Ensures a
    /// single lazy request: the FIRST reconcile with work to schedule prompts; later ones
    /// don't re-ask (the OS would no-op a re-request, but not re-asking keeps intent clear
    /// and the test assertion — "requested exactly once" — meaningful).
    private var didRequestAuthorization = false

    /// The most recently *chained* reconcile task, so ``reconcileSerialized(reminders:now:)``
    /// can run reconciles strictly FIFO — the newest always awaits the previous one and thus
    /// lands last (M24a review MINOR). `reconcile` itself is read-modify-write across `await`
    /// boundaries (it reads pending ids, then schedules/cancels); two un-serialized reconciles
    /// spawned by rapid reloads could interleave on the main actor so that a LATE-completing
    /// OLDER reconcile (holding the older reminders array) re-schedules a reminder the NEWER
    /// one just cancelled (e.g. the user ticked it). Chaining removes that interleave without
    /// cancellation (cancellation would add cooperative-cancel modes for no benefit — the win
    /// is purely ordering). `nil` until the first serialized reconcile. Not observed by
    /// SwiftUI (a plain stored property on this non-`@Observable` class).
    private var previousReconcile: Task<Void, Never>?

    /// - Parameter center: the notification-center seam. Production wires a
    ///   ``UserNotificationCenterScheduling`` wrapping `UNUserNotificationCenter.current()`
    ///   (macOS/iOS app targets only); tests inject a recording fake so the diff logic
    ///   runs without a real center (which requires an app bundle and would prompt).
    public init(center: NotificationScheduling) {
        self.center = center
    }

    /// The pure reconciliation decision: given the currently-`desired` reminders, the set
    /// of `pending` request identifiers, and `now`, decide what to **schedule** and what to
    /// **cancel**. No side effects — the caller applies the result.
    ///
    /// Rules (contract §7):
    ///   • **Desired to be pending** = a reminder that is NOT dismissed and whose `fireDate`
    ///     is strictly in the future (`> now`). Past-due and dismissed reminders are never
    ///     desired-pending.
    ///   • **Schedule** = desired-pending ids not already `pending`.
    ///   • **Cancel** = `pending` ids that are no longer desired-pending — a vanished line,
    ///     a dismissed one, a rewording's old id, or one that fell past-due while pending.
    ///
    /// A reminder appearing twice with the same `blockId` (identical duplicate lines share a
    /// hash but get distinct occurrence ordinals, so this is only possible for genuine id
    /// collisions) is de-duplicated by keeping the first — the identifier is the key.
    public static func plan(reminders desired: [Reminder],
                            pending: Set<String>,
                            now: Date) -> SchedulerPlan {
        // Walk in document order, keeping the FIRST occurrence of each blockId. A reminder
        // is desired-pending when it is not dismissed and its fireDate is in the future.
        // `toSchedule` = desired-pending whose id isn't already pending, in document order.
        var seenIDs = Set<String>()
        var desiredPendingIDs = Set<String>()
        var toSchedule: [Reminder] = []
        for reminder in desired {
            guard !seenIDs.contains(reminder.blockId) else { continue }
            seenIDs.insert(reminder.blockId)
            guard !reminder.isDismissed, reminder.fireDate > now else { continue }
            desiredPendingIDs.insert(reminder.blockId)
            if !pending.contains(reminder.blockId) { toSchedule.append(reminder) }
        }

        // Cancel pending ids no longer desired-pending: a vanished/dismissed line, a
        // reword's old id, or one that fell past-due while pending.
        let toCancel = pending.subtracting(desiredPendingIDs)

        return SchedulerPlan(toSchedule: toSchedule, toCancel: toCancel)
    }

    /// Reconcile the device's pending notifications to match `reminders` (the reminders in
    /// the latest inbox revision). Reads the center's pending identifiers, computes the
    /// ``plan(reminders:pending:now:)``, cancels what's stale, and schedules what's new —
    /// requesting authorization lazily the first time there is anything to schedule.
    ///
    /// - Parameters:
    ///   - reminders: the desired reminders (from ``ReminderGrammar/reminders(in:calendar:)``
    ///     over the latest inbox body).
    ///   - now: the reference instant for the past-due cutoff. Defaults to `Date()`;
    ///     injectable so a test can pin it.
    public func reconcile(reminders: [Reminder], now: Date = Date()) async {
        let pending = await center.pendingReminderIdentifiers()
        let plan = Self.plan(reminders: reminders, pending: pending, now: now)

        // Cancel first (a reword's old id is removed before its new id is added; also frees
        // the id if — pathologically — the same id were both cancelled and re-scheduled).
        if !plan.toCancel.isEmpty {
            center.removePendingReminders(identifiers: Array(plan.toCancel))
        }

        guard !plan.toSchedule.isEmpty else { return }

        // Lazy authorization: only now that we actually have something to schedule.
        if !didRequestAuthorization {
            didRequestAuthorization = true
            await center.requestAuthorization()
        }

        for reminder in plan.toSchedule {
            await center.scheduleReminder(reminder)
        }
    }

    /// Reconcile, but **serialized FIFO** against any prior serialized reconcile so the
    /// newest desired state always lands last (M24a review MINOR). Spawns a task that first
    /// awaits the previous serialized reconcile's completion and then runs
    /// ``reconcile(reminders:now:)`` for `reminders`; records that task as the new
    /// `previousReconcile`. Returns immediately with the spawned task (the caller does not
    /// await it — the fire-and-forget shape of the reload path is preserved), so a caller
    /// that spawns A then B is guaranteed the effective order A-then-B: B's read of the
    /// center's pending set happens *after* A has fully applied, so B's cancel of a ticked
    /// reminder can never be undone by a late A re-scheduling it.
    ///
    /// The `reminders` array is captured by value at call time (as `reconcile` already takes
    /// it by value), so each chained reconcile carries the snapshot it was requested with.
    /// This method must be called on the main actor (the class is `@MainActor`), which also
    /// makes the read-then-write of `previousReconcile` atomic — the ordering is established
    /// synchronously at spawn time, before either task's first `await`.
    @discardableResult
    public func reconcileSerialized(reminders: [Reminder], now: Date = Date()) -> Task<Void, Never> {
        let prev = previousReconcile
        let task = Task { [weak self] in
            // Wait for the previous reconcile to fully finish before starting this one, so
            // the chain applies in request order. `weak self` mirrors AppModel capturing the
            // scheduler (not the model) — if the scheduler outlives nothing, the chain simply
            // stops.
            await prev?.value
            await self?.reconcile(reminders: reminders, now: now)
        }
        previousReconcile = task
        return task
    }

    /// Post an immediate **arrival banner** (Mac only, M24a item 5) through the same center
    /// — a passthrough so the app layer never has to hold the center itself. Body is the
    /// first new inbox line's text (grammar-stripped for a reminder). Independent of the
    /// reconcile: its own random identifier, never a `blockId`.
    public func postArrivalBanner(body: String) async {
        await center.postArrivalBanner(body: body)
    }
}

/// The pure output of ``NotificationScheduler/plan(reminders:pending:now:)`` — what to
/// schedule and what to cancel. Value type so the diff is trivially testable.
public struct SchedulerPlan: Equatable, Sendable {
    /// Reminders to schedule (desired, future, not yet pending), in document order.
    public var toSchedule: [Reminder]
    /// Identifiers (== `blockId`) to cancel (pending but no longer desired).
    public var toCancel: Set<String>

    public init(toSchedule: [Reminder], toCancel: Set<String>) {
        self.toSchedule = toSchedule
        self.toCancel = toCancel
    }
}

// MARK: - The center seam

/// The narrow seam ``NotificationScheduler`` uses to touch the local-notification center,
/// so the diff logic tests pure. Production conforms `UNUserNotificationCenter`
/// (``UserNotificationCenterScheduling``); tests inject a recording fake. `@MainActor` to
/// match the scheduler.
///
/// The methods are deliberately reminder-shaped (not a generic notification API): the
/// scheduler only ever schedules a reminder for a `fireDate` under its `blockId`, cancels
/// by identifier, and reads back the identifiers it owns — so the seam carries exactly
/// that and nothing more.
@MainActor
public protocol NotificationScheduling {
    /// The identifiers of currently-pending requests **that this scheduler owns** (i.e.
    /// reminder requests keyed by `blockId`). A conformance may return only its own
    /// requests so unrelated app notifications are never cancelled by the reconcile.
    func pendingReminderIdentifiers() async -> Set<String>

    /// Schedule (or replace) a local notification for `reminder`, using `reminder.blockId`
    /// as the request identifier and `reminder.fireDate` as a calendar trigger. The
    /// caller guarantees the date is in the future.
    func scheduleReminder(_ reminder: Reminder) async

    /// Cancel the pending requests with these identifiers. No-op for ids that aren't
    /// pending.
    func removePendingReminders(identifiers: [String])

    /// Request notification authorization (alert/sound). Called at most once per process by
    /// the scheduler, lazily, on the first reconcile with something to schedule. A
    /// conformance awaits the user's decision; a denial just means the scheduled requests
    /// won't surface — never an error.
    func requestAuthorization() async

    /// Post an **arrival banner** immediately (Mac only, M24a item 5): one notification with
    /// no time trigger, shown as soon as a genuinely new `inbox` line arrives. `body` is the
    /// first new line's text (grammar-stripped for a reminder). Distinct from a scheduled
    /// reminder — it fires now, carries a fresh random identifier (never a `blockId`, so it
    /// can't collide with or cancel a scheduled reminder), and requests authorization
    /// itself if needed. iOS conformances may no-op it (iPhone arrival banners while the app
    /// is dead need push — the M24b spike).
    func postArrivalBanner(body: String) async
}

#if canImport(UserNotifications)
import UserNotifications

/// The production ``NotificationScheduling``: a thin wrapper over
/// `UNUserNotificationCenter`. Available on macOS + iOS (UserNotifications is in Core's
/// deployment floor); the watch never constructs one (this file is off its build).
///
/// **Reminder ownership.** Reminder requests are tagged in `userInfo` with
/// ``reminderKindKey`` `== "reminder"`, and `pendingReminderIdentifiers()` returns only
/// those — so a reconcile can never cancel a CloudKit/system notification that happens to
/// share the center. The `userInfo` also carries the target view (`"inbox"`) so a future
/// tap handler can deep-link (Mac v1 handling can be minimal — opening the app is fine).
@MainActor
public struct UserNotificationCenterScheduling: NotificationScheduling {

    /// `userInfo` key carrying the view a tap should deep-link to. **Must match the iOS
    /// app's `OllieNotificationDelegate.viewNameKey`** (`"viewName"`) so the sibling's tap
    /// router reads our value; the Mac tap handling is minimal (opening the app is fine).
    public static let viewNameKey = "viewName"
    /// `userInfo` key = the reminder marker; value ``reminderKind``. Used only to tell OUR
    /// scheduled reminders apart from unrelated notifications (CloudKit/system) so the
    /// reconcile never cancels a request it doesn't own.
    public static let reminderKindKey = "ollieKind"
    /// The ``reminderKindKey`` value identifying our reminder requests.
    public static let reminderKind = "reminder"
    /// The view a reminder / arrival-banner tap should open (contract §7 — only `inbox`
    /// participates in the delivery channel).
    public static let inboxViewName = "inbox"

    private let center: UNUserNotificationCenter

    /// - Parameter center: defaults to `.current()`. Constructing this touches the app's
    ///   bundle, so it is created only in the app targets (never in a test / the watch).
    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    public func pendingReminderIdentifiers() async -> Set<String> {
        let requests = await center.pendingNotificationRequests()
        var ids = Set<String>()
        for request in requests
        where request.content.userInfo[Self.reminderKindKey] as? String == Self.reminderKind {
            ids.insert(request.identifier)
        }
        return ids
    }

    public func scheduleReminder(_ reminder: Reminder) async {
        let content = UNMutableNotificationContent()
        content.body = reminder.text
        content.sound = .default
        content.userInfo = [
            Self.reminderKindKey: Self.reminderKind,
            Self.viewNameKey: Self.inboxViewName,
        ]

        // A calendar trigger at the resolved wall-time instant (device-local components),
        // non-repeating. We derive components in the current calendar from the frozen
        // fireDate, so the OS fires at that instant.
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: reminder.fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(
            identifier: reminder.blockId, content: content, trigger: trigger)
        do {
            try await center.add(request)
        } catch {
            Diag.log("HNDIAG reminder schedule FAILED (\(reminder.blockId)): \(error)")
        }
    }

    public func removePendingReminders(identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    public func requestAuthorization() async {
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            Diag.log("HNDIAG reminder authorization request FAILED: \(error)")
        }
    }

    public func postArrivalBanner(body: String) async {
        // Arrival banners need permission too, and (unlike scheduling) a banner is the
        // first thing that ever reaches the center on a fresh inbox — so ask here as well.
        // `requestAuthorization` is idempotent at the OS level (a second ask after a grant
        // is a no-op), so calling it from both paths is safe.
        await requestAuthorization()

        let content = UNMutableNotificationContent()
        content.body = body
        content.sound = .default
        content.userInfo = [
            Self.viewNameKey: Self.inboxViewName,
        ]
        // A fresh random identifier — NOT a blockId — so an arrival banner never shares an
        // id with (and thus never cancels or is cancelled by) a scheduled reminder, and
        // `pendingReminderIdentifiers()` never returns it (no `reminderKind` marker). nil
        // trigger ⇒ deliver immediately.
        let request = UNNotificationRequest(
            identifier: "ollie-arrival-\(UUID().uuidString)", content: content, trigger: nil)
        do {
            try await center.add(request)
        } catch {
            Diag.log("HNDIAG arrival banner FAILED: \(error)")
        }
    }
}
#endif
