// SPDX-License-Identifier: MPL-2.0
#if os(iOS)
import SwiftUI
import UIKit

/// Transparent gesture layer over the sprite canvas. Apple Pencil always
/// draws; a finger navigates by default and can be switched to drawing with
/// the visible finger-drawing toggle. Pinch and two-finger pan zoom/pan.
@MainActor
struct SpriteCanvasGestureOverlay: UIViewRepresentable {
    var fingerDrawingEnabled: Bool
    var onDrawBegan: @MainActor (CGPoint) -> Bool
    var onDrawMoved: @MainActor (CGPoint) -> Void
    var onDrawEnded: @MainActor (CGPoint) -> Void
    var onDrawCancelled: @MainActor () -> Void
    var onPan: @MainActor (CGSize) -> Void
    var onZoom: @MainActor (CGFloat, CGPoint) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.isMultipleTouchEnabled = true
        let coordinator = context.coordinator

        let pencilPan = UIPanGestureRecognizer(target: coordinator,
                                               action: #selector(Coordinator.handlePencilPan(_:)))
        pencilPan.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.pencil.rawValue),
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
        ]
        pencilPan.minimumNumberOfTouches = 1
        pencilPan.maximumNumberOfTouches = 1
        configure(pencilPan, coordinator: coordinator)
        view.addGestureRecognizer(pencilPan)

        let fingerPan = UIPanGestureRecognizer(target: coordinator,
                                               action: #selector(Coordinator.handleFingerPan(_:)))
        fingerPan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        fingerPan.minimumNumberOfTouches = 1
        fingerPan.maximumNumberOfTouches = 1
        configure(fingerPan, coordinator: coordinator)
        view.addGestureRecognizer(fingerPan)

        let pencilTap = UITapGestureRecognizer(target: coordinator,
            action: #selector(Coordinator.handlePencilTap(_:)))
        pencilTap.allowedTouchTypes = pencilPan.allowedTouchTypes
        pencilTap.require(toFail: pencilPan)
        configure(pencilTap, coordinator: coordinator)
        view.addGestureRecognizer(pencilTap)

        let fingerTap = UITapGestureRecognizer(target: coordinator,
            action: #selector(Coordinator.handleFingerTap(_:)))
        fingerTap.allowedTouchTypes = fingerPan.allowedTouchTypes
        fingerTap.require(toFail: fingerPan)
        configure(fingerTap, coordinator: coordinator)
        view.addGestureRecognizer(fingerTap)

        let twoFingerPan = UIPanGestureRecognizer(target: coordinator,
                                                  action: #selector(Coordinator.handleTwoFingerPan(_:)))
        twoFingerPan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2
        configure(twoFingerPan, coordinator: coordinator)
        view.addGestureRecognizer(twoFingerPan)

        let pinch = UIPinchGestureRecognizer(target: coordinator,
                                             action: #selector(Coordinator.handlePinch(_:)))
        pinch.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        configure(pinch, coordinator: coordinator)
        view.addGestureRecognizer(pinch)

        coordinator.pencilPan = pencilPan
        coordinator.fingerPan = fingerPan
        coordinator.twoFingerPan = twoFingerPan
        coordinator.pinch = pinch
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    private func configure(_ recognizer: UIGestureRecognizer, coordinator: Coordinator) {
        recognizer.delegate = coordinator
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: SpriteCanvasGestureOverlay
        weak var pencilPan: UIPanGestureRecognizer?
        weak var fingerPan: UIPanGestureRecognizer?
        weak var twoFingerPan: UIPanGestureRecognizer?
        weak var pinch: UIPinchGestureRecognizer?
        private var drawActive = false
        private var navigationLastTranslation: CGPoint = .zero
        private var twoFingerLastTranslation: CGPoint = .zero

        init(parent: SpriteCanvasGestureOverlay) {
            self.parent = parent
        }

        @objc func handlePencilPan(_ gesture: UIPanGestureRecognizer) {
            draw(gesture)
        }

        @objc func handleFingerPan(_ gesture: UIPanGestureRecognizer) {
            if parent.fingerDrawingEnabled {
                draw(gesture)
            } else {
                navigate(gesture)
            }
        }

        @objc func handlePencilTap(_ gesture: UITapGestureRecognizer) {
            drawTap(gesture)
        }

        @objc func handleFingerTap(_ gesture: UITapGestureRecognizer) {
            guard parent.fingerDrawingEnabled else { return }
            drawTap(gesture)
        }

        private func drawTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let view = gesture.view else { return }
            let point = gesture.location(in: view)
            guard parent.onDrawBegan(point) else { return }
            parent.onDrawEnded(point)
        }

        @objc func handleTwoFingerPan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            switch gesture.state {
            case .began:
                twoFingerLastTranslation = .zero
            case .changed:
                let translation = gesture.translation(in: view)
                let delta = CGSize(width: translation.x - twoFingerLastTranslation.x,
                                   height: translation.y - twoFingerLastTranslation.y)
                twoFingerLastTranslation = translation
                parent.onPan(delta)
            case .ended, .cancelled, .failed:
                twoFingerLastTranslation = .zero
            default:
                break
            }
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard let view = gesture.view else { return }
            switch gesture.state {
            case .changed:
                let scale = gesture.scale
                guard scale.isFinite, scale > 0, scale != 1 else { return }
                gesture.scale = 1
                parent.onZoom(scale, gesture.location(in: view))
            default:
                break
            }
        }

        private func draw(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            let location = gesture.location(in: view)
            switch gesture.state {
            case .began:
                drawActive = parent.onDrawBegan(location)
            case .changed:
                guard drawActive else { return }
                parent.onDrawMoved(location)
            case .ended:
                guard drawActive else { return }
                drawActive = false
                parent.onDrawEnded(location)
            case .cancelled, .failed:
                guard drawActive else { return }
                drawActive = false
                parent.onDrawCancelled()
            default:
                break
            }
        }

        private func navigate(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            switch gesture.state {
            case .began:
                navigationLastTranslation = .zero
            case .changed:
                let translation = gesture.translation(in: view)
                let delta = CGSize(width: translation.x - navigationLastTranslation.x,
                                   height: translation.y - navigationLastTranslation.y)
                navigationLastTranslation = translation
                parent.onPan(delta)
            case .ended, .cancelled, .failed:
                navigationLastTranslation = .zero
            default:
                break
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            let pinchAndPan = (gestureRecognizer === pinch && otherGestureRecognizer === twoFingerPan)
                || (gestureRecognizer === twoFingerPan && otherGestureRecognizer === pinch)
            return pinchAndPan
        }
    }
}
#endif
