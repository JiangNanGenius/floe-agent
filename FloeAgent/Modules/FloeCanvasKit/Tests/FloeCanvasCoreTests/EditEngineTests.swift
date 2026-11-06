import XCTest
@testable import FloeCanvasCore

private func makeNode(
    id: UUID = UUID(),
    locked: Bool = false
) -> CanvasNodeSnapshot {
    CanvasNodeSnapshot(
        content: .text("hello"),
        frame: CanvasGeometry.Frame(
            center: .init(x: 100, y: 100),
            size: .init(width: 200, height: 100)),
        isLocked: locked
    )
}

final class EditEngineTests: XCTestCase {
    func testLockedNodeBlocksContentAndMove() throws {
        let locked = makeNode(locked: true)
        let page = CanvasPageSnapshot(nodes: [locked])
        let snapshot = CanvasSnapshot(name: "S", pages: [page])

        let contentBatch = CanvasEditBatch(pageID: page.id, operations: [
            .updateContent(nodeID: locked.id, content: .text("changed"))
        ])
        XCTAssertThrowsError(try CanvasEditEngine.apply(contentBatch, to: snapshot)) { error in
            guard case CanvasKitError.editScopeViolations(let violations) = error else {
                XCTFail("expected violations, got \(error)")
                return
            }
            XCTAssertEqual(violations.count, 1)
            XCTAssertEqual(violations[0].reason, .nodeLocked)
        }

        let moveBatch = CanvasEditBatch(pageID: page.id, operations: [
            .move(nodeID: locked.id, center: .init(x: 0, y: 0))
        ])
        XCTAssertThrowsError(try CanvasEditEngine.apply(moveBatch, to: snapshot))
    }

    func testLockedNodeBlocksRemovalButSetLockedRequiresWholeScope() throws {
        let locked = makeNode(locked: true)
        let page = CanvasPageSnapshot(nodes: [locked])
        let snapshot = CanvasSnapshot(name: "S", pages: [page])

        let removeBatch = CanvasEditBatch(pageID: page.id, operations: [
            .removeNode(nodeID: locked.id)
        ])
        XCTAssertThrowsError(try CanvasEditEngine.apply(removeBatch, to: snapshot))

        // setLocked from a selected scope is rejected even for unlocked nodes.
        let unlockBatch = CanvasEditBatch(
            pageID: page.id,
            scope: .selectedNodes([locked.id]),
            operations: [.setLocked(nodeID: locked.id, isLocked: false)]
        )
        XCTAssertThrowsError(try CanvasEditEngine.apply(unlockBatch, to: snapshot)) { error in
            guard case CanvasKitError.editScopeViolations(let violations) = error else {
                XCTFail("expected violations")
                return
            }
            XCTAssertTrue(violations.contains { $0.reason == .outsideScope })
        }

        let wholeScope = CanvasEditBatch(pageID: page.id, operations: [
            .setLocked(nodeID: locked.id, isLocked: false)
        ])
        let result = try CanvasEditEngine.apply(wholeScope, to: snapshot)
        XCTAssertFalse(result.snapshot.pages[0].nodes[0].isLocked)
    }

    func testSelectedScopeRejectsOutOfScopeNodes() throws {
        let a = makeNode()
        let b = makeNode()
        let page = CanvasPageSnapshot(nodes: [a, b])
        let snapshot = CanvasSnapshot(name: "S", pages: [page])

        let batch = CanvasEditBatch(
            pageID: page.id,
            scope: .selectedNodes([a.id]),
            operations: [
                .updateContent(nodeID: a.id, content: .text("ok")),
                .updateContent(nodeID: b.id, content: .text("leak"))
            ]
        )
        XCTAssertThrowsError(try CanvasEditEngine.apply(batch, to: snapshot)) { error in
            guard case CanvasKitError.editScopeViolations(let violations) = error else {
                XCTFail("expected violations")
                return
            }
            XCTAssertEqual(violations.count, 1)
            XCTAssertEqual(violations[0].reason, .outsideScope)
            XCTAssertEqual(violations[0].nodeID, b.id)
        }
    }

    func testBatchIsAtomicAndReportsAllViolations() throws {
        let locked = makeNode(locked: true)
        let other = makeNode()
        let page = CanvasPageSnapshot(nodes: [locked, other])
        let snapshot = CanvasSnapshot(name: "S", pages: [page])

        let batch = CanvasEditBatch(pageID: page.id, operations: [
            .updateContent(nodeID: locked.id, content: .text("x")),
            .move(nodeID: other.id, center: .init(x: 0, y: 0)),
            .updateContent(nodeID: UUID(), content: .text("missing"))
        ])
        XCTAssertThrowsError(try CanvasEditEngine.apply(batch, to: snapshot)) { error in
            guard case CanvasKitError.editScopeViolations(let violations) = error else {
                XCTFail("expected violations")
                return
            }
            XCTAssertEqual(violations.count, 2)
            XCTAssertEqual(Set(violations.map(\.reason)), [.nodeLocked, .nodeMissing])
        }
        // Untouched input: the engine never partially applies.
        XCTAssertEqual(snapshot.pages[0].nodes.count, 2)
        XCTAssertEqual(snapshot.pages[0].nodes.first { $0.id == other.id }?.frame.center.x, 100)
    }

    func testRemoveNodeScrubsConnectionsAndGroupMembership() throws {
        let a = makeNode()
        let b = makeNode()
        var group = CanvasGroupRecord(name: "G", memberNodeIDs: [a.id, b.id])
        _ = group.memberNodeIDs
        let page = CanvasPageSnapshot(
            nodes: [a, b],
            connections: [
                CanvasConnectionSnapshot(
                    sourceNodeID: a.id, destinationNodeID: b.id, kind: .arrow)
            ],
            groups: [group]
        )
        let snapshot = CanvasSnapshot(name: "S", pages: [page])

        let batch = CanvasEditBatch(pageID: page.id, operations: [
            .removeNode(nodeID: b.id)
        ])
        let result = try CanvasEditEngine.apply(batch, to: snapshot)
        XCTAssertEqual(result.snapshot.pages[0].connections.count, 0)
        XCTAssertEqual(result.snapshot.pages[0].groups[0].memberNodeIDs, [a.id])
        XCTAssertEqual(result.changedNodeIDs, [b.id].sorted { $0.uuidString < $1.uuidString })
    }

    func testInsertConnectionRejectsDanglingEndpoints() throws {
        let a = makeNode()
        let page = CanvasPageSnapshot(nodes: [a])
        let snapshot = CanvasSnapshot(name: "S", pages: [page])

        let batch = CanvasEditBatch(pageID: page.id, operations: [
            .insertConnection(CanvasConnectionSnapshot(
                sourceNodeID: a.id, destinationNodeID: UUID(), kind: .arrow))
        ])
        XCTAssertThrowsError(try CanvasEditEngine.apply(batch, to: snapshot)) { error in
            guard case CanvasKitError.editScopeViolations(let violations) = error,
                  violations.contains(where: { $0.reason == .danglingConnection }) else {
                XCTFail("expected danglingConnection violation")
                return
            }
        }
    }
}
