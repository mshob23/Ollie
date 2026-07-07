# Ollie Agent Layer — Implementation Plan

*Approved scope, July 2026. Companion to [ECOSYSTEM.md](ECOSYSTEM.md), [BACKLOG.md](BACKLOG.md), [RELEASE.md](RELEASE.md).*

**Scope decisions (made by Mohammad, 2026-07-05):** build through **Views v1** (instructions →
write door → gate → views); **defer** the Apple Watch view surface, Views v2 interactive blocks,
photo notes, and the on-device FoundationModels agent (schemas reserve room for all four);
**include** the scheduled Mac agent runner. Capture/search App Intents already shipped (Rung 2) —
no new intent work in this plan.

**Scope extension (2026-07-06):** M0–M6 shipped; **M7** added — the Views v2 **checkbox
interaction layer**, designed in [`docs/views-v2-interaction-spec.md`](docs/views-v2-interaction-spec.md)
(the design contract for M7; on conflict with this plan's task list, the spec wins on design, the
plan on process). Fenced interactive blocks (`checklist`/`metric`/`chart`/`timeline`) stay deferred.

---

## 0. Context — what this adds and why

Ollie's thesis: **capture is dumb, intelligence is rented, the data is owned.** Today the system
captures morsels (Mac F16 / iPhone / Watch → one CloudKit library) and exposes them read-only to
agents via a Mac-side MCP server over an exported JSONL corpus. This plan adds the **agent layer**:

1. **Understanding** — agents write *tags* (cached judgment) and *memory* (a codebook: shorthand
   decodings, preferences, dead ends) back into the store.
2. **Views** — agents publish named living documents ("Open loops", "This week") as immutable
   revisions; the apps render a Views feed with history.
3. **The gate** — notes can be marked *restricted*; they and everything derived from them never
   leave the device boundary.
4. **The loop** — a launchd-scheduled headless Claude session periodically tags new notes,
   fulfills request-notes ("Ollie, look into…"), and refreshes views. Speak into the watch on the
   sidewalk; an answer is in the Views tab by the time you're home.

Core invariants (violating any of these is a design regression, not a style choice):

- **Notes are immutable ground truth.** No operation may edit `Note.transcript` on an agent's
  behalf. The agent layer is derived, attributed, regenerable, and disposable.
- **Append-only, attributed records.** Every agent contribution carries `agentId` + timestamp.
  Updates are new records (view revisions, memory corrections), never in-place edits. Agents may
  delete only *derived* records they conceptually own (untag); **users** may delete anything.
- **Validate mechanics, never meaning.** The app checks ids, sizes, schema — never whether a tag
  is sensible or a memory is true.
- **Restriction is contagious.** A derived record inherits the restriction of the note(s) it
  derives from; the export gate drops them together.
- **Capture is immediate; intelligence is eventually-consistent.** Nothing in the capture path
  may ever wait on the agent layer.
- **The app is the only store writer.** External agents write through the inbox; the Mac app
  validates and applies.

---

## 1. Read this first (implementing agent orientation)

**Repos** (both in `/Users/mohammadshobaki/Desktop/Projects/Agents/`):

| Repo | What | Build & test |
|---|---|---|
| `HandheldNotes` | SwiftPM: `HandheldNotesCore` (shared lib, macOS 14+/iOS 17+) + Mac app + Python MCP server (`mcp-server/`) | `swift test` · run app: `./Scripts/build_app.sh && open .build/debug/Ollie.app` (or `swift run HandheldNotes`) |
| `HandheldNotesiOS` | XcodeGen iPhone app (iOS 26) + embedded watch app | `xcodegen generate` then `xcodebuild -project HandheldNotesiOS.xcodeproj -scheme HandheldNotesiOS -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /tmp/hn_ios_dd build` — **never pass `-sdk iphonesimulator`** (it forces the embedded watchOS target onto the iOS SDK, breaking `WatchKit` and its asset catalog; `-destination` alone assigns each target its own SDK; the README's `-sdk` variant is wrong for CLI builds) |

**Hard rules — read before writing any code:**

1. **Schema golden gate.** Any change to the SwiftData schema (new `@Model`, new field) fails
   `Tests/HandheldNotesCoreTests/SchemaGoldenTests.swift` by design. Regenerate the golden
   (instructions in the test + `RELEASE.md`), update `Scripts/expected-ck-fields.txt` and the CK
   coverage tests. **All schema changes in this plan land in Milestone 1 — do not add entities
   piecemeal in later milestones.** CloudKit *Development* auto-creates record types; *Production*
   never does — before any release build, the schema must be deployed via CloudKit Dashboard
   (container `iCloud.com.mohammadshobaki.handheldnotes`) and release scripts require
   `SCHEMA_DEPLOYED=1`. See RELEASE.md; this exact miss caused the June 2026 outage.
2. **CloudKit-compatible models.** Every `@Model` property needs a default or optional (CloudKit
   forbids unique constraints and required-without-default). Follow `NoteEntity`'s pattern
   (`Sources/HandheldNotesCore/Store/NoteEntity.swift`): raw-string enums, flat fields, computed
   typed accessors, upsert-by-id in code.
3. **Watch target stays lean.** `HandheldNotesWatch` deliberately does NOT depend on
   `HandheldNotesCore` (no Speech on watchOS). Nothing in this plan touches `Watch/Sources/` —
   don't leak new code into it. New Core code must compile for macOS 14 / iOS 17 (Core's floor),
   even though the iOS app targets iOS 26.
