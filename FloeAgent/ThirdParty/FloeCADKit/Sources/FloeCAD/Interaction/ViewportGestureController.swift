//
//  ViewportGestureController.swift
//  openshape3d
//
//  Owns all viewport gesture recognizers and routes them. Navigation rules
//  (Shapr3D conventions, unified input rule plan N11):
//  - Two-finger pan and pinch ALWAYS navigate, in every mode.
//  - One-finger drag (finger, not Pencil): mode-dependent; orbit by default,
//    edit only while the explicit finger-drawing switch is on.
//  - Pencil and mouse/trackpad pointer edit with the selected tool (sketch
//    strokes, pulls); unclaimed Pencil drags do nothing rather than orbiting,
//    while an unclaimed pointer drag orbits like a finger.
//

import Foundation
import UIKit
import MetalKit

/// The physical source of a viewport drag (plan N11). The old `isPencil`
/// bool could not express the three-way split the unified input rule needs:
/// Apple Pencil and mouse/trackpad pointers edit with the selected tool,
/// while a finger navigates unless the explicit finger-drawing switch is on.
/// Classified once from `UITouch.type` at touch-down and carried unchanged
/// through the whole delivery path. SDK (UIKit UITouch.h): `indirect` is an
/// indirect touch not on a screen (a trackpad surface drag); `indirectPointer`
/// (iOS 13.4+) is a button-based indirect device such as a mouse.
enum CADViewportInputSource: Equatable {
    case pencil
    case finger
    /// Mouse or trackpad — a precision pointer, not a finger.
    case pointer

    init(_ touchType: UITouch.TouchType) {
        switch touchType {
        case .pencil: self = .pencil
        case .indirect, .indirectPointer: self = .pointer
        default: self = .finger
        }
    }
    func editsDrawing(fingerDrawingEnabled: Bool) -> Bool {
        self != .finger || fingerDrawingEnabled
    }
}

@MainActor
protocol ViewportGestureDelegate: AnyObject {
    func gestureTapped(at point: CGPoint)
    /// Physical-source-aware tap. Legacy/synthetic delegate entry remains available.
    func gestureTapped(at point: CGPoint, source: CADViewportInputSource)
    func gestureDoubleTapped(at point: CGPoint)
    /// Offered the one-finger drag at `.began`. Return true to claim it
    /// (gizmo drag, sketch stroke); false lets the camera orbit. `isPencil`
    /// distinguishes an Apple Pencil stroke from a finger so sketch mode can
    /// route drawing to the Pencil and navigation to the finger (Shapr3D).
    /// Kept for existing conformers — new code should use the `source` variant
    /// below, which also recognises mouse/trackpad pointers.
    func gestureDragBegan(at point: CGPoint, isPencil: Bool) -> Bool
    /// Source-aware drag offer (plan N11): Pencil and pointer edit with the
    /// selected tool; a finger edits only while the explicit finger-drawing
    /// switch is on and otherwise navigates.
    func gestureDragBegan(at point: CGPoint, source: CADViewportInputSource) -> Bool
    func gestureDragChanged(at point: CGPoint)
    func gestureDragEnded(at point: CGPoint)
    func gestureDragCancelled(at point: CGPoint)
    func gestureDragBegan(at point: CGPoint, isPencil: Bool, gestureID: UUID) -> Bool
    func gestureDragBegan(at point: CGPoint, source: CADViewportInputSource, gestureID: UUID) -> Bool
    func gestureDragBegan(at point:CGPoint,isPencil:Bool,pressure:Double,gestureID:UUID) -> Bool
    func gestureDragBegan(at point:CGPoint,source:CADViewportInputSource,pressure:Double,gestureID:UUID) -> Bool
    func gestureDragPressureChanged(_ pressure:Double,gestureID:UUID)
    func gestureDragChanged(at point: CGPoint, gestureID: UUID)
    func gestureDragEnded(at point: CGPoint, gestureID: UUID)
    func gestureDragCancelled(at point: CGPoint, gestureID: UUID)
    /// Long-press (plan §B13, spec §8.3): Select Through popup listing every
    /// body under the point through depth.
    func gestureLongPressed(at point: CGPoint)
    /// Pointer / Apple-Pencil hover moved to `point` (no touch down). Drives
    /// tap-built Line/Rectangle/Arc previews. `nil` point = hover ended.
    func gestureHovered(at point: CGPoint?)
    /// The Apple Pencil's double-tap (or squeeze) gesture fired.
    func gesturePencilDoubleTapped()
}

