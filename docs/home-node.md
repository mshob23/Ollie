# The home node — running the MacBook as Ollie's always-on hub

Why this exists: until phones run respectable agents, the Mac stands in as the always-on
place where intelligence meets the corpus (VISION.md §"The Mac is a home node"). This doc
is the machine half: keep the Mac awake on AC, asleep on battery, battery capped at 80%,
with **zero third-party software** in the default path. The agent half (headless runner
auth C2, event-driven runs) is tracked in BACKLOG.md §home-node track.

Everything scripted lives in `Scripts/setup-home-node.sh`. Bare invocation (or
`--status`) is read-only and safe anytime; it exits non-zero if the profile has drifted.

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
- **After a reboot or power blip** (FileVault): nothing runs until one lid-open login.
  Notes queue in CloudKit harmlessly and the agent catches up — graceful degradation,
  not data loss.
- **The laptop travels.** Unplug and go; everything sleeps normally on battery. The hub
  is simply down until it's back on the charger — same graceful degradation. If the
  vision proves out, a used Mac mini is the permanent-hub upgrade path.

## Undo

```bash
./Scripts/setup-home-node.sh --undo
```

Restores the backed-up AC pmset values and removes the LaunchAgent. The Charge Limit and
Software Update settings are GUI toggles — revert them in System Settings if desired.
