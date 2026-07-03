import HandheldNotesCore
import SwiftUI

/// The settings sheet: the microphone to record from, Quick Capture shortcuts,
/// geotagging, and iCloud sync — each grouped into a calm well.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Binding var isPresented: Bool

    /// Reset-sync flow state. `confirmingReset` gates the destructive action behind
    /// an explicit dialog; `resetResult` drives the follow-up alert.
    @State private var confirmingReset = false
    @State private var resetResult: ResetResult?
    /// Snapshot of available input devices, refreshed when Settings appears.
    @State private var availableMicsState: [String] = []

    /// The outcome to surface after a `resetSync()` attempt — either "relaunch
    /// needed" (success) or an error message (nothing was deleted).
    private enum ResetResult: Identifiable {
        case relaunchRequired
        case failed(String)
        var id: String {
            switch self {
            case .relaunchRequired: return "relaunch"
            case .failed(let msg): return "failed-\(msg)"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Color.hcCardBorder.opacity(0.5))

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    micSection
                    quickCaptureSection
                    captureSection
                    syncSection
                    footer
                }
                .onAppear { availableMicsState = AppModel.availableMicrophones() }
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 24)
            }
        }
        .frame(width: 500, height: 600)
        .background(WarmBackground())
        .confirmationDialog(
            "Reset iCloud sync?",
            isPresented: $confirmingReset,
            titleVisibility: .visible
        ) {
            Button("Back up & reset sync", role: .destructive) { performResetSync() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This backs up your notes, then rebuilds the local sync state from scratch. Your iCloud data is left untouched. Ollie must be relaunched afterward.")
        }
        .alert(item: $resetResult) { result in
            switch result {
            case .relaunchRequired:
                return Alert(
                    title: Text("Sync reset"),
                    message: Text("Please quit and reopen Ollie."),
                    primaryButton: .default(Text("Quit Ollie")) {
                        NSApp.terminate(nil)
                    },
                    secondaryButton: .cancel(Text("Later"))
                )
            case .failed(let message):
                return Alert(
                    title: Text("Couldn't reset sync"),
                    message: Text(message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
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

    // MARK: Microphone

    /// A sentinel for the "System default" picker row (a Picker tag can't be nil).
    private static let systemDefaultMic = "\u{0}systemDefault"

    private var micSelection: Binding<String> {
        Binding(
            get: { model.settings.microphoneName ?? Self.systemDefaultMic },
            set: { model.settings.microphoneName = ($0 == Self.systemDefaultMic) ? nil : $0 })
    }

    private var micSection: some View {
        SettingsSection(
            eyebrow: "Speech-to-text",
            title: "Microphone",
            blurb: "Recordings transcribe on-device with Apple Speech — private, no setup. Choose which mic to record from, or follow your Mac's current default."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Input device", selection: micSelection) {
                    Text("System default").tag(Self.systemDefaultMic)
                    Divider()
                    ForEach(availableMics, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(.hcAccent)

                // If a previously-picked mic is unplugged, say so — capture will
                // fall back to the system default until it's reconnected or changed.
                if let chosen = model.settings.microphoneName, !availableMics.contains(chosen) {
                    Label("“\(chosen)” isn't connected — recording uses the system default until it's back.",
                          systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.hcMutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Live device list, refreshed each time Settings appears (see `.onAppear`).
    private var availableMics: [String] { availableMicsState }

    // MARK: Capture (geotag)

    // MARK: Quick Capture

    private var quickCaptureSection: some View {
        SettingsSection(
            eyebrow: "Quick Capture",
            title: "Global shortcuts",
            blurb: "Capture a note from anywhere in macOS — dictate and it saves itself, transcribed behind the scenes. Click a field, then press the combo you want (esc cancels, delete clears)."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                shortcutRow(
                    title: "Hold to dictate",
                    subtitle: "Press and hold: record. Release: transcribe + save.",
                    binding: $model.settings.holdToDictateShortcut)
                shortcutRow(
                    title: "Toggle dictation",
                    subtitle: "Tap to start, tap again to stop + save. For longer thoughts.",
                    binding: $model.settings.toggleDictationShortcut)
                shortcutRow(
                    title: "Quick note pad",
                    subtitle: "Pops a small pad to type into — ⇧↩ saves, esc discards.",
                    binding: $model.settings.quickPadShortcut)

                Divider().overlay(Color.hcCardBorder.opacity(0.4))

                Toggle(isOn: $model.settings.confirmQuickCaptureBeforeSaving) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ask before saving")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(Color.hcPrimaryText)
                        Text("Show a Save/Discard confirmation after each dictated capture (↩ saves). Off = it just saves.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.hcSecondaryText)
                    }
                }
                .toggleStyle(.switch)
                .tint(.hcAccent)
            }
        }
    }

    private func shortcutRow(
        title: String, subtitle: String, binding: Binding<KeyShortcut?>
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.hcPrimaryText)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.hcSecondaryText)
            }
            Spacer(minLength: 8)
            ShortcutRecorderField(shortcut: binding)
        }
    }

    private var captureSection: some View {
        SettingsSection(
            eyebrow: "Capture",
            title: "Geotag notes",
            blurb: "Tag each new note with where you were — an on-device reverse-geocoded place name. Off by default; the coordinate never leaves your Mac."
        ) {
            Toggle(isOn: $model.settings.geotagEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Remember where a note was taken")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Color.hcPrimaryText)
                    Text("Asks for location permission the first time you capture with this on.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.hcSecondaryText)
                }
            }
            .toggleStyle(.switch)
            .tint(.hcAccent)
        }
    }

    // MARK: iCloud sync

    /// A relative-time formatter for the "Last synced <time>" affordance. One shared
    /// instance — building these is non-trivial and the format never changes.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private var syncSection: some View {
        SettingsSection(
            eyebrow: "iCloud",
            title: "Sync status",
            blurb: "Whether your notes are syncing across your devices through iCloud. A silent failure is the worst kind, so the real state shows here."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                syncStatusRow
                deviceFreshnessRows
                Divider().overlay(Color.hcCardBorder.opacity(0.4))
                syncNowButton
                resetSyncButton
            }
        }
    }

    /// "Last note from iPhone / Watch" rows — a human-readable smoke alarm for the
    /// failure the status row can't see: THIS Mac's sync being healthy while another
    /// device silently fails to export (the July 2026 outage: the Mac imported
    /// green-but-empty for a day). Derived purely from notes already in the store —
    /// no new sync machinery. Sources that have never produced a note are omitted.
    private var deviceFreshnessRows: some View {
        let sources: [(NoteSource, String, String)] = [
            (.phone, "iphone", "iPhone"),
            (.watch, "applewatch", "Watch"),
        ]
        return VStack(alignment: .leading, spacing: 5) {
            ForEach(sources, id: \.1) { source, symbol, label in
                if let latest = model.notes.filter({ $0.source == source })
                    .map(\.createdAt).max() {
                    HStack(spacing: 7) {
                        Image(systemName: symbol)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Color.hcMutedText)
                            .frame(width: 14)
                        Text("Last note from \(label): \(Self.relativeFormatter.localizedString(for: latest, relativeTo: Date()))")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.hcSecondaryText)
                    }
                }
            }
        }
        .padding(.leading, 14)
    }

    /// A coloured status row reflecting `model.syncHealth`: green when syncing,
    /// amber when local-only, red when degraded (with the actionable message).
    private var syncStatusRow: some View {
        let (color, symbol, title, detail) = syncStatusContent
        return HStack(alignment: .top, spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 20, alignment: .center)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.hcPrimaryText)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.hcSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(color.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(color.opacity(0.35), lineWidth: 1)
        )
    }

    /// Maps the current `SyncHealth` to (accent colour, SF Symbol, title, detail).
    private var syncStatusContent: (Color, String, String, String?) {
        switch model.syncHealth {
        case .idle(lastSuccess: nil):
            // No successful sync yet — stay NEUTRAL. A green checkmark here would
            // falsely signal health (and could mask an undeployed-schema failure)
            // before the first real sync event arrives.
            return (.hcMutedText, "icloud", "Connecting to iCloud",
                    "Waiting for the first sync to complete.")
        case .idle, .syncing:
            return (.hcOk, "checkmark.icloud.fill", "Syncing with iCloud", lastSyncedDetail)
        case .localOnly:
            return (.hcAccent, "icloud.slash.fill",
                    "Not syncing - local storage only",
                    "Notes are saved on this Mac only. Sign in to iCloud to sync across devices.")
        case .degraded(.reconciling, _):
            // Recoverable, self-healing — show as calm info, not an alarming red.
            return (.hcAccent, "arrow.triangle.2.circlepath.icloud",
                    "Reconciling with iCloud", SyncDegradation.reconciling.userMessage)
        case .degraded(let degradation, _):
            return (.syncDanger, "exclamationmark.icloud.fill",
                    "Sync problem", degradation.userMessage)
        }
    }

    /// The "Last synced <relative time>" secondary line for the healthy states,
    /// derived from `model.lastSuccessfulSync` (nil until a phase has completed).
    private var lastSyncedDetail: String? {
        guard let last = model.lastSuccessfulSync else {
            return "Waiting for the first sync to complete."
        }
        let rel = Self.relativeFormatter.localizedString(for: last, relativeTo: Date())
        return "Last synced \(rel)."
    }

    private var syncNowButton: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: { model.syncNow() }) {
                syncActionLabel(
                    symbol: "arrow.triangle.2.circlepath",
                    tint: .hcAccent,
                    title: "Sync now",
                    subtitle: "Refreshes from the local store and re-exports your notes. iCloud syncs on its own schedule; this reconciles what's on disk."
                )
            }
            .buttonStyle(.plain)

            // Manual-sync feedback: tapping "Sync now" reconciles local state with
            // nothing visible to pull, so echo WHEN it last ran to confirm the tap
            // registered. Derived from `model.lastManualSync` (nil until first tap).
            if let detail = lastReconciledDetail {
                Label(detail, systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.hcMutedText)
                    .padding(.leading, 14)
            }
        }
    }

    /// The "Last reconciled <relative time>" line under the Sync-now button, derived
    /// from `model.lastManualSync` (nil until the user taps "Sync now" at least once).
    private var lastReconciledDetail: String? {
        guard let last = model.lastManualSync else { return nil }
        let rel = Self.relativeFormatter.localizedString(for: last, relativeTo: Date())
        return "Last reconciled \(rel)."
    }

    private var resetSyncButton: some View {
        Button(action: { confirmingReset = true }) {
            syncActionLabel(
                symbol: "trash.slash",
                tint: .syncDanger,
                title: "Reset sync...",
                subtitle: "Backs up your notes, then rebuilds local sync state. Use only if sync is stuck. Requires a relaunch."
            )
        }
        .buttonStyle(.plain)
    }

    /// Shared row layout for the two sync action buttons (icon + title + subtitle).
    private func syncActionLabel(symbol: String, tint: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 20, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.hcPrimaryText)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.hcSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.hcPanel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.hcCardBorder.opacity(0.6), lineWidth: 1)
        )
        .contentShape(Rectangle())
    }

    /// Run the destructive reset (only reached after the confirmation dialog) and
    /// translate its result/throw into the follow-up alert.
    private func performResetSync() {
        do {
            switch try model.resetSync() {
            case .relaunchRequired:
                resetResult = .relaunchRequired
            }
        } catch AppModel.ResetSyncError.backupFailed {
            resetResult = .failed("Couldn't back up before reset - aborted, nothing was deleted.")
        } catch AppModel.ResetSyncError.storeDirectoryUnavailable {
            resetResult = .failed("Couldn't locate the local store - nothing was deleted.")
        } catch {
            resetResult = .failed("Reset failed - nothing was deleted. (\(error.localizedDescription))")
        }
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
