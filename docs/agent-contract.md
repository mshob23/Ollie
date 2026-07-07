# Ollie agent-layer contract

*The canonical data contract for the agent layer. Every door — the inbox, the MCP server,
future App Intents, a future on-device agent — conforms to **this** document. Extracted from
[`AGENT_LAYER_PLAN.md`](../AGENT_LAYER_PLAN.md) §3 (+ the §0 invariants) so agents and future
surfaces cite one stable file instead of the plan. If this and the plan ever disagree, the plan
§3 is the source of truth and this doc is the bug.*

> **What the agent layer is.** Ollie captures morsels (Mac F16 / iPhone / Watch → one CloudKit
> library) and, until now, exposed them **read-only** to agents. The agent layer lets agents write
> *back*: **tags** (cached judgment), **memory** (a codebook of shorthand/preferences/dead-ends),
> and **views** (named living documents published as immutable revisions) — plus a **gate** that
> keeps *restricted* notes and everything derived from them on-device. It is derived, attributed,
> regenerable, and disposable. It never touches the capture path or the notes themselves.

---

## 0. Invariants (the rules the mechanics enforce)

Violating any of these is a **design regression, not a style choice**:

- **Notes are immutable ground truth.** No operation edits `Note.transcript` on an agent's behalf.
  The agent layer is derived, attributed, regenerable, and disposable.
- **Append-only, attributed records.** Every agent contribution carries `agentId` + timestamp.
  Updates are *new* records (view revisions, memory corrections), never in-place edits. Agents may
  delete only *derived* records they conceptually own (untag, retire); **users** may delete anything.
- **Validate mechanics, never meaning.** The app checks ids, sizes, schema — **never** whether a tag
  is sensible or a memory is true. There is no "is this a good tag?" check anywhere, by design.
- **Restriction is contagious.** A derived record inherits the restriction of the note(s) it derives
  from; the export gate drops them together (see §5).
- **Capture is immediate; intelligence is eventually-consistent.** Nothing in the capture path may
  ever wait on the agent layer.
- **The app is the only store writer.** External agents write through the inbox; the Mac app
  validates and applies. Reads are served from the exported files under `~/Ollie/`.

Trust boundary = **the device**. The export gate filters restricted content out of everything under
`~/Ollie/`; the inbox is the only external write path; the Mac app is the only store writer.

---

## 1. Agent identity

`agentId`: a short `provider-surface` string, e.g. `claude-mac`, `claude-runner`. **Reserved for
later:** `ondevice-fm`, `siri`. Every derived record and every op carries one.

Op envelopes additionally carry `via` — the **door** the op came through:

| `via` | Meaning | Status |
|---|---|---|
| `inbox` | file dropped in `~/Ollie/inbox/` | **today** |
| `app-intent` | App Intents ↔ MCP bridge | reserved |
| `in-process` | on-device agent applying `AgentOp` directly | reserved |

---

## 2. Entities (SwiftData, all CloudKit-synced)

Four new `@Model` entities plus one field on the existing `NoteEntity`. All follow the `NoteEntity`
convention exactly: a **default on every property** (CloudKit forbids unique constraints and
required-without-default), the `Entity` suffix, raw-string enums, flat fields, and a public value-type
projection (`AgentTag`, `AgentMemory`, `AgentViewRevision`). Upsert-by-`id` in code.

```swift
@Model public final class TagEntity {          // value type: AgentTag
    public var id: UUID = UUID()
    public var noteId: UUID = UUID()           // subject note
    public var tag: String = ""                // freeform; "key:value" convention unenforced
    public var agentId: String = ""
    public var createdAt: Date = Date.distantPast
}

@Model public final class MemoryEntity {       // value type: AgentMemory
    public var id: UUID = UUID()
    public var text: String = ""               // one fact per entry
    public var agentId: String = ""
    public var createdAt: Date = Date.distantPast
    public var retired: Bool = false           // tombstone; never hard-edited
    public var retiredAt: Date?
}

@Model public final class ViewRevisionEntity { // value type: AgentViewRevision
    public var id: UUID = UUID()
    public var viewName: String = ""           // view identity; exact-match grouping
    public var body: String = ""               // markdown (see §6)
    public var agentId: String = ""
    public var createdAt: Date = Date.distantPast
}

@Model public final class InstructionsEntity { // single record, fixed well-known UUID, upsert
    public var id: UUID = UUID()
    public var text: String = ""               // the user's standing instructions to agents
    public var updatedAt: Date = Date.distantPast
}
```

