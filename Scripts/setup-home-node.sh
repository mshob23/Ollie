#!/bin/bash
# setup-home-node.sh — pin this Mac's power profile for Ollie home-node duty.
#
# Desired behavior (docs/home-node.md, VISION.md "The Mac is a home node"):
#   - On AC power: never system-sleep (even lid-closed, via a caffeinate agent),
#     display dark after 10 min.
#   - On battery: untouched — normal sleep, lid-close sleeps, safe to bag.
#   - Battery capped at 80% via the NATIVE macOS Charge Limit (26.4+) — a GUI
#     setting this script can only remind you about, not set.
#
# Modes (read-only unless stated):
#   --status           Compare live state against the profile (default mode)
#   --apply            Pin the profile (sudo for pmset; installs LaunchAgent)
#   --undo             Restore pmset from backup, remove the LaunchAgent
#   --lid-test-start   Begin the clamshell heartbeat test (plugged in!)
#   --lid-test-check   Analyze the heartbeat + pmset log, print the verdict
#
# Idempotent: re-running --apply is safe; the pmset backup is written once,
# on first apply, and never overwritten.

set -euo pipefail

STATE_DIR="$HOME/.ollie-home-node"
BACKUP_FILE="$STATE_DIR/pmset-backup.env"
AGENT_LABEL="com.ollie.home-node.caffeinate"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
LIDTEST_LOG="$STATE_DIR/lid-test.log"
LIDTEST_LAST="$STATE_DIR/lid-test-last.log"
LIDTEST_PIDFILE="$STATE_DIR/lid-test.pid"

AC_SLEEP_TARGET=0
AC_DISPLAYSLEEP_TARGET=10

GUI_DOMAIN="gui/$(id -u)"

ok()   { printf '  \342\234\223 %s\n' "$1"; }                 # ✓
bad()  { printf '  \342\234\227 %s\n' "$1"; FAILURES=$((FAILURES+1)); }  # ✗
info() { printf '  \342\200\242 %s\n' "$1"; }                 # •
warn() { printf '  \342\232\240 %s\n' "$1"; }                 # ⚠

