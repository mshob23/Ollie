import HandheldNotesCore
import SwiftUI

/// The settings sheet. One thing to decide: **which transcription engine** turns
/// recordings into text. Grouped into a calm well so the choice reads clearly —
/// the notes are the product, but this knob matters.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Color.hcCardBorder.opacity(0.5))

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
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
            Text("Ollie · all capture and transcription stays on this Mac.")
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
