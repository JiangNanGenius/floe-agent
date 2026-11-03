// SPDX-License-Identifier: MPL-2.0
import XCTest
import Foundation
import simd
@testable import FloeCAD
#if canImport(UIKit) && canImport(RealityKit)
import UIKit
import RealityKit
import ImageIO
import AVFoundation
#endif

@MainActor
final class CADSpherePhysicsTests: XCTestCase {
    private var directory: URL!
    private var documents: [FloeCADDocument] = []
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SpherePhysics-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        CADSpherePhysicsService.testBeforeCompute = nil; CADSpherePhysicsService.testBeforeCommit = nil
        documents.forEach { $0.close() }; documents = []
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }
    private func sphere(_ id: Int, center: SIMD3<Double>, velocity: SIMD3<Double> = .zero,
                        mass: Double = 1, restitution: Double = 1) -> CADSpherePhysicsBody {
        let uuid = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!
        return CADSpherePhysicsBody(instanceID: uuid, sourceBodyID: uuid, sourceSHA256: String(repeating: "a", count: 64),
            localCenterMM: .zero, initialCenterMM: center, initialPlacement: .init(translationMM: center),
            worldCenterOffsetMM: .zero, radiusMM: 1, massKG: mass, restitution: restitution, velocityMMPerSecond: velocity)
    }
    private func compute(_ definition: CADSpherePhysicsDefinition) throws -> CADSpherePhysicsCache {
        try CADSpherePhysicsKernel.compute(definition, cacheID: UUID(), clipID: UUID(), cancellation: CADMeshCancellation())
    }

    func testFixedStepFreeFallMatchesClosedFormAndRepeatsExactly() throws {
        var definition = CADSpherePhysicsDefinition(); definition.duration = 1; definition.floorY = -1000
        definition.spheres = [sphere(1, center: SIMD3(0, 20000, 0))]
        let a = try compute(definition), b = try compute(definition)
        let last = try XCTUnwrap(a.frames.last)
        // Independent continuous free-flight solution, not the step formula.
        XCTAssertEqual(last.positions[0].y, 20000 - 0.5 * 9810, accuracy: 1e-8)
        XCTAssertEqual(last.velocities[0].y, -9810, accuracy: 1e-8)
        XCTAssertEqual(a.frames.count, 241); XCTAssertEqual(a.contactCount, 0)
        XCTAssertEqual(a.frames, b.frames); XCTAssertEqual(a.framesSHA256, b.framesSHA256)
        XCTAssertNotEqual(a.id, b.id, "Independent runs retain separate identities despite identical motion")
    }

    func testUnequalMassElasticCollisionConservesMomentumAndEnergy() throws {
        var definition = CADSpherePhysicsDefinition(); definition.duration = 0.75; definition.gravityY = 0; definition.floorY = -1000
        definition.spheres = [sphere(1, center: SIMD3(-2, 10, 0), velocity: SIMD3(3, 0, 0), mass: 2),
                              sphere(2, center: SIMD3(2, 10, 0), velocity: SIMD3(-1, 0, 0), mass: 1)]
        let cache = try compute(definition), last = try XCTUnwrap(cache.frames.last)
        // Closed-form two-body elastic collision: v1=1/3, v2=13/3.
        XCTAssertEqual(last.velocities[0].x, 1.0 / 3, accuracy: 1e-10)
        XCTAssertEqual(last.velocities[1].x, 13.0 / 3, accuracy: 1e-10)
        XCTAssertEqual(2 * last.velocities[0].x + last.velocities[1].x, 5, accuracy: 1e-10)
        let kinetic = simd_length_squared(last.velocities[0]) + 0.5 * simd_length_squared(last.velocities[1])
        XCTAssertEqual(kinetic, 9.5, accuracy: 1e-10)
        XCTAssertEqual(last.positions[0].x, -0.5 + 0.25 / 3, accuracy: 1e-10)
        XCTAssertEqual(last.positions[1].x, 1.5 + 0.25 * 13 / 3, accuracy: 1e-10)
        XCTAssertEqual(cache.contactCount, 1)
        var inelastic = definition
        inelastic.spheres[0].restitution = 0.5; inelastic.spheres[1].restitution = 0.5
        let rebound = try XCTUnwrap(compute(inelastic).frames.last)
        XCTAssertEqual(rebound.velocities[0].x, 1, accuracy: 1e-10)
        XCTAssertEqual(rebound.velocities[1].x, 3, accuracy: 1e-10)
        XCTAssertEqual((rebound.velocities[1].x - rebound.velocities[0].x) / 4, 0.5, accuracy: 1e-10)
        XCTAssertEqual(2 * rebound.velocities[0].x + rebound.velocities[1].x, 5, accuracy: 1e-10)
    }

    func testGroundRestitutionAndNoTunnellingMatchIndependentImpact() throws {
        var definition = CADSpherePhysicsDefinition(); definition.duration = 1.5; definition.gravityY = 0
        definition.floorRestitution = 0.75
        definition.spheres = [sphere(1, center: SIMD3(0, 5, 0), velocity: SIMD3(0, -4, 0))]
        let cache = try compute(definition), impact = try XCTUnwrap(cache.contacts.first)
        XCTAssertEqual(impact.time, 1, accuracy: 1e-10)
        XCTAssertEqual(impact.incomingNormalSpeed, -4, accuracy: 1e-10)
        XCTAssertEqual(impact.outgoingNormalSpeed, 3, accuracy: 1e-10)
        XCTAssertEqual(-impact.outgoingNormalSpeed / impact.incomingNormalSpeed, 0.75, accuracy: 1e-10)
        XCTAssertEqual(try XCTUnwrap(cache.frames.last).positions[0].y, 2.5, accuracy: 1e-10)
        XCTAssertTrue(cache.frames.allSatisfy { $0.positions[0].y >= 1 - 1e-10 })
        var overlapping = definition; overlapping.spheres.append(sphere(2, center: SIMD3(0, 5, 0)))
        XCTAssertThrowsError(try compute(overlapping))
        var excessive = definition; excessive.duration = 11
        XCTAssertThrowsError(try compute(excessive))
    }

    private func fixture() async throws -> (FloeCADDocument, UUID, BodyID) {
        let document = try await FloeCADDocument.create(at: directory.appendingPathComponent("\(UUID()).floecad"), name: "Physics")
        documents.append(document)
        let bodyID = BodyID()
        document.session.recordAndRebuild([FeatureNode(name: "Owned sphere", kind: .primitive(spec: .sphere(radius: 5),
            placement: Transform3D(translation: SIMD3(0, 50, 0))), outputBodyIDs: [bodyID])], title: "Fixture")
        let instance = CADAssemblyInstance(name: "Moving sphere", bodyID: bodyID.raw)
        document.session.perform(SetAssemblyDataCommand(before: nil, after: try CADAssembly(instances: [instance]).encoded()))
        document.session.perform(SetItemVisibilityCommand(item: .body(bodyID), isHidden: true))
        return (document, instance.id, bodyID)
    }
    private func configure(_ document: FloeCADDocument, _ id: UUID) async {
        let reply = await CADViewOverlayService(document: document).handleAsync(action: "physics.configure", args: [
            "duration": 1.0, "gravity_y": -100.0, "floor_y": 0.0,
            "spheres": [["instance_id": id.uuidString, "radius_mm": 5.0, "mass_kg": 1.0, "restitution": 0.8]]])
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        XCTAssertEqual(document.animationDocument.schemaVersion, 3, "Configured parameters must be protected before any cache/clip exists")
    }

    func testRealDocumentCacheTimelineUndoSaveReopenAndSourceInvalidation() async throws {
        let (document, id, bodyID) = try await fixture(); await configure(document, id)
        let assemblyBefore = document.session.document.assemblyData
        let transformBefore = document.session.document.body(with: bodyID)?.transform
        let undo = document.session.undoStack.undoCommands.count
        let result = await CADViewOverlayService(document: document).handleAsync(action: "physics.run", args: [:])
        XCTAssertEqual(result["ok"] as? Bool, true, "\(result)")
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undo + 1)
        let record = try XCTUnwrap(try CADSpherePhysicsCodec.record(document.session.document.sceneSettingsData))
        let cache = try XCTUnwrap(record.cache), clip = try XCTUnwrap(document.animationDocument.activeClip)
        XCTAssertEqual(clip.physicsCacheID, cache.id); XCTAssertTrue(clip.tracks.isEmpty)
        XCTAssertEqual(document.animationDocument.schemaVersion, 3)
        let get = CADViewOverlayService(document: document).handle(action: "physics.get", args: [:])
        let parameters = try XCTUnwrap(get["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["gravity_y"] as? Double, -100)
        XCTAssertEqual((parameters["spheres"] as? [[String: Any]])?.first?["instance_id"] as? String, id.uuidString)
        // Inspect persisted intent before tolerant Codable sanitization.
        var rawAnimation = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(document.session.document.animationData)) as? [String: Any])
        rawAnimation["schemaVersion"] = 2
        let invalidPhysicsHeader = CADAnimationFormat.intent(try JSONSerialization.data(withJSONObject: rawAnimation))
        XCTAssertTrue(invalidPhysicsHeader.containsPhysicsCache); XCTAssertTrue(invalidPhysicsHeader.isMalformed)
        XCTAssertEqual(invalidPhysicsHeader.requiredVersion, 7)
        let frame = try document.evaluateAnimation(clipID: clip.id, time: 0.5)
        XCTAssertEqual(frame.instances[id]?.translationMM.y ?? .nan, -12.5, accuracy: 1e-8)
        XCTAssertEqual(frame.physicsFloorYMM, 0)
        XCTAssertEqual(document.session.document.assemblyData, assemblyBefore)
        XCTAssertEqual(document.session.document.body(with: bodyID)?.transform, transformBefore)
        XCTAssertThrowsError(try document.updateAnimationClip(id: clip.id, duration: 2))
        document.session.undo()
        XCTAssertNil(try CADSpherePhysicsCodec.record(document.session.document.sceneSettingsData)?.cache)
        document.session.redo()
        let saved = await document.save(); XCTAssertTrue(saved.succeeded, saved.error ?? "")
        let url = document.url; document.close()
        let reopened = try await FloeCADDocument.open(at: url); documents.append(reopened)
        let restored = try XCTUnwrap(try CADSpherePhysicsCodec.record(reopened.session.document.sceneSettingsData)?.cache)
        XCTAssertEqual(restored.framesSHA256, cache.framesSHA256)
        XCTAssertEqual(try reopened.evaluateAnimation(clipID: clip.id, time: 0.5).instances[id]?.translationMM.y ?? .nan, -12.5, accuracy: 1e-8)
        let before = try XCTUnwrap(reopened.session.document.body(with: bodyID)).transform
        reopened.session.perform(TransformBodiesCommand(before: [bodyID: before], after: [bodyID: Transform3D(translation: SIMD3(1, 50, 0))]))
        XCTAssertThrowsError(try reopened.evaluateAnimation(clipID: clip.id, time: 0.5))
        XCTAssertEqual(CADViewOverlayService(document: reopened).handle(action: "physics.get", args: [:])["state"] as? String, "stale")
    }

    func testOffMainStaleCancelAndClosedOwnerNeverCommitLateCache() async throws {
        let (document, id, bodyID) = try await fixture(); await configure(document, id)
        let latch = SpherePhysicsTestLatch()
        CADSpherePhysicsService.testBeforeCompute = { latch.pause() }
        defer { latch.release.signal(); CADSpherePhysicsService.testBeforeCompute = nil }
        func start(external: (any MeshImportCancellationChecking)? = nil) -> Task<Data, Never> {
            Task { @MainActor in
                let reply = await CADViewOverlayService(document: document).handleAsync(action: "physics.run", args: [:], cancellation: external)
                return (try? JSONSerialization.data(withJSONObject: reply)) ?? Data()
            }
        }
        let first = start(); let firstEntered = await Task.detached { latch.wait() }.value
        XCTAssertTrue(firstEntered)
        XCTAssertFalse(latch.onMain)
        let before = try XCTUnwrap(document.session.document.body(with: bodyID)).transform
        document.session.perform(TransformBodiesCommand(before: [bodyID: before], after: [bodyID: Transform3D(translation: SIMD3(1, 50, 0))]))
        latch.release.signal()
        let firstBytes = await first.value
        let firstReply = try XCTUnwrap(try JSONSerialization.jsonObject(with: firstBytes) as? [String: Any])
        XCTAssertEqual(firstReply["error"] as? String, "physics_source_changed")
        document.session.undo()
        let second = start(); let secondEntered = await Task.detached { latch.wait() }.value
        XCTAssertTrue(secondEntered)
        let status = CADViewOverlayService(document: document).handle(action: "physics.status", args: [:])
        let runID = try XCTUnwrap(status["run_id"] as? String)
        let wrong = await CADViewOverlayService(document: document).handleAsync(action: "physics.cancel", args: ["run_id": UUID().uuidString])
        XCTAssertEqual(wrong["ok"] as? Bool, false)
        let cancel = await CADViewOverlayService(document: document).handleAsync(action: "physics.cancel", args: ["run_id": runID])
        XCTAssertEqual(cancel["cancel_requested"] as? Bool, true)
        XCTAssertEqual(CADViewOverlayService(document: document).handle(action: "physics.status", args: [:])["running"] as? Bool, true,
                       "A cancel request is not a joined terminal state")
        latch.release.signal()
        let secondBytes = await second.value
        let secondReply = try XCTUnwrap(try JSONSerialization.jsonObject(with: secondBytes) as? [String: Any])
        XCTAssertEqual(secondReply["error"] as? String, "physics_cancelled")
        XCTAssertNil(try CADSpherePhysicsCodec.record(document.session.document.sceneSettingsData)?.cache)
        // The tool-run token can be cancelled without cancelling the Swift
        // Task; it must still stop the same joined solver before any commit.
        let external = MeshImportCancellation()
        let tokenRun = start(external: external); let tokenEntered = await Task.detached { latch.wait() }.value
        XCTAssertTrue(tokenEntered); external.cancel(); latch.release.signal()
        let tokenBytes = await tokenRun.value
        let tokenReply = try XCTUnwrap(try JSONSerialization.jsonObject(with: tokenBytes) as? [String: Any])
        XCTAssertEqual(tokenReply["error"] as? String, "physics_cancelled")
        XCTAssertNil(try CADSpherePhysicsCodec.record(document.session.document.sceneSettingsData)?.cache)
        let third = start(); let thirdEntered = await Task.detached { latch.wait() }.value
        XCTAssertTrue(thirdEntered)
        document.close()
        let (replacement, _, _) = try await fixture(); let replacementCount = replacement.liveChangeCount
        latch.release.signal(); _ = await third.value
        XCTAssertEqual(replacement.liveChangeCount, replacementCount)
        XCTAssertNil(replacement.cameraSceneSettings().spherePhysics)
    }

    #if canImport(UIKit) && canImport(RealityKit)
    func testActualPresentFramesAndExistingMP4ExportUseSolvedCache() async throws {
        let (document, id, bodyID) = try await fixture()
        var material = BodyMaterialSpec.default; material.baseColor = SIMD4(0.9, 0.025, 0.025, 1); material.roughness = 0.6
        document.session.perform(SetMaterialCommand(bodyIDs: [bodyID], material: material, document: document.session.document))
        await configure(document, id)
        let result = await CADViewOverlayService(document: document).handleAsync(action: "physics.run", args: [:])
        XCTAssertEqual(result["ok"] as? Bool, true)
        let clip = try XCTUnwrap(document.animationDocument.activeClip)
        let shot = try document.saveCamera(CADSavedCamera(name: "Owned physics witness", projection: .orthographic,
            targetMM: SIMD3(0, 30, 0), distanceMM: 200, azimuthRadians: 0, elevationRadians: 0, frameAspect: 1))
        try document.selectCamera(id: shot.id)
        let saved = await document.save(); XCTAssertTrue(saved.succeeded, saved.error ?? "")
        let a = try await document.captureAnimationFramePNG(clipID: clip.id, time: 0, width: 128, height: 128)
        let b = try await document.captureAnimationFramePNG(clipID: clip.id, time: 0.7, width: 128, height: 128)
        func redCenter(_ bytes: Data) throws -> Double {
            let source = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let space = CGColorSpaceCreateDeviceRGB()
            try pixels.withUnsafeMutableBytes { data in
                let context = try XCTUnwrap(CGContext(data: data.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
            }
            var count = 0, sum = 0.0
            for y in 0..<image.height { for x in 0..<image.width {
                let i = (y * image.width + x) * 4
                if pixels[i] > 40, Double(pixels[i]) > Double(pixels[i + 1]) * 1.5,
                   Double(pixels[i]) > Double(pixels[i + 2]) * 1.5 { count += 1; sum += Double(y) }
            }}
            XCTAssertGreaterThan(count, 8, "Actual sphere pixels must exist before comparing motion")
            return sum / Double(max(count, 1))
        }
        XCTAssertGreaterThan(abs(try redCenter(a.imageData) - redCenter(b.imageData)), 3)
        XCTAssertNotEqual(a.sha256, b.sha256)
        for (name, frame) in [("physics-initial", a), ("physics-fall", b)] {
            let attachment = XCTAttachment(data: frame.imageData, uniformTypeIdentifier: "public.png")
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        let movie = try await document.exportAnimationMP4(clipID: clip.id,
            to: directory.appendingPathComponent("actual-physics.mp4"),
            settings: CADAnimationExportSettings(width: 128, height: 128, frameRate: 12, posterEnabled: false))
        XCTAssertEqual(movie.frameCount, 12); XCTAssertGreaterThan(movie.byteCount, 0)
        let asset = AVURLAsset(url: movie.url), tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first), reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil); reader.add(output)
        XCTAssertTrue(reader.startReading()); var count = 0
        while let sample = output.copyNextSampleBuffer() { count += CMSampleBufferGetNumSamples(sample) }
        XCTAssertEqual(reader.status, .completed); XCTAssertEqual(count, 12)
    }
    #endif
}

private nonisolated final class SpherePhysicsTestLatch: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    private let lock = NSLock(); private var main = true
    func pause() { lock.lock(); main = Thread.isMainThread; lock.unlock(); entered.signal(); _ = release.wait(timeout: .now() + 10) }
    func wait() -> Bool { entered.wait(timeout: .now() + 10) == .success }
    var onMain: Bool { lock.lock(); defer { lock.unlock() }; return main }
}
