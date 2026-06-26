import Foundation

/// Locates the bundled demo WAVs. SwiftPM exposes them through `Bundle.module`;
/// when running from the hand-assembled .app, the build script copies the
/// generated resource bundle into `Contents/Resources`, and `Bundle.module`
/// still resolves it. As a final fallback we scan the main bundle's Resources.
enum SampleAudio {
    /// The two voice notes the mock device "syncs". Returned in a stable order.
    static let deviceNoteNames = ["device-note-1", "device-note-2"]

    static func url(named name: String) -> URL? {
        if let url = Bundle.module.url(forResource: name, withExtension: "wav") {
            return url
        }
        // Fallbacks for unusual bundle layouts.
        if let url = Bundle.main.url(forResource: name, withExtension: "wav") {
            return url
        }
        let resourceBundleName = "HandheldNotes_HandheldNotes.bundle"
        if let resURL = Bundle.main.resourceURL?
            .appendingPathComponent(resourceBundleName),
           let bundle = Bundle(url: resURL),
           let url = bundle.url(forResource: name, withExtension: "wav") {
            return url
        }
        return nil
    }

    static func deviceNoteURLs() -> [URL] {
        deviceNoteNames.compactMap { url(named: $0) }
    }
}
