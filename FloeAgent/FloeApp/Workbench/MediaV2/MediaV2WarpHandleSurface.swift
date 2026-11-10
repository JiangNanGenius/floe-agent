// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import UIKit

/// Narrow UIKit input boundary for actual touch/Pencil/mouse handle sequences.
/// Outside the 44-point controls hit testing passes through to the canvas.
struct MediaV2WarpHandleSurface: UIViewRepresentable {
    let points: [CGPoint]
    let canvasPixels: CGSize
    var displayScale: CGFloat = 1
    var fingerEditing = false
    let valid: Bool
    let onBegin: () -> Void
    let onChange: (Int, CGPoint) -> Void
    let onEnd: () -> Void
    let onCancel: () -> Void
    let onApply: () -> Void
    let onDiscard: () -> Void
    func makeUIView(context: Context) -> MediaV2WarpHandleView { let view = MediaV2WarpHandleView(); update(view); return view }
    func updateUIView(_ uiView: MediaV2WarpHandleView, context: Context) { update(uiView) }
    private func update(_ view: MediaV2WarpHandleView) {
        view.points = points; view.canvasPixels = canvasPixels; view.displayScale = max(0.05,displayScale); view.fingerEditing = fingerEditing; view.valid = valid
        view.onBegin = onBegin; view.onChange = onChange; view.onEnd = onEnd; view.onCancel = onCancel
        view.onApply = onApply; view.onDiscard = onDiscard; view.refresh()
    }
}

