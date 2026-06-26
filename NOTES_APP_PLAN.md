# Handheld Notes — App Plan

A macOS **voice-notes system** and the desktop companion to the Handheld Communicator
device (a Seeed XIAO BLE board). Where the existing **Handheld Companion** app is a
*clipboard utility* (hold F16 → record → transcribe → copy), **Handheld Notes** is a
*notes database*: every capture lands as a saved, titled, searchable note with its audio
attached and playable.

This document is the architecture, the data model, the BLE audio-sync protocol sketch, the
two capture modes, what is real vs. stubbed, and the exact build/run commands.

> Separate project. Does **not** touch the old app (`../HandheldCompanionMac`), its data,
> `~/.whisper-models`, or its Recordings. New code, new bundle id
> (`com.mohammadshobaki.handheldnotes`), new Application Support directory
> (`~/Library/Application Support/HandheldNotes`).

---

## 1. The product in one paragraph

A notes-first window: a **persistent capture area pinned to the top** (independent of which
note is selected), a sidebar list of finalized notes (newest first), and a detail pane
showing the transcript, an audio player, and editable title. In **Computer mode** the
capture area is a live **draft**: holding **F16** records the Mac mic and *appends* the
transcribed speech to the in-progress draft, which keeps accumulating across recordings and
edits until you **explicitly conclude it** (Send / ⌘↩) into the saved list. In **Local
mode** the handheld records to its SD card offline, then **syncs the audio over BLE**; those
recordings were composed + concluded on the device, so they arrive **already finished** and
drop straight into the notes list (no Mac-side drafting). Transcription reuses the proven
whisper.cpp + Apple Speech engine from the old app. The device/BLE half is **stubbed** this
pass so the entire UI and pipeline are exercisable with no hardware.

---

## 2. Two modes + how the mode is chosen

| Mode | Trigger | Audio source | Result | Status this pass |
|---|---|---|---|---|
| **Computer** ("talk to computer") | Global **F16** push-to-talk (hold to record, release to stop) | The Mac microphone via `AVAudioEngine` | **Appends to the active draft** (see §2.2) | **Real** (degrades gracefully if mic/hotkey perms are absent) |
| **Local** ("DIY notes") | The handheld syncs SD-card recordings over BLE | Audio files transferred from the device | **Already-concluded notes** drop into the list | **Stubbed**: a `MockDeviceSyncService` feeds bundled sample WAVs through the transcription → save → delete-ack pipeline |

### 2.1 Manual vs. Automatic (Settings ▸ Mode, persisted)

A `ModeSelection` decides which `CaptureMode` is active **right now**:

- **Manual** — the user flips **Computer ⇄ Local** with a persistent segmented control in
  the capture header (also settable in Settings). The choice is honored verbatim.
- **Automatic** — the app derives the mode from **device connectivity**: in range →
  **Computer** (live transcribe), out of range → **Local** (device stores to SD; sync +
  transcribe on reconnect). The capture header shows an **AUTO** badge with the auto-chosen
  mode and an **In range / Out of range** toggle. With the mock service there is no radio, so
  that toggle is a **simulated connectivity** flag (`AppModel.simulatedDeviceConnected`);
  flipping it makes Auto visibly switch. Coming back *into* range while Automatic kicks off a
  device sync — the handheld hands over what it recorded offline, and those finished notes
  land in the list.

`AppModel.activeMode` is the single source of truth: `manual ? settings.manualMode :
(simulatedDeviceConnected ? .computer : .local)`.

### 2.2 The draft model (Computer / live mode) — notes are open until concluded

A note **no longer finalizes when a recording stops.** The capture area holds one in-progress
`Draft` (`Models/Draft.swift`) that accumulates content until the user explicitly concludes
it. This mirrors the handheld's composition buttons:

- **Hold-to-talk (F16)** transcribes the clip and **appends** it to `draft.transcript`
  (`Draft.appendSpeech`, joining with a space so successive takes read as prose). The most
  recent recording's audio/duration/engine are retained on the draft so the concluded note
  keeps a playable recording.
- **Space / Newline / Backspace** (the on-screen device-mirror keys, or typing directly in
  the field) edit the **same** draft buffer (`typeSpace` / `typeNewline` / `backspace`).
  These map to the device's RIGHT tap (Space), RIGHT double-tap (Shift+Enter = newline), and
  BOTTOM (Backspace).
- **Conclude** — and only conclude — finalizes the draft into a saved `Note` and starts a
  fresh empty draft (`AppModel.concludeDraft`). It's triggered by the **Send** button, the
  **⌘↩** shortcut, mirroring the device's **double-tap-MIDDLE = Enter**. Concluding an empty
  draft is a no-op.

