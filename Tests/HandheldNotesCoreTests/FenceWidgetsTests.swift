import Foundation
import XCTest
@testable import HandheldNotesCore

/// Pins down the M9 fence-widget **parser** (`FenceWidget.parse(info:code:)`, plan §M9 9a,
/// contract §6.1). The parser is pure and Foundation-only, so these are pure goldens — no
/// SwiftUI. The single most important invariant under test is the forward-compat contract
/// (§6): parsing is tolerant and `nil` ALWAYS means "the caller renders the existing
/// monospaced panel" — an unknown info string, ONE malformed line, or an empty fence all
/// degrade the WHOLE fence to `nil`. It never throws and never strips.
final class FenceWidgetsTests: XCTestCase {

    // MARK: - metric

    func testMetricGoldenWithAndWithoutDelta() {
        // A mix: a card with a (+delta), one without, and one whose value is non-numeric
        // (metric values are kept verbatim as strings — no numeric parse here).
        let code = """
        Captured this week: 23 (+8)
        Open loops: 5
        Longest streak: 12 days
        """
        XCTAssertEqual(FenceWidget.parse(info: "metric", code: code), .metric([
            .init(label: "Captured this week", value: "23", delta: "+8"),
            .init(label: "Open loops", value: "5", delta: nil),
            .init(label: "Longest streak", value: "12 days", delta: nil),
        ]))
    }

    func testMetricDeltaLessLines() {
        // Every line delta-less — the whole fence still parses; deltas are all nil.
        let code = "A: 1\nB: two\nC: 3.5%"
        XCTAssertEqual(FenceWidget.parse(info: "metric", code: code), .metric([
            .init(label: "A", value: "1", delta: nil),
            .init(label: "B", value: "two", delta: nil),
            .init(label: "C", value: "3.5%", delta: nil),
        ]))
    }

    func testMetricValueWithInteriorParensIsNotADelta() {
        // Only a TRAILING `(…)` is the delta. A value that merely contains parens mid-way
        // keeps them (the last char isn't `)`), so no delta is split off.
        let code = "Note: see (page 3) for detail"
        XCTAssertEqual(FenceWidget.parse(info: "metric", code: code), .metric([
            .init(label: "Note", value: "see (page 3) for detail", delta: nil),
        ]))
    }

    func testMetricLineThatIsOnlyParensKeepsThemAsValue() {
        // A value that is ONLY "(…)" has no value before the parens — we never strip the
        // author's sole token to empty, so the parens stay the literal value, delta nil.
        let code = "Trend: (rising)"
        XCTAssertEqual(FenceWidget.parse(info: "metric", code: code), .metric([
            .init(label: "Trend", value: "(rising)", delta: nil),
        ]))
    }

    func testMetricUsesFirstColonSoValuesMayContainColons() {
        // Label is everything before the FIRST colon; a colon in the value survives.
        let code = "ETA: 3:30 PM (soon)"
        XCTAssertEqual(FenceWidget.parse(info: "metric", code: code), .metric([
            .init(label: "ETA", value: "3:30 PM", delta: "soon"),
        ]))
    }

    func testMetricMalformedLineDegradesWholeFenceToNil() {
        // One line without a colon poisons the whole fence — the single-bad-line rule.
        let code = "Good: 1\nthis line has no colon\nAlso good: 2"
        XCTAssertNil(FenceWidget.parse(info: "metric", code: code))
    }

    func testMetricEmptyLabelOrValueIsMalformed() {
        XCTAssertNil(FenceWidget.parse(info: "metric", code: ": 5"))         // empty label
        XCTAssertNil(FenceWidget.parse(info: "metric", code: "Label:"))      // empty value
        XCTAssertNil(FenceWidget.parse(info: "metric", code: "Label:    "))  // whitespace value
    }

    func testMetricBlankLinesInsideAreIgnored() {
        // Blank spacer lines are dropped (the grammar is over nonblank lines), not errors.
        let code = "A: 1\n\n\nB: 2\n"
        XCTAssertEqual(FenceWidget.parse(info: "metric", code: code), .metric([
            .init(label: "A", value: "1", delta: nil),
            .init(label: "B", value: "2", delta: nil),
        ]))
    }

    // MARK: - metric delta-sentiment hint (M12)

    func testMetricSentimentGoodAndBad() {
        // `(-5 good)` / `(+2 bad)`: the hint word is stripped off the delta (the number stays
        // verbatim, sign kept) and recorded as the sentiment override.
        let code = "Weight: 182 (-5 good)\nBugs: 7 (+2 bad)"
        XCTAssertEqual(FenceWidget.parse(info: "metric", code: code), .metric([
            .init(label: "Weight", value: "182", delta: "-5", sentiment: .good),
            .init(label: "Bugs", value: "7", delta: "+2", sentiment: .bad),
        ]))
    }

    func testMetricSentimentWithUnsignedAndScientificNumber() {
        // The hint slot opens after ANY finite numeric token — unsigned, decimal, scientific.
        XCTAssertEqual(FenceWidget.parse(info: "metric", code: "A: 1 (5 good)"), .metric([
            .init(label: "A", value: "1", delta: "5", sentiment: .good),
        ]))
        XCTAssertEqual(FenceWidget.parse(info: "metric", code: "B: 2 (1e3 bad)"), .metric([
            .init(label: "B", value: "2", delta: "1e3", sentiment: .bad),
        ]))
    }

