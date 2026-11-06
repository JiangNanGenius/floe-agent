#if canImport(UIKit)
import XCTest
@testable import FloeCanvasUI
import FloeCanvasCore
import FloeCanvasIntegration
import FloeCanvasLayout

/// Board accessibility (P1c guidance): bounded visible-only elements with
/// meaningful localized labels and real store-backed actions.
@MainActor
final class CanvasBoardAccessibilityTests: XCTestCase {

    private func makeStore(nodes: [CanvasNodeSnapshot]) -> CanvasEditorStore {
        let snapshot = CanvasSnapshot(
            name: "a11y",
            pages: [CanvasPageSnapshot(name: "P", nodes: nodes)])
        let store = CanvasEditorStore(
            canvasID: snapshot.id,
            services: CanvasEditorServices(
                documentStore: InMemoryCanvasRepository(snapshot: snapshot)))
        return store
    }

    func testOnlyVisibleNodesProduceElementsWithMeaningfulLabels() async throws {
        let near = CanvasTestStubs.textNode("visible body", center: .init(x: 0, y: 0))
        var titled = CanvasTestStubs.textNode("hidden body", center: .init(x: 100_000, y: 0))
        titled.title = "Hidden Card"
        let store = makeStore(nodes: [near, titled])
        await store.load()
        store.setViewport(try CanvasViewportTransform(center: .zero, scale: 1,
            viewSize: .init(width: 1024, height: 768)))
        let board = CanvasBoardView()
        board.bind(to: store)

        let elements = board.accessibilityElements ?? []
        XCTAssertEqual(elements.count, 1, "offscreen cards produce no elements")
        let element = try XCTUnwrap(elements.first as? UIAccessibilityElement)
        XCTAssertEqual(element.accessibilityLabel, "visible body",
                       "untitled card announces its content preview")
        XCTAssertTrue(element.accessibilityTraits.contains(.button))
        XCTAssertFalse(element.accessibilityTraits.contains(.selected))

        store.select(near.id)
        let selected = try XCTUnwrap(board.accessibilityElements?.first as? UIAccessibilityElement)
        XCTAssertTrue(selected.accessibilityTraits.contains(.selected),
                      "selection state is announced")
    }

    func testElementCountStaysBoundedOnLargeBoards() async throws {
        var nodes: [CanvasNodeSnapshot] = []
        for index in 0..<500 {
            nodes.append(CanvasTestStubs.textNode(
                "card \(index)",
                center: .init(x: 0, y: Double(index) * 200)))
        }
        let store = makeStore(nodes: nodes)
        await store.load()
        let board = CanvasBoardView()
        board.bind(to: store)
        let elements = board.accessibilityElements ?? []
        XCTAssertLessThanOrEqual(
            elements.count,
            CanvasBoardAccessibilityBuilder.maxNodeElements,
            "element synthesis is bounded regardless of board size")
    }

    func testCustomActionsDriveTheSameStorePipeline() async throws {
        let node = CanvasTestStubs.textNode("action target", center: .zero)
        let store = makeStore(nodes: [node])
        await store.load()
        let board = CanvasBoardView()
        board.bind(to: store)

        let element = try XCTUnwrap(board.accessibilityElements?.first as? UIAccessibilityElement)
        let actions = element.accessibilityCustomActions ?? []
        XCTAssertGreaterThanOrEqual(actions.count, 2, "select + open inspector actions exist")
        XCTAssertEqual(actions[0].name, store.strings[.toolSelect])
        XCTAssertEqual(actions[1].name, store.strings[.a11yOpenInspector])

        store.clearSelection()
        _ = actions[0].actionHandler?(actions[0])
        XCTAssertEqual(store.selection, [node.id], "accessibility select uses the store pipeline")
        store.showsInspector = false
        _ = actions[1].actionHandler?(actions[1])
        XCTAssertTrue(store.showsInspector, "open-inspector action reaches the inspector")
    }
}

#endif // canImport(UIKit)
