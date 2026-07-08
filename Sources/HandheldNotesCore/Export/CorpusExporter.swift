import Foundation

/// Rung 3 of the exposability ladder: mirror the note corpus **and the agent layer**
/// to plain, user-owned files so ANY tool — Obsidian, a script, an LLM, the Ollie MCP
/// server — can read them. The shapes, all from the same export pass:
///   • `ollie.jsonl` — the whole corpus, one JSON record per line. Machine/LLM fuel;
///     this is what the MCP server reads. Rewritten wholesale each export (cheap),
///     so it's always authoritative.
///   • `notes/<id>.md` — one Markdown file per note (frontmatter + body) for humans
///     and Obsidian.
///   • `tags.jsonl` / `memory.jsonl` / `views.jsonl` / `instructions.md` /
///     `interactions.jsonl` — the agent layer (contract §5, Views v2 spec §6). Written
///     from the `LayerSnapshot` the caller passes; `interactions.jsonl` is orphan-pruned
///     first (deleted-view + superseded-stale records — spec §6).
///
/// **The export gate runs here.** Notes (and their tags) are routed through
/// ``CorpusGate`` so restricted content — a note marked `isRestricted` and everything
/// derived from it — never lands under `~/Ollie/` (contract §0 "restriction is
/// contagious", §5). Views and memory export in full (they can't carry a restricted
/// transcript; see `CorpusGate`).
///
/// Best-effort + non-fatal; runs off the main actor (the snapshots are `[Note]` /
/// `LayerSnapshot`, both `Sendable`). **macOS-only for now** — the Mac holds the full
/// CloudKit-synced corpus and is where the MCP server runs; iOS export (into the
/// app's Files container) is a backlog item.
public enum CorpusExporter {

    /// The agent-layer data one export pass writes alongside the notes — a single
    /// `Sendable` value the caller (`AppModel.reloadNotes`) snapshots on the main actor
    /// and hands to the detached export task. Empty by default so the corpus-only call
    /// sites (a genuine wipe, `backup`) don't have to synthesize it.
    public struct LayerSnapshot: Sendable {
        public var tags: [AgentTag]
        public var memory: [AgentMemory]
        public var viewRevisions: [AgentViewRevision]
        public var instructions: String
        /// The live interaction state across all views (Views v2 spec §6) — one record
        /// per `(viewName, blockId)`, exported to `interactions.jsonl`. Empty on the
        /// corpus-only / wipe / backup paths.
        public var interactions: [ViewInteraction]

        public init(
            tags: [AgentTag] = [],
            memory: [AgentMemory] = [],
            viewRevisions: [AgentViewRevision] = [],
            instructions: String = "",
            interactions: [ViewInteraction] = []
        ) {
            self.tags = tags
            self.memory = memory
            self.viewRevisions = viewRevisions
            self.instructions = instructions
            self.interactions = interactions
        }

        /// The empty layer — nothing to write (used by the wipe / backup paths).
        public static let empty = LayerSnapshot()
    }

    /// Test-only override for the export root. When non-nil, `exportDirectory`
    /// returns this instead of `~/Ollie`, so tests can redirect the export at a temp
    /// dir (to assert success) or an unwritable path (to assert failure handling)
    /// without ever touching the real corpus. `nonisolated(unsafe)` is acceptable
    /// because it's set once at the top of a test, before the code under test runs,
    /// and never mutated concurrently.
    nonisolated(unsafe) public static var exportDirectoryOverride: URL?

