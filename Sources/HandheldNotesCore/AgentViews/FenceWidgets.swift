import Foundation

// MARK: - FenceWidgets
//
// The pure, watch-safe **parser** for the M9 view-body fence widgets (contract §6.1,
// `docs/agent-contract.md`; plan §M9 9a). Agents author real widgets — metric cards,
// bar charts, timelines, tables — by writing a *known* fenced code block inside a
// `ViewRevisionEntity.body` string:
//
//     ```metric
//     Captured this week: 23 (+8)
//     Open loops: 5
//     ```
//
// This file turns that fence's `(info, code)` into a structured ``FenceWidget`` the
// renderer (9b, `MarkdownLite`'s `.codeBlock` arm) can draw. It is **pure model +
// parser only** — no SwiftUI here — so the grammar is one testable definition and the
// renderer stays a thin picture of it.
//
// **The forward-compat contract is load-bearing (contract §6):** parsing is *tolerant*
// and ``FenceWidget/parse(info:code:)`` returns `nil` to mean **"render today's plain
// monospaced panel."** It NEVER throws, NEVER strips content, NEVER partially renders.
// `nil` is the whole fallback signal — a fence the parser doesn't understand (an unknown
// info string, `checklist`/`table`-with-garbage, an empty body, a single malformed line)
// degrades the *entire* fence to the panel the reader already knows. That "one bad line
// → whole-fence fallback" rule is deliberate: simple, predictable, and it can never
// silently drop the author's data — the reader still sees every raw line in the panel.
//
// Reserved / out of scope (do NOT parse — still forward-compat panels):
//   • `checklist` — reserved for the explicit-id (`cl2:`) interaction growth path; the
//     plain-markdown checkbox layer (M7) already handles interactive checklists outside
//     any fence. A `checklist` fence returns `nil` here.
//   • any other info string (`swift`, ``, `mermaid`, …) — `nil`, unchanged panel.
//
// Watch-safe by construction: Foundation only, no SwiftUI / AppKit / UIKit / Charts, so
// the same parser compiles for macOS 14 / iOS 17 / watchOS 10 (M8 path-references
// `MarkdownLite` — and therefore this — into the watch target).

/// A parsed view-body fence widget (plan §M9 9a). One case per known fence info string;
/// the associated value carries the widget's data in render-ready form (the renderer does
/// layout + scaling, never re-parsing). `Equatable`/`Sendable` and Foundation-only so the
/// grammar is unit-tested without touching any SwiftUI.
///
/// Construct one only through ``parse(info:code:)`` — a `nil` result is the caller's
/// signal to fall back to the existing monospaced panel (contract §6).
public enum FenceWidget: Equatable, Sendable {
    /// ` ```metric ` — big-number cards. Each nonblank line is `Label: value` with an
    /// optional trailing `(delta)` (e.g. `Captured this week: 23 (+8)`). `value` and
    /// `delta` are kept **verbatim as strings** (no numeric parse — a metric value may be
    /// `2m 14s`, `98%`, or `—`); the renderer wraps 2–3 cards per row.
    case metric([MetricCard])
    /// ` ```chart ` — horizontal bars. Each nonblank line is `Label: number`; the raw
    /// `Double` is kept and **scaling to the max is the renderer's job** (§M9 9a). A
    /// non-numeric value anywhere degrades the whole fence to `nil`.
    case chart([ChartBar])
    /// ` ```timeline ` — a vertical dotted timeline. Each nonblank line is
    /// `<when> — <text>` (em dash `—`, en dash `–`, or a space-padded hyphen ` - `,
    /// first separator wins). `when` is displayed **verbatim** — no date parsing (§M9 9a).
    case timeline([TimelineEntry])
    /// ` ```table ` — a simple grid. GitHub-style pipe rows: the first row is the
    /// `header`, an optional `|---|---|` separator row is tolerated and skipped, the rest
    /// are `rows`. Cells are trimmed; ragged rows are kept as-authored (the renderer pads).
    case table(header: [String], rows: [[String]])

    /// One `Label: value (delta)` line of a `metric` fence. `delta` is the trailing
    /// parenthesized token (parentheses stripped, inner text verbatim) or `nil` when the
    /// line carried none.
    public struct MetricCard: Equatable, Sendable {
        public var label: String
        public var value: String
        public var delta: String?
        public init(label: String, value: String, delta: String? = nil) {
            self.label = label
            self.value = value
            self.delta = delta
        }
    }

    /// One `Label: number` line of a `chart` fence. `value` is the raw parsed number;
    /// the renderer scales bars to the fence's max value.
    public struct ChartBar: Equatable, Sendable {
        public var label: String
        public var value: Double
        public init(label: String, value: Double) {
            self.label = label
            self.value = value
        }
    }

