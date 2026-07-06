import HandheldNotesCore
import SwiftUI

/// The whole window: a notes-first split — the notes list on the left, and a
/// center column with the capture bar on top of the selected note's detail.
/// Settings opens as a sheet.
struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSettings = false

    /// Which pane fills the two columns: the notes list + note detail (default), or
    /// the Views feed + view detail (contract §5, plan M5 5f). A segmented control in
    /// the header toggles between them.
    @State private var pane: RootPane = .notes
    /// The view the Mac Views feed has selected (drives the Views detail pane). Held
    /// here so it survives a pane toggle.
    @State private var selectedViewName: String?

    enum RootPane: Hashable { case notes, views }

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

                // Pane switch: Notes list / Views feed. Kept compact and left-aligned
                // so it reads as a mode toggle, not a primary navigation bar.
                HStack(spacing: 0) {
                    Picker("", selection: $pane) {
                        Label("Notes", systemImage: "note.text").tag(RootPane.notes)
                        Label("Views", systemImage: "rectangle.stack").tag(RootPane.views)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    Spacer()
                }

                Divider().overlay(Color.hcCardBorder.opacity(0.5))

                HStack(spacing: 0) {
                    switch pane {
                    case .notes:
                        NotesListView()
                            .overlay(Rectangle().fill(Color.hcCardBorder.opacity(0.5)).frame(width: 1), alignment: .trailing)
                        NoteDetailView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .views:
                        ViewsFeedPane(selectedViewName: $selectedViewName)
                            .overlay(Rectangle().fill(Color.hcCardBorder.opacity(0.5)).frame(width: 1), alignment: .trailing)
                        ViewDetailPane(selectedViewName: $selectedViewName, onOpenNote: openNote)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
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

    /// Open a note cited from a view (`ollie://note/<uuid>`): select it and flip the
    /// pane back to Notes so the note detail is on screen. If the id isn't a known
    /// note (e.g. a restricted/deleted note), select nothing and still switch — the
    /// detail pane's empty state is the graceful landing.
    private func openNote(_ id: UUID) {
        if model.notes.contains(where: { $0.id == id }) {
            model.selectedNoteID = id
        }
        pane = .notes
    }

    /// Raise a transient GLOBAL banner only when sync *transitions* into a real
    /// failure — `.degraded`. We deliberately do NOT global-toast `.localOnly`: it's
    /// a steady, non-error state already shown durably in the Settings sync row, and
    /// `model.banner` is the shared, no-auto-dismiss channel that also carries
    /// errors — a transient sync toast parked there can mask or clobber a real error
    /// banner. So `.localOnly` only updates the latch (keeping the
    /// transition/recovery bookkeeping honest) without ever toasting.
    ///
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
        case .none, .localOnly:
            // Recovery (.none) and the steady .localOnly state both stay silent on
            // the global banner — only the latch above is updated. .localOnly is
            // surfaced durably in Settings instead.
            break
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
