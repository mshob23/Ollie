# The home node — running the MacBook as Ollie's always-on hub

Why this exists: until phones run respectable agents, the Mac stands in as the always-on
place where intelligence meets the corpus (VISION.md §"The Mac is a home node"). This doc
is the machine half: keep the Mac awake on AC, asleep on battery, battery capped at 80%,
with **zero third-party software** in the default path. The agent half (headless runner
auth C2, event-driven runs) is tracked in BACKLOG.md §home-node track.

Everything scripted lives in `Scripts/setup-home-node.sh`. Bare invocation (or
`--status`) is read-only and safe anytime; it exits non-zero if the profile has drifted.
The event-driven-runs half (M11) is now shipped — see **Event-driven runs** below.

## Target behavior

| State | Behavior |
|---|---|
| Plugged in, lid open | Never sleeps; display dark after 10 min |
| Plugged in, lid closed | Stays awake (caffeinate assertion — see lid test) |
| On battery, lid open | Normal sleep (untouched defaults) |
| On battery, lid closed | Sleeps immediately — safe to unplug and bag, no ritual |

The conditional is enforced by two mechanisms, both Apple-first-party:
`pmset -c` (AC-profile-only settings) and a LaunchAgent running `/usr/bin/caffeinate -s`,
whose keep-awake assertion is **only valid on AC power** by design — unplugging drops it
instantly, no daemon logic of ours involved.

## One-time setup

1. **Run the script** (one sudo prompt, for the two `pmset` values):

   ```bash
   ./Scripts/setup-home-node.sh --apply
   ```

   It backs up the pre-existing AC values to `~/.ollie-home-node/pmset-backup.env`
   (written once, never clobbered), pins `sleep 0` / `displaysleep 10` on AC only, and
   installs + loads the `com.ollie.home-node.caffeinate` LaunchAgent.

2. **Battery cap 80% — native, no third-party**: System Settings → **Battery** →
   ⓘ next to **Charging** → **Charge Limit: 80%** (macOS 26.4+, Apple silicon).
   Two expected behaviors, not bugs: macOS occasionally charges to 100% on purpose to
   recalibrate the percentage readout, and it tops back up whenever the level sags ~5%
   below the limit.

3. **Stop the node rebooting itself**: System Settings → **General** → **Software
   Update** → ⓘ next to Automatic Updates → turn **off** "Install macOS updates"
   (leave security responses on). `--status` checks this and warns if it's on.

4. **Run the clamshell test** (below) to learn which lid mode this Mac supports.

## The clamshell test

Whether a caffeinate assertion survives lid-close (no external display) varies by
Mac/macOS generation — so we measure instead of assuming. Two independent signals: a 5s
heartbeat file (a gap means the machine actually slept) and `pmset -g log`'s own
"Entering Sleep" entries in the window.

```bash
./Scripts/setup-home-node.sh --lid-test-start   # charger must be connected
# close the lid, wait 3+ minutes, reopen, log in
./Scripts/setup-home-node.sh --lid-test-check   # prints the verdict
```

- **STAYED AWAKE** → clamshell works with zero third-party software. Done.

  > **Verified on this hardware 2026-07-07** (M2 MacBook Pro, macOS 26.5.1):
  > STAYED AWAKE — 46 beats over 3m46s, max gap 6s, no `Entering Sleep` in
  > `pmset -g log`. The Amphetamine fallback below is therefore **unused**.

- **SLEPT** → two options:
  - Run the node **lid-open** (display sleeps at 10 min anyway; the panel is LCD — a
    dark screen has no burn-in risk). Zero extra software.
  - Or install the **Amphetamine fallback** (below) for true lid-closed operation.
- **INCONCLUSIVE** → lid wasn't closed long enough; rerun with 3+ minutes.

## Fallback: Amphetamine (only if the lid test SLEPT and you want clamshell)

Trust profile (assessed 2026-07-07): Mac App Store-only — mandatory sandbox, Apple
review, store-channel updates; free since 2014; no network features; blast radius is
power assertions. The lowest-risk third-party category there is. (AlDente is NOT needed
on this setup — the native Charge Limit replaced it.)

