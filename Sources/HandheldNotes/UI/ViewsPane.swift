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
            ForEach(rows) { rev in
                ViewFeedRow(revision: rev,
                            isSelected: rev.viewName == selectedViewName,
                            isPinned: rev.viewName == model.pinnedViewName)
                    .onTapGesture { selectedViewName = rev.viewName }
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
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
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
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
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

    /// A compact, single-block preview of the body: the first non-blank, non-heading
    /// line's plain text (markdown markers stripped for the list glance).
    private var bodyPreview: String {
        for raw in revision.body.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            // Strip common leading markers for a cleaner preview.
            let stripped = line.drop { "#-*+> ".contains($0) }
            let text = stripped.isEmpty ? line : String(stripped)
            return text
        }
        return "Empty view"
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
        .onChange(of: shown?.id) { _, _ in rebuildInteraction() }
        .onAppear { rebuildInteraction() }
        .onDisappear { interaction?.commitNow() }
    }

    private func content(name: String, shown: AgentViewRevision) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerBlock(name: name, shown: shown)
                MarkdownLite(shown.body, onOpenNote: onOpenNote, checklist: checklistHook)
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

    private func headerBlock(name: String, shown: AgentViewRevision) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 12) {
                Text(name)
                    .font(.hcDisplay(26, weight: .semibold))
                    .foregroundStyle(Color.hcPrimaryText)
                    .lineLimit(1...3)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
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
