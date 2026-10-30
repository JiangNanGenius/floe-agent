//
//  CADAnimationTests.swift
//  FloeCADKitTests
//
//  Focused behavior tests for native keyframe animation: pure interpolation /
//  quaternion math, preset generation, invalid-binding reporting, undo,
//  persistence/reopen, corrupt-data isolation and service-owned cancellation.
//  The actual RealityKit playback and MP4 writer are exercised by the App /
//  Simulator batch, not faked here.
//

import XCTest
import simd
@testable import FloeCAD

@MainActor
final class CADAnimationTests: XCTestCase {
    private var workDir: URL!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeCADAnimation-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: workDir,
                                                withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    private func makeDocument(_ name: String = "Animation") async throws -> FloeCADDocument {
        try await FloeCADDocument.create(
            at: workDir.appendingPathComponent("\(name)-\(UUID().uuidString).floecad"),
            name: name)
    }

    private func camera(_ distance: Double = 1) -> CADAnimationCameraValue {
        CADAnimationCameraValue(target: SIMD3(0, 0, 0), distance: distance,
                                azimuthRadians: 0, elevationRadians: 0.2,
                                fovYDegrees: 60)
    }

    // MARK: - Pure interpolation

    func testCameraLinearAndEaseInOutInterpolation() {
        let start = camera(1)
        var end = camera(3)
        end.target = SIMD3(10, 2, -4)
        let middle = start.interpolated(to: end, progress: 0.5)
        XCTAssertEqual(middle.distance, 2, accuracy: 1e-9)
        XCTAssertEqual(middle.target.x, 5, accuracy: 1e-9)
        XCTAssertEqual(middle.target.y, 1, accuracy: 1e-9)
        XCTAssertEqual(middle.target.z, -2, accuracy: 1e-9)

        XCTAssertEqual(CADAnimationInterpolation.linear.eased(0.25), 0.25, accuracy: 1e-12)
        XCTAssertEqual(CADAnimationInterpolation.easeInOut.eased(0.25), 0.0625, accuracy: 1e-12)
        XCTAssertEqual(CADAnimationInterpolation.easeInOut.eased(0.5), 0.5, accuracy: 1e-12)
        XCTAssertEqual(CADAnimationInterpolation.easeInOut.eased(0.75), 0.9375, accuracy: 1e-12)
        XCTAssertEqual(CADAnimationInterpolation.easeInOut.eased(-1), 0, accuracy: 1e-12)
        XCTAssertEqual(CADAnimationInterpolation.easeInOut.eased(2), 1, accuracy: 1e-12)
    }

    func testQuaternionSlerpShortestPath() {
        let identity = SIMD4<Double>(0, 0, 0, 1)
        let halfTurn = SIMD4<Double>(0, 1, 0, 0)
        let middle = CADAnimationQuaternion.slerp(identity, halfTurn, 0.5)
        XCTAssertEqual(simd_length(middle), 1, accuracy: 1e-9)
        XCTAssertEqual(middle.y, sin(.pi / 4), accuracy: 1e-9)
        XCTAssertEqual(middle.w, cos(.pi / 4), accuracy: 1e-9)
        let rotated = CADAnimationQuaternion.rotated(SIMD3(1, 0, 0), by: middle)
        XCTAssertEqual(rotated.x, 0, accuracy: 1e-9)
        XCTAssertEqual(rotated.z, -1, accuracy: 1e-9)

        // The same quaternion negated is the same rotation; shortest-path
        // interpolation must not go the long way round.
        let negated = -halfTurn
        let fromNegated = CADAnimationQuaternion.slerp(identity, negated, 0.5)
        XCTAssertEqual(simd_length(fromNegated), 1, accuracy: 1e-9)
        XCTAssertEqual(abs(fromNegated.y), sin(.pi / 4), accuracy: 1e-9)
    }

