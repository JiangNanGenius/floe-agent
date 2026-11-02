//
//  CADViewportHandoffTests.swift
//  FloeCADKitTests
//
//  T7W regression for the reported fullscreen camera/context defect: the
//  fullscreen cover of the SAME workbench used to build a second
//  `ViewportCoordinator` that (a) fitted ITS OWN fresh camera to the scene, so
//  entering fullscreen re-framed the model to the default diagonal view, and
//  (b) replaced the shared `cameraControl`/provider bindings and then kept them
//  after dismissal, so the visible presenter's orientation-cube labels read the
//  cover's detached default camera while the presenter still showed the user's
//  Front view.
//
//  The fix keeps every live viewport's own camera but hands the shared
//  bindings between them: the newest on-screen appearance continues from the
//  camera the previous visible viewport showed, adopts it without any opening
//  fit, and a dismissal copies the fullscreen camera back to the presenter.
//  These tests pin that contract:
//    * fullscreen starts exactly at the presenter's camera (no re-fit),
//    * a fullscreen camera change returns to the presenter,
//    * camera commands target whichever viewport is actually visible,
//    * the first-open fit and the explicit Fit command still work.
//
//  SPDX-License-Identifier: MPL-2.0
//

import Metal
import MetalKit
import XCTest
import simd
import Euclid
@testable import FloeCAD

