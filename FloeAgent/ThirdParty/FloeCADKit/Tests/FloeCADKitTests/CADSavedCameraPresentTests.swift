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
import AVFoundation
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

    /// Two 30 mm coloured quads on the saved front plane at ±x. The saved
    /// 16:9 60° shot at 200 mm sees ±205 mm horizontally, so both fit; a
    /// square live viewport only sees ±115 mm and clips BOTH of them. A
    /// correct framed export must show two coloured landmarks near the left
    /// and right edges; a viewport-first export shows neither.
    private func makeLandmarkDocument(name: String,
                                      leftXMM: Float,
                                      rightXMM: Float,
                                      sizeMM: Float = 30) async throws
    -> (document: FloeCADDocument, url: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SavedCameraLandmarks-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        directories.append(directory)
        let url = directory.appendingPathComponent("\(name).floecad")
        let document = try await FloeCADDocument.create(at: url, name: name)
        documents.append(document)

        func marker(xMM: Float, color: SIMD4<Double>, title: String) -> Body {
            let half = sizeMM / 2
            let positions = [
                SIMD3<Float>(xMM - half, -half, 0),
                SIMD3<Float>(xMM + half, -half, 0),
                SIMD3<Float>(xMM + half, half, 0),
                SIMD3<Float>(xMM - half, half, 0),
            ]
            let normals = Array(repeating: SIMD3<Float>(0, 0, 1), count: 4)
            let indices: [UInt32] = [0, 1, 2, 0, 2, 3]
            var body = Body(id: BodyID(), name: title, transform: .identity,
                            primitive: nil,
                            render: RenderMesh(positions: positions,
                                               normals: normals,
                                               indices: indices),
                            revision: 1)
            body.material = BodyMaterialSpec(
                baseColor: color, metallic: 0, roughness: 1,
                emissive: SIMD3<Double>(color.x, color.y, color.z),
                emissiveStrength: 1.5)
            return body
        }
        document.session.perform(AddBodyCommand(
            body: marker(xMM: leftXMM,
                         color: SIMD4(0.9, 0.05, 0.05, 1),
                         title: "Left red marker"),
            title: "Add left marker"))
        document.session.perform(AddBodyCommand(
            body: marker(xMM: rightXMM,
                         color: SIMD4(0.05, 0.05, 0.95, 1),
                         title: "Right blue marker"),
            title: "Add right marker"))
        let saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "fixture save failed")
        return (document, url)
    }

    /// A straight-ahead saved shot in document millimetres. FOV and frame
    /// aspect are the properties under test; the pose is exact so both
    /// landmarks land on the target plane.
    private func frontCamera(name: String,
                             distanceMM: Double = 200,
                             fovYDegrees: Double = 60,
                             frameAspect: Double,
                             projection: CADCameraProjection) -> CADSavedCamera {
        CADSavedCamera(
            name: name,
            projection: projection,
            targetMM: .zero,
            distanceMM: distanceMM,
            azimuthRadians: 0,
            elevationRadians: 0,
            fovYDegrees: fovYDegrees,
            frameAspect: frameAspect,
            createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
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

    private func mount(_ document: FloeCADDocument,
                       size: CGSize = CGSize(width: 512, height: 512)) async throws
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
        window.frame = CGRect(origin: .zero, size: size)
        let hosting = UIHostingController(rootView: AnyView(
            CADPresentationPresentationPane(document: document, handle: handle,
                                            store: store, onEdit: {})
                .frame(width: size.width, height: size.height)
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

        let capturedPerspective = try await fixture.document.capturePresentedPNG()
        let perspectiveCapture = try XCTUnwrap(capturedPerspective)
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

        let reopenedCapture = try await reopened.capturePresentedPNG()
        let capture = try XCTUnwrap(reopenedCapture)
        XCTAssertEqual(capture.projection, "orthographic")
        XCTAssertEqual(capture.cameraName, "Reopen check")
        XCTAssertEqual(capture.matchesSavedCamera, true)

        await unmount(second.handle, second.store, second.window, second.hosting,
                      document: reopened)
    }

    // MARK: - Saved-shot framing (X21-R2)

    func testFramedPerspectiveStillKeepsBothLandmarksOfAWideShot() async throws {
        let fixture = try await makeLandmarkDocument(
            name: "Wide perspective PNG", leftXMM: -160, rightXMM: 160)
        let mounted = try await mount(fixture.document)
        let handle = mounted.handle
        let stored = try fixture.document.saveCamera(
            frontCamera(name: "Wide front", frameAspect: 16.0 / 9,
                        projection: .perspective))
        handle.showCamera(stored.presentationCamera)
        try await settle(handle, mounted.store)

        let liveBefore = try XCTUnwrap(handle.currentCamera)
        let changeBefore = fixture.document.liveChangeCount
        let settingsBefore = fixture.document.session.document.sceneSettingsData
        let undoBefore = fixture.document.session.undoStack.undoCommands.count

        let snapshot = try await CADPresentationSnapshotService().capture(
            handle: handle, document: fixture.document, targetWidth: 1_024,
            savedCamera: stored)

        XCTAssertEqual(snapshot.width, 1_024)
        XCTAssertEqual(snapshot.height, 576)
        XCTAssertEqual(Double(snapshot.width) / Double(snapshot.height),
                       16.0 / 9, accuracy: 0.002)
        let image = try XCTUnwrap(UIImage(data: snapshot.pngData),
                                  "the export must encode a real PNG")
        let landmarks = try Self.landmarks(in: image)
        Self.assertWideLandmarks(landmarks, label: "wide perspective PNG")
        guard landmarks.red.isPresent, landmarks.blue.isPresent else { return }

        let after = try XCTUnwrap(handle.currentCamera)
        XCTAssertEqual(after, liveBefore,
                       "the framed render must restore the user's live camera")
        XCTAssertEqual(fixture.document.liveChangeCount, changeBefore)
        XCTAssertEqual(fixture.document.session.document.sceneSettingsData,
                       settingsBefore)
        XCTAssertEqual(fixture.document.session.undoStack.undoCommands.count,
                       undoBefore, "an export must not add an undo step")
        XCTAssertEqual(fixture.document.activeSavedCamera?.id, stored.id)

        let attachment = XCTAttachment(image: image)
        attachment.name = "Wide perspective saved shot (16:9 from a square Present)"
        attachment.lifetime = .keepAlways
        add(attachment)
        await unmount(handle, mounted.store, mounted.window, mounted.hosting,
                      document: fixture.document)
    }

    func testFramedOrthographicStillKeepsBothLandmarksOfAWideShot() async throws {
        let fixture = try await makeLandmarkDocument(
            name: "Wide orthographic PNG", leftXMM: -160, rightXMM: 160)
        let mounted = try await mount(fixture.document)
        let handle = mounted.handle
        let stored = try fixture.document.saveCamera(
            frontCamera(name: "Wide orthographic", frameAspect: 16.0 / 9,
                        projection: .orthographic))
        handle.showCamera(stored.presentationCamera)
        try await settle(handle, mounted.store)

        let liveBefore = try XCTUnwrap(handle.currentCamera)
        XCTAssertEqual(liveBefore.projection, .orthographic)
        let snapshot = try await CADPresentationSnapshotService().capture(
            handle: handle, document: fixture.document, targetWidth: 1_024,
            savedCamera: stored)

        XCTAssertEqual(snapshot.width, 1_024)
        XCTAssertEqual(snapshot.height, 576)
        let image = try XCTUnwrap(UIImage(data: snapshot.pngData))
        let landmarks = try Self.landmarks(in: image)
        Self.assertWideLandmarks(landmarks, label: "wide orthographic PNG")
        guard landmarks.red.isPresent, landmarks.blue.isPresent else { return }
        XCTAssertEqual(try XCTUnwrap(handle.currentCamera), liveBefore,
                       "the framed render must restore the orthographic live camera")
        XCTAssertEqual(fixture.document.activeSavedCamera?.projection,
                       .orthographic)

        let attachment = XCTAttachment(image: image)
        attachment.name = "Wide orthographic saved shot (16:9 from a square Present)"
        attachment.lifetime = .keepAlways
        add(attachment)
        await unmount(handle, mounted.store, mounted.window, mounted.hosting,
                      document: fixture.document)
    }

    func testFramedWideShotKeepsBothLandmarksInAPortraitViewport() async throws {
        let fixture = try await makeLandmarkDocument(
            name: "Wide portrait viewport", leftXMM: -160, rightXMM: 160)
        let mounted = try await mount(fixture.document,
                                      size: CGSize(width: 360, height: 640))
        let handle = mounted.handle
        let viewport = try XCTUnwrap(handle.controller?.currentFrameAspect,
                                     "the live viewport must be measurable")
        XCTAssertLessThan(viewport, 0.95,
                          "fixture premise: the live viewport must be narrower "
                          + "than the saved 16:9 frame")
        let stored = try fixture.document.saveCamera(
            frontCamera(name: "Wide in portrait", frameAspect: 16.0 / 9,
                        projection: .perspective))
        handle.showCamera(stored.presentationCamera)
        try await settle(handle, mounted.store)

        let liveBefore = try XCTUnwrap(handle.currentCamera)
        let snapshot = try await CADPresentationSnapshotService().capture(
            handle: handle, document: fixture.document, targetWidth: 1_024,
            savedCamera: stored)

        XCTAssertEqual(snapshot.width, 1_024)
        XCTAssertEqual(snapshot.height, 576)
        let image = try XCTUnwrap(UIImage(data: snapshot.pngData))
        let landmarks = try Self.landmarks(in: image)
        Self.assertWideLandmarks(landmarks, label: "portrait viewport PNG")
        guard landmarks.red.isPresent, landmarks.blue.isPresent else { return }
        let after = try XCTUnwrap(handle.currentCamera)
        XCTAssertEqual(after, liveBefore)
        // The lens widened; the eye never moved. Moving the eye would change
        // perspective/parallax instead of just containing the saved shot.
        XCTAssertEqual(after.distance, liveBefore.distance, accuracy: 1e-6)
        XCTAssertEqual(after.target, liveBefore.target)

        let attachment = XCTAttachment(image: image)
        attachment.name = "Wide saved shot (16:9) from a portrait live viewport"
        attachment.lifetime = .keepAlways
        add(attachment)
        await unmount(handle, mounted.store, mounted.window, mounted.hosting,
                      document: fixture.document)
    }

    func testFramedPortraitShotKeepsBothLandmarksInASquareViewport() async throws {
        let fixture = try await makeLandmarkDocument(
            name: "Portrait saved shot", leftXMM: -45, rightXMM: 45)
        let mounted = try await mount(fixture.document)
        let handle = mounted.handle
        let stored = try fixture.document.saveCamera(
            frontCamera(name: "Portrait shot", frameAspect: 9.0 / 16,
                        projection: .perspective))
        handle.showCamera(stored.presentationCamera)
        try await settle(handle, mounted.store)

        let liveBefore = try XCTUnwrap(handle.currentCamera)
        let snapshot = try await CADPresentationSnapshotService().capture(
            handle: handle, document: fixture.document, targetWidth: 720,
            savedCamera: stored)

        XCTAssertEqual(snapshot.width, 720)
        XCTAssertEqual(snapshot.height, 1_280)
        XCTAssertEqual(Double(snapshot.width) / Double(snapshot.height),
                       9.0 / 16, accuracy: 0.002)
        let image = try XCTUnwrap(UIImage(data: snapshot.pngData))
        let landmarks = try Self.landmarks(in: image)
        Self.assertWideLandmarks(landmarks, label: "portrait saved shot PNG")
        guard landmarks.red.isPresent, landmarks.blue.isPresent else { return }
        XCTAssertEqual(try XCTUnwrap(handle.currentCamera), liveBefore)

        let attachment = XCTAttachment(image: image)
        attachment.name = "Portrait saved shot (9:16) cropped from a square Present"
        attachment.lifetime = .keepAlways
        add(attachment)
        await unmount(handle, mounted.store, mounted.window, mounted.hosting,
                      document: fixture.document)
    }

    func testFramedCaptureRefusesAnUnsupportedLensWithoutMovingTheCamera() async throws {
        let fixture = try await makeLandmarkDocument(
            name: "Unsupported lens", leftXMM: -160, rightXMM: 160)
        let mounted = try await mount(fixture.document)
        let handle = mounted.handle
        let stored = try fixture.document.saveCamera(
            frontCamera(name: "Extreme wide", fovYDegrees: 150,
                        frameAspect: 5, projection: .perspective))
        handle.showCamera(stored.presentationCamera)
        try await settle(handle, mounted.store)
        let liveBefore = try XCTUnwrap(handle.currentCamera)

        do {
            _ = try await CADPresentationSnapshotService().capture(
                handle: handle, document: fixture.document, targetWidth: 512,
                savedCamera: stored)
            XCTFail("a 5:1 150° shot cannot be contained in a square viewport "
                    + "without an unsupported transient lens")
        } catch let error as CADPresentationError {
            guard case .framingUnsupported = error else {
                XCTFail("unexpected capture error: \(error)")
                return
            }
        }
        XCTAssertEqual(try XCTUnwrap(handle.currentCamera), liveBefore,
                       "a refused export must not move the live camera")

        // The same stage still renders a supported shot afterwards.
        let supported = try fixture.document.saveCamera(
            frontCamera(name: "Supported", frameAspect: 16.0 / 9,
                        projection: .perspective))
        handle.showCamera(supported.presentationCamera)
        try await settle(handle, mounted.store)
        let snapshot = try await CADPresentationSnapshotService().capture(
            handle: handle, document: fixture.document, targetWidth: 512,
            savedCamera: supported)
        XCTAssertEqual(snapshot.width, 512)
        XCTAssertEqual(snapshot.height, 288)
        let image = try XCTUnwrap(UIImage(data: snapshot.pngData))
        let landmarks = try Self.landmarks(in: image)
        Self.assertWideLandmarks(landmarks, label: "supported after refusal")
        await unmount(handle, mounted.store, mounted.window, mounted.hosting,
                      document: fixture.document)
    }

    func testFramedCaptureRefusesWhileAVideoLeaseHoldsTheStage() async throws {
        let fixture = try await makeLandmarkDocument(
            name: "Leased stage", leftXMM: -160, rightXMM: 160)
        let mounted = try await mount(fixture.document)
        let handle = mounted.handle
        let stored = try fixture.document.saveCamera(
            frontCamera(name: "Leased shot", frameAspect: 16.0 / 9,
                        projection: .perspective))
        handle.showCamera(stored.presentationCamera)
        try await settle(handle, mounted.store)
        let liveBefore = try XCTUnwrap(handle.currentCamera)

        let controller = try XCTUnwrap(handle.controller)
        let lease = try XCTUnwrap(controller.beginAnimationLease(),
                                  "the stage must be ready for a real lease")
        defer {
            controller.endAnimationLease(lease)
            controller.clearAnimation()
        }
        do {
            _ = try await CADPresentationSnapshotService().capture(
                handle: handle, document: fixture.document, targetWidth: 512,
                savedCamera: stored)
            XCTFail("a framed still must not take a stage leased by a video export")
        } catch let error as CADPresentationError {
            guard case .renderingUnavailable = error else {
                XCTFail("unexpected capture error: \(error)")
                return
            }
        }
        XCTAssertEqual(try XCTUnwrap(handle.currentCamera), liveBefore)

        controller.endAnimationLease(lease)
        controller.clearAnimation()
        let snapshot = try await CADPresentationSnapshotService().capture(
            handle: handle, document: fixture.document, targetWidth: 512,
            savedCamera: stored)
        XCTAssertEqual(snapshot.width, 512)
        XCTAssertEqual(snapshot.height, 288)
        let image = try XCTUnwrap(UIImage(data: snapshot.pngData))
        Self.assertWideLandmarks(try Self.landmarks(in: image),
                                     label: "after the lease was released")
        await unmount(handle, mounted.store, mounted.window, mounted.hosting,
                      document: fixture.document)
    }

    func testVideoExportKeepsTheCompleteWideShotInsideASquareContainer() async throws {
        let fixture = try await makeLandmarkDocument(
            name: "Wide square video", leftXMM: -160, rightXMM: 160)
        let mounted = try await mount(fixture.document)
        let handle = mounted.handle
        let stored = try fixture.document.saveCamera(
            frontCamera(name: "Wide video shot", frameAspect: 16.0 / 9,
                        projection: .perspective))
        handle.showCamera(stored.presentationCamera)
        try await settle(handle, mounted.store)
        let liveBefore = try XCTUnwrap(handle.currentCamera)
        let changeBefore = fixture.document.liveChangeCount

        let export = try await exportVideo(
            fixture.document, name: "wide-square", width: 480, height: 480,
            fps: 8, cameraTrack: false)
        XCTAssertEqual(export.width, 480)
        XCTAssertEqual(export.height, 480)

        let first = try await videoFrame(export.url, atSeconds: 0)
        let landmarks = try Self.landmarks(in: first)
        Self.assertWideLandmarks(landmarks, label: "square video frame")
        guard landmarks.red.isPresent, landmarks.blue.isPresent else { return }
        // The complete 16:9 shot is contained in the square container: both
        // landmarks stay in the middle band, and the shot is not stretched.
        XCTAssertGreaterThan(CGFloat(landmarks.red.bounds.minY), 0.15 * 480)
        XCTAssertLessThan(CGFloat(landmarks.blue.bounds.maxY), 0.85 * 480)
        XCTAssertEqual(Double(first.cgImage?.width ?? 0), 480)
        XCTAssertEqual(Double(first.cgImage?.height ?? 0), 480)

        // The poster is the SHOT, not the letterboxed container.
        let posterData = try XCTUnwrap(export.posterPNG)
        let poster = try XCTUnwrap(UIImage(data: posterData))
        let posterLandmarks = try Self.landmarks(in: poster)
        Self.assertWideLandmarks(posterLandmarks, label: "video poster")
        XCTAssertEqual(Double(poster.size.width) / Double(poster.size.height),
                       16.0 / 9, accuracy: 0.02)

        XCTAssertEqual(try XCTUnwrap(handle.currentCamera), liveBefore,
                       "the video export must restore the user's live camera")
        XCTAssertEqual(fixture.document.liveChangeCount, changeBefore)
        XCTAssertEqual(fixture.document.activeSavedCamera?.id, stored.id)
        await unmount(handle, mounted.store, mounted.window, mounted.hosting,
                      document: fixture.document)
    }

    func testVideoExportPillarboxesAPortraitShotInALandscapeContainer() async throws {
        let fixture = try await makeLandmarkDocument(
            name: "Portrait landscape video", leftXMM: -45, rightXMM: 45)
        let mounted = try await mount(fixture.document)
        let handle = mounted.handle
        let stored = try fixture.document.saveCamera(
            frontCamera(name: "Portrait video shot", frameAspect: 9.0 / 16,
                        projection: .perspective))
        handle.showCamera(stored.presentationCamera)
        try await settle(handle, mounted.store)

        let export = try await exportVideo(
            fixture.document, name: "portrait-landscape", width: 640, height: 360,
            fps: 8, cameraTrack: false)
        XCTAssertEqual(export.width, 640)
        XCTAssertEqual(export.height, 360)
        let first = try await videoFrame(export.url, atSeconds: 0)
        let landmarks = try Self.landmarks(in: first)
        Self.assertLandmarksPresent(landmarks, label: "portrait video frame")
        guard landmarks.red.isPresent, landmarks.blue.isPresent else { return }
        // The 9:16 shot is pillarboxed inside the 16:9 container: both
        // landmarks sit in the central content band instead of being
        // stretched across the whole width.
        XCTAssertGreaterThan(CGFloat(landmarks.red.bounds.minX), 0.28 * 640)
        XCTAssertLessThan(CGFloat(landmarks.blue.bounds.maxX), 0.72 * 640)
        XCTAssertGreaterThan(landmarks.blue.centroid.x
                            - landmarks.red.centroid.x, 64)
        XCTAssertGreaterThan(CGFloat(landmarks.red.bounds.minY), 0.4 * 360)
        XCTAssertLessThan(CGFloat(landmarks.blue.bounds.maxY), 0.6 * 360)
        await unmount(handle, mounted.store, mounted.window, mounted.hosting,
                      document: fixture.document)
    }

    func testVideoExportAppliesTheSavedOrthographicProjectionToACameraTrack() async throws {
        let fixture = try await makeLandmarkDocument(
            name: "Tracked orthographic video", leftXMM: -160, rightXMM: 160)
        let mounted = try await mount(fixture.document)
        let handle = mounted.handle
        let stored = try fixture.document.saveCamera(
            frontCamera(name: "Tracked orthographic", frameAspect: 16.0 / 9,
                        projection: .orthographic))
        handle.showCamera(stored.presentationCamera)
        try await settle(handle, mounted.store)

        let export = try await exportVideo(
            fixture.document, name: "tracked-ortho", width: 960, height: 960,
            fps: 8, cameraTrack: true)
        let first = try await videoFrame(export.url, atSeconds: 0)
        let lastTime = Double(max(export.frameCount - 1, 0)) / 8.0
        let last = try await videoFrame(export.url, atSeconds: lastTime)
        let firstLandmarks = try Self.landmarks(in: first)
        let lastLandmarks = try Self.landmarks(in: last)
        Self.assertLandmarksPresent(firstLandmarks, label: "track first frame")
        Self.assertLandmarksPresent(lastLandmarks, label: "track last frame")
        guard firstLandmarks.red.isPresent, firstLandmarks.blue.isPresent,
              lastLandmarks.red.isPresent, lastLandmarks.blue.isPresent else {
            return
        }
        // The authored camera track really moves the shot.
        let shift = abs(lastLandmarks.red.centroid.x
                        - firstLandmarks.red.centroid.x)
        XCTAssertGreaterThan(shift, 0.004 * 960,
                             "the camera track must actually move the shot")
        // Orthographic projection keeps equal on-screen size at different
        // depths. A perspective fallback would shrink the far marker by
        // roughly 30% at the last frame.
        let firstRatio = CGFloat(firstLandmarks.red.bounds.width)
            / CGFloat(max(firstLandmarks.blue.bounds.width, 1))
        let lastRatio = CGFloat(lastLandmarks.red.bounds.width)
            / CGFloat(max(lastLandmarks.blue.bounds.width, 1))
        XCTAssertEqual(firstRatio, 1, accuracy: 0.2)
        XCTAssertEqual(lastRatio, 1, accuracy: 0.2,
                       "the selected orthographic projection must survive the track")
        XCTAssertEqual(fixture.document.activeSavedCamera?.projection,
                       .orthographic)
        await unmount(handle, mounted.store, mounted.window, mounted.hosting,
                      document: fixture.document)
    }

    // MARK: - Helpers

    private struct VideoExport {
        var url: URL
        var width: Int
        var height: Int
        var frameCount: Int
        var posterPNG: Data?
    }

    /// One real, small MP4 through the production exporter. No fabricated
    /// frames: the test decodes the file it just wrote.
    private func exportVideo(_ document: FloeCADDocument, name: String,
                             width: Int, height: Int, fps: Int,
                             cameraTrack: Bool) async throws -> VideoExport {
        let clip = try document.createAnimationClip(name: name, duration: 0.5)
        if cameraTrack {
            let track = try document.addAnimationTrack(clipID: clip.id,
                                                       target: .camera)
            _ = try document.setAnimationKeyframe(
                clipID: clip.id, trackID: track.id, time: 0,
                camera: CADAnimationCameraValue(
                    target: .zero, distance: 0.2, azimuthRadians: 0,
                    elevationRadians: 0, fovYDegrees: 60))
            _ = try document.setAnimationKeyframe(
                clipID: clip.id, trackID: track.id, time: 0.5,
                camera: CADAnimationCameraValue(
                    target: .zero, distance: 0.2,
                    azimuthRadians: 20 * .pi / 180,
                    elevationRadians: 0, fovYDegrees: 60))
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SavedCameraVideo-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        directories.append(directory)
        let url = directory.appendingPathComponent("\(name).mp4")
        let settings = CADAnimationExportSettings(
            width: width, height: height, frameRate: fps, codec: .h264,
            bitrate: nil, overwrite: false, posterEnabled: true)
        let handle = try document.startAnimationExportMP4(
            clipID: clip.id, to: url, settings: settings)
        let status = await CADAnimationExportCenter.shared.wait(handle.id)
        let result = try XCTUnwrap(status.result,
                                   status.error ?? "the video export produced no result")
        return VideoExport(url: result.url, width: result.width,
                           height: result.height, frameCount: result.frameCount,
                           posterPNG: result.posterPNG)
    }

    /// Decode an actual encoded frame; no test-only renderer is involved.
    /// A half-frame tolerance keeps exact-frame decoding robust on the
    /// Simulator without reaching a neighbouring authored keyframe.
    private func videoFrame(_ url: URL, atSeconds seconds: Double,
                            tolerance: Double = 1.0 / 16.0) async throws -> UIImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        let window = CMTime(seconds: max(0, tolerance), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = window
        generator.requestedTimeToleranceAfter = window
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        let cgImage = try await generator.image(at: time).image
        return UIImage(cgImage: cgImage)
    }

    private struct PixelRegion {
        var count = 0
        var minX = Int.max
        var minY = Int.max
        var maxX = -1
        var maxY = -1
        var sumX = 0
        var sumY = 0

        var isPresent: Bool { count >= 16 && maxX >= minX && maxY >= minY }
        var width: Int { max(0, maxX - minX + 1) }
        var height: Int { max(0, maxY - minY + 1) }
        var bounds: CGRect {
            CGRect(x: minX, y: minY, width: width, height: height)
        }
        var centroid: CGPoint {
            guard count > 0 else { return .zero }
            return CGPoint(x: CGFloat(sumX) / CGFloat(count),
                           y: CGFloat(sumY) / CGFloat(count))
        }
    }

    private struct Landmarks {
        var width: Int
        var height: Int
        var red: PixelRegion
        var blue: PixelRegion
    }

    /// Actual pixel landmarks. The quads are authored red (left) and blue
    /// (right); a viewport-first export that clipped the saved shot has
    /// neither, so this is a real framing witness rather than an image
    /// signature or a dimension check.
    private static func landmarks(in image: UIImage) throws -> Landmarks {
        let cgImage = try XCTUnwrap(image.cgImage,
                                    "the export must contain actual pixels")
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return
            }
            context.draw(cgImage, in: CGRect(x: 0, y: 0,
                                             width: width, height: height))
        }
        var red = PixelRegion()
        var blue = PixelRegion()
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                let r = Int(pixels[index])
                let g = Int(pixels[index + 1])
                let b = Int(pixels[index + 2])
                if r >= 110, r >= g + 45, r >= b + 45 {
                    red.count += 1
                    red.minX = min(red.minX, x); red.maxX = max(red.maxX, x)
                    red.minY = min(red.minY, y); red.maxY = max(red.maxY, y)
                    red.sumX += x; red.sumY += y
                } else if b >= 110, b >= r + 45, b >= g + 45 {
                    blue.count += 1
                    blue.minX = min(blue.minX, x); blue.maxX = max(blue.maxX, x)
                    blue.minY = min(blue.minY, y); blue.maxY = max(blue.maxY, y)
                    blue.sumX += x; blue.sumY += y
                }
            }
        }
        return Landmarks(width: width, height: height, red: red, blue: blue)
    }

    private static func assertLandmarksPresent(
        _ landmarks: Landmarks, label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let red = landmarks.red
        let blue = landmarks.blue
        XCTAssertTrue(red.isPresent,
                      "\(label): the left red landmark was not rendered",
                      file: file, line: line)
        XCTAssertTrue(blue.isPresent,
                      "\(label): the right blue landmark was not rendered",
                      file: file, line: line)
        guard red.isPresent, blue.isPresent else { return }
        XCTAssertLessThan(red.centroid.x, blue.centroid.x,
                          "\(label): the red landmark must stay left of blue",
                          file: file, line: line)
        XCTAssertEqual(CGFloat(red.bounds.width) / CGFloat(max(red.bounds.height, 1)), 1,
                       accuracy: 0.3,
                       "\(label): the saved shot must not be stretched",
                       file: file, line: line)
        XCTAssertEqual(CGFloat(blue.bounds.width) / CGFloat(max(blue.bounds.height, 1)), 1,
                       accuracy: 0.3,
                       "\(label): the saved shot must not be stretched",
                       file: file, line: line)
    }

    private static func assertWideLandmarks(
        _ landmarks: Landmarks, label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        assertLandmarksPresent(landmarks, label: label, file: file, line: line)
        let red = landmarks.red
        let blue = landmarks.blue
        guard red.isPresent, blue.isPresent else { return }
        let width = CGFloat(landmarks.width)
        let height = CGFloat(landmarks.height)
        XCTAssertGreaterThan(blue.centroid.x - red.centroid.x, width * 0.5,
                             "\(label): both landmarks must span the saved wide frame",
                             file: file, line: line)
        XCTAssertGreaterThan(red.bounds.minX, width * 0.02,
                             "\(label): the left landmark must not be clipped",
                             file: file, line: line)
        XCTAssertLessThan(blue.bounds.maxX, width * 0.98,
                          "\(label): the right landmark must not be clipped",
                          file: file, line: line)
        XCTAssertEqual(red.centroid.y / height, 0.5, accuracy: 0.2,
                       "\(label): the saved centred framing must be preserved",
                       file: file, line: line)
        XCTAssertEqual(blue.centroid.y / height, 0.5, accuracy: 0.2,
                       "\(label): the saved centred framing must be preserved",
                       file: file, line: line)
    }

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
