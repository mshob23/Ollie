import SwiftUI
import CryptoKit
#if os(iOS)
import UIKit   // UIImpactFeedbackGenerator (iOS-only haptic; guarded so Core still
               // compiles for macOS/watchOS, where the checklist haptic is a no-op).
#endif

// MARK: - MarkdownLite
//
// The shared, deliberately-tiny renderer for agent **view bodies** (contract §6,
// `docs/agent-contract.md`). Views are markdown that agents publish; the apps render
// them with THIS one renderer on both iOS and macOS so a view looks identical
// everywhere and the dialect stays a single, testable definition.
//
// The dialect is **line-based** — each line is classified independently (see
// ``MarkdownLineKind`` / ``MarkdownLite/classify(line:)``), with one multi-line
// exception: a fenced code block (```…```) captures the lines between its fences.
// Everything the classifier doesn't recognize falls through to
// `AttributedString(markdown:)` for inline styling (bold/italic/links), so ordinary
// prose Just Works.
//
// Two conventions agents rely on (contract §6):
//   • **Note citations** — `ollie://note/<uuid>` links are made tappable and routed
//     to ``onOpenNote`` instead of opening a URL. This is how a view cites the note
//     it was derived from.
//   • **Forward-compat fences** — an *unknown* fenced block (e.g. ```checklist … ```)
//     renders as a plain monospaced panel today; it is NEVER stripped and NEVER
//     errors. That's the reserved growth path for Views v2 interactive blocks — the
//     renderer passing it through untouched is the contract.
//
// Cross-platform by construction: SwiftUI + `Theme.swift` tokens only, no AppKit /
// UIKit, so the same file drives the Mac and iPhone Views surfaces unchanged.

/// The classification of a single line of a view body — the line-based core of the
/// §6 dialect. Pure and `Equatable` so it can be unit-tested without touching any
/// SwiftUI rendering (the classifier is the contract; the view is just its picture).
///
/// Fenced code blocks are the one construct that spans lines, so the classifier
/// reports the *fence delimiter* line (``fence``) and the block parser
/// (``MarkdownLite/blocks(from:)``) pairs opening/closing fences and collects the
/// lines between. A line's classification never depends on other lines.
public enum MarkdownLineKind: Equatable, Sendable {
    /// A heading: `#` / `##` / `###` (levels 1–3). `level` is clamped to 1...3; the
    /// captured `text` has the leading hashes + one space stripped.
    case heading(level: Int, text: String)
    /// A checklist item: `- [ ]` (unchecked) / `- [x]`/`- [X]` (checked). Display-only
    /// in v1 — the glyph reflects state but isn't interactive. `text` is the label.
    case checklist(checked: Bool, text: String)
    /// A plain bullet: `- ` / `* ` / `+ ` (but NOT the `- [ ]` checklist form). `text`
    /// is the item, hashes/markers stripped.
    case bullet(text: String)
    /// A code-fence delimiter line (```` ``` ````), optionally with an info string
    /// (```` ```checklist ````). `info` is the trimmed language/word after the ticks,
    /// or "" for a bare fence.
    case fence(info: String)
    /// A blank line (only whitespace) — a paragraph separator.
    case blank
    /// Anything else: ordinary prose, rendered via `AttributedString(markdown:)` for
    /// inline styling. `text` is the raw line.
    case paragraph(text: String)
}

/// A parsed, renderable block of a view body — the block parser's output (fences
/// collapsed into one ``codeBlock``, consecutive bullets/checklist items grouped into
/// a ``list``). Internal: the view walks these; tests exercise the line classifier.
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(text: String)
    case list([ListItem])
    /// A fenced code block: the info string (```` ```checklist ````) and the raw lines
    /// between the fences, joined with newlines. Rendered as a monospaced panel.
    case codeBlock(info: String, code: String)

    struct ListItem: Equatable {
        /// nil = a plain bullet; non-nil = a checklist item with its checked state.
        var checked: Bool?
        var text: String
        /// The content-derived interaction id for a **checklist** item
        /// (`cl1:<hash16>:<occ>`, spec §3) — nil for a plain bullet (no interaction).
        /// Annotated by ``MarkdownLite/blocks(from:)`` because computing the `<occ>`
        /// ordinal needs the whole document's checklist items in order. It is the join
        /// key against `InteractionStateEntity`; agents never recompute the hash (the
        /// export/MCP surfaces carry the snapshotted text instead). Defaults to nil so
        /// the memberwise init stays source-compatible with call sites that don't set it.
        var blockId: String? = nil
    }
}

/// An optional interaction hook that turns display-only checklist glyphs into tappable
/// checkboxes (Views v2, spec §5). When a ``MarkdownLite`` is built **with** one, each
/// checklist item's glyph reflects ``resolved`` (the three-layer resolved state — spec
/// §1) instead of the body default, and tapping the glyph+label row calls ``onToggle``.
/// When it is **nil** (the default) the renderer is exactly the v1 display-only surface
/// — the watch/feed previews stay untouched.
///
/// The hook is intentionally value-level plumbing only: the durable write path
/// (debounce, coalesce, one save per settle) lives in `ViewInteractionModel`, which the
/// panes own and wire into these two closures. `MarkdownLite` stays dumb.
public struct ChecklistHook {
    /// The resolved checked-state for a block, given the body default baked into the
    /// revision markdown. Layers pending → overlay(-iff-newer) → `bodyChecked` (spec §1)
    /// are resolved by the caller (`ViewInteractionModel`); the renderer just displays it.
    public var resolved: (_ blockId: String, _ bodyChecked: Bool) -> Bool
    /// Called when the user taps a checklist row. `text` is the classifier-captured item
    /// text (the snapshot stored as `blockText`); the caller flips its pending value and
    /// restarts the settle timer.
    public var onToggle: (_ blockId: String, _ text: String) -> Void

