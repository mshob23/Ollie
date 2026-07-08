import Foundation
import XCTest
@testable import HandheldNotesCore

/// Golden cases for the Views-feed preview snippet (``ViewPreviewSnippet``) — the pure
/// helper that turns a view body into the markdown-free one-liner shown under the title
/// in the iPhone Views tab and Mac Views pane. The bug it fixes: previews leaking literal
/// markdown (`**Open loops**` with the asterisks showing). Each test pins the plain-text
/// output for one markdown shape.
final class ViewPreviewSnippetTests: XCTestCase {

    // MARK: - The reported bug

    func testBoldLeaksNoAsterisks() {
        // The exact reported symptom: a body whose first line is a bold run.
        XCTAssertEqual(ViewPreviewSnippet.make(from: "**Open loops**"), "Open loops")
    }

    func testBoldInlineWithinProse() {
        XCTAssertEqual(
            ViewPreviewSnippet.make(from: "Today's **three** priorities"),
            "Today's three priorities"
        )
    }

    // MARK: - Emphasis shapes

    func testItalicAsterisk() {
        XCTAssertEqual(ViewPreviewSnippet.make(from: "*just* this"), "just this")
    }

    func testItalicUnderscore() {
        XCTAssertEqual(ViewPreviewSnippet.make(from: "_emphasis_ here"), "emphasis here")
    }

    func testBoldUnderscore() {
        XCTAssertEqual(ViewPreviewSnippet.make(from: "__strong__ word"), "strong word")
    }

    func testStrikethrough() {
        XCTAssertEqual(ViewPreviewSnippet.make(from: "~~done~~ not"), "done not")
    }

    func testBoldItalicTriple() {
        XCTAssertEqual(ViewPreviewSnippet.make(from: "***loud***"), "loud")
    }

    func testMixedEmphasisNoStrayMarkers() {
        XCTAssertEqual(
            ViewPreviewSnippet.make(from: "**bold** and *italic* and `code`"),
            "bold and italic and code"
        )
    }

    // MARK: - Code spans

    func testInlineCode() {
        XCTAssertEqual(ViewPreviewSnippet.make(from: "run `swift test` now"), "run swift test now")
    }

    // MARK: - Headings

    func testHeadingMarkerStripped() {
        XCTAssertEqual(ViewPreviewSnippet.make(from: "# Weekly Review"), "Weekly Review")
    }

    func testHeadingWithInlineMarkdown() {
        XCTAssertEqual(ViewPreviewSnippet.make(from: "## The **big** picture"), "The big picture")
    }

    // MARK: - List & checkbox markers

    func testBulletMarkerStripped() {
        XCTAssertEqual(ViewPreviewSnippet.make(from: "- first item"), "first item")
    }

    func testCheckboxUncheckedMarkerStripped() {
        // `- [ ] task` must lose BOTH the bullet and the `[ ]` box — the old stripper left `[ ]`.
        XCTAssertEqual(ViewPreviewSnippet.make(from: "- [ ] ship it"), "ship it")
    }

    func testCheckboxCheckedMarkerStripped() {
        XCTAssertEqual(ViewPreviewSnippet.make(from: "- [x] shipped"), "shipped")
    }

    func testCheckboxWithInlineMarkdown() {
        XCTAssertEqual(ViewPreviewSnippet.make(from: "- [ ] review **PR** #42"), "review PR #42")
    }

    // MARK: - Links

    func testInlineLinkYieldsLabel() {
        XCTAssertEqual(
            ViewPreviewSnippet.make(from: "see [the note](ollie://note/abc) for context"),
            "see the note for context"
        )
    }

    func testOllieCitationLinkLabel() {
        XCTAssertEqual(
            ViewPreviewSnippet.make(from: "[Open loops](ollie://note/123)"),
            "Open loops"
        )
    }

    // MARK: - Fence-leading bodies

    func testMetricFenceSkippedToProse() {
        // A body that opens with a metric fence should preview the first prose line AFTER it,
        // not the raw `Label: value` fence content.
        let body = """
        ```metric
        Open loops: 7 (+2)
        Closed: 3
        ```
        These are the threads still waiting on you.
        """
        XCTAssertEqual(
            ViewPreviewSnippet.make(from: body),
            "These are the threads still waiting on you."
        )
    }

    func testFenceOnlyBodyFallsBackToPlaceholder() {
        // Nothing but a fence → the placeholder, never leaked fence text.
        let body = """
        ```chart
        Mon: 3
        Tue: 5
        ```
        """
        XCTAssertEqual(ViewPreviewSnippet.make(from: body), ViewPreviewSnippet.emptyPlaceholder)
    }

    func testHeadingBeforeFenceStillWins() {
        // A heading ahead of the fence is the first meaningful line.
        let body = """
        # Metrics
        ```metric
        Open loops: 7
        ```
        """
        XCTAssertEqual(ViewPreviewSnippet.make(from: body), "Metrics")
    }

    // MARK: - Multi-line: first meaningful line wins

    func testFirstMeaningfulLineAfterBlanks() {
        let body = """


        **Open loops**
        second line
        """
        XCTAssertEqual(ViewPreviewSnippet.make(from: body), "Open loops")
    }

    func testEmptyReducingLineSkipped() {
        // A first line that reduces to nothing (stray `**`) is skipped for the next real line.
        let body = """
        **
        real content
        """
        XCTAssertEqual(ViewPreviewSnippet.make(from: body), "real content")
    }

    // MARK: - Empty / whitespace / passthrough

    func testEmptyBodyPlaceholder() {
        XCTAssertEqual(ViewPreviewSnippet.make(from: ""), ViewPreviewSnippet.emptyPlaceholder)
    }

    func testWhitespaceOnlyBodyPlaceholder() {
        XCTAssertEqual(ViewPreviewSnippet.make(from: "   \n\t\n  "), ViewPreviewSnippet.emptyPlaceholder)
    }

    func testPlainTextPassthroughUnchanged() {
        // No markdown at all → returned verbatim (whitespace-collapsed only).
        XCTAssertEqual(
            ViewPreviewSnippet.make(from: "Just a plain sentence."),
            "Just a plain sentence."
        )
    }

    func testInternalWhitespaceCollapsed() {
        XCTAssertEqual(
            ViewPreviewSnippet.make(from: "spaced    out\ttext"),
            "spaced out text"
        )
    }
}
