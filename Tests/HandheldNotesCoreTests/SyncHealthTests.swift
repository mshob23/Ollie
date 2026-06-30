import CloudKit
import Foundation
import XCTest
@testable import HandheldNotesCore

/// Unit tests for the sync-observability backbone: the pure error classifier
/// (`SyncHealth.classify`) and the pure event-fold state machine
/// (`SyncHealth.fold`). No real CloudKit container is needed — both are pure
/// functions fed synthetic `CKError`s / fields.
final class SyncHealthTests: XCTestCase {

    // MARK: classify(_:)

    /// A bare `.notAuthenticated` → account unavailable (the user must sign in).
    func testNotAuthenticatedClassifiesAsAccountUnavailable() {
        let error = CKError(.notAuthenticated)
        XCTAssertEqual(SyncHealth.classify(error), .accountUnavailable)
    }

    func testManagedAndTemporarilyUnavailableClassifyAsAccount() {
        XCTAssertEqual(SyncHealth.classify(CKError(.managedAccountRestricted)), .accountUnavailable)
        XCTAssertEqual(SyncHealth.classify(CKError(.accountTemporarilyUnavailable)), .accountUnavailable)
    }

    /// `.networkUnavailable` → network (transient).
    func testNetworkUnavailableClassifiesAsNetwork() {
        XCTAssertEqual(SyncHealth.classify(CKError(.networkUnavailable)), .network)
    }

    func testNetworkFailureAndServiceUnavailableAndRateLimitClassifyAsNetwork() {
        XCTAssertEqual(SyncHealth.classify(CKError(.networkFailure)), .network)
        XCTAssertEqual(SyncHealth.classify(CKError(.serviceUnavailable)), .network)
        XCTAssertEqual(SyncHealth.classify(CKError(.requestRateLimited)), .network)
    }

    /// `.quotaExceeded` → quota.
    func testQuotaExceededClassifiesAsQuota() {
        XCTAssertEqual(SyncHealth.classify(CKError(.quotaExceeded)), .quota)
    }

    /// A direct `.serverRejectedRequest` → schema-not-deployed.
    func testServerRejectedRequestClassifiesAsSchemaNotDeployed() {
        XCTAssertEqual(SyncHealth.classify(CKError(.serverRejectedRequest)), .schemaNotDeployed)
    }

    /// A `.partialFailure` whose per-item error is an internal "server rejected"
    /// (CKInternalErrorDomain code 1011) → schema-not-deployed. This is the real
    /// shape an undeployed Production schema takes through NSPersistentCloudKitContainer.
    func testPartialFailureWrappingInternalRejectionClassifiesAsSchemaNotDeployed() {
        let internalReject = NSError(
            domain: "CKInternalErrorDomain", code: 1011,
            userInfo: [NSLocalizedDescriptionKey: "server rejected request"])
        let itemID = CKRecord.ID(recordName: "rec-1")
        let partial = CKError(
            .partialFailure,
            userInfo: [CKPartialErrorsByItemIDKey: [itemID: internalReject]])
        XCTAssertEqual(SyncHealth.classify(partial), .schemaNotDeployed)
    }

    /// A `.partialFailure` whose per-item error wraps the internal 1011 rejection
    /// TWO levels deep under `NSUnderlyingErrorKey` must STILL classify as
    /// schema-not-deployed. CloudKit re-wraps the real rejection as it bubbles up, so
    /// the chain walk has to descend past a single level — a one-level peek would let
    /// this degrade to `.unknown` and hide the actionable "deploy your schema" signal.
    func testPartialFailureWrappingDoublyNestedInternalRejectionClassifiesAsSchemaNotDeployed() {
        let deepReject = NSError(
            domain: "CKInternalErrorDomain", code: 1011,
            userInfo: [NSLocalizedDescriptionKey: "server rejected request"])
        let middle = NSError(
            domain: "CKErrorDomain", code: 2,
            userInfo: [NSUnderlyingErrorKey: deepReject])
        let outer = NSError(
            domain: "CKErrorDomain", code: 2,
            userInfo: [NSUnderlyingErrorKey: middle])
        let itemID = CKRecord.ID(recordName: "rec-deep")
        let partial = CKError(
            .partialFailure,
            userInfo: [CKPartialErrorsByItemIDKey: [itemID: outer]])
        XCTAssertEqual(SyncHealth.classify(partial), .schemaNotDeployed,
                       "a doubly-nested 1011 must walk the underlying-error chain")
    }

    /// A `.partialFailure` whose per-item errors are all TRANSIENT must NOT be
    /// reported as a schema problem — false "deploy your schema" alarms are as bad
    /// as silence. It should reduce to `.network`.
    func testPartialFailureOfTransientErrorsIsNotSchemaNotDeployed() {
        let itemID = CKRecord.ID(recordName: "rec-2")
        let networkItem = CKError(.networkUnavailable)
        let partial = CKError(
            .partialFailure,
            userInfo: [CKPartialErrorsByItemIDKey: [itemID: networkItem]])
        let result = SyncHealth.classify(partial)
        XCTAssertNotEqual(result, .schemaNotDeployed)
        XCTAssertEqual(result, .network)
    }

