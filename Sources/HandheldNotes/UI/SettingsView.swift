import SwiftUI

/// A compact settings sheet: choose the transcription engine. Kept small on
/// purpose — the notes are the product, not the knobs.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 18)

            Divider().overlay(Color.hcCardBorder.opacity(0.5))

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    modeSection
                    Divider().overlay(Color.hcCardBorder.opacity(0.4))
                    engineSection
                }
                .padding(24)
            }
        }
        .frame(width: 480, height: 540)
        .background(WarmBackground())
    }

    // MARK: Mode

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Mode")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.hcPrimaryText)
                Text("How the app decides between talking to this computer (live transcribe) and storing on the device for later sync.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.hcMutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach([ModeSelection.manual, .automatic], id: \.self) { sel in
                modeRow(sel)
            }

            // When Manual: let the user pick the default Computer/Local here too.
            if model.settings.modeSelection == .manual {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Manual default")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.hcSecondaryText)
                    HStack(spacing: 8) {
                        ForEach([CaptureMode.computer, .local], id: \.self) { mode in
                            manualModeChip(mode)
                        }
                    }
                }
                .padding(.leading, 28)
            }
        }
    }

    private func modeRow(_ sel: ModeSelection) -> some View {
        let selected = model.settings.modeSelection == sel
        return Button(action: { model.settings.modeSelectionID = sel.rawValue }) {
            HStack(spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(selected ? Color.hcAccent : Color.hcMutedText)
                VStack(alignment: .leading, spacing: 2) {
                    Text(sel.label)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Color.hcPrimaryText)
                    Text(sel.subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.hcSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
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
        VStack(alignment: .leading, spacing: 14) {
            Text("Transcription engine")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.hcPrimaryText)

            ForEach(TranscriptionEngine.allCases, id: \.self) { engine in
                engineRow(engine)
            }

            Text("whisper.cpp uses your local whisper-cli + ffmpeg if installed; otherwise the app falls back to Apple Speech automatically. Audio is never sent off the machine.")
                .font(.system(size: 11))
                .foregroundStyle(Color.hcMutedText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
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
}
