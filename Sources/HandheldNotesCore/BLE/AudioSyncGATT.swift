import CoreBluetooth
import Foundation

// MARK: - Audio Sync GATT contract
//
// The custom BLE service the handheld exposes so the Mac can pull the voice
// recordings it captured to its SD card while offline, then tell it to delete
// them once they're safely saved as notes.
//
// Base UUID mirrors the keymap config service's "HCKM" convention; this one is
// "HCAS" = Handheld-Communicator Audio-Sync. The firmware
// (HandheldCommunicator-nRF/src/audio_sync.c) matches these UUIDs, opcodes, and
// frame layout byte-for-byte. Full prose protocol is in NOTES_APP_PLAN.md §5 and
// RECORDER_PLAN.md §12. **All multi-byte integers are little-endian.**
//
// Mac = GATT central. Device = peripheral. BLE is treated as BURST transfer
// (whole files, one at a time), not a live stream.

public enum AudioSyncGATT {
    // Service + characteristics (string form 48434153-000X-4000-A000-…).
    public static let serviceString  = "48434153-0001-4000-A000-000000000000"
    public static let fileListString = "48434153-0002-4000-A000-000000000000" // Read / Notify: list of files
    public static let controlString  = "48434153-0003-4000-A000-000000000000" // Write: central → device commands
    public static let dataString     = "48434153-0004-4000-A000-000000000000" // Notify: chunk frames device → central
    public static let ackString      = "48434153-0005-4000-A000-000000000000" // Write/Notify: per-chunk + status

    // Computed (not stored) so they don't become non-Sendable global mutable
    // state under Swift 6 strict concurrency — CBUUID isn't Sendable. They're
    // immutable value-like objects, so rebuilding per access is free.
    public static var service:  CBUUID { CBUUID(string: serviceString) }
    public static var fileList: CBUUID { CBUUID(string: fileListString) }
    public static var control:  CBUUID { CBUUID(string: controlString) }
    public static var data:     CBUUID { CBUUID(string: dataString) }
    public static var ack:      CBUUID { CBUUID(string: ackString) }

    // CONTROL opcodes (central → device). Wire: `op:u8` then LE args.
    public enum Control {
        public static let startTransfer: UInt8 = 0x01 // + fileId:u16
        public static let abortTransfer: UInt8 = 0x02 // + fileId:u16
        public static let deleteFile:    UInt8 = 0x03 // + fileId:u16 + crc32:u32  (only after a verified save)
        public static let requestList:   UInt8 = 0x04

        public static func start(fileId: UInt16) -> Data { packed(startTransfer, fileId) }
        public static func abort(fileId: UInt16) -> Data { packed(abortTransfer, fileId) }
        public static func delete(fileId: UInt16, crc32: UInt32) -> Data {
            var d = packed(deleteFile, fileId)
            withUnsafeBytes(of: crc32.littleEndian) { d.append(contentsOf: $0) }
            return d
        }
        public static let requestListData = Data([requestList])

        private static func packed(_ op: UInt8, _ fileId: UInt16) -> Data {
            var d = Data([op])
            withUnsafeBytes(of: fileId.littleEndian) { d.append(contentsOf: $0) }
            return d
        }
    }

    // ACK codes (central → device, per chunk / windowed).
    public enum Ack {
        public static let ok:      UInt8 = 0
        public static let resend:  UInt8 = 1
        public static let crcFail: UInt8 = 2
    }

    /// Conservative default DATA payload size until the ATT MTU exchange
    /// completes (frame header is fileId:u16 + seq:u16 + flags:u8 = 5 bytes).
    public static let defaultChunkPayload = 180
    public static let frameHeaderBytes = 5
    public static let lastChunkFlag: UInt8 = 0x01

    // MARK: - ACK frame (central → device)

    /// Encode an ACK write: `[fileId:u16 | ackSeq:u16 | code:u8]` (little-endian).
    /// The firmware's `hcas_write_ack` parses exactly these 5 bytes and only acts
    /// when `fileId` matches the in-flight transfer; `code` is one of `Ack.*`.
    public static func ack(fileId: UInt16, seq: UInt16, code: UInt8) -> Data {
        var d = Data()
        withUnsafeBytes(of: fileId.littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: seq.littleEndian)    { d.append(contentsOf: $0) }
        d.append(code)
        return d
    }

    // MARK: - DATA frame (device → central)

    /// One reassembly chunk decoded from a DATA notification:
    /// `[fileId:u16 | seq:u16 | flags:u8 | payload…]`. `isLast` is flags bit0.
    public struct DataFrame: Sendable, Equatable {
        public let fileId: UInt16
        public let seq: UInt16
        public let flags: UInt8
        public let payload: Data

        public var isLast: Bool { (flags & AudioSyncGATT.lastChunkFlag) != 0 }

        public init(fileId: UInt16, seq: UInt16, flags: UInt8, payload: Data) {
            self.fileId = fileId
            self.seq = seq
            self.flags = flags
            self.payload = payload
        }
    }

    /// Parse a DATA notification into a `DataFrame`. Returns nil if it's shorter
    /// than the 5-byte header (a malformed/empty notify). The payload may be empty
    /// (a zero-length final chunk is legal).
    public static func decodeDataFrame(_ data: Data) -> DataFrame? {
        guard data.count >= frameHeaderBytes else { return nil }
        // Index relative to startIndex — Data slices don't necessarily start at 0.
        let b = [UInt8](data)
        let fileId = UInt16(b[0]) | (UInt16(b[1]) << 8)
        let seq    = UInt16(b[2]) | (UInt16(b[3]) << 8)
        let flags  = b[4]
        let payload = Data(b[frameHeaderBytes...])
        return DataFrame(fileId: fileId, seq: seq, flags: flags, payload: payload)
    }

