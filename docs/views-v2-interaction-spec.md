# Views v2 — interaction spec (checkbox layer)

*Status: ✅ **BUILT & SHIPPED as M7** (Jul 2026) — iOS TestFlight build 31, Mac Developer-ID build,
CloudKit Production schema deployed (31/31 fields), and verified end-to-end on hardware (taps on
phone + Mac → synced `interactions.jsonl` → agent consumed the checks and republished "Open loops",
which auto-superseded them). This doc is now the **as-built reference**; the milestone task list is
`AGENT_LAYER_PLAN.md` §4 M7. Below resolves the six open questions from
[`views-v2-interaction-design.md`](views-v2-interaction-design.md) — the implementation followed it,
with two field-learned corrections captured in §"Post-ship notes" at the end.*

*Original framing (kept for context): the implementable spec for the first interactive block, the
checkbox, carried out as one milestone (**M7**) following `AGENT_LAYER_PLAN.md` §4 conventions.*
On conflict, the invariants in [`agent-contract.md`](agent-contract.md) §0 win.*

---

## 0. Decisions at a glance

| Open question (brief) | Resolution |
|---|---|
| 1. Where does state live? | A new **synced** `@Model` — `InteractionStateEntity`, **upserted by `(viewName, blockId)` in code**. Not local-only (the Mac agent must see iPhone toggles). Not append-only events (agent needs current state, not history; upsert is the `InstructionsEntity` precedent for user-authored state). The §7 reservation `InteractionEventEntity` is **superseded by this name** — nothing ever shipped under the old one. |
| 2. `blockId` stability | Content-derived: `cl1:<hash16>:<occ>` — SHA-256 over the classifier-captured item text, plus a document-order occurrence ordinal (§3). Survives reorders and republished-identical items; a reworded item detaches and **fails safe** to the body default. Explicit ids inside fenced ` ```checklist ` blocks are reserved (`cl2:` prefix) for later. |
| 3. Agent consumption | New export `interactions.jsonl` (denormalized: carries `blockText`, so agents never compute hashes) + `get_view` gains a resolved `interactions` field + a runbook step. **Republishing the view is the acknowledgment** (see the precedence rule, §1). Agents never write or delete interaction state. |
| 4. Cross-device conflict | Last-writer-wins by `updatedAt` per `(viewName, blockId)`. CloudKit merges edits to the same record; concurrent offline *inserts* of the same key are collapsed on read (latest wins) and losers opportunistically pruned. Derived, low-stakes state — a lost toggle costs one tap. |
| 5. Schema-gate cost | Accepted: **one** entity, one batch, one CloudKit Production deploy (§7). `value` is a `String` (not `Bool`) precisely so future kinds (metric, slider, select) reuse this entity with **no further schema change**. |
| 6. Contract invariant | Exact wording in §8, to be pasted into `agent-contract.md`. |

---

## 1. The model — three layers and one precedence rule

Rendered checked-state for a checklist item is resolved through three layers, top wins:

1. **Pending (optimistic, in-memory)** — the SwiftUI-local value flipped instantly on every tap.
   Zero writes at any tap rate. Never survives the pane.
2. **Overlay (durable, synced)** — the `InteractionStateEntity` record for `(viewName, blockId)`,
   **iff `state.updatedAt > displayedRevision.createdAt`**.
3. **Body default** — the `- [ ]` / `- [x]` state baked into the revision markdown.

The *iff* in layer 2 is the load-bearing rule:

> **A newer revision supersedes older interaction state.** Publishing a revision is how an agent
> *acknowledges* (or deliberately resets) interaction — the new body's baked state becomes the
> default and every older overlay stops applying.

Consequences, all intended:

- Agent republishes "Open loops" with an item **dropped** or baked `- [x]` → consistent, no residue.
- Agent republishes a recurring item as `- [ ]` (a reset) → the old checkmark does **not** bleed
  back through.
- User toggles *after* the latest revision → their state wins until the next publish.
- An agent that republishes an item unchanged *without* consuming a check reverts it visually —
  acceptable, and the runbook step (§6) makes consumption explicit so it shouldn't happen.
- Clock skew between devices is irrelevant at agent cadence (hours) vs. skew (seconds).

Per the brief's invariants: interaction **never** creates or edits a `ViewRevisionEntity`; the
UI responds instantly regardless of write timing; only the app writes the store; every record is
attributed (surface + revision provenance + timestamp).

---

## 2. Entity

Follows the `NoteEntity` conventions exactly (default on every property, no unique constraints,
flat fields, `Entity` suffix, raw-string enums, public value-type projection).

```swift
@Model public final class InteractionStateEntity {   // value type: ViewInteraction
    public var id: UUID = UUID()
    public var viewName: String = ""      // join key — exact match, like revisions
    public var blockId: String = ""       // join key — §3 scheme
    public var blockText: String = ""     // snapshot of the item text at toggle time
                                          // (provenance + agent ergonomics; ≤ 500 chars)
    public var kind: String = "checkbox"  // raw-string enum; only "checkbox" today
    public var value: String = ""         // kind-specific; checkbox: "true" / "false"
    public var revisionId: UUID = UUID()  // provenance: revision displayed at toggle time
    public var surface: String = ""       // provenance: "mac" | "ios"
    public var updatedAt: Date = Date.distantPast
}

