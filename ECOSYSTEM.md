# Handheld Notes — Ecosystem Status

*Snapshot of the whole system, June 2026.*

**The vision:** capture a spoken thought from whatever device is nearest — a pocket handheld, your
Mac, your iPhone, or your wrist — and have it transcribed and filed into one notes library, with no
fuss. Today the entire software stack for that vision exists and is verified against mocks/simulators;
it is waiting on the recorder **hardware** to be wired up.

---

## The system at a glance

**Four capture surfaces feed one transcribe-and-save pipeline.**

| Surface | How you capture | How it becomes a note |
|---|---|---|
| 🎙️ **Handheld** (XIAO nRF52840) | press a button, talk — records to its SD card **offline** | offloads the WAVs over BLE (the **HCAS** GATT service) when near the phone/Mac → transcribed there |
| 💻 **Mac** | hold **F16** (push-to-talk) | the Mac app records its mic and transcribes locally |
| 📱 **iPhone** | tap to type, or receive synced audio | transcribes on-device (Apple **SpeechAnalyzer**) |
| ⌚ **Apple Watch** | **hold** the on-screen button (or the Action button) | ships the clip to the iPhone over **WatchConnectivity** → the phone transcribes |

All four converge through **`HandheldNotesCore`** (the shared Swift library) into a notes library,
where each note is tagged with the source it came from.

> **Note:** the handheld also works as a plain **BLE keyboard** — that's the original product. Its
> **F16** is exactly what the Mac's push-to-talk listens for, and its other buttons send editing
> keystrokes (Backspace / Space / Enter). The "standalone recorder" role in the table is the
> **in-progress upgrade** (mic + SD card + the BLE sync service).

---

## Components (where the code lives)

| Repo | Stack | Role | Key paths |
|---|---|---|---|
| **HandheldCommunicator-nRF** | C / ZMK / Zephyr | The handheld firmware: BLE keyboard + the recorder upgrade | `src/audio_sync.c` (HCAS GATT), `src/recorder.c`, `src/sdcard.c`, `src/mic_i2s.c`, `src/lpcomp_wake.c`, `RECORDER_PLAN.md` |
| **HandheldNotes** | Swift / SwiftUI | The **shared core** + the **Mac app** | `Sources/HandheldNotesCore/` (model, store, BLE codec, transcription, theme, `AppModel`), `Sources/HandheldNotes/` (the macOS UI) |
| **HandheldNotesiOS** | Swift / SwiftUI | The **iPhone app** + the embedded **Apple Watch app** | `Sources/` (iOS UI + `WatchSessionReceiver`), `Watch/Sources/` (the watch app), `project.yml` (XcodeGen) |

`HandheldNotesCore` is the keystone: the **same** notes model, storage, BLE wire-codec (`AudioSyncGATT`
+ `CRC32`), and transcription pipeline are compiled into the Mac app **and** the iPhone app, so the two
never diverge. (The watch app reuses only the theme + model — watchOS has no Speech framework, so it
never transcribes.)

> Not to be confused with the **legacy** `HandheldCompanionMac` (the original SuperWhisper-style tool).
> It is separate and untouched; the current Mac app is **HandheldNotes**.

---

## How a note is born (data flow)

- **Handheld → note:** button press records the mic → 16 kHz WAV on the microSD card (works with no
  host present). Later, in BLE range, the phone/Mac connects to the **HCAS** service, lists the files,
  pulls each one in CRC-verified chunks, transcribes it, saves the note, and only **then** tells the
  device to delete it ("deleted only after a verified save").
- **Mac → note:** hold F16 → the Mac app records its mic → transcribes with whisper.cpp / Apple Speech
  → saves a note.
- **iPhone → note:** type directly, or receive audio (from the device or the watch) → transcribe
  on-device with SpeechAnalyzer → save.
- **Watch → note:** hold the button to record → on save, `WCSession.transferFile` ships the `.m4a` to
  the iPhone → `WatchSessionReceiver` → `AppModel.ingestFromWatch(url:)` → the normal pipeline → a
  `.watch`-tagged note.

