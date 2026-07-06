import Foundation
import Observation

// MARK: - ViewInteractionModel
//
// The shared write-path brain behind a tappable checklist (Views v2, spec §4). One
// instance backs one *displayed* view (a `viewName` + the revision the reader is
// looking at); both panes — the Mac `ViewsPane` and the iPhone Views detail — own one
// and wire it into `MarkdownLite`'s `ChecklistHook` (spec §5). `MarkdownLite` stays
// dumb; ALL the debounce / coalesce / diff / one-save-per-settle logic lives here.
//
// **Three-layer precedence (spec §1), top wins:**
//   1. Pending (optimistic, in-memory) — flipped instantly on every tap; zero writes.
//   2. Overlay (durable, synced `InteractionStateEntity`) — **iff its `updatedAt` is
//      newer than the displayed revision's `createdAt`**. The *iff* is load-bearing:
//      **a newer revision supersedes older interaction state — publishing is the
//      acknowledgment.**
//   3. Body default — the `- [ ]` / `- [x]` state baked into the revision markdown.
//
// **Write path (spec §4):** a tap flips `pending` and restarts a single settle timer
// (600 ms, cancel-and-restart). On settle — or a boundary (`.onDisappear`,
// backgrounding, switching views) via `commitNow()` — each pending entry is diffed
// against its currently-committed value (layers 2→3, *without* pending); entries where
// `new == committed` are skipped (a full round-trip on→off writes nothing); the
// survivors are upserted through `AgentLayerStore` with **one** `ModelContext` save for
// the whole batch; then `pending` clears. Net: tap-tap-tap-tap → at most one durable,
// diffed, atomic write of the resting state.
//
// Interaction state is user-authored / app-written only — there is no `AgentOp` case
// and no inbox op (spec §6, contract §0); the model writes exclusively via
// `AgentLayerStore.setInteractions(_:)`.

/// The `@MainActor @Observable` interaction brain for one displayed view (spec §4).
/// Construct it with the view's store, name, the revision being displayed, and the
/// surface (`"mac"` | `"ios"`). Feed `resolved`/`toggle` into a ``ChecklistHook`` and
/// call ``commitNow()`` at every navigation boundary.
@MainActor
@Observable
public final class ViewInteractionModel {

    /// The default settle interval — spec §4's **600 ms** cancel-and-restart debounce.
    /// Overridable via the initializer (tests inject `0` so a settle can be awaited
    /// deterministically instead of sleeping 600 ms).
    public static let defaultSettleInterval: TimeInterval = 0.6

    private let store: AgentLayerStore
    private let viewName: String
    /// Provenance: the revision displayed at toggle time. Its `createdAt` is the
    /// supersession boundary (layer 2's *iff*) and its `id` stamps `revisionId`.
    private let revisionId: UUID
    private let revisionCreatedAt: Date
    private let surface: String
    private let settleInterval: TimeInterval

    /// The optimistic in-memory layer (spec §1 layer 1): `blockId → checked`. A tap
    /// writes here instantly; the settle drains it. Never survives the pane.
    public private(set) var pending: [String: Bool] = [:]

    /// The classifier-captured text last seen for a toggled block (the snapshot stored
    /// as `blockText`). Recorded on `toggle` so the commit can denormalize it.
    private var pendingText: [String: String] = [:]

    /// The body default (layer 3) last observed for a block, captured from `resolved`
    /// on every render. The commit needs it to compute the currently-committed value
    /// for a block whose overlay doesn't apply (superseded or absent).
    private var bodyDefaults: [String: Bool] = [:]

    /// The single settle task (spec §4): a tap cancels the in-flight one and starts a
    /// fresh 600 ms timer, so a burst of taps collapses to one commit at rest.
    private var settleTask: Task<Void, Never>?

    /// Optional hook fired **after** a commit actually writes (skipped when the commit
    /// was a no-op). The panes use it to re-project / re-export so a toggle propagates
    /// promptly — the model itself never reaches into `AppModel`.
    private let onCommit: (() -> Void)?

    /// Test-only counter of durable saves this model has performed (a commit that wrote
    /// ≥ 1 record). Round-trips and empty settles do NOT increment it — the property the
    /// spec's "N toggles → one save", "round-trip → zero saves" tests assert on.
    public private(set) var saveCount = 0

    /// - Parameters:
    ///   - store: the write choke point (spec §3). The model reads the overlay and
    ///     writes the settled batch through it — never touches `ModelContext` directly.
    ///   - viewName: the displayed view's exact name (the join key, with `blockId`).
    ///   - revision: the revision the reader is looking at — its `createdAt` is the
    ///     supersession boundary and its `id` the stamped provenance.
    ///   - surface: `"mac"` | `"ios"` — provenance for the written record.
    ///   - settleInterval: the debounce window. **Defaults to 600 ms**
    ///     (``defaultSettleInterval``); tests inject a small/zero value.
    ///   - onCommit: called after a commit that wrote at least one record.
    public init(
        store: AgentLayerStore,
        viewName: String,
        revision: AgentViewRevision,
        surface: String,
        settleInterval: TimeInterval = ViewInteractionModel.defaultSettleInterval,
        onCommit: (() -> Void)? = nil
    ) {
        self.store = store
        self.viewName = viewName
        self.revisionId = revision.id
        self.revisionCreatedAt = revision.createdAt
        self.surface = surface
        self.settleInterval = settleInterval
        self.onCommit = onCommit
    }

