import XCTest
@testable import FloeCanvasCore

final class DocumentEditEngineTests: XCTestCase {
    private func makeSnapshot() -> (CanvasSnapshot, CanvasPageSnapshot, CanvasNodeSnapshot) {
        let node = CanvasNodeSnapshot(
            content: .text("hello"),
            frame: CanvasGeometry.Frame(
                center: .init(x: 100, y: 100),
                size: .init(width: 10, height: 10)))
        let page = CanvasPageSnapshot(nodes: [node])
        let snapshot = CanvasSnapshot(name: "D", pages: [page])
        return (snapshot, page, node)
    }

    // MARK: Pages

    func testPageCreateRenameReorderDeleteSelect() throws {
        let (snapshot, page, _) = makeSnapshot()
        let newPage = CanvasPageSnapshot(name: "Second")
        var batch = CanvasDocumentBatch(operations: [
            .createPage(newPage, select: true),
            .renamePage(pageID: page.id, name: "First"),
        ])
        var result = try CanvasDocumentEditEngine.apply(batch, to: snapshot)
        XCTAssertEqual(result.snapshot.pages.count, 2)
        XCTAssertEqual(result.snapshot.pages[0].name, "First")
        XCTAssertEqual(result.snapshot.selectedPageID, newPage.id)

        // Reorder: [Second, First]
        batch = CanvasDocumentBatch(operations: [
            .reorderPages(orderedPageIDs: [newPage.id, page.id])
        ])
        result = try CanvasDocumentEditEngine.apply(batch, to: result.snapshot)
        XCTAssertEqual(result.snapshot.pages.map(\.id), [newPage.id, page.id])

        // Delete the selected page (newPage) → first surviving in declared order.
        batch = CanvasDocumentBatch(operations: [
            .deletePage(pageID: newPage.id)
        ])
        result = try CanvasDocumentEditEngine.apply(batch, to: result.snapshot)
        XCTAssertEqual(result.snapshot.pages.count, 1)
        XCTAssertEqual(result.snapshot.selectedPageID, page.id)
        XCTAssertEqual(result.snapshot.viewports[newPage.id], nil)

        // Select page.
        batch = CanvasDocumentBatch(operations: [
            .createPage(newPage, select: false),
            .selectPage(pageID: newPage.id)
        ])
        result = try CanvasDocumentEditEngine.apply(batch, to: result.snapshot)
        XCTAssertEqual(result.snapshot.selectedPageID, newPage.id)
    }

    func testLastPageDeletionRejectedAndSelectedDeletionSurvives() throws {
        let (snapshot, page, _) = makeSnapshot()
        let batch = CanvasDocumentBatch(operations: [
            .deletePage(pageID: page.id)
        ])
        XCTAssertThrowsError(try CanvasDocumentEditEngine.apply(batch, to: snapshot)) { error in
            guard case CanvasKitError.editScopeViolations(let violations) = error else {
                XCTFail("expected violations, got \(error)")
                return
            }
            XCTAssertTrue(violations.contains { $0.reason == .lastPageRemaining })
        }
    }

    func testReorderPagesRejectsNonPermutation() throws {
        let (snapshot, page, _) = makeSnapshot()
        let batch = CanvasDocumentBatch(operations: [
            .reorderPages(orderedPageIDs: [UUID()])
        ])
        XCTAssertThrowsError(try CanvasDocumentEditEngine.apply(batch, to: snapshot)) { error in
            guard case CanvasKitError.editScopeViolations(let violations) = error else {
                XCTFail("expected violations, got \(error)")
                return
            }
            XCTAssertTrue(violations.contains { $0.reason == .invalidReference })
        }
    }

    func testDocumentBatchRequiresWholeDocumentScope() throws {
        let (snapshot, page, node) = makeSnapshot()
        let batch = CanvasDocumentBatch(
            scope: .selectedNodes([node.id]),
            operations: [.renamePage(pageID: page.id, name: "X")])
        XCTAssertThrowsError(try CanvasDocumentEditEngine.apply(batch, to: snapshot)) { error in
            guard case CanvasKitError.editScopeViolations(let violations) = error,
                  violations.first?.reason == .scopeEscalation else {
                XCTFail("expected scopeEscalation, got \(error)")
                return
            }
        }
    }