    /// CRITICAL invariant: a transient network / rate-limit error must NEVER
    /// classify as schemaNotDeployed (the whole point of the conservative mapping).
    func testTransientErrorsNeverClassifyAsSchemaNotDeployed() {
        for ck in [CKError(.networkUnavailable),
                   CKError(.networkFailure),
                   CKError(.serviceUnavailable),
                   CKError(.requestRateLimited)] {
            XCTAssertNotEqual(SyncHealth.classify(ck), .schemaNotDeployed,
                              "transient \(ck.code) must not be a schema alarm")
        }
    }

    /// A generic non-CloudKit `NSError` → unknown, carrying its description.
    func testGenericErrorClassifiesAsUnknown() {
        let error = NSError(
            domain: "com.example.whatever", code: 42,
            userInfo: [NSLocalizedDescriptionKey: "something odd"])
        XCTAssertEqual(SyncHealth.classify(error), .unknown("something odd"))
    }

    // MARK: userMessage

    func testUserMessagesAreActionable() {
        XCTAssertTrue(SyncDegradation.schemaNotDeployed.userMessage.contains("CloudKit Dashboard"))
        XCTAssertEqual(SyncDegradation.accountUnavailable.userMessage, "Not syncing - sign in to iCloud.")
        XCTAssertEqual(SyncDegradation.network.userMessage, "Sync paused - waiting for network.")
        XCTAssertEqual(SyncDegradation.quota.userMessage, "Not syncing - iCloud storage full.")
        XCTAssertEqual(SyncDegradation.unknown("raw text").userMessage, "raw text")
    }

    // MARK: fold(...) — event-fold transitions

    /// A START event (endDate == nil) from idle → .syncing. The failure counter is
    /// untouched by START events.
    func testStartEventTransitionsToSyncing() {
        let fold = SyncHealth.fold(
            current: .idle(lastSuccess: nil), lastSuccess: nil,
            consecutiveFailures: 0,
            isEnd: false, succeeded: false, degradation: nil, endDate: nil)
        XCTAssertEqual(fold.health, .syncing)
        XCTAssertNil(fold.lastSuccessfulSync)
        XCTAssertEqual(fold.consecutiveFailures, 0)
    }

    /// A succeeded import-END yields `.idle` with lastSuccess set to the end date.
    func testSucceededImportEndYieldsIdleWithLastSuccess() {
        let end = Date(timeIntervalSince1970: 2_000_000)
        let fold = SyncHealth.fold(
            current: .syncing, lastSuccess: nil,
            consecutiveFailures: 0,
            isEnd: true, succeeded: true, degradation: nil, endDate: end)
        XCTAssertEqual(fold.health, .idle(lastSuccess: end))
        XCTAssertEqual(fold.lastSuccessfulSync, end)
        XCTAssertEqual(fold.consecutiveFailures, 0)
    }

    // MARK: fold(...) — debounced degraded escalation

    /// DEBOUNCE: a single failed END (the 1st consecutive failure) must NOT escalate
    /// to `.degraded`. It only bumps the failure counter to 1 and preserves the
    /// current health. This is the transient recoverable CKError-1011 on cold launch
    /// that recovers ~1s later — it must stay healthy and never fire the schema banner.
    func testSingleFailedEndDoesNotDegrade() {
        let now = Date(timeIntervalSince1970: 3_000_000)
        let degradation = SyncHealth.classify(CKError(.serverRejectedRequest))
        XCTAssertEqual(degradation, .schemaNotDeployed)  // would-be banner cause
        let fold = SyncHealth.fold(
            current: .syncing, lastSuccess: nil,
            consecutiveFailures: 0,
            isEnd: true, succeeded: false, degradation: degradation,
            endDate: now, now: now)
        // Still healthy (in-flight syncing preserved), NOT degraded.
        XCTAssertEqual(fold.health, .syncing)
        XCTAssertEqual(fold.consecutiveFailures, 1)
    }

    /// DEBOUNCE (case a): one failed event THEN a successful event → sync stays
    /// healthy (`.idle`), the counter resets to 0, and no degraded banner is fired.
    func testFailureThenSuccessStaysHealthy() {
        let now = Date(timeIntervalSince1970: 3_000_000)
        // 1st failure: counter → 1, still .syncing (not degraded).
        let failDeg = SyncHealth.classify(CKError(.serverRejectedRequest))
        let afterFail = SyncHealth.fold(
            current: .syncing, lastSuccess: nil,
            consecutiveFailures: 0,
            isEnd: true, succeeded: false, degradation: failDeg,
            endDate: now, now: now)
        XCTAssertEqual(afterFail.health, .syncing)
        XCTAssertEqual(afterFail.consecutiveFailures, 1)

        // Success: feeds the running count back in; resets to 0 and goes idle.
        let end = Date(timeIntervalSince1970: 3_000_500)
        let afterSuccess = SyncHealth.fold(
            current: afterFail.health, lastSuccess: afterFail.lastSuccessfulSync,
            consecutiveFailures: afterFail.consecutiveFailures,
            isEnd: true, succeeded: true, degradation: nil, endDate: end)
        XCTAssertEqual(afterSuccess.health, .idle(lastSuccess: end))
        XCTAssertEqual(afterSuccess.lastSuccessfulSync, end)
        XCTAssertEqual(afterSuccess.consecutiveFailures, 0)
        // Crucially never .degraded.
        if case .degraded = afterSuccess.health {
            XCTFail("a failure followed by a success must not be degraded")
        }
    }

