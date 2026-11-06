#if canImport(UIKit)
import XCTest
@testable import FloeCanvasUI
import FloeCanvasCore
import FloeCanvasIntegration

/// Explicit source refresh through the store (ICH04): no auto-overwrite,
/// annotations preserved, conflict produces recoverable branch node.
@MainActor
final class CanvasSourceRefreshUITests: XCTestCase {
    func testRefreshUpdatesContentAndPreservesAnnotation() async throws {
        let sourceID = UUID()
        var node = CanvasTestStubs.textNode("old text")
        node.source = CanvasSourceReference(
            sourceID: sourceID,
            usedRevision: 1,
            annotations: [CanvasSourceAnnotation(author: "qa", text: "note")])
        let snapshot = CanvasTestStubs.snapshot(nodes: [node])
        let service = CanvasTestStubs.FakeSourceService(
            revision: 2, text: "new text")
        let store = CanvasEditorStore(
            canvasID: snapshot.id,
            services: CanvasEditorServices(
                documentStore: InMemoryCanvasRepository(snapshot: snapshot),
                sourceService: service))
        await store.load()
        await store.refreshSource(nodeID: node.id, instruction: .default)
        let refreshed = try XCTUnwrap(store.page.nodes.first)
        guard case .text(let text) = refreshed.content else {
            return XCTFail("expected text content")
        }
        XCTAssertEqual(text, "new text")
        XCTAssertEqual(refreshed.source?.usedRevision, 2)
        XCTAssertEqual(refreshed.source?.annotations.count, 1)
        XCTAssertEqual(store.revision, 1, "exactly one committed batch")
    }

    func testRefreshWithManualEditBranchesByDefault() async throws {
        let sourceID = UUID()
        var node = CanvasTestStubs.textNode("old")
        node.source = CanvasSourceReference(
            sourceID: sourceID,
            usedRevision: 1,
            annotations: [])
        let snapshot = CanvasTestStubs.snapshot(nodes: [node])
        let service = CanvasTestStubs.FakeSourceService(
            revision: 6, text: "fresh")
        let store = CanvasEditorStore(
            canvasID: snapshot.id,
            services: CanvasEditorServices(
                documentStore: InMemoryCanvasRepository(snapshot: snapshot),
                sourceService: service))
        await store.load()
        await store.apply(.updateContent(node.id, .text("hand edited")))
        XCTAssertEqual(store.revision, 1, "content and manual-edit marker commit together")
        XCTAssertEqual(store.page.nodes.first?.metadata[CanvasSourceRefresher.manualEditRevisionMetadataKey], "2")
        await store.refreshSource(nodeID: node.id, instruction: .default)
        XCTAssertEqual(store.page.nodes.count, 2, "original kept + branch")
        let original = store.page.nodes.first(where: { $0.id == node.id })
        guard case .text(let originalText)? = original?.content else {
            return XCTFail("original must be preserved")
        }
        XCTAssertEqual(originalText, "hand edited")
    }
}

/// Command → batch translation semantics.
final class CanvasCommandBatchBuilderTests: XCTestCase {
    private func makeSnapshot() -> CanvasSnapshot {
        let a = CanvasTestStubs.textNode("a", center: .init(x: 0, y: 0))
        let b = CanvasTestStubs.textNode("b", center: .init(x: 300, y: 0))
        return CanvasSnapshot(
            name: "s",
            pages: [CanvasPageSnapshot(
                name: "P",
                nodes: [a, b],
                connections: [CanvasConnectionSnapshot(
                    sourceNodeID: a.id,
                    destinationNodeID: b.id,
                    kind: .arrow)])])
    }

    func testDeleteSelectionIncludesConnectionsCleanup() throws {
        let snapshot = makeSnapshot()
        let a = snapshot.pages[0].nodes[0]
        let batch = try CanvasCommandBatchBuilder.makeBatch(
            .deleteSelection,
            in: snapshot,
            pageID: snapshot.pages[0].id,
            selection: [a.id],
            configuration: CanvasEditorConfiguration())
        let result = try CanvasDocumentEditEngine.apply(batch, to: snapshot)
        XCTAssertEqual(result.snapshot.pages[0].nodes.count, 1)
        XCTAssertTrue(result.snapshot.pages[0].connections.isEmpty)
    }

