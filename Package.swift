// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "HandheldNotes",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "HandheldNotes", targets: ["HandheldNotes"])
    ],
    targets: [
        .executableTarget(
            name: "HandheldNotes",
            resources: [
                .copy("Resources/device-note-1.wav"),
                .copy("Resources/device-note-2.wav")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("Speech")
            ]
        )
    ]
)