1. Install "Amphetamine" from the Mac App Store (id 937984704). No brew cask exists.
2. Amphetamine menu → Preferences → **Triggers** → Enable Triggers → **+**:
   - Criteria: **Power adapter is connected**
   - Session: duration **indefinite**, **allow display sleep ON**,
     **Closed-Display Mode ON** (accept its plugged-in warning — that's the point)
3. Keep the `caffeinate` LaunchAgent installed — they don't conflict; assertions stack.
4. Rerun the lid test to confirm.

## Event-driven runs

The agent runner has two cadences. The **4 h `StartInterval`** is the backstop — a
guaranteed floor so a pass eventually happens even if nothing else fires. On top of it,
`WatchPaths` makes runs **event-driven** so a note spoken into the watch is picked up in
well under a minute (the agent pass itself then takes ~1–3 min) instead of up to four hours:

1. A note arrives on the Mac — a CloudKit import from the watch/phone, or a local Mac
   capture — and becomes a new `NoteEntity` in the store.
2. The Mac app (`AppModel`, macOS-only) debounces: **15 s after the *last* new note**
   (M22; was 90 s), it atomically writes an ISO-8601 timestamp to
   `~/Ollie/.runner-trigger`. A burst of arrivals (a sync catch-up, several watch
   transfers) coalesces into one write — the window resets on each arrival and only
   fires once it goes quiet.
3. `~/Ollie/.runner-trigger` is listed under the launchd job's `WatchPaths`
   (`Scripts/install-agent-runner.sh`), so launchd starts the runner when the file
   changes. The run's own guards (pidfile, app-running, corpus-fresh, trusted-workspace)
   still decide whether it does anything — a firing while the app is closed is a cheap
   no-op, exactly like an interval firing. A trigger that fires **while a pass is already
   running** drops `~/Ollie/.rerun-requested` (M22): the running pass consumes it at a
   successful exit by re-touching the trigger, so a mid-run arrival is handled one
   run-length later instead of waiting for the 4 h backstop.

**Manual test** — force a run without waiting for a note:

```bash
touch ~/Ollie/.runner-trigger        # WatchPaths sees the change → a run starts
tail -f ~/Ollie/agent-runs/launchd.log
```

(In real use the *app* writes this file; you never create it by hand except to test.
Re-run `Scripts/install-agent-runner.sh` after any runner/plist change so the deployed
`~/Library/LaunchAgents/*.plist` actually carries `WatchPaths`.)

**Loop safety** — the trigger is driven **only** by new-`NoteEntity` inserts, and no
agent path ever inserts a note (the runner's tags/views/memory/interaction writes and
re-exports all go through `AgentLayerStore`, which never creates a `NoteEntity`), so a
run can never manufacture the event that would re-trigger it — the system cannot
self-trigger.

## Verification & health

- `./Scripts/setup-home-node.sh --status` — all ✓, exit 0.
- Overnight check (should print nothing from the plugged-in hours):
  `pmset -g log | grep "Entering Sleep" | tail -5`
- Unplug + idle → it should sleep normally (this is a *feature* check, not a failure).
- **The real end-to-end test**: lid closed (or display dark), Ollie Mac app running →
  speak a note into the watch → within a couple of minutes it appears in
  `~/Ollie/ollie.jsonl` without touching the Mac.
- Ongoing: `corpus_stats()` warns when the export is stale >24h — the standing signal
  that the node stopped doing its job.

## Realities to know

- **Stay logged in; locking the screen is fine.** LaunchAgents and the Mac app run in
  your login session. Lock ≠ logout.
- **After a reboot or power blip, one lid-open login is the entire recovery ritual.**
  FileVault means nothing user-level runs until that login; from there the node
  self-restores: pmset values persist across reboots, the caffeinate LaunchAgent and the
  agent runner re-arm via RunAtLoad, and **Ollie.app is a Login Item** (added
  2026-07-07 — remove via System Settings → General → Login Items if ever unwanted).
  Until the login happens, notes queue in CloudKit harmlessly and the agent catches up —
  graceful degradation, not data loss. Run `--status` after login to confirm; it also
  checks that the app is running and the corpus is fresh.
- **The laptop travels.** Unplug and go; everything sleeps normally on battery. The hub
  is simply down until it's back on the charger — same graceful degradation. If the
  vision proves out, a used Mac mini is the permanent-hub upgrade path.
- **Swapping in a new Mac app build — release flavor, quit by PID.** Two hard-won rules
  from 2026-07-08, both learned the same evening:
  1. **The installed app MUST be the `HC_SIGN=release` build.** A plain
     `./Scripts/build_app.sh` produces the DEV flavor — **Development** CloudKit
     entitlements — and installing it split-brains sync: the Mac happily syncs with the
     Development database while the TestFlight phone syncs with Production; every log on
     both ends stays green while nothing crosses (a several-hour incident that looked
     exactly like a phone bug, then a schema outage). Build the installable app as
     `HC_SIGN=release BUILD_CONFIG=release ./Scripts/build_app.sh` and, after EVERY swap,
     verify: `codesign -d --entitlements :- /Applications/Ollie.app | grep -o
     "environment</key><string>[A-Za-z]*"` must print **Production**.
  2. **Quit by PID, not by name.** The process is named **`HandheldNotes`** (the
     executable), not "Ollie": `pgrep -x Ollie` finds nothing and `osascript 'tell app
     "Ollie" to quit'` can silently no-op — leaving the OLD app on deleted vnodes after
     you replace the bundle (a subsequent `open` no-ops too; briefly TWO store writers).
  The ritual: `kill $(pgrep -x HandheldNotes)` → replace `/Applications/Ollie.app` with
  the **release** bundle → `open /Applications/Ollie.app` → verify one instance
  (`pgrep -x HandheldNotes | wc -l`), the Production entitlement (above), and
  `~/Ollie/.ollie.meta.json` mtime jumping (the export fires seconds after launch).
  (The agent runner's own guard already checks the right name — `APP_PROCESS="HandheldNotes"`.)

## Undo

```bash
./Scripts/setup-home-node.sh --undo
```

Restores the backed-up AC pmset values and removes the LaunchAgent. The Charge Limit and
Software Update settings are GUI toggles — revert them in System Settings if desired.
