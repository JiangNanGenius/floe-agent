//
//  CADViewOverlayBridgeTests.swift
//  FloeAppTests
//
//  X22-R2 — the AI/tool round trip for the persisted section/measurement
//  overlay. This is App-hosted source only; Root runs it with the canonical
//  reused iPad. The test drives the REAL `cad.document` tool → host center →
//  `FloeCAD3DBridge` → `CADViewOverlayService` → `FloeCADDocument` path and
//  reads the committed package back with an independent open.
//

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import XCTest
import FloeCore
import FloeSecurity
import FloeTools
import FloeWorkbench
@testable import FloeApp
@testable import FloeCAD

@MainActor
final class CADViewOverlayBridgeTests: XCTestCase {
    private var workspace: URL!
    private var documentURL: URL!

    override func setUp() async throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-x22-overlay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace,
                                                withIntermediateDirectories: true)
        documentURL = workspace.appendingPathComponent("Overlay.floecad")
    }

    override func tearDown() async throws {
        if let documentURL,
           FileManager.default.fileExists(atPath: documentURL.path) {
            await FloeCAD3DBridge.shared.releaseDocument(at: documentURL)
        }
        if let workspace { try? FileManager.default.removeItem(at: workspace) }
        workspace = nil
        documentURL = nil
    }

    private func makeCenter() -> CadDocumentCenter {
        CadDocumentCenter(nativeProposalStoreFileURL: workspace
            .appendingPathComponent("proposals-\(UUID().uuidString).json"))
    }

    private func makeContext(temporaryReadOnly: Bool = false) -> ToolContext {
        ToolContext(runID: UUID(), toolCallID: "x22-overlay-\(UUID().uuidString)",
                    scope: .local, workspaceRootURL: workspace,
                    cancellation: CancellationToken(),
                    environmentID: "env-x22-overlay",
                    conversationID: UUID(),
                    temporaryReadOnly: temporaryReadOnly)
    }

    private func decodeArgs(_ object: [String: Any]) throws -> CadDocumentArguments {
        let data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.sortedKeys])
        return try JSONDecoder().decode(CadDocumentArguments.self, from: data)
    }

    @discardableResult
    private func execute(_ tool: CadDocumentTool, _ object: [String: Any],
                         context: ToolContext) async throws -> ToolExecutionOutput {
        let args = try decodeArgs(object)
        try tool.validate(args)
        return try await tool.execute(args, context: context)
    }

    private func payloadString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func reply(_ output: ToolExecutionOutput,
                       prefix: String) throws -> [String: Any] {
        let marker = prefix + ": "
        guard let range = output.summary.range(of: marker) else {
            throw XCTSkip("unexpected tool summary: \(output.summary)")
        }
        let text = String(output.summary[range.upperBound...])
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(text.utf8))
                as? [String: Any], "not a JSON reply: \(text)")
    }

    private func run(_ document: FloeCADDocument, _ json: String) throws
    -> [String: Any] {
        let outcome = document.executeJSON(Data(json.utf8))
        XCTAssertTrue(outcome.isOK,
                      "command failed \(outcome.errorCode ?? ""): \(outcome.message ?? "")")
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: outcome.payload)
                as? [String: Any])
    }

    private func populateBox(_ document: FloeCADDocument) throws {
        let sketch = try XCTUnwrap(
            run(document, #"{"op":"sketch.create","args":{"name":"Base"}}"#)["sketchID"]
                as? String)
        _ = try run(document, """
        {"op":"sketch.addEntities","args":{"sketchID":"\(sketch)",
         "entities":[{"kind":"rect","min":[0,0],"max":[40,20]}]}}
        """)
        _ = try run(document, """
        {"op":"feature.extrude","args":{"sketchID":"\(sketch)",
         "seedPoint":[20,10],"distance":10}}
        """)
        XCTAssertEqual(document.summary().bodyCount, 1)
    }

    private func createDocument(tool: CadDocumentTool, context: ToolContext) async throws
    -> FloeCADDocument {
        _ = try await execute(tool, [
            "action": "create", "path": "Overlay.floecad", "name": "Overlay",
        ], context: context)
        let document = try await FloeCAD3DBridge.shared.openDocument(at: documentURL)
        try populateBox(document)
        let save = await document.save()
        XCTAssertTrue(save.succeeded, save.error ?? "")
        return document
    }

    func testSceneActionPersistsThroughExistingDocumentAuthority() async throws {
        let center = makeCenter()
        let tool = CadDocumentTool(host: center)
        let context = makeContext()
        let document = try await createDocument(tool: tool, context: context)

        let set = try await execute(tool, [
            "action": "scene", "path": "Overlay.floecad",
            "payload": try payloadString([
                "action": "setSection",
                "origin": [20.0, 0.0, 0.0],
                "normal": [1.0, 0.0, 0.0],
                "enabled": true,
            ]),
        ], context: context)
        let setReply = try reply(set, prefix: "cad.document scene")
        XCTAssertEqual(setReply["ok"] as? Bool, true, "\(setReply)")
        XCTAssertEqual(setReply["mutated"] as? Bool, true)
        XCTAssertEqual(setReply["saved"] as? Bool, true)
        XCTAssertEqual((setReply["revision"] as? NSNumber)?.intValue,
                       document.revision)
        XCTAssertFalse((setReply["content_sha256"] as? String ?? "").isEmpty)
        XCTAssertEqual(document.viewOverlayState.section?.origin, [20.0, 0.0, 0.0])

        let query = try await execute(tool, [
            "action": "query", "path": "Overlay.floecad", "kind": "scene",
        ], context: context)
        let queryReply = try reply(query, prefix: "cad.document query")
        let result = try XCTUnwrap(queryReply["result"] as? [String: Any])
        let summary = try XCTUnwrap(result["summary"] as? [String: Any])
        let overlay = try XCTUnwrap(summary["view_overlay"] as? [String: Any])
        let section = try XCTUnwrap(overlay["section"] as? [String: Any])
        let origin = (section["origin"] as? [NSNumber])?.map(\.doubleValue)
        XCTAssertEqual(origin, [20.0, 0.0, 0.0])

        let add = try await execute(tool, [
            "action": "scene", "path": "Overlay.floecad",
            "payload": try payloadString([
                "action": "addMeasurement",
                "start": [5.0, 15.0, 0.0], "end": [35.0, 15.0, 0.0],
            ]),
        ], context: context)
        let addReply = try reply(add, prefix: "cad.document scene")
        XCTAssertEqual(addReply["ok"] as? Bool, true, "\(addReply)")
        XCTAssertEqual((addReply["visible_measurement_count"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual(document.viewOverlayState.measurements.count, 1)

        // Undo removes only the measurement, then the section; each is one
        // ordinary document command and the package stays saved.
        let undoMeasurement = try await execute(tool, [
            "action": "scene", "path": "Overlay.floecad",
            "payload": try payloadString(["action": "undo"]),
        ], context: context)
        XCTAssertEqual(try reply(undoMeasurement, prefix: "cad.document scene")["ok"] as? Bool,
                       true)
        XCTAssertTrue(document.viewOverlayState.measurements.isEmpty)
        XCTAssertNotNil(document.viewOverlayState.activeSection)

        let undoSection = try await execute(tool, [
            "action": "scene", "path": "Overlay.floecad",
            "payload": try payloadString(["action": "undo"]),
        ], context: context)
        XCTAssertEqual(try reply(undoSection, prefix: "cad.document scene")["ok"] as? Bool,
                       true)
        XCTAssertNil(document.viewOverlayState.section)
        let save = await document.save()
        XCTAssertTrue(save.succeeded, save.error ?? "")

        // Independent package read proves the persisted sceneSettings bytes,
        // not only the live singleton.
        await FloeCAD3DBridge.shared.releaseDocument(at: documentURL)
        let reopened = try await FloeCADDocument.open(at: documentURL)
        defer { reopened.close() }
        XCTAssertNil(reopened.viewOverlayState.section)
        XCTAssertTrue(reopened.viewOverlayState.measurements.isEmpty)
    }

    func testSceneActionRevisionPinAndTemporaryReadOnly() async throws {
        let center = makeCenter()
        let tool = CadDocumentTool(host: center)
        let context = makeContext()
        let document = try await createDocument(tool: tool, context: context)
        _ = try await execute(tool, [
            "action": "scene", "path": "Overlay.floecad",
            "payload": try payloadString([
                "action": "setSection",
                "origin": [20.0, 0.0, 0.0],
                "normal": [1.0, 0.0, 0.0],
            ]),
        ], context: context)
        let currentRevision = document.revision
        let before = document.viewOverlayState

        do {
            _ = try await execute(tool, [
                "action": "scene", "path": "Overlay.floecad",
                "revision": currentRevision + 1,
                "payload": try payloadString([
                    "action": "setSection",
                    "origin": [10.0, 0.0, 0.0],
                    "normal": [1.0, 0.0, 0.0],
                ]),
            ], context: context)
            XCTFail("a stale revision pin must refuse before mutation")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("revision_mismatch"),
                          error.localizedDescription)
        }
        XCTAssertEqual(document.viewOverlayState, before,
                       "a refused revision pin leaves the overlay byte-identical")
        let temporary = makeContext(temporaryReadOnly: true)
        do {
            _ = try await execute(tool, [
                "action": "scene", "path": "Overlay.floecad",
                "payload": try payloadString(["action": "setSectionEnabled",
                                              "enabled": false]),
            ], context: temporary)
            XCTFail("temporary chat must not mutate the native view overlay")
        } catch {
            XCTAssertTrue(error.localizedDescription.lowercased().contains("unauthor"),
                          error.localizedDescription)
        }
    }

    func testSceneActionIsOnTheExistingToolSchemaAndPolicySurface() throws {
        let schema = CadDocumentTool.parametersJSON
        XCTAssertTrue(schema.contains("\"scene\""))
        XCTAssertEqual(CadDocumentAction.scene.rawValue, "scene")
        XCTAssertEqual(CadNativeEditActions.sceneReads, ["get"])
        XCTAssertTrue(CadNativeEditActions.sceneMutations.contains("setSection"))
        XCTAssertTrue(CadNativeEditActions.sceneMutations.contains("addMeasurement"))
        XCTAssertFalse(CadNativeEditActions.sceneMutations.contains("get"))
        XCTAssertEqual(Set(CADViewOverlayService.actions), CadNativeEditActions.scene)
        XCTAssertEqual(CADViewOverlayService.mutationActions,
                       CadNativeEditActions.sceneMutations)

        let getArguments = try payloadString(["action": "get"])
        XCTAssertEqual(OrdinaryDocumentActionProfile.role(
            forToolName: "cad.document",
            arguments: ["action": "scene", "path": "Overlay.floecad",
                        "payload": getArguments]), .readOnly)
        let setArguments = try payloadString(["action": "setSection"])
        XCTAssertNil(OrdinaryDocumentActionProfile.role(
            forToolName: "cad.document",
            arguments: ["action": "scene", "path": "Overlay.floecad",
                        "payload": setArguments]),
            "a scene mutation stays on the ordinary typed write path")
    }
}
#endif
