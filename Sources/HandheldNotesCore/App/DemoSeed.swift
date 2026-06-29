import Foundation

/// Seeds a handful of realistic notes on first run so the list is populated for
/// screenshots and the empty-state never greets a first-time launch. One note
/// gets a real, playable copy of a bundled sample WAV imported into the store so
/// the audio player is exercisable too.
///
/// **Deterministic by design.** Every demo note carries a *fixed* UUID (`Note.id`
/// is normally random). Pinning the ids makes `makeNotes()` return the exact same
/// identities on every call, so:
///   • a fresh launch shows exactly these notes — no more, no fewer; and
///   • the seed set carries no random ids that could collide or double up, and the
///     caller's de-dupe on id (see `AppModel.seedDemoNotesIfNeeded`) makes seeding
///     idempotent, so duplicates can never accumulate.
/// The only non-deterministic field is the relative timestamp, which only affects
/// list ordering, not identity or count.
enum DemoSeed {
    /// Stable identities for the seeded notes. Hand-assigned UUIDs (never random)
    /// so the demo set is reproducible across launches.
    private enum SeedID {
        static let headTracker  = UUID(uuidString: "5EED0001-0000-4000-A000-000000000001")!
        static let standup      = UUID(uuidString: "5EED0002-0000-4000-A000-000000000002")!
        static let shopping     = UUID(uuidString: "5EED0003-0000-4000-A000-000000000003")!
        static let linkAudio    = UUID(uuidString: "5EED0004-0000-4000-A000-000000000004")!
    }

    static func makeNotes() -> [Note] {
        let now = Date()
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

        var notes: [Note] = []

        // 1) A note WITH real playable audio (imported from the bundle).
        let withAudio = Note(
            id: SeedID.headTracker,
            title: "Head tracker: MPU-6050 over ESP-NOW",
            transcript: "Idea for the head tracker project. Use the MPU-6050 over I²C, and stream the orientation data to the second ESP32 using ESP-NOW, so there is no pairing latency. Worth checking the gyro drift over a few minutes before committing to the gimbal design.",
            createdAt: ago(34),
            source: .computer,
            durationSeconds: 12.4,
            engineUsed: "Apple Speech",
            isFavorite: true)
        if let bundled = SampleAudio.url(named: "device-note-2"),
           let stored = try? NotesStore.importAudio(from: bundled, noteID: withAudio.id) {
            var n = withAudio
            n.audioFileName = stored
            notes.append(n)
        } else {
            notes.append(withAudio)
        }

        // 2) A mic note, no audio retained.
        notes.append(Note(
            id: SeedID.standup,
            title: "Standup notes for tomorrow",
            transcript: "Yesterday I got the BLE keyboard advertising reliably after switching the low-power clock to the main crystal. Today I want to start on the user-editable keymap persisted in NVS. Blocker is that the SD-card audio sync protocol still needs the firmware side written.",
            createdAt: ago(190),
            source: .computer,
            durationSeconds: 19.8,
            engineUsed: "Apple Speech"))

        // 3) A longer-form note.
        notes.append(Note(
            id: SeedID.shopping,
            title: "Shopping list before the weekend build",
            transcript: "Reminder to myself: pick up the soldering iron tips and a new lithium-ion battery from the electronics store on the way home tomorrow afternoon. Also need heat-shrink tubing and a fresh roll of solder. Check if they have the 0.96 inch OLED in stock for the spare board.",
            createdAt: ago(420),
            source: .computer,
            durationSeconds: 16.1,
            engineUsed: "whisper.cpp"))

        // 4) A short idea.
        notes.append(Note(
            id: SeedID.linkAudio,
            title: "App idea: link notes to the recording",
            transcript: "What makes this a notes system and not a clipboard is that every transcript keeps its audio. So you can always go back and listen to exactly what you said, not just read the imperfect transcription. The audio is the source of truth.",
            createdAt: ago(1_440),
            source: .computer,
            durationSeconds: 11.2,
            engineUsed: "Apple Speech"))

        return notes
    }
}
