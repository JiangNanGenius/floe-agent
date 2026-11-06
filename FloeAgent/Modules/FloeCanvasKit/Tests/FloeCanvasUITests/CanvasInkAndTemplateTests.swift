#if canImport(UIKit)
import XCTest
@testable import FloeCanvasUI
import FloeCanvasCore
import FloeCanvasIntegration
import PencilKit

/// Ink recognition geometry + convert/keep batches (ICH05).
final class CanvasInkRecognitionTests: XCTestCase {
    private func lineDrawing() -> PKDrawing {
        let points = [CGPoint(x: 100, y: 150), CGPoint(x: 240, y: 150)].enumerated().map {
            PKStrokePoint(location: $0.element, timeOffset: Double($0.offset) * 0.1,
                size: CGSize(width: 3, height: 3), opacity: 1, force: 1,
                azimuth: 0, altitude: .pi / 2)
        }
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black),
            path: PKStrokePath(controlPoints: points, creationDate: Date()))])
    }

    @MainActor
    func testFinalStrokePublicationAfterToolEndIsSavedOnce() async throws {
        let page = CanvasPageSnapshot()
        let snapshot = CanvasSnapshot(name: "Ink publication", pages: [page])
        let repository = InMemoryCanvasRepository(snapshot: snapshot)
        let store = CanvasEditorStore(canvasID: snapshot.id, services: .init(documentStore: repository))
        await store.load()
        store.setViewport(try .init(center: .zero, scale: 1, viewSize: .init(width: 800, height: 600)))
        let board = CanvasBoardView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        board.bind(to: store)
        let ink = board.inkOverlay
        ink.editingTool = .pencil
        ink.canvasViewDidBeginUsingTool(ink)
        ink.canvasViewDidEndUsingTool(ink)
        // This is the actual callback order observed on Simulator:
        // tool-end arrives before the final PKDrawing is published.
        ink.drawing = lineDrawing()
        ink.canvasViewDrawingDidChange(ink)
        let deadline = Date().addingTimeInterval(3)
        while store.inkRecognitionSession == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let data = try XCTUnwrap(store.page.pencilDrawingData)
        XCTAssertEqual(try PKDrawing(data: data).strokes.count, 1)
        XCTAssertNotNil(store.inkRecognitionSession)
        let history = try await repository.historyAvailability(canvasID: snapshot.id)
        XCTAssertEqual(history.undoCount, 1, "no provisional empty-drawing save")
    }

    @MainActor
    func testPendingInkSaveKeepsItsOriginalPageAfterNavigation() async throws {
        let first = CanvasPageSnapshot(name: "First")
        let second = CanvasPageSnapshot(name: "Second")
        let snapshot = CanvasSnapshot(name: "Ink ownership", pages: [first, second])
        let repository = InMemoryCanvasRepository(snapshot: snapshot)
        let store = CanvasEditorStore(canvasID: snapshot.id, services: .init(documentStore: repository))
        await store.load()
        let revision = store.revision
        await store.selectPage(second.id)
        let data = lineDrawing().dataRepresentation()
        await store.finishInkGesture(worldData: data, clearedData: PKDrawing().dataRepresentation(),
            newStrokePointsWorld: [[.init(x: 0, y: 0), .init(x: 140, y: 0)]],
            wasInking: true, pageID: first.id, expectedRevision: revision)
        let saved = try await repository.load(canvasID: snapshot.id)
        XCTAssertEqual(saved.pages[0].pencilDrawingData, data)
        XCTAssertNil(saved.pages[1].pencilDrawingData)
        XCTAssertNil(store.inkRecognitionSession, "a late save cannot open a prompt on another page")
    }

    @MainActor
    func testInkConversionRetainsPageAndRejectsNewerRevision() async throws {
        let first = CanvasPageSnapshot(name: "First")
        let second = CanvasPageSnapshot(name: "Second")
        let snapshot = CanvasSnapshot(name: "Conversion", pages: [first, second])
        let repository = InMemoryCanvasRepository(snapshot: snapshot)
        let store = CanvasEditorStore(canvasID: snapshot.id, services: .init(documentStore: repository))
        await store.load()
        let data = lineDrawing().dataRepresentation()
        let points: [[CanvasGeometry.Point]] = [[.init(x: 0, y: 0), .init(x: 140, y: 0)]]
        await store.finishInkGesture(worldData: data, clearedData: PKDrawing().dataRepresentation(),
            newStrokePointsWorld: points, wasInking: true)
        XCTAssertEqual(store.inkRecognitionSession?.pageID, first.id)
        await store.selectPage(second.id)
        await store.applyInkConversion(keepInk: true)
        var saved = try await repository.load(canvasID: snapshot.id)
        XCTAssertEqual(saved.pages[0].nodes.count, 1)
        XCTAssertTrue(saved.pages[1].nodes.isEmpty)
        await store.selectPage(first.id)
        await store.finishInkGesture(worldData: data, clearedData: PKDrawing().dataRepresentation(),
            newStrokePointsWorld: points, wasInking: true)
        let expected = store.revision
        _ = try await repository.commitDocument(.init(scope: .wholeDocument,
            operations: [.renamePage(pageID: second.id, name: "Remote")]),
            canvasID: snapshot.id, expectedRevision: expected, requestID: UUID())
        await store.load()
        await store.applyInkConversion(keepInk: false)
        XCTAssertEqual(store.drafts.count, 1)
        saved = try await repository.load(canvasID: snapshot.id)
        XCTAssertEqual(saved.pages[0].nodes.count, 1)
        XCTAssertEqual(saved.pages[0].pencilDrawingData, data)
        XCTAssertEqual(saved.pages[1].name, "Remote")
    }

    @MainActor
    func testSavedInkStaysVisibleWhenToolsChangeAndUndoRestoresDrawing() async throws {
        let points = [CGPoint(x: 10, y: 10), CGPoint(x: 80, y: 20)].enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) * 0.1,
                size: CGSize(width: 3, height: 3), opacity: 1, force: 1,
                azimuth: 0, altitude: .pi / 2)
        }
        let stroke = PKStroke(ink: PKInk(.pencil, color: .black),
            path: PKStrokePath(controlPoints: points, creationDate: Date()))
        var page = CanvasPageSnapshot(name: "Ink")
        page.pencilDrawingData = PKDrawing(strokes: [stroke]).dataRepresentation()
        let snapshot = CanvasSnapshot(name: "Ink", pages: [page])
        let store = CanvasEditorStore(canvasID: snapshot.id, services: .init(
            documentStore: InMemoryCanvasRepository(snapshot: snapshot)))
        await store.load()
        let board = CanvasBoardView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        board.bind(to: store)
        board.inkOverlay.syncTransform()
        XCTAssertFalse(board.inkOverlay.isHidden, "saved ink is visible in select mode")
        XCTAssertFalse(board.inkOverlay.isUserInteractionEnabled)
        XCTAssertEqual(board.inkOverlay.drawing.strokes.count, 1)
        store.tool = .lasso
        let deadline = Date().addingTimeInterval(2)
        while !board.inkOverlay.isUserInteractionEnabled, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(board.inkOverlay.isUserInteractionEnabled)
        XCTAssertTrue(board.inkOverlay.tool is PKLassoTool)
        await store.savePencilDrawing(PKDrawing().dataRepresentation())
        board.inkOverlay.syncTransform()
        XCTAssertTrue(board.inkOverlay.drawing.strokes.isEmpty)
        await store.undo()
        board.inkOverlay.syncTransform()
        XCTAssertEqual(board.inkOverlay.drawing.strokes.count, 1)
    }
    func testStraightLineRecognized() {
        let points = (0...20).map {
            CanvasGeometry.Point(x: Double($0) * 5, y: 100)
        }
        let result = CanvasInkRecognition.recognize(points: points)
        guard case .line(let start, let end)? = result?.shape else {
            return XCTFail("expected line")
        }
        XCTAssertEqual(start.x, 0, accuracy: 0.001)
        XCTAssertEqual(end.x, 100, accuracy: 0.001)
    }

    func testCurvedStrokeNotRecognized() {
        let points = (0...30).map { index in
            CanvasGeometry.Point(
                x: Double(index) * 4,
                y: 100 + sin(Double(index) / 4) * 40)
        }
        XCTAssertNil(CanvasInkRecognition.recognize(points: points))
    }

    func testClosedBoxRecognized() {
        let points: [CanvasGeometry.Point] = [
            .init(x: 0, y: 0), .init(x: 100, y: 5),
            .init(x: 98, y: 60), .init(x: 4, y: 58),
            .init(x: 2, y: 2),
        ]
        let result = CanvasInkRecognition.recognize(points: points)
        guard case .box(let frame)? = result?.shape else {
            return XCTFail("expected box")
        }
        XCTAssertGreaterThan(frame.size.width, 80)
        XCTAssertGreaterThan(frame.size.height, 40)
    }

    func testArrowWithHeadStroke() {
        let shaft = (0...20).map {
            CanvasGeometry.Point(x: Double($0) * 5, y: 100)
        }
        let head: [CanvasGeometry.Point] = [
            .init(x: 100, y: 100),
            .init(x: 86, y: 90),
        ]
        let result = CanvasInkRecognition.recognize(strokes: [shaft, head])
        guard case .arrow(let start, let end)? = result?.shape else {
            return XCTFail("expected arrow")
        }
        XCTAssertEqual(end.x, 100, accuracy: 0.001)
        XCTAssertLessThan(start.x, end.x)
    }

    func testInkConversionBatchKeepVsClear() {
        let pageID = UUID()
        let result = CanvasInkRecognition.Result(
            shape: .box(frame: .init(
                center: .init(x: 10, y: 10),
                size: .init(width: 80, height: 60))),
            bounds: .init(center: .init(x: 10, y: 10), size: .init(width: 80, height: 60)),
            confidence: 0.9)
        let keep = CanvasInkObjectConversionBatchBuilder.batch(
            pageID: pageID, results: [result], keepInk: true,
            clearedPencilData: Data([1]))
        XCTAssertEqual(keep.operations.count, 1)
        let clear = CanvasInkObjectConversionBatchBuilder.batch(
            pageID: pageID, results: [result], keepInk: false,
            clearedPencilData: Data([1]))
        guard case .editPage(let pageBatch) = clear.operations[0] else {
            return XCTFail("expected nested page batch")
        }
        XCTAssertEqual(pageBatch.operations.count, 2)
        XCTAssertTrue(pageBatch.operations.contains(where: {
            if case .setPencilDrawingData = $0 { return true }
            return false
        }))
    }
}

