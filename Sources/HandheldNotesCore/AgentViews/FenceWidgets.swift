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
    /// `Double` is kept and **scaling is the renderer's job** (§M9 9a). An optional
    /// `min: <number>` directive line declares a truncated baseline (M12), and when none
    /// is given an auto-baseline may kick in for a tight series — either way the bar
    /// fraction is `(value − baseline)/(max − baseline)` and the axis LABELS the baseline
    /// (see ``Chart``). A non-numeric value, a non-finite value, or a second `min:` line
    /// degrades the whole fence to `nil`.
    case chart(Chart)
    /// ` ```timeline ` — a vertical dotted timeline. Each nonblank line is
    /// `<when> — <text>` (em dash `—`, en dash `–`, or a space-padded hyphen ` - `,
    /// first separator wins). `when` is displayed **verbatim** — no date parsing (§M9 9a).
    case timeline([TimelineEntry])
    /// ` ```table ` — a simple grid. GitHub-style pipe rows: the first row is the
    /// `header`, an optional `|---|---|` separator row is tolerated and skipped, the rest
    /// are `rows`. Cells are trimmed; ragged rows are kept as-authored (the renderer pads).
    case table(header: [String], rows: [[String]])
    /// ` ```diagram ` — a simple directed flow (M10). An optional `title:` first line, then
    /// `A -> B: label` edges (label optional) and bare `D` node-only lines; node ids are
    /// unquoted `[A-Za-z0-9_-]+` or `"double-quoted"` free text. `nodes` are in
    /// first-appearance order and `edges` reference them **by id string** (verbatim) — the
    /// renderer does the layout (topological layering, §M10). Caps (≤16 nodes, ≤24 edges,
    /// id ≤24, label ≤40) and any unparseable line degrade the whole fence to `nil`.
    case diagram(Diagram)

    /// One `Label: value (delta)` line of a `metric` fence. `delta` is the trailing
    /// parenthesized token (parentheses stripped, inner text verbatim) or `nil` when the
    /// line carried none. `sentiment` (M12) is an optional trailing `good`/`bad` hint
    /// inside those parens (`(-5 good)`, `(+2 bad)`) that OVERRIDES the sign-based delta
    /// tint — for a metric where "down is good" (a weight cut, a bug count). Absent →
    /// the renderer keeps today's sign-based tint. The number is still kept verbatim in
    /// `delta` (the hint word is stripped off it).
    public struct MetricCard: Equatable, Sendable {
        /// An explicit delta-sentiment hint (M12): the direction the reader should FEEL,
        /// regardless of the number's sign. `.good` tints positive/calm, `.bad` tints
        /// warning — overriding `deltaColor`'s sign reading.
        public enum Sentiment: Equatable, Sendable { case good, bad }
        public var label: String
        public var value: String
        public var delta: String?
        public var sentiment: Sentiment?
        public init(label: String, value: String, delta: String? = nil,
                    sentiment: Sentiment? = nil) {
            self.label = label
            self.value = value
            self.delta = delta
            self.sentiment = sentiment
        }
    }

    /// One `Label: number` line of a `chart` fence. `value` is the raw parsed number;
    /// the renderer scales bars against the fence's max and its (possibly truncated)
    /// baseline.
    public struct ChartBar: Equatable, Sendable {
        public var label: String
        public var value: Double
        public init(label: String, value: Double) {
            self.label = label
            self.value = value
        }
    }

    /// A parsed `chart` fence (M12): the ``ChartBar``s plus an optional author-declared
    /// baseline (`min: <number>`). The struct owns the **pure baseline math** so the
    /// renderer stays a thin picture of it and the honesty/degeneracy rules are unit-tested
    /// without SwiftUI:
    ///
    ///   • **Effective baseline** (``baseline``) = `Swift.min(declaredMin, smallest value)`
    ///     when a `min:` is declared (an over-declared min CLAMPS to the data rather than
    ///     clipping any bar); otherwise an **auto-baseline** for a tight all-positive series
    ///     (`(max−min)/max < 0.15` → just below the smallest value, never below 0); otherwise
    ///     `0` (today's behavior — bars scale from zero).
    ///   • **Div-zero guard** — when `baseline >= max` (degenerate: all-equal data, or a min
    ///     declared at/above the max), ``span`` is 0 and every ``fraction(for:)`` returns 0
    ///     (minimal-height equal bars). NaN/∞ never reaches the renderer's frame math.
    ///   • **Honesty** — ``hasActiveBaseline`` is true whenever ANY baseline (declared or
    ///     auto) is nonzero, so the renderer knows it MUST label the truncated axis.
    public struct Chart: Equatable, Sendable {
        public var bars: [ChartBar]
        /// The author's `min:` directive value, or `nil` when none was declared. Kept raw so
        /// the clamp (`min(declaredMin, smallestValue)`) is computed here, once.
        public var declaredMin: Double?
        public init(bars: [ChartBar], declaredMin: Double? = nil) {
            self.bars = bars
            self.declaredMin = declaredMin
        }

        /// The largest bar value (0 for an empty chart — never constructed, but total).
        public var maxValue: Double { bars.map(\.value).max() ?? 0 }
        /// The smallest bar value (0 for an empty chart).
        public var minValue: Double { bars.map(\.value).min() ?? 0 }

        /// The auto-baseline trigger threshold (M12): a series whose spread is under this
        /// fraction of its max is "tight" enough that zero-based bars hide the story.
        public static let autoBaselineThreshold = 0.15

        /// The effective baseline the bars are measured FROM. Declared `min:` clamps to the
        /// data's smallest value (tolerant — an over-declared min never clips a bar below the
        /// axis); with no `min:`, a tight all-positive series auto-truncates just below its
        /// smallest value; otherwise 0.
        public var baseline: Double {
            if let declaredMin {
                // Clamp: never sit the baseline ABOVE the smallest datum (that would clip a
                // bar to negative height). An over-declared min just pins to the data floor.
                return Swift.min(declaredMin, minValue)
            }
            return autoBaseline
        }

        /// The auto-baseline (no `min:` declared): for an all-positive series tight enough
        /// (`(max−min)/max < threshold`) sit the baseline 10% of the range below the smallest
        /// value, floored at 0; otherwise 0 (zero-based, today's behavior). Pure; guards every
        /// divisor so it can never produce NaN/∞.
        private var autoBaseline: Double {
            let mx = maxValue, mn = minValue
            // Only for a genuinely tight, all-positive, non-degenerate series.
            guard bars.count >= 2, mn > 0, mx > 0, mx > mn else { return 0 }
            guard (mx - mn) / mx < Chart.autoBaselineThreshold else { return 0 }
            let pad = (mx - mn) * 0.1
            return Swift.max(0, mn - pad)
        }

        /// The scaling span `max − baseline`. **Zero** in the degenerate case
        /// (`baseline >= max`) — the renderer must treat a zero span as "all bars minimal",
        /// never divide by it. Never negative (baseline is clamped ≤ minValue ≤ maxValue in
        /// the declared case, and ≤ maxValue in the auto case).
        public var span: Double { Swift.max(0, maxValue - baseline) }

        /// Is a truncated baseline in effect (declared OR auto)? When true the renderer MUST
        /// render the baseline value at the bar base — a truncated axis is never silent
        /// (the M12 honesty rule). A baseline of exactly 0 is NOT "active" (bars already
        /// start at zero; nothing to disclose).
        public var hasActiveBaseline: Bool { baseline != 0 }

        /// The 0…1 fill fraction for one value against the effective baseline:
        /// `(value − baseline)/span`, clamped to 0…1. Returns **0 when `span == 0`** (the
        /// degenerate all-equal / min-at-max case) — the div-zero guard, so NaN never reaches
        /// SwiftUI frame math. A value at/below the baseline reads as 0 (empty bar).
        public func fraction(for value: Double) -> Double {
            guard span > 0 else { return 0 }
            let f = (value - baseline) / span
            return Swift.max(0, Swift.min(1, f))
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

    /// A parsed `diagram` fence (M10): a directed flow of ``Node``s and ``Edge``s plus an
    /// optional `title`. This is the pure value type — **layout is entirely the renderer's
    /// job** (topological layering, arrows, boxes). `nodes` are in first-appearance order
    /// (the order ids are first mentioned, whether as an edge endpoint or a bare line);
    /// `edges` reference nodes **by their id string** (the same normalized id stored in a
    /// ``Node``), preserving authored order.
    public struct Diagram: Equatable, Sendable {
        /// The optional `title:` from the fence's first line (trimmed), or `nil`.
        public var title: String?
        /// The nodes in first-appearance order; ids are de-duplicated (a node mentioned by
        /// several edges appears once). A quoted id keeps its inner text verbatim.
        public var nodes: [Node]
        /// The directed edges in authored order; `from`/`to` are node id strings and `label`
        /// is the optional trimmed text after the edge's `:`.
        public var edges: [Edge]
        public init(title: String? = nil, nodes: [Node], edges: [Edge]) {
            self.title = title
            self.nodes = nodes
            self.edges = edges
        }
    }

    /// One node of a `diagram` fence. `id` is the node's identity **and** its display text
    /// (an unquoted `[A-Za-z0-9_-]+` run, or the inner text of a `"quoted"` id — quotes
    /// stripped, inner text verbatim). Equality/join is by `id`.
    public struct Node: Equatable, Sendable {
        public var id: String
        public init(id: String) { self.id = id }
    }

    /// One directed edge `from -> to` of a `diagram` fence, with an optional trailing
    /// `: label`. `from`/`to` are node id strings (matching a ``Node/id``); `label` is the
    /// trimmed text after the first `:` following the target, or `nil` when the edge carried
    /// none.
    public struct Edge: Equatable, Sendable {
        public var from: String
        public var to: String
        public var label: String?
        public init(from: String, to: String, label: String? = nil) {
            self.from = from
            self.to = to
            self.label = label
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
        case "diagram":  return parseDiagram(code)
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
            var sentiment: MetricCard.Sentiment? = nil
            if rest.hasSuffix(")"), let open = rest.lastIndex(of: "(") {
                let inner = rest[rest.index(after: open)..<rest.index(before: rest.endIndex)]
                    .trimmingCharacters(in: .whitespaces)
                let before = rest[..<open].trimmingCharacters(in: .whitespaces)
                // A well-formed delta needs non-empty parens AND a non-empty value before
                // it (a line that is *only* "(…)" keeps the parens as the literal value —
                // we never strip an author's sole token to nothing).
                if !inner.isEmpty, !before.isEmpty {
                    // Optional trailing sentiment hint (M12): `good`/`bad` after the number,
                    // e.g. `(-5 good)`. `splitDeltaSentiment` returns nil ONLY when the parens
                    // carry a hint slot that isn't exactly `good`/`bad` — that's a strict
                    // malformed case → whole fence nil (never a silent mis-tint).
                    guard let split = splitDeltaSentiment(inner) else { return nil }
                    value = before
                    delta = split.delta
                    sentiment = split.sentiment
                }
            }
            cards.append(MetricCard(label: label, value: value, delta: delta, sentiment: sentiment))
        }
        return cards.isEmpty ? nil : .metric(cards)
    }

    /// `chart`: each nonblank line `Label: number`, plus an optional `min: <number>`
    /// directive line (M12) anywhere among the data lines. Label = before the first colon
    /// (non-empty); the remainder must parse as a `Double` (locale-independent). Raw
    /// numbers are kept — scaling is the renderer's job (§M9 9a). A `min:` line declares the
    /// truncated baseline; **exactly one is allowed** (a second `min:` → nil), it must parse
    /// finite (a non-finite `min:` → nil, the existing number rule), and it never counts as a
    /// data bar. Non-numeric value, missing colon, empty label, or a duplicate/malformed
    /// `min:` → `nil`.
    ///
    /// `min:` is matched the same way a bar line is (a `min` label before the first colon,
    /// case-insensitively) so it reads as ordinary chart-line syntax. This does mean a bar
    /// can't be *labeled* `min` — an acceptable, documented trade for the tiny grammar.
    private static func parseChart(_ code: String) -> FenceWidget? {
        var bars: [ChartBar] = []
        var declaredMin: Double? = nil
        for line in nonblankLines(code) {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let label = line[..<colon].trimmingCharacters(in: .whitespaces)
            let rawValue = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty, !rawValue.isEmpty else { return nil }
            // Parse locale-independently (agents write `1234.5`, never `1.234,5`); reject
            // anything Double can't read (incl. non-finite) — the "one bad line → panel" degrade.
            guard let value = parseNumber(rawValue) else { return nil }
            // The `min:` directive: at most one, finite (parseNumber already enforced finite).
            // A second one is malformed (ambiguous baseline) → whole fence nil.
            if label.lowercased() == "min" {
                guard declaredMin == nil else { return nil }
                declaredMin = value
            } else {
                bars.append(ChartBar(label: label, value: value))
            }
        }
        // A fence that is ONLY a `min:` line (no bars) has no data → nil, same as empty.
        return bars.isEmpty ? nil : .chart(Chart(bars: bars, declaredMin: declaredMin))
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

    /// `diagram` (M10): an optional `title:` first nonblank line, then one edge or bare-node
    /// declaration per nonblank line. Grammar per line (after the optional title):
    ///
    ///   `<node>`                    → declares a node (no edge)
    ///   `<node> -> <node>`          → a directed edge, label nil
    ///   `<node> -> <node>: label`   → a directed edge with a label
    ///
    /// where `<node>` is an unquoted `[A-Za-z0-9_-]+` run **or** a `"double-quoted"` free-text
    /// id (inner text kept verbatim). Nodes accumulate in first-appearance order; edges keep
    /// authored order and reference nodes by id string.
    ///
    /// Tolerant-but-strict (contract §6.1): ANY line that isn't one of those three shapes — a
    /// dangling `->`, a chained `A -> B -> C`, an unclosed quote, an invalid unquoted char, an
    /// empty id, a `:` with no label — degrades the WHOLE fence to `nil`. So does any cap
    /// violation (`> 16` nodes, `> 24` edges, an id `> 24` chars, a label `> 40` chars) and an
    /// empty diagram (no nodes, e.g. a title-only fence). `nil` is the panel-fallback signal.
    private static func parseDiagram(_ code: String) -> FenceWidget? {
        var lines = nonblankLines(code)
        guard !lines.isEmpty else { return nil }

        // Title: ONLY the first nonblank line may be a `title: …` line. A `title:` prefix on
        // any later line is not special — it goes through node parsing (and, carrying a `:`
        // that no unquoted id may contain, degrades the fence, which is the intended strict
        // behavior). The title text is trimmed; an empty title (`title:`) is treated as "no
        // title", never as a malformed line.
        var title: String? = nil
        if let first = lines.first, let t = diagramTitle(first) {
            if !t.isEmpty { title = t }
            lines.removeFirst()
        }

        // Accumulate nodes in first-appearance order (a dictionary guards dupes while the
        // array preserves order) and edges in authored order.
        var nodeOrder: [String] = []
        var seen = Set<String>()
        var edges: [Edge] = []

        func note(_ id: String) -> Bool {
            // Enforce the id-length cap at the point every id enters. `false` = cap blown.
            guard id.count <= maxDiagramIdLength else { return false }
            if !seen.contains(id) {
                seen.insert(id)
                nodeOrder.append(id)
            }
            return true
        }

        for line in lines {
            guard let parsed = parseDiagramLine(line) else { return nil }
            switch parsed {
            case let .node(id):
                guard note(id) else { return nil }
            case let .edge(from, to, label):
                if let label, label.count > maxDiagramLabelLength { return nil }
                guard note(from), note(to) else { return nil }
                edges.append(Edge(from: from, to: to, label: label))
            }
        }

        // Caps + non-empty. A title-only fence has no nodes → nil (empty diagram).
        guard !nodeOrder.isEmpty else { return nil }
        guard nodeOrder.count <= maxDiagramNodes, edges.count <= maxDiagramEdges else { return nil }

        return .diagram(Diagram(title: title,
                                nodes: nodeOrder.map(Node.init(id:)),
                                edges: edges))
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

    /// Split a metric delta's inner text into `(delta, sentiment)` (M12), or `nil` when a
    /// sentiment hint is present but malformed (→ whole fence nil, strict tolerance).
    ///
    /// The hint occupies exactly the position **after a numeric delta**: if `inner`'s first
    /// whitespace-separated token is a finite number and there is trailing text, that trailing
    /// text is the hint slot and MUST be exactly `good` or `bad` — anything else there is
    /// malformed (`nil`). In that case the returned `delta` is the numeric token verbatim
    /// (sign kept). Otherwise the hint slot doesn't exist:
    ///   • a pure numeric delta (`+8`, `-5`, `1e3`) → `(inner, nil)`;
    ///   • a free-text delta not led by a number (`soon`, `rising`, `all time high`) →
    ///     `(inner, nil)` verbatim — today's behavior, untouched.
    /// `inner` is guaranteed non-empty by the caller.
    private static func splitDeltaSentiment(_ inner: String)
        -> (delta: String, sentiment: MetricCard.Sentiment?)? {
        // First token vs. the rest. A locale-independent number has no interior whitespace,
        // so the number (if any) is exactly the first token.
        guard let firstSpace = inner.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
            // Single token: a bare number or a one-word free-text delta — no hint slot.
            return (inner, nil)
        }
        let head = String(inner[..<firstSpace])
        let tail = inner[inner.index(after: firstSpace)...].trimmingCharacters(in: .whitespaces)
        // Only a *numeric* head opens the hint slot. A non-numeric head (a multi-word
        // free-text delta) is kept verbatim, unchanged from pre-M12.
        guard parseNumber(head) != nil, !tail.isEmpty else { return (inner, nil) }
        switch tail {
        case "good": return (head, .good)
        case "bad":  return (head, .bad)
        default:     return nil   // number then a non-hint word → strict malformed.
        }
    }

    // MARK: - Diagram helpers (pure)

    /// Diagram size caps (M10). Deliberately small — a diagram is a *glanceable* flow, not a
    /// graph; a fence that outgrows these degrades to the monospaced panel (still fully
    /// legible) rather than rendering an unreadable tangle on a watch.
    private static let maxDiagramNodes = 16
    private static let maxDiagramEdges = 24
    private static let maxDiagramIdLength = 24
    private static let maxDiagramLabelLength = 40

    /// The arrow token separating a diagram edge's endpoints.
    private static let diagramArrow = "->"

    /// One successfully-parsed diagram line: either a bare node declaration or a directed
    /// edge (optionally labeled). Internal to the parser.
    private enum DiagramLine {
        case node(id: String)
        case edge(from: String, to: String, label: String?)
    }

    /// If `line` is a `title: …` line, return the trimmed title text (possibly empty);
    /// otherwise `nil`. Only the parser's first-line check consults this (title is first-line
    /// only), so a `title:` anywhere else is left to fail node parsing.
    private static func diagramTitle(_ line: String) -> String? {
        // Case-insensitive `title:` prefix, then everything after the first colon, trimmed.
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        guard key == "title" else { return nil }
        return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }

    /// Parse ONE diagram body line into a ``DiagramLine``, or `nil` if it isn't a well-formed
    /// node / edge (the whole-fence-degrades signal). Grammar:
    ///
    ///   `<node>`  |  `<node> -> <node>`  |  `<node> -> <node>: label`
    ///
    /// A `<node>` is a `"double-quoted"` free-text id (inner text verbatim, quotes required to
    /// close) or an unquoted `[A-Za-z0-9_-]+` run. The scan reads a first node; if the
    /// remainder is empty it's a bare node; otherwise the remainder MUST begin with `->`
    /// (outside any quotes), a second node follows, and an optional `: label` (label = the
    /// verbatim trimmed remainder after that colon, and must be non-empty when the colon is
    /// present). Any leftover after the second node that isn't a `: label` (e.g. a chained
    /// `-> C`) is malformed → `nil`. Ids are *not* length-checked here — the caller enforces
    /// the id/label caps so every id (node-only and edge endpoints) is checked in one place.
    private static func parseDiagramLine(_ line: String) -> DiagramLine? {
        let scalars = Array(line)   // index by position; ids may contain non-ASCII (quoted).

        // Read the source node from the start.
        guard let first = scanDiagramNode(scalars, from: skipSpaces(scalars, 0)) else { return nil }
        var i = skipSpaces(scalars, first.next)

        // Bare node: nothing (but trailing spaces) after the first id.
        if i >= scalars.count {
            return .node(id: first.id)
        }

        // Otherwise the next token MUST be the arrow `->`.
        guard matches(scalars, at: i, diagramArrow) else { return nil }
        i = skipSpaces(scalars, i + diagramArrow.count)

        // A second node must follow the arrow.
        guard let second = scanDiagramNode(scalars, from: i) else { return nil }
        i = skipSpaces(scalars, second.next)

        // Optional `: label`. Anything else after the target is malformed (e.g. `-> C` chain,
        // stray text). The colon here is OUTSIDE any quotes (the target's own quotes closed).
        var label: String? = nil
        if i < scalars.count {
            guard scalars[i] == ":" else { return nil }
            let rest = String(scalars[(i + 1)...]).trimmingCharacters(in: .whitespaces)
            guard !rest.isEmpty else { return nil }   // `A -> B:` with no label is malformed.
            label = rest
        }
        return .edge(from: first.id, to: second.id, label: label)
    }

    /// Scan a single node id starting at `start` (which must already be at non-space content).
    /// Returns the id text (quotes stripped for a quoted id; verbatim run for an unquoted one)
    /// and the index just past it, or `nil` if there is no valid id there (empty, unclosed
    /// quote, or an unquoted run with an illegal char / of zero length).
    private static func scanDiagramNode(_ s: [Character], from start: Int)
        -> (id: String, next: Int)? {
        guard start < s.count else { return nil }
        if s[start] == "\"" {
            // Quoted: consume through the closing quote; inner text is verbatim (may be empty?
            // no — an empty `""` id is rejected below). No escape handling in v1 — a `"` ends
            // the id, so an id can't itself contain a quote (fine for node names).
            var j = start + 1
            while j < s.count, s[j] != "\"" { j += 1 }
            guard j < s.count else { return nil }          // unterminated quote → malformed.
            let inner = String(s[(start + 1)..<j])
            guard !inner.isEmpty else { return nil }        // `""` is an empty id → malformed.
            return (inner, j + 1)
        } else {
            // Unquoted run of the id charset. Must be non-empty.
            var j = start
            while j < s.count, isDiagramIdChar(s[j]) { j += 1 }
            guard j > start else { return nil }             // first char wasn't id-legal.
            return (String(s[start..<j]), j)
        }
    }

    /// The unquoted diagram id charset: ASCII letters, digits, `_`, `-`.
    private static func isDiagramIdChar(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "_" || c == "-")
    }

    /// Index of the first non-space character at or after `i` (spaces + tabs).
    private static func skipSpaces(_ s: [Character], _ i: Int) -> Int {
        var j = i
        while j < s.count, s[j] == " " || s[j] == "\t" { j += 1 }
        return j
    }

    /// Does the literal `token` occur in `s` starting exactly at index `i`?
    private static func matches(_ s: [Character], at i: Int, _ token: String) -> Bool {
        let t = Array(token)
        guard i + t.count <= s.count else { return false }
        for k in 0..<t.count where s[i + k] != t[k] { return false }
        return true
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
