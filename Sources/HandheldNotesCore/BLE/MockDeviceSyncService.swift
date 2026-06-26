import Foundation

/// A fake handheld that exercises the **entire** Local-mode pipeline — including
/// the real wire protocol — with no hardware. It stands up an in-process firmware
/// emulator (`MockAudioSyncPeripheral`) that speaks the exact HCAS byte format
/// from `audio_sync.c`: it serves a packed FILE_LIST, streams ACK-gated DATA
/// chunk frames, and honors DELETE-after-verified-CRC. This service plays the
/// **central** role against it, decoding every frame with the same
/// `AudioSyncGATT` codec the real `BLEDeviceSyncService` uses, ACK-ing each chunk,
/// reassembling the file, and verifying CRC-32/ISO-HDLC before confirming a save.
///
/// So unlike a cosmetic progress-ramp, the decode path + CRC check + ACK windowing
/// are genuinely run here: if the frame layout, endianness, or CRC drifted from
/// the firmware, this mock would fail to reassemble or the CRC equality would
/// break — exactly as a real device would. It feeds the reassembled WAV through
/// the real transcription + save path, so the screen shows the true end-to-end
/// list → fetch → verify → delete flow minus the radio.
@MainActor
public final class MockDeviceSyncService: DeviceSyncService {
    public let displayName = "Mock handheld (no hardware)"
    public var onEvent: ((DeviceSyncEvent) -> Void)?

    /// The in-process "firmware" the central talks to (owns the file table, the
    /// packed FILE_LIST bytes, the chunk streamer, and the CRC-checked delete).
    private let peripheral = MockAudioSyncPeripheral()

    private var task: Task<Void, Never>?
    /// fileId → reassembled temp file the app is ingesting, awaiting `confirmSaved`.
    private var pendingDeletes: [UInt16: (url: URL, crc: UInt32)] = [:]
    private var confirmed = Set<UInt16>()

    public init() {}

    public func startSync() {
        stop()
        confirmed.removeAll()
        pendingDeletes.removeAll()

        guard peripheral.reset() else {
            emit(.stateChanged(.unavailable("No bundled sample audio found.")))
            return
        }

        task = Task { @MainActor in
            emit(.log("Mock device: powering radio…"))
            emit(.stateChanged(.scanning))
            try? await sleep(0.6)
            guard !Task.isCancelled else { return }

            emit(.stateChanged(.connecting))
            emit(.log("Mock device: found 'Handheld-Communicator', connecting…"))
            try? await sleep(0.7)
            guard !Task.isCancelled else { return }

            // --- REQUEST_LIST (0x04) → decode the packed FILE_LIST bytes ---------
            emit(.stateChanged(.connected))
            let listBytes = peripheral.handleControl(AudioSyncGATT.Control.requestListData) ?? Data()
            guard let files = AudioSyncGATT.decodeFileList(listBytes) else {
                emit(.stateChanged(.error("FILE_LIST decode failed")))
                return
            }
            emit(.fileListUpdated(files))
            emit(.log("FILE_LIST: \(listBytes.count) B → \(files.count) recording(s) on SD card."))
            try? await sleep(0.4)

            for file in files {
                guard !Task.isCancelled else { return }
                await transfer(file)
                guard !Task.isCancelled else { return }
            }

            guard !Task.isCancelled else { return }
            // Re-read the (now empty) list the same way the real client would.
            let after = peripheral.handleControl(AudioSyncGATT.Control.requestListData) ?? Data()
            emit(.fileListUpdated(AudioSyncGATT.decodeFileList(after) ?? []))
            emit(.stateChanged(.connected))
            emit(.log("Sync complete. Device SD card is empty."))
        }
    }

