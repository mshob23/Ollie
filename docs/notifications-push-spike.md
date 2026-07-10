# CloudKit push spike — a visible iPhone banner when the app is dead (M24b, design only)

*Design spike, 2026-07-10. Companion to [AGENT_LAYER_PLAN.md](../AGENT_LAYER_PLAN.md) §M24
and [docs/agent-contract.md](agent-contract.md) §7 "Reminder lines + arrival banners".
**Docs only** — no shipping code, no schema change, no Xcode. This memo decides go/no-go and
hands the implementing wave a shape and a step plan.*

## 1. The question, and why it's the only open half

M24a shipped the local delivery channel: the `inbox` view's `- [ ] remind YYYY-MM-DD HH:MM: …`
lines schedule **local** `UNNotificationRequest`s (identifier = the M7 `blockId`) on Mac and
iPhone, and the **Mac** posts a one-shot arrival banner when a new blockId appears in the latest
`inbox` revision (AGENT_LAYER_PLAN §M24a; contract §7 "Reminder lines + arrival banners"). That
covers everything **except one case**, and it's the case that matters most for a mailbox: the
agent runs on the home-node Mac, publishes a new `inbox` revision, CloudKit carries it to the
phone — but **the iPhone app is not running**, so nothing on the phone schedules a banner or fires
one. A local notification can only be scheduled by a process that's alive to see the revision
arrive. The remaining question, precisely:

> Can a `CKQuerySubscription` — or any no-vendor-server CloudKit mechanism — deliver a
> **user-visible** push on the iPhone when the agent publishes a new `inbox`-view revision, **while
> the iPhone app is not running**? The store is SwiftData over `NSPersistentCloudKitContainer`
> mirroring; view revisions are mirrored as `CD_ViewRevisionEntity` in the private database's Core
> Data zone (`com.apple.coredata.cloudkit.zone`, a *custom* zone).

This must hold the VISION line: **no vendor server, ever** (VISION.md §"Not a service"). The
existing sync path *already* rides Apple APNs to wake devices (docs/cloudkit-sync-troubleshooting.md
stage ④: "CloudKit pushes a silent APNs notification to other devices"), so a CloudKit-native
visible push adds **no new custody boundary** — it reuses the one APNs hop iCloud sync already
depends on. That's why this is worth a spike instead of an instant no: it's the *only* way to get an
instant phone banner without standing up a server we run.

## 2. Mechanism candidates

| # | Mechanism | Fires when… | App-dead visible banner? | Verdict |
|---|---|---|---|---|
| A | **`CKQuerySubscription`** on `CD_ViewRevisionEntity`, `firesOnRecordCreation`, predicate `CD_viewName == "inbox"`, `notificationInfo.alertBody` set | a matching record is created in the private DB | **Yes** — a visible push (alertBody set) is delivered by the system to Notification Center whether or not the app runs | **Recommended shape** (§4) |
| B | **`CKRecordZoneSubscription`** on `com.apple.coredata.cloudkit.zone` + a Notification Service Extension to filter/enrich | **any** change in the Core Data zone (every note, tag, memory, interaction, view — not just `inbox`) | Yes, but see below | Rejected — over-fires; extension can't cheaply filter |
| C | **Silent database push** (`shouldSendContentAvailable`), app wakes and posts a local banner | any zone change (this is what `NSPersistentCloudKitContainer` already uses internally) | **No** — silent pushes are **dropped when the app is force-quit**, and throttled/never-guaranteed in background | Rejected — fails the "app is dead" requirement by design |
| D | **Background App Refresh** (`BGAppRefreshTask`) polls for new revisions | opportunistic, system-scheduled | No — best-effort, minutes-to-hours latency, user-disableable; not an *arrival* signal at all | Rejected — unreliable, wrong latency class |
| E | **Do nothing** — accept M24a's gap | — | No | The honest fallback (§4) |

