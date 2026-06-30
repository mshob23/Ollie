#!/usr/bin/env bash
set -uo pipefail
#
# diagnose-sync.sh (F9) — one-shot, READ-ONLY sync-health dump for Ollie (macOS).
#
# The first step for ANY iCloud/CloudKit sync incident: it gathers, in one pass, the
# signals you'd otherwise chase across five places — the unified-log HNDIAG trail,
# the ~/Ollie corpus mirror + its freshness sidecar, the local SwiftData store, and
# the iCloud account + container id. It changes NOTHING (no writes, no deploys); it's
# safe to run anytime. See docs/cloudkit-sync-troubleshooting.md.
#
# Usage:  ./Scripts/diagnose-sync.sh
# Knob:   LOG_WINDOW (default 1h) — how far back to pull the unified log, e.g. 30m, 3h.

LOG_WINDOW="${LOG_WINDOW:-1h}"
SUBSYSTEM="com.mohammadshobaki.handheldnotes"
CONTAINER_ID="iCloud.com.mohammadshobaki.handheldnotes"
OLLIE_DIR="$HOME/Ollie"
JSONL="$OLLIE_DIR/ollie.jsonl"
META="$OLLIE_DIR/.ollie.meta.json"
STORE_GLOB="$HOME/Library/Application Support/default.store"

hr() { printf '\n=== %s ===\n' "$1"; }

# Resolve the bare `log` alias trap: the owner's shell aliases `log`, so we always
# call /usr/bin/log explicitly (a bare `log show` silently returns nothing).
LOG_BIN="/usr/bin/log"

echo "Ollie sync diagnostics — $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "(read-only; gathers signals, changes nothing)"

# ── 1. Unified-log HNDIAG / diagnostics tail ────────────────────────────────
# Diagnostics now go through os.Logger (Sources/.../Sync/Diag.swift), so they're
# visible to `log show` filtered by subsystem (NSLog was not). HNDIAG lines carry
# the corpus + sync-event breadcrumbs.
hr "Unified log (subsystem == $SUBSYSTEM, last $LOG_WINDOW)"
if [[ -x "$LOG_BIN" ]]; then
  LOG_OUT="$("$LOG_BIN" show --predicate "subsystem == \"$SUBSYSTEM\"" --last "$LOG_WINDOW" \
              --style compact 2>/dev/null)"
  # Drop log's own header/footer noise; show the tail of real event lines.
  EVENTS="$(printf '%s\n' "$LOG_OUT" | grep -v -e '^Filtering the log data' -e '^Timestamp' -e '^$' || true)"
  if [[ -n "$EVENTS" ]]; then
    printf '%s\n' "$EVENTS" | tail -40
    echo "... ($(printf '%s\n' "$EVENTS" | wc -l | tr -d ' ') matching lines in the last $LOG_WINDOW)"
  else
    echo "No subsystem log lines in the last $LOG_WINDOW."
    echo "(If the app hasn't run/logged recently this is expected; widen with LOG_WINDOW=6h.)"
  fi
else
  echo "WARN: $LOG_BIN not found — cannot read the unified log."
fi

# ── 2. ~/Ollie corpus mirror + freshness sidecar ────────────────────────────
hr "Corpus mirror (~/Ollie)"
if [[ -f "$JSONL" ]]; then
  JSONL_MTIME="$(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$JSONL")"
  JSONL_LINES="$(wc -l < "$JSONL" | tr -d ' ')"
  echo "ollie.jsonl: present  mtime=$JSONL_MTIME  lines=$JSONL_LINES"
else
  echo "ollie.jsonl: MISSING ($JSONL)"
fi

if [[ -f "$META" ]]; then
  META_MTIME="$(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$META")"
  echo ".ollie.meta.json: present  mtime=$META_MTIME"
  # The sidecar records exportedAt/noteCount/schemaVersion. Surface them raw, and
  # flag the common "stale corpus" symptom: jsonl newer than its recorded export.
  # exportedAt is an ISO8601 string (contains ':'), so capture the full quoted value.
  EXPORTED_AT="$(grep -o '"exportedAt"[[:space:]]*:[[:space:]]*"[^"]*"' "$META" 2>/dev/null | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//')"
  NOTE_COUNT="$(grep -o '"noteCount"[[:space:]]*:[[:space:]]*[0-9]*' "$META" 2>/dev/null | head -1 | grep -o '[0-9]*$')"
  SCHEMA_VER="$(grep -o '"schemaVersion"[[:space:]]*:[[:space:]]*[0-9]*' "$META" 2>/dev/null | head -1 | grep -o '[0-9]*$')"
  echo "  exportedAt=$EXPORTED_AT  noteCount=$NOTE_COUNT  schemaVersion=$SCHEMA_VER"
  if [[ -f "$JSONL" ]]; then
    # mtime epoch comparison: is the live jsonl newer than the sidecar (i.e. was
    # the corpus touched after the last recorded export)?
    JSONL_EPOCH="$(stat -f '%m' "$JSONL")"
    META_EPOCH="$(stat -f '%m' "$META")"
    if (( JSONL_EPOCH > META_EPOCH + 5 )); then
      echo "  ⚠️  ollie.jsonl is NEWER than its sidecar — corpus may be stale vs exportedAt."
    else
      echo "  corpus looks consistent with its sidecar (sidecar written with/after the jsonl)."
    fi
  fi
else
  echo ".ollie.meta.json: MISSING ($META) — no export has completed, or it was removed."
fi

# ── 3. Local SwiftData store ────────────────────────────────────────────────
# Mac app is non-sandboxed → store lives in ~/Library/Application Support/, not a
# container. default.store(+ -wal/-shm) is the on-disk SQLite that CloudKit mirrors.
hr "Local SwiftData store (~/Library/Application Support/default.store*)"
FOUND_STORE=0
for f in "$STORE_GLOB" "$STORE_GLOB-wal" "$STORE_GLOB-shm"; do
  if [[ -e "$f" ]]; then
    FOUND_STORE=1
    SZ="$(stat -f '%z' "$f")"
    MT="$(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$f")"
    echo "$(basename "$f"): present  size=${SZ}B  mtime=$MT"
  fi
done
[[ "$FOUND_STORE" == 0 ]] && echo "default.store*: MISSING — store not created (or was deleted to force a fresh rebuild)."

# ── 4. iCloud account + CloudKit container ──────────────────────────────────
hr "iCloud account + CloudKit container"
ICLOUD_ACCT="$(defaults read MobileMeAccounts 2>/dev/null | grep -i 'AccountID' | head -1 | sed 's/.*= *//; s/[";]//g' | xargs 2>/dev/null)"
if [[ -n "$ICLOUD_ACCT" ]]; then
  echo "iCloud AccountID: $ICLOUD_ACCT"
else
  echo "iCloud AccountID: NOT FOUND — is iCloud signed in? (defaults read MobileMeAccounts returned no AccountID)"
fi
echo "CloudKit container: $CONTAINER_ID"

hr "Next steps"
echo "If sync is broken, this dump narrows it fast. Most-common root cause: the"
echo "Production schema was never deployed — internal error 1011, writes rejected,"
echo "reads still served (looks half-working). Full runbook + the deploy fix:"
echo "  docs/cloudkit-sync-troubleshooting.md  (and RELEASE.md for the deploy step)"

exit 0
