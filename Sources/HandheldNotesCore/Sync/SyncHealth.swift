import CloudKit
import Foundation

/// The observable health of iCloud sync, surfaced to the UI so a silent failure
/// (the worst kind) becomes visible. `AppModel` folds CloudKit phase events into
/// one of these states and publishes it; views render a banner/indicator off it.
///
/// The states are deliberately coarse — the UI only needs "is sync fine, working,
/// degraded, or simply not configured" — and `Equatable`/`Sendable` so they can
/// drive SwiftUI diffing and cross actors cleanly.
public enum SyncHealth: Equatable, Sendable {
    /// No CloudKit backing at all — the local-only fallback store (pre-portal,
    /// Simulator, no iCloud account). Not an error; sync is simply not in play.
    case localOnly
    /// CloudKit is active and at rest. `lastSuccess` is the timestamp of the most
    /// recent successful import/export phase, or `nil` if none has completed yet.
    case idle(lastSuccess: Date?)
    /// A CloudKit phase (setup/import/export) is in progress.
    case syncing
    /// Sync is failing. Carries the classified cause and the time it was first
    /// observed, so the UI can show "degraded since <relative>".
    case degraded(SyncDegradation, since: Date)
}

/// A conservative classification of *why* sync is degraded, so the UI can show
/// an actionable message instead of a raw error dump.
///
/// **Conservatism is the contract.** A transient hiccup (network, rate-limit)
/// must never be reported as a schema/config problem — a false "deploy your
/// schema" alarm is as damaging as silence. The classifier (`SyncHealth.classify`)
/// only escalates to `.schemaNotDeployed` for errors that genuinely indicate the
/// server rejected the request shape.
public enum SyncDegradation: Equatable, Sendable {
    /// The CloudKit schema hasn't been deployed to the Production environment
    /// (CloudKit Dashboard ▸ Deploy Schema Changes). Records get server-rejected.
    case schemaNotDeployed
    /// No usable iCloud account (signed out, restricted, temporarily unavailable).
    case accountUnavailable
    /// A transient network condition — offline, flaky, rate-limited, server busy.
    case network
    /// The user's iCloud storage is full.
    case quota
    /// Anything we don't recognize; carries the underlying description verbatim.
    case unknown(String)

    /// A short, user-facing sentence describing the situation and (where there is
    /// one) the corrective action.
    public var userMessage: String {
        switch self {
        case .schemaNotDeployed:
            return "Sync is failing - the iCloud schema may need deploying to Production (CloudKit Dashboard)."
        case .accountUnavailable:
            return "Not syncing - sign in to iCloud."
        case .network:
            return "Sync paused - waiting for network."
        case .quota:
            return "Not syncing - iCloud storage full."
        case .unknown(let description):
            return description
        }
    }
}

extension SyncHealth {

    /// CloudKit's internal error domain, surfaced as the `underlyingError` of a
    /// partial/translated failure. Code `1011` ("server rejected request") is the
    /// shape an undeployed schema takes when NSPersistentCloudKitContainer tries
    /// to push records the Production environment doesn't know.
    private static let ckInternalErrorDomain = "CKInternalErrorDomain"
    private static let ckServerRejectedRequestCode = 1011

    /// Pure, side-effect-free classification of a sync error into a
    /// `SyncDegradation`. No CloudKit calls, no I/O — just inspection of the
    /// error — so it's fully unit-testable with synthetic `CKError`s.
    ///
    /// Mapping (CONSERVATIVE — transient conditions never become `schemaNotDeployed`):
    ///   - auth/account:   `.notAuthenticated`, `.accountTemporarilyUnavailable`,
    ///                     `.managedAccountRestricted`            → `.accountUnavailable`
    ///   - transient:      `.networkUnavailable`, `.networkFailure`,
    ///                     `.serviceUnavailable`, `.requestRateLimited` → `.network`
    ///   - storage:        `.quotaExceeded`                       → `.quota`
    ///   - server reject:  `.serverRejectedRequest`, OR `.partialFailure` whose
    ///                     per-item errors include a server/internal rejection, OR
    ///                     a wrapped `CKInternalErrorDomain` code 1011
    ///                                                            → `.schemaNotDeployed`
    ///   - else:           `.unknown(error.localizedDescription)`
    public static func classify(_ error: Error) -> SyncDegradation {
        guard let ckError = asCKError(error) else {
            return .unknown(error.localizedDescription)
        }

        switch ckError.code {
        case .notAuthenticated,
             .accountTemporarilyUnavailable,
             .managedAccountRestricted:
            return .accountUnavailable

        // Transient. These must NEVER escalate to schemaNotDeployed.
        case .networkUnavailable,
             .networkFailure,
             .serviceUnavailable,
             .requestRateLimited:
            return .network

        case .quotaExceeded:
            return .quota

        case .serverRejectedRequest:
            return .schemaNotDeployed

        case .partialFailure:
            // A partial failure is only a schema/config signal if at least one of
            // its per-item errors is itself a server/internal rejection. If the
            // per-item failures are all transient (network, rate-limit), classify
            // by that transient cause instead — never a false schema alarm.
            return classifyPartialFailure(ckError)

        default:
            // Could still be a wrapped internal "server rejected" (1011).
            if isWrappedServerRejection(ckError) {
                return .schemaNotDeployed
            }
            return .unknown(error.localizedDescription)
        }
    }