/// Template factory + goal composer honesty (ICQA03).
@MainActor
final class CanvasTemplatesTests: XCTestCase {
    func testLabTemplateFlaggedDeterministic() {
        let content = CanvasTemplateFactory.make(
            .lab, name: "L", configuration: CanvasEditorConfiguration())
        XCTAssertTrue(content.isDeterministicLabSample)
        XCTAssertNotNil(content.flowGraph)
        let research = CanvasTemplateFactory.make(
            .research, name: "R", configuration: CanvasEditorConfiguration())
        XCTAssertFalse(research.isDeterministicLabSample)
        XCTAssertFalse(research.connections.isEmpty)
    }

    func testGoalComposerFallsBackWithoutGateway() async {
        let snapshot = CanvasTestStubs.snapshot()
        let store = CanvasEditorStore(
            canvasID: snapshot.id,
            services: CanvasEditorServices(
                documentStore: InMemoryCanvasRepository(snapshot: snapshot)))
        let content = await CanvasSceneGoalComposer.compose(
            description: "compare two designs",
            template: .compare,
            store: store)
        XCTAssertFalse(content.isDeterministicLabSample)
        XCTAssertEqual(content.nodes.count, 3, "plain compare template")
    }

    func testGoalComposerUsesProposalGateway() async {
        let node = CanvasTestStubs.textNode("generated")
        let proposal = CanvasAssistantProposal.canvasBatch(CanvasEditBatch(
            pageID: UUID(),
            scope: .selectedNodes([node.id]),
            operations: [.insertNode(node)]))
        let snapshot = CanvasTestStubs.snapshot()
        let store = CanvasEditorStore(
            canvasID: snapshot.id,
            services: CanvasEditorServices(
                documentStore: InMemoryCanvasRepository(snapshot: snapshot),
                proposalGateway: CanvasTestStubs.FakeProposalGateway(
                    proposal: proposal)))
        let content = await CanvasSceneGoalComposer.compose(
            description: "make a card",
            template: .research,
            store: store)
        XCTAssertEqual(content.nodes.count, 1)
        XCTAssertEqual(content.nodes.first?.id, node.id)
    }

    func testCreateScenePageCommitsOneBatch() async {
        let snapshot = CanvasTestStubs.snapshot()
        let store = CanvasEditorStore(
            canvasID: snapshot.id,
            services: CanvasEditorServices(
                documentStore: InMemoryCanvasRepository(snapshot: snapshot)))
        await store.load()
        let content = CanvasTemplateFactory.make(
            .research, name: "Scene", configuration: store.configuration)
        let revisionBefore = store.revision
        await store.createScenePage(from: content)
        XCTAssertEqual(store.revision, revisionBefore + 1, "one undo unit")
        XCTAssertEqual(store.snapshot.pages.count, 2)
        let newPage = store.page
        XCTAssertEqual(newPage.nodes.count, content.nodes.count)
        XCTAssertEqual(newPage.connections.count, content.connections.count)
        await store.undo()
        XCTAssertEqual(store.snapshot.pages.count, 1)
    }
}

#endif // canImport(UIKit)