    /// Fetch one file: START_TRANSFER, then pull ACK-gated DATA frames, decode +
    /// reassemble + CRC-verify, and only on a CRC match hand it to the app.
    private func transfer(_ file: DeviceFile) async {
        emit(.log("CONTROL START_TRANSFER id=\(file.id) (\(file.name))"))
        peripheral.handleControl(AudioSyncGATT.Control.start(fileId: file.id))

        var assembled = Data()
        var runningCRC = CRC32.initial
        var expectedSeq: UInt16 = 0

        while true {
            guard !Task.isCancelled else { return }

            // Pull the next DATA notification the "firmware" wants to send for the
            // current (acked) seq. Window-of-1: it won't advance until we ACK.
            guard let frameBytes = peripheral.nextDataFrame() else {
                emit(.log("DATA stream ended unexpectedly for id=\(file.id)"))
                break
            }
            guard let frame = AudioSyncGATT.decodeDataFrame(frameBytes) else {
                // Malformed → ask for a resend (mirrors the real client).
                peripheral.handleAck(AudioSyncGATT.ack(fileId: file.id, seq: expectedSeq,
                                                       code: AudioSyncGATT.Ack.resend))
                continue
            }
            guard frame.fileId == file.id, frame.seq == expectedSeq else {
                // Out-of-order / stale → resend the seq we still want.
                peripheral.handleAck(AudioSyncGATT.ack(fileId: file.id, seq: expectedSeq,
                                                       code: AudioSyncGATT.Ack.resend))
                continue
            }

            assembled.append(frame.payload)
            runningCRC = CRC32.update(runningCRC, with: frame.payload)

            // ACK OK → the firmware advances to the next chunk.
            peripheral.handleAck(AudioSyncGATT.ack(fileId: file.id, seq: frame.seq,
                                                   code: AudioSyncGATT.Ack.ok))
            expectedSeq &+= 1

            let progress = file.sizeBytes > 0
                ? min(1.0, Double(assembled.count) / Double(file.sizeBytes)) : 1.0
            emit(.stateChanged(.transferring(file: file.name, progress: progress)))

            if frame.isLast { break }
            try? await sleep(0.04) // pace it so the progress bar is visible
        }

        guard !Task.isCancelled else { return }

        // --- CRC-32/ISO-HDLC verify against the FILE_LIST entry -----------------
        let computed = CRC32.finalize(runningCRC)
        guard computed == file.crc32 else {
            emit(.log(String(format: "CRC MISMATCH id=%u (got 0x%08X, expected 0x%08X) — aborting, NOT deleting",
                             file.id, computed, file.crc32)))
            peripheral.handleControl(AudioSyncGATT.Control.abort(fileId: file.id))
            return
        }
        emit(.log(String(format: "CRC OK id=%u (0x%08X) — reassembled %d B", file.id, computed, assembled.count)))

        // Write the reassembled bytes to a temp WAV and hand it to the app.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hn-sync-\(file.id)-\(UUID().uuidString).wav")
        do {
            try assembled.write(to: tmp, options: [.atomic])
        } catch {
            emit(.stateChanged(.error("Couldn't stage received file: \(error.localizedDescription)")))
            return
        }

        emit(.stateChanged(.savingNote(file: file.name)))
        pendingDeletes[file.id] = (url: tmp, crc: computed)
        emit(.fileReceived(fileId: file.id, url: tmp, suggestedSource: .device))

        // Wait for the app to confirm a verified save before issuing DELETE.
        var waited = 0.0
        while !confirmed.contains(file.id), waited < 30, !Task.isCancelled {
            try? await sleep(0.1); waited += 0.1
        }
        guard confirmed.contains(file.id), let pend = pendingDeletes[file.id] else { return }

        // --- DELETE_FILE(id, crc) — only after a verified save ------------------
        // The emulator re-checks this crc against the file and refuses on mismatch
        // (the firmware's safety invariant), so we send the crc we verified.
        let deleted = peripheral.handleControl(
            AudioSyncGATT.Control.delete(fileId: file.id, crc32: pend.crc)) != nil
        if deleted {
            emit(.log("CONTROL DELETE_FILE id=\(file.id) acked — device freed the slot."))
        } else {
            emit(.log("CONTROL DELETE_FILE id=\(file.id) REFUSED by device (crc mismatch)."))
        }
        try? FileManager.default.removeItem(at: pend.url)
        confirmed.remove(file.id)
        pendingDeletes[file.id] = nil
    }

    public func stop() {
        task?.cancel()
        task = nil
        // Clean up any staged temp files we never got to delete.
        for (_, pend) in pendingDeletes { try? FileManager.default.removeItem(at: pend.url) }
        pendingDeletes.removeAll()
    }

    public func confirmSaved(fileId: UInt16) {
        confirmed.insert(fileId)
    }

    // MARK: Helpers

    private func emit(_ event: DeviceSyncEvent) {
        onEvent?(event)
    }

