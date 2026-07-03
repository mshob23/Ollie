import HandheldNotesCore
import SwiftUI

/// The persistent capture area, pinned to the top of the window and independent of
/// which note is selected. It hosts:
///   • the live DRAFT — the in-progress note that accumulates appended speech and
///     edits until the user explicitly concludes it,
///   • the record button (also driven by global F16 push-to-talk), the edit keys
///     (Space / Newline / Backspace), and the Send / Conclude button (⌘↩).
struct CaptureBar: View {
    @EnvironmentObject var model: AppModel
    var onOpenSettings: () -> Void = {}

    /// User tapped to open an empty draft to type into. The bar also auto-expands
    /// whenever the draft has content or a recording/transcription is in progress.
    @State private var composing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow
            Divider().overlay(Color.hcCardBorder.opacity(0.4))
            computerCapture
        }
        .padding(16)
        .hcPanel(fill: .hcPanelRaised)
    }

    // MARK: Header (window actions)

    private var headerRow: some View {
        HStack(spacing: 12) {
            Eyebrow(text: "Capture")
            Spacer()
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.hcSecondaryText)
                    .padding(7)
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
    }

    // MARK: Live capture — compact when idle, expands while drafting

    /// True while the mic/transcriber is busy FOR THE DRAFT flow. A Quick Capture
    /// (the global-shortcut auto-save path) must NOT expand the draft composer —
    /// its text never lands there; the status line + menu-bar mic are its feedback.
    private var draftCaptureBusy: Bool {
        (model.isRecording || model.isTranscribing) && model.captureMode == .draft
    }

    /// A draft is "active" once it has content or a draft recording/transcription runs.
    private var isDrafting: Bool {
        !model.draft.isEmpty || draftCaptureBusy
    }
    private var expanded: Bool { isDrafting || composing }

    /// True when it's safe to collapse the composer back to the slim idle row:
    /// the draft holds no real content and nothing is actively recording or
    /// transcribing for it. We *never* collapse over real content — `isDrafting`
    /// keeps the bar expanded in that case regardless of `composing`.
    private var canCollapse: Bool {
        model.draft.isEmpty && !draftCaptureBusy
    }

    /// Collapse the (empty) composer back to compact. No-op when there's content
    /// or a capture in flight, so a half-typed or recording draft is never lost.
    private func collapseIfEmpty() {
        if canCollapse { composing = false }
    }

    private var computerCapture: some View {
        Group {
            if expanded {
                expandedCapture
            } else {
                compactCapture
            }
        }
        .animation(.easeInOut(duration: 0.22), value: expanded)
        .onChange(of: model.draft.isEmpty) { _, isEmpty in
            if isEmpty { composing = false }   // collapse back to slim after Send / clear
        }
        // Escape collapses an empty composer back to the slim idle row (so clicking
        // the idle prompt and then typing nothing isn't a one-way trip). Gated on
        // `canCollapse`, so Escape never discards real draft content.
        .onExitCommand { collapseIfEmpty() }
    }

    /// Slim idle row: the record button + a one-line prompt. Click to start typing,
    /// or hold F16 to talk — either expands into the full composer below.
    private var compactCapture: some View {
        HStack(spacing: 14) {
            recordButton
            Button(action: { composing = true }) {
                VStack(alignment: .leading, spacing: 2) {
                    Eyebrow(text: "Draft")
                    Text("Click to type a note — or use your Quick Capture key to dictate one from anywhere.")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Color.hcSecondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Start a new draft note")
            Text("Ready")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.hcMutedText)
        }
    }

    private var expandedCapture: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                recordButton

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Eyebrow(text: "Draft")
                        Text("· click the mic to talk, keep going, then Send")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Color.hcMutedText)
                        if model.draft.appendCount > 0 {
                            Chip("\(model.draft.appendCount) clip\(model.draft.appendCount == 1 ? "" : "s")",
                                 symbol: "mic.fill", tint: .hcAccent)
                        }
                    }
                    // Auto-focus the field when the composer was opened by clicking
                    // the idle prompt (composing, empty draft), so the cursor is
                    // ready and clicking away collapses an untouched draft.
                    DraftField(autoFocus: composing && model.draft.isEmpty,
                               onLostFocusWhenEmpty: { collapseIfEmpty() })
                }

                if model.isRecording {
                    LevelMeter(level: model.micLevel)
                        .frame(width: 96, height: 26)
                }
            }

            HStack(spacing: 10) {
                Text(statusText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)

                Spacer()

                // Edit keys — these edit the SAME draft.
                EditKey(symbol: "space", label: "Space", help: "Insert a space") {
                    model.draftSpace()
                }
                EditKey(symbol: "return", label: "Newline", help: "Insert a new line") {
                    model.draftNewline()
                }
                EditKey(symbol: "delete.left", label: "Backspace", help: "Delete last character") {
                    model.draftBackspace()
                }

                if model.isRecording {
                    Button(action: { model.cancelRecording() }) { Text("Cancel") }
                        .buttonStyle(SecondaryButtonStyle())
                }

                Button(action: { model.concludeDraft(); composing = false }) {
                    HStack(spacing: 6) {
                        Image(systemName: "paperplane.fill")
                        Text("Send")
                        Text("⌘↩").font(.system(size: 11, weight: .semibold)).opacity(0.7)
                    }
                }
                .buttonStyle(PrimaryButtonStyle(enabled: !model.draft.isEmpty))
                .disabled(model.draft.isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Conclude this draft into a saved note")
            }
        }
    }

    private var recordButton: some View {
        Button(action: { model.toggleRecording() }) {
            ZStack {
                Circle()
                    .fill(model.isRecording ? Color.hcAccentPressed : Color.hcAccent)
                    .frame(width: 46, height: 46)
                if isBusyTranscribing {
                    ProgressView().controlSize(.small).tint(Color.hcOnAccent)
                } else {
                    Image(systemName: model.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Color.hcOnAccent)
                }
            }
            .overlay(
                Circle().stroke(Color.hcAccent.opacity(model.isRecording ? 0.5 : 0), lineWidth: 4)
                    .scaleEffect(model.isRecording ? 1.25 : 1)
                    .opacity(model.isRecording ? 0 : 1)
                    .animation(model.isRecording ? .easeOut(duration: 1).repeatForever(autoreverses: false) : .default,
                               value: model.isRecording)
            )
        }
        .buttonStyle(.plain)
        .disabled(isBusyTranscribing)
        .help(model.isRecording ? "Stop and append to the draft" : "Record and append to the draft")
    }

    // MARK: Derived

    private var isBusyTranscribing: Bool { model.isTranscribing }

    private var statusText: String {
        let quick = model.captureMode == .quick
        switch model.recordingState {
        case .idle:
            return model.draft.isEmpty ? "Ready" : "Draft in progress — keep talking, or Send to save"
        case .recording:
            return quick ? "Recording… release (or tap) your key to save"
                         : "Recording… press stop to append to the draft"
        case .transcribing:
            return quick ? "Transcribing… saving your note" : "Transcribing… appending to your draft"
        case .error(let m): return m
        }
    }

    private var statusColor: Color {
        switch model.recordingState {
        case .error, .recording: return .hcAccent
        default:                 return .hcSecondaryText
        }
    }
}

