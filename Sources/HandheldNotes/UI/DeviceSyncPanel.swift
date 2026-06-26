import SwiftUI

/// The Local-mode surface: a slide-over panel that drives the (mock) handheld
/// device sync. Shows connection state, the files "on the device," a live
/// progress/log, and the Sync button. This is what exercises the BLE audio-sync
/// pipeline end-to-end with no hardware.
struct DeviceSyncPanel: View {
    @EnvironmentObject var model: AppModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Color.hcCardBorder.opacity(0.5))

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    statusCard
                    fileSection
                    logSection
                    protocolNote
                }
                .padding(20)
            }
        }
        .frame(width: 380)
        .background(Color.hcBackgroundBottom)
        .overlay(Rectangle().fill(Color.hcCardBorder.opacity(0.5)).frame(width: 1), alignment: .leading)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Eyebrow(text: "Local mode")
                Text("Device Sync")
                    .font(.hcDisplay(19, weight: .semibold))
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
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                StatusDot(color: dotColor, pulsing: model.syncState.isBusy)
                Text(model.syncState.label)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.hcPrimaryText)
                Spacer()
            }

            if case .transferring(_, let progress) = model.syncState {
                ProgressView(value: progress)
                    .tint(.hcAccent)
            } else if case .savingNote = model.syncState {
                ProgressView()
                    .controlSize(.small)
                    .tint(.hcAccent)
            }

            HStack(spacing: 10) {
                if model.syncState.isBusy {
                    Button(action: { model.stopDeviceSync() }) { Text("Stop") }
                        .buttonStyle(SecondaryButtonStyle())
                } else {
                    Button(action: { model.startDeviceSync() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("Sync from device")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
            }

            Text(model.deviceSync.displayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.hcMutedText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .hcPanel(fill: .hcPanelRaised)
    }

    private var fileSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Eyebrow(text: "On device")
                Spacer()
                Text("\(model.deviceFiles.count) recording\(model.deviceFiles.count == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.hcMutedText)
            }
            if model.deviceFiles.isEmpty {
                Text("No recordings on the device. Press “Sync from device” to simulate the handheld handing over its SD-card audio.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.hcSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .hcPanel(fill: .hcPanel)
            } else {
                VStack(spacing: 6) {
                    ForEach(model.deviceFiles) { file in
                        HStack(spacing: 10) {
                            Image(systemName: "waveform.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(Color.hcAccent)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(file.name)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(Color.hcPrimaryText)
                                Text("\(AudioPlayerModel.timeString(file.durationSeconds)) · \(byteString(file.sizeBytes))")
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(Color.hcMutedText)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .hcPanel(fill: .hcPanel, radius: 10)
                    }
                }
            }
        }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Eyebrow(text: "Transfer log")
            VStack(alignment: .leading, spacing: 3) {
                if model.syncLog.isEmpty {
                    Text("Idle.")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.hcMutedText)
                } else {
                    ForEach(Array(model.syncLog.suffix(40).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.hcSecondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hcPanel(fill: .hcPanel)
        }
    }

    private var protocolNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.hcMutedText)
                Text("BLE audio-sync (stubbed)")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.hcSecondaryText)
            }
            Text("Service 48434153 “HCAS”. File-list → chunked notify → CRC verify → delete-on-verified-save. The real CoreBluetooth central is scaffolded; this panel runs the mock. Protocol spec in NOTES_APP_PLAN.md §5.")
                .font(.system(size: 10.5))
                .foregroundStyle(Color.hcMutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.hcAccentSoft.opacity(0.5)))
    }

    private var dotColor: Color {
        switch model.syncState {
        case .connected, .transferring, .savingNote: return .hcOk
        case .scanning, .connecting: return .hcAccent
        case .error, .unavailable: return .hcAccentHover
        case .idle: return .hcMutedText
        }
    }

    private func byteString(_ bytes: UInt32) -> String {
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        return String(format: "%.1f MB", kb / 1024)
    }
}
