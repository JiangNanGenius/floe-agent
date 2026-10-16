#if canImport(UIKit)
import UIKit
import PencilKit
import Testing
import FloeNotes
@testable import FloeApp

@Suite("Notes live ink refresh")
@MainActor struct NotesInkRefreshTests {
    private func coordinator(onDrawing: @escaping (Data) -> Void = { _ in }) -> NotePencilView.Coordinator {
        NotePencilView(page: NotePage(), drawing: nil, background: nil, fingerDrawing: false,
                       tool: PKInkingTool(.marker, color: .yellow, width: 20), onDrawing: onDrawing).makeCoordinator()
    }
    private func nextTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
    private func markerDrawing() -> PKDrawing {
        let points = [CGPoint(x: 40, y: 50), CGPoint(x: 200, y: 50)].enumerated().map { index, location in
            PKStrokePoint(location: location, timeOffset: Double(index) * 0.1,
                          size: CGSize(width: 20, height: 20), opacity: 1, force: 1,
                          azimuth: 0, altitude: .pi / 2)
        }
        let stroke = PKStroke(ink: PKInk(.marker, color: UIColor.yellow.withAlphaComponent(0.45)),
                              path: PKStrokePath(controlPoints: points, creationDate: Date()))
        return PKDrawing(strokes: [stroke])
    }

    @Test("Equivalent marker, eraser and lasso updates do not reset PencilKit tools")
    func unchangedTools() {
        let canvas = PKCanvasView(), coordinator = coordinator()
        #expect(coordinator.applyToolIfChanged(PKInkingTool(.marker, color: .yellow, width: 20), to: canvas))
        for _ in 0..<10 {
            #expect(!coordinator.applyToolIfChanged(PKInkingTool(.marker, color: .yellow, width: 20), to: canvas))
        }
        #expect(coordinator.applyToolIfChanged(PKInkingTool(.marker, color: .red, width: 20), to: canvas))
        #expect(coordinator.applyToolIfChanged(PKEraserTool(.vector), to: canvas))
        #expect(!coordinator.applyToolIfChanged(PKEraserTool(.vector), to: canvas))
        #expect(coordinator.applyToolIfChanged(PKLassoTool(), to: canvas))
        #expect(!coordinator.applyToolIfChanged(PKLassoTool(), to: canvas))
    }

    @Test("Many drawing changes coalesce into one post-stroke display request without rewriting ink")
    func coalescedStrokeRefresh() async {
        let canvas = PKCanvasView()
        var saves = 0
        let coordinator = coordinator { _ in saves += 1 }
        coordinator.canvasViewDidBeginUsingTool(canvas)
        canvas.drawing = markerDrawing()
        coordinator.canvasViewDrawingDidChange(canvas)
        for _ in 0..<20 { coordinator.noteInkRevision() }
        #expect(saves == 0)
        #expect(coordinator.displayRefreshCount == 0)
        let original = canvas.drawing.dataRepresentation()
        coordinator.canvasViewDidEndUsingTool(canvas)
        coordinator.scheduleInkDisplayRefresh(canvas)
        coordinator.canvasViewDidEndUsingTool(canvas)
        await nextTurn()
        #expect(coordinator.displayRefreshCount == 1)
        #expect(saves == 1)
        #expect(canvas.drawing.dataRepresentation() == original)
        coordinator.canvasViewDidEndUsingTool(canvas)
        await nextTurn()
        #expect(coordinator.displayRefreshCount == 1)
        coordinator.noteInkRevision()
        coordinator.canvasViewDidEndUsingTool(canvas)
        await nextTurn()
        #expect(coordinator.displayRefreshCount == 2)
    }

    @Test("A render-complete callback cancels a queued invalidation")
    func renderArrivalCancelsRefresh() async {
        let canvas = PKCanvasView(), coordinator = coordinator()
        coordinator.noteInkRevision()
        coordinator.canvasViewDidEndUsingTool(canvas)
        coordinator.canvasViewDidFinishRendering(canvas)
        await nextTurn()
        #expect(coordinator.displayRefreshCount == 0)
    }

    @Test("A resumed stroke postpones the queued refresh until its end")
    func refreshDoesNotInterruptStroke() async {
        let canvas = PKCanvasView(), coordinator = coordinator()
        coordinator.noteInkRevision(); coordinator.canvasViewDidEndUsingTool(canvas)
        coordinator.canvasViewDidBeginUsingTool(canvas)
        await nextTurn()
        #expect(coordinator.displayRefreshCount == 0)
        coordinator.canvasViewDidEndUsingTool(canvas)
        await nextTurn()
        #expect(coordinator.displayRefreshCount == 1)
    }

    @Test("Late rendering views cannot cover ink with paper and repeated layouts do not republish viewport")
    func paperOrderingAndViewport() {
        let canvas = NotesPKCanvasView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        canvas.pageSize = CGSize(width: 768, height: 1024)
        let paper = UIImageView(), lateInk = UIView()
        canvas.addSubview(paper); canvas.pageBackdrop = paper
        canvas.insertSubview(lateInk, at: 0)
        var viewportReports = 0
        canvas.onViewportChanged = { _ in viewportReports += 1 }
        for _ in 0..<10 { canvas.setNeedsLayout(); canvas.layoutIfNeeded() }
        #expect(canvas.subviews.first === paper)
        #expect(canvas.subviews.firstIndex(of: lateInk)! > canvas.subviews.firstIndex(of: paper)!)
        #expect(viewportReports == 1)
        canvas.contentOffset.y += 30; canvas.rememberPagePosition()
        #expect(viewportReports == 2)
    }
}
#endif