`NoteEntity` gains one field: `public var isRestricted: Bool = false` (mirrored on `Note`, default
`false`, tolerant decode; `Note.currentSchemaVersion` bumps 2 → 3).

### Semantics

- **Tags** are a **set per note**. Applying an existing `(noteId, tag)` pair is a **no-op**
  (idempotent); dedup **case-insensitively** on apply. `untag` deletes the matching record(s).
- **Memory** is **append-only**; `retire` flips the tombstone (`retired = true`, stamps `retiredAt`).
  Never hard-edited by an agent. Users can hard-delete from the UI.
- **Views**: a "view" is the set of revisions sharing an exact `viewName`. **Latest `createdAt`
  wins display.** Publishing to an existing name **appends** a revision. Users can delete a whole
  view (deletes all its revisions).
- **Instructions**: a **single** user-authored record (fixed well-known UUID, upsert), edited
  in-app, synced like everything else.

> **The M1 entity batch above shipped as one CloudKit Production deploy.** A **fifth** entity,
> **`InteractionStateEntity`**, shipped later in **M7** (Views v2 checkbox layer) as its own single
> batched deploy — see [`views-v2-interaction-spec.md`](views-v2-interaction-spec.md) §2 and the
> **Interaction state** entry in §7. The rule stands: any *new* `@Model`/field trips the schema
> golden gate (`Tests/HandheldNotesCoreTests/SchemaGoldenTests.swift`) by design, and CloudKit
> **Production** must be deployed (Dev import → Dashboard promote → `verify-prod-schema.sh`) before
> the release build — batch it, don't add entities piecemeal. See [`RELEASE.md`](../RELEASE.md) and
> [`docs/cloudkit-sync-troubleshooting.md`](cloudkit-sync-troubleshooting.md).

---

## 3. The write path — `AgentLayerStore`

Every door writes through **one** MainActor choke point, `AgentLayerStore`
(`Sources/HandheldNotesCore/Agent/AgentLayerStore.swift`). Mechanical validation lives **here** and
throws `AgentLayerError`. Agents never touch `ModelContext` directly.

```swift
@MainActor public struct AgentLayerStore {
    public init(context: ModelContext)
    // queries
    public func tags(forNote: UUID) -> [AgentTag]
    public func allTags() -> [AgentTag]                       // vocabulary + export
    public func memory(includeRetired: Bool) -> [AgentMemory]
    public func viewNames() -> [String]
    public func revisions(viewName: String) -> [AgentViewRevision]  // newest first
    public func latestRevisions() -> [AgentViewRevision]      // one per view, newest first
    public func instructions() -> String
    // mutations (mechanical validation here; throws AgentLayerError)
    public func apply(_ op: AgentOp) throws                   // op enum mirrors §4
    public func setInstructions(_ text: String)               // user path (Settings UI)
    public func userDelete(tag: AgentTag) / (memory: AgentMemory) / (view name: String)
}
```

`AgentOp` is `Codable` — the **same struct** the inbox decodes and, later, App Intents construct.

---

## 4. Inbox op protocol (`~/Ollie/inbox/`)

The **only external write path**. One file per op, named `<agentId>-<requestId>.json`, written to a
temp name then **renamed** into place (atomic on APFS — no locks). `requestId` is a UUID minted by
the writer. Envelope:

```json
{"op":"tag","agent":"claude-mac","via":"inbox","ts":"2026-07-05T12:00:00Z",
 "requestId":"…uuid…","payload":{…}}
```

### Ops (payload + mechanical validation — mechanics only, never meaning)

| op | payload | validation |
|---|---|---|
| `tag` | `{"noteId","tag"}` | note exists; tag **1–64** printable chars |
| `untag` | `{"noteId","tag"}` | note exists |
| `memory.append` | `{"text"}` | **1–2000** chars |
| `memory.retire` | `{"id"}` | entry exists |
| `view.publish` | `{"viewName","body"}` | name **1–80** chars; body **1–131072** chars |

**Envelope-level validation:** known `op`, well-formed JSON, file **≤ 256 KB**, and `requestId` not
already in the recent-ledger.

### Results, ledger, and cleanup

- **Echoes** (JSONL append): `~/Ollie/applied.jsonl` / `~/Ollie/rejected.jsonl`, each line
  `{"requestId","op","agent","ts","result":"applied"|"rejected","reason"?}`.
- **Idempotency ledger:** `~/Ollie/.applied-requests.json` — a ring buffer of the **last 1000**
  requestIds, maintained by the ingestor. A duplicate `requestId` is rejected without re-applying.
