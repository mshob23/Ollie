import AppKit

// The Quick Capture heads-up overlay: a floating card with the Siri-style
// "listening" meter, shown while a global-shortcut capture records/transcribes,
// then a brief "Saved to Ollie" flash. Ported from HandheldCompanionMac's
// RecordingOverlay (the WaveformView motion constants are owner-tuned via that
// repo's Tools/WaveTuner — retune there and transplant; do not tweak here).
// Palette adapted to Ollie's warm coral/cream theme.

// MARK: - Palette (NSColor mirrors of Ollie's SwiftUI Theme)

private enum OverlayColor {
    static let accent = NSColor(red: 0.851, green: 0.467, blue: 0.341, alpha: 1)      // hcAccent coral
    static let accentWarm = NSColor(red: 0.882, green: 0.541, blue: 0.408, alpha: 1)  // hcAccentHover peach
    static let ok = NSColor(red: 0.498, green: 0.694, blue: 0.510, alpha: 1)          // hcOk sage
    static let card = NSColor(red: 0.145, green: 0.138, blue: 0.130, alpha: 0.97)     // hcPanelRaised
    static let primaryText = NSColor(red: 0.925, green: 0.914, blue: 0.890, alpha: 1) // cream
    static let secondaryText = NSColor(red: 0.659, green: 0.635, blue: 0.604, alpha: 1)
}

private func serifDisplayFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    if let descriptor = base.fontDescriptor.withDesign(.serif),
       let serif = NSFont(descriptor: descriptor, size: size) {
        return serif
    }
    return base
}

private func eyebrowText(_ text: String) -> NSAttributedString {
    NSAttributedString(string: text.uppercased(), attributes: [
        .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
        .foregroundColor: OverlayColor.accent,
        .kern: 1.4,
    ])
}

// MARK: - Window controller

/// Owns the borderless floating window, its lower-third positioning on the
/// active screen, and the show/hide/flash lifecycle.
@MainActor
final class QuickCaptureOverlayController {
    private let overlayView = QuickCaptureOverlayView()
    private let window: NSWindow
    private var hideTask: Task<Void, Never>?
    private var flashTask: Task<Void, Never>?
    private var isFlashing = false

    init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 168),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        window.canHide = false
        window.isReleasedWhenClosed = false
        window.contentView = overlayView
    }

    func show(mode: QuickCaptureOverlayView.Mode) {
        cancelPendingHide()
        cancelFlash()
        overlayView.setMode(mode)
        positionOnActiveScreen()
        window.setIsVisible(true)
        window.orderFrontRegardless()
        overlayView.show()
    }

    func update(level: Float) {
        overlayView.update(level: level)
    }

    /// Hide unless a result flash is on screen — the flash owns its own dismissal.
    func hide() {
        guard !isFlashing else { return }
        overlayView.hide()
        cancelPendingHide()
        // Let the fade-out play before the window drops; a re-show cancels this.
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard !Task.isCancelled else { return }
            self?.window.orderOut(nil)
            self?.hideTask = nil
        }
    }

    /// The brief outcome toast ("Saved to Ollie", "Discarded"). Auto-dismisses;
    /// any new recording overlay replaces it.
    func flashResult(success: Bool, message: String, seconds: Double = 1.6) {
        cancelPendingHide()
        cancelFlash()
        isFlashing = true
        overlayView.setMode(.result(success: success, message: message))
        positionOnActiveScreen()
        window.setIsVisible(true)
        window.orderFrontRegardless()
        overlayView.show()
        flashTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.isFlashing = false
            self.flashTask = nil
            self.hide()
        }
    }

    private func cancelPendingHide() {
        hideTask?.cancel()
        hideTask = nil
    }

    private func cancelFlash() {
        flashTask?.cancel()
        flashTask = nil
        isFlashing = false
    }

    /// Lower third of the active screen — visible without sitting on top of
    /// whatever the user is dictating about.
    private func positionOnActiveScreen() {
        let screenFrame = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        window.setFrameOrigin(NSPoint(
            x: screenFrame.midX - window.frame.width / 2,
            y: screenFrame.minY + screenFrame.height * 0.16))
    }
}

// MARK: - Overlay card

@MainActor
final class QuickCaptureOverlayView: NSView {
    enum Mode {
        case recording
        case transcribing
        case result(success: Bool, message: String)
    }

