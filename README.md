# Handheld Notes

A macOS **voice-notes system** — the desktop companion to the Handheld Communicator
device. Where the sibling *Handheld Companion* app is a clipboard utility (hold F16 →
record → transcribe → copy), **Handheld Notes** is a notes database: every capture lands
as a saved, titled, searchable note with its audio attached and playable.

Two capture modes:
- **Computer mode** — a global **F16** push-to-talk records the Mac mic, transcribes, and
  saves the result as a note. (Real.)
- **Local mode** — the handheld records to its SD card offline and later syncs the audio
  over BLE; the app transcribes each file, saves it, and tells the device to delete its
  copy. (Pipeline real; the BLE device side is **stubbed** with a mock that replays bundled
  sample audio through the same path, so the whole flow runs with no hardware.)

Transcription reuses the proven whisper.cpp + Apple Speech engine from the sibling app.

See [`NOTES_APP_PLAN.md`](./NOTES_APP_PLAN.md) for the full architecture, the BLE audio-sync
GATT protocol sketch, the data model, and what is real vs. stubbed.

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
