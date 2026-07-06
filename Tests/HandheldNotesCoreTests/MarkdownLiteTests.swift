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
        // Plain bullets carry no blockId; the checklist item is annotated with its
        // content-derived id (cl1:<hash16>:<occ>) — hash16("three"), occurrence 0.
        XCTAssertEqual(items, [
            .init(checked: nil, text: "one", blockId: nil),
            .init(checked: nil, text: "two", blockId: nil),
            .init(checked: false, text: "three", blockId: "cl1:8b5b9db0c13db242:0"),
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

    // MARK: - 7b: blockId derivation (spec §3 — cl1:<hash16>:<occ>)
    //
    // These are pure (no SwiftUI): they exercise the block parser's blockId annotation.
    // The goldens are the first 16 lowercase hex chars of SHA-256 over the UTF-8 of the
    // classifier-captured item text — computed independently with `shasum -a 256`.

    /// Pull the annotated blockIds of every checklist item in `body`, in document order.
    /// Bullets (no blockId) are skipped; this is exactly the interaction join-key list.
    private func checklistBlockIds(_ body: String) -> [String] {
        MarkdownLite.blocks(from: body).flatMap { block -> [String] in
            guard case let .list(items) = block else { return [] }
            return items.compactMap(\.blockId)
        }
    }

    func testHash16GoldenMatchesSHA256Prefix() {
        // Golden vectors: `printf '%s' "<text>" | shasum -a 256 | cut -c1-16`.
        XCTAssertEqual(MarkdownLite.hash16(ofChecklistText: "Buy milk"), "df3db8a9ea05f22c")
        XCTAssertEqual(MarkdownLite.hash16(ofChecklistText: "Call the plumber"), "4e9e5e96b4622879")
        XCTAssertEqual(MarkdownLite.hash16(ofChecklistText: "todo"), "602fae580f5863ab")
        // 16 lowercase hex chars, always.
        let h = MarkdownLite.hash16(ofChecklistText: "anything at all")
        XCTAssertEqual(h.count, 16)
        XCTAssertTrue(h.allSatisfy { "0123456789abcdef".contains($0) })
    }

    func testBlockIdGoldenForSingleChecklistItem() {
        // occ is always present (uniform ids, no singleton special case — spec §3).
        XCTAssertEqual(checklistBlockIds("- [ ] Buy milk"), ["cl1:df3db8a9ea05f22c:0"])
        XCTAssertEqual(checklistBlockIds("- [x] Call the plumber"), ["cl1:4e9e5e96b4622879:0"])
    }

    func testBlockIdHashesClassifierCapturedTextNotBodyMarker() {
        // The hash is over the text `classify(line:)` captures (post-marker, trimmed),
        // so `- [ ] Buy milk` and `- [x] Buy milk` (checked vs unchecked) — same label —
        // share the same id. Checked-state is NOT part of the id.
        XCTAssertEqual(checklistBlockIds("- [ ] Buy milk"), checklistBlockIds("- [x] Buy milk"))
        // Extra spacing after the box is trimmed by the classifier, so it doesn't change
        // the id either.
        XCTAssertEqual(checklistBlockIds("- [ ]   Buy milk"), ["cl1:df3db8a9ea05f22c:0"])
    }

    func testOccurrenceOrdinalsForDuplicateText() {
        // Three identical items → occ 0, 1, 2 in document order; the hash16 is constant.
        let body = "- [ ] todo\n- [ ] todo\n- [x] todo"
        XCTAssertEqual(checklistBlockIds(body), [
            "cl1:602fae580f5863ab:0",
            "cl1:602fae580f5863ab:1",
            "cl1:602fae580f5863ab:2",
        ])
    }

    func testOccurrenceOrdinalsCountAcrossTheWholeBodyNotPerList() {
        // Duplicate text split across two lists (a blank line breaks the list, per the
        // parser) still shares one document-wide occurrence counter — occ 0 then occ 1.
        let body = "- [ ] todo\n\n- [ ] todo"
        XCTAssertEqual(checklistBlockIds(body), [
            "cl1:602fae580f5863ab:0",
            "cl1:602fae580f5863ab:1",
        ])
    }

    func testOccurrenceOrdinalsArePerHashNotGlobal() {
        // Different text → independent counters, each starting at 0. Interleaving A and B
        // gives A:0, B:0, A:1, B:1 — the ordinal is scoped to equal-hash items only.
        let body = "- [ ] Buy milk\n- [ ] Call the plumber\n- [ ] Buy milk\n- [ ] Call the plumber"
        XCTAssertEqual(checklistBlockIds(body), [
            "cl1:df3db8a9ea05f22c:0",
            "cl1:4e9e5e96b4622879:0",
            "cl1:df3db8a9ea05f22c:1",
            "cl1:4e9e5e96b4622879:1",
        ])
    }

    func testReorderKeepsIds() {
        // Reordering distinct items (no equal-text duplicates crossing) preserves every
        // id — the whole point of content-addressing over index ids (spec §3).
        let a = "- [ ] Buy milk\n- [ ] Call the plumber\n- [x] Ship it"
        let b = "- [x] Ship it\n- [ ] Buy milk\n- [ ] Call the plumber"
        XCTAssertEqual(Set(checklistBlockIds(a)), Set(checklistBlockIds(b)))
        // And each specific id is stable across the reorder.
        XCTAssertTrue(checklistBlockIds(a).contains("cl1:df3db8a9ea05f22c:0"))
        XCTAssertTrue(checklistBlockIds(b).contains("cl1:df3db8a9ea05f22c:0"))
        XCTAssertTrue(checklistBlockIds(a).contains("cl1:2c8d1fbaf0f6d462:0"))
        XCTAssertTrue(checklistBlockIds(b).contains("cl1:2c8d1fbaf0f6d462:0"))
    }

    func testRewordChangesId() {
        // Rewording an item detaches it (new bytes → new hash → new id) so stale
        // interaction state stops matching and the item fails safe to the body default.
        let before = checklistBlockIds("- [x] Buy milk")
        let after = checklistBlockIds("- [x] Buy milk (2%)")
        XCTAssertEqual(before, ["cl1:df3db8a9ea05f22c:0"])
        XCTAssertEqual(after, ["cl1:8849adfdee7c91d5:0"])
        XCTAssertNotEqual(before, after)
    }

    func testChecklistItemsInsideFencedBlockGetNoBlockId() {
        // A `- [ ]` line INSIDE a ```checklist fence is captured verbatim as a code block
        // (the reserved cl2: growth path), never classified as an interactive checklist
        // item — so it carries no cl1: blockId and stays non-interactive (spec §3).
        let body = "```checklist\n- [ ] not interactive yet\n```"
        XCTAssertEqual(checklistBlockIds(body), [], "fenced checklist items get no blockId")
        // Sanity: it did render as a code block, unchanged.
        let blocks = MarkdownLite.blocks(from: body)
        XCTAssertEqual(blocks, [.codeBlock(info: "checklist", code: "- [ ] not interactive yet")])
    }

    func testPlainBulletsGetNoBlockId() {
        // Only checklist items are interaction targets; plain bullets never get an id.
        let blocks = MarkdownLite.blocks(from: "- just a bullet\n- another")
        guard case let .list(items) = blocks.first else { return XCTFail("expected a list") }
        XCTAssertTrue(items.allSatisfy { $0.blockId == nil })
    }
}
