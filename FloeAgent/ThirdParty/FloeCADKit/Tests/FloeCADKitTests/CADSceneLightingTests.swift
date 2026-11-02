// SPDX-License-Identifier: MPL-2.0
import XCTest
import simd
import ImageIO
@testable import FloeCAD

#if canImport(RealityKit) && canImport(UIKit)
import RealityKit
import UIKit
import CoreImage
import AVFoundation

/// Real document commands, HDR decoding and the production RealityKit stage.
/// App-hosted cases deliberately fail, rather than substitute a software image,
/// when there is no foreground render surface.
@MainActor
final class CADSceneLightingTests: XCTestCase {
    private var directory: URL!
    private var documents: [FloeCADDocument] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CADSceneLighting-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        documents.forEach { $0.close() }
        documents = []
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    /// Original RGBE Radiance image: two asymmetric HDR hemispheres plus a
    /// vertical gradient. It is not an 8-bit PNG renamed with an HDR suffix.
    private func panorama() -> Data {
        let width = 64, height = 32
        var data = Data("#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y \(height) +X \(width)\n".utf8)
        for y in 0..<height {
            data.append(contentsOf: [2, 2, 0, UInt8(width)])
            for channel in 0..<4 {
                data.append(UInt8(width)) // one literal run per channel
                for x in 0..<width {
                    let value: UInt8
                    switch channel {
                    case 0: value = x < width / 2 ? 192 : 8
                    case 1: value = UInt8(16 + y * 3)
                    case 2: value = x < width / 2 ? 8 : 192
                    default: value = 131 // linear radiance reaches six
                    }
                    data.append(value)
                }
            }
        }
        return data
    }

