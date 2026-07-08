import Foundation

/// The **debounced event-driven trigger** for the launchd agent runner (M11).
///
/// ## What it is for
/// The Mac's agent runner (`Scripts/ollie-agent-run.sh`) is scheduled by launchd.
/// Historically its only cadence was a 4 h `StartInterval` — so a note spoken into
/// the watch could sit for up to four hours before an agent pass tagged it or
/// answered it. This type closes that latency: it turns *note arrivals* (a new
/// `NoteEntity` becoming visible — a CloudKit import from the watch/phone, or a
/// local Mac capture) into a **single** touch of `~/Ollie/.runner-trigger`, on
/// which launchd is watching via `WatchPaths`. The touch fires the (already-guarded)
/// runner within ~2 minutes of the last arrival. The 4 h interval stays as a
/// backstop.
///
/// ## Behavior — a quiet-window debounce
/// Each ``noteArrived()`` (re)starts a `debounce`-second countdown. While arrivals
/// keep coming (a burst of watch transfers, a sync catch-up) the countdown keeps
/// resetting, so nothing fires mid-burst. When the arrivals *stop* and the window
/// elapses quietly, the injected ``fire`` closure runs **once**. In production that
/// closure atomically writes an ISO-8601 timestamp to the trigger path; launchd
/// sees the file change and starts one debounced run. A fresh arrival after a fire
/// starts a new window → a new fire, so a later batch gets its own run.
///
/// ## Why a debounce (not fire-per-arrival)
/// A CloudKit import or a watch batch surfaces *many* `NoteEntity` inserts in quick
/// succession. Firing per insert would touch the trigger dozens of times and (given
/// `WatchPaths`) risk launchd coalescing/queueing redundant runs. Debouncing to the
/// **last** arrival means one settled batch → one trigger file write → one run.
///
/// ## Loop safety (the acceptance criterion — see M11 task + docs/home-node.md)
/// This is driven **only** by `NoteEntity` inserts. Notes are immutable user ground
/// truth (CLAUDE.md invariant 1) and *no agent path ever inserts a NoteEntity*: the
/// runner's own effects — tags, view revisions, memory, interaction records,
/// re-exports — all flow through `AgentLayerStore`, which only inserts
/// `TagEntity` / `MemoryEntity` / `ViewRevisionEntity` / `InteractionStateEntity` /
/// `InstructionsEntity`. So a run can never manufacture the very event that would
/// re-trigger it; the system cannot self-trigger. (The four `NoteEntity` insert
/// sites are all user-capture paths: the compose/quick-capture/draft persist path,
/// the one-time legacy import, opt-in demo seeding, and the Shortcuts App Intent.)
///
/// ## Concurrency & purity
/// Pure logic, no I/O of its own — production I/O lives in the injected `fire`
/// closure — so it is cross-platform and unit-testable. Its production *wiring*
/// (into `AppModel`, writing under `~/Ollie/`) is macOS-only; the type itself
/// compiles everywhere. The scheduling seam (``RunnerTriggerScheduler``) is
/// injected so tests advance a manual clock and assert fires in milliseconds
/// instead of waiting real seconds. All members touch `state` only on the main
/// actor, so the class is `@MainActor`-isolated.
@MainActor
public final class RunnerTrigger {

    /// The default quiet window: 90 s after the LAST arrival before the trigger
    /// fires. Long enough that a multi-note sync catch-up or a burst of watch
    /// transfers settles into one run; short enough to meet the "within ~2 minutes"
    /// goal.
    public static let defaultDebounce: TimeInterval = 90

    private let debounce: TimeInterval
    private let scheduler: RunnerTriggerScheduler
    private let fire: () -> Void

    /// The in-flight scheduled fire, if a window is currently open. Cancelled and
    /// replaced on each new arrival (that's the debounce reset); cleared when it
    /// fires. Nil ⇔ no window open.
    private var pending: RunnerTriggerScheduledWork?

    /// - Parameters:
    ///   - debounce: the quiet window after the last arrival (default 90 s).
    ///   - scheduler: the scheduling seam — production uses ``DispatchRunnerTriggerScheduler``
    ///     (a real GCD timer on the main queue); tests inject a manual one.
    ///   - fire: called once when a window elapses quietly. Production: an atomic
    ///     write of an ISO-8601 timestamp to `~/Ollie/.runner-trigger`.
    public init(
        debounce: TimeInterval = RunnerTrigger.defaultDebounce,
        scheduler: RunnerTriggerScheduler = DispatchRunnerTriggerScheduler(),
        fire: @escaping () -> Void
    ) {
        self.debounce = debounce
        self.scheduler = scheduler
        self.fire = fire
    }