die() { echo "error: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] && die "run as your normal user, not root (sudo is invoked internally where needed)"

# ---- helpers ---------------------------------------------------------------

# get_pm <Battery|AC> <key> — read one value from `pmset -g custom`
get_pm() {
  pmset -g custom | awk -v sec="$1" -v key="$2" '
    /^Battery Power:/ { cur = "Battery" }
    /^AC Power:/      { cur = "AC" }
    cur == sec && $1 == key { print $2; exit }'
}

on_ac() { pmset -g ps | head -1 | grep -q "AC Power"; }

agent_loaded() { launchctl print "$GUI_DOMAIN/$AGENT_LABEL" >/dev/null 2>&1; }

heartbeat_alive() {
  [[ -f "$LIDTEST_PIDFILE" ]] && kill -0 "$(cat "$LIDTEST_PIDFILE")" 2>/dev/null
}

# ---- status ----------------------------------------------------------------

status() {
  FAILURES=0
  echo "Ollie home-node status ($(date '+%Y-%m-%d %H:%M'))"
  echo
  echo "Power profile:"
  local ac_sleep ac_disp batt_sleep
  ac_sleep=$(get_pm AC sleep)
  ac_disp=$(get_pm AC displaysleep)
  batt_sleep=$(get_pm Battery sleep)

  if [[ "$ac_sleep" == "$AC_SLEEP_TARGET" ]]; then
    ok "AC: system never idle-sleeps (sleep $ac_sleep)"
  else
    bad "AC: system idle-sleeps after ${ac_sleep} min (want $AC_SLEEP_TARGET) — run --apply"
  fi
  if [[ "$ac_disp" == "$AC_DISPLAYSLEEP_TARGET" ]]; then
    ok "AC: display sleeps at ${ac_disp} min"
  else
    bad "AC: display sleeps at ${ac_disp} min (want $AC_DISPLAYSLEEP_TARGET) — run --apply"
  fi
  if [[ "$batt_sleep" != "0" ]]; then
    ok "Battery: normal sleep preserved (sleep $batt_sleep)"
  else
    bad "Battery: system sleep is DISABLED on battery — undo/apply to fix (bag-heat risk)"
  fi

  echo
  echo "Clamshell keep-awake agent (caffeinate -s):"
  if [[ -f "$AGENT_PLIST" ]]; then ok "LaunchAgent installed"; else bad "LaunchAgent not installed — run --apply"; fi
  if agent_loaded; then ok "LaunchAgent loaded"; else bad "LaunchAgent not loaded — run --apply"; fi
  if on_ac; then
    if pmset -g assertions 2>/dev/null | grep -q "caffeinate"; then
      ok "caffeinate assertion active (on AC now)"
    else
      bad "on AC but no caffeinate assertion visible"
    fi
  else
    info "on battery right now — caffeinate assertion is intentionally inactive"
  fi

  echo
  echo "Manual settings (script can only check, not set):"
  local limit
  limit=$(ioreg -r -c AppleSmartBattery 2>/dev/null | grep -i -m1 '"ChargeLimit' || true)
  if [[ -n "$limit" ]]; then
    info "charge limit (from ioreg): $limit"
  else
    warn "charge limit not verifiable via CLI — confirm 80% in System Settings → Battery → Charging (i)"
  fi
  local auto_install
  auto_install=$(defaults read /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates 2>/dev/null || echo "unset")
  if [[ "$auto_install" == "1" ]]; then
    warn "macOS updates auto-install is ON — it can reboot the node overnight (System Settings → General → Software Update)"
  else
    ok "macOS updates do not auto-install (value: $auto_install)"
  fi

  echo
  info "power now: $(pmset -g batt | tail -1 | sed 's/^ *//')"
  echo
  if [[ $FAILURES -eq 0 ]]; then
    echo "RESULT: home-node profile fully applied."
  else
    echo "RESULT: $FAILURES check(s) failing."
  fi
  return "$FAILURES"
}

# ---- apply -----------------------------------------------------------------

apply() {
  mkdir -p "$STATE_DIR"

  # One-time backup of the values we change (never overwritten on re-apply).
  if [[ ! -f "$BACKUP_FILE" ]]; then
    {
      echo "# pmset values before first setup-home-node --apply ($(date '+%Y-%m-%d %H:%M'))"
      echo "PREV_AC_SLEEP=$(get_pm AC sleep)"
      echo "PREV_AC_DISPLAYSLEEP=$(get_pm AC displaysleep)"
    } > "$BACKUP_FILE"
    echo "backed up current AC pmset values to $BACKUP_FILE"
  else
    echo "backup already exists ($BACKUP_FILE) — keeping the original"
  fi

  echo "pinning AC power profile (sudo will prompt)..."
  sudo pmset -c sleep "$AC_SLEEP_TARGET" displaysleep "$AC_DISPLAYSLEEP_TARGET"

  echo "installing $AGENT_LABEL LaunchAgent..."
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$AGENT_PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.ollie.home-node.caffeinate</string>
	<key>ProgramArguments</key>
	<array>
		<string>/usr/bin/caffeinate</string>
		<string>-s</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ProcessType</key>
	<string>Background</string>
</dict>
</plist>
PLIST
  launchctl bootout "$GUI_DOMAIN/$AGENT_LABEL" 2>/dev/null || true
  launchctl bootstrap "$GUI_DOMAIN" "$AGENT_PLIST"

  echo
  status || true
  echo
  echo "NEXT (manual, once):"
  echo "  1. System Settings → Battery → Charging (i) → Charge Limit 80%"
  echo "  2. System Settings → General → Software Update → (i) → turn OFF 'Install macOS updates'"
  echo "  3. Run the clamshell test: $0 --lid-test-start   (see docs/home-node.md)"
}

# ---- undo ------------------------------------------------------------------

undo() {
  [[ -f "$BACKUP_FILE" ]] || die "no backup at $BACKUP_FILE — nothing recorded to restore"
  # shellcheck disable=SC1090
  source "$BACKUP_FILE"
  echo "restoring AC pmset values (sleep=$PREV_AC_SLEEP displaysleep=$PREV_AC_DISPLAYSLEEP; sudo will prompt)..."
  sudo pmset -c sleep "$PREV_AC_SLEEP" displaysleep "$PREV_AC_DISPLAYSLEEP"
  echo "removing $AGENT_LABEL LaunchAgent..."
  launchctl bootout "$GUI_DOMAIN/$AGENT_LABEL" 2>/dev/null || true
  rm -f "$AGENT_PLIST"
  echo "done (backup kept at $BACKUP_FILE). Charge Limit, if set, is yours to revert in System Settings."
}

# ---- clamshell lid test ----------------------------------------------------

lid_test_start() {
  on_ac || die "plug the charger in first — caffeinate -s only asserts on AC, so the test is only meaningful plugged in"
  agent_loaded || die "LaunchAgent not loaded — run --apply first"
  mkdir -p "$STATE_DIR"

  if heartbeat_alive; then
    kill "$(cat "$LIDTEST_PIDFILE")" 2>/dev/null || true
    echo "(restarting an already-running heartbeat)"
  fi
  rm -f "$LIDTEST_LOG"

  # Heartbeat: epoch every 5 s, self-terminating after 15 min.
  (
    for _ in $(seq 1 180); do
      date +%s >> "$LIDTEST_LOG"
      sleep 5
    done
  ) >/dev/null 2>&1 &
  echo $! > "$LIDTEST_PIDFILE"
  disown

  echo "heartbeat started (every 5 s, auto-stops after 15 min)."
  echo
  echo "Now, KEEPING THE CHARGER CONNECTED:"
  echo "  1. Close the lid."
  echo "  2. Wait at least 3 minutes."
  echo "  3. Reopen, log in, and run: $0 --lid-test-check"
}

lid_test_check() {
  [[ -f "$LIDTEST_LOG" ]] || die "no heartbeat log — run --lid-test-start first"
  if heartbeat_alive; then kill "$(cat "$LIDTEST_PIDFILE")" 2>/dev/null || true; fi
  rm -f "$LIDTEST_PIDFILE"

  local beats max_gap start_e end_e start_fmt end_fmt
  beats=$(wc -l < "$LIDTEST_LOG" | tr -d ' ')
  [[ "$beats" -ge 2 ]] || die "heartbeat log too short ($beats lines) — rerun --lid-test-start"
  max_gap=$(awk 'NR>1 { g = $1 - p; if (g > max) max = g } { p = $1 } END { print max + 0 }' "$LIDTEST_LOG")
  start_e=$(head -1 "$LIDTEST_LOG"); end_e=$(tail -1 "$LIDTEST_LOG")
  start_fmt=$(date -r "$start_e" '+%Y-%m-%d %H:%M:%S')
  end_fmt=$(date -r "$end_e" '+%Y-%m-%d %H:%M:%S')

  echo "heartbeat window: $start_fmt → $end_fmt ($beats beats, max gap ${max_gap}s)"

  # Independent signal: system sleep entries inside the window, from pmset's own log.
  local sleeps
  sleeps=$(pmset -g log | awk -v s="$start_fmt" -v e="$end_fmt" \
    '/Entering Sleep/ { ts = $1 " " $2; if (ts >= s && ts <= e) print }' || true)
  if [[ -n "$sleeps" ]]; then
    echo "pmset log shows sleep during the window:"
    echo "$sleeps" | sed 's/^/    /'
  else
    echo "pmset log shows no 'Entering Sleep' in the window."
  fi

  mv "$LIDTEST_LOG" "$LIDTEST_LAST"
  echo
  if [[ "$max_gap" -le 20 && -z "$sleeps" ]]; then
    echo "VERDICT: STAYED AWAKE — caffeinate holds the lid-closed state on AC."
    echo "Clamshell mode works with zero third-party software. You're done."
  elif [[ "$max_gap" -ge 30 || -n "$sleeps" ]]; then
    echo "VERDICT: SLEPT — the assertion does not survive lid-close on this Mac/OS."
    echo "Fallback: install Amphetamine (App Store) per docs/home-node.md §Fallback,"
    echo "or run the node lid-open (display still sleeps at ${AC_DISPLAYSLEEP_TARGET} min)."
  else
    echo "VERDICT: INCONCLUSIVE (gap ${max_gap}s) — close the lid for longer (3+ min) and rerun the test."
  fi
}

# ---- main ------------------------------------------------------------------

case "${1:---status}" in
  --status)          status ;;
  --apply)           apply ;;
  --undo)            undo ;;
  --lid-test-start)  lid_test_start ;;
  --lid-test-check)  lid_test_check ;;
  --help|-h)         sed -n '2,20p' "$0" ;;
  *)                 die "unknown mode: $1 (try --help)" ;;
esac
