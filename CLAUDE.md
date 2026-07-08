# CLAUDE.md — HandheldNotes (Ollie)

Ollie is a voice-notes system: capture a spoken thought on Mac / iPhone / Apple Watch, it
lands in one CloudKit library, and an **agent layer** (tags, memory, published "views")
adds rented intelligence on top. This repo is a SwiftPM package holding:

- `Sources/HandheldNotesCore/` — the shared library compiled into the Mac app, the iPhone
  app, **and** the watch app (models, store, sync, transcription, agent layer, `MarkdownLite`
  + `FenceWidgets` renderers, theme).
- `Sources/HandheldNotes/` — the macOS app (ships as `Ollie.app`).
- `mcp-server/` — the Python MCP server agents use to read/write the corpus.
- `Scripts/` — build/sign/release, the launchd agent runner, and `ollie-runbook.md`
  (the prompt the scheduled agent executes — editing it changes agent behavior).

The iPhone + watch app live in the sibling repo `../HandheldNotesiOS` (XcodeGen; has its
own CLAUDE.md). It consumes Core by relative path, so **a Core change is not done until
BOTH apps are rebuilt and reinstalled** — testing against a stale installed binary is the
classic phantom-bug trap here (RELEASE.md).

**Product-shaped decision?** (new surface, new dependency, anything touching cost, custody,
or how agents connect) — read `VISION.md` first. It defines what Ollie is *and refuses to
be* (no vendor server, no chat surface, one gate, one store writer, agent-agnostic file
contract). A change that fights it needs the vision updated deliberately, not worked around.

## State of the world (July 2026)

Agent-layer milestones **M0–M9 are all shipped** (see `AGENT_LAYER_PLAN.md` §M-headers for
as-built notes): tags/memory/views + restriction gate + MCP server + scheduled runner (M0–M6),
interactive checkboxes (M7), watch views + revision restore + double-title fix (M8), the
fence widgets `metric`/`chart`/`timeline`/`table` (M9, renderer-only), and a watch-face
complication (WidgetKit, tap → capture). Shipped as iOS TestFlight **build 33** + a
Developer-ID Mac app; 33 also validated deleting `NSCameraUsageDescription` (C1 closed). `checklist` and `cl2:` ids remain **reserved,
unbuilt** (contract §7). **C2 closed 2026-07-07**: the launchd runner does unattended passes
(first verified run: 72 tags, 8 views, 2 request-notes answered). The RUNTIME is deployed to
`~/Ollie/{bin,mcp}` by `Scripts/install-agent-runner.sh` — launchd cannot read this Desktop
repo (TCC), so **re-run the installer after editing the runner, runbook, or MCP server**.

## Build & test

```bash
swift test                          # 240+ tests, includes the schema golden gate
./Scripts/build_app.sh              # build + sign a runnable Ollie.app (prints path)
```

- **This repo lives on the iCloud-synced Desktop, and iCloud corrupts SwiftPM's `.build`
  SQLite db** ("disk I/O error" on `.build/build.db`, sometimes *after* all tests pass).
  Use `swift test --scratch-path /private/tmp/hn_scratch` for anything heavy. Parallel
  agents MUST each use their own scratch path. `build_app.sh` honors `BUILD_DIR` the same
  way; release signing also behaves better off iCloud.
- Full ship procedure (both platforms) is `RELEASE.md` — schema-deploy gate, notarization,
  and the TestFlight rule that **upload success ≠ shipped** (poll `processingState` → `VALID`).

## Invariants (violating these is a design regression, not a style choice)

1. **Notes are immutable ground truth.** Nothing may edit a note's transcript on an agent's
   behalf. The agent layer is derived, attributed, regenerable, disposable.
2. **Append-only, attributed.** Every agent record carries `agentId` + timestamp; updates are
   new records (view revisions, memory retire-and-replace), never in-place edits.
3. **The Mac app is the only store writer.** External writes queue as ops in `~/Ollie/inbox/`;
   the app validates mechanics (ids, sizes) — never meaning.
4. **Restriction is contagious.** A restricted note and everything derived from it stay out of
   everything under `~/Ollie/`.
5. **Capture never waits on intelligence.**

## Landmines (each of these has already cost real hours — state them to any subagent)

- **Never mutate observed `@Observable`/`@Published` state during SwiftUI render.** It makes
  an infinite render loop: Mac beachball, iOS `0x8BADF00D` watchdog kill. Cache render-time
  derivations behind `@ObservationIgnored`. Unit tests cannot catch it; diagnose with
  `sample <pid>` and judge frames by sample weight (N/N = loop). See
  `docs/views-v2-interaction-spec.md` §10.
