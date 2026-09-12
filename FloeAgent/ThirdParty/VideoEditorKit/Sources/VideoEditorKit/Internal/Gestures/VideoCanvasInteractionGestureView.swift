import CoreGraphics
import SwiftUI

struct VideoCanvasPinchPanGesturePolicy {

    // MARK: - Public Methods

    static func translation(
        from startLocation: CGPoint,
        to currentLocation: CGPoint
    ) -> CGSize {
        guard
            startLocation.x.isFinite,
            startLocation.y.isFinite,
            currentLocation.x.isFinite,
            currentLocation.y.isFinite
        else {
            return .zero
        }

        return CGSize(
            width: currentLocation.x - startLocation.x,
            height: currentLocation.y - startLocation.y
        )
    }

}

struct VideoCanvasInteractionGestureView: UIViewRepresentable {

    // MARK: - Public Properties

    var onPanChanged: (CGSize) -> Void
    var onPanEnded: () -> Void
    var onPinchChanged: (_ magnification: CGFloat, _ anchor: CGPoint, _ translation: CGSize) -> Void
    var onPinchEnded: () -> Void
    var onDoubleTap: () -> Void

    // MARK: - Public Methods

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true

        let panGesture = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        panGesture.maximumNumberOfTouches = 1
        panGesture.cancelsTouchesInView = false
        panGesture.delegate = context.coordinator
        view.addGestureRecognizer(panGesture)

        let pinchGesture = UIPinchGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePinch(_:))
        )
        pinchGesture.cancelsTouchesInView = false
        pinchGesture.delegate = context.coordinator
        view.addGestureRecognizer(pinchGesture)

        let doubleTapGesture = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTapGesture.numberOfTapsRequired = 2
        doubleTapGesture.cancelsTouchesInView = false
        doubleTapGesture.delegate = context.coordinator
        view.addGestureRecognizer(doubleTapGesture)

        return view
    }

    func updateUIView(
        _ uiView: UIView,
        context: Context
    ) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {

        // MARK: - Public Properties

        var parent: VideoCanvasInteractionGestureView

        // MARK: - Private Properties

        private var pinchStartLocation: CGPoint?

        // MARK: - Initializer

        init(_ parent: VideoCanvasInteractionGestureView) {
            self.parent = parent
        }

        // MARK: - Public Methods

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        @objc
        func handlePan(_ recognizer: UIPanGestureRecognizer) {
            let translationPoint = recognizer.translation(in: recognizer.view)
            let translation = CGSize(
                width: translationPoint.x,
                height: translationPoint.y
            )

            switch recognizer.state {
            case .began, .changed:
                parent.onPanChanged(translation)
            case .ended, .cancelled, .failed:
                parent.onPanEnded()
            default:
                break
            }
        }

        @objc
        func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            let currentLocation = recognizer.location(in: recognizer.view)

            switch recognizer.state {
            case .began:
                pinchStartLocation = currentLocation
                parent.onPinchChanged(recognizer.scale, currentLocation, .zero)
            case .changed:
                let startLocation = pinchStartLocation ?? currentLocation
                let translation = VideoCanvasPinchPanGesturePolicy.translation(
                    from: startLocation,
                    to: currentLocation
                )
                parent.onPinchChanged(recognizer.scale, startLocation, translation)
            case .ended, .cancelled, .failed:
                pinchStartLocation = nil
                parent.onPinchEnded()
            default:
                break
            }
        }

        @objc
        func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            parent.onDoubleTap()
        }
    }

}
