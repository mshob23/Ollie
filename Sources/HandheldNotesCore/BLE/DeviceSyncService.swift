import Foundation

/// High-level connection state of a device-sync session, surfaced to the UI.
public enum DeviceSyncState: Equatable, Sendable {
    case idle                       // not connected, not scanning
    case scanning                   // looking for the device
    case connecting                 // found it, connecting
    case connected                  // ready; file list known
    case transferring(file: String, progress: Double) // 0…1 for the current file
    case savingNote(file: String)   // transcribing + persisting a received file
    case error(String)
    case unavailable(String)        // BLE off / unsupported / no peripheral

    public var label: String {
        switch self {
        case .idle: return "Not connected"
        case .scanning: return "Scanning for device…"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .transferring(let f, let p): return "Receiving \(f) — \(Int(p * 100))%"
        case .savingNote(let f): return "Transcribing \(f)…"
        case .error(let m): return "Error: \(m)"
        case .unavailable(let m): return m
        }
    }

    public var isBusy: Bool {
        switch self {
        case .scanning, .connecting, .transferring, .savingNote: return true
        default: return false
        }
    }
}

/// Events a sync service reports back to the app as it works through a sync.
public enum DeviceSyncEvent: Sendable {
    case stateChanged(DeviceSyncState)
    case fileListUpdated([DeviceFile])
    /// A complete audio file was received and verified; the app should ingest it
    /// into a note, then call `confirmSaved(fileId:)` so the device can delete it.
    case fileReceived(fileId: UInt16, url: URL, suggestedSource: NoteSource)
    case log(String)
}

/// The abstraction both the mock and the real CoreBluetooth implementation
/// satisfy. The app talks only to this, so swapping mock ↔ BLE is a one-line
/// change and the firmware can be matched later without touching the UI.
@MainActor
public protocol DeviceSyncService: AnyObject {
    var displayName: String { get }
    /// The app sets this to receive state/file/received events.
    var onEvent: ((DeviceSyncEvent) -> Void)? { get set }

    /// Begin scanning / connecting and (for the mock) start the simulated sync.
    func startSync()
    /// Stop and disconnect.
    func stop()
    /// Tell the device a received file is now safely saved, so it may delete it.
    func confirmSaved(fileId: UInt16)
}