    func testMetricUnknownHintWordDegradesToNil() {
        // A number then a trailing word that ISN'T exactly good/bad occupies the hint slot and
        // is strictly malformed → whole fence nil (this deprecates the old "(5 down)" workaround).
        XCTAssertNil(FenceWidget.parse(info: "metric", code: "A: 1 (5 down)"))
        XCTAssertNil(FenceWidget.parse(info: "metric", code: "A: 1 (-5 great)"))
        XCTAssertNil(FenceWidget.parse(info: "metric", code: "A: 1 (2 Good)"))   // case-sensitive
        XCTAssertNil(FenceWidget.parse(info: "metric", code: "A: 1 (5 good extra)")) // number + 2 words
    }

    func testMetricNoHintIsUnchanged() {
        // Absent hint: today's behavior exactly — a bare numeric delta, sentiment nil.
        XCTAssertEqual(FenceWidget.parse(info: "metric", code: "A: 1 (+8)"), .metric([
            .init(label: "A", value: "1", delta: "+8", sentiment: nil),
        ]))
        // A free-text (non-number-led) delta is kept verbatim, no hint slot, no sentiment.
        XCTAssertEqual(FenceWidget.parse(info: "metric", code: "Trend: up (rising fast)"), .metric([
            .init(label: "Trend", value: "up", delta: "rising fast", sentiment: nil),
        ]))
        // A one-word non-hint delta stays verbatim too (the pre-M12 `(soon)` case).
        XCTAssertEqual(FenceWidget.parse(info: "metric", code: "ETA: 3:30 (soon)"), .metric([
            .init(label: "ETA", value: "3:30", delta: "soon", sentiment: nil),
        ]))
    }

    func testMetricGoodBadAloneIsAVerbatimDeltaNotAHint() {
        // A bare `(good)` / `(bad)` has no numeric head → it is NOT a hint slot; it's a
        // one-word free-text delta kept verbatim (sentiment nil). The hint only applies AFTER
        // a number, per the grammar.
        XCTAssertEqual(FenceWidget.parse(info: "metric", code: "Mood: fine (good)"), .metric([
            .init(label: "Mood", value: "fine", delta: "good", sentiment: nil),
        ]))
    }

    // MARK: - chart

    func testChartGoldenKeepsRawNumbers() {
        // Values are kept raw as Doubles; scaling is the renderer's job (§M9 9a). With no
        // `min:` and a value of 0 in the series, no baseline is declared (declaredMin nil).
        let code = """
        Mon: 12
        Tue: 3.5
        Wed: 0
        """
        XCTAssertEqual(FenceWidget.parse(info: "chart", code: code), .chart(.init(bars: [
            .init(label: "Mon", value: 12),
            .init(label: "Tue", value: 3.5),
            .init(label: "Wed", value: 0),
        ], declaredMin: nil)))
    }

    func testChartAcceptsNegativeAndScientific() {
        let code = "Drop: -4\nBig: 1e3"
        XCTAssertEqual(FenceWidget.parse(info: "chart", code: code), .chart(.init(bars: [
            .init(label: "Drop", value: -4),
            .init(label: "Big", value: 1000),
        ], declaredMin: nil)))
    }

    func testChartNonNumericValueDegradesToNil() {
        // A chart value that isn't a number falls the whole fence back to the panel.
        XCTAssertNil(FenceWidget.parse(info: "chart", code: "Mon: 12\nTue: lots"))
        XCTAssertNil(FenceWidget.parse(info: "chart", code: "Pct: 80%"))     // trailing unit
        XCTAssertNil(FenceWidget.parse(info: "chart", code: "Mon: 1,234"))   // thousands sep
    }

    func testChartMissingColonIsMalformed() {
        XCTAssertNil(FenceWidget.parse(info: "chart", code: "Mon 12"))
    }

    func testChartNonFiniteValueDegradesToNil() {
        // Double(_:) happily parses inf/nan/overflow literals; those must never reach
        // the bar-scaling math as NaN/∞ frame widths — the whole fence falls back.
        XCTAssertNil(FenceWidget.parse(info: "chart", code: "Spike: inf"))
        XCTAssertNil(FenceWidget.parse(info: "chart", code: "Bad: nan"))
        XCTAssertNil(FenceWidget.parse(info: "chart", code: "Huge: 1e400"))
        XCTAssertNil(FenceWidget.parse(info: "chart", code: "Mon: 12\nSpike: -infinity"))
    }

    // MARK: - chart min-baseline (M12)

    /// Unwrap a parsed chart to its ``FenceWidget/Chart`` for baseline assertions, or fail.
    private func parsedChart(_ code: String,
                             file: StaticString = #filePath, line: UInt = #line) -> FenceWidget.Chart? {
        guard case let .chart(chart)? = FenceWidget.parse(info: "chart", code: code) else {
            XCTFail("expected a .chart, got \(String(describing: FenceWidget.parse(info: "chart", code: code)))",
                    file: file, line: line)
            return nil
        }
        return chart
    }

