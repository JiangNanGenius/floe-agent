import SwiftUI

/// Vertical performance wheel (pitch bend / modulation) with a drag surface,
/// a value indicator and full accessibility support. Binding writes flow
/// through `KeyboardPerformanceController`, which owns event emission.
struct PerformanceWheel: View {
    enum Behavior: Hashable {
        /// Returns to center on release (pitch bend).
        case springToCenter
        /// Stays where released (modulation).
        case latch
    }

    @Binding var value: Float
    var range: ClosedRange<Float>
    var behavior: Behavior

    @State private var dragStartValue: Float?

    private var span: Float { range.upperBound - range.lowerBound }

    private var fraction: CGFloat {
        guard span > 0 else { return 0 }
        return CGFloat((value - range.lowerBound) / span)
    }

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.secondary.opacity(0.18))
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.28), lineWidth: 0.5)
                // Center marker
                Rectangle()
                    .fill(Color.secondary.opacity(0.28))
                    .frame(height: 1)
                    .offset(y: height / 2)
                // Value indicator
                Capsule()
                    .fill(Color.accentColor)
                    .frame(height: 5)
                    .padding(.horizontal, 4)
                    .offset(y: height * (1 - fraction) - 2.5)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if dragStartValue == nil { dragStartValue = value }
                        guard let start = dragStartValue, height > 0 else { return }
                        let delta = Float(-gesture.translation.height / height) * span
                        value = min(range.upperBound, max(range.lowerBound, start + delta))
                    }
                    .onEnded { _ in
                        dragStartValue = nil
                        if case .springToCenter = behavior {
                            withAnimation(.easeOut(duration: 0.15)) {
                                value = (range.lowerBound + range.upperBound) / 2
                            }
                        }
                    }
            )
            .accessibilityValue(String(format: "%.2f", value))
            .accessibilityAdjustableAction { direction in
                let step = span / 20
                switch direction {
                case .increment: value = min(range.upperBound, value + step)
                case .decrement: value = max(range.lowerBound, value - step)
                default: break
                }
            }
        }
    }
}
