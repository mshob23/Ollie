# Roadmap — the next awesome point (Jul 2026)

> **STATUS: ✅ EXECUTED (Jul 2026).** F1–F9 and C1 all shipped — implemented by an Opus agent
> fleet (2-stage impl with disjoint file ownership → verify → 3-lens adversarial review, zero
> confirmed findings, builds green on round 1), shipped as iOS TestFlight **build 32** + a
> rebuilt Mac Developer-ID app. Only **C2** (headless `claude` auth for the launchd runner)
> remains, and it needs the user. Milestone as-built notes: `AGENT_LAYER_PLAN.md` §M8/§M9.
> The acceptance demo below is the manual hardware pass to run.

*The orchestration-facing plan for the next implementation push. Milestone mechanics live in
`AGENT_LAYER_PLAN.md` (§M8, §M9) — this doc is the feature inventory,
sequencing, and verification map an implementing agent (or agent fleet) should work from.*

## Where we are

M0–M7 are shipped and verified on hardware: the full agent layer (tags, memory, views,
instructions, restriction gate, MCP server, scheduled runner) plus M7's interactive checkboxes —
views are now a **two-way** channel (user ticks → `interactions.jsonl` / `get_view.interactions` →
agent acts + republishes). iOS TestFlight build 31, Mac Developer-ID build, CloudKit Production
schema at 31/31 fields.

## The destination

One connected experience: **speak into the watch on the sidewalk → the agent works the corpus →
a designed, glanceable answer is on your wrist**; views look intentional (metric cards, bars,
timelines, tables — not plain text); every checkbox is a lever the agent honors; the user can
rewind any view to an earlier revision; and the agents themselves tell us, via a votable wishlist,
which capability to expose next.

## Phase 1 — M8: Watch views + views polish

*Spec: `AGENT_LAYER_PLAN.md` §M8. No schema change. Touches BOTH repos.*

| # | Feature | Summary | Where |
|---|---------|---------|-------|
| F1 | **Watch views (read-only)** | Pinned view's latest revision on the wrist: iPhone extends the `updateApplicationContext` snapshot (name + body ≤ 24 KB char-boundary truncated + provenance); watch renders via path-referenced `MarkdownLite` in a new `WatchViewScreen`. Prereq: wrap `.textSelection(.enabled)` in `#if !os(watchOS)` (Core). Interaction stays off the watch (hook nil). | Core + iOS repo (`WatchSessionReceiver.swift`, `Watch/Sources/`) |
| F2 | **Time machine (revision restore)** | `AgentLayerStore.userRestore(viewName:revisionId:surface:)` appends a NEW revision copying an old body (history never edited); `agentId: user-mac` / `user-ios` (add the `user-<surface>` convention to contract §1). Restore button + confirm on the "Earlier revisions" rows, both platforms. M7 synergy: the restored copy is newer, so stale checkbox overlays stop applying automatically. | Core + Mac `ViewsPane.swift` + iOS `ViewsFeedView.swift` |
| F3 | **Double-title suppression** | `MarkdownLite` gains `suppressLeadingHeading: String?` (default nil = zero change): skip the first block iff it's an H1 equal (case-insensitive) to the view name. Detail panes pass the name; feed previews don't. | Core + both detail panes |

## Phase 2 — M9: Views expressivity (fence widgets + wishlist)

*Spec: `AGENT_LAYER_PLAN.md` §M9. No schema change — a fence is characters inside the existing
`ViewRevisionEntity.body`; old builds keep showing the monospaced panel. Run after M8 (both touch
`MarkdownLite`); all widgets must be watch-safe.*