    public init(
        resolved: @escaping (_ blockId: String, _ bodyChecked: Bool) -> Bool,
        onToggle: @escaping (_ blockId: String, _ text: String) -> Void
    ) {
        self.resolved = resolved
        self.onToggle = onToggle
    }
}

/// A lightweight SwiftUI renderer for the view-body markdown dialect (contract §6).
/// Inject ``onOpenNote`` to receive taps on `ollie://note/<uuid>` citations.
public struct MarkdownLite: View {
    private let source: String
    private let onOpenNote: (UUID) -> Void
    /// nil ⇒ exactly v1 display-only glyphs (every existing call site). Non-nil ⇒
    /// checklist items become interactive (glyph reflects `resolved`, row taps toggle).
    private let checklist: ChecklistHook?
    /// The view name whose leading H1 to suppress, or nil ⇒ render every block (plan
    /// §M8 8c). Non-nil ⇒ if the FIRST block is an H1 case-insensitively equal to this
    /// (both trimmed), that block is dropped — the detail panes pass the view name so a
    /// body opening with its own title doesn't render it twice under the pane's header.
    private let suppressLeadingHeading: String?

    /// - Parameters:
    ///   - source: the view body (markdown in the §6 dialect).
    ///   - onOpenNote: called with the note id when the reader taps an
    ///     `ollie://note/<uuid>` citation. The host routes it to the note detail.
    ///   - checklist: optional interaction hook (spec §5). **Defaults to nil**, which is
    ///     byte-for-byte the v1 display-only rendering — no existing call site changes.
    ///     Pass one to make checklist boxes tappable (Views panes do; feed/watch previews
    ///     don't).
    ///   - suppressLeadingHeading: a view name whose leading H1 to drop (plan §M8 8c).
    ///     **Defaults to nil** (render every block — unchanged). When set and the first
    ///     block is an H1 case-insensitively equal to it (trimmed), that block is
    ///     skipped so a body opening with its own title isn't shown twice. Detail panes
    ///     pass the view name; feed/watch previews pass nothing.
    public init(
        _ source: String,
        onOpenNote: @escaping (UUID) -> Void,
        checklist: ChecklistHook? = nil,
        suppressLeadingHeading: String? = nil
    ) {
        self.source = source
        self.onOpenNote = onOpenNote
        self.checklist = checklist
        self.suppressLeadingHeading = suppressLeadingHeading
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let rendered = MarkdownLite.blocks(from: source,
                                               suppressingLeadingHeading: suppressLeadingHeading)
            ForEach(Array(rendered.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // A single environment handler so nested `Text` links (built via
        // AttributedString) route ollie:// taps back here rather than to the system
        // URL opener. Non-ollie links fall through to the default handler.
        .environment(\.openURL, OpenURLAction { url in
            if let id = MarkdownLite.noteID(fromOllieURL: url) {
                onOpenNote(id)
                return .handled
            }
            return .systemAction
        })
    }

    // MARK: - Block rendering

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            Text(text)
                .font(.hcDisplay(headingSize(level), weight: .semibold))
                .foregroundStyle(Color.hcPrimaryText)
                .fixedSize(horizontal: false, vertical: true)
                .hcTextSelectable()

        case let .paragraph(text):
            Text(inlineAttributed(text))
                .font(.system(size: 15))
                .foregroundStyle(Color.hcPrimaryText)
                .lineSpacing(4)
                .tint(.hcAccent)
                .fixedSize(horizontal: false, vertical: true)
                // No .textSelection here: on macOS a selectable Text is AppKit-backed and
                // routes link clicks through NSWorkspace, bypassing the SwiftUI openURL
                // handler above — which silently breaks ollie://note citation taps.

        case let .list(items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    listItemView(item)
                }
            }

        case let .codeBlock(info, code):
            codeBlockView(info: info, code: code)
        }
    }

    @ViewBuilder
    private func listItemView(_ item: MarkdownBlock.ListItem) -> some View {
        // Interactive iff a hook is present AND this is a checklist item (has a blockId).
        // Otherwise it's the v1 display-only row (plain bullet, or a checklist with no
        // hook — the feed/watch previews).
        if let hook = checklist, let blockId = item.blockId, let bodyChecked = item.checked {
            interactiveChecklistRow(item, hook: hook, blockId: blockId, bodyChecked: bodyChecked)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // Checklist glyph (display-only) or a plain bullet dot.
                if let checked = item.checked {
                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(checked ? Color.hcAccent : Color.hcSecondaryText)
                } else {
                    Text("•")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.hcAccent)
                }
                listItemLabel(item.text)
                Spacer(minLength: 0)
            }
        }
    }

    /// A tappable checklist row (spec §5): the glyph reflects the caller's resolved
    /// state, the whole glyph+label row is a hit target, tapping calls `onToggle`, the
    /// glyph change is animated, and iOS fires a light haptic. Everything else (the label
    /// styling, the no-`.textSelection` rule for link-bearing Text) matches the v1 row.
    @ViewBuilder
    private func interactiveChecklistRow(
        _ item: MarkdownBlock.ListItem,
        hook: ChecklistHook,
        blockId: String,
        bodyChecked: Bool
    ) -> some View {
        let checked = hook.resolved(blockId, bodyChecked)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(checked ? Color.hcAccent : Color.hcSecondaryText)
                .animation(.snappy(duration: 0.18), value: checked)
            listItemLabel(item.text)
            Spacer(minLength: 0)
        }
        // The whole row (glyph + label + trailing space) is the hit target. `.contentShape`
        // makes the Spacer region tappable too. Use a plain tap gesture rather than a
        // Button so the label's inline `ollie://` links keep routing through the openURL
        // handler instead of being swallowed by a button's own hit testing.
        .contentShape(Rectangle())
        .onTapGesture {
            Self.checklistHaptic()
            hook.onToggle(blockId, item.text)
        }
    }

    /// The shared label styling for a list item — identical for display-only and
    /// interactive rows. **No `.textSelection`**: on macOS a selectable Text is
    /// AppKit-backed and routes link clicks through NSWorkspace, bypassing the SwiftUI
    /// openURL handler above — which silently breaks `ollie://note` citation taps.
    private func listItemLabel(_ text: String) -> some View {
        Text(inlineAttributed(text))
            .font(.system(size: 15))
            .foregroundStyle(Color.hcPrimaryText)
            .lineSpacing(4)
            .tint(.hcAccent)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A light selection haptic on tap — iOS only. Platform-guarded so the file still
    /// compiles for macOS (and watchOS, though the hook is never wired there): AppKit has
    /// no `UIImpactFeedbackGenerator`, so on every non-iOS platform this is a no-op.
    private static func checklistHaptic() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    /// The `.codeBlock` render arm (plan §M9 9b). Consult the pure fence-widget parser:
    /// a recognized fence (`metric`/`chart`/`timeline`/`table`) renders as its real
    /// widget; **`nil` renders today's monospaced panel byte-for-byte unchanged** (the
    /// forward-compat fallback — an unknown info string, a single malformed line, or an
    /// empty fence all degrade the whole fence to the panel the reader already knows).
    @ViewBuilder
    private func codeBlockView(info: String, code: String) -> some View {
        if let widget = FenceWidget.parse(info: info, code: code) {
            FenceWidgetView(widget)
        } else {
            monospacedPanel(info: info, code: code)
        }
    }

    /// The v1 monospaced code panel — the byte-for-byte fallback for any fence the widget
    /// parser doesn't recognize. Unchanged from the pre-9b renderer (an eyebrow of the info
    /// word over the literal lines, in a recessed rounded well).
    private func monospacedPanel(info: String, code: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !info.isEmpty {
                Text(info.uppercased())
                    .font(.hcEyebrow(9.5))
                    .tracking(1.3)
                    .foregroundStyle(Color.hcMutedText)
            }
            Text(code)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Color.hcPrimaryText)
                .fixedSize(horizontal: false, vertical: true)
                .hcTextSelectable()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.hcPanel))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Color.hcCardBorder.opacity(0.6), lineWidth: 1))
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1:  return 22
        case 2:  return 18
        default: return 15.5
        }
    }

    /// Parse one line of inline markdown into an `AttributedString`, tolerating a
    /// parse failure by falling back to the raw text (never throws to the UI). Inline
    /// styling (bold/italic) and links come for free; `ollie://` links are routed by
    /// the `openURL` environment handler above.
    private func inlineAttributed(_ text: String) -> AttributedString {
        // `.inlineOnlyPreservingWhitespace` keeps this line-based: no block parsing,
        // no list/heading interpretation inside a paragraph line (we already did that).
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return attributed
        }
        return AttributedString(text)
    }

    // MARK: - Line classification (the dialect core — pure, unit-tested)

    /// Classify a single line of a view body per the §6 line-based dialect. Pure: the
    /// result depends only on `line` (fence pairing is the block parser's job). This
    /// is the contract the ``MarkdownLineKind`` tests pin down.
    nonisolated public static func classify(line: String) -> MarkdownLineKind {
        // Blank = only whitespace.
        if line.trimmingCharacters(in: .whitespaces).isEmpty {
            return .blank
        }

        // Leading-whitespace-tolerant inspection, but captured text keeps the author's
        // spacing after the marker.
        let trimmedLeading = line.drop { $0 == " " || $0 == "\t" }

        // Code fence: a line whose first non-space content is ``` (three+ backticks).
        if trimmedLeading.hasPrefix("```") {
            let afterTicks = trimmedLeading.drop { $0 == "`" }
            return .fence(info: afterTicks.trimmingCharacters(in: .whitespaces))
        }

        // Headings: #, ##, ### (1–3). More than 3 hashes still reads as level-3 rather
        // than failing — tolerant, and level is clamped.
        if trimmedLeading.hasPrefix("#") {
            let hashes = trimmedLeading.prefix { $0 == "#" }
            let rest = trimmedLeading.dropFirst(hashes.count)
            // A heading needs a space after the hashes (`#Heading` is NOT a heading —
            // it's prose, e.g. a tag). This matches CommonMark's ATX rule loosely.
            if rest.first == " " {
                let level = min(max(hashes.count, 1), 3)
                let text = rest.dropFirst().trimmingCharacters(in: .whitespaces)
                return .heading(level: level, text: text)
            }
        }

        // Checklist BEFORE bullet: `- [ ]` / `- [x]` / `- [X]`.
        if let item = Self.checklistItem(trimmedLeading) {
            return .checklist(checked: item.checked, text: item.text)
        }

        // Plain bullets: `-`, `*`, `+` followed by a space.
        if let first = trimmedLeading.first, "-*+".contains(first) {
            let afterMarker = trimmedLeading.dropFirst()
            if afterMarker.first == " " {
                return .bullet(text: afterMarker.dropFirst().trimmingCharacters(in: .whitespaces))
            }
        }

        // Everything else is prose.
        return .paragraph(text: String(line))
    }

    /// Recognize a checklist line (`- [ ] task` / `- [x] done`) and pull its state +
    /// label, or return nil if it isn't one. Case-insensitive on the `x`.
    nonisolated private static func checklistItem(_ s: Substring) -> (checked: Bool, text: String)? {
        // Marker must be one of - * + then a space then `[`.
        guard let marker = s.first, "-*+".contains(marker) else { return nil }
        var rest = s.dropFirst()
        guard rest.first == " " else { return nil }
        rest = rest.dropFirst().drop { $0 == " " }
        guard rest.first == "[" else { return nil }
        let box = rest.dropFirst()               // after '['
        guard let mark = box.first else { return nil }
        let afterMark = box.dropFirst()
        guard afterMark.first == "]" else { return nil }
        let checked: Bool
        switch mark {
        case " ":            checked = false
        case "x", "X":       checked = true
        default:             return nil           // `[?]` isn't a checklist box
        }
        let label = afterMark.dropFirst().trimmingCharacters(in: .whitespaces)
        return (checked, label)
    }

    // MARK: - Block parsing (fences + list grouping)

    /// Fold the classified lines into renderable ``MarkdownBlock``s: pair code fences
    /// (collecting the literal lines between as a monospaced block), group runs of
    /// bullets/checklist items into one list, coalesce prose, drop blank separators.
    /// Internal (the view uses it); the *classifier* is the public, tested contract.
    nonisolated static func blocks(from source: String) -> [MarkdownBlock] {
        // Split on newlines, preserving empty lines (paragraph separators). Handles
        // both \n and \r\n.
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")

        var blocks: [MarkdownBlock] = []
        var pendingList: [MarkdownBlock.ListItem] = []

        // Document-order occurrence counter per hash16, so `<occ>` is assigned across
        // the WHOLE body (spec §3) — not reset per list. Two identical checklist items
        // anywhere in the body get occ 0, 1, … in the order they appear.
        var occByHash: [String: Int] = [:]

        func flushList() {
            if !pendingList.isEmpty {
                blocks.append(.list(pendingList))
                pendingList.removeAll()
            }
        }

        var i = 0
        while i < lines.count {
            let kind = classify(line: lines[i])
            switch kind {
            case let .fence(openInfo):
                flushList()
                // Collect literal lines until the closing fence (or end of input —
                // an unterminated fence still renders, never errors).
                var body: [String] = []
                var j = i + 1
                var closed = false
                while j < lines.count {
                    if case .fence = classify(line: lines[j]) { closed = true; break }
                    body.append(lines[j])
                    j += 1
                }
                blocks.append(.codeBlock(info: openInfo, code: body.joined(separator: "\n")))
                // Skip past the closing fence when there was one; otherwise we consumed
                // to the end.
                i = closed ? j + 1 : j
                continue

            case let .heading(level, text):
                flushList()
                blocks.append(.heading(level: level, text: text))

            case let .checklist(checked, text):
                // Annotate with the content-derived blockId (spec §3). The hash is over
                // the classifier-captured text (this exact `text`); `occ` is the running
                // document-order ordinal among items sharing that hash.
                let hash = Self.hash16(ofChecklistText: text)
                let occ = occByHash[hash, default: 0]
                occByHash[hash] = occ + 1
                pendingList.append(.init(checked: checked, text: text,
                                         blockId: "cl1:\(hash):\(occ)"))

            case let .bullet(text):
                pendingList.append(.init(checked: nil, text: text, blockId: nil))

            case .blank:
                flushList()   // a blank ends any open list / paragraph run

            case let .paragraph(text):
                flushList()
                blocks.append(.paragraph(text: text))
            }
            i += 1
        }
        flushList()
        return blocks
    }

    /// ``blocks(from:)`` with the optional §M8 8c leading-title suppression applied:
    /// when `viewName` is non-nil and the **first** block is an H1 (`level == 1`) whose
    /// text is case-insensitively equal to `viewName` (both trimmed), that first block
    /// is dropped. `nil` (or a non-matching / non-first / non-H1 leading block) returns
    /// the parse unchanged. Pure — the suppression is the tested contract; the view just
    /// renders whatever this returns.
    ///
    /// Only the *leading* block is ever considered, and only an exact (trimmed,
    /// case-insensitive) match to the view name suppresses it — an H2 with the same
    /// text, a matching H1 that isn't first, or a differently-worded H1 all render.
    nonisolated static func blocks(from source: String,
                                   suppressingLeadingHeading viewName: String?) -> [MarkdownBlock] {
        let parsed = blocks(from: source)
        guard let viewName else { return parsed }
        guard case let .heading(level, text)? = parsed.first, level == 1 else { return parsed }
        let a = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = viewName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard a.caseInsensitiveCompare(b) == .orderedSame else { return parsed }
        return Array(parsed.dropFirst())
    }

    // MARK: - blockId derivation (content-addressed checklist ids — spec §3)

    /// The `<hash16>` component of a checklist item's `blockId` (`cl1:<hash16>:<occ>`):
    /// the first **16 lowercase hex chars** of SHA-256 over the **UTF-8 bytes of the
    /// item text exactly as ``classify(line:)`` captures it** (post-marker, trimmed,
    /// raw inline markdown — *not* rendered text). Pure and platform-shared (CryptoKit
    /// exists on macOS 10.15+/iOS 13+, well within Core's floor), so the same text
    /// yields the same id on Mac and iPhone — the ids agree by construction (spec §3).
    ///
    /// Reword ⇒ different bytes ⇒ different hash ⇒ the old interaction state detaches and
    /// the item falls back to the body default (fails safe). This is an internal join
    /// key; agents never recompute it (the export/MCP surfaces carry `blockText`).
    nonisolated static func hash16(ofChecklistText text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        // Lowercase hex; take the first 16 characters (= first 8 bytes).
        var hex = ""
        hex.reserveCapacity(16)
        for byte in digest.prefix(8) {
            hex += String(format: "%02x", byte)
        }
        return hex
    }

    /// The set of checklist-item `blockId`s present in a view body, derived exactly as
    /// the renderer derives them (`blocks(from:)` — spec §3, including occurrence
    /// ordinals). Used by the exporter's interaction-prune pass to decide which stored
    /// interaction records still correspond to a live item in a revision. Plain bullets
    /// (no `blockId`) and non-checklist content are excluded.
    nonisolated public static func checklistBlockIds(in source: String) -> Set<String> {
        var ids: Set<String> = []
        for block in blocks(from: source) {
            if case let .list(items) = block {
                for item in items {
                    if let id = item.blockId { ids.insert(id) }
                }
            }
        }
        return ids
    }

    // MARK: - ollie://note/<uuid> citation parsing

    /// Extract the note id from an `ollie://note/<uuid>` citation URL, or nil if the
    /// URL isn't an Ollie note link (or carries a malformed id). The `ollie` scheme +
    /// `note` host are the citation convention (contract §6).
    public static func noteID(fromOllieURL url: URL) -> UUID? {
        guard url.scheme?.lowercased() == "ollie" else { return nil }
        guard url.host?.lowercased() == "note" else { return nil }
        // Path is "/<uuid>"; take the last non-empty path component.
        let last = url.pathComponents.last { $0 != "/" && !$0.isEmpty }
        guard let last else { return nil }
        return UUID(uuidString: last)
    }
}