    func testInstanceValueNormalizesRotation() {
        let value = CADAnimationInstanceValue(
            translationMM: SIMD3(1, 2, 3),
            rotation: SIMD4(0, 0, 0, 4))
        XCTAssertTrue(value.isValid)
        XCTAssertEqual(value.normalizedRotation, SIMD4(0, 0, 0, 1))
        let invalid = CADAnimationInstanceValue(rotation: SIMD4(0, 0, 0, 0))
        XCTAssertFalse(invalid.isValid)
    }

    // MARK: - Evaluator

    func testEvaluatorInterpolatesInstanceAndClampsTime() {
        let instanceID = UUID()
        let bodyID = UUID()
        let context = CADAnimationSceneContext(
            instances: [instanceID: .init(
                id: instanceID, sourceBodyID: bodyID, sourceRevision: 7,
                baseline: CADAnimationInstanceValue())],
            bodyRevisions: [bodyID: 7])
        let track = CADAnimationTrack(
            target: .instance(instanceID, sourceBodyID: bodyID),
            keyframes: [
                CADAnimationKeyframe(time: 0, interpolation: .linear,
                                     instance: CADAnimationInstanceValue()),
                CADAnimationKeyframe(time: 2, interpolation: .linear,
                                     instance: CADAnimationInstanceValue(
                                        translationMM: SIMD3(0, 100, 0))),
            ])
        let clip = CADAnimationClip(name: "Move", duration: 5, tracks: [track])

        let atOne = CADAnimationEvaluator.evaluate(clip: clip, at: 1, context: context)
        XCTAssertEqual(atOne.instances[instanceID]?.translationMM.y ?? -1,
                       50, accuracy: 1e-9)
        XCTAssertTrue(atOne.issues.isEmpty)

        let before = CADAnimationEvaluator.evaluate(clip: clip, at: -3, context: context)
        XCTAssertEqual(before.time, 0)
        XCTAssertEqual(before.instances[instanceID]?.translationMM.y ?? -1, 0,
                       accuracy: 1e-9)

        let after = CADAnimationEvaluator.evaluate(clip: clip, at: 99, context: context)
        XCTAssertEqual(after.time, 5)
        XCTAssertEqual(after.instances[instanceID]?.translationMM.y ?? -1, 100,
                       accuracy: 1e-9)
    }

    func testEvaluatorReportsMissingReboundAndStaleSourceBindings() {
        let instanceID = UUID()
        let bodyID = UUID()
        let otherBodyID = UUID()
        let target = CADAnimationTrack(
            target: .instance(instanceID, sourceBodyID: bodyID),
            keyframes: [
                CADAnimationKeyframe(time: 0,
                                     instance: CADAnimationInstanceValue(
                                        translationMM: SIMD3(10, 0, 0))),
            ])
        let clip = CADAnimationClip(name: "Move", duration: 5, tracks: [target])

        let missing = CADAnimationEvaluator.evaluate(
            clip: clip, at: 0, context: CADAnimationSceneContext())
        XCTAssertEqual(missing.issues.first?.kind, .missingInstance)
        XCTAssertTrue(missing.instances.isEmpty)

        let reboundContext = CADAnimationSceneContext(
            instances: [instanceID: .init(
                id: instanceID, sourceBodyID: otherBodyID,
                baseline: CADAnimationInstanceValue())],
            bodyRevisions: [otherBodyID: 1])
        let rebound = CADAnimationEvaluator.evaluate(
            clip: clip, at: 0, context: reboundContext)
        XCTAssertEqual(rebound.issues.first?.kind, .sourceBindingChanged)
        XCTAssertTrue(rebound.instances.isEmpty)

        let staleContext = CADAnimationSceneContext(
            instances: [instanceID: .init(
                id: instanceID, sourceBodyID: bodyID, sourceRevision: 2,
                baseline: CADAnimationInstanceValue())],
            bodyRevisions: [bodyID: 9])
        let stale = CADAnimationEvaluator.evaluate(
            clip: clip, at: 0, context: staleContext)
        XCTAssertTrue(stale.issues.contains { $0.kind == .sourceGeometryUpdated })
        XCTAssertEqual(stale.instances[instanceID]?.translationMM.x ?? -1, 10,
                       accuracy: 1e-9)

        let missingSource = CADAnimationSceneContext(
            instances: [instanceID: .init(
                id: instanceID, sourceBodyID: bodyID,
                baseline: CADAnimationInstanceValue())],
            bodyRevisions: [:])
        let missingBody = CADAnimationEvaluator.evaluate(
            clip: clip, at: 0, context: missingSource)
        XCTAssertEqual(missingBody.issues.first?.kind, .missingSource)
    }