    func testChartMinDirectiveParses() {
        // A `min:` directive line declares the baseline and is NOT itself a bar.
        let code = """
        min: 175
        Mon: 183
        Tue: 178
        """
        guard let chart = parsedChart(code) else { return }
        XCTAssertEqual(chart.bars, [.init(label: "Mon", value: 183), .init(label: "Tue", value: 178)])
        XCTAssertEqual(chart.declaredMin, 175)
        XCTAssertEqual(chart.baseline, 175)          // min < smallest value -> used as-is.
        XCTAssertTrue(chart.hasActiveBaseline)
    }

    func testChartMinDirectiveAnywhereAmongDataLines() {
        // The `min:` line may appear anywhere (here, last) - position doesn't matter.
        guard let chart = parsedChart("Mon: 183\nTue: 178\nmin: 170") else { return }
        XCTAssertEqual(chart.bars.count, 2)
        XCTAssertEqual(chart.declaredMin, 170)
    }

    func testChartDuplicateMinDegradesToNil() {
        // Exactly one `min:` is allowed; a second is an ambiguous baseline -> whole fence nil.
        XCTAssertNil(FenceWidget.parse(info: "chart", code: "min: 1\nmin: 2\nA: 5"))
    }

    func testChartNonFiniteMinDegradesToNil() {
        // A `min:` must parse finite - the existing non-finite rejection applies to it too.
        XCTAssertNil(FenceWidget.parse(info: "chart", code: "min: inf\nA: 5"))
        XCTAssertNil(FenceWidget.parse(info: "chart", code: "min: nan\nA: 5"))
        XCTAssertNil(FenceWidget.parse(info: "chart", code: "min: notanumber\nA: 5"))
    }

    func testChartMinOnlyNoBarsDegradesToNil() {
        // A fence that is only a `min:` line has no data bars -> nil (same as an empty fence).
        XCTAssertNil(FenceWidget.parse(info: "chart", code: "min: 5"))
    }

    func testChartOverDeclaredMinClampsRatherThanClips() {
        // An over-declared min (ABOVE the smallest datum) CLAMPS to the data floor - it never
        // clips a bar to negative height. baseline = min(declaredMin, smallestValue).
        guard let chart = parsedChart("min: 200\nMon: 183\nTue: 178") else { return }
        XCTAssertEqual(chart.declaredMin, 200)
        XCTAssertEqual(chart.baseline, 178)          // clamped down to the smallest value.
        // Every fraction stays within 0...1 - no bar clips past the axis.
        for bar in chart.bars {
            let f = chart.fraction(for: bar.value)
            XCTAssertGreaterThanOrEqual(f, 0)
            XCTAssertLessThanOrEqual(f, 1)
        }
    }

    func testChartAutoBaselineTriggersOnTightSeries() {
        // No `min:`, all positive, spread (183-178)/183 ~ 0.027 < 0.15 -> auto-baseline just
        // below the smallest value (min - 10% of range), floored at 0. The story is preserved.
        guard let chart = parsedChart("Mon: 183\nTue: 178") else { return }
        XCTAssertNil(chart.declaredMin)
        XCTAssertTrue(chart.hasActiveBaseline)       // honesty: the axis MUST be labeled.
        // Baseline sits below the smallest value, above 0.
        XCTAssertLessThan(chart.baseline, 178)
        XCTAssertGreaterThan(chart.baseline, 0)
        // Concretely: range 5, pad 0.5, baseline = 178 - 0.5 = 177.5.
        XCTAssertEqual(chart.baseline, 177.5, accuracy: 1e-9)
        // The taller bar reads as fuller than the shorter one (the story is now visible).
        XCTAssertGreaterThan(chart.fraction(for: 183), chart.fraction(for: 178))
        XCTAssertEqual(chart.fraction(for: 183), 1, accuracy: 1e-9)   // max -> full.
    }

    func testChartNoAutoBaselineOnWideRangeSeries() {
        // A wide spread (min 8, max 15 -> 0.47 >= 0.15) does NOT auto-truncate - zero-based,
        // no active baseline (today's behavior, unchanged).
        guard let chart = parsedChart("Mon: 12\nTue: 8\nWed: 15") else { return }
        XCTAssertNil(chart.declaredMin)
        XCTAssertEqual(chart.baseline, 0)
        XCTAssertFalse(chart.hasActiveBaseline)
    }

    func testChartNoAutoBaselineWhenAValueIsZeroOrNegative() {
        // Auto-baseline is all-positive only; a 0 or a negative present -> no auto (baseline 0).
        guard let withZero = parsedChart("A: 100\nB: 99\nC: 0") else { return }
        XCTAssertEqual(withZero.baseline, 0)
        XCTAssertFalse(withZero.hasActiveBaseline)
        guard let withNeg = parsedChart("A: 100\nB: 99\nC: -1") else { return }
        XCTAssertEqual(withNeg.baseline, 0)
        XCTAssertFalse(withNeg.hasActiveBaseline)
    }

    func testChartNoAutoBaselineForSingleBar() {
        // A single-bar chart can't be "tight" (no spread) - no auto-baseline.
        guard let chart = parsedChart("Only: 42") else { return }
        XCTAssertEqual(chart.baseline, 0)
        XCTAssertFalse(chart.hasActiveBaseline)
    }

