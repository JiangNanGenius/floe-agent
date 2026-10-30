import SwiftUI
import UIKit

/// Public UIKit continuous input gives contextual controls an explicit cancel
/// channel. SwiftUI GestureState reset order is not used to guess completion.
/// Zero-duration long press preserves touch-down and the controls' 2pt threshold.
struct CADSketchControlDragGesture: UIGestureRecognizerRepresentable {
    typealias GestureID = EditorViewModel.SketchDragGestureID
    var onBegan: () -> GestureID?
    var onChanged: (SIMD2<Double>, GestureID) -> Void
    var onEnded: (GestureID) -> Void
    var onCancelled: (GestureID) -> Void

    @MainActor
    final class Coordinator {
        private var active: GestureID?
        private var start = CGPoint.zero
        private var changed: ((SIMD2<Double>, GestureID) -> Void)?
        private var ended: ((GestureID) -> Void)?
        private var cancelled: ((GestureID) -> Void)?

        func receive(state: UIGestureRecognizer.State, point: CGPoint,
                     callbacks: CADSketchControlDragGesture) {
            switch state {
            case .began:
                // A recognizer starts a fresh lease; a previous cancellation
                // can affect only the identity captured by that previous lease.
                if let active { cancelled?(active) }
                active = callbacks.onBegan()
                start = point
                changed = callbacks.onChanged
                ended = callbacks.onEnded
                cancelled = callbacks.onCancelled
            case .changed:
                guard let active else { return }
                changed?(SIMD2(Double(point.x - start.x), Double(point.y - start.y)), active)
            case .ended:
                guard let lease = active else { return }
                let update = changed, finish = ended
                active = nil
                changed = nil; ended = nil; cancelled = nil
                update?(SIMD2(Double(point.x - start.x), Double(point.y - start.y)), lease)
                finish?(lease)
            case .cancelled, .failed:
                guard let lease = active else { return }
                let cancel = cancelled
                active = nil
                changed = nil; ended = nil; cancelled = nil
                cancel?(lease)
            default: break
            }
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }
    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = 0
        recognizer.allowableMovement = .greatestFiniteMagnitude
        recognizer.numberOfTouchesRequired = 1
        return recognizer
    }
    func updateUIGestureRecognizer(_ recognizer: UILongPressGestureRecognizer, context: Context) {}
    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        context.coordinator.receive(state: recognizer.state,
                                    point: context.converter.location(in: .global), callbacks: self)
    }
}
