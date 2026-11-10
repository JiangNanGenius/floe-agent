// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import UIKit
import FloeMusicCore

/// The ruler owns one-finger scrubbing. In lanes, fingers pan the scroll view;
/// a held clip moves and selected edges trim. Pencil/mouse edit immediately.
/// Two-finger gestures stay with the enclosing scrolling/zooming timeline.
struct MusicTimelineInput: UIViewRepresentable {
    var ruler = false
    var selected = false
    var select: () -> Void = {}
    var open: () -> Void = {}
    var seek: (CGFloat) -> Void = { _ in }
    var edit: (MusicTimelineEditKind, CGFloat, UIGestureRecognizer.State) -> Void = { _, _, _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UIView {
        let view = UIView(); view.backgroundColor = .clear
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.panned(_:)))
        pan.maximumNumberOfTouches = 1
        let held = MusicTimelineHoldGesture(target: context.coordinator, action: #selector(Coordinator.held(_:)))
        held.minimumPressDuration = 0.28
        held.allowableMovement = 10
        held.numberOfTouchesRequired = 1
        held.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        let single = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        let double = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.opened(_:)))
        double.numberOfTapsRequired = 2
        single.require(toFail: double)
        for recognizer in [pan, held, single, double] {
            recognizer.delegate = context.coordinator
            view.addGestureRecognizer(recognizer)
        }
        context.coordinator.pan = pan; context.coordinator.hold = held
        context.coordinator.doubleTap = double
        configure(context.coordinator)
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self; configure(context.coordinator)
    }
    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) { coordinator.cancel() }
    private func configure(_ coordinator: Coordinator) {
        coordinator.hold?.isEnabled = !ruler
        coordinator.doubleTap?.isEnabled = !ruler
    }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: MusicTimelineInput
        weak var pan: UIPanGestureRecognizer?
        weak var hold: UILongPressGestureRecognizer?
        weak var doubleTap: UITapGestureRecognizer?
        private var touchTypes: [ObjectIdentifier: UITouch.TouchType] = [:]
        private var touchStarts: [ObjectIdentifier: CGPoint] = [:]
        private var activeKind: MusicTimelineEditKind?
        private weak var activeRecognizer: UIGestureRecognizer?
        private var heldStart = CGPoint.zero
        init(_ parent: MusicTimelineInput) { self.parent = parent }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            touchTypes[ObjectIdentifier(recognizer)] = touch.type
            touchStarts[ObjectIdentifier(recognizer)] = touch.location(in: recognizer.view)
            return true
        }
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard recognizer === pan else { return true }
            guard !parent.ruler else { return true }
            return kind(x: touchStarts[ObjectIdentifier(recognizer)]?.x ?? 0, recognizer: recognizer) != nil
        }
        private func kind(x: CGFloat, recognizer: UIGestureRecognizer, held: Bool = false) -> MusicTimelineEditKind? {
            MusicTimelineInputPolicy.editKind(x: Double(x), width: Double(recognizer.view?.bounds.width ?? 0),
                selected: parent.selected, finger: touchTypes[ObjectIdentifier(recognizer)] == .direct, held: held)
        }
        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            if parent.ruler { parent.seek(recognizer.location(in: recognizer.view).x) }
            else { parent.select() }
        }
        @objc func opened(_ recognizer: UITapGestureRecognizer) { parent.open() }
        @objc func panned(_ recognizer: UIPanGestureRecognizer) {
            let point = recognizer.location(in: recognizer.view)
            if parent.ruler {
                if [.began, .changed, .ended].contains(recognizer.state) { parent.seek(point.x) }
                return
            }
            let delta = recognizer.translation(in: recognizer.view?.window)
            if recognizer.state == .began {
                activeKind = kind(x: touchStarts[ObjectIdentifier(recognizer)]?.x ?? point.x, recognizer: recognizer)
                activeRecognizer = recognizer
            }
            guard activeRecognizer === recognizer else { return }
            if let activeKind { parent.edit(activeKind, delta.x, recognizer.state) }
            if [.ended, .cancelled, .failed].contains(recognizer.state) { activeKind = nil }
        }
        @objc func held(_ recognizer: UILongPressGestureRecognizer) {
            let point = recognizer.location(in: recognizer.view?.window)
            if recognizer.state == .began {
                heldStart = point
                activeRecognizer = recognizer
                activeKind = kind(x: touchStarts[ObjectIdentifier(recognizer)]?.x ?? 0, recognizer: recognizer, held: true)
            }
            guard activeRecognizer === recognizer else { return }
            if let activeKind { parent.edit(activeKind, point.x - heldStart.x, recognizer.state) }
            if [.ended, .cancelled, .failed].contains(recognizer.state) { activeKind = nil }
        }
        func cancel() {
            if let activeKind { parent.edit(activeKind, 0, .cancelled) }
            activeKind = nil; activeRecognizer = nil
        }
    }
}

/// A second finger belongs to timeline pan/zoom, including when added after
/// the hold has begun. Cancel the edit instead of committing an accidental trim.
private final class MusicTimelineHoldGesture: UILongPressGestureRecognizer {
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        let count = event.allTouches?.filter { $0.phase != .ended && $0.phase != .cancelled }.count ?? numberOfTouches
        if count > 1 { state = state == .possible ? .failed : .cancelled }
    }
}
#endif