    // The crash-class case: the (v-baseline)/(max-baseline) denominator hits zero when all
    // values are equal (and, with a min declared at that value, the baseline == max). The guard
    // must yield 0, never NaN/inf - these would crash SwiftUI frame math.

    func testChartAllEqualValuesNoMinDoesNotDivideByZero() {
        // All-equal data, no min: max == min, auto-baseline can't engage (needs max > min), so
        // baseline is 0 and span is max. Fractions are finite; no NaN.
        guard let chart = parsedChart("A: 100\nB: 100\nC: 100") else { return }
        XCTAssertEqual(chart.baseline, 0)
        XCTAssertEqual(chart.span, 100)
        for bar in chart.bars {
            let f = chart.fraction(for: bar.value)
            XCTAssertTrue(f.isFinite, "fraction must be finite, got \(f)")
            XCTAssertEqual(f, 1, accuracy: 1e-9)   // each equals the max -> full bar.
        }
    }

    func testChartAllEqualValuesWithMinAtValueDoesNotDivideByZero() {
        // The degenerate div-zero case: min declared AT the (all-equal) value -> baseline == max
        // -> span 0. The guard returns 0 for every bar (minimal-height equal bars), NOT NaN/inf.
        guard let chart = parsedChart("min: 100\nA: 100\nB: 100\nC: 100") else { return }
        XCTAssertEqual(chart.baseline, 100)
        XCTAssertEqual(chart.maxValue, 100)
        XCTAssertEqual(chart.span, 0)              // baseline >= max -> zero span.
        for bar in chart.bars {
            let f = chart.fraction(for: bar.value)
            XCTAssertTrue(f.isFinite, "fraction must be finite (no NaN/inf), got \(f)")
            XCTAssertEqual(f, 0)                   // minimal-height equal bars.
        }
        // And a value literally equal to baseline is 0, not NaN.
        XCTAssertEqual(chart.fraction(for: 100), 0)
    }

    func testChartMinAboveAllEqualValuesClampsAndNoNaN() {
        // Over-declared min ABOVE an all-equal series: clamps to the value (baseline == max),
        // span 0, every fraction a finite 0 - belt-and-suspenders on the crash class.
        guard let chart = parsedChart("min: 500\nA: 100\nB: 100") else { return }
        XCTAssertEqual(chart.baseline, 100)        // clamped to the (all-equal) value.
        XCTAssertEqual(chart.span, 0)
        for bar in chart.bars {
            XCTAssertTrue(chart.fraction(for: bar.value).isFinite)
            XCTAssertEqual(chart.fraction(for: bar.value), 0)
        }
    }

    func testChartBaselineLabeledWheneverActive_logicLevel() {
        // The honesty rule at the logic level: hasActiveBaseline is the renderer's signal to
        // LABEL the truncated axis. It's true for BOTH an explicit min and an auto-baseline,
        // and false only when bars genuinely start at zero (nothing to disclose).
        XCTAssertTrue(parsedChart("min: 170\nA: 183\nB: 178")?.hasActiveBaseline ?? false) // explicit
        XCTAssertTrue(parsedChart("A: 183\nB: 178")?.hasActiveBaseline ?? false)            // auto
        XCTAssertFalse(parsedChart("A: 12\nB: 8\nC: 15")?.hasActiveBaseline ?? true)        // zero-based
        // A min declared at exactly 0 is not "active" (bars already start at zero).
        XCTAssertFalse(parsedChart("min: 0\nA: 12\nB: 8")?.hasActiveBaseline ?? true)
    }

    // MARK: - timeline

    func testTimelineEmDashGolden() {
        let code = """
        9:00 — Standup
        Noon — Lunch with Sam
        """
        XCTAssertEqual(FenceWidget.parse(info: "timeline", code: code), .timeline([
            .init(when: "9:00", text: "Standup"),
            .init(when: "Noon", text: "Lunch with Sam"),
        ]))
    }

    func testTimelineHyphenSeparatorGolden() {
        // A space-padded hyphen is an accepted separator too.
        let code = "Mon - shipped it\nTue - fixed the bug"
        XCTAssertEqual(FenceWidget.parse(info: "timeline", code: code), .timeline([
            .init(when: "Mon", text: "shipped it"),
            .init(when: "Tue", text: "fixed the bug"),
        ]))
    }

    func testTimelineEnDashSeparator() {
        let code = "Q1 – planning"   // en dash, tight
        XCTAssertEqual(FenceWidget.parse(info: "timeline", code: code), .timeline([
            .init(when: "Q1", text: "planning"),
        ]))
    }

    func testTimelineWhenIsVerbatimNoDateParsing() {
        // `<when>` is kept exactly as written; the space-padded-hyphen rule means the
        // bare hyphens inside the ISO date do NOT split the line — the em dash does.
        let code = "2026-07-06 — Deployed to prod"
        XCTAssertEqual(FenceWidget.parse(info: "timeline", code: code), .timeline([
            .init(when: "2026-07-06", text: "Deployed to prod"),
        ]))
    }

