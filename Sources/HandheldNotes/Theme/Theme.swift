import SwiftUI

// MARK: - Theme
//
// The Claude-warm design system, ported to SwiftUI from the old AppKit app's
// Theme.swift + NSColor token set. Candlelit-paper background, cream text, a
// confident coral accent, soft rounded panels, and a New York serif for display
// headings. Same exact hex values as the old app so the family resemblance is
// real, not approximate.

extension Color {
    // Backgrounds (warm near-black "paper").
    static let hcBackground       = Color(red: 0.122, green: 0.118, blue: 0.114) // #1F1E1D
    static let hcBackgroundTop    = Color(red: 0.149, green: 0.137, blue: 0.125) // #262320
    static let hcBackgroundBottom = Color(red: 0.106, green: 0.100, blue: 0.094) // #1B1918

    // Recessed surfaces / panels.
    static let hcPanel       = Color(red: 0.102, green: 0.098, blue: 0.094)      // #1A1918
    static let hcPanelRaised  = Color(red: 0.145, green: 0.138, blue: 0.130)     // slightly lifted card
    static let hcCardBorder  = Color(red: 0.255, green: 0.239, blue: 0.216)      // #413D37 warm hairline

    // Text.
    static let hcPrimaryText   = Color(red: 0.925, green: 0.914, blue: 0.890)    // #ECE9E3 cream
    static let hcSecondaryText = Color(red: 0.659, green: 0.635, blue: 0.604)    // #A8A29A
    static let hcMutedText     = Color(red: 0.435, green: 0.416, blue: 0.388)    // #6F6A63

    // Accent (coral).
    static let hcAccent        = Color(red: 0.851, green: 0.467, blue: 0.341)    // #D97757
    static let hcAccentHover   = Color(red: 0.882, green: 0.541, blue: 0.408)    // #E18A68
    static let hcAccentPressed = Color(red: 0.761, green: 0.376, blue: 0.244)    // #C2603E
    static let hcOnAccent      = Color(red: 0.984, green: 0.965, blue: 0.933)    // #FBF6EE cream-on-coral

    // Soft accent tint for chips / selection.
    static let hcAccentSoft    = Color(red: 0.851, green: 0.467, blue: 0.341).opacity(0.16)
    static let hcOk            = Color(red: 0.498, green: 0.694, blue: 0.510)    // calm green
}

extension Font {
    /// Serif display face (New York) for headings.
    static func hcDisplay(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
    /// Tracked-caps eyebrow.
    static func hcEyebrow(_ size: CGFloat = 10.5) -> Font {
        .system(size: size, weight: .semibold)
    }
}

// MARK: - Reusable views

/// The window background: a barely-perceptible warm vertical gradient — candlelit
/// paper, not neon.
struct WarmBackground: View {
    var body: some View {
        LinearGradient(
            colors: [.hcBackgroundTop, .hcBackground, .hcBackgroundBottom],
            startPoint: .top, endPoint: .bottom)
        .ignoresSafeArea()
    }
}

/// A tracked-caps coral eyebrow label.
struct Eyebrow: View {
    let text: String
    var color: Color = .hcAccent
    var body: some View {
        Text(text.uppercased())
            .font(.hcEyebrow())
            .tracking(1.7)
            .foregroundStyle(color)
    }
}

/// A softly rounded recessed panel for content wells.
struct PanelBackground: ViewModifier {
    var fill: Color = .hcPanel
    var radius: CGFloat = 14
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Color.hcCardBorder.opacity(0.6), lineWidth: 1)
            )
    }
}

extension View {
    func hcPanel(fill: Color = .hcPanel, radius: CGFloat = 14) -> some View {
        modifier(PanelBackground(fill: fill, radius: radius))
    }
}

/// The app's primary capsule button (coral fill, cream text).
struct PrimaryButtonStyle: ButtonStyle {
    var enabled: Bool = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(Color.hcOnAccent)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(
                Capsule().fill(
                    configuration.isPressed ? Color.hcAccentPressed : Color.hcAccent)
            )
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Capsule())
    }
}

/// A quiet outlined secondary capsule button.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.hcPrimaryText)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(Color.hcPrimaryText.opacity(configuration.isPressed ? 0.10 : 0.0))
            )
            .overlay(Capsule().stroke(Color.hcPrimaryText.opacity(0.22), lineWidth: 1))
            .contentShape(Capsule())
    }
}

/// A small status dot.
struct StatusDot: View {
    var color: Color
    var pulsing: Bool = false
    @State private var on = false
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .opacity(pulsing ? (on ? 0.35 : 1) : 1)
            .animation(pulsing ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: on)
            .onAppear { if pulsing { on = true } }
    }
}

/// A small rounded source/metadata chip.
struct Chip: View {
    let symbol: String?
    let text: String
    var tint: Color = .hcSecondaryText
    init(_ text: String, symbol: String? = nil, tint: Color = .hcSecondaryText) {
        self.text = text; self.symbol = symbol; self.tint = tint
    }
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold)) }
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.12)))
    }
}