**Local mode is different on purpose:** recordings synced from the device arrive **already
concluded** (composed + concluded on the handheld), so they bypass the draft entirely and
drop straight into the notes list as finished notes via `ingest(…, source: .device)`. That
ingest path deliberately does **not** touch `recordingState` / `draft`, so a background sync
never disturbs the Computer-mode capture area.

Both *finalize* paths still converge on a `Note`: `Draft.makeNote()` for concluded drafts,
`NotesPipeline.ingest(audioFileURL:source:)` for device files. Computer-mode appending uses
the new `NotesPipeline.transcribeClip(audioURL:noteID:)`, which transcribes + imports audio
**without** producing a note.

---

## 3. Architecture

```
                         ┌─────────────────────────────────────────────┐
                         │                 SwiftUI UI                    │
                         │  CaptureBar (persistent top: mode + DRAFT)    │
                         │  NotesListView · NoteDetailView               │
                         │  DeviceSyncPanel · SettingsView (Mode+Engine) │
                         └───────────────┬───────────────────────────────┘
                                         │  @MainActor ObservableObject
                         ┌───────────────▼───────────────┐
                         │          AppModel              │  app-wide state
                         │  notes, selection, search,     │
                         │  recordingState, syncState     │
                         └───┬───────────┬───────────┬────┘
                             │           │           │
          ┌──────────────────▼──┐  ┌─────▼───────┐  ┌▼───────────────────┐
          │   NotesStore        │  │ NotesPipeline│  │  Capture / Sync     │
          │  (JSON + audio dir) │  │  ingest()    │  │  MicCaptureService  │
          │  CRUD, search, seed │  │              │  │  HotKeyManager (F16)│
          └─────────────────────┘  └──────┬───────┘  │  DeviceSyncService  │
                                          │          │   ├ Mock (stub)     │
                                   ┌──────▼───────┐  │   └ BLE (skeleton)  │
                                   │ Transcribing │  └─────────────────────┘
                                   │  Service     │
                                   │  ├ AppleSpeech (real)
                                   │  └ WhisperCpp  (real if installed, else stub note)
                                   └──────────────┘
```

### Layer responsibilities

- **`AppModel`** (`@MainActor`, `ObservableObject`) — the single source of truth the views
  observe. Holds the notes array, current selection, search text, recording state, the active
  **`draft`**, the **mode** (`settings.modeSelection` + `simulatedDeviceConnected` →
  `activeMode`), and sync state. Owns the services and the draft lifecycle
  (`concludeDraft` / `clearDraft` / `draftSpace|Newline|Backspace`). Everything the UI does
  goes through here.
- **`NotesStore`** — persistence. Notes are a JSON array at
  `~/Library/Application Support/HandheldNotes/notes.json`; audio files live in
  `.../Audio/<uuid>.wav`. CRUD, full-text search, and first-run seeding of demo notes.
- **`NotesPipeline`** — the convergence point. Takes an audio URL + a `NoteSource`, copies
  the audio into the store, runs transcription, derives a title, creates the `Note`, saves
  it, and returns it. Mode-agnostic.
- **`TranscribingService`** — protocol with two implementations (Apple Speech, whisper.cpp),
  adapted from the old app. Picks by setting; falls back cleanly.
- **`MicCaptureService`** — `AVAudioEngine` tap → writes a 16 kHz mono WAV. (The old app
  shells out to ffmpeg for capture; here we use native `AVAudioEngine` so capture has no
  external-binary dependency and degrades to a clear message if mic permission is absent.)
- **`HotKeyManager`** — Carbon `RegisterEventHotKey` for global **F16** press/release
  (push-to-talk), adapted from the old app. No Accessibility permission required.
- **`DeviceSyncService`** — protocol. `MockDeviceSyncService` (default, this pass) replays
  bundled WAVs through the pipeline. `BLEDeviceSyncService` is the CoreBluetooth skeleton
  that will speak the real audio-sync GATT protocol (see §5).

### Concurrency

Swift 6 strict concurrency. `AppModel` and all services that touch UI state are
`@MainActor`. Transcription runners are `actor`s (CPU-bound work off the main thread).
CoreBluetooth is queue-confined to main (same pattern the old `BLEKeymapClient` uses), and
its delegate extracts only `Sendable` values before hopping to `@MainActor`.

---

## 4. Data model

```swift
struct Note: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String            // editable; derived from transcript on creation
    var transcript: String       // the body
    var createdAt: Date
    var updatedAt: Date
    var source: NoteSource       // .computer | .device | .seed
    var audioFileName: String?   // relative to the Audio/ dir; nil if audio was deleted
    var durationSeconds: Double?
    var engineUsed: String?      // "Apple Speech" | "whisper.cpp" | "demo"
    var isFavorite: Bool
}

enum NoteSource: String, Codable { case computer, device, seed }
```