    func testTimelineFirstSeparatorWins() {
        // Earliest separator by position splits; the remainder (dashes and all) is text.
        let code = "Start — middle — end"
        XCTAssertEqual(FenceWidget.parse(info: "timeline", code: code), .timeline([
            .init(when: "Start", text: "middle — end"),
        ]))
    }

    func testTimelineEmDashBeatsLaterHyphen() {
        // Both a tight em dash and a space-padded hyphen are present; the em dash is
        // earlier, so it wins (first-separator-wins across all three kinds).
        let code = "A—B - C"
        XCTAssertEqual(FenceWidget.parse(info: "timeline", code: code), .timeline([
            .init(when: "A", text: "B - C"),
        ]))
    }

    func testTimelineNoSeparatorDegradesToNil() {
        XCTAssertNil(FenceWidget.parse(info: "timeline", code: "9:00 Standup"))
        // A bare (non-space-padded) hyphen is NOT a separator on its own.
        XCTAssertNil(FenceWidget.parse(info: "timeline", code: "well-being matters"))
    }

    func testTimelineEmptySideIsMalformed() {
        XCTAssertNil(FenceWidget.parse(info: "timeline", code: "— text only"))   // empty when
        XCTAssertNil(FenceWidget.parse(info: "timeline", code: "when only —"))   // empty text
    }

    // MARK: - table

    func testTableWithSeparatorRow() {
        let code = """
        | Task | Owner | Status |
        |------|-------|--------|
        | Ship | Sam | done |
        | Test | Alex | wip |
        """
        XCTAssertEqual(FenceWidget.parse(info: "table", code: code), .table(
            header: ["Task", "Owner", "Status"],
            rows: [["Ship", "Sam", "done"], ["Test", "Alex", "wip"]]
        ))
    }

    func testTableWithoutSeparatorRow() {
        // The separator row is optional; without it, row 2 is body data, not skipped.
        let code = """
        | A | B |
        | 1 | 2 |
        """
        XCTAssertEqual(FenceWidget.parse(info: "table", code: code), .table(
            header: ["A", "B"],
            rows: [["1", "2"]]
        ))
    }

    func testTableAlignmentSeparatorRowSkipped() {
        // A GitHub alignment row (colons) counts as a separator and is skipped.
        let code = "| L | R |\n|:---|---:|\n| a | b |"
        XCTAssertEqual(FenceWidget.parse(info: "table", code: code), .table(
            header: ["L", "R"],
            rows: [["a", "b"]]
        ))
    }

    func testTableHeaderOnly() {
        // Just a header (with or without a separator) is a valid one-row table.
        XCTAssertEqual(FenceWidget.parse(info: "table", code: "| Only | Header |"),
                       .table(header: ["Only", "Header"], rows: []))
        XCTAssertEqual(FenceWidget.parse(info: "table", code: "| Only | Header |\n|---|---|"),
                       .table(header: ["Only", "Header"], rows: []))
    }

    func testTableRaggedRowsKeptAsAuthored() {
        // A short/long body row is kept verbatim (renderer pads) — not an error.
        let code = "| A | B | C |\n| 1 | 2 |\n| x | y | z | w |"
        XCTAssertEqual(FenceWidget.parse(info: "table", code: code), .table(
            header: ["A", "B", "C"],
            rows: [["1", "2"], ["x", "y", "z", "w"]]
        ))
    }

    func testTableInteriorEmptyCellPreserved() {
        // Edge pipes' empty cells are dropped; an interior blank cell survives.
        let code = "| A | B | C |\n| 1 || 3 |"
        XCTAssertEqual(FenceWidget.parse(info: "table", code: code), .table(
            header: ["A", "B", "C"],
            rows: [["1", "", "3"]]
        ))
    }

    func testTableLineWithNoPipeDegradesToNil() {
        let code = "| A | B |\n|---|---|\nthis row has no pipe"
        XCTAssertNil(FenceWidget.parse(info: "table", code: code))
    }

    func testTableSeparatorNotUnderHeaderIsData() {
        // A `---` row that is NOT immediately under the header is a normal (data) row —
        // only the header-adjacent separator is skipped.
        let code = "| A |\n| 1 |\n|---|"
        XCTAssertEqual(FenceWidget.parse(info: "table", code: code), .table(
            header: ["A"],
            rows: [["1"], ["---"]]
        ))
    }

    // MARK: - diagram

    func testDiagramLinearFlowGolden() {
        // The canonical case: a simple A -> B -> C chain, some edges labeled. Nodes come out
        // in first-appearance order; edges keep authored order and carry their labels.
        let code = """
        A -> B: label
        B -> C
        """
        XCTAssertEqual(FenceWidget.parse(info: "diagram", code: code), .diagram(.init(
            title: nil,
            nodes: [.init(id: "A"), .init(id: "B"), .init(id: "C")],
            edges: [.init(from: "A", to: "B", label: "label"),
                    .init(from: "B", to: "C", label: nil)]
        )))
    }

    func testDiagramTitleFirstLine() {
        // A `title:` first line is captured (trimmed) and does not become a node.
        let code = """
        title: Capture flow
        A -> B
        """
        XCTAssertEqual(FenceWidget.parse(info: "diagram", code: code), .diagram(.init(
            title: "Capture flow",
            nodes: [.init(id: "A"), .init(id: "B")],
            edges: [.init(from: "A", to: "B", label: nil)]
        )))
    }

