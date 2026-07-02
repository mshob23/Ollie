import Foundation
import SwiftData
import XCTest
@testable import HandheldNotesCore

/// Pins `Scripts/expected-ck-fields.txt` (the release gate's source of truth for
/// what the PRODUCTION CloudKit schema must contain) to the LIVE `NoteEntity`
/// model. If an attribute is added/renamed without updating the tracked file,
/// this fails — closing the loop:
///
///   model ⟷ (this test) ⟷ expected-ck-fields.txt ⟷ (verify-prod-schema.sh) ⟷ Production
///
/// Rules encoded here (from two production outages):
///  - every stored attribute `x` → `CD_x`
///  - every `Data` attribute ALSO gets its lazily-materialized CKAsset twin
///    `CD_x_ckAsset` (CoreData+CloudKit switches from inline bytes to an Asset
///    past a size threshold; Production REJECTS the unknown field and the whole
///    export wedges — the July 2026 outage).
final class CKFieldCoverageTests: XCTestCase {

    func testTrackedFieldFileMatchesTheModel() throws {
        // Derive the required CK field set from the model itself.
        let schema = Schema([NoteEntity.self])
        let entity = try XCTUnwrap(
            schema.entities.first { $0.name == "NoteEntity" },
            "NoteEntity missing from the SwiftData schema")

        var derived = Set<String>()
        for attribute in entity.attributes {
            derived.insert("CD_\(attribute.name)")
            // Data (or Data?) attributes get the CKAsset twin.
            let typeName = String(describing: attribute.valueType)
            if typeName == "Data" || typeName == "Optional<Data>" {
                derived.insert("CD_\(attribute.name)_ckAsset")
            }
        }

        // Read the tracked file (repo-relative from this source file's location).
        let fileURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // HandheldNotesCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Scripts/expected-ck-fields.txt")
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        let tracked = Set(
            contents.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") })

        XCTAssertEqual(
            tracked, derived,
            """
            Scripts/expected-ck-fields.txt is out of sync with NoteEntity.
              missing from file:  \(derived.subtracting(tracked).sorted())
              stale in file:      \(tracked.subtracting(derived).sorted())
            After updating the file, add the field(s) in the CloudKit Dashboard's
            Development schema and Deploy Schema Changes to Production.
            """)
    }
}