    /// The export root: `~/Ollie` (or `exportDirectoryOverride` in tests). Visible
    /// and easy to point Obsidian / the MCP server at.
    ///
    /// The base dir is platform-aware: `homeDirectoryForCurrentUser` is macOS-only
    /// (unavailable on iOS), so iOS falls back to the app's Documents container. macOS
    /// behavior is unchanged. The test override, when set, wins on every platform.
    public static var exportDirectory: URL {
        if let override = exportDirectoryOverride { return override }
        // TEST FAIL-SAFE (Jul 2026 incident): any AppModel-constructing test triggers
        // the real macOS export via reloadNotes — `inMemoryStore` gates the container,
        // NOT the export — and a 1-note fixture export sails past the zero-note guard,
        // clobbering the live ~/Ollie wholesale (it even prunes the real notes/*.md).
        // Under XCTest with no explicit override, redirect to a per-process temp dir
        // so a forgotten override can never reach the production corpus. Fail-safe
        // beats fail-loud here: the protected asset is user data.
        if NSClassFromString("XCTestCase") != nil {
            let fallback = FileManager.default.temporaryDirectory
                .appendingPathComponent("ollie-test-export-\(ProcessInfo.processInfo.processIdentifier)",
                                        isDirectory: true)
            Diag.log("HNDIAG CorpusExporter: XCTest with no exportDirectoryOverride — redirecting export to \(fallback.path)")
            return fallback
        }
        #if os(macOS)
        let base = FileManager.default.homeDirectoryForCurrentUser
        #else
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #endif
        return base.appendingPathComponent("Ollie", isDirectory: true)
    }

    /// The sidecar metadata file `~/Ollie/.ollie.meta.json`. Written after every
    /// successful corpus export so external readers (the MCP server) can tell how
    /// fresh the corpus is and how many notes it should contain.
    public static var metaURL: URL {
        exportDirectory.appendingPathComponent(".ollie.meta.json")
    }

    /// Schedule an export off the main actor (best-effort).
    ///
    /// **Priority `.default`, not `.utility`.** The export feeds the `~/Ollie` mirror
    /// the MCP server and Obsidian read, so a user who just captured a note expects it
    /// to show up there promptly. `.utility` could sit behind other background work;
    /// default priority keeps the corpus fresh without contending with interactive UI.
    /// (Spelled `.medium` — the non-deprecated name for `TaskPriority.default`; same
    /// underlying value.)
    public static func exportInBackground(
        _ notes: [Note],
        layer: LayerSnapshot = .empty,
        allowEmpty: Bool = false
    ) {
        Task.detached(priority: .medium) { export(notes, layer: layer, allowEmpty: allowEmpty) }
    }

