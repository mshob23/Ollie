# Handheld Notes — App Plan

A macOS **voice-notes system**. Where the existing **Handheld Companion** app is a
*clipboard utility* (hold F16 → record → transcribe → copy), **Handheld Notes** is a
*notes database*: every capture lands as a saved, titled, searchable note with its audio
attached and playable. Notes sync across the Mac, iPhone, and Apple Watch apps over iCloud.

This document is the architecture, the data model, the capture flow, the iCloud sync story,
and the exact build/run commands.

> Separate project. Does **not** touch the old app (`../HandheldCompanionMac`), its data,
> `~/.whisper-models`, or its Recordings. New code, new bundle id
> (`com.mohammadshobaki.handheldnotes`), new Application Support directory
> (`~/Library/Application Support/HandheldNotes`).

---

## 1. The product in one paragraph

A notes-first window: a **persistent capture area pinned to the top** (independent of which
note is selected), a sidebar list of finalized notes (newest first), and a detail pane
showing the transcript, an audio player, and editable title. The capture area is a live
**draft**: holding **F16** records the Mac mic and *appends* the transcribed speech to the
in-progress draft, which keeps accumulating across recordings and edits until you
**explicitly conclude it** (Send / ⌘↩) into the saved list. Notes captured on the **iPhone**
or **Apple Watch** (sibling repo) arrive over iCloud / WatchConnectivity and drop straight
into the same library. Transcription reuses the proven whisper.cpp + Apple Speech engine from
the old app.

---

## 2. The capture flow — notes are open until concluded

A note **does not finalize when a recording stops.** The capture area holds one in-progress
`Draft` (`Models/Draft.swift`) that accumulates content until the user explicitly concludes
it:

- **Hold-to-talk (F16)** records the Mac mic via `AVAudioEngine`, transcribes the clip, and
  **appends** it to `draft.transcript` (`Draft.appendSpeech`, joining with a space so
  successive takes read as prose). The most recent recording's audio/duration/engine are
  retained on the draft so the concluded note keeps a playable recording. Degrades gracefully
  to a banner if mic/hotkey permissions are absent.
- **Space / Newline / Backspace** (the on-screen edit keys, or typing directly in the field)
  edit the **same** draft buffer (`typeSpace` / `typeNewline` / `backspace`).
- **Conclude** — and only conclude — finalizes the draft into a saved `Note` and starts a
  fresh empty draft (`AppModel.concludeDraft`). It's triggered by the **Send** button or the
  **⌘↩** shortcut. Concluding an empty draft is a no-op.

