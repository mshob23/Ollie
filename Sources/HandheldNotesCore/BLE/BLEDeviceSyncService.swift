import CoreBluetooth
import Foundation

// MARK: - Real CoreBluetooth audio-sync central
//
// Talks to the firmware's audio-sync GATT service (AudioSyncGATT / HCAS, defined
// in HandheldCommunicator-nRF/src/audio_sync.c). Scan / connect /
// service+characteristic discovery / notify-subscription are wired, and the wire
// protocol is fully implemented: FILE_LIST decode, START_TRANSFER, ACK-gated DATA
// reassembly, CRC-32/ISO-HDLC verification, and DELETE-after-verified-save.
//
// What's NOT exercisable without the physical device is flagged `TODO(hw)`:
// real RF discovery, MTU negotiation, and throughput tuning. The decode + CRC +
// ACK *logic* is identical to what `MockDeviceSyncService` runs end-to-end here,
// so it's covered without hardware; only the radio is missing.
//
// Concurrency (Swift 6 strict): CBCentralManager is created with `queue: nil`, so
// every delegate callback arrives on the MAIN queue. This object is @MainActor.
// CoreBluetooth objects (CBPeripheral, CBCharacteristic) are non-Sendable and
// never leave this class; we extract only Sendable values (Data, UUIDs, structs)
// before emitting events. Same proven pattern as the old app's BLEKeymapClient.

@MainActor
public final class BLEDeviceSyncService: NSObject, DeviceSyncService {
    public let displayName = "Handheld over BLE"
    public var onEvent: ((DeviceSyncEvent) -> Void)?

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var controlChar: CBCharacteristic?
    private var ackChar: CBCharacteristic?
    private var dataChar: CBCharacteristic?

    // The device's advertised files and our position working through them.
    private var fileList: [DeviceFile] = []
    private var transferQueue: [DeviceFile] = []

    // Reassembly state for the in-flight transfer.
    private var activeFile: DeviceFile?
    private var assembled = Data()
    private var runningCRC: UInt32 = CRC32.initial
    private var expectedSeq: UInt16 = 0
    /// fileId → staged temp file + verified crc, awaiting `confirmSaved`.
    private var staged: [UInt16: (url: URL, crc: UInt32)] = [:]

    public override init() { super.init() }

    public func startSync() {
        if central == nil {
            // Creating the manager triggers `centralManagerDidUpdateState`, which
            // is where we actually begin scanning (once we know the radio is on).
            central = CBCentralManager(delegate: self, queue: nil)
        } else {
            beginScanIfPowered()
        }
    }

    public func stop() {
        if let central, let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        central?.stopScan()
        peripheral = nil
        controlChar = nil
        ackChar = nil
        dataChar = nil
        resetTransferState()
        transferQueue.removeAll()
        for (_, s) in staged { try? FileManager.default.removeItem(at: s.url) }
        staged.removeAll()
        emit(.stateChanged(.idle))
    }

    public func confirmSaved(fileId: UInt16) {
        guard let peripheral, let controlChar else { return }
        // Delete-only-after-verified-save: the safety invariant. Use the crc we
        // actually verified over the reassembled stream (falls back to the
        // file-list entry, which equals it on success).
        let crc = staged[fileId]?.crc ?? fileList.first(where: { $0.id == fileId })?.crc32
        guard let crc else { return }
        peripheral.writeValue(AudioSyncGATT.Control.delete(fileId: fileId, crc32: crc),
                              for: controlChar, type: .withResponse)
        emit(.log("Sent DELETE_FILE for fileId=\(fileId)"))
        if let s = staged[fileId] { try? FileManager.default.removeItem(at: s.url) }
        staged[fileId] = nil
        // Move on to the next queued file (if any). The firmware re-notifies the
        // (shorter) FILE_LIST after a delete, but we drive the queue directly so a
        // missed notify can't stall the batch.
        startNextTransfer()
    }

    // MARK: Transfer driving