    func testGroupAndRegionRequireWholeDocument() throws {
        let snapshot = makeSnapshot()
        let a = snapshot.pages[0].nodes[0]
        let groupBatch = try CanvasCommandBatchBuilder.makeBatch(
            .groupSelection,
            in: snapshot,
            pageID: snapshot.pages[0].id,
            selection: [a.id],
            configuration: CanvasEditorConfiguration())
        XCTAssertEqual(groupBatch.scope, .wholeDocument)
        let regionBatch = try CanvasCommandBatchBuilder.makeBatch(
            .createRegionForSelection(name: "R"),
            in: snapshot,
            pageID: snapshot.pages[0].id,
            selection: [a.id],
            configuration: CanvasEditorConfiguration())
        guard case .createRegion(_, let region) = regionBatch.operations[0] else {
            return XCTFail("expected createRegion")
        }
        XCTAssertGreaterThanOrEqual(region.frame.size.width, 80)
        let applied = try CanvasDocumentEditEngine.apply(regionBatch, to: snapshot)
        XCTAssertEqual(applied.snapshot.pages[0].regions.count, 1)
    }

    func testLockGestureUsesWholeDocumentScope() throws {
        let snapshot = makeSnapshot()
        let a = snapshot.pages[0].nodes[0]
        let batch = try CanvasCommandBatchBuilder.makeBatch(
            .setLocked([a.id], true),
            in: snapshot,
            pageID: snapshot.pages[0].id,
            selection: [a.id],
            configuration: CanvasEditorConfiguration())
        guard case .editPage(let pageBatch) = batch.operations[0] else {
            return XCTFail("expected nested page batch")
        }
        XCTAssertEqual(pageBatch.scope, .wholeDocument)
    }

    func testDuplicateSelectionRetainsInternalLinks() throws {
        let snapshot = makeSnapshot()
        let page = snapshot.pages[0]
        let selection = Set(page.nodes.map(\.id))
        let plan = try CanvasSelectionDuplicator.plan(
            snapshot: snapshot, pageID: page.id, nodeIDs: selection)
        XCTAssertEqual(plan.newNodeIDs.count, 2)
        let result = try CanvasDocumentEditEngine.apply(plan.batch, to: snapshot)
        let applied = result.snapshot.pages[0]
        XCTAssertEqual(applied.nodes.count, 4)
        XCTAssertEqual(applied.connections.count, 2)
        let newConnection = applied.connections.first(where: { connection in
            !page.connections.contains(where: { $0.id == connection.id })
        })
        XCTAssertNotNil(newConnection)
        XCTAssertTrue(applied.nodes.contains(where: { $0.id == newConnection?.sourceNodeID }))
        XCTAssertTrue(applied.nodes.contains(where: { $0.id == newConnection?.destinationNodeID }))
    }
}

/// Accessibility identifiers and bilingual copy parity.
final class CanvasAccessibilityAndStringsTests: XCTestCase {
    func testAccessibilityIDsAreUnique() {
        let all = CanvasAccessibilityID.allCases.map(\.identifier)
        XCTAssertEqual(Set(all).count, all.count)
        for identifier in all {
            XCTAssertTrue(identifier.hasPrefix("floe.canvas."))
        }
    }

    func testEnglishAndChineseKeyParity() {
        let english = CanvasStrings(language: .english)
        let chinese = CanvasStrings(language: .simplifiedChinese)
        for key in CanvasStrings.Key.allCases {
            XCTAssertFalse(english[key].isEmpty, key.rawValue)
            XCTAssertFalse(chinese[key].isEmpty, key.rawValue)
            XCTAssertNotEqual(english[key], key.rawValue,
                              "unmapped key: \(key.rawValue)")
            XCTAssertNotEqual(chinese[key], key.rawValue,
                              "unmapped key: \(key.rawValue)")
        }
    }

    func testLanguageResolution() {
        XCTAssertEqual(
            CanvasStrings.resolve(preferred: .simplifiedChinese),
            .simplifiedChinese)
        XCTAssertEqual(
            CanvasStrings.resolve(preferred: nil, locale: Locale(identifier: "zh-Hans")),
            .simplifiedChinese)
        XCTAssertEqual(
            CanvasStrings.resolve(preferred: nil, locale: Locale(identifier: "en-AU")),
            .english)
    }
}

#endif // canImport(UIKit)
