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
            .padding(24)

            Spacer()
        }
        .frame(width: 460, height: 380)
        .background(WarmBackground())
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
