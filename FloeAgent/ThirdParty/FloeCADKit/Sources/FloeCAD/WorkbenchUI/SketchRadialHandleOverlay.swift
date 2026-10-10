import SwiftUI
import simd

/// A single selected circle or arc exposes radial sizing. Move/Rotate is explicit.
struct SketchRadialHandleOverlay: View {
    @Bindable var viewModel: EditorViewModel
    @State private var dragAxis: SIMD2<Double>?
    @State private var pointsPerUnit: Double = 1

    var body: some View {
        let _ = viewModel.cameraEpoch
        if !viewModel.sketchTransformActive, viewModel.editingDimension == nil,
           let entity = viewModel.selectedSingleRadialEntity,
           let geometry = radialGeometry(entity),
           let plane = viewModel.activeSketch?.plane,
           let camera = viewModel.cameraControl,
           let c = camera.worldToScreenPoint(plane.toWorld(geometry.center)) {
            let radius = geometry.radius
            let rim = geometry.center + SIMD2(cos(geometry.angle), sin(geometry.angle)) * radius
            if let p = camera.worldToScreenPoint(plane.toWorld(rim)) {
                let delta = SIMD2(Double(p.x - c.x), Double(p.y - c.y))
                let length = simd_length(delta)
                if length > 1 {
                    let axis = delta / length
                    let anchor = CGPoint(x: p.x + axis.x * 30, y: p.y + axis.y * 30)
                    ZStack {
                        Image(systemName: "arrow.left.and.right")
                            .foregroundStyle(Color(white: 0.15)).scaleEffect(1.12)
                        Image(systemName: "arrow.left.and.right").foregroundStyle(.white)
                    }
                    .font(.system(size: 28, weight: .semibold))
                    .rotationEffect(.radians(atan2(axis.y, axis.x)))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .position(anchor)
                    .accessibilityIdentifier(geometry.isCircle ? "SketchCircleRadiusHandle" : "SketchArcRadiusHandle")
                    .accessibilityLabel(geometry.isCircle ? "Adjust circle radius" : "Adjust arc radius")
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global).onChanged { value in
                        if dragAxis == nil {
                            dragAxis = axis
                            pointsPerUnit = length / radius
                        }
                        let translation = SIMD2(Double(value.translation.width), Double(value.translation.height))
                        viewModel.updateRadialRadiusDrag(delta: simd_dot(translation, dragAxis ?? axis) / pointsPerUnit)
                    }.onEnded { _ in
                        viewModel.endRadialRadiusDrag()
                        dragAxis = nil
                    })
                }
            }
        }
    }

    private func radialGeometry(_ entity: SketchEntity) -> (center: SIMD2<Double>, radius: Double, angle: Double, isCircle: Bool)? {
        switch entity {
        case let .circle(_, center, radius):
            return (center, radius, .pi / 2, true)
        case let .arc(_, center, radius, start, end):
            return (center, radius, start + SketchEntity.arcSweep(startAngle: start, endAngle: end) / 2, false)
        default: return nil
        }
    }
}
