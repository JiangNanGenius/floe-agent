//
//  CADAnimationAuthoringTests.swift
//  FloeCADKitTests
//
//  X23-X25 focused source tests: supported camera/placed-instance tracks
//  persist and evaluate without changing the assembly baseline; keyframe
//  move/delete keeps stable identity and refuses duplicate times; the
//  additive timed curve really drives evaluation and the same frame-time
//  mapping the PNG/video exporter uses; old documents and old readers keep
//  their behaviour. The live RealityKit playback, actual exporter and native
//  timeline UI are Root-owned runtime acceptance, not claimed here.
//

import XCTest
import Euclid
import simd
@testable import FloeCAD

@MainActor
final class CADAnimationAuthoringTests: XCTestCase {
    private var workDir: URL!
    private var document: FloeCADDocument!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeCADAnimationAuthoring-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: workDir,
                                                withIntermediateDirectories: true)
        document = try await FloeCADDocument.create(
            at: workDir.appendingPathComponent("authoring.floecad"),
            name: "Authoring")
    }

    override func tearDown() async throws {
        document?.close()
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - Helpers

    private func camera(_ distance: Double = 1,
                        azimuth: Double = 0.2) -> CADAnimationCameraValue {
        CADAnimationCameraValue(
            target: SIMD3(0.1, 0.2, 0.3), distance: distance,
            azimuthRadians: azimuth, elevationRadians: 0.25,
            fovYDegrees: 60)
    }

    @discardableResult
    private func addPlacedPart(name: String = "Plate",
                               position: SIMD3<Double> = .zero)
    throws -> (bodyID: UUID, instanceID: UUID) {
        let body = Body(
            name: name, transform: .identity, primitive: nil,
            euclidMesh: .cube(center: Vector(0, 0, 0),
                              size: Vector(10, 10, 10)),
            revision: 1)
        document.session.perform(AddBodyCommand(body: body, title: "Test \(name)"))
        let reply = CADAssemblyService(document: document).handle(
            action: "addInstance",
            args: [
                "bodyID": body.id.raw.uuidString,
                "name": name,
                "transform": ["position": [position.x, position.y, position.z]],
            ])
        XCTAssertEqual(reply["ok"] as? Bool, true, "addInstance refused: \(reply)")
        let instanceID = try XCTUnwrap(
            UUID(uuidString: reply["id"] as? String ?? ""))
        return (body.id.raw, instanceID)
    }

    private func makeClip(trackTarget: CADAnimationTarget,
                          duration: Double = 4) throws -> (CADAnimationClip,
                                                           CADAnimationTrack) {
        let clip = try document.createAnimationClip(name: "Authoring",
                                                    duration: duration)
        let track = try document.addAnimationTrack(clipID: clip.id,
                                                   target: trackTarget)
        return (clip, track)
    }

    private func jsonObject(_ outcome: CADCommandOutcome) throws -> [String: Any] {
        try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: outcome.payload)) as? [String: Any])
    }

    private func double(_ object: [String: Any], _ key: String) -> Double? {
        (object[key] as? NSNumber)?.doubleValue
    }

    private func numbers(_ object: [String: Any], _ key: String) -> [Double]? {
        guard let values = object[key] as? [Any] else { return nil }
        let result = values.compactMap { ($0 as? NSNumber)?.doubleValue }
        return result.count == values.count ? result : nil
    }

    // MARK: - Timed curve

    func testTimedCurveSolverHitsEndpointsAndIsMonotonic() {
        let curve = CADAnimationTimingCurve(x1: 0.25, y1: 0.1,
                                            x2: 0.75, y2: 0.9)
        XCTAssertTrue(curve.isValid)
        XCTAssertEqual(curve.progress(0), 0, accuracy: 1e-12)
        XCTAssertEqual(curve.progress(1), 1, accuracy: 1e-12)
        XCTAssertEqual(curve.progress(-4), 0, accuracy: 1e-12)
        XCTAssertEqual(curve.progress(9), 1, accuracy: 1e-12)

        var previous = -Double.infinity
        for index in 0...200 {
            let value = curve.progress(Double(index) / 200)
            XCTAssertTrue(value.isFinite)
            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThanOrEqual(value, 1)
            XCTAssertGreaterThanOrEqual(value, previous - 1e-9,
                                        "the timing curve must not run backwards")
            previous = value
        }
        XCTAssertEqual(curve.progress(0.5), 0.5, accuracy: 1e-6,
                       "a symmetric curve must keep its geometric midpoint")
        XCTAssertGreaterThan(
            abs(curve.progress(0.25)
                - CADAnimationInterpolation.linear.eased(0.25)), 1e-3,
            "a custom curve must not silently behave like linear")

        XCTAssertFalse(CADAnimationTimingCurve(x1: -0.1, y1: 0,
                                               x2: 0.5, y2: 1).isValid)
        XCTAssertFalse(CADAnimationTimingCurve(x1: 0.2, y1: 0,
                                               x2: 1.1, y2: 1).isValid)
        XCTAssertFalse(CADAnimationTimingCurve(x1: 0.2, y1: -0.1,
                                               x2: 0.8, y2: 1).isValid)
        XCTAssertFalse(CADAnimationTimingCurve(x1: 0.2, y1: 0,
                                               x2: 0.8, y2: 1.1).isValid)
    }

    func testLegacyKeyframeDecodeAndOldReadersIgnoreTheAdditiveCurve() throws {
        let curved = CADAnimationKeyframe(
            time: 1, interpolation: .linear, camera: camera(),
            timingCurve: .defaultCurve)
        let data = try JSONEncoder().encode(curved)
        let decoded = try JSONDecoder().decode(CADAnimationKeyframe.self,
                                               from: data)
        XCTAssertEqual(decoded, curved)
        XCTAssertEqual(decoded.timingCurve, .defaultCurve)

        // A frozen schema-1 reader decodes the same keyframe while ignoring
        // the unknown member. That is exactly why the record cannot stay
        // schema 1: if that reader rewrites the key it drops the curve. The
        // version contract below is the protection, not the additive decode.
        struct LegacyKeyframe: Codable {
            let id: UUID
            let time: Double
            let interpolation: CADAnimationInterpolation
            let camera: CADAnimationCameraValue?
            let instance: CADAnimationInstanceValue?
        }
        let legacy = try JSONDecoder().decode(LegacyKeyframe.self, from: data)
        XCTAssertEqual(legacy.time, 1)
        XCTAssertEqual(legacy.camera?.distance, 1)
        let legacyRewrite = try JSONEncoder().encode(legacy)
        XCTAssertFalse(String(decoding: legacyRewrite, as: UTF8.self)
            .contains("timingCurve"),
            "a frozen schema-1 writer would drop the curve")

        // A brand-new/default clip must not be stamped with schema 2 merely
        // because this build can write it; the curve itself is the intent.
        XCTAssertEqual(CADAnimationDocument.legacySchemaVersion, 1)
        XCTAssertEqual(CADAnimationDocument.currentSchemaVersion, 2)
        let fresh = CADAnimationDocument()
        XCTAssertEqual(fresh.schemaVersion, CADAnimationDocument.legacySchemaVersion)
        XCTAssertEqual(fresh.requiredSchemaVersion, 1)
        let freshCurved = CADAnimationDocument(clips: [
            CADAnimationClip(name: "Curved", tracks: [
                CADAnimationTrack(target: .camera, keyframes: [curved]),
            ]),
        ])
        XCTAssertEqual(freshCurved.requiredSchemaVersion, 2)
        XCTAssertEqual(freshCurved.sanitized().schemaVersion, 2)

        // A pre-curve document (no key) decodes with nil and evaluates exactly
        // like the old interpolation formula.
        let linearKey = CADAnimationKeyframe(time: 0.5,
                                             interpolation: .easeInOut,
                                             camera: camera())
        let linearData = try JSONEncoder().encode(linearKey)
        XCTAssertFalse(String(decoding: linearData, as: UTF8.self)
            .contains("timingCurve"),
            "an absent curve must stay absent on encode")
        let oldDecoded = try JSONDecoder().decode(CADAnimationKeyframe.self,
                                                  from: linearData)
        XCTAssertNil(oldDecoded.timingCurve)
        XCTAssertEqual(oldDecoded.progress(0.25),
                       CADAnimationInterpolation.easeInOut.eased(0.25),
                       accuracy: 1e-12)

        // A malformed curve cannot change the pose at evaluation. This is
        // the last-resort evaluator fallback for a programmatic record; the
        // persisted-data path refuses edit and preserves the original bytes
        // (covered by CADAnimationVersionedPersistenceTests).
        let malformed = CADAnimationKeyframe(
            time: 0, interpolation: .easeInOut, camera: camera(),
            timingCurve: CADAnimationTimingCurve(x1: -1, y1: 0,
                                                 x2: 0.5, y2: 1))
        XCTAssertFalse(malformed.timingCurve!.isValid)
        XCTAssertEqual(malformed.progress(0.25),
                       CADAnimationInterpolation.easeInOut.eased(0.25),
                       accuracy: 1e-12)
    }

    func testEulerEditorConversionMatchesTheStoredQuaternionRotation() {
        let degrees = SIMD3<Double>(12, -24, 36)
        let quaternion = CADAnimationQuaternion.fromEulerDegrees(degrees)
        let roundTrip = CADAnimationQuaternion.eulerDegrees(from: quaternion)
        let restored = CADAnimationQuaternion.fromEulerDegrees(roundTrip)
        let vector = SIMD3<Double>(1, 2, 3)
        XCTAssertEqual(
            simd_length(CADAnimationQuaternion.rotated(vector, by: quaternion)
                - CADAnimationQuaternion.rotated(vector, by: restored)),
            0, accuracy: 1e-9)
        XCTAssertEqual(roundTrip.x, degrees.x, accuracy: 1e-9)
        XCTAssertEqual(roundTrip.y, degrees.y, accuracy: 1e-9)
        XCTAssertEqual(roundTrip.z, degrees.z, accuracy: 1e-9)
    }

    // MARK: - Part track authoring and baseline isolation

    func testPartTrackAuthoringPersistsEvaluationAndLeavesBaselineUnchanged() async throws {
        let part = try addPlacedPart(position: SIMD3(40, 0, 0))
        let initialAssembly = document.session.document.assemblyData
        let baselineBefore = try XCTUnwrap(
            document.animationSceneContext().instances[part.instanceID]?.baseline)
        let (clip, track) = try makeClip(
            trackTarget: .instance(part.instanceID,
                                   sourceBodyID: part.bodyID))

        let first = try document.setAnimationKeyframe(
            clipID: clip.id, trackID: track.id, time: 0,
            timingCurve: CADAnimationTimingCurve(
                x1: 0.2, y1: 0, x2: 0.8, y2: 1),
            instance: baselineBefore)
        let second = try document.setAnimationKeyframe(
            clipID: clip.id, trackID: track.id, time: 4,
            instance: CADAnimationInstanceValue(
                translationMM: baselineBefore.translationMM + SIMD3(60, 30, 0),
                rotation: CADAnimationQuaternion.fromEulerDegrees(
                    SIMD3(0, 0, 45))))

        XCTAssertNotEqual(first.id, second.id)
        let changeCountBeforeEvaluation = document.liveChangeCount
        let canUndoBeforeEvaluation = document.session.undoStack.canUndo

        let midpoint = try document.evaluateAnimation(
            clipID: clip.id, time: 2)
        let progress = first.timingCurve!.progress(0.5)
        let expected = baselineBefore.interpolated(
            to: second.instance!, progress: progress)
        let sampled = try XCTUnwrap(midpoint.instances[part.instanceID])
        XCTAssertEqual(sampled.translationMM.x, expected.translationMM.x,
                       accuracy: 1e-9)
        XCTAssertEqual(sampled.translationMM.y, expected.translationMM.y,
                       accuracy: 1e-9)
        XCTAssertEqual(simd_length(sampled.rotation - expected.rotation), 0,
                       accuracy: 1e-9)
        XCTAssertEqual(document.session.document.assemblyData, initialAssembly,
                       "evaluation must not write the assembly baseline")
        XCTAssertEqual(document.liveChangeCount, changeCountBeforeEvaluation)
        XCTAssertEqual(document.session.undoStack.canUndo, canUndoBeforeEvaluation)

        // Endpoints are exact key values, not a resampled approximation.
        let start = try document.evaluateAnimation(clipID: clip.id, time: 0)
        let end = try document.evaluateAnimation(clipID: clip.id, time: 4)
        XCTAssertEqual(start.instances[part.instanceID]?.translationMM.x ?? -1,
                       baselineBefore.translationMM.x, accuracy: 1e-9)
        XCTAssertEqual(end.instances[part.instanceID]?.translationMM.x ?? -1,
                       baselineBefore.translationMM.x + 60, accuracy: 1e-9)

        // The PNG/video exporter samples exactly this frame-time mapping and
        // this evaluator, so selected frames must agree with the curve.
        let segmentCurve = try XCTUnwrap(first.timingCurve)
        for frame in 0...120 {
            let time = FloeCADDocument.animationFrameTime(
                frame: frame, fps: 30, duration: clip.duration)
            let sample = try document.evaluateAnimation(
                clipID: clip.id, time: time)
            let value = try XCTUnwrap(sample.instances[part.instanceID])
            let expected = baselineBefore.interpolated(
                to: second.instance!,
                progress: segmentCurve.progress(time / clip.duration))
            XCTAssertEqual(value.translationMM.x, expected.translationMM.x,
                           accuracy: 1e-9, "frame \(frame)")
            XCTAssertEqual(value.translationMM.y, expected.translationMM.y,
                           accuracy: 1e-9, "frame \(frame)")
        }

        let outcome = await document.save()
        XCTAssertNil(outcome.error)
        let url = document.url
        document.close()
        let reopened = try await FloeCADDocument.open(at: url)
        defer { reopened.close() }
        let saved = try XCTUnwrap(reopened.animationDocument.clip(withID: clip.id))
        let savedTrack = try XCTUnwrap(saved.tracks.first { $0.id == track.id })
        XCTAssertEqual(savedTrack.keyframes.map(\.id), [first.id, second.id])
        XCTAssertEqual(savedTrack.keyframes.first?.timingCurve,
                       first.timingCurve)
        XCTAssertEqual(reopened.session.document.assemblyData, initialAssembly)
        let reopenedEnd = try reopened.evaluateAnimation(
            clipID: clip.id, time: 4)
        XCTAssertEqual(reopenedEnd.instances[part.instanceID]?.translationMM.x ?? -1,
                       baselineBefore.translationMM.x + 60, accuracy: 1e-9)
    }

    func testTrackCandidatesListOnlyVisiblePlacedLeafParts() throws {
        let visible = try addPlacedPart(name: "Visible plate",
                                        position: SIMD3(0, 0, 0))
        let hidden = try addPlacedPart(name: "Hidden plate",
                                       position: SIMD3(80, 0, 0))
        let hide = CADAssemblyService(document: document).handle(
            action: "setVisible",
            args: ["id": hidden.instanceID.uuidString, "hidden": true])
        XCTAssertEqual(hide["ok"] as? Bool, true, "\(hide)")

        let candidates = document.animationTrackCandidates()
        XCTAssertEqual(candidates.map(\.instanceID), [visible.instanceID])
        XCTAssertEqual(candidates.first?.name, "Visible plate")
        XCTAssertEqual(candidates.first?.sourceBodyID, visible.bodyID)
        XCTAssertEqual(candidates.first?.baseline.translationMM.x ?? -1, 0,
                       accuracy: 1e-9)
    }

    // MARK: - Move / delete / duplicate policy

    func testKeyframeMoveDeleteConflictAndUndoPreserveIdentity() async throws {
        let part = try addPlacedPart()
        let initialAssembly = document.session.document.assemblyData
        let (clip, track) = try makeClip(
            trackTarget: .instance(part.instanceID,
                                   sourceBodyID: part.bodyID))
        let value = CADAnimationInstanceValue(translationMM: SIMD3(0, 0, 0))
        let first = try document.setAnimationKeyframe(
            clipID: clip.id, trackID: track.id, time: 0, instance: value)
        let last = try document.setAnimationKeyframe(
            clipID: clip.id, trackID: track.id, time: 2,
            timingCurve: .defaultCurve,
            instance: CADAnimationInstanceValue(
                translationMM: SIMD3(10, 20, 30)))

        let moved = try document.moveAnimationKeyframe(
            clipID: clip.id, trackID: track.id,
            keyframeID: last.id, to: 3)
        XCTAssertEqual(moved.id, last.id)
        XCTAssertEqual(moved.time, 3, accuracy: 1e-12)
        XCTAssertEqual(moved.timingCurve, last.timingCurve)
        XCTAssertEqual(moved.instance, last.instance)

        XCTAssertThrowsError(
            try document.moveAnimationKeyframe(
                clipID: clip.id, trackID: track.id,
                keyframeID: first.id, to: 3)
        ) { error in
            XCTAssertEqual((error as? CADDocumentError)?.code,
                           "animation_keyframe_conflict")
        }
        let afterConflict = try XCTUnwrap(
            document.animationDocument.clip(withID: clip.id)?.tracks.first { $0.id == track.id })
        XCTAssertEqual(afterConflict.keyframes.map(\.id), [first.id, last.id])
        XCTAssertEqual(afterConflict.keyframes.map(\.time), [0.0, 3.0])
        XCTAssertEqual(afterConflict.keyframes.first?.instance, first.instance)

        _ = try document.removeAnimationKeyframe(
            clipID: clip.id, trackID: track.id, keyframeID: first.id)
        XCTAssertEqual(document.animationDocument.clip(withID: clip.id)?
            .tracks.first { $0.id == track.id }?.keyframes.map(\.id), [last.id])

        document.session.undo()
        let undone = try XCTUnwrap(
            document.animationDocument.clip(withID: clip.id)?.tracks.first { $0.id == track.id })
        XCTAssertEqual(undone.keyframes.map(\.id), [first.id, last.id])
        XCTAssertEqual(undone.keyframes.map(\.time), [0.0, 3.0])

        document.session.redo()
        XCTAssertEqual(document.animationDocument.clip(withID: clip.id)?
            .tracks.first { $0.id == track.id }?.keyframes.map(\.id), [last.id])
        document.session.undo()

        let outcome = await document.save()
        XCTAssertNil(outcome.error)
        let url = document.url
        document.close()
        let reopened = try await FloeCADDocument.open(at: url)
        defer { reopened.close() }
        let reopenedTrack = try XCTUnwrap(
            reopened.animationDocument.clip(withID: clip.id)?
                .tracks.first { $0.id == track.id })
        XCTAssertEqual(reopenedTrack.keyframes.map(\.id), [first.id, last.id])
        XCTAssertEqual(reopenedTrack.keyframes.map(\.time), [0.0, 3.0])
        XCTAssertEqual(reopenedTrack.keyframes.last?.timingCurve,
                       last.timingCurve)
        XCTAssertEqual(reopened.session.document.assemblyData, initialAssembly)
    }

    // MARK: - Same records through the AI JSON surface

    func testJSONSurfaceMovesEditsCurveAndExposesTheSameRecords() throws {
        let part = try addPlacedPart()
        let (clip, track) = try makeClip(
            trackTarget: .instance(part.instanceID,
                                   sourceBodyID: part.bodyID))
        let first = try document.setAnimationKeyframe(
            clipID: clip.id, trackID: track.id, time: 0,
            instance: CADAnimationInstanceValue(
                translationMM: SIMD3(0, 0, 0)))
        let last = try document.setAnimationKeyframe(
            clipID: clip.id, trackID: track.id, time: 2,
            timingCurve: CADAnimationTimingCurve(
                x1: 0.2, y1: 0, x2: 0.8, y2: 1),
            instance: CADAnimationInstanceValue(
                translationMM: SIMD3(40, 0, 0)))

        let moved = document.animationJSON([
            "action": "setKeyframe",
            "clip_id": clip.id.uuidString,
            "track_id": track.id.uuidString,
            "keyframe_id": last.id.uuidString,
            "time": 1.5,
        ])
        XCTAssertTrue(moved.isOK, "\(moved.errorCode ?? "") \(moved.message ?? "")")
        let movedObject = try jsonObject(moved)
        let movedKey = try XCTUnwrap(movedObject["keyframe"] as? [String: Any])
        XCTAssertEqual(movedKey["id"] as? String, last.id.uuidString)
        XCTAssertEqual(double(movedKey, "time") ?? -1, 1.5, accuracy: 1e-9)
        let movedInstance = try XCTUnwrap(movedKey["instance"] as? [String: Any])
        let movedTranslation = try XCTUnwrap(numbers(movedInstance,
                                                     "translation_mm"))
        XCTAssertEqual(movedTranslation[0], 40, accuracy: 1e-9,
                       "a time-only move must keep the existing value")
        XCTAssertNotNil(movedKey["timing_curve"],
                        "a time-only move must keep the existing curve")

        // The returned records are the same identities a later query reads.
        let listed = document.animationJSON(["action": "list"])
        XCTAssertTrue(listed.isOK)
        let listedObject = try jsonObject(listed)
        let clips = try XCTUnwrap(listedObject["clips"] as? [[String: Any]])
        let tracks = try XCTUnwrap(clips.first?["tracks"] as? [[String: Any]])
        let listedTrack = try XCTUnwrap(tracks.first { $0["id"] as? String == track.id.uuidString })
        let listedKeys = try XCTUnwrap(listedTrack["keyframes"] as? [[String: Any]])
        XCTAssertEqual(Set(listedKeys.compactMap { $0["id"] as? String }),
                       Set([first.id.uuidString, last.id.uuidString]))
        XCTAssertNotNil(listedKeys.first { $0["id"] as? String == last.id.uuidString }?["timing_curve"],
                        "a time-only move must keep the existing curve in the list")
        XCTAssertNil(listedKeys.first { $0["id"] as? String == first.id.uuidString }?["timing_curve"])

        // Explicit interpolation replaces the curve on that same key.
        let eased = document.animationJSON([
            "action": "updateKeyframe",
            "clip_id": clip.id.uuidString,
            "track_id": track.id.uuidString,
            "keyframe_id": last.id.uuidString,
            "time": 1.5,
            "interpolation": "easeInOut",
        ])
        XCTAssertTrue(eased.isOK, "\(eased.errorCode ?? "") \(eased.message ?? "")")
        let easedKey = try XCTUnwrap(try jsonObject(eased)["keyframe"] as? [String: Any])
        XCTAssertEqual(easedKey["interpolation"] as? String, "easeInOut")
        XCTAssertNil(easedKey["timing_curve"])

        // A custom curve authored on the segment's start key is sampled by
        // evaluate; list exposes that same record and curve.
        let custom = document.animationJSON([
            "action": "setKeyframe",
            "clip_id": clip.id.uuidString,
            "track_id": track.id.uuidString,
            "keyframe_id": first.id.uuidString,
            "time": 0,
            "timing_curve": ["x1": 0.1, "y1": 0.2, "x2": 0.9, "y2": 0.8],
        ])
        XCTAssertTrue(custom.isOK, "\(custom.errorCode ?? "") \(custom.message ?? "")")
        let customKey = try XCTUnwrap(try jsonObject(custom)["keyframe"] as? [String: Any])
        let curve = try XCTUnwrap(customKey["timing_curve"] as? [String: Any])
        XCTAssertEqual(double(curve, "x1") ?? -1, 0.1, accuracy: 1e-9)

        let relisted = document.animationJSON(["action": "list"])
        XCTAssertTrue(relisted.isOK)
        let relistedObject = try jsonObject(relisted)
        let relistedTracks = try XCTUnwrap(
            (try XCTUnwrap(relistedObject["clips"] as? [[String: Any]]))
                .first?["tracks"] as? [[String: Any]])
        let relistedKeys = try XCTUnwrap(
            relistedTracks.first { $0["id"] as? String == track.id.uuidString }?["keyframes"] as? [[String: Any]])
        let firstRow = try XCTUnwrap(
            relistedKeys.first { $0["id"] as? String == first.id.uuidString })
        XCTAssertNotNil(firstRow["timing_curve"],
                        "list must expose the curve authored on the same record")

        let sampled = document.animationJSON([
            "action": "evaluate",
            "clip_id": clip.id.uuidString,
            "time": 0.75,
        ])
        XCTAssertTrue(sampled.isOK)
        let sampledObject = try jsonObject(sampled)
        let sampledInstances = try XCTUnwrap(
            sampledObject["instances"] as? [[String: Any]])
        let sampledRow = try XCTUnwrap(
            sampledInstances.first { $0["instance_id"] as? String == part.instanceID.uuidString })
        let sampledTranslation = try XCTUnwrap(numbers(sampledRow,
                                                      "translation_mm"))
        let expectedProgress = CADAnimationTimingCurve(
            x1: 0.1, y1: 0.2, x2: 0.9, y2: 0.8).progress(0.5)
        XCTAssertEqual(sampledTranslation[0],
                       40 * expectedProgress, accuracy: 1e-9)

        // Malformed input and duplicate times refuse without a silent write.
        let beforeRefusal = document.session.document.animationData
        let badCurve = document.animationJSON([
            "action": "setKeyframe",
            "clip_id": clip.id.uuidString,
            "track_id": track.id.uuidString,
            "keyframe_id": first.id.uuidString,
            "time": 0,
            "timing_curve": ["x1": -1, "y1": 0, "x2": 0.5, "y2": 1],
        ])
        XCTAssertFalse(badCurve.isOK)
        XCTAssertEqual(badCurve.errorCode, "bad_animation_curve")
        XCTAssertEqual(document.session.document.animationData, beforeRefusal)

        let conflict = document.animationJSON([
            "action": "updateKeyframe",
            "clip_id": clip.id.uuidString,
            "track_id": track.id.uuidString,
            "keyframe_id": first.id.uuidString,
            "time": 1.5,
        ])
        XCTAssertFalse(conflict.isOK)
        XCTAssertEqual(conflict.errorCode, "animation_keyframe_conflict")
        XCTAssertEqual(document.session.document.animationData, beforeRefusal)

        let shortDuration = document.animationJSON([
            "action": "updateClip",
            "clip_id": clip.id.uuidString,
            "duration": 1.0,
        ])
        XCTAssertFalse(shortDuration.isOK)
        XCTAssertEqual(shortDuration.errorCode, "animation_duration_conflict")
        XCTAssertEqual(document.animationDocument.clip(withID: clip.id)?.duration, 4.0)

        // rotation_degrees is a real 90-degree Z rotation, not a half-angle.
        let rotated = document.animationJSON([
            "action": "setKeyframe",
            "clip_id": clip.id.uuidString,
            "track_id": track.id.uuidString,
            "time": 0.5,
            "translation_mm": [0, 0, 0],
            "rotation_degrees": [0, 0, 90],
        ])
        XCTAssertTrue(rotated.isOK, "\(rotated.errorCode ?? "") \(rotated.message ?? "")")
        let rotatedKey = try XCTUnwrap(try jsonObject(rotated)["keyframe"] as? [String: Any])
        let rotatedInstance = try XCTUnwrap(rotatedKey["instance"] as? [String: Any])
        let rotation = try XCTUnwrap(numbers(rotatedInstance, "rotation"))
        XCTAssertEqual(rotation.count, 4)
        XCTAssertEqual(rotation[0], 0, accuracy: 1e-9)
        XCTAssertEqual(rotation[1], 0, accuracy: 1e-9)
        XCTAssertEqual(rotation[2], sin(.pi / 4), accuracy: 1e-9)
        XCTAssertEqual(rotation[3], cos(.pi / 4), accuracy: 1e-9)
    }

    // MARK: - Camera curve and exporter frame times

    func testCameraCurveEvaluationMatchesExporterFrameTimes() throws {
        let (clip, track) = try makeClip(trackTarget: .camera, duration: 2)
        let start = camera(1, azimuth: 0.2)
        var end = camera(2, azimuth: 1.0)
        end.target = SIMD3(0.5, 0.2, 0.3)
        let curve = CADAnimationTimingCurve(x1: 0.2, y1: 0, x2: 0.8, y2: 1)
        _ = try document.setAnimationKeyframe(
            clipID: clip.id, trackID: track.id, time: 0,
            timingCurve: curve, camera: start)
        _ = try document.setAnimationKeyframe(
            clipID: clip.id, trackID: track.id, time: 2,
            interpolation: .linear, camera: end)

        var previousTime = -Double.infinity
        for frame in 0...60 {
            let time = FloeCADDocument.animationFrameTime(
                frame: frame, fps: 30, duration: clip.duration)
            XCTAssertGreaterThanOrEqual(time, previousTime)
            previousTime = time
            let evaluation = try document.evaluateAnimation(
                clipID: clip.id, time: time)
            let camera = try XCTUnwrap(evaluation.camera)
            let expected = start.interpolated(
                to: end, progress: curve.progress(time / clip.duration))
            XCTAssertEqual(camera.distance, expected.distance, accuracy: 1e-9)
            XCTAssertEqual(camera.azimuthRadians, expected.azimuthRadians,
                           accuracy: 1e-9)
            XCTAssertEqual(camera.target.x, expected.target.x, accuracy: 1e-9)
        }

        let midpointTime = FloeCADDocument.animationFrameTime(
            frame: 30, fps: 30, duration: clip.duration)
        let midpoint = try document.evaluateAnimation(
            clipID: clip.id, time: midpointTime)
        XCTAssertEqual(midpoint.time, 1, accuracy: 1e-12)
        XCTAssertEqual(midpoint.camera?.distance ?? -1,
                       start.distance
                        + (end.distance - start.distance)
                        * curve.progress(0.5),
                       accuracy: 1e-9)
        XCTAssertEqual(midpoint.camera?.azimuthRadians ?? -1,
                       start.azimuthRadians
                        + (end.azimuthRadians - start.azimuthRadians)
                        * curve.progress(0.5),
                       accuracy: 1e-9)
    }
}