    func testDiagramTitleOnlyFirstLineCountsAsTitle() {
        // "first line only": a `title:` on a LATER line is NOT a title. It carries a colon no
        // unquoted id may hold, so it degrades the whole fence (the strict, predictable path).
        let code = "A -> B\ntitle: too late"
        XCTAssertNil(FenceWidget.parse(info: "diagram", code: code))
    }

    func testDiagramEmptyTitleIsTreatedAsNoTitle() {
        // A bare `title:` (no text) is not malformed — it's simply "no title", and it's still
        // consumed as the first line (so it doesn't try to be a node).
        let code = "title:\nA -> B"
        XCTAssertEqual(FenceWidget.parse(info: "diagram", code: code), .diagram(.init(
            title: nil,
            nodes: [.init(id: "A"), .init(id: "B")],
            edges: [.init(from: "A", to: "B", label: nil)]
        )))
    }

    func testDiagramQuotedIdsAllowSpaces() {
        // Double-quoted ids carry free text (spaces, punctuation) verbatim; quotes stripped.
        let code = "\"Multi word\" -> C: sends"
        XCTAssertEqual(FenceWidget.parse(info: "diagram", code: code), .diagram(.init(
            title: nil,
            nodes: [.init(id: "Multi word"), .init(id: "C")],
            edges: [.init(from: "Multi word", to: "C", label: "sends")]
        )))
    }

    func testDiagramQuotedIdMayContainArrowLikeAndColonText() {
        // Inside quotes, `->` and `:` are literal text, not structure — only the OUTSIDE arrow
        // and the OUTSIDE label colon are structural.
        let code = "\"a -> b\" -> \"c: d\": go"
        XCTAssertEqual(FenceWidget.parse(info: "diagram", code: code), .diagram(.init(
            title: nil,
            nodes: [.init(id: "a -> b"), .init(id: "c: d")],
            edges: [.init(from: "a -> b", to: "c: d", label: "go")]
        )))
    }

    func testDiagramBareNodeLine() {
        // A lone id (no arrow) declares a node with no edges — combined here with an edge.
        let code = """
        A -> B
        D
        """
        XCTAssertEqual(FenceWidget.parse(info: "diagram", code: code), .diagram(.init(
            title: nil,
            nodes: [.init(id: "A"), .init(id: "B"), .init(id: "D")],
            edges: [.init(from: "A", to: "B", label: nil)]
        )))
    }

    func testDiagramFirstAppearanceOrderAcrossEdgesAndBareLines() {
        // Order is the order ids are FIRST seen — as a source, a target, or a bare line — and
        // a repeat mention never re-adds the node.
        let code = """
        B -> C
        A -> B
        C -> A
        """
        XCTAssertEqual(FenceWidget.parse(info: "diagram", code: code), .diagram(.init(
            title: nil,
            nodes: [.init(id: "B"), .init(id: "C"), .init(id: "A")],
            edges: [.init(from: "B", to: "C", label: nil),
                    .init(from: "A", to: "B", label: nil),
                    .init(from: "C", to: "A", label: nil)]
        )))
    }

    func testDiagramCycleParsesOK() {
        // A cycle is valid DATA (the RENDERER falls back to first-appearance order, but the
        // parser has no opinion on layout) — it must parse, not degrade.
        let code = "A -> B\nB -> A"
        XCTAssertEqual(FenceWidget.parse(info: "diagram", code: code), .diagram(.init(
            title: nil,
            nodes: [.init(id: "A"), .init(id: "B")],
            edges: [.init(from: "A", to: "B", label: nil),
                    .init(from: "B", to: "A", label: nil)]
        )))
    }

    func testDiagramSelfLoopParsesOK() {
        // A -> A is one node and one (self) edge — valid data.
        XCTAssertEqual(FenceWidget.parse(info: "diagram", code: "A -> A: retry"), .diagram(.init(
            title: nil,
            nodes: [.init(id: "A")],
            edges: [.init(from: "A", to: "A", label: "retry")]
        )))
    }

    func testDiagramLabelWithColonsAndArrowsIsKeptVerbatim() {
        // The label is everything after the FIRST colon following the target, verbatim — so a
        // label may itself contain `:` and `->`.
        let code = "A -> B: at 3:30, then -> done"
        XCTAssertEqual(FenceWidget.parse(info: "diagram", code: code), .diagram(.init(
            title: nil,
            nodes: [.init(id: "A"), .init(id: "B")],
            edges: [.init(from: "A", to: "B", label: "at 3:30, then -> done")]
        )))
    }

    func testDiagramHyphenAndUnderscoreInUnquotedIds() {
        // The unquoted charset is [A-Za-z0-9_-]; a hyphen/underscore/digits id is fine and a
        // `->` right after a hyphen-ending id still splits (the arrow needs the two chars `->`).
        let code = "step-1_a -> step-2"
        XCTAssertEqual(FenceWidget.parse(info: "diagram", code: code), .diagram(.init(
            title: nil,
            nodes: [.init(id: "step-1_a"), .init(id: "step-2")],
            edges: [.init(from: "step-1_a", to: "step-2", label: nil)]
        )))
    }

