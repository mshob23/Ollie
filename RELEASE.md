# Release checklist (Ollie / Mac)

The single most expensive past incident was a multi-hour **CloudKit sync outage** whose
root cause was mundane: a shipped build's SwiftData `@Model` had drifted, but the manual
**"Deploy Schema Changes to Production"** step in the CloudKit Dashboard was never run.
CloudKit **Development** auto-creates record types/fields/indexes; **Production never
does**, so the live build rejected every write with internal error `1011` (reads still
worked, so it looked half-functional). See `docs/cloudkit-sync-troubleshooting.md` §1.

This checklist exists so that mistake **cannot ship silently**. Two guardrails enforce it:

- **F5 — golden schema gate (`Tests/HandheldNotesCoreTests/SchemaGoldenTests.swift`).**
  Hashes the live `Schema([NoteEntity.self])` and compares to a committed golden. Any
  `NoteEntity` change fails the test with regeneration + deploy instructions.
- **Release-time ack (`Scripts/build_app.sh`).** The Developer-ID / RELEASE signing path
  refuses to run unless `SCHEMA_DEPLOYED=1` is set, forcing a human to confirm the
  Production deploy happened. **Dev builds are unaffected.**

## Steps

1. **Run the tests — must be green, including the golden gate.**
   ```bash
   swift test
   ```
   If `SchemaGoldenTests` fails, the schema changed. Do BOTH of these before continuing:
   - **Regenerate the golden.** The failure prints the new hash; set it in
     `SchemaGoldenTests.goldenHash` **and** in
     `Tests/HandheldNotesCoreTests/Resources/schema.golden`, then re-run `swift test`.
   - **Plan the Production deploy** (next step) — a new golden means the record type /
     fields / indexes changed and Production needs the update.

2. **Deploy the schema to CloudKit Production.**
   CloudKit Dashboard → container **`iCloud.com.mohammadshobaki.handheldnotes`** →
   **Deploy Schema Changes… → Deploy to Production.** A `– Modified` badge on Record
   Types / Indexes in Development means there are undeployed changes. Verify the deploy
   completes (all 5 sync indexes for `CD_NoteEntity` present in Production).

3. **Set the ack and build/sign the release.**
   ```bash
   SCHEMA_DEPLOYED=1 ./Scripts/package_release.sh
   ```
   (`package_release.sh` invokes `build_app.sh` with `HC_SIGN=release`; the env var
   propagates, so set `SCHEMA_DEPLOYED=1` on the outer command.) Without the ack the
   build aborts with the deploy reminder. This produces the Developer-ID-signed,
   **notarized** `dist/Ollie.dmg`.

4. **Smoke-test the signed build** before publishing: launch it, capture a note on the
   Mac, confirm it round-trips to another signed-in device (or run
   `Scripts/diagnose-sync.sh` and confirm a healthy export — `err=F`, no `1011`).

## After an incident

`Scripts/diagnose-sync.sh` is the first step for any sync incident — it dumps the
unified-log `HNDIAG` tail, the `~/Ollie/ollie.jsonl` corpus freshness, the local store
presence, and the iCloud account + container id in one shot. See
`docs/cloudkit-sync-troubleshooting.md`.
