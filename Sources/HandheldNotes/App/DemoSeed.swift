import Foundation

/// Seeds a handful of realistic notes on first run so the list is populated for
/// screenshots and the empty-state never greets a first-time launch. One note
/// gets a real, playable copy of a bundled sample WAV imported into the store so
/// the audio player is exercisable too.
enum DemoSeed {
    static func makeNotes() -> [Note] {
        let now = Date()
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

        var notes: [Note] = []

        // 1) A device note WITH real playable audio (imported from the bundle).
        let withAudio = Note(
            title: "Head tracker: MPU-6050 over ESP-NOW",
            transcript: "Idea for the head tracker project. Use the MPU-6050 over I²C, and stream the orientation data to the second ESP32 using ESP-NOW, so there is no pairing latency. Worth checking the gyro drift over a few minutes before committing to the gimbal design.",
            createdAt: ago(34),
            source: .device,
            durationSeconds: 12.4,
            engineUsed: "Apple Speech",
            isFavorite: true)
        if let bundled = SampleAudio.url(named: "device-note-2") {
            if let stored = try? NotesStore.importAudio(from: bundled, noteID: withAudio.id) {
                var n = withAudio
                n.audioFileName = stored
                notes.append(n)
            } else {
                notes.append(withAudio)
            }
        } else {
            notes.append(withAudio)
        }

        // 2) Computer-mode note (mic), no audio retained.
        notes.append(Note(
            title: "Standup notes for tomorrow",
            transcript: "Yesterday I got the BLE keyboard advertising reliably after switching the low-power clock to the main crystal. Today I want to start on the user-editable keymap persisted in NVS. Blocker is that the SD-card audio sync protocol still needs the firmware side written.",
            createdAt: ago(190),
            source: .computer,
            durationSeconds: 19.8,
            engineUsed: "Apple Speech"))

        // 3) Device note, longer-form.
        notes.append(Note(
            title: "Shopping list before the weekend build",
            transcript: "Reminder to myself: pick up the soldering iron tips and a new lithium-ion battery from the electronics store on the way home tomorrow afternoon. Also need heat-shrink tubing and a fresh roll of solder. Check if they have the 0.96 inch OLED in stock for the spare board.",
            createdAt: ago(420),
            source: .device,
            durationSeconds: 16.1,
            engineUsed: "whisper.cpp"))

        // 4) A short idea captured on the device.
        notes.append(Note(
            title: "App idea: link notes to the recording",
            transcript: "What makes this a notes system and not a clipboard is that every transcript keeps its audio. So you can always go back and listen to exactly what you said, not just read the imperfect transcription. The audio is the source of truth.",
            createdAt: ago(1_440),
            source: .device,
            durationSeconds: 11.2,
            engineUsed: "Apple Speech"))

        return notes
    }
}
