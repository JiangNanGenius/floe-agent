// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreGraphics
import simd
import Testing
@testable import FloeCAD

@Suite("Planar CAD navigation", .serialized)
@MainActor struct CAD2DNavigationTests {
    private final class Camera: ViewportCameraControl {
        var standards: [StandardView] = []
        var planes: [SketchPlane] = []
        var projections: [Bool] = []
        var worldUnitsPerPoint: Double { 1 }
        func fitScene() {}
        func fitTo(bounds: (min: SIMD3<Float>, max: SIMD3<Float>)) {}
        func moveCameraHeadOn(to plane: SketchPlane) { planes.append(plane) }
        func animateToStandardView(_ view: StandardView) { standards.append(view) }
        func setProjection(orthographic: Bool) { projections.append(orthographic) }
        func worldToScreenPoint(_ world: SIMD3<Double>) -> CGPoint? { nil }
        func offAxisDegrees(to plane: SketchPlane) -> Double { 0 }
        func orientationCubeLabels() -> [OrientationCube.FaceLabel] { [] }
        func gizmoWorldScale(at origin: SIMD3<Float>) -> Float { 1 }
    }

    @Test func emptySpaceDragPansTheRealPlanarCameraAndZoomKeepsThePlane() {
        var camera = TurntableCamera(target: .zero, distance: 30, azimuth: 0, elevation: 0, projection: .orthographic)
        let before = camera
        camera.navigateDrag(deltaPixels: CGSize(width: 70, height: -35), viewportSize: CGSize(width: 600, height: 800), planar: true)
        #expect(camera.target != before.target)
        #expect(camera.target.z == 0)
        #expect(camera.azimuth == before.azimuth && camera.elevation == before.elevation)
        #expect(camera.upVector == before.upVector && camera.projection == .orthographic)
        let moved = camera.target
        camera.zoom(scale: 1.5)
        #expect(camera.distance < before.distance && camera.target == moved)
        #expect(camera.azimuth == before.azimuth && camera.elevation == before.elevation)
        var spatial = before
        spatial.navigateDrag(deltaPixels: CGSize(width: 70, height: -35), viewportSize: CGSize(width: 600, height: 800), planar: false)
        #expect(spatial.target == before.target)
        #expect(spatial.azimuth != before.azimuth && spatial.elevation != before.elevation)
    }

    @Test func draftingCommandsKeepTheActualSketchOpenAndCannotSwitchToPerspective() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cad-2d-navigation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = try await FloeCADDocument.create(at: root.appendingPathComponent("Drawing.floecad"), name: "Actual 2D drawing")
        defer { document.close() }
        document.activate2DWorkspace()
        let model = document.viewModel(), camera = Camera()
        let sketch = try #require(model.activeSketch?.id)
        let changes = document.exchangeChangeCount
        model.cameraControl = camera
        model.applyStandardView(.right)
        model.setOrthographic(false)
        #expect(model.planarNavigationOnly)
        #expect(model.activeSketch?.id == sketch)
        #expect(camera.standards.isEmpty && !camera.planes.isEmpty)
        #expect(model.orthographicEnabled && camera.projections.last == true)
        #expect(document.exchangeChangeCount == changes)
        model.planarNavigationOnly = false
        #expect(model.planarNavigationOnly && model.activeSketch?.id == sketch)
        model.finishSketch()
        #expect(!model.planarNavigationOnly)
        model.applyStandardView(.right)
        #expect(camera.standards == [.right])
    }
}
