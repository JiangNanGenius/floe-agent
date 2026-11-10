// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import UIKit

/// Finger pans remain owned by the enclosing scroll view unless explicitly
/// enabled. Pencil and mouse edit without changing the user's touch setting.
struct MusicPianoRollInput: UIViewRepresentable {
    var fingerEditing: Bool
    var tap: (CGPoint) -> Void
    var drag: (CGPoint, CGPoint, UIGestureRecognizer.State) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UIView {
        let view = UIView(); view.backgroundColor = .clear
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.panned(_:)))
        pan.maximumNumberOfTouches = 1
        tap.require(toFail: pan)
        context.coordinator.tap = tap; context.coordinator.pan = pan
        view.addGestureRecognizer(tap); view.addGestureRecognizer(pan)
        configure(context.coordinator)
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) { context.coordinator.parent = self; configure(context.coordinator) }
    private func configure(_ coordinator: Coordinator) {
        let types: [NSNumber] = [UITouch.TouchType.pencil, .indirectPointer].map { NSNumber(value: $0.rawValue) }
            + (fingerEditing ? [NSNumber(value: UITouch.TouchType.direct.rawValue)] : [])
        coordinator.tap?.allowedTouchTypes = types; coordinator.pan?.allowedTouchTypes = types
    }
    @MainActor final class Coordinator: NSObject {
        var parent: MusicPianoRollInput
        var tap: UITapGestureRecognizer?
        var pan: UIPanGestureRecognizer?
        var start = CGPoint.zero
        init(_ parent: MusicPianoRollInput) { self.parent = parent }
        @objc func tapped(_ recognizer: UITapGestureRecognizer) { parent.tap(recognizer.location(in: recognizer.view)) }
        @objc func panned(_ recognizer: UIPanGestureRecognizer) {
            let point = recognizer.location(in: recognizer.view)
            if recognizer.state == .began {
                let translation = recognizer.translation(in: recognizer.view)
                start = CGPoint(x: point.x - translation.x, y: point.y - translation.y)
            }
            parent.drag(start, point, recognizer.state)
        }
    }
}
#endif