// MARK: - Watch-safe text selection

private extension View {
    /// Enable text selection on Mac/iOS, no-op on watchOS. `.textSelection(.enabled)`
    /// does not exist on watchOS (this file is path-referenced into the watch target —
    /// plan §M8 8a), so it's guarded here rather than inline; on Mac/iOS the behavior is
    /// byte-for-byte the same as calling `.textSelection(.enabled)` directly.
    @ViewBuilder
    func hcTextSelectable() -> some View {
        #if os(watchOS)
        self
        #else
        self.textSelection(.enabled)
        #endif
    }
}

// MARK: - Fence widget renderers (plan §M9 9b)
//
// The SwiftUI **renderers** for the M9 view-body fence widgets (the pure grammar + parser
// live in `FenceWidgets.swift`, 9a). `codeBlockView` above calls `FenceWidget.parse`; a
// non-`nil` result is drawn by ``FenceWidgetView`` here, a `nil` result stays the existing
// monospaced panel (`monospacedPanel`, byte-for-byte unchanged).
//
// Five widgets, one per known fence:
//   • metric   → big-number cards, wrapping 2–3 per row (label small, value large, delta
//                small beside the value).
//   • chart    → horizontal bars scaled to the fence's max value (label left, value at the
//                bar end). Plain `Capsule`s + `Text` — **no Swift Charts**.
//   • timeline → a vertical dotted timeline: dot + `when` (verbatim) + text per entry.
//   • table    → a simple `Grid`, header row bolded, thin hairline separators.
//   • diagram  → a vertical directed flow (M10): rounded-rect node boxes laid out top→down
//                in topological layers (Kahn; on a cycle, first-appearance order), a downward
//                arrow between layers, edge labels on the connector below their source. Pure
//                SwiftUI stacks/shapes — **no Canvas, no Charts**.
//
// Kept **inline in this file** (rather than a sibling `FenceWidgetViews.swift`) on purpose:
// only `MarkdownLite.swift` is path-referenced into the watch target (plan §M8 8a), so
// folding the renderers in here means the watch's loose-source list needs no extra file —
// it already compiles this one. (`FenceWidgets.swift`, the 9a parser, is the one further
// dependency the watch target must add alongside it.)
//
// **Watch-safe by construction:** SwiftUI + `Theme.swift` tokens only — no AppKit / UIKit /
// Swift Charts. Sizes are relative and there are no fixed wide frames, so the exact same
// body renders on a 40mm watch and a Mac window (`.frame(maxWidth: .infinity)` + wrapping,
// never a hard-coded width). `Grid`, `Capsule`, `RoundedRectangle`, `LazyVGrid` all exist
// on macOS 14 / iOS 17 / watchOS 10.
//
// Each widget carries an `.accessibilityLabel` summarizing its data (plan §M9 9b) so a
// VoiceOver reader hears "3 metrics: Captured this week 23 up 8; …" rather than a pile of
// unlabeled shapes. The widgets are pure value pictures — no `@Observable` state is mutated
// during render (the views-v2 render-loop landmine, spec §10), so they're safe in any body.

