#!/usr/bin/env bash
set -uo pipefail
#
# ollie-agent-run.sh (M6) — one unattended pass of the Ollie agent loop on the Mac.
#
# WHAT IT DOES
#   Runs a headless Claude session against the Ollie MCP server (`mcp__ollie__*`)
#   with Scripts/ollie-runbook.md as the prompt: tag new notes, fulfill request-
#   notes, refresh the standing views. Speak a note into the watch on the sidewalk;
#   an answer is in the Views tab by the time you're home.
#
# WHERE IT RUNS
#   Manually (`./Scripts/ollie-agent-run.sh`) or on a schedule via the launchd job
#   that Scripts/install-agent-runner.sh installs (StartInterval 4 h). Either way it
#   is the SAME script — launchd just calls it on a timer.
#
# GUARDS (all three must pass, checked cheapest-and-most-decisive first)
#   1. No run already alive  — a pidfile (~/Ollie/.agent-run.pid) whose PID is still
#      running means a prior pass is in flight; exit quietly so passes never overlap.
#   2. Mac app running       — the corpus only refreshes, and the inbox only drains,
#      while the Ollie Mac app is open (it is the only store writer). If it's closed
#      there is nothing fresh to work on and nothing to apply our writes, so we EXIT
#      QUIETLY (status 0): this is the normal "not now" case on a laptop that's asleep
#      or where the app isn't running, not an error worth waking anyone over.
#   3. Corpus fresh          — `.ollie.meta.json`'s exportedAt must be < 24 h old. A
#      stale corpus means the app hasn't re-exported recently; we STOP (non-zero) so a
#      scheduled run makes noise in its log instead of tagging against stale data.
#
# STATE
#   ~/Ollie/.agent-state.json  {"lastRunAt": "<ISO8601 UTC>"}. Read at start and
#   interpolated into the prompt (the runbook works `list_notes(since=lastRunAt)`),
#   rewritten with the new timestamp only after a successful run. First run (no state)
#   passes an empty lastRunAt — the runbook treats that as "recent notes".
#
# INVOCATION
#   "$CLAUDE_BIN" -p "<runbook>" --model "$CLAUDE_MODEL" --allowedTools "mcp__ollie__*"
#   CLAUDE_BIN defaults to `claude` (override to shim/stub it — the tests point it at a
#   script that just echoes its args). Output → ~/Ollie/agent-runs/<timestamp>.log;
#   logs older than 30 days are pruned. The op writer stamps agentId from
#   OLLIE_AGENT_ID, which we set to `claude-runner`.
#
# ONE-TIME PREREQ (not done here — external to this script)
#   The `ollie` MCP server and its tool allowlist live in ~/.claude/settings.local.json.
#   The write tools (mcp__ollie__tag_note, …) MUST be allowlisted there (or the whole
#   server via "mcp__ollie__*") or the headless run stalls on a permission prompt. See
#   docs/agent-contract.md §9 and mcp-server/README.md.
#
# ENV KNOBS
#   CLAUDE_BIN     claude binary / shim            (default: claude)
#   CLAUDE_MODEL   model passed to --model         (default: opus)
#   OLLIE_DIR      corpus + state + logs root      (default: $HOME/Ollie)
#   RUNBOOK        prompt file                      (default: Scripts/ollie-runbook.md)
#   MAX_CORPUS_AGE_HOURS  freshness ceiling         (default: 24)
#   LOG_RETENTION_DAYS    log-prune horizon         (default: 30)
#   OLLIE_AGENT_ID exported for the MCP op writer   (forced: claude-runner)
#
# EXIT CODES
#   0  ran (or a guard said "not now": app closed, or another run in flight)
#   1  a hard stop: stale corpus, missing runbook, or the Claude invocation failed

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

OLLIE_DIR="${OLLIE_DIR:-$HOME/Ollie}"
RUNBOOK="${RUNBOOK:-$SCRIPT_DIR/ollie-runbook.md}"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
CLAUDE_MODEL="${CLAUDE_MODEL:-opus}"
MAX_CORPUS_AGE_HOURS="${MAX_CORPUS_AGE_HOURS:-24}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"

# The bundle id / process name to detect the Mac app by (from Info.plist:
# CFBundleIdentifier + CFBundleExecutable). Display name is "Ollie".
APP_BUNDLE_ID="com.mohammadshobaki.handheldnotes"
APP_PROCESS="HandheldNotes"