- **Cleanup:** op files are **deleted** after echo. **Malformed** files move to
  `~/Ollie/inbox/rejected/` for postmortem (not deleted).

---

## 5. Export layout & gate (`~/Ollie/`, written by `CorpusExporter`)

Existing files: `ollie.jsonl`, `notes/<id>.md`, `.ollie.meta.json`, `backups/`. **New:**

| File | Shape (one JSON per line unless noted) |
|---|---|
| `tags.jsonl` | `{"noteId","tag","agentId","createdAt"}` |
| `memory.jsonl` | `{"id","text","agentId","createdAt","retired","retiredAt"?}` (retired entries included, flagged) |
| `views.jsonl` | `{"id","viewName","body","agentId","createdAt"}` — every revision, **full body** (snapshots, not diffs) |
| `instructions.md` | plain markdown, the instructions text |
| `interactions.jsonl` | `{"viewName","blockId","blockText","kind","value","revisionId","surface","updatedAt"}` — **M7**, one line per live checkbox-interaction record (see [`views-v2-interaction-spec.md`](views-v2-interaction-spec.md) §6) |

### Gate rules (apply to every exported artifact)

- Notes with `isRestricted` are **omitted** from `ollie.jsonl` and `notes/`. A note that *becomes*
  restricted has its previously-exported `.md` **pruned** (the orphan-pruning pass already exists; it
  is extended to cover this).
- Tags whose `noteId` is restricted are **omitted** from `tags.jsonl`.
- **Views and memory export in full** — they're agent-authored from an already-filtered corpus, so
  they can't leak a restricted transcript. (The on-device privileged tier that *could* see restricted
  notes is out of scope; see §8.)

The contagion rule lives in **one** Core function so future doors reuse it:
`CorpusGate.exportableNotes(_:)` / `exportableTags(_:notes:)` in
`Sources/HandheldNotesCore/Export/CorpusGate.swift`.

### Meta + reserved field

- `ExportRecord` (in `CorpusExporter`) gains a **reserved** optional `media: [String]?` — always
  `nil`/omitted today, documented for photo notes later (see §8).
- `.ollie.meta.json` keeps its shape; `schemaVersion` becomes **3** and gains
  `"layerCounts": {"tags":N,"memory":N,"viewRevisions":N}`.

---

## 6. View body format

Markdown, rendered with a shared lightweight renderer (`MarkdownLite`). Two conventions agents rely
on:

- **Note citations** — `ollie://note/<uuid>` links; the renderer makes them tappable → opens the
  note.
- **Forward-compat fences** — unknown fenced code blocks (e.g. ` ```checklist … ``` `) render as
  plain monospaced blocks **today**. They are **never stripped, never errored**. This is the reserved
  growth path for Views v2 interactive blocks.

### 6.1 Authoring style + fence-widget conventions (advisory)

The two bullets above are the *mechanical* contract; **style** is guidance and lives in the runbook
(`Scripts/ollie-runbook.md` → "View style guide"), which is the prompt every scheduled run actually
reads. The conventions agents follow, summarized (normative source is the runbook):

- **Glance budget** — first screenful carries the point; first ~10 lines are the wrist-sized version.
- **No leading H1 repeating the view name** (the app shows the name; M8 adds renderer suppression).
- **A published checkbox is a contract** (M7) — the agent only publishes `- [ ]` items it will act on
  when ticked, including the *approval pattern* ("- [ ] Archive these 12 stale notes?" → tick = yes).
- **Fence widgets** — agents may label fenced blocks with the reserved names (`metric`, `chart`,
  `timeline`, `table`) and fill them with simple line-oriented text (`Label: value` rows, bars,
  sparklines). Today these render as monospaced panels (the §6 pass-through); M9
  (`AGENT_LAYER_PLAN.md` §M9) upgrades them to real widgets **in place** — same stored bytes.
  Content must stay legible as plain text, because the panel *is* the permanent fallback rendering
  (older builds, malformed content).

---

## 7. Reserved for later (do not build; do not break)

Named now so schemas leave room and renderers pass them through — but **out of scope** for this plan.
Building any of these is scope creep; breaking the reservation (stripping an unknown fence, erroring
on `media`, colliding a reserved id) is a regression.

