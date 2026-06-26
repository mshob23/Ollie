import Foundation

/// Which capture surface is active *right now*. Computer = the Mac mic transcribes
/// live into the working draft; Local = the handheld records to its SD card offline
/// and the finished notes arrive over BLE on reconnect (no Mac-side drafting).
enum CaptureMode: String, Codable, Sendable, Hashable {
    case computer
    case local

    var label: String {
        switch self {
        case .computer: return "Computer"
        case .local:    return "Local"
        }
    }

    var subtitle: String {
        switch self {
        case .computer: return "Live transcribe on this Mac"
        case .local:    return "Device records offline · sync on reconnect"
        }
    }

    var symbol: String {
        switch self {
        case .computer: return "laptopcomputer"
        case .local:    return "externaldrive.badge.timemachine"
        }
    }
}

/// How the active `CaptureMode` is decided. **Manual** = the user flips Computer ⇄
/// Local themselves. **Automatic** = the app derives it from device connectivity
/// (connected/in-range → Computer; out of range → Local).
enum ModeSelection: String, Codable, Sendable, Hashable {
    case manual
    case automatic

    var label: String {
        switch self {
        case .manual:    return "Manual"
        case .automatic: return "Automatic"
        }
    }

    var subtitle: String {
        switch self {
        case .manual:    return "You choose Computer or Local"
        case .automatic: return "Follow the device — in range talks to the computer, out of range stores locally"
        }
    }
}
