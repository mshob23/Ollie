import SwiftUI

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
    }
}

/// A lightweight SwiftUI renderer for the view-body markdown dialect (contract §6).
/// Inject ``onOpenNote`` to receive taps on `ollie://note/<uuid>` citations.
public struct MarkdownLite: View {
    private let source: String
    private let onOpenNote: (UUID) -> Void

    /// - Parameters:
    ///   - source: the view body (markdown in the §6 dialect).
    ///   - onOpenNote: called with the note id when the reader taps an
    ///     `ollie://note/<uuid>` citation. The host routes it to the note detail.
    public init(_ source: String, onOpenNote: @escaping (UUID) -> Void) {
        self.source = source
        self.onOpenNote = onOpenNote
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
                .textSelection(.enabled)

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
            Text(inlineAttributed(item.text))
                .font(.system(size: 15))
                .foregroundStyle(Color.hcPrimaryText)
                .lineSpacing(4)
                .tint(.hcAccent)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
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
                pendingList.append(.init(checked: checked, text: text))

            case let .bullet(text):
                pendingList.append(.init(checked: nil, text: text))

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