/// Draws a parsed ``FenceWidget`` (plan §M9 9b). Thin dispatch over the four cases; each
/// concrete widget is its own subview below. Themed with `Theme.swift` tokens so a widget
/// looks native to the app, not foreign.
struct FenceWidgetView: View {
    let widget: FenceWidget
    init(_ widget: FenceWidget) { self.widget = widget }

    var body: some View {
        switch widget {
        case let .metric(cards):
            MetricWidget(cards: cards)
        case let .chart(bars):
            ChartWidget(bars: bars)
        case let .timeline(entries):
            TimelineWidget(entries: entries)
        case let .table(header, rows):
            TableWidget(header: header, rows: rows)
        case let .diagram(diagram):
            DiagramWidget(diagram: diagram)
        }
    }
}

// MARK: metric

/// Big-number metric cards wrapping 2 per row. Each card: a small muted label above a large
/// serif value, with the optional delta small beside it. A fixed column count keeps a card
/// legible on a 40mm watch — the row width flexes, the column count doesn't.
private struct MetricWidget: View {
    let cards: [FenceWidget.MetricCard]

    var body: some View {
        // 2 per row so a single card is at least half the (already narrow) container —
        // readable on a 40mm watch; on a wide Mac window the cards simply grow. §M9 9b's
        // "2–3 per row" — we take the low end so the watch never gets a 3-up squeeze.
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .topLeading),
                            count: 2)
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                MetricCardView(card: card)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.summary(cards))
    }

    /// A VoiceOver summary: "3 metrics: Captured this week 23, up 8; Open loops 5; …".
    static func summary(_ cards: [FenceWidget.MetricCard]) -> String {
        let items = cards.map { card -> String in
            var s = "\(card.label) \(card.value)"
            if let delta = card.delta { s += ", \(spokenDelta(delta))" }
            return s
        }
        return "\(cards.count) metric\(cards.count == 1 ? "" : "s"): " + items.joined(separator: "; ")
    }
}