| # | Feature | Summary | Where |
|---|---------|---------|-------|
| F4 | **`metric` fence widget** | `Label: value (delta)` lines → big-number cards, 2–3 per row. | Core (`FenceWidgets.swift` + `MarkdownLite`) |
| F5 | **`chart` fence widget** | `Label: number` lines → horizontal bars scaled to max. Plain shapes, no Swift Charts. | Core |
| F6 | **`timeline` fence widget** | `<when> — <text>` lines → vertical dotted timeline (`when` verbatim, no date parsing). | Core |
| F7 | **`table` fence widget** | Pipe rows (header + optional `---` row) → simple grid. `table` newly reserved in contract §7. | Core |
| F8 | **View authoring style guide + portfolio rules** | ✅ **Docs shipped ahead (Jul 2026)** — runbook v2: glance budget, lead-with-takeaway, checkbox-as-contract + approval pattern, topic-dossier trigger (4+ related notes), ~8-view cap + retirement, delta lines, no no-op republishes, read-interactions-before-republish invariant. Remaining M9 work is only the §9c doc sync after widgets ship. | `Scripts/ollie-runbook.md`, contract §6.1 |
| F9 | **Agent capability wishlist** | ✅ **Docs shipped ahead (Jul 2026)** — runbook step 6 + contract §7 convention: "Ollie wishlist" view (one checklist line per wish) + `wish:` memory entries; a user *tick* = "build this", agent moves it to `## Requested`. Zero app code — rides M7 checkboxes. This is the demand signal for post-M9 renderer work. | `Scripts/ollie-runbook.md`, contract §7 |

**Shared invariant for F4–F7 (load-bearing):** parsing is tolerant — malformed fence content falls
back to today's monospaced panel, **never** an error, never stripped (contract §6). `FenceWidget.parse`
is pure and returns `nil` for fallback; the `.codeBlock` render arm changes behavior *only* on a
non-nil parse.

## Chores (fold into the same push)

| # | Chore | Summary | Where |
|---|-------|---------|-------|
| C1 | **Compile `MicCaptureService` out of iOS** | `#if os(macOS)` the service (it's Mac-capture-only); once the `AVCaptureDevice` symbol is out of the iOS binary, the ITMS-90683 `NSCameraUsageDescription` workaround in `project.yml` can carry a "removable when…" note (keep the string until a TestFlight build proves the scanner is satisfied). | Core + iOS repo |
| C2 | **Headless `claude` auth for the runner** | `ollie-agent-run.sh` currently fails rc=1 "Not logged in" when launchd runs it. Operational, needs the user's login — not agent-implementable; track it, don't attempt it. | user action |

## Orchestration notes (for the future agent fleet)

- **Two repos**: `HandheldNotes` (SwiftPM: Core + Mac + mcp-server) and `HandheldNotesiOS`
  (XcodeGen: iPhone + watch). F1 spans both; F2–F7 + C1 are Core-first with thin platform wiring.
- **Zero CloudKit deploys in this entire roadmap** — nothing touches a synced `@Model`. If
  `SchemaGoldenTests` fails at any point, an agent has drifted out of scope: stop and re-read the
  spec, don't regenerate the golden.
- **Verify loop per work item**: `swift test` (HandheldNotes) → iOS build → **watch build**
  (`HandheldNotesWatch` scheme, `-destination 'generic/platform=watchOS'` — **never `-sdk`**).
  MarkdownLite changes must build for all three platforms.
- **Known landmines**: `.textSelection` doesn't exist on watchOS (F1 prereq); never mutate
  observed `@Observable` state during render (the M7 0x8BADF00D loop — see
  `docs/views-v2-interaction-spec.md` §10 and RELEASE.md); a shared-Core change requires
  rebuilding BOTH apps before manual testing (stale-binary trap, RELEASE.md).
- **Ship**: Mac via `SCHEMA_DEPLOYED=1 ./Scripts/package_release.sh` (the ack is vacuous here but
  the gate still asks); iOS per RELEASE.md §iOS — bump build number, archive/export/upload, poll
  `processingState` to **VALID** (upload success is not done).

## Acceptance — the demo that proves "awesome"

1. On the Mac, the agent's scheduled pass publishes "This week" containing a `metric` block and a
   `chart` block → they render as **cards and bars** on Mac and iPhone (not gray panels), and the
   same body shows glanceably on the **watch** below the pinned view name (rendered once, no
   double title).
2. User ticks "- [ ] Archive these 12 stale meeting notes?" on the phone → next pass tags the
   cited notes and republishes with the item consumed.
3. User hits **Restore** on last Tuesday's "Open loops" revision on the Mac → latest flips
   everywhere; old checkbox overlays no longer apply.
4. "Ollie wishlist" shows a ticked wish moved under `## Requested` — the input queue for the next
   roadmap.
