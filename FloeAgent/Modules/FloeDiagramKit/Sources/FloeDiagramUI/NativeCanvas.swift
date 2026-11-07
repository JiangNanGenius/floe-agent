// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import UIKit
import PencilKit
import FloeDiagramCore
import FloeDiagramLayout
import FloeDiagramExchange

/// `pencilOnly` would also reject mouse/trackpad drawing. Filter physical
/// sources on the existing PencilKit recognizer instead, leaving pan/select alone.
enum DiagramDrawingInputPolicy {
    static let preferenceKey = "diagram.fingerDrawing.enabled"
    @MainActor static func apply(to canvas: PKCanvasView, fingerDrawing: Bool) {
        if canvas.drawingPolicy != .anyInput { canvas.drawingPolicy = .anyInput }
        var types = [UITouch.TouchType.pencil, .indirect, .indirectPointer]
        if fingerDrawing { types.append(.direct) }
        let allowed = types.map { NSNumber(value: $0.rawValue) }
        if canvas.drawingGestureRecognizer.allowedTouchTypes != allowed {
            canvas.drawingGestureRecognizer.allowedTouchTypes = allowed
        }
    }
}

struct DiagramCanvas: UIViewRepresentable {
    let model: DiagramEditorModel
    var fingerDrawing = false
    @Environment(\.colorScheme) private var colorScheme
    func makeUIView(context: Context) -> DiagramCanvasView {
        let view = DiagramCanvasView(model: model)
        DiagramDrawingInputPolicy.apply(to: view.inkView, fingerDrawing: fingerDrawing)
        return view
    }
    func updateUIView(_ view: DiagramCanvasView, context: Context) {
        // Explicit Observation reads make native drawing updates follow SwiftUI's dependency tracking.
        _ = model.scene?.generation; _ = model.selection; _ = model.selectedEdge; _ = model.tool
        _ = model.fitRequest; _ = model.centerRequest; _ = model.zoomRequest; _ = model.assetBytes; _ = model.editingElementID
        DiagramDrawingInputPolicy.apply(to: view.inkView, fingerDrawing: fingerDrawing)
        view.synchronize()
        view.renderer.appearance = colorScheme == .dark ? .dark : .light
        view.setNeedsDisplay()
    }
    static func dismantleUIView(_ view: DiagramCanvasView, coordinator: ()) { view.finishEditing(); view.flushInk(); view.toolPicker.setVisible(false, forFirstResponder: view.inkView); view.toolPicker.removeObserver(view.inkView) }
}

@MainActor final class DiagramCanvasView: UIView, UIGestureRecognizerDelegate, UITextViewDelegate, PKCanvasViewDelegate, UIContextMenuInteractionDelegate {
    let model: DiagramEditorModel
    let renderer = DiagramNativeRenderer()
    let inkView = DiagramInkCanvasView()
    let toolPicker = PKToolPicker()
    private var scene: DiagramEditorScene?
    private var preview: DiagramLayoutResult?
    private var cameraCenter = DiagramPoint(x: 0, y: 0)
    private var scale: Double = 1
    private var lastFit = -1
    private var lastGeneration = -1
    private var initialFit = false
    private var loadedImages: Set<UUID> = []
    private var titleInput: UITextView?
    private var originalTitle = ""
    private var editedID: UUID?
    private var suppressInk = false
    private var lastInk: Data?
    private var inkSaveTask: Task<Void, Never>?
    private var pendingWorldInk: Data?
    private var startPoint = DiagramPoint(x: 0, y: 0)
    private var startCenter = DiagramPoint(x: 0, y: 0)
    private var drag = Drag.none
    private var hoverParent: UUID?
    private var connectionStart: UUID?
    private var marquee: DiagramRect?
    private var temporaryLine: (DiagramPoint, DiagramPoint)?
    private var resizeOriginal: DiagramRect?
    private enum Drag { case none, camera, nodes(Set<UUID>), resize(UUID), connect(UUID, DiagramAnchorSide), endpoint(Bool), waypoint(Int), label, marquee }