    /// Encode a DATA frame back to wire bytes — used by the mock device so its
    /// notifications are byte-identical to the firmware's `hcas_notify_frame`.
    public static func encodeDataFrame(fileId: UInt16, seq: UInt16, isLast: Bool, payload: Data) -> Data {
        var d = Data()
        withUnsafeBytes(of: fileId.littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: seq.littleEndian)    { d.append(contentsOf: $0) }
        d.append(isLast ? lastChunkFlag : 0)
        d.append(payload)
        return d
    }

    // MARK: - FILE_LIST payload (device → central)

    /// Decode the packed FILE_LIST characteristic into `[DeviceFile]`. Layout
    /// (matches `hcas_build_file_list`, all integers little-endian):
    ///
    ///     u8   count
    ///     repeat count times:
    ///       u16  id            (1-based, == the id to pass to START/DELETE)
    ///       u8   nameLen
    ///       u8[] name          (ASCII)
    ///       u32  sizeBytes
    ///       u32  durationMs
    ///       u32  crc32
    ///
    /// Returns nil only if the buffer is empty (not even a count byte). A
    /// truncated record (the firmware caps the list to one ATT payload) yields the
    /// records that fully parsed.
    public static func decodeFileList(_ data: Data) -> [DeviceFile]? {
        let b = [UInt8](data)
        guard !b.isEmpty else { return nil }
        var i = 0
        let count = Int(b[i]); i += 1

        var files: [DeviceFile] = []
        files.reserveCapacity(count)

        func u16() -> UInt16? {
            guard i + 2 <= b.count else { return nil }
            let v = UInt16(b[i]) | (UInt16(b[i + 1]) << 8); i += 2; return v
        }
        func u32() -> UInt32? {
            guard i + 4 <= b.count else { return nil }
            let v = UInt32(b[i]) | (UInt32(b[i + 1]) << 8)
                  | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
            i += 4; return v
        }

        for _ in 0..<count {
            guard let id = u16() else { break }
            guard i < b.count else { break }
            let nameLen = Int(b[i]); i += 1
            guard i + nameLen <= b.count else { break }
            let name = String(decoding: b[i..<(i + nameLen)], as: UTF8.self); i += nameLen
            guard let sizeBytes = u32(), let durationMs = u32(), let crc32 = u32() else { break }
            files.append(DeviceFile(id: id, name: name, sizeBytes: sizeBytes,
                                    durationMs: durationMs, crc32: crc32))
        }
        return files
    }

    /// Encode a `[DeviceFile]` list back into the packed FILE_LIST wire bytes —
    /// used by the mock device so its FILE_LIST read/notify is byte-identical to
    /// `hcas_build_file_list`. (Round-trips with `decodeFileList`.)
    public static func encodeFileList(_ files: [DeviceFile]) -> Data {
        var d = Data()
        d.append(UInt8(min(files.count, 255)))
        for f in files {
            withUnsafeBytes(of: f.id.littleEndian) { d.append(contentsOf: $0) }
            let nameBytes = Array(f.name.utf8)
            d.append(UInt8(min(nameBytes.count, 255)))
            d.append(contentsOf: nameBytes.prefix(255))
            withUnsafeBytes(of: f.sizeBytes.littleEndian)  { d.append(contentsOf: $0) }
            withUnsafeBytes(of: f.durationMs.littleEndian) { d.append(contentsOf: $0) }
            withUnsafeBytes(of: f.crc32.littleEndian)      { d.append(contentsOf: $0) }
        }
        return d
    }
}

/// One entry from the device's FILE_LIST characteristic. Sendable so it can cross
/// from the CoreBluetooth thread to the UI.
public struct DeviceFile: Identifiable, Sendable, Hashable {
    public let id: UInt16
    public let name: String
    public let sizeBytes: UInt32
    public let durationMs: UInt32
    public let crc32: UInt32

    public var durationSeconds: Double { Double(durationMs) / 1000 }

    public init(id: UInt16, name: String, sizeBytes: UInt32, durationMs: UInt32, crc32: UInt32) {
        self.id = id
        self.name = name
        self.sizeBytes = sizeBytes
        self.durationMs = durationMs
        self.crc32 = crc32
    }
}

// MARK: - CRC-32/ISO-HDLC

/// CRC-32/ISO-HDLC — reflected polynomial `0xEDB88320`, init `0xFFFFFFFF`, final
/// XOR `0xFFFFFFFF`. This is *exactly* `zlib.crc32`, Zephyr's `crc32_ieee()` /
/// `crc32_ieee_update()`, and therefore the value the firmware puts in FILE_LIST
/// and re-checks on `DELETE_FILE`. The end-to-end verification is a plain equality
/// of this over the reassembled file against the FILE_LIST entry's `crc32`.
public enum CRC32 {
    /// Lazily-built 256-entry lookup table for the reflected `0xEDB88320` poly.
    private static let table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    /// CRC over a buffer (init + finalize in one shot).
    public static func checksum(_ data: Data) -> UInt32 {
        finalize(update(initial, with: data))
    }

    /// Running-CRC seed. Feed chunks via `update(_:with:)`, then `finalize(_:)`.
    public static let initial: UInt32 = 0xFFFF_FFFF

    /// Fold `data` into a running CRC `crc` (which must have started at `initial`).
    public static func update(_ crc: UInt32, with data: Data) -> UInt32 {
        var c = crc
        for byte in data {
            c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
        }
        return c
    }

    /// Apply the final XOR to a running CRC to get the published checksum.
    public static func finalize(_ crc: UInt32) -> UInt32 { crc ^ 0xFFFF_FFFF }
}
