import Foundation
import SwiftData
import XCTest
@testable import HandheldNotesCore

/// Pins `Scripts/expected-ck-fields.txt` (the release gate's source of truth for
/// what the PRODUCTION CloudKit schema must contain) to the LIVE synced models —
/// `NoteEntity` plus the agent-layer entities (`TagEntity`, `MemoryEntity`,
/// `ViewRevisionEntity`, `InstructionsEntity`). If an attribute is added/renamed on
/// ANY of them without updating the tracked file, this fails — closing the loop:
///
///   models ⟷ (this test) ⟷ expected-ck-fields.txt ⟷ (verify-prod-schema.sh) ⟷ Production
///
/// The CD_ field names are unique across record types (each `@Model`'s attribute
/// names are distinct enough), so one flat `CD_<field>` set covers every record type
/// the container mirrors — matching how CloudKit names fields under each `CD_<Entity>`.
///
/// Rules encoded here (from two production outages):
///  - every stored attribute `x` on any synced model → `CD_x`
///  - every `Data` attribute ALSO gets its lazily-materialized CKAsset twin
///    `CD_x_ckAsset` (CoreData+CloudKit switches from inline bytes to an Asset
///    past a size threshold; Production REJECTS the unknown field and the whole
///    export wedges — the July 2026 outage).
final class CKFieldCoverageTests: XCTestCase {

    func testTrackedFieldFileMatchesTheModel() throws {
        // Derive the required CK field set from the full synced schema itself.
        let schema = Schema(NotesDataStore.modelTypes)

        var derived = Set<String>()
        for entity in schema.entities {
            for attribute in entity.attributes {
                derived.insert("CD_\(attribute.name)")
                // Data (or Data?) attributes get the CKAsset twin.
                let typeName = String(describing: attribute.valueType)
                if typeName == "Data" || typeName == "Optional<Data>" {
                    derived.insert("CD_\(attribute.name)_ckAsset")
                }
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
            Scripts/expected-ck-fields.txt is out of sync with the synced models.
              missing from file:  \(derived.subtracting(tracked).sorted())
              stale in file:      \(tracked.subtracting(derived).sorted())
            After updating the file, add the field(s) in the CloudKit Dashboard's
            Development schema and Deploy Schema Changes to Production.
            """)
    }
}
