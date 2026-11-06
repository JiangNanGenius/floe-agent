import XCTest
import FloeCanvasCore
import FloeDiagramCore
@testable import FloeCanvasLayout

/// Generated-scale fixtures: 500 / 3000 / 10000 nodes on a 1000pt grid.
/// Assertions are structural (exact visible counts, hit locality, bounded
/// pan-query results) plus generous wall-clock guards against accidental
/// superlinear blowups. No FPS or device claims — CPU timing only.
final class ScaleFixtureTests: XCTestCase {
    private func assertScale(_ count: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let fixture = makeGridPage(count: count, connections: true)
        let start = Date()
        let index = try CanvasPageLayoutIndex(page: fixture.page)
        let buildSeconds = Date().timeIntervalSince(start)
        XCTAssertEqual(index.nodes.count, count, file: file, line: line)
        XCTAssertEqual(index.proxyEdges.count, count - 1, file: file, line: line)
        XCTAssertTrue(index.issues.isEmpty, file: file, line: line)
        // Generous guard: catches O(N²) regressions without flaky precision.
        XCTAssertLessThan(buildSeconds, 10, "build took \(buildSeconds)s at N=\(count)", file: file, line: line)

        // Query locality: a 999×999 viewport at the grid origin intersects
        // exactly the four nodes at (0,0), (1000,0), (0,1000), (1000,1000)
        // regardless of page size.
        let visible = index.visibleNodes(
            in: DiagramRect(x: 0, y: 0, width: 999, height: 999),
            overscan: 0)
        XCTAssertEqual(visible.count, 4, file: file, line: line)

        // Hit locality: a point between cells misses; a point inside the
        // (1000, 0) cell hits exactly that node.
        XCTAssertNil(index.hitTest(.init(x: 500, y: 500)), file: file, line: line)
        guard case .node(let hit)? = index.hitTest(.init(x: 950, y: 50)) else {
            XCTFail("expected hit at (950, 50) for N=\(count)", file: file, line: line)
            return
        }
        XCTAssertEqual(hit.id, fixture.nodes[1].id, file: file, line: line)

        // 100 pan queries across the whole extent: per-query visible counts
        // stay bounded by the viewport, never the page size.
        var maxVisible = 0
        for step in 0..<100 {
            let rect = DiagramRect(
                x: Double(step) * 990, y: Double(step % 10) * 990,
                width: 999, height: 999)
            let count = index.visibleNodes(in: rect, overscan: 0).count
            maxVisible = max(maxVisible, count)
        }
        XCTAssertLessThanOrEqual(maxVisible, 16, file: file, line: line)
    }

    func testScale500() throws { try assertScale(500) }
    func testScale3000() throws { try assertScale(3000) }
    func testScale10000() throws { try assertScale(10000) }

    func testLargeExtentCoordinatesStayUsable() throws {
        // 10k nodes spread across ±1e6 world units: still inside the safe
        // extent, queries and fits must behave.
        var nodes: [CanvasNodeSnapshot] = []
        for index in 0..<1000 {
            nodes.append(makeNode(center: .init(
                x: Double(index) * 2000 - 1e6,
                y: (index % 2 == 0 ? 1 : -1) * 500_000)))
        }
        let page = CanvasPageSnapshot(nodes: nodes)
        let index = try CanvasPageLayoutIndex(page: page)
        XCTAssertEqual(index.nodes.count, 1000)
        XCTAssertTrue(index.visibleNodes(in: index.bounds, overscan: 0).count > 0)
        let transform = try CanvasViewportTransform(
            center: .zero, scale: 0.05,
            viewSize: .init(width: 390, height: 844))
        XCTAssertNotNil(transform.fitting(index.bounds))
    }

    func testIndexBuildHonoursCancellation() async {
        let fixture = makeGridPage(count: 10000)
        let task = Task {
            try CanvasPageLayoutIndex(page: fixture.page)
        }
        task.cancel()
        await XCTAssertThrowsErrorAsync({ try await task.value }) { error in
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
    }
}
