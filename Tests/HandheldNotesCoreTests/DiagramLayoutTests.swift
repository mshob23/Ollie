import Foundation
import XCTest
@testable import HandheldNotesCore

/// Pins down the M12 `diagram` v2 renderer polish at the **pure-logic level** — the parts of
/// the diagram renderer that are value computations rather than SwiftUI layout:
///   • wide-layer wrapping (`DiagramLayerRow.rows` — chunk a layer into rows of ≤ 3),
///   • connector-label disambiguation (`DiagramConnectorLabel.rendered(ambiguousAmong:)` +
///     `DiagramLayout.connectorLabels` — `from -> to: label` only when a layer has >1 labeled
///     out-edge), and
///   • self-loop badges (`DiagramLayout.selfLoopBadges` — a `A -> A: label` edge's label rides
///     its node, not a connector).
///
/// These are renderer-only (no grammar change): the parser (`FenceWidget.parse`) is unchanged
/// and produces the same `Diagram` value; only how the renderer arranges it moved. SwiftUI
/// layout isn't unit-testable, so we assert the pure decisions the views consult. All the
/// parser's own diagram goldens continue to hold in `FenceWidgetsTests`.
final class DiagramLayoutTests: XCTestCase {

    /// Build the layout the `DiagramWidget` computes for a diagram fence body (parsed through
    /// the real parser so the input is exactly what ships), or fail.
    private func layout(_ code: String,
                        file: StaticString = #filePath, line: UInt = #line) -> DiagramLayout? {
        guard case let .diagram(diagram)? = FenceWidget.parse(info: "diagram", code: code) else {
            XCTFail("expected a .diagram from: \(code)", file: file, line: line)
            return nil
        }
        return DiagramLayout(diagram)
    }

    // MARK: - Wide-layer wrapping (chunk into rows of <= 3)

    func testLayerRowChunkingIsNoOpForThreeOrFewer() {
        // A layer of <= 3 nodes is a single row - identical to the pre-M12 single HStack.
        XCTAssertEqual(DiagramLayerRow.rows([]), [])
        XCTAssertEqual(DiagramLayerRow.rows(["A"]), [["A"]])
        XCTAssertEqual(DiagramLayerRow.rows(["A", "B"]), [["A", "B"]])
        XCTAssertEqual(DiagramLayerRow.rows(["A", "B", "C"]), [["A", "B", "C"]])
    }

    func testLayerRowChunkingWrapsAtFourNodes() {
        // 4 nodes -> two rows (3 + 1); a wide fan-out can't overflow a narrow watch face.
        XCTAssertEqual(DiagramLayerRow.rows(["A", "B", "C", "D"]), [["A", "B", "C"], ["D"]])
    }

    func testLayerRowChunkingWrapsWiderLayersDeterministically() {
        // 7 nodes -> 3 + 3 + 1, order preserved.
        XCTAssertEqual(DiagramLayerRow.rows(["N0", "N1", "N2", "N3", "N4", "N5", "N6"]),
                       [["N0", "N1", "N2"], ["N3", "N4", "N5"], ["N6"]])
    }

    func testWideFanOutLayerChunksInTheRealLayout() {
        // A real fan-out: root A -> five children. The children share one topological layer of
        // 5, which chunks into rows of 3 + 2 so it wraps instead of overflowing.
        let code = """
        A -> B
        A -> C
        A -> D
        A -> E
        A -> F
        """
        guard let layout = layout(code) else { return }
        // Layer 0 is [A]; layer 1 is the 5 children in first-appearance order.
        XCTAssertEqual(layout.layers.count, 2)
        XCTAssertEqual(layout.layers[0], ["A"])
        XCTAssertEqual(layout.layers[1], ["B", "C", "D", "E", "F"])
        // The wide child layer wraps 3 + 2.
        XCTAssertEqual(DiagramLayerRow.rows(layout.layers[1]), [["B", "C", "D"], ["E", "F"]])
    }

    // MARK: - Connector-label disambiguation

    func testSingleLabeledEdgeStaysBare() {
        // One labeled out-edge from a layer -> the bare label, exactly as before (no clutter).
        let item = DiagramConnectorLabel(from: "A", to: "B", label: "sends")
        XCTAssertEqual(item.rendered(ambiguousAmong: 1), "sends")
    }

