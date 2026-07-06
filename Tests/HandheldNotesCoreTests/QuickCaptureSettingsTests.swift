import Foundation
import XCTest
@testable import HandheldNotesCore

/// The Quick Capture shortcut settings have a subtle persistence contract: an OLDER
/// settings file (key absent) must yield the DEFAULT binding, while an explicitly
/// CLEARED shortcut (key present as null) must stay cleared. These pin both, plus
/// the plain round-trip.
final class QuickCaptureSettingsTests: XCTestCase {

    func testOlderSettingsFileGetsDefaultShortcuts() throws {
        // A pre-Quick-Capture settings.json: no shortcut keys at all.
        let old = #"{"transcriptionEngineID":"appleSpeech","hasSeededDemo":true}"#
        let s = try JSONDecoder().decode(NotesSettings.self, from: Data(old.utf8))
        XCTAssertEqual(s.holdToDictateShortcut?.display, "F16")
        XCTAssertEqual(s.toggleDictationShortcut?.display, "F15")
        XCTAssertEqual(s.quickPadShortcut?.display, "F14")
        XCTAssertFalse(s.confirmQuickCaptureBeforeSaving)
    }

    func testClearedShortcutStaysClearedAcrossSaveLoad() throws {
        var s = NotesSettings()
        s.holdToDictateShortcut = nil            // user cleared it
        let data = try JSONEncoder().encode(s)
        // The cleared key must be PRESENT as null (not omitted), else a reload
        // would silently resurrect the default binding.
        let raw = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(raw.contains("\"holdToDictateShortcut\":null"))
        let back = try JSONDecoder().decode(NotesSettings.self, from: data)
        XCTAssertNil(back.holdToDictateShortcut, "cleared must stay cleared")
        XCTAssertEqual(back.toggleDictationShortcut?.display, "F15", "others keep defaults")
    }

    func testCustomShortcutRoundTrips() throws {
        var s = NotesSettings()
        s.toggleDictationShortcut = KeyShortcut(keyCode: 49, carbonModifiers: 2048 | 4096,
                                                display: "⌃⌥Space")
        s.confirmQuickCaptureBeforeSaving = true
        let back = try JSONDecoder().decode(NotesSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.toggleDictationShortcut,
                       KeyShortcut(keyCode: 49, carbonModifiers: 6144, display: "⌃⌥Space"))
        XCTAssertTrue(back.confirmQuickCaptureBeforeSaving)
    }

    // MARK: - pinnedViewName (M5 5e: per-device Views-feed pin)

    /// An older settings file (no `pinnedViewName` key) tolerant-decodes to nil —
    /// nothing pinned — without disturbing the other keys.
    func testOlderSettingsFileHasNoPinnedView() throws {
        let old = #"{"transcriptionEngineID":"appleSpeech","hasSeededDemo":true}"#
        let s = try JSONDecoder().decode(NotesSettings.self, from: Data(old.utf8))
        XCTAssertNil(s.pinnedViewName, "absent key → nothing pinned")
    }

    /// A pinned view name round-trips, and is OMITTED (not written as null) when nil so
    /// the settings file stays clean — mirroring `microphoneName`'s `encodeIfPresent`.
    func testPinnedViewNameRoundTripsAndOmitsWhenNil() throws {
        var s = NotesSettings()
        XCTAssertNil(s.pinnedViewName)
        // nil → key omitted.
        let emptyRaw = String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
        XCTAssertFalse(emptyRaw.contains("pinnedViewName"),
                       "an unset pin should not be written at all")
        // Set → round-trips.
        s.pinnedViewName = "Open loops"
        let back = try JSONDecoder().decode(NotesSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.pinnedViewName, "Open loops")
    }
}
