import HandheldNotesCore
import SwiftUI

/// The Local-mode surface: a slide-over panel that drives the (mock) handheld
/// device sync. It tells the whole story at a glance — connection state, the
/// recordings sitting on the device, each file's transfer progress, a live log,
/// and the trust contract that a file is only deleted from the device **after**
/// it has been transcribed and safely saved here. This is what exercises the BLE
/// audio-sync pipeline end-to-end with no hardware.
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
                    safetyContract
                    fileSection
                    logSection
                    protocolNote
                }
                .padding(20)
            }
        }
        .frame(width: 392)
        .background(Color.hcBackgroundBottom)
        .overlay(Rectangle().fill(Color.hcCardBorder.opacity(0.5)).frame(width: 1), alignment: .leading)
    }

    // MARK: Header

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
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }

    // MARK: Status card (connection + stage tracker + primary action)

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                StatusDot(color: dotColor, pulsing: model.syncState.isBusy)
                Text(model.syncState.label)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.hcPrimaryText)
                Spacer()
            }

            // A four-dot stage tracker: Connect → Receive → Save → Done.
            StageTracker(stage: currentStage)

            if case .transferring(_, let progress) = model.syncState {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress).tint(.hcAccent)
                    Text("\(Int(progress * 100))% of the current file")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.hcMutedText)
                }
            } else if case .savingNote = model.syncState {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(.hcAccent)
                    Text("Transcribing and saving…")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.hcMutedText)
                }
            }

            HStack(spacing: 10) {
                if model.syncState.isBusy {
                    Button(action: { model.stopDeviceSync() }) { Text("Stop") }
                        .buttonStyle(SecondaryButtonStyle())
                } else {
                    Button(action: { model.startDeviceSync() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text(hasSyncedThisSession ? "Sync again" : "Sync from device")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                Spacer()
            }

            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.hcMutedText)
                Text(model.deviceSync.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.hcMutedText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .hcPanel(fill: .hcPanelRaised)
    }

    // MARK: Safety contract (the trust story)

    private var safetyContract: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.hcOk)
                Text("Nothing is lost")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.hcPrimaryText)
            }
            VStack(alignment: .leading, spacing: 7) {
                contractStep(1, "Received", "The recording streams over BLE in verified chunks.")
                contractStep(2, "Transcribed", "It's turned into a note and written to your library.")
                contractStep(3, "Deleted on device", "Only **after** the note is safely saved is the SD-card slot freed.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.hcOk.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.hcOk.opacity(0.22), lineWidth: 1)
        )
    }

    private func contractStep(_ n: Int, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text("\(n)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.hcOk)
                .frame(width: 17, height: 17)
                .background(Circle().fill(Color.hcOk.opacity(0.16)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.hcPrimaryText)
                Text(markdown(body))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.hcSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Render a small markdown string (we use **bold**) as an AttributedString so
    /// the emphasis shows instead of literal asterisks. Falls back to plain text.
    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s)) ?? AttributedString(s)
    }

    // MARK: Files on the device

    private var fileSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Eyebrow(text: "On device")
                Spacer()
                Text(fileCountLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.hcMutedText)
            }
            if model.deviceFiles.isEmpty {
                emptyFiles
            } else {
                VStack(spacing: 7) {
                    ForEach(model.deviceFiles) { file in
                        DeviceFileRow(file: file, status: status(for: file))
                    }
                }
            }
        }
    }

    private var emptyFiles: some View {
        HStack(spacing: 10) {
            Image(systemName: hasSyncedThisSession ? "checkmark.circle.fill" : "tray")
                .font(.system(size: 16))
                .foregroundStyle(hasSyncedThisSession ? Color.hcOk : Color.hcMutedText)
            Text(hasSyncedThisSession
                 ? "All recordings synced. The device's SD card is empty."
                 : "No recordings staged. Press “Sync from device” to simulate the handheld handing over its SD-card audio.")
                .font(.system(size: 12))
                .foregroundStyle(Color.hcSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hcPanel(fill: .hcPanel)
    }

    // MARK: Transfer log

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Eyebrow(text: "Transfer log")
                Spacer()
                if !model.syncLog.isEmpty {
                    Text("\(model.syncLog.count) line\(model.syncLog.count == 1 ? "" : "s")")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.hcMutedText)
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        if model.syncLog.isEmpty {
                            Text("Idle — waiting for a sync.")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color.hcMutedText)
                        } else {
                            ForEach(Array(model.syncLog.enumerated()), id: \.offset) { idx, line in
                                Text(line)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(logColor(for: line))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(idx)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
                .onChange(of: model.syncLog.count) { _, count in
                    if count > 0 { withAnimation { proxy.scrollTo(count - 1, anchor: .bottom) } }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hcPanel(fill: .hcPanel)
        }
    }

    // MARK: Protocol footnote

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
            Text("Service 48434153 “HCAS”. File-list → chunked notify → CRC verify → delete-on-verified-save. The real CoreBluetooth central is scaffolded; this panel drives the mock service. Full protocol spec in NOTES_APP_PLAN.md §5.")
                .font(.system(size: 10.5))
                .foregroundStyle(Color.hcMutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.hcAccentSoft.opacity(0.5)))
    }

    // MARK: Derived UI state

    /// Has at least one full sync happened this session? (Device list emptied
    /// after the log shows a completed sync.) Used to vary empty-state copy.
    private var hasSyncedThisSession: Bool {
        model.deviceFiles.isEmpty && model.syncLog.contains { $0.contains("Sync complete") }
    }

    private var fileCountLabel: String {
        let n = model.deviceFiles.count
        return n == 0 ? "—" : "\(n) recording\(n == 1 ? "" : "s")"
    }

    /// Map the single `syncState` onto a per-file status so each row shows where
    /// it is in the pipeline. Files ahead of the active one are queued; files the
    /// log has acked a DELETE for are done.
    private func status(for file: DeviceFile) -> FileTransferStatus {
        if model.syncLog.contains(where: { $0.contains("DELETE fileId=\(file.id)") }) {
            return .done
        }
        switch model.syncState {
        case .transferring(let name, let progress) where name == file.name:
            return .transferring(progress)
        case .savingNote(let name) where name == file.name:
            return .saving
        default:
            return model.syncState.isBusy ? .queued : .idle
        }
    }

    private var currentStage: SyncStage {
        switch model.syncState {
        case .idle, .unavailable: return hasSyncedThisSession ? .done : .none
        case .scanning, .connecting: return .connect
        case .connected:
            return hasSyncedThisSession ? .done : .connect
        case .transferring: return .receive
        case .savingNote: return .save
        case .error: return .none
        }
    }

    private var dotColor: Color {
        switch model.syncState {
        case .connected, .transferring, .savingNote: return .hcOk
        case .scanning, .connecting: return .hcAccent
        case .error, .unavailable: return .hcAccentHover
        case .idle: return .hcMutedText
        }
    }

    private func logColor(for line: String) -> Color {
        if line.contains("DELETE") || line.contains("verified") || line.contains("complete") { return .hcOk }
        if line.contains("Transfer START") || line.contains("connecting") { return .hcAccent }
        return .hcSecondaryText
    }
}

