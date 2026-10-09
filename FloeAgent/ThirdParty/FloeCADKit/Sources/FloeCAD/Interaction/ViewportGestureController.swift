//
//  ViewportGestureController.swift
//  openshape3d
//
//  Owns all viewport gesture recognizers and routes them. Navigation rules
//  (Shapr3D conventions):
//  - Two-finger pan and pinch ALWAYS navigate, in every mode.
//  - One-finger (finger, not Pencil) drag: mode-dependent; orbit by default.
//  - Pencil never orbits — it draws (sketch mode) or precision-selects.
//    Pencil drags reach the delegate (sketch strokes, pulls); if unclaimed
//    they do nothing rather than falling back to orbit.
//

import Foundation
import UIKit
import MetalKit

@MainActor
protocol ViewportGestureDelegate: AnyObject {
    func gestureTapped(at point: CGPoint)
    func gestureDoubleTapped(at point: CGPoint)
    /// Offered the one-finger drag at `.began`. Return true to claim it
    /// (gizmo drag, sketch stroke); false lets the camera orbit. `isPencil`
    /// distinguishes an Apple Pencil stroke from a finger so sketch mode can
    /// route drawing to the Pencil and navigation to the finger (Shapr3D).
    func gestureDragBegan(at point: CGPoint, isPencil: Bool) -> Bool
    func gestureDragChanged(at point: CGPoint)
    func gestureDragEnded(at point: CGPoint)
    /// Long-press (plan §B13, spec §8.3): Select Through popup listing every
    /// body under the point through depth.
    func gestureLongPressed(at point: CGPoint)
    /// Pointer / Apple-Pencil hover moved to `point` (no touch down). Drives
    /// tap-built Line/Rectangle/Arc previews. `nil` point = hover ended.
    func gestureHovered(at point: CGPoint?)
    /// The Apple Pencil's double-tap (or squeeze) gesture fired.
    func gesturePencilDoubleTapped()
}

final class ViewportGestureController: NSObject {
    weak var view: MTKView?
    weak var renderer: Renderer?
    weak var delegate: ViewportGestureDelegate?

    /// Fired whenever a navigation gesture moved the camera (orbit/pan/zoom).
    var cameraChanged: (() -> Void)?

    private var lastPanLocation: CGPoint = .zero
    private var lastTwoFingerLocation: CGPoint = .zero
    private weak var orbitRecognizer: UIPanGestureRecognizer?
    /// Set in shouldReceive: the one-finger drag is being driven by the Pencil.
    private var orbitTouchIsPencil = false
    /// Where the one-finger touch actually LANDED, captured in shouldReceive
    /// before the pan recognizer has moved its threshold. See `handleOrbit`.
    private var orbitTouchDown: CGPoint?

    func attach(to view: MTKView, renderer: Renderer) {
        self.view = view
        self.renderer = renderer

        let orbit = UIPanGestureRecognizer(target: self, action: #selector(handleOrbit(_:)))
        orbit.minimumNumberOfTouches = 1
        orbit.maximumNumberOfTouches = 1
        orbit.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.pencil.rawValue),
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

    private var dragClaimed = false

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
            orbitTouchDown = nil
            lastPanLocation = start
            dragClaimed = delegate?.gestureDragBegan(at: start, isPencil: orbitTouchIsPencil) ?? false
            if dragClaimed, start != location {
                delegate?.gestureDragChanged(at: location)
                redraw()
            }
        case .changed:
            if dragClaimed {
                delegate?.gestureDragChanged(at: location)
                redraw()
            } else if orbitTouchIsPencil {
                // Pencil never orbits (spec §7.1) — unclaimed pencil drags
                // are dropped instead of moving the camera.
            } else {
                let delta = CGSize(
                    width: location.x - lastPanLocation.x,
                    height: location.y - lastPanLocation.y
                )
                lastPanLocation = location
                renderer.camera.orbit(deltaPixels: delta, viewportSize: view.bounds.size)
                redraw()
                cameraChanged?()
            }
        case .ended, .cancelled, .failed:
            if dragClaimed {
                delegate?.gestureDragEnded(at: location)
                dragClaimed = false
                redraw()
            }
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
        delegate?.gestureTapped(at: gesture.location(in: view))
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
        if gestureRecognizer === orbitRecognizer {
            orbitTouchIsPencil = touch.type == .pencil
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
