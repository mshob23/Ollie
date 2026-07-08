# Ollie — Ecosystem Status

*Snapshot of the whole system, July 2026.*

**The vision:** capture a spoken thought from whatever device is nearest — your Mac, your iPhone, or
your wrist — and have it transcribed and filed into one notes library, with no fuss; then let agents
work that library and hand you back designed, glanceable answers on every screen. The entire loop
exists and is verified on hardware: notes flow between the three apps over iCloud, a scheduled agent
runner tags/answers/publishes, and its views render on Mac, iPhone, **and the watch**.

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
| **HandheldNotes** | Swift / SwiftUI / Python | The **shared core** + the **Mac app** + the **MCP server** + the **agent runner** | `Sources/HandheldNotesCore/` (model, store, transcription, agent layer, `MarkdownLite`/`FenceWidgets`, theme, `AppModel`), `Sources/HandheldNotes/` (the macOS UI), `mcp-server/`, `Scripts/` (runner + runbook) |
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
| `HandheldNotesCore` shared library | ✅ extracted, public API, green tests (incl. schema golden gate) |
| Mac app | ✅ Developer-ID build installed; capture + Views pane verified on screen |
| iPhone app | ✅ TestFlight **build 33** (`VALID`); Notes / Views / Settings tabs on hardware; camera string dropped (C1 validated) |
| Apple Watch app | ✅ on hardware: press-and-hold capture verified; pinned view renders on the wrist; watch-face complication (build 33) taps straight to capture |
| iCloud / CloudKit shared store | ✅ one library across all three (CloudKit + SwiftData, Production schema deployed) |
| Agent layer (M0–M9) | ✅ tags · memory · views · gate · MCP server · scheduled runner · checkboxes · watch views · restore · fence widgets |

---

## The three layers (the agent layer — SHIPPED July 2026)

Ollie's thesis in one line: **capture is dumb, intelligence is rented, the data is owned.** The whole
system sorts into three layers — all shipped (milestones M0–M9):

| Layer | What it is | State |
|---|---|---|
| **Capture** | The three surfaces above → transcribe → save. Immediate, never waits on anything. | ✅ shipped |
| **Owned store** | One CloudKit/SwiftData library. **Notes are immutable ground truth**; the agent layer (tags · memory · view revisions · interactions · instructions) is *derived, attributed, regenerable, disposable* data alongside them. | ✅ shipped |
| **Rented intelligence** | Agents (a Claude session / the scheduled `claude-runner`) read the corpus over MCP and write back through a validated inbox → the Mac app applies. Understanding is **cached**, not baked in. | ✅ shipped |

What makes it safe and useful: agents **write back** tags + memory (owned judgment, not a
one-off chat); a **gate** marks notes *restricted* so they and everything derived from them never
leave the device; **views** — named living documents agents publish as immutable revisions, rendered
as a feed with history, tappable citations, and **fence widgets** (`metric`/`chart`/`timeline`/`table`
render as real cards, bars, timelines, grids on every device); **checkboxes are a two-way channel**
(a tick is consumed and acknowledged by the next run); the user can **restore** any earlier revision
(append-only, attributed `user-mac`/`user-ios`); and a votable **"Ollie wishlist"** view lets agents
propose — and the user approve — the next capability. The launchd runner closes the loop: speak a
question into the watch on the sidewalk, and a designed answer is on your wrist by the time you're home.

The canonical data contract every door conforms to is **[`docs/agent-contract.md`](docs/agent-contract.md)**;
milestone specs + as-built notes are [`AGENT_LAYER_PLAN.md`](AGENT_LAYER_PLAN.md); agent-facing
operating notes are [`CLAUDE.md`](CLAUDE.md); what's next is [`BACKLOG.md`](BACKLOG.md).

---

## Roadmap / next (ordered)

1. **Live-eval follow-ups (Jul 2026)** — a `diagram`/sketch fence (the wishlist's first user-approved
   request), a min-baseline option for `chart` (tight-range series render as identical bars), and two
   app fixes: capture-bar notes stamp `createdAt` at draft-session start (agents miss them), and feed
   previews leak literal `**`. See BACKLOG.md.
2. **Event-driven runner** — C2 closed 2026-07-07 (headless runner live, every 4 h, runtime
   deployed to `~/Ollie`); next make the Mac app kick it on CloudKit note arrival (debounced)
   instead of only the timer, with the arrival-time coverage cursor + `runs.jsonl` work log
   (BACKLOG.md §home-node track).
3. **Polish** — platform-aware transcription placeholder; more iOS / watch UI depth.