    /// Coerce an arbitrary error into a `CKError` if it is one (directly or as an
    /// `NSError` in the CloudKit domain).
    private static func asCKError(_ error: Error) -> CKError? {
        if let ck = error as? CKError { return ck }
        let ns = error as NSError
        if ns.domain == CKError.errorDomain {
            return CKError(_nsError: ns)
        }
        return nil
    }

    /// Inspect a `.partialFailure`'s per-item errors. Returns `.schemaNotDeployed`
    /// only if a contained error is a server/internal rejection; otherwise reduces
    /// to the most relevant contained cause (transient wins over unknown).
    private static func classifyPartialFailure(_ ckError: CKError) -> SyncDegradation {
        let itemErrors = (ckError.partialErrorsByItemID ?? [:]).values

        var sawTransient = false
        for itemError in itemErrors {
            let nested = classifyNested(itemError)
            switch nested {
            case .schemaNotDeployed:
                return .schemaNotDeployed   // a server rejection anywhere wins
            case .network:
                sawTransient = true
            default:
                break
            }
        }
        // No server rejection found: don't false-alarm. Prefer a transient label
        // if we saw one, else fall back to the partial-failure description.
        return sawTransient ? .network : .unknown(ckError.localizedDescription)
    }

    /// Classify a per-item / nested error WITHOUT recursing back into
    /// `partialFailure` handling (avoids infinite mutual recursion and keeps the
    /// "is this a server rejection?" question crisp).
    private static func classifyNested(_ error: Error) -> SyncDegradation {
        if let ck = asCKError(error) {
            switch ck.code {
            case .serverRejectedRequest:
                return .schemaNotDeployed
            case .networkUnavailable, .networkFailure,
                 .serviceUnavailable, .requestRateLimited:
                return .network
            default:
                break
            }
            if isWrappedServerRejection(ck) {
                return .schemaNotDeployed
            }
        }
        if isWrappedServerRejection(error) {
            return .schemaNotDeployed
        }
        return .unknown(error.localizedDescription)
    }

    /// The outcome of folding one CloudKit phase event into sync state: the new
    /// health, the (possibly updated) last-success timestamp, and the running count
    /// of CONSECUTIVE failed END events the caller should retain. A pure value so the
    /// fold is unit-testable without CloudKit.
    ///
    /// `consecutiveFailures` is the debounce accumulator: it increments on each
    /// failed END, resets to 0 on any success, and is unchanged by START events.
    /// The caller stores it and feeds it back in on the next event.
    public struct Fold: Equatable, Sendable {
        public let health: SyncHealth
        public let lastSuccessfulSync: Date?
        public let consecutiveFailures: Int
        public init(health: SyncHealth, lastSuccessfulSync: Date?, consecutiveFailures: Int) {
            self.health = health
            self.lastSuccessfulSync = lastSuccessfulSync
            self.consecutiveFailures = consecutiveFailures
        }
    }

    /// How many CONSECUTIVE failed sync events must be observed before escalating to
    /// `.degraded`. A single failed event followed by a success keeps sync healthy —
    /// this debounces the transient "RecoverableImportError" (a CKError-2 partialFailure
    /// wrapping CKInternalErrorDomain 1011) that `NSPersistentCloudKitContainer` fires
    /// once on a cold launch and recovers from ~1s later, which otherwise false-alarms
    /// the "deploy your schema" banner. A genuine outage produces many consecutive
    /// failures and still surfaces (after the 2nd).
    public static let degradeFailureThreshold = 2

