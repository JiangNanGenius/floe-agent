import SwiftUI
import simd

/// Contextual resize control for an isolated four-line rectangle edge.
/// Explicit Move/Rotate remains separate from moving this edge normally.
struct SketchRectangleEdgeHandleOverlay: View {
    @Bindable var viewModel: EditorViewModel
    @State private var dragAxis: SIMD2<Double>?
    @State private var pointsPerUnit: Double = 1

    var body: some View {
        let _ = viewModel.cameraEpoch
        if !viewModel.sketchTransformActive, viewModel.editingDimension == nil,
           let geometry = viewModel.rectangleHandleGeometry,
           let sketch = viewModel.activeSketch,
           let camera = viewModel.cameraControl {
            let middle = (geometry.a + geometry.b) / 2
            let outward = geometry.normal
            if let p = camera.worldToScreenPoint(sketch.plane.toWorld(middle)),
               let q = camera.worldToScreenPoint(sketch.plane.toWorld(middle + outward)) {
                let delta = SIMD2(Double(q.x - p.x), Double(q.y - p.y))
                let length = simd_length(delta)
                if length > 1e-6 {
                    let axis = delta / length
                    ZStack {
                        Image(systemName: "arrow.left.and.right")
                            .foregroundStyle(Color(white: 0.15)).scaleEffect(1.12)
                        Image(systemName: "arrow.left.and.right").foregroundStyle(.white)
                    }
                    .font(.system(size: 28, weight: .semibold))
                    .rotationEffect(.radians(atan2(axis.y, axis.x)))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .position(x: p.x + axis.x * 30, y: p.y + axis.y * 30)
                    .accessibilityIdentifier("SketchRectangleEdgeHandle")
                    .accessibilityLabel("Resize rectangle from selected edge")
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .onChanged { value in
                            if dragAxis == nil { dragAxis = axis; pointsPerUnit = length }
                            let translation = SIMD2(Double(value.translation.width), Double(value.translation.height))
                            viewModel.updateRectangleEdgeDrag(delta: simd_dot(translation, dragAxis ?? axis) / pointsPerUnit)
                        }.onEnded { _ in
                            viewModel.endRectangleEdgeDrag()
                            dragAxis = nil
                        })
                }
            }
        }
    }
}