    func testEmptyTrackAndInvalidTargetAreBounded() {
        let clip = CADAnimationClip(
            name: "Empty", duration: 5,
            tracks: [CADAnimationTrack(target: .camera)])
        let evaluation = CADAnimationEvaluator.evaluate(
            clip: clip, at: 1, context: CADAnimationSceneContext())
        XCTAssertNil(evaluation.camera)
        XCTAssertTrue(evaluation.issues.isEmpty)

        let invalid = CADAnimationTrack(target: CADAnimationTarget(kind: .instance))
        let invalidClip = CADAnimationClip(name: "Bad", duration: 5, tracks: [invalid])
        let invalidEvaluation = CADAnimationEvaluator.evaluate(
            clip: invalidClip, at: 1, context: CADAnimationSceneContext())
        XCTAssertEqual(invalidEvaluation.issues.first?.kind, .invalidTrackValue)
    }

    // MARK: - Presets

    func testTurntablePresetStartsAndEndsAtTheSamePose() {
        let base = camera(2)
        let clip = CADAnimationPreset.turntable(duration: 5, base: base)
        XCTAssertEqual(clip.duration, 5)
        XCTAssertTrue(clip.isLooping)
        XCTAssertEqual(clip.cameraTrack?.keyframes.count, 2)
        let context = CADAnimationSceneContext()
        let start = CADAnimationEvaluator.evaluate(clip: clip, at: 0, context: context)
        let end = CADAnimationEvaluator.evaluate(clip: clip, at: 5, context: context)
        let middle = CADAnimationEvaluator.evaluate(clip: clip, at: 2.5, context: context)
        XCTAssertEqual(start.camera?.distance ?? 0, 2, accuracy: 1e-9)
        XCTAssertEqual(end.camera?.distance ?? 0, 2, accuracy: 1e-9)
        XCTAssertEqual(sin(end.camera?.azimuthRadians ?? 0),
                       sin(base.azimuthRadians), accuracy: 1e-9)
        XCTAssertEqual(cos(end.camera?.azimuthRadians ?? 0),
                       cos(base.azimuthRadians), accuracy: 1e-9)
        XCTAssertEqual(middle.camera?.azimuthRadians ?? 0,
                       base.azimuthRadians + .pi, accuracy: 1e-9)
    }

    func testExplodeReturnPresetUsesBaselineAndReturns() {
        let a = CADAnimationInstanceSeed(
            instanceID: UUID(), sourceBodyID: UUID(),
            value: CADAnimationInstanceValue(translationMM: SIMD3(-50, 0, 0)))
        let b = CADAnimationInstanceSeed(
            instanceID: UUID(), sourceBodyID: UUID(),
            value: CADAnimationInstanceValue(translationMM: SIMD3(50, 0, 0)))
        let clip = CADAnimationPreset.explodeReturn(
            duration: 5, seeds: [a, b], distanceMM: 100)
        let context = CADAnimationSceneContext(
            instances: [
                a.instanceID: .init(id: a.instanceID, sourceBodyID: a.sourceBodyID,
                                    baseline: a.value),
                b.instanceID: .init(id: b.instanceID, sourceBodyID: b.sourceBodyID,
                                    baseline: b.value),
            ],
            bodyRevisions: [a.sourceBodyID: 1, b.sourceBodyID: 1])
        let start = CADAnimationEvaluator.evaluate(clip: clip, at: 0, context: context)
        let peak = CADAnimationEvaluator.evaluate(clip: clip, at: 2.25, context: context)
        let end = CADAnimationEvaluator.evaluate(clip: clip, at: 5, context: context)
        XCTAssertEqual(start.instances[a.instanceID]?.translationMM.x ?? 0,
                       -50, accuracy: 1e-9)
        XCTAssertEqual(peak.instances[a.instanceID]?.translationMM.x ?? 0,
                       -150, accuracy: 1e-9)
        XCTAssertEqual(peak.instances[b.instanceID]?.translationMM.x ?? 0,
                       150, accuracy: 1e-9)
        XCTAssertEqual(end.instances[a.instanceID]?.translationMM.x ?? 0,
                       -50, accuracy: 1e-9)
        XCTAssertEqual(end.instances[b.instanceID]?.translationMM.x ?? 0,
                       50, accuracy: 1e-9)
    }