/// One metric card: label (small, muted) over value (large, serif) + optional delta chip.
private struct MetricCardView: View {
    let card: FenceWidget.MetricCard

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(card.label)
                .font(.hcEyebrow(9.5))
                .tracking(0.8)
                .foregroundStyle(Color.hcMutedText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(card.value)
                    .font(.hcDisplay(24, weight: .semibold))
                    .foregroundStyle(Color.hcPrimaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let delta = card.delta {
                    Text(delta)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(deltaColor(delta))
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.hcPanel))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Color.hcCardBorder.opacity(0.6), lineWidth: 1))
    }
}

/// Delta tint by direction, read from the leading sign (verbatim token — we never parse the
/// number): `+…` reads as the calm-green "up", `-…`/`−…` as the warm-red "down", anything
/// else stays secondary. Deliberately shallow — the delta text is shown exactly as authored.
private func deltaColor(_ delta: String) -> Color {
    let t = delta.trimmingCharacters(in: .whitespaces)
    if t.hasPrefix("+") { return .hcOk }
    if t.hasPrefix("-") || t.hasPrefix("\u{2212}") { return .syncDanger } // -, − minus sign
    return .hcSecondaryText
}

/// Speak a delta for VoiceOver: `+8` → "up 8", `-3` → "down 3", else verbatim.
private func spokenDelta(_ delta: String) -> String {
    let t = delta.trimmingCharacters(in: .whitespaces)
    if t.hasPrefix("+") { return "up " + t.dropFirst().trimmingCharacters(in: .whitespaces) }
    if t.hasPrefix("-") { return "down " + t.dropFirst().trimmingCharacters(in: .whitespaces) }
    if t.hasPrefix("\u{2212}") { return "down " + t.dropFirst().trimmingCharacters(in: .whitespaces) }
    return t
}

