// FloeAppTests — native CAD engineering-drawing and assembly closure through
// the REAL engine + host + tool contract.
//
// This suite closes the reported failures end to end on the actual kernel:
//
//   * a `three_d_drawing` / `three_d_assembly` payload that does not name a
//     recognizable operation is REFUSED with the known action list — it can no
//     longer silently default to a read (`pages` / `report`), and the reported
//     model guesses (`addPage` without an action, `drawing.createPage`) are
//     answered with the canonical propose contract;
//   * the engineering-drawing workflow runs for real: page create
//     (`drawing.addPage` / `drawing.standardSheet`) → projection/query →
//     save/reopen → pdf/svg/dxf exports verified from the written bytes
//     (a page-less drawing export is truthfully refused with `page_required`);
//   * the assembly workflow runs for real: `assembly.addInstance` with a
//     transform → query → `setTransform` → `addConstraint` → deterministic
//     `dof`/`interference` reports → save/reopen with the instances intact;
//   * the decision notice carries the trusted `toolAutomatic` origin for an
//     automatic runtime-authority apply and `user` for a CAD-UI confirmation.
//
// Real engine, real packages, real exported bytes; no fixture JSON, no mocks
// of the kernel path. The suite needs the native CAD kernel (FloeCADKit).
//
// SPDX-License-Identifier: MPL-2.0

#if canImport(SwiftUI) && canImport(UIKit)
import XCTest
import FloeCAD
import FloeWorkbench
import FloeTools
import FloeCore
import FloeWorkspace
@testable import FloeApp

@MainActor
final class NativeCADDrawingAssemblyClosureTests: XCTestCase {

    private var workspace: URL!
    private var owner: UUID!

