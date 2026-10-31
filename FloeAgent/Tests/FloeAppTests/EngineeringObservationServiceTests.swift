// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import CoreGraphics
import FloeCAD
import Foundation
import ImageIO
import Testing
import UIKit
@testable import FloeApp
import FloeCore
import FloeWorkbench
import FloeWorkspace

private func appendFloat(_ value: Float, to data: inout Data) {
    var bits = value.bitPattern.littleEndian
    withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
}

@Suite("Original model WebGL observation", .serialized)
@MainActor
struct EngineeringObservationServiceTests {
    private func fixture() throws -> (URL, WorkspaceFileService, Data) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("model-observation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var positions = Data()
        for value: Float in [-1, 0, 0, 1, 0, 0, 0, 1.5, 0] {
            appendFloat(value, to: &positions)
        }
        let positionByteCount = positions.count
        // A one-second translation clip so selected clip/time is an actual
        // scene selection, not a static first frame.
        for value: Float in [0, 1] { appendFloat(value, to: &positions) }
        for value: Float in [0, 0, 2, 1, 0, 2] { appendFloat(value, to: &positions) }
        var nodes: [[String: Any]] = [
            ["name": "Main", "children": Array(2..<242)],
            ["name": "Alternative", "mesh": 0, "translation": [0, 0, 2]]
        ]
        for index in 0..<240 {
            nodes.append(["name": "Part \(index)", "mesh": 0,
                          "translation": [Double(index % 20) * 2.5, Double(index / 20) * 2, 0]])
        }
        let object: [String: Any] = [
            "asset": ["version": "2.0"], "scene": 0,
            "scenes": [["name": "Assembly", "nodes": [0]], ["name": "Alternative", "nodes": [1]]],
            "nodes": nodes,
            "meshes": [["primitives": [["attributes": ["POSITION": 0], "material": 0]]]],
            "materials": [["doubleSided": true, "pbrMetallicRoughness": [
                "baseColorFactor": [0.2, 0.6, 0.9, 1.0], "metallicFactor": 0.1, "roughnessFactor": 0.6]]],
            "accessors": [
                ["bufferView": 0, "componentType": 5126, "count": 3,
                 "type": "VEC3", "min": [-1, 0, 0], "max": [1, 1.5, 0]],
                ["bufferView": 1, "componentType": 5126, "count": 2,
                 "type": "SCALAR", "min": [0], "max": [1]],
                ["bufferView": 2, "componentType": 5126, "count": 2, "type": "VEC3"]
            ],
            "bufferViews": [
                ["buffer": 0, "byteOffset": 0, "byteLength": positionByteCount],
                ["buffer": 0, "byteOffset": positionByteCount, "byteLength": 8],
                ["buffer": 0, "byteOffset": positionByteCount + 8, "byteLength": 24]
            ],
            "animations": [[
                "name": "Slide",
                "samplers": [["input": 1, "output": 2, "interpolation": "LINEAR"]],
                "channels": [["sampler": 0, "target": ["node": 1, "path": "translation"]]]
            ]],
            "buffers": [["byteLength": positions.count,
                "uri": "data:application/octet-stream;base64,\(positions.base64EncodedString())"]]
        ]
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try bytes.write(to: root.appendingPathComponent("assembly.gltf"))
        return (root, WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root)), bytes)
    }

    /// Asymmetric wedge: every view is expected to produce different real
    /// pixels, and the second fixture is used for source-change fencing.
    private func stlFixture(name: String = "wedge.stl", xOffset: Float = 0)
        throws -> (URL, WorkspaceFileService, Data) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stl-observation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let triangles: [[[Float]]] = [
            [[0, 0, 0], [2, 0, 0], [0, 1, 0]],
            [[0, 0, 0], [0, 1, 0], [0, 0, 3]],
            [[0, 0, 0], [0, 0, 3], [2, 0, 0]],
            [[2, 0, 0], [0, 0, 3], [0, 1, 0]]
        ]
        var data = Data(repeating: 0, count: 80)
        var count = UInt32(triangles.count).littleEndian
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        for triangle in triangles {
            appendFloat(0, to: &data)
            appendFloat(0, to: &data)
            appendFloat(0, to: &data)
            for vertex in triangle {
                appendFloat(vertex[0] + xOffset, to: &data)
                appendFloat(vertex[1], to: &data)
                appendFloat(vertex[2], to: &data)
            }
            data.append(contentsOf: [UInt8(0), UInt8(0)])
        }
        try data.write(to: root.appendingPathComponent(name))
        return (root, WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root)), data)
    }

    private func metadata(_ frame: CadModelObservationFrame) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(
            with: Data(frame.metadataJSON.utf8)) as? [String: Any])
    }

    private func expectPNG(_ frame: CadModelObservationFrame, width: Int, height: Int) throws {
        #expect(frame.pngData.count > 1000)
        let image = try #require(CGImageSourceCreateWithData(frame.pngData as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == width)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == height)
    }

    @Test("actual original-scene pixels, complete hierarchy pages and selected scenes are source-bound")
    func originalScenePixelsAndHierarchy() async throws {
        let (root, service, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let digest = FloeDigest.sha256Hex(original)
        let request = CadModelObservationRequest(
            views: [.init(azimuthDegrees: 35, elevationDegrees: 20),
                    .init(azimuthDegrees: 215, elevationDegrees: 20)],
            width: 320, height: 240, sceneIndex: 0, expectedSourceSHA256: digest,
            nodeOffset: 200, nodeLimit: 100)
        let result = try await EngineeringObservationService.shared.observe(
            path: "assembly.gltf", service: service, request: request)
        #expect(result.frames.count == 2)
        let summary = try #require(try JSONSerialization.jsonObject(with: Data(result.summaryJSON.utf8)) as? [String: Any])
        #expect(summary["backend"] as? String == "threeGLTF")
        let hierarchy = try #require(summary["hierarchy"] as? [String: Any])
        // This is the live render graph: the selected glTF scene root,
        // Main and its240 mesh children. The scene root is intentionally
        // retained, distinct from a source glTF node or native CAD topology.
        let pageBytes = try JSONSerialization.data(withJSONObject: hierarchy)
        let page = try JSONDecoder().decode(EngineeringSceneHierarchyPage.self, from: pageBytes)
        #expect(page.total == 242)
        #expect(page.offset == 200)
        #expect(page.sceneIndex == 0)
        #expect(page.nodes.count == 42)
        #expect(page.nodes.map(\.name) == (198..<240).map { "Part_\($0)" })
        #expect(Set(page.nodes.map(\.path)).count == 42)
        #expect(page.nextOffset == nil)
        let stateObject = try #require(summary["state"] as? [String: Any])
        let visibleNodes = try #require(stateObject["nodes"] as? [[String: Any]])
        #expect(visibleNodes.prefix(2).compactMap { $0["name"] as? String } == ["Assembly", "Main"])
        Attachment.record(result.summaryJSON, named: "original-scene-observation.json")
        #expect(summary["sourceUnchanged"] as? Bool == true)
        for (index, frame) in result.frames.enumerated() {
            Attachment.record(Array(frame.pngData), named: "original-scene-view-\(index).png")
            Attachment.record(frame.metadataJSON, named: "original-scene-view-\(index).json")
            try expectPNG(frame, width: 320, height: 240)
            #expect(frame.metadataJSON.contains(digest))
            #expect(frame.metadataJSON.contains(FloeDigest.sha256Hex(frame.pngData)))
            let meta = try metadata(frame)
            #expect(meta["projection"] as? String == "perspective")
            #expect(meta["renderer"] as? String == "threeGLTF")
        }
        #expect(result.frames[0].pngData != result.frames[1].pngData)
        #expect(try Data(contentsOf: root.appendingPathComponent("assembly.gltf")) == original)

        let alternative = try await EngineeringObservationService.shared.observe(
            path: "assembly.gltf", service: service,
            request: .init(sceneIndex: 1, expectedSourceSHA256: digest, includeImages: false))
        #expect(alternative.frames.isEmpty)
        let alternativeObject = try #require(try JSONSerialization.jsonObject(
            with: Data(alternative.summaryJSON.utf8)) as? [String: Any])
        let state = try #require(alternativeObject["state"] as? [String: Any])
        #expect(state["activeSceneIndex"] as? Int == 1)
        #expect(state["meshCount"] as? Int == 1)
    }

    @Test("glTF capture keeps the selected clip/time and applies the requested projection")
    func glTFSelectedTimeAndProjection() async throws {
        let (root, service, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let digest = FloeDigest.sha256Hex(original)
        let result = try await EngineeringObservationService.shared.observe(
            path: "assembly.gltf", service: service,
            request: .init(
                views: [.init(azimuthDegrees: 35, elevationDegrees: 20),
                        .init(azimuthDegrees: 125, elevationDegrees: 20)],
                width: 320, height: 240, clipIndex: 0, timeSeconds: 0.5,
                projection: .orthographic, expectedSourceSHA256: digest))
        #expect(result.frames.count == 2)
        for frame in result.frames {
            let meta = try metadata(frame)
            #expect(meta["projection"] as? String == "orthographic")
            #expect(meta["renderer"] as? String == "threeGLTF")
            #expect((meta["timeSeconds"] as? NSNumber)?.doubleValue == 0.5)
            #expect(meta["clipIndex"] as? Int == 0)
            try expectPNG(frame, width: 320, height: 240)
        }
        #expect(result.frames[0].pngData != result.frames[1].pngData)
    }

    @Test("original STL renders actual perspective and orthographic views with distinct real PNGs")
    func staticSTLPixels() async throws {
        let (root, service, original) = try stlFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let digest = FloeDigest.sha256Hex(original)
        let perspective = try await EngineeringObservationService.shared.observe(
            path: "wedge.stl", service: service,
            request: .init(
                views: [.init(azimuthDegrees: 35, elevationDegrees: 20),
                        .init(azimuthDegrees: 215, elevationDegrees: 20),
                        .init(azimuthDegrees: 305, elevationDegrees: -15)],
                width: 320, height: 240, projection: .perspective,
                expectedSourceSHA256: digest))
        #expect(perspective.frames.count == 3)
        let summary = try #require(try JSONSerialization.jsonObject(
            with: Data(perspective.summaryJSON.utf8)) as? [String: Any])
        #expect(summary["backend"] as? String == "online3DViewer")
        #expect(summary["sourceUnchanged"] as? Bool == true)
        let state = try #require(summary["state"] as? [String: Any])
        #expect(state["backend"] as? String == "online3DViewer")
        #expect((state["clips"] as? [Any])?.isEmpty == true)
        #expect((state["cameras"] as? [Any])?.isEmpty == true)
        #expect(state["bounds"] is [String: Any])
        let hierarchy = try #require(summary["hierarchy"] as? [String: Any])
        // A simple STL imports as the model root carrying one mesh; the full
        // hierarchy is still the actual imported tree, not a fixed 200-node
        // surface. Multi-node paging is covered by the adapter fixture tests.
        #expect((hierarchy["total"] as? Int ?? 0) >= 1)
        #expect(hierarchy["sourceSHA256"] as? String == digest)
        var hashes = Set<String>()
        for (index, frame) in perspective.frames.enumerated() {
            Attachment.record(Array(frame.pngData), named: "static-original-perspective-\(index).png")
            Attachment.record(frame.metadataJSON, named: "static-original-perspective-\(index).json")
            let meta = try metadata(frame)
            #expect(meta["projection"] as? String == "perspective")
            #expect(meta["renderer"] as? String == "online3DViewer")
            #expect(meta["sourceSHA256"] as? String == digest)
            #expect(meta["width"] as? Int == 320)
            #expect(meta["height"] as? Int == 240)
            try expectPNG(frame, width: 320, height: 240)
            let hash = FloeDigest.sha256Hex(frame.pngData)
            hashes.insert(hash)
            #expect(frame.metadataJSON.contains(hash))
        }
        #expect(hashes.count == 3)
        #expect(try Data(contentsOf: root.appendingPathComponent("wedge.stl")) == original)

        let orthographic = try await EngineeringObservationService.shared.observe(
            path: "wedge.stl", service: service,
            request: .init(
                views: [.init(azimuthDegrees: 0, elevationDegrees: 0),
                        .init(azimuthDegrees: 90, elevationDegrees: 10)],
                width: 320, height: 240, projection: .orthographic,
                expectedSourceSHA256: digest))
        #expect(orthographic.frames.count == 2)
        for (index, frame) in orthographic.frames.enumerated() {
            Attachment.record(Array(frame.pngData), named: "static-original-orthographic-\(index).png")
            let meta = try metadata(frame)
            #expect(meta["projection"] as? String == "orthographic")
            #expect(meta["renderer"] as? String == "online3DViewer")
            try expectPNG(frame, width: 320, height: 240)
        }
        #expect(orthographic.frames[0].pngData != orthographic.frames[1].pngData)
        #expect(Set(orthographic.frames.map { FloeDigest.sha256Hex($0.pngData) }).count == 2)
    }

    @Test("static originals refuse unsupported scene, camera, clip and time selections")
    func staticSelectionRefusals() async throws {
        let (root, service, original) = try stlFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let digest = FloeDigest.sha256Hex(original)
        let requests: [CadModelObservationRequest] = [
            .init(sceneIndex: 1, includeImages: false),
            .init(cameraIndex: 0, includeImages: false),
            .init(clipIndex: 0, includeImages: false),
            .init(timeSeconds: 1, includeImages: false)
        ]
        for request in requests {
            await #expect(throws: (any Error).self) {
                try await EngineeringObservationService.shared.observe(
                    path: "wedge.stl", service: service, request: request)
            }
        }
        // The valid static scene selector is scene 0.
        let valid = try await EngineeringObservationService.shared.observe(
            path: "wedge.stl", service: service,
            request: .init(sceneIndex: 0, expectedSourceSHA256: digest, includeImages: false))
        #expect(valid.frames.isEmpty)
    }

    @Test("a changed static original is refused under its old hash and accepted fresh")
    func staticSourceFence() async throws {
        let (root, service, original) = try stlFixture()
        let replacement = try stlFixture(name: "replacement.stl", xOffset: 4)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: replacement.0)
        }
        let digest = FloeDigest.sha256Hex(original)
        let first = try await EngineeringObservationService.shared.observe(
            path: "wedge.stl", service: service,
            request: .init(expectedSourceSHA256: digest, includeImages: false))
        #expect(first.frames.isEmpty)
        try replacement.2.write(to: root.appendingPathComponent("wedge.stl"), options: .atomic)
        await #expect(throws: (any Error).self) {
            try await EngineeringObservationService.shared.observe(
                path: "wedge.stl", service: service,
                request: .init(expectedSourceSHA256: digest, includeImages: false))
        }
        let freshDigest = FloeDigest.sha256Hex(replacement.2)
        let fresh = try await EngineeringObservationService.shared.observe(
            path: "wedge.stl", service: service,
            request: .init(expectedSourceSHA256: freshDigest, includeImages: false))
        #expect(fresh.summaryJSON.contains(freshDigest))
    }

    @Test("stale identity and cancellation refuse before any image is returned, then a fresh request can run")
    func staleIdentityAndCancellation() async throws {
        let (root, service, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: (any Error).self) {
            try await EngineeringObservationService.shared.observe(path: "assembly.gltf", service: service,
                request: .init(expectedSourceSHA256: String(repeating: "0", count: 64)))
        }
        let cancelled = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(100))
            return try await EngineeringObservationService.shared.observe(
                path: "assembly.gltf", service: service, request: .init(includeImages: false))
        }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let fresh = try await EngineeringObservationService.shared.observe(
            path: "assembly.gltf", service: service, request: .init(includeImages: false))
        #expect(fresh.summaryJSON.contains("sourceUnchanged"))
        #expect(fresh.frames.isEmpty)
    }

    #if DEBUG
    @Test("a sibling buffer changed after actual capture invalidates every old frame")
    func resourceMutationDuringCaptureRejectsOldFrames() async throws {
        let (root, service, embedded) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var model = try #require(try JSONSerialization.jsonObject(with: embedded) as? [String: Any])
        var buffers = try #require(model["buffers"] as? [[String: Any]])
        let uri = try #require(buffers[0]["uri"] as? String)
        let encoded = try #require(uri.split(separator: ",", maxSplits: 1).last)
        let originalBuffer = try #require(Data(base64Encoded: String(encoded)))
        buffers[0]["uri"] = "positions.bin"
        model["buffers"] = buffers
        let sourceBytes = try JSONSerialization.data(withJSONObject: model, options: [.sortedKeys])
        let sourceURL = root.appendingPathComponent("assembly.gltf")
        let bufferURL = root.appendingPathComponent("positions.bin")
        try sourceBytes.write(to: sourceURL)
        try originalBuffer.write(to: bufferURL)
        let sourceHash = FloeDigest.sha256Hex(sourceBytes)
        var changedBuffer = originalBuffer
        var firstCoordinate = Data()
        appendFloat(-0.5, to: &firstCoordinate)
        changedBuffer.replaceSubrange(0..<4, with: firstCoordinate)
        let observer = EngineeringObservationService()
        var validatedFrames = 0
        observer.testBeforeSourceRevalidation = { count in
            validatedFrames = count
            try changedBuffer.write(to: bufferURL, options: .atomic)
        }
        defer { observer.testBeforeSourceRevalidation = nil }
        let request = CadModelObservationRequest(
            views: [.init(azimuthDegrees: 35, elevationDegrees: 20)],
            width: 320, height: 240, expectedSourceSHA256: sourceHash)
        var rejection: (any Error)?
        do {
            _ = try await observer.observe(path: "assembly.gltf", service: service, request: request)
        } catch { rejection = error }
        #expect(validatedFrames == 1, "the race must happen after a real PNG was validated")
        let error = try #require(rejection)
        #expect(error.localizedDescription.contains("changed during capture"))
        #expect(try Data(contentsOf: sourceURL) == sourceBytes,
                "the main file alone did not change; resource identity must fence the image")

        observer.testBeforeSourceRevalidation = nil
        let fresh = try await observer.observe(path: "assembly.gltf", service: service, request: request)
        #expect(fresh.frames.count == 1)
        #expect(fresh.summaryJSON.contains(FloeDigest.sha256Hex(changedBuffer)))
        #expect(!fresh.summaryJSON.contains(FloeDigest.sha256Hex(originalBuffer)))
        Attachment.record(Array(fresh.frames[0].pngData), named: "fresh-after-resource-mutation.png")
    }
    #endif

    @Test("cancelling a static observation leaves the next request runnable")
    func staticCancelThenFresh() async throws {
        let (root, service, _) = try stlFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let cancelled = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(100))
            return try await EngineeringObservationService.shared.observe(
                path: "wedge.stl", service: service, request: .init(includeImages: false))
        }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let fresh = try await EngineeringObservationService.shared.observe(
            path: "wedge.stl", service: service, request: .init(includeImages: false))
        #expect(fresh.summaryJSON.contains("sourceUnchanged"))
    }

    // MARK: - Original STEP / resource-backed OBJ qualification

    /// A real `FloeCADDocument` plate with a Ø10 through hole, exported through
    /// the production OCCT STEP writer. The document owner is closed before the
    /// observer sees the file; the observer gets only original STEP bytes.
    private func stepOriginalFixture()
        async throws -> (root: URL, service: WorkspaceFileService,
                         sourceURL: URL, sourceBytes: Data) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("step-original-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let packageURL = root.appendingPathComponent("fixture-\(UUID()).floecad")
        let document = try await FloeCADDocument.create(at: packageURL, name: "Observation Plate")
        let exported: Data
        do {
            let plate = try cadCommand(document, #"{"op":"sketch.create","args":{"name":"Plate"}}"#)
            let plateSketch = try #require(plate["sketchID"] as? String)
            _ = try cadCommand(document, """
            {"op":"sketch.addEntities","args":{"sketchID":"\(plateSketch)",
             "entities":[{"kind":"rect","min":[0,0],"max":[100,60]}]}}
            """)
            let extrude = try cadCommand(document, """
            {"op":"feature.extrude","args":{"sketchID":"\(plateSketch)",
             "seedPoint":[50,30],"distance":10}}
            """)
            let bodyID = try #require((extrude["producedBodyIDs"] as? [String])?.first
                ?? (extrude["changedBodyIDs"] as? [String])?.first)
            // The off-centre hole makes both views genuinely asymmetric and
            // proves the STEP writer carries a real analytic OCCT solid, not a
            // synthetic mesh.
            let hole = try cadCommand(document, #"{"op":"sketch.create","args":{"name":"Hole"}}"#)
            let holeSketch = try #require(hole["sketchID"] as? String)
            _ = try cadCommand(document, """
            {"op":"sketch.addEntities","args":{"sketchID":"\(holeSketch)",
             "entities":[{"kind":"circle","center":[35,22],"radius":5}]}}
            """)
            _ = try cadCommand(document, """
            {"op":"feature.hole","args":{"sketchID":"\(holeSketch)","seedPoint":[35,22],
             "targetBodyID":"\(bodyID)","type":"throughAll"}}
            """)
            let saved = await document.save()
            try #require(saved.succeeded, "the real STEP fixture document must commit")
            switch document.nativeExportData(format: "step", pageID: nil) {
            case .success(let result):
                exported = result.data
            case .failure(let error):
                throw FloeError.validationFailed(
                    "the native OCCT STEP export failed: \(error.message)")
            }
        } catch {
            document.close()
            throw error
        }
        // The owner is closed before the read-only observation starts.
        document.close()
        try #require(String(decoding: exported.prefix(12), as: UTF8.self) == "ISO-10303-21",
                     "the fixture must be a genuine STEP exchange file")
        let sourceURL = root.appendingPathComponent("plate.step")
        try exported.write(to: sourceURL)
        return (root, WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root)),
                sourceURL, exported)
    }

    private func cadCommand(_ document: FloeCADDocument,
                            _ json: String) throws -> [String: Any] {
        let outcome = document.executeJSON(Data(json.utf8))
        try #require(outcome.isOK,
                     "CAD fixture command failed (\(outcome.errorCode ?? "")): \(outcome.message ?? "")")
        return try #require(try JSONSerialization.jsonObject(
            with: outcome.payload) as? [String: Any])
    }

    private func objOriginalFixture(texture: UIColor,
                                    missingTexture: Bool = false) throws -> OBJOriginalFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("obj-original-\(UUID())")
        let models = root.appendingPathComponent("models")
        let materials = models.appendingPathComponent("materials")
        let textures = materials.appendingPathComponent("textures")
        try FileManager.default.createDirectory(at: textures, withIntermediateDirectories: true)

        let halfX = 20.0, halfY = 12.0, halfZ = 8.0
        let v0 = SIMD3<Double>(-halfX, -halfY, -halfZ)
        let v1 = SIMD3<Double>(halfX, -halfY, -halfZ)
        let v2 = SIMD3<Double>(halfX, halfY, -halfZ)
        let v3 = SIMD3<Double>(-halfX, halfY, -halfZ)
        let v4 = SIMD3<Double>(-halfX, -halfY, halfZ)
        let v5 = SIMD3<Double>(halfX, -halfY, halfZ)
        let v6 = SIMD3<Double>(halfX, halfY, halfZ)
        let v7 = SIMD3<Double>(-halfX, halfY, halfZ)
        let faces: [(corners: [SIMD3<Double>], normal: SIMD3<Double>)] = [
            ([v4, v5, v6, v7], SIMD3<Double>(0, 0, 1)),
            ([v0, v3, v2, v1], SIMD3<Double>(0, 0, -1)),
            ([v1, v2, v6, v5], SIMD3<Double>(1, 0, 0)),
            ([v0, v4, v7, v3], SIMD3<Double>(-1, 0, 0)),
            ([v3, v7, v6, v2], SIMD3<Double>(0, 1, 0)),
            ([v0, v1, v5, v4], SIMD3<Double>(0, -1, 0)),
        ]
        let cornerUVs = [SIMD2<Double>(0, 0), SIMD2<Double>(1, 0),
                         SIMD2<Double>(1, 1), SIMD2<Double>(0, 1)]
        var positions: [SIMD3<Double>] = []
        var textureCoordinates: [SIMD2<Double>] = []
        var normals: [SIMD3<Double>] = []
        var triangles: [(Int, Int, Int)] = []
        for face in faces {
            let base = positions.count
            for (index, corner) in face.corners.enumerated() {
                positions.append(corner)
                textureCoordinates.append(cornerUVs[index])
                normals.append(face.normal)
            }
            triangles.append((base, base + 1, base + 2))
            triangles.append((base, base + 2, base + 3))
        }
        var obj = "mtllib materials/paint.mtl\no TexturedPlate\n"
        for position in positions {
            obj += "v \(position.x) \(position.y) \(position.z)\n"
        }
        for uv in textureCoordinates {
            obj += "vt \(uv.x) \(uv.y)\n"
        }
        for normal in normals {
            obj += "vn \(normal.x) \(normal.y) \(normal.z)\n"
        }
        obj += "usemtl Paint\n"
        for triangle in triangles {
            let a = triangle.0 + 1, b = triangle.1 + 1, c = triangle.2 + 1
            obj += "f \(a)/\(a)/\(a) \(b)/\(b)/\(b) \(c)/\(c)/\(c)\n"
        }
        let material = """
        newmtl Paint
        Ka 0.000000 0.000000 0.000000
        Kd 1.000000 1.000000 1.000000
        Ks 0.000000 0.000000 0.000000
        d 1.000000
        illum 1
        map_Kd textures/paint.png

        """
        let png = try observationSolidPNG(texture)
        let sourceURL = models.appendingPathComponent("plate.obj")
        let materialURL = materials.appendingPathComponent("paint.mtl")
        let textureURL = textures.appendingPathComponent("paint.png")
        let sourceBytes = Data(obj.utf8)
        let materialBytes = Data(material.utf8)
        try sourceBytes.write(to: sourceURL)
        try materialBytes.write(to: materialURL)
        if !missingTexture {
            try png.write(to: textureURL)
        }
        return OBJOriginalFixture(root: root,
            service: WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root)),
            sourceURL: sourceURL, materialURL: materialURL, textureURL: textureURL,
            sourceBytes: sourceBytes, materialBytes: materialBytes, textureBytes: png)
    }

    @Test("a real exported STEP original keeps source identity and actual OCCT display pixels")
    func originalSTEPDisplayPixelsAndSourceFence() async throws {
        let fixture = try await stepOriginalFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let digest = FloeDigest.sha256Hex(fixture.sourceBytes)
        let original = try Data(contentsOf: fixture.sourceURL)
        #expect(original == fixture.sourceBytes)

        let result = try await EngineeringObservationService().observe(
            path: "plate.step", service: fixture.service,
            request: .init(
                // Opposite azimuths project this rectangular plate to nearly
                // the same silhouette. Use unequal oblique views so the pixel
                // comparison exercises camera motion as well as its small hole.
                views: [.init(azimuthDegrees: 35, elevationDegrees: 20),
                        .init(azimuthDegrees: 120, elevationDegrees: 45)],
                width: 320, height: 240, projection: .perspective,
                expectedSourceSHA256: digest))
        #expect(result.frames.count == 2)
        Attachment.record(result.summaryJSON, named: "original-step-summary.json")
        let summary = try #require(try JSONSerialization.jsonObject(
            with: Data(result.summaryJSON.utf8)) as? [String: Any])
        #expect(summary["backend"] as? String == "occt")
        #expect(summary["sourceUnchanged"] as? Bool == true)
        let provenance = try #require(summary["provenance"] as? [String: Any])
        #expect(provenance["sourceSHA256"] as? String == digest)
        #expect(provenance["sourceName"] as? String == "plate.step")
        #expect(provenance["maximumBytes"] as? Int == 20 * 1024 * 1024)
        #expect(provenance["maximumFiles"] as? Int == 32)
        let resources = try #require(provenance["resources"] as? [[String: Any]])
        #expect(resources.count == 1)
        #expect(resources.first?["sha256"] as? String == digest)
        // Static, lossy display triangulation only. This test does not claim a
        // CAD import, editable B-Rep, feature tree or structural preservation;
        // the product copy below is the actual boundary the caller sees.
        let evidence = try #require(summary["visualEvidence"] as? String)
        #expect(evidence.contains("display triangulation"))
        #expect(evidence.contains("not native editable B-Rep"))
        let limitations = try #require(summary["limitations"] as? [String])
        let saysTessellated = limitations.contains {
            $0.contains("tessellated by the local OCCT worker")
        }
        let saysNotEditable = limitations.contains {
            $0.contains("not native editable B-Rep")
        }
        #expect(saysTessellated)
        #expect(saysNotEditable)

        let stateObject = try #require(summary["state"] as? [String: Any])
        let state = try #require(EngineeringSceneState.decode(fromJSONObject: stateObject))
        #expect(state.ready)
        #expect(state.backend == "occt")
        #expect(state.sourceSHA256 == digest)
        #expect(state.meshCount >= 1)
        #expect(state.missingResources.isEmpty)

        let hierarchyObject = try #require(summary["hierarchy"] as? [String: Any])
        let page = try JSONDecoder().decode(EngineeringSceneHierarchyPage.self,
            from: try JSONSerialization.data(withJSONObject: hierarchyObject))
        #expect(page.sourceSHA256 == digest)
        #expect(page.total >= 1)

        var imageHashes = Set<String>()
        for (index, frame) in result.frames.enumerated() {
            Attachment.record(Array(frame.pngData), named: "original-step-view-\(index).png")
            Attachment.record(frame.metadataJSON, named: "original-step-view-\(index).json")
            try expectPNG(frame, width: 320, height: 240)
            let meta = try metadata(frame)
            #expect(meta["sourceSHA256"] as? String == digest)
            #expect(meta["renderer"] as? String == "online3DViewer")
            #expect(meta["projection"] as? String == "perspective")
            let frameResources = try #require(meta["resources"] as? [[String: Any]])
            #expect(frameResources.count == 1)
            #expect(frameResources.first?["name"] as? String == "plate.step")
            #expect(frameResources.first?["sha256"] as? String == digest)
            let pixels = try observationPixelStats(frame.pngData)
            #expect(pixels.nonBackground > 500,
                    "the OCCT display conversion must contain actual rendered geometry")
            #expect(pixels.luminanceRange > 25)
            imageHashes.insert(FloeDigest.sha256Hex(frame.pngData))
        }
        #expect(imageHashes.count == 2)
        let differingPixels = try observationDifferingPixels(
            result.frames[0].pngData, result.frames[1].pngData)
        #expect(differingPixels > 1000,
                "the two views must differ in decoded pixels, not only in PNG bytes")
        #expect(try Data(contentsOf: fixture.sourceURL) == original,
                "observation must never rewrite the original STEP bytes")

        await #expect(throws: (any Error).self) {
            try await EngineeringObservationService().observe(
                path: "plate.step", service: fixture.service,
                request: .init(expectedSourceSHA256: String(repeating: "0", count: 64),
                               includeImages: false))
        }
    }

    @Test("a real OBJ package carries every resource and reports missing references")
    func resourceBackedOBJPixelsAndMissingReference() async throws {
        let fixture = try objOriginalFixture(texture: UIColor(
            red: 0.85, green: 0.08, blue: 0.08, alpha: 1))
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let digest = FloeDigest.sha256Hex(fixture.sourceBytes)
        let materialHash = FloeDigest.sha256Hex(fixture.materialBytes)
        let textureHash = FloeDigest.sha256Hex(fixture.textureBytes)
        let original = try Data(contentsOf: fixture.sourceURL)

        let result = try await EngineeringObservationService().observe(
            path: "models/plate.obj", service: fixture.service,
            request: .init(
                views: [.init(azimuthDegrees: 35, elevationDegrees: 20),
                        .init(azimuthDegrees: 215, elevationDegrees: 20)],
                width: 320, height: 240, expectedSourceSHA256: digest))
        #expect(result.frames.count == 2)
        Attachment.record(result.summaryJSON, named: "obj-original-summary.json")
        let summary = try #require(try JSONSerialization.jsonObject(
            with: Data(result.summaryJSON.utf8)) as? [String: Any])
        #expect(summary["backend"] as? String == "online3DViewer")
        #expect(summary["sourceUnchanged"] as? Bool == true)
        #expect(summary["partial"] as? Bool == false)
        let evidence = try #require(summary["visualEvidence"] as? String)
        #expect(evidence.contains("not CAD topology"))
        let limitations = try #require(summary["limitations"] as? [String])
        let saysNotAFeatureTree = limitations.contains {
            $0.contains("not a CAD feature tree")
        }
        #expect(saysNotAFeatureTree)
        let provenance = try #require(summary["provenance"] as? [String: Any])
        #expect(provenance["sourceSHA256"] as? String == digest)
        #expect(provenance["maximumBytes"] as? Int == 20 * 1024 * 1024)
        #expect(provenance["maximumFiles"] as? Int == 32)
        let resources = try #require(provenance["resources"] as? [[String: Any]])
        #expect(resources.compactMap { $0["name"] as? String }
            == ["plate.obj", "materials/paint.mtl", "materials/textures/paint.png"])
        #expect(resources.compactMap { $0["sha256"] as? String }
            == [digest, materialHash, textureHash])

        let stateObject = try #require(summary["state"] as? [String: Any])
        let state = try #require(EngineeringSceneState.decode(fromJSONObject: stateObject))
        #expect(state.backend == "online3DViewer")
        #expect(state.missingResources.isEmpty)
        #expect(state.meshCount >= 1)

        let hierarchyObject = try #require(summary["hierarchy"] as? [String: Any])
        let page = try JSONDecoder().decode(EngineeringSceneHierarchyPage.self,
            from: try JSONSerialization.data(withJSONObject: hierarchyObject))
        #expect(page.sourceSHA256 == digest)
        #expect(page.total >= 1)

        for (index, frame) in result.frames.enumerated() {
            Attachment.record(Array(frame.pngData), named: "obj-original-view-\(index).png")
            Attachment.record(frame.metadataJSON, named: "obj-original-view-\(index).json")
            try expectPNG(frame, width: 320, height: 240)
            let meta = try metadata(frame)
            #expect(meta["sourceSHA256"] as? String == digest)
            #expect(meta["renderer"] as? String == "online3DViewer")
            // The per-capture state is the state attached to this real frame,
            // not a possibly older asynchronous toolbar publication.
            let frameStateObject = try #require(meta["state"] as? [String: Any])
            let frameState = try #require(
                EngineeringSceneState.decode(fromJSONObject: frameStateObject))
            #expect(frameState.textureCount >= 1,
                    "the MTL map_Kd texture must be loaded, not silently ignored")
            let frameResources = try #require(meta["resources"] as? [[String: Any]])
            #expect(frameResources.compactMap { $0["name"] as? String }
                == ["plate.obj", "materials/paint.mtl", "materials/textures/paint.png"])
            let pixels = try observationPixelStats(frame.pngData)
            #expect(pixels.nonBackground > 500)
            #expect(pixels.redDominant > 200,
                    "the red texture must be visible in actual pixels")
            #expect(pixels.meanRed > pixels.meanBlue + 20,
                    "the textured surface must be red-dominant, not the default material")
        }
        #expect(try Data(contentsOf: fixture.sourceURL) == original,
                "observation must never rewrite the original OBJ bytes")
        #expect(try Data(contentsOf: fixture.materialURL) == fixture.materialBytes)
        #expect(try Data(contentsOf: fixture.textureURL) == fixture.textureBytes)

        // A missing texture is an explicit partial result, never a silent
        // complete package: the unresolved reference stays in state.
        let missing = try objOriginalFixture(texture: UIColor(
            red: 0.85, green: 0.08, blue: 0.08, alpha: 1), missingTexture: true)
        defer { try? FileManager.default.removeItem(at: missing.root) }
        let missingResult = try await EngineeringObservationService().observe(
            path: "models/plate.obj", service: missing.service,
            request: .init(views: [.init(azimuthDegrees: 35, elevationDegrees: 20)],
                           width: 320, height: 240,
                           expectedSourceSHA256: FloeDigest.sha256Hex(missing.sourceBytes)))
        #expect(missingResult.frames.count == 1)
        Attachment.record(missingResult.summaryJSON, named: "obj-missing-texture-summary.json")
        let missingSummary = try #require(try JSONSerialization.jsonObject(
            with: Data(missingResult.summaryJSON.utf8)) as? [String: Any])
        #expect(missingSummary["partial"] as? Bool == true)
        let missingMeta = try metadata(missingResult.frames[0])
        let missingFrameStateObject = try #require(missingMeta["state"] as? [String: Any])
        let missingFrameState = try #require(
            EngineeringSceneState.decode(fromJSONObject: missingFrameStateObject))
        let reportsMissingTexture = missingFrameState.missingResources.contains {
            $0.hasSuffix("textures/paint.png")
        }
        #expect(reportsMissingTexture)
        let missingProvenance = try #require(
            missingSummary["provenance"] as? [String: Any])
        #expect((missingProvenance["resources"] as? [[String: Any]])?.count == 2,
                "only the OBJ and MTL are present; the missing PNG is not fabricated")
    }

    #if DEBUG
    @Test("a resource-only OBJ change after real PNG validation rejects old frames and fresh pixels")
    func resourceOnlyOBJMutationDuringCaptureRejectsOldFrames() async throws {
        let red = UIColor(red: 0.85, green: 0.08, blue: 0.08, alpha: 1)
        let blue = UIColor(red: 0.08, green: 0.10, blue: 0.85, alpha: 1)
        let fixture = try objOriginalFixture(texture: red)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let digest = FloeDigest.sha256Hex(fixture.sourceBytes)
        let originalSource = try Data(contentsOf: fixture.sourceURL)
        let originalMaterial = try Data(contentsOf: fixture.materialURL)
        let oldTextureHash = FloeDigest.sha256Hex(fixture.textureBytes)
        let observer = EngineeringObservationService()
        let request = CadModelObservationRequest(
            views: [.init(azimuthDegrees: 35, elevationDegrees: 20),
                    .init(azimuthDegrees: 215, elevationDegrees: 20)],
            width: 320, height: 240, expectedSourceSHA256: digest)

        // Baseline pixels with the original red texture. These are the "old"
        // frames; they are not returned by the rejected race request.
        let before = try await observer.observe(
            path: "models/plate.obj", service: fixture.service, request: request)
        #expect(before.frames.count == 2)
        Attachment.record(before.summaryJSON, named: "obj-textured-before-summary.json")
        for (index, frame) in before.frames.enumerated() {
            Attachment.record(Array(frame.pngData),
                              named: "obj-textured-before-view-\(index).png")
            let pixels = try observationPixelStats(frame.pngData)
            #expect(pixels.redDominant > 200)
            #expect(pixels.meanRed > pixels.meanBlue + 20)
        }

        let freshTexture = try observationSolidPNG(blue)
        var validatedFrames = 0
        observer.testBeforeSourceRevalidation = { count in
            validatedFrames = count
            // Only the referenced PNG changes; the OBJ and MTL remain
            // byte-identical and the main-file SHA stays the same.
            try freshTexture.write(to: fixture.textureURL, options: .atomic)
        }
        defer { observer.testBeforeSourceRevalidation = nil }
        var rejection: (any Error)?
        do {
            _ = try await observer.observe(
                path: "models/plate.obj", service: fixture.service, request: request)
        } catch { rejection = error }
        #expect(validatedFrames == 2,
                "the race must occur after two real PNGs were validated")
        let error = try #require(rejection)
        #expect(error.localizedDescription.contains("changed during capture"))
        #expect(try Data(contentsOf: fixture.sourceURL) == originalSource,
                "the main OBJ bytes must be unchanged")
        #expect(try Data(contentsOf: fixture.materialURL) == originalMaterial,
                "the MTL bytes must be unchanged")
        #expect(try Data(contentsOf: fixture.textureURL) != fixture.textureBytes)

        observer.testBeforeSourceRevalidation = nil
        let fresh = try await observer.observe(
            path: "models/plate.obj", service: fixture.service, request: request)
        #expect(fresh.frames.count == 2)
        Attachment.record(fresh.summaryJSON, named: "obj-textured-after-summary.json")
        let freshTextureHash = FloeDigest.sha256Hex(freshTexture)
        #expect(fresh.summaryJSON.contains(freshTextureHash))
        #expect(!fresh.summaryJSON.contains(oldTextureHash))
        let summary = try #require(try JSONSerialization.jsonObject(
            with: Data(fresh.summaryJSON.utf8)) as? [String: Any])
        #expect(summary["backend"] as? String == "online3DViewer")
        #expect(summary["sourceUnchanged"] as? Bool == true)
        let provenance = try #require(summary["provenance"] as? [String: Any])
        #expect(provenance["sourceSHA256"] as? String == digest,
                "a resource-only change must not alter the source identity")
        let resources = try #require(provenance["resources"] as? [[String: Any]])
        let freshTextureResource = resources.first {
            ($0["name"] as? String) == "materials/textures/paint.png"
        }
        #expect(freshTextureResource?["sha256"] as? String == freshTextureHash)

        for (index, frame) in fresh.frames.enumerated() {
            Attachment.record(Array(frame.pngData),
                              named: "obj-textured-after-view-\(index).png")
            Attachment.record(frame.metadataJSON,
                              named: "obj-textured-after-view-\(index).json")
            try expectPNG(frame, width: 320, height: 240)
            let meta = try metadata(frame)
            #expect(meta["sourceSHA256"] as? String == digest)
            let metaResources = try #require(meta["resources"] as? [[String: Any]])
            let metadataCarriesFreshTexture = metaResources.contains {
                ($0["sha256"] as? String) == freshTextureHash
            }
            #expect(metadataCarriesFreshTexture)
            let pixels = try observationPixelStats(frame.pngData)
            #expect(pixels.blueDominant > 200,
                    "the fresh texture must produce genuinely different pixels")
            #expect(pixels.meanBlue > pixels.meanRed + 20,
                    "the fresh capture must show the changed texture, not cached material")
        }
        #expect(FloeDigest.sha256Hex(fresh.frames[0].pngData)
            != FloeDigest.sha256Hex(before.frames[0].pngData))
        #expect(try Data(contentsOf: fixture.sourceURL) == originalSource)
    }
    #endif
}

