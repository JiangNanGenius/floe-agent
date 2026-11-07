// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit) && canImport(MetalKit)
import SwiftUI
import MetalKit
import simd

public nonisolated struct CADSimulationCamera: Sendable {
    public var positionMeters:SIMD3<Double>
    public var rotation:SIMD4<Double>
    public var verticalFOVDegrees:Double
    public var orthographicHeightMeters:Double?
    public init(positionMeters:SIMD3<Double>,rotation:SIMD4<Double>,verticalFOVDegrees:Double = 60,orthographicHeightMeters:Double? = nil) {
        self.positionMeters = positionMeters; self.rotation = rotation; self.verticalFOVDegrees = verticalFOVDegrees; self.orthographicHeightMeters = orthographicHeightMeters
    }
}

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
    public var camera:CADSimulationCamera?
    public init(id: UUID, revision: UInt64, surfaces: [Surface], legend: String? = nil,camera:CADSimulationCamera? = nil) { self.id = id; self.revision = revision; self.surfaces = surfaces; self.legend = legend; self.camera = camera }
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
            guard let snapshot = try? CADSimulationRenderScene.make(display) else { return }
            renderer.scene = snapshot.scene
            if needsFit, snapshot.lo.x.isFinite { renderer.camera.fit(boundsMin:snapshot.lo,boundsMax:snapshot.hi,aspect:Float(max(1,view.bounds.width)/max(1,view.bounds.height))) }
            if let camera = display.camera { try? CADSimulationRenderScene.applyCamera(camera,to:&renderer.camera) }
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
