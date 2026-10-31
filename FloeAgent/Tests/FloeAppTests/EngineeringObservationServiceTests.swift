// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import ImageIO
import Testing
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
        for frame in perspective.frames {
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
        for frame in orthographic.frames {
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
}
#endif
