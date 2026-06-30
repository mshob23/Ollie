# CloudKit sync troubleshooting (Ollie)

A runbook for when notes stop syncing between devices. Written after a multi-hour
June 2026 outage where Mac↔iPhone sync was dead in **both** directions. The lesson:
**don't guess — trace the data path hop by hop and get visibility at each hop.**

> 🩺 **First step for ANY sync incident: run `Scripts/diagnose-sync.sh`.** It's a
> read-only, one-shot health dump that gathers the signals below in a single pass —
> the unified-log `HNDIAG` tail (`subsystem == "com.mohammadshobaki.handheldnotes"`,
> now visible because diagnostics moved to `os.Logger`), the `~/Ollie/ollie.jsonl`
> corpus + its `.ollie.meta.json` freshness sidecar (is the corpus stale vs
> `exportedAt`?), the local `~/Library/Application Support/default.store*`, and the
> iCloud account + container id. Start there, *then* trace the hops below.

## The full path a note travels (Mac → phone)

| # | Stage | Where the data sits | How to SEE it | 
|---|---|---|---|
| ① | App saves the note | Mac `~/Library/Application Support/default.store` → table `ZNOTEENTITY` | `sqlite3 default.store 'SELECT count(*) FROM ZNOTEENTITY'` |
| ② | `NSPersistentCloudKitContainer` builds a `CKRecord` from the change (export side) | persistent history + mirror tables `ANSCKEVENT`, `ANSCKMETADATAENTRY` | `log show --predicate 'subsystem=="com.apple.coredata"'`; `ANSCKEVENT` rows |
| ③ | `cloudd` uploads to Apple | your **private** CloudKit DB, zone `com.apple.coredata.cloudkit.zone`, **Production** | `/usr/bin/log show --predicate 'process=="cloudd"'` → `CKDModifyRecords…err=F`; **CloudKit Dashboard** records |
| ④ | CloudKit pushes a silent APNs notification to other devices | Apple → APNs → device | Dashboard → Subscriptions; (a cold launch skips push and fetches directly) |
| ⑤ | Phone fetches + imports + shows it | phone local store → UI | **`idevicesyslog`** over USB; the phone UI |

> ⚠️ **Use `/usr/bin/log`, not `log`.** The owner's shell aliases `log`, so a bare `log show`
> silently returns nothing and hides every clue.

## Getting eyes on the phone (the usual blind spot)

```bash
brew install libimobiledevice           # one time
idevice_id -l                           # confirm the phone is connected + trusted (USB)
idevicesyslog -u <udid> > /tmp/phone.log 2>&1 &   # stream; then open the app on the phone
grep -iE 'HandheldNotesiOS|cloudd|CoreData|CKError' /tmp/phone.log
```
Healthy export looks like: `PFCloudKitExporter … Modify records finished` + `CKDModifyRecords…err=F` + `error (null)`.

## What broke it — one root cause, and the red herrings

**In this incident there was exactly ONE root cause: #1 below (the undeployed Production schema).**
#2 and #3 are real CloudKit failure modes worth knowing — but we did **not** actually hit #2 here
(no zone was deleted; the corpus was cleaned by swipe-deleting *records*), and #3 was a *trigger*,
not a fix (sync resumes on its own once #1 is deployed). Don't let them distract from #1.

### 1. Production schema not deployed  ← the real root cause
CloudKit **Development** auto-creates record types/fields/indexes; **Production** (TestFlight/App
Store) **never** does. If the schema (`CD_NoteEntity`, its fields, and its **5 sync indexes**) only
exists in Development, Production **rejects every write** with internal error **`1011`**
(`NSCloudKitMirroringDelegate … Never successfully initialized`) while still serving reads — so it
looks half-working.

**Fix:** CloudKit Dashboard → the container → **Deploy Schema Changes… → Deploy to Production.**
A `– Modified` badge by Record Types / Indexes in the Development env means there are undeployed
changes. **Make this a release step whenever the `@Model` changes.**

### 2. A "wedged" store (deleted zone)
The **old** `--wipe-all-notes` deleted the whole CloudKit *zone*. Every other device's local sync
bookkeeping still points at that now-dead zone (a stale change-token), so import/export throw
`CKError 2` partial-failures forever — it can't self-heal. (Like a GPS routing to a demolished
building.)

**Recover an already-wedged device:** delete the local store so the container rebuilds fresh — Mac:
`rm ~/Library/Application\ Support/default.store*`; iOS: delete + reinstall the app. **Back up first**
(`sqlite3 … json_object(...)`).

**Fixed (Jun 2026):** `AppModel.deleteAllNotes()` now deletes the *records*, not the zone — each
`modelContext.delete` exports as an ordinary CloudKit record deletion (tombstone) that peers import
and self-heal from. It also writes a timestamped JSONL backup to `~/Ollie/backups/` before wiping
(the live `~/Ollie/ollie.jsonl` mirror can't serve as the backup — the post-wipe reload rewrites it
empty). So a fresh wipe no longer wedges peers; the recovery above is only for devices a *pre-fix*
build already wedged.

### 3. Backed-off mirror
After many failures the container backs off into a long retry sleep and stays asleep even after the
fix. **Fix:** **cold-launch** the app (force-quit + reopen) to force a fresh fetch. Both devices
needed this.

## Gotchas / non-obvious truths
- **`ANSCKEXPORTEDOBJECT` count is NOT a reliable "is it synced" signal** — it read 0 while notes
  were provably in the cloud. Truth = an end-to-end round-trip: wipe the local store and watch it
  re-download from the cloud.
- Mac app is **non-sandboxed** → its store is in `~/Library/Application Support/`, not a container.
- The container config is correct (`cloudKitDatabase: .private(...)` in `NotesDataStore.swift`) —
  history + remote-change notifications are implied by CloudKit mirroring; nothing extra to set.