---

## The sync contract (handheld ↔ apps)

A custom BLE GATT service, **"HCAS"** (`48434153-0001-…`), defined by the firmware and mirrored
byte-for-byte in `HandheldNotesCore/BLE/AudioSyncGATT.swift`:

- **FILE_LIST** — enumerate the WAVs on the SD card (`id, name, size, durationMs, crc32`).
- **CONTROL** — `start<id>` / `abort<id>` / `delete<id><crc32>` / `requestList`.
- **DATA** — the file streamed in chunks: `[fileId | seq | flags | payload]`, last chunk flagged.
- **ACK** — the receiver acks **every** chunk (window-of-1), which is what advances the firmware's
  streamer.
- **CRC** — **CRC-32/ISO-HDLC** (`= zlib.crc32`, vector `"123456789" → 0xCBF43926`). The receiver
  verifies the reassembled file before confirming the save and issuing the delete.

---

## Current status — built & verified vs. pending hardware

| Piece | Status |
|---|---|
| Firmware: BLE keyboard (F16 + editing keys) | ✅ shipped (the stable `v1.0-keyboard` product) |
| Firmware: recorder Phases 1–3 (analog buttons, mic→WAV→SD, deep-sleep wake, HCAS GATT) | ✅ **builds** (28.98% flash); hardware-untested |
| `HandheldNotesCore` shared library + real BLE decoders | ✅ extracted, public API, 4 green protocol tests |
| Mac app | ✅ builds + runs; verified on screen |
| iPhone app | ✅ builds + runs in the iOS 26 simulator; full mock-sync pipeline exercised |
| Apple Watch app | ✅ builds + launches in the watchOS 26 simulator; UI verified |
| End-to-end (record → transfer → note) | ⚠️ **code-complete**, exercised via mocks; the device/watch transfers need real hardware |

---

## Not built yet (the honest gaps)

1. **Shared cloud store (iCloud / CloudKit).** Each app currently keeps its **own** local notes
   library — they do **not** sync to each other. A note made on the phone won't appear on the Mac. A
   shared CloudKit-backed store is the natural next unlock so all four surfaces land in **one** library.
2. **All hardware-side verification.** The mic + microSD + the single-pin resistor-ladder buttons need
   to be wired and the ADC voltage bands + LPCOMP wake threshold calibrated; then real BLE transfer and
   real on-device transcription (iPhone/Watch) can be confirmed. Until then everything runs on
   `MockDeviceSyncService` / simulators.
3. **Watch live capture.** The record→transfer→note hop is code-complete and standard WatchConnectivity,
   but the simulator can't synthesize the press-and-hold gesture — it's confirmable only on a real watch.
4. **Cosmetic:** the transcription-unavailable placeholder string is Mac-flavored ("install
   whisper-cli") and should be made platform-aware.

---

## Branches (as of this snapshot)

- **HandheldCommunicator-nRF:** `feature/recorder` — Phases 1–3. (`main` / `v1.0-keyboard` = the stable
  keyboard.)
- **HandheldNotes:** `feature/draft-model-and-modes` — the Mac app + the extracted core. The watch's
  small core additions (`NoteSource.watch`, `AppModel.ingestFromWatch`) are on `feature/watch-support`.
- **HandheldNotesiOS:** `main` — the iPhone app. The watch app is on `feature/watch-support`.

---

## Roadmap / next (ordered)

1. **iCloud/CloudKit shared store** — unify the four surfaces into one synced library (the big unlock).
2. **Hardware bring-up** — wire the mic + SD + resistor ladder, calibrate, then confirm real BLE
   transfer and real transcription on device.
3. **Polish** — platform-aware placeholder; firmware Phase 4 (keyboard ↔ recorder mode toggle); more
   iOS/watch UI depth.
4. **Branch consolidation** — merge the `feature/*` lines once each is verified.