META_FILE="$OLLIE_DIR/.ollie.meta.json"
STATE_FILE="$OLLIE_DIR/.agent-state.json"
PID_FILE="$OLLIE_DIR/.agent-run.pid"
LOG_DIR="$OLLIE_DIR/agent-runs"

# The op writer attributes this run's ops to the launchd loop (contract §1).
export OLLIE_AGENT_ID="claude-runner"

log() { printf '[ollie-agent-run %s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

# ── Guard 1: no run already alive (pidfile) ─────────────────────────────────
# A live PID in the pidfile ⇒ a prior pass hasn't finished; skip so runs never
# overlap (two sessions tagging the same notes / racing the inbox). A stale
# pidfile (PID gone) is reclaimed. We take the file, then trap-clean it on exit.
if [[ -f "$PID_FILE" ]]; then
  OLD_PID="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ -n "$OLD_PID" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
    log "a previous run (pid $OLD_PID) is still alive — skipping this pass."
    exit 0
  fi
  log "clearing a stale pidfile (pid ${OLD_PID:-?} is gone)."
fi

mkdir -p "$OLLIE_DIR" "$LOG_DIR"
echo "$$" > "$PID_FILE"
# Only remove the pidfile if it's still OURS (guards against a racing run that
# reclaimed a stale file and wrote its own pid over ours).
cleanup() {
  if [[ -f "$PID_FILE" ]] && [[ "$(cat "$PID_FILE" 2>/dev/null || true)" == "$$" ]]; then
    rm -f "$PID_FILE"
  fi
}
trap cleanup EXIT

# ── Guard 2: Mac app running (else exit QUIETLY, status 0) ──────────────────
# Prefer lsappinfo (matches the running app by bundle id, the authoritative
# signal); fall back to pgrep on the executable name if lsappinfo is unavailable.
app_running() {
  if command -v lsappinfo >/dev/null 2>&1; then
    if lsappinfo list 2>/dev/null | grep -qF "$APP_BUNDLE_ID"; then
      return 0
    fi
    # lsappinfo ran but didn't see it → fall through to pgrep as a second opinion
  fi
  pgrep -x "$APP_PROCESS" >/dev/null 2>&1
}

if ! app_running; then
  log "Ollie Mac app is not running — nothing to export or ingest against; exiting quietly."
  exit 0
fi

# ── Guard 3: corpus fresh (< MAX_CORPUS_AGE_HOURS) else STOP (non-zero) ──────
# exportedAt is written by CorpusExporter as ISO8601 UTC with a trailing Z and no
# fractional seconds (e.g. 2026-07-06T06:21:28Z) — BSD `date -j -u -f` parses it.
read_exported_at() {
  [[ -f "$META_FILE" ]] || return 1
  local v=""
  if command -v jq >/dev/null 2>&1; then
    v="$(jq -r '.exportedAt // empty' "$META_FILE" 2>/dev/null || true)"
  fi
  if [[ -z "$v" ]]; then
    # jq-free fallback: pull the quoted exportedAt string out with grep/sed.
    v="$(grep -o '"exportedAt"[[:space:]]*:[[:space:]]*"[^"]*"' "$META_FILE" 2>/dev/null \
          | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//')"
  fi
  [[ -n "$v" ]] || return 1
  printf '%s' "$v"
}

EXPORTED_AT="$(read_exported_at || true)"
if [[ -z "$EXPORTED_AT" ]]; then
  log "STOP: no exportedAt in $META_FILE — the corpus has never been exported. Open the Mac app to export, then retry."
  exit 1
fi

EXPORTED_EPOCH="$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$EXPORTED_AT" "+%s" 2>/dev/null || true)"
if [[ -z "$EXPORTED_EPOCH" ]]; then
  log "STOP: could not parse exportedAt='$EXPORTED_AT' from $META_FILE."
  exit 1
fi

NOW_EPOCH="$(date -u +%s)"
AGE_SEC=$(( NOW_EPOCH - EXPORTED_EPOCH ))
MAX_AGE_SEC=$(( MAX_CORPUS_AGE_HOURS * 3600 ))
if (( AGE_SEC > MAX_AGE_SEC )); then
  log "STOP: corpus is stale — exportedAt=$EXPORTED_AT is $(( AGE_SEC / 3600 ))h old (limit ${MAX_CORPUS_AGE_HOURS}h). Open the Mac app to refresh, then retry."
  exit 1