    private func startNextTransfer() {
        guard let peripheral, let controlChar else { return }
        resetTransferState()
        guard !transferQueue.isEmpty else {
            emit(.stateChanged(.connected))
            emit(.log("All transfers complete."))
            return
        }
        let file = transferQueue.removeFirst()
        activeFile = file
        assembled.removeAll(keepingCapacity: true)
        runningCRC = CRC32.initial
        expectedSeq = 0
        emit(.log("CONTROL START_TRANSFER id=\(file.id) (\(file.name))"))
        peripheral.writeValue(AudioSyncGATT.Control.start(fileId: file.id),
                              for: controlChar, type: .withResponse)
    }

    private func resetTransferState() {
        activeFile = nil
        assembled.removeAll(keepingCapacity: false)
        runningCRC = CRC32.initial
        expectedSeq = 0
    }

    /// Handle one decoded DATA frame: validate seq, append, fold CRC, ACK, and on
    /// the last chunk verify CRC + stage the file + emit `fileReceived`.
    private func handleDataFrame(_ frame: AudioSyncGATT.DataFrame) {
        guard let file = activeFile, let peripheral, let ackChar else { return }
        guard frame.fileId == file.id else { return } // stale / other file

        if frame.seq != expectedSeq {
            // Out-of-order (window-of-1): ask the firmware to resend what we want.
            peripheral.writeValue(
                AudioSyncGATT.ack(fileId: file.id, seq: expectedSeq, code: AudioSyncGATT.Ack.resend),
                for: ackChar, type: .withResponse)
            return
        }

        assembled.append(frame.payload)
        runningCRC = CRC32.update(runningCRC, with: frame.payload)

        // ACK OK so the firmware advances (the stream is ACK-gated, window-of-1 —
        // without this the transfer never progresses).
        peripheral.writeValue(
            AudioSyncGATT.ack(fileId: file.id, seq: frame.seq, code: AudioSyncGATT.Ack.ok),
            for: ackChar, type: .withResponse)
        expectedSeq &+= 1

        let progress = file.sizeBytes > 0
            ? min(1.0, Double(assembled.count) / Double(file.sizeBytes)) : 1.0
        emit(.stateChanged(.transferring(file: file.name, progress: progress)))

        guard frame.isLast else { return }

        // --- File fully received → CRC-32/ISO-HDLC verify ----------------------
        let computed = CRC32.finalize(runningCRC)
        guard computed == file.crc32 else {
            emit(.log(String(format: "CRC MISMATCH id=%u (got 0x%08X, expected 0x%08X) — aborting, NOT deleting",
                             file.id, computed, file.crc32)))
            if let controlChar {
                peripheral.writeValue(AudioSyncGATT.Control.abort(fileId: file.id),
                                      for: controlChar, type: .withResponse)
            }
            startNextTransfer()
            return
        }
        emit(.log(String(format: "CRC OK id=%u (0x%08X) — %d B received", file.id, computed, assembled.count)))

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hn-ble-\(file.id)-\(UUID().uuidString).wav")
        do {
            try assembled.write(to: tmp, options: [.atomic])
        } catch {
            emit(.stateChanged(.error("Couldn't stage received file: \(error.localizedDescription)")))
            startNextTransfer()
            return
        }
        staged[file.id] = (url: tmp, crc: computed)
        resetTransferState()
        emit(.stateChanged(.savingNote(file: file.name)))
        // The app ingests → persists → calls confirmSaved(fileId:), which sends
        // DELETE_FILE and triggers the next transfer.
        emit(.fileReceived(fileId: file.id, url: tmp, suggestedSource: .device))
    }

    // MARK: Internals

    private func beginScanIfPowered() {
        guard let central, central.state == .poweredOn else {
            emit(.stateChanged(.unavailable("Bluetooth is off or unauthorized.")))
            return
        }
        emit(.stateChanged(.scanning))
        // TODO(hw): real RF discovery happens only against the physical device.
        central.scanForPeripherals(withServices: [AudioSyncGATT.service], options: nil)
    }