    /// Record that a note arrived. (Re)starts the quiet window: any previously
    /// scheduled fire is cancelled and a fresh `debounce`-second countdown begins,
    /// so a steady stream of arrivals coalesces into a single fire once they stop.
    public func noteArrived() {
        pending?.cancel()
        pending = scheduler.schedule(after: debounce) { [weak self] in
            guard let self else { return }
            // Clear the handle *before* firing so a `noteArrived()` triggered from
            // within `fire` (or immediately after) opens a clean new window rather
            // than racing a stale handle.
            self.pending = nil
            self.fire()
        }
    }

    /// Cancel any open window without firing (teardown / tests). Idempotent.
    public func cancel() {
        pending?.cancel()
        pending = nil
    }

    /// Whether a fire is currently scheduled (a window is open). Test-facing.
    public var isPending: Bool { pending != nil }
}

// MARK: - Scheduling seam

/// A cancellable unit of scheduled work returned by ``RunnerTriggerScheduler``.
/// `@MainActor` to match ``RunnerTriggerScheduler`` and ``RunnerTrigger`` — cancels
/// happen on the main actor (a `noteArrived()` reset, teardown), so an
/// implementation may touch main-actor state in `cancel()`.
@MainActor
public protocol RunnerTriggerScheduledWork: AnyObject {
    /// Cancel the scheduled fire so it never runs.
    func cancel()
}

/// The scheduling seam ``RunnerTrigger`` uses to defer its fire. Injected so
/// production uses a real timer while tests drive a manual clock deterministically.
@MainActor
public protocol RunnerTriggerScheduler {
    /// Schedule `work` to run once after `delay` seconds, returning a handle that
    /// can cancel it before it runs.
    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> RunnerTriggerScheduledWork
}

/// The production scheduler: a one-shot GCD timer on the **main queue** (so the
/// fired work lands back on the main actor, matching `RunnerTrigger`'s isolation).
///
/// A `DispatchSourceTimer` (not `Task.sleep`) so a cancel is immediate and precise
/// and there is no dangling structured-concurrency task — the same GCD-timer idiom
/// `InboxIngestor` uses for its fallback sweep.
@MainActor
public struct DispatchRunnerTriggerScheduler: RunnerTriggerScheduler {
    public init() {}

    public func schedule(
        after delay: TimeInterval, _ work: @escaping () -> Void
    ) -> RunnerTriggerScheduledWork {
        let handle = DispatchScheduledWork()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler {
            // One-shot: mark done and cancel the source so it can't re-fire, then run.
            MainActor.assumeIsolated {
                guard !handle.isCancelled else { return }
                handle.finish()
                work()
            }
        }
        handle.timer = timer
        timer.resume()
        return handle
    }

    /// Handle wrapping the one-shot timer. `cancel()` stops it before it fires;
    /// `finish()` retires it after a successful fire. Main-actor-confined.
    @MainActor
    private final class DispatchScheduledWork: RunnerTriggerScheduledWork {
        var timer: DispatchSourceTimer?
        private(set) var isCancelled = false

        nonisolated init() {}

        func cancel() {
            guard !isCancelled else { return }
            isCancelled = true
            timer?.cancel()
            timer = nil
        }

        func finish() {
            timer?.cancel()
            timer = nil
        }
    }
}

// MARK: - Production fire: atomic trigger-file write (macOS)

#if os(macOS)
public extension RunnerTrigger {

    /// The launchd `WatchPaths` file the deployed runner watches:
    /// `~/Ollie/.runner-trigger`. Touching it (an atomic write) fires a debounced
    /// run. Derived from `CorpusExporter.exportDirectory` so a test override of the
    /// `~/Ollie` root redirects this in lockstep with the rest of the mirror.
    static var triggerFileURL: URL {
        CorpusExporter.exportDirectory.appendingPathComponent(".runner-trigger")
    }

    /// The production `fire`: atomically write an ISO-8601 timestamp to
    /// `~/Ollie/.runner-trigger`, creating `~/Ollie` if needed. The *content* is
    /// only a breadcrumb (launchd `WatchPaths` reacts to the file changing, not to
    /// what it contains) but a monotonically-changing timestamp guarantees the
    /// bytes differ every time, and it doubles as a "last event-trigger" marker a
    /// human can `cat`. Best-effort: a failure is logged, never fatal — the 4 h
    /// backstop still runs.
    static func writeTriggerFile() {
        let url = triggerFileURL
        let stamp = ISO8601DateFormatter().string(from: Date())
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (stamp + "\n").write(to: url, atomically: true, encoding: .utf8)
            Diag.log("HNDIAG runner-trigger touched (\(stamp)) — debounced note arrival → launchd WatchPaths")
        } catch {
            Diag.log("HNDIAG runner-trigger FAILED to write \(url.path): \(error)")
        }
    }
}
#endif
