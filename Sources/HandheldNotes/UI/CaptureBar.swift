import HandheldNotesCore
import SwiftUI

/// The persistent capture area, pinned to the top of the window and independent of
/// which note is selected. It hosts:
///   • the mode control (Manual Computer⇄Local toggle, or the Automatic badge +
///     simulated connectivity),
///   • the live DRAFT — the in-progress note that accumulates appended speech and
///     edits until the user explicitly concludes it,
///   • the record button (also driven by global F16 push-to-talk), the device-
///     mirror edit keys (Space / Newline / Backspace), and the Send / Conclude
///     button (⌘↩).
///
/// In Local mode the draft area is replaced by a note that the handheld is
/// recording offline — those recordings arrive already concluded over sync.
struct CaptureBar: View {
    @EnvironmentObject var model: AppModel
    var onOpenSettings: () -> Void = {}
    var onOpenSync: () -> Void = {}

    /// User tapped to open an empty draft to type into. The bar also auto-expands
    /// whenever the draft has content or a recording/transcription is in progress.
    @State private var composing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow
            Divider().overlay(Color.hcCardBorder.opacity(0.4))
            if model.activeMode == .computer {
                computerCapture
            } else {
                localCapture
            }
        }
        .padding(16)
        .hcPanel(fill: .hcPanelRaised)
    }

    // MARK: Header (mode control + window actions)

    private var headerRow: some View {
        HStack(spacing: 12) {
            ModeControl()
            Spacer()
            Button(action: onOpenSync) {
                HStack(spacing: 6) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                    Text("Device")
                }
            }
            .buttonStyle(SecondaryButtonStyle())
            .help("Sync recordings from the handheld device")

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

    // MARK: Computer / live capture — compact when idle, expands while drafting

    /// A draft is "active" once it has content or a recording/transcription runs.
    private var isDrafting: Bool {
        !model.draft.isEmpty || model.isRecording || model.isTranscribing
    }
    private var expanded: Bool { isDrafting || composing }

    /// True when it's safe to collapse the composer back to the slim idle row:
    /// the draft holds no real content and nothing is actively recording or
    /// transcribing. We *never* collapse over real content — `isDrafting` keeps
    /// the bar expanded in that case regardless of `composing`.
    private var canCollapse: Bool {
        model.draft.isEmpty && !model.isRecording && !model.isTranscribing
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
                    Text("Hold F16 to talk — or click to start typing a note.")
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
                        Text("· hold F16 to talk, keep going, then Send")
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

                // Device-mirror edit keys — these edit the SAME draft.
                EditKey(symbol: "space", label: "Space", help: "Insert a space (device: RIGHT tap)") {
                    model.draftSpace()
                }
                EditKey(symbol: "return", label: "Newline", help: "New line (device: RIGHT double-tap = Shift+Enter)") {
                    model.draftNewline()
                }
                EditKey(symbol: "delete.left", label: "Backspace", help: "Delete last character (device: BOTTOM)") {
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
                .help("Conclude this draft into a saved note (device: double-tap MIDDLE = Enter)")
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

    // MARK: Local capture (device records offline)

    private var localCapture: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle().fill(Color.hcOk.opacity(0.18)).frame(width: 46, height: 46)
                Image(systemName: "externaldrive.fill.badge.timemachine")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.hcOk)
            }
            VStack(alignment: .leading, spacing: 3) {
                Eyebrow(text: "Local mode", color: .hcOk)
                Text("The handheld records to its SD card while out of range.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.hcPrimaryText)
                Text("Recordings arrive already finished and drop straight into your notes on reconnect — no drafting here.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.hcMutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(action: onOpenSync) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("Sync now")
                }
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Derived

    private var isBusyTranscribing: Bool { model.isTranscribing }

    private var statusText: String {
        switch model.recordingState {
        case .idle:
            return model.draft.isEmpty ? "Ready — hold F16 to start a draft" : "Draft in progress — keep talking, or Send to save"
        case .recording:    return "Recording… release F16 or press stop (appends to draft)"
        case .transcribing: return "Transcribing… appending to your draft"
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
/// editing acts on the same draft the device buttons edit).
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
                Text("Your draft will appear here as you talk. Space / Newline / Backspace edit it; Send (⌘↩) concludes it into a note.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.hcMutedText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 8)
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

// MARK: - A device-mirror edit key

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

// MARK: - Mode control (Manual toggle / Automatic badge)

/// Manual: a Computer ⇄ Local segmented switch the user drives. Automatic: a read-
/// only badge showing the auto-chosen active mode plus an in-range/out-of-range
/// toggle so Auto visibly flips.
private struct ModeControl: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.modeIsAutomatic {
            automatic
        } else {
            manual
        }
    }

    private var manual: some View {
        HStack(spacing: 8) {
            Eyebrow(text: "Mode")
            HStack(spacing: 0) {
                segment(.computer)
                segment(.local)
            }
            .padding(2)
            .background(Capsule().fill(Color.hcPanel))
            .overlay(Capsule().stroke(Color.hcCardBorder.opacity(0.6), lineWidth: 1))
        }
    }

    private func segment(_ mode: CaptureMode) -> some View {
        let selected = model.activeMode == mode
        return Button(action: { model.setManualMode(mode) }) {
            HStack(spacing: 5) {
                Image(systemName: mode.symbol).font(.system(size: 10.5, weight: .semibold))
                Text(mode.label).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(selected ? Color.hcOnAccent : Color.hcSecondaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(selected ? Color.hcAccent : Color.clear))
        }
        .buttonStyle(.plain)
        .help(mode.subtitle)
    }

    private var automatic: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars").font(.system(size: 11, weight: .semibold))
                Text("AUTO").font(.hcEyebrow()).tracking(1.4)
                Text("·").foregroundStyle(Color.hcMutedText)
                Image(systemName: model.activeMode.symbol).font(.system(size: 11, weight: .semibold))
                Text(model.activeMode.label).font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(Color.hcAccent)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.hcAccentSoft))
            .help("Mode is chosen automatically from device connectivity")

            // Simulated connectivity so Auto visibly flips.
            Button(action: { model.setSimulatedConnected(!model.simulatedDeviceConnected) }) {
                HStack(spacing: 6) {
                    StatusDot(color: model.simulatedDeviceConnected ? .hcOk : .hcMutedText)
                    Text(model.simulatedDeviceConnected ? "In range" : "Out of range")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.hcSecondaryText)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .overlay(Capsule().stroke(Color.hcCardBorder.opacity(0.6), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Toggle simulated device connectivity (Automatic mode follows this)")
        }
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
