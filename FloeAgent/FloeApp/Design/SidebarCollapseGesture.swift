// FloeApp — Shared horizontal gesture for dismissible iPad sidebars.

// SPDX-License-Identifier: MPL-2.0

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

private struct SidebarCollapseGestureModifier: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    let translation = value.predictedEndTranslation
                    guard translation.width > 80,
                          abs(translation.width) > abs(translation.height) * 1.25 else { return }
                    action()
                }
        )
    }
}

extension View {
    /// Collapses a visible leading sidebar after a deliberate right swipe.
    /// Kept shared so Settings and the task shell use identical thresholds.
    func collapseSidebarOnRightSwipe(perform action: @escaping () -> Void) -> some View {
        modifier(SidebarCollapseGestureModifier(action: action))
    }
}
#endif