extension ViewportGestureDelegate {
    func gestureTapped(at point: CGPoint, source: CADViewportInputSource) { gestureTapped(at: point) }
    func gestureDragBegan(at point:CGPoint,isPencil:Bool,pressure:Double,gestureID:UUID) -> Bool { gestureDragBegan(at:point,isPencil:isPencil,gestureID:gestureID) }
    func gestureDragBegan(at point: CGPoint, source: CADViewportInputSource, pressure: Double, gestureID: UUID) -> Bool {
        gestureDragBegan(at: point, isPencil: source == .pencil, pressure: pressure, gestureID: gestureID)
    }
    func gestureDragPressureChanged(_ pressure:Double,gestureID:UUID) {}
    func gestureDragCancelled(at point: CGPoint) { gestureDragEnded(at: point) }
    func gestureDragBegan(at point: CGPoint, isPencil: Bool, gestureID: UUID) -> Bool {
        gestureDragBegan(at: point, isPencil: isPencil)
    }
    func gestureDragBegan(at point: CGPoint, source: CADViewportInputSource, gestureID: UUID) -> Bool {
        gestureDragBegan(at: point, isPencil: source == .pencil, gestureID: gestureID)
    }
    // Legacy bool entry maps onto the unified source: only the Pencil was
    // ever distinguishable here, so a non-Pencil legacy caller meant finger.
    func gestureDragBegan(at point: CGPoint, source: CADViewportInputSource) -> Bool {
        gestureDragBegan(at: point, isPencil: source == .pencil)
    }
    func gestureDragChanged(at point: CGPoint, gestureID: UUID) { gestureDragChanged(at: point) }
    func gestureDragEnded(at point: CGPoint, gestureID: UUID) { gestureDragEnded(at: point) }
    func gestureDragCancelled(at point: CGPoint, gestureID: UUID) { gestureDragCancelled(at: point) }
}

/// Records actual Pencil force before UIPan dispatches its action. Ordinary
/// finger drags use unit pressure; no synthetic Pencil pressure is inferred.
private final class ViewportPressurePan:UIPanGestureRecognizer {
    private(set) var normalizedPressure:Double=1
    private func record(_ touches:Set<UITouch>) {
        guard let touch=touches.first else { return }
        normalizedPressure=touch.type == .pencil && touch.maximumPossibleForce>0
            ? min(1,max(0,Double(touch.force/touch.maximumPossibleForce))):1
    }
    override func touchesBegan(_ touches:Set<UITouch>,with event:UIEvent) { record(touches);super.touchesBegan(touches,with:event) }
    override func touchesMoved(_ touches:Set<UITouch>,with event:UIEvent) { record(touches);super.touchesMoved(touches,with:event) }
}

final class ViewportGestureController: NSObject {
    weak var view: MTKView?
    weak var renderer: Renderer?
    weak var delegate: ViewportGestureDelegate?
    var planarNavigation = false

    /// Fired whenever a navigation gesture moved the camera (orbit/pan/zoom).
    var cameraChanged: (() -> Void)?

