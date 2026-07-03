import HandheldNotesCore
import SwiftUI

/// The quick-note pad: a small floating panel for dumping a typed thought without
/// opening the main window. ⇧↩ saves, Esc discards (↩ alone is a newline, as in
/// any text field). Presented by the AppDelegate in an `NSPanel` when the quick-pad
/// shortcut or menu-bar item fires.
struct QuickPadView: View {
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Quick note")
                    .font(.hcDisplay(15, weight: .semibold))
                    .foregroundStyle(Color.hcPrimaryText)
                Spacer()
                Text("⇧↩ save · esc discard")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.hcMutedText)
            }

            TextEditor(text: $text)
                .focused($focused)
                .font(.system(size: 14))
                .foregroundStyle(Color.hcPrimaryText)
                .lineSpacing(4)
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 120)
                .hcPanel(fill: .hcPanel)
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    onSave(text)
                    return .handled
                }
                .onKeyPress(.escape) {
                    onCancel()
                    return .handled
                }

            HStack {
                Spacer()
                Button("Discard") { onCancel() }
                    .buttonStyle(.bordered)
                Button("Save") { onSave(text) }
                    .buttonStyle(.borderedProminent)
                    .tint(.hcAccent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 420)
        .background(Color.hcBackground)
        .onAppear { focused = true }
    }
}