fi
log "corpus is fresh (exportedAt=$EXPORTED_AT, age $(( AGE_SEC / 60 ))m)."

# ── State: read lastRunAt to hand the runbook ───────────────────────────────
read_last_run_at() {
  [[ -f "$STATE_FILE" ]] || return 0   # first run: empty is fine
  if command -v jq >/dev/null 2>&1; then
    jq -r '.lastRunAt // empty' "$STATE_FILE" 2>/dev/null || true
  else
    grep -o '"lastRunAt"[[:space:]]*:[[:space:]]*"[^"]*"' "$STATE_FILE" 2>/dev/null \
      | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//'
  fi
}
LAST_RUN_AT="$(read_last_run_at)"
if [[ -n "$LAST_RUN_AT" ]]; then
  log "last successful run: $LAST_RUN_AT"
else
  log "no prior run recorded — the runbook will treat this as a first pass."
fi

# ── Runbook prompt (with lastRunAt interpolated) ────────────────────────────
if [[ ! -f "$RUNBOOK" ]]; then
  log "STOP: runbook not found at $RUNBOOK."
  exit 1
fi
# The runbook contains the literal token {{LAST_RUN_AT}}; substitute the state
# value (or the word "never") so step 3's `list_notes(since=…)` has a concrete
# anchor. Read the file, replace in-shell (no sed escaping headaches with the
# markdown body).
RUNBOOK_TEXT="$(cat "$RUNBOOK")"
SINCE_VALUE="${LAST_RUN_AT:-never}"
PROMPT="${RUNBOOK_TEXT//\{\{LAST_RUN_AT\}\}/$SINCE_VALUE}"

# ── Log target + 30-day prune ───────────────────────────────────────────────
RUN_TS="$(date '+%Y%m%d-%H%M%S')"
LOG_FILE="$LOG_DIR/$RUN_TS.log"
# Prune old run logs (best-effort; never fails the run). Match our own naming so
# launchd.log and anything else in the dir is left alone.
find "$LOG_DIR" -maxdepth 1 -type f -name '*.log' ! -name 'launchd.log' \
  -mtime "+$LOG_RETENTION_DAYS" -delete 2>/dev/null || true

# ── Invoke headless Claude ──────────────────────────────────────────────────
{
  echo "=== ollie-agent-run $RUN_TS ==="
  echo "model=$CLAUDE_MODEL  agentId=$OLLIE_AGENT_ID  since=$SINCE_VALUE"
  echo "claude=$CLAUDE_BIN"
  echo "corpus exportedAt=$EXPORTED_AT (age $(( AGE_SEC / 60 ))m)"
  echo "==============================="
} > "$LOG_FILE"

log "invoking Claude (model=$CLAUDE_MODEL) — output → $LOG_FILE"
set +e
"$CLAUDE_BIN" -p "$PROMPT" \
  --model "$CLAUDE_MODEL" \
  --allowedTools "mcp__ollie__*" \
  >> "$LOG_FILE" 2>&1
CLAUDE_RC=$?
# (The whole script runs under `set -uo pipefail`, never `-e`, so a non-zero
# claude rc doesn't abort — we branch on $CLAUDE_RC explicitly below.)

if (( CLAUDE_RC != 0 )); then
  log "STOP: Claude exited non-zero (rc=$CLAUDE_RC). See $LOG_FILE."
  echo "=== exited rc=$CLAUDE_RC ===" >> "$LOG_FILE"
  exit 1
fi
echo "=== completed ok ===" >> "$LOG_FILE"

# ── Write back lastRunAt (only on success) ──────────────────────────────────
NEW_RUN_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
NEW_STATE_TMP="$STATE_FILE.tmp.$$"
printf '{\n  "lastRunAt": "%s"\n}\n' "$NEW_RUN_AT" > "$NEW_STATE_TMP"
mv -f "$NEW_STATE_TMP" "$STATE_FILE"
log "done. lastRunAt=$NEW_RUN_AT recorded. Log: $LOG_FILE"
exit 0
