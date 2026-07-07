import Foundation
import XCTest
@testable import HandheldNotesCore

/// Pins down the **widget-selection logic** of the M9 9b renderer: the exact decision
/// `MarkdownLite`'s `.codeBlock` arm makes for every fence — does this `(info, code)`
/// render as a real widget, or fall back to the plain monospaced panel? SwiftUI layout
/// isn't unit-testable, so we test the pure decision the view consults:
/// `FenceWidget.parse(info:code:)` on the `(info, code)` that `blocks(from:)` produces —
/// the same two values `codeBlockView(info:code:)` passes to the parser. A non-`nil`
/// parse ⇒ the widget renders; `nil` ⇒ the byte-for-byte panel (contract §6 fallback).
///
/// The headline test is `testDemoBodyWithAllFourFencesPlusMalformed`: a single body with
/// all four widget fences plus one deliberately malformed fence, parsed through the real
/// `MarkdownLite.blocks(from:)` block logic, asserting the malformed one stays a plain
/// `.codeBlock` panel and the four valid ones are each recognized as their widget.
final class FenceWidgetSelectionTests: XCTestCase {

    // MARK: - The renderer's decision, expressed purely

    /// The widget the `.codeBlock` arm would draw for a block, or `nil` for the panel —
    /// exactly `codeBlockView`'s `FenceWidget.parse(info:code:)` call. Non-`.codeBlock`
    /// blocks return `nil` too (they aren't fences), but we only ask it of codeBlocks.
    private func widget(for block: MarkdownBlock) -> FenceWidget? {
        guard case let .codeBlock(info, code) = block else { return nil }
        return FenceWidget.parse(info: info, code: code)
    }

    /// Parse a one-fence body and return the widget the renderer would pick (or nil for
    /// the panel). Asserts the body really is a single codeBlock so the selection test
    /// isn't accidentally measuring a mis-parse.
    private func selectedWidget(info: String, body: String) -> FenceWidget?? {
        let src = "```\(info)\n\(body)\n```"
        let blocks = MarkdownLite.blocks(from: src)
        guard blocks.count == 1, case let .codeBlock(gotInfo, code)? = blocks.first else {
            XCTFail("expected a single codeBlock, got \(blocks)")
            return nil
        }
        XCTAssertEqual(gotInfo, info)
        return FenceWidget.parse(info: gotInfo, code: code)
    }

    // MARK: - Each known fence selects its widget

    func testMetricFenceSelectsMetricWidget() {
        let got = selectedWidget(info: "metric", body: "Captured this week: 23 (+8)\nOpen loops: 5")
        guard case .metric(let cards)?? = got else { return XCTFail("expected .metric, got \(String(describing: got))") }
        XCTAssertEqual(cards, [
            .init(label: "Captured this week", value: "23", delta: "+8"),
            .init(label: "Open loops", value: "5", delta: nil),
        ])
    }

    func testChartFenceSelectsChartWidget() {
        let got = selectedWidget(info: "chart", body: "Mon: 12\nTue: 8\nWed: 15")
        guard case .chart(let bars)?? = got else { return XCTFail("expected .chart, got \(String(describing: got))") }
        XCTAssertEqual(bars, [
            .init(label: "Mon", value: 12),
            .init(label: "Tue", value: 8),
            .init(label: "Wed", value: 15),
        ])
    }

    func testTimelineFenceSelectsTimelineWidget() {
        let got = selectedWidget(info: "timeline", body: "09:00 — Stand-up\n10:30 — Review")
        guard case .timeline(let entries)?? = got else { return XCTFail("expected .timeline, got \(String(describing: got))") }
        XCTAssertEqual(entries, [
            .init(when: "09:00", text: "Stand-up"),
            .init(when: "10:30", text: "Review"),
        ])
    }

    func testTableFenceSelectsTableWidget() {
        let got = selectedWidget(info: "table", body: "| Task | Owner |\n|---|---|\n| Ship | Me |")
        guard case .table(let header, let rows)?? = got else { return XCTFail("expected .table, got \(String(describing: got))") }
        XCTAssertEqual(header, ["Task", "Owner"])
        XCTAssertEqual(rows, [["Ship", "Me"]])
    }

    // MARK: - Fallback: these stay the monospaced panel (parse → nil)

    func testUnknownInfoFallsBackToPanel() {
        // A `swift` fence (or any unknown info) is not a widget — nil ⇒ the panel.
        XCTAssertNil(selectedWidget(info: "swift", body: "let x = 1") ?? nil)
    }

    func testChecklistFenceFallsBackToPanel() {
        // `checklist` is reserved (M7 handles plain-markdown checkboxes) — always the panel.
        XCTAssertNil(selectedWidget(info: "checklist", body: "- [ ] a\n- [x] b") ?? nil)
    }

    func testBareFenceFallsBackToPanel() {
        XCTAssertNil(selectedWidget(info: "", body: "plain code\nsecond line") ?? nil)
    }

    func testMalformedMetricFallsBackToPanel() {
        // A metric line with no colon is malformed → the WHOLE fence degrades to the panel
        // (one bad line → nil, §M9 9a). This is the widget-vs-fallback boundary.
        XCTAssertNil(selectedWidget(info: "metric", body: "Captured: 23\nno colon here") ?? nil)
    }