    fileprivate func emit(_ event: DeviceSyncEvent) {
        onEvent?(event)
    }
}

// MARK: - CBCentralManagerDelegate
//
// `@preconcurrency` conformance: CoreBluetooth's delegate requirements are
// nonisolated, but because we create the CBCentralManager with `queue: nil`
// every callback is delivered on the MAIN queue — so satisfying them with these
// @MainActor methods is sound, and the attribute downgrades the checker's
// data-race complaint to a runtime check that our queue:nil invariant upholds.
// (Same single-thread-on-main reasoning as the old app's BLEKeymapClient.)

extension BLEDeviceSyncService: @preconcurrency CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            beginScanIfPowered()
        case .poweredOff:
            emit(.stateChanged(.unavailable("Bluetooth is turned off.")))
        case .unauthorized:
            emit(.stateChanged(.unavailable("Bluetooth permission not granted.")))
        case .unsupported:
            emit(.stateChanged(.unavailable("This Mac does not support Bluetooth LE.")))
        default:
            emit(.stateChanged(.unavailable("Bluetooth unavailable.")))
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        emit(.stateChanged(.connecting))
        central.connect(peripheral, options: nil)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        emit(.log("Connected; discovering audio-sync service…"))
        peripheral.discoverServices([AudioSyncGATT.service])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        emit(.stateChanged(.error(error?.localizedDescription ?? "connection failed")))
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        emit(.stateChanged(.idle))
    }
}

// MARK: - CBPeripheralDelegate (see the @preconcurrency note above).

extension BLEDeviceSyncService: @preconcurrency CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == AudioSyncGATT.service }) else {
            emit(.stateChanged(.error("audio-sync service not found")))
            return
        }
        peripheral.discoverCharacteristics(
            [AudioSyncGATT.fileList, AudioSyncGATT.control, AudioSyncGATT.data, AudioSyncGATT.ack],
            for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for char in service.characteristics ?? [] {
            switch char.uuid {
            case AudioSyncGATT.control: controlChar = char
            case AudioSyncGATT.ack:     ackChar = char
            case AudioSyncGATT.fileList:
                peripheral.setNotifyValue(true, for: char)
                peripheral.readValue(for: char)
            case AudioSyncGATT.data:
                dataChar = char
                peripheral.setNotifyValue(true, for: char)
            default: break
            }
        }
        emit(.stateChanged(.connected))
        emit(.log("Characteristics discovered. Requesting file list…"))
        if let controlChar {
            peripheral.writeValue(AudioSyncGATT.Control.requestListData, for: controlChar, type: .withResponse)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value else { return }
        switch characteristic.uuid {
        case AudioSyncGATT.fileList:
            // Packed FILE_LIST: u8 count, then per file {u16 id, u8 nameLen, name,
            // u32 sizeBytes, u32 durationMs, u32 crc32} — all little-endian. Mirrors
            // hcas_build_file_list().
            guard let files = AudioSyncGATT.decodeFileList(value) else {
                emit(.log("FILE_LIST notify: \(value.count) bytes — empty/undecodable."))
                return
            }
            fileList = files
            emit(.fileListUpdated(files))
            emit(.log("FILE_LIST: \(value.count) B → \(files.count) recording(s)."))
            // Drive the batch: queue everything not already staged, and if nothing
            // is mid-transfer, kick off the first one. (Re-notified lists after a
            // delete are handled by the confirmSaved → startNextTransfer path, so
            // we only auto-start when idle to avoid double-driving.)
            if activeFile == nil && staged.isEmpty {
                transferQueue = files
                startNextTransfer()
            }
        case AudioSyncGATT.data:
            // One chunk frame: [fileId:u16 | seq:u16 | flags:u8 | payload]. Decode,
            // append, ACK (window-of-1), CRC-verify on LAST_CHUNK.
            guard let frame = AudioSyncGATT.decodeDataFrame(value) else {
                emit(.log("DATA notify: \(value.count) bytes — too short to decode."))
                return
            }
            handleDataFrame(frame)
        default:
            break
        }
    }
}
