# Contributing to Ollie

Thanks for looking under the hood. Ollie is a personal project, open-sourced so you can
run your own — contributions are welcome inside the guardrails below.

## Before you build anything product-shaped

1. **Read [`VISION.md`](VISION.md) first.** It defines what Ollie is and — just as
   binding — what it *refuses to be*: no vendor server, no accounts, no chat surface,
   one gate, one store writer, an agent-agnostic file contract. A PR that fights a
   non-goal will be declined even if it's well built; if you think the vision itself
   should change, open an issue and argue that instead.
2. **On mechanics, [`docs/agent-contract.md`](docs/agent-contract.md) wins.** Entities,
   export layout, inbox ops, fence grammar, reserved names — every surface conforms to
   that one document. If your change and the contract disagree, either the change is
   wrong or the PR must update the contract deliberately.
3. **The invariants are design constraints, not style choices:**
   - Notes are immutable ground truth — nothing edits a transcript on an agent's behalf.
   - Agent data is append-only and attributed (`agentId` + timestamp); updates are new
     records, never in-place edits.
   - The Mac app is the only store writer; external writes queue as inbox ops, and the
     app validates *mechanics*, never *meaning*.
   - Restriction is contagious: a restricted note and everything derived from it stay
     out of everything under `~/Ollie/`.
   - Capture never waits on intelligence.

## Getting set up

The README's [Getting started](README.md#getting-started-zero-to-the-full-loop) covers
the zero-to-loop path. You don't need an Apple Developer account to build and hack —
the ad-hoc tier runs everything locally. For CloudKit sync you'll need your own team;
see [Bring your own Apple identity](README.md#bring-your-own-apple-identity-forks--contributors).

## The verify loop (run all of it before opening a PR)

Core is compiled into **three** apps, so a change isn't verified until all three compile:

```bash
swift test --scratch-path /private/tmp/hn_scratch   # full suite incl. the schema golden gate
./Scripts/build_app.sh                              # Mac app builds + signs
# then, in the sibling HandheldNotesiOS repo:
xcodegen generate
xcodebuild -project HandheldNotesiOS.xcodeproj -scheme HandheldNotesiOS \
    -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /tmp/hn_ios_dd build
xcodebuild -project HandheldNotesiOS.xcodeproj -scheme HandheldNotesWatch \
    -destination 'generic/platform=watchOS' -derivedDataPath /tmp/hn_watch_dd build
```

## Things that have already cost real hours (don't re-learn them)

- **Never mutate observed `@Observable`/`@Published` state during SwiftUI render.** It
  makes an infinite render loop — Mac beachball, iOS `0x8BADF00D` watchdog kill. Cache
  render-time derivations behind `@ObservationIgnored`. Unit tests cannot catch this
  class of bug.
- **A red `SchemaGoldenTests` means you changed the synced CloudKit schema.** If a schema
  change wasn't your intent, you drifted — stop and re-check; never "fix" it by
  regenerating the golden. Deliberate schema changes require the Production deploy dance
  in [`RELEASE.md`](RELEASE.md) (Production never auto-creates fields).
- **Never pass `-sdk iphonesimulator` to xcodebuild** in the iOS repo — the scheme embeds
  a watchOS target and `-sdk` forces it onto the wrong SDK. `-destination` alone is right.
- **watchOS compiles a subset of Core** (path references only). New rendering code must be
  reachable from `MarkdownLite.swift` / `FenceWidgets.swift`, and watch-unavailable API
  must be guarded.
- **Fence-widget parsing stays tolerant and pure**: malformed input → `nil` → monospaced
  fallback panel. Never an error, never stripped, and no NaN/∞ may reach SwiftUI frame
  math (that's a crash class).
- **Keep build products out of cloud-synced folders.** If your clone lives in a synced
  directory (iCloud Desktop, Google Drive, Dropbox), use scratch paths as shown above —
  file-provider sync corrupts SwiftPM's build DB and races codesign.

## PR conventions

- Branch from `main`, keep diffs small and focused, one concern per PR.
- Subject style matches the log: `fix: …`, `docs: …`, `chore: …`.
- By contributing you agree your work is licensed under the project's [MIT license](LICENSE).
