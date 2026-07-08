import HandheldNotesCore
import SwiftUI

// MARK: - Mac Views surface (contract §5, plan M5 5f)
//
// The Mac keeps this deliberately MINIMAL (per the plan): the left pane swaps to a
// feed of published views (latest revision per view, pinned on top), and the right
// pane renders the selected view's latest revision with the shared Core `MarkdownLite`
// renderer — the same dialect the iPhone Views tab uses, so a view reads identically
// on both. The heavier affordances (per-revision history navigation, pin/unpin,
// delete) live here as a compact detail header; the iPhone tab is the primary surface.
//
// Note citations (`ollie://note/<uuid>`) route back through `onOpenNote`, which the
// window uses to select the note and flip the pane back to Notes.

/// The left column in Views mode: the feed of views (one row per view, pinned first),
/// mirroring `NotesListView`'s shape. Selecting a row drives the detail pane via the
/// bound `selectedViewName`.
struct ViewsFeedPane: View {
    @EnvironmentObject var model: AppModel
    @Binding var selectedViewName: String?

    /// The feed rows: latest revision per view, pinned view hoisted to the top.
    private var rows: [AgentViewRevision] {
        let latest = model.agentViews.latest
        guard let pinned = model.pinnedViewName,
              let idx = latest.firstIndex(where: { $0.viewName == pinned }) else {
            return latest
        }
        var reordered = latest
        let pin = reordered.remove(at: idx)
        reordered.insert(pin, at: 0)
        return reordered
    }

    /// The rows partitioned into directory sections (M18, contract §7 "View directory
    /// convention"): ungrouped views (no `/` in the name) first with no header, then
    /// sections headed by the text before the FIRST `/` (trimmed), alphabetically.
    /// Within a group the pane's existing `rows` order is preserved. A pure derivation
    /// of `rows` — no writes — so evaluating it during render is loop-safe.
    private var sections: ViewDirectory { ViewDirectory(rows: rows) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if rows.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(minWidth: 300, idealWidth: 340, maxWidth: 380)
        .background(Color.hcBackgroundBottom.opacity(0.6))
    }