    private let waveformView = OverlayWaveformView()
    private let stateDot = OverlayStatusDot()
    private let eyebrow = NSTextField(labelWithString: "")
    private let headline = NSTextField(labelWithString: "Listening…")
    private let timeLabel = NSTextField(labelWithString: "0:00")
    private var isShown = false
    private var lastAudioLevel: CGFloat = 0.08
    private var idlePhase: CGFloat = 0
    private var animationTimer: Timer?
    private var mode: Mode = .recording
    private var startDate = Date()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = OverlayColor.card.cgColor
        layer?.cornerRadius = 24
        layer?.borderWidth = 1
        layer?.borderColor = OverlayColor.accent.withAlphaComponent(0.28).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.4
        layer?.shadowRadius = 24
        layer?.shadowOffset = NSSize(width: 0, height: -8)
        isHidden = true
        alphaValue = 0
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        guard !isShown else { return }
        isShown = true
        isHidden = false
        alphaValue = 0
        startDate = Date()
        timeLabel.stringValue = "0:00"
        waveformView.reset()
        startAnimation()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 1
        }
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        stopAnimation()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                self?.isHidden = true
                self?.alphaValue = 0
            }
        }
    }

    func update(level: Float) {
        lastAudioLevel = max(0.04, min(1, CGFloat(level)))
    }

    func setMode(_ mode: Mode) {
        self.mode = mode
        switch mode {
        case .recording:
            eyebrow.attributedStringValue = eyebrowText("Quick Capture")
            headline.font = serifDisplayFont(size: 24, weight: .medium)
            headline.stringValue = "Listening…"
            timeLabel.isHidden = false
            stateDot.set(color: OverlayColor.accent, pulsing: true)
        case .transcribing:
            eyebrow.attributedStringValue = eyebrowText("Transcribing")
            headline.font = serifDisplayFont(size: 24, weight: .medium)
            headline.stringValue = "Saving your note…"
            timeLabel.isHidden = false
            stateDot.set(color: OverlayColor.accentWarm, pulsing: true)
        case let .result(success, message):
            eyebrow.attributedStringValue = eyebrowText(success ? "Done" : "Heads up")
            headline.font = serifDisplayFont(size: 18, weight: .medium)
            headline.stringValue = message
            timeLabel.isHidden = true
            stateDot.set(color: success ? OverlayColor.ok : OverlayColor.accent, pulsing: false)
        }
    }

    private func startAnimation() {
        animationTimer?.invalidate()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickWaveform() }
        }
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        lastAudioLevel = 0.08
    }

    private func tickWaveform() {
        switch mode {
        case .recording:
            // Real mic level with a little gain so normal speech fills the height.
            waveformView.organicMotion = true
            waveformView.push(target: min(1, lastAudioLevel * 1.707))
            let seconds = max(0, Int(Date().timeIntervalSince(startDate)))
            let formatted = String(format: "%d:%02d", seconds / 60, seconds % 60)
            if timeLabel.stringValue != formatted { timeLabel.stringValue = formatted }
        case .transcribing:
            // One slow synchronized breath (~2s) while "thinking".
            waveformView.organicMotion = false
            idlePhase += 0.055
            let pulse = 0.26 + 0.22 * (0.5 + 0.5 * sin(idlePhase))
            waveformView.push(target: pulse)
        case .result:
            waveformView.organicMotion = false
            waveformView.push(target: 0)
        }
    }

    private func buildUI() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 14
        stack.alignment = .width
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        eyebrow.attributedStringValue = eyebrowText("Quick Capture")

        headline.font = serifDisplayFont(size: 24, weight: .medium)
        headline.textColor = OverlayColor.primaryText
        headline.lineBreakMode = .byTruncatingTail
        headline.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        headline.alignment = .center

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        timeLabel.textColor = OverlayColor.secondaryText

        stateDot.set(color: OverlayColor.accent, pulsing: true)

        let eyebrowRow = NSStackView()
        eyebrowRow.orientation = .horizontal
        eyebrowRow.spacing = 7
        eyebrowRow.alignment = .centerY
        eyebrowRow.addArrangedSubview(stateDot)
        eyebrowRow.addArrangedSubview(eyebrow)
        eyebrowRow.addArrangedSubview(NSView())
        eyebrowRow.addArrangedSubview(timeLabel)

        let labelStack = NSStackView()
        labelStack.orientation = .vertical
        labelStack.spacing = 4
        labelStack.alignment = .width
        labelStack.addArrangedSubview(eyebrowRow)
        labelStack.addArrangedSubview(headline)

        waveformView.heightAnchor.constraint(greaterThanOrEqualToConstant: 54).isActive = true
        waveformView.setContentHuggingPriority(.init(1), for: .vertical)
        stack.addArrangedSubview(labelStack)
        stack.addArrangedSubview(waveformView)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
            labelStack.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            labelStack.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            eyebrowRow.leadingAnchor.constraint(equalTo: labelStack.leadingAnchor),
            eyebrowRow.trailingAnchor.constraint(equalTo: labelStack.trailingAnchor),
            headline.leadingAnchor.constraint(equalTo: labelStack.leadingAnchor),
            headline.trailingAnchor.constraint(equalTo: labelStack.trailingAnchor),
        ])
    }
}

// MARK: - The Siri-style listening meter (motion constants owner-tuned — do not tweak)

