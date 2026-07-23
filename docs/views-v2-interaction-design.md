# Views v2 — user interaction design brief

*Status: ✅ **RESOLVED → BUILT & SHIPPED** (M7, Jul 2026). The six open questions below are answered
in [`views-v2-interaction-spec.md`](views-v2-interaction-spec.md), which was implemented and verified
end-to-end on hardware (iOS build 31 + Mac). This brief is kept as the problem-statement / rationale
record — read the spec for the as-built reference. Originally deferred from Views v1 (see
`AGENT_LAYER_PLAN.md` §6 and [`agent-contract.md`](agent-contract.md) §7).*

## The problem

Views are agent-authored markdown documents rendered in the Ollie apps (Mac + iPhone). Today (v1)
they are **read-only**: the only interactions are tapping a `ollie://note/<uuid>` citation (navigates
to the note), pinning, and deleting a view. Checklist items (`- [ ]`) render as **display-only
glyphs** — tapping does nothing and writes nothing.

Views v2 wants view content to become **interactive** — the obvious first case is a checkbox the user
can actually check. Two questions must be answered before building it:

1. **What is the user-interaction model for views?** (Currently only a one-line reservation exists:
   "`InteractionEventEntity` — tap → event record → export → next run." That is a name, not a design.)
2. **How do we avoid writing a whole new document (or one record per click) when a user rapidly
   toggles a control?** The desired behavior: **commit the settled end-state as one atomic
   transaction**, not one write per tap.

## Non-negotiable invariants (these constrain the design)

These come from the core invariants in `AGENT_LAYER_PLAN.md` §0 — a design that violates them is wrong:

- **Interaction never mutates a view revision.** A `ViewRevisionEntity` is the agent's *immutable,
  append-only, attributed* artifact. A checkbox tap must **never** create a new revision or edit the
  markdown body. Writing "a whole new document per click" is the explicit anti-goal.
- **Capture/UI is immediate; persistence is eventually-consistent.** The UI must respond instantly to
  every tap regardless of write timing. Nothing user-facing waits on a write.
- **The app is the only store writer.** Interaction state is written by the app (like notes/settings),
  not by external agents. Agents *read* interaction state and *react* on their next run.
- **Attributed + mechanical validation.** Any persisted interaction record carries provenance
  (which surface, when); the app validates shape, never meaning.

## Desired design (the shape to flesh out)

Two separations do the heavy lifting:

**A. Interaction state is a separate per-block layer — not part of the document.**
Checked-state (and any future block state) lives keyed by `(viewName, revisionId, blockId) → value`,
*distinct* from the markdown body. Resolving which `blockId` a checklist item has needs a stable,
deterministic scheme (e.g. index-within-view, or a hash of the item text) — **open question below.**

**B. Ephemeral local state vs. durable commit — the debounce/coalesce that answers question 2:**
1. **Optimistic local state** — the box flips instantly in SwiftUI `@State` on every tap. Zero writes,
   any tap rate. UI never blocks.
2. **Debounced commit on settle** — the durable write fires only after interaction *quiesces*
   (~500 ms–1 s after the last toggle) or at a natural boundary (leaving the view, app backgrounding).
3. **End-state, diffed, idempotent** — commit the *final* value, not the sequence. A round-trip
   (on→off→…→back to original) writes **nothing** (guard `new != committed`). One settle → at most one
   write.
4. **Coalesced across blocks** — toggling several boxes before settling commits them as **one batch**,
   not N writes.

Net: tap-tap-tap-tap → one debounced, diffed, atomic write of the resting state.

**Existing patterns to reuse (do not reinvent):**
- The **AI-instructions editor** already does exactly (B): `SettingsView.swift` commits on
  `onDisappear` / focus-loss via `commitInstructionsIfChanged()`, guarded by
  `instructionsDraft != model.agentInstructions()` (buffer locally, write settled value once, no-op if
  unchanged). The checkbox layer is this pattern + a debounce timer.
- The **inbox op protocol** (`agent-contract.md` §"Inbox") writes each op to a temp file then
  **renames** into place — atomic on APFS, no locks. If interaction commits flow as ops, reuse this.
- **`NotesSettings`** tolerant-decode + upsert is the model for a mutable, per-key state layer that is
  *not* append-only revision history.

## Open design questions (what Fable needs to decide)

1. **Where does interaction state live?**
   (a) a new `@Model` `InteractionStateEntity` upserted by `(viewName, revisionId, blockId)` — syncs via
   CloudKit like everything else, visible cross-device; **triggers the schema golden gate** (see below);
   or (b) a local-only UI overlay (per-device, not synced); or (c) append-only `InteractionEventEntity`
   events (matches the reserved name) with latest-wins collapse on read. Trade-offs: sync vs. simplicity
   vs. history. The reservation named *events*, but *upserted state* fits the debounce/idempotent goal
   more naturally — reconcile this.
2. **`blockId` stability** — how to address a specific checklist item across revisions when the agent
   republishes the view body. Index? Content hash? Explicit id in a v2 fenced-block syntax
   (`\`\`\`checklist`)? This interacts with the reserved fence names (`checklist`/`metric`/`chart`/`timeline`).
3. **Agent consumption** — what does the agent *do* with a checked box on its next run? (Mark the
   underlying todo/note done? Rewrite the view to drop it? Nothing?) This is runbook/behavior, but the
   record shape must carry enough for the agent to act.
4. **Cross-device conflict** — two devices toggle the same block offline. Latest-write-wins by
   timestamp is probably fine (it's derived state), but state it explicitly.
5. **Schema-gate cost** — per `agent-contract.md` §1, *any* new `@Model`/field trips
   `SchemaGoldenTests` and requires a **CloudKit Production schema deploy** before release
   (Dev auto-creates; Prod never does — the June/July 2026 outage class). If interaction state is a new
   synced entity, batch it as a single schema change and plan the Prod deploy. A local-only overlay
   avoids this entirely — weigh it.
6. **Contract invariant to add** once designed: *"User interaction never mutates a view revision;
   interaction state is a separate, debounced, end-state, per-block layer — at most one durable write
   per settle."*

## Pointers

- Renderer + where interaction would hook in: `Sources/HandheldNotesCore/AgentViews/MarkdownLite.swift`
  (checklist items render at the `listItemView` / `.checklist` path; `onOpenNote` shows the injected-
  callback pattern to copy for an `onToggle`).
- View detail panes: `Sources/HandheldNotes/UI/ViewsPane.swift` (Mac),
  `HandheldNotesiOS/Sources/` Views tab (iPhone).
- Debounce precedent: `Sources/HandheldNotes/UI/SettingsView.swift` → `commitInstructionsIfChanged()`.
- Store patterns: `Sources/HandheldNotesCore/Store/*Entity.swift`, `Store/AgentLayerStore.swift`.
- Contract + reserved fence/event names: [`agent-contract.md`](agent-contract.md) §7.
