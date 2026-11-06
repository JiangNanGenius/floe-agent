#if canImport(UIKit)
import UIKit
import PencilKit
import FloeCanvasCore

/// PencilKit surface overlaid on the board for freehand ink.
///
/// World alignment (ICH05): the overlay always renders the document's
/// `page.pencilDrawingData` (world-space PKDrawing bytes) transformed into
/// the current view coordinates, so strokes drawn at any zoom land in
/// world coordinates and survive reopen byte-for-byte.
public final class CanvasInkOverlayView: PKCanvasView {
    weak var board: CanvasBoardView?
    var editingTool: CanvasEditingTool = .select {
        didSet { applyTool() }
    }

    /// Stroke count when the current gesture began — used to isolate new
    /// strokes for recognition and ink-retention decisions.
    private var strokeCountAtGestureStart = 0
    private var isDrawingGesture = false
    private var gestureWasInking = false
    private var isSynchronizing = false
    private let drawingDelegate = CanvasInkDrawingDelegate()
    private var endingTask: Task<Void, Never>?
    private var isEndingGesture = false
    private var gesturePageID: UUID?
    private var gestureRevision: Int64 = 0
    private var gestureTransform = CGAffineTransform.identity

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        // PKCanvasView itself implements internal drawing delegation.
        // Using the canvas as its own public delegate recurses through
        // UIKit's forwarding chain when an actual stroke begins.
        drawingDelegate.owner = self
        delegate = drawingDelegate
        isScrollEnabled = false
        bounces = false
        alwaysBounceHorizontal = false
        alwaysBounceVertical = false
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        drawingPolicy = .anyInput   // synthetic/stylus-optional qualification
        backgroundColor = .clear
        isOpaque = false
        isHidden = false
        isUserInteractionEnabled = false
        accessibilityIdentifier = CanvasAccessibilityID.boardInk.identifier
        applyTool()
    }

    private func applyTool() {
        switch editingTool {
        case .pencil:
            self.tool = PKInkingTool(.pencil, color: .label, width: 3)
        case .eraser:
            self.tool = PKEraserTool(.vector)
        case .lasso:
            self.tool = PKLassoTool()
        default:
            break
        }
    }

    /// Reloads the view-space drawing from the document bytes after pan,
    /// zoom, or external snapshot changes.
    func syncTransform() {
        guard !isDrawingGesture, let board, let store = board.store else { return }
        let worldData = store.page.pencilDrawingData
        let worldDrawing: PKDrawing
        if let worldData, !worldData.isEmpty,
           let decoded = try? PKDrawing(data: worldData) {
            worldDrawing = decoded
        } else {
            worldDrawing = PKDrawing()
        }
        let viewDrawing = worldDrawing.transformed(
            using: board.worldToViewAffine(store.viewport))
        isSynchronizing = true
        defer { isSynchronizing = false }
        super.drawing = viewDrawing
        strokeCountAtGestureStart = viewDrawing.strokes.count
    }

    /// World-space transform for the current view state.
    private var viewToWorldAffine: CGAffineTransform {
        guard let board, let store = board.store else { return .identity }
        return board.worldToViewAffine(store.viewport).inverted()
    }

    // MARK: Commit pipeline (one gesture = one undo unit)

    private func commitGesture() {
        guard let board, let store = board.store else { return }
        let viewDrawing = drawing
        let transform = gestureTransform
        let worldDrawing = viewDrawing.transformed(using: transform)

        let retainedCount = min(strokeCountAtGestureStart, viewDrawing.strokes.count)
        let newStrokes = Array(viewDrawing.strokes.dropFirst(retainedCount))
        let clearedDrawing = PKDrawing(strokes: Array(viewDrawing.strokes.prefix(retainedCount)))
        let newStrokePoints: [[CanvasGeometry.Point]] = newStrokes.map { stroke in
            stroke.path.map { point in
                let worldPoint = point.location.applying(transform)
                return CanvasGeometry.Point(x: worldPoint.x, y: worldPoint.y)
            }
        }
        let worldData = worldDrawing.dataRepresentation()
        let clearedData = clearedDrawing.transformed(using: transform)
            .dataRepresentation()
        let pageID = gesturePageID ?? store.selectedPageID
        let revision = gestureRevision
        let wasInking = gestureWasInking
        strokeCountAtGestureStart = viewDrawing.strokes.count
        // A cancelled/provisional stroke must not overwrite real ink with
        // an empty PKDrawing before PencilKit publishes the final model.
        if wasInking && newStrokes.isEmpty { return }
        Task {
            await store.finishInkGesture(
                worldData: worldData,
                clearedData: clearedData,
                newStrokePointsWorld: newStrokePoints,
                wasInking: wasInking, pageID: pageID, expectedRevision: revision)
        }
    }

    private func scheduleGestureEnd() {
        guard isDrawingGesture else { return }
        isEndingGesture = true
        endingTask?.cancel()
        endingTask = Task { @MainActor [weak self] in
            // PKCanvasView can send tool-end before the completed stroke
            // is visible through `drawing`. Keep snapshot synchronization
            // fenced while coalescing its final drawing-change callbacks.
            do { try await Task.sleep(nanoseconds: 16_000_000) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.isDrawingGesture = false
            self.isEndingGesture = false
            self.commitGesture()
            if self.board?.store?.selectedPageID != self.gesturePageID {
                self.syncTransform()
            }
        }
    }
}

extension CanvasInkOverlayView {
    public func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !isSynchronizing else { return }
        // Programmatic snapshot/viewport updates are not user gestures.
        if isEndingGesture { scheduleGestureEnd() }
    }

    public func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        endingTask?.cancel()
        if isEndingGesture { commitGesture() }
        isEndingGesture = false
        isDrawingGesture = true
        gestureWasInking = self.tool is PKInkingTool
        strokeCountAtGestureStart = min(strokeCountAtGestureStart, canvasView.drawing.strokes.count)
        gesturePageID = board?.store?.selectedPageID
        gestureRevision = board?.store?.revision ?? 0
        gestureTransform = viewToWorldAffine
    }

    public func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        guard isDrawingGesture else { return }
        scheduleGestureEnd()
    }

    public func canvasViewDidEndEditing(_ canvasView: PKCanvasView) {
        guard isDrawingGesture else { return }
        scheduleGestureEnd()
    }
}

@MainActor
private final class CanvasInkDrawingDelegate: NSObject, PKCanvasViewDelegate {
    weak var owner: CanvasInkOverlayView?
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        owner?.canvasViewDrawingDidChange(canvasView)
    }
    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        owner?.canvasViewDidBeginUsingTool(canvasView)
    }
    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        owner?.canvasViewDidEndUsingTool(canvasView)
    }
    func canvasViewDidEndEditing(_ canvasView: PKCanvasView) {
        owner?.canvasViewDidEndEditing(canvasView)
    }
}
#endif