    // MARK: Groups

    func testGroupLifecycleAndContentsKeptOnRemove() throws {
        let (snapshot, page, node) = makeSnapshot()
        let group = CanvasGroupRecord(
            name: "G", memberNodeIDs: [node.id])
        var batch = CanvasDocumentBatch(operations: [
            .createGroup(pageID: page.id, group: group)
        ])
        var result = try CanvasDocumentEditEngine.apply(batch, to: snapshot)
        XCTAssertEqual(result.snapshot.pages[0].groups.count, 1)

        batch = CanvasDocumentBatch(operations: [
            .removeGroup(groupID: group.id, deleteMembers: false)
        ])
        result = try CanvasDocumentEditEngine.apply(batch, to: result.snapshot)
        XCTAssertEqual(result.snapshot.pages[0].groups.count, 0)
        XCTAssertEqual(result.snapshot.pages[0].nodes.count, 1)
        XCTAssertNil(result.snapshot.pages[0].nodes[0].groupID)
    }

    func testRemoveGroupWithMembersDeletesNodesAndScrubsReferences() throws {
        let (snapshot, page, node) = makeSnapshot()
        let group = CanvasGroupRecord(
            name: "G", memberNodeIDs: [node.id])
        var batch = CanvasDocumentBatch(operations: [
            .createGroup(pageID: page.id, group: group)
        ])
        var result = try CanvasDocumentEditEngine.apply(batch, to: snapshot)

        batch = CanvasDocumentBatch(operations: [
            .removeGroup(groupID: group.id, deleteMembers: true)
        ])
        result = try CanvasDocumentEditEngine.apply(batch, to: result.snapshot)
        XCTAssertTrue(result.snapshot.pages[0].nodes.isEmpty)
        XCTAssertTrue(result.snapshot.pages[0].groups.isEmpty)
    }

    func testMoveGroupIsAtomicAndLockedMemberRejectsWholeBatch() throws {
        let unlocked = CanvasNodeSnapshot(
            content: .text("a"),
            frame: CanvasGeometry.Frame(
                center: .zero, size: .init(width: 5, height: 5)))
        let locked = CanvasNodeSnapshot(
            content: .text("b"),
            frame: CanvasGeometry.Frame(
                center: .init(x: 50, y: 0),
                size: .init(width: 5, height: 5)),
            isLocked: true)
        let mixedGroup = CanvasGroupRecord(
            name: "M", memberNodeIDs: [unlocked.id, locked.id])
        let mixedPage = CanvasPageSnapshot(
            nodes: [unlocked, locked], groups: [mixedGroup])
        let mixed = CanvasSnapshot(name: "M", pages: [mixedPage])

        let move = CanvasDocumentBatch(operations: [
            .moveGroup(groupID: mixedGroup.id, delta: .init(x: 10, y: 10))
        ])
        XCTAssertThrowsError(try CanvasDocumentEditEngine.apply(move, to: mixed)) { error in
            guard case CanvasKitError.editScopeViolations(let violations) = error,
                  violations.contains(where: { $0.reason == .nodeLocked }) else {
                XCTFail("expected nodeLocked, got \(error)")
                return
            }
        }

        // Without the locked member the move lands atomically.
        let freeGroup = CanvasGroupRecord(
            name: "F", memberNodeIDs: [unlocked.id])
        let freePage = CanvasPageSnapshot(
            nodes: [unlocked], groups: [freeGroup])
        let free = CanvasSnapshot(name: "F", pages: [freePage])
        let moved = try CanvasDocumentEditEngine.apply(
            CanvasDocumentBatch(operations: [
                .moveGroup(groupID: freeGroup.id, delta: .init(x: 7, y: -3))
            ]), to: free)
        XCTAssertEqual(
            moved.snapshot.pages[0].nodes[0].frame.center, .init(x: 7, y: -3))
    }

