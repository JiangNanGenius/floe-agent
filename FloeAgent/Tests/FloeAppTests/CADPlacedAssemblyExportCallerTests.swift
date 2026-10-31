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
            await FloeCAD3DBridge.shared.releaseDocument(
                at: workspace.appendingPathComponent("Placed.floecad"))
            try? FileManager.default.removeItem(at: workspace)
        }
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
        let (_, nestedID, _) = try makeWorkspaceDocument()
        let center = await CadDocumentCenter(nativeProposalStoreFileURL: workspace
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
        _ = try makeWorkspaceDocument()
        let center = await CadDocumentCenter(nativeProposalStoreFileURL: workspace
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
        _ = try makeWorkspaceDocument()
        let center = await CadDocumentCenter(nativeProposalStoreFileURL: workspace
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
        _ = try makeWorkspaceDocument()
        let center = await CadDocumentCenter(nativeProposalStoreFileURL: workspace
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

}