4. **Follow existing patterns, not new ones.** Entity↔value projection like `NoteEntity`↔`Note`;
   settings via tolerant-decode `NotesSettings`; export via `CorpusExporter` (already dedupes,
   guards empty overwrites, prunes orphans, supports `exportDirectoryOverride` for tests);
   MainActor `AppModel` as the single source of truth; theme via `Theme.swift` (`hcAccent`,
   `.hcPanel()`, `WarmBackground()`); Python: pure logic in a corpus module, thin FastMCP wrapper.
5. **No new third-party dependencies** in either repo (Swift or Python) — everything below is
   achievable with platform APIs + `mcp>=1.2` (+ `pytest` as a dev dependency).
6. Each milestone ends **green**: `swift test` passes, Mac app launches, iOS app builds for the
   simulator, and the milestone's verification steps pass. Commit per milestone.

**Key existing files you will touch most:**

- `Sources/HandheldNotesCore/Store/NoteEntity.swift`, `Store/NotesDataStore.swift`
- `Sources/HandheldNotesCore/App/AppModel.swift` (notes projection, `reloadNotes()`,
  `observeRemoteChanges()`, `NotesSettings`)
- `Sources/HandheldNotesCore/Export/CorpusExporter.swift` (JSONL/Markdown/meta export; `ExportRecord`)
- `mcp-server/ollie_corpus.py`, `mcp-server/ollie_mcp.py`
- iOS: `Sources/RootTabView.swift`, `Sources/NotesListView.swift`, `Sources/NoteDetailView.swift`,
  `Sources/SettingsView.swift`
- Mac: `Sources/HandheldNotes/UI/RootView.swift`, `UI/NoteDetailView.swift`, `UI/SettingsView.swift`

---

## 2. Architecture at a glance

```
capture (watch/phone/Mac)                    [unchanged]
        ↓
┌─ CloudKit store (SwiftData) ────────────────────────────────┐
│ NoteEntity (ground truth, + isRestricted)                    │
│ TagEntity · MemoryEntity · ViewRevisionEntity ·              │
│ InstructionsEntity                    ← the agent layer      │
└──────────────────────────────────────────────────────────────┘
   ↓ export (gated)                      ↑ apply (validated)
~/Ollie/ollie.jsonl, tags.jsonl,      ~/Ollie/inbox/*.json
memory.jsonl, views.jsonl,            (op files, temp+rename)
instructions.md, notes/*.md              ↑
   ↓                                     │
Python MCP server (reads + write tools; read-your-writes overlay)
   ↕
any agent (Claude session / launchd runner)
```

Trust boundary = the device. The export gate filters restricted content out of everything under
`~/Ollie/`; the inbox is the only external write path; the Mac app is the only store writer.

---

## 3. Data contracts (canonical — all milestones conform to this section)

### 3.1 Agent identity

`agentId`: short string `provider-surface`, e.g. `claude-mac`, `claude-runner`. Future reserved:
`ondevice-fm`, `siri`. Every derived record and op carries one. Op envelopes also carry `via`
(door): `"inbox"` today; reserved: `"app-intent"`, `"in-process"`.

### 3.2 New SwiftData entities (all added in Milestone 1, all CloudKit-synced)

Follow `NoteEntity` conventions exactly (defaults on every field, `Entity` suffix, public value
struct projection). New file per entity under `Sources/HandheldNotesCore/Store/`.

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
    public var body: String = ""               // markdown (see 3.5)
    public var agentId: String = ""
    public var createdAt: Date = Date.distantPast
}

