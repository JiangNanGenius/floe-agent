//
//  CADPlacedAssemblyExportCallerTests.swift
//  FloeAppTests
//
//  Caller-level closure for the placed-assembly exchange path:
//   * the real `cad.document` tool + `CadDocumentCenter` + bridge route,
//   * dry-run coverage before any file exists,
//   * explicit STEP partial choice leaves no half artifact,
//   * stale revision writes nothing and preserves an existing target,
//   * selecting one occurrence exports one object (part vs assembly).
//
//  This tests the caller/host contract, not external CAD acceptance. The STEP
//  file is still verified only by the same engine here.
//

import XCTest
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import simd
@testable import FloeCAD
import FloeCore
import FloeTools
import FloeWorkbench
@testable import FloeApp

/// Exercise the real durable task store, not a source-string assertion. The
/// saved request is inert: it survives interruption, but never writes an
/// output or bypasses the caller's next permission/document resolution.
@MainActor
final class NativeCADAnimationExportRecoveryTests: XCTestCase {
    func testInterruptedExportKeepsExactChoicesAndNeverRunsOnRecovery() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CADExportRecovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("native-tasks.json")
        let owner = NativeCADTaskRegistry.Ownership(
            environmentID: "test-environment", ownerKind: "task", ownerID: UUID(),
            documentPath: "Projects/Assembly.floecad")
        let request = NativeCADTaskRegistry.AnimationExportRequest(
            relativeOutput: "VideoExports/assembly.mp4",
            options: CadAnimationExportOptions(
                width: 640, height: 480, frameRate: 12, codec: "hevc",
                bitrate: 2_000_000, overwrite: true, posterEnabled: false))
        let original = NativeCADTaskRegistry(fileURL: file)
        let id = try await original.beginAnimationExport(ownership: owner,
                                                         request: request)

        let reopened = NativeCADTaskRegistry(fileURL: file)
        let records = await reopened.status(id: id, ownership: owner)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.id, id)
        XCTAssertEqual(record.state, .interrupted)
        XCTAssertEqual(record.animationExport, request)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(request.relativeOutput).path),
            "Recovering metadata must not restart a renderer or write a video")

        let reply = CadDocumentCenter.nativeTaskRecordJSON(record)
        let saved = try XCTUnwrap(reply["export_request"] as? [String: Any])
        XCTAssertEqual(saved["output"] as? String, request.relativeOutput)
        XCTAssertEqual(saved["width"] as? Int, 640)
        XCTAssertEqual(saved["height"] as? Int, 480)
        XCTAssertEqual(saved["frame_rate"] as? Int, 12)
        XCTAssertEqual(saved["codec"] as? String, "hevc")
        XCTAssertEqual(saved["bitrate"] as? Int, 2_000_000)
        XCTAssertEqual(saved["overwrite"] as? Bool, true)
        XCTAssertEqual(saved["poster_enabled"] as? Bool, false)
        XCTAssertEqual(reply["foreground_required"] as? Bool, true)
        XCTAssertEqual(reply["frame_resume_supported"] as? Bool, false)
        XCTAssertEqual(reply["automatic_resume"] as? Bool, false)
        XCTAssertEqual(reply["restart_requires_revalidation"] as? Bool, true)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: reply))

        let other = NativeCADTaskRegistry.Ownership(
            environmentID: owner.environmentID, ownerKind: owner.ownerKind,
            ownerID: UUID(), documentPath: owner.documentPath)
        let foreign = await reopened.status(id: id, ownership: other)
        XCTAssertTrue(foreign.isEmpty, "Export settings keep exact task ownership")
        let twice = NativeCADTaskRegistry(fileURL: file)
        let secondRead = await twice.status(id: id, ownership: owner)
        XCTAssertEqual(secondRead.first?.animationExport, request)
        XCTAssertEqual(secondRead.first?.state, .interrupted)
    }

    func testOldRecordsDecodeWithoutInventingExportSettings() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CADLegacyTasks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("native-tasks.json")
        let owner = NativeCADTaskRegistry.Ownership(
            environmentID: nil, ownerKind: "project", ownerID: UUID(),
            documentPath: "Legacy.floecad")
        let initial = NativeCADTaskRegistry(fileURL: file)
        let id = await initial.begin(kind: "animation-export", ownership: owner)
        await initial.finish(id: id, state: .completed, detail: "old completed job")
        let data = try Data(contentsOf: file)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let raw = try XCTUnwrap((envelope["records"] as? [[String: Any]])?.first)
        XCTAssertNil(raw["animationExport"], "The fixture uses the old record shape")
        let reopened = NativeCADTaskRegistry(fileURL: file)
        let rows = await reopened.status(id: id, ownership: owner)
        let record = try XCTUnwrap(rows.first)
        XCTAssertEqual(record.state, .completed)
        XCTAssertNil(record.animationExport)
        XCTAssertNil(CadDocumentCenter.nativeTaskRecordJSON(record)["export_request"])
    }

    func testExplicitCancellationKeepsIntentWithoutBecomingInterrupted() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CADCancelledExport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("native-tasks.json")
        let owner = NativeCADTaskRegistry.Ownership(
            environmentID: "test", ownerKind: "task", ownerID: UUID(),
            documentPath: "Cancelled.floecad")
        let request = NativeCADTaskRegistry.AnimationExportRequest(
            relativeOutput: "cancelled.mp4", options: .init())
        let initial = NativeCADTaskRegistry(fileURL: file)
        let id = try await initial.beginAnimationExport(ownership: owner,
                                                        request: request)
        _ = await initial.requestCancel(id: id, ownership: owner)
        await initial.finish(id: id, state: .cancelled, detail: "owned writer stopped")
        let reopened = NativeCADTaskRegistry(fileURL: file)
        let rows = await reopened.status(id: id, ownership: owner)
        XCTAssertEqual(rows.first?.state, .cancelled)
        XCTAssertEqual(rows.first?.animationExport, request)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(request.relativeOutput).path))
    }

    func testFailedRequestWriteRollsBackTheInMemoryTaskIndex() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CADRecoveryWriteFailure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blocker = root.appendingPathComponent("not-a-directory")
        try Data("existing file".utf8).write(to: blocker)
        let registry = NativeCADTaskRegistry(
            fileURL: blocker.appendingPathComponent("native-tasks.json"))
        let owner = NativeCADTaskRegistry.Ownership(
            environmentID: nil, ownerKind: "task", ownerID: UUID(),
            documentPath: "Blocked.floecad")
        let old = await registry.begin(kind: "legacy-job", ownership: owner)
        let before = await registry.status(id: nil, ownership: owner)
        do {
            _ = try await registry.beginAnimationExport(
                ownership: owner,
                request: .init(relativeOutput: "not-created.mp4", options: .init()))
            XCTFail("The renderer must not receive a task id without durable recovery info")
        } catch {
            XCTAssertTrue(error is CocoaError)
        }
        let after = await registry.status(id: nil, ownership: owner)
        XCTAssertEqual(after, before)
        XCTAssertEqual(after.map(\.id), [old])
        XCTAssertEqual(try Data(contentsOf: blocker), Data("existing file".utf8))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("not-created.mp4").path))
    }
}

@MainActor
final class CADPlacedAssemblyExportCallerTests: XCTestCase {
    private var workspace: URL!

