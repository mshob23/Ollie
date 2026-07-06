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

    /// - Parameters:
    ///   - source: the view body (markdown in the §6 dialect).
    ///   - onOpenNote: called with the note id when the reader taps an
    ///     `ollie://note/<uuid>` citation. The host routes it to the note detail.
    ///   - checklist: optional interaction hook (spec §5). **Defaults to nil**, which is
    ///     byte-for-byte the v1 display-only rendering — no existing call site changes.
    ///     Pass one to make checklist boxes tappable (Views panes do; feed/watch previews
    ///     don't).
    public init(
        _ source: String,
        onOpenNote: @escaping (UUID) -> Void,
        checklist: ChecklistHook? = nil
    ) {
        self.source = source
        self.onOpenNote = onOpenNote
        self.checklist = checklist
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(MarkdownLite.blocks(from: source).enumerated()), id: \.offset) { _, block in
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
                .textSelection(.enabled)

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

    private func codeBlockView(info: String, code: String) -> some View {
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
                .textSelection(.enabled)
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
    public static func classify(line: String) -> MarkdownLineKind {
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
    private static func checklistItem(_ s: Substring) -> (checked: Bool, text: String)? {
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
    static func blocks(from source: String) -> [MarkdownBlock] {
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
    static func hash16(ofChecklistText text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        // Lowercase hex; take the first 16 characters (= first 8 bytes).
        var hex = ""
        hex.reserveCapacity(16)
        for byte in digest.prefix(8) {
            hex += String(format: "%02x", byte)
        }
        return hex
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
