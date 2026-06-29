# Handheld Notes

A macOS **voice-notes system**. Where the sibling *Handheld Companion* app is a clipboard
utility (hold F16 → record → transcribe → copy), **Handheld Notes** is a notes database:
every capture lands as a saved, titled, searchable note with its audio attached and playable.

How you capture:
- A global **F16** push-to-talk records the Mac mic, transcribes, and **appends** the speech
  to a live draft, which you conclude (Send / ⌘↩) into a saved note.
- Notes captured on an **iPhone** or **Apple Watch** (sibling repo) arrive over **iCloud /
  WatchConnectivity** and drop straight into the same library.

Notes sync across your Mac, iPhone, and Apple Watch through **iCloud (CloudKit + SwiftData)** —
one library, every device. Transcription reuses the proven whisper.cpp + Apple Speech engine
from the sibling app.

See [`NOTES_APP_PLAN.md`](./NOTES_APP_PLAN.md) for the full architecture, the data model, and
the iCloud sync story.

## Build & run

```bash
./Scripts/build_app.sh                       # builds + signs a real .app, prints its path
open ".build/debug/Handheld Notes.app"       # launch it
```

Or run the executable directly: `swift run HandheldNotes`.

**Requirements:** macOS 14+ (Apple Speech is best on macOS 26+), the Swift toolchain.
whisper.cpp transcription additionally wants `whisper-cli` + `ffmpeg` on `PATH` (Homebrew);
without them the app uses Apple Speech (or a labelled placeholder) and still runs.

## Not affiliated with the data of the sibling app

This is a separate project with its own bundle id (`com.mohammadshobaki.handheldnotes`) and
its own storage (`~/Library/Application Support/HandheldNotes`). It does not touch the
*Handheld Companion* app, its recordings, or `~/.whisper-models`.
