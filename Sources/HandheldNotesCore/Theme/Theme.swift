import SwiftUI

// MARK: - Theme
//
// The "Seal Night" design system — Oliver's colorway. Same structure as the
// original candlelit theme (soft rounded panels, cream text, New York serif
// display headings), re-inked from the cat the app is named for: the ground
// pulled a hair sealward (a seal-point's dark coat), and the accent is
// Siamese-eye blue — the only saturated color, spent where the app looks back
// at you. Ok is a quiet fern; danger a muted madder that can never be read as
// the accent.
//
// Cross-platform by construction: built on SwiftUI `Color` / `Font` only (no
// NSColor / AppKit), so this same theme drives the iOS + watch apps unchanged.

extension Color {
    // Backgrounds. Warm in HUE, near-zero in CHROMA (~9% saturation — matching the
    // panels below at 8-10%). The eye-blue accent sits nearly opposite these on the
    // wheel, so ANY visible brown competes with it: a first pass at 36-45% read as a
    // brown halo around neutral cards, and even 18% still registered as warmth
    // fighting the blue in daily use. Do not re-warm these to "match the seal coat" —
    // the coat lives in the icon and the cream text; the ground stays out of the way
    // so blue is the only color on screen.
    public static let hcBackground       = Color(red: 0.129, green: 0.122, blue: 0.118) // #211F1E
    public static let hcBackgroundTop    = Color(red: 0.157, green: 0.149, blue: 0.141) // #282624
    public static let hcBackgroundBottom = Color(red: 0.114, green: 0.106, blue: 0.102) // #1D1B1A

    // Recessed surfaces / panels.
    public static let hcPanel       = Color(red: 0.102, green: 0.098, blue: 0.094)      // #1A1918
    public static let hcPanelRaised  = Color(red: 0.145, green: 0.138, blue: 0.130)     // slightly lifted card
    public static let hcCardBorder  = Color(red: 0.255, green: 0.239, blue: 0.216)      // #413D37 warm hairline

    // Text.
    public static let hcPrimaryText   = Color(red: 0.925, green: 0.914, blue: 0.890)    // #ECE9E3 cream
    public static let hcSecondaryText = Color(red: 0.659, green: 0.635, blue: 0.604)    // #A8A29A
    public static let hcMutedText     = Color(red: 0.435, green: 0.416, blue: 0.388)    // #6F6A63

    // Accent (Siamese-eye blue).
    public static let hcAccent        = Color(red: 0.357, green: 0.561, blue: 0.788)    // #5B8FC9
    public static let hcAccentHover   = Color(red: 0.471, green: 0.651, blue: 0.839)    // #78A6D6
    public static let hcAccentPressed = Color(red: 0.290, green: 0.475, blue: 0.690)    // #4A79B0
    public static let hcOnAccent      = Color(red: 0.984, green: 0.965, blue: 0.933)    // #FBF6EE cream-on-blue

    // Soft accent tint for chips / selection.
    public static let hcAccentSoft    = Color(red: 0.357, green: 0.561, blue: 0.788).opacity(0.16)
    public static let hcOk            = Color(red: 0.482, green: 0.659, blue: 0.459)    // #7BA875 quiet fern, cooled to sit beside blue
    public static let syncDanger      = Color(red: 0.659, green: 0.271, blue: 0.235)   // #A8453C muted madder for failures — never reads as accent
}

extension Font {
    /// Serif display face (New York) for headings.
    public static func hcDisplay(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
    /// Tracked-caps eyebrow.
    public static func hcEyebrow(_ size: CGFloat = 10.5) -> Font {
        .system(size: size, weight: .semibold)
    }
}

// MARK: - Reusable views

/// The window background: a barely-perceptible warm vertical gradient — candlelit
/// paper, not neon.
public struct WarmBackground: View {
    public init() {}
    public var body: some View {
        LinearGradient(
            colors: [.hcBackgroundTop, .hcBackground, .hcBackgroundBottom],
            startPoint: .top, endPoint: .bottom)
        .ignoresSafeArea()
    }
}

/// A tracked-caps coral eyebrow label.
public struct Eyebrow: View {
    let text: String
    var color: Color = .hcAccent
    public init(text: String, color: Color = .hcAccent) {
        self.text = text
        self.color = color
    }
    public var body: some View {
        Text(text.uppercased())
            .font(.hcEyebrow())
            .tracking(1.7)
            .foregroundStyle(color)
    }
}

/// A softly rounded recessed panel for content wells.
public struct PanelBackground: ViewModifier {
    var fill: Color = .hcPanel
    var radius: CGFloat = 14
    public init(fill: Color = .hcPanel, radius: CGFloat = 14) {
        self.fill = fill
        self.radius = radius
    }
    public func body(content: Content) -> some View {
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
    public func hcPanel(fill: Color = .hcPanel, radius: CGFloat = 14) -> some View {
        modifier(PanelBackground(fill: fill, radius: radius))
    }
}

/// The app's primary capsule button (coral fill, cream text).
public struct PrimaryButtonStyle: ButtonStyle {
    var enabled: Bool = true
    public init(enabled: Bool = true) { self.enabled = enabled }
    public func makeBody(configuration: Configuration) -> some View {
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
public struct SecondaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
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
public struct StatusDot: View {
    var color: Color
    var pulsing: Bool = false
    @State private var on = false
    public init(color: Color, pulsing: Bool = false) {
        self.color = color
        self.pulsing = pulsing
    }
    public var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .opacity(pulsing ? (on ? 0.35 : 1) : 1)
            .animation(pulsing ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: on)
            .onAppear { if pulsing { on = true } }
    }
}

/// A small rounded source/metadata chip.
public struct Chip: View {
    let symbol: String?
    let text: String
    var tint: Color = .hcSecondaryText
    public init(_ text: String, symbol: String? = nil, tint: Color = .hcSecondaryText) {
        self.text = text; self.symbol = symbol; self.tint = tint
    }
    public var body: some View {
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