final class MediaV2WarpHandleView: UIView {
    var points: [CGPoint] = []
    var canvasPixels = CGSize(width: 1, height: 1)
    var valid = true
    var displayScale: CGFloat = 1
    var fingerEditing = false
    var onBegin: (() -> Void)?
    var onChange: ((Int, CGPoint) -> Void)?
    var onEnd: (() -> Void)?
    var onCancel: (() -> Void)?
    var onApply: (() -> Void)?
    var onDiscard: (() -> Void)?
    private var trackedTouch: UITouch?
    private var selectedCorner = 0
    private var dragging = false
    private var dragOrigin = CGPoint.zero
    private var originalCenter = CGPoint.zero
    private var cornerElements: [WarpCornerAccessibilityElement] = []
    override init(frame: CGRect) {
        super.init(frame: frame); backgroundColor = .clear; isOpaque = false; isMultipleTouchEnabled = true
        accessibilityIdentifier = "media.warp.handles"
        cornerElements = (0...4).map { WarpCornerAccessibilityElement(owner: self, index: $0) }
        accessibilityElements = cornerElements
    }
    required init?(coder: NSCoder) { return nil }
    override var canBecomeFirstResponder: Bool { true }
    override var keyCommands: [UIKeyCommand]? {
        let arrows = [UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow, UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow]
        return arrows.flatMap { value in [UIKeyCommand(input: value, modifierFlags: [], action: #selector(arrow(_:))),
            UIKeyCommand(input: value, modifierFlags: .shift, action: #selector(arrow(_:)))] }
            + [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(discard)), UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(apply))]
    }
    func refresh() { setNeedsDisplay(); updateAccessibility() }
    override func layoutSubviews() { super.layoutSubviews(); updateAccessibility() }
    func handleCenter(_ index: Int) -> CGPoint? {
        guard points.count == 4, (0...4).contains(index) else { return nil }
        let point = index == 4 ? CGPoint(x: points.map(\.x).reduce(0,+)/4,y: points.map(\.y).reduce(0,+)/4) : points[index]
        return .init(x: point.x*bounds.width, y: point.y*bounds.height)
    }
    func corner(at location: CGPoint) -> Int? {
        (0..<(points.count == 4 ? 5:0)).filter { index in
            guard let center = handleCenter(index) else { return false }
            return abs(center.x-location.x) <= 22/displayScale && abs(center.y-location.y) <= 22/displayScale
        }.min { a,b in
            let ca = handleCenter(a)!, cb = handleCenter(b)!
            return hypot(ca.x-location.x,ca.y-location.y) < hypot(cb.x-location.x,cb.y-location.y)
        }
    }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, alpha > 0.01, isUserInteractionEnabled else { return nil }
        if corner(at: point) != nil { return self }
        let type = event?.allTouches?.first?.type
        if (fingerEditing || type == .pencil || type == .indirectPointer), containsQuad(point) { return self }
        return nil
    }
    private func containsQuad(_ point: CGPoint) -> Bool {
        guard points.count == 4, let first = handleCenter(0) else { return false }
        let path = UIBezierPath();path.move(to: first)
        for index in 1..<4 { if let value = handleCenter(index) { path.addLine(to: value) } }
        path.close();return path.contains(point)
    }
    override func draw(_ rect: CGRect) {
        guard points.count == 4, let context = UIGraphicsGetCurrentContext() else { return }
        let locations = points.indices.compactMap(handleCenter)
        context.addLines(between: locations); context.closePath()
        context.setStrokeColor(UIColor.white.cgColor); context.setLineWidth(3/displayScale); context.strokePath()
        context.addLines(between: locations); context.closePath()
        context.setStrokeColor((valid ? tintColor : UIColor.systemRed).cgColor); context.setLineWidth(1.5/displayScale); context.strokePath()
        if let center = handleCenter(4) {
            let radius = 7/displayScale
            context.setFillColor(UIColor.systemBackground.cgColor); context.fillEllipse(in: .init(x: center.x-radius,y: center.y-radius,width: radius*2,height: radius*2))
            context.setStrokeColor(tintColor.cgColor); context.setLineWidth(1.5/displayScale)
            context.move(to: .init(x: center.x-radius,y: center.y));context.addLine(to: .init(x: center.x+radius,y: center.y))
            context.move(to: .init(x: center.x,y: center.y-radius));context.addLine(to: .init(x: center.x,y: center.y+radius));context.strokePath()
        }
        for (index,point) in locations.enumerated() {
            let size: CGFloat = (dragging && index == selectedCorner ? 14 : 11)/displayScale
            let frame = CGRect(x: point.x-size/2,y: point.y-size/2,width: size,height: size)
            context.setFillColor(UIColor.systemBackground.cgColor); context.fillEllipse(in: frame)
            context.setStrokeColor((valid ? tintColor : UIColor.systemRed).cgColor); context.setLineWidth(2/displayScale); context.strokeEllipse(in: frame)
        }
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard trackedTouch == nil, touches.count == 1, let touch = touches.first else { cancelDrag(); return }
        let location = touch.location(in: self), index = corner(at: location) ?? (containsQuad(location) ? 4:nil)
        guard let index, let center = handleCenter(4) else { return }
        dragOrigin = location; originalCenter = center
        trackedTouch = touch; selectedCorner = index; dragging = true; becomeFirstResponder(); onBegin?(); setNeedsDisplay()
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if (event?.allTouches?.filter { $0.phase == .began || $0.phase == .moved || $0.phase == .stationary }.count ?? 1) > 1 { cancelDrag(); return }
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        let location = touch.location(in: self)
        guard bounds.width > 0, bounds.height > 0 else { return }
        let target = selectedCorner == 4 ? CGPoint(x: originalCenter.x+location.x-dragOrigin.x,y: originalCenter.y+location.y-dragOrigin.y) : location
        onChange?(selectedCorner, .init(x: target.x/bounds.width,y: target.y/bounds.height))
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        touchesMoved(touches,with: event); guard dragging else { return }
        trackedTouch = nil; dragging = false; onEnd?(); setNeedsDisplay()
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { cancelDrag() }
    private func cancelDrag() { if dragging { onCancel?() }; trackedTouch = nil; dragging = false; setNeedsDisplay() }
    func nudge(_ index: Int, dx: Double, dy: Double) {
        guard let center = handleCenter(index), bounds.width > 0, bounds.height > 0 else { return }; selectedCorner = index
        onBegin?(); onChange?(index,.init(x: center.x/bounds.width+dx/max(1,canvasPixels.width), y: center.y/bounds.height+dy/max(1,canvasPixels.height))); onEnd?()
    }
    @objc private func arrow(_ command: UIKeyCommand) {
        let amount = command.modifierFlags.contains(.shift) ? 10.0 : 1.0
        switch command.input {
        case UIKeyCommand.inputLeftArrow: nudge(selectedCorner,dx: -amount,dy: 0)
        case UIKeyCommand.inputRightArrow: nudge(selectedCorner,dx: amount,dy: 0)
        case UIKeyCommand.inputUpArrow: nudge(selectedCorner,dx: 0,dy: -amount)
        case UIKeyCommand.inputDownArrow: nudge(selectedCorner,dx: 0,dy: amount)
        default: break
        }
    }
    @objc private func apply() { onApply?() }
    @objc private func discard() { cancelDrag(); onDiscard?() }
    private func updateAccessibility() {
        for item in cornerElements {
            guard let center = handleCenter(item.index) else { continue }
            item.accessibilityFrameInContainerSpace = .init(x: center.x-22/displayScale,y: center.y-22/displayScale,width: 44/displayScale,height: 44/displayScale)
            item.accessibilityValue = String(format: "%.1f%%, %.1f%%", center.x/max(1,bounds.width)*100, center.y/max(1,bounds.height)*100)
        }
    }
}
private final class WarpCornerAccessibilityElement: UIAccessibilityElement {
    weak var owner: MediaV2WarpHandleView?
    let index: Int
    init(owner: MediaV2WarpHandleView, index: Int) {
        self.owner = owner; self.index = index; super.init(accessibilityContainer: owner)
        let chinese = Locale.preferredLanguages.first?.hasPrefix("zh") == true
        accessibilityLabel = chinese ? ["左上控制点","右上控制点","右下控制点","左下控制点","移动图层"][index] : ["Top-left handle","Top-right handle","Bottom-right handle","Bottom-left handle","Move layer"][index]
        accessibilityIdentifier = "media.warp.corner.\(index)"; accessibilityTraits = [.adjustable]
        accessibilityCustomActions = [
            .init(name: chinese ? "向左" : "Move left", target: self, selector: #selector(left)),
            .init(name: chinese ? "向右" : "Move right", target: self, selector: #selector(right)),
            .init(name: chinese ? "向上" : "Move up", target: self, selector: #selector(up)),
            .init(name: chinese ? "向下" : "Move down", target: self, selector: #selector(down))]
    }
    override func accessibilityIncrement() { owner?.nudge(index,dx: 1,dy: 0) }
    override func accessibilityDecrement() { owner?.nudge(index,dx: -1,dy: 0) }
    @objc private func left() -> Bool { owner?.nudge(index,dx: -1,dy: 0); return true }
    @objc private func right() -> Bool { owner?.nudge(index,dx: 1,dy: 0); return true }
    @objc private func up() -> Bool { owner?.nudge(index,dx: 0,dy: -1); return true }
    @objc private func down() -> Bool { owner?.nudge(index,dx: 0,dy: 1); return true }
}
#endif
