//
//  CADSavedCameraTests.swift
//  FloeCADKitTests
//
//  X21 saved projection cameras. These exercise the REAL document authority
//  (package create/save/reopen, undo stack, scene settings), the REAL
//  engineering renderer for framing/projection captures, and the shared
//  projection math. No App build, Simulator UI or device interaction is
//  required for this file.
//

import XCTest
import Foundation
import simd
@testable import FloeCAD

#if canImport(SwiftUI) && canImport(RealityKit) && canImport(UIKit)
import RealityKit
#endif

@MainActor
final class CADSavedCameraTests: XCTestCase {
    private var directory: URL!
    private var document: FloeCADDocument!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SavedCamera-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        document = try await FloeCADDocument.create(
            at: directory.appendingPathComponent("Camera.floecad"),
            name: "Camera fixtures")
    }

    override func tearDown() async throws {
        document?.close()
        document = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    // MARK: - Fixtures

    @discardableResult
    private func addTriangle(name: String = "Plate") -> UUID {
        let mesh = RenderMesh(
            positions: [SIMD3(0, 0, 0), SIMD3(40, 0, 0), SIMD3(40, 20, 6)],
            normals: [SIMD3(0, 0, 1), SIMD3(0, 0, 1), SIMD3(0, 0, 1)],
            indices: [0, 1, 2])
        let body = Body(id: BodyID(), name: name, transform: .identity,
                        primitive: nil, render: mesh, revision: 1)
        document.session.perform(AddBodyCommand(body: body, title: "Add test plate"))
        return body.id.raw
    }

    private func camera(name: String,
                        projection: CADCameraProjection = .perspective,
                        distanceMM: Double = 160,
                        frameAspect: Double = 4.0 / 3) -> CADSavedCamera {
        CADSavedCamera(
            name: name,
            projection: projection,
            targetMM: SIMD3(20, 10, 3),
            distanceMM: distanceMM,
            azimuthRadians: .pi * 0.22,
            elevationRadians: .pi * 0.12,
            fovYDegrees: 42,
            frameAspect: frameAspect,
            createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func settings() -> CADSceneSettings {
        document.session.document.sceneSettingsData.flatMap {
            try? JSONDecoder().decode(CADSceneSettings.self, from: $0)
        } ?? CADSceneSettings()
    }

    // MARK: - Projection math

    func testOrthographicProjectionKeepsDepthSizeWhilePerspectiveChangesIt() throws {
        var perspective = TurntableCamera()
        perspective.target = .zero
        perspective.distance = 1_000
        perspective.azimuth = 0
        perspective.elevation = 0
        perspective.projection = .perspective(fovY: 40 * .pi / 180)
        var orthographic = perspective
        orthographic.projection = .orthographic

        // Same screen offset, two depths either side of the target. Absolute
        // NDC size must be depth-independent only for the orthographic lens.
        let nearPoint = SIMD3<Float>(100, 100, 100)
        let farPoint = SIMD3<Float>(100, 100, -100)
        let perspectiveNear = ndc(perspective.viewProjection(aspect: 1), nearPoint)
        let perspectiveFar = ndc(perspective.viewProjection(aspect: 1), farPoint)
        XCTAssertGreaterThan(abs(perspectiveNear.x - perspectiveFar.x), 1e-3,
                             "perspective must shrink a farther point")
        XCTAssertGreaterThan(abs(perspectiveNear.y - perspectiveFar.y), 1e-3)

        let orthoNear = ndc(orthographic.viewProjection(aspect: 1), nearPoint)
        let orthoFar = ndc(orthographic.viewProjection(aspect: 1), farPoint)
        XCTAssertEqual(orthoNear.x, orthoFar.x, accuracy: 1e-5,
                       "orthographic size must not depend on depth")
        XCTAssertEqual(orthoNear.y, orthoFar.y, accuracy: 1e-5)
    }

#if canImport(SwiftUI) && canImport(RealityKit) && canImport(UIKit)
    func testOrthographicHalfHeightMatchesPerspectiveFraming() throws {
        let distance: Float = 2.5
        let fov: Float = 48
        let perspectiveHalfHeight = distance * tan(fov * .pi / 360)
        var camera = CADPresentationCamera(target: SIMD3(0.1, 2, -0.3),
                                           distance: distance,
                                           fovYDegrees: fov)
        XCTAssertEqual(camera.halfHeightAtTarget, perspectiveHalfHeight,
                       accuracy: 1e-5)
        let perspectiveMatrix = camera.perspectiveCameraComponent
        XCTAssertEqual(perspectiveMatrix.fieldOfViewInDegrees, fov)
        XCTAssertEqual(perspectiveMatrix.fieldOfViewOrientation, .vertical)

        camera.projection = .orthographic
        XCTAssertEqual(camera.halfHeightAtTarget, perspectiveHalfHeight,
                       accuracy: 1e-5,
                       "toggling projection must preserve the on-screen size")
        let orthographic = camera.orthographicCameraComponent
        XCTAssertEqual(orthographic.scale, perspectiveHalfHeight, accuracy: 1e-5)
        XCTAssertEqual(orthographic.scaleDirection, .vertical)
        XCTAssertGreaterThan(orthographic.far, orthographic.near)
        XCTAssertGreaterThan(orthographic.near, 0)
    }

    func testStageTransformAndFitPreserveProjectionAndPose() throws {
        var camera = CADPresentationCamera(
            target: SIMD3(1, 2, 3), distance: 8,
            azimuthRadians: 0.7, elevationRadians: -0.4, fovYDegrees: 55,
            projection: .orthographic)
        let targetInCamera = camera.stageTransform * SIMD4(camera.target, 1)
        XCTAssertEqual(targetInCamera.x, 0, accuracy: 1e-4)
        XCTAssertEqual(targetInCamera.y, 0, accuracy: 1e-4)
        XCTAssertEqual(targetInCamera.z, -camera.distance, accuracy: 1e-4)
        let roundTrip = camera.stageTransform * camera.viewToWorld
        for column in 0..<4 {
            for row in 0..<4 {
                XCTAssertEqual(roundTrip[column][row],
                               column == row ? 1 : 0,
                               accuracy: 1e-4)
            }
        }

        let bounds = CADPresentationBounds(min: SIMD3(-1, -2, -3),
                                           max: SIMD3(5, 6, 7))
        camera.fit(bounds, aspect: 0.5)
        XCTAssertEqual(camera.projection, .orthographic,
                       "fit must not silently return to perspective")
        XCTAssertEqual(camera.target, bounds.center)
        XCTAssertTrue(camera.isValid)
    }

#endif

    // MARK: - Persistence / reopen

    func testSaveRenameSwitchReopenKeepsProjectionPoseAndFrame() async throws {
        addTriangle()
        let first = try document.saveCamera(
            camera(name: "  Front   view ", projection: .orthographic))
        XCTAssertEqual(first.name, "Front view")
        XCTAssertEqual(document.activeSavedCameraID, first.id)
        _ = try document.saveCamera(camera(name: "Perspective shot"))
        XCTAssertEqual(document.savedCameras.count, 2)

        let renamed = try document.renameCamera(id: first.id,
                                               to: "Orthographic plan")
        XCTAssertEqual(renamed.name, "Orthographic plan")
        try document.selectCamera(id: first.id)

        let save = await document.save()
        XCTAssertTrue(save.succeeded, save.error ?? "save failed")
        let url = document.url
        document.close()
        document = nil

        let reopened = try await FloeCADDocument.open(at: url)
        document = reopened
        let saved = reopened.savedCameras
        XCTAssertEqual(saved.count, 2)
        let restored = try XCTUnwrap(saved.first { $0.id == first.id })
        XCTAssertEqual(restored.name, "Orthographic plan")
        XCTAssertEqual(restored.projection, .orthographic)
        XCTAssertEqual(restored.targetMM, SIMD3(20, 10, 3))
        XCTAssertEqual(restored.distanceMM, 160, accuracy: 1e-9)
        XCTAssertEqual(restored.azimuthRadians, .pi * 0.22, accuracy: 1e-12)
        XCTAssertEqual(restored.elevationRadians, .pi * 0.12, accuracy: 1e-12)
        XCTAssertEqual(restored.fovYDegrees, 42, accuracy: 1e-12)
        XCTAssertEqual(restored.frameAspect, 4.0 / 3, accuracy: 1e-12)
        XCTAssertEqual(restored.createdAt.timeIntervalSinceReferenceDate,
                       800_000_000, accuracy: 1e-6)
        XCTAssertEqual(reopened.activeSavedCameraID, first.id)
        XCTAssertEqual(reopened.effectiveCameraProjection, .orthographic)
        XCTAssertEqual(reopened.effectiveCameraFovYDegrees ?? 0, 42,
                       accuracy: 1e-12)
    }

    func testLegacySceneSettingsStillDecodeAndKeepTheirProjection() async throws {
        // A package written before X21 has no camera list. The legacy single
        // camera must remain the compatibility default, untouched by saving a
        // new view.
        let legacyCamera = CADSceneSettings.Camera(
            azimuthRadians: 0, elevationRadians: 0, distance: 300,
            targetX: 0, targetY: 0, targetZ: 0,
            fovYDegrees: 38, isOrthographic: true)
        let legacy = CADSceneSettings(camera: legacyCamera, showsGrid: true)
        let legacyData = try JSONEncoder().encode(legacy)
        document.session.perform(SetSceneSettingsDataCommand(
            before: document.session.document.sceneSettingsData,
            after: legacyData))
        XCTAssertTrue(document.savedCameras.isEmpty)
        XCTAssertNil(document.activeSavedCamera)
        XCTAssertEqual(document.effectiveCameraProjection, .orthographic)

        // A hand-written v1 record with no X21 keys decodes.
        let minimal = try JSONDecoder().decode(
            CADSceneSettings.self,
            from: Data(#"{"schemaVersion":1,"showsGrid":true}"#.utf8))
        XCTAssertNil(minimal.savedCameras)
        XCTAssertNil(minimal.activeCameraID)

        _ = try document.saveCamera(camera(name: "New ortho",
                                           projection: .orthographic))
        XCTAssertEqual(document.effectiveCameraProjection, .orthographic)
        let after = settings()
        XCTAssertEqual(after.camera?.fovYDegrees, 38,
                       "saving a view must not rewrite the legacy camera")
        XCTAssertEqual(after.camera?.isOrthographic, true)
        XCTAssertEqual(after.savedCameras?.count, 1)
    }

    func testFutureEntryWithoutFrameOrDateDecodesCompatibly() throws {
        let id = UUID()
        let json = """
        {"schemaVersion":2,"activeCameraID":"\(id.uuidString)","savedCameras":[
          {"id":"\(id.uuidString)","name":"Legacy entry",
           "projection":"orthographic","targetMM":[1,2,3],
           "distanceMM":1200,"azimuthRadians":0.5,"elevationRadians":0.25,
           "fovYDegrees":55}
        ]}
        """
        let decoded = try JSONDecoder().decode(
            CADSceneSettings.self, from: Data(json.utf8))
        let entry = try XCTUnwrap(decoded.savedCameras?.first)
        XCTAssertEqual(entry.name, "Legacy entry")
        XCTAssertEqual(entry.projection, .orthographic)
        XCTAssertEqual(entry.frameAspect, 1)
        XCTAssertEqual(entry.createdAt.timeIntervalSince1970, 0)
        XCTAssertEqual(decoded.activeSavedCameraEntry?.id, id)
    }

    // MARK: - Edit rules

    func testSaveUpdateRenameDeleteAreSingleUndoSteps() throws {
        addTriangle()
        let undoBefore = document.session.undoStack.undoCommands.count
        let saved = try document.saveCamera(camera(name: "View one"))
        XCTAssertEqual(document.session.undoStack.undoCommands.count,
                       undoBefore + 1, "one save must be one undo step")

        let updated = try document.updateCamera(
            id: saved.id,
            with: camera(name: "ignored", projection: .orthographic,
                         distanceMM: 240, frameAspect: 1))
        XCTAssertEqual(updated.id, saved.id)
        XCTAssertEqual(updated.name, "View one",
                       "update keeps the authored name")
        XCTAssertEqual(updated.distanceMM, 240, accuracy: 1e-9)
        XCTAssertEqual(updated.projection, .orthographic)
        XCTAssertEqual(updated.frameAspect, 1, accuracy: 1e-12)

        _ = try document.renameCamera(id: saved.id, to: "Plan")
        XCTAssertEqual(document.savedCameras.first?.name, "Plan")

        // Undo walks the three camera commands; redo restores them.
        document.session.undo()
        XCTAssertEqual(document.savedCameras.first?.name, "View one")
        document.session.undo()
        XCTAssertEqual(try XCTUnwrap(document.savedCameras.first).distanceMM, 160,
                       accuracy: 1e-9)
        document.session.undo()
        XCTAssertTrue(document.savedCameras.isEmpty)
        XCTAssertNil(document.activeSavedCameraID)
        document.session.redo()
        XCTAssertEqual(document.savedCameras.count, 1)
        XCTAssertEqual(document.activeSavedCameraID, saved.id)

        try document.deleteCamera(id: saved.id)
        XCTAssertTrue(document.savedCameras.isEmpty)
        XCTAssertNil(document.activeSavedCameraID)
        document.session.undo()
        XCTAssertEqual(document.savedCameras.count, 1)
        XCTAssertEqual(document.activeSavedCameraID, saved.id)
    }

    func testDuplicateNamesLimitsAndNamesRefuseBeforeMutation() throws {
        let saved = try document.saveCamera(camera(name: "Front"))
        XCTAssertThrowsError(
            try document.saveCamera(camera(name: " front "))) { error in
            XCTAssertEqual(error as? CADCameraBookmarkError,
                           .duplicateName("front"))
        }
        XCTAssertEqual(document.savedCameras.count, 1)
        XCTAssertEqual(document.savedCameras.first?.id, saved.id)

        XCTAssertThrowsError(
            try document.renameCamera(id: saved.id, to: "   ")) { error in
            XCTAssertEqual(error as? CADCameraBookmarkError, .emptyName)
        }
        XCTAssertThrowsError(
            try document.renameCamera(
                id: saved.id,
                to: String(repeating: "x",
                           count: CADSavedCamera.maximumNameLength + 1))) { error in
            XCTAssertEqual(error as? CADCameraBookmarkError,
                           .nameTooLong(CADSavedCamera.maximumNameLength))
        }
        XCTAssertEqual(document.savedCameras.first?.name, "Front")

        _ = try document.saveCamera(camera(name: "Second"))
        XCTAssertThrowsError(
            try document.renameCamera(id: saved.id, to: "second")) { error in
            XCTAssertEqual(error as? CADCameraBookmarkError,
                           .duplicateName("second"))
        }
    }

    func testCameraLimitAndUnknownIdsRefuseWithoutChangingTheList() throws {
        let limit = CADSavedCamera.maximumCount
        for index in 1...limit {
            _ = try document.saveCamera(camera(name: "View \(index)"))
        }
        XCTAssertEqual(document.savedCameras.count, limit)
        let before = document.session.changeCount
        XCTAssertThrowsError(
            try document.saveCamera(camera(name: "Too many"))) { error in
            XCTAssertEqual(error as? CADCameraBookmarkError,
                           .limitReached(limit))
        }
        XCTAssertEqual(document.session.changeCount, before,
                       "a refused save must not edit the document")
        XCTAssertEqual(document.savedCameras.count, limit)

        let missing = UUID()
        XCTAssertThrowsError(try document.renameCamera(id: missing, to: "x")) {
            XCTAssertEqual($0 as? CADCameraBookmarkError, .notFound(missing))
        }
        XCTAssertThrowsError(try document.deleteCamera(id: missing)) {
            XCTAssertEqual($0 as? CADCameraBookmarkError, .notFound(missing))
        }
        XCTAssertThrowsError(try document.selectCamera(id: missing)) {
            XCTAssertEqual($0 as? CADCameraBookmarkError, .notFound(missing))
        }
    }

    func testSelectingFreeViewKeepsTheSavedList() throws {
        let saved = try document.saveCamera(camera(name: "Front"))
        try document.selectCamera(id: nil)
        XCTAssertNil(document.activeSavedCameraID)
        XCTAssertEqual(document.savedCameras.map(\.id), [saved.id])
        try document.selectCamera(id: saved.id)
        XCTAssertEqual(document.activeSavedCameraID, saved.id)
    }

    // MARK: - Temporary observation never writes

    func testObservationProjectionOverrideNeverOverwritesSavedCamera() throws {
        addTriangle()
        let saved = try document.saveCamera(
            camera(name: "Plan", projection: .orthographic))
        try document.selectCamera(id: saved.id)
        let beforeSettings = document.session.document.sceneSettingsData
        let beforeChange = document.session.changeCount

        // Temporary override: the frame is perspective, but the document's
        // selected orthographic view must be untouched.
        let frames = try document.captureObservationViews(
            [CADObservationView(azimuthDegrees: 25, elevationDegrees: 15)],
            width: 320, height: 240, projection: .perspective)
        let frame = try XCTUnwrap(frames.first)
        XCTAssertEqual(frame.projection, "perspective")
        XCTAssertEqual(document.session.document.sceneSettingsData, beforeSettings)
        XCTAssertEqual(document.session.changeCount, beforeChange)
        let restored = try XCTUnwrap(document.activeSavedCamera)
        XCTAssertEqual(restored.id, saved.id)
        XCTAssertEqual(restored.projection, .orthographic)

        // No override: the observation follows the selected saved view.
        let inherited = try document.captureObservationViews(
            [CADObservationView(azimuthDegrees: 25, elevationDegrees: 15)],
            width: 320, height: 240)
        XCTAssertEqual(inherited.first?.projection, "orthographic")
        XCTAssertEqual(document.session.document.sceneSettingsData, beforeSettings)
    }

    // MARK: - AI query describes the actual camera

    func testSceneSummaryAndCameraQueryDescribeTheActualProjection() throws {
        let saved = try document.saveCamera(
            camera(name: "Board plan", projection: .orthographic,
                   frameAspect: 16.0 / 9))
        try document.selectCamera(id: saved.id)
        let changeCount = document.session.changeCount

        let summary = document.sceneSummaryJSON()
        let cameras = try XCTUnwrap(summary["cameras"] as? [String: Any])
        XCTAssertEqual(cameras["count"] as? Int, 1)
        XCTAssertEqual(cameras["active_id"] as? String, saved.id.uuidString)
        XCTAssertEqual(cameras["active_name"] as? String, "Board plan")
        XCTAssertEqual(cameras["active_projection"] as? String, "orthographic")
        let rows = try XCTUnwrap(cameras["saved"] as? [[String: Any]])
        XCTAssertEqual(rows.first?["frame"] as? String, "16:9")
        XCTAssertEqual(rows.first?["projection"] as? String, "orthographic")

        let outcome = document.nativeQueryJSON(["scope": "camera"])
        XCTAssertTrue(outcome.isOK, outcome.message ?? "camera query failed")
        let payload = try jsonObject(outcome.payload)
        let cameraPayload = try XCTUnwrap(payload["camera"] as? [String: Any])
        XCTAssertEqual(cameraPayload["active_projection"] as? String,
                       "orthographic")
        XCTAssertEqual(document.session.changeCount, changeCount,
                       "queries must not edit the document")
    }

    // MARK: - Real engineering capture keeps projection and frame

    func testEngineeringCaptureUsesSavedProjectionAndFrame() throws {
        addTriangle()
        let orthographic = try document.saveCamera(
            camera(name: "Ortho capture", projection: .orthographic,
                   distanceMM: 120, frameAspect: 4.0 / 3))
        let settingsBefore = document.session.document.sceneSettingsData
        let changeBefore = document.session.changeCount

        let ortho = try document.captureViewportPNG(
            width: 800, height: 600,
            expectedRevision: document.revision, camera: orthographic)
        XCTAssertEqual(ortho.width, 800)
        XCTAssertEqual(ortho.height, 600)
        XCTAssertEqual(ortho.projection, "orthographic")
        XCTAssertEqual(ortho.cameraName, "Ortho capture")
        XCTAssertEqual(ortho.matchesSavedCamera, true)
        XCTAssertEqual(ortho.renderer, "engineering")
        XCTAssertTrue(ortho.note.contains("Ortho capture"))
        XCTAssertEqual(ortho.pngData.prefix(2), Data([0x89, 0x50]))

        var perspectiveCamera = orthographic
        perspectiveCamera.projection = .perspective
        perspectiveCamera.id = UUID()
        let perspective = try document.captureViewportPNG(
            width: 800, height: 600, camera: perspectiveCamera)
        XCTAssertEqual(perspective.projection, "perspective")
        XCTAssertNotEqual(perspective.sha256, ortho.sha256,
                          "perspective and orthographic pixels must differ")

        // Capturing is a read: neither the saved view nor the document moved.
        XCTAssertEqual(document.session.document.sceneSettingsData,
                       settingsBefore)
        XCTAssertEqual(document.session.changeCount, changeBefore)
        XCTAssertEqual(document.activeSavedCamera?.projection, .orthographic)
    }

    func testEngineeringCaptureRejectsAnInvalidSavedCamera() throws {
        var invalid = camera(name: "Broken")
        invalid.distanceMM = 0
        XCTAssertThrowsError(
            try document.captureViewportPNG(width: 320, height: 240,
                                            camera: invalid)) { error in
            XCTAssertEqual((error as? CADDocumentError)?.code, "bad_camera")
        }
    }

    // MARK: - Frame composition

    func testFrameCompositionFitsWithoutCropping() throws {
        let landscape = try XCTUnwrap(CADExportFrame.pixelSize(
            forAspect: 4.0 / 3, targetWidth: 2_048))
        XCTAssertEqual(landscape.width, 2_048)
        XCTAssertEqual(landscape.height, 1_536)
        let wide = try XCTUnwrap(CADExportFrame.pixelSize(
            forAspect: 16.0 / 9, targetWidth: 2_048))
        XCTAssertEqual(wide.width, 2_048)
        XCTAssertEqual(wide.height, 1_152)
        let tall = try XCTUnwrap(CADExportFrame.pixelSize(
            forAspect: 0.2, targetWidth: 2_048))
        XCTAssertLessThanOrEqual(tall.width, 4_096)
        XCTAssertLessThanOrEqual(tall.height, 4_096)
        XCTAssertEqual(Double(tall.width) / Double(tall.height), 0.2,
                       accuracy: 0.002)

        let contained = CADExportFrame.fittedRect(
            content: CGSize(width: 2_048, height: 1_536),
            canvas: CGSize(width: 2_048, height: 1_152))
        XCTAssertEqual(contained.width, 1_536, accuracy: 0.5)
        XCTAssertEqual(contained.height, 1_152, accuracy: 0.5)
        XCTAssertEqual(contained.minX, 256, accuracy: 0.5)
        XCTAssertEqual(contained.minY, 0, accuracy: 0.5)

        let portrait = CADExportFrame.fittedRect(
            content: CGSize(width: 600, height: 800),
            canvas: CGSize(width: 800, height: 600))
        XCTAssertEqual(portrait.width, 450, accuracy: 0.5)
        XCTAssertEqual(portrait.height, 600, accuracy: 0.5)
        XCTAssertEqual(portrait.minX, 175, accuracy: 0.5)
    }

    // MARK: - Transient saved-shot framing (X21-R2)

    func testFramingPlanWidensAWideShotToFitASquareViewport() throws {
        let plan = try XCTUnwrap(CADExportFraming.plan(
            savedAspect: 16.0 / 9, viewportAspect: 1, fovYDegrees: 60,
            projection: .perspective, targetWidth: 2_048))
        XCTAssertEqual(plan.width, 2_048)
        XCTAssertEqual(plan.height, 1_152)
        XCTAssertEqual(Double(plan.width) / Double(plan.height), 16.0 / 9,
                       accuracy: 0.001)
        XCTAssertGreaterThan(plan.transientScale, 16.0 / 9,
                             "a square viewport must widen to contain a 16:9 frustum")
        XCTAssertLessThan(plan.transientScale, 1.79)
        XCTAssertGreaterThan(plan.transientFovYDegrees, 60)
        XCTAssertLessThanOrEqual(plan.transientFovYDegrees,
                                 CADExportFraming.maximumTransientFovYDegrees)
        let crop = try XCTUnwrap(plan.cropRect(renderedAspect: 1))
        XCTAssertEqual(crop.midX, 0.5, accuracy: 1e-9)
        XCTAssertEqual(crop.midY, 0.5, accuracy: 1e-9)
        XCTAssertGreaterThan(crop.height, 0.55)
        XCTAssertLessThan(crop.height, 0.57)
        XCTAssertGreaterThan(crop.width, 0.99)
        XCTAssertLessThanOrEqual(crop.maxX, 1)
        XCTAssertLessThanOrEqual(crop.maxY, 1)
        XCTAssertEqual(crop.width / crop.height, 16.0 / 9, accuracy: 0.002)
    }

    func testFramingPlanCropsAPortraitShotWithoutWideningAWiderViewport() throws {
        let plan = try XCTUnwrap(CADExportFraming.plan(
            savedAspect: 9.0 / 16, viewportAspect: 1, fovYDegrees: 60,
            projection: .orthographic, targetWidth: 720))
        XCTAssertEqual(plan.transientScale, 1, accuracy: 1e-12)
        XCTAssertEqual(plan.transientFovYDegrees, 60, accuracy: 1e-12)
        XCTAssertEqual(plan.width, 720)
        XCTAssertEqual(plan.height, 1_280)
        let crop = try XCTUnwrap(plan.cropRect(renderedAspect: 1))
        XCTAssertEqual(crop.width, 9.0 / 16, accuracy: 1e-9)
        XCTAssertEqual(crop.height, 1, accuracy: 1e-9)
        XCTAssertEqual(crop.midX, 0.5, accuracy: 1e-9)
        XCTAssertEqual(crop.midY, 0.5, accuracy: 1e-9)
    }

    func testFramingPlanRefusesAnUnsupportedTransientLens() {
        XCTAssertNil(CADExportFraming.plan(
            savedAspect: 5, viewportAspect: 0.2, fovYDegrees: 150,
            projection: .perspective, targetWidth: 1_024),
            "a 178° transient lens must be refused rather than clip the shot")
        let orthographic = CADExportFraming.plan(
            savedAspect: 5, viewportAspect: 0.2, fovYDegrees: 150,
            projection: .orthographic, targetWidth: 1_024)
        XCTAssertNotNil(orthographic,
                        "an orthographic camera has no angle to explode")
        XCTAssertEqual(orthographic?.transientScale ?? 0, 25.05, accuracy: 0.02)
    }

    func testFramingCropRefusesWhenTheRenderedViewportBecameNarrower() throws {
        let plan = try XCTUnwrap(CADExportFraming.plan(
            savedAspect: 16.0 / 9, viewportAspect: 1, fovYDegrees: 60,
            projection: .perspective, targetWidth: 1_024))
        XCTAssertNotNil(plan.cropRect(renderedAspect: 1))
        XCTAssertNil(plan.cropRect(renderedAspect: 0.9),
                     "a viewport that shrank mid-capture must discard the frame")
        XCTAssertNil(plan.cropRect(renderedAspect: .nan))
    }

#if canImport(SwiftUI) && canImport(RealityKit) && canImport(UIKit)
    func testTransientFramingScaleChangesOnlyTheLens() throws {
        var camera = CADPresentationCamera(
            target: SIMD3(1, 2, 3), distance: 2.5,
            azimuthRadians: 0.4, elevationRadians: 0.2, fovYDegrees: 60,
            projection: .perspective)
        let target = camera.target
        let distance = camera.distance
        let fov = camera.fovYDegrees
        let azimuth = camera.azimuthRadians
        camera.transientHalfHeightScale = 2
        XCTAssertEqual(camera.target, target)
        XCTAssertEqual(camera.distance, distance)
        XCTAssertEqual(camera.fovYDegrees, fov)
        XCTAssertEqual(camera.azimuthRadians, azimuth)
        let expected = Float(2 * atan(tan(60.0 * Double.pi / 360) * 2)
                             * 180 / Double.pi)
        XCTAssertEqual(camera.effectiveFovYDegrees, expected, accuracy: 1e-4)
        XCTAssertEqual(camera.perspectiveCameraComponent.fieldOfViewInDegrees,
                       expected, accuracy: 1e-4)
        camera.projection = .orthographic
        XCTAssertEqual(camera.orthographicCameraComponent.scale,
                       camera.halfHeightAtTarget * 2, accuracy: 1e-5)
        // Clearing the transient scale restores the authored lens exactly.
        camera.transientHalfHeightScale = 1
        XCTAssertEqual(camera.effectiveFovYDegrees, fov)
        XCTAssertEqual(camera.orthographicCameraComponent.scale,
                       camera.halfHeightAtTarget, accuracy: 1e-6)
    }
#endif

    // MARK: - Helpers

    private func ndc(_ viewProjection: simd_float4x4,
                     _ point: SIMD3<Float>) -> SIMD2<Float> {
        let clip = viewProjection * SIMD4(point, 1)
        return SIMD2(clip.x / clip.w, clip.y / clip.w)
    }
}
