// SPDX-License-Identifier: MPL-2.0
import XCTest
import FloeNotes

/// Pure layout-engine and model-compat tests for the native mind map. These
/// run without any WebKit surface; the view contract they protect: old
/// documents decode without positions, the automatic layout is deterministic
/// and overlap-free in all three directions, and first-edit materialization
/// (including collapsed subtrees) can be derived from `includeCollapsed`.
@MainActor final class MindMapLayoutTests: XCTestCase {
    private func makeDocument(direction: Int, branchCount: Int = 4, depth: Int = 2) -> NoteDocument {
        var document = NoteDocument(kind: .mindMap, title: "Root")
        document.mindMapDirection = direction
        let rootID = document.nodes[0].id
        for index in 0..<branchCount {
            let branch = MindMapNode(parentID: rootID, title: "分支 \(index)", order: index)
            document.nodes.append(branch)
            if depth > 1 {
                for inner in 0..<2 {
                    document.nodes.append(MindMapNode(parentID: branch.id, title: "叶 \(index)-\(inner)", order: inner))
                }
            }
        }
        return document
    }

    private func rects(_ frames: [UUID: NoteRect]) -> [CGRect] {
        frames.values.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
    }

    private func assertNoOverlap(_ frames: [UUID: NoteRect], file: StaticString = #filePath, line: UInt = #line) {
        let rects = rects(frames)
        for (index, first) in rects.enumerated() {
            for (other, second) in rects.enumerated() where other > index {
                XCTAssertFalse(first.intersects(second), "frames overlap: \(first) vs \(second)", file: file, line: line)
            }
        }
    }

    func testAutomaticLayoutIsDeterministicAndOverlapFreeInAllDirections() {
        for direction in [0, 1, 2] {
            let document = makeDocument(direction: direction)
            let first = MindMapLayout.frames(document: document, sizes: [:])
            let second = MindMapLayout.frames(document: document, sizes: [:])
            XCTAssertEqual(first, second, "direction \(direction) layout must be deterministic")
            XCTAssertEqual(first.count, document.nodes.count)
            assertNoOverlap(first)
        }
    }

    func testLeftAndRightDirectionsPlaceChildrenOnTheirSide() {
        let right = makeDocument(direction: 1)
        let rightFrames = MindMapLayout.frames(document: right, sizes: [:])
        let root = right.nodes[0]
        for child in MindMapLayout.orderedChildren(of: root.id, in: right) {
            XCTAssertGreaterThan(rightFrames[child.id]!.x, rightFrames[root.id]!.x, "right-mode children must grow right")
        }
        let left = makeDocument(direction: 0)
        let leftFrames = MindMapLayout.frames(document: left, sizes: [:])
        for child in MindMapLayout.orderedChildren(of: root.id, in: left) {
            XCTAssertLessThan(leftFrames[child.id]!.x + leftFrames[child.id]!.width, leftFrames[root.id]!.x,
                              "left-mode children must grow left")
        }
    }

    func testCollapsedSubtreeIsExcludedButIncludedOnDemand() {
        var document = makeDocument(direction: 2)
        let branch = document.nodes[1]
        document.nodes[1].isCollapsed = true
        let visible = MindMapLayout.frames(document: document, sizes: [:])
        XCTAssertNil(visible[document.nodes[2].id], "collapsed child leaves must not be laid out")
        XCTAssertNotNil(visible[branch.id], "the collapsed topic itself stays visible")
        let full = MindMapLayout.frames(document: document, sizes: [:], includeCollapsed: true)
        XCTAssertEqual(full.count, document.nodes.count, "materialization covers hidden subtree members")
        assertNoOverlap(full)
    }

    func testManualPositionPinsOnlyItsOwnTopic() {
        var document = makeDocument(direction: 2)
        let branch = document.nodes[1]
        document.nodes[1].position = MindMapPoint(x: 500, y: -300)
        let frames = MindMapLayout.frames(document: document, sizes: [:])
        XCTAssertEqual(frames[branch.id]!.x + frames[branch.id]!.width / 2, 500, accuracy: 0.001)
        XCTAssertEqual(frames[branch.id]!.y + frames[branch.id]!.height / 2, -300, accuracy: 0.001)
        assertNoOverlap(frames)
    }

