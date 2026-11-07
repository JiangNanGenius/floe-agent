// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit) && canImport(MetalKit)
import SwiftUI
import MetalKit
import simd

/// Analysis display values only. No editor, selection, undo or saved placement.
public nonisolated struct CADSimulationDisplay: Sendable {
    public nonisolated struct Surface: Sendable {
        public var positionsMM: [SIMD3<Float>]
        public var indices: [UInt32]
        public var color: SIMD4<Float>
        public init(positionsMM: [SIMD3<Float>], indices: [UInt32], color: SIMD4<Float>) {
            self.positionsMM = positionsMM; self.indices = indices; self.color = color
        }
    }
    public var id: UUID
    public var revision: UInt64
    public var surfaces: [Surface]
    public var legend: String?
    public init(id: UUID, revision: UInt64, surfaces: [Surface], legend: String? = nil) { self.id = id; self.revision = revision; self.surfaces = surfaces; self.legend = legend }
}

/// Reuses the CAD Metal renderer and shaders, with an independent display-only camera.
public struct CADSimulationViewport: View {
    public var display: CADSimulationDisplay
    @State private var unavailable = false
    public init(display: CADSimulationDisplay) { self.display = display }
    public var body: some View {
        Group {
            if unavailable { ContentUnavailableView("3D", systemImage: "cube.transparent", description: Text(CADViewportStartupError.message)) }
            else { SurfaceView(display: display, unavailable: $unavailable) }
        }.overlay(alignment:.bottomLeading) {
            if let legend = display.legend { Text(legend).font(.caption.monospacedDigit()).padding(8).background(.bar,in:RoundedRectangle(cornerRadius:8)).padding(8) }
        }.accessibilityIdentifier("cad.simulation.viewport")
    }
}

private struct SurfaceView: UIViewRepresentable {
    var display: CADSimulationDisplay
    @Binding var unavailable: Bool
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero)
        guard let renderContext = RenderContext() else {
            Task { @MainActor in unavailable = true }; return view
        }
        renderContext.configure(view: view)
        context.coordinator.renderer = Renderer(context: renderContext)
        context.coordinator.view = view; view.delegate = context.coordinator.renderer
        view.addGestureRecognizer(UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:))))
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:))))
        return view
    }
    func updateUIView(_ view: MTKView, context: Context) { context.coordinator.apply(display) }
    static func dismantleUIView(_ view: MTKView, coordinator: Coordinator) { view.delegate = nil; coordinator.renderer = nil }

    @MainActor final class Coordinator: NSObject {
        var renderer: Renderer?
        weak var view: MTKView?
        var identity: UUID?
        var revision: UInt64?
        var fitPending = false
        func apply(_ display: CADSimulationDisplay) {
            guard let renderer, let view, identity != display.id || revision != display.revision else { return }
            let needsFit = identity != display.id
            identity = display.id; revision = display.revision
            var scene = ViewportScene(); scene.showsGrid = false
            var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
            for surface in display.surfaces {
                guard !surface.positionsMM.isEmpty, surface.positionsMM.count <= 900_000,
                      surface.indices.count <= 900_000, surface.indices.count.isMultiple(of: 3),
                      surface.positionsMM.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }),
                      surface.indices.allSatisfy({ Int($0) < surface.positionsMM.count }) else { continue }
                var normals = Array(repeating: SIMD3<Float>.zero, count: surface.positionsMM.count)
                for i in stride(from: 0, to: surface.indices.count, by: 3) {
                    let a = Int(surface.indices[i]), b = Int(surface.indices[i+1]), c = Int(surface.indices[i+2])
                    let n = simd_cross(surface.positionsMM[b]-surface.positionsMM[a],surface.positionsMM[c]-surface.positionsMM[a])
                    normals[a] += n; normals[b] += n; normals[c] += n
                }
                normals = normals.map { simd_length_squared($0) > 1e-20 ? simd_normalize($0) : SIMD3(0,1,0) }
                for p in surface.positionsMM { lo = simd_min(lo,p); hi = simd_max(hi,p) }
                let mesh = RenderMesh(positions: surface.positionsMM, normals: normals, indices: surface.indices)
                scene.bodies.append(.init(id: BodyID(), renderMesh: mesh, edges: nil, meshRevision: display.revision,
                    modelMatrix: matrix_identity_float4x4, baseColor: surface.color, material: nil))
            }
            renderer.scene = scene
            if needsFit, lo.x.isFinite { renderer.camera.fit(boundsMin: lo, boundsMax: hi, aspect: Float(max(1,view.bounds.width)/max(1,view.bounds.height))) }
            view.setNeedsDisplay()
        }
        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            guard let view, let renderer else { return }
            let delta = gesture.translation(in: view)
            if gesture.numberOfTouches >= 2 { renderer.camera.pan(deltaPixels: CGSize(width:delta.x,height:delta.y), viewportSize:view.bounds.size) }
            else { renderer.camera.orbit(deltaPixels:CGSize(width:delta.x,height:delta.y), viewportSize:view.bounds.size) }
            gesture.setTranslation(.zero,in:view); view.setNeedsDisplay()
        }
        @objc func pinch(_ gesture: UIPinchGestureRecognizer) {
            renderer?.camera.zoom(scale:Float(gesture.scale)); gesture.scale = 1; view?.setNeedsDisplay()
        }
    }
}
#endif
