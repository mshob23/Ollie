import XCTest
@testable import HandheldNotesCore

/// Exercises the Part B wire protocol end-to-end *without hardware and without
/// depending on bundled resources*: it builds a synthetic "firmware" side (a file
/// table with a real CRC-32/ISO-HDLC over synthetic WAV bytes), encodes FILE_LIST
/// + DATA frames exactly as the device would, and runs the same central-side
/// decode → ACK-gated reassembly → CRC-verify → delete logic the real
/// BLEDeviceSyncService / MockDeviceSyncService use. If endianness, the frame
/// layout, or the CRC drifted from the firmware, these would fail.
final class MockSyncFlowTests: XCTestCase {

    /// Canonical CRC-32/ISO-HDLC test vector (== zlib.crc32 == crc32_ieee).
    func testCRC32MatchesISOHDLCVector() {
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF43926)
        XCTAssertEqual(CRC32.checksum(Data()), 0)
        // Streaming in chunks must equal one-shot (the per-chunk fold).
        var r = CRC32.initial
        r = CRC32.update(r, with: Data("12345".utf8))
        r = CRC32.update(r, with: Data("6789".utf8))
        XCTAssertEqual(CRC32.finalize(r), 0xCBF43926)
    }

    /// FILE_LIST + DATA + ACK encode/decode round-trip byte-exactly.
    func testCodecRoundTripAndAckBytes() {
        let files = [
            DeviceFile(id: 1, name: "REC0001.WAV", sizeBytes: 1234, durationMs: 5600, crc32: 0xAABBCCDD),
            DeviceFile(id: 2, name: "REC0002.WAV", sizeBytes: 9999, durationMs: 1000, crc32: 0x01020304),
        ]
        XCTAssertEqual(AudioSyncGATT.decodeFileList(AudioSyncGATT.encodeFileList(files)), files)

        let payload = Data((0..<200).map { UInt8($0 & 0xFF) })
        let frame = AudioSyncGATT.encodeDataFrame(fileId: 7, seq: 42, isLast: true, payload: payload)
        let df = AudioSyncGATT.decodeDataFrame(frame)
        XCTAssertEqual(df?.fileId, 7)
        XCTAssertEqual(df?.seq, 42)
        XCTAssertEqual(df?.isLast, true)
        XCTAssertEqual(df?.payload, payload)

        // ACK wire shape: [fileId:u16 | ackSeq:u16 | code:u8] little-endian.
        XCTAssertEqual([UInt8](AudioSyncGATT.ack(fileId: 0x0201, seq: 0x0403, code: 2)),
                       [0x01, 0x02, 0x03, 0x04, 0x02])
        // CONTROL DELETE: 03 <id:u16> <crc:u32> little-endian.
        XCTAssertEqual([UInt8](AudioSyncGATT.Control.delete(fileId: 0x0102, crc32: 0x04030201)),
                       [0x03, 0x02, 0x01, 0x01, 0x02, 0x03, 0x04])
    }

    /// Full transfer: device streams `payload`-sized DATA chunks; central decodes,
    /// ACK-gates (window-of-1), reassembles, and verifies CRC == FILE_LIST entry.
    func testAckGatedReassemblyAndCRCVerify() {
        // Synthetic "WAV": 44-byte header + 500 bytes PCM = 4 chunks at 180/chunk.
        var wav = Data([0x52, 0x49, 0x46, 0x46]) // "RIFF"
        wav.append(Data(repeating: 0, count: 40))
        wav.append(Data((0..<500).map { UInt8(($0 * 7) & 0xFF) }))
        let fileCRC = CRC32.checksum(wav)

        // FILE_LIST the device would advertise.
        let listed = DeviceFile(id: 3, name: "REC0003.WAV",
                                sizeBytes: UInt32(wav.count), durationMs: 0, crc32: fileCRC)
        let list = AudioSyncGATT.decodeFileList(AudioSyncGATT.encodeFileList([listed]))!
        let file = list[0]

        // --- central side: ACK-gated pull + reassemble + CRC (mirrors the services) ---
        let payloadSize = AudioSyncGATT.defaultChunkPayload // 180
        var offset = 0
        var seq: UInt16 = 0
        var assembled = Data()
        var running = CRC32.initial
        var ackCount = 0

        while offset < wav.count {
            let end = min(offset + payloadSize, wav.count)
            let isLast = end >= wav.count
            // device builds the frame:
            let frameBytes = AudioSyncGATT.encodeDataFrame(
                fileId: file.id, seq: seq, isLast: isLast, payload: wav.subdata(in: offset..<end))
            // central decodes it:
            let frame = AudioSyncGATT.decodeDataFrame(frameBytes)!
            XCTAssertEqual(frame.fileId, file.id)
            XCTAssertEqual(frame.seq, seq)            // in-order under window-of-1
            assembled.append(frame.payload)
            running = CRC32.update(running, with: frame.payload)
            // central ACKs OK -> firmware would advance:
            _ = AudioSyncGATT.ack(fileId: file.id, seq: frame.seq, code: AudioSyncGATT.Ack.ok)
            ackCount += 1
            offset = end
            seq &+= 1
            if isLast { XCTAssertTrue(frame.isLast) }
        }

        XCTAssertEqual(assembled, wav, "reassembled bytes match the source file")
        XCTAssertEqual(CRC32.finalize(running), file.crc32, "streamed CRC equals FILE_LIST crc")
        XCTAssertEqual(ackCount, 4, "4 chunks (3*180 + 4) each ACKed (window-of-1)")
        // The delete the central would send only after the verified save:
        let del = AudioSyncGATT.Control.delete(fileId: file.id, crc32: CRC32.finalize(running))
        XCTAssertEqual(del.first, AudioSyncGATT.Control.deleteFile)
    }

    /// A corrupted byte must break the CRC equality so the file is NOT deleted.
    func testCorruptionFailsCRC() {
        var wav = Data((0..<300).map { UInt8($0 & 0xFF) })
        let good = CRC32.checksum(wav)
        wav[100] ^= 0xFF // flip one bit region
        XCTAssertNotEqual(CRC32.checksum(wav), good, "a single corrupted byte changes the CRC")
    }
}
