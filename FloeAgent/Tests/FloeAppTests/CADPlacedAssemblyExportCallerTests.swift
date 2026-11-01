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
import simd
@testable import FloeCAD
import FloeCore
import FloeTools
import FloeWorkbench
@testable import FloeApp

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
        XCTAssertTrue(warnings.contains("texture_uv_unmapped"), "\(warnings)")
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