    // MARK: - Codable / sanitize

    func testAnimationDocumentRoundTripSanitizesKeyframes() throws {
        let clip = CADAnimationClip(
            name: "  Spin  ", duration: 9_999,
            tracks: [CADAnimationTrack(
                target: .camera,
                keyframes: [
                    CADAnimationKeyframe(time: 9, camera: camera()),
                    CADAnimationKeyframe(time: 0, camera: camera(2)),
                    CADAnimationKeyframe(time: 0.0000001, camera: camera(3)),
                ])])
        let document = CADAnimationDocument(clips: [clip]).sanitized()
        XCTAssertEqual(document.clips.first?.name, "Spin")
        XCTAssertEqual(document.clips.first?.duration,
                       CADAnimationDocument.maximumDurationSeconds)
        let frames = document.clips.first?.cameraTrack?.keyframes ?? []
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames.first?.time, 0)
        XCTAssertEqual(frames.first?.camera?.distance ?? 0, 3, accuracy: 1e-9)

        let data = try CADAnimationCodec.encode(document)
        let decoded = try CADAnimationCodec.decode(data)
        XCTAssertEqual(decoded, document)
    }

    func testFramePlanAndExportSettingsAreBounded() {
        XCTAssertEqual(CADAnimationClip(name: "F", duration: 5).frameCount(at: 30), 150)
        XCTAssertEqual(FloeCADDocument.animationFrameTime(
            frame: 149, fps: 30, duration: 5), 149.0 / 30.0, accuracy: 1e-12)
        XCTAssertEqual(FloeCADDocument.animationFrameTime(
            frame: 999, fps: 30, duration: 5), 149.0 / 30.0, accuracy: 1e-12)
        XCTAssertNil(CADAnimationExportSettings.default.validationError)
        var odd = CADAnimationExportSettings.default
        odd.width = 1921
        XCTAssertNotNil(odd.validationError)
        var badFPS = CADAnimationExportSettings.default
        badFPS.frameRate = 0
        XCTAssertNotNil(badFPS.validationError)
        var tiny = CADAnimationExportSettings.default
        tiny.height = 32
        XCTAssertNotNil(tiny.validationError)
    }

    // MARK: - Document editing / persistence

    func testAnimationEditsAreUndoableAndReopenable() async throws {
        let document = try await makeDocument()
        let clip = try document.createAnimationClip(name: "Spin", duration: 5)
        XCTAssertEqual(document.animationDocument.clips.count, 1)
        XCTAssertEqual(document.liveChangeCount > 0, true)

        let track = try document.addAnimationTrack(clipID: clip.id, target: .camera)
        _ = try document.setAnimationKeyframe(
            clipID: clip.id, trackID: track.id, time: 0,
            camera: camera(1))
        _ = try document.setAnimationKeyframe(
            clipID: clip.id, trackID: track.id, time: 5,
            camera: camera(4))
        XCTAssertEqual(document.animationDocument.clip(withID: clip.id)?
            .cameraTrack?.keyframes.count, 2)
        XCTAssertEqual(document.session.undoStack.canUndo, true)

        document.session.undo()
        XCTAssertEqual(document.animationDocument.clip(withID: clip.id)?
            .cameraTrack?.keyframes.count, 1)
        document.session.redo()
        XCTAssertEqual(document.animationDocument.clip(withID: clip.id)?
            .cameraTrack?.keyframes.count, 2)

        let outcome = await document.save()
        XCTAssertNil(outcome.error)
        let url = document.url
        document.close()
        let reopened = try await FloeCADDocument.open(at: url)
        let saved = reopened.animationDocument.clip(withID: clip.id)
        XCTAssertEqual(saved?.name, "Spin")
        XCTAssertEqual(saved?.cameraTrack?.keyframes.count, 2)
        XCTAssertEqual(saved?.duration, 5)
        reopened.close()
    }

    func testCorruptAnimationDoesNotAffectGeometryOrAssembly() async throws {
        let document = try await makeDocument()
        _ = try document.createAnimationClip(name: "Spin", duration: 5)
        _ = await document.save()
        let url = document.url
        let beforeAssembly = document.session.document.assemblyData
        XCTAssertNil(beforeAssembly)

        document.session.perform(SetAnimationDataCommand(
            before: document.session.document.animationData,
            after: Data("not animation json".utf8)))
        XCTAssertNil(document.session.document.assemblyData)
        _ = await document.save()
        document.close()

        let reopened = try await FloeCADDocument.open(at: url)
        XCTAssertEqual(reopened.summary().bodyCount, 0)
        let state = reopened.animationLoadState()
        XCTAssertEqual(state.issues.first?.kind, .corruptData)
        XCTAssertTrue(state.animation.clips.isEmpty)
        reopened.close()
    }

    func testDocumentWithoutAnimationStillLoads() async throws {
        let document = try await makeDocument()
        XCTAssertFalse(document.animationLoadState().hasStoredData)
        _ = await document.save()
        let url = document.url
        document.close()
        let opened = try await FloeCADDocument.open(at: url)
        XCTAssertTrue(opened.animationDocument.isEmpty)
        XCTAssertNil(opened.animationLoadState().storedDataSHA256)
        opened.close()
    }

    func testAnimationJSONSurfaceCreatesAndListsClip() async throws {
        let document = try await makeDocument()
        let created = document.animationJSON([
            "action": "createClip", "name": "Turntable", "duration": 4,
        ])
        XCTAssertTrue(created.isOK)
        let createdObject = try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: created.payload)) as? [String: Any])
        XCTAssertEqual(createdObject["mutated"] as? Bool, true)
        XCTAssertEqual((createdObject["animation"] as? [String: Any])?["clip_count"] as? Int, 1)

        let listed = document.animationJSON(["action": "list"])
        XCTAssertTrue(listed.isOK)
        let listObject = try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: listed.payload)) as? [String: Any])
        let clips = try XCTUnwrap(listObject["clips"] as? [[String: Any]])
        XCTAssertEqual(clips.count, 1)
        XCTAssertEqual(clips.first?["name"] as? String, "Turntable")
        XCTAssertEqual((clips.first?["duration"] as? NSNumber)?.doubleValue ?? 0,
                       4, accuracy: 1e-9)

        let exported = document.animationJSON(["action": "export"])
        XCTAssertFalse(exported.isOK)
        XCTAssertEqual(exported.errorCode, "needs_async")
        document.close()
    }

    // MARK: - Service-owned cancellation

    func testExportCenterCancellationIsReported() async throws {
        let center = CADAnimationExportCenter.shared
        let id = center.register(documentKey: "animation-test-\(UUID().uuidString)",
                                 totalFrames: 10, progress: nil)
        let task = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
            }
            center.finish(id, status: CADAnimationExportStatus(
                id: id,
                progress: CADAnimationExportProgress(
                    phase: .cancelled, completedFrames: 0, totalFrames: 10),
                error: "cancelled", isCancelled: true))
        }
        center.attach(task: task, to: id)
        center.cancel(id)
        let status = await center.wait(id)
        XCTAssertTrue(status.isCancelled)
        XCTAssertTrue(status.isFinished)
        XCTAssertEqual(status.progress.totalFrames, 10)
    }
}
