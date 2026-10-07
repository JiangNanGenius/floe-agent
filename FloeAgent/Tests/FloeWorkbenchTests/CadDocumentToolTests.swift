// FloeWorkbenchTests — cad.document tool contract.
//
// Covers: capability/read requests, proposal validation and preview, trusted
// grant enforcement (unknown/revision/SHA/expiry/single-use), apply/save/export
// receipts, idempotent request ids, and the truthful error surface. The host is
// a fake in-memory implementation; the real engine is exercised by the app
// target and the bundled-WASM node tests.

import Foundation
import Testing
@testable import FloeWorkbench
import FloeTools
import FloeCore

// MARK: - Fake host

actor FakeCadHost: CadDocumentHost {
    struct Denied: Error {}

    var authorized = true
    var editable = true
    var revision: Int64 = 4
    var sha = String(repeating: "a", count: 64)
    var storedProposal: CadProposal?
    var appliedReceipts: [String: CadDocumentReceipt] = [:]
    var applyCount = 0
    var queryReply = #"{"entities":[],"entityCount":0}"#
    var preview = CadDiffPreview(added: [], changed: [], deleted: [], counts: ["added": 0, "changed": 0, "deleted": 0], truncated: false, note: "preview")
    var snapshotCalls = 0
    var appliedOperationsJSON: String?

    func setEditable(_ editable: Bool) { self.editable = editable }
    func setAuthorized(_ value: Bool) { authorized = value }
    func setQueryReply(_ reply: String) { queryReply = reply }
    func setPreview(_ preview: CadDiffPreview) { self.preview = preview }

    func authorizeAccess(access: CadDocumentAccess) async throws {
        if !authorized { throw FloeError.unauthorized }
    }

    func capabilities(access: CadDocumentAccess) async throws -> String {
        #"{"version":2,"operations":["addLine","trim"]}"#
    }

    func snapshot(documentID: String, access: CadDocumentAccess) async throws -> CadDocumentSnapshot {
        snapshotCalls += 1
        return CadDocumentSnapshot(documentID: documentID, format: "dwg", revision: revision,
                                   sha256: sha, unit: "unitless drawing units", activeLayer: "0",
                                   entityCount: 7, layerCount: 2, editable: editable,
                                   diagnostics: [], capabilitiesJSON: #"{"version":2}"#)
    }

    func query(documentID: String, requestJSON: String, access: CadDocumentAccess) async throws -> String {
        queryReply
    }

    func prepareProposal(documentID: String, snapshot: CadDocumentSnapshot, summary: String,
                         operationsJSON: String, access: CadDocumentAccess) async throws -> CadProposal {
        appliedOperationsJSON = operationsJSON
        return CadProposal(documentID: documentID, baseRevision: snapshot.revision,
                           baseSHA256: snapshot.sha256, summary: summary,
                           operationsJSON: operationsJSON, preview: preview)
    }

    func storeProposal(_ proposal: CadProposal) async throws { storedProposal = proposal }
    func loadProposal(id: UUID) async throws -> CadProposal? {
        storedProposal?.id == id ? storedProposal : nil
    }
    func removeProposal(id: UUID) async throws {
        if storedProposal?.id == id { storedProposal = nil }
    }

    func consumeGrant(grantID: String, proposalID: UUID, documentID: String,
                      revision: Int64, sha256: String) async -> CadGrantDecision {
        // The fake delegates to the real store the tool owns? No: the tool's
        // grants live inside the tool, so this path is only reached when a
        // host-owned store is used. Tests exercise the tool path below.
        .unknownGrant
    }

    func apply(proposal: CadProposal, grantID: String, requestID: String,
               access: CadDocumentAccess) async throws -> CadDocumentReceipt {
        applyCount += 1
        if let existing = appliedReceipts[requestID] {
            return CadDocumentReceipt(documentID: existing.documentID, revision: existing.revision,
                                      sha256: existing.sha256, created: existing.created,
                                      saved: true, replay: true)
        }
        revision += 1
        sha = String(repeating: "b", count: 64)
        let receipt = CadDocumentReceipt(documentID: proposal.documentID, revision: revision,
                                         sha256: sha, created: ["AB"], saved: true)
        appliedReceipts[requestID] = receipt
        return receipt
    }

    func save(documentID: String, expectedSHA256: String, requestID: String,
              access: CadDocumentAccess) async throws -> CadDocumentReceipt {
        if let existing = appliedReceipts[requestID] {
            return CadDocumentReceipt(documentID: existing.documentID, revision: existing.revision,
                                      sha256: existing.sha256, created: [], saved: true, replay: true)
        }
        revision += 1
        sha = String(repeating: "c", count: 64)
        let receipt = CadDocumentReceipt(documentID: documentID, revision: revision, sha256: sha,
                                         created: [], saved: true)
        appliedReceipts[requestID] = receipt
        return receipt
    }

    func export(documentID: String, relativeOutput: String,
                access: CadDocumentAccess) async throws -> CadExportReceipt {
        CadExportReceipt(documentID: documentID, relativePath: relativeOutput,
                         sha256: String(repeating: "d", count: 64), byteCount: 128,
                         note: "presentation copy; source unchanged")
    }
}

@Suite("cad.document tool contract")
struct CadDocumentToolTests {
    func makeContext(conversation: UUID? = UUID()) -> ToolContext {
        ToolContext(runID: UUID(), toolCallID: "call-1", scope: .local,
                    workspaceRootURL: URL(fileURLWithPath: "/tmp/workspace"),
                    cancellation: CancellationToken(), environmentID: "env-1",
                    conversationID: conversation)
    }

    func decode(_ json: String) throws -> CadDocumentArguments {
        try JSONDecoder().decode(CadDocumentArguments.self, from: Data(json.utf8))
    }

    func execute(_ tool: CadDocumentTool, _ json: String, context: ToolContext? = nil) async throws -> ToolExecutionOutput {
        let args = try decode(json)
        try tool.validate(args)
        return try await tool.execute(args, context: context ?? makeContext())
    }

    @Test("metadata teaches discover-read-propose-confirm-apply-verify")
    func metadata() {
        #expect(CadDocumentTool.name == "cad.document")
        #expect(CadDocumentTool.riskLabels == [.readsFiles, .writesFiles])
        #expect(CadDocumentTool.isSideEffecting)
        #expect(CadDocumentTool.toolEffect == .mutating)
        let schema = CadDocumentTool.parametersJSON
        for action in ["capabilities", "read", "query", "locate", "measure", "check",
                       "propose", "preview", "apply", "save", "export"] {
            #expect(schema.contains("\"\(action)\""))
        }
        #expect(schema.contains("grant_id"))
        #expect(schema.contains("proposal_id"))
    }

    @Test("capabilities action needs no path and returns engine JSON")
    func capabilitiesAction() async throws {
        let tool = CadDocumentTool(host: FakeCadHost())
        let output = try await execute(tool, #"{"action":"capabilities"}"#)
        #expect(output.summary.contains("\"version\":2"))
        #expect(output.requiresUserAction == false)
    }

    @Test("validate enforces path, action and operation rules")
    func validation() throws {
        let tool = CadDocumentTool(host: FakeCadHost())
        #expect(throws: FloeError.self) { try tool.validate(try decode(#"{"action":"read"}"#)) }
        #expect(throws: FloeError.self) { try tool.validate(try decode(#"{"action":"propose","path":"a.dwg"}"#)) }
        #expect(throws: FloeError.self) {
            try tool.validate(try decode(#"{"action":"propose","path":"a.dwg","operations":[{"operation":"execJavascript"}]}"#))
        }
        #expect(throws: FloeError.self) {
            try tool.validate(try decode(#"{"action":"measure","path":"a.dwg","kind":"volume"}"#))
        }
        #expect(throws: FloeError.self) {
            try tool.validate(try decode(#"{"action":"locate","path":"a.dwg"}"#))
        }
        let valid = try decode(#"{"action":"propose","path":"a.dwg","operations":[{"operation":"addLine","start":[0,0,0],"end":[1,0,0],"layer":"0"}]}"#)
        try tool.validate(valid)
    }

    @Test("read returns the snapshot and the comment scope is honored")
    func readAction() async throws {
        let host = FakeCadHost()
        let tool = CadDocumentTool(host: host)
        let output = try await execute(tool, #"{"action":"read","path":"plans/plate.dwg"}"#)
        #expect(output.summary.contains("\"revision\":4"))
        #expect(output.summary.contains("unitless drawing units"))
        #expect(output.summary.contains("plans/plate.dwg"))
        let snapshotCalls = await host.snapshotCalls
        #expect(snapshotCalls == 1)
    }

    @Test("propose validates through the host, stores the proposal and requires confirmation")
    func proposeAction() async throws {
        let host = FakeCadHost()
        await host.setPreview(CadDiffPreview(
            added: [CadEntityPreview(handle: "AB", type: "Line", layer: "0", bounds: nil)],
            changed: [], deleted: [],
            counts: ["added": 1, "changed": 0, "deleted": 0], truncated: false, note: "scratch only"))
        let tool = CadDocumentTool(host: host)
        let output = try await execute(tool, #"""
        {"action":"propose","path":"plate.dwg","summary":"add a line",
         "operations":[{"operation":"addLine","start":[0,0,0],"end":[10,0,0],"layer":"0"}]}
        """#)
        #expect(output.requiresUserAction == true)
        #expect(output.summary.contains("+1 ~0 -0"))
        #expect(output.summary.contains("User confirmation is required"))
        let stored = await host.storedProposal
        #expect(stored != nil)
        #expect(stored?.summary == "add a line")
        #expect(stored?.baseRevision == 4)
        // Integral numbers must survive as integers for engine integer fields.
        let operationsJSON = await host.appliedOperationsJSON ?? ""
        #expect(operationsJSON.contains("\"start\":[0,0,0]"))
        let decoded = try JSONDecoder().decode([CadEditOperation].self, from: Data(operationsJSON.utf8))
        #expect(decoded.first?.operation == "addLine")
    }

    @Test("propose refuses a drawing with blocking diagnostics")
    func proposeRefusesDiagnostics() async throws {
        let host = FakeCadHost()
        await host.setEditable(false)
        let tool = CadDocumentTool(host: host)
        await #expect(throws: FloeError.self) {
            _ = try await execute(tool, #"""
            {"action":"propose","path":"plate.dwg","operations":[{"operation":"delete","handle":"AB"}]}
            """#)
        }
    }

    @Test("apply requires a UI-issued grant, consumes it once and returns the receipt")
    func applyRequiresGrant() async throws {
        let host = FakeCadHost()
        let tool = CadDocumentTool(host: host)
        _ = try await execute(tool, #"""
        {"action":"propose","path":"plate.dwg","operations":[{"operation":"delete","handle":"AB"}]}
        """#)
        guard let proposal = await host.storedProposal else {
            Issue.record("proposal not stored")
            return
        }
        // Without a grant the tool refuses before touching the host.
        await #expect(throws: FloeError.self) {
            _ = try await execute(tool, """
            {"action":"apply","path":"plate.dwg","proposal_id":"\(proposal.id.uuidString)"}
            """)
        }
        let initialApplies = await host.applyCount
        #expect(initialApplies == 0)

        let grant = await tool.issueUserGrant(for: proposal)
        let output = try await execute(tool, """
        {"action":"apply","path":"plate.dwg","proposal_id":"\(proposal.id.uuidString)","grant_id":"\(grant)"}
        """)
        #expect(output.summary.contains("\"saved\":true"))
        let applies = await host.applyCount
        #expect(applies == 1)
        let remaining = await host.storedProposal
        #expect(remaining == nil)
        // A consumed grant cannot be replayed.
        await #expect(throws: FloeError.self) {
            _ = try await execute(tool, """
            {"action":"apply","path":"plate.dwg","proposal_id":"\(proposal.id.uuidString)","grant_id":"\(grant)"}
            """)
        }
        let finalApplies = await host.applyCount
        #expect(finalApplies == 1)
    }

    @Test("grant store rejects revision, SHA, expiry and replay")
    func grantStoreDecisions() async {
        let store = CadProposalGrantStore(timeToLive: 60)
        let proposal = CadProposal(documentID: "a.dwg", baseRevision: 3,
                                   baseSHA256: String(repeating: "a", count: 64),
                                   summary: "s", operationsJSON: "[]",
                                   preview: CadDiffPreview(added: [], changed: [], deleted: [],
                                                           counts: [:], truncated: false, note: ""))
        let grant = await store.issueGrant(proposal: proposal)
        let missing = await store.consume(grantID: "missing", proposalID: proposal.id,
                                    documentID: "a.dwg", revision: 3,
                                    sha256: proposal.baseSHA256)
        #expect(missing == .unknownGrant)
        let revisionMismatch = await store.consume(grantID: grant, proposalID: proposal.id,
                                    documentID: "a.dwg", revision: 4,
                                    sha256: proposal.baseSHA256)
        #expect(revisionMismatch == .revisionMismatch(expected: 3, actual: 4))
        let shaMismatch = await store.consume(grantID: grant, proposalID: proposal.id,
                                    documentID: "a.dwg", revision: 3,
                                    sha256: String(repeating: "b", count: 64))
        #expect(shaMismatch == .shaMismatch(expected: proposal.baseSHA256, actual: String(repeating: "b", count: 64)))
        let authorized = await store.consume(grantID: grant, proposalID: proposal.id,
                                    documentID: "a.dwg", revision: 3,
                                    sha256: proposal.baseSHA256)
        #expect(authorized == .authorized)
        let replayed = await store.consume(grantID: grant, proposalID: proposal.id,
                                    documentID: "a.dwg", revision: 3,
                                    sha256: proposal.baseSHA256)
        #expect(replayed == .alreadyConsumed)

        let expiring = CadProposalGrantStore(timeToLive: -1)
        let expiredGrant = await expiring.issueGrant(proposal: proposal)
        let expired = await expiring.consume(grantID: expiredGrant, proposalID: proposal.id,
                                       documentID: "a.dwg", revision: 3,
                                       sha256: proposal.baseSHA256)
        // An entry that is already past its TTL is swept before lookup, so the
        // caller sees the same denial as an unknown grant.
        #expect(expired == .unknownGrant || expired == .expired)
    }

    @Test("grant reservation is single-flight, releasable after failure, consumable once")
    func grantReservation() async {
        let store = CadProposalGrantStore(timeToLive: 60)
        let proposal = CadProposal(documentID: "a.dwg", baseRevision: 2,
                                   baseSHA256: String(repeating: "a", count: 64),
                                   summary: "s", operationsJSON: "[]",
                                   preview: CadDiffPreview(added: [], changed: [], deleted: [],
                                                           counts: [:], truncated: false, note: ""))
        let grant = await store.issueGrant(proposal: proposal)
        let first = await store.reserve(grantID: grant, proposalID: proposal.id,
                                        documentID: "a.dwg", revision: 2, sha256: proposal.baseSHA256)
        #expect(first == .reserved)
        let second = await store.reserve(grantID: grant, proposalID: proposal.id,
                                         documentID: "a.dwg", revision: 2, sha256: proposal.baseSHA256)
        #expect(second == .alreadyReserved)
        let whileReserved = await store.consume(grantID: grant, proposalID: proposal.id,
                                                documentID: "a.dwg", revision: 2, sha256: proposal.baseSHA256)
        #expect(whileReserved == .alreadyConsumed)
        await store.releaseReservation(grantID: grant)
        let retry = await store.reserve(grantID: grant, proposalID: proposal.id,
                                        documentID: "a.dwg", revision: 2, sha256: proposal.baseSHA256)
        #expect(retry == .reserved)
        #expect(await store.commitReservation(grantID: grant) == true)
        #expect(await store.commitReservation(grantID: grant) == false)
        let afterCommit = await store.consume(grantID: grant, proposalID: proposal.id,
                                              documentID: "a.dwg", revision: 2, sha256: proposal.baseSHA256)
        #expect(afterCommit == .alreadyConsumed)
    }

    @Test("preview returns the stored overlay and save/export are CAS receipts")
    func previewSaveExport() async throws {
        let host = FakeCadHost()
        await host.setPreview(CadDiffPreview(
            added: [], changed: [CadEntityPreview(handle: "CD", type: "Circle", layer: "0", bounds: CadBounds(min: [0, 0], max: [1, 1]))],
            deleted: [], counts: ["added": 0, "changed": 1, "deleted": 0], truncated: false, note: "n"))
        let tool = CadDocumentTool(host: host)
        _ = try await execute(tool, #"""
        {"action":"propose","path":"plate.dwg","operations":[{"operation":"setRadius","handle":"CD","radius":2}]}
        """#)
        guard let proposal = await host.storedProposal else {
            Issue.record("proposal not stored")
            return
        }
        let preview = try await execute(tool, """
        {"action":"preview","path":"plate.dwg","proposal_id":"\(proposal.id.uuidString)"}
        """)
        #expect(preview.summary.contains("CD"))

        let save = try await execute(tool, #"{"action":"save","path":"plate.dwg"}"#)
        #expect(save.summary.contains("\"saved\":true"))
        let export = try await execute(tool, #"{"action":"export","path":"plans/plate.dwg"}"#)
        #expect(export.summary.contains("plans/plate.export.dxf"))
        #expect(CadDocumentTool.defaultExportPath(for: "plate.dwg") == "plate.export.dxf")
    }

    @Test("query/measure/check dispatch typed engine requests")
    func readOnlyQueries() async throws {
        let host = FakeCadHost()
        let tool = CadDocumentTool(host: host)
        await host.setQueryReply(#"{"value":5,"unit":"unitless drawing units"}"#)
        let measure = try await execute(tool, #"""
        {"action":"measure","path":"plate.dwg","kind":"distance","points":[[0,0],[3,4]]}
        """#)
        #expect(measure.summary.contains("\"value\":5"))
        let check = try await execute(tool, #"{"action":"check","path":"plate.dwg","tolerance":0.01}"#)
        #expect(check.summary.contains("\"value\":5"))
        let locate = try await execute(tool, #"{"action":"locate","path":"plate.dwg","handles":["AB"]}"#)
        #expect(locate.summary.contains("\"value\":5"))
    }

    @Test("authorization denial never reaches document work")
    func authorizationDenied() async throws {
        let host = FakeCadHost()
        await host.setAuthorized(false)
        let tool = CadDocumentTool(host: host)
        await #expect(throws: FloeError.self) {
            _ = try await execute(tool, #"{"action":"read","path":"plate.dwg"}"#)
        }
        #expect(await host.snapshotCalls == 0)
    }
}
