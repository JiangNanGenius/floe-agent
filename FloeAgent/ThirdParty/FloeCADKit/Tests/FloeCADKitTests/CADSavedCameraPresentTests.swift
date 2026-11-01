//
//  CADSavedCameraPresentTests.swift
//  FloeCADKitTests
//
//  X21 native runtime fixture. This hosts the PRODUCTION Present pane in a real
//  UIWindow, applies a saved orthographic/perspective view to the real
//  RealityKit stage, captures the actual pixels, exports the saved frame
//  aspect, and reopens the document to prove the selected view is restored.
//
//  Requires the App-hosted UIKit test target with a foreground UIWindowScene
//  (the same requirement as CADMaterialPresentRenderWitnessTests). Hostless
//  xctest skips with an explicit message; no render or success is fabricated.
//

import XCTest
import Foundation
import simd
#if canImport(SwiftUI) && canImport(RealityKit) && canImport(UIKit)
import SwiftUI
import UIKit
import RealityKit
@testable import FloeCAD

@MainActor
final class CADSavedCameraPresentTests: XCTestCase {
    private var documents: [FloeCADDocument] = []
    private var directories: [URL] = []
    private var stores: [CADPresentationSceneStore] = []
    private var handles: [CADPresentationHandle] = []
    private var windows: [UIWindow] = []
    private var hostings: [UIHostingController<AnyView>] = []
    private weak var previousKeyWindow: UIWindow?

    private enum FixtureError: Error {
        case stageUnavailable
    }

    override func tearDown() async throws {
        for hosting in hostings { hosting.rootView = AnyView(EmptyView()) }
        for window in windows {
            window.isHidden = true
            window.rootViewController = nil
        }
        for store in stores { store.stopObserving() }
        for handle in handles { handle.controller?.release() }
        for document in documents {
            CADPresentationCaptureRegistry.shared.unregister(document)
            document.close()
        }
        previousKeyWindow?.makeKey()
        hostings = []; windows = []; stores = []; handles = []
        documents = []
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        previousKeyWindow = nil
    }

    // MARK: - Fixtures