    func testMultipleLabeledEdgesDisambiguateWithEndpoints() {
        // >1 labeled out-edge from the SAME layer -> each renders as `from -> to: label`.
        let a = DiagramConnectorLabel(from: "A", to: "B", label: "yes")
        let b = DiagramConnectorLabel(from: "A", to: "C", label: "no")
        XCTAssertEqual(a.rendered(ambiguousAmong: 2), "A \u{2192} B: yes")
        XCTAssertEqual(b.rendered(ambiguousAmong: 2), "A \u{2192} C: no")
    }

    func testLayoutSingleLabelPerLayerIsBareInEndToEndCase() {
        // A -> B: go / B -> C (only B->? labeled once per layer). Each connector has one label,
        // so it stays bare (rendered with ambiguousAmong == 1).
        guard let layout = layout("A -> B: go\nB -> C") else { return }
        // Layer 0 = [A] has one labeled out-edge (A->B).
        let layer0 = layout.connectorLabels[0] ?? []
        XCTAssertEqual(layer0.count, 1)
        XCTAssertEqual(layer0[0].rendered(ambiguousAmong: layer0.count), "go")
    }

    func testLayoutMultiLabelPerLayerDisambiguatesInEndToEndCase() {
        // A branches to B and C, both labeled -> layer 0 has TWO labeled out-edges, so both
        // render disambiguated. This is the decision case the renderer feeds to the connector.
        let code = """
        A -> B: yes
        A -> C: no
        """
        guard let layout = layout(code) else { return }
        let layer0 = layout.connectorLabels[0] ?? []
        XCTAssertEqual(layer0.count, 2)
        let rendered = layer0.map { $0.rendered(ambiguousAmong: layer0.count) }
        XCTAssertEqual(rendered, ["A \u{2192} B: yes", "A \u{2192} C: no"])
    }

    func testConnectorLabelsPreserveAuthoredOrder() {
        // Labels on a layer keep the authored edge order.
        let code = """
        A -> C: third
        A -> B: first
        """
        guard let layout = layout(code) else { return }
        let layer0 = layout.connectorLabels[0] ?? []
        XCTAssertEqual(layer0.map(\.label), ["third", "first"])
    }

    // MARK: - Self-loop badges

    func testSelfLoopLabelBecomesNodeBadgeNotConnectorLabel() {
        // A -> A: retry is a self-loop: its label rides node A as a badge, and it must NOT
        // appear on any inter-layer connector or in the residual footer.
        let code = """
        A -> A: retry
        A -> B
        """
        guard let layout = layout(code) else { return }
        XCTAssertEqual(layout.selfLoopBadges["A"], ["retry"])
        // No connector/residual label carries the self-loop's text.
        let allConnector = layout.connectorLabels.values.flatMap { $0 }.map(\.label)
        XCTAssertFalse(allConnector.contains("retry"))
        XCTAssertFalse((layout.residualLabels ?? []).map(\.label).contains("retry"))
    }

    func testMultipleSelfLoopsOnANodeKeepOrder() {
        // Two self-loops on the same node -> two badges in authored order.
        let code = """
        A -> A: first
        A -> A: second
        A -> B
        """
        guard let layout = layout(code) else { return }
        XCTAssertEqual(layout.selfLoopBadges["A"], ["first", "second"])
    }

    func testUnlabeledSelfLoopMakesNoBadge() {
        // A self-loop with no label makes no badge (nothing to show), and still doesn't break
        // layering (self-loops are excluded from the topological ordering).
        guard let layout = layout("A -> A\nA -> B") else { return }
        XCTAssertNil(layout.selfLoopBadges["A"])
        XCTAssertEqual(layout.layers, [["A"], ["B"]])
    }

    func testSelfLoopDoesNotBlockLayeringOfTheRestOfTheFlow() {
        // A labeled self-loop on a middle node doesn't prevent a clean A -> B -> C layering.
        let code = """
        A -> B
        B -> B: loop
        B -> C
        """
        guard let layout = layout(code) else { return }
        XCTAssertEqual(layout.layers, [["A"], ["B"], ["C"]])
        XCTAssertEqual(layout.selfLoopBadges["B"], ["loop"])
    }
}
