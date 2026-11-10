// SPDX-License-Identifier: MPL-2.0
// One focused App-host candidate for the merged B21 / M32 seam.
#if canImport(UIKit)
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
import FloeCore
import FloeWorkbench

@MainActor final class PreparedVideoAlphaHDRBoundaryTests: XCTestCase {
    func testFallbackHDRWithAlphaRejectsBeforeTouchingDestinationAndPreservesSavedOriginal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AlphaHDR-boundary-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.png")
        let pixels = try XCTUnwrap(CGContext(data: nil, width: 128, height: 96,
            bitsPerComponent: 8, bytesPerRow: 128 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        pixels.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 1))
        pixels.fill(CGRect(x: 0, y: 0, width: 128, height: 96))
        let image = try XCTUnwrap(pixels.makeImage())
        let encoder = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL,
            UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(encoder, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(encoder))
        let sourceBytes = try Data(contentsOf: source)

        let project = MediaProject(kind: .video, name: "Fallback HDR alpha boundary",
            canvas: .init(width: 128, height: 96, frameRate: 10, videoColorProfile: .rec2020HLG))
        let store = MediaProjectStore(directory: root.appendingPathComponent("Projects"))
        let coordinator = MediaPreparedCoordinator(store: store)
        try await store.save(project)
        _ = try await coordinator.upgradeDocument(id: project.id)
        let reference = MediaAssetReference(kind: .image, relativePath: "source.png", originalName: "source.png",
            byteCount: Int64(sourceBytes.count), contentHash: FloeDigest.sha256Hex(sourceBytes),
            metadata: .init(width: 128, height: 96))
        let range = try MediaTimeRange(start: .seconds(0), duration: .seconds(0.3))
        let track = MediaPreparedTrack(kind: .visual, name: "Original image")
        let clip = MediaPreparedClip(assetID: reference.id, timelineRange: range, sourceRange: range)
        _ = try await coordinator.applyUserOperations([
            .init(action: .insertAsset(reference)), .init(action: .insertTrack(track: track, index: nil)),
            .init(action: .insertClip(trackID: track.id, clip: clip, index: nil))
        ], to: project.id)
        let document = try await coordinator.loadDocument(id: project.id)
        // The active coordinator keeps fractional timestamps in memory;
        // the existing store persists ISO8601 seconds. Compare complete
        // durable snapshots on both sides of the refusal.
        let durableBefore = try await MediaPreparedCoordinator(store:
            MediaProjectStore(directory: root.appendingPathComponent("Projects")))
            .loadDocument(id: project.id)
        let plan = try MediaPreparedVideoDocumentAdapter.resolve(document, assetURLs: [reference.id: source], includeAudio: false)
        try plan.validateForRender() // Rejecting an invalid empty plan would prove the wrong boundary.
        XCTAssertEqual(document.canvas?.videoColorProfile, .rec2020HLG)
        XCTAssertEqual(plan.colorProfile, .rec2020HLG)

        // The caller intentionally leaves output color nil. The exporter must
        // resolve the plan's HDR profile before testing alpha compatibility.
        let settings = try PreparedVideoOutputSettings(width: 128, height: 96, frameRate: plan.frameRate,
            codec: .hevc, quality: 0.95, preservesAlpha: true)
        XCTAssertNil(settings.colorProfile)
        let resolved = settings.resolvingColorProfile(plan.colorProfile)
        XCTAssertEqual(resolved.preservesAlpha, true)
        XCTAssertEqual(resolved.colorProfile, .rec2020HLG)
        XCTAssertEqual(resolved.width, settings.width)
        XCTAssertEqual(resolved.height, settings.height)
        XCTAssertEqual(resolved.frameRate, settings.frameRate)
        XCTAssertEqual(resolved.codec, settings.codec)
        XCTAssertEqual(resolved.quality, settings.quality)
        XCTAssertTrue(resolved.identity.contains(":color=rec2020HLG") && resolved.identity.hasSuffix(":alpha"))
        let roundTrip = try JSONDecoder().decode(PreparedVideoOutputSettings.self, from: JSONEncoder().encode(resolved))
        XCTAssertEqual(roundTrip, resolved, "The merged typed output contract must retain both fields")

        // Honest sentinel bytes, not a claim that this is an encoded movie.
        // overwrite=true makes an accidentally admitted request destructive;
        // an early destinationExists rejection cannot make this test pass.
        let destination = root.appendingPathComponent("existing.mov")
        let destinationBytes = Data("previous-task-owned-destination-bytes".utf8)
        try destinationBytes.write(to: destination, options: .withoutOverwriting)
        let beforeAttributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        let projectBytes = try Data(contentsOf: store.projectURL(id: project.id))
        let namesBefore = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        let window = try PreparedVideoFrameWindow(
            range: .init(start: .init(seconds: 0, timescale: plan.timeScale), duration: plan.duration),
            frameRate: plan.frameRate)
        var rejectedForAlphaHDR = false
        do {
            _ = try await PreparedVideoExporter().renderWindow(plan: plan, window: window,
                settings: settings, destination: destination, overwrite: true,
                cancellation: PreparedVideoCancellation(), progress: { _ in })
            XCTFail("The effective HDR + alpha request must be rejected before export")
        } catch PreparedVideoError.invalidOutputSettings(let reason) {
            rejectedForAlphaHDR = reason.contains("transparent HDR")
            XCTAssertTrue(rejectedForAlphaHDR, "A different settings error is not evidence of the merged guard")
        } catch { XCTFail("Unexpected boundary error: \(error)") }

        XCTAssertTrue(rejectedForAlphaHDR)
        XCTAssertEqual(try Data(contentsOf: destination), destinationBytes)
        let afterAttributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual(afterAttributes[.systemFileNumber] as? NSNumber, beforeAttributes[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(afterAttributes[.modificationDate] as? Date, beforeAttributes[.modificationDate] as? Date)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), namesBefore,
            "No temporary video/audio/proxy must be staged before this refusal")
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
        XCTAssertEqual(try Data(contentsOf: store.projectURL(id: project.id)), projectBytes)
        let reopened = try await MediaPreparedCoordinator(store: MediaProjectStore(directory: root.appendingPathComponent("Projects")))
            .loadDocument(id: project.id)
        XCTAssertEqual(reopened, durableBefore)
        XCTAssertEqual(reopened.canvas?.videoColorProfile, .rec2020HLG)
        XCTAssertEqual(plan.colorProfile, .rec2020HLG)
        XCTAssertNil(settings.colorProfile)
        XCTAssertEqual(settings.preservesAlpha, true)
    }
}
#endif
