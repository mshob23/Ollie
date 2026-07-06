import Foundation
import XCTest
@testable import HandheldNotesCore

/// Pins down the **line classifier** of the view-body dialect (contract §6) — the
/// pure core of `MarkdownLite`. Per the plan we unit-test the classifier (and the
/// pure block parser + `ollie://` citation parser), NOT the SwiftUI rendering.
final class MarkdownLiteTests: XCTestCase {

    // MARK: - Headings

    func testHeadingLevelsOneToThree() {
        XCTAssertEqual(MarkdownLite.classify(line: "# Title"), .heading(level: 1, text: "Title"))
        XCTAssertEqual(MarkdownLite.classify(line: "## Section"), .heading(level: 2, text: "Section"))
        XCTAssertEqual(MarkdownLite.classify(line: "### Sub"), .heading(level: 3, text: "Sub"))
    }

    func testHeadingDeeperThanThreeClampsToThree() {
        XCTAssertEqual(MarkdownLite.classify(line: "#### Deep"), .heading(level: 3, text: "Deep"))
    }

    func testHashWithoutSpaceIsNotAHeading() {
        // `#tag` is prose (a hashtag), not a heading — the ATX space rule.
        XCTAssertEqual(MarkdownLite.classify(line: "#tag"), .paragraph(text: "#tag"))
    }

    // MARK: - Bullets

    func testDashBullet() {
        XCTAssertEqual(MarkdownLite.classify(line: "- an item"), .bullet(text: "an item"))
    }

    func testStarAndPlusBullets() {
        XCTAssertEqual(MarkdownLite.classify(line: "* star item"), .bullet(text: "star item"))
        XCTAssertEqual(MarkdownLite.classify(line: "+ plus item"), .bullet(text: "plus item"))
    }

    func testDashWithoutSpaceIsProse() {
        // A leading dash with no following space (e.g. a negative number, an em-dash
        // sentence) is NOT a bullet.
        XCTAssertEqual(MarkdownLite.classify(line: "-5 degrees"), .paragraph(text: "-5 degrees"))
    }

    // MARK: - Checklist (must win over plain bullet)

    func testUncheckedChecklist() {
        XCTAssertEqual(MarkdownLite.classify(line: "- [ ] todo"),
                       .checklist(checked: false, text: "todo"))
    }

    func testCheckedChecklistLowerAndUpperX() {
        XCTAssertEqual(MarkdownLite.classify(line: "- [x] done"),
                       .checklist(checked: true, text: "done"))
        XCTAssertEqual(MarkdownLite.classify(line: "- [X] also done"),
                       .checklist(checked: true, text: "also done"))
    }

    func testChecklistNotConfusedWithBulletedBracketText() {
        // `- [note]` is a bullet whose text starts with a bracket, NOT a checklist
        // (the box must be a single space or x/X).
        XCTAssertEqual(MarkdownLite.classify(line: "- [note] see above"),
                       .bullet(text: "[note] see above"))
    }

    // MARK: - Fences

    func testBareFence() {
        XCTAssertEqual(MarkdownLite.classify(line: "```"), .fence(info: ""))
    }

    func testFenceWithInfoString() {
        // Reserved/unknown fence words are captured as the info string, never errored.
        XCTAssertEqual(MarkdownLite.classify(line: "```checklist"), .fence(info: "checklist"))
        XCTAssertEqual(MarkdownLite.classify(line: "```swift"), .fence(info: "swift"))
    }

    // MARK: - Blank + paragraph

    func testBlankLine() {
        XCTAssertEqual(MarkdownLite.classify(line: ""), .blank)
        XCTAssertEqual(MarkdownLite.classify(line: "    "), .blank)
    }

    func testPlainProse() {
        XCTAssertEqual(MarkdownLite.classify(line: "Just a sentence."),
                       .paragraph(text: "Just a sentence."))
    }

