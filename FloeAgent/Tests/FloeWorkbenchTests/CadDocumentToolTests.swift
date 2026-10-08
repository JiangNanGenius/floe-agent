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
    var queryRequests: [String] = []
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
        queryRequests.append(requestJSON)
        return queryReply
    }

    func prepareProposal(documentID: String, snapshot: CadDocumentSnapshot, summary: String,
                          operationsJSON: String, access: CadDocumentAccess) async throws -> CadProposal {
        appliedOperationsJSON = operationsJSON
        storedAccess = access
        return CadProposal(documentID: documentID, baseRevision: snapshot.revision,
                           baseSHA256: snapshot.sha256, summary: summary,
                           operationsJSON: operationsJSON, preview: preview)
    }

    func storeProposal(_ proposal: CadProposal) async throws { storedProposal = proposal }
    var storedAccess: CadDocumentAccess?
    var bindingChecked = 0
    var lastBindingDocumentID: String?
    /// Mirrors the real host's applied-proposal tombstone.
    var outcome: (proposalID: UUID, access: CadDocumentAccess, requestID: String, receipt: CadDocumentReceipt)?
    func loadProposal(id: UUID, access: CadDocumentAccess) async throws -> CadProposal? {
        // Mirrors the real host: proposals are only visible to the exact
        // environment/workspace/owner that prepared them, and applied
        // proposals leave only the outcome tombstone.
        guard outcome?.proposalID != id else { return nil }
        guard storedAccess == nil || storedAccess == access else { return nil }
        return storedProposal?.id == id ? storedProposal : nil
    }
    func loadProposalOutcome(id: UUID, access: CadDocumentAccess) async throws -> CadProposalOutcome? {
        guard let outcome, outcome.proposalID == id, outcome.access == access else { return nil }
        return CadProposalOutcome(requestID: outcome.requestID, receipt: outcome.receipt)
    }
    func verifyProposalBinding(_ proposal: CadProposal, documentID: String,
                               access: CadDocumentAccess) async throws {
        bindingChecked += 1
        lastBindingDocumentID = documentID
        guard storedAccess == nil || storedAccess == access else { throw FloeError.unauthorized }
        guard proposal.documentID == documentID else {
            throw FloeError.validationFailed("proposal belongs to \(proposal.documentID), not \(documentID)")
        }
    }
    func removeProposal(id: UUID) async throws {
        if storedProposal?.id == id { storedProposal = nil }
        if outcome?.proposalID == id { outcome = nil }
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
        storedAccess = access
        outcome = (proposal.id, access, requestID, receipt)
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

    @Test("propose normalizes 2-number vectors and named delta objects to the engine's 3-number shape")
    func proposeNormalizesVectors() async throws {
        let host = FakeCadHost()
        let tool = CadDocumentTool(host: host)
        _ = try await execute(tool, #"""
        {"action":"propose","path":"plate.dwg",
         "operations":[{"operation":"move","handle":"35","delta":[1,0]},
                       {"operation":"copy","handle":"35","delta":{"dx":0,"dy":2}},
                       {"operation":"addText","position":{"x":1,"y":2},"text":"hi","height":2,"layer":"0"},
                       {"operation":"mirror","handle":"35","axis":[[0,0],[1,0]]}]}
        """#)
        let operationsJSON = await host.appliedOperationsJSON ?? ""
        #expect(operationsJSON.contains("\"delta\":[1,0,0]"))
        #expect(operationsJSON.contains("\"delta\":[0,2,0]"))
        #expect(operationsJSON.contains("\"position\":[1,2,0]"))
        #expect(operationsJSON.contains("\"axis\":[[0,0,0],[1,0,0]]"))
    }

    @Test("propose rejects a malformed vector with a structured message before the engine")
    func proposeRejectsMalformedVectors() async throws {
        let host = FakeCadHost()
        let tool = CadDocumentTool(host: host)
        var reason: String?
        do {
            _ = try await execute(tool, #"""
            {"action":"propose","path":"plate.dwg",
             "operations":[{"operation":"move","handle":"35","delta":"1,0"}]}
            """#)
        } catch let error as FloeError {
            reason = error.reason
        }
        #expect(reason == "move.delta must be [x,y] or [x,y,z]")
        let applied = await host.appliedOperationsJSON
        #expect(applied == nil, "a malformed proposal must never reach the host")
    }

    @Test("propose refuses nonzero z in vectors and lwpolyline vertices, including nested batches")
    func proposeRejectsNonPlanarCoordinates() async throws {
        let host = FakeCadHost()
        let tool = CadDocumentTool(host: host)
        let cases = [
            #"{"action":"propose","path":"plate.dwg","operations":[{"operation":"move","handle":"35","delta":[1,0,5]}]}"#,
            #"{"action":"propose","path":"plate.dwg","operations":[{"operation":"copy","handle":"35","delta":{"dx":1,"dy":0,"dz":4}}]}"#,
            #"{"action":"propose","path":"plate.dwg","operations":[{"operation":"addLwPolyline","points":[[0,0,3],[1,0,0]],"layer":"0"}]}"#,
            #"{"action":"propose","path":"plate.dwg","operations":[{"operation":"batch","operations":[{"operation":"move","handle":"35","delta":[1,0,2]}]}]}"#
        ]
        for json in cases {
            var reason: String?
            do {
                _ = try await execute(tool, json)
            } catch let error as FloeError {
                reason = error.reason
            }
            #expect(reason?.contains("z must be 0") == true,
                    "case must be refused without projecting z: \(json) -> \(reason ?? "no error")")
        }
        let applied = await host.appliedOperationsJSON
        #expect(applied == nil, "no non-planar proposal may reach the host")
    }

    @Test("propose normalizes nested batch operations with the same canonical shapes")
    func proposeNormalizesNestedBatch() async throws {
        let host = FakeCadHost()
        let tool = CadDocumentTool(host: host)
        _ = try await execute(tool, #"""
        {"action":"propose","path":"plate.dwg",
         "operations":[{"operation":"batch","operations":[
             {"operation":"move","handle":"35","delta":[1,0]},
             {"operation":"rotate","handle":"35","center":{"x":0,"y":0},"angle":90}]}]}
        """#)
        let operationsJSON = await host.appliedOperationsJSON ?? ""
        #expect(operationsJSON.contains("\"delta\":[1,0,0]"))
        #expect(operationsJSON.contains("\"center\":[0,0,0]"))
    }

    @Test("measure enforces the engine's exact arity per kind before the worker")
    func measureArityEnforced() async throws {
        let host = FakeCadHost()
        let tool = CadDocumentTool(host: host)
        var distanceReason: String?
        do {
            _ = try await execute(tool, #"{"action":"measure","path":"plate.dwg","kind":"distance","handles":["35"]}"#)
        } catch let error as FloeError {
            distanceReason = error.reason
        }
        #expect(distanceReason == "CAD distance needs two points or two handles")
        _ = try await execute(tool, #"{"action":"measure","path":"plate.dwg","kind":"distance","points":[[0,0],[10,10]]}"#)
        let requests = await host.queryRequests
        #expect(requests.contains { $0.contains("\"kind\":\"distance\"") && $0.contains("\"points\"") })
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
        // One task owns the whole propose→preview→apply sequence.
        let context = makeContext()
        _ = try await execute(tool, #"""
        {"action":"propose","path":"plate.dwg","operations":[{"operation":"delete","handle":"AB"}]}
        """#, context: context)
        guard let proposal = await host.storedProposal else {
            Issue.record("proposal not stored")
            return
        }
        // Without a grant the tool refuses before touching the host.
        await #expect(throws: FloeError.self) {
            _ = try await execute(tool, """
            {"action":"apply","path":"plate.dwg","proposal_id":"\(proposal.id.uuidString)"}
            """, context: context)
        }
        let initialApplies = await host.applyCount
        #expect(initialApplies == 0)

        let grant = await tool.issueUserGrant(for: proposal)
        let output = try await execute(tool, """
        {"action":"apply","path":"plate.dwg","proposal_id":"\(proposal.id.uuidString)","grant_id":"\(grant)"}
        """, context: context)
        #expect(output.summary.contains("\"saved\":true"))
        let applies = await host.applyCount
        #expect(applies == 1)
        // The applied proposal stays as a replay tombstone (not deleted), so a
        // retry with the SAME request id returns the original receipt without
        // mutating again — the tool path, not only the center.
        let replay = try await execute(tool, """
        {"action":"apply","path":"plate.dwg","proposal_id":"\(proposal.id.uuidString)","grant_id":"\(grant)"}
        """, context: context)
        #expect(replay.summary.contains("\"replay\":true"))
        #expect(await host.applyCount == 1)
        // A different request id (new tool call) after the grant was consumed
        // is a new operation and is refused without mutation.
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
        let context = makeContext()
        _ = try await execute(tool, #"""
        {"action":"propose","path":"plate.dwg","operations":[{"operation":"setRadius","handle":"CD","radius":2}]}
        """#, context: context)
        guard let proposal = await host.storedProposal else {
            Issue.record("proposal not stored")
            return
        }
        let preview = try await execute(tool, """
        {"action":"preview","path":"plate.dwg","proposal_id":"\(proposal.id.uuidString)"}
        """, context: context)
        #expect(preview.summary.contains("CD"))

        let save = try await execute(tool, #"{"action":"save","path":"plate.dwg"}"#)
        #expect(save.summary.contains("\"saved\":true"))
        let export = try await execute(tool, #"{"action":"export","path":"plans/plate.dwg"}"#)
        #expect(export.summary.contains("plans/plate.export.dxf"))
        #expect(CadDocumentTool.defaultExportPath(for: "plate.dwg") == "plate.export.dxf")
    }

    @Test("query action validates kind and dispatches typed engine requests")
    func queryAction() async throws {
        let host = FakeCadHost()
        let tool = CadDocumentTool(host: host)
        // Legal kinds pass validate and reach the engine.
        let entities = try await execute(tool, #"{"action":"query","path":"plate.dwg","kind":"entities","offset":0,"limit":50,"layer":"0"}"#)
        #expect(entities.summary.contains("cad.document query"))
        let layers = try await execute(tool, #"{"action":"query","path":"plate.dwg","kind":"layers"}"#)
        #expect(layers.summary.contains("cad.document query"))
        let drawing = try await execute(tool, #"{"action":"query","path":"plate.dwg","kind":"drawing"}"#)
        #expect(drawing.summary.contains("cad.document query"))
        let text = try await execute(tool, #"{"action":"query","path":"plate.dwg","kind":"text","text":"beam"}"#)
        #expect(text.summary.contains("cad.document query"))
        let snap = try await execute(tool, #"{"action":"query","path":"plate.dwg","kind":"snap","points":[[1.5,2.5]]}"#)
        #expect(snap.summary.contains("cad.document query"))
        let requests = await host.queryRequests
        #expect(requests.count == 5)
        #expect(requests[0].contains("\"operation\":\"entities\""))
        #expect(requests[0].contains("\"limit\":50"))
        #expect(requests[4].contains("\"operation\":\"snap\""))

        // Invalid inputs fail validation before any engine work.
        #expect(throws: FloeError.self) {
            try tool.validate(try decode(#"{"action":"query","path":"plate.dwg"}"#))
        }
        #expect(throws: FloeError.self) {
            try tool.validate(try decode(#"{"action":"query","path":"plate.dwg","kind":"volume"}"#))
        }
        #expect(throws: FloeError.self) {
            try tool.validate(try decode(#"{"action":"query","path":"plate.dwg","kind":"snap"}"#))
        }
        #expect(throws: FloeError.self) {
            try tool.validate(try decode(#"{"action":"query","path":"plate.dwg","kind":"entities","offset":-1}"#))
        }
        #expect(throws: FloeError.self) {
            try tool.validate(try decode(#"{"action":"query","path":"plate.dwg","kind":"entities","limit":501}"#))
        }
        let requestCount = await host.queryRequests.count
        #expect(requestCount == 5)
    }

    @Test("preview/apply enforce proposal ownership and canonical target path")
    func proposalBindingEnforced() async throws {
        let host = FakeCadHost()
        let tool = CadDocumentTool(host: host)
        // One task owns the propose→preview→apply sequence.
        let owner = makeContext()
        _ = try await execute(tool, #"""
        {"action":"propose","path":"plans/plate.dwg","operations":[{"operation":"delete","handle":"AB"}]}
        """#, context: owner)
        guard let proposal = await host.storedProposal else {
            Issue.record("proposal not stored")
            return
        }
        // Preview from the owning context succeeds and binds the supplied path.
        let preview = try await execute(tool, """
        {"action":"preview","path":"plans/plate.dwg","proposal_id":"\(proposal.id.uuidString)"}
        """, context: owner)
        #expect(preview.summary.contains("\"changed\""))
        #expect(await host.bindingChecked >= 1)

        // A different conversation (task owner) cannot even see the proposal.
        let otherContext = makeContext(conversation: UUID())
        await #expect(throws: FloeError.self) {
            let args = try self.decode("""
            {"action":"preview","path":"plans/plate.dwg","proposal_id":"\(proposal.id.uuidString)"}
            """)
            try tool.validate(args)
            _ = try await tool.execute(args, context: otherContext)
        }
        // A different workspace root for the same relative filename is refused.
        let otherRoot = ToolContext(runID: UUID(), toolCallID: "call-1", scope: .local,
                                    workspaceRootURL: URL(fileURLWithPath: "/tmp/other-root"),
                                    cancellation: CancellationToken(), environmentID: "env-1",
                                    conversationID: owner.conversationID)
        await #expect(throws: FloeError.self) {
            let args = try self.decode("""
            {"action":"preview","path":"plans/plate.dwg","proposal_id":"\(proposal.id.uuidString)"}
            """)
            try tool.validate(args)
            _ = try await tool.execute(args, context: otherRoot)
        }

        // The owning task cannot preview the same proposal id against another path.
        await #expect(throws: FloeError.self) {
            let args = try self.decode("""
            {"action":"preview","path":"other/frame.dwg","proposal_id":"\(proposal.id.uuidString)"}
            """)
            try tool.validate(args)
            _ = try await tool.execute(args, context: owner)
        }

        // Apply against a mismatched path is refused before any mutation.
        let grant = await tool.issueUserGrant(for: proposal)
        await #expect(throws: FloeError.self) {
            let args = try self.decode("""
            {"action":"apply","path":"other/frame.dwg","proposal_id":"\(proposal.id.uuidString)","grant_id":"\(grant)"}
            """)
            try tool.validate(args)
            _ = try await tool.execute(args, context: owner)
        }
        #expect(await host.applyCount == 0)

        // Apply with the correct canonical path succeeds for the owner.
        let applied = try await execute(tool, """
        {"action":"apply","path":"plans/plate.dwg","proposal_id":"\(proposal.id.uuidString)","grant_id":"\(grant)"}
        """, context: owner)
        #expect(applied.summary.contains("\"saved\":true"))
        #expect(await host.applyCount == 1)
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