    private var header: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.hcAccent)
                    .frame(width: 30, height: 30)
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.hcOnAccent)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("Views")
                    .font(.hcDisplay(18, weight: .semibold))
                    .foregroundStyle(Color.hcPrimaryText)
                Text("\(rows.count) view\(rows.count == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.hcMutedText)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 22)
        .padding(.bottom, 16)
    }

    private var list: some View {
        List {
            // Ungrouped views first, headerless (M18). Rows render identically here
            // and inside a section — same `row(for:)` builder, same dot/name/meta.
            ForEach(sections.ungrouped) { rev in
                row(for: rev)
            }
            // Then one plain, non-collapsible section per directory prefix,
            // alphabetically; the pane's existing order is preserved within each.
            ForEach(sections.groups, id: \.name) { group in
                Section(header: sectionHeader(group.name)) {
                    ForEach(group.rows) { rev in
                        row(for: rev)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    /// One feed row (M18: shared by the ungrouped list and every section so grouping
    /// changes only where a row sits, never how it renders). The unread dot (M16) is
    /// driven by a pure read of the published snapshot; selecting the row marks the
    /// view seen from the tap ACTION (never during render — landmine).
    @ViewBuilder
    private func row(for rev: AgentViewRevision) -> some View {
        ViewFeedRow(revision: rev,
                    isSelected: rev.viewName == selectedViewName,
                    isPinned: rev.viewName == model.pinnedViewName,
                    isUnread: model.agentViews.isUnread(rev.viewName))
            .onTapGesture {
                selectedViewName = rev.viewName
                // Opening a view to read it clears its unread dot live (M16). Safe:
                // this is a user action, not render — `markViewSeen` re-projects the
                // snapshot itself.
                model.markViewSeen(rev.viewName, surface: "mac")
            }
            .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .contextMenu {
                Button(rev.viewName == model.pinnedViewName ? "Unpin" : "Pin to top") {
                    model.togglePinnedView(rev.viewName)
                }
                Button("Delete view", role: .destructive) {
                    if selectedViewName == rev.viewName { selectedViewName = nil }
                    model.userDelete(view: rev.viewName)
                }
            }
    }

    /// A plain (non-collapsible) directory section header in the pane's list idiom —
    /// the tracked-caps coral `Eyebrow`, matching the "Capture"/"Earlier revisions"
    /// eyebrows used elsewhere in the app.
    private func sectionHeader(_ name: String) -> some View {
        Eyebrow(text: name)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .padding(.leading, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "rectangle.stack")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Color.hcMutedText)
            Text("No views yet")
                .font(.hcDisplay(15))
                .foregroundStyle(Color.hcSecondaryText)
            Text("Agents publish summaries here — an answer to a request, an \u{201C}Open loops\u{201D} digest.")
                .font(.system(size: 12))
                .foregroundStyle(Color.hcMutedText)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }
}

/// One row in the Views feed: name, a 2-line preview of the latest body, and a
/// provenance footer (agent · relative time). A pin glyph marks the pinned view.
private struct ViewFeedRow: View {
    let revision: AgentViewRevision
    let isSelected: Bool
    let isPinned: Bool
    /// Whether the view is unread (M16) — draws the small accent dot before the name.
    let isUnread: Bool
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                // Unread dot (M16): a small filled accent circle, matching the pane's
                // pin-glyph accent language. Only present when unread, so a read row
                // reads exactly as before.
                if isUnread {
                    Circle()
                        .fill(Color.hcAccent)
                        .frame(width: 6, height: 6)
                        .padding(.top, 5)
                        .help("Unread — updated since you last opened it")
                }
                Text(revision.viewName)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.hcPrimaryText)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.hcAccent)
                        .help("Pinned")
                }
            }
            Text(bodyPreview)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.hcSecondaryText)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text(revision.agentId.isEmpty ? "agent" : revision.agentId)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.hcMutedText)
                Text("·").foregroundStyle(Color.hcMutedText)
                Text(HCRelative.string(from: revision.createdAt))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.hcMutedText)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(isSelected ? Color.hcAccentSoft : (hovering ? Color.hcPanel : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(isSelected ? Color.hcAccent.opacity(0.45) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovering)
    }

    /// A compact, single-block preview of the body: the first meaningful line rendered as
    /// markdown-free plain text (leading + inline markdown stripped, leading fences
    /// skipped) via the shared ``ViewPreviewSnippet`` — so `**Open loops**` glances as
    /// `Open loops`, not with the asterisks showing.
    private var bodyPreview: String {
        ViewPreviewSnippet.make(from: revision.body)
    }
}

// MARK: - Views detail (right pane)

/// The right pane in Views mode: the selected view's latest revision rendered with
/// `MarkdownLite`, a provenance header, a pin/unpin + delete affordance, and an
/// "earlier revisions" list that swaps which revision is shown. Nothing selected →
/// a friendly empty state.
struct ViewDetailPane: View {
    @EnvironmentObject var model: AppModel
    @Binding var selectedViewName: String?
    /// Called when the reader taps an `ollie://note/<uuid>` citation.
    let onOpenNote: (UUID) -> Void

    /// Which revision the reader is viewing; nil = the latest. Reset when the view
    /// selection changes (via `.id(selectedViewName)` on the content).
    @State private var shownRevisionID: UUID?

    /// The earlier revision the reader has asked to restore, awaiting confirmation
    /// (plan §M8 8b). Non-nil drives the confirmation dialog; the confirm appends a new
    /// revision copying this one's body via `model.userRestore`.
    @State private var revisionToRestore: AgentViewRevision?

    /// The interaction brain for the currently-*displayed* revision (Views v2 spec §4).
    /// Rebuilt whenever the shown view/revision changes (committing the previous one at
    /// that boundary first), so the supersession boundary — the revision's `createdAt` —
    /// always matches what's on screen. `nil` until a view is shown.
    @State private var interaction: ViewInteractionModel?

    private var revisions: [AgentViewRevision] {
        guard let name = selectedViewName else { return [] }
        return model.revisions(forView: name)
    }

    /// The revision currently displayed: the explicitly-selected earlier one, else the
    /// latest (head of the newest-first list).
    private var shown: AgentViewRevision? {
        let revs = revisions
        if let id = shownRevisionID, let match = revs.first(where: { $0.id == id }) {
            return match
        }
        return revs.first
    }

