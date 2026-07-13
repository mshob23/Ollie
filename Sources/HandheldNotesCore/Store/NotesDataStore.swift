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
    /// truth plus the agent layer (tags, memory, view revisions, instructions, and the
    /// Views v2 per-block interaction state). This is the SINGLE source of truth for
    /// the schema — the container factory, the store-URL derivation, and the tests all
    /// build `Schema` from this so a new entity is added in exactly one place. Any
    /// change here shifts the golden fingerprint (`SchemaGoldenTests`) by design;
    /// regenerate it and deploy the CloudKit Production schema before release (see
    /// RELEASE.md).
    public static let modelTypes: [any PersistentModel.Type] = [
        NoteEntity.self,
        TagEntity.self,
        MemoryEntity.self,
        ViewRevisionEntity.self,
        InstructionsEntity.self,
        InteractionStateEntity.self,
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
    @MainActor public static func makeContainer(
        inMemory: Bool = false,
        cloudKit: Bool = true,
        storeURL overrideURL: URL? = nil
    ) -> ModelContainer {
        let schema = Schema(modelTypes)

        if inMemory {
            let mem = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            // A purely in-memory store can't realistically fail; if it somehow
            // does there is nothing to fall back to, so fail loudly in tests.
            return try! ModelContainer(for: schema, configurations: [mem])
        }

        // A generic SwiftData `default.store` is process-global enough that two
        // sibling apps can open the same file when they share a hand-bundled
        // runtime. Ollie therefore owns one explicit URL. Never inspect, migrate,
        // rename, or delete a generic `default.store`; another app may own it.
        let url = overrideURL ?? storeURL()
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            Self.writeDiag("Store directory FAILED at \(url.deletingLastPathComponent().path): \(error)")
            fatalError("Ollie cannot safely create its persistent store directory")
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
        if cloudKit {
            let cloud = ModelConfiguration(
                "HandheldNotes", schema: schema, url: url,
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
        }

        // 2) Fallback: a normal on-disk store, no CloudKit. The app stays fully
        //    functional locally; this is what runs pre-portal and on the
        //    Simulator without an iCloud account.
        let local = ModelConfiguration(
            "HandheldNotes", schema: schema, url: url, cloudKitDatabase: .none)
        do {
            let container = try ModelContainer(for: schema, configurations: [local])
            isCloudKitActive = false
            return container
        } catch {
            Self.writeDiag("Persistent local store FAILED at \(url.path): \(error)")
            fatalError("Ollie cannot safely open its persistent local store")
        }
    }

    /// Ollie's private on-disk store URL. This is deliberately explicit and
    /// app-owned; no Ollie code may ever open SwiftData's generic `default.store`.
    public static func storeURL(
        baseDirectory: URL = defaultBaseDirectory()
    ) -> URL {
        baseDirectory.appendingPathComponent("HandheldNotes.store", isDirectory: false)
    }

    public static func defaultBaseDirectory() -> URL {
        guard let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            Self.writeDiag("Application Support lookup FAILED; refusing nonpersistent fallback")
            fatalError("Ollie cannot safely resolve Application Support")
        }
        return appSupport.appendingPathComponent("HandheldNotes", isDirectory: true)
    }

    /// Directory containing Ollie's explicit store and sidecars.
    public static func storeDirectory() -> URL? {
        storeURL().deletingLastPathComponent()
    }

    /// The on-disk store files SwiftData maintains for Ollie's explicit store: the main
    /// SQLite database plus its write-ahead-log and shared-memory companions.
    /// `resetSync()` deletes exactly these (and nothing else) to force SwiftData to
    /// rebuild a clean local store on the next launch.
    public static func storeFileURLs(storeURL url: URL = storeURL()) -> [URL] {
        [url, URL(fileURLWithPath: url.path + "-wal"), URL(fileURLWithPath: url.path + "-shm")]
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
