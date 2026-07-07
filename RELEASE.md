# Release checklist (Ollie / Mac)

The single most expensive past incident was a multi-hour **CloudKit sync outage** whose
root cause was mundane: a shipped build's SwiftData `@Model` had drifted, but the manual
**"Deploy Schema Changes to Production"** step in the CloudKit Dashboard was never run.
CloudKit **Development** auto-creates record types/fields/indexes; **Production never
does**, so the live build rejected every write with internal error `1011` (reads still
worked, so it looked half-functional). See `docs/cloudkit-sync-troubleshooting.md` §1.

> ## ⚠️ Two "declared done but the endpoint was never verified" traps (learned the hard way, Jul 2026)
>
> **1. A shared-`HandheldNotesCore` change means rebuild AND reinstall BOTH apps before
> testing.** The Mac app (`/Applications/Ollie.app`) and the iOS app link the same Core.
> Fixing a Core bug and then testing against a **stale installed binary** shows the bug
> "still there" and sends you diagnosing a phantom platform-specific issue (this cost an hour
> on the M7 checkbox hang — the Mac was running a binary built *before* the fix). After any
> Core change, rebuild the Mac app (steps below) *and* ship a new iOS build (§iOS), then test.
> Confirm the running binary post-dates the fix:
> `stat -f %Sm /Applications/Ollie.app/Contents/MacOS/HandheldNotes` newer than
> `git show -s --format=%ci <fix-sha>`.
>
> **2. `altool` "UPLOAD SUCCEEDED" is NOT "installable on a phone."** It only means the bytes
> transferred. "Shipped" = the build reaches **processingState VALID** (App Store Connect →
> app → TestFlight → Build Uploads = *Complete*), never the upload exit code. Three builds
> "uploaded successfully" then silently **failed processing** (ITMS-90683) before this was
> caught. Failed processing still **burns the build number**, so always bump. §iOS shows how
> to poll processing to a terminal state.

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

## iOS / TestFlight release {#ios}

The iPhone + embedded watch app live in the sibling repo `../HandheldNotesiOS` (XcodeGen).
Same Production-schema rule applies: **a shared-Core `@Model`/field change must be deployed
to CloudKit Production before a TestFlight build ships** (the golden gate in this repo is the
canary; deploy per step 2 above). Then:

1. **Bump the build number.** `project.yml` → `CURRENT_PROJECT_VERSION` on **both** the iOS
   and watch targets (keep them equal). Failed uploads still consume the number — always go
   up, never reuse. `xcodegen generate` after editing.
2. **Archive → export → upload** (Release config; never pass `-sdk` — it drags the watch
   target onto the iOS SDK):
   ```bash
   xcodebuild archive -project HandheldNotesiOS.xcodeproj -scheme HandheldNotesiOS \
     -configuration Release -destination 'generic/platform=iOS' \
     -archivePath /tmp/Ollie-ios.xcarchive -allowProvisioningUpdates DEVELOPMENT_TEAM=2J5S7H2LTB
   xcodebuild -exportArchive -archivePath /tmp/Ollie-ios.xcarchive \
     -exportPath <out> -exportOptionsPlist <plist> -allowProvisioningUpdates   # method: app-store-connect
   xcrun altool --upload-app -f <out>/HandheldNotesiOS.ipa -t ios \
     --apiKey V2S345C7SB --apiIssuer 5ec716ff-5d65-4f02-87f7-66a3825024eb
   ```
3. **VERIFY PROCESSING — the actual finish line.** `altool` success ≠ done. Poll App Store
   Connect until the build reaches **`VALID`** (or read the rejection):
   - UI: App Store Connect → the app → **TestFlight → Build Uploads**; status must be
     *Complete*, not *Failed*.
   - API: `GET https://api.appstoreconnect.apple.com/v1/builds?filter[app]=6785293567&sort=-uploadedDate`
     with an ES256 JWT (kid `V2S345C7SB`, iss `5ec716ff-5d65-4f02-87f7-66a3825024eb`, aud
     `appstoreconnect-v1`); watch `attributes.processingState` go `PROCESSING → VALID`.
   Only after `VALID` is the build installable — tell the user to update *then*.
4. **`NSCameraUsageDescription` is required even though Ollie has no camera** (ITMS-90683):
   shared Core's `MicCaptureService` references `AVCaptureDevice` (audio-only) and the symbol
   reference alone trips the App Store scanner. The string is in `project.yml`. As of Jul 2026
   `MicCaptureService` IS `#if os(macOS)`-guarded out of the iOS binary (C1, shipped in
   build 32 — which still carried the string), so the string should now be removable: delete
   it only after a build **later than 32** reaches `VALID` without it.

## After an incident

`Scripts/diagnose-sync.sh` is the first step for any sync incident — it dumps the
unified-log `HNDIAG` tail, the `~/Ollie/ollie.jsonl` corpus freshness, the local store
presence, and the iCloud account + container id in one shot. See
`docs/cloudkit-sync-troubleshooting.md`.

**App hang / beachball / iOS `0x8BADF00D` watchdog kill after a Views/UI change:** suspect an
`@Observable` model mutated *during* SwiftUI render (see the M7 checkbox loop —
`docs/views-v2-interaction-spec.md` and the `resolved()`/`@ObservationIgnored` fix). Unit tests
can't catch it; diagnose with `sample <pid>` (Mac) / `idevicecrashreport` (iOS), and judge a
frame by its **sample weight** (N/N = loop; 1/739 = a benign single render).