    var body: some View {
        Group {
            if let name = selectedViewName, let shown, !revisions.isEmpty {
                content(name: name, shown: shown)
                    // Re-key on the selected VIEW so the shown-revision state resets
                    // when the user picks a different view.
                    .id(name)
            } else {
                empty
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Boundary commits (Views v2 spec §4): switching the displayed view/revision
        // settles the outgoing model first (rebuilding it for the new one), and leaving
        // the pane entirely flushes the last one. Keyed on the shown revision id so a
        // "time machine" jump to an older revision also re-anchors the supersession
        // boundary (`createdAt`) to what's now on screen.
        .onChange(of: shown?.id) { _, _ in
            rebuildInteraction()
            // Switching the displayed view (or time-machining to another revision of
            // it) means the reader is now looking at this one — mark it seen (M16).
            markSeenForShown()
        }
        .onAppear {
            rebuildInteraction()
            markSeenForShown()
        }
        .onDisappear { interaction?.commitNow() }
        // Restore-revision confirmation (plan §M8 8b). Appends a NEW revision copying the
        // chosen earlier one's body — history is append-only, so this is additive, not a
        // rollback that loses anything.
        .confirmationDialog(
            "Restore this revision?",
            isPresented: Binding(get: { revisionToRestore != nil },
                                 set: { if !$0 { revisionToRestore = nil } }),
            presenting: revisionToRestore) { rev in
            Button("Restore") {
                if let name = selectedViewName {
                    model.userRestore(viewName: name, revisionId: rev.id)
                    // Snap back to the latest so the restored copy (now newest) is shown.
                    shownRevisionID = nil
                }
                revisionToRestore = nil
            }
            Button("Cancel", role: .cancel) { revisionToRestore = nil }
        } message: { rev in
            Text("Adds a new revision copying this one from \(HCRelative.string(from: rev.createdAt)). Nothing is deleted.")
        }
    }

    private func content(name: String, shown: AgentViewRevision) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerBlock(name: name, shown: shown)
                // Suppress a leading H1 that just repeats the view name (plan §M8 8c):
                // the pane's own header already shows the title.
                MarkdownLite(shown.body, onOpenNote: onOpenNote, checklist: checklistHook,
                             suppressLeadingHeading: name)
                if revisions.count > 1 {
                    earlierRevisions(shown: shown)
                }
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The interaction hook fed into `MarkdownLite` (spec §5). A checklist glyph
    /// reflects the model's three-layer `resolved(...)`; a tap flips `pending` and
    /// restarts the settle timer via `toggle(...)`. Nil-safe: before the model exists
    /// (or if it's rebuilding) the glyph falls back to the body default and taps no-op.
    private var checklistHook: ChecklistHook {
        ChecklistHook(
            resolved: { blockId, bodyChecked in
                interaction?.resolved(blockId: blockId, bodyChecked: bodyChecked) ?? bodyChecked
            },
            onToggle: { blockId, text in
                interaction?.toggle(blockId: blockId, blockText: text)
            })
    }

    /// Commit the outgoing interaction model (a view/revision switch is a settle
    /// boundary — spec §4) and build a fresh one anchored to the now-shown revision, so
    /// its supersession boundary (`createdAt`) matches what's on screen. No shown
    /// revision → tear the model down (and commit it first).
    private func rebuildInteraction() {
        interaction?.commitNow()
        if let shown {
            interaction = model.interactionModel(for: shown)
        } else {
            interaction = nil
        }
    }

    /// Mark the currently-shown view seen (M16) so its unread dot clears once the
    /// reader is looking at it. Called from the detail's lifecycle actions
    /// (`.onAppear` / view-switch) — never during render — and `markViewSeen`
    /// re-projects the snapshot itself, so the dot in the feed drops live.
    private func markSeenForShown() {
        guard let name = selectedViewName else { return }
        model.markViewSeen(name, surface: "mac")
    }

    /// Annotate (M17): open the Mac capture composer prefilled with the contract §7
    /// annotation prefix — `re: view "<name>": ` (cursor lands at the end, editable).
    /// Sending produces an ordinary note through the existing pipeline; nothing in the
    /// app parses the grammar (it's a runbook convention). Routed via the
    /// `ollieSeedDraft` notification the `CaptureBar` listens for, so this stays inside
    /// the Views file and needs no Core change.
    private func annotate(_ name: String) {
        let seed = "re: view \"\(name)\": "
        NotificationCenter.default.post(
            name: .ollieSeedDraft,
            object: nil,
            userInfo: [SeedDraftKey.text: seed])
    }

    private func headerBlock(name: String, shown: AgentViewRevision) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 12) {
                Text(name)
                    .font(.hcDisplay(26, weight: .semibold))
                    .foregroundStyle(Color.hcPrimaryText)
                    .lineLimit(1...3)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                // Annotate (M17): route into the normal capture composer prefilled
                // with the contract §7 annotation prefix. A user ACTION (button tap),
                // so it never mutates observed state during render.
                Button(action: { annotate(name) }) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.hcMutedText)
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .help("Comment on this view — opens Capture prefilled with re: view \u{201C}\(name)\u{201D}")

                Button(action: { model.togglePinnedView(name) }) {
                    Image(systemName: model.pinnedViewName == name ? "pin.fill" : "pin")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(model.pinnedViewName == name ? Color.hcAccent : Color.hcMutedText)
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .help(model.pinnedViewName == name ? "Unpin from the top of the feed" : "Pin to the top of the feed")

                Button(action: {
                    selectedViewName = nil
                    model.userDelete(view: name)
                }) {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.hcMutedText)
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .help("Delete this view and all its revisions")
            }

            // Provenance: which agent, when, and the revision count.
            ChipFlow {
                Chip(shown.agentId.isEmpty ? "agent" : shown.agentId, symbol: "cpu", tint: .hcAccent)
                Chip(HCRelative.string(from: shown.createdAt), symbol: "clock")
                    .help(Self.fullDate(shown.createdAt))
                let count = revisions.count
                Chip("\(count) revision\(count == 1 ? "" : "s")", symbol: "clock.arrow.circlepath")
                if isViewingEarlier {
                    Chip("older revision", symbol: "arrow.uturn.backward", tint: .hcMutedText)
                }
            }
        }
    }

    private var isViewingEarlier: Bool {
        guard let id = shownRevisionID, let latest = revisions.first else { return false }
        return id != latest.id
    }

    private func earlierRevisions(shown: AgentViewRevision) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "Earlier revisions")
            // Skip the head (that's the latest, shown by default); list the rest, plus
            // a "Latest" entry so the reader can return after browsing an older one.
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(revisions.enumerated()), id: \.element.id) { index, rev in
                    RevisionRow(
                        revision: rev,
                        label: index == 0 ? "Latest" : "Revision \(revisions.count - index)",
                        isShown: rev.id == shown.id,
                        // Only earlier revisions are restorable — restoring the latest
                        // would just duplicate it. nil ⇒ no Restore affordance.
                        onRestore: index == 0 ? nil : { revisionToRestore = rev },
                        onTap: { shownRevisionID = rev.id })
                }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color.hcMutedText)
            Text("Select a view")
                .font(.hcDisplay(20))
                .foregroundStyle(Color.hcSecondaryText)
            Text("Pick a view on the left to read it. Agents publish summaries and answers here.")
                .font(.system(size: 13))
                .foregroundStyle(Color.hcMutedText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
    }

    static func fullDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "EEEE, MMM d, yyyy 'at' h:mm a"
        return fmt.string(from: date)
    }
}

