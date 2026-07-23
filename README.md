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
an iCloud-vs-SwiftPM `.build` corruption bug when the repo lives in a cloud-synced folder).
The Mac app is the only store writer and the corpus **only refreshes while it is running**,
so keep it open for everything below.

> **No Apple Developer account?** That command still works: with no signing identity
> installed the script falls back to **ad-hoc signing** — the app builds, launches, and
> everything runs locally on this Mac. What you don't get is CloudKit: no cross-device
> sync (and macOS permission grants won't persist across rebuilds). For the full
> Mac ⇄ iPhone ⇄ watch loop, see
> [Bring your own Apple identity](#bring-your-own-apple-identity-forks--contributors).

### 2. The iPhone + watch app

For real devices, install via **TestFlight** (currently build 37 — the watch is three
side-by-side panels with a full views list, unread dots light every surface and clear
across devices, Annotate sends corrections back to the agent, revision history +
AI memory each fold into their own pages, and agent-written reminders fire as real
notifications that deep-link back to the inbox view). To build from source,
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
(`python3 -m venv .venv && . .venv/bin/activate && pip install -r requirements.txt`), then
register it from the repo root (`claude mcp` needs absolute paths — `$PWD` supplies them):

```bash
claude mcp add ollie -- \
  "$PWD/mcp-server/.venv/bin/python" \
  "$PWD/mcp-server/ollie_mcp.py"
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

## Bring your own Apple identity (forks & contributors)

The repo ships **no signing artifacts** — the entitlements files carry the maintainer's
team/bundle/container values as a worked example, and `build_app.sh` takes yours through
environment variables. Ad-hoc local builds need none of this (see the note in step 1).
To run the full CloudKit sync loop under your own team (requires a paid Apple Developer
Program membership — CloudKit + push are member-only entitlements):

1. **Pick your identifiers.** A bundle id (e.g. `com.you.ollie`) and an iCloud container
   (`iCloud.com.you.ollie`). Register the App ID with iCloud + Push Notifications enabled
   and create the container (developer.apple.com → Certificates, Identifiers & Profiles).
2. **Make your entitlements.** Copy `HandheldNotes.entitlements` and replace the
   `application-identifier` (`TEAMID.bundleid`), `team-identifier`, and container values
   with yours — each key's role is documented inline in the file. Set the same bundle id
   as `CFBundleIdentifier` in `Info.plist`, and point the one code constant at your
   container: `cloudKitContainerID` in
   `Sources/HandheldNotesCore/Store/NotesDataStore.swift` (Core is compiled into all
   three apps, so this one edit covers Mac, iPhone, and watch). (Same drill for
   `HandheldNotes-release.entitlements` when you get to Developer-ID builds.)
3. **Make a provisioning profile** for that App ID (macOS *Development* to iterate;
   *Developer ID* for release) and download it. The build embeds it in the bundle —
   macOS refuses to launch an app with iCloud/aps entitlements without a matching
   embedded profile (AMFI error 163), which is also why profile and entitlements must
   agree on the CloudKit environment.
4. **Point the build at your artifacts:**

   ```bash
   ENTITLEMENTS=path/to/your.entitlements \
   PROVISION_PROFILE=path/to/your.provisionprofile \
   CODE_SIGN_IDENTITY="Apple Development: Your Name (YOURTEAMID)" \
   ./Scripts/build_app.sh
   ```

5. **Schema.** The CloudKit **Development** schema self-creates — sign into iCloud, save
   a note, done. **Production never self-creates**: before any release build you must
   deploy the schema in the CloudKit Dashboard, and the release path in `build_app.sh`
   refuses to proceed until that's verified (the full procedure and the outage that
   motivated the gate are in [`RELEASE.md`](RELEASE.md)).
6. **iOS + watch.** Set the same team and container in the sibling repo
   ([`../HandheldNotesiOS/README.md`](../HandheldNotesiOS/README.md) → *Building with
   your own Apple identity*). All three apps must share **one** container — mismatched
   environments sync "successfully" into different universes and nothing crosses.

## Going deeper — the docs map

| Doc | Role |
|---|---|
| [`VISION.md`](VISION.md) | **The soul** — what Ollie is / refuses to be, the trust + cost model, north-star scenes |
| [`docs/agent-contract.md`](docs/agent-contract.md) | **The canonical contract** — entities, export layout, inbox ops, fence grammar, reserved names. On mechanics, this wins |
| [`ECOSYSTEM.md`](ECOSYSTEM.md) | Component map + data flow + current status across all three apps |
| [`RELEASE.md`](RELEASE.md) | Ship discipline both platforms — the schema-deploy gate and "upload ≠ shipped" traps |
| [`docs/home-node.md`](docs/home-node.md) | Running the Mac as the always-on hub |
| [`mcp-server/README.md`](mcp-server/README.md) | MCP tools + setup for interactive Claude |

**Status (July 2026):** agent-layer milestones **M0–M24a shipped** (tags · memory · views · gate
· MCP server · scheduled runner · checkboxes · watch views · restore · fence widgets ·
event-driven runs · arrival coverage · watch side panels · unread indicators · annotations ·
directory sections · inbox receipts · **reminders + arrival banners · runner web research**);
iOS **TestFlight build 37** (three-panel watch with a full views list, save/discard undo,
unread dots + badges, Annotate, `/`-sections, notification deep-links); the unattended runner
is **live and event-driven** (a note arrival kicks a run in **~15–25 s**, a mid-run arrival
schedules one follow-up pass; 4 h backstop) and may **read the public web** under contract
§9's egress rules (distilled queries, never note text). `checklist` / `cl2:` names are
reserved but unbuilt; instant iPhone push is designed (`docs/notifications-push-spike.md`),
not built.