    func testCreateGroupRejectsDanglingMember() throws {
        let (snapshot, page, _) = makeSnapshot()
        let batch = CanvasDocumentBatch(operations: [
            .createGroup(
                pageID: page.id,
                group: CanvasGroupRecord(
                    name: "Bad", memberNodeIDs: [UUID()]))
        ])
        XCTAssertThrowsError(try CanvasDocumentEditEngine.apply(batch, to: snapshot)) { error in
            guard case CanvasKitError.editScopeViolations(let violations) = error,
                  violations.first?.reason == .invalidReference else {
                XCTFail("expected invalidReference, got \(error)")
                return
            }
        }
    }

    // MARK: Regions (geometric containment)

    func testRegionDeleteContentsUsesGeometryNotStaleCache() throws {
        // Node with a NIL cache inside the region frame; another node with
        // a STALE cache (points at the region) but sits OUTSIDE the frame;
        // a node in a nested inner region (outer delete must include it).
        let insideNoCache = CanvasNodeSnapshot(
            content: .text("in"),
            frame: CanvasGeometry.Frame(
                center: .init(x: 50, y: 50),
                size: .init(width: 5, height: 5)))
        let outsideStaleCache = CanvasNodeSnapshot(
            content: .text("out"),
            frame: CanvasGeometry.Frame(
                center: .init(x: 500, y: 500),
                size: .init(width: 5, height: 5)))
        let innerRegion = CanvasRegionRecord(
            name: "Inner",
            frame: CanvasGeometry.Frame(
                center: .init(x: 20, y: 20),
                size: .init(width: 20, height: 20)))
        let innerMember = CanvasNodeSnapshot(
            content: .text("nested"),
            frame: CanvasGeometry.Frame(
                center: .init(x: 20, y: 20),
                size: .init(width: 4, height: 4)))
        let outerRegion = CanvasRegionRecord(
            name: "Outer",
            frame: CanvasGeometry.Frame(
                center: .init(x: 50, y: 50),
                size: .init(width: 100, height: 100)))
        let page = CanvasPageSnapshot(
            nodes: [insideNoCache, outsideStaleCache, innerMember],
            regions: [innerRegion, outerRegion])
        var snapshot = CanvasSnapshot(name: "R", pages: [page])
        // Stale cache: claims the outside node belongs to the outer region.
        snapshot.pages[0].nodes[1].regionID = outerRegion.id

        let result = try CanvasDocumentEditEngine.apply(
            CanvasDocumentBatch(operations: [
                .removeRegion(regionID: outerRegion.id, deleteContents: true)
            ]), to: snapshot)

        let remainingIDs = Set(result.snapshot.pages[0].nodes.map(\.id))
        XCTAssertFalse(remainingIDs.contains(insideNoCache.id))
        XCTAssertFalse(remainingIDs.contains(innerMember.id))
        XCTAssertTrue(remainingIDs.contains(outsideStaleCache.id))
        XCTAssertTrue(result.snapshot.pages[0].regions.contains(where: {
            $0.id == innerRegion.id
        }))
    }

    func testRegionDeleteContentsLockedMemberFailsWholeBatch() throws {
        let locked = CanvasNodeSnapshot(
            content: .text("locked"),
            frame: CanvasGeometry.Frame(
                center: .init(x: 0, y: 0), size: .init(width: 5, height: 5)),
            isLocked: true)
        let region = CanvasRegionRecord(
            name: "R",
            frame: CanvasGeometry.Frame(
                center: .zero, size: .init(width: 100, height: 100)))
        let page = CanvasPageSnapshot(
            nodes: [locked], regions: [region])
        let snapshot = CanvasSnapshot(name: "L", pages: [page])
        XCTAssertThrowsError(try CanvasDocumentEditEngine.apply(
            CanvasDocumentBatch(operations: [
                .removeRegion(regionID: region.id, deleteContents: true)
            ]), to: snapshot)) { error in
            guard case CanvasKitError.editScopeViolations(let violations) = error,
                  violations.contains(where: { $0.reason == .nodeLocked }) else {
                XCTFail("expected nodeLocked, got \(error)")
                return
            }
        }
    }

