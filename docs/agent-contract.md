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

> **Every entity change in this plan lands in one batch (Milestone 1).** Do not add entities
> piecemeal in later milestones — the schema golden gate
> (`Tests/HandheldNotesCoreTests/SchemaGoldenTests.swift`) fails by design on any `@Model` change,
> and CloudKit **Production** must be deployed once for the whole set. See
> [`RELEASE.md`](../RELEASE.md) and [`docs/cloudkit-sync-troubleshooting.md`](cloudkit-sync-troubleshooting.md).

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

---

## 7. Reserved for later (do not build; do not break)

Named now so schemas leave room and renderers pass them through — but **out of scope** for this plan.
Building any of these is scope creep; breaking the reservation (stripping an unknown fence, erroring
on `media`, colliding a reserved id) is a regression.

- **Interaction events** — an `InteractionEventEntity` (tap → event record → export → next run) for
  interactive view blocks. Not modeled yet.
- **`media: [String]?`** on `ExportRecord` — reserved for per-note photo/audio attachments; always
  `nil` today.
- **Request-lifecycle tag convention** — `request:open` / `request:done` tags mark a note the agent
  is working through (addressed to Ollie, or a clear task). A convention agents follow via the
  runbook, **not** an app feature; nothing in the app special-cases these tag strings.
- **Reserved fence names** — `checklist`, `metric`, `chart`, `timeline`. Reserved for Views v2
  interactive blocks; today they render as monospaced panels like any unknown fence (§6).
- **Reserved `agentId`s** — `ondevice-fm` (on-device FoundationModels agent), `siri`.
- **Reserved `via` doors** — `app-intent`, `in-process` (§1).

---

## 8. Deferred surfaces (context — where this is headed)

For the full deferred list see [`AGENT_LAYER_PLAN.md`](../AGENT_LAYER_PLAN.md) §6. In brief:

- **Views v2** — interactive fenced blocks (`checklist` / `metric` / `chart` / `timeline`) +
  `InteractionEventEntity`. The renderer already passes unknown fences through untouched.
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

*Filled in by Milestone 6; summarized here so the contract stays the one place to look.*

The **agent runner** is a launchd-scheduled headless Claude session on the Mac that periodically tags
new notes, fulfills request-notes, and refreshes standing views. Reserved details:

- **Run once manually:** `./Scripts/ollie-agent-run.sh` (guards: Mac app running, corpus fresh,
  no run already alive). Logs land in `~/Ollie/agent-runs/<timestamp>.log`.
- **The prompt** is `Scripts/ollie-runbook.md` — short and directive: honor `get_instructions()`,
  tag new notes (reuse the vocabulary before inventing), handle request-notes, refresh "Open loops"
  and "This week", append durable memory sparingly. **Never edits notes** (it can't); never asks
  questions.
- **Schedule / cadence:** `Scripts/install-agent-runner.sh` writes + loads
  `~/Library/LaunchAgents/com.mohammadshobaki.ollie.agent-runner.plist` (`StartInterval` 14400 = 4 h).
  The `ollie` MCP server + its tool allowlist live in `~/.claude/settings.local.json`; the new write
  tools (`mcp__ollie__tag_note`, etc.) must be allowlisted there so the headless run never prompts.