    /// Mirror the corpus + agent layer to disk. Safe on a background thread.
    ///
    /// - Parameters:
    ///   - notes: the full note projection (before restriction filtering). Routed
    ///     through ``CorpusGate`` so restricted notes never reach disk.
    ///   - layer: the agent-layer snapshot (tags/memory/views/instructions). Tags are
    ///     gated against `notes`; memory, views, and instructions export in full.
    ///   - allowEmpty: pass `true` ONLY for a genuine wipe (`deleteAllNotes`). By
    ///     default a zero-note export is REFUSED when a non-empty corpus already exists
    ///     on disk (see the guard below).
    public static func export(_ notes: [Note], layer: LayerSnapshot = .empty, allowEmpty: Bool = false) {
        // De-dup by id first — CloudKit mirroring can briefly surface duplicate-id
        // rows, and the corpus an LLM reads shouldn't contain the same note twice.
        var seen = Set<UUID>()
        let notes = notes.filter { seen.insert($0.id).inserted }
        let dir = exportDirectory
        let jsonlURL = dir.appendingPathComponent("ollie.jsonl")

        // ── SAFETY GUARD: never destroy a good corpus with a transient empty read ──
        // Verified failure (July 2026): after the Mac slept, an NSPersistentCloudKit-
        // Container import failed on wake ("file couldn't be opened"), the model
        // projected 0 notes, and this exporter overwrote a healthy 25-note
        // `ollie.jsonl` with an empty file — the MCP/Obsidian corpus vanished though
        // the data was intact in the store + iCloud. So: refuse to write an empty
        // corpus over a non-empty one unless a caller explicitly allows it (a real
        // wipe). `reloadNotes`'s fetch-failure guard is the first line of defense;
        // this is the second, in case a readable-but-momentarily-empty store slips
        // through. A genuine wipe passes `allowEmpty: true` after backing up.
        //
        // Keyed on the RAW projection (`notes`), NOT the gated set below: an empty
        // gated set can be a *legitimate* state (every note restricted) that should
        // write through, whereas an empty raw projection is the transient-failure
        // signal this guard exists to catch.
        if notes.isEmpty && !allowEmpty {
            let existing = (try? Data(contentsOf: jsonlURL)) ?? Data()
            if !existing.isEmpty {
                Diag.log("HNDIAG export SKIPPED: refused to overwrite a non-empty corpus with 0 notes (transient empty projection?). Corpus preserved.")
                return
            }
        }

        // ── THE GATE (contract §5): restricted notes — and their tags — never leave
        //    the device. Everything below writes the GATED note set; the raw `notes`
        //    (with its restricted members) is used only to derive the restriction that
        //    contaminates the tags. Views/memory/instructions export in full.
        let exportableNotes = CorpusGate.exportableNotes(notes)
        let exportableTags = CorpusGate.exportableTags(layer.tags, notes: notes)

        let notesDir = dir.appendingPathComponent("notes", isDirectory: true)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: notesDir, withIntermediateDirectories: true)
        } catch {
            // Can't even make the directory — log it (don't silently swallow) and bail.
            Diag.log("HNDIAG export FAILED to create \(notesDir.path): \(error)")
            return
        }

        // 1) The whole (gated) corpus as JSONL (one compact record per line) — the
        //    LLM/MCP source of truth. A failed write is LOGGED, not swallowed: a
        //    silently stale corpus is the exact failure this whole stage exists to
        //    prevent. (`jsonlURL` computed above, before the empty-corpus guard.)
        var jsonlOK = false
        // `written` is the count ACTUALLY serialized (a record that fails to encode is
        // dropped), so `meta.noteCount` matches the JSONL line count exactly — a reader
        // that compares them never sees a phantom mismatch.
        let (jsonl, written) = jsonlString(for: exportableNotes)
        do {
            try jsonl.write(to: jsonlURL, atomically: true, encoding: .utf8)
            jsonlOK = true
        } catch {
            Diag.log("HNDIAG export FAILED to write \(jsonlURL.path): \(error)")
        }

        // 2) One Markdown file per (gated) note (frontmatter + body) for humans / Obsidian.
        for note in exportableNotes {
            let url = notesDir.appendingPathComponent("\(note.id.uuidString).md")
            do {
                try markdown(for: note).write(to: url, atomically: true, encoding: .utf8)
            } catch {
                Diag.log("HNDIAG export FAILED to write \(url.lastPathComponent): \(error)")
            }
        }

        // 2b) Prune orphaned `.md` files — best-effort. This does DOUBLE duty:
        //     (a) a deleted note used to leave its Markdown behind forever, so
        //         Obsidian/a human browsing `notes/` saw resurrected notes and the
        //         directory grew unbounded; and
        //     (b) a note that just became RESTRICTED drops out of `exportableNotes`,
        //         so its previously-exported `.md` is pruned here too (contract §5 —
        //         "a note that becomes restricted has its previously-exported `.md`
        //         pruned"). `liveNames` is built from the GATED set, so any `.md` whose
        //         id isn't currently exportable is removed.
        let liveNames = Set(exportableNotes.map { "\($0.id.uuidString).md" })
        if let existing = try? fm.contentsOfDirectory(atPath: notesDir.path) {
            for name in existing where name.hasSuffix(".md") && !liveNames.contains(name) {
                try? fm.removeItem(at: notesDir.appendingPathComponent(name))
            }
        }

        // 3) The agent layer (contract §5, Views v2 spec §6): tags.jsonl (gated),
        //    memory.jsonl, views.jsonl, instructions.md, interactions.jsonl (pruned).
        //    Best-effort, same atomic write as ollie.jsonl. A layer-file failure is
        //    logged but does NOT block the note corpus or meta — the corpus is the
        //    load-bearing artifact; the layer files are additive. Returns the exported
        //    (post-prune) interaction count for the meta below.
        let interactionCount = writeLayer(exportableTags: exportableTags, layer: layer, dir: dir)

        // 4) Only after a SUCCESSFUL JSONL write, refresh the staleness sidecar so a
        //    reader can trust it. Writing meta after a failed corpus write would
        //    falsely advertise a fresh export. Meta carries the layer counts (contract
        //    §5) reflecting what was actually written (gated tags; full memory/views;
        //    post-prune interactions).
        if jsonlOK {
            writeMeta(
                noteCount: written,
                layerCounts: LayerCounts(
                    tags: exportableTags.count,
                    memory: layer.memory.count,
                    viewRevisions: layer.viewRevisions.count,
                    interactions: interactionCount))
        }
    }

    /// The `layerCounts` block in `.ollie.meta.json` (contract §5 + Views v2 spec §6).
    /// Reflects what was actually exported: **gated** tag count, full memory +
    /// view-revision counts, and the **post-prune** interaction count.
    private struct LayerCounts {
        let tags: Int
        let memory: Int
        let viewRevisions: Int
        let interactions: Int
    }

    /// Write the five agent-layer artifacts. Each is best-effort and independent — one
    /// failing (logged) never blocks the others or the note corpus.
    ///   • `tags.jsonl`        — the **gated** tags (restricted-note tags already removed).
    ///   • `memory.jsonl`      — all memory, retired entries included and flagged.
    ///   • `views.jsonl`       — every view revision, full body (snapshots, not diffs).
    ///   • `instructions.md`   — the plain-markdown instructions text.
    ///   • `interactions.jsonl`— the **pruned** live interaction state (Views v2 spec §6).
    ///
    /// Each JSONL file is written through a dedicated `Encodable` **record** struct
    /// (below) rather than the value type's own `Codable`, so the wire format matches
    /// the contract §5 / spec §6 shape EXACTLY and stays decoupled from the in-app type
    /// (same philosophy as `ExportRecord` for notes). Notably `tags.jsonl` omits the tag
    /// record's `id` — the contract shape is `{"noteId","tag","agentId","createdAt"}`.
    ///
    /// Files are written even when their source is empty, so a reader sees an
    /// authoritative empty file rather than a stale one (mirrors `ollie.jsonl`'s
    /// wholesale rewrite). `instructions.md` is written empty (`""`) when there are no
    /// instructions — never left dangling from a prior export.
    ///
    /// Returns the count of interaction records actually exported (post-prune), so
    /// `meta.layerCounts.interactions` matches the `interactions.jsonl` line count.
    @discardableResult
    private static func writeLayer(exportableTags: [AgentTag], layer: LayerSnapshot, dir: URL) -> Int {
        write(jsonlLines: exportableTags.map(TagRecord.init), to: dir.appendingPathComponent("tags.jsonl"))
        write(jsonlLines: layer.memory.map(MemoryRecord.init), to: dir.appendingPathComponent("memory.jsonl"))
        write(jsonlLines: layer.viewRevisions.map(ViewRecord.init), to: dir.appendingPathComponent("views.jsonl"))
        // Interaction state (Views v2 spec §6): views export in full, so their
        // interaction state does too (same gate reasoning — nothing here can cite a
        // restricted transcript the view itself couldn't). Pruned first (orphan pass).
        let liveInteractions = prunedInteractions(layer.interactions, revisions: layer.viewRevisions)
        write(jsonlLines: liveInteractions.map(InteractionRecord.init),
              to: dir.appendingPathComponent("interactions.jsonl"))
        let instructionsURL = dir.appendingPathComponent("instructions.md")
        do {
            try layer.instructions.write(to: instructionsURL, atomically: true, encoding: .utf8)
        } catch {
            Diag.log("HNDIAG export FAILED to write \(instructionsURL.path): \(error)")
        }
        return liveInteractions.count
    }

    /// The orphan-prune pass for interaction state (Views v2 spec §6), the interaction
    /// analogue of the `.md` prune. Two records drop out:
    ///   1. **Deleted-view records** — the record's `viewName` no longer appears in any
    ///      exported revision. Its view is gone; the state can never apply again.
    ///   2. **Superseded, stale records** — the record's `blockId` is absent from its
    ///      view's **latest** revision **and** `updatedAt < latestRevision.createdAt`
    ///      **and** the record is older than 30 days. All three must hold: an item the
    ///      agent hasn't re-published (absent from latest) whose state the newer body
    ///      already supersedes (older than that body — spec §1) and which has had 30
    ///      days to be consumed. A fresh toggle, or one on a view the agent hasn't
    ///      touched since, is kept.
    ///
    /// Records whose block is still present in the latest revision are always kept (the
    /// user's checkmark is live). This runs against the SAME revision snapshot being
    /// exported, so the `blockId`s are derived identically to the renderer (spec §3).
    static func prunedInteractions(
        _ interactions: [ViewInteraction],
        revisions: [AgentViewRevision],
        now: Date = Date()
    ) -> [ViewInteraction] {
        // Latest revision per view (exact-name match, latest createdAt wins) — the
        // same "latest wins" rule the display + precedence use.
        var latestByView: [String: AgentViewRevision] = [:]
        for r in revisions {
            if let existing = latestByView[r.viewName] {
                if r.createdAt > existing.createdAt { latestByView[r.viewName] = r }
            } else {
                latestByView[r.viewName] = r
            }
        }
        // The set of live blockIds in each view's latest revision (derived exactly as
        // the renderer does — spec §3). Computed lazily + cached per view name.
        var liveBlockIdsByView: [String: Set<String>] = [:]
        func liveBlockIds(_ view: String) -> Set<String>? {
            guard let latest = latestByView[view] else { return nil }
            if let cached = liveBlockIdsByView[view] { return cached }
            let ids = MarkdownLite.checklistBlockIds(in: latest.body)
            liveBlockIdsByView[view] = ids
            return ids
        }

        let ageCutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)   // 30 days
        return interactions.filter { rec in
            guard let latest = latestByView[rec.viewName] else {
                return false   // (1) the whole view is gone → prune
            }
            let liveIds = liveBlockIds(rec.viewName) ?? []
            if liveIds.contains(rec.blockId) {
                return true    // block still in the latest revision → keep (live checkmark)
            }
            // (2) absent from latest — prune only if the newer body supersedes it AND
            //     it's had 30 days. Otherwise keep (recent toggle, or a view the agent
            //     hasn't re-published since — its state may still apply on read).
            let superseded = rec.updatedAt < latest.createdAt
            let old = rec.updatedAt < ageCutoff
            return !(superseded && old)
        }
    }

    /// `tags.jsonl` line — contract §5: `{"noteId","tag","agentId","createdAt"}`.
    /// Deliberately **no `id`**: a tag is identified by `(noteId, tag)`, and the
    /// contract shape omits the record id.
    private struct TagRecord: Encodable {
        let noteId: String
        let tag: String
        let agentId: String
        let createdAt: Date
        init(_ t: AgentTag) {
            noteId = t.noteId.uuidString
            tag = t.tag
            agentId = t.agentId
            createdAt = t.createdAt
        }
    }

    /// `memory.jsonl` line — contract §5:
    /// `{"id","text","agentId","createdAt","retired","retiredAt"?}`. Retired entries
    /// are included and flagged; `retiredAt` is omitted while live (nil optional).
    private struct MemoryRecord: Encodable {
        let id: String
        let text: String
        let agentId: String
        let createdAt: Date
        let retired: Bool
        let retiredAt: Date?
        init(_ m: AgentMemory) {
            id = m.id.uuidString
            text = m.text
            agentId = m.agentId
            createdAt = m.createdAt
            retired = m.retired
            retiredAt = m.retiredAt
        }
    }

    /// `views.jsonl` line — contract §5:
    /// `{"id","viewName","body","agentId","createdAt"}`. Every revision, full body
    /// (snapshots, not diffs).
    private struct ViewRecord: Encodable {
        let id: String
        let viewName: String
        let body: String
        let agentId: String
        let createdAt: Date
        init(_ v: AgentViewRevision) {
            id = v.id.uuidString
            viewName = v.viewName
            body = v.body
            agentId = v.agentId
            createdAt = v.createdAt
        }
    }

    /// `interactions.jsonl` line — Views v2 spec §6:
    /// `{"viewName","blockId","blockText","kind","value","revisionId","surface","updatedAt"}`.
    /// One line per live interaction record (post-prune). Denormalized: it carries
    /// `blockText` so agents never recompute the `blockId` hash (spec §3). The record
    /// `id` is omitted — the logical key is `(viewName, blockId)`, mirroring how
    /// `TagRecord` omits its id.
    private struct InteractionRecord: Encodable {
        let viewName: String
        let blockId: String
        let blockText: String
        let kind: String
        let value: String
        let revisionId: String
        let surface: String
        let updatedAt: Date
        init(_ i: ViewInteraction) {
            viewName = i.viewName
            blockId = i.blockId
            blockText = i.blockText
            kind = i.kind
            value = i.value
            revisionId = i.revisionId.uuidString
            surface = i.surface
            updatedAt = i.updatedAt
        }
    }

    /// Encode a list of `Encodable` records as JSONL (one compact record per line,
    /// trailing newline) and atomically write it — the same shape/round-trip as
    /// `ollie.jsonl`. An empty list writes an empty file (authoritative, not stale).
    private static func write<T: Encodable>(jsonlLines values: [T], to url: URL) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]   // one line each, NOT pretty
        var lines: [String] = []
        lines.reserveCapacity(values.count)
        for value in values {
            if let data = try? enc.encode(value), let line = String(data: data, encoding: .utf8) {
                lines.append(line)
            }
        }
        let text = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Diag.log("HNDIAG export FAILED to write \(url.path): \(error)")
        }
    }

    /// Write `~/Ollie/.ollie.meta.json` describing the just-completed export:
    /// ```json
    /// { "exportedAt": <ISO8601 now>, "noteCount": N, "schemaVersion": 3,
    ///   "layerCounts": {"tags":N, "memory":N, "viewRevisions":N, "interactions":N} }
    /// ```
    /// The MCP server reads this to surface staleness ("corpus older than ~24h"), to
    /// know the expected note count, and (as of schema v3) the agent-layer sizes. The
    /// `interactions` count is **additive** (Views v2 spec §6) — no meta version bump.
    /// Failures are logged, never swallowed.
    private static func writeMeta(noteCount: Int, layerCounts: LayerCounts) {
        let meta: [String: Any] = [
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "noteCount": noteCount,
            "schemaVersion": Note.currentSchemaVersion,
            "layerCounts": [
                "tags": layerCounts.tags,
                "memory": layerCounts.memory,
                "viewRevisions": layerCounts.viewRevisions,
                "interactions": layerCounts.interactions,
            ],
        ]
        do {
            let data = try JSONSerialization.data(
                withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: metaURL, options: [.atomic])
        } catch {
            Diag.log("HNDIAG export FAILED to write \(metaURL.path): \(error)")
        }
    }

    /// Write a one-off, timestamped JSONL snapshot of the corpus to
    /// `~/Ollie/backups/ollie-backup-<stamp>.jsonl` and return its URL.
    ///
    /// Unlike `export(_:)` — which rewrites the live `ollie.jsonl` mirror in place —
    /// this lands in a dedicated file that nothing else overwrites, so it survives a
    /// subsequent empty export (e.g. the reload right after `--wipe-all-notes`). Use it
    /// as a safety net immediately before a destructive operation. Best-effort: returns
    /// `nil` if the directory or file can't be written.
    @discardableResult
    public static func backup(_ notes: [Note]) -> URL? {
        let fm = FileManager.default
        let dir = exportDirectory.appendingPathComponent("backups", isDirectory: true)
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil
        else { return nil }

        // Filesystem-safe local-time stamp (`yyyyMMdd-HHmmss`). Built locally rather
        // than as a shared static — DateFormatter isn't Sendable.
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let url = dir.appendingPathComponent("ollie-backup-\(stamp.string(from: Date())).jsonl")
        do {
            try jsonlString(for: notes).text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    // MARK: Shapes

    /// The flat record written to `ollie.jsonl` — a stable, LLM-friendly shape kept
    /// deliberately separate from `Note`'s internal `Codable` so the export format
    /// can evolve on its own.
    private struct ExportRecord: Encodable {
        let id: String
        let createdAt: Date
        let updatedAt: Date
        let source: String
        let kind: String
        let text: String
        let place: String?
        let latitude: Double?
        let longitude: Double?
        let durationSeconds: Double?
        let hasAudio: Bool
        /// Only present (and true) when the transcript is a failure placeholder, not
        /// real content — so an LLM reading the corpus doesn't treat `[Transcription
        /// failed: …]` as something the user said. Omitted for healthy notes.
        let transcriptionFailed: Bool?
        /// **Reserved for photo notes** (contract §5, §7): per-note media references.
        /// Always `nil` today — and because the encoder omits nil optionals (same as
        /// `transcriptionFailed`), the key is absent from `ollie.jsonl` entirely until
        /// photo notes ship. Documented here so readers know the shape it will take.
        let media: [String]?

        init(_ n: Note) {
            id = n.id.uuidString
            createdAt = n.createdAt
            updatedAt = n.updatedAt
            source = n.source.rawValue
            kind = n.kind.rawValue
            text = n.transcript
            place = n.location?.label
            latitude = n.location?.latitude
            longitude = n.location?.longitude
            durationSeconds = n.durationSeconds
            hasAudio = n.hasAudio
            transcriptionFailed = n.transcriptionFailed ? true : nil
            media = nil   // reserved — no media notes today
        }
    }

    /// Encode notes as JSONL (one compact `ExportRecord` per line, trailing newline).
    /// Shared by the live `ollie.jsonl` mirror (`export`) and the timestamped `backup`.
    /// Returns the text AND the count actually written, so `meta.noteCount` can reflect
    /// the real line count rather than the input count (a record that fails to encode
    /// is silently dropped from the text — the two must not disagree).
    private static func jsonlString(for notes: [Note]) -> (text: String, written: Int) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]   // NOT prettyPrinted: one line each
        var lines: [String] = []
        lines.reserveCapacity(notes.count)
        for note in notes {
            if let data = try? enc.encode(ExportRecord(note)),
               let line = String(data: data, encoding: .utf8) {
                lines.append(line)
            }
        }
        let text = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        return (text, lines.count)
    }

    private static func markdown(for note: Note) -> String {
        let iso = ISO8601DateFormatter()
        var out = "---\n"
        out += "id: \(note.id.uuidString)\n"
        out += "date: \(iso.string(from: note.createdAt))\n"
        out += "source: \(note.source.rawValue)\n"
        out += "kind: \(note.kind.rawValue)\n"
        if let place = note.location?.label { out += "place: \(place)\n" }
        out += "---\n\n"
        out += note.transcript
        if !note.transcript.hasSuffix("\n") { out += "\n" }
        return out
    }
}
