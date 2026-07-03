import AppKit
import Carbon
import HandheldNotesCore
import SwiftUI

/// A click-to-record shortcut field: click it, press your combo, done. Esc cancels
/// the recording; ⌫ clears the binding (the shortcut becomes unassigned).
///
/// While recording, an `NSEvent` local monitor captures the next keyDown and turns
/// it into a `KeyShortcut` (key code + Carbon modifier bits + a display string
/// built right here, so nothing ever needs to reverse-map a key code).
struct ShortcutRecorderField: View {
    @Binding var shortcut: KeyShortcut?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(action: { recording ? stopRecording() : startRecording() }) {
            HStack(spacing: 6) {
                if recording {
                    Text("Press keys…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.hcAccent)
                } else if let shortcut {
                    Text(shortcut.display)
                        .font(.system(size: 12, weight: .semibold).monospaced())
                        .foregroundStyle(Color.hcPrimaryText)
                } else {
                    Text("Click to set")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.hcMutedText)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(minWidth: 96)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(recording ? Color.hcAccent.opacity(0.12) : Color.hcPanel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(recording ? Color.hcAccent.opacity(0.6) : Color.hcCardBorder, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(recording ? "Press the key combo to assign — esc cancels, delete clears"
                        : "Click, then press the key combo to assign")
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            defer { stopRecording() }
            switch Int(event.keyCode) {
            case kVK_Escape:
                break                                     // cancel — keep current
            case kVK_Delete, kVK_ForwardDelete:
                shortcut = nil                            // clear the binding
            default:
                let mods = HotKeyManager.carbonModifiers(from: event.modifierFlags)
                shortcut = KeyShortcut(
                    keyCode: UInt32(event.keyCode),
                    carbonModifiers: mods,
                    display: Self.display(for: event, carbonModifiers: mods))
            }
            return nil                                    // swallow the keystroke
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }

    // MARK: Display string

    private static func display(for event: NSEvent, carbonModifiers: UInt32) -> String {
        var out = ""
        if carbonModifiers & UInt32(controlKey) != 0 { out += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { out += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { out += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { out += "⌘" }
        out += keyName(for: Int(event.keyCode), event: event)
        return out
    }

    private static func keyName(for keyCode: Int, event: NSEvent) -> String {
        let special: [Int: String] = [
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
            kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
            kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14",
            kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
            kVK_F19: "F19", kVK_F20: "F20",
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥",
            kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_LeftArrow: "←", kVK_RightArrow: "→",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        ]
        if let name = special[keyCode] { return name }
        let chars = event.charactersIgnoringModifiers ?? ""
        return chars.isEmpty ? "key \(keyCode)" : chars.uppercased()
    }
}
