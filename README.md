# Ollie

Ollie is a **mailbox and a bulletin board**: you drop a spoken or typed thought in from your
wrist, pocket, or desk the moment it occurs, it lands in one private iCloud library, and
intelligence *you already own* posts back small living "views" — a metric on the watch, a
weekly report under a pinned name — that you read, tick, and restore. Capture never waits on
intelligence; everything between the two surfaces is asynchronous. There is no vendor server,
no account, no copy of your data in anyone's custody. Ollie validates *mechanics* and never
*meaning* — the thinking is rented from whatever agent you already have (Claude today). See
[`VISION.md`](VISION.md) for what Ollie is and refuses to be.

> **Product name is Ollie; the code/scheme/bundle names still say `HandheldNotes`**
> (`com.mohammadshobaki.handheldnotes`). This repo (**HandheldNotes**) is the hub — Mac app +
> shared Core + MCP server + Scripts; the iPhone + watch app live in `../HandheldNotesiOS`.

## The ecosystem

| Piece | What it is | Where |
|---|---|---|
| 💻 **Mac app** (`Ollie.app`) | Capture (hold **F16**), the only store writer, the home node that runs agents | `Sources/HandheldNotes/` |
| 📱 **iPhone + ⌚ watch app** | Capture anywhere; views render on every screen | sibling repo `../HandheldNotesiOS` |
| 🧠 **Shared Core** | Models, store, CloudKit sync, transcription, agent layer, renderers, theme — compiled into **all three** apps | `Sources/HandheldNotesCore/` |
| 🗂️ **`~/Ollie` corpus** | The exported note library + agent-layer files (JSONL) + inbox — the file contract agents integrate with | `~/Ollie/` (runtime, not in-repo) |
| 🔌 **MCP server** | Thin adapter exposing the corpus to Claude as read/write tools | `mcp-server/` |
| ⚙️ **Agent runner** | launchd job that runs an agent pass unattended on the Mac | `Scripts/install-agent-runner.sh`, `Scripts/ollie-agent-run.sh` |
| 📐 **Agent layer** | Tags · memory · views · restriction gate — derived, attributed, disposable data | `~/Ollie/{tags,memory,views,interactions}.jsonl` |

**How a note flows:** capture (Mac F16 / phone type-or-speak / watch hold-to-record) →
transcribe → save to one CloudKit + SwiftData library → the Mac app exports it to
`~/Ollie/ollie.jsonl` → an agent reads over MCP, writes tags/memory/views back through the
inbox → the Mac app applies + re-syncs → views ride CloudKit back to phone and wrist.

## Getting started (zero to the full loop)

Prereqs: macOS 14+ (Apple Speech best on 26+), the Swift toolchain, an iCloud account signed
in. Optional for whisper.cpp transcription: `whisper-cli` + `ffmpeg` on `PATH` (Homebrew);
without them the Mac app falls back to Apple Speech and still runs.

### 1. Build and run the Mac app

```bash
./Scripts/build_app.sh          # builds + signs Ollie.app, prints the bundle path
open .build/debug/Ollie.app     # launch it
```

`swift test --scratch-path /private/tmp/hn_scratch` runs the suite (the scratch path avoids
an iCloud-vs-SwiftPM `.build` corruption bug on the Desktop — see [`CLAUDE.md`](CLAUDE.md)).
The Mac app is the only store writer and the corpus **only refreshes while it is running**,
so keep it open for everything below.

### 2. The iPhone + watch app

For real devices, install via **TestFlight** (currently build 34 — watch-face complication
plus the full fence-widget set on the wrist). To build from source,
`xcodegen generate` then open in Xcode — the full build rules (and the two xcodebuild
gotchas) live in [`../HandheldNotesiOS/README.md`](../HandheldNotesiOS/README.md). It links
this repo's Core by relative path, so a Core change means rebuilding **both** apps.

### 3. First capture → where the note lands

Hold **F16** on the Mac (or capture on the phone/watch), speak, and Send. The note appears in
the app's list and — with the Mac app running — is exported to `~/Ollie/ollie.jsonl`, tagged
with the source it came from. That file (plus the agent-layer JSONL beside it) is the corpus
every agent reads.