    func testMoveUpdatesDerivedRegionCache() throws {
        let node = CanvasNodeSnapshot(
            content: .text("n"),
            frame: CanvasGeometry.Frame(
                center: .zero, size: .init(width: 5, height: 5)))
        let region = CanvasRegionRecord(
            name: "R",
            frame: CanvasGeometry.Frame(
                center: .zero, size: .init(width: 100, height: 100)))
        let page = CanvasPageSnapshot(nodes: [node], regions: [region])
        let snapshot = CanvasSnapshot(name: "C", pages: [page])
        let movedOut = try CanvasEditEngine.apply(CanvasEditBatch(
            pageID: page.id,
            operations: [.move(nodeID: node.id, center: .init(x: 500, y: 500))]
        ), to: snapshot)
        XCTAssertNil(movedOut.snapshot.pages[0].nodes[0].regionID)
        let movedBack = try CanvasEditEngine.apply(CanvasEditBatch(
            pageID: page.id,
            operations: [.move(nodeID: node.id, center: .zero)]
        ), to: snapshot)
        XCTAssertEqual(movedBack.snapshot.pages[0].nodes[0].regionID, region.id)
    }

    // MARK: Scenes

    func testSceneCrudAndReferenceValidation() throws {
        let (snapshot, page, node) = makeSnapshot()
        let scene = CanvasSceneRecord(
            name: "Intro", focusedNodeIDs: [node.id])
        var result = try CanvasDocumentEditEngine.apply(
            CanvasDocumentBatch(operations: [
                .createScene(pageID: page.id, scene: scene)
            ]), to: snapshot)
        XCTAssertEqual(result.snapshot.pages[0].scenes.count, 1)

        result = try CanvasDocumentEditEngine.apply(
            CanvasDocumentBatch(operations: [
                .removeScene(sceneID: scene.id)
            ]), to: result.snapshot)
        XCTAssertTrue(result.snapshot.pages[0].scenes.isEmpty)

        let badScene = CanvasSceneRecord(
            name: "Bad", focusedNodeIDs: [UUID()])
        XCTAssertThrowsError(try CanvasDocumentEditEngine.apply(
            CanvasDocumentBatch(operations: [
                .createScene(pageID: page.id, scene: badScene)
            ]), to: snapshot)) { error in
            guard case CanvasKitError.editScopeViolations(let violations) = error,
                  violations.first?.reason == .invalidReference else {
                XCTFail("expected invalidReference, got \(error)")
                return
            }
        }
    }

    // MARK: Strokes

    func testStrokeCrudAndGeometryValidation() throws {
        let (snapshot, page, _) = makeSnapshot()
        let stroke = CanvasStrokeSnapshot(
            points: [.init(x: 0, y: 0), .init(x: 1, y: 1)], width: 2)
        var result = try CanvasDocumentEditEngine.apply(
            CanvasDocumentBatch(operations: [
                .addStroke(pageID: page.id, stroke: stroke)
            ]), to: snapshot)
        XCTAssertEqual(result.snapshot.pages[0].strokes.count, 1)

        let badStroke = CanvasStrokeSnapshot(
            points: [.init(x: .nan, y: 0)], width: 2)
        XCTAssertThrowsError(try CanvasDocumentEditEngine.apply(
            CanvasDocumentBatch(operations: [
                .addStroke(pageID: page.id, stroke: badStroke)
            ]), to: snapshot)) { error in
            guard case CanvasKitError.editScopeViolations(let violations) = error,
                  violations.first?.reason == .invalidGeometry else {
                XCTFail("expected invalidGeometry, got \(error)")
                return
            }
        }

        result = try CanvasDocumentEditEngine.apply(
            CanvasDocumentBatch(operations: [
                .removeStroke(strokeID: stroke.id)
            ]), to: result.snapshot)
        XCTAssertTrue(result.snapshot.pages[0].strokes.isEmpty)
    }

    // MARK: Node attributes + metadata patch

