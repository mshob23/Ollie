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
#   interpolated into the prompt (the runbook works `list_notes(ingested_since=lastRunAt)`),
#   rewritten with the new timestamp only after a successful run. First run (no state)
#   passes an empty lastRunAt — the runbook treats that as "recent notes".
#
# WORK LOG (M13)
#   ~/Ollie/agent-runs/runs.jsonl — ONE JSON line appended after EVERY claude
#   invocation (success AND failure), append-only (contract §9):
#     {"runId","agentId","startedAt","finishedAt","since","corpusExportedAt",
#      "rc","ok","logFile"}
#   Advisory context only, never access control: a later run reads it (via the MCP
#   `recent_runs` tool) to see what prior runs covered. Built as a whole line then
#   appended with a single `>>` (no partial lines). `lastRunAt` still advances on
#   success only; this log records both outcomes.
#
# INVOCATION
#   Runs from a FIXED workspace (Guard 4): cd "$OLLIE_WORKSPACE" (default
#   ~/Ollie/agent-workspace), then
#   "$CLAUDE_BIN" -p "<runbook>" --model "$CLAUDE_MODEL" --allowedTools "mcp__ollie,mcp__ollie__*"
#   CLAUDE_BIN defaults to `claude` (override to shim/stub it — the tests point it at a
#   script that just echoes its args). Output → ~/Ollie/agent-runs/<timestamp>.log;
#   logs older than 30 days are pruned. The op writer stamps agentId from
#   OLLIE_AGENT_ID, which we set to `claude-runner`.
#
# ONE-TIME PREREQS (C2 — external to this script; each is checked/diagnosed here)
#   1. `claude` logged in (subscription): run `claude` interactively once → /login.
#   2. `ollie` MCP registered USER-scope (visible from any cwd: `claude mcp list`).
#   3. The workspace trusted in ~/.claude.json — headless claude IGNORES a
#      workspace's permission allowlist when the cwd is untrusted, and -p mode
#      cannot show the trust dialog. Guard 4 verifies and prints the exact remedy.
#   The tool allowlist itself lives in $WORKSPACE/.claude/settings.local.json and
#   is self-written by Guard 4 if missing. See docs/agent-contract.md §9 and
#   mcp-server/README.md.
#
# ENV KNOBS
#   CLAUDE_BIN     claude binary / shim            (default: claude)
#   CLAUDE_MODEL   model passed to --model         (default: opus)
#   OLLIE_DIR      corpus + state + logs root      (default: $HOME/Ollie)
#   OLLIE_WORKSPACE fixed cwd for the claude session (default: $OLLIE_DIR/agent-workspace)
#   OLLIE_MCP_CONFIG deployed MCP config (default: $OLLIE_DIR/mcp/mcp-config.json;
#                  if present, passed via --strict-mcp-config so the run uses the
#                  DEPLOYED server copy — launchd cannot read the Desktop repo (TCC).
#                  If absent, falls back to the user-scope `claude mcp` registration.)
#   RUNBOOK        prompt file                      (default: <script dir>/ollie-runbook.md)
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

# ── Guard 4: fixed, trusted workspace for the headless session ───────────────
# launchd provides no useful cwd, and claude IGNORES a workspace's permission
# allowlist when the cwd is untrusted (-p cannot show the trust dialog) — the
# run would proceed with its tools silently denied. So: always cd into one
# dedicated workspace, self-heal its allowlist, and verify it is trusted in
# ~/.claude.json, stopping with the exact remedy if not.
WORKSPACE="${OLLIE_WORKSPACE:-$OLLIE_DIR/agent-workspace}"
mkdir -p "$WORKSPACE/.claude"
if [[ ! -f "$WORKSPACE/.claude/settings.local.json" ]]; then
  cat > "$WORKSPACE/.claude/settings.local.json" <<'SETTINGS'
{
  "permissions": {
    "allow": [
      "mcp__ollie",
      "mcp__ollie__search_notes",
      "mcp__ollie__list_notes",
      "mcp__ollie__recent_notes",
      "mcp__ollie__get_note",
      "mcp__ollie__corpus_stats",
      "mcp__ollie__get_instructions",
      "mcp__ollie__tag_vocabulary",
      "mcp__ollie__notes_by_tag",
      "mcp__ollie__read_memory",
      "mcp__ollie__list_views",
      "mcp__ollie__get_view",
      "mcp__ollie__tag_note",
      "mcp__ollie__untag_note",
      "mcp__ollie__append_memory",
      "mcp__ollie__retire_memory",
      "mcp__ollie__publish_view"
    ]
  }
}
SETTINGS
  log "wrote workspace allowlist: $WORKSPACE/.claude/settings.local.json"