    private var lastPanLocation: CGPoint = .zero
    private var lastTwoFingerLocation: CGPoint = .zero
    private weak var orbitRecognizer: UIPanGestureRecognizer?
    private weak var tapRecognizer: UITapGestureRecognizer?
    private var tapTouchSource: CADViewportInputSource = .finger
    /// Set in shouldReceive: the physical source of the one-finger drag,
    /// classified from `UITouch.type` at touch-down and carried unchanged
    /// through delivery (plan N11).
    private var orbitTouchSource: CADViewportInputSource = .finger
    /// Where the one-finger touch actually LANDED, captured in shouldReceive
    /// before the pan recognizer has moved its threshold. See `handleOrbit`.
    private var orbitTouchDown: CGPoint?
    private var orbitTouchDownPressure:Double?
    private var ownedRecognizers: [UIGestureRecognizer] = []
    private var pencilInteraction: UIPencilInteraction?

    func attach(to view: MTKView, renderer: Renderer) {
        if self.view === view { self.renderer = renderer; return }
        if let previous = self.view {
            finishClaimedDrag(at: lastPanLocation, cancelled: true)
            previous.isPaused = true
            for recognizer in ownedRecognizers { previous.removeGestureRecognizer(recognizer) }
            if let pencilInteraction { previous.removeInteraction(pencilInteraction) }
        }
        interactiveDepth = 0
        orbitTouchDown = nil
        orbitTouchDownPressure=nil
        orbitTouchSource = .finger
        tapTouchSource = .finger
        ownedRecognizers.removeAll()
        pencilInteraction = nil
        self.view = view
        self.renderer = renderer

        let orbit = ViewportPressurePan(target: self, action: #selector(handleOrbit(_:)))
        orbit.minimumNumberOfTouches = 1
        orbit.maximumNumberOfTouches = 1
        // direct = finger, pencil = Apple Pencil, indirect = trackpad surface
        // drag, indirectPointer = mouse (UIKit UITouch.h). Without the two
        // indirect types a mouse/trackpad click-drag never reached the
        // viewport at all — the unified input rule (plan N11) requires the
        // pointer to edit with the selected tool exactly like the Pencil.
        orbit.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.pencil.rawValue),
            NSNumber(value: UITouch.TouchType.indirect.rawValue),
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
        ]
        orbit.delegate = self
        orbitRecognizer = orbit
        view.addGestureRecognizer(orbit)

        let twoFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2
        twoFingerPan.delegate = self
        view.addGestureRecognizer(twoFingerPan)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        view.addGestureRecognizer(pinch)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.allowedTouchTypes = [UITouch.TouchType.direct, .pencil, .indirect, .indirectPointer]
            .map { NSNumber(value: $0.rawValue) }
        tap.delegate = self
        tapRecognizer = tap
        tap.require(toFail: doubleTap)
        view.addGestureRecognizer(tap)

        // Long-press = Select Through (spec §8.3). A held-still touch fires
        // before the pan's movement threshold, so drags stay unaffected.
        let longPress = UILongPressGestureRecognizer(
            target: self, action: #selector(handleLongPress(_:))
        )
        view.addGestureRecognizer(longPress)

        // Pointer / Pencil hover: tap-built Line/Rectangle/Arc previews
        // (trackpad, mouse, or M2+ Pencil hover). Touch-only devices simply
        // never fire it — tap-to-place still works without a preview.
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        view.addGestureRecognizer(hover)

