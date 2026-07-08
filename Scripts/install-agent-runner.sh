#!/usr/bin/env bash
set -euo pipefail
#
# install-agent-runner.sh (M6) — install the launchd job that runs the Ollie agent
# loop on a schedule.
#
# DEPLOYS the runtime out of this repo, then schedules it:
#   ~/Ollie/bin/   ollie-agent-run.sh + ollie-runbook.md          (copies)
#   ~/Ollie/mcp/   ollie_mcp.py + ollie_corpus.py + ollie_layers.py + .venv
#                  + mcp-config.json (the runner passes it via --strict-mcp-config)
#   ~/Library/LaunchAgents/com.mohammadshobaki.ollie.agent-runner.plist
#                  (StartInterval 14400 = every 4 h, RunAtLoad false,
#                   stdout+stderr → ~/Ollie/agent-runs/launchd.log)
#
# WHY DEPLOY (not run from the repo): the repo lives on the iCloud-synced Desktop.
# launchd-spawned processes cannot read Desktop at all — macOS TCC folder protection
# returns "Operation not permitted" (this failed in production 2026-07-07) — and
# iCloud can evict/corrupt runtime files. ~/Ollie is home for the RUNTIME; the repo
# is SOURCE. RE-RUN THIS INSTALLER after editing the runner, the runbook, or the
# MCP server — the deployed copies are what execute.
#
# The runner's own guards (Mac app running, corpus fresh, no run in flight, trusted
# workspace) decide whether each firing does anything — see ollie-agent-run.sh.
# Cadence: edit StartInterval below (or re-run with START_INTERVAL=…). Model: set
# CLAUDE_MODEL in the plist's EnvironmentVariables (add a block) or the runner default.
#
# Env knobs:
#   PRINT_ONLY=1   write nothing, load nothing — just print the plist + the commands
#                  (useful to review before committing to the install).
#   START_INTERVAL seconds between runs (default 14400 = 4 h).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNNER="$SCRIPT_DIR/ollie-agent-run.sh"
RUNBOOK_SRC="$SCRIPT_DIR/ollie-runbook.md"
MCP_SRC="$(cd "$SCRIPT_DIR/.." && pwd)/mcp-server"

OLLIE_DIR="$HOME/Ollie"
BIN_DIR="$OLLIE_DIR/bin"
MCP_DIR="$OLLIE_DIR/mcp"
DEPLOYED_RUNNER="$BIN_DIR/ollie-agent-run.sh"
MCP_CONFIG="$MCP_DIR/mcp-config.json"

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
        <string>$DEPLOYED_RUNNER</string>
    </array>

    <!-- Every 4 h. The runner exits quietly when the Mac app is closed, so a firing
         while you're away is a cheap no-op. This is the BACKSTOP cadence. -->
    <key>StartInterval</key>
    <integer>$START_INTERVAL</integer>

    <!-- Event-driven cadence (M11): fire whenever ~/Ollie/.runner-trigger changes.
         The Mac app touches that file (an atomic timestamp write) 90 s after the
         last new note arrives — a note spoken into the watch syncs to the Mac and,
         debounced, kicks a run within ~2 min instead of waiting up to 4 h. launchd
         watches the FILE, not the dir; the app creates/rewrites it in normal use
         (this installer never touches it). The runner's own guards (pidfile,
         app-running, corpus-fresh, trusted-workspace) still gate whether the firing
         does anything, so a spurious change is a cheap no-op — same as an interval
         firing. Loop-safe: the trigger is driven only by immutable-note inserts, and
         no agent effect inserts a note, so a run can't re-trigger itself. -->
    <key>WatchPaths</key>
    <array>
        <string>$OLLIE_DIR/.runner-trigger</string>
    </array>

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

# Copy the runtime out of the (TCC-protected, iCloud-synced) repo into ~/Ollie.
deploy() {
  mkdir -p "$BIN_DIR" "$MCP_DIR"
  cp "$RUNNER" "$BIN_DIR/ollie-agent-run.sh"
  chmod +x "$BIN_DIR/ollie-agent-run.sh"
  cp "$RUNBOOK_SRC" "$BIN_DIR/ollie-runbook.md"
  cp "$MCP_SRC/ollie_mcp.py" "$MCP_SRC/ollie_corpus.py" "$MCP_SRC/ollie_layers.py" \
     "$MCP_SRC/requirements.txt" "$MCP_DIR/"
  if [[ ! -x "$MCP_DIR/.venv/bin/python" ]]; then
    echo "Creating MCP venv at $MCP_DIR/.venv ..."
    python3 -m venv "$MCP_DIR/.venv"
  fi
  "$MCP_DIR/.venv/bin/pip" install -q -r "$MCP_DIR/requirements.txt"
  cat > "$MCP_CONFIG" <<MCP_EOF
{
  "mcpServers": {
    "ollie": {
      "command": "$MCP_DIR/.venv/bin/python",
      "args": ["$MCP_DIR/ollie_mcp.py"],
      "env": { "OLLIE_AGENT_ID": "claude-runner" }
    }
  }
}
MCP_EOF
  echo "Deployed runtime → $BIN_DIR (runner + runbook), $MCP_DIR (server + venv + mcp-config)."
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

deploy

mkdir -p "$PLIST_DIR" "$LOG_DIR"
render_plist > "$PLIST"
echo "Wrote $PLIST (StartInterval=${START_INTERVAL}s, RunAtLoad=false)."
echo "Runner (deployed): $DEPLOYED_RUNNER"
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
  After editing runner/runbook/mcp-server: RE-RUN THIS INSTALLER (deployed copies execute)
  Change cadence:           edit StartInterval in $PLIST (or re-run with START_INTERVAL=…), then
                            $UNINSTALL_CMD ; $BOOTSTRAP_CMD
  Uninstall:                $UNINSTALL_CMD
INFO