fi

TRUSTED="unchecked"
if command -v python3 >/dev/null 2>&1; then
  TRUSTED="$(python3 - "$WORKSPACE" <<'PY' 2>/dev/null || echo unknown
import json, os, sys
ws = sys.argv[1]
try:
    cfg = json.load(open(os.path.expanduser("~/.claude.json")))
    entry = cfg.get("projects", {}).get(ws, {})
    print("yes" if entry.get("hasTrustDialogAccepted") else "no")
except Exception:
    print("unknown")
PY
)"
  if [[ "$TRUSTED" == "no" ]]; then
    log "STOP: workspace $WORKSPACE is NOT trusted — headless claude would ignore its tool allowlist."
    log "Fix once: in ~/.claude.json set projects[\"$WORKSPACE\"].hasTrustDialogAccepted = true"
    log "(or run claude interactively in that directory once and accept the trust dialog)."
    exit 1
  fi
fi
cd "$WORKSPACE" || { log "STOP: cannot cd into $WORKSPACE."; exit 1; }
log "workspace: $WORKSPACE (trusted=$TRUSTED)"

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

# Prefer the DEPLOYED MCP server (installed under ~/Ollie by
# install-agent-runner.sh) via --strict-mcp-config: a launchd-spawned claude
# cannot read the Desktop repo (TCC), so the user-scope registration pointing
# there would fail to spawn. Without a deployed config, fall back to it
# (dev/manual runs from a TCC-granted shell).
MCP_CONFIG="${OLLIE_MCP_CONFIG:-$OLLIE_DIR/mcp/mcp-config.json}"
MCP_ARGS=()
if [[ -f "$MCP_CONFIG" ]]; then
  MCP_ARGS=(--strict-mcp-config --mcp-config "$MCP_CONFIG")
  log "mcp: using deployed config $MCP_CONFIG"
else
  log "mcp: no deployed config at $MCP_CONFIG — relying on user-scope registration"
fi

log "invoking Claude (model=$CLAUDE_MODEL) — output → $LOG_FILE"
RUN_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
set +e
"$CLAUDE_BIN" -p "$PROMPT" \
  --model "$CLAUDE_MODEL" \
  --allowedTools "mcp__ollie,mcp__ollie__*" \
  ${MCP_ARGS[@]+"${MCP_ARGS[@]}"} \
  >> "$LOG_FILE" 2>&1
CLAUDE_RC=$?
RUN_FINISHED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# (The whole script runs under `set -uo pipefail`, never `-e`, so a non-zero
# claude rc doesn't abort — we branch on $CLAUDE_RC explicitly below.)

# ── Work log: append ONE line to runs.jsonl (contract §9) — SUCCESS AND FAILURE ──
# Advisory only (never access control): lets a later run — and the user — see what
# past runs covered (which `since`, how long, ok?), so the agent can decide what's
# already been looked at. Written with the same care as the state file: build the
# whole line first, then a SINGLE `>>` append (no partial lines if the process dies
# mid-write). `ok` is the boolean form of `rc == 0`; `logFile` is the log's basename
# so a reader can find it under agent-runs/ without an absolute path leaking. lastRunAt
# semantics are unchanged (advanced on success only, below) — this log records BOTH.
append_run_log() {
  local rc="$1" started="$2" finished="$3"
  local ok="false"; (( rc == 0 )) && ok="true"
  local runs_file="$LOG_DIR/runs.jsonl"
  # Assemble the line fully, THEN append once. Fields mirror contract §9. All values
  # here are shell-controlled (timestamps, our own ids, an int rc) — no user text — so
  # a hand-built JSON string is safe; jq is not required on the box.
  local line
  line="$(printf '{"runId":"%s","agentId":"%s","startedAt":"%s","finishedAt":"%s","since":"%s","corpusExportedAt":"%s","rc":%d,"ok":%s,"logFile":"%s"}' \
    "$RUN_TS" "$OLLIE_AGENT_ID" "$started" "$finished" "$SINCE_VALUE" "$EXPORTED_AT" "$rc" "$ok" "$RUN_TS.log")"
  printf '%s\n' "$line" >> "$runs_file"
}
append_run_log "$CLAUDE_RC" "$RUN_STARTED_AT" "$RUN_FINISHED_AT"

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