    init(model: DiagramEditorModel) {
        self.model = model; super.init(frame: .zero)
        isOpaque = true; backgroundColor = .systemBackground; clipsToBounds = true; accessibilityIdentifier = "diagram.canvas"
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:))); double.numberOfTapsRequired = 2
        tap.require(toFail: double)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:))); pan.maximumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        let long = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:))); long.minimumPressDuration = 0.45
        for gesture in [tap, double, pan, pinch, long] { gesture.delegate = self; addGestureRecognizer(gesture) }
        addInteraction(UIContextMenuInteraction(delegate: self)); addInteraction(UIPointerInteraction(delegate: nil))
        inkView.backgroundColor = .clear; inkView.isOpaque = false; inkView.isScrollEnabled = false
        DiagramDrawingInputPolicy.apply(to: inkView, fingerDrawing: false)
        inkView.tool = PKInkingTool(.pen, color: .label, width: 2.5); inkView.delegate = self
        inkView.accessibilityLabel = DL("手写批注", "Ink annotation"); addSubview(inkView); inkView.isHidden = true
        toolPicker.addObserver(inkView)
    }
    required init?(coder: NSCoder) { nil }
    override var canBecomeFirstResponder: Bool { true }
    private var cameraTransform: CGAffineTransform { CGAffineTransform(translationX: bounds.midX, y: bounds.midY).scaledBy(x: scale, y: scale).translatedBy(x: -cameraCenter.x, y: -cameraCenter.y) }
    private func world(_ point: CGPoint) -> DiagramPoint { .init(x: cameraCenter.x+(point.x-bounds.midX)/scale, y: cameraCenter.y+(point.y-bounds.midY)/scale) }
    private func screen(_ point: DiagramPoint) -> CGPoint { point.cgPoint.applying(cameraTransform) }
    private var visibleRect: DiagramRect { .init(x: cameraCenter.x-bounds.width/(2*scale), y: cameraCenter.y-bounds.height/(2*scale), width: bounds.width/scale, height: bounds.height/scale) }
    override func layoutSubviews() {
        super.layoutSubviews(); inkView.frame = bounds
        if !initialFit, scene != nil, bounds.width > 0 { fit(); initialFit = true; lastFit = model.fitRequest }
        positionInput(); updateAccessibility(); setNeedsDisplay()
    }
    func synchronize() {
        guard !model.isClosed else { return }
        let next = model.scene
        if next?.generation != lastGeneration {
            if editedID != nil, next?.page.id != scene?.page.id { finishEditing() }
            scene = next; preview = nil; lastGeneration = next?.generation ?? -1
        }
        renderer.appearance = traitCollection.userInterfaceStyle == .dark ? .dark : .light
        if model.fitRequest != lastFit, bounds.width > 0, scene != nil { lastFit = model.fitRequest; fit() }
        if let id = model.centerRequest, centerOn(id) {
            DispatchQueue.main.async { [weak self] in if self?.model.centerRequest == id { self?.model.centerRequest = nil } }
        }
        if let requested = model.zoomRequest { let value = min(4, max(0.04, requested)); scale = value; DispatchQueue.main.async { [weak self] in self?.model.zoomRequest = nil; self?.model.zoom = value }; updateInkTransform() }
        if let id = model.editingElementID, id != editedID { startEditing(id) }
        let inkActive = model.tool == .pencil
        if inkView.isHidden == inkActive {
            flushInk(); inkView.isHidden = !inkActive; updateInkTransform()
            toolPicker.setVisible(inkActive, forFirstResponder: inkView)
            if inkActive { inkView.becomeFirstResponder() } else { inkView.resignFirstResponder(); becomeFirstResponder() }
        }
        if lastInk != scene?.page.ink, pendingWorldInk == nil { lastInk = scene?.page.ink; updateInkTransform() }
        updateAccessibility(); setNeedsDisplay()
    }
    private func fit() {
        guard let rect = scene?.layout.bounds.insetBy(-64), bounds.width > 0 else { return }
        cameraCenter = rect.center; scale = min(1.15, max(0.04, min(bounds.width/max(1, rect.width), bounds.height/max(1, rect.height))))
        publishZoom(); updateInkTransform(); positionInput(); setNeedsDisplay()
    }
    @discardableResult private func centerOn(_ id: UUID) -> Bool {
        guard let rect = scene?.layout.frames[id] else { return false }; cameraCenter = rect.center; scale = max(0.75, scale)
        publishZoom(); updateInkTransform(); positionInput(); setNeedsDisplay()
        return true
    }
    private func publishZoom() { let value = scale; DispatchQueue.main.async { [weak self] in guard let self, self.model.zoom != value else { return }; self.model.zoom = value } }
    private func prepareVisibleImages() {
        guard scale >= 0.22 else { return }
        let visibleIDs = scene?.layout.spatialIndex.query(visibleRect.insetBy(-120)) ?? []
        var needed: [UUID:Int] = [:]
        for node in scene?.page.elements ?? [] where visibleIDs.contains(node.id) {
            let width = scene?.layout.frames[node.id]?.width ?? 220
            let pixels = Int(min(1_024,max(128,(width-28)*scale*traitCollection.displayScale)))
            for block in node.content { if case .image(let id,_) = block { needed[id] = max(needed[id] ?? 0,pixels) } }
        }
        var missing: Set<UUID> = []
        for asset in model.document.assets where needed[asset.id] != nil && asset.mediaType.hasPrefix("image/") {
            let pixels = needed[asset.id]!
            if renderer.hasCachedAsset(asset,minimumPixelSize: pixels) { continue }
            if let bytes = model.assetBytes[asset.id], (try? renderer.cacheAsset(asset, data: bytes,maximumPixelSize: pixels)) != nil { continue }
            missing.insert(asset.id)
        }
        model.requestAssets(missing)
    }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), var scene else { return }
        let layout = preview ?? scene.layout
        if !inkView.isHidden { scene.page.ink = nil }
        context.saveGState(); context.concatenate(cameraTransform)
        renderer.draw(document: scene.document, page: scene.page, layout: layout, in: context, visibleRect: visibleRect, zoom: scale,
                      selection: model.selection, selectedEdge: model.selectedEdge, editingElement: editedID)
        context.setStrokeColor(DiagramPalette.color("accent", appearance: renderer.appearance)); context.setLineWidth(1.5/scale)
        if let hoverParent, let f = layout.frames[hoverParent] { context.stroke(f.insetBy(-5).cgRect) }
        if let marquee { context.setFillColor(DiagramPalette.color("soft", appearance: renderer.appearance)); context.setAlpha(0.5); context.fill(marquee.cgRect); context.setAlpha(1); context.stroke(marquee.cgRect) }
        if let temporaryLine { context.setLineDash(phase: 0, lengths: [5/scale,5/scale]); context.move(to: temporaryLine.0.cgPoint); context.addLine(to: temporaryLine.1.cgPoint); context.strokePath(); context.setLineDash(phase: 0, lengths: []) }
        if model.selection.count == 1, let id = model.selection.first, let frame = layout.frames[id], model.tool != .pencil, scale >= 0.65 {
            context.setFillColor(DiagramPalette.color("surface", appearance: renderer.appearance))
            for side in [DiagramAnchorSide.left, .right, .top, .bottom] {
                let point = DiagramRouter.anchor(frame, side: side), r = 4/scale
                context.addEllipse(in: CGRect(x: point.x-r, y: point.y-r, width: 2*r, height: 2*r)); context.drawPath(using: .fillStroke)
            }
            let r = 5/scale; context.addRect(CGRect(x: frame.maxX-r, y: frame.maxY-r, width: 2*r, height: 2*r)); context.drawPath(using: .fillStroke)
        }
        if let edge = model.selectedConnection {
            context.setFillColor(DiagramPalette.color("surface", appearance: renderer.appearance))
            for point in edge.waypoints { let r = 4/scale; context.addEllipse(in: CGRect(x: point.x-r, y: point.y-r, width: 2*r, height: 2*r)); context.drawPath(using: .fillStroke) }
        }
        context.restoreGState()
    }
    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard let scene else { return }; let point = world(gesture.location(in: self))
        if titleInput != nil { finishEditing(); return }; becomeFirstResponder()
        let hit = scene.layout.hitElement(at: point, page: scene.page)
        if model.tool == .connect {
            if let from = connectionStart, let hit { model.connect(from, to: hit); connectionStart = nil; temporaryLine = nil }
            else { connectionStart = hit; model.select(hit) }; setNeedsDisplay(); return
        }
        if let hit { model.select(hit) }
        else if let edge = scene.layout.hitEdge(at: point, zoom: scale) { model.selectEdge(edge) }
        else { model.select(nil); model.selectedEdge = nil }
        setNeedsDisplay(); updateAccessibility()
    }
    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        guard let scene else { return }; let point = world(gesture.location(in: self))
        if let id = scene.layout.hitElement(at: point, page: scene.page) {
            if model.mode == .board || model.mode == .gantt { model.select(id); model.showInspector = true }
            else { model.select(id); startEditing(id) }
        } else if model.selectedConnection != nil { model.addWaypoint(point) }
        else if model.mode == .board || model.mode == .gantt { model.addTask() }
        else { let id = model.addElement(kind: .floatingTopic, child: false, at: point); Task { await model.waitForIdle(); model.editingElementID = id } }
    }
    private func near(_ a: DiagramPoint, _ b: DiagramPoint, tolerance: Double = 17) -> Bool { hypot(a.x-b.x, a.y-b.y)*scale < tolerance }
    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        guard let scene else { return }; let point = world(gesture.location(in: self))
        switch gesture.state {
        case .began:
            finishEditing(); startPoint = point; startCenter = cameraCenter; hoverParent = nil; resizeOriginal = nil
            if gesture.numberOfTouches > 1 || model.tool == .pan { drag = .camera; return }
            if let edgeID = model.selectedEdge, let geometry = scene.layout.edges.first(where: { $0.id == edgeID }), model.selectedConnection != nil {
                if near(point, geometry.start) { drag = .endpoint(true); return }
                if near(point, geometry.end) { drag = .endpoint(false); return }
                if let at = model.selectedConnection?.waypoints.firstIndex(where: { near(point, $0) }) { drag = .waypoint(at); return }
                if near(point, geometry.labelPoint, tolerance: 30) { drag = .label; return }
            }
            if model.selection.count == 1, let id = model.selection.first, let f = scene.layout.frames[id], scale >= 0.65 {
                if near(point, .init(x: f.maxX, y: f.maxY)) { drag = .resize(id); resizeOriginal = f; return }
                for side in [DiagramAnchorSide.left, .right, .top, .bottom] where near(point, DiagramRouter.anchor(f, side: side)) { drag = .connect(id, side); return }
            }
            if let hit = scene.layout.hitElement(at: point, page: scene.page) {
                if (model.mode == .board || model.mode == .gantt) && scene.page.elements.first(where: { $0.id == hit })?.taskID == nil { drag = .camera; return }
                if model.tool == .connect { drag = .connect(hit, .automatic); return }
                if !model.selection.contains(hit) { model.select(hit) }
                let index = DiagramPageIndex(scene.page)
                guard index.descendants(of: model.selection).isDisjoint(with: index.effectivelyLockedIDs) else { drag = .none; return }
                drag = .nodes(model.selection)
            } else { drag = .camera }
        case .changed:
            let translation = gesture.translation(in: self), delta = DiagramPoint(x: translation.x/scale, y: translation.y/scale)
            switch drag {
            case .camera:
                cameraCenter = startCenter - delta; updateInkTransform()
            case .nodes(let ids):
                let moved = DiagramPageIndex(scene.page).descendants(of: ids); preview = translated(scene.layout, ids: moved, delta: delta)
                if ids.count == 1, model.mode == .canvas, let target = scene.layout.hitElement(at: point, page: scene.page), !moved.contains(target), scene.page.elements.first(where: { $0.id == target })?.kind.isTopic == true { hoverParent = target } else { hoverParent = nil }
            case .resize(let id):
                if var frame = resizeOriginal { frame.width = max(40, frame.width+delta.x); frame.height = max(32, frame.height+delta.y); var frames = scene.layout.frames; frames[id] = frame; preview = .init(frames: frames, edges: scene.layout.edges, visibleRepresentatives: scene.layout.visibleRepresentatives) }
            case .connect(let id, _): if let frame = scene.layout.frames[id] { temporaryLine = (frame.center, point) }
            case .endpoint(let start):
                if let g = scene.layout.edges.first(where: { $0.id == model.selectedEdge }) { temporaryLine = (start ? g.end : g.start, point) }
            case .waypoint, .label: temporaryLine = (startPoint, point)
            default: break
            }; setNeedsDisplay()
        case .ended:
            let translation = gesture.translation(in: self), delta = DiagramPoint(x: translation.x/scale, y: translation.y/scale)
            switch drag {
            case .nodes(let ids):
                if model.mode == .board || model.mode == .gantt { model.movePlanTasks(Set(scene.page.elements.filter { ids.contains($0.id) }.compactMap(\.taskID)),delta: delta) }
                else { model.moveSelection(ids, delta: delta, reparentTo: hoverParent) }
            case .resize(let id):
                if let task = scene.page.elements.first(where: { $0.id == id })?.taskID, model.mode == .gantt { model.movePlanTask(task, delta: delta, resizeEnd: true) }
                else if let frame = preview?.frames[id] { model.resize(id, to: frame) }
            case .connect(let id, let side): if let to = scene.layout.hitElement(at: point, page: scene.page) { model.connect(id, to: to, source: side, target: nearestAnchor(point, nodeID: to)) }
            case .endpoint(let start): if let target = scene.layout.hitElement(at: point, page: scene.page) { let side = nearestAnchor(point, nodeID: target); model.editConnection { if start { $0.from = target; $0.sourceAnchor = side } else { $0.to = target; $0.targetAnchor = side } } }
            case .waypoint(let at): model.editConnection { if $0.waypoints.indices.contains(at) { $0.waypoints[at] = point } }
            case .label:
                if let edge = scene.layout.edges.first(where: { $0.id == model.selectedEdge }) {
                    let closest = (0...100).min { distance(edge.point(at: Double($0)/100), point) < distance(edge.point(at: Double($1)/100), point) } ?? 50
                    model.editConnection { $0.labelPosition = Double(closest)/100 }
                }
            default: break
            }
            resetDrag(); positionInput(); updateAccessibility()
        case .cancelled, .failed: resetDrag()
        default: break
        }
    }
    private func distance(_ a: DiagramPoint, _ b: DiagramPoint) -> Double { hypot(a.x-b.x,a.y-b.y) }
    private func nearestAnchor(_ point: DiagramPoint, nodeID: UUID) -> DiagramAnchorSide {
        guard let frame = scene?.layout.frames[nodeID] else { return .automatic }
        return [DiagramAnchorSide.left,.right,.top,.bottom].min { distance(point, DiagramRouter.anchor(frame, side: $0)) < distance(point, DiagramRouter.anchor(frame, side: $1)) } ?? .automatic
    }
    private func translated(_ layout: DiagramLayoutResult, ids: Set<UUID>, delta: DiagramPoint) -> DiagramLayoutResult {
        var frames = layout.frames
        for id in ids { if let f = frames[id] { frames[id] = f.translated(by: delta) } }
        let edges = layout.edges.map { old in
            var edge = old; let a = ids.contains(edge.from), b = ids.contains(edge.to)
            guard a || b else { return edge }
            if a && b {
                edge.start = edge.start+delta
                edge.segments = edge.segments.map { switch $0 { case .line(let p): .line(p+delta); case .cubic(let x, let y, let p): .cubic(control1: x+delta,control2: y+delta,end: p+delta) } }
            } else {
                let start = edge.start+(a ? delta : .init(x: 0,y: 0)), end = edge.end+(b ? delta : .init(x: 0,y: 0))
                edge.start = start; let mid = (start.x+end.x)/2
                edge.segments = [.cubic(control1: .init(x: mid,y: start.y),control2: .init(x: mid,y: end.y),end: end)]
            }; return edge
        }
        return .init(frames: frames, edges: edges, visibleRepresentatives: layout.visibleRepresentatives)
    }
    private func resetDrag() { drag = .none; preview = nil; hoverParent = nil; temporaryLine = nil; setNeedsDisplay() }
    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        if gesture.state == .began { finishEditing() }
        let anchor = gesture.location(in: self), before = world(anchor)
        scale = min(4, max(0.04, scale*gesture.scale)); gesture.scale = 1
        let after = world(anchor); cameraCenter = cameraCenter+(before-after); model.zoom = scale
        updateInkTransform(); setNeedsDisplay()
        if gesture.state == .ended { updateAccessibility() }
    }
    @objc private func longPressed(_ gesture: UILongPressGestureRecognizer) {
        guard let scene else { return }; let point = world(gesture.location(in: self))
        switch gesture.state {
        case .began: guard scene.layout.hitElement(at: point, page: scene.page) == nil else { return }; startPoint = point; drag = .marquee
        case .changed: if case .marquee = drag { marquee = .init(x: min(startPoint.x, point.x), y: min(startPoint.y,point.y),width: abs(point.x-startPoint.x),height: abs(point.y-startPoint.y)); setNeedsDisplay() }
        case .ended: if case .marquee = drag, let marquee { model.selection = scene.layout.spatialIndex.query(marquee).filter { scene.layout.frames[$0]?.intersects(marquee) == true }; model.selectedEdge = nil }; marquee = nil; resetDrag()
        case .failed, .cancelled: marquee = nil; resetDrag()
        default: break
        }
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { gestureRecognizer is UIPinchGestureRecognizer || other is UIPinchGestureRecognizer }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool { !model.isLayingOut && model.tool != .pencil && (titleInput == nil || touch.view !== titleInput) }
    func startEditing(_ id: UUID) {
        guard let scene, let node = scene.page.elements.first(where: { $0.id == id }), !DiagramPageIndex(scene.page).isEffectivelyLocked(id), model.mode == .canvas else { return }
        finishEditing(); if scale < 0.6 { centerOn(id) }
        editedID = id; model.editingElementID = id; originalTitle = node.title
        let input = UITextView(); input.text = node.title; input.font = .systemFont(ofSize: node.style.fontSize*scale, weight: node.style.bold ? .semibold : .regular)
        input.textColor = .label; input.backgroundColor = .secondarySystemBackground; input.layer.cornerRadius = 8; input.layer.borderWidth = 1.5; input.layer.borderColor = tintColor.cgColor
        input.delegate = self; input.isScrollEnabled = true; input.accessibilityIdentifier = "diagram.titleEditor"
        titleInput = input; addSubview(input); positionInput(); input.becomeFirstResponder(); setNeedsDisplay()
    }
    private func positionInput() {
        guard let id = editedID, let f = scene?.layout.frames[id], let titleInput else { return }
        let rect = f.cgRect.applying(cameraTransform)
        titleInput.frame = CGRect(x: max(4,min(rect.minX,bounds.width-120)),y: max(4,min(rect.minY,bounds.height-70)),width: max(120,min(rect.width,bounds.width-8)),height: max(60,min(160,rect.height)))
    }
    func finishEditing() {
        guard let input = titleInput, let id = editedID else { return }
        input.unmarkText()
        let text = String(input.text.prefix(20_000)); titleInput = nil; editedID = nil; model.editingElementID = nil
        input.delegate = nil; input.resignFirstResponder(); input.removeFromSuperview()
        if text != originalTitle { model.editElement(id, title: DL("编辑标题", "Edit title")) { $0.title = text } }; setNeedsDisplay()
    }
    func textViewDidEndEditing(_ textView: UITextView) { finishEditing() }
    private func updateInkTransform() {
        guard !inkView.isHidden, pendingWorldInk == nil else { return }
        suppressInk = true; defer { suppressInk = false }
        inkView.drawing = ((try? PKDrawing(data: scene?.page.ink ?? Data())) ?? PKDrawing()).transformed(using: cameraTransform)
    }
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !suppressInk, !inkView.isHidden else { return }
        pendingWorldInk = canvasView.drawing.transformed(using: cameraTransform.inverted()).dataRepresentation()
        if let data = pendingWorldInk { model.scheduleInk(data, pageID: model.pageID) }
    }
    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) { flushInk() }
    func flushInk() { inkSaveTask?.cancel(); if let data = pendingWorldInk { pendingWorldInk = nil; lastInk = data; model.flushPendingInk() } }
    override var keyCommands: [UIKeyCommand]? {
        guard titleInput == nil else { return nil }
        return [UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(addChild)), UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(addSibling)),
                UIKeyCommand(input: UIKeyCommand.inputDelete, modifierFlags: [], action: #selector(deleteItems)),
                UIKeyCommand(input: "z", modifierFlags: .command, action: #selector(undoEdit)), UIKeyCommand(input: "z", modifierFlags: [.command,.shift], action: #selector(redoEdit)),
                UIKeyCommand(input: "c", modifierFlags: .command, action: #selector(copyItems)), UIKeyCommand(input: "x", modifierFlags: .command, action: #selector(cutItems)), UIKeyCommand(input: "v", modifierFlags: .command, action: #selector(pasteItems)),
                UIKeyCommand(input: "a", modifierFlags: .command, action: #selector(selectAll)), UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escape))]
    }
    @objc private func addChild() { if model.mode == .board || model.mode == .gantt { model.addTask() } else { model.addElement() } }
    @objc private func addSibling() { if model.mode == .board || model.mode == .gantt { model.addTask() } else { model.addSibling() } }
    @objc private func deleteItems() { model.removeSelection() }
    @objc private func undoEdit() { model.undo() }
    @objc private func redoEdit() { model.undo(redo: true) }
    @objc private func copyItems() { model.copySelection() }
    @objc private func cutItems() { model.copySelection(cut: true) }
    @objc private func pasteItems() { model.pasteSelection() }
    @objc override func selectAll(_ sender: Any?) {
        model.selectedTaskID = nil
        model.selection = model.mode == .board || model.mode == .gantt ? Set(scene?.page.elements.filter { $0.taskID != nil && $0.metadata["taskLabel"] != "true" }.map(\.id) ?? []) : Set(scene?.layout.frames.keys.map { $0 } ?? [])
    }
    @objc private func escape() { finishEditing(); model.select(nil); model.tool = .select; connectionStart = nil; temporaryLine = nil; model.focus(nil); setNeedsDisplay() }
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let scene else { return nil }; let id = scene.layout.hitElement(at: world(location), page: scene.page)
        if let id { model.select(id) }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return UIMenu() }
            if self.model.mode == .board || self.model.mode == .gantt {
                let tasks = self.model.selectedTaskIDs
                return UIMenu(children: DiagramTaskStatus.allCases.map { status in
                    UIAction(title: status.title,image: UIImage(systemName: status.icon)) { _ in self.model.perform(DL("更新任务", "Update tasks")) { doc in doc.tasks.filter { tasks.contains($0.id) }.map { old in var t = old; t.status = status; return .upsertTask(t) } } }
                } + [UIAction(title: DL("删除任务", "Delete tasks"),image: UIImage(systemName: "trash"),attributes: .destructive) { _ in self.model.removeSelection() }])
            }
            var actions: [UIMenuElement] = []
            if let id {
                actions += [UIAction(title: DL("编辑", "Edit"), image: UIImage(systemName: "pencil")) { _ in self.startEditing(id) },
                            UIAction(title: DL("折叠 / 展开", "Fold / unfold"), image: UIImage(systemName: "arrow.up.left.and.arrow.down.right")) { _ in self.model.toggleCollapse(id) },
                            UIAction(title: DL("复制", "Copy"), image: UIImage(systemName: "doc.on.doc")) { _ in self.model.copySelection() },
                            UIAction(title: DL("锁定", "Lock"), image: UIImage(systemName: "lock")) { _ in self.model.lockSelection(true) },
                            UIAction(title: DL("删除", "Delete"), image: UIImage(systemName: "trash"), attributes: .destructive) { _ in self.model.removeSelection() }]
            }
            actions.append(UIAction(title: DL("粘贴", "Paste"), image: UIImage(systemName: "doc.on.clipboard")) { _ in self.model.pasteSelection(at: self.world(location)) })
            return UIMenu(children: actions)
        }
    }
    private func updateAccessibility() {
        prepareVisibleImages()
        guard let scene else { accessibilityElements = []; return }
        let visible = scene.layout.spatialIndex.query(visibleRect), frames = scene.layout.frames
        accessibilityElements = scene.page.elements.filter { visible.contains($0.id) && !$0.kind.isContainer }.prefix(200).compactMap { node -> UIAccessibilityElement? in
            guard let f = frames[node.id] else { return nil }
            let element = DiagramAccessibleNode(accessibilityContainer: self); element.activate = { [weak self] in self?.model.select(node.id); self?.model.showInspector = true; return true }
            element.accessibilityLabel = node.title; element.accessibilityValue = node.isLocked ? DL("已锁定", "Locked") : nil
            element.accessibilityTraits = model.selection.contains(node.id) ? [.button,.selected] : [.button]
            element.accessibilityFrameInContainerSpace = f.cgRect.applying(cameraTransform)
            element.accessibilityCustomActions = [UIAccessibilityCustomAction(name: DL("编辑", "Edit")) { [weak self] _ in self?.startEditing(node.id); return true },
                                                  UIAccessibilityCustomAction(name: DL("折叠 / 展开", "Fold / unfold")) { [weak self] _ in self?.model.toggleCollapse(node.id); return true }]
            return element
        }
    }
}
@MainActor private final class DiagramAccessibleNode: UIAccessibilityElement {
    var activate: (() -> Bool)?
    override func accessibilityActivate() -> Bool { activate?() ?? false }
}
@MainActor final class DiagramInkCanvasView: PKCanvasView {
    override var undoManager: UndoManager? { nil }
}
#endif
