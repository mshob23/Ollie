import SwiftUI

/// The whole window: a notes-first split — the notes list on the left, and a
/// center column with the capture bar on top of the selected note's detail. A
/// device-sync panel slides in from the right; settings opens as a sheet.
struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSync = false
    @State private var showSettings = false

    var body: some View {
        ZStack {
            WarmBackground()

            HStack(spacing: 0) {
                NotesListView()
                    .overlay(Rectangle().fill(Color.hcCardBorder.opacity(0.5)).frame(width: 1), alignment: .trailing)

                centerColumn

                if showSync {
                    DeviceSyncPanel(isPresented: $showSync)
                        .transition(.move(edge: .trailing))
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
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showSync)
        .animation(.easeInOut(duration: 0.25), value: model.banner)
        .sheet(isPresented: $showSettings) {
            SettingsView(isPresented: $showSettings)
                .environmentObject(model)
        }
        .frame(minWidth: 880, minHeight: 560)
    }

    private var centerColumn: some View {
        VStack(spacing: 0) {
            toolbar
            CaptureBar()
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 4)
            NoteDetailView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Spacer()
            Button(action: { showSync.toggle() }) {
                HStack(spacing: 6) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                    Text("Device")
                }
            }
            .buttonStyle(SecondaryButtonStyle())
            .help("Sync recordings from the handheld device")

            Button(action: { showSettings = true }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.hcSecondaryText)
                    .padding(7)
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 2)
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
