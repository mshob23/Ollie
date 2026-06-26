import Foundation

/// A fake handheld that exercises the entire Local-mode pipeline with no
/// hardware. On `startSync()` it simulates: scan → connect → advertise a file
/// list (the bundled sample WAVs) → "transfer" each file with a progress ramp →
/// hand it to the app to ingest → receive a delete-ack.
///
/// This is the default `DeviceSyncService` for this pass. It feeds real audio
/// (the bundled WAVs) through the real transcription + save path, so what you
/// see on screen is the genuine end-to-end flow minus the radio.
@MainActor
final class MockDeviceSyncService: DeviceSyncService {
    let displayName = "Mock handheld (no hardware)"
    var onEvent: ((DeviceSyncEvent) -> Void)?

    private var task: Task<Void, Never>?
    private var pendingDeletes = Set<UInt16>()

    /// Synthetic file list derived from the bundled samples (so the UI shows a
    /// realistic "2 files on device" state).
    private func buildFileList() -> [DeviceFile] {
        SampleAudio.deviceNoteURLs().enumerated().map { index, url in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            let seconds = (try? AudioInfo.duration(of: url)) ?? 0
            return DeviceFile(
                id: UInt16(index + 1),
                name: "REC_\(String(format: "%04d", index + 1)).wav",
                sizeBytes: UInt32(size),
                durationMs: UInt32(seconds * 1000),
                crc32: 0xDEAD_0000 &+ UInt32(index)) // placeholder; real CRC comes from firmware
        }
    }

    func startSync() {
        stop()
        let files = buildFileList()
        guard !files.isEmpty else {
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

            emit(.stateChanged(.connected))
            emit(.fileListUpdated(files))
            emit(.log("Mock device: \(files.count) recording(s) on SD card."))
            try? await sleep(0.4)

            for file in files {
                guard !Task.isCancelled else { return }
                guard let url = urlForFile(file) else { continue }

                // Simulate a chunked transfer with a progress ramp.
                emit(.log("Transfer START fileId=\(file.id) (\(file.name))"))
                let steps = 16
                for step in 1...steps {
                    guard !Task.isCancelled else { return }
                    emit(.stateChanged(.transferring(file: file.name, progress: Double(step) / Double(steps))))
                    try? await sleep(0.05)
                }

                // Verified (CRC ok, in the mock) → hand to the app to make a note.
                emit(.stateChanged(.savingNote(file: file.name)))
                emit(.log("CRC verified — ingesting fileId=\(file.id)"))
                emit(.fileReceived(fileId: file.id, url: url, suggestedSource: .device))

                // Wait until the app confirms the save before "deleting".
                var waited = 0.0
                while !pendingDeletes.contains(file.id), waited < 30, !Task.isCancelled {
                    try? await sleep(0.1); waited += 0.1
                }
                if pendingDeletes.contains(file.id) {
                    pendingDeletes.remove(file.id)
                    emit(.log("DELETE fileId=\(file.id) acked — device freed the slot."))
                }
            }

            guard !Task.isCancelled else { return }
            emit(.stateChanged(.connected))
            emit(.fileListUpdated([])) // all synced
            emit(.log("Sync complete. Device SD card is empty."))
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func confirmSaved(fileId: UInt16) {
        pendingDeletes.insert(fileId)
    }

    // MARK: Helpers

    private func urlForFile(_ file: DeviceFile) -> URL? {
        let urls = SampleAudio.deviceNoteURLs()
        let index = Int(file.id) - 1
        guard index >= 0, index < urls.count else { return urls.first }
        return urls[index]
    }

    private func emit(_ event: DeviceSyncEvent) {
        onEvent?(event)
    }

    private func sleep(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