    func testDiagramBlankLinesInsideAreIgnored() {
        // Blank spacer lines are dropped (grammar is over nonblank lines), not errors.
        let code = "A -> B\n\n\nB -> C\n"
        XCTAssertEqual(FenceWidget.parse(info: "diagram", code: code), .diagram(.init(
            title: nil,
            nodes: [.init(id: "A"), .init(id: "B"), .init(id: "C")],
            edges: [.init(from: "A", to: "B", label: nil),
                    .init(from: "B", to: "C", label: nil)]
        )))
    }

    // diagram — malformed lines each degrade the WHOLE fence to nil

    func testDiagramDanglingArrowIsMalformed() {
        XCTAssertNil(FenceWidget.parse(info: "diagram", code: "A ->"))       // no target
        XCTAssertNil(FenceWidget.parse(info: "diagram", code: "-> B"))       // no source
        XCTAssertNil(FenceWidget.parse(info: "diagram", code: "A -> "))      // trailing space only
    }

    func testDiagramChainedEdgeIsMalformed() {
        // v1 is one edge per line; a chained `A -> B -> C` has leftover after the target.
        XCTAssertNil(FenceWidget.parse(info: "diagram", code: "A -> B -> C"))
    }

    func testDiagramTwoBareTokensIsMalformed() {
        // Two ids with no arrow between them isn't a node or an edge.
        XCTAssertNil(FenceWidget.parse(info: "diagram", code: "A B"))
    }

    func testDiagramInvalidUnquotedCharIsMalformed() {
        XCTAssertNil(FenceWidget.parse(info: "diagram", code: "A.B -> C"))   // dot not in charset
        XCTAssertNil(FenceWidget.parse(info: "diagram", code: "a b -> c"))   // space in unquoted id
        XCTAssertNil(FenceWidget.parse(info: "diagram", code: "café -> c"))  // non-ASCII unquoted
    }

    func testDiagramUnterminatedQuoteIsMalformed() {
        XCTAssertNil(FenceWidget.parse(info: "diagram", code: "\"unclosed -> B"))
        XCTAssertNil(FenceWidget.parse(info: "diagram", code: "A -> \"unclosed"))
    }

    func testDiagramEmptyQuotedIdIsMalformed() {
        XCTAssertNil(FenceWidget.parse(info: "diagram", code: "\"\" -> B"))
    }

    func testDiagramEmptyLabelIsMalformed() {
        // A `:` after the target with no label text is malformed (mirrors metric's empty value).
        XCTAssertNil(FenceWidget.parse(info: "diagram", code: "A -> B:"))
        XCTAssertNil(FenceWidget.parse(info: "diagram", code: "A -> B:   "))
    }

    func testDiagramOneBadLineDegradesWholeFence() {
        // A good chain with a single garbage line falls the WHOLE fence back to the panel.
        XCTAssertNil(FenceWidget.parse(info: "diagram", code: "A -> B\ngarbage line\nB -> C"))
    }

    func testDiagramEmptyAndTitleOnlyAreNil() {
        XCTAssertNil(FenceWidget.parse(info: "diagram", code: ""))            // empty
        XCTAssertNil(FenceWidget.parse(info: "diagram", code: "   \n \n"))    // all blank
        XCTAssertNil(FenceWidget.parse(info: "diagram", code: "title: Only")) // title, no nodes
    }

    // diagram — cap violations degrade the whole fence

    func testDiagramTooManyNodesIsNil() {
        // 17 distinct nodes across 16 edges exceeds the 16-node cap → nil. (16 edges is within
        // the 24-edge cap, so nodes are the ONLY thing over here.)
        var lines: [String] = []
        for i in 0..<16 { lines.append("N\(i) -> N\(i + 1)") }  // N0..N16 = 17 nodes, 16 edges
        let code = lines.joined(separator: "\n")
        XCTAssertNil(FenceWidget.parse(info: "diagram", code: code))
    }

    func testDiagramExactlySixteenNodesIsOK() {
        // The boundary: 16 nodes (N0..N15) via 15 edges parses (≤16 nodes, ≤24 edges).
        var lines: [String] = []
        for i in 0..<15 { lines.append("N\(i) -> N\(i + 1)") }  // N0..N15 = 16 nodes, 15 edges
        let code = lines.joined(separator: "\n")
        let parsed = FenceWidget.parse(info: "diagram", code: code)
        guard case let .diagram(d)? = parsed else { return XCTFail("expected .diagram, got \(String(describing: parsed))") }
        XCTAssertEqual(d.nodes.count, 16)
        XCTAssertEqual(d.edges.count, 15)
    }

    func testDiagramTooManyEdgesIsNil() {
        // 25 edges between just 2 nodes exceeds the 24-edge cap (nodes stay at 2, well under 16).
        let code = Array(repeating: "A -> B", count: 25).joined(separator: "\n")
        XCTAssertNil(FenceWidget.parse(info: "diagram", code: code))
    }