**Externally captured notes are different on purpose:** audio recorded on the Apple Watch
arrives **already concluded** (over WatchConnectivity → the iPhone's pipeline), so it bypasses
the draft entirely and drops straight into the notes list as a finished note via
`ingest(…, source: .watch)`. That ingest path deliberately does **not** touch `recordingState`
/ `draft`, so a background ingest never disturbs the live capture area.

Both *finalize* paths converge on a `Note`: `Draft.makeNote()` for concluded drafts,
`NotesPipeline.ingest(audioURL:source:)` for ingested files. Live appending uses
`NotesPipeline.transcribeClip(audioURL:noteID:)`, which transcribes + imports audio
**without** producing a note.

---

## 3. Architecture

```
                         ┌─────────────────────────────────────────────┐
                         │                 SwiftUI UI                    │
                         │  CaptureBar (persistent top: live DRAFT)      │
                         │  NotesListView · NoteDetailView               │
                         │  SettingsView (Engine)                        │
                         └───────────────┬───────────────────────────────┘
                                         │  @MainActor ObservableObject
                         ┌───────────────▼───────────────┐
                         │          AppModel              │  app-wide state
                         │  notes, selection, search,     │
                         │  recordingState, draft         │
                         └───┬───────────┬───────────┬────┘
                             │           │           │
          ┌──────────────────▼──┐  ┌─────▼───────┐  ┌▼───────────────────┐
          │  NotesDataStore     │  │ NotesPipeline│  │  Capture            │
          │  (SwiftData+CloudKit│  │  ingest()    │  │  MicCaptureService  │
          │   + audio dir)      │  │              │  │  HotKeyManager (F16)│
          └─────────────────────┘  └──────┬───────┘  └─────────────────────┘
                                          │
                                   ┌──────▼───────┐
                                   │ Transcribing │
                                   │  Service     │
                                   │  ├ AppleSpeech (real)
                                   │  └ WhisperCpp  (real if installed, else stub note)
                                   └──────────────┘
```

### Layer responsibilities

- **`AppModel`** (`@MainActor`, `ObservableObject`) — the single source of truth the views
  observe. Holds the notes array, current selection, search text, recording state, and the
  active **`draft`**. Owns the services and the draft lifecycle (`concludeDraft` /
  `clearDraft` / `draftSpace|Newline|Backspace`) plus the `ingest(…)` path watch notes arrive
  through. Everything the UI does goes through here.
- **`NotesDataStore` / `NoteEntity`** — persistence. Notes are SwiftData records under
  `~/Library/Application Support/HandheldNotes`, mirrored over **iCloud (CloudKit)**; audio
  rides along as an `.externalStorage` blob and materializes to `.../Audio/<uuid>.<ext>` on
  demand (`AudioSync`). `AppModel` projects an `[Note]` array out of the store. CRUD,
  full-text search, and first-run seeding of demo notes.
- **`NotesPipeline`** — the convergence point. Takes an audio URL + a `NoteSource`, copies
  the audio into the store, runs transcription, derives a title, creates the `Note`, and
  returns it. Source-agnostic.
- **`TranscribingService`** — protocol with two implementations (Apple Speech, whisper.cpp),
  adapted from the old app. Picks by setting; falls back cleanly.
- **`MicCaptureService`** — `AVAudioEngine` tap → writes a 16 kHz mono WAV. (The old app
  shells out to ffmpeg for capture; here we use native `AVAudioEngine` so capture has no
  external-binary dependency and degrades to a clear message if mic permission is absent.)
- **`HotKeyManager`** — Carbon `RegisterEventHotKey` for global **F16** press/release
  (push-to-talk), adapted from the old app. No Accessibility permission required.

### Concurrency

Swift 6 strict concurrency. `AppModel` and all services that touch UI state are
`@MainActor`. Transcription runners are `actor`s (CPU-bound work off the main thread).

---

## 4. Data model

```swift
struct Note: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String            // editable; derived from transcript on creation
    var transcript: String       // the body
    var createdAt: Date
    var updatedAt: Date
    var source: NoteSource       // .computer | .watch | .phone | .seed
    var audioFileName: String?   // relative to the Audio/ dir; nil if audio was deleted
    var durationSeconds: Double?
    var engineUsed: String?      // "Apple Speech" | "whisper.cpp" | "demo"
    var isFavorite: Bool
}

enum NoteSource: String, Codable { case computer, watch, phone, seed }
```

A `Note` is **finalized** content in the sidebar list. In-progress live content is a
separate, lighter **`Draft`** (`Models/Draft.swift`) that is *not* persisted as a note until
concluded — it carries the accumulating `transcript`, the retained `audioFileName` /
`durationSeconds` / `engineUsed` from the latest recording, and an `appendCount`. On conclude,
`Draft.makeNote()` materializes it into a `Note` with `source: .computer`. The active draft is
session state (a fresh empty draft on launch); only finalized notes are persisted.

- **Title derivation**: first sentence (or first ~6 words) of the transcript, title-cased,
  capped to ~60 chars. User can edit it freely; editing sets `updatedAt`.
- **Search**: case-insensitive substring over `title` + `transcript`.
- **Audio**: stored as `Audio/<note.id>.<ext>`. Playback via `AVAudioPlayer`. Deleting a note
  deletes its audio file too.
- **Persistence**: SwiftData (`NoteEntity`) mirrored over iCloud (CloudKit). See §5.

---

## 5. iCloud sync (Mac ↔ iPhone ↔ Watch)

Notes live in a SwiftData store that is **CloudKit-mirrored**, so the Mac and iPhone apps
share one library and a note made on one device appears on the others. (The watch app carries
no Speech framework, so it never transcribes — it ships audio to the iPhone; see §2.)

- **`NoteEntity`** is the on-disk + synced record; `AppModel` projects a public `[Note]` array
  out of it. Every stored property has a default value and there are **no unique constraints**
  (both are CloudKit requirements); identity is enforced in code by upserting by `id`.
- **Audio** rides along as an `.externalStorage` `audioData` blob so the recording syncs
  alongside the transcript (toggleable — the user opts into syncing audio). `AudioSync.encode`
  reads the local file into the blob; `AudioSync.materialize` writes a synced blob back out to
  a local `Audio/<id>.<ext>` file on demand so playback just works on a device that received
  the note but not yet its local file.
- **Bidirectional refresh**: `ModelContext.didSave` covers local writes, and
  `.NSPersistentStoreRemoteChange` re-projects another device's synced-in edits. Both call
  `reloadNotes()` (see `AppModel.observeRemoteChanges()`).

---

## 6. What is real vs. stubbed

| Piece | State | Notes |
|---|---|---|
| Notes store, CRUD, search, seed | **Real** | SwiftData + audio dir under `HandheldNotes/` |
| iCloud / CloudKit sync (Mac ↔ iPhone) | **Real** | CloudKit-mirrored SwiftData; audio rides along as an external blob |
| Notes UI (list, detail, edit, delete, playback, search) | **Real** | SwiftUI |
| Apple Speech transcription | **Real** | macOS 26 `SpeechAnalyzer`; on-device, file-based path needs no TCC |
| whisper.cpp transcription | **Real if installed** | Shells to `whisper-cli` + `ffmpeg`; if missing, returns a clear stub transcript and the note still saves |
| Capture (F16 → mic → **append to draft**) | **Real** | `AVAudioEngine` capture + Carbon F16 hotkey; transcribed speech appends to the active draft; **conclude** (Send / ⌘↩) finalizes. Degrades to a banner if mic/hotkey unavailable |
| Draft model (open until concluded) | **Real** | `Draft` + `AppModel.concludeDraft` |
| Watch ingest (notes arrive **already concluded**) | **Real** | `AppModel.ingestFromWatch` runs the audio through the normal transcribe → save path; finished notes drop straight into the list |
| Demo seed notes | **Real** | 4 seeded notes (1 with a real playable bundled WAV) so screenshots are populated |

**Graceful degradation (so an automated launch never blocks):** the app never *requests*
mic permission at launch. The window always shows. Mic permission is requested only when the
user first triggers a recording; if denied, a banner explains it and the rest of the app keeps
working.

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
  Info.plist                   ← bundle id, usage strings (mic)
  HandheldNotes.entitlements   ← mic + iCloud/CloudKit + aps
  Scripts/build_app.sh         ← build + bundle + sign
  Sources/HandheldNotesCore/   ← shared library (Mac + iOS compile this)
    App/        AppModel.swift, DemoSeed.swift
    Models/     Note.swift, Draft.swift   ← Draft = open-until-concluded
    Store/      NotesDataStore.swift, NoteEntity.swift (SwiftData+CloudKit),
                NotesStore.swift, NotesPipeline.swift (ingest + transcribeClip),
                AudioSync.swift (local file ↔ synced blob), SampleAudio.swift
    Transcription/  TranscribingService.swift, AppleSpeechTranscriber.swift, WhisperCppTranscriber.swift
    Capture/    MicCaptureService.swift
    Theme/      Theme.swift (colors, fonts, reusable SwiftUI styles)
    Resources/*.wav            ← bundled demo audio (seed note)
  Sources/HandheldNotes/       ← the macOS app (AppKit + Carbon F16)
    App/        main.swift, AppDelegate.swift
    Capture/    HotKeyManager.swift (Carbon F16 push-to-talk)
    UI/         RootView.swift (persistent capture header + list|detail),
                CaptureBar.swift (live DRAFT + edit keys + Send),
                NotesListView.swift, NoteDetailView.swift,
                SettingsView.swift (Engine), AudioPlayerView.swift
```

---

## 9. Next steps (after this pass)

1. Tag/folder organization and export (Markdown) across the synced library.
2. Make the transcription-unavailable placeholder platform-aware (it's Mac-flavored today).
3. Optional: bundle a whisper model or wire the model picker from the old app if whisper is
   preferred over Apple Speech.