@Model public final class InstructionsEntity { // single record, fixed well-known UUID, upsert
    public var id: UUID = UUID()
    public var text: String = ""               // the user's standing instructions to agents
    public var updatedAt: Date = Date.distantPast
}
```

`NoteEntity` gains one field: `public var isRestricted: Bool = false` (+ mirror on `Note`,
default false; bump `Note.currentSchemaVersion` 2 → 3).

Semantics:
- **Tags** are a set per note: applying an existing `(noteId, tag)` pair is a no-op (idempotent);
  `untag` deletes the matching record(s). Dedup case-insensitively on apply.
- **Memory** is append-only; `retire` flips the tombstone. Users can hard-delete from the UI.
- **Views**: a "view" is the set of revisions sharing `viewName`; latest `createdAt` wins display.
  Publishing to an existing name appends. Users can delete a whole view (deletes its revisions).
- **Instructions**: single user-authored record, edited in-app, synced like everything else.

### 3.3 Export layout (`~/Ollie/`, written by `CorpusExporter`)

Existing: `ollie.jsonl`, `notes/<id>.md`, `.ollie.meta.json`, `backups/`. New:

| File | Shape (one JSON per line unless noted) |
|---|---|
| `tags.jsonl` | `{"noteId","tag","agentId","createdAt"}` |
| `memory.jsonl` | `{"id","text","agentId","createdAt","retired","retiredAt"?}` (retired entries included, flagged) |
| `views.jsonl` | `{"id","viewName","body","agentId","createdAt"}` — every revision, full body (snapshots, not diffs) |
| `instructions.md` | plain markdown, the instructions text |

**Gate rules (apply to every exported artifact):** notes with `isRestricted` are omitted from
`ollie.jsonl` and `notes/` (prune previously-exported `.md` when a note becomes restricted — the
orphan-pruning pass already exists; extend it). Tags whose `noteId` is restricted are omitted from
`tags.jsonl`. Views and memory export in full (they're agent-authored from already-filtered
corpus; the on-device privileged tier that could see restricted notes is out of scope). Encode the
contagion rule in one Core function so future doors reuse it:
`CorpusGate.exportableNotes(_:)` / `exportableTags(_:notes:)` in a new
`Sources/HandheldNotesCore/Export/CorpusGate.swift`.

`ExportRecord` (in CorpusExporter) additionally gains a reserved optional `media: [String]?`
field — always `nil`/omitted today; documented for photo notes later. `.ollie.meta.json` keeps its
shape; `schemaVersion` becomes 3 and gains `"layerCounts": {"tags":N,"memory":N,"viewRevisions":N}`.

### 3.4 Inbox op protocol (`~/Ollie/inbox/`)

One file per op, name `<agentId>-<requestId>.json`, written to a temp name then **renamed** into
place (atomic on APFS; no locks). `requestId` = UUID minted by the writer. Envelope:

```json
{"op":"tag","agent":"claude-mac","via":"inbox","ts":"2026-07-05T12:00:00Z",
 "requestId":"…uuid…","payload":{…}}
```

| op | payload | validation (mechanics only) |
|---|---|---|
| `tag` | `{"noteId","tag"}` | note exists; tag 1–64 printable chars |
| `untag` | `{"noteId","tag"}` | note exists |
| `memory.append` | `{"text"}` | 1–2000 chars |
| `memory.retire` | `{"id"}` | entry exists |
| `view.publish` | `{"viewName","body"}` | name 1–80 chars; body 1–131072 chars |

Envelope-level validation: known `op`, well-formed JSON, file ≤ 256 KB, `requestId` not in the
recent-ledger. Results are echoed (JSONL append) to `~/Ollie/applied.jsonl` /
`~/Ollie/rejected.jsonl` as `{"requestId","op","agent","ts","result":"applied"|"rejected","reason"?}`.
Idempotency ledger: `~/Ollie/.applied-requests.json` (ring buffer of last 1000 requestIds,
maintained by the ingestor). Op files are deleted after echo; malformed files move to
`~/Ollie/inbox/rejected/` for postmortem rather than deletion.

### 3.5 View body format

Markdown, rendered with a shared lightweight renderer (see M5). Two conventions agents rely on:
- **Note citations**: `ollie://note/<uuid>` links; renderer makes them tappable → opens the note.
- **Forward-compat fences**: unknown fenced code blocks (```checklist … ```) render as plain
  monospaced blocks today — never stripped, never errored. This is the reserved growth path for
  Views v2 interactive blocks.

---

## 4. Milestones

Execute in order; each is independently shippable and ends green. Estimated relative sizes: M1 ●●,
M2 ●●, M3 ●●, M4 ●●, M5 ●●●●, M6 ●●, M7 ●●●, M8 ●●.

### M0 — Contract doc + backlog alignment (docs only)

**Goal:** the contract in §3 becomes a repo-canonical doc agents and future doors cite.

- Create `docs/agent-contract.md` in HandheldNotes: copy §3 (identity, entities, export layout,
  op protocol, caps, gate rules, view-body conventions), plus the invariants from §0, plus a
  "reserved for later" list (interaction events, `media`, `request:open`/`request:done` tag
  convention, block fence names `checklist`/`metric`/`chart`/`timeline`).
- Update `BACKLOG.md`: mark this work as **Rung 5 (agent write-back)**, **Rung 6 (gate)**,
  **Rung 7 (views v1)**, **Rung 8 (agent runner)**, statuses "planned → in progress" as executed.
  Update `ECOSYSTEM.md` with the three-layer picture (one short section, link to the contract).

**Done when:** docs exist; no code changed.

### M1 — Schema: all entities + `isRestricted` (one-shot CloudKit change)

**Goal:** every schema change this plan needs, in one batch.

Files:
- New: `Store/TagEntity.swift`, `Store/MemoryEntity.swift`, `Store/ViewRevisionEntity.swift`,
  `Store/InstructionsEntity.swift` (each: `@Model` + public value struct + projection, per §3.2).
- Edit `Store/NoteEntity.swift`: add `isRestricted: Bool = false`; mirror on `Note` (Codable —
  keep tolerant decoding: `decodeIfPresent … ?? false`); bump `Note.currentSchemaVersion` to 3.
- Edit `Store/NotesDataStore.swift`: `Schema([NoteEntity.self, TagEntity.self, MemoryEntity.self,
  ViewRevisionEntity.self, InstructionsEntity.self])`.