- **A red `SchemaGoldenTests` means you changed the synced schema.** If a schema change was
  not your task, you have drifted — stop and re-read the spec; never "fix" it by regenerating
  the golden. A *deliberate* schema change requires the CloudKit **Production** deploy dance
  (RELEASE.md steps 1–2; Production never auto-creates fields — skipping this caused a
  multi-hour sync outage, internal error `1011`).
- **watchOS compiles a subset of Core.** The watch target path-references only
  `AgentViews/MarkdownLite.swift` + `AgentViews/FenceWidgets.swift` (plus theme/models) from
  this package — new rendering code must live in (or be reachable from) those files, and
  watch-unavailable API must be guarded (no `.textSelection` — use the `hcTextSelectable()`
  shim already in MarkdownLite).
- **Fence-widget parsing must stay tolerant and pure.** `FenceWidget.parse` returns `nil` on
  anything malformed (one bad line fails the whole fence; non-finite chart numbers rejected)
  and the renderer falls back to the monospaced panel — never an error, never stripped
  (contract §6.1). NaN/∞ reaching SwiftUI frame math is a crash class.
- **`strings` on a release binary misses literals ≤15 UTF-8 bytes** (Swift small-string
  inlining). To confirm a feature is compiled in, grep a >15-byte literal from the same view.
- The runtime corpus (`~/Ollie/ollie.jsonl`, `tags/memory/views/interactions.jsonl`,
  `.ollie.meta.json`, `inbox/`) **only refreshes while the Mac app is running** — it is also
  your best verification surface (authoritative record of saves, ticks, publishes).
- Known app bug until fixed: a capture-bar note's `createdAt` is the *draft session start*,
  not send time — `list_notes(since:)` can miss fresh notes; the runbook works around it.

## Docs map (where the truth lives)

| Doc | Role |
|---|---|
| `VISION.md` | **The soul** — what Ollie is / refuses to be, trust + cost model, north-star scenes. Governs *product intent*; consult before product-shaped decisions. |
| `docs/agent-contract.md` | **Canonical data contract** — entities, export layout, inbox ops, fence grammar (§6.1), reserved names (§7), agentId conventions (§1, incl. `user-<surface>` restores), runner ops (§9). On conflict over mechanics, this wins. |
| `AGENT_LAYER_PLAN.md` | Milestone specs M0–M9 with as-built notes — written as implementable specs; point implementing agents at the relevant § |
| `RELEASE.md` | Ship discipline, both platforms; the "declared done but never verified" traps |
| `Scripts/ollie-runbook.md` | The scheduled agent's prompt (7 steps + view style guide) |
| `docs/views-v2-interaction-spec.md` | M7 checkbox design contract (blockId derivation, overlay semantics) |
| `docs/home-node.md` | Running the user's MacBook as the always-on hub — power profile script (`Scripts/setup-home-node.sh`), clamshell test, native 80% charge limit |
| `docs/roadmap-next.md` | The executed Jul-2026 roadmap (historical record) |
| `ECOSYSTEM.md` / `BACKLOG.md` | Cross-repo overview / what's next |
| `docs/cloudkit-sync-troubleshooting.md` | Sync incidents — start with `Scripts/diagnose-sync.sh` |

## Orchestrating agent fleets here (the pattern that shipped M7–M9 clean)

- Stage by **disjoint file ownership**, not by feature; all agents share the real tree. Give
  each agent its ownership list plus the rule: *a build failure exclusively in files you don't
  own is a sibling's in-flight edit — note it and finish, don't fix it.*
- Every agent prompt carries the landmine list above as ground rules.
- Separate `--scratch-path` per agent (see Build & test).
- Verify loop per work item: `swift test` → iOS build → **watch build** (`HandheldNotesWatch`
  scheme, `-destination 'generic/platform=watchOS'`, **never `-sdk`**).
- Review pass: three lenses (render-loop/observation, spec-compliance, watch-safety/parser
  edges), then an independent refuter agent per blocker/major finding before any fixer runs.

## Conventions

- Direct commits to `main` are the norm in both repos (user-sanctioned; no PR flow). Subject
  style per `git log`: `fix(m7): …`, `docs: …`, `M8: …`.
- Product name is **Ollie**; code/scheme/bundle names still say HandheldNotes
  (`com.mohammadshobaki.handheldnotes`).
- The Mac app must be running for MCP writes to apply (`corpus_stats().pendingOps` climbing
  means it's closed).
