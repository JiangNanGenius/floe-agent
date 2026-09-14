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
    // The anchor is normalized to the visible viewport, independent of paper zoom.
    var onPencilAction: (UIPencilPreferredAction, CGPoint) -> Void = { _, _ in }

    var initialViewport: NoteWorkspaceTabs.Viewport? = nil
    var onViewportChanged: (NoteWorkspaceTabs.Viewport) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = NotesPKCanvasView()
        // Paper/PDF colors are authored pixels, independent of the app theme.
        // PencilKit otherwise adapts dark ink to the surrounding dark interface.
        canvas.overrideUserInterfaceStyle = .light
        canvas.pageSize = CGSize(width: page.width, height: page.height)
        canvas.initialViewport = initialViewport
        canvas.onViewportChanged = { [weak coordinator = context.coordinator] value in
            coordinator?.parent.onViewportChanged(value)
        }
        // The page backdrop owns paper/PDF pixels; PencilKit only draws the ink above it.
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = fingerDrawing ? .anyInput : .pencilOnly
        canvas.maximumSupportedContentVersion = .latest
        canvas.tool = tool
        canvas.delegate = context.coordinator
        canvas.addInteraction(UIPencilInteraction(delegate: context.coordinator))
        canvas.minimumZoomScale = 0.1; canvas.maximumZoomScale = 5
        canvas.contentInsetAdjustmentBehavior = .never
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
    }
    final class Coordinator: NSObject, PKCanvasViewDelegate, UIPencilInteractionDelegate {
        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
            guard squeeze.phase == .ended else { return }
            performPencilAction(UIPencilInteraction.preferredSqueezeAction, interaction: interaction, location: squeeze.hoverPose?.location)
        }
        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
            performPencilAction(UIPencilInteraction.preferredTapAction, interaction: interaction, location: tap.hoverPose?.location)
        }
        private func performPencilAction(_ action: UIPencilPreferredAction, interaction: UIPencilInteraction, location: CGPoint?) {
            guard action != .ignore, action != .runSystemShortcut, let view = interaction.view else { return }
            let point = location.map {
                CGPoint(x: min(0.95, max(0.05, ($0.x - view.bounds.minX) / max(1, view.bounds.width))),
                        y: min(0.95, max(0.05, ($0.y - view.bounds.minY) / max(1, view.bounds.height))))
            } ?? CGPoint(x: 0.5, y: 0.15)
            parent.onPencilAction(action, point)
        }
        var parent: NotePencilView
        weak var backdrop: UIImageView?
        var loadedDrawing: Data?
        var loadedBackground: Data?
        var loadedImages: [UUID: Data] = [:]
        var elements: [NoteElement] = []
        var paper: NotePage.Paper?
        var isApplying = false
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
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            (scrollView as? NotesPKCanvasView)?.rememberPagePosition()
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
    var initialViewport: NoteWorkspaceTabs.Viewport?
    var onViewportChanged: (NoteWorkspaceTabs.Viewport) -> Void = { _ in }
    private var viewportSize = CGSize.zero
    private var pagePosition = CGPoint.zero
    private var updatingViewport = false
    func rememberPagePosition() {
        // UIKit adjusts offsets while rotating. Retain the last position from
        // the old viewport until layout has restored that page-space anchor.
        guard !updatingViewport, bounds.size == viewportSize, zoomScale > 0 else { return }
        pagePosition = CGPoint(x: max(0, contentOffset.x) / zoomScale,
                               y: max(0, contentOffset.y) / zoomScale)
        onViewportChanged(.init(x: pagePosition.x, y: pagePosition.y, zoom: zoomScale))
    }
    override func layoutSubviews() {
        guard !updatingViewport else { super.layoutSubviews(); return }
        let resized = bounds.size != viewportSize && bounds.width > 0 && pageSize.width > 0
        let firstLayout = viewportSize == .zero
        updatingViewport = resized
        super.layoutSubviews()
        if resized {
            if firstLayout {
                if let initialViewport {
                    let safe = NoteWorkspaceTabs.Viewport(x: initialViewport.x, y: initialViewport.y, zoom: initialViewport.zoom)
                    zoomScale = safe.zoom
                    pagePosition = CGPoint(x: safe.x, y: safe.y)
                } else { zoomScale = min(1, bounds.width / pageSize.width) }
            }
            viewportSize = bounds.size
            alignPageBackdrop()
            let maximumX = max(0, pageSize.width * zoomScale - bounds.width)
            let maximumY = max(0, pageSize.height * zoomScale - bounds.height)
            contentOffset = CGPoint(x: contentInset.left > 0 ? -contentInset.left : min(maximumX, pagePosition.x * zoomScale),
                                    y: contentInset.top > 0 ? -contentInset.top : min(maximumY, pagePosition.y * zoomScale))
        }
        alignPageBackdrop()
        updatingViewport = false
        rememberPagePosition()
    }
    func alignPageBackdrop() {
        pageBackdrop?.frame = CGRect(x: 0, y: 0, width: pageSize.width * zoomScale, height: pageSize.height * zoomScale)
        // Center undersized paper using scroll insets, keeping the paper and
        // PencilKit drawing at the same unshifted page-space origin. Selection
        // coordinates therefore remain valid through zoom and rotation.
        let horizontal = max(0, (bounds.width - pageSize.width * zoomScale) / 2)
        let vertical = max(0, (bounds.height - pageSize.height * zoomScale) / 2)
        let insets = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
        if contentInset != insets { contentInset = insets }
        var offset = contentOffset
        if horizontal > 0 { offset.x = -horizontal }
        if vertical > 0 { offset.y = -vertical }
        if contentOffset != offset { contentOffset = offset }
    }
}
#endif