- New: `Sources/HandheldNotesCore/Agent/AgentLayerStore.swift` — MainActor API over the container,
  the single choke point every door uses:
  ```swift
  @MainActor public struct AgentLayerStore {
      public init(context: ModelContext)
      // queries
      public func tags(forNote: UUID) -> [AgentTag]
      public func allTags() -> [AgentTag]                       // for vocabulary + export
      public func memory(includeRetired: Bool) -> [AgentMemory]
      public func viewNames() -> [String]
      public func revisions(viewName: String) -> [AgentViewRevision]  // newest first
      public func latestRevisions() -> [AgentViewRevision]      // one per view, newest first
      public func instructions() -> String
      // mutations (mechanical validation lives HERE; throws AgentLayerError)
      public func apply(_ op: AgentOp) throws                   // op enum mirrors §3.4
      public func setInstructions(_ text: String)               // user path (Settings UI)
      public func userDelete(tag: AgentTag) / (memory: AgentMemory) / (view name: String)
  }
  ```
  `AgentOp` is `Codable` (the same struct the inbox decodes and, later, App Intents construct).
- Tests (`Tests/HandheldNotesCoreTests/AgentLayerStoreTests.swift`, in-memory container):
  tag idempotency + untag; memory append/retire; publish + latest-wins ordering + multi-agent
  interleave on one viewName; caps rejected with the right `AgentLayerError`; instructions upsert
  keeps a single record; `Note` decodes legacy JSON without `isRestricted`.
- Regenerate schema golden (`SchemaGoldenTests.goldenHash` + `Resources/schema.golden`); update
  `Scripts/expected-ck-fields.txt` + CK coverage/rejection tests for the new record types.

**Verify:** `swift test` green; Mac app launches and syncs (Development CloudKit auto-creates the
new record types — check Dashboard shows them).
**Release note (not a step now):** before the next TestFlight/DMG release, deploy schema to
Production per RELEASE.md.

### M2 — Export v3: gate + layer files + instructions

**Goal:** `~/Ollie/` reflects the full agent layer, restriction-filtered.

- New: `Export/CorpusGate.swift` (§3.3 rules; pure functions, unit-testable).
- Edit `Export/CorpusExporter.swift`: accept the layer data
  (`export(notes:tags:memory:viewRevisions:instructions:allowEmpty:)`), write the four new files
  (same atomic write-temp-rename style as ollie.jsonl), route notes/tags through `CorpusGate`,
  extend orphan-pruning to remove `.md` of newly-restricted notes, `media` reserved field, meta v3
  with `layerCounts`.
- Edit `App/AppModel.swift`: `reloadNotes()` gathers layer snapshots via `AgentLayerStore` and
  passes them to `exportInBackground`. Also observe remote changes to the new entity types (the
  existing `.NSPersistentStoreRemoteChange` observer already fires for the whole store — confirm
  the reload path re-exports when only layer records changed).
- Tests: extend `CorpusExporterGuardTests` — restricted note absent from jsonl + md pruned;
  restricted note's tags absent; layer files round-trip; empty-corpus guard still holds.

**Verify:** run Mac app, mark a note restricted via a temporary debug action if M5 UI isn't there
yet (or set in tests only) — simplest: `swift test` covers the gate; manually confirm
`~/Ollie/tags.jsonl` etc. appear (empty) after launching the app.

### M3 — Inbox ingestion (Mac app)

**Goal:** external agents can write; the app validates, applies, echoes, dedupes.

- New: `Sources/HandheldNotesCore/Agent/InboxIngestor.swift` (MainActor class):
  - Watches `~/Ollie/inbox/` via `DispatchSourceFileSystemObject` + a 30 s fallback timer +
    a full scan on startup. (Use `CorpusExporter.exportDirectory` to derive the path so the
    test override redirects everything together.)
  - Per file: size check → decode envelope → ledger check → `AgentLayerStore.apply(op)` →
    echo to `applied.jsonl`/`rejected.jsonl` → update `.applied-requests.json` → delete file
    (malformed → move to `inbox/rejected/`).
  - After a batch applies: trigger `reloadNotes()`-equivalent so the export refreshes promptly
    (post a notification the AppModel observes, mirroring how remote changes flow).
- Wire up in Mac app only: instantiate in `AppDelegate.applicationDidFinishLaunching`
  (`Sources/HandheldNotes/App/AppDelegate.swift`), holding a reference alongside the model.
  (iOS does not ingest an inbox in this plan.)
- Tests (`InboxIngestorTests.swift`, in-memory store + temp export dir): valid op of each type
  applies + echoes + deletes; duplicate requestId rejected via ledger; oversized/malformed →
  `rejected.jsonl` + moved file; crash-recovery semantics (re-scan applies leftover files;
  re-applied `tag` is a no-op).

**Verify:** launch Mac app; hand-craft an op file (`echo '{"op":"tag",…}' > /tmp/x && mv /tmp/x
~/Ollie/inbox/claude-mac-$(uuidgen).json`); watch `applied.jsonl` gain a line, the note's tag
land in the store, and `tags.jsonl` refresh.