// MARK: - A single device-file row with its pipeline status

private enum FileTransferStatus: Equatable {
    case idle                  // not syncing
    case queued                // waiting its turn
    case transferring(Double)  // 0…1
    case saving                // transcribing + persisting
    case done                  // delete acked

    var label: String {
        switch self {
        case .idle:               return "Staged"
        case .queued:             return "Queued"
        case .transferring(let p): return "\(Int(p * 100))%"
        case .saving:             return "Saving…"
        case .done:               return "Synced"
        }
    }

    var tint: Color {
        switch self {
        case .idle:         return .hcMutedText
        case .queued:       return .hcSecondaryText
        case .transferring: return .hcAccent
        case .saving:       return .hcAccent
        case .done:         return .hcOk
        }
    }

    var symbol: String {
        switch self {
        case .idle:         return "waveform.circle.fill"
        case .queued:       return "clock"
        case .transferring: return "arrow.down.circle.fill"
        case .saving:       return "square.and.arrow.down.fill"
        case .done:         return "checkmark.circle.fill"
        }
    }
}

private struct DeviceFileRow: View {
    let file: DeviceFile
    let status: FileTransferStatus

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 10) {
                Image(systemName: status.symbol)
                    .font(.system(size: 17))
                    .foregroundStyle(status.tint)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.hcPrimaryText)
                    Text("\(AudioPlayerModel.timeString(file.durationSeconds)) · \(byteString(file.sizeBytes))")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.hcMutedText)
                }
                Spacer()
                Text(status.label)
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(status.tint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(status.tint.opacity(0.14)))
            }
            if case .transferring(let p) = status {
                ProgressView(value: p)
                    .tint(.hcAccent)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .hcPanel(fill: .hcPanel, radius: 10)
        .opacity(status == .done ? 0.7 : 1)
        .animation(.easeInOut(duration: 0.2), value: status)
    }

    private func byteString(_ bytes: UInt32) -> String {
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        return String(format: "%.1f MB", kb / 1024)
    }
}

// MARK: - Four-dot stage tracker (Connect → Receive → Save → Done)

private enum SyncStage: Int { case none = 0, connect = 1, receive = 2, save = 3, done = 4 }

private struct StageTracker: View {
    let stage: SyncStage

    private let steps: [(SyncStage, String, String)] = [
        (.connect, "Connect", "link"),
        (.receive, "Receive", "arrow.down"),
        (.save,    "Save",    "tray.and.arrow.down"),
        (.done,    "Done",    "checkmark"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { idx, step in
                let reached = stage.rawValue >= step.0.rawValue && stage != .none
                let isCurrent = stage == step.0
                VStack(spacing: 5) {
                    ZStack {
                        Circle()
                            .fill(reached ? Color.hcAccent.opacity(isCurrent ? 1 : 0.85) : Color.hcPanel)
                            .frame(width: 22, height: 22)
                        Circle()
                            .stroke(reached ? Color.clear : Color.hcCardBorder.opacity(0.7), lineWidth: 1)
                            .frame(width: 22, height: 22)
                        Image(systemName: step.0 == .done && reached ? "checkmark" : step.2)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(reached ? Color.hcOnAccent : Color.hcMutedText)
                    }
                    Text(step.1)
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(reached ? Color.hcSecondaryText : Color.hcMutedText)
                }
                if idx < steps.count - 1 {
                    Rectangle()
                        .fill(stage.rawValue > step.0.rawValue && stage != .none
                              ? Color.hcAccent.opacity(0.75) : Color.hcCardBorder.opacity(0.6))
                        .frame(height: 1.5)
                        .frame(maxWidth: .infinity)
                        .offset(y: -7)
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: stage)
    }
}
