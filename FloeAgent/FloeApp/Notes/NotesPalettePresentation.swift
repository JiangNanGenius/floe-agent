// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI

extension View {
    func notesPencilPalette<Palette: View>(
        isPresented: Binding<Bool>, point: CGPoint,
        @ViewBuilder content: @escaping () -> Palette
    ) -> some View {
        // Anchor directly to the visible canvas. A positioned 1-point overlay
        // expands its layout bounds and can put the popover above the window.
        popover(isPresented: isPresented,
                attachmentAnchor: .point(UnitPoint(
                    x: point.x.isFinite ? min(0.95, max(0.05, point.x)) : 0.5,
                    y: point.y.isFinite ? min(0.95, max(0.05, point.y)) : 0.15
                )), arrowEdge: nil) {
            content().presentationCompactAdaptation(.popover)
        }
    }
}

// The label owns the hit region, not an outside layout-only frame. Keep
// identifiers on individual controls; a stack identifier masks its children.
struct NotesToolbarButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.55 : 1) : 0.35)
    }
}
#endif
