#!/usr/bin/env bash
set -euo pipefail
#
# install-agent-runner.sh (M6) — install the launchd job that runs the Ollie agent
# loop on a schedule.
#
# It writes ~/Library/LaunchAgents/com.mohammadshobaki.ollie.agent-runner.plist
# (StartInterval 14400 = every 4 h, RunAtLoad false, stdout+stderr →
# ~/Ollie/agent-runs/launchd.log), then bootstraps it into your GUI launchd domain
# so macOS runs Scripts/ollie-agent-run.sh on the timer. The runner's own guards
# (Mac app running, corpus fresh, no run in flight) decide whether each firing does
# anything — see ollie-agent-run.sh.
#
# The heavy lifting is all in ollie-agent-run.sh; this only schedules it. To change
# the cadence, edit StartInterval below (or the installed plist) and re-run. To use a
# different model, set CLAUDE_MODEL in the plist's EnvironmentVariables (add a block)
# or edit the runner's default.
#
# Env knobs:
#   PRINT_ONLY=1   write nothing, load nothing — just print the plist + the commands
#                  (useful to review before committing to the install).
#   START_INTERVAL seconds between runs (default 14400 = 4 h).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNNER="$SCRIPT_DIR/ollie-agent-run.sh"

LABEL="com.mohammadshobaki.ollie.agent-runner"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST="$PLIST_DIR/$LABEL.plist"
LOG_DIR="$HOME/Ollie/agent-runs"
LAUNCHD_LOG="$LOG_DIR/launchd.log"
START_INTERVAL="${START_INTERVAL:-14400}"   # 4 hours
DOMAIN="gui/$(id -u)"

# Render the plist to stdout so the same text is used whether we print or install.
render_plist() {
  cat <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$RUNNER</string>
    </array>

    <!-- Every 4 h. The runner exits quietly when the Mac app is closed, so a firing
         while you're away is a cheap no-op. -->
    <key>StartInterval</key>
    <integer>$START_INTERVAL</integer>

    <!-- Don't fire at login/load — wait for the first interval. -->
    <key>RunAtLoad</key>
    <false/>

    <key>StandardOutPath</key>
    <string>$LAUNCHD_LOG</string>
    <key>StandardErrorPath</key>
    <string>$LAUNCHD_LOG</string>

    <!-- launchd starts jobs with a minimal PATH; give the runner the usual dirs so
         it can find claude, jq, and friends. -->
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
</dict>
</plist>
PLIST_EOF
}

BOOTSTRAP_CMD="launchctl bootstrap $DOMAIN \"$PLIST\""
KICKSTART_CMD="launchctl kickstart -k $DOMAIN/$LABEL"
UNINSTALL_CMD="launchctl bootout $DOMAIN/$LABEL ; rm -f \"$PLIST\""

if [[ "${PRINT_ONLY:-}" == "1" ]]; then
  echo "# PRINT_ONLY=1 — nothing written or loaded. Plist that WOULD be written to:"
  echo "#   $PLIST"
  echo "# ----------------------------------------------------------------------"
  render_plist
  echo "# ----------------------------------------------------------------------"
  echo "# To install it: bootstrap into your GUI launchd domain —"
  echo "#   $BOOTSTRAP_CMD"
  echo "# Run once immediately (test):"
  echo "#   $KICKSTART_CMD"
  echo "# Uninstall:"
  echo "#   $UNINSTALL_CMD"
  exit 0
fi

mkdir -p "$PLIST_DIR" "$LOG_DIR"
render_plist > "$PLIST"
echo "Wrote $PLIST (StartInterval=${START_INTERVAL}s, RunAtLoad=false)."
echo "Runner: $RUNNER"
echo "launchd log: $LAUNCHD_LOG"

# If a previous copy is loaded, replace it cleanly (bootout is a no-op if absent).
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
if launchctl bootstrap "$DOMAIN" "$PLIST"; then
  echo "Bootstrapped $LABEL into $DOMAIN."
else
  echo "WARNING: 'launchctl bootstrap $DOMAIN \"$PLIST\"' failed. Load it manually:" >&2
  echo "  $BOOTSTRAP_CMD" >&2
fi

cat <<INFO

Installed. It will run every $((START_INTERVAL / 3600)) h (next firing after one interval;
RunAtLoad is false so nothing runs at login).

  Run once now (test it):   $KICKSTART_CMD
  Watch the launchd log:    tail -f "$LAUNCHD_LOG"
  Per-run logs:             $LOG_DIR/<timestamp>.log
  Change cadence:           edit StartInterval in $PLIST (or re-run with START_INTERVAL=…), then
                            $UNINSTALL_CMD ; $BOOTSTRAP_CMD
  Uninstall:                $UNINSTALL_CMD
INFO