    /// DEBOUNCE (case b): two CONSECUTIVE failed events (no success between) → the
    /// 2nd escalates to `.degraded` with the correct classification. A persistent
    /// outage (the real June incident produced many consecutive fails) still surfaces.
    func testTwoConsecutiveFailuresDegrade() {
        let t1 = Date(timeIntervalSince1970: 3_000_000)
        let degradation = SyncHealth.classify(CKError(.serverRejectedRequest))
        let afterFirst = SyncHealth.fold(
            current: .syncing, lastSuccess: nil,
            consecutiveFailures: 0,
            isEnd: true, succeeded: false, degradation: degradation,
            endDate: t1, now: t1)
        XCTAssertEqual(afterFirst.health, .syncing, "1st failure debounced")
        XCTAssertEqual(afterFirst.consecutiveFailures, 1)

        let t2 = Date(timeIntervalSince1970: 3_000_001)
        let afterSecond = SyncHealth.fold(
            current: afterFirst.health, lastSuccess: afterFirst.lastSuccessfulSync,
            consecutiveFailures: afterFirst.consecutiveFailures,
            isEnd: true, succeeded: false, degradation: degradation,
            endDate: t2, now: t2)
        XCTAssertEqual(afterSecond.health, .degraded(.schemaNotDeployed, since: t2),
                       "2nd consecutive failure escalates to degraded")
        XCTAssertEqual(afterSecond.consecutiveFailures, 2)
    }

    /// DEBOUNCE (case c): failure, failure (→ degraded), then success → back to
    /// `.idle` with the degraded state cleared and the counter reset to 0.
    func testFailureFailureThenSuccessRecovers() {
        let degradation = SyncHealth.classify(CKError(.quotaExceeded))
        let t1 = Date(timeIntervalSince1970: 3_000_000)
        let f1 = SyncHealth.fold(
            current: .syncing, lastSuccess: nil,
            consecutiveFailures: 0,
            isEnd: true, succeeded: false, degradation: degradation,
            endDate: t1, now: t1)
        let t2 = Date(timeIntervalSince1970: 3_000_001)
        let f2 = SyncHealth.fold(
            current: f1.health, lastSuccess: f1.lastSuccessfulSync,
            consecutiveFailures: f1.consecutiveFailures,
            isEnd: true, succeeded: false, degradation: degradation,
            endDate: t2, now: t2)
        XCTAssertEqual(f2.health, .degraded(.quota, since: t2))
        XCTAssertEqual(f2.consecutiveFailures, 2)

        // Recovery.
        let end = Date(timeIntervalSince1970: 3_000_500)
        let s = SyncHealth.fold(
            current: f2.health, lastSuccess: f2.lastSuccessfulSync,
            consecutiveFailures: f2.consecutiveFailures,
            isEnd: true, succeeded: true, degradation: nil, endDate: end)
        XCTAssertEqual(s.health, .idle(lastSuccess: end))
        XCTAssertEqual(s.lastSuccessfulSync, end)
        XCTAssertEqual(s.consecutiveFailures, 0)
    }

    /// A success CLEARS a prior degraded state (degraded is sticky only until a
    /// phase actually succeeds) and resets the failure counter.
    func testSuccessClearsPriorDegraded() {
        let priorDegradedSince = Date(timeIntervalSince1970: 1_000)
        let end = Date(timeIntervalSince1970: 5_000)
        let fold = SyncHealth.fold(
            current: .degraded(.network, since: priorDegradedSince),
            lastSuccess: nil,
            consecutiveFailures: 2,
            isEnd: true, succeeded: true, degradation: nil, endDate: end)
        XCTAssertEqual(fold.health, .idle(lastSuccess: end))
        XCTAssertEqual(fold.lastSuccessfulSync, end)
        XCTAssertEqual(fold.consecutiveFailures, 0)
    }

    /// While degraded, a START event must NOT flap back to `.syncing` (that would
    /// hide a live failure behind an in-flight retry). The state and counter stay put.
    func testStartWhileDegradedStaysDegraded() {
        let since = Date(timeIntervalSince1970: 1_000)
        let fold = SyncHealth.fold(
            current: .degraded(.schemaNotDeployed, since: since),
            lastSuccess: nil,
            consecutiveFailures: 2,
            isEnd: false, succeeded: false, degradation: nil, endDate: nil)
        XCTAssertEqual(fold.health, .degraded(.schemaNotDeployed, since: since))
        XCTAssertEqual(fold.consecutiveFailures, 2)
    }
}