    /// Pure state-machine step for one CloudKit phase event, decoupled from
    /// `NSPersistentCloudKitContainer.Event` (which has no public initializer) so it
    /// can be tested with synthetic inputs. `AppModel.handleSyncEvent` reads the
    /// event's fields and delegates here.
    ///
    /// - Parameters:
    ///   - current: the current `syncHealth`.
    ///   - lastSuccess: the retained `lastSuccessfulSync`.
    ///   - consecutiveFailures: the retained running count of consecutive failed END
    ///     events (the debounce accumulator the caller fed back from the prior fold).
    ///   - isEnd: `false` for a START event (`endDate == nil`), `true` for an END.
    ///   - succeeded: the event's `succeeded` (only meaningful on END).
    ///   - degradation: the already-classified cause of a failed END (apply
    ///     `classify(_:)` to the event's `error` before calling), or `nil` if the
    ///     phase didn't fail. Pre-classifying keeps this fold free of the
    ///     non-Sendable `Error` so it crosses actors cleanly.
    ///   - endDate: the event's `endDate` (the success timestamp on a succeeded END).
    ///   - now: injected clock for the `since:` on a degraded transition (testable).
    ///
    /// **Debounce.** A failed END does NOT immediately escalate to `.degraded`. It
    /// increments `consecutiveFailures`; only once that reaches `degradeFailureThreshold`
    /// (2) — i.e. the 2nd *consecutive* failure with no intervening success — does the
    /// state go `.degraded`. A single failed event followed by a success keeps sync
    /// healthy, and any success resets the counter to 0 and clears `.degraded`. This
    /// stops a transient recoverable CKError (1011) on launch from false-alarming the
    /// schema banner while still surfacing a persistent outage (many consecutive fails).
    public static func fold(
        current: SyncHealth,
        lastSuccess: Date?,
        consecutiveFailures: Int,
        isEnd: Bool,
        succeeded: Bool,
        degradation: SyncDegradation?,
        endDate: Date?,
        now: Date = Date()
    ) -> Fold {
        if !isEnd {
            // START: advance to .syncing unless we're parked in .degraded (sticky
            // until a phase actually succeeds). The failure counter is untouched by
            // START events (only an END that succeeds or fails moves it).
            if case .degraded = current {
                return Fold(health: current, lastSuccessfulSync: lastSuccess,
                            consecutiveFailures: consecutiveFailures)
            }
            return Fold(health: .syncing, lastSuccessfulSync: lastSuccess,
                        consecutiveFailures: consecutiveFailures)
        }

        // END.
        if succeeded {
            // A success resets the debounce accumulator and clears any degraded state.
            let when = endDate ?? now
            return Fold(health: .idle(lastSuccess: when), lastSuccessfulSync: when,
                        consecutiveFailures: 0)
        }
        if let degradation {
            // Failed END: count it. Only escalate to .degraded once we've seen
            // `degradeFailureThreshold` consecutive failures with no success between —
            // a lone transient blip (count 1) keeps the current health.
            let failures = consecutiveFailures + 1
            if failures >= degradeFailureThreshold {
                return Fold(health: .degraded(degradation, since: now),
                            lastSuccessfulSync: lastSuccess,
                            consecutiveFailures: failures)
            }
            // Below threshold: don't flip the trust indicator yet. Preserve the
            // current health (an in-flight .syncing or prior .idle stays put).
            return Fold(health: current, lastSuccessfulSync: lastSuccess,
                        consecutiveFailures: failures)
        }
        // END with neither success nor a failure cause: leave state and counter
        // unchanged (this isn't a classified failure, so it doesn't debounce).
        return Fold(health: current, lastSuccessfulSync: lastSuccess,
                    consecutiveFailures: consecutiveFailures)
    }

    /// True if `error` (or its `underlyingError`) is a `CKInternalErrorDomain`
    /// code-1011 "server rejected request" — the signature of an undeployed
    /// schema reaching the Production environment.
    private static func isWrappedServerRejection(_ error: Error) -> Bool {
        // A real undeployed-schema rejection can be buried SEVERAL levels deep under
        // `NSUnderlyingErrorKey` (CloudKit re-wraps it as it bubbles up). Inspecting
        // only one level lets a deeper-nested 1011 fall through to `.unknown` instead
        // of the actionable `.schemaNotDeployed`. Walk the chain in a bounded loop.
        var current: NSError? = error as NSError
        var depth = 0
        let maxDepth = 4  // cap to stay O(1) and immune to pathological cycles.
        while let ns = current, depth < maxDepth {
            if ns.domain == ckInternalErrorDomain, ns.code == ckServerRejectedRequestCode {
                return true
            }
            current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return false
    }
}