public struct ViewInteraction: Identifiable, Codable, Hashable, Sendable { /* mirror, as usual */ }
```

Notes:

- **Logical key** is `(viewName, blockId)` — `revisionId` is *provenance only* (which body the
  user was looking at), **not** part of the key. Keying on revision would wipe every checkmark at
  each 4-hour republish; §1's temporal rule gives the good half of that behavior without the loss.
- `blockText` is stored, not derived at export: the item may be gone from the latest revision by
  export time, and it records what the user *believed* they checked.
- `kind`/`value` as strings: `metric`, slider, select etc. later reuse this entity — **no second
  Production deploy** for the interaction layer.
- Caps (mechanical, in `AgentLayerStore.Caps`): `blockId` ≤ 128, `blockText` ≤ 500 (truncate,
  don't reject — it's a snapshot), `value` ≤ 64, `kind` ≤ 32.

---

## 3. `blockId` scheme

For a plain markdown checklist item (the only interactive block in this milestone):

```
cl1:<hash16>:<occ>
```

- `hash16` — first 16 lowercase hex chars of SHA-256 over the **UTF-8 bytes of the item text
  exactly as `MarkdownLite.classify(line:)` captures it** (post-marker, trimmed, raw inline
  markdown — *not* rendered text). Both platforms share that classifier, so ids agree by
  construction; CryptoKit provides SHA-256 on both.
- `occ` — 0-based ordinal, in document order, among items in the same body whose `hash16` is
  equal. Always present (uniform ids; no special case for singletons).

Properties:

- **Reorder-stable** (the failure mode of index ids) as long as equal-text duplicates don't cross
  each other — and duplicate checklist text in one view is degenerate anyway.
- **Reword detaches** — "Buy milk" → "Buy milk (2%)" is a different id; the old state stops
  matching and the item shows the body default. Failing safe (an unchecked box) is correct: the
  agent changed the statement, so stale agreement shouldn't transfer.
- Computed by the **block parser** (`MarkdownLite.blocks(from:)` annotates checklist `ListItem`s
  with their `blockId`), which has the document order needed for `occ`.
- Reserved: `cl2:<explicit-id>` for future fenced ` ```checklist ` blocks whose items carry
  explicit ids (contract §7 reserved fences). Renderers must treat unknown prefixes as
  non-interactive, never error.

Agents **do not need to implement this hash**: the export and MCP surfaces are denormalized with
`blockText` (§6). The id is an internal join key.

---

## 4. Write path — debounce, coalesce, atomic end-state

One shared `@MainActor @Observable` component in Core (used by both panes, mirroring how
`MarkdownLite` is shared):

```swift
ViewInteractionModel(store: AgentLayerStore, viewName: String, revision: AgentViewRevision, surface: String)
    var pending: [String: Bool]                    // blockId → optimistic value
    func resolved(blockId: String, bodyChecked: Bool) -> Bool   // §1 layers 1→2→3
    func toggle(blockId: String, blockText: String)             // flip pending, restart timer
    func commitNow()                                            // settle boundary
```

Flow (this is `commitInstructionsIfChanged()` + a timer + a batch):

1. **Tap** → flip `pending[blockId]`, restart a single **600 ms** settle timer
   (`Task.sleep`, cancel-and-restart). UI reads `resolved(...)` → instant feedback, zero writes.
2. **Settle** (timer fires) or **boundary** (`.onDisappear`, `scenePhase != .active`, switching
   the displayed view) → `commitNow()`.