    // MARK: - Read (three-layer resolution, spec §1)

    /// The rendered checked-state for a checklist block, resolving the three layers
    /// (spec §1): **pending** (if the block has an optimistic value) → **overlay**
    /// (the durable record, *iff* its `updatedAt` is newer than the displayed
    /// revision's `createdAt`) → **body default** (`bodyChecked`, the state baked into
    /// the revision markdown). Called by the renderer on every layout; it also records
    /// `bodyChecked` so the commit can compute the committed value for this block.
    public func resolved(blockId: String, bodyChecked: Bool) -> Bool {
        bodyDefaults[blockId] = bodyChecked   // remember layer 3 for the commit diff
        if let optimistic = pending[blockId] { return optimistic }
        return committedValue(blockId: blockId, bodyChecked: bodyChecked)
    }

    // MARK: - Write (tap → debounce → settle)

    /// Handle a checklist tap (spec §4 step 1): flip the block's **pending** value
    /// (optimistic; the UI re-reads `resolved(...)` for instant feedback with zero
    /// writes), snapshot its `text` for the eventual `blockText`, and restart the
    /// single 600 ms settle timer. A burst of taps thus collapses to one commit at rest.
    public func toggle(blockId: String, blockText: String) {
        // Flip against the currently-resolved value so tapping an as-yet-unpended box
        // moves it off its committed/body state, not off `false`.
        let current = pending[blockId] ?? committedValue(blockId: blockId,
                                                          bodyChecked: bodyDefaults[blockId] ?? false)
        pending[blockId] = !current
        pendingText[blockId] = blockText
        restartSettleTimer()
    }

    /// Force the settled end-state to persist **now** (spec §4 step 2): the boundary
    /// commit the panes call on `.onDisappear`, on backgrounding
    /// (`scenePhase != .active`), and when switching the displayed view. Cancels any
    /// pending settle timer and commits synchronously. Idempotent — a second call with
    /// nothing pending is a no-op.
    public func commitNow() {
        settleTask?.cancel()
        settleTask = nil
        commit()
    }

    // MARK: - Test seam

    /// Await the in-flight settle task, if any — a deterministic way for tests to let
    /// the injected (zero-interval) debounce fire and drive `commit()` without a
    /// wall-clock sleep. No-op when nothing is pending a settle. Not for app use (the
    /// panes drive settles via the timer and `commitNow()` boundaries).
    func awaitSettleForTesting() async {
        await settleTask?.value
    }

    // MARK: - Internals

    private func restartSettleTimer() {
        settleTask?.cancel()
        let interval = settleInterval
        settleTask = Task { [weak self] in
            // A zero/small interval still yields to the runloop first, so a test can
            // `await` the task and observe the commit deterministically without a
            // wall-clock 600 ms sleep.
            if interval > 0 {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            } else {
                await Task.yield()
            }
            guard let self, !Task.isCancelled else { return }
            self.commit()
        }
    }

    /// The commit body (spec §4 step 3): diff every pending entry against its
    /// currently-committed value (layers 2→3, *without* pending); drop entries that
    /// round-tripped back to committed; upsert the survivors through
    /// ``AgentLayerStore/setInteractions(_:)`` (one save for the batch); clear
    /// `pending`. Writes nothing — and does not bump ``saveCount`` or fire
    /// ``onCommit`` — when no entry actually changed.
    private func commit() {
        settleTask = nil
        guard !pending.isEmpty else { return }

        let now = Date()
        var survivors: [ViewInteraction] = []
        for (blockId, newValue) in pending {
            let committed = committedValue(blockId: blockId, bodyChecked: bodyDefaults[blockId] ?? false)
            // Skip a full round-trip: the resting value equals what's already committed.
            if newValue == committed { continue }
            survivors.append(ViewInteraction(
                viewName: viewName,
                blockId: blockId,
                blockText: pendingText[blockId] ?? "",
                value: newValue ? "true" : "false",
                revisionId: revisionId,
                surface: surface,
                updatedAt: now))
        }

        pending.removeAll()
        pendingText.removeAll()

        guard !survivors.isEmpty else { return }   // nothing changed → zero writes
        store.setInteractions(survivors)           // one ModelContext save for the batch
        saveCount += 1
        onCommit?()
    }

    /// The committed value for a block — spec §1 layers **2→3, without pending**: the
    /// overlay record's boolean **iff** its `updatedAt` is newer than the displayed
    /// revision's `createdAt` (a newer revision supersedes older interaction state);
    /// otherwise the `bodyChecked` default. Read fresh from the store so the commit
    /// diffs against the authoritative current state.
    private func committedValue(blockId: String, bodyChecked: Bool) -> Bool {
        if let overlay = overlay(blockId: blockId),
           overlay.updatedAt > revisionCreatedAt {
            return overlay.boolValue
        }
        return bodyChecked
    }

    /// The collapsed overlay record for a block (latest `updatedAt` wins on duplicate
    /// keys), or nil if the user hasn't toggled it. Reads the store's collapsed view.
    private func overlay(blockId: String) -> ViewInteraction? {
        store.interactions(viewName: viewName).first { $0.blockId == blockId }
    }
}