### 4. Connect interactive Claude via MCP

Point a Claude Code session at the corpus so you can ask *"what did I need to do last week?"*
and let it tag, remember, and publish views. From `mcp-server/` set up the venv first
(`python3 -m venv .venv && . .venv/bin/activate && pip install -r requirements.txt`), then:

```bash
claude mcp add ollie -- \
  /Users/mohammadshobaki/Desktop/Projects/Agents/HandheldNotes/mcp-server/.venv/bin/python \
  /Users/mohammadshobaki/Desktop/Projects/Agents/HandheldNotes/mcp-server/ollie_mcp.py
```

Read tools are safe to auto-approve; the **write** tools queue changes and prompt unless
allowlisted. Full tool list, Claude Desktop config, and the allowlist snippet are in
[`mcp-server/README.md`](mcp-server/README.md).

### 5. Make the Mac a home node

So the Mac stays awake on AC (even lid-closed) to run agents while you're away:

```bash
./Scripts/setup-home-node.sh --apply     # bare invocation / --status is read-only & safe
```

Uses only Apple-first-party mechanisms (pmset + a caffeinate LaunchAgent); one sudo prompt.
The battery-cap and clamshell-test steps are in [`docs/home-node.md`](docs/home-node.md).

### 6. Unattended agent runs

This closes the loop — speak a question into the watch on the sidewalk, and a designed answer
is on your wrist by the time you're home. Two one-time prereqs, then install:

- **Log `claude` in** with your subscription account: run `claude` interactively once and
  `/login` (a headless run can't answer a login or a permission prompt — allowlist the `ollie`
  write tools too, see step 4).

```bash
./Scripts/install-agent-runner.sh         # PRINT_ONLY=1 to dry-run first
```

The installer **deploys the runtime into `~/Ollie`** (`bin/` = runner + runbook, `mcp/` =
server + venv + config) and schedules a launchd job (every 4 h). It deploys because
launchd-spawned processes **cannot read the iCloud-synced Desktop repo** (macOS TCC) — so
`~/Ollie` is home for the *runtime*, the repo is *source*. **Re-run the installer after
editing the runner, the runbook, or the MCP server** — the deployed copies are what execute.

Each firing guards itself and no-ops unless all pass: no run already in flight, the **Mac app
is running**, the **corpus is fresh** (< 24 h), and the **workspace is trusted**. The agent's
prompt is [`Scripts/ollie-runbook.md`](Scripts/ollie-runbook.md) (editing it changes agent
behavior). Model defaults to `opus`; logs land in `~/Ollie/agent-runs/`.

## Going deeper — the docs map

| Doc | Role |
|---|---|
| [`VISION.md`](VISION.md) | **The soul** — what Ollie is / refuses to be, the trust + cost model, north-star scenes |
| [`docs/agent-contract.md`](docs/agent-contract.md) | **The canonical contract** — entities, export layout, inbox ops, fence grammar, reserved names. On mechanics, this wins |
| [`ECOSYSTEM.md`](ECOSYSTEM.md) | Component map + data flow + current status across all three apps |
| [`CLAUDE.md`](CLAUDE.md) | Agent-facing operating notes — repo map, invariants, landmines, build gotchas |
| [`AGENT_LAYER_PLAN.md`](AGENT_LAYER_PLAN.md) | Milestone specs M0–M9 with as-built notes |
| [`RELEASE.md`](RELEASE.md) | Ship discipline both platforms — the schema-deploy gate and "upload ≠ shipped" traps |
| [`docs/home-node.md`](docs/home-node.md) | Running the Mac as the always-on hub |
| [`mcp-server/README.md`](mcp-server/README.md) | MCP tools + setup for interactive Claude |
| [`BACKLOG.md`](BACKLOG.md) | What's next |

**Status (July 2026):** agent-layer milestones **M0–M9 shipped** (tags · memory · views · gate
· MCP server · scheduled runner · checkboxes · watch views · restore · fence widgets); iOS
**TestFlight build 34** (watch-face complication + fence widgets v2 + clean previews); the
unattended runner is **live and event-driven** (a note arrival kicks a run in ~2 min; 4 h
backstop). `checklist` / `cl2:` names are reserved but unbuilt.