// MARK: chart

/// Horizontal bars scaled to the fence's max value: label on the left, a coral bar whose
/// length is `value / max`, the value at the bar's end. Plain `Capsule` + `Text` — no Swift
/// Charts. Scaling happens here (the parser keeps raw `Double`s, §M9 9a).
private struct ChartWidget: View {
    let bars: [FenceWidget.ChartBar]

    var body: some View {
        // Scale to the max magnitude so a bar is never wider than its track. Guard the
        // all-zero / empty case (denominator 0) — those bars render as an empty track.
        let maxValue = bars.map { abs($0.value) }.max() ?? 0
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(bars.enumerated()), id: \.offset) { _, bar in
                ChartBarView(bar: bar, fraction: maxValue > 0 ? abs(bar.value) / maxValue : 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.hcPanel))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Color.hcCardBorder.opacity(0.6), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.summary(bars))
    }

    /// A VoiceOver summary: "Bar chart, 3 bars: Mon 12; Tue 8; Wed 15".
    static func summary(_ bars: [FenceWidget.ChartBar]) -> String {
        let items = bars.map { "\($0.label) \(formatChartValue($0.value))" }
        return "Bar chart, \(bars.count) bar\(bars.count == 1 ? "" : "s"): " + items.joined(separator: "; ")
    }
}

/// One chart row: label (fixed-share on the left), a track with a filled coral bar, and the
/// value at the bar's trailing edge. `GeometryReader` sizes the bar to the row's own width,
/// so the same row works on a watch and a Mac — no hard-coded bar width.
private struct ChartBarView: View {
    let bar: FenceWidget.ChartBar
    let fraction: Double

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(bar.label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.hcSecondaryText)
                .lineLimit(1)
                .frame(width: 72, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.hcCardBorder.opacity(0.35))
                    Capsule()
                        .fill(Color.hcAccent)
                        // At least a sliver so a nonzero-but-tiny bar is visible; a true
                        // zero (or an all-zero fence) stays empty.
                        .frame(width: fraction > 0
                               ? max(3, geo.size.width * CGFloat(fraction.clamped01))
                               : 0)
                }
            }
            .frame(height: 12)
            Text(formatChartValue(bar.value))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.hcPrimaryText)
                .lineLimit(1)
                .frame(minWidth: 28, alignment: .trailing)
        }
    }
}

/// Format a chart value for display: drop a trailing `.0` so `12.0` reads `12`, keep real
/// fractions (`3.5`). Locale-independent to match the parser's `.`-decimal reading.
private func formatChartValue(_ value: Double) -> String {
    if value == value.rounded() && abs(value) < 1e15 {
        return String(Int(value))
    }
    return String(value)
}

// MARK: timeline

/// A vertical dotted timeline: each entry is a dot on a rail, the `when` (verbatim), and the
/// text. The rail is drawn as a coral dot plus a short dotted connector down the leading edge
/// (dotted, not a solid line) so it reads as a timeline at a glance.
private struct TimelineWidget: View {
    let entries: [FenceWidget.TimelineEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                TimelineRow(entry: entry, isLast: index == entries.count - 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.summary(entries))
    }

    /// A VoiceOver summary: "Timeline, 3 entries: 09:00 Stand-up; 10:30 Review; …".
    static func summary(_ entries: [FenceWidget.TimelineEntry]) -> String {
        let items = entries.map { "\($0.when) \($0.text)" }
        return "Timeline, \(entries.count) entr\(entries.count == 1 ? "y" : "ies"): "
            + items.joined(separator: "; ")
    }
}