    override func setUp() async throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloePlacedExportCaller-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let workspace {
            // Release every document this class may have opened through the
            // bridge, so a thrown assertion cannot leave a live package under
            // the workspace we are about to delete.
            for name in ["Placed", "LegacyIntegrity", "LegacyStep",
                         "LegacyComplete", "EditorIntegrity", "EditorClean"] {
                await FloeCAD3DBridge.shared.releaseDocument(
                    at: workspace.appendingPathComponent("\(name).floecad"))
            }
            try? FileManager.default.removeItem(at: workspace)
        }
    }

    /// Locate a repo-relative source file from this test (the file may live in
    /// FloeAgent/Tests now or the package test target after a move).
    private func sourceText(_ relative: String) -> String {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<12 {
            let candidate = directory.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path),
               let text = try? String(contentsOf: candidate, encoding: .utf8) {
                return text
            }
            directory.deleteLastPathComponent()
        }
        XCTFail("could not locate source \(relative) from \(#filePath)")
        return ""
    }

    private func decode(_ json: String) throws -> CadDocumentArguments {
        try JSONDecoder().decode(CadDocumentArguments.self, from: Data(json.utf8))
    }

    private func run(_ document: FloeCADDocument, _ json: String,
                     file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let outcome = document.executeJSON(Data(json.utf8))
        XCTAssertTrue(outcome.isOK,
                      "command failed (\(outcome.status)) \(outcome.errorCode ?? ""): "
                        + "\(outcome.message ?? "") — \(json)",
                      file: file, line: line)
        return (try? JSONSerialization.jsonObject(with: outcome.payload)) as? [String: Any] ?? [:]
    }

    @discardableResult
    private func makeBox(_ document: FloeCADDocument, name: String,
                         min: [Double], max: [Double]) throws -> String {
        let sketch = try run(document, #"{"op":"sketch.create","args":{"name":"\#(name)"}}"#)
        let sketchID = try XCTUnwrap(sketch["sketchID"] as? String)
        _ = try run(document, """
        {"op":"sketch.addEntities","args":{"sketchID":"\(sketchID)",
         "entities":[{"kind":"rect","min":[\(min[0]),\(min[1])],
                      "max":[\(max[0]),\(max[1])]}]}}
        """)
        let extrude = try run(document, """
        {"op":"feature.extrude","args":{"sketchID":"\(sketchID)",
         "seedPoint":[\((min[0] + max[0]) / 2),\((min[1] + max[1]) / 2)],
         "distance":10}}
        """)
        return try XCTUnwrap((extrude["producedBodyIDs"] as? [String])?.first
            ?? (extrude["changedBodyIDs"] as? [String])?.first)
    }

    private func addMeshBody(_ document: FloeCADDocument, name: String) -> String {
        let half: Float = 5
        let positions: [SIMD3<Float>] = [
            [-half, -half, -half], [half, -half, -half],
            [half, half, -half], [-half, half, -half],
            [-half, -half, half], [half, -half, half],
            [half, half, half], [-half, half, half],
        ]
        let normals = positions.map { simd_normalize($0) }
        let indices: [UInt32] = [
            0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7,
            0, 1, 5, 0, 5, 4, 2, 3, 7, 2, 7, 6,
            1, 2, 6, 1, 6, 5, 0, 4, 7, 0, 7, 3,
        ]
        let body = Body(id: BodyID(), name: name, transform: .identity, primitive: nil,
                        render: RenderMesh(positions: positions, normals: normals,
                                           indices: indices), revision: 1)
        document.session.perform(AddBodyCommand(body: body, title: "Add \(name)"))
        return body.id.raw.uuidString
    }

    private func makeWorkspaceDocument() async throws -> (URL, String, String) {
        let url = workspace.appendingPathComponent("Placed.floecad")
        let document = try await FloeCADDocument.create(at: url, name: "Placed")
        let sourceA = try makeBox(document, name: "Part A", min: [0, 0], max: [40, 20])
        let meshBody = addMeshBody(document, name: "Mesh Insert")
        let service = CADAssemblyService(document: document)
        let nested = service.handle(action: "addSubassembly", args: [
            "name": "Nested",
            "transform": ["position": [0.0, 50.0, 0.0],
                          "rotation": [0.0, 0.0, 1.0, 0.0]],
        ])
        XCTAssertEqual(nested["ok"] as? Bool, true, "\(nested)")
        let nestedID = try XCTUnwrap(nested["id"] as? String)

        let placements: [(String, [Double], String?)] = [
            ("Part A 1", [0.0, 0.0, 0.0], nil),
            ("Part A 2", [40.0, 0.0, 0.0], nil),
            ("Part A 3", [100.0, 0.0, 0.0], nestedID),
        ]
        for (name, position, parent) in placements {
            var args: [String: Any] = ["bodyID": sourceA, "name": name,
                                       "transform": ["position": position as [Double]]]
            if let parent { args["parentID"] = parent }
            let reply = service.handle(action: "addInstance", args: args)
            XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        }
        let mesh = service.handle(action: "addInstance", args: [
            "bodyID": meshBody, "name": "Mesh Insert 1",
            "transform": ["position": [0.0, 0.0, 60.0]],
        ])
        XCTAssertEqual(mesh["ok"] as? Bool, true, "\(mesh)")

        let save = await document.save()
        XCTAssertTrue(save.succeeded, save.error ?? "")
        document.close()
        return (url, nestedID, sourceA)
    }

    private func context(cancellation: CancellationToken = CancellationToken()) -> ToolContext {
        ToolContext(runID: UUID(), toolCallID: "call-\(UUID().uuidString)",
                    scope: .local, workspaceRootURL: workspace,
                    cancellation: cancellation, environmentID: "env-1",
                    conversationID: UUID())
    }

    func testDryRunCoverageAndSelectedOccurrenceExportBeforeAnyWrite() async throws {
        let (_, nestedID, _) = try await makeWorkspaceDocument()
        let center = CadDocumentCenter(nativeProposalStoreFileURL: workspace
            .appendingPathComponent("proposals.json"))
        let tool = CadDocumentTool(host: center)

        let dry = try await tool.execute(try decode("""
        {"action":"export","path":"Placed.floecad","output":"assembly.glb",
         "scope":"assembly","dry_run":true}
        """), context: context())
        XCTAssertTrue(dry.summary.contains("\"dry_run\":true"), dry.summary)
        XCTAssertTrue(dry.summary.contains("\"selected_count\":4"), dry.summary)
        XCTAssertTrue(dry.summary.contains("\"complete\":true"), dry.summary)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent("assembly.glb").path),
            "dry_run must not write a file")

        let one = try await tool.execute(try decode("""
        {"action":"export","path":"Placed.floecad","output":"one.glb",
         "scope":"assembly","instance_ids":["\(nestedID)"],"dry_run":true}
        """), context: context())
        XCTAssertTrue(one.summary.contains("\"selected_count\":1"), one.summary)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent("one.glb").path))
        await FloeCAD3DBridge.shared.releaseDocument(
            at: workspace.appendingPathComponent("Placed.floecad"))
    }

    func testSTEPPartialChoiceLeavesNoHalfArtifact() async throws {
        _ = try await makeWorkspaceDocument()
        let center = CadDocumentCenter(nativeProposalStoreFileURL: workspace
            .appendingPathComponent("proposals-partial.json"))
        let tool = CadDocumentTool(host: center)
        let target = workspace.appendingPathComponent("assembly.step")

        let refused = try await tool.execute(try decode("""
        {"action":"export","path":"Placed.floecad","output":"assembly.step",
         "scope":"assembly"}
        """), context: context())
        XCTAssertTrue(refused.summary.contains("\"error\":\"coverage_incomplete\""),
                      refused.summary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path),
                       "an incomplete STEP receipt must not promote a file")

        let accepted = try await tool.execute(try decode("""
        {"action":"export","path":"Placed.floecad","output":"assembly.step",
         "scope":"assembly","accept_partial":true}
        """), context: context())
        XCTAssertTrue(accepted.summary.contains("\"ok\":true"), accepted.summary)
        XCTAssertTrue(accepted.summary.contains("\"partial\":true"), accepted.summary)
        XCTAssertTrue(accepted.summary.contains("\"coverage_complete\":false"), accepted.summary)
        let bytes = try Data(contentsOf: target)
        XCTAssertTrue(String(decoding: bytes.prefix(32), as: UTF8.self)
            .contains("ISO-10303-21"))
        await FloeCAD3DBridge.shared.releaseDocument(
            at: workspace.appendingPathComponent("Placed.floecad"))
    }

    func testStaleExportPreservesExistingTarget() async throws {
        _ = try await makeWorkspaceDocument()
        let center = CadDocumentCenter(nativeProposalStoreFileURL: workspace
            .appendingPathComponent("proposals-stale.json"))
        let tool = CadDocumentTool(host: center)
        let target = workspace.appendingPathComponent("stale.glb")
        let sentinel = Data("original target".utf8)
        try sentinel.write(to: target)

        let reply = try await tool.execute(try decode("""
        {"action":"export","path":"Placed.floecad","output":"stale.glb",
         "scope":"assembly","revision":999999}
        """), context: context())
        XCTAssertTrue(reply.summary.contains("\"error\":\"stale_export\""), reply.summary)
        XCTAssertEqual(try Data(contentsOf: target), sentinel,
                       "a stale export must preserve the previous target bytes")
        await FloeCAD3DBridge.shared.releaseDocument(
            at: workspace.appendingPathComponent("Placed.floecad"))
    }
    func testWriteFailureEndsOnlyTheOwnedExportAndPreservesFiles() async throws {
        _ = try await makeWorkspaceDocument()
        let center = CadDocumentCenter(nativeProposalStoreFileURL: workspace
            .appendingPathComponent("proposals-write-failure.json"))
        let tool = CadDocumentTool(host: center)
        let ctx = context()
        let ownership = NativeCADTaskRegistry.Ownership(
            access: CadDocumentTool.access(for: ctx), documentPath: "Placed.floecad")
        let before = await NativeCADTaskRegistry.shared.status(id: nil, ownership: ownership)
        let previousIDs = Set(before.map(\.id))
        let blocker = workspace.appendingPathComponent("blocked")
        let sentinel = Data("Existing file must remain intact".utf8)
        try sentinel.write(to: blocker)
        do {
            _ = try await tool.execute(try decode("""
            {"action":"export","path":"Placed.floecad","output":"blocked/assembly.glb",
             "scope":"assembly"}
            """), context: ctx)
            XCTFail("A file cannot become the export's parent directory")
        } catch {
            // The real guarded writer refusal is expected, not a fake host.
        }
        let after = await NativeCADTaskRegistry.shared.status(id: nil, ownership: ownership)
        let created = after.filter { !previousIDs.contains($0.id) }
        XCTAssertEqual(created.count, 1, "Exactly one owned export was begun")
        XCTAssertEqual(created.first?.state, .failed,
                       "A write refusal must not leave the task running")
        XCTAssertEqual(try Data(contentsOf: blocker), sentinel)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: blocker.appendingPathComponent("assembly.glb").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent("Placed.floecad").path))
    }

    // MARK: - X31 legacy export integrity

    private func addEmptyMeshBody(_ document: FloeCADDocument, name: String) -> String {
        let body = Body(id: BodyID(), name: name, transform: .identity, primitive: nil,
                        render: RenderMesh(positions: [], normals: [], indices: []),
                        revision: 2)
        document.session.perform(AddBodyCommand(body: body, title: "Add \(name)"))
        return body.id.raw.uuidString
    }

    private func addBrokenTexture(_ document: FloeCADDocument, bodyID: String) {
        let corrupt = Data([0x00, 0x01, 0x02, 0x03])
        var spec = BodyMaterialSpec(baseColor: SIMD4(0.8, 0.2, 0.2, 1))
        spec.baseColorTexture = corrupt
        spec.textureMetadata = [CADMaterialTextureMetadata(
            assetID: UUID(), slot: .baseColor, mimeType: "image/png",
            colorSpace: .srgb, orientation: .topLeft,
            sha256: CADMaterialTexture.digest(corrupt), byteCount: corrupt.count)]
        document.session.perform(SetMaterialCommand(
            bodyIDs: [BodyID(raw: UUID(uuidString: bodyID)!)],
            material: spec, document: document.session.document))
    }

    private func addValidTexture(_ document: FloeCADDocument, bodyID: String) throws {
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        var spec = BodyMaterialSpec(baseColor: SIMD4(0.2, 0.8, 0.3, 1))
        spec.baseColorTexture = png
        spec.textureMetadata = [CADMaterialTextureMetadata(
            assetID: UUID(), slot: .baseColor, mimeType: "image/png",
            colorSpace: .srgb, orientation: .topLeft,
            sha256: CADMaterialTexture.digest(png), byteCount: png.count)]
        spec.uvMapping = CADMaterialUVMapping(source: .boxProjection, axis: .y,
                                              scaleMM: SIMD2(20, 20))
        document.session.perform(SetMaterialCommand(
            bodyIDs: [BodyID(raw: UUID(uuidString: bodyID)!)],
            material: spec, document: document.session.document))
    }

    /// A real PNG whose encoded bytes exceed the 8 MiB material-library cap
    /// while its dimensions/decoded allocation stay inside the GLB writer and
    /// MeshImportKit bounds. Deterministic pseudo-random pixels make the PNG
    /// incompressible, so the byte cap is exercised rather than the header.
    private func largeValidPNG(width: Int = 1800, height: Int = 1800) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        var state: UInt64 = 0x9E3779B97F4A7C15
        for index in stride(from: 0, to: bytes.count, by: 4) {
            for channel in 0..<3 {
                state = state &* 6_364_136_223_846_793_005
                    &+ 1_442_695_040_888_963_407
                bytes[index + channel] = UInt8((state >> 33) & 0xFF)
            }
            bytes[index + 3] = 255
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func addTexture(_ document: FloeCADDocument, bodyID: String, data: Data) {
        var spec = BodyMaterialSpec(baseColor: SIMD4(0.2, 0.8, 0.3, 1),
                                    materialName: "Large Texture")
        spec.baseColorTexture = data
        spec.textureMetadata = [CADMaterialTextureMetadata(
            assetID: UUID(), slot: .baseColor, mimeType: "image/png",
            colorSpace: .srgb, orientation: .topLeft,
            sha256: CADMaterialTexture.digest(data), byteCount: data.count)]
        spec.uvMapping = CADMaterialUVMapping(source: .boxProjection, axis: .y,
                                              scaleMM: SIMD2(20, 20))
        document.session.perform(SetMaterialCommand(
            bodyIDs: [BodyID(raw: UUID(uuidString: bodyID)!)],
            material: spec, document: document.session.document))
    }

    private func exportReply(_ output: ToolExecutionOutput) throws -> [String: Any] {
        let prefix = "cad.document export: "
        let text = output.summary.hasPrefix(prefix)
            ? String(output.summary.dropFirst(prefix.count)) : output.summary
        return try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
            "export reply is not JSON: \(output.summary)")
    }

    /// Stable digest of a .floecad package directory (it is not a single
    /// file): every regular child file's package-relative path + SHA-256.
    private func packageDigest(_ url: URL) throws -> String {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys)
        var rows: [String] = []
        while let child = enumerator?.nextObject() as? URL {
            let values = try child.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }
            let relative = child.path.replacingOccurrences(of: url.path + "/", with: "")
            rows.append(relative + ":" + FloeDigest.sha256Hex(try Data(contentsOf: child)))
        }
        return FloeDigest.sha256Hex(Data(rows.sorted().joined(separator: "\n").utf8))
    }

    private func glbJSON(_ data: Data) throws -> [String: Any] {
        func u32(_ offset: Int) -> UInt32 {
            data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        }
        XCTAssertEqual(u32(0), GLBExporter.magic)
        let length = Int(u32(12))
        let json = data.subdata(in: 20..<(20 + length))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
    }

    /// The legacy unscoped AI export used to report `complete: true` while a
    /// GLB export dropped an invalid mesh or a broken material image. It must
    /// now refuse before writing and return the exact per-body receipt; only
    /// the explicit `scope=part` + `accept_partial=true` route may write a
    /// partial file.
    func testLegacyUnscopedGLBRefusesInvalidMeshAndBrokenTexture() async throws {
        let url = workspace.appendingPathComponent("LegacyIntegrity.floecad")
        let document = try await FloeCADDocument.create(at: url, name: "Legacy Integrity")
        _ = try makeBox(document, name: "Solid", min: [0, 0], max: [40, 20])
        let brokenTexture = try makeBox(document, name: "Broken Texture",
                                        min: [60, 0], max: [70, 10])
        let empty = addEmptyMeshBody(document, name: "Empty Mesh")
        addBrokenTexture(document, bodyID: brokenTexture)
        let save = await document.save()
        XCTAssertTrue(save.succeeded, save.error ?? "")
        let sourceBefore = try packageDigest(url)
        document.close()

        let center = CadDocumentCenter(nativeProposalStoreFileURL: workspace
            .appendingPathComponent("legacy-integrity-proposals.json"))
        let tool = CadDocumentTool(host: center)
        let ctx = context()

        let refused = try await tool.execute(try decode("""
        {"action":"export","path":"LegacyIntegrity.floecad","output":"legacy.glb"}
        """), context: ctx)
        let receipt = try exportReply(refused)
        XCTAssertEqual(receipt["ok"] as? Bool, false, refused.summary)
        XCTAssertEqual(receipt["error"] as? String, "coverage_incomplete", refused.summary)
        XCTAssertTrue((receipt["message"] as? String ?? "").contains("scope=part"),
                      "the refusal must name the explicit partial route: \(refused.summary)")
        let coverage = try XCTUnwrap(receipt["coverage"] as? [String: Any])
        XCTAssertEqual(coverage["complete"] as? Bool, false)
        XCTAssertEqual(coverage["scope"] as? String, "part")
        XCTAssertEqual(coverage["selected_count"] as? Int, 3)
        XCTAssertEqual(coverage["included_count"] as? Int, 2)
        XCTAssertEqual(coverage["excluded_count"] as? Int, 1)
        let excluded = try XCTUnwrap(coverage["excluded"] as? [[String: Any]])
        XCTAssertEqual(excluded.first?["reason"] as? String, "empty_mesh")
        XCTAssertEqual(excluded.first?["body_id"] as? String, empty)
        let items = try XCTUnwrap(coverage["items"] as? [[String: Any]])
        let textured = try XCTUnwrap(items.first { ($0["body_id"] as? String) == brokenTexture })
        let warnings = (textured["material_warnings"] as? [String]) ?? []
        XCTAssertTrue(warnings.contains("texture_baseColor_invalid"), "\(warnings)")
        XCTAssertFalse(warnings.contains("texture_uv_unmapped"),
                       "the writer supplies automatic UVs; invalid texture bytes are a separate loss: \(warnings)")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent("legacy.glb").path),
            "an incomplete legacy receipt must not promote a file")
        XCTAssertEqual(try packageDigest(url), sourceBefore,
                       "a refused export must not modify the source package")

        let accepted = try await tool.execute(try decode("""
        {"action":"export","path":"LegacyIntegrity.floecad","output":"legacy-partial.glb",
         "scope":"part","accept_partial":true}
        """), context: ctx)
        let acceptedReply = try exportReply(accepted)
        XCTAssertEqual(acceptedReply["ok"] as? Bool, true, accepted.summary)
        XCTAssertEqual(acceptedReply["partial"] as? Bool, true)
        XCTAssertEqual(acceptedReply["coverage_complete"] as? Bool, false)
        let acceptedCoverage = try XCTUnwrap(acceptedReply["coverage"] as? [String: Any])
        XCTAssertEqual(acceptedCoverage["included_count"] as? Int, 2)
        XCTAssertEqual(acceptedCoverage["excluded_count"] as? Int, 1)
        XCTAssertEqual(acceptedCoverage["accepted_partial"] as? Bool, true)
        let target = workspace.appendingPathComponent("legacy-partial.glb")
        let bytes = try Data(contentsOf: target)
        XCTAssertEqual(bytes.prefix(4), Data("glTF".utf8))
        XCTAssertEqual(acceptedReply["sha256"] as? String, FloeDigest.sha256Hex(bytes))
        let parsed = try glbJSON(bytes)
        let meshes = try XCTUnwrap(parsed["meshes"] as? [[String: Any]])
        XCTAssertEqual(meshes.count, 2, "only included bodies may become meshes")
        XCTAssertTrue((parsed["images"] as? [Any] ?? []).isEmpty,
                      "the warned invalid image must not be embedded as a usable texture")
        XCTAssertFalse(meshes.contains { ($0["name"] as? String) == "Empty Mesh" })
        XCTAssertEqual(try packageDigest(url), sourceBefore,
                       "a partial export must not modify the source package")
        await FloeCAD3DBridge.shared.releaseDocument(at: url)
    }

    /// STEP has the same legacy bypass: mesh-only bodies used to be skipped
    /// while the reply still said complete. The receipt now names them, no
    /// file is promoted, and the existing explicit part route is the only
    /// partial write.
    func testLegacyUnscopedSTEPRefusesMeshOnlyBodyBeforeWriting() async throws {
        let url = workspace.appendingPathComponent("LegacyStep.floecad")
        let document = try await FloeCADDocument.create(at: url, name: "Legacy STEP")
        _ = try makeBox(document, name: "Solid", min: [0, 0], max: [40, 20])
        _ = addMeshBody(document, name: "Mesh Only")
        let save = await document.save()
        XCTAssertTrue(save.succeeded, save.error ?? "")
        document.close()

        let center = CadDocumentCenter(nativeProposalStoreFileURL: workspace
            .appendingPathComponent("legacy-step-proposals.json"))
        let tool = CadDocumentTool(host: center)
        let ctx = context()

        let refused = try await tool.execute(try decode("""
        {"action":"export","path":"LegacyStep.floecad","output":"legacy.step"}
        """), context: ctx)
        let receipt = try exportReply(refused)
        XCTAssertEqual(receipt["error"] as? String, "coverage_incomplete", refused.summary)
        let coverage = try XCTUnwrap(receipt["coverage"] as? [String: Any])
        XCTAssertEqual(coverage["included_count"] as? Int, 1)
        XCTAssertEqual(coverage["excluded_count"] as? Int, 1)
        let excluded = try XCTUnwrap(coverage["excluded"] as? [[String: Any]])
        XCTAssertEqual(excluded.first?["reason"] as? String, "mesh_only_no_analytic_brep")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent("legacy.step").path),
            "STEP must not be written while the receipt is incomplete")

        let accepted = try await tool.execute(try decode("""
        {"action":"export","path":"LegacyStep.floecad","output":"legacy-partial.step",
         "scope":"part","accept_partial":true}
        """), context: ctx)
        let acceptedReply = try exportReply(accepted)
        XCTAssertEqual(acceptedReply["ok"] as? Bool, true, accepted.summary)
        XCTAssertEqual(acceptedReply["coverage_complete"] as? Bool, false)
        let data = try Data(contentsOf:
            workspace.appendingPathComponent("legacy-partial.step"))
        XCTAssertTrue(String(decoding: data.prefix(32), as: UTF8.self)
            .contains("ISO-10303-21"))
        await FloeCAD3DBridge.shared.releaseDocument(at: url)
    }

    /// A complete legacy export keeps the historical bytes, reports a complete
    /// receipt, and comes from the shared plan rather than a second writer.
    /// A per-body selection exports exactly the chosen body.
    func testLegacyCompleteGLBReceiptAndSelectedBodyMatchSharedPlan() async throws {
        let url = workspace.appendingPathComponent("LegacyComplete.floecad")
        let document = try await FloeCADDocument.create(at: url, name: "Legacy Complete")
        let first = try makeBox(document, name: "First", min: [0, 0], max: [40, 20])
        _ = try makeBox(document, name: "Second", min: [60, 0], max: [70, 10])
        try addValidTexture(document, bodyID: first)
        let save = await document.save()
        XCTAssertTrue(save.succeeded, save.error ?? "")
        document.close()

        let center = CadDocumentCenter(nativeProposalStoreFileURL: workspace
            .appendingPathComponent("legacy-complete-proposals.json"))
        let tool = CadDocumentTool(host: center)
        let ctx = context()

        let exported = try await tool.execute(try decode("""
        {"action":"export","path":"LegacyComplete.floecad","output":"legacy-complete.glb"}
        """), context: ctx)
        let reply = try exportReply(exported)
        XCTAssertEqual(reply["ok"] as? Bool, true, exported.summary)
        XCTAssertEqual(reply["coverage_complete"] as? Bool, true)
        XCTAssertEqual(reply["partial"] as? Bool, false)
        XCTAssertNil(reply["coverage"],
                     "a complete legacy success keeps the bounded reply free of the full receipt")
        let target = workspace.appendingPathComponent("legacy-complete.glb")
        let bytes = try Data(contentsOf: target)
        XCTAssertEqual(reply["sha256"] as? String, FloeDigest.sha256Hex(bytes))
        let parsed = try glbJSON(bytes)
        XCTAssertEqual((parsed["meshes"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual((parsed["images"] as? [[String: Any]])?.count, 1,
                       "a valid material image must stay embedded")
        XCTAssertEqual((parsed["textures"] as? [[String: Any]])?.count, 1)
        let materials = try XCTUnwrap(parsed["materials"] as? [[String: Any]])
        let pbr = try XCTUnwrap(materials.first?["pbrMetallicRoughness"] as? [String: Any])
        XCTAssertEqual((pbr["baseColorTexture"] as? [String: Any])?["index"] as? Int, 0)

        // The bridge must not have its own writer: the written bytes equal the
        // shared part plan on the same saved document.
        await FloeCAD3DBridge.shared.releaseDocument(at: url)
        do {
            let reopened = try await FloeCADDocument.open(at: url)
            defer { reopened.close() }
            guard case let .success(planData, _, planCoverage) = reopened.nativePartExport(
                format: "glb", pageID: nil, acceptPartial: false) else {
                return XCTFail("the shared part plan must export the complete document")
            }
            XCTAssertTrue(planCoverage.complete)
            XCTAssertEqual(planData, bytes,
                           "legacy bridge bytes must come from the shared plan")
        }

        // Per-body selection through the same route exports exactly one body.
        let selected = try await tool.execute(try decode("""
        {"action":"export","path":"LegacyComplete.floecad","output":"legacy-first.glb",
         "scope":"part","body_ids":["\(first)"]}
        """), context: ctx)
        let selectedReply = try exportReply(selected)
        XCTAssertEqual(selectedReply["ok"] as? Bool, true, selected.summary)
        let selectedCoverage = try XCTUnwrap(selectedReply["coverage"] as? [String: Any])
        XCTAssertEqual(selectedCoverage["selected_count"] as? Int, 1)
        XCTAssertEqual(selectedCoverage["included_count"] as? Int, 1)
        XCTAssertEqual(selectedCoverage["complete"] as? Bool, true)
        let selectedData = try Data(contentsOf:
            workspace.appendingPathComponent("legacy-first.glb"))
        let selectedJSON = try glbJSON(selectedData)
        let selectedMeshes = try XCTUnwrap(selectedJSON["meshes"] as? [[String: Any]])
        XCTAssertEqual(selectedMeshes.count, 1)
        let row = try XCTUnwrap((selectedCoverage["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(row["body_id"] as? String, first)
        XCTAssertEqual(selectedMeshes.first?["name"] as? String, row["name"] as? String)
        XCTAssertEqual((selectedJSON["images"] as? [[String: Any]])?.count, 1)
        await FloeCAD3DBridge.shared.releaseDocument(at: url)
    }

    /// The real editor GLB entry points share the plan receipt: an incomplete
    /// document refuses whole-file and per-body export, an explicit partial
    /// choice writes exactly the covered bodies (one file each), and a
    /// complete document stays byte-identical to the historical raw writer.
    func testEditorGLBReceiptGatesWholeAndPerBodyWrites() async throws {
        let url = workspace.appendingPathComponent("EditorIntegrity.floecad")
        let document = try await FloeCADDocument.create(at: url, name: "Editor Integrity")
        defer { document.close() }
        _ = addMeshBody(document, name: "First Slab")
        let second = addMeshBody(document, name: "Second Slab")
        _ = addEmptyMeshBody(document, name: "Empty Mesh")
        addBrokenTexture(document, bodyID: second)
        let viewModel = document.viewModel()

        XCTAssertNil(viewModel.exportGLB(),
                     "an invalid mesh or material image must not become a silent success")
        XCTAssertNotNil(viewModel.errorMessage)
        viewModel.errorMessage = nil
        XCTAssertNil(viewModel.exportGLBPerBody())
        XCTAssertNotNil(viewModel.errorMessage)
        viewModel.errorMessage = nil

        let coverage = try XCTUnwrap(viewModel.glbExportCoverage())
        XCTAssertEqual(coverage.selectedCount, 3)
        XCTAssertEqual(coverage.includedCount, 2)
        XCTAssertEqual(coverage.excludedCount, 1)
        XCTAssertFalse(coverage.complete)

        let whole = try XCTUnwrap(viewModel.exportGLB(acceptPartial: true))
        let wholeJSON = try glbJSON(whole)
        let wholeMeshes = try XCTUnwrap(wholeJSON["meshes"] as? [[String: Any]])
        XCTAssertEqual(wholeMeshes.count, 2)
        XCTAssertEqual(Set(wholeMeshes.compactMap { $0["name"] as? String }),
                       Set(["First Slab", "Second Slab"]))

        let perBody = try XCTUnwrap(viewModel.exportGLBPerBody(acceptPartial: true))
        XCTAssertEqual(perBody.count, 2, "one file per included body")
        XCTAssertEqual(Set(perBody.map(\.name)), Set(["First Slab", "Second Slab"]))
        for payload in perBody {
            let json = try glbJSON(payload.data)
            let meshes = try XCTUnwrap(json["meshes"] as? [[String: Any]])
            XCTAssertEqual(meshes.count, 1, "\(payload.name) must not merge another body")
            XCTAssertEqual(meshes.first?["name"] as? String, payload.name)
            let accessors = try XCTUnwrap(json["accessors"] as? [[String: Any]])
            XCTAssertEqual(accessors.first?["count"] as? Int, 8,
                           "the cube slab keeps its own eight vertices in every file")
        }

        let cleanURL = workspace.appendingPathComponent("EditorClean.floecad")
        let clean = try await FloeCADDocument.create(at: cleanURL, name: "Editor Clean")
        defer { clean.close() }
        let textured = addMeshBody(clean, name: "Textured Slab")
        _ = addMeshBody(clean, name: "Plain Slab")
        try addValidTexture(clean, bodyID: textured)
        let cleanModel = clean.viewModel()
        let cleanCoverage = try XCTUnwrap(cleanModel.glbExportCoverage())
        XCTAssertTrue(cleanCoverage.complete,
                      "\(cleanCoverage.items.map(\.materialWarnings))")
        XCTAssertFalse(cleanCoverage.requiresConfirmation)
        let cleanGLB = try XCTUnwrap(cleanModel.exportGLB())
        XCTAssertEqual(cleanGLB, GLBExporter.glb(bodies: clean.session.document.bodies),
                       "complete exports keep the exact historical bytes")
        let cleanPerBody = try XCTUnwrap(cleanModel.exportGLBPerBody())
        XCTAssertEqual(cleanPerBody.count, clean.session.document.bodies.count)
        for (index, body) in clean.session.document.bodies.enumerated() {
            XCTAssertEqual(cleanPerBody[index].name, body.name)
            XCTAssertEqual(cleanPerBody[index].data, GLBExporter.glb(bodies: [body]),
                           "per-body files stay byte-identical to the raw single-body writer")
        }
        let cleanParsed = try glbJSON(cleanGLB)
        XCTAssertEqual((cleanParsed["images"] as? [[String: Any]])?.count, 1,
                       "the valid material image stays embedded")
    }

    func testRetainedEditorCannotExportAfterItsFacadeCloses() async throws {
        let url = workspace.appendingPathComponent("ClosedEditor.floecad")
        let document = try await FloeCADDocument.create(at: url, name: "Closed Editor")
        _ = addMeshBody(document, name: "Slab")
        let model = document.viewModel()
        XCTAssertNotNil(model.exportGLB())
        let coverageHandler = try XCTUnwrap(model.exchangeCoverageHandler)
        document.close()
        switch coverageHandler("glb", CADExchangeSelection(scope: .part)) {
        case .success:
            XCTFail("a retained editor cannot preflight through a closed owner")
        case .failure(let error):
            XCTAssertEqual(error.code, "document_closed")
        }
        XCTAssertNil(model.exportGLB())
        XCTAssertNil(model.exportGLBPerBody())
        XCTAssertNil(model.exportSTL())
        XCTAssertNil(model.exportThreeMF())
        XCTAssertNil(model.exportOBJ())
        XCTAssertNil(model.exportOBJPerBody())
        XCTAssertNil(model.objBundlePlan(perBody: false))
    }

    func testReviewedExportCannotAuthorizeAChangedDocument() async throws {
        let url = workspace.appendingPathComponent("ReviewedExport.floecad")
        let document = try await FloeCADDocument.create(at: url, name: "Reviewed Export")
        defer { document.close() }
        _ = addMeshBody(document, name: "First")
        let model = document.viewModel()
        let review = try XCTUnwrap(model.glbExportCoverage())
        let bundle = try XCTUnwrap(model.objBundlePlan(
            perBody: false, expectedChangeCount: review.changeCount))
        XCTAssertNotNil(bundle.single?.data)
        _ = addMeshBody(document, name: "Added after review")
        XCTAssertNotEqual(document.exchangeChangeCount, review.changeCount)
        XCTAssertNil(model.exportGLB(acceptPartial: true,
                                     expectedChangeCount: review.changeCount))
        XCTAssertNil(model.exportGLBPerBody(acceptPartial: true,
                                            expectedChangeCount: review.changeCount))
        XCTAssertNil(model.objBundlePlan(perBody: false, acceptPartial: true,
                                         expectedChangeCount: review.changeCount))
        let refreshed = try XCTUnwrap(model.glbExportCoverage())
        XCTAssertEqual(refreshed.includedCount, 2)
        XCTAssertNotNil(model.exportGLB(expectedChangeCount: refreshed.changeCount))
    }

    func testOBJBundleAndPlainOBJUseTheSameBodyCompletenessGate() async throws {
        let url = workspace.appendingPathComponent("OBJCompleteness.floecad")
        let document = try await FloeCADDocument.create(at: url, name: "OBJ Completeness")
        defer { document.close() }
        _ = addMeshBody(document, name: "Valid")
        _ = addEmptyMeshBody(document, name: "Excluded empty mesh")
        let model = document.viewModel()
        XCTAssertNil(model.exportOBJ())
        XCTAssertNil(model.exportOBJPerBody())
        XCTAssertNil(model.objBundlePlan(perBody: false))
        guard case let .coverageRequired(coverage) = document.nativePartExport(
            format: "obj_bundle", pageID: nil) else {
            return XCTFail("legacy material bundles must return a truthful incomplete receipt")
        }
        XCTAssertFalse(coverage.complete)
        XCTAssertEqual(coverage.includedCount, 1)
        XCTAssertEqual(coverage.excludedCount, 1)
        XCTAssertNotNil(model.objBundlePlan(perBody: false, acceptPartial: true,
                                            expectedChangeCount: coverage.changeCount)?.single?.data)
    }

    func testLargeEncodedGLBImageUsesWriterPredicateNotStrictOBJCap() async throws {
        let url = workspace.appendingPathComponent("LargeGLB.floecad")
        let document = try await FloeCADDocument.create(at: url, name: "Large GLB")
        defer { document.close() }
        let bodyID = addMeshBody(document, name: "Large Texture Slab")
        let png = try largeValidPNG()
        XCTAssertGreaterThan(png.count, CADMaterialLimits.maximumTextureBytes)
        XCTAssertTrue(GLBExporter.textureCanBeEmbedded(png),
                      "the image is a valid, dimension-bounded PNG")
        addTexture(document, bodyID: bodyID, data: png)
        let model = document.viewModel()

        let glbCoverage = try XCTUnwrap(model.glbExportCoverage())
        XCTAssertTrue(glbCoverage.complete,
                      "\(glbCoverage.items.map(\.materialWarnings))")
        XCTAssertFalse(glbCoverage.requiresConfirmation)
        let glbWarnings = glbCoverage.items.flatMap(\.materialWarnings)
        XCTAssertFalse(glbWarnings.contains { $0.hasSuffix("_too_large") }, "\(glbWarnings)")
        let glb = try XCTUnwrap(model.exportGLB())
        let parsed = try glbJSON(glb)
        XCTAssertEqual((parsed["images"] as? [[String: Any]])?.count, 1,
                       "a valid >8 MiB imported GLB image must be embedded")

        // USDZ and the OBJ bundle still enforce the material-library 8 MiB cap;
        // coverage must say so instead of letting the GLB predicate leak out.
        let bundleCoverage = try XCTUnwrap(model.meshExportCoverage(format: "obj_bundle"))
        XCTAssertFalse(bundleCoverage.complete)
        XCTAssertTrue(bundleCoverage.requiresConfirmation)
        let bundleWarnings = bundleCoverage.items.flatMap(\.materialWarnings)
        XCTAssertTrue(bundleWarnings.contains("texture_baseColor_too_large"),
                      "\(bundleWarnings)")
        XCTAssertNil(model.objBundlePlan(perBody: false))
        let partialPlan = try XCTUnwrap(model.objBundlePlan(
            perBody: false, acceptPartial: true,
            expectedChangeCount: bundleCoverage.changeCount))
        XCTAssertTrue(partialPlan.hasRefusal)
        XCTAssertEqual(partialPlan.firstDiagnostic?.code, "obj_bundle_texture_too_large")
    }

    func testPlainOBJPartialWritesOnlyIncludedBodiesAndHonorsReviewedCount() async throws {
        let url = workspace.appendingPathComponent("PlainOBJPartial.floecad")
        let document = try await FloeCADDocument.create(at: url, name: "Plain OBJ Partial")
        defer { document.close() }
        let validID = addMeshBody(document, name: "Valid Slab")
        _ = addEmptyMeshBody(document, name: "Empty Slab")
        let model = document.viewModel()
        let coverage = try XCTUnwrap(model.meshExportCoverage(format: "obj"))
        XCTAssertFalse(coverage.complete)
        XCTAssertEqual(coverage.includedCount, 1)
        XCTAssertEqual(coverage.excludedCount, 1)
        XCTAssertNil(model.exportOBJ(), "the default remains strict")
        model.errorMessage = nil

        let partial = try XCTUnwrap(model.exportOBJ(
            acceptPartial: true, expectedChangeCount: coverage.changeCount))
        let text = String(decoding: partial, as: UTF8.self)
        let objectNames = text.split(separator: "\n").filter { $0.hasPrefix("o ") }
        XCTAssertEqual(objectNames, ["o Valid_Slab"],
                       "only the included object is written, with the writer's existing safe name")
        let perBody = try XCTUnwrap(model.exportOBJPerBody(
            acceptPartial: true, expectedChangeCount: coverage.changeCount))
        XCTAssertEqual(perBody.count, 1)
        XCTAssertEqual(perBody[0].name, "Valid Slab")
        XCTAssertEqual(perBody[0].bodyID.uuidString, validID)
        XCTAssertNil(model.exportOBJ(acceptPartial: true,
                                     expectedChangeCount: coverage.changeCount - 1),
                     "a changed reviewed count must refuse before writing")
        XCTAssertNil(model.exportOBJPerBody(acceptPartial: true,
            expectedChangeCount: coverage.changeCount - 1))
        for format in ["stl", "obj", "3mf"] {
            for staleCount in [coverage.changeCount - 1, coverage.changeCount + 1] {
                let outcome = document.nativePartExport(format: format, pageID: nil,
                    acceptPartial: true, expectedChangeCount: staleCount)
                guard case let .failure(error) = outcome else {
                    XCTFail("\(format) must reject a stale reviewed count before producing bytes")
                    continue
                }
                XCTAssertEqual(error.code, "stale_export")
            }
        }
    }

    func testOBJBundleCoverageTreatsFreshOverlapAsLoss() async throws {
        let url = workspace.appendingPathComponent("OBJOverlapCoverage.floecad")
        let document = try await FloeCADDocument.create(at: url, name: "OBJ Overlap Coverage")
        defer { document.close() }
        let bodyIDString = try makeBox(document, name: "Overlap Box",
                                       min: [0, 0], max: [20, 20])
        let bodyID = try XCTUnwrap(UUID(uuidString: bodyIDString))
        let source = try XCTUnwrap(document.session.document.bodies.first {
            $0.id.raw == bodyID
        })
        let table = try XCTUnwrap(document.session.lastFaceTables[source.id])
        XCTAssertEqual(document.session.lastNamingRevisions[source.id],
                       source.meshRevision,
                       "the fixture must start from a fresh face table")
        let entry = try XCTUnwrap(table.entries.first { !$0.triangles.isEmpty })
        let material = BodyMaterialSpec(baseColor: SIMD4(0.8, 0.2, 0.1, 1),
                                        materialName: "Overlap Face")
        let binding = CADFaceMaterialBinding(
            key: CADFaceKey(signature: entry.signature), material: material)
        document.session.perform(SetMaterialAppearanceCommand(
            bodyIDs: [source.id],
            after: [source.id: SetMaterialAppearanceCommand.Snapshot(
                material: source.material,
                faceBindings: [binding, binding])],
            document: document.session.document))

        let model = document.viewModel()
        let coverage = try XCTUnwrap(model.meshExportCoverage(format: "obj_bundle"))
        XCTAssertFalse(coverage.complete)
        XCTAssertTrue(coverage.requiresConfirmation)
        let warnings = coverage.items.flatMap(\.materialWarnings)
        XCTAssertTrue(warnings.contains("face_material_overlap"), "\(warnings)")
        XCTAssertNil(model.objBundlePlan(perBody: false))
        model.errorMessage = nil
        let plan = try XCTUnwrap(model.objBundlePlan(
            perBody: false, acceptPartial: true,
            expectedChangeCount: coverage.changeCount))
        let data = try XCTUnwrap(plan.single?.data)
        let receipt = try XCTUnwrap(plan.single?.receipt)
        XCTAssertTrue(data.starts(with: Data([0x50, 0x4B, 0x03, 0x04])))
        XCTAssertTrue(receipt.warnings.contains("face_material_fallback"))
        XCTAssertTrue(receipt.bodies.flatMap(\.unresolvedFaceBindings)
            .contains { $0.contains("face_triangle_map_overlap_or_invalid") })
    }

    func testOBJBundleAsyncPreflightIsSnapshotBoundAndNamesStayDistinct() async throws {
        let url = workspace.appendingPathComponent("AsyncReview.floecad")
        let document = try await FloeCADDocument.create(at: url, name: "Async Review")
        defer { document.close() }
        let first = addMeshBody(document, name: "Same Name")
        _ = addMeshBody(document, name: "Same Name")
        addTexture(document, bodyID: first,
                   data: Data(base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!)
        let model = document.viewModel()
        let count = document.session.changeCount

        let preflightResult = await model.objBundlePreflight(
            perBody: true, acceptPartial: false, expectedChangeCount: count)
        let preflight = try XCTUnwrap(preflightResult)
        XCTAssertNil(preflight.refusal)
        XCTAssertTrue(preflight.isReady)
        let reviewed = try XCTUnwrap(model.reviewedOBJBundlePlan(
            perBody: true, acceptPartial: false, expectedChangeCount: count))
        XCTAssertEqual(reviewed.items.count, 2)
        XCTAssertEqual(Set(reviewed.items.compactMap(\.bodyID)).count, 2)
        XCTAssertEqual(Set(reviewed.items.map(\.name)), Set(["Same Name"]))
        let cached = try XCTUnwrap(model.objBundlePlan(
            perBody: true, acceptPartial: false, expectedChangeCount: count))
        XCTAssertEqual(reviewed.items.compactMap(\.result.data),
                       cached.items.compactMap(\.result.data),
                       "confirm must reuse the exact reviewed bytes")

        let payloads = try XCTUnwrap(model.exportOBJPerBody())
        let stems = EditorViewModel.perBodyFileStems(
            namesAndIDs: payloads.map { (name: $0.name, id: $0.bodyID) })
        XCTAssertEqual(Set(stems).count, 2)
        XCTAssertTrue(stems.allSatisfy { $0.hasPrefix("Same Name-") }, "\(stems)")

        model.clearOBJBundlePlan()
        XCTAssertNil(model.reviewedOBJBundlePlan(
            perBody: true, acceptPartial: false, expectedChangeCount: count))
        let refreshedResult = await model.objBundlePreflight(
            perBody: true, acceptPartial: false, expectedChangeCount: count)
        let refreshed = try XCTUnwrap(refreshedResult)
        XCTAssertNil(refreshed.refusal)
        _ = addMeshBody(document, name: "Added After Review")
        XCTAssertNil(model.reviewedOBJBundlePlan(
            perBody: true, acceptPartial: false, expectedChangeCount: count))

        let closedURL = workspace.appendingPathComponent("ClosedAsyncReview.floecad")
        let closedDocument = try await FloeCADDocument.create(
            at: closedURL, name: "Closed Async Review")
        _ = addMeshBody(closedDocument, name: "Closed Slab")
        let closedModel = closedDocument.viewModel()
        let closedCount = closedDocument.session.changeCount
        closedDocument.close()
        let closed = await closedModel.objBundlePreflight(
            perBody: false, acceptPartial: false, expectedChangeCount: closedCount)
        XCTAssertEqual(closed?.refusal?.code, "obj_bundle_owner_unavailable")
    }

    func testOBJBundlePreflightCancellationDoesNotCacheOrPublish() async throws {
        let url = workspace.appendingPathComponent("CancelledPreflight.floecad")
        let document = try await FloeCADDocument.create(
            at: url, name: "Cancelled Preflight")
        defer { document.close() }
        let bodyID = addMeshBody(document, name: "Cancelled Slab")
        addTexture(document, bodyID: bodyID,
                   data: Data(base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!)
        let model = document.viewModel()
        let count = document.session.changeCount
        let started = expectation(description: "preflight started")
        let release = expectation(description: "preflight release")
        model.objBundlePreflightSuspensionForTesting = {
            started.fulfill()
            await self.fulfillment(of: [release], timeout: 5)
        }
        let task = Task {
            await model.objBundlePreflight(
                perBody: false, acceptPartial: false,
                expectedChangeCount: count)
        }
        await fulfillment(of: [started], timeout: 5)
        model.clearOBJBundlePlan()
        model.objBundlePreflightSuspensionForTesting = nil
        release.fulfill()
        let cancelled = await task.value
        XCTAssertNil(cancelled, "a cleared generation must not publish a result")
        XCTAssertNil(model.reviewedOBJBundlePlan(
            perBody: false, acceptPartial: false, expectedChangeCount: count))
    }

    func testPerBodyExportNamesKeepCaseVariantsAndSharedUUIDPrefixesDistinct() throws {
        let names = ["Panel", "panel", "a/b", "a-b", "Panel-AAAAAAAA"]
        let ids = try (1...names.count).map { index in
            try XCTUnwrap(UUID(uuidString: String(
                format: "AAAAAAAA-0000-0000-0000-%012d", index)))
        }
        let stems = EditorViewModel.perBodyFileStems(
            namesAndIDs: Array(zip(names, ids)).map { (name: $0.0, id: $0.1) })
        XCTAssertEqual(stems.count, names.count)
        XCTAssertEqual(Set(stems.map { $0.lowercased() }).count, names.count,
                       "a case-insensitive destination must keep every body")
        let directory = workspace.appendingPathComponent("separate-files", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payloads = ids.map { Data($0.uuidString.utf8) }
        for index in names.indices {
            try payloads[index].write(to: directory.appendingPathComponent(stems[index] + ".obj"),
                                      options: .atomic)
        }
        for index in names.indices {
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(stems[index] + ".obj")),
                           payloads[index], "a later body must not replace an earlier file")
        }
    }

    /// The GLB options sheet must show the shared receipt and the explicit
    /// partial choice; a future simplification back to a bare toggle would
    /// reintroduce the silent-drop UI.
    func testMeshOptionsSheetUsesSharedReceiptAndExplicitPartial() throws {
        let editor = sourceText(
            "ThirdParty/FloeCADKit/Sources/FloeCAD/WorkbenchUI/FloeCADEditorView.swift")
        XCTAssertTrue(editor.contains("CADExportCoverageSummary(coverage: coverage)"),
                      "the GLB options sheet must render the shared receipt")
        XCTAssertTrue(editor.contains("cad.ui.export.coverage.confirmPartial"),
                      "an incomplete receipt must offer the explicit partial action")
        XCTAssertTrue(editor.contains("coverage?.requiresConfirmation == true, reviewedChangeCount"),
                      "the partial choice must reach the caller explicitly")
        XCTAssertTrue(editor.contains("viewModel.meshExportCoverage(format: $0)"),
                      "the sheet must read the same plan as cad.document")
        XCTAssertTrue(editor.contains(".task(id: preflightRequest)"),
                      "the OBJ preflight must be a cancellable async task")
        XCTAssertTrue(editor.contains("reviewedOBJBundlePlan("),
                      "confirm must consume the reviewed plan, not rebuild it")
        XCTAssertFalse(editor.contains("viewModel.objBundlePlan("),
                       "the sheet must not run the image/ZIP preflight synchronously")
        XCTAssertTrue(editor.contains("exportGLB(acceptPartial: acceptPartial,"))
        XCTAssertTrue(editor.contains("exportGLBPerBody(acceptPartial: acceptPartial,"))
        XCTAssertTrue(editor.contains("exportSTL()"),
                      "STL must stay on the gated view-model entry point")
        XCTAssertTrue(editor.contains("exportThreeMF()"),
                      "3MF must stay on the gated view-model entry point")

        let sheet = sourceText(
            "ThirdParty/FloeCADKit/Sources/FloeCAD/WorkbenchUI/FloeCADAssemblyExportSheet.swift")
        XCTAssertTrue(sheet.contains("struct CADExportCoverageSummary: View"))
        XCTAssertTrue(sheet.contains("nonisolated enum CADExportCopy"))
        XCTAssertTrue(sheet.contains("cad.export.reason.invalidTexture"),
                      "invalid/oversize image warnings must have actionable copy")
        XCTAssertTrue(sheet.contains("cad.export.reason.textureMapping"),
                      "unmapped texture warnings must have actionable copy")
    }

}

// X30 — direct Present export recovery through the production App adapter and
// the real NativeCADTaskRegistry store. These are behavioral tests of the
// production adapter/session, not source-string checks and not a fake store.
// The exporter's own real background/edit/lease/staging fences are covered by
// the existing CADAnimationExportOptionsTests; these cases verify that the
// host adapter maps those terminal statuses to one honest durable record and
// that cleanup precedes the single finish call.

@MainActor
final class NativeCADEditorAnimationExportRecoveryTests: XCTestCase {
    private nonisolated final class CleanupFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false

        func set() {
            lock.lock()
            flag = true
            lock.unlock()
        }

        var value: Bool {
            lock.lock()
            defer { lock.unlock() }
            return flag
        }
    }

    /// Delegates to the real adapter and records whether the session's cleanup
    /// closure ran before the singleton finish call.
    private nonisolated final class CleanupProbeSink: CADAnimationExportRecoverySink,
        @unchecked Sendable {
        private let inner: NativeCADEditorAnimationExportRecovery
        private let cleanupFlag: CleanupFlag
        private let lock = NSLock()
        private var finishCount = 0
        private var cleanupWasSet = false

        init(inner: NativeCADEditorAnimationExportRecovery,
             cleanupFlag: CleanupFlag) {
            self.inner = inner
            self.cleanupFlag = cleanupFlag
        }

        func beginAnimationExport(
            _ request: CADAnimationExportRecoveryRequest
        ) async throws -> UUID {
            try await inner.beginAnimationExport(request)
        }

        func finishAnimationExport(
            id: UUID,
            outcome: CADAnimationExportRecoveryOutcome,
            detail: String?
        ) async {
            lock.withLock {
                finishCount += 1
                cleanupWasSet = cleanupFlag.value
            }
            await inner.finishAnimationExport(
                id: id, outcome: outcome, detail: detail)
        }

        func lastInterruptedAnimationExport(
            documentURL: URL
        ) async -> CADAnimationExportRecoverySummary? {
            await inner.lastInterruptedAnimationExport(documentURL: documentURL)
        }

        func snapshot() -> (count: Int, cleanupWasSet: Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (finishCount, cleanupWasSet)
        }

        func dismissInterruptedAnimationExport(id: UUID, documentURL: URL) async throws {
            try await inner.dismissInterruptedAnimationExport(id: id, documentURL: documentURL)
        }
    }

    /// Proves the document/tool export API never consults the App editor sink.
    private nonisolated final class CountingSink: CADAnimationExportRecoverySink,
        @unchecked Sendable {
        private let lock = NSLock()
        private var begins = 0

        func beginAnimationExport(
            _ request: CADAnimationExportRecoveryRequest
        ) async throws -> UUID {
            lock.withLock {
                begins += 1
            }
            return UUID()
        }

        func finishAnimationExport(
            id: UUID,
            outcome: CADAnimationExportRecoveryOutcome,
            detail: String?
        ) async {}

        func lastInterruptedAnimationExport(
            documentURL: URL
        ) async -> CADAnimationExportRecoverySummary? { nil }

        var beginCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return begins
        }

        func dismissInterruptedAnimationExport(id: UUID, documentURL: URL) async throws {
            throw CADAnimationExportRecoveryError.recordUnavailable
        }
    }

    private var root: URL!
    private var registryFile: URL!
    private var registry: NativeCADTaskRegistry!
    private var documentURL: URL!
    private var adapter: NativeCADEditorAnimationExportRecovery!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CADEditorRecovery-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        registryFile = root.appendingPathComponent("native-tasks.json")
        registry = NativeCADTaskRegistry(fileURL: registryFile)
        documentURL = root.appendingPathComponent("Assembly.floecad")
        adapter = NativeCADEditorAnimationExportRecovery(
            documentURL: documentURL, registry: registry)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        registryFile = nil
        registry = nil
        documentURL = nil
        adapter = nil
    }

    private var sampleOptions: CADAnimationExportRecoveryOptions {
        CADAnimationExportRecoveryOptions(
            orientation: "portrait",
            resolution: 720,
            frameRate: 24,
            codec: "hevc",
            quality: "higher",
            width: 720,
            height: 1280,
            bitrate: 8_000_000,
            overwrite: false,
            posterEnabled: true)
    }

    private func makeRequest(
        clipID: UUID = UUID()
    ) -> CADAnimationExportRecoveryRequest {
        CADAnimationExportRecoveryRequest(
            documentURL: documentURL,
            options: sampleOptions,
            sourceRevision: 9,
            sourceContentSHA256: "sha-9",
            sourceChangeCount: 27,
            clipID: clipID,
            clipDuration: 1.5,
            suggestedFilename: "Assembly animation.mp4")
    }

    private var nativeOwnership: NativeCADTaskRegistry.Ownership {
        NativeCADTaskRegistry.Ownership(
            environmentID: nil,
            ownerKind: "native-editor",
            ownerID: nil,
            documentPath: documentURL.standardizedFileURL
                .resolvingSymlinksInPath().path)
    }

    func testSavedOptionsRoundTripTheExactSheetChoices() throws {
        let options = CADAnimationExportOptions(
            orientation: .portrait, resolution: .p720, frameRate: .fps24,
            codec: .hevc, quality: .higher)
        let saved = options.recoveryOptions
        let settings = options.exportSettings()
        XCTAssertEqual(saved.orientation, "portrait")
        XCTAssertEqual(saved.resolution, 720)
        XCTAssertEqual(saved.frameRate, 24)
        XCTAssertEqual(saved.codec, "hevc")
        XCTAssertEqual(saved.quality, "higher")
        XCTAssertEqual(saved.width, settings.width)
        XCTAssertEqual(saved.height, settings.height)
        XCTAssertEqual(saved.bitrate, settings.bitrate)
        XCTAssertEqual(saved.overwrite, settings.overwrite)
        XCTAssertEqual(saved.posterEnabled, settings.posterEnabled)
        XCTAssertEqual(try XCTUnwrap(CADAnimationExportOptions(recoveryOptions: saved)), options)

        // An unknown future value is refused instead of silently changing
        // the user's saved selection.
        var unknown = saved
        unknown.quality = "future-quality"
        XCTAssertNil(CADAnimationExportOptions(recoveryOptions: unknown))
    }

    func testBeginPersistsExactNativeIntentAndFinishIsExactlyOnce() async throws {
        let request = makeRequest()
        let session = CADAnimationExportRecoverySession(
            sink: adapter, request: request)
        try await session.begin()
        let id = try XCTUnwrap(session.id)
        XCTAssertTrue(session.isStarted)

        let rows = await registry.status(id: id, ownership: nativeOwnership)
        let record = try XCTUnwrap(rows.first)
        XCTAssertEqual(record.kind, "animation-export")
        XCTAssertEqual(record.state, .running)
        XCTAssertEqual(record.ownership.ownerKind, "native-editor")
        XCTAssertNil(record.ownership.environmentID)
        XCTAssertNil(record.ownership.ownerID)

        let saved = try XCTUnwrap(record.animationExport)
        XCTAssertEqual(saved.destination, .exportPicker)
        XCTAssertEqual(saved.relativeOutput, "Assembly animation.mp4")
        XCTAssertEqual(saved.suggestedFilename, "Assembly animation.mp4")
        XCTAssertEqual(saved.nativeOptions, request.options)
        XCTAssertEqual(saved.options.width, 720)
        XCTAssertEqual(saved.options.height, 1280)
        XCTAssertEqual(saved.options.frameRate, 24)
        XCTAssertEqual(saved.options.codec, "hevc")
        XCTAssertEqual(saved.options.bitrate, 8_000_000)
        XCTAssertFalse(saved.options.overwrite)
        XCTAssertTrue(saved.options.posterEnabled)
        XCTAssertEqual(saved.source?.revision, 9)
        XCTAssertEqual(saved.source?.contentSHA256, "sha-9")
        XCTAssertEqual(saved.source?.changeCount, 27)
        XCTAssertEqual(saved.source?.clipID, request.clipID)
        XCTAssertEqual(saved.source?.clipDuration, 1.5)

        // The status projection is the same inert metadata the host can show;
        // it must never present the temporary render file as a real output
        // path.
        let reply = CadDocumentCenter.nativeTaskRecordJSON(record)
        let export = try XCTUnwrap(reply["export_request"] as? [String: Any])
        XCTAssertEqual(export["destination"] as? String, "export_picker")
        XCTAssertEqual(export["output_is_path"] as? Bool, false)
        XCTAssertNil(export["output"],
                     "the native picker record must not claim a permanent path")
        XCTAssertEqual(export["suggested_filename"] as? String,
                       "Assembly animation.mp4")
        XCTAssertEqual(export["orientation"] as? String, "portrait")
        XCTAssertEqual(export["resolution"] as? Int, 720)
        XCTAssertEqual(export["quality"] as? String, "higher")
        XCTAssertEqual(export["source_revision"] as? Int, 9)
        XCTAssertEqual(export["source_content_sha256"] as? String, "sha-9")
        XCTAssertEqual(export["source_change_count"] as? Int, 27)
        XCTAssertEqual(export["clip_id"] as? String, request.clipID.uuidString)

        await session.finish(outcome: .completed, detail: "verified mp4")
        await session.finish(outcome: .failed, detail: "late duplicate")
        // The adapter itself is also idempotent, so a future caller cannot
        // rewrite the completed record after the session guard has gone away.
        await adapter.finishAnimationExport(
            id: id, outcome: .failed, detail: "adapter late duplicate")
        let after = await registry.status(id: id, ownership: nativeOwnership)
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after.first?.state, .completed)
        XCTAssertEqual(after.first?.detail, "verified mp4")
        XCTAssertEqual(after.first?.animationExport, saved)
    }

    func testDurableBeginFailureLeavesNoRecordAndStartsNothing() async throws {
        // A file cannot act as the registry's parent directory, so the atomic
        // envelope write fails before the adapter returns an id.
        let blocker = root.appendingPathComponent("blocked")
        try Data("existing file".utf8).write(to: blocker)
        let brokenFile = blocker.appendingPathComponent("native-tasks.json")
        let brokenRegistry = NativeCADTaskRegistry(fileURL: brokenFile)
        let brokenAdapter = NativeCADEditorAnimationExportRecovery(
            documentURL: documentURL, registry: brokenRegistry)
        let session = CADAnimationExportRecoverySession(
            sink: brokenAdapter, request: makeRequest())

        do {
            try await session.begin()
            XCTFail("The frame loop must not receive an id without durable intent")
        } catch {
            XCTAssertTrue(error is CocoaError)
        }
        XCTAssertNil(session.id)
        XCTAssertFalse(session.isStarted)
        let rows = await brokenRegistry.status(id: nil, ownership: nativeOwnership)
        XCTAssertTrue(rows.isEmpty, "a failed begin must not leave a phantom task")
        XCTAssertFalse(FileManager.default.fileExists(atPath: brokenFile.path))
    }

    func testAdapterRejectsARequestForAnotherDocument() async throws {
        let otherURL = root.appendingPathComponent("Other.floecad")
        let request = CADAnimationExportRecoveryRequest(
            documentURL: otherURL,
            options: sampleOptions,
            sourceRevision: 1,
            sourceContentSHA256: "other-sha",
            sourceChangeCount: 3,
            clipID: UUID(),
            clipDuration: 0.5,
            suggestedFilename: "Other animation.mp4")
        do {
            _ = try await adapter.beginAnimationExport(request)
            XCTFail("A sink bound to Assembly.floecad must refuse another document")
        } catch let error as CADAnimationExportRecoveryError {
            XCTAssertEqual(error, .documentMismatch)
        }
        let rows = await registry.status(id: nil, ownership: nativeOwnership)
        XCTAssertTrue(rows.isEmpty)
    }

    func testCleanupRunsBeforeOneFinishForACloseOrCancel() async throws {
        let flag = CleanupFlag()
        let probe = CleanupProbeSink(inner: adapter, cleanupFlag: flag)
        let session = CADAnimationExportRecoverySession(
            sink: probe, request: makeRequest())
        try await session.begin()
        let id = try XCTUnwrap(session.id)

        // `close()` and the explicit cancel both settle the exporter as
        // `.cancelled`; the Present lifecycle must finalise that same job once.
        await session.finish(outcome: .cancelled, detail: "closed") {
            flag.set()
            return nil
        }
        await session.finish(outcome: .completed, detail: "late status") {
            flag.set()
            return nil
        }

        let snapshot = probe.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertTrue(snapshot.cleanupWasSet,
                      "finish must observe completed temporary-file cleanup")
        let rows = await registry.status(id: id, ownership: nativeOwnership)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.state, .cancelled)
        XCTAssertEqual(rows.first?.detail, "closed")
    }

    func testBackgroundEditAndCancelStatusesEachReportOneHonestJob() async throws {
        let cancelled = CADAnimationExportStatus(
            id: UUID(),
            progress: CADAnimationExportProgress(phase: .cancelled),
            error: "Video export was cancelled.",
            isCancelled: true)
        let background = CADAnimationExportStatus(
            id: UUID(),
            progress: CADAnimationExportProgress(phase: .failed),
            error: "The app must be in the foreground so the native 3D renderer can draw the animation.")
        let edited = CADAnimationExportStatus(
            id: UUID(),
            progress: CADAnimationExportProgress(phase: .failed),
            error: "The document changed during export; the video was discarded.")

        let cases: [(CADAnimationExportStatus,
                     CADAnimationExportRecoveryOutcome,
                     NativeCADTaskRegistry.State)] = [
            (cancelled, .cancelled, .cancelled),
            (background, .failed, .failed),
            (edited, .failed, .failed),
        ]
        for (status, expectedOutcome, expectedState) in cases {
            let session = CADAnimationExportRecoverySession(
                sink: adapter, request: makeRequest())
            try await session.begin()
            let id = try XCTUnwrap(session.id)
            let outcome = CADAnimationExportRecoveryOutcome(status: status)
            XCTAssertEqual(outcome, expectedOutcome)
            await session.finish(outcome: outcome, detail: status.error)
            let rows = await registry.status(id: id, ownership: nativeOwnership)
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows.first?.state, expectedState)
            XCTAssertEqual(rows.first?.detail, status.error)
        }
    }

    func testReopenRestoresMetadataOnlyUnderTheNativeDocumentOwner() async throws {
        let request = makeRequest()
        let session = CADAnimationExportRecoverySession(
            sink: adapter, request: request)
        try await session.begin()
        let id = try XCTUnwrap(session.id)

        // A real relaunch creates a new registry instance from the same file;
        // the still-running record is downgraded to interrupted and remains
        // inert.
        let reopened = NativeCADTaskRegistry(fileURL: registryFile)
        let reopenedAdapter = NativeCADEditorAnimationExportRecovery(
            documentURL: documentURL, registry: reopened)
        let summary = await reopenedAdapter.lastInterruptedAnimationExport(
            documentURL: documentURL)
        let restored = try XCTUnwrap(summary)
        XCTAssertEqual(restored.id, id)
        XCTAssertEqual(restored.options, request.options)
        XCTAssertEqual(restored.sourceRevision, request.sourceRevision)
        XCTAssertEqual(restored.sourceContentSHA256, request.sourceContentSHA256)
        XCTAssertEqual(restored.sourceChangeCount, request.sourceChangeCount)
        XCTAssertEqual(restored.clipID, request.clipID)
        XCTAssertEqual(restored.clipDuration, request.clipDuration)
        XCTAssertEqual(restored.suggestedFilename, request.suggestedFilename)
        XCTAssertEqual(restored.detail,
                       "the app ended while this job was running; it was not completed")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(request.suggestedFilename).path),
            "recovery metadata must never write a video or reuse a destination")

        // Another document, even with the same registry, cannot see it.
        let foreignAdapter = NativeCADEditorAnimationExportRecovery(
            documentURL: root.appendingPathComponent("Other.floecad"),
            registry: reopened)
        let foreign = await foreignAdapter.lastInterruptedAnimationExport(
            documentURL: root.appendingPathComponent("Other.floecad"))
        XCTAssertNil(foreign)

        // The tool/session ownership is disjoint: a native-editor record grants
        // no tool status/cancel access.
        let toolOwnership = NativeCADTaskRegistry.Ownership(
            environmentID: nil,
            ownerKind: "task",
            ownerID: UUID(),
            documentPath: documentURL.standardizedFileURL.path)
        let toolRows = await reopened.status(id: id, ownership: toolOwnership)
        XCTAssertTrue(toolRows.isEmpty)

        // A newer completed native export supersedes the old interrupted
        // notice instead of nagging forever.
        let retry = CADAnimationExportRecoverySession(
            sink: reopenedAdapter, request: makeRequest())
        try await retry.begin()
        await retry.finish(outcome: .completed, detail: "retry completed")
        let afterRetry = await reopenedAdapter.lastInterruptedAnimationExport(
            documentURL: documentURL)
        XCTAssertNil(afterRetry)
    }

    func testDismissIsDurableAndForeignAdapterCannotFinishOrDismissIt() async throws {
        let id = try await adapter.beginAnimationExport(makeRequest())
        let reopened = NativeCADTaskRegistry(fileURL: registryFile)
        let own = NativeCADEditorAnimationExportRecovery(
            documentURL: documentURL, registry: reopened)
        let foreignURL = root.appendingPathComponent("Foreign.floecad")
        let foreign = NativeCADEditorAnimationExportRecovery(
            documentURL: foreignURL, registry: reopened)

        await foreign.finishAnimationExport(id: id, outcome: .completed,
                                            detail: "foreign late callback")
        do {
            try await foreign.dismissInterruptedAnimationExport(id: id,
                                                                 documentURL: foreignURL)
            XCTFail("A different document cannot dismiss this record")
        } catch let error as CADAnimationExportRecoveryError {
            XCTAssertEqual(error, .recordUnavailable)
        }
        let unchanged = await reopened.status(id: id, ownership: nativeOwnership)
        XCTAssertEqual(unchanged.first?.state, .interrupted)

        try await own.dismissInterruptedAnimationExport(id: id, documentURL: documentURL)
        let diskReopened = NativeCADTaskRegistry(fileURL: registryFile)
        let diskAdapter = NativeCADEditorAnimationExportRecovery(
            documentURL: documentURL, registry: diskReopened)
        let rows = await diskReopened.status(id: id, ownership: nativeOwnership)
        XCTAssertEqual(rows.first?.state, .cancelled)
        let summary = await diskAdapter.lastInterruptedAnimationExport(documentURL: documentURL)
        XCTAssertNil(summary, "Ignoring recovery must survive closing and reopening the editor")
    }

    func testDismissSaveFailurePreservesTheInterruptedRecordForRetry() async throws {
        let id = try await adapter.beginAnimationExport(makeRequest())
        let reopened = NativeCADTaskRegistry(fileURL: registryFile)
        let own = NativeCADEditorAnimationExportRecovery(
            documentURL: documentURL, registry: reopened)
        let diskData = try Data(contentsOf: registryFile)
        try FileManager.default.removeItem(at: registryFile)
        try FileManager.default.createDirectory(at: registryFile,
                                                withIntermediateDirectories: false)
        do {
            try await own.dismissInterruptedAnimationExport(id: id, documentURL: documentURL)
            XCTFail("A failed atomic write cannot dismiss recovery in memory")
        } catch {
            XCTAssertTrue(error is CocoaError)
        }
        let retained = await own.lastInterruptedAnimationExport(documentURL: documentURL)
        XCTAssertEqual(retained?.id, id)
        try FileManager.default.removeItem(at: registryFile)
        try diskData.write(to: registryFile, options: .atomic)
        try await own.dismissInterruptedAnimationExport(id: id, documentURL: documentURL)
        let rows = await reopened.status(id: id, ownership: nativeOwnership)
        XCTAssertEqual(rows.first?.state, .cancelled)
    }

    func testHeadlessDocumentExportNeverUsesTheEditorRecoverySink() async throws {
        let document = try await FloeCADDocument.create(
            at: root.appendingPathComponent("Headless.floecad"),
            name: "Headless")
        defer { document.close() }
        let counting = CountingSink()
        document.installAnimationExportRecoverySink(counting)

        // The direct document API is the tool/headless path. With no clip it
        // refuses before rendering; the editor sink must remain untouched so
        // CadDocumentCenter.exportAnimation stays the only record for a tool
        // export.
        do {
            _ = try await document.exportAnimationMP4(
                to: root.appendingPathComponent("headless.mp4"))
            XCTFail("A document without a clip must not start an export")
        } catch {
            XCTAssertEqual(counting.beginCount, 0)
        }
    }
}
