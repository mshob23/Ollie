# Ollie — Ecosystem Status

*Snapshot of the whole system, June 2026.*

**The vision:** capture a spoken thought from whatever device is nearest — your Mac, your iPhone, or
your wrist — and have it transcribed and filed into one notes library, with no fuss. The entire
software stack for that vision exists and is verified; notes flow between the three apps over iCloud.

---

## The system at a glance

**Three capture surfaces feed one transcribe-and-save pipeline.**

| Surface | How you capture | How it becomes a note |
|---|---|---|
| 💻 **Mac** | hold **F16** (push-to-talk) | the Mac app records its mic and transcribes locally |
| 📱 **iPhone** | tap to type, or record a voice note | transcribes on-device (Apple **SpeechAnalyzer**) |
| ⌚ **Apple Watch** | **hold** the on-screen button (or the Action button) | ships the clip to the iPhone over **WatchConnectivity** → the phone transcribes |

All three converge through **`HandheldNotesCore`** (the shared Swift library) into one notes library,
where each note is tagged with the source it came from. The library is shared across every device
through **iCloud (CloudKit + SwiftData)**, so a note made on the phone shows up on the Mac and watch.

---

## Components (where the code lives)

| Repo | Stack | Role | Key paths |
|---|---|---|---|
| **HandheldNotes** | Swift / SwiftUI | The **shared core** + the **Mac app** | `Sources/HandheldNotesCore/` (model, store, transcription, theme, `AppModel`), `Sources/HandheldNotes/` (the macOS UI) |
| **HandheldNotesiOS** | Swift / SwiftUI | The **iPhone app** + the embedded **Apple Watch app** | `Sources/` (iOS UI + `WatchSessionReceiver`), `Watch/Sources/` (the watch app), `project.yml` (XcodeGen) |

`HandheldNotesCore` is the keystone: the **same** notes model, storage, and transcription pipeline are
compiled into the Mac app **and** the iPhone app, so the two never diverge. (The watch app reuses only
the theme + model — watchOS has no Speech framework, so it never transcribes.)

> Not to be confused with the **legacy** `HandheldCompanionMac` (the original SuperWhisper-style tool).
> It is separate and untouched; the current Mac app is **HandheldNotes**.

---

## How a note is born (data flow)

- **Mac → note:** hold F16 → the Mac app records its mic → transcribes with whisper.cpp / Apple Speech
  → saves a note.
- **iPhone → note:** type directly, or record a voice note → transcribe on-device with SpeechAnalyzer
  → save.
- **Watch → note:** hold the button to record → on save, `WCSession.transferFile` ships the `.m4a` to
  the iPhone → `WatchSessionReceiver` → `AppModel.ingestFromWatch(url:)` → the normal pipeline → a
  `.watch`-tagged note.

Every saved note then mirrors to the other devices over iCloud.

---

## The sync story (Mac ↔ iPhone ↔ Watch)

A single **iCloud / CloudKit** store, backed by SwiftData, is shared by the Mac and iPhone apps:

- Each note is a `NoteEntity` record; its recording rides along as an `.externalStorage` blob so
  audio syncs alongside the transcript (toggleable per the user's iCloud space).
- Identity is enforced in code (upsert-by-`id`) because CloudKit forbids unique constraints.
- Changes flow in both directions; `.NSPersistentStoreRemoteChange` re-projects another device's
  edits into the live list. (See `NotesDataStore` + `AppModel.observeRemoteChanges()`.)

---

## Current status

| Piece | Status |
|---|---|
| `HandheldNotesCore` shared library | ✅ extracted, public API, green tests |
| Mac app | ✅ builds + runs; verified on screen |
| iPhone app | ✅ builds + runs in the iOS 26 simulator |
| Apple Watch app | ✅ builds + launches in the watchOS 26 simulator; UI verified |
| iCloud / CloudKit shared store | ✅ Mac + iPhone sync one library (CloudKit + SwiftData) |

---

## Not built yet (the honest gaps)

1. **Watch live capture on hardware.** The record→transfer→note hop is code-complete and standard
   WatchConnectivity, but the simulator can't synthesize the press-and-hold gesture — it's confirmable
   only on a real watch.
2. **Cosmetic:** the transcription-unavailable placeholder string is Mac-flavored ("install
   whisper-cli") and should be made platform-aware.

---

## Roadmap / next (ordered)

1. **Hardware verification of watch capture** — confirm the press-and-hold record → transfer → note
   path on a real Apple Watch.
2. **Polish** — platform-aware transcription placeholder; more iOS / watch UI depth.
3. **Organization & export** — tags/folders and Markdown export across the synced library.
