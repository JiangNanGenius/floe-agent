// SPDX-License-Identifier: MPL-2.0
import XCTest
import MetalKit
import simd
@testable import FloeCAD

/// Uses the production mode transitions, viewport bridge, and camera. Actual
/// touch/Pencil UI dispatch remains a full-App acceptance step.
@MainActor
final class CADSketchNavigationTests: XCTestCase {
    private func makeDocument(_ root: URL, plane: SketchPlane) async throws -> (FloeCADDocument, Sketch) {
        let document = try await FloeCADDocument.create(at: root.appendingPathComponent("Drawing.floecad"), name: "Navigation")
        let sketch = Sketch(plane: plane, entities: [.line(id: UUID(), a: .zero, b: SIMD2(8, 5))])
        document.session.perform(AddSketchCommand(sketch: sketch, title: "Fixture"))
        return (document, sketch)
    }

    func testSketchPlaneLockRestoresPerspectiveAndOrthographicNavigation() async throws {
        let planes: [SketchPlane] = [.ground, SketchPlane(origin: SIMD3(4, 7, 9),
            xAxis: SIMD3(1, 0, 0), yAxis: simd_normalize(SIMD3(0, 1, -1)))]
        for (index, plane) in planes.enumerated() {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("CADSketchNavigation-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let (document, sketch) = try await makeDocument(root, plane: plane)
            defer { document.close() }
            let model = document.viewModel()
            let viewport = MTKView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
            let coordinator = ViewportCoordinator(viewModel: model)
            coordinator.attach(to: viewport)
            let renderer = try XCTUnwrap(coordinator.renderer, "App-host fixture requires the real Metal viewport")
            let original = TurntableCamera(target: SIMD3(3, 5, 2), distance: 39,
                azimuth: 0.72, elevation: 0.31,
                projection: index == 0 ? .perspective(fovY: 0.83) : .orthographic)
            renderer.camera = original
            model.orthographicEnabled = original.projection == .orthographic
            let sketchesBefore = document.session.document.sketches
            let undoCount = document.session.undoStack.undoCommands.count
            let cube = OrientationCube.rect(in: viewport.bounds.size)
            let cubePoint = CGPoint(x: cube.midX, y: cube.midY)
            let oldDrag = UUID()
            XCTAssertTrue(coordinator.gestureDragBegan(at: cubePoint, source: .pointer, gestureID: oldDrag))
            model.openItemSketch(sketch.id)
            let lockedCamera = renderer.camera
            coordinator.gestureDragChanged(at: CGPoint(x: cubePoint.x + 70, y: cubePoint.y + 30), gestureID: oldDrag)
            XCTAssertEqual(renderer.camera, lockedCamera, "A pre-sketch cube drag cannot keep rotating or start drawing")
            XCTAssertTrue(model.planarNavigationOnly)
            XCTAssertEqual(renderer.camera.projection, .orthographic)
            XCTAssertLessThan(coordinator.offAxisDegrees(to: plane), 0.05)
            XCTAssertFalse(renderer.showsOrientationCube)
            XCTAssertNil(coordinator.pendingCameraTarget, "Plane entry must cancel a prior 3D animation")
            let headOn = renderer.camera
            renderer.camera.navigateDrag(deltaPixels: CGSize(width: 55, height: -21),
                viewportSize: viewport.bounds.size, planar: model.planarNavigationOnly)
            renderer.camera.zoom(scale: 1.6)
            let panned = renderer.camera
            XCTAssertNotEqual(panned.target, headOn.target)
            XCTAssertNotEqual(panned.distance, headOn.distance)
            XCTAssertEqual(panned.azimuth, headOn.azimuth)
            XCTAssertEqual(panned.elevation, headOn.elevation)
            XCTAssertEqual(panned.upVector, headOn.upVector)
            let normal = SIMD3<Float>(Float(plane.normal.x), Float(plane.normal.y), Float(plane.normal.z))
            XCTAssertEqual(simd_dot(panned.target - headOn.target, normal), 0, accuracy: 0.0001)
            // Changing the tool and repeated SwiftUI updates must keep pan/zoom.
            model.mode = .sketching(sketch.id, tool: .line)
            coordinator.sceneDidChange(); coordinator.sceneDidChange()
            XCTAssertEqual(renderer.camera, panned)
            model.applyStandardView(.right)
            model.setOrthographic(false)
            coordinator.animateToStandardView(.isometric)
            coordinator.setProjection(orthographic: false)
            XCTAssertEqual(model.activeSketch?.id, sketch.id)
            XCTAssertEqual(renderer.camera.projection, .orthographic)
            XCTAssertLessThan(coordinator.offAxisDegrees(to: plane), 0.05)
            model.finishSketch()
            XCTAssertFalse(model.planarNavigationOnly)
            XCTAssertEqual(renderer.camera, original)
            XCTAssertEqual(model.orthographicEnabled, original.projection == .orthographic)
            XCTAssertTrue(renderer.showsOrientationCube)
            XCTAssertEqual(document.session.document.sketches, sketchesBefore)
            XCTAssertEqual(document.session.undoStack.undoCommands.count, undoCount)
            renderer.camera.navigateDrag(deltaPixels: CGSize(width: 30, height: 20),
                viewportSize: viewport.bounds.size, planar: model.planarNavigationOnly)
            XCTAssertNotEqual(renderer.camera.azimuth, original.azimuth)
            XCTAssertNotEqual(renderer.camera.elevation, original.elevation)
            XCTAssertEqual(renderer.camera.projection, original.projection)
        }
    }

    func testSketchLockSurvivesFullscreenAndDraftingHostStaysPlanarAfterFinish() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CADSketchHandoff-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (document, sketch) = try await makeDocument(root, plane: .ground)
        defer { document.close() }
        let model = document.viewModel()
        let presenter = ViewportCoordinator(viewModel: model)
        let presenterView = MTKView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        presenter.attach(to: presenterView)
        let renderer = try XCTUnwrap(presenter.renderer)
        let original = renderer.camera
        model.openItemSketch(sketch.id)
        renderer.camera.pan(deltaPixels: CGSize(width: 44, height: -20), viewportSize: CGSize(width: 600, height: 800))
        renderer.camera.zoom(scale: 1.4)
        let planar = renderer.camera
        let cover = ViewportCoordinator(viewModel: model)
        let coverView = MTKView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        cover.attach(to: coverView)
        cover.viewportDidEnterWindow()
        XCTAssertEqual(cover.renderer?.camera, planar)
        cover.sceneDidChange()
        XCTAssertEqual(cover.renderer?.camera, planar)
        cover.viewportDidLeaveWindow()
        XCTAssertTrue(model.cameraControl === presenter)
        XCTAssertEqual(renderer.camera, planar)
        model.finishSketch()
        XCTAssertEqual(renderer.camera, original)
        XCTAssertNil(model.cameraBeforeSketchNavigation)
        presenter.setDraftingOnly(true)
        model.openItemSketch(sketch.id)
        model.finishSketch()
        XCTAssertTrue(model.planarNavigationOnly)
        XCTAssertEqual(renderer.camera.projection, .orthographic)
        XCTAssertFalse(renderer.showsOrientationCube)
        model.setOrthographic(false)
        XCTAssertEqual(renderer.camera.projection, .orthographic)
        XCTAssertNil(model.cameraBeforeSketchNavigation, "Permanent drafting must not create a temporary 3D restore")
    }
}