A `Note` is **finalized** content in the sidebar list. In-progress Computer-mode content is a
separate, lighter **`Draft`** (`Models/Draft.swift`) that is *not* persisted as a note until
concluded — it carries the accumulating `transcript`, the retained `audioFileName` /
`durationSeconds` / `engineUsed` from the latest recording, and an `appendCount`. On conclude,
`Draft.makeNote()` materializes it into a `Note` with `source: .computer`. The active draft is
session state (a fresh empty draft on launch); only finalized notes hit `notes.json`.

- **Title derivation**: first sentence (or first ~6 words) of the transcript, title-cased,
  capped to ~60 chars. User can edit it freely; editing sets `updatedAt`.
- **Search**: case-insensitive substring over `title` + `transcript`.
- **Audio**: stored as `Audio/<note.id>.wav`. Playback via `AVAudioPlayer`. Deleting a note
  deletes its audio file too.
- **Persistence**: a single `notes.json` (pretty-printed, tolerant decode like the old
  `AppSettings`). Atomic writes. Corrupt file is backed up to `notes.json.bak`, not
  clobbered.

---

## 5. BLE audio-sync protocol sketch (firmware can match this later)

The device is **BLE-only** (no Bluetooth Classic, so no standard audio profile). Audio
moves as **application data over a custom GATT service** — the same shape the existing
keymap config service uses, extended for bulk file transfer. The Mac is GATT **central**;
the device is **peripheral**.

### Service & characteristics

Base UUID mirrors the keymap service's `48434B4D…` ("HCKM") convention. The audio-sync
service uses **`48434153…` ("HCAS" = Handheld-Communicator Audio-Sync)**:

```
Service  48434153-0001-4000-A000-000000000000   Audio Sync Service

Char     48434153-0002-…  FILE_LIST     Read / Notify
         → JSON or packed list of available recordings on the SD card:
           [{ id: u16, name, sizeBytes: u32, durationMs: u32, crc32: u32 }, …]

Char     48434153-0003-…  CONTROL       Write
         Central → device commands (1-byte op + args):
           0x01 <id:u16>            START_TRANSFER(fileId)  — begin chunked send
           0x02 <id:u16>            ABORT_TRANSFER(fileId)
           0x03 <id:u16> <crc:u32>  DELETE_FILE(fileId, expectedCrc) — only after verified save
           0x04                     REQUEST_FILE_LIST (refresh the list)

Char     48434153-0004-…  DATA          Notify (device → central)
         Chunk frames for the active transfer:
           [ fileId:u16 | seq:u16 | flags:u8 | payload:… ]
           flags bit0 = LAST_CHUNK. Payload sized to (negotiated ATT MTU − 5) bytes.

Char     48434153-0005-…  ACK           Write (central → device) / Notify (status)
         Central → device, per chunk or windowed:
           [ fileId:u16 | ackSeq:u16 | code:u8 ]   code 0 = ok, 1 = resend, 2 = crc-fail
         Device → central STATUS notify mirrors keymap STATUS codes
           (0 ok, 5 = SD/IO error, …).
```

### Transfer flow

1. Connect → discover the service → subscribe to `FILE_LIST`, `DATA`, `ACK` notifies.
2. Read `FILE_LIST`. For each file: write `START_TRANSFER(id)` on `CONTROL`.
3. Device streams `DATA` chunks (`seq` increasing); central reassembles into a temp file.
4. Central verifies `crc32` against the `FILE_LIST` entry. On match → write `DELETE_FILE`.
5. The reassembled WAV goes through `NotesPipeline.ingest(…, source: .device)`.
6. On any failure, central writes `ABORT_TRANSFER` and does **not** delete the file.

**Design notes for the firmware author**
- BLE is **burst, not stream**. Transfer whole files opportunistically when connected; do
  not try to stream audio live (bandwidth + power). One file at a time, serialized.
- Chunk size tracks the negotiated MTU. Default to a conservative 180-byte payload until
  MTU exchange completes.
- CRC32 end-to-end (not just per-chunk) so a bit-flip can't cause a bad note + premature
  delete. **Delete only after a verified, persisted note.** This is the safety invariant.
- The same custom-GATT plumbing is what the on-device microphone roadmap item needs, so
  this service is the natural first payload (matches `ROADMAP.md` items 2–3 in the firmware
  repo).

### What's implemented this pass

- `AudioSyncGATT` — the UUID + opcode constants above, in code, ready for the firmware.
- `DeviceSyncService` protocol + `MockDeviceSyncService` (default) that simulates the flow
  (discover → "transfer" a bundled WAV with a progress delay → ingest → "delete-ack") with
  **zero hardware**.
- `BLEDeviceSyncService` — a CoreBluetooth central skeleton (scan/connect/discover wired;
  chunk reassembly + CRC verify are marked `TODO(firmware)` since there's nothing to talk
  to yet). It compiles and is selectable but inert without a peripheral.