    /// One `<when> — <text>` line of a `timeline` fence. `when` is kept verbatim (no
    /// date parsing); `text` is the trimmed remainder after the first separator.
    public struct TimelineEntry: Equatable, Sendable {
        public var when: String
        public var text: String
        public init(when: String, text: String) {
            self.when = when
            self.text = text
        }
    }

    // MARK: - Parse

    /// Parse a fenced code block into a widget, or `nil` to fall back to the monospaced
    /// panel (contract §6 — the sole fallback signal; never throws, never strips).
    ///
    /// - Parameters:
    ///   - info: the fence's info string exactly as `MarkdownLite.classify` captured it
    ///     (trimmed language word — `"metric"`, `"chart"`, `"timeline"`, `"table"`; any
    ///     other value, including `""` and `"checklist"`, yields `nil`).
    ///   - code: the literal lines between the fences, joined with `\n` (as
    ///     `MarkdownLite.blocks(from:)` supplies them).
    /// - Returns: the parsed widget, or `nil` if `info` is unknown **or** any nonblank
    ///   line is malformed for that grammar **or** the fence has no data lines at all.
    ///   A single malformed line degrades the whole fence to `nil` (§M9 9a) — simple and
    ///   predictable, and the reader still sees every raw line in the panel.
    public static func parse(info: String, code: String) -> FenceWidget? {
        // Normalize the info word the same way we'd compare any keyword: trimmed +
        // case-insensitive, so ` ```Metric ` and ` ```metric ` are one thing.
        let keyword = info.trimmingCharacters(in: .whitespaces).lowercased()
        switch keyword {
        case "metric":   return parseMetric(code)
        case "chart":    return parseChart(code)
        case "timeline": return parseTimeline(code)
        case "table":    return parseTable(code)
        default:         return nil   // unknown / "" / reserved "checklist" → panel.
        }
    }

    // MARK: - Per-grammar parsers (each: all-or-nothing, `nil` on the first bad line)

    /// `metric`: each nonblank line `Label: value` with an optional trailing `(delta)`.
    /// Label = everything before the FIRST colon (trimmed, must be non-empty); value =
    /// the remainder (trimmed, must be non-empty); if that remainder ends in a
    /// `(…)` group, the group is the delta (verbatim, parens stripped) and the value is
    /// what precedes it. A nonblank line with no colon, an empty label, or an empty value
    /// is malformed → whole fence `nil`.
    private static func parseMetric(_ code: String) -> FenceWidget? {
        var cards: [MetricCard] = []
        for line in nonblankLines(code) {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let label = line[..<colon].trimmingCharacters(in: .whitespaces)
            let rest = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty, !rest.isEmpty else { return nil }

            // Optional trailing "(delta)": only when the LAST character is ")" and a
            // matching "(" opens the trailing group. Anything else is part of the value.
            var value = rest
            var delta: String? = nil
            if rest.hasSuffix(")"), let open = rest.lastIndex(of: "(") {
                let inner = rest[rest.index(after: open)..<rest.index(before: rest.endIndex)]
                    .trimmingCharacters(in: .whitespaces)
                let before = rest[..<open].trimmingCharacters(in: .whitespaces)
                // A well-formed delta needs non-empty parens AND a non-empty value before
                // it (a line that is *only* "(…)" keeps the parens as the literal value —
                // we never strip an author's sole token to nothing).
                if !inner.isEmpty, !before.isEmpty {
                    value = before
                    delta = inner
                }
            }
            cards.append(MetricCard(label: label, value: value, delta: delta))
        }
        return cards.isEmpty ? nil : .metric(cards)
    }

    /// `chart`: each nonblank line `Label: number`. Label = before the first colon
    /// (non-empty); the remainder must parse as a `Double` (locale-independent). Raw
    /// numbers are kept — scaling is the renderer's job (§M9 9a). Non-numeric value,
    /// missing colon, or empty label → `nil`.
    private static func parseChart(_ code: String) -> FenceWidget? {
        var bars: [ChartBar] = []
        for line in nonblankLines(code) {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let label = line[..<colon].trimmingCharacters(in: .whitespaces)
            let rawValue = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty, !rawValue.isEmpty else { return nil }
            // Parse locale-independently (agents write `1234.5`, never `1.234,5`); reject
            // anything Double can't read — that's the "one bad line → panel" degrade.
            guard let value = parseNumber(rawValue) else { return nil }
            bars.append(ChartBar(label: label, value: value))
        }
        return bars.isEmpty ? nil : .chart(bars)
    }