// MARK: - The draft transcript field (prominent, editable, accumulating)

/// Shows the active draft's accumulating transcript. Editable inline (typing /
/// editing acts on the same draft the edit keys act on).
///
/// - `autoFocus`: focus the editor as soon as it appears (used when the composer
///   was opened by clicking the idle prompt, so the cursor is ready to type).
/// - `onLostFocusWhenEmpty`: called when the editor loses focus while the draft is
///   still empty — the parent uses it to collapse the composer back to the slim
///   idle row. It is never called with real content, and the parent re-checks
///   anyway, so half-typed drafts are never collapsed away.
private struct DraftField: View {
    var autoFocus: Bool = false
    var onLostFocusWhenEmpty: () -> Void = {}

    @EnvironmentObject var model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            if model.draft.transcript.isEmpty {
                // Match the editor's font AND its glyph origin so the placeholder
                // sits exactly where typed text (and the insertion cursor) appear —
                // the editor's own ~5pt text-container inset is the alignment target.
                Text("Your draft will appear here as you talk. Space / Newline / Backspace edit it; Send (⌘↩) concludes it into a note.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.hcMutedText)
                    .padding(.leading, 5)
                    .padding(.top, 1)
                    .allowsHitTesting(false)
            }
            TextEditor(text: Binding(
                get: { model.draft.transcript },
                set: { model.setDraftTranscript($0) }))
                .focused($focused)
                .font(.system(size: 14))
                .foregroundStyle(Color.hcPrimaryText)
                .lineSpacing(3)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 52, maxHeight: 120)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.hcPanel))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(focused ? Color.hcAccent.opacity(0.4) : Color.hcCardBorder.opacity(0.6), lineWidth: 1))
        .onAppear {
            // Defer a tick so the editor is in the hierarchy before we focus it.
            if autoFocus {
                DispatchQueue.main.async { focused = true }
            }
        }
        .onChange(of: focused) { wasFocused, isFocused in
            // Field blurred while the draft is still empty → let the parent collapse
            // the composer. (Only meaningful once it had focus to lose.)
            if wasFocused && !isFocused && model.draft.isEmpty {
                onLostFocusWhenEmpty()
            }
        }
    }
}

// MARK: - A draft edit key

private struct EditKey: View {
    let symbol: String
    let label: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                Text(label).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Color.hcPrimaryText)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color.hcPrimaryText.opacity(0.06)))
            .overlay(Capsule().stroke(Color.hcPrimaryText.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// A simple animated level meter (a row of bars reacting to mic RMS).
struct LevelMeter: View {
    let level: Float   // 0…1
    private let barCount = 14

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<barCount, id: \.self) { i in
                let threshold = Float(i) / Float(barCount)
                let active = level > threshold
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(active ? barColor(for: i) : Color.hcMutedText.opacity(0.25))
                    .frame(width: 4, height: barHeight(for: i, active: active))
            }
        }
    }

    private func barHeight(for index: Int, active: Bool) -> CGFloat {
        let base: CGFloat = 6
        let maxH: CGFloat = 24
        let frac = CGFloat(index) / CGFloat(barCount)
        return active ? base + (maxH - base) * (0.4 + frac * 0.6) : base
    }

    private func barColor(for index: Int) -> Color {
        let frac = Double(index) / Double(barCount)
        return frac > 0.8 ? .hcAccentHover : .hcAccent
    }
}
