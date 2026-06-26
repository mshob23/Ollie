import SwiftUI

/// The settings sheet. Two things to decide: **how the capture mode is chosen**
/// (Manual vs. Automatic, plus the manual Computer/Local default) and **which
/// transcription engine** turns recordings into text. Grouped into calm wells so
/// the choices read clearly — the notes are the product, but these knobs matter.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Color.hcCardBorder.opacity(0.5))

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    modeSection
                    engineSection
                    footer
                }
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 24)
            }
        }
        .frame(width: 500, height: 600)
        .background(WarmBackground())
    }

    // MARK: Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Eyebrow(text: "Preferences")
                Text("Settings")
                    .font(.hcDisplay(20, weight: .semibold))
                    .foregroundStyle(Color.hcPrimaryText)
            }
            Spacer()
            Button(action: { isPresented = false }) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.hcMutedText)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close settings")
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }

    // MARK: Mode

    private var modeSection: some View {
        SettingsSection(
            eyebrow: "Capture",
            title: "Mode",
            blurb: "How the app decides between talking to this computer and letting the handheld store recordings for later sync."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach([ModeSelection.manual, .automatic], id: \.self) { sel in
                    modeRow(sel)
                }

                // Automatic: explain what "follows the device" actually does.
                if model.settings.modeSelection == .automatic {
                    automaticExplainer
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // Manual: pick which mode is the default.
                if model.settings.modeSelection == .manual {
                    manualDefaultPicker
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: model.settings.modeSelection)
        }
    }

    private func modeRow(_ sel: ModeSelection) -> some View {
        let selected = model.settings.modeSelection == sel
        return Button(action: { model.settings.modeSelectionID = sel.rawValue }) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(selected ? Color.hcAccent : Color.hcMutedText)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Image(systemName: sel == .automatic ? "wand.and.stars" : "hand.tap")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(selected ? Color.hcAccent : Color.hcSecondaryText)
                        Text(sel.label)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(Color.hcPrimaryText)
                    }
                    Text(sel.subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.hcSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(selected ? Color.hcAccentSoft : Color.hcPanel))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(selected ? Color.hcAccent.opacity(0.4) : Color.hcCardBorder.opacity(0.6), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// A short, friendly explanation of the Automatic behaviour: it tracks the
    /// device's connectivity and flips the mode accordingly.
    private var automaticExplainer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.hcAccent)
                Text("What Automatic does")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.hcPrimaryText)
            }
            autoRule(symbol: "laptopcomputer", mode: "In range → Computer",
                     detail: "The handheld is connected, so the F16 hotkey records the Mac mic and transcribes live.")
            autoRule(symbol: "externaldrive.badge.timemachine", mode: "Out of range → Local",
                     detail: "The device records to its SD card offline; reconnecting syncs those finished notes in.")
            Text("Flip the In range / Out of range toggle in the capture bar to watch Automatic switch (a simulated radio in this build).")
                .font(.system(size: 10.5))
                .foregroundStyle(Color.hcMutedText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 1)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.hcAccentSoft.opacity(0.5)))
        .padding(.leading, 28)
    }

    private func autoRule(symbol: String, mode: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.hcSecondaryText)
                .frame(width: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(mode)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.hcPrimaryText)
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.hcSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The manual Computer/Local default picker — only meaningful when Manual is
    /// the selection.
    private var manualDefaultPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Manual default")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.hcSecondaryText)
            HStack(spacing: 8) {
                ForEach([CaptureMode.computer, .local], id: \.self) { mode in
                    manualModeChip(mode)
                }
            }
            Text(model.settings.manualMode == .computer
                 ? "New captures dictate into a live draft on this Mac."
                 : "Captures come from the handheld; the device-sync panel pulls them in.")
                .font(.system(size: 10.5))
                .foregroundStyle(Color.hcMutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.hcPanel))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.hcCardBorder.opacity(0.5), lineWidth: 1))
        .padding(.leading, 28)
    }

    private func manualModeChip(_ mode: CaptureMode) -> some View {
        let selected = model.settings.manualMode == mode
        return Button(action: { model.setManualMode(mode) }) {
            HStack(spacing: 6) {
                Image(systemName: mode.symbol).font(.system(size: 11, weight: .semibold))
                Text(mode.label).font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(selected ? Color.hcOnAccent : Color.hcSecondaryText)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(selected ? Color.hcAccent : Color.hcPanel))
            .overlay(Capsule().stroke(selected ? Color.clear : Color.hcCardBorder.opacity(0.6), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(mode.subtitle)
    }

    // MARK: Transcription engine

    private var engineSection: some View {
        SettingsSection(
            eyebrow: "Speech-to-text",
            title: "Transcription engine",
            blurb: "Which engine turns a recording into a transcript. Everything runs on-device — audio is never sent off the machine."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(TranscriptionEngine.allCases, id: \.self) { engine in
                    engineRow(engine)
                }
                Text("whisper.cpp uses your local whisper-cli + ffmpeg if installed; otherwise the app falls back to Apple Speech automatically, so a note always gets saved.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.hcMutedText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }

    private func engineRow(_ engine: TranscriptionEngine) -> some View {
        let selected = model.settings.engine == engine
        return Button(action: {
            model.settings.transcriptionEngineID = engine.rawValue
        }) {
            HStack(spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(selected ? Color.hcAccent : Color.hcMutedText)
                VStack(alignment: .leading, spacing: 2) {
                    Text(engine.displayName)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Color.hcPrimaryText)
                    Text(engine.subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.hcSecondaryText)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(selected ? Color.hcAccentSoft : Color.hcPanel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(selected ? Color.hcAccent.opacity(0.4) : Color.hcCardBorder.opacity(0.6), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 7) {
            Image(systemName: "lock.shield")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.hcMutedText)
            Text("Handheld Notes · all capture and transcription stays on this Mac.")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.hcMutedText)
            Spacer()
        }
        .padding(.top, 2)
    }
}

// MARK: - A titled settings group (eyebrow + heading + blurb + content well)

private struct SettingsSection<Content: View>: View {
    let eyebrow: String
    let title: String
    let blurb: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(text: eyebrow)
                Text(title)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Color.hcPrimaryText)
                Text(blurb)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.hcSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.hcPanel.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.hcCardBorder.opacity(0.4), lineWidth: 1)
        )
    }
}