    func testProseWithInlineMarkdownStaysParagraph() {
        // Inline emphasis/links are handled at render time via AttributedString, so
        // the classifier still calls this a paragraph and preserves it verbatim.
        let line = "See **bold** and [a link](https://x.com)."
        XCTAssertEqual(MarkdownLite.classify(line: line), .paragraph(text: line))
    }

    // MARK: - Block parser (fences pair, lists group, prose coalesces)

    func testBlocksGroupConsecutiveListItems() {
        let src = "- one\n- two\n- [ ] three"
        let blocks = MarkdownLite.blocks(from: src)
        XCTAssertEqual(blocks.count, 1)
        guard case let .list(items) = blocks.first else { return XCTFail("expected one list") }
        XCTAssertEqual(items, [
            .init(checked: nil, text: "one"),
            .init(checked: nil, text: "two"),
            .init(checked: false, text: "three"),
        ])
    }

    func testBlocksSeparateListsAcrossBlankLine() {
        let src = "- a\n\n- b"
        let blocks = MarkdownLite.blocks(from: src)
        // A blank line ends the first list, so this is two distinct lists.
        XCTAssertEqual(blocks.count, 2)
        if case let .list(first) = blocks[0] { XCTAssertEqual(first.map(\.text), ["a"]) }
        else { XCTFail("first block should be a list") }
        if case let .list(second) = blocks[1] { XCTAssertEqual(second.map(\.text), ["b"]) }
        else { XCTFail("second block should be a list") }
    }

    func testFenceCapturesLiteralLinesBetweenDelimiters() {
        // An unknown fence's content is captured verbatim (never interpreted) — the
        // forward-compat reservation for Views v2 blocks.
        let src = "before\n```checklist\n- [ ] not a real checkbox\n# not a heading\n```\nafter"
        let blocks = MarkdownLite.blocks(from: src)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[0], .paragraph(text: "before"))
        XCTAssertEqual(blocks[1], .codeBlock(info: "checklist",
                                             code: "- [ ] not a real checkbox\n# not a heading"))
        XCTAssertEqual(blocks[2], .paragraph(text: "after"))
    }

    func testUnterminatedFenceStillRendersToEnd() {
        // A fence with no closing ``` consumes to the end and renders — never errors.
        let src = "```\nline one\nline two"
        let blocks = MarkdownLite.blocks(from: src)
        XCTAssertEqual(blocks, [.codeBlock(info: "", code: "line one\nline two")])
    }

    func testCRLFLineEndingsHandled() {
        let src = "# Heading\r\n\r\nbody text"
        let blocks = MarkdownLite.blocks(from: src)
        XCTAssertEqual(blocks, [.heading(level: 1, text: "Heading"), .paragraph(text: "body text")])
    }

    // MARK: - ollie://note/<uuid> citation parsing

    func testValidOllieNoteURLYieldsID() {
        let id = UUID()
        let url = URL(string: "ollie://note/\(id.uuidString)")!
        XCTAssertEqual(MarkdownLite.noteID(fromOllieURL: url), id)
    }

    func testOllieNoteURLIsSchemeAndHostCaseInsensitive() {
        let id = UUID()
        let url = URL(string: "OLLIE://NOTE/\(id.uuidString)")!
        XCTAssertEqual(MarkdownLite.noteID(fromOllieURL: url), id)
    }

    func testNonOllieURLReturnsNil() {
        XCTAssertNil(MarkdownLite.noteID(fromOllieURL: URL(string: "https://example.com/note/x")!))
    }

    func testOllieNonNoteHostReturnsNil() {
        XCTAssertNil(MarkdownLite.noteID(fromOllieURL: URL(string: "ollie://view/Open-loops")!))
    }

    func testOllieNoteURLWithGarbageIDReturnsNil() {
        XCTAssertNil(MarkdownLite.noteID(fromOllieURL: URL(string: "ollie://note/not-a-uuid")!))
    }
}
