// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "HandheldNotes",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .executable(name: "HandheldNotes", targets: ["HandheldNotes"]),
        .library(name: "HandheldNotesCore", targets: ["HandheldNotesCore"])
    ],
    targets: [
        // Shared, platform-agnostic core: model, storage, transcription, mic
        // capture, theme tokens, and the observable AppModel. The iOS app links
        // this same target — it must NOT reference AppKit or Carbon (macOS-only);
        // those stay in the executable target below. Frameworks it uses (SwiftUI /
        // AVFoundation / Speech / SwiftData / CloudKit) are linked implicitly by
        // `import`, and all exist on both macOS and iOS, so no explicit (and
        // unconditional) linkerSettings are needed here.
        .target(
            name: "HandheldNotesCore",
            resources: [
                .copy("Resources/device-note-1.wav"),
                .copy("Resources/device-note-2.wav")
            ]
        ),
        // The macOS app: AppKit window/menu, the Carbon F16 hotkey, and all UI.
        .executableTarget(
            name: "HandheldNotes",
            dependencies: ["HandheldNotesCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon")
            ]
        ),
        .testTarget(
            name: "HandheldNotesCoreTests",
            dependencies: ["HandheldNotesCore"],
            resources: [
                // The committed golden schema fingerprint (F5 release gate). Bundled
                // so SchemaGoldenTests can read it via Bundle.module at runtime.
                .copy("Resources/schema.golden")
            ]
        )
    ]
)