    override func setUp() async throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-cad-closure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        owner = UUID()
    }

    override func tearDown() async throws {
        for name in ["Closure.floecad"] {
            let url = workspace.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                await FloeCAD3DBridge.shared.releaseDocument(at: url)
            }
        }
        try? FileManager.default.removeItem(at: workspace)
    }

    // MARK: - Helpers

    private func access() -> CadDocumentAccess {
        CadDocumentAccess(environmentID: "env-1", workspacePath: workspace.path,
                          ownerKind: "chat", ownerID: owner)
    }

    private func toolContext() -> ToolContext {
        ToolContext(runID: UUID(), toolCallID: "closure-call", toolIdempotencyKey: "closure-idem",
                    scope: .local, workspaceRootURL: workspace,
                    cancellation: CancellationToken(), environmentID: "env-1",
                    conversationID: owner)
    }

    private func request(_ center: CadDocumentCenter, _ documentID: String,
                         _ object: [String: Any], access: CadDocumentAccess) async throws -> [String: Any] {
        let json = String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
        let reply = try await center.threeDAction(documentID: documentID, requestJSON: json, access: access)
        return try XCTUnwrap((try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any],
                             "native reply must be a JSON object: \(reply)")
    }

    /// Draft one native operation and return the proposal id the reply named.
    @discardableResult
    private func propose(_ center: CadDocumentCenter, _ documentID: String, op: String,
                         args: [String: Any], access: CadDocumentAccess,
                         summary: String = "closure") async throws -> UUID {
        let reply = try await request(center, documentID,
                                      ["kind": "propose", "op": op, "args": args, "summary": summary],
                                      access: access)
        let proposal = try XCTUnwrap(reply["proposal"] as? [String: Any], "propose must return a proposal")
        return try XCTUnwrap(UUID(uuidString: try XCTUnwrap(proposal["id"] as? String)))
    }

    /// The interactive CAD-UI confirmation path (single-use grant).
    @discardableResult
    private func applyGranted(_ center: CadDocumentCenter, _ documentID: String,
                              proposal: UUID, access: CadDocumentAccess) async throws -> [String: Any] {
        let grant = try await center.issueNativeCADGrant(proposalID: proposal)
        XCTAssertFalse(grant.isEmpty, "the UI path must mint a single-use grant")
        return try await request(center, documentID,
                                 ["kind": "apply", "proposal_id": proposal.uuidString,
                                  "grant_id": grant, "request_id": "ui-\(proposal.uuidString)"],
                                 access: access)
    }

    /// A real body on a real package: create → base sketch → rectangle →
    /// 80×40×10 extrude, each commit authorized with a UI grant.
    private func makeExtrudedBody(_ center: CadDocumentCenter, documentID: String,
                                  access: CadDocumentAccess) async throws -> String {
        let sketch = try await propose(center, documentID, op: "sketch.create",
                                       args: ["name": "Base"], access: access,
                                       summary: "base sketch")
        _ = try await applyGranted(center, documentID, proposal: sketch, access: access)
        let sketches = try await request(center, documentID,
                                         ["kind": "query", "payload": ["scope": "sketches"]],
                                         access: access)
        let sketchRow = try XCTUnwrap(((sketches["result"] as? [String: Any])?["rows"] as? [[String: Any]])?.first)
        let sketchID = try XCTUnwrap(sketchRow["id"] as? String)

        let profile = try await propose(center, documentID, op: "sketch.addEntities",
                                        args: ["sketchID": sketchID,
                                               "entities": [["kind": "rect", "min": [0, 0], "max": [80, 40]]]],
                                        access: access, summary: "80x40 profile")
        _ = try await applyGranted(center, documentID, proposal: profile, access: access)

        let extrude = try await propose(center, documentID, op: "feature.extrude",
                                        args: ["sketchID": sketchID, "seedPoint": [40, 20], "distance": 10],
                                        access: access, summary: "10 mm extrude")
        _ = try await applyGranted(center, documentID, proposal: extrude, access: access)

        let bodies = try await request(center, documentID,
                                       ["kind": "query", "payload": ["scope": "bodies"]],
                                       access: access)
        let bodyRow = try XCTUnwrap(((bodies["result"] as? [String: Any])?["rows"] as? [[String: Any]])?.first)
        let bodyID = try XCTUnwrap(bodyRow["id"] as? String)
        XCTAssertEqual(bodyRow["analyticBRep"] as? Bool, true, "the extruded body must stay an analytic B-rep")
        return bodyID
    }

    private func pages(_ center: CadDocumentCenter, documentID: String,
                       access: CadDocumentAccess) async throws -> [[String: Any]] {
        let reply = try await request(center, documentID,
                                      ["kind": "drawing", "payload": ["action": "pages"]],
                                      access: access)
        XCTAssertEqual(reply["ok"] as? Bool, true, "pages must be a read-only success: \(reply)")
        return (reply["pages"] as? [[String: Any]]) ?? []
    }

    // MARK: - Engineering drawing closure

    func testDrawingPageWorkflowSaveReopenAndVectorExports() async throws {
        let center = CadDocumentCenter(nativeProposalStoreFileURL:
            workspace.appendingPathComponent("proposals-closure-\(UUID().uuidString).json"))
        let access = access()
        let url = workspace.appendingPathComponent("Closure.floecad")
        _ = try await FloeCADDocument.create(at: url, name: "Closure")
        let documentID = "Closure.floecad"

        // An empty drawing set must REPORT empty — never a false success later.
        let initiallyEmpty = try await pages(center, documentID: documentID, access: access)
        XCTAssertTrue(initiallyEmpty.isEmpty, "a fresh package has no drawing pages")

        let bodyID = try await makeExtrudedBody(center, documentID: documentID, access: access)

        // 1. The standard sheet: four real projected views from the body.
        let sheet = try await propose(center, documentID, op: "drawing.standardSheet",
                                      args: ["bodyID": bodyID, "title": "Closure"],
                                      access: access, summary: "standard sheet")
        let sheetApply = try await applyGranted(center, documentID, proposal: sheet, access: access)
        XCTAssertEqual(sheetApply["ok"] as? Bool, true, "standardSheet apply must commit: \(sheetApply)")
        var currentPages = try await pages(center, documentID: documentID, access: access)
        XCTAssertEqual(currentPages.count, 4, "front/top/side/iso must be created")
        XCTAssertEqual(Set(currentPages.compactMap { $0["kind"] as? String }),
                       ["front", "top", "side", "iso"])

        // 2. One additional page with a real scale and paper size.
        let extra = try await propose(center, documentID, op: "drawing.addPage",
                                      args: ["kind": "iso", "bodyIDs": [bodyID],
                                             "scale": 0.5, "paper": "a3", "showDimensions": true],
                                      access: access, summary: "half-scale iso")
        _ = try await applyGranted(center, documentID, proposal: extra, access: access)
        currentPages = try await pages(center, documentID: documentID, access: access)
        XCTAssertEqual(currentPages.count, 5)
        let page = try XCTUnwrap(currentPages.first)
        let pageID = try XCTUnwrap(page["id"] as? String)
        XCTAssertEqual(page["scale"] as? Double, 1, "the first standard page keeps its own scale")
        let scaledPage = try XCTUnwrap(currentPages.last)
        XCTAssertEqual((scaledPage["scale"] as? NSNumber)?.doubleValue, 0.5)

        // 3. Real projected geometry for a page (not a screenshot).
        let projection = try await request(center, documentID,
                                           ["kind": "drawing",
                                            "payload": ["action": "project", "pageID": pageID]],
                                           access: access)
        XCTAssertEqual(projection["ok"] as? Bool, true, "project must return real geometry: \(projection)")
        let entities = (projection["entities"] as? [[String: Any]]) ?? []
        XCTAssertFalse(entities.isEmpty, "a projected page must carry entities")

        // 4. Save + reopen: the pages persist in the committed package.
        let reopened = try await request(center, documentID,
                                         ["kind": "save", "payload": [:]],
                                         access: access)
        XCTAssertEqual(reopened["ok"] as? Bool, true, "save must commit the drawing set: \(reopened)")
        await FloeCAD3DBridge.shared.releaseDocument(at: url)
        let afterReopen = try await pages(center, documentID: documentID, access: access)
        XCTAssertEqual(afterReopen.count, 5, "the drawing set must survive save/reopen")

        // 5. pdf/svg/dxf through the TOOL: real written bytes verified.
        let tool = CadDocumentTool(host: center)
        let context = toolContext()
        var expecting: [(String, (Data) -> Bool, String)] = [
            ("pdf", { $0.starts(with: Data("%PDF".utf8)) }, "PDF header"),
            ("svg", { String(data: $0, encoding: .utf8)?.contains("<svg") == true }, "SVG root"),
            ("dxf", { String(data: $0, encoding: .utf8)?.contains("SECTION") == true }, "DXF SECTION"),
        ]
        while let entry = expecting.first {
            expecting.removeFirst()
            let (format, check, label) = entry
            let output = "closure.export.\(format)"
            let args = try JSONDecoder().decode(CadDocumentArguments.self, from: Data("""
            {"action":"export","path":"Closure.floecad","output":"\(output)","page_id":"\(pageID)"}
            """.utf8))
            try tool.validate(args)
            let result = try await tool.execute(args, context: context)
            XCTAssertTrue(result.summary.contains("\"ok\":true"),
                          "the \(format) export must succeed: \(result.summary)")
            let written = try Data(contentsOf: workspace.appendingPathComponent(output))
            XCTAssertGreaterThan(written.count, 0, "the \(format) export must write real bytes")
            XCTAssertTrue(check(written), "the \(format) export must carry a real \(label)")
        }

        // 6. A drawing export WITHOUT a page is refused truthfully, never a
        //    fabricated success.
        let pageless = try JSONDecoder().decode(CadDocumentArguments.self, from: Data("""
        {"action":"export","path":"Closure.floecad","output":"closure.pageless.pdf"}
        """.utf8))
        let pagelessResult = try await tool.execute(pageless, context: context)
        XCTAssertTrue(pagelessResult.summary.contains("page_required"),
                      "a page-less PDF export must be refused with page_required: \(pagelessResult.summary)")
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            workspace.appendingPathComponent("closure.pageless.pdf").path),
            "a refused export must not write an empty file")
    }

    // MARK: - Assembly closure

    func testAssemblyInstancesTransformsConstraintsSaveReopen() async throws {
        let center = CadDocumentCenter(nativeProposalStoreFileURL:
            workspace.appendingPathComponent("proposals-assembly-\(UUID().uuidString).json"))
        let access = access()
        let url = workspace.appendingPathComponent("Closure.floecad")
        _ = try await FloeCADDocument.create(at: url, name: "Closure")
        let documentID = "Closure.floecad"
        let bodyID = try await makeExtrudedBody(center, documentID: documentID, access: access)

        // An empty assembly reports empty and carries no stale value.
        let emptyReport = try await request(center, documentID,
                                            ["kind": "assembly", "payload": ["action": "report"]],
                                            access: access)
        XCTAssertEqual(emptyReport["ok"] as? Bool, true)
        XCTAssertEqual((emptyReport["instances"] as? [[String: Any]])?.count, 0)

        // 1. Place the instance with an explicit transform.
        let placement = try await propose(center, documentID, op: "assembly.addInstance",
                                          args: ["bodyID": bodyID,
                                                 "transform": ["position": [0, 0, 0]],
                                                 "name": "Base part"],
                                          access: access, summary: "place base part")
        let placed = try await applyGranted(center, documentID, proposal: placement, access: access)
        XCTAssertEqual(placed["ok"] as? Bool, true, "addInstance must commit: \(placed)")
        let report = try await request(center, documentID,
                                       ["kind": "assembly", "payload": ["action": "report"]],
                                       access: access)
        let instances = try XCTUnwrap(report["instances"] as? [[String: Any]])
        XCTAssertEqual(instances.count, 1)
        let instanceID = try XCTUnwrap(instances.first?["id"] as? String)

        // 2. Move it deterministically.
        let moved = try await propose(center, documentID, op: "assembly.setTransform",
                                      args: ["id": instanceID, "transform": ["position": [60, 0, 0]]],
                                      access: access, summary: "move part")
        _ = try await applyGranted(center, documentID, proposal: moved, access: access)
        let afterMove = try await request(center, documentID,
                                          ["kind": "assembly", "payload": ["action": "instances"]],
                                          access: access)
        let movedRow = try XCTUnwrap((afterMove["instances"] as? [[String: Any]])?.first)
        let transform = try XCTUnwrap(movedRow["transform"] as? [String: Any])
        let position = try XCTUnwrap(transform["position"] as? [Double])
        XCTAssertEqual(position, [60, 0, 0], "the committed transform must be the placed one")

        // 3. Ground it and read the deterministic checks.
        let grounded = try await propose(center, documentID, op: "assembly.addConstraint",
                                         args: ["kind": "fixed", "instanceA": instanceID],
                                         access: access, summary: "ground the part")
        _ = try await applyGranted(center, documentID, proposal: grounded, access: access)
        let dof = try await request(center, documentID,
                                    ["kind": "measure", "payload": ["kind": "dof"]],
                                    access: access)
        XCTAssertEqual(dof["ok"] as? Bool, true, "dof must be a deterministic success: \(dof)")
        let dofResult = try XCTUnwrap(dof["result"] as? [String: Any])
        XCTAssertNotNil(dofResult["assemblyDOF"], "dof must report the assembly DOF")
        XCTAssertNotNil(dofResult["fullyConstrained"])
        let interference = try await request(center, documentID,
                                             ["kind": "measure",
                                              "payload": ["kind": "interference", "toleranceMM": 0.001]],
                                             access: access)
        XCTAssertEqual(interference["ok"] as? Bool, true,
                       "interference must run its exact check: \(interference)")

        // 4. Save + reopen keeps instances and constraints.
        let saved = try await request(center, documentID, ["kind": "save", "payload": [:]],
                                      access: access)
        XCTAssertEqual(saved["ok"] as? Bool, true)
        await FloeCAD3DBridge.shared.releaseDocument(at: url)
        let reopened = try await request(center, documentID,
                                         ["kind": "assembly", "payload": ["action": "report"]],
                                         access: access)
        let reopenedInstances = try XCTUnwrap(reopened["instances"] as? [[String: Any]])
        XCTAssertEqual(reopenedInstances.count, 1, "the instance must survive save/reopen")
        XCTAssertEqual(reopenedInstances.first?["id"] as? String, instanceID)
        let constraints = (reopened["constraints"] as? [[String: Any]]) ?? []
        XCTAssertEqual(constraints.count, 1, "the fixed constraint must survive save/reopen")
    }

    // MARK: - Malformed requests and the exact propose contract

    func testMalformedServiceRequestsAreRefusedWithTheProposeContract() async throws {
        let center = CadDocumentCenter(nativeProposalStoreFileURL:
            workspace.appendingPathComponent("proposals-malformed-\(UUID().uuidString).json"))
        let access = access()
        let url = workspace.appendingPathComponent("Closure.floecad")
        _ = try await FloeCADDocument.create(at: url, name: "Closure")
        let documentID = "Closure.floecad"
        let bodyID = try await makeExtrudedBody(center, documentID: documentID, access: access)

        // The reported silent default: a payload without any action.
        let missing = try await request(center, documentID,
                                        ["kind": "drawing", "payload": [:]],
                                        access: access)
        XCTAssertEqual(missing["ok"] as? Bool, false, "an action-less payload must not succeed")
        XCTAssertEqual(missing["error"] as? String, "missing_action")
        let missingMessage = try XCTUnwrap(missing["message"] as? String)
        XCTAssertTrue(missingMessage.contains("addPage"))
        XCTAssertTrue(missingMessage.contains("standardSheet"))
        XCTAssertEqual((missing["known_actions"] as? [String])?.contains("pages"), true)

        // The reported model guess.
        let guessed = try await request(center, documentID,
                                        ["kind": "drawing",
                                         "payload": ["op": "drawing.createPage"]],
                                        access: access)
        XCTAssertEqual(guessed["error"] as? String, "unknown_op")
        XCTAssertTrue((guessed["message"] as? String)?.contains("Did you mean 'addPage'?") == true)

        // A direct mutating payload names the exact propose call.
        let direct = try await request(center, documentID,
                                       ["kind": "assembly",
                                        "payload": ["action": "addInstance", "bodyID": bodyID]],
                                       access: access)
        XCTAssertEqual(direct["error"] as? String, "proposal_required")
        let propose = try XCTUnwrap(direct["propose"] as? [String: Any])
        XCTAssertEqual(propose["op"] as? String, "assembly.addInstance")
        XCTAssertEqual((propose["args"] as? [String: Any])?["bodyID"] as? String, bodyID)

        // The legacy op spelling is normalized onto the same contract.
        let legacy = try await request(center, documentID,
                                       ["kind": "assembly",
                                        "payload": ["op": "assembly.addInstance", "bodyID": bodyID]],
                                       access: access)
        XCTAssertEqual(legacy["error"] as? String, "proposal_required")
        XCTAssertEqual((legacy["propose"] as? [String: Any])?["op"] as? String, "assembly.addInstance")

        // A read-only action with the legacy op form runs directly.
        let report = try await request(center, documentID,
                                       ["kind": "assembly", "payload": ["op": "assembly.report"]],
                                       access: access)
        XCTAssertEqual(report["ok"] as? Bool, true)
        XCTAssertNotNil(report["task_id"], "read-only jobs stay durably registered")
    }

    // MARK: - Decision origin marker

    func testDecisionOriginDistinguishesAutomaticFromUserApply() async throws {
        // The origin-aware deliverer records exactly what the conversation
        // layer would persist; the production AppEnvironment wires the same
        // shape through ConversationCenter.recordAutomaticProposalDecision.
        let recorder = DecisionOriginRecorder()
        let center = CadDocumentCenter(
            nativeProposalStoreFileURL: workspace.appendingPathComponent("proposals-origin-\(UUID().uuidString).json"),
            decisionDeliverer: { conversationID, proposalID, decision, _, _, origin in
                await recorder.record(conversationID: conversationID, proposalID: proposalID,
                                      decision: decision, origin: origin)
            })
        let access = access()
        let url = workspace.appendingPathComponent("Closure.floecad")
        _ = try await FloeCADDocument.create(at: url, name: "Closure")
        let documentID = "Closure.floecad"

        // 1. UI confirmation → `.user`.
        let uiProposal = try await propose(center, documentID, op: "sketch.create",
                                           args: ["name": "UI sketch"], access: access)
        _ = try await applyGranted(center, documentID, proposal: uiProposal, access: access)
        try await waitForDecisions(recorder, count: 1)
        let uiDecisions = await recorder.snapshot()
        let uiDecision = try XCTUnwrap(uiDecisions.first)
        XCTAssertEqual(uiDecision.origin, .user)
        XCTAssertEqual(uiDecision.decision, "applied")

        // 2. Automatic runtime-authority apply → `.toolAutomatic`.
        let sketchID = try await firstSketchID(center, documentID: documentID, access: access)
        let autoProposal = try await propose(center, documentID, op: "sketch.addEntities",
                                             args: ["sketchID": sketchID,
                                                    "entities": [["kind": "circle", "center": [10, 10], "radius": 5]]],
                                             access: access)
        let context = toolContext()
        let args = try JSONDecoder().decode(CadDocumentArguments.self, from: Data("""
        {"action":"apply","path":"Closure.floecad","proposal_id":"\(autoProposal.uuidString)"}
        """.utf8))
        let binding = try CadDocumentTool.runtimeAuthorityBinding(for: args, context: context)
        let authorization = CadAutomaticAuthorization(
            runID: binding.runID, taskID: binding.taskID,
            operationID: binding.operationID, idempotencyKey: binding.idempotencyKey,
            approvalGrantID: UUID(), binding: binding)
        let reply = try await center.applyAutomatic(proposalID: autoProposal,
                                                    authorization: authorization,
                                                    requestID: "auto-\(autoProposal.uuidString)",
                                                    access: access)
        XCTAssertTrue(reply.contains("\"ok\":true"), "the automatic apply must commit: \(reply)")
        try await waitForDecisions(recorder, count: 2)
        let automaticDecisions = await recorder.snapshot()
        let automatic = try XCTUnwrap(automaticDecisions.last)
        XCTAssertEqual(automatic.origin, .toolAutomatic,
                       "an automatic apply must carry the toolAutomatic marker")
        XCTAssertEqual(automatic.proposalID, autoProposal)
    }

    private func firstSketchID(_ center: CadDocumentCenter, documentID: String,
                               access: CadDocumentAccess) async throws -> String {
        let sketches = try await request(center, documentID,
                                         ["kind": "query", "payload": ["scope": "sketches"]],
                                         access: access)
        let row = try XCTUnwrap(((sketches["result"] as? [String: Any])?["rows"] as? [[String: Any]])?.first)
        return try XCTUnwrap(row["id"] as? String)
    }

    private func waitForDecisions(_ recorder: DecisionOriginRecorder, count: Int) async throws {
        for _ in 0..<100 {
            if await recorder.snapshot().count >= count { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("the deliverer did not receive \(count) decision notice(s)")
    }
}

/// Records the decisions the CadDocumentCenter deliverer hands to the
/// conversation layer, including the trusted origin marker.
actor DecisionOriginRecorder {
    struct Entry: Sendable {
        var conversationID: UUID
        var proposalID: UUID
        var decision: String
        var origin: ProposalDecisionNoticeProjection.DecisionOrigin
    }

    private var entries: [Entry] = []

    func record(conversationID: UUID, proposalID: UUID, decision: String,
                origin: ProposalDecisionNoticeProjection.DecisionOrigin) {
        entries.append(Entry(conversationID: conversationID, proposalID: proposalID,
                             decision: decision, origin: origin))
    }

    func snapshot() -> [Entry] { entries }
}
#endif