    func testNodeAttributeEditsRespectLocksAndValidateGeometry() throws {
        let (snapshot, page, node) = makeSnapshot()
        let source = CanvasSourceReference(sourceID: UUID(), usedRevision: 1)
        var result = try CanvasDocumentEditEngine.apply(
            CanvasDocumentBatch(operations: [
                .updateNodeSource(nodeID: node.id, source: source),
                .updateNodeRotation(nodeID: node.id, rotationDegrees: 45),
                .updateNodeStyle(nodeID: node.id, zIndex: 3),
            ]), to: snapshot)
        let edited = result.snapshot.pages[0].nodes[0]
        XCTAssertEqual(edited.source, source)
        XCTAssertEqual(edited.rotationDegrees, 45)
        XCTAssertEqual(edited.zIndex, 3)

        XCTAssertThrowsError(try CanvasDocumentEditEngine.apply(
            CanvasDocumentBatch(operations: [
                .updateNodeRotation(nodeID: node.id, rotationDegrees: .infinity)
            ]), to: snapshot)) { error in
            guard case CanvasKitError.editScopeViolations(let violations) = error,
                  violations.first?.reason == .invalidGeometry else {
                XCTFail("expected invalidGeometry, got \(error)")
                return
            }
        }

        var locked = result.snapshot
        locked.pages[0].nodes[0].isLocked = true
        XCTAssertThrowsError(try CanvasDocumentEditEngine.apply(
            CanvasDocumentBatch(operations: [
                .updateNodeStyle(nodeID: node.id, zIndex: 9)
            ]), to: locked)) { error in
            guard case CanvasKitError.editScopeViolations(let violations) = error,
                  violations.first?.reason == .nodeLocked else {
                XCTFail("expected nodeLocked, got \(error)")
                return
            }
        }
    }

    func testUpdateNodeMetadataPatchesAndValidates() throws {
        let (snapshot, page, node) = makeSnapshot()
        let result = try CanvasDocumentEditEngine.apply(
            CanvasDocumentBatch(operations: [
                .updateNodeMetadata(
                    nodeID: node.id,
                    values: [
                        CanvasVisualMetadataKeys.fillColor: "#FF0000",
                        CanvasVisualMetadataKeys.strokeWidth: "2.5",
                        "custom.key": "custom value",
                    ],
                    removingKeys: [])
            ]), to: snapshot)
        let metadata = result.snapshot.pages[0].nodes[0].metadata
        XCTAssertEqual(metadata[CanvasVisualMetadataKeys.fillColor], "#FF0000")
        XCTAssertEqual(metadata[CanvasVisualMetadataKeys.strokeWidth], "2.5")
        XCTAssertEqual(metadata["custom.key"], "custom value")

        XCTAssertThrowsError(try CanvasDocumentEditEngine.apply(
            CanvasDocumentBatch(operations: [
                .updateNodeMetadata(
                    nodeID: node.id,
                    values: [CanvasVisualMetadataKeys.strokeWidth: "not-a-number"],
                    removingKeys: [])
            ]), to: snapshot)) { error in
            guard case CanvasKitError.editScopeViolations(let violations) = error,
                  violations.first?.reason == .invalidGeometry else {
                XCTFail("expected invalidGeometry, got \(error)")
                return
            }
        }

        // Invalid binding UUID rejected.
        XCTAssertThrowsError(try CanvasDocumentEditEngine.apply(
            CanvasDocumentBatch(operations: [
                .updateNodeMetadata(
                    nodeID: node.id,
                    values: [CanvasFlowCardBindingKey.graphID: "junk"],
                    removingKeys: [])
            ]), to: snapshot)) { error in
            guard case CanvasKitError.editScopeViolations = error else {
                XCTFail("expected violations, got \(error)")
                return
            }
        }
    }

    // MARK: Nested editPage composition

    func testEditPageComposesNodeEditsIntoOneDocumentBatch() throws {
        let (snapshot, page, node) = makeSnapshot()
        let newNode = CanvasNodeSnapshot(
            content: .text("new"),
            frame: CanvasGeometry.Frame(
                center: .init(x: 300, y: 300),
                size: .init(width: 10, height: 10)))
        let result = try CanvasDocumentEditEngine.apply(
            CanvasDocumentBatch(operations: [
                .editPage(CanvasEditBatch(
                    pageID: page.id,
                    operations: [
                        .insertNode(newNode),
                        .move(nodeID: node.id, center: .init(x: 150, y: 150)),
                    ])),
                .renamePage(pageID: page.id, name: "Renamed"),
            ]), to: snapshot)
        XCTAssertEqual(result.snapshot.pages[0].nodes.count, 2)
        XCTAssertEqual(result.snapshot.pages[0].name, "Renamed")
        XCTAssertEqual(result.changedNodeIDs.sorted(), [node.id, newNode.id].sorted())
    }

