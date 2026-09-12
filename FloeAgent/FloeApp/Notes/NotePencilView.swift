// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import PencilKit
import FloeNotes

struct NotePencilView: UIViewRepresentable {
    let page: NotePage
    let drawing: Data?
    let background: Data?
    let fingerDrawing: Bool
    let tool: PKTool
    let onDrawing: (Data) -> Void
    var deleteSelectionRequest: UUID? = nil
    var onSelectionCount: (Int) -> Void = { _ in }
    var captureSelectionRequest: UUID? = nil
    var regionSelection = false
    var onSelectionCapture: (CGRect, Data) -> Void = { _, _ in }
    var elementImages: [UUID: Data] = [:]

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = NotesPKCanvasView()
        canvas.pageSize = CGSize(width: page.width, height: page.height)
        canvas.backgroundColor = .white
        canvas.isOpaque = true
        canvas.drawingPolicy = fingerDrawing ? .anyInput : .pencilOnly
        canvas.tool = tool
        canvas.delegate = context.coordinator
        canvas.minimumZoomScale = 0.1; canvas.maximumZoomScale = 5
        canvas.contentSize = CGSize(width: page.width, height: page.height)
        canvas.accessibilityLabel = "手记书写页面"
        canvas.accessibilityIdentifier = "notes.pencil.page"
        let backdrop = UIImageView()
        backdrop.contentMode = .scaleToFill
        backdrop.isUserInteractionEnabled = false
        backdrop.frame = CGRect(x: 0, y: 0, width: page.width, height: page.height)
        canvas.insertSubview(backdrop, at: 0)
        context.coordinator.backdrop = backdrop
        canvas.pageBackdrop = backdrop
        let selection = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.selectRegion(_:)))
        selection.maximumNumberOfTouches = 1
        selection.isEnabled = regionSelection
        canvas.addGestureRecognizer(selection)
        context.coordinator.regionGesture = selection
        return canvas
    }
    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.regionGesture?.isEnabled = regionSelection
        canvas.drawingGestureRecognizer.isEnabled = !regionSelection
        canvas.drawingPolicy = fingerDrawing ? .anyInput : .pencilOnly
        canvas.tool = tool
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            if let request = deleteSelectionRequest, request != coordinator.handledDeleteRequest {
                coordinator.handledDeleteRequest = request
                // Defer delegate-driven SwiftUI state changes until this view update finishes.
                DispatchQueue.main.async { [weak canvas, weak coordinator] in
                    guard let canvas, let coordinator else { return }
                    let selected = canvas.selection
                    guard !selected.isEmpty else { return }
                    canvas.drawing = PKDrawing(strokes: canvas.drawing.strokes.filter { !selected.contains($0.id) })
                    canvas.selection = []
                    coordinator.canvasViewDrawingDidChange(canvas)
                    coordinator.parent.onSelectionCount(0)
                }
            }
        }
        if #available(iOS 27.0, *), let request = captureSelectionRequest, request != coordinator.handledCaptureRequest {
            coordinator.handledCaptureRequest = request
            DispatchQueue.main.async { [weak canvas, weak coordinator] in
                guard let canvas, let coordinator else { return }
                let selected = canvas.drawing.strokes.filter { canvas.selection.contains($0.id) }
                guard !selected.isEmpty else { return }
                let pageBounds = CGRect(x: 0, y: 0, width: coordinator.parent.page.width, height: coordinator.parent.page.height)
                let bounds = selected.reduce(CGRect.null) { $0.union($1.renderBounds) }.insetBy(dx: -18, dy: -18).intersection(pageBounds)
                guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return }
                let format = UIGraphicsImageRendererFormat()
                format.scale = min(2, 2048 / max(bounds.width, bounds.height))
                let image = UIGraphicsImageRenderer(size: bounds.size, format: format).image { context in
                    context.cgContext.translateBy(x: -bounds.minX, y: -bounds.minY)
                    UIColor.white.setFill(); context.cgContext.fill(pageBounds)
                    coordinator.backdrop?.image?.draw(in: pageBounds)
                    canvas.drawing.image(from: bounds, scale: format.scale).draw(in: bounds)
                }
                if let data = image.pngData() { coordinator.parent.onSelectionCapture(bounds, data) }
            }
        }
        #endif
        if coordinator.loadedDrawing != drawing, !coordinator.isUsingTool {
            coordinator.isApplying = true
            canvas.drawing = drawing.flatMap { try? PKDrawing(data: $0) } ?? PKDrawing()
            coordinator.loadedDrawing = drawing
            coordinator.isApplying = false
        }
        if coordinator.loadedBackground != background || coordinator.elements != page.elements || coordinator.paper != page.paper || coordinator.loadedImages != elementImages {
            coordinator.loadedImages = elementImages
            coordinator.loadedBackground = background; coordinator.elements = page.elements; coordinator.paper = page.paper
            let size = CGSize(width: page.width, height: page.height)
            let format = UIGraphicsImageRendererFormat(); format.scale = min(2, 2048 / max(size.width, size.height))
            coordinator.backdrop?.image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                NotePageRenderer.draw(page, background: background.flatMap { UIImage(data: $0) }, images: elementImages.compactMapValues { UIImage(data: $0) })
            }
        }
        if !coordinator.didFit, canvas.bounds.width > 0 {
            coordinator.didFit = true
            canvas.zoomScale = min(1, canvas.bounds.width / page.width)
        }
    }
    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: NotePencilView
        weak var backdrop: UIImageView?
        var loadedDrawing: Data?
        var loadedBackground: Data?
        var loadedImages: [UUID: Data] = [:]
        var elements: [NoteElement] = []
        var paper: NotePage.Paper?
        var isApplying = false
        var didFit = false
        var handledDeleteRequest: UUID?
        var handledCaptureRequest: UUID?
        var isUsingTool = false
        var pendingDrawing: Data?
        weak var regionGesture: UIPanGestureRecognizer?
        var selectionOrigin: CGPoint?
        let selectionLayer = CAShapeLayer()
        @objc func selectRegion(_ gesture: UIPanGestureRecognizer) {
            guard let canvas = gesture.view as? PKCanvasView else { return }
            let position = gesture.location(in: canvas)
            let point = CGPoint(x: position.x / canvas.zoomScale, y: position.y / canvas.zoomScale)
            if gesture.state == .began {
                selectionOrigin = point
                selectionLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.12).cgColor
                selectionLayer.strokeColor = UIColor.systemBlue.cgColor
                selectionLayer.lineWidth = 2
                canvas.layer.addSublayer(selectionLayer)
            }
            guard let origin = selectionOrigin else { return }
            let bounds = CGRect(x: min(origin.x, point.x), y: min(origin.y, point.y),
                                width: abs(origin.x - point.x), height: abs(origin.y - point.y))
                .intersection(CGRect(x: 0, y: 0, width: parent.page.width, height: parent.page.height))
            selectionLayer.path = UIBezierPath(rect: bounds.applying(CGAffineTransform(scaleX: canvas.zoomScale, y: canvas.zoomScale))).cgPath
            if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
                selectionLayer.removeFromSuperlayer(); selectionOrigin = nil
                guard gesture.state == .ended, !bounds.isNull, bounds.width >= 8, bounds.height >= 8 else { return }
                let format = UIGraphicsImageRendererFormat(); format.scale = min(2, 2048 / max(bounds.width, bounds.height))
                let image = UIGraphicsImageRenderer(size: bounds.size, format: format).image { context in
                    context.cgContext.translateBy(x: -bounds.minX, y: -bounds.minY)
                    backdrop?.image?.draw(in: CGRect(x: 0, y: 0, width: parent.page.width, height: parent.page.height))
                    canvas.drawing.image(from: bounds, scale: format.scale).draw(in: bounds)
                }
                if let data = image.pngData() { parent.onSelectionCapture(bounds, data) }
            }
        }
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? NotesPKCanvasView)?.alignPageBackdrop()
        }
        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) { isUsingTool = true }
        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            isUsingTool = false
            if let data = pendingDrawing { pendingDrawing = nil; parent.onDrawing(data) }
        }
        func canvasViewSelectionDidChange(_ canvasView: PKCanvasView) {
            #if compiler(>=6.4)
            if #available(iOS 27.0, *) {
                let count = canvasView.selection.count
                DispatchQueue.main.async { [weak self] in self?.parent.onSelectionCount(count) }
            }
            #endif
        }
        init(parent: NotePencilView) { self.parent = parent }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !isApplying else { return }
            let data = canvasView.drawing.dataRepresentation()
            guard data != loadedDrawing else { return }
            loadedDrawing = data
            if isUsingTool { pendingDrawing = data }
            else { parent.onDrawing(data) }
        }
    }
}
/// Background subviews of a scroll view do not automatically participate in PencilKit's zoom view.
private final class NotesPKCanvasView: PKCanvasView {
    var pageSize = CGSize.zero
    weak var pageBackdrop: UIImageView?
    private var fitted = false
    override func layoutSubviews() {
        super.layoutSubviews()
        if !fitted, bounds.width > 0, pageSize.width > 0 {
            fitted = true
            zoomScale = min(1, bounds.width / pageSize.width)
        }
        alignPageBackdrop()
    }
    func alignPageBackdrop() {
        pageBackdrop?.frame = CGRect(x: 0, y: 0, width: pageSize.width * zoomScale, height: pageSize.height * zoomScale)
    }
}
#endif
