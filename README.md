# Ollie

A macOS **voice-notes system**. Where the sibling *Handheld Companion* app is a clipboard
utility (hold F16 → record → transcribe → copy), **Ollie** is a notes database:
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
open ".build/debug/Ollie.app"       # launch it
```

Or run the executable directly: `swift run HandheldNotes`.

**Requirements:** macOS 14+ (Apple Speech is best on macOS 26+), the Swift toolchain.
whisper.cpp transcription additionally wants `whisper-cli` + `ffmpeg` on `PATH` (Homebrew);
without them the app uses Apple Speech (or a labelled placeholder) and still runs.

## Agent runner (the loop)

Ollie has an **agent layer**: agents read the note corpus and write back *tags*, a *memory* codebook,
and living *views* (published through the Mac-side inbox; the app is the only store writer). The
**agent runner** drives that layer unattended — a headless Claude session that periodically tags new
notes, answers request-notes ("Ollie, look into…"), and refreshes the standing views. Speak a note
into the watch on the sidewalk; an answer can be in the Views tab by the time you're home. Full
operational detail is in [`docs/agent-contract.md`](./docs/agent-contract.md) §9; the essentials:

```bash
./Scripts/ollie-agent-run.sh              # run one pass now (needs the Mac app open)
./Scripts/install-agent-runner.sh         # install the launchd job (every 4h); PRINT_ONLY=1 to dry-run
```

The runner guards itself (skips if a run is already alive, exits quietly if the Mac app is closed,
stops if the corpus is stale > 24h). Logs land in `~/Ollie/agent-runs/<timestamp>.log` (pruned after
30 days). The prompt is [`Scripts/ollie-runbook.md`](./Scripts/ollie-runbook.md).

- **Cadence:** the launchd `StartInterval` (default `14400` = 4 h). Change it in the installed plist
  (or re-run the installer with `START_INTERVAL=<seconds>`) and reload the job.
- **Model:** defaults to `opus`; override per run with `CLAUDE_MODEL=<model> ./Scripts/ollie-agent-run.sh`
  (or set it in the plist's `EnvironmentVariables` for the scheduled job).

**Allowlist the write tools first.** A headless run can't answer permission prompts, so the `ollie` MCP
write tools must be pre-approved in `~/.claude/settings.local.json` or the run stalls:

```json
{
  "permissions": {
    "allow": [
      "mcp__ollie__tag_note",
      "mcp__ollie__untag_note",
      "mcp__ollie__append_memory",
      "mcp__ollie__retire_memory",
      "mcp__ollie__publish_view"
    ]
  }
}
```

(Or allow the whole server with `"mcp__ollie__*"`.) The scripts never touch `~/.claude/` for you — do
this once by hand. The MCP server itself lives in [`mcp-server/`](./mcp-server/) (see its README).

## Not affiliated with the data of the sibling app

This is a separate project with its own bundle id (`com.mohammadshobaki.handheldnotes`) and
its own storage (`~/Library/Application Support/HandheldNotes`). It does not touch the
*Handheld Companion* app, its recordings, or `~/.whisper-models`.