    private func makeDocument(name: String) async throws
    -> (document: FloeCADDocument, url: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SavedCameraPresent-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        directories.append(directory)
        let url = directory.appendingPathComponent("\(name).floecad")
        let document = try await FloeCADDocument.create(at: url, name: name)
        documents.append(document)
        let sketch = try XCTUnwrap(
            try execute(document, #"{"op":"sketch.create","args":{"name":"Plate"}}"#)["sketchID"] as? String)
        _ = try execute(document, """
        {"op":"sketch.addEntities","args":{"sketchID":"\(sketch)","entities":[{"kind":"rect","min":[0,0],"max":[80,50]}]}}
        """)
        _ = try execute(document, """
        {"op":"feature.extrude","args":{"sketchID":"\(sketch)","seedPoint":[40,25],"distance":18}}
        """)
        let saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "fixture save failed")
        return (document, url)
    }

    private func execute(_ document: FloeCADDocument,
                         _ json: String) throws -> [String: Any] {
        let outcome = document.executeJSON(Data(json.utf8))
        XCTAssertTrue(outcome.isOK, outcome.message ?? "command failed: \(json)")
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: outcome.payload) as? [String: Any])
    }

    private func savedCamera(name: String,
                             projection: CADCameraProjection,
                             frameAspect: Double,
                             from camera: CADPresentationCamera) -> CADSavedCamera {
        var pose = camera
        pose.projection = projection
        return CADSavedCamera(presentationCamera: pose, name: name,
                              frameAspect: frameAspect)
    }

    // MARK: - Mount

    private func mount(_ document: FloeCADDocument) async throws
    -> (handle: CADPresentationHandle, store: CADPresentationSceneStore,
        window: UIWindow, hosting: UIHostingController<AnyView>) {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: {
            $0.activationState == .foregroundActive
        }) else {
            throw XCTSkip("Saved-camera Present fixture requires the App-hosted "
                          + "UIKit target with a foreground window scene; "
                          + "hostless xctest has none and no render is faked.")
        }
        if previousKeyWindow == nil {
            previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        }
        let store = CADPresentationSceneStore(document: document)
        let handle = CADPresentationHandle()
        stores.append(store)
        handles.append(handle)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 512, height: 512)
        let hosting = UIHostingController(rootView: AnyView(
            CADPresentationPresentationPane(document: document, handle: handle,
                                            store: store, onEdit: {})
                .frame(width: 512, height: 512)
                .id(ObjectIdentifier(document))))
        window.rootViewController = hosting
        windows.append(window)
        hostings.append(hosting)
        window.makeKeyAndVisible()
        hosting.view.setNeedsLayout()
        hosting.view.layoutIfNeeded()

        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            if CADPresentationCaptureRegistry.shared.isActive(for: document),
               let active = CADPresentationCaptureRegistry.shared
                .activeHandle(for: document),
               active.controller?.isStageReady == true {
                try await Task.sleep(for: .milliseconds(700))
                return (handle, store, window, hosting)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Present never became active with a built stage; no image was "
                + "fabricated.")
        throw FixtureError.stageUnavailable
    }

    /// Wait until the production scene store has applied every document change
    /// and the stage is ready again. A rebuild between selecting a view and
    /// capturing would otherwise make the capture service report stale
    /// (truthfully) and turn a real regression into a flaky test.
    private func settle(_ handle: CADPresentationHandle,
                        _ store: CADPresentationSceneStore) async throws {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if handle.isReady,
               store.lastChangeCount == store.document.liveChangeCount {
                try await Task.sleep(for: .milliseconds(350))
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("the Present stage did not settle after the camera edit")
        throw FixtureError.stageUnavailable
    }

    private func unmount(_ handle: CADPresentationHandle,
                        _ store: CADPresentationSceneStore,
                        _ window: UIWindow,
                        _ hosting: UIHostingController<AnyView>,
                        document: FloeCADDocument) async {
        hosting.rootView = AnyView(EmptyView())
        try? await Task.sleep(for: .milliseconds(300))
        window.isHidden = true
        window.rootViewController = nil
        CADPresentationCaptureRegistry.shared.unregister(document)
        store.stopObserving()
        handle.controller?.release()
        if let index = handles.firstIndex(where: { $0 === handle }) {
            handles.remove(at: index)
        }
        if let index = stores.firstIndex(where: { $0 === store }) {
            stores.remove(at: index)
        }
        if let index = windows.firstIndex(where: { $0 === window }) {
            windows.remove(at: index)
        }
        if let index = hostings.firstIndex(where: { $0 === hosting }) {
            hostings.remove(at: index)
        }
    }

    // MARK: - Tests

    func testDocumentCameraSelectionUndoAndRedoMoveTheLivePresenter() async throws {
        let fixture = try await makeDocument(name: "Live camera undo")
        let mounted = try await mount(fixture.document)
        let base = try XCTUnwrap(mounted.handle.currentCamera)
        let perspective = try fixture.document.saveCamera(savedCamera(
            name: "Perspective", projection: .perspective, frameAspect: 1, from: base))
        var otherPose = base
        otherPose.azimuthRadians += 0.4
        let orthographic = try fixture.document.saveCamera(savedCamera(
            name: "Orthographic", projection: .orthographic, frameAspect: 1, from: otherPose))
        try await settle(mounted.handle, mounted.store)
        XCTAssertTrue(try XCTUnwrap(mounted.handle.currentCamera).matches(orthographic))

        // These are document commands, not toolbar calls to showCamera. The
        // production representable must reconcile undo/redo with the renderer.
        try fixture.document.selectCamera(id: perspective.id)
        try await settle(mounted.handle, mounted.store)
        XCTAssertTrue(try XCTUnwrap(mounted.handle.currentCamera).matches(perspective))
        fixture.document.session.undo()
        try await settle(mounted.handle, mounted.store)
        XCTAssertTrue(try XCTUnwrap(mounted.handle.currentCamera).matches(orthographic))
        fixture.document.session.redo()
        try await settle(mounted.handle, mounted.store)
        XCTAssertTrue(try XCTUnwrap(mounted.handle.currentCamera).matches(perspective))

        var temporary = perspective.presentationCamera
        temporary.azimuthRadians += 0.25
        mounted.handle.showCamera(temporary)
        _ = try fixture.document.renameCamera(id: perspective.id, to: "Renamed")
        try await settle(mounted.handle, mounted.store)
        XCTAssertEqual(mounted.handle.currentCamera, temporary,
                       "renaming a bookmark must not reset a temporary orbit")
        await unmount(mounted.handle, mounted.store, mounted.window, mounted.hosting,
                      document: fixture.document)
    }

    func testRealityKitOrthographicScaleMatchesTheActualPerspectivePixelFootprint() async throws {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(scenes.first { $0.activationState == .foregroundActive },
                                 "This witness requires the real App-hosted foreground scene")
        if previousKeyWindow == nil { previousKeyWindow = scene.windows.first { $0.isKeyWindow } }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 512, height: 512)
        let host = UIViewController()
        let view = ARView(frame: window.bounds, cameraMode: .nonAR,
                          automaticallyConfigureSession: false)
        view.environment.background = .color(.black)
        host.view = view
        window.rootViewController = host
        windows.append(window)
        window.makeKeyAndVisible()
        view.layoutIfNeeded()

        // A known 100 x 50 mm rectangle exactly on the target plane. This
        // tests rendered pixels against geometry, not the assigned scale
        // property or another copy of the production projection calculation.
        let anchor = AnchorEntity(world: .zero)
        let plane = ModelEntity(mesh: .generatePlane(width: 0.1, height: 0.05),
                                materials: [UnlitMaterial(color: .red)])
        plane.position = SIMD3(0, 0, -0.2)
        let entity = Entity()
        anchor.addChild(plane)
        anchor.addChild(entity)
        view.scene.addAnchor(anchor)
        var camera = CADPresentationCamera(target: .zero, distance: 0.2,
                                            azimuthRadians: 0, elevationRadians: 0,
                                            fovYDegrees: 60)
        entity.components.set(camera.perspectiveCameraComponent)
        try await Task.sleep(for: .milliseconds(700))
        let perspectiveImage = try await actualSnapshot(view)
        let perspective = try redFootprint(perspectiveImage)
        let expectedWidth = Double(perspective.height) * 0.1 / (2 * 0.2 * tan(Double.pi / 6))
        XCTAssertEqual(Double(perspective.bounds.width), expectedWidth,
                       accuracy: max(4, expectedWidth * 0.03))

        entity.components.remove(PerspectiveCameraComponent.self)
        camera.projection = .orthographic
        entity.components.set(camera.orthographicCameraComponent)
        try await Task.sleep(for: .milliseconds(400))
        let orthographicImage = try await actualSnapshot(view)
        let orthographic = try redFootprint(orthographicImage)
        XCTAssertEqual(Double(orthographic.bounds.width), expectedWidth,
                       accuracy: max(4, expectedWidth * 0.03),
                       "orthographic framing must preserve the actual target-plane size")
        XCTAssertEqual(Double(orthographic.bounds.height), expectedWidth / 2,
                       accuracy: max(4, expectedWidth * 0.03))
        for (name, image) in [("Perspective target plane", perspectiveImage),
                              ("Orthographic target plane", orthographicImage)] {
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let metrics: [String: Any] = [
            "imageHeight": perspective.height, "expectedPlaneWidth": expectedWidth,
            "perspectiveWidth": perspective.bounds.width,
            "orthographicWidth": orthographic.bounds.width,
            "orthographicHeight": orthographic.bounds.height,
        ]
        let attachment = XCTAttachment(data: try JSONSerialization.data(
            withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys]),
            uniformTypeIdentifier: "public.json")
        attachment.name = "Actual projection pixel footprint"
        attachment.lifetime = .keepAlways
        add(attachment)
        view.scene.anchors.removeAll()
        window.isHidden = true
        window.rootViewController = nil
    }

    func testLivePresenterRendersAndReportsTheSavedOrthographicView() async throws {
        let fixture = try await makeDocument(name: "Ortho live")
        let mounted = try await mount(fixture.document)
        let handle = mounted.handle
        let base = try XCTUnwrap(handle.currentCamera)

        let bookmark = savedCamera(name: "Board plan", projection: .orthographic,
                                   frameAspect: 4.0 / 3, from: base)
        let stored = try fixture.document.saveCamera(bookmark)
        handle.showCamera(stored.presentationCamera)
        try await settle(handle, mounted.store)

        XCTAssertEqual(handle.currentCamera?.projection, .orthographic)
        let capture = try await fixture.document.capturePresentedPNG()
        let presented = try XCTUnwrap(capture)
        XCTAssertEqual(presented.projection, "orthographic")
        XCTAssertEqual(presented.cameraName, "Board plan")
        XCTAssertEqual(presented.matchesSavedCamera, true)
        XCTAssertTrue(presented.note.contains("Board plan"))
        XCTAssertEqual(presented.pngData.prefix(2), Data([0x89, 0x50]))

        // A LIVE projection toggle is temporary and must not touch the view.
        let settingsBefore = fixture.document.session.document.sceneSettingsData
        handle.setProjection(.perspective)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(handle.currentCamera?.projection, .perspective)
        XCTAssertEqual(fixture.document.session.document.sceneSettingsData,
                       settingsBefore,
                       "a temporary projection change must not overwrite the saved view")
        XCTAssertEqual(fixture.document.activeSavedCamera?.projection,
                       .orthographic)

        let perspectiveCapture = try XCTUnwrap(
            try await fixture.document.capturePresentedPNG())
        XCTAssertEqual(perspectiveCapture.projection, "perspective")
        XCTAssertEqual(perspectiveCapture.matchesSavedCamera, false)
        XCTAssertNotEqual(perspectiveCapture.pngData, presented.pngData,
                          "the orthographic and perspective renders must differ")

        await unmount(handle, mounted.store, mounted.window, mounted.hosting,
                      document: fixture.document)
    }

    func testFramedStillUsesSavedAspectAndRestoresTheLiveCamera() async throws {
        let fixture = try await makeDocument(name: "Framed still")
        let mounted = try await mount(fixture.document)
        let handle = mounted.handle
        let base = try XCTUnwrap(handle.currentCamera)

        let bookmark = savedCamera(name: "Wide board", projection: .perspective,
                                   frameAspect: 16.0 / 9, from: base)
        let stored = try fixture.document.saveCamera(bookmark)
        handle.showCamera(stored.presentationCamera)
        try await settle(handle, mounted.store)

        let liveBefore = try XCTUnwrap(handle.currentCamera)
        let service = CADPresentationSnapshotService()
        let snapshot = try await service.capture(
            handle: handle, document: fixture.document, targetWidth: 1_024,
            savedCamera: stored)

        XCTAssertEqual(snapshot.width, 1_024)
        XCTAssertEqual(snapshot.height, 576)
        XCTAssertEqual(snapshot.revision, fixture.document.revision)
        XCTAssertEqual(snapshot.pngData.prefix(2), Data([0x89, 0x50]))
        XCTAssertTrue(snapshot.note.contains("Wide board"))
        XCTAssertTrue(snapshot.note.contains("perspective"))

        let after = try XCTUnwrap(handle.currentCamera)
        XCTAssertEqual(after.projection, liveBefore.projection)
        XCTAssertEqual(after.distance, liveBefore.distance, accuracy: 1e-5)
        XCTAssertEqual(after.azimuthRadians, liveBefore.azimuthRadians,
                       accuracy: 1e-5)
        XCTAssertEqual(after.elevationRadians, liveBefore.elevationRadians,
                       accuracy: 1e-5)
        XCTAssertEqual(after.target, liveBefore.target)
        XCTAssertEqual(fixture.document.activeSavedCamera?.id, stored.id,
                       "a framed export must not select or rewrite a view")

        // The PNG itself is the requested frame, not the 512x512 viewport.
        let pixels = try XCTUnwrap(Self.pngPixelSize(snapshot.pngData))
        XCTAssertEqual(pixels.width, 1_024)
        XCTAssertEqual(pixels.height, 576)

        await unmount(handle, mounted.store, mounted.window, mounted.hosting,
                      document: fixture.document)
    }

    func testReopenRestoresTheSelectedProjectionAndFraming() async throws {
        let fixture = try await makeDocument(name: "Reopen view")
        let first = try await mount(fixture.document)
        let base = try XCTUnwrap(first.handle.currentCamera)
        let bookmark = savedCamera(name: "Reopen check",
                                   projection: .orthographic,
                                   frameAspect: 1, from: base)
        let stored = try fixture.document.saveCamera(bookmark)
        try fixture.document.selectCamera(id: stored.id)
        let save = await fixture.document.save()
        XCTAssertTrue(save.succeeded, save.error ?? "save failed")

        await unmount(first.handle, first.store, first.window, first.hosting,
                      document: fixture.document)
        fixture.document.close()
        if let index = documents.firstIndex(where: { $0 === fixture.document }) {
            documents.remove(at: index)
        }

        let reopened = try await FloeCADDocument.open(at: fixture.url)
        documents.append(reopened)
        let second = try await mount(reopened)
        let restored = try XCTUnwrap(second.handle.currentCamera)
        XCTAssertEqual(restored.projection, .orthographic)
        XCTAssertTrue(restored.matches(stored),
                      "reopening must restore the selected saved view's exact pose and framing")

        let capture = try XCTUnwrap(
            try await reopened.capturePresentedPNG())
        XCTAssertEqual(capture.projection, "orthographic")
        XCTAssertEqual(capture.cameraName, "Reopen check")
        XCTAssertEqual(capture.matchesSavedCamera, true)

        await unmount(second.handle, second.store, second.window, second.hosting,
                      document: reopened)
    }

    // MARK: - Helpers

    private func actualSnapshot(_ view: ARView) async throws -> UIImage {
        let image: UIImage? = await withCheckedContinuation { continuation in
            view.snapshot(saveToHDR: false) { continuation.resume(returning: $0) }
        }
        return try XCTUnwrap(image, "RealityKit must return a real render")
    }

    private func redFootprint(_ image: UIImage) throws -> (height: Int, bounds: CGRect) {
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress,
                width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                if pixels[index] > 170 && pixels[index + 1] < 90 && pixels[index + 2] < 90 {
                    minX = min(minX, x); minY = min(minY, y)
                    maxX = max(maxX, x); maxY = max(maxY, y)
                }
            }
        }
        XCTAssertGreaterThan(maxX, minX, "the target plane must actually render")
        XCTAssertGreaterThan(maxY, minY)
        return (height, CGRect(x: minX, y: minY,
                               width: max(0, maxX - minX + 1),
                               height: max(0, maxY - minY + 1)))
    }

    private static func pngPixelSize(_ data: Data) -> (width: Int, height: Int)? {
        guard let image = UIImage(data: data) else { return nil }
        return (Int(image.size.width * image.scale),
                Int(image.size.height * image.scale))
    }
}
#endif