### M4 — MCP server v2 (write tools + layer reads + read-your-writes)

**Goal:** the Python server exposes the full contract.

- New `mcp-server/ollie_layers.py` (pure logic, mirrors `ollie_corpus.py` style):
  readers for `tags.jsonl` / `memory.jsonl` / `views.jsonl` / `instructions.md`;
  `pending_ops(inbox_dir)` reader; overlay functions that merge pending ops onto reads
  (read-your-writes: a just-written tag appears in `tag_vocabulary` etc. before the Mac app
  ingests); op-file writer (`write_op(op, payload, agent) -> requestId`, temp+rename, mints
  requestId, stamps `agent` from env `OLLIE_AGENT_ID` default `claude-mac`).
- Edit `mcp-server/ollie_mcp.py` — add tools (docstrings matter; they're the agent's manual):
  - Reads: `get_instructions()`, `tag_vocabulary()` (tag → count + lastUsed),
    `notes_by_tag(tag, limit=50)` (slim notes, newest first), `read_memory(include_retired=False)`,
    `list_views()` (name, revisionCount, latestAt, latestAgent), `get_view(name, revision_limit=5)`
    (latest body + prior revision metadata).
  - Writes (each returns `{"requestId", "status": "queued"}` and notes the async apply):
    `tag_note(id, tag)`, `untag_note(id, tag)`, `append_memory(text)`, `retire_memory(id)`,
    `publish_view(name, body)`.
  - `corpus_stats()` gains `layerCounts` + pending-inbox count.
- Tests: `mcp-server/tests/test_layers.py` (pytest; add `pytest` to a `requirements-dev.txt`):
  overlay correctness, op file shape, caps enforced client-side too (reject before writing),
  vocabulary counting.
- Update `mcp-server/README.md` tool table; note the new write tools need allowlisting
  (`mcp__ollie__tag_note` etc.) in `~/.claude/settings.local.json`.

**Verify:** `pytest mcp-server/tests`; then end-to-end with the Mac app running: from a Claude
session call `tag_note` → `applied.jsonl` line appears → `tag_vocabulary` shows it (overlay makes
it visible even before apply).

### M5 — UI: restriction, instructions, memory, tags, Views tab (iOS + Mac)

**Goal:** the human surfaces. Largest milestone; sub-checklists below are independently commitable.

**5a. Shared renderer (Core).** New `Sources/HandheldNotesCore/AgentViews/MarkdownLite.swift`:
SwiftUI view rendering the §3.5 dialect — line-based: `#`/`##`/`###` headers, `-` bullets,
`- [ ]`/`- [x]` checklist glyphs (display-only in v1), blank-line paragraphs, fenced blocks as
monospaced panels, everything else through `AttributedString(markdown:)` for inline styling.
Custom link handling: intercept `ollie://note/<uuid>` and call an injected
`onOpenNote: (UUID) -> Void`. Style with existing `Theme.swift` tokens. Unit-test the line
classifier (not the SwiftUI rendering).

**5b. Restriction toggle.** `Note.isRestricted` editable: add `setRestricted(_:for:)` on
`AppModel` (mirrors `toggleFavorite`). iOS `NoteDetailView`: toolbar lock toggle + a small
"restricted — never exported" banner; `NotesListView` row lock glyph. Mac `NoteDetailView` same.
Flipping it must trigger re-export (existing save → reload → export path covers this; confirm).

**5c. Instructions editor.** iOS + Mac `SettingsView`: new "AI instructions" section, multi-line
`TextEditor` bound through `AppModel` to `AgentLayerStore.setInstructions` (load on appear, save
on done). Footer copy: "Agents read this before working with your notes."

**5d. Memory + tag visibility (trust surfaces).** iOS + Mac Settings: "AI memory" screen listing
`AgentMemory` entries (text, agent, date; retired dimmed) with swipe/context delete
(`userDelete`). Note detail (both platforms): tag chips under the metadata row (reuse `FlowChips`
on iOS), each chip deletable via context menu.

**5e. Views surface — iOS.** `RootTabView` gains a third tab **Views** (list icon):
- `ViewsFeedView`: latest revision per view (via `AgentLayerStore.latestRevisions()`), newest
  first; pinned view (if any) at top with pin badge. Row: view name, 2-line body preview,
  "agentId · relative time" footer (reuse `HCFormat.relative`). Empty state: "No views yet —
  agents publish summaries here."
- `ViewDetailView`: MarkdownLite body of latest revision, provenance header, "Earlier revisions"
  section (dated rows → tap to read that revision), pin/unpin toolbar button, delete-view (user)
  in a menu. `onOpenNote` navigates to the existing `NoteDetailView`.
- Pinning: `pinnedViewName: String?` in `NotesSettings` (per-device, tolerant decode).
- Deep link: register `ollie` URL scheme in `Resources/Info.plist`; `onOpenURL` in
  `HandheldNotesiOSApp`/RootTabView routes `ollie://note/<uuid>` to the note.
- Reload: views/tags/memory arrive via CloudKit; the existing remote-change observation already
  refreshes AppModel — extend its projection to also refresh a published
  `viewRevisions`/`tagsByNote`/`memory` snapshot (single `AgentLayerSnapshot` published struct
  keeps AppModel tidy).

