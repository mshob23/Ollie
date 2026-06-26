import Foundation

/// Which capture surface is active *right now*. Computer = the Mac mic transcribes
/// live into the working draft; Local = the handheld records to its SD card offline
/// and the finished notes arrive over BLE on reconnect (no Mac-side drafting).
public enum CaptureMode: String, Codable, Sendable, Hashable {
    case computer
    case local

    public var label: String {
        switch self {
        case .computer: return "Computer"
        case .local:    return "Local"
        }
    }

    public var subtitle: String {
        switch self {
        case .computer: return "Live transcribe on this Mac"
        case .local:    return "Device records offline · sync on reconnect"
        }
    }

    public var symbol: String {
        switch self {
        case .computer: return "laptopcomputer"
        case .local:    return "externaldrive.badge.timemachine"
        }
    }
}

/// How the active `CaptureMode` is decided. **Manual** = the user flips Computer ⇄
/// Local themselves. **Automatic** = the app derives it from device connectivity
/// (connected/in-range → Computer; out of range → Local).
public enum ModeSelection: String, Codable, Sendable, Hashable {
    case manual
    case automatic

    public var label: String {
        switch self {
        case .manual:    return "Manual"
        case .automatic: return "Automatic"
        }
    }

    public var subtitle: String {
        switch self {
        case .manual:    return "You choose Computer or Local"
        case .automatic: return "Follow the device — in range talks to the computer, out of range stores locally"
        }
    }
}
