import Foundation
import XCTest
@testable import HandheldNotesCore

/// Unit tests for `RunnerTrigger` — the debounced event-driven trigger for the
/// launchd agent runner (M11). Uses an injected **manual scheduler** so the quiet
/// window is advanced explicitly and every assertion runs in microseconds, never
/// waiting real seconds.
///
/// The production `fire` (an atomic write to `~/Ollie/.runner-trigger`) is replaced
/// by a counter closure, so these tests exercise the pure debounce state machine in
/// isolation — exactly the seam the task calls for.
///
/// Coverage (the M11 acceptance cases):
///   • a burst of 5 arrivals → **exactly one** fire after the window elapses;
///   • an arrival *during* the window **resets** it (no early fire; one fire later);
///   • a second burst **after** a fire → a **second** fire (windows are independent);
///   • the "gate closed" path (no `noteArrived()`, or a `cancel()` before the window
///     elapses) → **no** fire — the mechanism `AppModel` relies on so a nil trigger /
///     a disabled export never writes the trigger file.
@MainActor
final class RunnerTriggerTests: XCTestCase {

    /// A deterministic ``RunnerTriggerScheduler`` that retains **every** item ever
    /// scheduled and fires all still-uncancelled ones on ``advance()``.
    ///
    /// Review fix (2026-07-07): an earlier version kept only the LATEST item, which
    /// silently modelled the cancel these tests exist to verify — a production
    /// `noteArrived()` that forgot `pending?.cancel()` still passed the reset test.
    /// By retaining all items, a stale un-cancelled window FIRES here exactly as a
    /// real DispatchSource timer would, so the reset-on-arrival contract is genuinely
    /// pinned (two fires = red test).
    private final class ManualScheduler: RunnerTriggerScheduler {
        /// Every scheduled work item, in schedule order, pending until advance().
        private var scheduled: [ManualWork] = []
        /// How many distinct work items were ever scheduled (a re-schedule after a
        /// reset counts again) — lets a test assert the debounce re-armed.
        private(set) var scheduleCount = 0

        func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> RunnerTriggerScheduledWork {
            scheduleCount += 1
            let w = ManualWork(work)
            scheduled.append(w)
            return w
        }

        /// Simulate the quiet window elapsing: fire EVERY pending item that was not
        /// cancelled (a correct trigger leaves at most one). No-op when nothing is
        /// pending — precisely the "gate closed → nothing happens" case.
        func advance() {
            let pending = scheduled.filter { !$0.isCancelled }
            scheduled.removeAll()
            pending.forEach { $0.run() }
        }

        private final class ManualWork: RunnerTriggerScheduledWork {
            private let work: () -> Void
            private(set) var isCancelled = false
            init(_ work: @escaping () -> Void) { self.work = work }
            func cancel() { isCancelled = true }
            func run() { work() }
        }
    }

    // MARK: - Cases

    /// A burst of 5 arrivals produces exactly ONE fire once the window elapses.
    func testBurstOfFiveFiresExactlyOnceAfterQuiet() {
        let scheduler = ManualScheduler()
        var fires = 0
        let trigger = RunnerTrigger(debounce: 90, scheduler: scheduler) { fires += 1 }

        for _ in 0..<5 { trigger.noteArrived() }

        // Mid-burst: a window is open but nothing has fired yet.
        XCTAssertEqual(fires, 0, "must not fire while arrivals are still coming")
        XCTAssertTrue(trigger.isPending, "a window should be open after the burst")

        scheduler.advance()   // the quiet window elapses

        XCTAssertEqual(fires, 1, "a settled burst fires exactly once")
        XCTAssertFalse(trigger.isPending, "the window is closed after firing")
    }

    /// An arrival during the window RESETS it: the earlier countdown is superseded, so
    /// there is no fire until the LATEST window elapses, and then only once.
    func testArrivalDuringWindowResetsIt() {
        let scheduler = ManualScheduler()
        var fires = 0
        let trigger = RunnerTrigger(debounce: 90, scheduler: scheduler) { fires += 1 }

        trigger.noteArrived()   // opens window #1
        trigger.noteArrived()   // resets → window #2 (window #1's work is cancelled)

        XCTAssertEqual(scheduler.scheduleCount, 2, "each arrival re-arms the debounce")
        XCTAssertEqual(fires, 0)

        scheduler.advance()     // only the latest (live) window fires

        XCTAssertEqual(fires, 1, "the reset collapses both arrivals into a single fire")
    }

    /// A second burst AFTER a fire opens a fresh window and fires again — windows are
    /// independent, so a later batch of notes gets its own run.
    func testSecondBurstAfterFireFiresAgain() {
        let scheduler = ManualScheduler()
        var fires = 0
        let trigger = RunnerTrigger(debounce: 90, scheduler: scheduler) { fires += 1 }

        trigger.noteArrived()
        scheduler.advance()
        XCTAssertEqual(fires, 1)

        // A new arrival after the first fire must re-arm and fire a second time.
        trigger.noteArrived()
        XCTAssertTrue(trigger.isPending, "a post-fire arrival opens a new window")
        scheduler.advance()

        XCTAssertEqual(fires, 2, "a later burst gets its own fire")
    }

    /// The gate-closed path: with NO arrival, advancing the clock fires nothing — the
    /// no-op the nil-trigger / disabled-export wiring depends on. And a `cancel()`
    /// before the window elapses suppresses an already-armed fire.
    func testNoArrivalNeverFiresAndCancelSuppresses() {
        let scheduler = ManualScheduler()
        var fires = 0
        let trigger = RunnerTrigger(debounce: 90, scheduler: scheduler) { fires += 1 }

        // (a) No arrival at all → nothing scheduled, advancing does nothing.
        scheduler.advance()
        XCTAssertEqual(fires, 0, "with no arrival there is nothing to fire")
        XCTAssertFalse(trigger.isPending)

        // (b) An armed window that is cancelled (teardown / gate turned off) never fires.
        trigger.noteArrived()
        XCTAssertTrue(trigger.isPending)
        trigger.cancel()
        XCTAssertFalse(trigger.isPending, "cancel closes the window")
        scheduler.advance()
        XCTAssertEqual(fires, 0, "a cancelled window must not fire")
    }

    /// The default quiet window is the documented 90 s (guards against an accidental
    /// change to the latency contract the WatchPaths design depends on).
    func testDefaultDebounceIs90Seconds() {
        XCTAssertEqual(RunnerTrigger.defaultDebounce, 90, accuracy: 0.0001)
    }
}