    func testNewChildAndSiblingPlacementLeaveFullSpacing() {
        let metrics = MindMapLayoutMetrics.standard
        let document = makeDocument(direction: 1)
        let frames = MindMapLayout.frames(document: document, sizes: [:])
        let root = document.nodes[0]
        guard let childPoint = MindMapLayout.newChildPosition(document: document, frames: frames, parentID: root.id),
              let siblingPoint = MindMapLayout.newSiblingPosition(document: document, frames: frames, siblingID: document.nodes[1].id) else {
            return XCTFail("placement helpers must return a point")
        }
        let rootFrame = frames[root.id]!
        XCTAssertEqual(childPoint.x, rootFrame.x + rootFrame.width + metrics.horizontalGap + metrics.defaultNodeWidth / 2, accuracy: 0.001,
                       "new child center must clear the parent by a full gap plus its own half width")
        let lastSibling = MindMapLayout.orderedChildren(of: root.id, in: document).last!
        let lastFrame = frames[lastSibling.id]!
        XCTAssertGreaterThanOrEqual(childPoint.y - metrics.defaultNodeHeight / 2, lastFrame.y + lastFrame.height + metrics.siblingGap - 0.001,
                                    "new child must sit below the last sibling with a full gap")
        let siblingFrame = frames[document.nodes[1].id]!
        XCTAssertEqual(siblingPoint.x, siblingFrame.x + siblingFrame.width / 2, accuracy: 0.001)
        XCTAssertEqual(siblingPoint.y - metrics.defaultNodeHeight / 2, siblingFrame.y + siblingFrame.height + metrics.siblingGap, accuracy: 0.001)
    }

    func testLegacyDocumentsWithoutPositionsDecodeLosslessly() throws {
        // The shape written before free positioning existed: no `position` key.
        let legacy = """
        {
          "id": "00000000-0000-0000-0000-0000000000AA",
          "parentID": null,
          "title": "旧主题",
          "note": "",
          "order": 0,
          "isCollapsed": false
        }
        """.data(using: .utf8)!
        let node = try JSONDecoder().decode(MindMapNode.self, from: legacy)
        XCTAssertNil(node.position, "legacy nodes join the automatic layout")
        // Re-encoding keeps the key absent until a position exists.
        let encoded = try JSONEncoder().encode(node)
        XCTAssertFalse(String(data: encoded, encoding: .utf8)!.contains("position"))
        // Once set, the value round-trips.
        var updated = node
        updated.position = MindMapPoint(x: 12.5, y: -7.25)
        let roundTrip = try JSONDecoder().decode(MindMapNode.self, from: try JSONEncoder().encode(updated))
        XCTAssertEqual(roundTrip.position, updated.position)
    }

    func testValidationRejectsInvalidManualPositions() {
        var document = makeDocument(direction: 2)
        document.nodes[0].position = MindMapPoint(x: .nan, y: 0)
        XCTAssertThrowsError(try document.validate())
        var far = makeDocument(direction: 2)
        far.nodes[0].position = MindMapPoint(x: 200_000, y: 0)
        XCTAssertThrowsError(try far.validate())
    }

    func testSummaryReanchorsAfterSiblingInsertAndDelete() throws {
        var document = makeDocument(direction: 2, branchCount: 3, depth: 1)
        let rootID = document.nodes[0].id
        document.summaries = [MindMapSummary(label: "合计", parent: rootID, start: 0, end: 1)]
        // The editor inserts a sibling by shifting every later order up in
        // descending order within the same batch, then commits the new topic
        // into its freed slot; no intermediate state has order ties, so the
        // summary re-anchor is deterministic.
        var second = document
        let later = MindMapLayout.orderedChildren(of: rootID, in: second)
            .filter { $0.order >= 1 }
            .sorted { $0.order > $1.order }
        for child in later {
            var shifted = child
            shifted.order += 1
            try NoteEdit.upsertNode(shifted).apply(to: &second)
        }
        try NoteEdit.upsertNode(MindMapNode(parentID: rootID, title: "插入", order: 1)).apply(to: &second)
        XCTAssertEqual(second.summaries?.first?.start, 0)
        XCTAssertEqual(second.summaries?.first?.end, 2, "the summary must follow its covered topics")
        var removed = document
        try NoteEdit.deleteBranch(document.nodes[1].id).apply(to: &removed)
        XCTAssertEqual(removed.summaries?.first?.start, 0)
        XCTAssertEqual(removed.summaries?.first?.end, 0, "the summary must shrink to the surviving covered topic")
    }

    func testDeleteBranchRejectsRoot() {
        let document = makeDocument(direction: 2)
        var copy = document
        XCTAssertThrowsError(try NoteEdit.deleteBranch(document.nodes[0].id).apply(to: &copy))
    }
}
