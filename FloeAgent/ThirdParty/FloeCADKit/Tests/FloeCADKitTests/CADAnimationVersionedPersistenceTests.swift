//
//  CADAnimationVersionedPersistenceTests.swift
//  FloeCADKitTests
//
//  X23-X25 R2 version contract: a REAL authored timing curve raises the
//  animation header to schema 2 and the package to the existing coordinated
//  associative floor 2; an ordinary clip without a curve stays schema/floor 1.
//  Removing a curve or editing another part of the document never lowers an
//  already-higher header/floor. Malformed or future curve bytes are preserved
//  verbatim and the animation is reported uneditable instead of being decoded
//  to linear/ease and rewritten.
//
//  The frozen-reader checks are an honest SOURCE-CONTRACT mirror of the
//  released schema-1 reader policy (unknown curve member ignored; package
//  schema > 1 opens for viewing but save is refused). They are not a run of
//  the shipped 1.7.65 App binary.
//

import CryptoKit
import Foundation
import XCTest
import Euclid
import simd
@testable import FloeCAD

@MainActor
final class CADAnimationVersionedPersistenceTests: XCTestCase {
    private var workDir: URL!
    private var document: FloeCADDocument!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeCADAnimationVersioned-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: workDir,
                                                withIntermediateDirectories: true)
        document = try await FloeCADDocument.create(
            at: workDir.appendingPathComponent("versioned.floecad"),
            name: "Versioned")
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

    private func addPlacedPart(name: String = "Plate",
                               position: SIMD3<Double> = SIMD3(40, 0, 0))
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

    private struct ClipFixture {
        var clip: CADAnimationClip
        var cameraTrack: CADAnimationTrack
        var partTrack: CADAnimationTrack
        var firstKeyID: UUID
        var lastKeyID: UUID
        var partInstanceID: UUID
        var startCamera: CADAnimationCameraValue
        var endCamera: CADAnimationCameraValue
        var startPart: CADAnimationInstanceValue
        var endPart: CADAnimationInstanceValue
    }

    private func makeClip(curve: CADAnimationTimingCurve?,
                          duration: Double = 4) throws -> ClipFixture {
        let part = try addPlacedPart()
        let context = document.animationSceneContext()
        let baseline = try XCTUnwrap(
            context.instances[part.instanceID]?.baseline)
        let clip = try document.createAnimationClip(name: "Versioned",
                                                    duration: duration)
        let cameraTrack = try document.addAnimationTrack(
            clipID: clip.id, target: .camera)
        let partTrack = try document.addAnimationTrack(
            clipID: clip.id,
            target: .instance(part.instanceID, sourceBodyID: part.bodyID))
        let startCamera = camera(0.3, azimuth: 0.1)
        var endCamera = camera(0.5, azimuth: 0.9)
        endCamera.target = SIMD3(0.15, 0.2, 0.3)
        let startPart = baseline
        let endPart = CADAnimationInstanceValue(
            translationMM: baseline.translationMM + SIMD3(100, 0, 0),
            rotation: CADAnimationQuaternion.fromEulerDegrees(
                SIMD3(0, 0, 30)))
        let first = try document.setAnimationKeyframe(
            clipID: clip.id, trackID: cameraTrack.id, time: 0,
            timingCurve: curve, camera: startCamera)
        _ = try document.setAnimationKeyframe(
            clipID: clip.id, trackID: cameraTrack.id, time: duration,
            interpolation: .linear, camera: endCamera)
        _ = try document.setAnimationKeyframe(
            clipID: clip.id, trackID: partTrack.id, time: 0,
            timingCurve: curve, instance: startPart)
        let last = try document.setAnimationKeyframe(
            clipID: clip.id, trackID: partTrack.id, time: duration,
            interpolation: .linear, instance: endPart)
        return ClipFixture(
            clip: document.animationDocument.clip(withID: clip.id)!,
            cameraTrack: cameraTrack, partTrack: partTrack,
            firstKeyID: first.id, lastKeyID: last.id,
            partInstanceID: part.instanceID,
            startCamera: startCamera, endCamera: endCamera,
            startPart: startPart, endPart: endPart)
    }

    private struct PackageProbe {
        var manifestSchema: Int
        var animationSchema: Int?
        var animationData: Data
        var animationObject: [String: Any]
    }

    private func readPackage(_ url: URL) throws -> PackageProbe {
        let manifestData = try Data(contentsOf: url.appendingPathComponent("manifest.json"))
        let manifest = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        let manifestSchema = try XCTUnwrap(manifest["schemaVersion"] as? Int)
        let documentData = try Data(contentsOf: url.appendingPathComponent("document.json"))
        let documentObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: documentData) as? [String: Any])
        let encoded = try XCTUnwrap(documentObject["animation"] as? String)
        let animationData = try XCTUnwrap(Data(base64Encoded: encoded))
        let animationObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: animationData) as? [String: Any])
        let schema = (animationObject["schemaVersion"] as? NSNumber)?.intValue
        return PackageProbe(manifestSchema: manifestSchema,
                            animationSchema: schema,
                            animationData: animationData,
                            animationObject: animationObject)
    }

    private func rawKeyframe(_ object: [String: Any],
                             clipIndex: Int = 0,
                             trackIndex: Int = 0,
                             keyframeIndex: Int = 0) throws -> [String: Any] {
        let clips = try XCTUnwrap(object["clips"] as? [[String: Any]])
        let tracks = try XCTUnwrap(clips[clipIndex]["tracks"] as? [[String: Any]])
        let keys = try XCTUnwrap(tracks[trackIndex]["keyframes"] as? [[String: Any]])
        return keys[keyframeIndex]
    }

    private func save() async {
        let outcome = await document.save()
        XCTAssertNil(outcome.error, "save failed: \(outcome.error ?? "")")
    }

    private func reopen() async throws {
        let url = document.url
        document.close()
        document = try await FloeCADDocument.open(at: url)
    }

    // MARK: - Ordinary / curved / removal

    func testOrdinaryClipWithoutCurveKeepsSchemaAndFloorOne() async throws {
        _ = try makeClip(curve: nil)
        await save()
        let pkg = try readPackage(document.url)
        XCTAssertEqual(pkg.animationSchema, 1,
                       "a default clip must not be stamped schema 2")
        XCTAssertEqual(pkg.manifestSchema, 1,
                       "no new intent may raise an ordinary package floor")
        XCTAssertEqual(CADAnimationFormat.intent(pkg.animationData).requiredVersion, 1)
        XCTAssertFalse(CADAnimationFormat.intent(pkg.animationData).containsTimingCurve)

        try await reopen()
        XCTAssertEqual(document.animationDocument.schemaVersion, 1)
        let evaluation = try document.evaluateAnimation(clipID: nil, time: 2)
        XCTAssertNotNil(evaluation.camera)
    }

    func testCurveRaisesHeaderAndFloorAndSurvivesSaveReopen() async throws {
        let curve = CADAnimationTimingCurve(x1: 1.0 / 3, y1: 0,
                                            x2: 2.0 / 3, y2: 1)
        let fixture = try makeClip(curve: curve)
        await save()
        let pkg = try readPackage(document.url)
        XCTAssertEqual(pkg.animationSchema, 2)
        XCTAssertEqual(pkg.manifestSchema, 2)
        let intent = CADAnimationFormat.intent(pkg.animationData)
        XCTAssertTrue(intent.containsTimingCurve)
        XCTAssertFalse(intent.isMalformed)
        XCTAssertEqual(intent.requiredVersion, 2)
        let rawFirst = try rawKeyframe(pkg.animationObject)
        let rawCurve = try XCTUnwrap(rawFirst["timingCurve"] as? [String: Any])
        XCTAssertEqual((rawCurve["x1"] as? NSNumber)?.doubleValue ?? -1,
                       1.0 / 3, accuracy: 1e-12)

        try await reopen()
        let clip = try XCTUnwrap(
            document.animationDocument.clip(withID: fixture.clip.id))
        let cameraTrack = try XCTUnwrap(
            clip.tracks.first { $0.id == fixture.cameraTrack.id })
        let partTrack = try XCTUnwrap(
            clip.tracks.first { $0.id == fixture.partTrack.id })
        XCTAssertEqual(cameraTrack.keyframes.map(\.id),
                       [fixture.firstKeyID, cameraTrack.keyframes[1].id])
        XCTAssertEqual(cameraTrack.keyframes.first?.timingCurve, curve)
        XCTAssertEqual(partTrack.keyframes.first?.timingCurve, curve)
        XCTAssertEqual(document.animationDocument.schemaVersion, 2)

        let mid = try document.evaluateAnimation(clipID: fixture.clip.id,
                                                 time: 1)
        XCTAssertEqual(mid.camera?.distance ?? -1,
                       fixture.startCamera.interpolated(
                           to: fixture.endCamera,
                           progress: 0.15625).distance,
                       accuracy: 1e-9)
        XCTAssertEqual(mid.instances[fixture.partInstanceID]?.translationMM.x ?? -1,
                       fixture.startPart.translationMM.x + 100 * 0.15625,
                       accuracy: 1e-9)
        XCTAssertEqual(document.project.formatVersion, 2)
    }

    func testRemovingCurveNeverLowersHeaderOrPackageFloor() async throws {
        let curve = CADAnimationTimingCurve(x1: 0.2, y1: 0, x2: 0.8, y2: 1)
        let fixture = try makeClip(curve: curve)
        await save()
        let savedPackage = try readPackage(document.url)
        XCTAssertEqual(savedPackage.manifestSchema, 2)
        try await reopen()

        // Remove the curve from the segment's first camera key only; the part
        // key still carries one, so remove both and verify the header/floor.
        let cameraStart = try XCTUnwrap(
            document.animationDocument.clip(withID: fixture.clip.id)?
                .tracks.first { $0.id == fixture.cameraTrack.id }?
                .keyframes.first)
        _ = try document.setAnimationKeyframe(
            clipID: fixture.clip.id, trackID: fixture.cameraTrack.id,
            keyframeID: cameraStart.id, time: cameraStart.time,
            interpolation: .linear, clearTimingCurve: true,
            camera: cameraStart.camera)
        let partStart = try XCTUnwrap(
            document.animationDocument.clip(withID: fixture.clip.id)?
                .tracks.first { $0.id == fixture.partTrack.id }?
                .keyframes.first)
        _ = try document.setAnimationKeyframe(
            clipID: fixture.clip.id, trackID: fixture.partTrack.id,
            keyframeID: partStart.id, time: partStart.time,
            interpolation: .linear, clearTimingCurve: true,
            instance: partStart.instance)
        XCTAssertNil(document.animationDocument.clip(withID: fixture.clip.id)?
            .tracks.first { $0.id == fixture.cameraTrack.id }?
            .keyframes.first?.timingCurve)
        XCTAssertEqual(document.animationDocument.schemaVersion, 2,
                       "removing the last curve must not lower the header")

        // Model a package that already carries a HIGHER floor (e.g. a later
        // feature) and prove this edit cannot decrease it.
        document.project.formatVersion = 4
        await save()
        let pkg = try readPackage(document.url)
        XCTAssertEqual(pkg.animationSchema, 2)
        XCTAssertEqual(pkg.manifestSchema, 4)
        XCTAssertEqual(document.project.formatVersion, 4)
        try await reopen()
        XCTAssertEqual(document.animationDocument.schemaVersion, 2)
        XCTAssertEqual(document.project.formatVersion, 4)
        XCTAssertNil(document.animationDocument.clip(withID: fixture.clip.id)?
            .tracks.first { $0.id == fixture.cameraTrack.id }?
            .keyframes.first?.timingCurve)
    }

    // MARK: - Raw store claim

    private func curveDocumentData(schemaVersion: Int = 1) throws -> Data {
        let curve = CADAnimationTimingCurve(x1: 0.25, y1: 0, x2: 0.75, y2: 1)
        let keyframe = CADAnimationKeyframe(
            time: 0, interpolation: .linear, camera: camera(),
            timingCurve: curve)
        let clip = CADAnimationClip(name: "Curve", tracks: [
            CADAnimationTrack(target: .camera, keyframes: [keyframe]),
        ])
        let document = CADAnimationDocument(schemaVersion: schemaVersion,
                                            clips: [clip])
        return try CADAnimationCodec.encode(document)
    }

    private func record(animation: Data?) -> CADDocumentRecord {
        CADDocumentRecord(
            bodies: [], sketches: [], planes: [], axes: [], images: [],
            symbols: [], features: [], variables: [],
            rollbackIndex: nil, folderID: nil, itemFolders: nil,
            assembly: nil, drawings: nil, scripts: nil,
            sceneSettings: nil, materials: nil, animation: animation,
            datumPoints: nil)
    }

    private func payload(_ record: CADDocumentRecord,
                         schema: Int) -> CADWritePayload {
        CADWritePayload(
            expectedRevision: 0, schemaVersion: schema, name: "Raw",
            createdAt: Date(timeIntervalSince1970: 0),
            modifiedAt: Date(timeIntervalSince1970: 0),
            unit: nil, tolerance: nil, appBuild: "test",
            document: record, blobs: [:], thumbnail: nil)
    }

    func testSchemaOneWriterCannotClaimCurveIntent() throws {
        let curved = try curveDocumentData(schemaVersion: 1)
        let curvedRecord = record(animation: curved)
        let assessment = try CADDocumentFormat.assess(curvedRecord)
        XCTAssertEqual(assessment.requiredVersion, 2,
                       "the curve itself, not the header, raises the floor")
        XCTAssertThrowsError(try CADDocumentFormat.validateWrite(
            payload(curvedRecord, schema: 1))) { error in
            XCTAssertEqual(error as? CADDocumentFormatError,
                           Optional(CADDocumentFormatError.insufficientFormat(
                               provided: 1, required: 2)))
        }
        XCTAssertNoThrow(try CADDocumentFormat.validateWrite(
            payload(curvedRecord, schema: 2)))

        let ordinaryRecord = record(
            animation: try CADAnimationCodec.encode(CADAnimationDocument(
                clips: [CADAnimationClip(name: "Legacy")])))
        let ordinaryAssessment = try CADDocumentFormat.assess(ordinaryRecord)
        XCTAssertEqual(ordinaryAssessment.requiredVersion, 1)
        XCTAssertNoThrow(try CADDocumentFormat.validateWrite(
            payload(ordinaryRecord, schema: 1)))

        // A stored boolean control (the NSNumber 0/1 bridge) is malformed,
        // not a valid 1/0 curve, and still raises the curve floor.
        var booleanObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: curveDocumentData(schemaVersion: 1)) as? [String: Any])
        var clips = try XCTUnwrap(booleanObject["clips"] as? [[String: Any]])
        var tracks = try XCTUnwrap(clips[0]["tracks"] as? [[String: Any]])
        var keys = try XCTUnwrap(tracks[0]["keyframes"] as? [[String: Any]])
        var booleanCurve = try XCTUnwrap(
            keys[0]["timingCurve"] as? [String: Any])
        booleanCurve["x1"] = true
        keys[0]["timingCurve"] = booleanCurve
        tracks[0]["keyframes"] = keys
        clips[0]["tracks"] = tracks
        booleanObject["clips"] = clips
        let booleanData = try JSONSerialization.data(
            withJSONObject: booleanObject, options: [.sortedKeys])
        let booleanIntent = CADAnimationFormat.intent(booleanData)
        XCTAssertTrue(booleanIntent.containsTimingCurve)
        XCTAssertTrue(booleanIntent.isMalformed)
        XCTAssertEqual(booleanIntent.requiredVersion, 2)
    }

    // MARK: - Malformed / future preservation

    func testMalformedCurveBytesArePreservedAndAnimationIsUneditable() async throws {
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: curveDocumentData(schemaVersion: 2)) as? [String: Any])
        let clips = try XCTUnwrap(object["clips"] as? [[String: Any]])
        var mutatedClips = clips
        let tracks = try XCTUnwrap(mutatedClips[0]["tracks"] as? [[String: Any]])
        var keys = try XCTUnwrap(tracks[0]["keyframes"] as? [[String: Any]])
        var curve = try XCTUnwrap(keys[0]["timingCurve"] as? [String: Any])
        curve["y2"] = 1.4
        keys[0]["timingCurve"] = curve
        var mutatedTrack = tracks[0]
        mutatedTrack["keyframes"] = keys
        var mutatedClip = mutatedClips[0]
        mutatedClip["tracks"] = [mutatedTrack]
        mutatedClips[0] = mutatedClip
        object["clips"] = mutatedClips
        let bad = try JSONSerialization.data(withJSONObject: object,
                                              options: [.sortedKeys])

        let before = document.session.document.animationData
        document.session.perform(SetAnimationDataCommand(
            title: "Inject malformed curve", before: before, after: bad))
        let state = document.animationLoadState()
        XCTAssertEqual(state.issues.first?.kind, .corruptData)
        XCTAssertTrue(state.hasStoredData)
        XCTAssertEqual(state.storedDataSHA256, Self.sha256(bad))
        XCTAssertTrue(state.animation.isEmpty,
                      "unavailable animation must not pretend to be an empty new clip")
        XCTAssertTrue(CADAnimationFormat.intent(bad).isMalformed)
        XCTAssertThrowsError(try document.createAnimationClip(name: "Wipe")) {
            XCTAssertEqual(($0 as? CADDocumentError)?.code, "animation_corrupt")
        }
        XCTAssertEqual(document.session.document.animationData, bad,
                       "a refused edit must leave the raw bytes untouched")

        await save()
        let pkg = try readPackage(document.url)
        XCTAssertEqual(pkg.animationData, bad,
                       "a normal save must carry the original malformed bytes")
        XCTAssertEqual(pkg.animationSchema, 2)
        XCTAssertGreaterThanOrEqual(pkg.manifestSchema, 2)
        try await reopen()
        XCTAssertEqual(document.animationLoadState().issues.first?.kind,
                       .corruptData)
        XCTAssertEqual(document.session.document.animationData, bad)
    }

    func testFutureSchemaBytesArePreservedAndAnimationIsReadOnly() async throws {
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: curveDocumentData(schemaVersion: 2)) as? [String: Any])
        object["schemaVersion"] = CADAnimationDocument.currentSchemaVersion + 1
        let future = try JSONSerialization.data(withJSONObject: object,
                                                options: [.sortedKeys])
        let before = document.session.document.animationData
        document.session.perform(SetAnimationDataCommand(
            title: "Inject future schema", before: before, after: future))
        let state = document.animationLoadState()
        XCTAssertEqual(state.issues.first?.kind, .newerSchema)
        XCTAssertTrue(state.animation.isEmpty)
        let intent = CADAnimationFormat.intent(future)
        XCTAssertTrue(intent.isFutureSchema)
        XCTAssertEqual(intent.requiredVersion,
                       CADAnimationDocument.currentSchemaVersion + 1)
        XCTAssertThrowsError(try document.createAnimationClip(name: "Wipe")) {
            XCTAssertEqual(($0 as? CADDocumentError)?.code,
                           "animation_newer_schema")
        }
        XCTAssertEqual(document.session.document.animationData, future)

        // A future feature schema is whole-document read-only: preserve the
        // original bytes and refuse any writer rather than guessing which
        // targets the future semantics depend on.
        let futureRecord = record(animation: future)
        let futureAssessment = try CADDocumentFormat.assess(futureRecord)
        XCTAssertTrue(futureAssessment.isOpaqueReadOnly)
        XCTAssertThrowsError(try CADDocumentFormat.validateWrite(
            payload(futureRecord, schema: CADAnimationDocument.currentSchemaVersion + 1))) {
            XCTAssertEqual($0 as? CADDocumentFormatError,
                           Optional(CADDocumentFormatError.opaqueAssociations))
        }
        XCTAssertEqual(document.session.document.animationData, future,
                       "a refused future-schema write must preserve the bytes")
    }

    // MARK: - Frozen reader source contract

    func testFrozenSchemaOneReaderPolicyCannotEditCurvedPackage() throws {
        struct FrozenV1ReaderPolicy {
            static let currentFormatVersion = 1
            static func canEdit(packageSchema: Int) -> Bool {
                packageSchema <= currentFormatVersion
            }
        }
        let curve = CADAnimationTimingCurve(x1: 0.2, y1: 0, x2: 0.8, y2: 1)
        let keyframe = CADAnimationKeyframe(
            time: 0, interpolation: .linear, camera: camera(),
            timingCurve: curve)
        let data = try JSONEncoder().encode(keyframe)
        struct FrozenKeyframeV1: Codable {
            let id: UUID
            let time: Double
            let interpolation: CADAnimationInterpolation
            let camera: CADAnimationCameraValue?
            let instance: CADAnimationInstanceValue?
        }
        let frozen = try JSONDecoder().decode(FrozenKeyframeV1.self, from: data)
        XCTAssertEqual(frozen.time, 0)
        let rewritten = try JSONEncoder().encode(frozen)
        XCTAssertFalse(String(decoding: rewritten, as: UTF8.self)
            .contains("timingCurve"),
            "the frozen schema-1 reader provably drops the curve on rewrite")

        // The released policy opens a package above its format for viewing but
        // refuses to save it. R2 must therefore publish schema/floor 2 for a
        // document carrying this keyframe, which rule 4 above also proves.
        XCTAssertTrue(FrozenV1ReaderPolicy.canEdit(packageSchema: 1))
        XCTAssertFalse(FrozenV1ReaderPolicy.canEdit(packageSchema: 2))
        // The frozen animation reader sees schema 2 as newer than its own 1
        // and refuses animation edits; this is the animation-level half of the
        // same contract, while the package floor above blocks a whole save.
        struct FrozenV1AnimationPolicy {
            static let currentSchemaVersion = 1
            static func canEdit(schemaVersion: Int) -> Bool {
                schemaVersion <= currentSchemaVersion
            }
        }
        XCTAssertTrue(FrozenV1AnimationPolicy.canEdit(schemaVersion: 1))
        XCTAssertFalse(FrozenV1AnimationPolicy.canEdit(
            schemaVersion: CADAnimationDocument.timingCurveSchemaVersion))
    }

    // MARK: - AI JSON curve parser

    func testCurveJSONRejectsBooleanNonFiniteAndOutOfRangeControls() throws {
        let fixture = try makeClip(curve: nil)
        let before = document.session.document.animationData
        let badCurves: [[String: Any]] = [
            ["x1": true, "y1": 0, "x2": 0.5, "y2": 1],
            ["x1": false, "y1": 0, "x2": 0.5, "y2": 1],
            ["x1": "0.5", "y1": 0, "x2": 0.5, "y2": 1],
            ["x1": Double.infinity, "y1": 0, "x2": 0.5, "y2": 1],
            ["x1": -0.1, "y1": 0, "x2": 0.5, "y2": 1],
            ["x1": 0.2, "y1": 0, "x2": 0.8, "y2": 1.2],
        ]
        for curve in badCurves {
            let outcome = document.animationJSON([
                "action": "setKeyframe",
                "clip_id": fixture.clip.id.uuidString,
                "track_id": fixture.cameraTrack.id.uuidString,
                "keyframe_id": fixture.firstKeyID.uuidString,
                "time": 0,
                "timing_curve": curve,
            ])
            XCTAssertFalse(outcome.isOK, "must refuse \(curve)")
            XCTAssertEqual(outcome.errorCode, "bad_animation_curve")
            XCTAssertEqual(document.session.document.animationData, before)
        }
        let notAnObject = document.animationJSON([
            "action": "setKeyframe",
            "clip_id": fixture.clip.id.uuidString,
            "track_id": fixture.cameraTrack.id.uuidString,
            "keyframe_id": fixture.firstKeyID.uuidString,
            "time": 0,
            "timing_curve": true,
        ])
        XCTAssertFalse(notAnObject.isOK)
        XCTAssertEqual(notAnObject.errorCode, "bad_animation_curve")
        XCTAssertEqual(document.session.document.animationData, before)

        // Numeric 0 and 1 are REAL in-range controls and stay valid.
        let good = document.animationJSON([
            "action": "setKeyframe",
            "clip_id": fixture.clip.id.uuidString,
            "track_id": fixture.cameraTrack.id.uuidString,
            "keyframe_id": fixture.firstKeyID.uuidString,
            "time": 0,
            "timing_curve": ["x1": 0, "y1": 0, "x2": 1, "y2": 1],
        ])
        XCTAssertTrue(good.isOK, "\(good.errorCode ?? "") \(good.message ?? "")")
        let key = try XCTUnwrap(
            (try JSONSerialization.jsonObject(with: good.payload)) as? [String: Any])
        let written = try XCTUnwrap(key["keyframe"] as? [String: Any])
        let curve = try XCTUnwrap(written["timing_curve"] as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(curve["x1"] as? NSNumber).doubleValue, 0)
        XCTAssertEqual(try XCTUnwrap(curve["x2"] as? NSNumber).doubleValue, 1)
        XCTAssertEqual(document.animationDocument.schemaVersion, 2)
    }

    private static func sha256(_ data: Data) -> String {
        var hash = SHA256()
        hash.update(data: data)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