**5f. Views surface — Mac.** Keep minimal: toolbar segmented control in `RootView` toggling the
left pane between Notes list and Views feed (right pane shows `ViewDetailView` equivalent using
the same Core `MarkdownLite`). Reuse 5e's row/detail components where SwiftUI lets you; else thin
Mac twins.

**Verify:** `swift test`; Mac app manual pass (restrict → gone from `~/Ollie`; edit instructions →
`instructions.md` updates; publish a view via MCP → appears in Mac Views pane). iOS: build +
launch in simulator, `xcrun simctl openurl booted "ollie://note/<uuid>"` opens the note; publish a
view op on the Mac and confirm it syncs to the phone's Views tab (real devices; simulator iCloud
is unreliable — acceptable to verify sync on hardware and UI-with-local-data in simulator).

### M6 — Agent runner (the loop)

**Goal:** unattended periodic agent runs on the Mac.

- New `Scripts/ollie-agent-run.sh`:
  - Guards: Mac app running (else exit quietly — corpus/ingest need it), corpus fresh
    (`.ollie.meta.json` exportedAt < 24 h), previous run not still alive (pidfile).
  - Reads state `~/Ollie/.agent-state.json` (`lastRunAt`), interpolates it into the prompt.
  - Invokes headless Claude: `claude -p "$(cat "$RUNBOOK")" --model opus
    --allowedTools "mcp__ollie__*"` with output → `~/Ollie/agent-runs/<timestamp>.log`
    (create dir; prune logs > 30 days). Note: `ollie` MCP server + tool allowlist already live in
    `~/.claude/settings.local.json`; extend that allowlist with the new write tools so the
    headless run never prompts.
  - Writes back `lastRunAt` on success.