---

## 6. What is real vs. stubbed

| Piece | State | Notes |
|---|---|---|
| Notes store, CRUD, search, seed | **Real** | JSON + audio dir under `HandheldNotes/` |
| Notes UI (list, detail, edit, delete, playback, search) | **Real** | SwiftUI |
| Apple Speech transcription | **Real** | macOS 26 `SpeechAnalyzer`; on-device, file-based path needs no TCC |
| whisper.cpp transcription | **Real if installed** | Shells to `whisper-cli` + `ffmpeg`; if missing, returns a clear stub transcript and the note still saves |
| Computer mode (F16 → mic → **append to draft**) | **Real** | `AVAudioEngine` capture + Carbon F16 hotkey; transcribed speech appends to the active draft; **conclude** (Send / ⌘↩) finalizes. Degrades to a banner if mic/hotkey unavailable |
| Draft model (open until concluded) + Manual/Automatic mode | **Real** | `Draft` + `AppModel.activeMode`; Auto follows simulated connectivity so it visibly flips |
| Local mode end-to-end (notes arrive **already concluded**) | **Real pipeline, stubbed source** | Mock device replays bundled WAVs through the ingest path; finished notes drop straight into the list |
| BLE audio-sync transport | **Skeleton** | CoreBluetooth central scaffold + protocol constants; `TODO(firmware)` for live transfer |
| Demo seed notes | **Real** | 4 seeded notes (1 with a real playable bundled WAV) so screenshots are populated |

**Graceful degradation (so an automated launch never blocks):** the app never *requests*
mic or Bluetooth permission at launch. The window always shows. Mic permission is requested
only when the user first triggers a recording; if denied, a banner explains it and the rest
of the app keeps working. The mock device needs no permission at all.

---

## 7. Build & run

Swift Package + a build script that bundles a real, signed `.app` (modeled on the old
`Scripts/build_app.sh`; signs with the installed **Developer ID** so this is a normal,
launchable app).

```bash
cd /Users/mohammadshobaki/Desktop/Projects/Agents/HandheldNotes

# Build the .app bundle (prints the bundle path on the last line)
./Scripts/build_app.sh

# Launch it
open ".build/debug/Handheld Notes.app"
```

Or run the raw executable (still shows the window; uses the bundle's resources from the
build dir):

```bash
swift run HandheldNotes
```

**Requirements:** macOS 14+ (Apple Speech path is best on macOS 26+), Xcode/Swift toolchain.
whisper.cpp transcription additionally wants `whisper-cli` + `ffmpeg` on `PATH` (Homebrew);
absent those, the app uses Apple Speech or the whisper stub and still runs.

---

## 8. Repo map

```
HandheldNotes/
  Package.swift
  NOTES_APP_PLAN.md            ← this file
  README.md
  Info.plist                   ← bundle id, usage strings
  HandheldNotes.entitlements   ← mic + bluetooth
  Scripts/build_app.sh         ← build + bundle + sign
  Sources/HandheldNotes/
    Resources/*.wav            ← bundled demo audio (device-sync mock + seed note)
    App/        main.swift, AppDelegate.swift, AppModel.swift, DemoSeed.swift
    Models/     Note.swift, Draft.swift, CaptureMode.swift  ← Draft = open-until-concluded; CaptureMode/ModeSelection = mode system
    Store/      NotesStore.swift, NotesPipeline.swift (ingest + transcribeClip)
    Transcription/  TranscribingService.swift, AppleSpeechTranscriber.swift, WhisperCppTranscriber.swift
    Capture/    MicCaptureService.swift, HotKeyManager.swift
    BLE/        AudioSyncGATT.swift, DeviceSyncService.swift, MockDeviceSyncService.swift, BLEDeviceSyncService.swift
    Theme/      Theme.swift (colors, fonts, reusable SwiftUI styles)
    UI/         RootView.swift (persistent capture header + list|detail|slideover),
                CaptureBar.swift (mode control + live DRAFT + device-mirror keys + Send),
                NotesListView.swift, NoteDetailView.swift, DeviceSyncPanel.swift,
                SettingsView.swift (Mode + Engine), AudioPlayerView.swift
```

---

## 9. Next steps (after this pass)

1. Wire `BLEDeviceSyncService` to a real peripheral once the firmware ships the `48434153…`
   service; fill the `TODO(firmware)` chunk-reassembly/CRC blocks.
2. Match the firmware side to §5 (SD-card file list, chunked notify, delete-on-verified-ack).
3. Optional: tag/folder organization, export (Markdown), and the dedicated note-taking app
   surface from the firmware roadmap.
4. Optional: bundle a whisper model or wire the model picker from the old app if whisper is
   preferred over Apple Speech.
