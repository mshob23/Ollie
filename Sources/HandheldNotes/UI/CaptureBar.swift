import SwiftUI

/// The Computer-mode capture control: a record button (also driven by the global
/// F16 hotkey), a live level meter while recording, and status text. Lives at the
/// top of the center column so capturing a note is always one click away.
struct CaptureBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 16) {
            recordButton

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Eyebrow(text: "Computer mode")
                    Text("· hold F16 to talk")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.hcMutedText)
                }
                Text(statusText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
            }

            Spacer()

            if model.isRecording {
                LevelMeter(level: model.micLevel)
                    .frame(width: 120, height: 26)
                Button(action: { model.cancelRecording() }) {
                    Text("Cancel")
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .hcPanel(fill: .hcPanelRaised)
    }

    private var recordButton: some View {
        Button(action: { model.toggleRecording() }) {
            ZStack {
                Circle()
                    .fill(model.isRecording ? Color.hcAccentPressed : Color.hcAccent)
                    .frame(width: 46, height: 46)
                if isBusyTranscribing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.hcOnAccent)
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
        .help(model.isRecording ? "Stop and transcribe" : "Record a note")
    }

    private var isBusyTranscribing: Bool {
        if case .transcribing = model.recordingState { return true }
        return false
    }

    private var statusText: String {
        switch model.recordingState {
        case .idle:          return "Ready to record"
        case .recording:     return "Recording… release F16 or press stop"
        case .transcribing:  return "Transcribing your note…"
        case .error(let m):  return m
        }
    }

    private var statusColor: Color {
        switch model.recordingState {
        case .error:     return .hcAccent
        case .recording: return .hcAccent
        default:         return .hcSecondaryText
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