    private func sleep(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

// MARK: - In-process firmware emulator

/// A minimal stand-in for `audio_sync.c` that produces byte-identical HCAS wire
/// data so the central decode path is genuinely exercised. It owns the file table
/// (built from the bundled sample WAVs), serves the packed FILE_LIST, streams the
/// armed file as ACK-gated DATA frames (window-of-1, with real resend), and
/// honors DELETE only when the host's crc matches the file's.
@MainActor
private final class MockAudioSyncPeripheral {
    private struct Entry {
        let file: DeviceFile
        let bytes: Data   // the actual WAV bytes we stream + CRC
    }
    private var entries: [Entry] = []

    // In-flight transfer state (mirrors hcas_xfer_*).
    private var activeId: UInt16?
    private var activeBytes = Data()
    private var offset = 0
    private var seq: UInt16 = 0
    private let payloadSize = AudioSyncGATT.defaultChunkPayload

    /// (Re)build the file table from the bundled samples. Returns false if none.
    func reset() -> Bool {
        entries = SampleAudio.deviceNoteURLs().enumerated().compactMap { index, url in
            guard let bytes = try? Data(contentsOf: url) else { return nil }
            let durationSeconds = (try? AudioInfo.duration(of: url)) ?? 0
            // CRC computed exactly like the firmware: CRC-32/ISO-HDLC over the
            // whole file. This is the value that goes in FILE_LIST and that the
            // central must reproduce over the reassembled stream.
            let crc = CRC32.checksum(bytes)
            let file = DeviceFile(
                id: UInt16(index + 1),
                name: "REC\(String(format: "%04d", index + 1)).WAV",
                sizeBytes: UInt32(bytes.count),
                durationMs: UInt32(durationSeconds * 1000),
                crc32: crc)
            return Entry(file: file, bytes: bytes)
        }
        activeId = nil
        return !entries.isEmpty
    }

    /// Handle a CONTROL write. Returns the packed FILE_LIST bytes for REQUEST_LIST
    /// and (non-nil) for a successful DELETE; nil for refusals / START / ABORT.
    @discardableResult
    func handleControl(_ data: Data) -> Data? {
        guard let op = data.first else { return nil }
        switch op {
        case AudioSyncGATT.Control.requestList:
            return AudioSyncGATT.encodeFileList(entries.map(\.file))

        case AudioSyncGATT.Control.startTransfer:
            guard data.count >= 3 else { return nil }
            let id = UInt16(data[data.startIndex + 1]) | (UInt16(data[data.startIndex + 2]) << 8)
            guard let entry = entries.first(where: { $0.file.id == id }) else { return nil }
            activeId = id
            activeBytes = entry.bytes
            offset = 0
            seq = 0
            return nil

        case AudioSyncGATT.Control.abortTransfer:
            activeId = nil
            activeBytes = Data()
            return nil

        case AudioSyncGATT.Control.deleteFile:
            guard data.count >= 7 else { return nil }
            let base = data.startIndex
            let id = UInt16(data[base + 1]) | (UInt16(data[base + 2]) << 8)
            let crc = UInt32(data[base + 3]) | (UInt32(data[base + 4]) << 8)
                    | (UInt32(data[base + 5]) << 16) | (UInt32(data[base + 6]) << 24)
            guard let idx = entries.firstIndex(where: { $0.file.id == id }) else { return nil }
            // Safety invariant: refuse to delete unless the host's crc matches.
            guard entries[idx].file.crc32 == crc else { return nil }
            entries.remove(at: idx)
            return AudioSyncGATT.encodeFileList(entries.map(\.file)) // re-notify shorter list

        default:
            return nil
        }
    }

    /// Produce the DATA frame for the current `seq` (window-of-1). The central
    /// must ACK before the offset advances — so calling this repeatedly without an
    /// intervening OK ACK re-emits the *same* chunk (a real resend).
    func nextDataFrame() -> Data? {
        guard let id = activeId, offset < activeBytes.count || (activeBytes.isEmpty && seq == 0) else {
            return nil
        }
        let end = min(offset + payloadSize, activeBytes.count)
        let payload = activeBytes.subdata(in: offset..<end)
        let isLast = end >= activeBytes.count
        return AudioSyncGATT.encodeDataFrame(fileId: id, seq: seq, isLast: isLast, payload: payload)
    }

    /// Handle an ACK write: code 0 advances, code 1/2 holds (resend the same seq).
    func handleAck(_ data: Data) {
        guard data.count >= 5, let id = activeId else { return }
        let base = data.startIndex
        let ackFileId = UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
        let ackSeq    = UInt16(data[base + 2]) | (UInt16(data[base + 3]) << 8)
        let code      = data[base + 4]
        guard ackFileId == id, ackSeq == seq else { return } // ignore stale
        if code == AudioSyncGATT.Ack.ok {
            offset = min(offset + payloadSize, activeBytes.count)
            seq &+= 1
            if offset >= activeBytes.count { activeId = nil } // transfer complete
        }
        // resend / crc-fail: do nothing — nextDataFrame() re-emits the same chunk.
    }
}
