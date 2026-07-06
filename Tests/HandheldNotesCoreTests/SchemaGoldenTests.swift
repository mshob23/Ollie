import CryptoKit
import Foundation
import SwiftData
import XCTest
@testable import HandheldNotesCore

/// **F5 — golden schema fingerprint (the release gate that the June 2026 outage
/// would have caught).**
///
/// The outage's single root cause was a forgotten manual *"Deploy Schema Changes
/// to Production"* step in the CloudKit Dashboard: CloudKit **Development**
/// auto-creates record types/fields/indexes, but **Production never does**, so a
/// shipped build whose `@Model` had drifted hit internal error `1011` and every
/// write was rejected (see `docs/cloudkit-sync-troubleshooting.md` §1).
///
/// This test makes that class of mistake **loud at build time**: it serializes the
/// live SwiftData `Schema(NotesDataStore.modelTypes)` (every synced `@Model` — the
/// notes ground truth plus the agent-layer entities) to a deterministic, sorted
/// string, hashes it (SHA256), and compares against a committed golden value. The
/// moment any of those entities changes shape, the hash diverges and the test FAILS
/// with explicit instructions to (a) regenerate the golden and (b) deploy the
/// Production schema before release. A green run is the human-readable proof that
/// "the schema the code expects == the schema we last deployed."
///
/// The serialization is intentionally deterministic (entities and properties are
/// sorted by name) so it never churns between runs or machines, and it captures
/// only the wire-relevant shape — record-type name, and each property's name +
/// value type + optionality + uniqueness + attribute-vs-relationship — which is
/// exactly what CloudKit materializes as record types, fields and indexes.
final class SchemaGoldenTests: XCTestCase {

    /// The committed fingerprint of the schema that has been (or must be) deployed
    /// to the CloudKit **Production** environment. Regenerate this whenever any synced
    /// `@Model` in `NotesDataStore.modelTypes` legitimately changes — see
    /// ``regenerationInstructions`` and the failure message below. Keep it in sync
    /// with the checked-in
    /// `Tests/HandheldNotesCoreTests/Resources/schema.golden` file (both hold the
    /// same hash); the test prefers the file when present and falls back to this
    /// constant so the gate still works if the resource is ever stripped.
    static let goldenHash = "547fd122e54b9d05c32b1e375df447ba02a7eda877caa8ee0dd0d29393fcce43"

    func testSchemaMatchesDeployedGolden() {
        let fingerprint = Self.schemaFingerprint()
        let actual = Self.sha256(of: fingerprint)
        let expected = Self.expectedGoldenHash()

        // First run / placeholder: there is no real golden yet. Emit the values to
        // copy in rather than asserting against a sentinel.
        guard expected != "__PLACEHOLDER__" else {
            XCTFail(
                """
                No golden schema fingerprint committed yet. Set the golden to the \
                value below (and write Resources/schema.golden), then re-run.

                \(Self.regenerationInstructions(fingerprint: fingerprint, hash: actual))
                """)
            return
        }

        XCTAssertEqual(
            actual, expected,
            """

            ┌──────────────────────────────────────────────────────────────────────┐
            │ SCHEMA DRIFT DETECTED — the SwiftData NoteEntity no longer matches the  │
            │ schema fingerprint last deployed to CloudKit Production.                │
            └──────────────────────────────────────────────────────────────────────┘

            CloudKit Development auto-creates record types/fields/indexes, but
            Production NEVER does. Shipping this change WITHOUT deploying the schema
            reproduces the June 2026 outage (internal error 1011 — every write
            rejected, reads still served, so it looks half-working).

            Before this can ship you MUST do BOTH:

              (a) Regenerate the golden so this test passes:
            \(Self.regenerationInstructions(fingerprint: fingerprint, hash: actual))

              (b) Deploy the schema to PRODUCTION in the CloudKit Dashboard:
                  CloudKit Dashboard → container iCloud.com.mohammadshobaki.handheldnotes
                  → Deploy Schema Changes… → Deploy to Production.
                  (A "– Modified" badge on Record Types / Indexes means undeployed
                  changes exist.) Then set SCHEMA_DEPLOYED=1 for the release build.

            See docs/cloudkit-sync-troubleshooting.md §1 and RELEASE.md.
            """)
    }

    // MARK: - Deterministic fingerprint

    /// A STABLE, sorted, human-readable description of the SwiftData schema backing
    /// the synced store. Sorting both entities and their properties by name makes
    /// the output independent of declaration order / runtime ordering, so the hash
    /// only moves when the schema's *shape* actually changes.
    static func schemaFingerprint() -> String {
        // Fingerprint the FULL synced schema (notes ground truth + the agent-layer
        // entities), from the single source of truth so a new entity is captured
        // here automatically. Entities and properties are sorted below, so order in
        // `modelTypes` doesn't matter.
        let schema = Schema(NotesDataStore.modelTypes)
        var lines: [String] = ["schemaVersion=\(Note.currentSchemaVersion)"]

        for entity in schema.entities.sorted(by: { $0.name < $1.name }) {
            lines.append("record \(entity.name)")
            for property in entity.properties.sorted(by: { $0.name < $1.name }) {
                let kind = property.isAttribute ? "attribute" : "relationship"
                // `valueType` already renders optionals as `Optional<T>` and the
                // external-storage blob as its element type, which is exactly the
                // CloudKit-relevant field type. We normalize whitespace only.
                let type = String(describing: property.valueType)
                lines.append(
                    "  \(property.name): "
                    + "type=\(type) "
                    + "optional=\(property.isOptional) "
                    + "unique=\(property.isUnique) "
                    + "kind=\(kind)")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func sha256(of string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Reads the checked-in golden from `Tests/Resources/schema.golden` when the
    /// resource is bundled, otherwise falls back to ``goldenHash``. The file holds
    /// just the hex hash on its first non-comment line.
    static func expectedGoldenHash() -> String {
        if let url = Bundle.module.url(forResource: "schema", withExtension: "golden"),
           let contents = try? String(contentsOf: url, encoding: .utf8) {
            for raw in contents.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if !line.isEmpty && !line.hasPrefix("#") { return line }
            }
        }
        return goldenHash
    }

    static func regenerationInstructions(fingerprint: String, hash: String) -> String {
        """
                  • Set SchemaGoldenTests.goldenHash =
                      "\(hash)"
                  • Write Tests/HandheldNotesCoreTests/Resources/schema.golden with that same hash.
                  • The (debug-only) fingerprint this hash covers was:
            \(fingerprint.split(separator: "\n").map { "            \($0)" }.joined(separator: "\n"))
        """
    }
}
