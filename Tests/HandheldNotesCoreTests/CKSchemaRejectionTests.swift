import CloudKit
import Foundation
import XCTest
@testable import HandheldNotesCore

/// Regression tests for the July 2026 outage signature: CloudKit "Invalid
/// Arguments" (12/2006) whose server message names a field missing from the
/// PRODUCTION schema ("Cannot create or modify field 'CD_x' … in production
/// schema") — the shape a lazily-materialized field (e.g. a Data attribute's
/// `_ckAsset` twin) takes when it hits Production. Must classify as
/// `.schemaNotDeployed` so the Settings row/banners name the actual fix.
final class CKSchemaRejectionTests: XCTestCase {

    /// The real per-item error observed on-device during the outage (shape-wise).
    private func productionSchemaRejection() -> NSError {
        NSError(
            domain: CKError.errorDomain,
            code: CKError.Code.invalidArguments.rawValue,
            userInfo: [
                NSLocalizedDescriptionKey: "Invalid Arguments",
                "ServerErrorDescription":
                    "Cannot create or modify field 'CD_audioData_ckAsset' in record 'CD_NoteEntity' in production schema",
            ])
    }

    func testDirectProductionSchemaRejectionClassifiesAsSchemaNotDeployed() {
        XCTAssertEqual(SyncHealth.classify(productionSchemaRejection()), .schemaNotDeployed)
    }

    func testPartialFailureWrappingProductionSchemaRejectionClassifies() {
        // On-device, the per-item 12/2006 arrives wrapped in a CKError 2
        // (partialFailure) — exactly what handleSyncEvent sees.
        let itemID = CKRecord.ID(recordName: "CB156521-94D2-4DF6-8A05-6BCFE6B6900A")
        let partial = NSError(
            domain: CKError.errorDomain,
            code: CKError.Code.partialFailure.rawValue,
            userInfo: [CKPartialErrorsByItemIDKey: [itemID: productionSchemaRejection()]])
        XCTAssertEqual(SyncHealth.classify(partial), .schemaNotDeployed)
    }

    /// The M7 record type: if `CD_InteractionStateEntity` (or any of its 6 new
    /// fields, e.g. `CD_blockId`) hits Production before the schema is deployed, the
    /// same 12/2006 signature must still classify as `.schemaNotDeployed` — the new
    /// entity is not special-cased.
    private func interactionStateSchemaRejection() -> NSError {
        NSError(
            domain: CKError.errorDomain,
            code: CKError.Code.invalidArguments.rawValue,
            userInfo: [
                NSLocalizedDescriptionKey: "Invalid Arguments",
                "ServerErrorDescription":
                    "Cannot create or modify field 'CD_blockId' in record 'CD_InteractionStateEntity' in production schema",
            ])
    }

    func testInteractionStateProductionSchemaRejectionClassifiesAsSchemaNotDeployed() {
        XCTAssertEqual(SyncHealth.classify(interactionStateSchemaRejection()), .schemaNotDeployed)
    }

    func testPlainInvalidArgumentsIsNotASchemaAlarm() {
        // CONSERVATISM: invalidArguments without the schema server-message must NOT
        // false-alarm the "deploy your schema" banner (it has non-schema causes).
        let plain = NSError(
            domain: CKError.errorDomain,
            code: CKError.Code.invalidArguments.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Invalid Arguments"])
        XCTAssertNotEqual(SyncHealth.classify(plain), .schemaNotDeployed)
    }
}