3. **Commit**: for each pending entry, compute the currently-committed value (§1 layers 2→3
   *without* pending); **skip entries where `new == committed`** — a full round-trip
   (on→off→…→original) writes nothing. Upsert the survivors through `AgentLayerStore` and
   **save the `ModelContext` once** — one transactional save per settle, however many boxes
   changed. Clear `pending`.
4. Upsert = fetch by `(viewName, blockId)`, update `value/blockText/revisionId/surface/updatedAt`
   if found, else insert. (In-code upsert per contract §2 — CloudKit forbids unique constraints.)

Net: tap-tap-tap-tap → at most **one** durable, diffed, atomic write of the resting state.
`AgentLayerStore` gains `interactions(viewName:)`, `setInteraction(_:)` (the user path, like
`setInstructions`), and interaction cleanup inside `userDelete(view:)` (deleting a view deletes
its interaction state).

**Boundary cycling (enter → toggle → leave, repeated).** Deliberately *not* coalesced further:
each cycle's exit commit is a genuine settled state change and writes once. Entering/leaving
*without* toggling writes nothing (nothing pending). This is fine because (a) the upsert rewrites
one record in place — storage is O(boxes touched), never O(toggles); (b) it's bounded by human
navigation speed (a few ~200-byte record writes per minute, worst case — less traffic than note
capture); and (c) the alternative — holding pending state in memory across navigation to batch
wider — silently loses the user's toggle if the app dies mid-hold. The boundary commit is the last
reliable moment to persist; durability beats saving a tiny write.

---

## 5. Renderer + panes

`MarkdownLite` stays dumb and backward-compatible — one optional hook, same shape as `onOpenNote`:

```swift
public struct ChecklistHook {
    public var resolved: (_ blockId: String, _ bodyChecked: Bool) -> Bool
    public var onToggle: (_ blockId: String, _ text: String) -> Void
}
public init(_ source: String, onOpenNote: @escaping (UUID) -> Void, checklist: ChecklistHook? = nil)
```

- `checklist == nil` (default) → exactly today's v1 display-only glyphs. No other call site changes.
- Non-nil → the glyph renders `resolved(...)` and the glyph+label row gets a tap/click gesture
  calling `onToggle`. Animate the glyph; haptic on iOS. Everything else (citations, fences,
  `openURL` routing — including the *no `.textSelection` on link-bearing Text* rule) is untouched.
- `ViewsPane` (Mac) and the iPhone Views tab each own a `ViewInteractionModel` for the displayed
  view and wire the hook + the `commitNow()` boundaries.

---

## 6. Sync, export, MCP, runbook — the agent side

