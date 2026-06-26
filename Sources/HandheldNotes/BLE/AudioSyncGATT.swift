import CoreBluetooth
import Foundation

// MARK: - Audio Sync GATT contract
//
// The custom BLE service the handheld will expose so the Mac can pull the voice
// recordings it captured to its SD card while offline, then tell it to delete
// them once they're safely saved as notes.
//
// Base UUID mirrors the keymap config service's "HCKM" convention; this one is
// "HCAS" = Handheld-Communicator Audio-Sync. The firmware must match these
// UUIDs and opcodes. Full prose protocol is in NOTES_APP_PLAN.md §5.
//
// Mac = GATT central. Device = peripheral. BLE is treated as BURST transfer
// (whole files, one at a time), not a live stream.

enum AudioSyncGATT {
    // Service + characteristics (string form 48434153-000X-4000-A000-…).
    static let serviceString  = "48434153-0001-4000-A000-000000000000"
    static let fileListString = "48434153-0002-4000-A000-000000000000" // Read / Notify: list of files
    static let controlString  = "48434153-0003-4000-A000-000000000000" // Write: central → device commands
    static let dataString     = "48434153-0004-4000-A000-000000000000" // Notify: chunk frames device → central
    static let ackString      = "48434153-0005-4000-A000-000000000000" // Write/Notify: per-chunk + status

    // Computed (not stored) so they don't become non-Sendable global mutable
    // state under Swift 6 strict concurrency — CBUUID isn't Sendable. They're
    // immutable value-like objects, so rebuilding per access is free.
    static var service:  CBUUID { CBUUID(string: serviceString) }
    static var fileList: CBUUID { CBUUID(string: fileListString) }
    static var control:  CBUUID { CBUUID(string: controlString) }
    static var data:     CBUUID { CBUUID(string: dataString) }
    static var ack:      CBUUID { CBUUID(string: ackString) }

    // CONTROL opcodes (central → device).
    enum Control {
        static let startTransfer: UInt8 = 0x01 // + fileId:u16
        static let abortTransfer: UInt8 = 0x02 // + fileId:u16
        static let deleteFile:    UInt8 = 0x03 // + fileId:u16 + crc32:u32  (only after a verified save)
        static let requestList:   UInt8 = 0x04

        static func start(fileId: UInt16) -> Data { packed(startTransfer, fileId) }
        static func abort(fileId: UInt16) -> Data { packed(abortTransfer, fileId) }
        static func delete(fileId: UInt16, crc32: UInt32) -> Data {
            var d = packed(deleteFile, fileId)
            withUnsafeBytes(of: crc32.littleEndian) { d.append(contentsOf: $0) }
            return d
        }
        static let requestListData = Data([requestList])

        private static func packed(_ op: UInt8, _ fileId: UInt16) -> Data {
            var d = Data([op])
            withUnsafeBytes(of: fileId.littleEndian) { d.append(contentsOf: $0) }
            return d
        }
    }

    // ACK codes (central → device, per chunk / windowed).
    enum Ack {
        static let ok:      UInt8 = 0
        static let resend:  UInt8 = 1
        static let crcFail: UInt8 = 2
    }

    /// Conservative default DATA payload size until the ATT MTU exchange
    /// completes (frame header is fileId:u16 + seq:u16 + flags:u8 = 5 bytes).
    static let defaultChunkPayload = 180
    static let frameHeaderBytes = 5
    static let lastChunkFlag: UInt8 = 0x01
}

/// One entry from the device's FILE_LIST characteristic. Sendable so it can cross
/// from the CoreBluetooth thread to the UI.
struct DeviceFile: Identifiable, Sendable, Hashable {
    let id: UInt16
    let name: String
    let sizeBytes: UInt32
    let durationMs: UInt32
    let crc32: UInt32

    var durationSeconds: Double { Double(durationMs) / 1000 }
}