private struct OBJOriginalFixture {
    let root: URL
    let service: WorkspaceFileService
    let sourceURL: URL
    let materialURL: URL
    let textureURL: URL
    let sourceBytes: Data
    let materialBytes: Data
    let textureBytes: Data
}

private struct ObservationPixelStats {
    let width: Int
    let height: Int
    let nonBackground: Int
    let redDominant: Int
    let blueDominant: Int
    let luminanceRange: Int
    let meanRed: Double
    let meanGreen: Double
    let meanBlue: Double
}

/// Decodes the actual PNG pixels so tests can make visual claims from pixels,
/// never from the PNG container hash alone.
private func observationRGBA(_ png: Data)
    throws -> (width: Int, height: Int, pixels: [UInt8]) {
    let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    try pixels.withUnsafeMutableBytes { raw in
        guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw FloeError.validationFailed("the captured PNG could not be decoded")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return (width, height, pixels)
}

private func observationPixelStats(_ png: Data) throws -> ObservationPixelStats {
    let decoded = try observationRGBA(png)
    let pixels = decoded.pixels
    let width = decoded.width
    let height = decoded.height
    var nonBackground = 0
    var redDominant = 0
    var blueDominant = 0
    var redSum = 0
    var greenSum = 0
    var blueSum = 0
    var minimumLuminance = 255
    var maximumLuminance = 0
    for index in stride(from: 0, to: pixels.count, by: 4) {
        let r = Int(pixels[index])
        let g = Int(pixels[index + 1])
        let b = Int(pixels[index + 2])
        if abs(r - 245) + abs(g - 246) + abs(b - 248) > 30 {
            nonBackground += 1
            redSum += r
            greenSum += g
            blueSum += b
        }
        if r > g + 30, r > b + 30, r > 70 { redDominant += 1 }
        if b > r + 30, b > g + 30, b > 70 { blueDominant += 1 }
        let luminance = (r * 299 + g * 587 + b * 114) / 1000
        minimumLuminance = min(minimumLuminance, luminance)
        maximumLuminance = max(maximumLuminance, luminance)
    }
    let denominator = Double(max(nonBackground, 1))
    return ObservationPixelStats(width: width, height: height,
        nonBackground: nonBackground, redDominant: redDominant,
        blueDominant: blueDominant,
        luminanceRange: maximumLuminance - minimumLuminance,
        meanRed: Double(redSum) / denominator,
        meanGreen: Double(greenSum) / denominator,
        meanBlue: Double(blueSum) / denominator)
}

/// Number of decoded RGB pixels that differ between two same-size frames.
private func observationDifferingPixels(_ lhs: Data, _ rhs: Data) throws -> Int {
    let left = try observationRGBA(lhs)
    let right = try observationRGBA(rhs)
    guard left.width == right.width, left.height == right.height else {
        return max(left.width * left.height, right.width * right.height)
    }
    var differing = 0
    for index in stride(from: 0, to: min(left.pixels.count, right.pixels.count), by: 4) {
        if left.pixels[index] != right.pixels[index]
            || left.pixels[index + 1] != right.pixels[index + 1]
            || left.pixels[index + 2] != right.pixels[index + 2] {
            differing += 1
        }
    }
    return differing
}

/// Synthetic fixture texture generated by Apple's rasterizer, never a user
/// image or a network download.
private func observationSolidPNG(_ color: UIColor) throws -> Data {
    let side: CGFloat = 16
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
    let image = renderer.image { context in
        color.setFill()
        context.cgContext.fill(CGRect(x: 0, y: 0, width: side, height: side))
    }
    return try #require(image.pngData())
}
#endif