**Sync/conflict (Q4).** LWW by `updatedAt`. Same-record edits merge in CloudKit per-record;
duplicate-key records (two devices *insert* the same key offline) are collapsed on read — latest
`updatedAt` wins — and losers are hard-deleted opportunistically (app surface; users may delete
anything). Pruning (in the exporter's existing orphan pass): delete records whose view no longer
exists, and records whose `blockId` is absent from the view's latest revision **and**
`updatedAt < latestRevision.createdAt` **and** age > 30 days.

**Export.** New `~/Ollie/interactions.jsonl`, one line per live record:

```json
{"viewName":"Open loops","blockId":"cl1:9f2ab34c11de08a7:0","blockText":"Call the plumber — cite ollie://note/…",
 "kind":"checkbox","value":"true","revisionId":"…","surface":"ios","updatedAt":"2026-07-06T18:12:03Z"}
```

`.ollie.meta.json` `layerCounts` gains `"interactions": N` (additive — no meta version bump).
**Gate:** views export in full (agent-authored from an already-filtered corpus, contract §5), so
interaction state on them exports in full too — nothing here can cite a restricted transcript
that the view itself couldn't.

**MCP.** `get_view` gains an `interactions` array containing only the rows that *apply* under §1
(newer than the returned revision), each `{blockId, blockText, value, updatedAt}`. No new write
tool — **interaction state has no inbox op**; it is user-authored, app-written only.

**Runbook step (convention, like `request:open`/`request:done` — not an app feature).** On each
run, for every standing view: read `get_view(...).interactions`; for each checked item, *act* on
what it says (if `blockText` cites `ollie://note/<uuid>`, tag the note — e.g. `done`, or
`request:done` if it was a request), then **republish the view** dropping the item or baking in
`- [x]`. The republish is the acknowledgment — per §1 it retires the consumed state. Never
append interaction records; never delete them.

---

## 7. Schema gate & release order (Q5)

`InteractionStateEntity` joins `NotesDataStore.modelTypes` → `SchemaGoldenTests` fails by design.
This is the **only** schema change in the milestone (batch rule, contract §2). Ship order:

1. Land the entity + regenerate the golden (test instructions / `Resources/schema.golden`), and
   update `Scripts/expected-ck-fields.txt`: that file is a flat **union** of field names across
   record types, and `CD_id` / `CD_viewName` / `CD_updatedAt` already exist — so only **6** new
   names land (`CD_blockId`, `CD_blockText`, `CD_kind`, `CD_value`, `CD_revisionId`,
   `CD_surface`; 25 → 31). No `Data`-typed fields → no `_ckAsset` twins. One new record type:
   `CD_InteractionStateEntity`.
2. Deploy to CloudKit **Production** before any release build: cktool import to Development →
   Dashboard *Deploy Schema Changes to Production* → `verify-prod-schema.sh` (31/31). Same
   runbook as the M1 deploy.
3. Only then bump the TestFlight build.

---

## 8. Contract amendments (paste-ready)

*`agent-contract.md` §0, new invariant:*

> - **User interaction never mutates a view revision.** Interaction state (`InteractionStateEntity`)
>   is a separate, user-authored, per-block layer written **only by the app** — debounced to the
>   settled end-state, at most one durable write per settle, no write when the end-state equals
>   the committed state. A newer revision supersedes older interaction state: **publishing is the
>   acknowledgment.**

*`agent-contract.md` §7:* replace the `InteractionEventEntity` reservation with a pointer here;
note the rename (`InteractionStateEntity`) and that `cl2:` explicit-id checklist fences remain
reserved.

---

## 9. Milestone M7 — task order

1. **Core:** `InteractionStateEntity` + `ViewInteraction` + store methods + caps; golden regen.
2. **Core:** `blockId` derivation in the block parser + `ChecklistHook` in `MarkdownLite`
   (default nil → zero behavior change); classifier/parser unit tests incl. occurrence ordinals,
   reorder stability, reword detachment.
3. **Core:** `ViewInteractionModel` (debounce/commit); tests: round-trip writes nothing, N toggles
   → one save, boundary commit, §1 precedence (incl. newer-revision supersession).
4. **Apps:** wire panes (Mac + iPhone), boundaries, haptic/animation.
5. **Export/MCP:** `interactions.jsonl` + meta count + prune pass; `get_view.interactions`;
   exporter tests via `exportDirectoryOverride`.
6. **Runbook:** consumption step in `Scripts/ollie-runbook.md`.
7. **Release:** Production schema deploy (§7) → build bump.

**Non-goals (unchanged reservations):** fenced ` ```checklist `/`metric`/`chart`/`timeline`
interactivity, watch interaction, an interaction inbox op, per-tap event history.

---

## 10. Post-ship notes (field-learned corrections, Jul 2026)

Two bugs surfaced only on-device (not in the 182 unit tests, which exercise `resolved()` outside any
SwiftUI observation transaction). Both are fixed and guarded; a future editor of `ViewInteractionModel`
/ `MarkdownLite` must not reintroduce them. See [`ollie-swiftui-render-loop`] for the full write-up.

1. **`resolved()` must not do a per-call store fetch.** It runs for every checklist glyph on every
   layout pass; fetching `store.interactions()` per call meant O(items × re-renders) synchronous
   main-thread SwiftData fetches, which collided with a fresh-install CloudKit import and tripped the
   iOS scene-update watchdog (**0x8BADF00D**). Fix (`f2d46c6`): cache the overlay fetch once per model
   lifetime, invalidate on a writing commit.

2. **`resolved()` must not mutate *observed* state during render.** It records `bodyDefaults` and lazy-
   loads `overlayCache`; while those were observed, the mid-render write re-dirtied the SwiftUI graph →
   infinite update loop (iOS **0x8BADF00D** watchdog kill / macOS endless beachball). Fix (`97ec866`):
   mark every render-mutated property `@ObservationIgnored`; keep **only** `pending` observed (it is
   mutated solely by taps + boundary commits, never during render). Guard test:
   `testResolvedTriggersNoObservationDuringRender` asserts `resolved()` fires no observation `onChange`.

**Also learned (process, now in `RELEASE.md`):** a shared-`HandheldNotesCore` fix requires rebuilding
**and reinstalling both apps** before re-testing (a stale Mac binary masked the fix for an hour); and
TestFlight `altool` "UPLOAD SUCCEEDED" ≠ installable — verify `processingState` reaches **VALID**.