    /// `timeline`: each nonblank line `<when> — <text>`, split at the first separator —
    /// an em dash `—`, an en dash `–`, or a **space-padded** hyphen ` - `, whichever
    /// appears earliest (first-separator-wins, §M9 9a). The hyphen is required to be
    /// space-padded so a bare hyphen inside `when` (an ISO date `2026-07-06`, a compound
    /// word) does NOT split the line — em/en dashes never appear in dates/numbers, so
    /// they split even when tight. `when` is kept **verbatim** (no date parsing); both
    /// sides must be non-empty. A line with no separator → `nil`.
    private static func parseTimeline(_ code: String) -> FenceWidget? {
        var entries: [TimelineEntry] = []
        for line in nonblankLines(code) {
            guard let sep = firstTimelineSeparator(in: line) else { return nil }
            let when = String(line[..<sep.lowerBound]).trimmingCharacters(in: .whitespaces)
            let text = String(line[sep.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !when.isEmpty, !text.isEmpty else { return nil }
            entries.append(TimelineEntry(when: when, text: text))
        }
        return entries.isEmpty ? nil : .timeline(entries)
    }

    /// `table`: GitHub-style pipe rows. The first data row is the header; an optional
    /// `|---|---|` separator row (every cell only `-`/`:`/space, at least one dash) is
    /// tolerated and skipped; the rest are body rows. A nonblank line with no `|` is
    /// malformed → `nil`. Ragged rows are kept as authored (the renderer pads to the
    /// header width) — raggedness is not an error.
    private static func parseTable(_ code: String) -> FenceWidget? {
        var rowsRaw: [[String]] = []
        for line in nonblankLines(code) {
            guard line.contains("|") else { return nil }
            rowsRaw.append(splitTableRow(line))
        }
        guard let header = rowsRaw.first else { return nil }
        var body = Array(rowsRaw.dropFirst())
        // A separator row is only meaningful immediately under the header; skip it there.
        if let first = body.first, isTableSeparatorRow(first) {
            body.removeFirst()
        }
        return .table(header: header, rows: body)
    }

    // MARK: - Shared helpers (pure)

    /// The nonblank lines of a fence body, in order, each trimmed of trailing whitespace
    /// but keeping interior spacing. Blank lines (all-whitespace) are dropped everywhere —
    /// the grammars are defined over *nonblank* lines (§M9 9a), so blank spacer lines
    /// inside a fence are ignored, never treated as malformed.
    private static func nonblankLines(_ code: String) -> [String] {
        code.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Parse a chart value as a locale-independent `Double`. Uses `Double(_:)` (C locale,
    /// `.`-decimal) so agent-authored `12`, `3.5`, `-4`, `1e3` all read and a stray
    /// `12%`/`n/a` is rejected (→ fence falls back). No thousands separators — agents
    /// don't write them here. Non-finite values (`inf`, `nan`, `1e400`) are rejected too:
    /// they would reach the bar-scaling math in render code as NaN/∞ frame widths.
    private static func parseNumber(_ s: String) -> Double? {
        guard let v = Double(s), v.isFinite else { return nil }
        return v
    }

    /// Find the first timeline separator in a line: the earliest of an em dash `—`, an
    /// en dash `–`, or a space-padded hyphen ` - `. Returns the matched range so the
    /// caller can split around it, or `nil` if the line has none. Em/en dashes match even
    /// when tight (they never occur in dates/numbers); the hyphen only matches with a
    /// space on each side, so ISO dates and compound words in `when` stay intact.
    private static func firstTimelineSeparator(in line: String) -> Range<String.Index>? {
        var best: Range<String.Index>? = nil
        func consider(_ range: Range<String.Index>?) {
            guard let range else { return }
            if let current = best {
                if range.lowerBound < current.lowerBound { best = range }
            } else {
                best = range
            }
        }
        consider(line.range(of: "\u{2014}"))   // — em dash (tight ok)
        consider(line.range(of: "\u{2013}"))   // – en dash (tight ok)
        consider(line.range(of: " - "))         // space-padded hyphen only
        return best
    }

    /// Split a GitHub-style pipe row into trimmed cells, dropping the empty cells that
    /// leading/trailing pipes produce (`| a | b |` → ["a","b"]). Interior empties are
    /// kept (`a || b` → ["a","","b"]) so a deliberately blank cell survives.
    private static func splitTableRow(_ line: String) -> [String] {
        var cells = line.components(separatedBy: "|").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        // A row wrapped in pipes yields a leading and/or trailing empty cell — drop just
        // those edge artifacts, never an interior blank.
        if cells.first == "" { cells.removeFirst() }
        if cells.last == "" { cells.removeLast() }
        return cells
    }

    /// Is this the `|---|:--:|` alignment/separator row? True iff every cell is nonempty
    /// and made only of `-`, `:`, and spaces with at least one `-` — the GitHub table
    /// separator shape. An all-empty split (a bare `|`) is not a separator.
    private static func isTableSeparatorRow(_ cells: [String]) -> Bool {
        guard !cells.isEmpty else { return false }
        var sawDash = false
        for cell in cells {
            if cell.isEmpty { return false }
            for ch in cell {
                switch ch {
                case "-": sawDash = true
                case ":", " ": break
                default: return false
                }
            }
        }
        return sawDash
    }
}
