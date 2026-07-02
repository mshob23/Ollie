#!/usr/bin/env bash
set -euo pipefail
#
# verify-prod-schema.sh — machine-check that the PRODUCTION CloudKit schema
# contains every field the app can write (Scripts/expected-ck-fields.txt).
#
# WHY: two production outages (June + July 2026) were the same disease — a field
# missing from the Production schema silently wedging every export (the July one
# via a LAZILY-materialized `_ckAsset` field the app-side golden-schema test
# cannot see). This replaces the `SCHEMA_DEPLOYED=1` honor pledge with a real
# check against Apple's server.
#
# AUTH (one-time): cktool needs a CloudKit MANAGEMENT token —
#   CloudKit Dashboard ▸ (account menu) ▸ Tokens & Keys ▸ Management Tokens ▸ +
#   then:  xcrun cktool save-token   (paste the token; stored in the keychain)
#
# EXIT CODES:  0 = schema verified   1 = FIELDS MISSING (do not ship)
#              2 = cktool not configured (caller may fall back to the manual ack)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEAM_ID="2J5S7H2LTB"
CONTAINER_ID="iCloud.com.mohammadshobaki.handheldnotes"
EXPECTED="$SCRIPT_DIR/expected-ck-fields.txt"

SCHEMA_FILE="$(mktemp -t ollie-prod-schema)"
trap 'rm -f "$SCHEMA_FILE"' EXIT

if ! xcrun cktool export-schema \
        --team-id "$TEAM_ID" \
        --container-id "$CONTAINER_ID" \
        --environment production \
        --output-file "$SCHEMA_FILE" 2>/dev/null; then
    echo "verify-prod-schema: SKIPPED — cktool has no management token." >&2
    echo "  One-time setup: CloudKit Dashboard ▸ Tokens & Keys ▸ Management Tokens," >&2
    echo "  then: xcrun cktool save-token" >&2
    exit 2
fi

missing=0
while IFS= read -r field; do
    [[ -z "$field" || "$field" == \#* ]] && continue
    if ! grep -q "$field" "$SCHEMA_FILE"; then
        echo "MISSING from the Production CloudKit schema: $field" >&2
        missing=1
    fi
done < "$EXPECTED"

if [[ "$missing" == 1 ]]; then
    echo "" >&2
    echo "Production schema is INCOMPLETE — exports will wedge for any record that" >&2
    echo "touches a missing field. Fix: CloudKit Dashboard ▸ Development ▸" >&2
    echo "CD_NoteEntity ▸ add the field(s) ▸ Deploy Schema Changes to Production." >&2
    exit 1
fi

echo "verify-prod-schema: OK — all $(grep -cvE '^\s*(#|$)' "$EXPECTED") expected fields present in Production."
exit 0