**Why B over-fires.** A `CKRecordZoneSubscription` fires on *any* modification in the zone — and the
Core Data mirroring zone holds **every** synced record type (`CD_NoteEntity`, `CD_TagEntity`,
`CD_MemoryEntity`, `CD_ViewRevisionEntity`, `CD_InteractionStateEntity`). Every tag the runner
writes, every seen-stamp, every note sync would raise a push. A zone subscription carries no
predicate, and its push names *the zone*, not the changed record — so filtering down to "a new
`inbox` revision" needs a **Notification Service Extension** that opens its own `CKDatabase` handle
and fetches changes on every zone write, inside a tight time/energy budget. A lot of wake-ups and
battery to approximate what a query predicate does server-side for free. Rejected on cost, not
impossibility.

**Why C is the trap.** This is the tempting one — "let Core Data's own push wake us, then post a
local banner" — and it is exactly what does **not** work. `NSPersistentCloudKitContainer` already
registers a `CKDatabaseSubscription` and receives *silent* (content-available) pushes to drive its
background import. But **a silent push is not delivered when the user has force-quit the app**
([QA1917](https://developer.apple.com/library/archive/qa/qa1917/_index.html) reason #4;
[cocoacasts](https://cocoacasts.com/five-reasons-cloudkit-notifications-are-not-arriving) reason
#1), and even when the app is merely backgrounded (not force-quit) content-available pushes are
throttled and **never guaranteed** ([Apple: Pushing background updates to your
App](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app);
[Medium: silent pushes are opportunities, not
guarantees](https://mohsinkhan845.medium.com/silent-push-notifications-in-ios-opportunities-not-guarantees-2f18f645b5d5)).
"App is dead" is the requirement; silent-wake-then-local-banner fails it categorically. Only a
**visible** push (alertBody set) is system-rendered without the app participating at all.

## 3. Decisive constraints

| Constraint | Finding | Source / status |
|---|---|---|
| **Query sub in a *custom* zone of the private DB** | Query subscriptions are supported in the **public and private** databases (NOT shared), and in the private DB they work in **both the default zone and custom zones**. The Core Data mirroring zone is a private-DB custom zone, so it is in scope. | Multiple secondary sources agree ([techotopia](https://www.techotopia.com/index.php/An_iOS_8_CloudKit_Subscription_Example), search-of-Apple-docs). **See UNVERIFIED-1** for the narrower CD_-record claim. |
| **Visible push while app not running** | A push with `alertBody` set is delivered by the system and shown in Notification Center **independent of app state**; the app need not be running or wake. Silent (`shouldSendContentAvailable`) pushes are the ones that die on force-quit. | [Hacking with Swift](https://www.hackingwithswift.com/read/33/8/delivering-notifications-with-cloudkit-push-messages-ckquerysubscription); [QA1917](https://developer.apple.com/library/archive/qa/qa1917/_index.html) #4 scopes force-quit loss to `shouldSendContentAvailable` |
| **Queryable index on the predicate field** | Any field named in a `CKQuerySubscription` predicate **must be marked queryable** in the schema, or saving the subscription in **Production** fails with `CKError.invalidArguments`. A visible push needs a queryable index on `CD_viewName` (the predicate field); a `firesOnRecordCreation` sub also implicitly needs `recordName` queryable. | [QA1917](https://developer.apple.com/library/archive/qa/qa1917/_index.html): *"saving subscriptions that refer to un-indexed fields in the production environment … will generate an Invalid Arguments error … checking the Query box under the Index column"*; forum: [`recordName` not queryable](https://developer.apple.com/forums/thread/79126) |
| **The Prod promote path (this repo)** | An index is a **schema change**. `cktool` **cannot deploy to Production** here — the working recipe is **Dev import → CloudKit Dashboard "Deploy Schema Changes to Production" → `Scripts/verify-prod-schema.sh`**. NB: adding a *Query index* on an existing field is **not a new field** — it does **not** change the 31-field count `verify-prod-schema.sh` checks — so the gate must be extended to assert the *index*, not just the field union. | RELEASE.md steps 1–2; [ollie-cloudkit-schema-deploy memory]; `Scripts/expected-ck-fields.txt` (31 fields, index-agnostic today) |
| **Coexistence with Core Data's own subscription** | `NSPersistentCloudKitContainer` registers its **own** `CKDatabaseSubscription` for the private mirror (fires silent pushes on `com.apple.coredata.cloudkit.zone` changes). A developer-added `CKQuerySubscription` is a **separate subscription with its own ID** and coexists — the two serve different purposes and do not collide, as long as our subscriptionID never clashes with Apple's. | [fatbobman](https://fatbobman.com/en/posts/coredatawithcloudkit-6/); [copyprogramming 2026 guide](https://copyprogramming.com/howto/how-to-subscribe-to-changes-for-a-public-database-in-cloudkit). **See UNVERIFIED-2** (Apple doesn't *document* a supported way to add subscriptions to the CD zone) |
| **Service-extension enrichment limits** | A Notification Service Extension can rewrite the alert **only** if the push carries `mutable-content: 1` and already has an `alertBody` (a purely-silent push is never handed to the extension). It runs in a tight time/memory budget; it *can* do network/CloudKit fetches but must finish fast or the OS shows the un-enriched body. It cannot conjure a banner where the payload had none. | [Medium: NSE real-world](https://medium.com/@_.sirsha/enhancing-ios-push-notifications-with-notification-service-extensions-overcoming-real-world-8b71186b54e1). Relevant only if we ever enrich (§6) |
| **Delivery is best-effort + coalesced** | CloudKit/APNs give **best-effort** delivery, coalesce bursts, and store only the latest per unreachable device. A visible arrival banner is a *nicety*, never a guarantee — the local schedule (M24a) and the unread dots remain the source of truth. | [cocoacasts](https://cocoacasts.com/five-reasons-cloudkit-notifications-are-not-arriving) #5; [QA1917](https://developer.apple.com/library/archive/qa/qa1917/_index.html) #5 |
| **Originating device gets no push** | CloudKit does **not** notify the device that made the change. The Mac publishes; only the *phone* (a different device) is pushed. Good — it means no self-banner on the Mac, and it shapes the test (§5): you need two devices. | [QA1917](https://developer.apple.com/library/archive/qa/qa1917/_index.html) #2 |

### Privacy — what plaintext rides the push

The only free-text a **static** `CKQuerySubscription` puts on the wire is `alertBody` (or a
localization key + args). We keep it **content-free**: a fixed **`Ollie: something new in your
inbox`**. The view's *content* — reminder text, note citations — **never enters the payload**. This
isn't a limitation we're tolerating; it's the design we'd choose anyway: the push is a doorbell, the
content is read in-app after the phone syncs the revision through the existing (already-trusted)
iCloud path. APNs already carries the silent sync pushes today, and a fixed doorbell string reveals
nothing an observer of "this account uses Ollie" doesn't already know. Enriching the banner to *say*
the reminder (§6) would put that text on a `mutable-content` payload — a real custody decision for
**then**, not now; the recommended shape keeps content out of the payload entirely.

## 4. Recommendation — **go-with-shape** (conditional on UNVERIFIED-1)

**Ship mechanism A** — a single `CKQuerySubscription` on `CD_ViewRevisionEntity`, gated on the one
verification below. Concretely:

- **Record type:** `CD_ViewRevisionEntity` (private DB, Core Data zone).
- **Options:** `.firesOnRecordCreation` (a new revision is always a *created* record — the layer is
  append-only; contract §0 — so creation-fires exactly matches "a new revision landed"; no update/
  delete cases to handle).
- **Predicate:** `CD_viewName == "inbox"` — so *only* the mailbox raises a banner, honoring the
  contract §7 discipline that **only `inbox` may raise banners**; every other view's freshness is
  the unread dots' job. This also means the runner republishing "Open loops" or "This week" stays
  silent, which is correct.
- **`notificationInfo`:** `alertBody = "Ollie: something new in your inbox"` (static),
  `soundName` default, `shouldSendContentAvailable = false` (we want the *visible* path, and want to
  dodge the force-quit-drop that afflicts silent pushes), `shouldBadge` optional. **No content.**
- **Deduping with M24a:** if the app *is* foreground/background-alive when the revision arrives, the
  local arrival-banner path (M24a) and this push can both fire. Suppress the push-driven banner in
  the foreground via the `UNUserNotificationCenterDelegate` (present nothing, or coalesce), and
  accept that a backgrounded-but-alive app might show one banner from each path in rare overlap —
  tolerable, and rare (the target case is *app dead*, where only the push fires).

**Go-with-shape, not an unconditional go**, because the whole recommendation rests on one fact this
spike could **not** fully verify from a primary source (UNVERIFIED-1 below): that a query-subscription
predicate reliably evaluates against the `CD_`-mangled records `NSPersistentCloudKitContainer`
writes into its managed zone. The general capability (query sub in a private-DB custom zone) is well
attested; the *specific* pairing with Core Data mirroring is not something I found Apple documenting,
and Apple's guidance treats the mirroring zone as theirs to manage. **Step 1 of §5 is a
throwaway spike that settles this before any real work.** If it fails, fall back to **E (do
nothing)** and revisit if/when the phone runs its own agent (VISION.md §"The Mac is a home node" —
the on-device future removes the "app is dead on the phone" problem entirely, because the phone
becomes the node). Do **not** fall back to B/C — B is a battery sink and C cannot meet the
requirement.

## 5. Step plan for the implementing wave

Numbered; the choreography around dev-vs-prod is the load-bearing part.

1. **Throwaway verification spike (settles UNVERIFIED-1 — do this FIRST, in Development, before
   writing product code).** In a scratch build, after the container is up, register a
   `CKQuerySubscription` on `CD_ViewRevisionEntity` / `firesOnRecordCreation` / predicate
   `CD_viewName == "inbox"` / `alertBody` set, on the **private** database. Then, on a **second**
   signed-in device (remember: [QA1917](https://developer.apple.com/library/archive/qa/qa1917/_index.html)
   #2 — the originating device is never pushed), create an `inbox` revision through the normal app
   path and **force-quit the receiving app**. A banner appearing on the dead app = **go**; nothing
   = **no-go, fall back to E**. This is hours, not days, and it's the gate for everything below.
2. **Subscription lifecycle (idempotent).** Create the subscription **once per install**, lazily,
   the first time the app has CloudKit active and notification authorization — keyed by a
   well-known `subscriptionID` (e.g. `ollie-inbox-revision-v1`) so re-creation is a no-op
   (`CKModifySubscriptionsOperation` with a fetch-or-create guard, or tolerate the "already exists"
   error). On **re-install**, the subscription is gone with the app's local state → re-created on
   first launch; the server-side sub for the old install is orphaned harmlessly (CloudKit prunes
   per-app). Never hard-code Apple's Core Data subscriptionID; use our own namespace so we can't
   collide with the container's `CKDatabaseSubscription` (constraint table, coexistence row).
3. **Request notification authorization** at a sensible moment (lazily, mirroring M24a's local-
   notification authorization — do not stack two prompts; share one authorization request path).
4. **Foreground/alive suppression.** Wire the `UNUserNotificationCenterDelegate` so that when the
   app is alive the push-driven banner is suppressed or coalesced with M24a's local path (§4
   dedup). Tap-through routes to the Views tab → `inbox` detail (same deep-link M24a's local banner
   already uses).
5. **The queryable index — deploy to Production without split-braining.** Mark `CD_viewName`
   queryable (and confirm `recordName` queryable) via the repo's Prod path: **Dev import →
   Dashboard "Deploy Schema Changes to Production" → `Scripts/verify-prod-schema.sh`**. Extend
   `verify-prod-schema.sh` / `expected-ck-fields.txt` to assert the *index* exists (today the file
   is a **field** union of 31 names and is index-blind — adding a Query index does **not** bump the
   count, so the gate would otherwise pass while the index is missing and Production would reject
   the subscription save with `invalidArguments`). Saving the subscription in Development
   auto-creates the index; **Production never does** — same class of miss as the June 2026 outage.
6. **Dev-vs-Prod test choreography — the Jul-8 landmine, stated explicitly.** A **dev-signed Mac
   app and a TestFlight phone are in DIFFERENT CloudKit environments** (docs/home-node.md
   §"Swapping in a new Mac app build": a plain `build_app.sh` build is **Development** CloudKit; the
   TestFlight phone is **Production** — every log stays green while **nothing crosses**). To test
   push end-to-end **without split-braining**:
   - **Phase A — Development, both ends same env.** Build the Mac app dev-signed **and** install the
     iPhone app via **Xcode (dev/debug) directly on the phone** — both now in **Development**
     CloudKit. Publish an `inbox` revision on the Mac (or via the runner), force-quit the phone app,
     watch for the banner. The queryable index auto-exists in Development, so no deploy needed for
     this phase. This is the real round-trip that proves the *mechanism*.
   - **Phase B — Production, after the index is deployed.** Deploy the index to Production (step 5),
     then swap the Mac to the **release-signed** build (`HC_SIGN=release BUILD_CONFIG=release
     ./Scripts/build_app.sh`; verify `codesign -d --entitlements` prints **Production** per
     docs/home-node.md) and ship a **TestFlight** iOS build (RELEASE.md §iOS — remember
     `processingState` must reach `VALID`, and attach to the Family & Friends group). Repeat the
     force-quit round-trip on the TestFlight phone against the release Mac. **Never mix a dev Mac
     with a TestFlight phone** for this test — that's the split-brain, and it looks exactly like
     "push doesn't work" while the real cause is env mismatch.
7. **Coexistence sanity.** After deploy, confirm ordinary sync still flows (the container's own
   `CKDatabaseSubscription` is untouched; ours is additive) — `Scripts/diagnose-sync.sh`, expect
   `err=F`, no `1011`.
8. **Rollback.** The subscription is server-side and self-contained: delete it with a
   `CKModifySubscriptionsOperation` (or let a version bump to `ollie-inbox-revision-v2` supersede
   it) and stop creating it in code. The queryable index can stay (an unused index is inert and
   harmless; removing it is itself a Prod deploy, so leave it). No `@Model`/golden-schema impact at
   any point — **this feature adds no SwiftData entity or field** (it's a subscription + an index on
   an existing field), so `SchemaGoldenTests` never moves. Ripping it out cannot brick sync.

## 6. Open questions

- **UNVERIFIED-1 (decisive).** Does a `CKQuerySubscription` predicate reliably evaluate against the
  `CD_`-prefixed records `NSPersistentCloudKitContainer` writes into `com.apple.coredata.cloudkit.zone`,
  and does `firesOnRecordCreation` fire per mirrored revision? The general capability (query sub in a
  private-DB custom zone) is attested by multiple secondary sources, but the **specific** pairing with
  Core Data mirroring is not Apple-documented and Apple treats the mirroring zone as its own. **Verify
  via step 1** (throwaway spike) before committing — this is the go/no-go pivot.
- **UNVERIFIED-2.** Is adding a developer-owned subscription to the Core Data mirroring zone a
  *supported* pattern, or merely one that happens to work today? Sources
  ([fatbobman](https://fatbobman.com/en/posts/coredatawithcloudkit-6/), the 2026 guide) show the two
  subscription types coexisting, but none cite Apple *sanctioning* custom subscriptions on the CD
  zone. Risk: a future OS could reserve the zone more strictly. **Mitigation:** the rollback (step 8)
  is trivial and the whole feature is a best-effort nicety, so the downside of it silently ceasing is
  "phone banners stop while the app is dead; local schedule + unread dots unaffected" — acceptable.
- **UNVERIFIED-3.** Exact **foreground-suppression** behavior when M24a's local arrival banner and
  this push race on a backgrounded-but-alive app — how often a double banner actually shows.
  Low-stakes; settle empirically during step 4, tune the delegate.
- **Enrichment (deferred, not for this wave).** If the doorbell should ever *say the reminder*, a
  `mutable-content` push + Notification Service Extension could fetch the `inbox` latest revision and
  rewrite `alertBody`. That's a new custody decision (content-bearing payload, §3 privacy) and a new
  target to maintain — out of scope; named here so the reservation is explicit. The recommended shape
  keeps content out of the payload.
- **Throttling reality.** Best-effort + coalesced delivery ([QA1917](https://developer.apple.com/library/archive/qa/qa1917/_index.html)
  #5) means a burst of `inbox` republishes may collapse to one banner. That's fine for a doorbell,
  but worth confirming the runner doesn't republish `inbox` needlessly (the no-op-republish rule in
  the runbook already guards this).