/// One timeline entry: the rail (dot + a short dotted connector to the next entry) beside the
/// `when` label and the entry text.
private struct TimelineRow: View {
    let entry: FenceWidget.TimelineEntry
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // The rail: a coral dot, then a dotted connector down to the next entry (small
            // muted dots, omitted on the last row so the rail ends cleanly).
            VStack(spacing: 3) {
                Circle()
                    .fill(Color.hcAccent)
                    .frame(width: 8, height: 8)
                    .padding(.top, 3)
                if !isLast {
                    VStack(spacing: 3) {
                        ForEach(0..<3, id: \.self) { _ in
                            Circle()
                                .fill(Color.hcCardBorder)
                                .frame(width: 2.5, height: 2.5)
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.when)
                    .font(.hcEyebrow(10))
                    .tracking(0.4)
                    .foregroundStyle(Color.hcAccent)
                Text(entry.text)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.hcPrimaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, isLast ? 0 : 10)
            Spacer(minLength: 0)
        }
    }
}

// MARK: table

/// A simple grid: header row bolded, thin hairline separators under the header and between
/// rows. Uses SwiftUI `Grid` (macOS 14 / iOS 17 / watchOS 10). Ragged rows are padded to the
/// header's column count (the parser keeps them as-authored, §M9 9a).
private struct TableWidget: View {
    let header: [String]
    let rows: [[String]]

    var body: some View {
        let columnCount = max(header.count, rows.map(\.count).max() ?? 0)
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 0) {
            GridRow {
                ForEach(0..<columnCount, id: \.self) { col in
                    Text(cell(header, col))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.hcPrimaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 6)
            Divider().overlay(Color.hcCardBorder)
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                GridRow {
                    ForEach(0..<columnCount, id: \.self) { col in
                        Text(cell(row, col))
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color.hcSecondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 6)
                if index < rows.count - 1 {
                    Divider().overlay(Color.hcCardBorder.opacity(0.4))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.hcPanel))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Color.hcCardBorder.opacity(0.6), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.summary(header: header, rows: rows))
    }

    /// Safe cell access — a ragged row shorter than the column count reads as an empty cell
    /// (the parser keeps rows as-authored; the renderer pads, §M9 9a).
    private func cell(_ row: [String], _ col: Int) -> String {
        col < row.count ? row[col] : ""
    }

    /// A VoiceOver summary: "Table, 2 columns, 2 rows. Columns: Task, Owner.".
    static func summary(header: [String], rows: [[String]]) -> String {
        let cols = header.filter { !$0.isEmpty }
        var s = "Table, \(header.count) column\(header.count == 1 ? "" : "s"), "
            + "\(rows.count) row\(rows.count == 1 ? "" : "s")."
        if !cols.isEmpty { s += " Columns: " + cols.joined(separator: ", ") + "." }
        return s
    }
}

// MARK: diagram

/// A vertical directed flow (M10). Nodes are rounded-rect boxes laid out top→down in
/// **topological layers** (Kahn's algorithm over the edges); a downward arrow separates the
/// layers, and each edge's label rides the connector below its source layer. On a **cycle**
/// (Kahn can't order it) the layout falls back to a single column in first-appearance order —
/// it still renders every node and edge label, it just doesn't claim a layering it can't have.
///
/// Nodes within a layer sit side by side in one row (parallel branches), so a fan-out like
/// `A -> B` / `A -> C` shows B and C on the row under A. Everything is SwiftUI stacks +
/// `RoundedRectangle` with `Theme` tokens — no `Canvas`, no `Charts` — and there are no fixed
/// wide frames, so the same body renders on a 40mm watch and a Mac window. The whole widget is
/// one `.accessibilityLabel` summarizing the flow (edges spoken as "A to B via label").
private struct DiagramWidget: View {
    let diagram: FenceWidget.Diagram

    var body: some View {
        // Lay the nodes into rows once (pure; no observed state touched — render-loop-safe).
        let layout = DiagramLayout(diagram)
        VStack(alignment: .leading, spacing: 0) {
            if let title = diagram.title, !title.isEmpty {
                Text(title)
                    .font(.hcEyebrow(10))
                    .tracking(1.1)
                    .foregroundStyle(Color.hcMutedText)
                    .padding(.bottom, 10)
            }
            ForEach(Array(layout.layers.enumerated()), id: \.offset) { index, layer in
                DiagramLayerRow(ids: layer)
                // The connector below this layer: a downward arrow plus any labels of edges
                // that leave this layer. Omitted under the last layer (nothing below it).
                if index < layout.layers.count - 1 {
                    DiagramConnector(labels: layout.connectorLabels[index] ?? [])
                }
            }
            // Any labels whose source sits in the LAST layer (only possible via the cycle
            // fallback's single column, e.g. a back-edge from the final node) can't ride a
            // between-layer connector — surface them here so no edge label is ever dropped.
            if let residual = layout.residualLabels, !residual.isEmpty {
                DiagramConnector(labels: residual, showArrow: false)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.hcPanel))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Color.hcCardBorder.opacity(0.6), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.summary(diagram))
    }

    /// A VoiceOver summary: "Diagram 'Capture flow', 3 nodes: A, B, C. A to B via label; B to C.".
    static func summary(_ diagram: FenceWidget.Diagram) -> String {
        var s = "Diagram"
        if let title = diagram.title, !title.isEmpty { s += " \u{201C}\(title)\u{201D}" }
        let names = diagram.nodes.map(\.id)
        s += ", \(names.count) node\(names.count == 1 ? "" : "s"): " + names.joined(separator: ", ") + "."
        if !diagram.edges.isEmpty {
            let flows = diagram.edges.map { edge -> String in
                var f = "\(edge.from) to \(edge.to)"
                if let label = edge.label { f += " via \(label)" }
                return f
            }
            s += " " + flows.joined(separator: "; ") + "."
        }
        return s
    }
}

