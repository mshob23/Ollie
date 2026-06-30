import HandheldNotesCore
import SwiftUI

/// The whole window: a notes-first split — the notes list on the left, and a
/// center column with the capture bar on top of the selected note's detail.
/// Settings opens as a sheet.
struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSettings = false

    /// Tracks which "bad sync" state we last raised a banner for, so we only toast
    /// on a *transition* into local-only / degraded — not on every fold event while
    /// already parked there. `nil` = currently healthy (idle/syncing).
    @State private var lastSurfacedSyncIssue: SyncIssueKind?

    /// The coarse kind of a sync issue worth a banner. Deliberately ignores the
    /// `.degraded(since:)` timestamp so a re-fold of the same degradation doesn't
    /// re-spam — only a change of *kind* (or recovery) is a transition.
    private enum SyncIssueKind: Equatable {
        case localOnly
        case degraded(SyncDegradation)
    }

    var body: some View {
        ZStack {
            WarmBackground()

            VStack(spacing: 0) {
                // Persistent capture area — the active DRAFT lives here, above the
                // whole window and independent of which note is selected.
                CaptureBar(onOpenSettings: { showSettings = true })
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .padding(.bottom, 10)

                Divider().overlay(Color.hcCardBorder.opacity(0.5))

                HStack(spacing: 0) {
                    NotesListView()
                        .overlay(Rectangle().fill(Color.hcCardBorder.opacity(0.5)).frame(width: 1), alignment: .trailing)

                    NoteDetailView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            // Transient banner (permission denied, save errors).
            if let banner = model.banner {
                VStack {
                    Spacer()
                    BannerView(text: banner) { model.banner = nil }
                        .padding(.bottom, 20)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.banner)
        .sheet(isPresented: $showSettings) {
            SettingsView(isPresented: $showSettings)
                .environmentObject(model)
        }
        .frame(minWidth: 880, minHeight: 560)
        .onChange(of: model.syncHealth) { _, newValue in
            surfaceSyncBannerIfNeeded(newValue)
        }
    }

    /// Raise a transient banner only when sync *transitions* into a bad state.
    /// Healthy states clear the latch so the next problem toasts again, but a
    /// steady-state degradation never re-toasts (kept non-spammy).
    private func surfaceSyncBannerIfNeeded(_ health: SyncHealth) {
        let issue: SyncIssueKind?
        switch health {
        case .idle, .syncing:
            issue = nil
        case .localOnly:
            issue = .localOnly
        case .degraded(let degradation, _):
            issue = .degraded(degradation)
        }

        // Only act on a change of issue kind (recovery resets the latch silently).
        guard issue != lastSurfacedSyncIssue else { return }
        lastSurfacedSyncIssue = issue

        switch issue {
        case .none:
            break
        case .localOnly:
            model.banner = "Not syncing - local only"
        case .degraded(let degradation):
            model.banner = degradation.userMessage
        }
    }
}

/// A bottom toast for transient messages.
struct BannerView: View {
    let text: String
    let dismiss: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color.hcAccent)
            Text(text)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.hcPrimaryText)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.hcMutedText)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 560)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.hcPanelRaised)
                .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.hcCardBorder, lineWidth: 1)
        )
        .padding(.horizontal, 24)
    }
}