@MainActor
final class CADViewportHandoffTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable in this environment.")
        }
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeCADHandoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    @discardableResult
    private func addCube(_ document: FloeCADDocument, name: String = "C") -> Body {
        let body = Body(name: name, transform: Transform3D.identity, primitive: nil,
                        euclidMesh: .cube(center: Vector(0, 0, 0), size: Vector(10, 10, 10)),
                        revision: 1)
        document.session.perform(AddBodyCommand(body: body, title: "Test \(name)"))
        return body
    }

    private func makeDocument(_ name: String) async throws -> FloeCADDocument {
        try await FloeCADDocument.create(at: workDir.appendingPathComponent("\(name).floecad"),
                                         name: name)
    }

    /// The reported sequence: presenter on Front, fullscreen must start there,
    /// fullscreen camera changes must come back, and the shared bindings must
    /// end on the visible presenter.
    func testUnattachedCoordinatorCannotStealOrClearTheLiveCameraBinding() async throws {
        let document = try await makeDocument("Unattached owner")
        defer { document.close() }
        addCube(document)
        let model = document.viewModel()
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let visible = ViewportCoordinator(viewModel: model)
        visible.attach(to: view)
        visible.viewportDidEnterWindow()
        XCTAssertTrue(model.cameraControl === visible)
        do {
            let unused = ViewportCoordinator(viewModel: model)
            XCTAssertNil(unused.renderer)
            XCTAssertTrue(model.cameraControl === visible,
                "Creating a SwiftUI coordinator without a view cannot claim the shared camera")
            model.cameraControl?.animateToStandardView(.front)
            XCTAssertNotNil(visible.pendingCameraTarget)
            XCTAssertNil(unused.pendingCameraTarget)
        }
        XCTAssertTrue(model.cameraControl === visible,
            "Deallocating an unused coordinator must not clear a weak shared binding")
        XCTAssertNotNil(model.cameraControl?.worldToScreenPoint(.zero))
    }

    func testReplacedUIViewKeepsRendererCameraAndOnlyOneSetOfGestures() async throws {
        let document = try await makeDocument("Replacement")
        defer { document.close() }
        addCube(document)
        let model = document.viewModel()
        let coordinator = ViewportCoordinator(viewModel: model)
        let sizing = CADViewportMTKView(frame: .zero)
        sizing.coordinator = coordinator
        coordinator.attach(to: sizing)
        let renderer = try XCTUnwrap(coordinator.renderer)
        renderer.camera.distance = 77
        renderer.camera.target = SIMD3(1, 2, 3)
        let camera = renderer.camera
        let originalGestureCount = sizing.gestureRecognizers?.count
        // UIPencilInteraction adds a second UIHoverGestureRecognizer on this
        // SDK. Its public class is the same as ours. Verify our named
        // seven concrete recognizers, then compare the full before/after
        // count to catch duplication without counting Apple's private input.
        let originalOwned = sizing.gestureRecognizers?.filter {
            $0.name?.hasPrefix("FloeCAD.viewport.") == true
        } ?? []
        XCTAssertEqual(originalOwned.count, 7)
        XCTAssertEqual(Set(originalOwned.compactMap(\.name)), Set(
            ["orbit", "pan", "pinch", "doubleTap", "tap", "longPress", "hover"]
                .map { "FloeCAD.viewport." + $0 }))
        let expected: [(UIGestureRecognizer.Type, Int)] = [
            (UIPanGestureRecognizer.self, 2), (UIPinchGestureRecognizer.self, 1),
            (UITapGestureRecognizer.self, 2), (UILongPressGestureRecognizer.self, 1),
            (UIHoverGestureRecognizer.self, 1)]
        for (kind, count) in expected {
            XCTAssertEqual(originalOwned.filter {
                ObjectIdentifier(type(of: $0)) == ObjectIdentifier(kind)
            }.count, count, String(describing: kind))
        }

        let replacement = CADViewportMTKView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        replacement.coordinator = coordinator
        coordinator.updateViewport(to: replacement)
        XCTAssertTrue(coordinator.renderer === renderer)
        XCTAssertTrue(replacement.delegate === renderer)
        XCTAssertNil(sizing.delegate)
        XCTAssertTrue(sizing.gestureRecognizers?.isEmpty ?? true)
        XCTAssertFalse(sizing.interactions.contains { $0 is UIPencilInteraction })
        XCTAssertEqual(renderer.camera, camera)
        XCTAssertNotNil(model.cameraControl?.worldToScreenPoint(.zero))

        // Repeated updates do not duplicate input; a dismantle delivered for
        // the old UIView cannot hand off or reset the active renderer.
        coordinator.updateViewport(to: replacement)
        ViewportView.dismantleUIView(sizing, coordinator: coordinator)
        XCTAssertTrue(model.cameraControl === coordinator)
        XCTAssertEqual(replacement.gestureRecognizers?.count, originalGestureCount)
        XCTAssertEqual(replacement.gestureRecognizers?.filter {
            $0.name?.hasPrefix("FloeCAD.viewport.") == true
        }.count, 7)
        XCTAssertEqual(replacement.interactions.filter { $0 is UIPencilInteraction }.count, 1)
        XCTAssertEqual(renderer.camera, camera)

        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            return XCTFail("App test host must provide a window scene")
        }
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        controller.view.addSubview(replacement)
        XCTAssertNotNil(replacement.window)

        let unusedMeasurement = CADViewportMTKView(frame: .zero)
        coordinator.attach(to: unusedMeasurement)
        coordinator.updateViewport(to: unusedMeasurement)
        XCTAssertTrue(replacement.delegate === renderer,
            "A detached measurement cannot displace the mounted view")
        XCTAssertNil(unusedMeasurement.delegate)
        XCTAssertEqual(renderer.camera, camera)
        XCTAssertNotNil(model.cameraControl?.worldToScreenPoint(.zero))
    }

    func testFullscreenStartsAtPresenterCameraAndHandsBack() async throws {
        let document = try await makeDocument("Handoff")
        defer { document.close() }
        addCube(document)
        let model = document.viewModel()

        // Presenter: attached, on screen, user moved to the Front view.
        let presenterView = MTKView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let presenter = ViewportCoordinator(viewModel: model)
        presenter.attach(to: presenterView)
        presenter.viewportDidEnterWindow()
        XCTAssertTrue(model.cameraControl === presenter)
        var front = try XCTUnwrap(presenter.renderer).camera
        front.azimuth = 0
        front.elevation = 0
        front.distance = 44
        presenter.renderer?.camera = front
        let presentedCamera = try XCTUnwrap(presenter.renderer?.camera)

        // The fullscreen cover: a second LIVE viewport for the SAME document.
        let coverView = MTKView(frame: CGRect(x: 0, y: 0, width: 400, height: 700))
        let cover = ViewportCoordinator(viewModel: model)
        cover.attach(to: coverView)
        cover.viewportDidEnterWindow()

        // 1. Fullscreen starts exactly where the presenter was — no re-fit and
        //    no opening fit owed on the cover.
        XCTAssertEqual(cover.renderer?.camera, presentedCamera,
                       "fullscreen must continue the presenter's camera")
        XCTAssertNil(cover.pendingOpeningFit,
                     "a re-presented viewport must never auto-fit its own camera")
        XCTAssertTrue(model.cameraControl === cover)

        // The visible renderer receives explicit view commands; the covered
        // presenter is not driven.
        model.cameraControl?.animateToStandardView(.right)
        let right = try XCTUnwrap(cover.pendingCameraTarget)
        XCTAssertEqual(right.azimuth, Float.pi / 2, accuracy: 1e-6)
        XCTAssertEqual(right.elevation, 0, accuracy: 1e-6)
        XCTAssertNil(presenter.pendingCameraTarget,
                     "the covered presenter must not receive view commands")

        // A fullscreen camera change (orbit + zoom).
        var fullscreen = try XCTUnwrap(cover.renderer?.camera)
        fullscreen.azimuth = 1.1
        fullscreen.distance = 25
        cover.renderer?.camera = fullscreen
        let fullscreenCamera = try XCTUnwrap(cover.renderer?.camera)

        // 2. Dismissal through the production hook: the presenter gets the
        //    camera the user last saw and the shared bindings.
        ViewportView.dismantleUIView(coverView, coordinator: cover)
        XCTAssertTrue(model.cameraControl === presenter,
                      "dismissal must rebind camera control to the visible presenter")
        XCTAssertEqual(presenter.renderer?.camera, fullscreenCamera,
                       "the fullscreen camera must return to the presenter")
        XCTAssertTrue(presenterView.delegate === presenter.renderer,
                      "the presenter's view must stay driven by its own renderer")

        // Working viewport controls afterwards, on the presenter's renderer.
        model.cameraControl?.setProjection(orthographic: true)
        XCTAssertEqual(presenter.renderer?.camera.projection, .orthographic)

        // The providers point at the presenter's live renderer again: the
        // shared thumbnail is byte-identical to the presenter's own capture.
        let shared = try XCTUnwrap(model.thumbnailProvider?())
        let presenterPNG = try XCTUnwrap(presenter.renderer?.makeThumbnailPNG())
        XCTAssertEqual(shared, presenterPNG,
                       "the shared thumbnail provider must belong to the presenter")

        // Let the view-command flight finish so its display link does not leak
        // into later tests.
        try await Task.sleep(nanoseconds: 600_000_000)
    }

    /// On a real fullScreen dismissal the presenter's view re-enters the
    /// window while the cover is still animating out: the returning presenter
    /// adopts the cover camera first, and the cover's later window exit must
    /// not steal the bindings back.
    func testPresenterReturningAdoptsCoverCameraAndKeepsOwnership() async throws {
        let document = try await makeDocument("Reenter")
        defer { document.close() }
        addCube(document)
        let model = document.viewModel()

        let presenterView = MTKView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        let presenter = ViewportCoordinator(viewModel: model)
        presenter.attach(to: presenterView)
        presenter.viewportDidEnterWindow()

        let coverView = MTKView(frame: CGRect(x: 0, y: 0, width: 300, height: 600))
        let cover = ViewportCoordinator(viewModel: model)
        cover.attach(to: coverView)
        cover.viewportDidEnterWindow()
        cover.renderer?.camera.azimuth = 2.25
        cover.renderer?.camera.distance = 18
        let coverCamera = try XCTUnwrap(cover.renderer?.camera)

        // Presenter returns on screen before the cover leaves.
        presenter.viewportDidEnterWindow()
        XCTAssertTrue(model.cameraControl === presenter)
        XCTAssertEqual(presenter.renderer?.camera, coverCamera)

        // The cover's removal is a no-op for a newer active presenter.
        ViewportView.dismantleUIView(coverView, coordinator: cover)
        XCTAssertTrue(model.cameraControl === presenter)
        XCTAssertEqual(presenter.renderer?.camera, coverCamera)
    }

    /// The handoff must not weaken the normal first-open fit or the explicit
    /// Fit command (the presenter still gets a fitted camera on attach, and
    /// calls through `cameraControl` still reach its renderer).
    func testFirstOpenFitAndExplicitFitRemainIntact() async throws {
        let document = try await makeDocument("Fit")
        defer { document.close() }
        addCube(document)
        let model = document.viewModel()

        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 256, height: 256))
        let coordinator = ViewportCoordinator(viewModel: model)
        coordinator.attach(to: view)
        XCTAssertTrue(model.cameraControl === coordinator)

        // First open: the automatic fit is owed and already applied.
        let opening = try XCTUnwrap(coordinator.pendingOpeningFit)
        XCTAssertEqual(coordinator.renderer?.camera, opening,
                       "the first-open fit must be the live camera until the user moves it")
        let bounds = try XCTUnwrap(coordinator.renderer?.scene.worldBounds)
        var expected = TurntableCamera()
        expected.fit(boundsMin: bounds.min, boundsMax: bounds.max)
        XCTAssertEqual(opening, expected, "first open must frame the scene, not the default diagonal")

        // Explicit Zoom to Fit still flies the CURRENT camera to the scene.
        var moved = try XCTUnwrap(coordinator.renderer?.camera)
        moved.distance = 999
        coordinator.renderer?.camera = moved
        var movedExpected = moved
        movedExpected.fit(boundsMin: bounds.min, boundsMax: bounds.max)
        model.cameraControl?.fitScene()
        XCTAssertEqual(coordinator.pendingCameraTarget, movedExpected,
                       "explicit Fit must reach the live renderer camera")

        // Let the fit flight finish before the test tears the document down.
        try await Task.sleep(nanoseconds: 600_000_000)
    }

    /// A migrated legacy scene still opens on its authored camera (the
    /// presenter-continuation branch must not shadow the saved-scene camera
    /// when there is no presenter), and fullscreen continues on it.
    func testLegacySceneAuthoredCameraAppliesAndContinuesInFullscreen() async throws {
        let document = try await makeDocument("Legacy")
        defer { document.close() }
        let legacy = CADLegacyScene(
            objects: [CADLegacyScene.Object(
                id: UUID(), name: "Box", kind: .box,
                positionX: 0, positionY: 0, positionZ: 0,
                rotationX: 0, rotationY: 0, rotationZ: 0,
                scaleX: 1, scaleY: 1, scaleZ: 1,
                colorHex: "#3366CC", roughness: 0.35, metallic: false, isHidden: false)],
            camera: CADLegacyScene.Camera(
                yawDegrees: 38, pitchDegrees: -22, distance: 6.5,
                targetX: 0, targetY: 0, targetZ: 0, fieldOfViewDegrees: 48),
            lighting: CADLegacyScene.Lighting(
                keyIntensity: 28_000, fillIntensity: 7_000, castsShadows: true),
            background: .studio,
            showsGrid: true,
            sourceDigest: String(repeating: "a", count: 64),
            sourceSceneJSON: Data(#"{"objects":[]}"#.utf8))
        _ = try document.importLegacyScene(legacy)
        let model = document.viewModel()
        let authored = try XCTUnwrap(model.savedSceneCamera)

        let presenterView = MTKView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let presenter = ViewportCoordinator(viewModel: model)
        presenter.attach(to: presenterView)
        XCTAssertEqual(presenter.renderer?.camera, authored,
                       "a migrated scene must keep its authored camera")
        XCTAssertNil(presenter.pendingOpeningFit,
                     "an authored camera must never be re-fitted on resize")

        let coverView = MTKView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let cover = ViewportCoordinator(viewModel: model)
        cover.attach(to: coverView)
        XCTAssertEqual(cover.renderer?.camera, authored,
                       "fullscreen must continue the authored camera")
        XCTAssertNil(cover.pendingOpeningFit)
    }
}