    func testEditPageRejectsSelectedScopeAndNestedFailureRollsBackAll() throws {
        let (snapshot, page, node) = makeSnapshot()
        // Nested selectedNodes scope is a scopeEscalation (cannot widen).
        XCTAssertThrowsError(try CanvasDocumentEditEngine.apply(
            CanvasDocumentBatch(operations: [
                .editPage(CanvasEditBatch(
                    pageID: page.id,
                    scope: .selectedNodes([node.id]),
                    operations: [.move(nodeID: node.id, center: .zero)]))
            ]), to: snapshot)) { error in
            guard case CanvasKitError.editScopeViolations(let violations) = error,
                  violations.first?.reason == .scopeEscalation else {
                XCTFail("expected scopeEscalation, got \(error)")
                return
            }
        }

        // A nested violation aborts the WHOLE document batch.
        let lockedNode = CanvasNodeSnapshot(
            content: .text("locked"),
            frame: CanvasGeometry.Frame(
                center: .init(x: 5, y: 5), size: .init(width: 5, height: 5)),
            isLocked: true)
        var multi = snapshot
        multi.pages[0].nodes.append(lockedNode)
        XCTAssertThrowsError(try CanvasDocumentEditEngine.apply(
            CanvasDocumentBatch(operations: [
                .renamePage(pageID: page.id, name: "ShouldNotLand"),
                .editPage(CanvasEditBatch(
                    pageID: page.id,
                    operations: [.move(nodeID: lockedNode.id, center: .zero)])),
            ]), to: multi)) { error in
            guard case CanvasKitError.editScopeViolations(let violations) = error,
                  violations.contains(where: { $0.reason == .nodeLocked }) else {
                XCTFail("expected nodeLocked, got \(error)")
                return
            }
        }
        // Verify nothing landed by re-applying an empty batch: name unchanged.
        let check = try CanvasDocumentEditEngine.apply(
            CanvasDocumentBatch(operations: []), to: multi)
        XCTAssertEqual(check.snapshot.pages[0].name, page.name)
    }

    // MARK: Duplicate IDs in stored snapshot never trap

    func testDuplicateIDsInStoredSnapshotThrowRecoverableError() {
        let node = CanvasNodeSnapshot(
            content: .text("a"),
            frame: CanvasGeometry.Frame(
                center: .zero, size: .init(width: 5, height: 5)))
        var page = CanvasPageSnapshot(nodes: [node, node]) // duplicate ID
        page.id = UUID()
        let snapshot = CanvasSnapshot(name: "Dup", pages: [page])
        let batch = CanvasDocumentBatch(operations: [
            .renamePage(pageID: page.id, name: "X")
        ])
        XCTAssertThrowsError(try CanvasDocumentEditEngine.apply(batch, to: snapshot)) { error in
            guard case CanvasKitError.invalidSnapshot(let message) = error else {
                XCTFail("expected invalidSnapshot, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("duplicate node ID"))
        }
    }

    func testClassicEngineDuplicateIDsThrowInsteadOfTrapping() {
        let node = CanvasNodeSnapshot(
            content: .text("a"),
            frame: CanvasGeometry.Frame(
                center: .zero, size: .init(width: 5, height: 5)))
        var page = CanvasPageSnapshot(nodes: [node, node])
        page.id = UUID()
        let snapshot = CanvasSnapshot(name: "Dup", pages: [page])
        let batch = CanvasEditBatch(
            pageID: page.id,
            operations: [.move(nodeID: node.id, center: .init(x: 1, y: 1))])
        XCTAssertThrowsError(try CanvasEditEngine.apply(batch, to: snapshot)) { error in
            guard case CanvasKitError.invalidSnapshot = error else {
                XCTFail("expected invalidSnapshot, got \(error)")
                return
            }
        }
    }
}
