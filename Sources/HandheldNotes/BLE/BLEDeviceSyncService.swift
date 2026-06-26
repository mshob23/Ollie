import CoreBluetooth
import Foundation

// MARK: - Real CoreBluetooth audio-sync central (SKELETON)
//
// This is the structural scaffold for talking to the firmware's audio-sync GATT
// service (AudioSyncGATT). Scan / connect / service+characteristic discovery /
// notify-subscription are wired. The chunk reassembly + CRC verification +
// delete handshake are marked TODO(firmware) because there is no peripheral to
// talk to yet — the mock service is what exercises the pipeline this pass.
//
// Concurrency (Swift 6 strict): CBCentralManager is created with `queue: nil`, so
// every delegate callback arrives on the MAIN queue. This object is @MainActor.
// CoreBluetooth objects (CBPeripheral, CBCharacteristic) are non-Sendable and
// never leave this class; we extract only Sendable values (Data, UUIDs, structs)
// before emitting events. Same proven pattern as the old app's BLEKeymapClient.

@MainActor
final class BLEDeviceSyncService: NSObject, DeviceSyncService {
    let displayName = "Handheld over BLE"
    var onEvent: ((DeviceSyncEvent) -> Void)?

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var controlChar: CBCharacteristic?
    private var ackChar: CBCharacteristic?

    // Reassembly state for the in-flight transfer.
    private var activeFileId: UInt16?
    private var assembled = Data()
    private var expectedCRC: UInt32?
    private var fileList: [DeviceFile] = []

    func startSync() {
        if central == nil {
            // Creating the manager triggers `centralManagerDidUpdateState`, which
            // is where we actually begin scanning (once we know the radio is on).
            central = CBCentralManager(delegate: self, queue: nil)
        } else {
            beginScanIfPowered()
        }
    }

    func stop() {
        if let central, let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        central?.stopScan()
        peripheral = nil
        controlChar = nil
        ackChar = nil
        activeFileId = nil
        assembled.removeAll()
        emit(.stateChanged(.idle))
    }

    func confirmSaved(fileId: UInt16) {
        guard let peripheral, let controlChar,
              let crc = fileList.first(where: { $0.id == fileId })?.crc32 else { return }
        // Delete-only-after-verified-save: the safety invariant.
        peripheral.writeValue(AudioSyncGATT.Control.delete(fileId: fileId, crc32: crc),
                              for: controlChar, type: .withResponse)
        emit(.log("Sent DELETE for fileId=\(fileId)"))
    }

    // MARK: Internals

    private func beginScanIfPowered() {
        guard let central, central.state == .poweredOn else {
            emit(.stateChanged(.unavailable("Bluetooth is off or unauthorized.")))
            return
        }
        emit(.stateChanged(.scanning))
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
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
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

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        emit(.stateChanged(.connecting))
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        emit(.log("Connected; discovering audio-sync service…"))
        peripheral.discoverServices([AudioSyncGATT.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        emit(.stateChanged(.error(error?.localizedDescription ?? "connection failed")))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        emit(.stateChanged(.idle))
    }
}

// MARK: - CBPeripheralDelegate (see the @preconcurrency note above).

extension BLEDeviceSyncService: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == AudioSyncGATT.service }) else {
            emit(.stateChanged(.error("audio-sync service not found")))
            return
        }
        peripheral.discoverCharacteristics(
            [AudioSyncGATT.fileList, AudioSyncGATT.control, AudioSyncGATT.data, AudioSyncGATT.ack],
            for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for char in service.characteristics ?? [] {
            switch char.uuid {
            case AudioSyncGATT.control: controlChar = char
            case AudioSyncGATT.ack:     ackChar = char
            case AudioSyncGATT.fileList:
                peripheral.setNotifyValue(true, for: char)
                peripheral.readValue(for: char)
            case AudioSyncGATT.data:
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

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value else { return }
        switch characteristic.uuid {
        case AudioSyncGATT.fileList:
            // TODO(firmware): decode the packed/JSON file list into [DeviceFile].
            // Shape is defined in AudioSyncGATT / NOTES_APP_PLAN.md §5.
            emit(.log("FILE_LIST notify: \(value.count) bytes (decode pending firmware)."))
        case AudioSyncGATT.data:
            // TODO(firmware): parse [fileId|seq|flags|payload], append to
            // `assembled`, ack via `ackChar`, and on LAST_CHUNK verify crc32
            // against the file-list entry, then emit `.fileReceived`.
            assembled.append(value)
        default:
            break
        }
    }
}
