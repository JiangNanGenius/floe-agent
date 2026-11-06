import Foundation
import XCTest
import FloeCanvasCore
import FloeDiagramCore

/// XCTest's XCTAssertThrowsError uses a synchronous autoclosure and cannot
/// accept `await`; this is the local async equivalent (same pattern as the
/// Integration tests' helper, kept per-target to avoid cross-target imports).
func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Any,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ verifier: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error to be thrown, but none was", file: file, line: line)
    } catch {
        verifier(error)
    }
}

func makeNode(
    id: UUID = UUID(),
    center: CanvasGeometry.Point = .init(x: 0, y: 0),
    size: CanvasGeometry.Size = .init(width: 100, height: 100),
    zIndex: Int = 0,
    locked: Bool = false,
    rotationDegrees: Double = 0,
    groupID: UUID? = nil,
    kind: CanvasNodeKind = .content,
    content: CanvasContent = .text("node")
) -> CanvasNodeSnapshot {
    CanvasNodeSnapshot(
        id: id,
        kind: kind,
        content: content,
        frame: CanvasGeometry.Frame(center: center, size: size),
        rotationDegrees: rotationDegrees,
        zIndex: zIndex,
        isLocked: locked,
        groupID: groupID)
}

func makeRegion(
    id: UUID = UUID(),
    center: CanvasGeometry.Point,
    size: CanvasGeometry.Size,
    collapsed: Bool = false
) -> CanvasRegionRecord {
    CanvasRegionRecord(
        id: id,
        name: "Region",
        frame: CanvasGeometry.Frame(center: center, size: size),
        isCollapsed: collapsed)
}

func makeConnection(
    id: UUID = UUID(),
    from: UUID,
    to: UUID,
    kind: CanvasRelationKind = .arrow,
    label: String? = nil
) -> CanvasConnectionSnapshot {
    CanvasConnectionSnapshot(
        id: id,
        sourceNodeID: from,
        destinationNodeID: to,
        kind: kind,
        label: label)
}

/// Deterministic grid page: `count` nodes on a 1000pt pitch, each 200×200,
/// so a 999×999 viewport always intersects exactly four nodes. Optionally
/// chains connections between consecutive nodes.
func makeGridPage(
    count: Int,
    id: UUID = UUID(),
    connections: Bool = false
) -> (page: CanvasPageSnapshot, nodes: [CanvasNodeSnapshot]) {
    var nodes: [CanvasNodeSnapshot] = []
    nodes.reserveCapacity(count)
    var connectionsOut: [CanvasConnectionSnapshot] = []
    connectionsOut.reserveCapacity(connections ? max(0, count - 1) : 0)
    var previous: UUID?
    for index in 0..<count {
        let col = index % 100
        let row = index / 100
        let node = makeNode(
            center: .init(x: Double(col) * 1000, y: Double(row) * 1000))
        nodes.append(node)
        if connections, let previous {
            connectionsOut.append(makeConnection(from: previous, to: node.id))
        }
        previous = node.id
    }
    return (CanvasPageSnapshot(
        id: id,
        nodes: nodes,
        connections: connectionsOut), nodes)
}
