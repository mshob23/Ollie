import Foundation

/// A user-assignable global keyboard shortcut: a macOS virtual key code plus
/// Carbon modifier bits, with the display string captured at record time (so we
/// never need to reverse-map a key code to a glyph). Pure data — lives in Core so
/// `NotesSettings` can persist it — while registration (Carbon) stays in the Mac
/// app target.
public struct KeyShortcut: Codable, Equatable, Sendable {
    /// macOS virtual key code (kVK_*).
    public var keyCode: UInt32
    /// Carbon modifier bits (cmdKey | optionKey | controlKey | shiftKey).
    public var carbonModifiers: UInt32
    /// Human-readable form, e.g. "F16" or "⌃⌥Space" — built when the user records
    /// the combo.
    public var display: String

    public init(keyCode: UInt32, carbonModifiers: UInt32 = 0, display: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.display = display
    }
}

/// The three Quick Capture actions a global shortcut can drive.
public enum CaptureHotKeyAction: String, CaseIterable, Codable, Sendable {
    /// Press = start dictating, release = stop → transcribe → save.
    case holdToDictate
    /// Tap = start dictating, tap again = stop → transcribe → save.
    case toggleDictation
    /// Pop up the quick text pad (type, ⇧↩ to save).
    case quickPad
}

/// The platform seam for global capture hotkeys. The Mac app implements this with
/// Carbon (`HotKeyManager`); iOS has no global hotkeys and passes no controller.
/// `apply` replaces ALL current registrations with the given bindings, so a
/// settings change simply re-applies.
@MainActor
public protocol CaptureHotKeyController: AnyObject {
    func apply(bindings: [CaptureHotKeyAction: KeyShortcut])
}
