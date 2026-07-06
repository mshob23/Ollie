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

    /// The full set of `@Model` types the synced store mirrors: the notes ground
    /// truth plus the agent layer (tags, memory, view revisions, instructions). This
    /// is the SINGLE source of truth for the schema — the container factory, the
    /// store-URL derivation, and the tests all build `Schema` from this so a new
    /// entity is added in exactly one place. Any change here shifts the golden
    /// fingerprint (`SchemaGoldenTests`) by design; regenerate it and deploy the
    /// CloudKit Production schema before release (see RELEASE.md).
    public static let modelTypes: [any PersistentModel.Type] = [
        NoteEntity.self,
        TagEntity.self,
        MemoryEntity.self,
        ViewRevisionEntity.self,
        InstructionsEntity.self,
    ]

    /// True if the live container ended up CloudKit-backed (vs. the local
    /// fallback). Surfaced for diagnostics / a Settings indicator; never gates
    /// behavior — the app works identically either way. `@MainActor` because it's
    /// written from `makeContainer` (called during the `@MainActor` `AppModel`
    /// init) and read from the UI.
    @MainActor public private(set) static var isCloudKitActive = false

    /// The process-wide shared container, created once on first access. BOTH the
    /// app (`AppModel`) and the App Intents / Spotlight code read through this one
    /// container, so a background-launched intent never opens a competing CloudKit
    /// store on the same file. (Tests pass `inMemory: true` to `makeContainer`
    /// directly instead of touching this.)
    @MainActor public static let shared: ModelContainer = makeContainer(inMemory: false)

    /// Build (once) the shared container. Prefers private-CloudKit mirroring and
    /// degrades to a local-only store if that can't be constructed. `inMemory`
    /// is for tests.
    @MainActor public static func makeContainer(inMemory: Bool = false) -> ModelContainer {
        let schema = Schema(modelTypes)

        if inMemory {
            let mem = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            // A purely in-memory store can't realistically fail; if it somehow
            // does there is nothing to fall back to, so fail loudly in tests.
            return try! ModelContainer(for: schema, configurations: [mem])
        }

        // 1) Preferred: the user's PRIVATE iCloud database. Inert (but harmless)
        //    until the portal container + signing profile exist.
        //
        //    Pointing a `ModelConfiguration` at a CloudKit database turns on the
        //    mirroring machinery, which transparently enables persistent history
        //    AND the `.NSPersistentStoreRemoteChange` notification — that's the
        //    signal `AppModel.observeRemoteChanges()` listens for to live-refresh
        //    when another device's edits sync in. There is no separate switch to
        //    flip (SwiftData's `ModelConfiguration` exposes no remote-change
        //    option; it's implied by CloudKit mirroring), so nothing extra is set
        //    here.
        let cloud = ModelConfiguration(
            schema: schema,
            cloudKitDatabase: .private(cloudKitContainerID))
        do {
            let container = try ModelContainer(for: schema, configurations: [cloud])
            isCloudKitActive = true
            Self.writeDiag("CloudKit ACTIVE — \(cloudKitContainerID)")
            return container
        } catch {
            // Don't swallow silently — record WHY CloudKit couldn't start so a
            // signing/entitlement/account problem is diagnosable.
            Self.writeDiag("CloudKit FAILED, using local fallback — \(String(describing: error))")
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

    /// The directory that holds the on-disk SwiftData store files (`default.store`
    /// + its `-wal` / `-shm` companions). SwiftData, when handed a
    /// `ModelConfiguration` with no explicit URL, writes them into the app's
    /// Application Support directory under the default store name. `resetSync()`
    /// needs this to delete the local store as part of the CLI-equivalent recovery.
    ///
    /// Derived from a throwaway `ModelConfiguration` so it tracks SwiftData's own
    /// default-URL choice rather than hard-coding a path: `config.url` is the
    /// `…/default.store` file URL; its parent directory is what we return. Returns
    /// `nil` only if SwiftData yields no URL (it always does for an on-disk config).
    public static func storeDirectory() -> URL? {
        let schema = Schema(modelTypes)
        let config = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
        return config.url.deletingLastPathComponent()
    }

    /// The on-disk store files SwiftData maintains for the default store: the main
    /// SQLite database plus its write-ahead-log and shared-memory companions.
    /// `resetSync()` deletes exactly these (and nothing else) to force SwiftData to
    /// rebuild a clean local store on the next launch.
    public static func storeFileURLs() -> [URL] {
        guard let dir = storeDirectory() else { return [] }
        return ["default.store", "default.store-wal", "default.store-shm"]
            .map { dir.appendingPathComponent($0) }
    }

    /// Record the CloudKit-vs-local outcome to the unified log (tagged `HNDIAG` so
    /// it's greppable via `log show --predicate 'eventMessage CONTAINS "HNDIAG"'`).
    /// Keep this: a future signing/entitlement/account regression silently drops the
    /// app to the local store, and this line is the fastest way to catch it.
    ///
    /// Routes through `Diag` (os.Logger) rather than `NSLog` — on this machine
    /// `NSLog` output is NOT visible to `log show`, so the breadcrumb was being
    /// lost. See `Diag` for the rationale.
    static func writeDiag(_ message: String) {
        Diag.log("HNDIAG \(message)")
    }
}
