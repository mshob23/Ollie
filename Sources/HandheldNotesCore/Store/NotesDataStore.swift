import Foundation
import SwiftData

/// Owns the SwiftData `ModelContainer` that backs the notes library and the
/// CloudKit-vs-local decision. The Mac app, the iPhone app, and (via the phone)
/// the watch all point at the SAME private-iCloud container, so one user's notes
/// converge across every device.
///
/// **Graceful degradation is the whole point of this type.** The CloudKit
/// container only works once the user has created the matching iCloud container
/// in the Apple Developer portal *and* the app is signed with a profile that
/// carries the iCloud entitlement. Until then (and on the Simulator, in unit
/// tests, or for any signing/entitlement hiccup) we must STILL launch with a
/// working local store. So we *try* CloudKit and fall back to a plain local
/// store — the app is always usable, sync simply lights up later with no code
/// change once the portal side exists.
public enum NotesDataStore {

    /// The private-iCloud container identifier. Must match the entitlement files
    /// (`com.apple.developer.icloud-container-identifiers`) in both apps and the
    /// container the user creates in the Developer portal.
    public static let cloudKitContainerID = "iCloud.com.mohammadshobaki.handheldnotes"

    /// True if the live container ended up CloudKit-backed (vs. the local
    /// fallback). Surfaced for diagnostics / a Settings indicator; never gates
    /// behavior — the app works identically either way. `@MainActor` because it's
    /// written from `makeContainer` (called during the `@MainActor` `AppModel`
    /// init) and read from the UI.
    @MainActor public private(set) static var isCloudKitActive = false

    /// Build (once) the shared container. Prefers private-CloudKit mirroring and
    /// degrades to a local-only store if that can't be constructed. `inMemory`
    /// is for tests.
    @MainActor public static func makeContainer(inMemory: Bool = false) -> ModelContainer {
        let schema = Schema([NoteEntity.self])

        if inMemory {
            let mem = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            // A purely in-memory store can't realistically fail; if it somehow
            // does there is nothing to fall back to, so fail loudly in tests.
            return try! ModelContainer(for: schema, configurations: [mem])
        }

        // 1) Preferred: the user's PRIVATE iCloud database. Inert (but harmless)
        //    until the portal container + signing profile exist.
        let cloud = ModelConfiguration(
            schema: schema,
            cloudKitDatabase: .private(cloudKitContainerID))
        if let container = try? ModelContainer(for: schema, configurations: [cloud]) {
            isCloudKitActive = true
            return container
        }

        // 2) Fallback: a normal on-disk store, no CloudKit. The app stays fully
        //    functional locally; this is what runs pre-portal and on the
        //    Simulator without an iCloud account.
        let local = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
        if let container = try? ModelContainer(for: schema, configurations: [local]) {
            isCloudKitActive = false
            return container
        }

        // 3) Last-ditch: in-memory, so the app can never be bricked by a storage
        //    failure (notes won't persist, but it launches and runs).
        isCloudKitActive = false
        let mem = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try! ModelContainer(for: schema, configurations: [mem])
    }
}
