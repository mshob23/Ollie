import AVFoundation
import SwiftUI

/// A small AVAudioPlayer-backed transport with play/pause, a scrubber, and time
/// labels — styled to the warm palette. Used in the note detail pane.
@MainActor
final class AudioPlayerModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var loadedURL: URL?

    func load(_ url: URL?) {
        guard loadedURL != url else { return }
        stop()
        loadedURL = url
        guard let url else { player = nil; duration = 0; return }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.delegate = self
        player?.prepareToPlay()
        duration = player?.duration ?? 0
        currentTime = 0
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying { pause() } else { play() }
    }

    func play() {
        guard let player else { return }
        player.play()
        isPlaying = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.player else { return }
                self.currentTime = p.currentTime
            }
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        timer?.invalidate(); timer = nil
    }

    func stop() {
        player?.stop()
        player?.currentTime = 0
        isPlaying = false
        currentTime = 0
        timer?.invalidate(); timer = nil
    }

    func seek(to time: Double) {
        player?.currentTime = time
        currentTime = time
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.currentTime = 0
            self.timer?.invalidate(); self.timer = nil
        }
    }

    static func timeString(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let total = Int(t.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct AudioPlayerView: View {
    let url: URL?
    @StateObject private var playerModel = AudioPlayerModel()
    @State private var scrubbing = false

    var body: some View {
        HStack(spacing: 14) {
            Button(action: { playerModel.toggle() }) {
                ZStack {
                    Circle().fill(Color.hcAccent)
                        .frame(width: 40, height: 40)
                    Image(systemName: playerModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.hcOnAccent)
                        .offset(x: playerModel.isPlaying ? 0 : 1)
                }
            }
            .buttonStyle(.plain)
            .disabled(url == nil)

            VStack(alignment: .leading, spacing: 5) {
                Slider(
                    value: Binding(
                        get: { playerModel.currentTime },
                        set: { playerModel.seek(to: $0) }),
                    in: 0...(max(playerModel.duration, 0.01)),
                    onEditingChanged: { scrubbing = $0 })
                .tint(.hcAccent)
                .controlSize(.small)
                .disabled(url == nil)

                HStack {
                    Text(AudioPlayerModel.timeString(playerModel.currentTime))
                    Spacer()
                    Text(AudioPlayerModel.timeString(playerModel.duration))
                }
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Color.hcMutedText)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .hcPanel(fill: .hcPanel)
        .onAppear { playerModel.load(url) }
        .onChange(of: url) { _, newURL in playerModel.load(newURL) }
    }
}