/// One row in the "earlier revisions" list: a label, a provenance footer, and a
/// selection marker on the currently-shown revision.
private struct RevisionRow: View {
    let revision: AgentViewRevision
    let label: String
    let isShown: Bool
    /// nil ⇒ this row can't be restored (it's the latest); non-nil ⇒ a "Restore this
    /// revision" context-menu item that runs this (which raises the confirm).
    let onRestore: (() -> Void)?
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: isShown ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isShown ? Color.hcAccent : Color.hcMutedText)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.hcPrimaryText)
                    HStack(spacing: 6) {
                        Text(revision.agentId.isEmpty ? "agent" : revision.agentId)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Color.hcMutedText)
                        Text("·").foregroundStyle(Color.hcMutedText)
                        Text(HCRelative.string(from: revision.createdAt))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Color.hcMutedText)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isShown ? Color.hcAccentSoft : (hovering ? Color.hcPanel : Color.hcPanel.opacity(0.5))))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.hcCardBorder.opacity(isShown ? 0.8 : 0.4), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovering)
        .contextMenu {
            if let onRestore {
                Button("Restore this revision", systemImage: "arrow.uturn.backward") {
                    onRestore()
                }
            }
        }
    }
}

// MARK: - View directory grouping (M18, contract §7 "View directory convention")