- **Interaction state** — ✅ **SHIPPED in M7** (Jul 2026), no longer reserved. A synced
  `InteractionStateEntity` (user toggles a view checkbox → debounced upserted per-block state →
  `interactions.jsonl` + `get_view.interactions` → agent acts next run and republishes). Full spec:
  [`views-v2-interaction-spec.md`](views-v2-interaction-spec.md) (superseded the earlier
  `InteractionEventEntity` name; rationale in
  [`views-v2-interaction-design.md`](views-v2-interaction-design.md)). **Load-bearing invariants that
  must not regress:** (a) user interaction never mutates a `ViewRevisionEntity`; interaction state is
  a separate, user-authored, app-written, debounced end-state per-block layer — at most one durable
  write per settle; (b) a newer revision supersedes older interaction state — **publishing is the
  acknowledgment**; (c) `ViewInteractionModel.resolved()` runs during SwiftUI render, so it must
  mutate **no** observed state (`@ObservationIgnored`) or it infinite-loops the render (0x8BADF00D) —
  see [`ollie-swiftui-render-loop`]. Still reserved on top of this: explicit-id checklist items inside
  fenced blocks (`cl2:` prefix) and the interactive fence names below.
- **`media: [String]?`** on `ExportRecord` — reserved for per-note photo/audio attachments; always
  `nil` today.
- **Request-lifecycle tag convention** — `request:open` / `request:done` tags mark a note the agent
  is working through (addressed to Ollie, or a clear task). A convention agents follow via the
  runbook, **not** an app feature; nothing in the app special-cases these tag strings.
- **Reserved fence names** — `checklist`, `metric`, `chart`, `timeline`, `table` (`table` added
  Jul 2026). Today they render as monospaced panels like any unknown fence (§6). `metric` / `chart`
  / `timeline` / `table` are **scheduled**: real widget renderers, renderer-only (no schema change),
  planned as `AGENT_LAYER_PLAN.md` §M9 with the fence content grammar defined there. `checklist` (and
  `cl2:` explicit-id items inside fences) stays reserved beyond M9.
- **Wishlist convention** — the standing view named **"Ollie wishlist"** plus `wish:`-prefixed
  memory entries: agents log view-dialect capabilities they lacked (one checklist line per wish);
  the user *ticks* a wish to request it, and the agent moves it under `## Requested` on the next
  republish. This is the demand signal for which reserved capability to build next. A runbook
  convention like the request-lifecycle tags — nothing in the app special-cases these strings.
- **Reserved `agentId`s** — `ondevice-fm` (on-device FoundationModels agent), `siri`.
- **Reserved `via` doors** — `app-intent`, `in-process` (§1).

---

## 8. Deferred surfaces (context — where this is headed)

For the full deferred list see [`AGENT_LAYER_PLAN.md`](../AGENT_LAYER_PLAN.md) §6. In brief:

- **Views v2 fence widgets** — real renderers for `metric` / `chart` / `timeline` / `table`,
  planned as `AGENT_LAYER_PLAN.md` §M9 (renderer-only; the checkbox interaction layer already
  shipped in M7). The renderer already passes unknown fences through untouched, so bodies written
  today upgrade in place.
- **Watch views** — the pinned view's latest revision on the wrist (one more
  `updateApplicationContext` payload).
- **Photo notes** — `CaptureKind.photo`, per-note media, OCR/caption at capture, the reserved `media`
  export field, content-addressed view assets.
- **On-device agent** — a FoundationModels tool-calling loop inside the apps: a **privileged tier**
  that *can* see restricted notes, applying the same `AgentOp` structs in-process (`via: "in-process"`).
- **System MCP / App Intents bridge** — expose the contract's reads/writes as intents 1:1 when
  Apple's App Intents ↔ MCP bridge matures (`via: "app-intent"`). Capture/search intents already ship
  (`SaveNoteIntent`, `FindNotesIntent`, `StartRecordingIntent`).

---

## 9. Running the agent loop (operational)

The **agent runner** is a launchd-scheduled headless Claude session on the Mac that periodically tags
new notes, fulfills request-notes, and refreshes standing views. It is the fourth door in §1 wearing
the `claude-runner` `agentId` and going through the `inbox` `via` like any other external agent — it
writes nothing the MCP write tools couldn't; it just runs unattended on a timer. Three scripts under
`Scripts/`:

| Script | Role |
|---|---|
| `ollie-agent-run.sh` | One pass of the loop. Guards, then invokes headless Claude with the runbook. |
| `ollie-runbook.md` | The prompt — the 6-step directive the run follows. |
| `install-agent-runner.sh` | Writes + loads the launchd job that calls the runner on a schedule. |

### Run it once, by hand

```bash
./Scripts/ollie-agent-run.sh
```

The **Ollie Mac app must be open** — it is the only store writer, so it is what applies the ops the
run queues and what keeps the corpus fresh. The runner checks three guards before doing anything:

1. **No run already alive** — a pidfile (`~/Ollie/.agent-run.pid`) whose PID is still running means a
   prior pass is in flight; the run **skips** (exit 0) so passes never overlap.
2. **Mac app running** — detected by bundle id `com.mohammadshobaki.handheldnotes`. If it's closed the
   run **exits quietly** (exit 0) — the normal "not now" case; nothing to work on or apply against.
3. **Corpus fresh** — `~/Ollie/.ollie.meta.json`'s `exportedAt` must be < 24 h old. A stale corpus
   means the app hasn't re-exported recently; the run **stops** (exit 1) rather than tag stale data.

**Exit codes:** `0` = ran, or a guard said "not now" (app closed / another run alive); `1` = a hard
stop (stale corpus, missing runbook, or the Claude invocation failed).

**Logs** land in `~/Ollie/agent-runs/<timestamp>.log` (one per invoking run; the header records the
model, `agentId`, `since`, and corpus age). Logs older than **30 days** are pruned on each run;
`launchd.log` is never pruned.

**State:** `~/Ollie/.agent-state.json` holds `{"lastRunAt":"<ISO8601 UTC>"}`, written only on a
successful run and fed into the prompt so step 3 works `list_notes(since=lastRunAt)` — the run only
looks at notes since it last succeeded. A failed run does **not** advance it, so the next run re-covers
the same window.

### The prompt

`Scripts/ollie-runbook.md` is short and directive — honor `get_instructions()`; verify the corpus is
fresh; tag new notes (reuse the vocabulary before inventing); handle request-notes (`request:open` →
read-only work → `publish_view` an answer citing the notes → `request:done`); refresh the standing
views **"Open loops"** and **"This week"**; append durable memory sparingly. It **never edits notes**
(it can't) and **never asks questions** (no one is watching). The runner substitutes the literal token
`{{LAST_RUN_AT}}` in it with the state value (or `never` on a first run).

### Cadence + model knobs

- **Cadence** is the launchd `StartInterval` — **14400 s (4 h)** by default. Change it by editing
  `StartInterval` in the installed plist (or re-running the installer with `START_INTERVAL=<seconds>`),
  then reload: `launchctl bootout gui/$(id -u)/com.mohammadshobaki.ollie.agent-runner ;
  launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.mohammadshobaki.ollie.agent-runner.plist`.
- **Model** defaults to `opus`; override per-run with `CLAUDE_MODEL=<model> ./Scripts/ollie-agent-run.sh`,
  or persist it for the scheduled job by adding it to the plist's `EnvironmentVariables`.
- Other env knobs the runner honors: `CLAUDE_BIN` (the Claude binary, default `claude` — the tests
  point it at a stub), `OLLIE_DIR`, `RUNBOOK`, `MAX_CORPUS_AGE_HOURS` (default 24),
  `LOG_RETENTION_DAYS` (default 30). The op writer's `agentId` is forced to `claude-runner`.

### Install the schedule

```bash
./Scripts/install-agent-runner.sh          # writes the plist + bootstraps the job
PRINT_ONLY=1 ./Scripts/install-agent-runner.sh   # dry run: print the plist + commands, install nothing
```

It writes `~/Library/LaunchAgents/com.mohammadshobaki.ollie.agent-runner.plist` (`StartInterval` 14400,
`RunAtLoad` false so nothing fires at login, stdout/err → `~/Ollie/agent-runs/launchd.log`) and
bootstraps it into your GUI launchd domain. Run once immediately to test:
`launchctl kickstart -k gui/$(id -u)/com.mohammadshobaki.ollie.agent-runner`. Uninstall:
`launchctl bootout gui/$(id -u)/com.mohammadshobaki.ollie.agent-runner ; rm ~/Library/LaunchAgents/com.mohammadshobaki.ollie.agent-runner.plist`.

### Allowlist the write tools (required for headless)

The `ollie` MCP server + its tool allowlist live in `~/.claude/settings.local.json`. An interactive
Claude session prompts before each write tool; a **headless run has no one to answer the prompt and
would stall**, so the write tools must be allowlisted there before the runner (or the launchd job) can
work. Add them to `permissions.allow`:

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

(Or allow the whole server with `"mcp__ollie__*"`, which also covers the read tools the runbook uses.)
These are *your* notes on *your* machine and every op is attributed and reversible (untag, retire, or
delete in the app), so broad approval is reasonable — but it's opt-in by design. The scripts do **not**
edit `~/.claude/` for you; do this once by hand.