    func testMalformedChartFallsBackToPanel() {
        // A non-numeric chart value degrades the whole fence.
        XCTAssertNil(selectedWidget(info: "chart", body: "Mon: 12\nTue: lots") ?? nil)
    }

    func testEmptyFenceFallsBackToPanel() {
        // An empty fence has no data lines for any grammar → nil ⇒ the panel.
        XCTAssertNil(selectedWidget(info: "metric", body: "") ?? nil)
    }

    // MARK: - The demo body: all four fences + one malformed, one real block walk

    func testDemoBodyWithAllFourFencesPlusMalformed() {
        // A realistic view body exercising every widget plus prose, a heading, and one
        // deliberately MALFORMED metric fence (a line with no colon). Parsed through the
        // actual block logic the renderer uses (`MarkdownLite.blocks(from:)`), then each
        // codeBlock is run through the parser exactly as `codeBlockView` does. The malformed
        // fence must stay a plain `.codeBlock` panel; the four valid ones are recognized.
        let body = """
        # Weekly review

        Some intro prose with an *emphasis*.

        ```metric
        Captured this week: 23 (+8)
        Open loops: 5
        ```

        ```chart
        Mon: 12
        Tue: 8
        Wed: 15
        ```

        ```timeline
        Mon — Kicked off
        Wed — Shipped
        ```

        ```table
        | Task | Owner |
        |------|-------|
        | Ship | Me |
        | Review | You |
        ```

        ```metric
        This line has no colon so the whole fence is malformed
        ```
        """

        let blocks = MarkdownLite.blocks(from: body)

        // Pull the code blocks in document order. There are five fences.
        let codeBlocks = blocks.compactMap { block -> (info: String, code: String)? in
            guard case let .codeBlock(info, code) = block else { return nil }
            return (info, code)
        }
        XCTAssertEqual(codeBlocks.count, 5, "expected five fenced blocks in the demo body")

        // 1) metric → recognized
        guard case .metric(let cards)? = FenceWidget.parse(info: codeBlocks[0].info, code: codeBlocks[0].code) else {
            return XCTFail("first fence should select the metric widget")
        }
        XCTAssertEqual(cards, [
            .init(label: "Captured this week", value: "23", delta: "+8"),
            .init(label: "Open loops", value: "5", delta: nil),
        ])

        // 2) chart → recognized
        guard case .chart(let bars)? = FenceWidget.parse(info: codeBlocks[1].info, code: codeBlocks[1].code) else {
            return XCTFail("second fence should select the chart widget")
        }
        XCTAssertEqual(bars, [.init(label: "Mon", value: 12), .init(label: "Tue", value: 8), .init(label: "Wed", value: 15)])

        // 3) timeline → recognized
        guard case .timeline(let entries)? = FenceWidget.parse(info: codeBlocks[2].info, code: codeBlocks[2].code) else {
            return XCTFail("third fence should select the timeline widget")
        }
        XCTAssertEqual(entries, [.init(when: "Mon", text: "Kicked off"), .init(when: "Wed", text: "Shipped")])

        // 4) table → recognized (separator row skipped)
        guard case .table(let header, let rows)? = FenceWidget.parse(info: codeBlocks[3].info, code: codeBlocks[3].code) else {
            return XCTFail("fourth fence should select the table widget")
        }
        XCTAssertEqual(header, ["Task", "Owner"])
        XCTAssertEqual(rows, [["Ship", "Me"], ["Review", "You"]])

        // 5) malformed metric → nil ⇒ STAYS the plain monospaced panel. The renderer draws
        // `.codeBlock` here; the author's raw line is never dropped.
        XCTAssertEqual(codeBlocks[4].info, "metric")
        XCTAssertNil(
            FenceWidget.parse(info: codeBlocks[4].info, code: codeBlocks[4].code),
            "the malformed fence must fall back to the plain codeBlock panel"
        )
        // And the block really is still a codeBlock (never stripped, never errored).
        if case let .codeBlock(_, code) = blocks.last {
            XCTAssertEqual(code, "This line has no colon so the whole fence is malformed")
        } else {
            XCTFail("the malformed fence must remain a .codeBlock block")
        }
    }

    // MARK: - Info-string tolerance flows through the renderer's decision

    func testWidgetSelectionIsCaseAndWhitespaceInsensitiveOnInfo() {
        // The renderer picks the widget off the classifier-captured info word; the parser
        // normalizes it (trim + lowercase). So `Metric` and ` TABLE ` still select widgets.
        guard case .metric?? = selectedWidget(info: "Metric", body: "A: 1") else {
            return XCTFail("`Metric` should still select the metric widget")
        }
        // A trailing-spaced info survives the classifier's own trim, then the parser's.
        let src = "```  table  \n| H |\n| v |\n```"
        let blocks = MarkdownLite.blocks(from: src)
        guard case let .codeBlock(info, code)? = blocks.first else { return XCTFail("expected a codeBlock") }
        guard case .table? = FenceWidget.parse(info: info, code: code) else {
            return XCTFail("` table ` should still select the table widget")
        }
    }
}