    private func makeDocument() async throws -> FloeCADDocument {
        let document = try await FloeCADDocument.create(
            at: directory.appendingPathComponent("scene-\(UUID().uuidString).floecad"), name: "Scene lighting")
        documents.append(document)
        func command(_ json: String) throws -> [String: Any] {
            let result = document.executeJSON(Data(json.utf8))
            XCTAssertTrue(result.isOK, result.message ?? "")
            return try XCTUnwrap(try JSONSerialization.jsonObject(with: result.payload) as? [String: Any])
        }
        let sketch = try command(#"{"op":"sketch.create","args":{"name":"Slab"}}"#)
        let id = try XCTUnwrap(sketch["sketchID"] as? String)
        _ = try command("""
        {"op":"sketch.addEntities","args":{"sketchID":"\(id)","entities":[{"kind":"rect","min":[-20,-20],"max":[20,20]}]}}
        """)
        _ = try command("""
        {"op":"feature.extrude","args":{"sketchID":"\(id)","seedPoint":[0,0],"distance":20}}
        """)
        return document
    }

    private func importMap(_ document: FloeCADDocument) async throws -> CADEnvironmentMap {
        let reply = await CADMaterialService(document: document).handleAsync(
            action: "environment.import", args: ["name": "Studio.hdr", "asset_base64": panorama().base64EncodedString()])
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        return try XCTUnwrap(document.viewAppearance.environmentMap)
    }

    func testActualHDRDecodeRotationAndResourceIntegrity() throws {
        let bytes = panorama()
        var map = try CADEnvironmentMap.imported(data: bytes, name: "Studio.hdr")
        XCTAssertEqual(map.width, 64)
        XCTAssertEqual(map.height, 32)
        XCTAssertEqual(try map.checkedBytes(), bytes)
        let original = try CADEnvironmentImageDecoder.decode(map)
        func linear(_ image: CGImage) -> [Float] {
            var values = [Float](repeating: 0, count: image.width * image.height * 4)
            let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
            values.withUnsafeMutableBytes { buffer in
                CIContext(options: [.cacheIntermediates: false]).render(CIImage(cgImage: image),
                    toBitmap: buffer.baseAddress!, rowBytes: image.width * 16,
                    bounds: CGRect(x: 0, y: 0, width: image.width, height: image.height), format: .RGBAf, colorSpace: space)
            }
            return values
        }
        let first = linear(original)
        XCTAssertGreaterThan(first.max() ?? 0, 2, "HDR energy must survive decoding")
        map.rotationDegrees = 180
        let rotated = try CADEnvironmentImageDecoder.decode(map)
        let second = linear(rotated)
        XCTAssertGreaterThan(second.max() ?? 0, 2, "Yaw must not clamp HDR into 8-bit sRGB")
        let a = (16 * 64 + 8) * 4, b = (16 * 64 + 40) * 4
        XCTAssertEqual(first[a], second[b], accuracy: 0.02)
        XCTAssertEqual(first[b + 2], second[a + 2], accuracy: 0.02)
        XCTAssertNotEqual(first, second)
        map.bytes = nil
        XCTAssertThrowsError(try CADEnvironmentImageDecoder.decode(map))
        map.bytes = Data("not the original resource".utf8)
        XCTAssertThrowsError(try CADEnvironmentImageDecoder.decode(map))
        map.bytes = bytes; map.width = 32; map.height = 16
        XCTAssertThrowsError(try CADEnvironmentImageDecoder.decode(map))
        XCTAssertThrowsError(try CADEnvironmentMap.imported(data: Data([1, 2, 3]), name: "broken.hdr"))
    }

    func testNamedLightsAndHDRShareOneUndoSaveAndReopenAuthority() async throws {
        let document = try await makeDocument()
        let old = document.viewAppearance
        let map = try await importMap(document)
        let service = CADMaterialService(document: document)
        let first = CADSceneLight(name: "Window", kind: .directional, direction: [-1, -2, -1], intensity: 750)
        let second = CADSceneLight(name: "Fill", kind: .point, positionMM: [40, 80, 120], color: [0.2, 0.5, 1], intensity: 350)
        let count = document.session.undoStack.undoCommands.count
        let reply = service.handle(action: "environment.update", args: [
            "expected_change_count": document.liveChangeCount,
            "lights": [first.summaryJSON, second.summaryJSON],
            "environment_map": ["rotation_degrees": 90.0, "intensity": 0.75, "shows_background": true]])
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        XCTAssertEqual(document.session.undoStack.undoCommands.count, count + 1)
        let expected = document.viewAppearance
        XCTAssertEqual(expected.sceneLights?.map(\.id), [first.id, second.id])
        XCTAssertEqual(expected.environmentMap?.bytes, map.bytes)
        let description = String(decoding: try JSONSerialization.data(withJSONObject: reply), as: UTF8.self)
        XCTAssertFalse(description.contains(panorama().base64EncodedString()))
        document.session.undo()
        XCTAssertNil(document.viewAppearance.sceneLights)
        XCTAssertEqual(document.viewAppearance.environmentMap, map)
        document.session.redo()
        XCTAssertEqual(document.viewAppearance, expected)
        let result = await document.save()
        XCTAssertTrue(result.succeeded, result.error ?? "")
        let identity = document.modelSHA256
        document.close()
        let reopened = try await FloeCADDocument.open(at: document.url)
        documents.append(reopened)
        XCTAssertEqual(reopened.viewAppearance, expected)
        XCTAssertEqual(reopened.modelSHA256, identity)
        XCTAssertEqual(CADPresentationSceneBuilder.build(snapshot: reopened.sceneSnapshot(), documentKey: "reopened").environment.sceneLights,
                       [first, second])
        XCTAssertNotEqual(old, expected)
    }

    func testInvalidLightsAndMixedPatchesCommitNothing() async throws {
        let document = try await makeDocument()
        _ = try await importMap(document)
        let service = CADMaterialService(document: document)
        let appearance = document.viewAppearance
        let bytes = document.session.document.sceneSettingsData
        let history = document.session.undoStack.undoCommands.count
        let light = CADSceneLight(name: "Key", kind: .directional)
        let invalid: [[String: Any]] = [
            ["lights": [light.summaryJSON, light.summaryJSON]],
            ["lights": (0..<9).map { CADSceneLight(name: "Light \($0)", kind: .point).summaryJSON }],
            ["lights": [["name": "Bad", "kind": "spot", "direction": [0, 0, 0]]]],
            ["lights": [["name": "Bad", "kind": "point", "casts_shadow": true]]],
            ["lights": [["name": "Bad", "kind": "spot", "intensity": true]]],
            ["lights": [light.summaryJSON], "preset_lights": true],
            ["lights": [light.summaryJSON], "environment_map": ["intensity": -1]],
            ["environment_map": ["rotation_degrees": Double.infinity]],
            ["environment_map": ["shows_background": 1]],
            ["environment_map": ["bytes": "untrusted"]],
            ["expected_change_count": document.liveChangeCount + 1, "lights": []],
        ]
        for patch in invalid {
            let reply = service.handle(action: "environment.update", args: patch)
            XCTAssertEqual(reply["ok"] as? Bool, false, "\(patch) → \(reply)")
            XCTAssertEqual(document.viewAppearance, appearance)
            XCTAssertEqual(document.session.document.sceneSettingsData, bytes)
            XCTAssertEqual(document.session.undoStack.undoCommands.count, history)
        }
        var bad = light; bad.positionMM = []
        XCTAssertThrowsError(try bad.validate())
        bad = light; bad.direction = [Double.nan, 0, 1]
        XCTAssertThrowsError(try bad.validate())
    }

    func testCancelledAndClosedImportCannotResurrectDocument() async throws {
        let document = try await makeDocument()
        let service = CADMaterialService(document: document)
        let before = document.session.document.sceneSettingsData
        let count = document.liveChangeCount
        let args: [String: Any] = ["name": "Studio.hdr", "asset_base64": panorama().base64EncodedString()]
        let task = Task { @MainActor in
            let reply = await service.handleAsync(action: "environment.import", args: args)
            return reply["error"] as? String
        }
        task.cancel()
        let cancelled = await task.value
        XCTAssertEqual(cancelled, "cancelled")
        XCTAssertEqual(document.liveChangeCount, count)
        XCTAssertEqual(document.session.document.sceneSettingsData, before)
        document.close()
        let reply = await service.handleAsync(action: "environment.import", args: args)
        XCTAssertEqual(reply["error"] as? String, "document_closed")
        XCTAssertEqual(document.session.document.sceneSettingsData, before)
    }

    func testVersionFloorTracksRealIntentAndFutureBytesStayOpaque() throws {
        func bytes(_ presentation: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["presentation": presentation])
        }
        XCTAssertEqual(CADDocumentFormat.sceneLightingIntent(try bytes([:] )).version, CADDocumentFormat.legacyVersion)
        XCTAssertEqual(CADDocumentFormat.sceneLightingIntent(try bytes(["sceneLights": NSNull()])).version, CADDocumentFormat.legacyVersion)
        let light = CADSceneLight(name: "Key", kind: .directional)
        let row = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(light)) as? [String: Any])
        let current = try bytes(["sceneLights": [row]])
        let assessment = try CADDocumentFormat.assess(planes: [], sketches: [], sceneSettings: current)
        XCTAssertEqual(assessment.requiredVersion, CADDocumentFormat.sceneLightingVersion)
        XCTAssertFalse(assessment.isOpaqueReadOnly)
        XCTAssertEqual(CADDocumentFormat.sceneLightingIntent(try bytes(["sceneLights": []])).version, CADDocumentFormat.sceneLightingVersion)
        var future = row; future["version"] = 2
        XCTAssertTrue(try CADDocumentFormat.assess(planes: [], sketches: [], sceneSettings: bytes(["sceneLights": [future]])).isOpaqueReadOnly)
        var unknown = row; unknown["animationBinding"] = "future"
        XCTAssertTrue(CADDocumentFormat.sceneLightingIntent(try bytes(["sceneLights": [unknown]])).opaque)
        var map = try CADEnvironmentMap.imported(data: panorama(), name: "Missing.hdr")
        map.bytes = nil
        let mapRow = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(map)) as? [String: Any])
        XCTAssertFalse(CADDocumentFormat.sceneLightingIntent(try bytes(["environmentMap": mapRow])).opaque,
                       "A missing image is an explicit render issue, not unreadable geometry")
    }

    func testActualStageUsesNamedLightsAndExactMillimetres() async throws {
        let document = try await makeDocument()
        let point = CADSceneLight(name: "Blue fill", kind: .point, positionMM: [10, 20, 30], color: [0, 0, 1], intensity: 250, radiusMM: 750)
        let spot = CADSceneLight(name: "Warm key", kind: .spot, positionMM: [40, 60, 80], direction: [-1, -2, -1], color: [1, 0.3, 0], intensity: 500, castsShadow: true)
        var appearance = document.viewAppearance
        appearance.sceneLights = [point, spot]
        XCTAssertTrue(document.applyViewAppearance(appearance))
        let scene = CADPresentationSceneBuilder.build(snapshot: document.sceneSnapshot(), documentKey: "lights")
        let cache = CADPresentationResourceCache(); defer { cache.dispose() }
        let stage = try await CADPresentationEntityBuilder(cache: cache).build(scene: scene).stage
        XCTAssertEqual(stage.children.filter { $0.name.hasPrefix("CADPresentationLight-") }.count, 2)
        let a = try XCTUnwrap(stage.children.first { $0.name == "CADPresentationLight-\(point.id)" } as? PointLight)
        XCTAssertEqual(simd_length(a.position - SIMD3<Float>(0.01, 0.02, 0.03)), 0, accuracy: 1e-8,
                       "Millimetre-to-metre Float conversion must preserve placement to 0.00001 mm")
        XCTAssertEqual(a.light.intensity, 250, accuracy: 1e-5)
        XCTAssertEqual(a.light.attenuationRadius, 0.75, accuracy: 1e-5)
        let b = try XCTUnwrap(stage.children.first { $0.name == "CADPresentationLight-\(spot.id)" } as? SpotLight)
        XCTAssertEqual(b.light.intensity, 500, accuracy: 1e-5)
        XCTAssertNotNil(b.shadow)
        XCTAssertEqual(simd_length(b.orientation.act(SIMD3<Float>(0, 0, -1)) - simd_normalize(SIMD3<Float>(-1, -2, -1))), 0, accuracy: 1e-5)
    }

    func testActualResourceCacheRejectsForgedBytesAndRecovers() async throws {
        let document = try await makeDocument()
        _ = try await importMap(document)
        let cache = CADPresentationResourceCache(); defer { cache.dispose() }
        var environment = CADPresentationSceneBuilder.build(snapshot: document.sceneSnapshot(), documentKey: "map-cache").environment
        let good = environment
        let resource = await cache.environment(for: good)
        XCTAssertNotNil(resource)
        environment.environmentMap?.bytes = Data("forged".utf8)
        let bad = await cache.environment(for: environment)
        XCTAssertNil(bad, "A trusted SHA string must not make different bytes reuse a cached GPU resource")
        XCTAssertNotNil(cache.environmentFailure(for: environment))
        let repaired = await cache.environment(for: good)
        XCTAssertNotNil(repaired, "A failed decode must not permanently poison repaired source bytes")
        XCTAssertNil(cache.environmentFailure(for: good))
        cache.dispose()
        let disposed = await cache.environment(for: good)
        XCTAssertNil(disposed)
    }

    private func render(_ document: FloeCADDocument) async throws -> Data {
        let host = try XCTUnwrap(CADPresentationServiceRenderHost(document: document, width: 640, height: 480))
        defer { host.release() }
        let ready = await host.waitUntilReady(timeout: 40)
        XCTAssertTrue(ready)
        XCTAssertFalse(host.handle.issues.contains { $0.id == "environment-map" })
        // Wait actual frames after resource installation, never a generated thumbnail.
        try await Task.sleep(for: .milliseconds(400))
        return try await host.controller.snapshotPNG(targetWidth: 640).png
    }
    private func attach(_ data: Data, name: String, type: String = "public.png") {
        let item = XCTAttachment(data: data, uniformTypeIdentifier: type)
        item.name = name; item.lifetime = .keepAlways; add(item)
    }
    private func pixels(_ png: Data) throws -> [UInt8] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }

    func testActualHDRAndLightsReachStillReopenAndMoviePixels() async throws {
        let document = try await makeDocument()
        _ = try await importMap(document)
        let service = CADMaterialService(document: document)
        let key = CADSceneLight(name: "Key", kind: .directional, direction: [0, -1, -1], intensity: 700)
        let fill = CADSceneLight(name: "Fill", kind: .point, positionMM: [100, 100, 100], color: [0.2, 0.5, 1], intensity: 20)
        let update = service.handle(action: "environment.update", args: ["lights": [key.summaryJSON, fill.summaryJSON],
            "environment_map": ["rotation_degrees": 90, "intensity": 0.5, "shows_background": true]])
        XCTAssertEqual(update["ok"] as? Bool, true)
        let first = try await render(document)
        attach(first, name: "X16 X17 actual HDR and named lights")
        _ = service.handle(action: "environment.update", args: ["environment_map": ["rotation_degrees": 270, "intensity": 1.5]])
        let changed = try await render(document)
        attach(changed, name: "X16 actual rotated HDR brighter")
        let p = try pixels(first), q = try pixels(changed)
        XCTAssertEqual(p.count, q.count)
        XCTAssertGreaterThan(zip(p, q).filter { abs(Int($0) - Int($1)) > 20 }.count, p.count / 100)
        document.session.undo()
        let saved = await document.save(); XCTAssertTrue(saved.succeeded, saved.error ?? "")
        let expected = document.viewAppearance
        document.close()
        let reopened = try await FloeCADDocument.open(at: document.url); documents.append(reopened)
        XCTAssertEqual(reopened.viewAppearance, expected)
        let after = try await render(reopened)
        attach(after, name: "X16 X17 actual saved HDR lights reopened")
        let r = try pixels(after)
        XCTAssertLessThan(Double(zip(p, r).map { abs(Int($0) - Int($1)) }.reduce(0, +)) / Double(p.count), 3,
                          "The actual saved scene must reproduce its lighting, not just metadata")
        let clip = try reopened.createAnimationClip(name: "Lighting witness", duration: 0.25)
        let track = try reopened.addAnimationTrack(clipID: clip.id, target: .camera)
        for t in [0.0, 0.25] {
            _ = try reopened.setAnimationKeyframe(clipID: clip.id, trackID: track.id, time: t,
                camera: CADAnimationCameraValue(target: SIMD3(0, 0.01, 0), distance: 0.15,
                    azimuthRadians: 0, elevationRadians: 0.3, fovYDegrees: 60))
        }
        let destination = directory.appendingPathComponent("scene.mp4")
        let settings = CADAnimationExportSettings(width: 640, height: 480, frameRate: 24,
            bitrate: nil, overwrite: false, posterEnabled: true)
        let movie = try await reopened.exportAnimation(clipID: clip.id, to: destination, settings: settings)
        XCTAssertEqual(movie.frameCount, clip.frameCount(at: 24))
        XCTAssertGreaterThan(movie.byteCount, 1000)
        let asset = AVURLAsset(url: destination)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let frame = try await generator.image(at: .zero).image
        let videoPNG = try XCTUnwrap(UIImage(cgImage: frame).pngData())
        attach(videoPNG, name: "X16 X17 actual movie first frame")
        let poster = try XCTUnwrap(movie.posterPNG)
        attach(poster, name: "X16 X17 actual movie source poster")
        let vp = try pixels(videoPNG), pp = try pixels(poster)
        XCTAssertEqual(vp.count, pp.count)
        XCTAssertLessThan(Double(zip(vp, pp).map { abs(Int($0) - Int($1)) }.reduce(0, +)) / Double(vp.count), 8,
                          "Decoded movie pixels must retain the same real HDR/light frame")
        attach(try Data(contentsOf: destination), name: "X16 X17 original scene movie", type: "public.mpeg-4")
        XCTAssertEqual(reopened.viewAppearance, expected)
    }
}
#endif
