import XCTest
@testable import FloeCanvasCore
@testable import FloeCanvasIntegration

private actor FakeSourceService: CanvasSourceService {
    var revisions: [UUID: Int64] = [:]
    var contents: [UUID: String] = [:]

    func setRevision(_ revision: Int64, for sourceID: UUID) {
        revisions[sourceID] = revision
    }

    func setContent(_ content: String, for sourceID: UUID) {
        contents[sourceID] = content
    }

    func currentRevision(sourceID: UUID) throws -> Int64 {
        guard let revision = revisions[sourceID] else {
            throw CanvasKitError.sourceUnavailable(sourceID)
        }
        return revision
    }

    func read(sourceID: UUID, fragment: String?) throws -> CanvasSourceContent {
        guard let text = contents[sourceID] else {
            throw CanvasKitError.sourceUnavailable(sourceID)
        }
        return CanvasSourceContent(
            sourceID: sourceID, revision: revisions[sourceID] ?? 0,
            text: text, fragment: fragment)
    }
}

final class SourceRefreshTests: XCTestCase {
    private func makeFixture() -> (CanvasSnapshot, CanvasPageSnapshot, CanvasNodeSnapshot, FakeSourceService) {
        let service = FakeSourceService()
        let node = CanvasNodeSnapshot(
            content: .text("old text"),
            frame: CanvasGeometry.Frame(center: .zero, size: .init(width: 10, height: 10)),
            source: CanvasSourceReference(
                sourceID: UUID(),
                usedRevision: 3,
                annotations: [CanvasSourceAnnotation(author: "u", text: "important")]
            )
        )
        let page = CanvasPageSnapshot(nodes: [node])
        let snapshot = CanvasSnapshot(name: "S", pages: [page])
        return (snapshot, page, node, service)
    }

    func testUnchangedSourceLeavesSnapshotUntouched() async throws {
        let (snapshot, page, node, service) = makeFixture()
        await service.setRevision(3, for: node.source!.sourceID)
        let refresher = CanvasSourceRefresher(sourceService: service)
        let result = try await refresher.refresh(
            canvasID: snapshot.id, in: snapshot, pageID: page.id,
            nodeIDs: [node.id])
        guard case .unchanged = result.outcome else {
            XCTFail("expected unchanged, got \(result.outcome)")
            return
        }
        XCTAssertEqual(result.snapshot, snapshot)
    }

    func testRefreshInPlacePreservesAnnotations() async throws {
        let (snapshot, page, node, service) = makeFixture()
        await service.setRevision(4, for: node.source!.sourceID)
        await service.setContent("new text", for: node.source!.sourceID)
        let refresher = CanvasSourceRefresher(sourceService: service)
        let result = try await refresher.refresh(
            canvasID: snapshot.id, in: snapshot, pageID: page.id,
            nodeIDs: [node.id])
        guard case .updated(let ids) = result.outcome else {
            XCTFail("expected updated, got \(result.outcome)")
            return
        }
        XCTAssertEqual(ids, [node.id])
        let refreshed = result.snapshot.selectedPage!.nodes[0]
        XCTAssertEqual(refreshed.textContent, "new text")
        XCTAssertEqual(refreshed.source?.usedRevision, 4)
        XCTAssertEqual(refreshed.source?.annotations.count, 1)
    }

    func testManualEditProducesRecoverableAlternativeBranch() async throws {
        let (snapshot, page, node, service) = makeFixture()
        let sourceID = node.source!.sourceID
        await service.setRevision(4, for: sourceID)
        await service.setContent("new text", for: sourceID)
        var edited = snapshot
        edited.pages[0].nodes[0].textContent = "user edit"
        edited.pages[0].nodes[0].metadata[CanvasSourceRefresher.manualEditRevisionMetadataKey] = "4"

        let refresher = CanvasSourceRefresher(sourceService: service)
        let result = try await refresher.refresh(
            canvasID: snapshot.id, in: edited, pageID: page.id,
            nodeIDs: [node.id])
        guard case .conflict(let alternatives, let originals) = result.outcome else {
            XCTFail("expected conflict, got \(result.outcome)")
            return
        }
        XCTAssertEqual(originals, [node.id])
        XCTAssertEqual(alternatives.count, 1)
        let resultPage = result.snapshot.selectedPage!
        let original = resultPage.nodes.first { $0.id == node.id }!
        let alternative = resultPage.nodes.first { $0.id == alternatives[0] }!
        // Original kept exactly as the user left it.
        XCTAssertEqual(original.textContent, "user edit")
        XCTAssertEqual(original.source?.usedRevision, 3)
        // Alternative carries the fresh content and is discarded run-free.
        XCTAssertEqual(alternative.textContent, "new text")
        XCTAssertEqual(alternative.source?.usedRevision, 4)
        XCTAssertNil(alternative.createdByRunID)
    }

    func testExplicitReplaceInstructionWinsOverDefault() async throws {
        let (snapshot, page, node, service) = makeFixture()
        let sourceID = node.source!.sourceID
        await service.setRevision(4, for: sourceID)
        await service.setContent("new text", for: sourceID)
        var edited = snapshot
        edited.pages[0].nodes[0].textContent = "user edit"
        edited.pages[0].nodes[0].metadata[CanvasSourceRefresher.manualEditRevisionMetadataKey] = "4"

        let refresher = CanvasSourceRefresher(sourceService: service)
        let result = try await refresher.refresh(
            canvasID: snapshot.id, in: edited, pageID: page.id,
            nodeIDs: [node.id], instruction: .replace)
        guard case .updated = result.outcome else {
            XCTFail("expected updated, got \(result.outcome)")
            return
        }
        let replaced = result.snapshot.selectedPage!.nodes[0]
        XCTAssertEqual(replaced.textContent, "new text")
        XCTAssertEqual(result.snapshot.selectedPage!.nodes.count, 1)
    }

    func testExplicitBranchInstructionKeepsOriginal() async throws {
        let (snapshot, page, node, service) = makeFixture()
        let sourceID = node.source!.sourceID
        await service.setRevision(4, for: sourceID)
        await service.setContent("new text", for: sourceID)
        let refresher = CanvasSourceRefresher(sourceService: service)
        let result = try await refresher.refresh(
            canvasID: snapshot.id, in: snapshot, pageID: page.id,
            nodeIDs: [node.id], instruction: .branch)
        guard case .conflict = result.outcome else {
            XCTFail("expected conflict, got \(result.outcome)")
            return
        }
        XCTAssertEqual(result.snapshot.selectedPage!.nodes.count, 2)
    }

    func testMissingSourceThrowsRecoverable() async throws {
        let (snapshot, page, node, service) = makeFixture()
        _ = service
        let refresher = CanvasSourceRefresher(sourceService: service)
        await XCTAssertThrowsErrorAsync({ try await refresher.refresh(
            canvasID: snapshot.id, in: snapshot, pageID: page.id,
            nodeIDs: [node.id]) }) { error in
            guard case CanvasKitError.sourceUnavailable = error else {
                XCTFail("expected sourceUnavailable, got \(error)")
                return
            }
            guard let kitError = error as? CanvasKitError else {
                XCTFail("expected CanvasKitError")
                return
            }
            XCTAssertTrue(kitError.isRecoverable)
        }
    }
}
