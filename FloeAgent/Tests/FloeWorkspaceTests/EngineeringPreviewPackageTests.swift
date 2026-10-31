// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import CryptoKit
import FloeWorkspace

@Suite("Read-only engineering preview packages")
struct EngineeringPreviewPackageTests {
    @Test func explicitReferencesStayGuardedAndNeverFetchRemoteResources() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = #"{"buffers":[{"uri":"part.bin"}],"images":[{"uri":"https://example.com/texture.png"},{"uri":"../secret.png"},{"uri":".env.png"},{"uri":"private.png"}]}"#
        try Data(model.utf8).write(to: root.appendingPathComponent("part.gltf"))
        try Data([0, 1, 2]).write(to: root.appendingPathComponent("part.bin"))
        try Data("secret".utf8).write(to: root.appendingPathComponent(".env.png"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("private.png"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        let package = try EngineeringPreviewPackage.load(path: "part.gltf", service: WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root)))
        #expect(package.files.map(\.name) == ["part.gltf", "part.bin"])
        #expect(package.missingReferences.count == 4)
        #expect(package.kind == .mesh)
        #expect(try Data(contentsOf: root.appendingPathComponent("part.gltf")) == Data(model.utf8))
    }
    @Test func nestedMaterialReferencesAndMissingFilesAreVisible() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("materials"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("mtllib materials/model.mtl\nv 0 0 0\n".utf8).write(to: root.appendingPathComponent("model.obj"))
        try Data("newmtl red\nmap_Kd texture.png\nmap_Ks missing.png\n".utf8).write(to: root.appendingPathComponent("materials/model.mtl"))
        try Data([1]).write(to: root.appendingPathComponent("materials/texture.png"))
        let result = try EngineeringPreviewPackage.load(path: "model.obj", service: WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root)))
        #expect(result.files.map(\.name) == ["model.obj", "materials/model.mtl", "materials/texture.png"])
        #expect(result.missingReferences == ["materials/missing.png"])
    }
    @Test func limitsAndUnsupportedDecodersAreExplicit() throws {
        #expect(EngineeringPreviewKind.identify("BOARD.DXF") == .dxf)
        #expect(EngineeringPreviewKind.identify("part.step") == .cadSurface)
        #expect(EngineeringPreviewKind.identify("drawing.dwg") == .dwg)
        #expect(EngineeringPreviewKind.identify("board.kicad_pcb") == .unsupported)
        #expect(EngineeringPreviewKind.identify("report.pdf") == nil)
        #expect(throws: Error.self) { try EngineeringPreviewPackage.single(name: "part.stl", bytes: Data(count: EngineeringPreviewPackage.maximumBytes + 1)) }
        let remote = try EngineeringPreviewPackage.single(name: "part.obj", bytes: Data("mtllib missing.mtl\n".utf8))
        #expect(remote.missingReferences == ["missing.mtl"])
    }

    @Test func scenePreflightReportsRequiredExtensionsAndNeverSilentlySkips() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = #"""
        {
          "asset": {"version": "2.0", "generator": "fixture"},
          "extensionsRequired": ["EXT_unbundled_required"],
          "extensionsUsed": ["EXT_unbundled_required", "EXT_optional_unknown"],
          "scene": 0, "scenes": [{"nodes": [0]}],
          "nodes": [{"name": "Root"}],
          "meshes": [{"name": "Patch", "primitives": [{
            "attributes": {"POSITION": 0}, "mode": 99,
            "targets": [{"POSITION": 0}]
          }]}],
          "materials": [{"name": "Blue"}],
          "textures": [{"source": 0}],
          "images": [{"uri": "https://example.com/texture.png"}],
          "cameras": [{"name": "Camera", "type": "perspective", "perspective": {"yfov": 0.7}}],
          "skins": [{"joints": [0]}],
          "accessors": [
            {"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3",
             "sparse": {"count": 1, "indices": {"bufferView": 1, "componentType": 5123},
                        "values": {"bufferView": 2}}},
            {"bufferView": 1, "componentType": 5126, "count": 2, "type": "SCALAR", "max": [1.5]}
          ],
          "buffers": [{"uri": "missing.bin", "byteLength": 12}],
          "animations": [
            {"name": "Linear", "samplers": [{"input": 1, "output": 1, "interpolation": "LINEAR"}], "channels": []},
            {"name": "Step", "samplers": [{"input": 1, "output": 1, "interpolation": "STEP"}], "channels": []},
            {"name": "Cubic", "samplers": [{"input": 1, "output": 1, "interpolation": "CUBICSPLINE"}], "channels": []}
          ]
        }
        """#
        let sourceURL = root.appendingPathComponent("scene.gltf")
        try Data(model.utf8).write(to: sourceURL)
        let before = try Data(contentsOf: sourceURL)
        let package = try EngineeringPreviewPackage.load(
            path: "scene.gltf",
            service: WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root)))
        let diagnostics = package.diagnostics
        #expect(package.backend == .threeGLTF)
        #expect(diagnostics.blockingIssues.contains { $0.code == .unsupportedRequiredExtension })
        #expect(diagnostics.blockingIssues.contains { $0.code == .missingBuffer })
        #expect(diagnostics.warnings.contains { $0.code == .unsupportedExtension })
        #expect(diagnostics.warnings.contains { $0.code == .externalResourceBlocked })
        #expect(diagnostics.unsupportedPrimitiveModes == [99])
        #expect(diagnostics.primitiveModeCounts.isEmpty)
        #expect(diagnostics.sparseAccessorCount == 1)
        #expect(diagnostics.morphPrimitiveCount == 1)
        #expect(diagnostics.morphTargetCount == 1)
        #expect(diagnostics.cameraCount == 1)
        #expect(diagnostics.animationCount == 3)
        #expect(Set(diagnostics.animations.flatMap(\.interpolations)) == ["LINEAR", "STEP", "CUBICSPLINE"])
        #expect(diagnostics.animations.allSatisfy { $0.durationSeconds == 1.5 })
        #expect(!diagnostics.isScenePreviewAvailable)
        #expect(try Data(contentsOf: sourceURL) == before)
    }

    @Test func nestedSceneReferencesResolveAgainstTheMainFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("models/textures"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = #"{"asset":{"version":"2.0"},"buffers":[{"uri":"part.bin","byteLength":3}],"images":[{"uri":"textures/tex.png"}],"meshes":[]}"#
        try Data(model.utf8).write(to: root.appendingPathComponent("models/scene.gltf"))
        try Data([0, 1, 2]).write(to: root.appendingPathComponent("models/part.bin"))
        try Data([9]).write(to: root.appendingPathComponent("models/textures/tex.png"))
        let package = try EngineeringPreviewPackage.load(
            path: "models/scene.gltf",
            service: WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root)))
        #expect(Set(package.files.map(\.name)) == [
            "scene.gltf", "part.bin", "textures/tex.png"
        ])
        #expect(package.missingReferences.isEmpty)
        #expect(package.diagnostics.blockingIssues.isEmpty)
        #expect(package.diagnostics.warnings.isEmpty)
        #expect(package.diagnostics.imageCount == 1)
    }

    @Test func singleFileGrantReportsSiblingsButNeverReadsThem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = #"{"asset":{"version":"2.0"},"buffers":[{"uri":"part.bin","byteLength":3}],"images":[{"uri":"tex.png"}]}"#
        let sourceURL = root.appendingPathComponent("scene.gltf")
        try Data(model.utf8).write(to: sourceURL)
        try Data([0, 1, 2]).write(to: root.appendingPathComponent("part.bin"))
        try Data([9]).write(to: root.appendingPathComponent("tex.png"))
        let before = try Data(contentsOf: sourceURL)

        let single = try EngineeringPreviewPackage.load(fileURL: sourceURL)
        #expect(single.files.map(\.name) == ["scene.gltf"])
        #expect(Set(single.missingReferences) == ["part.bin", "tex.png"])
        #expect(single.diagnostics.blockingIssues.contains { $0.code == .missingBuffer })
        #expect(single.diagnostics.blockingIssues.contains { $0.code == .missingResource } == false)
        #expect(try Data(contentsOf: sourceURL) == before)

        let bundled = try EngineeringPreviewPackage.load(fileURL: sourceURL, includeSiblingResources: true)
        #expect(Set(bundled.files.map(\.name)) == ["scene.gltf", "part.bin", "tex.png"])
        #expect(bundled.missingReferences.isEmpty)
        #expect(bundled.diagnostics.blockingIssues.isEmpty)
        #expect(try Data(contentsOf: sourceURL) == before)

        let displayed = try EngineeringPreviewPackage.load(
            fileURL: sourceURL, displayName: "User Scene.gltf")
        #expect(displayed.name == "User Scene.gltf")
        #expect(displayed.provenance.sourceName == "scene.gltf")
        #expect(displayed.provenance.sourceSHA256 == bundled.provenance.sourceSHA256)
        #expect(throws: Error.self) {
            try EngineeringPreviewPackage.load(fileURL: sourceURL, displayName: "scene.obj")
        }
    }

    @Test func siblingResourceChangeAltersProvenanceButNotSourceIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = Data(#"{"asset":{"version":"2.0"},"buffers":[{"uri":"part.bin"}],"meshes":[]}"#.utf8)
        try source.write(to: root.appendingPathComponent("scene.gltf"))
        try Data([1, 2, 3, 4]).write(to: root.appendingPathComponent("part.bin"))
        let service = WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root))
        let first = try EngineeringPreviewPackage.load(path: "scene.gltf", service: service)
        try Data([9, 8, 7, 6]).write(to: root.appendingPathComponent("part.bin"))
        let second = try EngineeringPreviewPackage.load(path: "scene.gltf", service: service)
        #expect(first.provenance.sourceSHA256 == second.provenance.sourceSHA256)
        #expect(first.provenance != second.provenance)
        #expect(first.provenance.resources != second.provenance.resources)
        #expect(first.provenance.resources.count == 2)
        #expect(second.provenance.resources.count == 2)
    }

    @Test func glbPreflightParsesJSONChunkAndRejectsTruncation() throws {
        let json = #"{"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0]}],"nodes":[{"name":"A"}],"meshes":[],"images":[{"uri":"sibling.png"}]}"#
        let glb = makeGLB(json: json)
        let package = try EngineeringPreviewPackage.single(name: "scene.glb", bytes: glb)
        #expect(package.backend == .threeGLTF)
        #expect(package.diagnostics.formatVersion == "2.0")
        #expect(package.diagnostics.nodeCount == 1)
        #expect(package.diagnostics.isScenePreviewAvailable)
        #expect(package.missingReferences == ["sibling.png"])

        let truncated = try EngineeringPreviewPackage.single(
            name: "scene.glb", bytes: Data(glb.prefix(10)))
        #expect(truncated.diagnostics.blockingIssues.contains { $0.code == .invalidContainer })
        #expect(!truncated.diagnostics.isScenePreviewAvailable)
    }

    @Test func provenanceRecordsEveryResourceAndExplicitLimits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = Data(#"{"asset":{"version":"2.0"},"buffers":[{"uri":"part.bin"}],"meshes":[]}"#.utf8)
        let binary = Data([1, 2, 3, 4])
        try source.write(to: root.appendingPathComponent("scene.gltf"))
        try binary.write(to: root.appendingPathComponent("part.bin"))
        let package = try EngineeringPreviewPackage.load(
            path: "scene.gltf",
            service: WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root)))
        #expect(package.provenance.sourceName == "scene.gltf")
        #expect(package.provenance.sourceByteCount == source.count)
        #expect(package.provenance.sourceSHA256 == sha256Hex(source))
        #expect(package.provenance.resourceCount == 2)
        #expect(package.provenance.resourceByteCount == source.count + binary.count)
        #expect(package.provenance.maximumBytes == EngineeringPreviewPackage.maximumBytes)
        #expect(package.provenance.maximumFiles == EngineeringPreviewPackage.maximumFiles)
        #expect(package.provenance.isWithinDefaultLimits)

        let explicit = EngineeringPreviewLimits(maximumBytes: 64 * 1024 * 1024, maximumFiles: 64)
        let expanded = try EngineeringPreviewPackage.load(
            path: "scene.gltf",
            service: WorkspaceFileService(guard: WorkspacePathGuard(
                rootURL: root, maxReadBytes: explicit.maximumBytes)),
            limits: explicit)
        #expect(expanded.provenance.maximumBytes == explicit.maximumBytes)
        #expect(expanded.provenance.maximumFiles == explicit.maximumFiles)
        #expect(!expanded.provenance.isWithinDefaultLimits)
        #expect(throws: Error.self) {
            try EngineeringPreviewPackage.single(
                name: "part.stl", bytes: Data(count: 2048),
                limits: EngineeringPreviewLimits(maximumBytes: 1024, maximumFiles: 32))
        }
    }

    @Test func sceneStateAndCaptureContractsAreTypedAndBounded() throws {
        let object: [String: Any] = [
            "documentName": "scene.glb", "sourceSHA256": "abc", "ready": true,
            "nodeCount": 1, "meshCount": 1, "clips": [["index": 0, "name": "A",
                "durationSeconds": 1.5, "channelCount": 3,
                "interpolations": ["LINEAR"]]],
            "nodes": [["path": "Root", "name": "Root", "type": "Object3D",
                       "childCount": 0, "instanceCount": 0, "visible": true]]
        ]
        let state = try #require(EngineeringSceneState.decode(fromJSONObject: object))
        #expect(state.ready)
        #expect(state.speed == 1)
        #expect(state.loopMode == "repeat")
        #expect(state.nodes.count == 1)
        #expect(state.clips.first?.durationSeconds == 1.5)

        #expect(EngineeringSceneCommand.play.jsonObject["action"] as? String == "play")
        #expect(EngineeringSceneCommand.selectClip(index: nil).jsonString()?.contains("null") == true)
        #expect(EngineeringSceneCommand.loop(.pingPong).jsonString()?.contains("pingpong") == true)

        let request = EngineeringSceneCaptureRequest(
            views: Array(repeating: .init(azimuthDegrees: 0, elevationDegrees: 20), count: 20),
            width: 5000, height: 1, clipIndex: 1, timeSeconds: -2,
            maximumFrames: 20, maximumPNGBytes: 100_000_000,
            maximumTotalBytes: 100_000_000)
        #expect(request.views.count == 8)
        #expect(request.width == 2048)
        #expect(request.height == 64)
        #expect(request.timeSeconds == 0)
        #expect(request.maximumPNGBytes == 16 * 1024 * 1024)
        #expect(request.maximumTotalBytes == 32 * 1024 * 1024)
        let encoded = try #require(request.jsonString())
        #expect(encoded.contains("\"maximumFrames\":8"))

        let frame = EngineeringSceneCaptureFrame(
            pngData: Data([1, 2, 3]), width: 64, height: 64, viewIndex: 2,
            azimuthDegrees: 35, elevationDegrees: 20, timeSeconds: 0.5,
            clipIndex: 0, sourceSHA256: "source", state: state)
        #expect(frame.mimeType == "image/png")
        #expect(frame.byteCount == 3)
        #expect(frame.pngSHA256.count == 64)
        #expect(frame.receipt.contains("sourceSHA256=source"))
        #expect(frame.receipt.contains("view=2"))
        let result = EngineeringSceneCaptureResult(frames: [frame], failures: [])
        #expect(result.sourceSHA256 == "source")
        #expect(!result.isPartial)
        let partial = EngineeringSceneCaptureResult(
            frames: [frame], failures: [.init(viewIndex: 3, reason: "test")])
        #expect(partial.isPartial)
    }

    @Test func sceneCaptureProjectionIsTypedAndReported() throws {
        #expect(EngineeringSceneProjection(rawValue: "perspective") == .perspective)
        #expect(EngineeringSceneProjection(rawValue: "orthographic") == .orthographic)
        #expect(EngineeringSceneProjection(rawValue: "isometric") == nil)
        let request = EngineeringSceneCaptureRequest(
            views: [.init(azimuthDegrees: 0, elevationDegrees: 20)],
            width: 320, height: 240, clipIndex: nil, timeSeconds: nil,
            projection: .orthographic, maximumFrames: 2,
            maximumPNGBytes: 1024, maximumTotalBytes: 4096)
        #expect(request.projection == .orthographic)
        let encoded = try #require(request.jsonString())
        #expect(encoded.contains("\"projection\":\"orthographic\""))

        let defaultRequest = EngineeringSceneCaptureRequest(
            views: [.init(azimuthDegrees: 0, elevationDegrees: 20)],
            width: 320, height: 240, clipIndex: nil, timeSeconds: nil,
            maximumFrames: 2, maximumPNGBytes: 1024, maximumTotalBytes: 4096)
        #expect(defaultRequest.projection == nil)
        #expect(try #require(defaultRequest.jsonString()).contains("\"projection\":null"))

        let frame = EngineeringSceneCaptureFrame(
            pngData: Data([1, 2, 3]), width: 64, height: 64, viewIndex: 0,
            azimuthDegrees: 0, elevationDegrees: 20, timeSeconds: 0,
            clipIndex: nil, sourceSHA256: "source", state: nil,
            projection: .orthographic, renderer: "online3DViewer")
        #expect(frame.projection == .orthographic)
        #expect(frame.renderer == "online3DViewer")
        #expect(frame.receipt.contains("projection=orthographic"))
        #expect(frame.receipt.contains("renderer=online3DViewer"))
    }

    private func makeGLB(json: String) -> Data {
        var jsonData = Data(json.utf8)
        let jsonPadding = (4 - jsonData.count % 4) % 4
        jsonData.append(contentsOf: repeatElement(0x20, count: jsonPadding))
        let total = 12 + 8 + jsonData.count
        var data = Data([0x67, 0x6C, 0x54, 0x46])
        data.appendLittleEndian(UInt32(2))
        data.appendLittleEndian(UInt32(total))
        data.appendLittleEndian(UInt32(jsonData.count))
        data.appendLittleEndian(UInt32(0x4E4F534A))
        data.append(jsonData)
        return data
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt32) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}

@Suite("Engineering multi-scene and hierarchy contracts")
struct EngineeringScenePagingContractTests {
    @Test func olderSceneStatesRemainReadableAndNewScenesRoundTrip() throws {
        let old = try #require(EngineeringSceneState.decode(fromJSONObject: ["ready": true]))
        #expect(old.scenes.isEmpty)
        #expect(old.activeSceneIndex == 0)
        let current = try #require(EngineeringSceneState.decode(fromJSONObject: [
            "ready": true, "sourceSHA256": "source", "activeSceneIndex": 1,
            "scenes": [["index": 0, "name": "Assembly"], ["index": 1, "name": "Detail"]]
        ]))
        let encoded = try JSONEncoder().encode(current)
        let reopened = try JSONDecoder().decode(EngineeringSceneState.self, from: encoded)
        #expect(reopened.scenes.map(\.name) == ["Assembly", "Detail"])
        #expect(reopened.activeSceneIndex == 1)
        #expect(EngineeringSceneCommand.selectScene(index: 1).jsonObject["index"] as? Int == 1)
    }

    @Test func hierarchyPagesRetainRealOffsetsAndTheExplicitTailLocation() throws {
        let data = Data(#"{"sourceSHA256":"source","sceneIndex":1,"total":241,"offset":200,"nextOffset":220,"nodes":[]}"#.utf8)
        let page = try JSONDecoder().decode(EngineeringSceneHierarchyPage.self, from: data)
        #expect(page.sceneIndex == 1)
        #expect(page.offset == 200)
        #expect(page.nextOffset == 220)
        #expect(page.total == 241)
        #expect(page.sourceSHA256 == "source")
    }
}

@Suite("Preview-specific read budgets")
struct EngineeringPreviewReadBudgetTests {
    @Test func largerPreviewKeepsPathMountAndWriteRestrictions() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("preview-budgets-\(UUID())")
        let root = folder.appendingPathComponent("workspace")
        let mount = folder.appendingPathComponent("mounted")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bytes = Data(repeating: 1, count: 64)
        try bytes.write(to: root.appendingPathComponent("part.glb"))
        try bytes.write(to: mount.appendingPathComponent("mounted.glb"))
        let original = WorkspacePathGuard(rootURL: root, maxReadBytes: 16,
            maxWriteBytes: 4, mounts: ["Shared": mount])
        let preview = original.withReadLimit(128)
        #expect(throws: Error.self) { try original.assertReadableSize(original.resolve("part.glb")) }
        try preview.assertReadableSize(preview.resolve("part.glb"))
        #expect(preview.maxWriteBytes == original.maxWriteBytes)
        #expect(try preview.resolve("Mounts/Shared/mounted.glb") == original.resolve("Mounts/Shared/mounted.glb"))
        #expect(throws: Error.self) { try preview.resolve("../escape.glb") }
        #expect(throws: Error.self) { try preview.resolve(".env") }
        #expect(EngineeringPreviewLimits.standard.maximumBytes == 20 * 1024 * 1024)
        #expect(EngineeringPreviewLimits.expandedReadOnly.maximumBytes == 64 * 1024 * 1024)
    }
}

@Suite("Engineering preview bridge payload")
struct EngineeringPreviewBridgePayloadTests {
    @Test func directBridgePreservesTheCompleteCodableContract() throws {
        let package = try EngineeringPreviewPackage.single(name: "part.obj",
            bytes: Data("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n".utf8))
        let expected = try JSONSerialization.jsonObject(with: JSONEncoder().encode(package))
        let actual = try package.bridgeObject()
        let a = try JSONSerialization.data(withJSONObject: actual, options: [.sortedKeys])
        let b = try JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys])
        #expect(a == b)
        let files = try #require(actual["files"] as? [[String: String]])
        #expect(files.first?["base64"] == package.files.first?.base64)
    }
}
