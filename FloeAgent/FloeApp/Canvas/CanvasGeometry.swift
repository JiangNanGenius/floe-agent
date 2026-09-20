// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI

/// Pure viewport math shared by touch navigation and regression tests. Keeping
/// the transform independent from gesture state prevents pinch updates from
/// drifting away from the point between the user's fingers.
/// Shared by the workspace canvas and the native mind map surface.
struct CanvasViewportTransform: Equatable {
    var scale: Double
    var pan: CGSize

    func panned(by delta: CGSize) -> Self {
        Self(
            scale: scale,
            pan: CGSize(width: pan.width + delta.width, height: pan.height + delta.height)
        )
    }

    func zoomed(
        by factor: CGFloat,
        around anchor: CGPoint,
        limits: ClosedRange<Double> = 0.3...3
    ) -> Self {
        guard scale.isFinite, scale > 0, factor.isFinite, factor > 0 else { return self }
        let nextScale = min(limits.upperBound, max(limits.lowerBound, scale * Double(factor)))
        let appliedFactor = CGFloat(nextScale / scale)
        return Self(
            scale: nextScale,
            pan: CGSize(
                width: anchor.x - (anchor.x - pan.width) * appliedFactor,
                height: anchor.y - (anchor.y - pan.height) * appliedFactor
            )
        )
    }
}

/// Keeps node movement subordinate to a live connector gesture. SwiftUI's
/// recognizer priority prevents both drags from beginning together; this
/// state guard also makes a late parent callback harmless.
/// Shared by the workspace canvas and the native mind map surface.
struct CanvasNodeGesturePolicy {
    static func allowsNodeDrag(
        isSelectMode: Bool,
        isMultiTouchNavigating: Bool,
        hasLiveConnectionDrag: Bool,
        isEditing: Bool,
        isLocked: Bool
    ) -> Bool {
        isSelectMode
            && !isMultiTouchNavigating
            && !hasLiveConnectionDrag
            && !isEditing
            && !isLocked
    }
}
#endif