    func testDiagramExactlyTwentyFourEdgesIsOK() {
        // The boundary: 24 duplicate edges between 2 nodes parses (2 nodes, 24 edges).
        let code = Array(repeating: "A -> B", count: 24).joined(separator: "\n")
        let parsed = FenceWidget.parse(info: "diagram", code: code)
        guard case let .diagram(d)? = parsed else { return XCTFail("expected .diagram, got \(String(describing: parsed))") }
        XCTAssertEqual(d.nodes.count, 2)
        XCTAssertEqual(d.edges.count, 24)
    }

    func testDiagramIdTooLongIsNil() {
        // An id > 24 chars degrades the fence — checked for unquoted and quoted ids alike.
        let longUnquoted = String(repeating: "a", count: 25)
        XCTAssertNil(FenceWidget.parse(info: "diagram", code: "\(longUnquoted) -> B"))
        let longQuoted = String(repeating: "x", count: 25)
        XCTAssertNil(FenceWidget.parse(info: "diagram", code: "\"\(longQuoted)\" -> B"))
    }

    func testDiagramIdExactlyTwentyFourIsOK() {
        // The boundary: a 24-char id is accepted.
        let id24 = String(repeating: "a", count: 24)
        XCTAssertEqual(FenceWidget.parse(info: "diagram", code: "\(id24) -> B"), .diagram(.init(
            title: nil,
            nodes: [.init(id: id24), .init(id: "B")],
            edges: [.init(from: id24, to: "B", label: nil)]
        )))
    }

    func testDiagramLabelTooLongIsNil() {
        // A label > 40 chars degrades the fence.
        let long = String(repeating: "z", count: 41)
        XCTAssertNil(FenceWidget.parse(info: "diagram", code: "A -> B: \(long)"))
    }

    func testDiagramLabelExactlyFortyIsOK() {
        // The boundary: a 40-char label is accepted.
        let label40 = String(repeating: "z", count: 40)
        XCTAssertEqual(FenceWidget.parse(info: "diagram", code: "A -> B: \(label40)"), .diagram(.init(
            title: nil,
            nodes: [.init(id: "A"), .init(id: "B")],
            edges: [.init(from: "A", to: "B", label: label40)]
        )))
    }

    // MARK: - unknown / reserved / empty → nil (the panel fallback)

    func testUnknownInfoStringIsNil() {
        XCTAssertNil(FenceWidget.parse(info: "swift", code: "let x = 1"))
        XCTAssertNil(FenceWidget.parse(info: "mermaid", code: "graph TD;"))
    }

    func testBareFenceEmptyInfoIsNil() {
        // A bare ``` fence (no info) always falls back to the monospaced panel.
        XCTAssertNil(FenceWidget.parse(info: "", code: "anything\ngoes here"))
    }

    func testChecklistFenceIsReservedAndReturnsNil() {
        // `checklist` is still reserved (the cl2: growth path) — never parsed here even
        // when its body looks perfectly well-formed. It stays a forward-compat panel.
        let code = "- [ ] not interactive yet\n- [x] still a panel"
        XCTAssertNil(FenceWidget.parse(info: "checklist", code: code))
    }

    func testInfoStringIsCaseAndWhitespaceInsensitive() {
        // The keyword match is trimmed + case-insensitive, matching how the renderer
        // captures the info word. `Metric`/` metric ` are the metric fence.
        XCTAssertEqual(FenceWidget.parse(info: "Metric", code: "A: 1"),
                       .metric([.init(label: "A", value: "1", delta: nil)]))
        XCTAssertEqual(FenceWidget.parse(info: "  TABLE  ", code: "| A |"),
                       .table(header: ["A"], rows: []))
    }

    // MARK: - empty fence → nil (every grammar)

    func testEmptyFenceIsNilForEveryGrammar() {
        for info in ["metric", "chart", "timeline", "table", "diagram"] {
            XCTAssertNil(FenceWidget.parse(info: info, code: ""), "\(info) empty → nil")
            XCTAssertNil(FenceWidget.parse(info: info, code: "   \n  \n"),
                         "\(info) all-blank → nil")
        }
    }

    // MARK: - mixed valid + garbage → nil (every grammar's single-bad-line rule)

    func testOneGarbageLineAmongValidDegradesEachGrammarToNil() {
        // metric: middle line missing colon
        XCTAssertNil(FenceWidget.parse(info: "metric", code: "A: 1\ngarbage\nB: 2"))
        // chart: middle line non-numeric
        XCTAssertNil(FenceWidget.parse(info: "chart", code: "A: 1\nB: nope\nC: 3"))
        // timeline: middle line no separator
        XCTAssertNil(FenceWidget.parse(info: "timeline", code: "A — x\nB no sep\nC — z"))
        // table: middle line no pipe
        XCTAssertNil(FenceWidget.parse(info: "table", code: "| A |\n| 1 |\nno pipe\n| 2 |"))
        // diagram: middle line neither a node nor an edge
        XCTAssertNil(FenceWidget.parse(info: "diagram", code: "A -> B\nno good here\nB -> C"))
    }

    // MARK: - equatable / value-type sanity

    func testWidgetIsEquatableByValue() {
        let a = FenceWidget.parse(info: "chart", code: "X: 1")
        let b = FenceWidget.parse(info: "chart", code: "X: 1")
        let c = FenceWidget.parse(info: "chart", code: "X: 2")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
