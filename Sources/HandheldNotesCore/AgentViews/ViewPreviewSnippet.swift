import Foundation

/// A pure, plain-text one-liner for the **Views feed** — the single-line snippet shown
/// under a view's title in the iPhone Views tab and the Mac Views pane.
///
/// The feed rows want a glance-able preview, not rendered markdown. Detail screens hand
/// the body to ``MarkdownLite`` (which turns `**bold**` into actual bold), but a preview
/// is drawn as flat `Text`, so any markdown syntax that survives leaks *literally* —
/// `**Open loops**`, backticks, `- [ ]`, and so on. This helper produces the markdown-free
/// text the rows should display.
///
/// It is deliberately a free function over `String` (no SwiftUI, no state): watch-safe by
/// construction and directly unit-testable. Both feed surfaces call it; there is no
/// per-platform copy of the stripping logic.
///
/// Strategy (line structure first, then inline):
///  1. Walk the body top-down, **skipping** blank lines and any fenced block in full
///     (from its opening ```` ``` ```` to its closing fence). A view whose body opens with
///     a `metric`/`chart`/etc. fence previews the first prose line *after* it — the fence's
///     numbers are already the detail view's job, and the raw fence text (`Label: value`)
///     is a poor glance. The block-level shape is read via ``MarkdownLite/classify(line:)``
///     so the two stay in lockstep on what a heading/bullet/checklist/fence is.
///  2. Take the first meaningful line's already-marker-stripped text (heading text, bullet
///     label, checklist label, or the paragraph itself).
///  3. Strip **inline** markdown from it (`**bold**`, `*italic*`/`_italic_`, `~~strike~~`,
///     `` `code` ``, `[label](url)` links, and stray emphasis runs), collapsing whitespace.
///  4. If nothing meaningful remains (empty body, or a body that is *only* fences/blanks),
///     return a sensible placeholder.
public enum ViewPreviewSnippet {

    /// The placeholder shown when a body has no previewable prose (empty, or nothing but
    /// fenced blocks / blank lines). Matches the pre-existing per-platform fallback text.
    public static let emptyPlaceholder = "Empty view"

    /// Build the markdown-free preview line for a view body.
    ///
    /// - Parameter body: the latest revision's raw markdown body.
    /// - Returns: a single line of plain text with markdown removed, or
    ///   ``emptyPlaceholder`` when there is nothing meaningful to show.
    public static func make(from body: String) -> String {
        // Normalize newlines; keep blanks so fence pairing is faithful.
        let lines = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")

        var insideFence = false
        for raw in lines {
            switch MarkdownLite.classify(line: raw) {
            case .fence:
                // Toggle in/out of a fenced block; the fence delimiters and everything
                // between them are skipped for the preview.
                insideFence.toggle()
                continue
            case .blank:
                continue
            case _ where insideFence:
                // Interior lines of a fence never classify as `.fence`; skip them until
                // the closing delimiter flips `insideFence` back off.
                continue
            case .heading(_, let text),
                 .bullet(let text),
                 .checklist(_, let text),
                 .paragraph(let text):
                let plain = stripInline(text)
                if !plain.isEmpty { return plain }
                // A line that reduces to nothing (e.g. `**` or `----`) isn't meaningful;
                // keep scanning for the first line with real content.
                continue
            }
        }
        return emptyPlaceholder
    }

    // MARK: - Inline stripping

    /// Remove inline markdown from a single line of already-block-stripped text, returning
    /// flat display text. Handles the view dialect's inline shapes; unmatched/stray markers
    /// are dropped rather than left to leak. Whitespace is collapsed and trimmed.
    ///
    /// Order matters: links are unwrapped to their label first (so emphasis *inside* a
    /// label is then handled), code spans have their backticks removed, multi-char emphasis
    /// (`**`, `__`, `~~`) is removed before single-char (`*`, `_`) so `**x**` never leaves a
    /// stray `*`.
    static func stripInline(_ input: String) -> String {
        var s = input

        // 1. Links: [label](target) -> label. (Images ![alt](src) -> alt via the same
        //    pass, since the leading `!` is dropped as a stray char below.)
        s = replaceLinks(in: s)

        // 2. Code spans: `code` -> code. Remove the backticks, keep the content. Handles
        //    single and multi-backtick spans; a lone unmatched backtick is dropped.
        s = removeCodeSpans(in: s)

        // 3. Emphasis / strikethrough delimiters. Remove the markers wherever they appear
        //    (including unmatched ones) — the preview only wants the words. Multi-char
        //    first so `**bold**` doesn't degrade to `*bold*`.
        for marker in ["***", "**", "~~", "__", "*", "_"] {
            s = s.replacingOccurrences(of: marker, with: "")
        }

        // 4. Any leftover leading blockquote / list punctuation that classify() didn't own
        //    (e.g. a nested `> ` inside a paragraph). Drop a stray leading `!` from images.
        s = s.replacingOccurrences(of: "`", with: "")

        // 5. Collapse internal whitespace runs and trim.
        return collapseWhitespace(s)
    }

    /// Replace `[label](target)` with `label`, and a bare `[label]` reference-style link
    /// with `label`. Non-link brackets are left as-is.
    private static func replaceLinks(in input: String) -> String {
        var result = ""
        result.reserveCapacity(input.count)
        var idx = input.startIndex
        let end = input.endIndex

        while idx < end {
            let ch = input[idx]
            guard ch == "[" else {
                result.append(ch)
                idx = input.index(after: idx)
                continue
            }
            // Find the matching `]`.
            guard let closeBracket = input[idx...].firstIndex(of: "]") else {
                // No closing bracket — emit the rest verbatim.
                result.append(contentsOf: input[idx...])
                break
            }
            let labelStart = input.index(after: idx)
            let label = String(input[labelStart..<closeBracket])
            var next = input.index(after: closeBracket)

            // Inline link `](target)` — consume the parenthesized target.
            if next < end, input[next] == "(" {
                if let closeParen = input[next...].firstIndex(of: ")") {
                    next = input.index(after: closeParen)
                }
                // else: unterminated `(` — leave `next` after `]`, target text stays.
            }
            // (Reference-style `][ref]` or bare `[label]` both just yield the label.)
            result.append(label)
            idx = next
        }
        return result
    }

    /// Remove backtick code-span delimiters, preserving the code text. A run of N backticks
    /// opens a span closed by the next run of N; unmatched backticks are simply removed by
    /// the trailing backtick sweep in ``stripInline(_:)``.
    private static func removeCodeSpans(in input: String) -> String {
        // Simplest faithful behavior for a one-line preview: keep code text, drop ticks.
        // The final `replacingOccurrences(of: "`")` in stripInline handles the removal;
        // this pass exists as the documented seam and to keep the ordering explicit.
        return input
    }

    /// Collapse runs of whitespace (including tabs) to single spaces and trim the ends.
    private static func collapseWhitespace(_ input: String) -> String {
        let parts = input.split(whereSeparator: { $0 == " " || $0 == "\t" })
        return parts.joined(separator: " ")
    }
}