- New `Scripts/ollie-runbook.md` (the prompt; keep it short and directive):
  1. `get_instructions()` and honor it. 2. `corpus_stats()`; if stale, stop and say so.
  3. `list_notes(since=lastRunAt)` → for each new note: apply 1–3 useful tags (check
  `tag_vocabulary()` first; reuse before inventing). 4. Detect request-notes (addressed to Ollie
  or clearly tasks): tag `request:open`, do the (read-only) work, `publish_view` an answer named
  for the request citing the note, retag `request:done`. Anything requiring outside-world *action*
  is out of scope: note it in the view instead. 5. Refresh standing views "Open loops" and
  "This week" from the recent corpus (cite notes). 6. `append_memory` sparingly — only durable
  codebook facts. Never ask questions; never edit notes (you can't).
- New `Scripts/install-agent-runner.sh`: writes + loads
  `~/Library/LaunchAgents/com.mohammadshobaki.ollie.agent-runner.plist`
  (`StartInterval` 14400 = 4 h, `RunAtLoad` false, stdout/err → `~/Ollie/agent-runs/launchd.log`);
  `launchctl bootstrap gui/$(id -u)` / print uninstall instructions.
- Document in `docs/agent-contract.md` + README: how to run once manually
  (`./Scripts/ollie-agent-run.sh`), where logs live, how to change cadence/model.

**Verify:** run the script manually once with the Mac app open → log shows tool calls; new notes
gain tags; "This week" view appears on Mac and (hardware) iPhone. Then `launchctl kickstart` the
job and confirm one scheduled run completes.

### M7 — Views v2: checkbox interaction layer ✅ SHIPPED (Jul 2026)

**Status:** built and verified end-to-end on hardware — iOS TestFlight build **31**, Mac Developer-ID
build, CloudKit Production schema deployed (**31/31** fields), full round-trip confirmed (taps on
phone + Mac → synced `interactions.jsonl` → agent consumed checks and republished "Open loops", which
auto-superseded them). Two on-device-only bugs were found and fixed post-first-build (per-render
SwiftData fetch `f2d46c6`; `@Observable`-mutation-during-render loop `97ec866`) — see the spec's
§10 "Post-ship notes". The task list below is the as-executed record.

**Goal:** checklist items in views become tappable; the settled end-state syncs; the agent
consumes checks on its next run. **Design contract:** [`docs/views-v2-interaction-spec.md`](docs/views-v2-interaction-spec.md)
— read it in full first; every design decision below (precedence rule, `blockId` derivation,
debounce semantics) is normative *there*, and this milestone only lists the tasks. This milestone
contains the plan's **second and final** schema change — one entity, one batch, one Production
deploy (hard rule 1 applies in full).

**7a. Schema + store (Core).**
- New `Store/InteractionStateEntity.swift`: `@Model` + `ViewInteraction` value struct + projection,
  per spec §2 (9 fields incl. `kind`/`value` as strings; caps in `AgentLayerStore.Caps`:
  blockId ≤ 128, blockText ≤ 500 truncate-don't-reject, value ≤ 64, kind ≤ 32).
- Edit `Store/NotesDataStore.swift`: add to the schema.
- Edit `Agent/AgentLayerStore.swift`: `interactions(viewName:)` (collapsed: latest `updatedAt`
  wins per `(viewName, blockId)`), `setInteraction(_:)` (in-code upsert by key; the user path —
  **no new `AgentOp` case, no inbox op**: interaction state is user-authored, app-written only),
  cascade inside `userDelete(view:)`.
- Regenerate schema golden; update `Scripts/expected-ck-fields.txt` (**6** new names — the file
  is a union and `CD_id`/`CD_viewName`/`CD_updatedAt` already exist: `CD_blockId`, `CD_blockText`,
  `CD_kind`, `CD_value`, `CD_revisionId`, `CD_surface`; 25 → 31; no Data fields → no `_ckAsset`
  twins) + CK coverage/rejection tests for `CD_InteractionStateEntity`.
- Tests: upsert-by-key (second set rewrites, doesn't duplicate); duplicate-key collapse picks
  latest `updatedAt`; caps; view delete cascades.

**7b. blockId + renderer hook (Core).**
- Edit `AgentViews/MarkdownLite.swift`: block parser annotates checklist `ListItem`s with
  `blockId` = `cl1:<sha256-16hex-of-classifier-text>:<occ>` (spec §3; CryptoKit); new optional
  `ChecklistHook` init param (`resolved` + `onToggle`), default nil → **zero behavior change** at
  existing call sites (watch/feed previews untouched). Non-nil: glyph renders `resolved(...)`,
  glyph+label row gets the tap gesture, animated; haptic on iOS.
- Tests (pure, no SwiftUI): id derivation goldens; occurrence ordinals for duplicate text;
  reorder keeps ids; reword changes id; `cl2:`-style unknown prefixes stay non-interactive.

**7c. Interaction model (Core) + panes (Mac + iOS).**
- New `AgentViews/ViewInteractionModel.swift` (`@MainActor @Observable`, per spec §4): `pending`,
  `resolved(blockId:bodyChecked:)` (pending → overlay-iff-newer-than-revision → body), `toggle(...)`
  (600 ms cancel-and-restart settle timer), `commitNow()` (diff against committed, skip
  `new == committed`, one `ModelContext` save per settle, clear pending).
- Wire `ViewsPane.swift` (Mac) + the iOS Views detail: one model per displayed view; `commitNow()`
  on `.onDisappear`, `scenePhase != .active` (iOS), and view-switch (Mac pane selection change).
- Tests: N toggles → one save; round-trip → zero saves; enter/leave with no toggle → zero saves;
  precedence incl. newer-revision supersession (spec §1) and the recurring-reset case (agent
  republishes `- [ ]`, old checked overlay does NOT bleed through).

**7d. Export + prune + MCP + runbook.**
- Edit `Export/CorpusExporter.swift`: write `interactions.jsonl` (spec §6 line shape, denormalized
  `blockText`; same temp+rename style); `.ollie.meta.json` `layerCounts` gains `"interactions": N`
  (additive, no meta version bump); extend the orphan-prune pass (records of deleted views;
  records with `blockId` absent from latest revision AND older than it AND age > 30 days).
  Interactions export **in full** — same gate reasoning as views (§3.3).
- Edit `mcp-server/ollie_layers.py` + `ollie_mcp.py`: `get_view` gains `interactions`
  (only rows *applying* under the precedence rule — newer than the returned revision), each
  `{blockId, blockText, value, updatedAt}`. No new write tool.
- Edit `Scripts/ollie-runbook.md`: consumption step — for each applying checked item, act on it
  (if `blockText` cites `ollie://note/<uuid>`, tag that note, e.g. `done` / `request:done`), then
  republish the view dropping it or baking in `- [x]`; **the republish is the acknowledgment**.
  Never write or delete interaction records.
- Tests: exporter via `exportDirectoryOverride` (shape, prune, meta count); pytest for the
  `get_view` overlay filtering.

**Verify:** `swift test` + `pytest mcp-server/tests` green; iOS simulator build green (no `-sdk`!);
Mac manual pass — tap boxes rapidly, confirm exactly one `interactions.jsonl` change per settle
and none on a round-trip; check a box on the iPhone (hardware), see it in `interactions.jsonl` on
the Mac, run `./Scripts/ollie-agent-run.sh`, confirm the republished view absorbed it and the
overlay stopped applying.
**Release gate (blocking, before any TestFlight/DMG build):** deploy the schema to CloudKit
**Production** — cktool import to Development → Dashboard *Deploy Schema Changes to Production* →
`Scripts/verify-prod-schema.sh` reports **31/31** — then bump the build. Same runbook as the M1
deploy (see `docs/cloudkit-sync-troubleshooting.md`).

### M8 — Watch views + views polish (time machine, double-title)

**Goal:** the pinned view's latest revision readable on the wrist; users can restore an earlier
view revision; the view-name/H1 duplication is gone. **No schema change** — nothing here touches
a synced `@Model`, so no golden regen and no Production deploy.

**8a. Watch views (read-only).**
- iPhone side (`HandheldNotesiOS/Sources/WatchSessionReceiver.swift` — it already calls
  `updateApplicationContext`): extend the snapshot with the pinned view (`viewName`, latest
  revision `body` truncated safely to ≤ 24 KB on a character boundary with a "… (truncated)"
  marker, `agentId`, `createdAt`). Pinned name comes from `NotesSettings.pinnedViewName`; when
  nothing is pinned, send the newest view. Pure encode/truncate helpers, unit-tested.
- Watch side (`Watch/Sources/`): receive in `WatchConnectivityClient.swift`; new
  `WatchViewScreen` rendering the body via `MarkdownLite` **path-referenced into the watch
  target like `Theme.swift`** (project.yml `sources` entry). MarkdownLite is watch-safe except
  `.textSelection(.enabled)` (heading + code block), which **does not exist on watchOS** — wrap
  it in a small `#if !os(watchOS)` conditional modifier first (Core change, no behavior change
  on Mac/iOS). `onOpenNote` = no-op on watch (citations render as plain text; no note browsing
  on the wrist). This is the one plan-sanctioned exception to "nothing touches `Watch/Sources/`."
- **Interaction stays off the watch** (M7 non-goal): the hook is nil there.

**8b. Time machine — restore an earlier revision.**
- Core: `AgentLayerStore.userRestore(viewName:revisionId:surface:)` — appends a **new** revision
  copying the old body (append-only preserved; never edits or reorders history), `agentId` =
  `user-mac` / `user-ios`. Add the `user-<surface>` agentId convention to `docs/agent-contract.md`
  §1 (one line).
- UI: the "Earlier revisions" rows (Mac `ViewsPane.swift` detail; iOS `ViewsFeedView.swift`
  detail) gain a **Restore** action with a confirm. Free synergy with M7: the restored copy is a
  *newer revision*, so per the precedence rule any older interaction overlays stop applying —
  exactly right.
- Tests: restore appends (count + 1); latest-wins now shows the restored body; the source
  revision is byte-identical afterward.

**8c. Double-title.**
- `MarkdownLite` gains an optional `suppressLeadingHeading: String?` (default nil = zero change):
  when the **first** block is an H1 case-insensitively equal to it, skip that block. Detail panes
  pass the view name; feed previews and everything else pass nothing.
- `Scripts/ollie-runbook.md`: one line — don't open a view body with an H1 repeating the view
  name.
- Tests: suppression logic on `blocks(from:)` output; non-first / non-matching H1 untouched.

**Verify:** `swift test` green; iOS app **and** watch app build (`-destination` only — never
`-sdk`; the `HandheldNotesWatch` scheme exists for exactly this). Manual: pin a view on the
iPhone → it appears on watch hardware; restore an old revision on the Mac → latest flips, iPhone
follows via sync; publish a view whose body opens with its own name as H1 → renders once.

---

## 5. End-to-end acceptance (after M6)

The demo that proves the vision, on real hardware:

1. Speak a note into the **watch**: "Ollie, what did I say about the heat pump last week?"
2. Watch → iPhone (WatchConnectivity) → transcribed, saved, synced (existing pipeline).
3. Mac app (running) re-exports; the scheduled runner (or a manual `ollie-agent-run.sh`) picks it
   up: tags it `request:open`, searches the corpus, publishes a view "Heat pump question" citing
   the relevant notes, retags `request:done`.
4. iPhone **Views tab** shows the answer, provenance-stamped; tapping a citation opens the
   original note. Mark one cited note restricted → within one export cycle it vanishes from
   `~/Ollie/` including its tag lines.

Plus the standing checks: `swift test` green in HandheldNotes; `pytest` green in `mcp-server/`;
iOS simulator build green; `SchemaGoldenTests` golden regenerated exactly once (M1); CloudKit
Production deploy done before any release build (`SCHEMA_DEPLOYED=1` gate enforces the ack).

---

## 6. Deferred, with names reserved (do not build; do not break)

- **Views v2 fenced blocks**: interactive fenced blocks (`checklist`, `metric`, `chart`,
  `timeline`) with explicit item ids (`cl2:` prefix reserved). Renderer already passes unknown
  fences through as monospaced panels. *(The plain-markdown checkbox interaction layer is no
  longer deferred — it is **M7**, designed in `docs/views-v2-interaction-spec.md`, which also
  supersedes the old `InteractionEventEntity` name with `InteractionStateEntity`.)*
- ~~**Watch views**~~ — no longer deferred: now **M8** (read-only pinned view on the wrist).
  Watch *interaction* (tapping checkboxes on the wrist) remains deferred.
- **Photo notes**: `CaptureKind.photo`, per-note media attachments, render-to-text (OCR/caption)
  at capture, `media` field in exports (already reserved), content-addressed view assets.
- **On-device agent**: FoundationModels tool-calling loop inside the apps, privileged tier
  (sees restricted), same `AgentOp` structs applied in-process (`via: "in-process"`).
- **System MCP / App Intents bridge**: when Apple's App Intents ↔ MCP bridge matures, expose the
  contract's reads/writes as intents 1:1 (`via: "app-intent"`). Intents for capture/search
  already exist (`SaveNoteIntent`, `FindNotesIntent`, `StartRecordingIntent`).
- **Request lifecycle beyond tags**, memory consolidation passes, tag-merge gardening: agent
  behaviors, not app features — evolve them in `Scripts/ollie-runbook.md`.