/// Partitions the feed's rows into directory sections. The grouping rule is CONTRACT
/// (§7): a view name containing `/` groups under a section named for the text before
/// the FIRST `/` (trimmed of surrounding whitespace); a prefix-less name stays
/// ungrouped. Ordering: ungrouped rows first (no header), then sections
/// alphabetically (case-insensitive); WITHIN each group the caller's existing row
/// order is preserved.
///
/// A pure value type built from the rows — no observed-state writes — so a
/// `ViewsFeedPane` may build it during render without risking the render loop.
private struct ViewDirectory {
    /// Views with no `/` in their name, in the caller's original order.
    let ungrouped: [AgentViewRevision]
    /// Prefix sections, alphabetical by `name`; each keeps the caller's row order.
    let groups: [Group]

    struct Group {
        let name: String
        let rows: [AgentViewRevision]
    }

    init(rows: [AgentViewRevision]) {
        var ungrouped: [AgentViewRevision] = []
        // Preserve first-appearance order of prefixes while bucketing, then sort the
        // buckets alphabetically at the end (within-bucket order stays insertion order).
        var order: [String] = []
        var buckets: [String: [AgentViewRevision]] = [:]

        for rev in rows {
            guard let prefix = Self.prefix(of: rev.viewName) else {
                ungrouped.append(rev)
                continue
            }
            if buckets[prefix] == nil {
                buckets[prefix] = []
                order.append(prefix)
            }
            buckets[prefix]?.append(rev)
        }

        self.ungrouped = ungrouped
        self.groups = order
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { Group(name: $0, rows: buckets[$0] ?? []) }
    }

    /// The section prefix for a view name: the trimmed text before the FIRST `/`, or
    /// `nil` when the name has no `/` (ungrouped) or the prefix is empty after
    /// trimming (e.g. a leading `/` — nothing sensible to head a section with).
    static func prefix(of viewName: String) -> String? {
        guard let slash = viewName.firstIndex(of: "/") else { return nil }
        let head = viewName[..<slash].trimmingCharacters(in: .whitespaces)
        return head.isEmpty ? nil : head
    }
}

// MARK: - Wrapping chip layout (a file-local twin of the note-detail FlowChips)

/// Lays children left-to-right and wraps onto new lines when the pane is narrow — so
/// the provenance chip row degrades gracefully. A private twin of the `FlowChips`
/// `Layout` used in the note-detail pane (that one is `private` to its file; the plan
/// says reuse where SwiftUI lets you, else a thin twin — this is the thin twin).
private struct ChipFlow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > maxWidth {
                widest = max(widest, x - spacing)
                x = 0; y += lineHeight + lineSpacing; lineHeight = 0
            }
            x += s.width + spacing
            lineHeight = max(lineHeight, s.height)
        }
        widest = max(widest, x - spacing)
        return CGSize(width: min(widest, maxWidth), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > maxWidth {
                x = 0; y += lineHeight + lineSpacing; lineHeight = 0
            }
            v.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            lineHeight = max(lineHeight, s.height)
        }
    }
}

// MARK: - Shared relative-date helper (Mac Views surface)

/// The same "just now / 12m ago / yesterday / Mar 4" relative format the iPhone uses
/// (`HCFormat.relative`), re-provided here for the Mac Views surface (the Mac app has
/// no `HCFormat` — it uses inline formatters elsewhere).
enum HCRelative {
    static func string(from date: Date) -> String {
        let now = Date()
        let secs = now.timeIntervalSince(date)
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(Int(secs / 60))m ago" }
        if secs < 86_400 { return "\(Int(secs / 3600))h ago" }
        if Calendar.current.isDateInYesterday(date) { return "yesterday" }
        let days = Int(secs / 86_400)
        if days < 7 { return "\(days)d ago" }
        let fmt = DateFormatter()
        fmt.dateFormat = Calendar.current.isDate(date, equalTo: now, toGranularity: .year)
            ? "MMM d" : "MMM d, yyyy"
        return fmt.string(from: date)
    }
}
