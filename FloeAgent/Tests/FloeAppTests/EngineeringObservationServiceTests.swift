// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import ImageIO
import Testing
@testable import FloeApp
import FloeCore
import FloeWorkbench
import FloeWorkspace

@Suite("Original model WebGL observation", .serialized)
@MainActor
struct EngineeringObservationServiceTests {
    private func fixture() throws -> (URL, WorkspaceFileService, Data) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("model-observation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var positions = Data()
        for value: Float in [-1, 0, 0, 1, 0, 0, 0, 1.5, 0] {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { positions.append(contentsOf: $0) }
        }
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
            "accessors": [["bufferView": 0, "componentType": 5126, "count": 3,
                "type": "VEC3", "min": [-1, 0, 0], "max": [1, 1.5, 0]]],
            "bufferViews": [["buffer": 0, "byteOffset": 0, "byteLength": positions.count]],
            "buffers": [["byteLength": positions.count,
                "uri": "data:application/octet-stream;base64,\(positions.base64EncodedString())"]]
        ]
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try bytes.write(to: root.appendingPathComponent("assembly.gltf"))
        return (root, WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root)), bytes)
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
        let hierarchy = try #require(summary["hierarchy"] as? [String: Any])
        #expect(hierarchy["total"] as? Int == 241)
        #expect(hierarchy["offset"] as? Int == 200)
        #expect((hierarchy["nodes"] as? [Any])?.count == 41)
        #expect(hierarchy["nextOffset"] is NSNull)
        #expect(summary["sourceUnchanged"] as? Bool == true)
        for frame in result.frames {
            let image = try #require(CGImageSourceCreateWithData(frame.pngData as CFData, nil))
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any])
            #expect(properties[kCGImagePropertyPixelWidth] as? Int == 320)
            #expect(properties[kCGImagePropertyPixelHeight] as? Int == 240)
            #expect(frame.pngData.count > 1000)
            #expect(frame.metadataJSON.contains(digest))
            #expect(frame.metadataJSON.contains(FloeDigest.sha256Hex(frame.pngData)))
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
}
#endif