        // Apple Pencil double-tap / squeeze (Pencil 2 / Pro): a quick undo, the
        // Shapr3D-style "fix that" shortcut without reaching for the toolbar.
        let pencil = UIPencilInteraction()
        pencil.delegate = self
        view.addInteraction(pencil)
        ownedRecognizers = [orbit, twoFingerPan, pinch, doubleTap, tap, longPress, hover]
        for (recognizer, name) in zip(ownedRecognizers,
                ["orbit", "pan", "pinch", "doubleTap", "tap", "longPress", "hover"]) {
            recognizer.name = "FloeCAD.viewport." + name
        }
        pencilInteraction = pencil
    }

    private func redraw() {
        view?.setNeedsDisplay()
    }

    // MARK: - Interactive (continuous) rendering

    /// The viewport renders on-demand (paused + setNeedsDisplay) when idle, but
    /// that adds a frame-plus of input-to-photon latency that reads as a
    /// "sluggish" drag. While any gesture is live we un-pause the view so it
    /// renders every display refresh; a depth counter keeps it un-paused until
    /// the LAST overlapping gesture ends (pinch + two-finger pan overlap).
    private var interactiveDepth = 0
    private func beginInteractive() {
        interactiveDepth += 1
        if interactiveDepth == 1 { view?.isPaused = false }
    }
    private func endInteractive() {
        interactiveDepth = max(0, interactiveDepth - 1)
        if interactiveDepth == 0 {
            view?.isPaused = true
            view?.setNeedsDisplay()   // one settled frame after the gesture
        }
    }

    // MARK: - Handlers

    private var claimedDragID: UUID?
    private var dragClaimed: Bool { claimedDragID != nil }

    /// The actual recognizer and component input tests share this delivery
    /// path. Every delivery carries the identity acquired at touch begin.
    @discardableResult
    func claimDrag(at point: CGPoint, source: CADViewportInputSource, pressure: Double = 1) -> Bool {
        if claimedDragID != nil { finishClaimedDrag(at: point, cancelled: true) }
        let id = UUID()
        guard delegate?.gestureDragBegan(at: point, source: source, pressure: pressure, gestureID: id) == true else { return false }
        claimedDragID = id
        return true
    }
    /// Legacy bool entry kept for existing component tests; a non-Pencil
    /// legacy drag meant a finger.
    @discardableResult
    func claimDrag(at point: CGPoint, isPencil: Bool, pressure: Double = 1) -> Bool {
        claimDrag(at: point, source: isPencil ? .pencil : .finger, pressure: pressure)
    }
    func changeClaimedDrag(at point: CGPoint,pressure:Double=1) {
        if let id = claimedDragID { delegate?.gestureDragPressureChanged(pressure,gestureID:id);delegate?.gestureDragChanged(at: point, gestureID: id) }
    }
    func finishClaimedDrag(at point: CGPoint, cancelled: Bool) {
        guard let id = claimedDragID else { return }
        claimedDragID = nil
        if cancelled { delegate?.gestureDragCancelled(at: point, gestureID: id) }
        else { delegate?.gestureDragEnded(at: point, gestureID: id) }
    }

    @objc private func handleOrbit(_ gesture: UIPanGestureRecognizer) {
        guard let view, let renderer else { return }
        let location = gesture.location(in: view)
        switch gesture.state {
        case .began:
            beginInteractive()
            // A pan recognizer begins only after the finger has travelled its
            // ~10 pt threshold, and `location` is where the finger is THEN —
            // so every sketch stroke used to anchor up to 10 pt (0.7 mm at a
            // part-sized zoom, several mm zoomed out) away from the point the
            // user actually touched: a circle's centre, a rectangle's first
            // corner, a line's start all drifted in the direction of the drag.
            // `translation` is the movement since touch-down, so subtracting
            // it recovers the touch-down point exactly. The first `.changed`
            // then carries the finger from there to wherever it is now.
            // `translation` should recover that point, but on the simulator's
            // injected touches it read zero at `.began` (the circle still
            // landed 1 mm downstream), so the touch-down captured by
            // `shouldReceive` is the primary source and the subtraction the
            // fallback.
            let translation = gesture.translation(in: view)
            let start = orbitTouchDown
                ?? CGPoint(x: location.x - translation.x, y: location.y - translation.y)
            let startPressure=orbitTouchDownPressure ?? (gesture as? ViewportPressurePan)?.normalizedPressure ?? 1
            let startSource = orbitTouchSource
            orbitTouchDown = nil;orbitTouchDownPressure=nil
            lastPanLocation = start
            claimDrag(at: start, source: startSource, pressure: startPressure)
            if dragClaimed, start != location {
                changeClaimedDrag(at: location,pressure:(gesture as? ViewportPressurePan)?.normalizedPressure ?? 1)
                redraw()
            }
        case .changed:
            if dragClaimed {
                changeClaimedDrag(at: location,pressure:(gesture as? ViewportPressurePan)?.normalizedPressure ?? 1)
                redraw()
            } else if orbitTouchSource == .pencil {
                // Pencil never orbits (spec §7.1) — unclaimed pencil drags
                // are dropped instead of moving the camera.
            } else {
                // Unclaimed finger AND mouse/trackpad pointer drags orbit.
                // Claimed pointer drags already edit with the selected tool
                // (plan N11); navigation remains the default for empty space.
                let delta = CGSize(
                    width: location.x - lastPanLocation.x,
                    height: location.y - lastPanLocation.y
                )
                lastPanLocation = location
                renderer.camera.navigateDrag(deltaPixels: delta, viewportSize: view.bounds.size, planar: planarNavigation)
                redraw()
                cameraChanged?()
            }
        case .ended:
            if dragClaimed { finishClaimedDrag(at: location, cancelled: false); redraw() }
            endInteractive()
        case .cancelled, .failed:
            if dragClaimed { finishClaimedDrag(at: location, cancelled: true); redraw() }
            endInteractive()
        default:
            break
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let view, let renderer else { return }
        let location = gesture.location(in: view)
        switch gesture.state {
        case .began:
            beginInteractive()
            lastTwoFingerLocation = location
        case .changed:
            let delta = CGSize(
                width: location.x - lastTwoFingerLocation.x,
                height: location.y - lastTwoFingerLocation.y
            )
            lastTwoFingerLocation = location
            renderer.camera.pan(deltaPixels: delta, viewportSize: view.bounds.size)
            redraw()
            cameraChanged?()
        case .ended, .cancelled, .failed:
            endInteractive()
        default:
            break
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard let renderer else { return }
        switch gesture.state {
        case .began:
            beginInteractive()
        case .changed:
            renderer.camera.zoom(scale: Float(gesture.scale))
            gesture.scale = 1
            redraw()
            cameraChanged?()
        case .ended, .cancelled, .failed:
            endInteractive()
        default:
            break
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let view else { return }
        deliverTap(at: gesture.location(in: view), source: tapTouchSource)
    }

    /// One dispatch path for the recognizer's already-classified physical source.
    func deliverTap(at point: CGPoint, source: CADViewportInputSource) {
        delegate?.gestureTapped(at: point, source: source)
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard let view else { return }
        delegate?.gestureDoubleTapped(at: gesture.location(in: view))
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard let view, gesture.state == .began else { return }
        delegate?.gestureLongPressed(at: gesture.location(in: view))
    }

    @objc private func handleHover(_ gesture: UIHoverGestureRecognizer) {
        guard let view else { return }
        switch gesture.state {
        case .began, .changed:
            delegate?.gestureHovered(at: gesture.location(in: view))
        case .ended, .cancelled, .failed:
            delegate?.gestureHovered(at: nil)
        default:
            break
        }
    }
}

extension ViewportGestureController: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // Two-finger pan and pinch combine into a single pan+zoom feel.
        // (The one-finger orbit recognizer never runs simultaneously: it is
        // single-touch, so the pinch cannot coexist with it.)
        (gestureRecognizer is UIPinchGestureRecognizer && otherGestureRecognizer is UIPanGestureRecognizer)
            || (gestureRecognizer is UIPanGestureRecognizer && otherGestureRecognizer is UIPinchGestureRecognizer)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch
    ) -> Bool {
        if gestureRecognizer === tapRecognizer {
            tapTouchSource = CADViewportInputSource(touch.type)
        }
        if gestureRecognizer === orbitRecognizer {
            orbitTouchSource = CADViewportInputSource(touch.type)
            orbitTouchDownPressure=touch.type == .pencil && touch.maximumPossibleForce>0
                ? min(1,max(0,Double(touch.force/touch.maximumPossibleForce))):1
            if let view { orbitTouchDown = touch.location(in: view) }
        }
        return true
    }
}

extension ViewportGestureController: UIPencilInteractionDelegate {
    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        delegate?.gesturePencilDoubleTapped()
    }
}