/// A fixed, center-weighted cluster of rounded bars that swell in place with the
/// live mic level. Center bars respond most/fastest; outer bars follow with lag,
/// so speech blooms outward. While recording each bar carries decorrelated
/// shimmer; in synchronized mode the cluster breathes as one.
private final class OverlayWaveformView: NSView {
    private let barCount = 38
    private let restingLevel: CGFloat = 0.019
    private var displayLevels: [CGFloat]
    private var driveLevel: CGFloat = 0
    private var phases: [CGFloat]
    private let shimmerSpeeds: [CGFloat]
    /// Fixed irregular per-bar gains — the tall-short-tall pattern that makes the
    /// silhouette read as a waveform instead of a smooth hill. Deterministic.
    private let barGains: [CGFloat]
    private static let barGainPattern: [CGFloat] = [
        0.60, 0.92, 0.55, 1.0, 0.70, 0.88, 1.0, 0.82, 0.62, 0.96, 0.58, 0.90, 0.52,
    ]

    var organicMotion = true

    override init(frame frameRect: NSRect) {
        displayLevels = Array(repeating: restingLevel, count: barCount)
        // Golden-angle phase spread + varied speeds decorrelate neighbors, no RNG.
        phases = (0..<barCount).map { CGFloat($0) * 2.39996 }
        shimmerSpeeds = (0..<barCount).map { 0.518 + 0.131 * CGFloat(($0 * 5) % 7) }
        barGains = (0..<barCount).map { Self.barGainPattern[$0 % Self.barGainPattern.count] }
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reset() {
        displayLevels = Array(repeating: restingLevel, count: barCount)
        driveLevel = 0
        needsDisplay = true
    }

    func push(target: CGFloat) {
        let clamped = max(0, min(1, target))
        let driveRate: CGFloat = clamped > driveLevel ? 0.276 : 0.288
        driveLevel += (clamped - driveLevel) * driveRate

        let center = CGFloat(barCount - 1) / 2
        for index in 0..<barCount {
            let distance = abs(CGFloat(index) - center) / center

            let barTarget: CGFloat
            let barRate: CGFloat
            if organicMotion {
                let bias = 0.220 + 0.780 * cos(distance * .pi / 2)
                phases[index] += shimmerSpeeds[index]
                let phase = phases[index]
                let wobble = (sin(phase) + 0.332 * sin(phase * 1.9 + CGFloat(index)))
                    * (0.118 + 0.742 * driveLevel)
                barTarget = max(restingLevel, min(1, driveLevel * bias * barGains[index] * (1 + wobble)))
                barRate = 0.370 + 0.159 * (1 - distance)
            } else {
                let dome = 0.30 + 0.70 * pow(cos(distance * .pi / 2), 1.5)
                barTarget = max(restingLevel, driveLevel * dome)
                barRate = 0.30
            }
            displayLevels[index] += (barTarget - displayLevels[index]) * barRate
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard bounds.width > 0, bounds.height > 0 else { return }

        let slot = min(bounds.width / CGFloat(barCount + 2), 22)
        let barWidth = max(4, slot * 0.42)
        let clusterWidth = slot * CGFloat(barCount)
        let startX = bounds.midX - clusterWidth / 2
        let centerY = bounds.midY
        let maxHalf = bounds.height * 0.46
        let minHalf: CGFloat = 2.4
        let center = CGFloat(barCount - 1) / 2

        for (index, level) in displayLevels.enumerated() {
            let half = max(minHalf, maxHalf * level)
            let x = startX + CGFloat(index) * slot + (slot - barWidth) / 2
            let rect = NSRect(x: x, y: centerY - half, width: barWidth, height: half * 2)
            let path = NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2)

            // Louder bars warm from coral toward peach; edges sit quieter so the
            // cluster reads as one glowing center.
            let distance = abs(CGFloat(index) - center) / center
            let warmth = min(1, level) * 0.55
            let alpha = 0.52 + 0.48 * (1 - distance * 0.55)
            let color = (OverlayColor.accent.blended(withFraction: warmth, of: OverlayColor.accentWarm)
                ?? OverlayColor.accent).withAlphaComponent(alpha)

            if level > 0.5 {
                NSGraphicsContext.saveGraphicsState()
                let glow = NSShadow()
                glow.shadowColor = OverlayColor.accent.withAlphaComponent(0.55 * min(1, (level - 0.5) / 0.5))
                glow.shadowBlurRadius = 7
                glow.shadowOffset = .zero
                glow.set()
                color.setFill()
                path.fill()
                NSGraphicsContext.restoreGraphicsState()
            } else {
                color.setFill()
                path.fill()
            }
        }
    }
}

// MARK: - Pulsing status dot

private final class OverlayStatusDot: NSView {
    private var pulsing = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 4
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 8),
            heightAnchor.constraint(equalToConstant: 8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func set(color: NSColor, pulsing: Bool) {
        layer?.backgroundColor = color.cgColor
        guard pulsing != self.pulsing else { return }
        self.pulsing = pulsing
        layer?.removeAnimation(forKey: "pulse")
        if pulsing {
            let anim = CABasicAnimation(keyPath: "opacity")
            anim.fromValue = 1.0
            anim.toValue = 0.35
            anim.duration = 0.8
            anim.autoreverses = true
            anim.repeatCount = .infinity
            layer?.add(anim, forKey: "pulse")
        }
    }
}