/// One horizontal row of node boxes — a topological layer (or a single node in the cycle
/// fallback). Wraps the boxes so a wide layer doesn't overflow a narrow watch; a lone node
/// simply left-aligns.
private struct DiagramLayerRow: View {
    let ids: [String]

    var body: some View {
        // A wrapping HStack via `HStackWrap` would need a custom layout; for the small caps
        // (≤16 nodes total) a plain HStack that lets boxes shrink is enough and simplest. Most
        // layers are 1–3 wide. `Spacer` keeps a short row left-aligned.
        HStack(alignment: .top, spacing: 8) {
            ForEach(Array(ids.enumerated()), id: \.offset) { _, id in
                DiagramNodeBox(text: id)
            }
            Spacer(minLength: 0)
        }
    }
}

/// A single rounded-rect node box: the node id as its label, in a soft raised panel with a
/// coral hairline so the flow reads as connected cards. Compact type + wrapping so a
/// multi-word quoted id stays legible on a watch without a fixed width.
private struct DiagramNodeBox: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.hcPrimaryText)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.hcPanelRaised))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.hcAccent.opacity(0.55), lineWidth: 1))
    }
}

/// The between-layer connector: a downward arrow glyph with any edge labels leaving the layer
/// above stacked beside it. Kept short and muted so it reads as "flows down (via …)" without
/// competing with the node boxes.
private struct DiagramConnector: View {
    let labels: [String]
    var showArrow: Bool = true

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            if showArrow {
                Image(systemName: "arrow.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.hcAccent.opacity(0.8))
            }
            if !labels.isEmpty {
                Text(labels.joined(separator: ", "))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.hcSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 10)   // sit the arrow under the leading edge of the boxes above.
        .padding(.vertical, 5)
    }
}

/// Pure layout for a ``FenceWidget/Diagram``: assigns nodes to vertical layers and maps each
/// edge label to the connector below its source layer. Foundation-only value computation (no
/// SwiftUI, no observed state) so it's render-loop-safe and could be unit-tested in isolation.
///
/// Layering is **Kahn's algorithm** over the *unique* directed pairs (duplicate edges don't
/// inflate in-degree): repeatedly emit the in-degree-0 nodes (in first-appearance order) as a
/// layer, then remove them. If a cycle blocks progress, the whole layout falls back to a
/// **single column in first-appearance order** — still a faithful, if unlayered, rendering.
private struct DiagramLayout {
    /// Node ids grouped into vertical layers, top → bottom.
    let layers: [[String]]
    /// Labels to show on the connector below layer `i` (edges whose source is in layer `i`).
    let connectorLabels: [Int: [String]]
    /// Labels whose source is in the *last* layer (no connector below it) — shown as a footer
    /// so they're never dropped. `nil`/empty in the common DAG case.
    let residualLabels: [String]?

    init(_ diagram: FenceWidget.Diagram) {
        let ids = diagram.nodes.map(\.id)
        let order = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })

        // Unique directed pairs for degree math (self-loops excluded — they don't order).
        var pairs = Set<[String]>()
        for e in diagram.edges where e.from != e.to { pairs.insert([e.from, e.to]) }

        var indegree: [String: Int] = Dictionary(uniqueKeysWithValues: ids.map { ($0, 0) })
        var successors: [String: [String]] = [:]
        for pair in pairs {
            let (from, to) = (pair[0], pair[1])
            indegree[to, default: 0] += 1
            successors[from, default: []].append(to)
        }

        // Kahn, emitting a whole in-degree-0 frontier per layer (first-appearance order within).
        var computedLayers: [[String]] = []
        var remaining = Set(ids)
        while !remaining.isEmpty {
            let frontier = remaining
                .filter { (indegree[$0] ?? 0) == 0 }
                .sorted { (order[$0] ?? 0) < (order[$1] ?? 0) }
            if frontier.isEmpty { break }   // a cycle blocks progress → fall back below.
            computedLayers.append(frontier)
            for node in frontier {
                remaining.remove(node)
                for succ in successors[node] ?? [] { indegree[succ, default: 1] -= 1 }
            }
        }

        // Cycle fallback: any node left un-emitted means Kahn stalled → single column in
        // first-appearance order (still renders every node; §M10 "on cycle, don't fail").
        let finalLayers = remaining.isEmpty ? computedLayers : ids.map { [$0] }
        self.layers = finalLayers

        // Which layer each node landed in, so an edge's label can find its source layer.
        var layerOf: [String: Int] = [:]
        for (i, layer) in finalLayers.enumerated() {
            for id in layer { layerOf[id] = i }
        }

        // Map each labeled edge to the gap below its source layer; a source in the last layer
        // has no gap below → residual footer. Labels keep authored order (edges are ordered).
        var byLayer: [Int: [String]] = [:]
        var residual: [String] = []
        let lastIndex = finalLayers.count - 1
        for edge in diagram.edges {
            guard let label = edge.label, !label.isEmpty else { continue }
            let src = layerOf[edge.from] ?? 0
            if src < lastIndex {
                byLayer[src, default: []].append(label)
            } else {
                residual.append(label)   // source in (or below) the last layer.
            }
        }
        self.connectorLabels = byLayer
        self.residualLabels = residual.isEmpty ? nil : residual
    }
}

// MARK: helpers

private extension Double {
    /// Clamp to `0...1` for a bar fraction — defensive against a stray value that slips past
    /// the max scaling (e.g. a negative in an otherwise-positive fence).
    var clamped01: Double { Swift.max(0, Swift.min(1, self)) }
}
