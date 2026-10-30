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
import FloeModels

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
    var exportRealPayload: Data?

    func setEditable(_ editable: Bool) { self.editable = editable }
    func setAuthorized(_ value: Bool) { authorized = value }
    func setQueryReply(_ reply: String) { queryReply = reply }
    func setPreview(_ preview: CadDiffPreview) { self.preview = preview }

    func authorizeAccess(access: CadDocumentAccess) async throws {
        if !authorized { throw FloeError.unauthorized }
    }

    // MARK: Native bridge recording

    var threeDRequests: [String] = []
    var threeDReply: String = #"{"ok":true,"state":{"bodies":[]}}"#

    func setThreeDReply(_ reply: String) { threeDReply = reply }

    var createdPackages: [String] = []
    var createReply: CadNativePackageReceipt = CadNativePackageReceipt(
        relativePath: "untitled.floecad", name: "untitled", revision: 1,
        schemaVersion: 1, contentSHA256: String(repeating: "0", count: 64))
    var createError: Error?
    var nativeCapabilitiesReply: String = #"{"ok":true,"available":true}"#

    func setCreateError(_ error: Error?) { createError = error }

    func createNativePackage(relativePath: String, name: String,
                             access: CadDocumentAccess) async throws -> CadNativePackageReceipt {
        if let createError { throw createError }
        createdPackages.append(relativePath)
        var receipt = createReply
        receipt.relativePath = relativePath
        receipt.name = name
        return receipt
    }

    func nativeCapabilities(access: CadDocumentAccess) async throws -> String {
        nativeCapabilitiesReply
    }

    func threeDAction(documentID: String, requestJSON: String,
                      access: CadDocumentAccess) async throws -> String {
        threeDRequests.append(requestJSON)
        return threeDReply
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

    // MARK: Runtime-approved automatic apply

    var automaticApplies = 0
    var nativeAutomaticApplies = 0
    var lastAutomaticAuthorization: CadAutomaticAuthorization?

    func applyAutomatic(proposal: CadProposal, authorization: CadAutomaticAuthorization,
                        requestID: String, access: CadDocumentAccess) async throws -> CadDocumentReceipt {
        automaticApplies += 1
        lastAutomaticAuthorization = authorization
        if let existing = appliedReceipts[requestID] {
            return CadDocumentReceipt(documentID: existing.documentID, revision: existing.revision,
                                      sha256: existing.sha256, created: existing.created,
                                      saved: true, replay: true)
        }
        revision += 1
        sha = String(repeating: "e", count: 64)
        let receipt = CadDocumentReceipt(documentID: proposal.documentID, revision: revision,
                                         sha256: sha, created: ["AB"], saved: true)
        appliedReceipts[requestID] = receipt
        storedAccess = access
        outcome = (proposal.id, access, requestID, receipt)
        return receipt
    }

    func applyAutomatic(proposalID: UUID, authorization: CadAutomaticAuthorization,
                        requestID: String, access: CadDocumentAccess) async throws -> String {
        nativeAutomaticApplies += 1
        lastAutomaticAuthorization = authorization
        return #"{"ok":true,"replay":false,"mode":"runtime-authority","receipt":{"proposal_id":"\#(proposalID.uuidString)","revision":1}}"#
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
        var sha = String(repeating: "d", count: 64)
        var byteCount = 128
        // S3-D focused tests opt this into committing real bytes at the export
        // path so the production run-output publication exercises the full
        // commit → snapshot → verify chain against an actual file. `nil`
        // (default) preserves the original synthetic-receipt behavior.
        if let payload = exportRealPayload, let path = access.workspacePath,
           !path.isEmpty, FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path).appendingPathComponent(relativeOutput)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try payload.write(to: url, options: .atomic)
            sha = try FloeDigest.sha256Hex(payload)
            byteCount = payload.count
        }
        return CadExportReceipt(documentID: documentID, relativePath: relativeOutput,
                                sha256: sha, byteCount: byteCount,
                                note: "presentation copy; source unchanged")
    }

    func setExportPayload(_ data: Data?) { exportRealPayload = data }

    // MARK: Animation

    var animationCaptureRequests: [CadAnimationCaptureRequest] = []
    var animationExportRequests: [(String, CadAnimationExportOptions)] = []
    var animationCaptureTask = UUID()
    var animationExportTask = UUID()

    func captureAnimationFrame(documentID: String,
                               request: CadAnimationCaptureRequest,
                               access: CadDocumentAccess) async throws -> CadAnimationCapture {
        animationCaptureRequests.append(request)
        let data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        return CadAnimationCapture(
            imageData: data, mimeType: "image/png",
            width: request.width, height: request.height,
            revision: revision, changeCount: 3,
            contentSHA256: sha, sha256: FloeDigest.sha256Hex(data),
            clipID: request.clipID ?? UUID(),
            timeSeconds: request.timeSeconds ?? 0,
            frameIndex: request.frame ?? 0,
            frameRate: request.fps,
            renderer: "presentation",
            note: "fake host actual-frame test",
            taskID: animationCaptureTask)
    }

    func exportAnimation(documentID: String, relativeOutput: String,
                         options: CadAnimationExportOptions,
                         access: CadDocumentAccess) async throws -> CadAnimationExportReceipt {
        animationExportRequests.append((relativeOutput, options))
        return CadAnimationExportReceipt(
            relativePath: relativeOutput,
            width: options.width, height: options.height,
            frameRate: Double(options.frameRate),
            durationSeconds: 5, frameCount: options.frameRate * 5,
            codec: options.codec, hasAudio: false,
            byteCount: 4096, sha256: String(repeating: "e", count: 64),
            posterPNG: Data([1, 2, 3]), taskID: animationExportTask,
            note: "fake host verified MP4")
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

    @Test("schema enum matches every runtime action and advertises native arguments")
    func schemaMatchesRuntimeActions() throws {
        let data = Data(CadDocumentTool.parametersJSON.utf8)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let properties = try #require(object["properties"] as? [String: Any])
        let action = try #require(properties["action"] as? [String: Any])
        let enumValues = Set(try #require(action["enum"] as? [String]))
        let runtime = Set(CadDocumentAction.allCases.map(\.rawValue))
        #expect(enumValues == runtime,
                "the JSON schema enum must equal the runtime CadDocumentAction cases")
        #expect(object["additionalProperties"] as? Bool == false)
        for field in ["op", "args", "payload", "task_id", "output", "kind"] {
            #expect(properties[field] != nil, "schema must declare \(field)")
        }
        let kind = try #require(properties["kind"] as? [String: Any])
        let kindDescription = try #require(kind["description"] as? String)
        for scope in CadDocumentTool.nativeQueryScopes {
            #expect(kindDescription.contains(scope), "native query scope \(scope) must be advertised")
        }
        for measure in CadDocumentTool.nativeMeasureKinds {
            #expect(kindDescription.contains(measure), "native measure kind \(measure) must be advertised")
        }
        // The tool description names the native surface too.
        #expect(CadDocumentTool.toolDescription.contains("floecad"))
    }

    @Test("a .floecad path routes to the native host and never the 2D loader")
    func nativeRepresentationRouting() async throws {
        let host = FakeCadHost()
        await host.setThreeDReply(#"{"ok":true,"summary":{"revision":1}}"#)
        let tool = CadDocumentTool(host: host)

        _ = try await execute(tool, #"{"action":"read","path":"parts/plate.floecad"}"#)
        let readRequests = await host.threeDRequests
        #expect(readRequests.count == 1)
        #expect(readRequests.first?.contains("\"kind\":\"snapshot\"") == true)
        #expect(await host.snapshotCalls == 0,
                "the 2D snapshot loader must not see a .floecad path")

        _ = try await execute(tool, #"{"action":"capabilities","path":"parts/plate.floecad"}"#)
        let capabilityRequests = await host.threeDRequests
        #expect(capabilityRequests.last?.contains("capabilities") == true)
        #expect(await host.snapshotCalls == 0)

        _ = try await execute(tool, #"{"action":"query","path":"parts/plate.floecad","kind":"bodies"}"#)
        let queryRequests = await host.threeDRequests
        #expect(queryRequests.last?.contains("\"scope\":\"bodies\"") == true)
        #expect(await host.queryRequests.isEmpty, "the 2D engine query must not run")

        // A 2D drawing still uses the 2D host.
        _ = try await execute(tool, #"{"action":"read","path":"plans/plate.dwg"}"#)
        #expect(await host.snapshotCalls == 1)
    }

    @Test("native validate enforces typed operations, scopes and task ids")
    func nativeValidation() throws {
        let tool = CadDocumentTool(host: FakeCadHost())
        // Native propose needs an op.
        #expect(throws: FloeError.self) {
            try tool.validate(try decode(#"{"action":"propose","path":"p.floecad"}"#))
        }
        // A complete operation envelope accidentally placed inside args must
        // not become an implicit top-level operation (seen in the live run).
        #expect(throws: FloeError.self) {
            try tool.validate(try decode(
                #"{"action":"propose","path":"p.floecad","args":"{\"op\":\"feature.extrude\",\"args\":{\"sketchID\":\"x\"}}"}"#))
        }
        try tool.validate(try decode(
            #"{"action":"propose","path":"p.floecad","op":"feature.extrude","args":"{\"sketchID\":\"x\"}"}"#))
        // Native query scopes are enumerated.
        #expect(throws: FloeError.self) {
            try tool.validate(try decode(#"{"action":"query","path":"p.floecad","kind":"entities"}"#))
        }
        try tool.validate(try decode(#"{"action":"query","path":"p.floecad","kind":"assembly"}"#))
        // Native measure kinds are enumerated and arity-checked.
        #expect(throws: FloeError.self) {
            try tool.validate(try decode(#"{"action":"measure","path":"p.floecad","kind":"radius"}"#))
        }
        try tool.validate(try decode(#"{"action":"measure","path":"p.floecad","kind":"dof"}"#))
        #expect(throws: FloeError.self) {
            try tool.validate(try decode(#"{"action":"measure","path":"p.floecad","kind":"distance","points":[[0,0,0]]}"#))
        }
        // status needs no id; cancel does.
        try tool.validate(try decode(#"{"action":"status","path":"p.floecad"}"#))
        #expect(throws: FloeError.self) {
            try tool.validate(try decode(#"{"action":"cancel","path":"p.floecad"}"#))
        }
        try tool.validate(try decode(#"{"action":"cancel","path":"p.floecad","task_id":"t-1"}"#))
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
        // A preview no longer ends the model turn (ordinary authorized edits
        // apply without a per-edit human pause), but it still writes nothing
        // and the proposal stays pending until a grant/runtime authority
        // authorizes the apply.
        #expect(output.requiresUserAction == false)
        #expect(output.summary.contains("+1 ~0 -0"))
        #expect(output.summary.contains("User confirmation is required"))
        #expect(output.summary.contains("pending proposal alone changes nothing"))
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

    @Test("native measure translates body handles into the kernel's raw bodyID/bodyIDs")
    func nativeMeasureHandleTranslation() async throws {
        let host = FakeCadHost()
        let tool = CadDocumentTool(host: host)
        let bodyID = UUID()
        let otherID = UUID()

        func lastPayload() async throws -> [String: Any] {
            let requests = await host.threeDRequests
            let raw = try #require(requests.last)
            let object = try #require(try JSONSerialization.jsonObject(
                with: Data(raw.utf8)) as? [String: Any])
            #expect(object["kind"] as? String == "measure")
            return try #require(object["payload"] as? [String: Any])
        }

        _ = try await execute(tool, #"""
        {"action":"measure","path":"p.floecad","op":"body","handles":["body:\#(bodyID.uuidString)"]}
        """#)
        let bodyPayload = try await lastPayload()
        #expect(bodyPayload["kind"] as? String == "body")
        #expect(bodyPayload["bodyID"] as? String == bodyID.uuidString,
                "the kernel measures one body by its raw UUID, not by the handle string")

        // A bare UUID (copied from a query row) is accepted as well.
        _ = try await execute(tool, #"""
        {"action":"measure","path":"p.floecad","op":"mesh","handles":["\#(otherID.uuidString)"]}
        """#)
        let meshPayload = try await lastPayload()
        #expect(meshPayload["bodyID"] as? String == otherID.uuidString)

        // Bounds maps every body handle.
        _ = try await execute(tool, #"""
        {"action":"measure","path":"p.floecad","op":"bounds","handles":["body:\#(bodyID.uuidString)","body:\#(otherID.uuidString)"]}
        """#)
        let boundsPayload = try await lastPayload()
        #expect(boundsPayload["bodyIDs"] as? [String] == [bodyID.uuidString, otherID.uuidString])

        // A foreign handle is refused here; an unresolvable id must never reach
        // the host or the kernel.
        let requestCount = await host.threeDRequests.count
        await #expect(throws: FloeError.self) {
            _ = try await execute(tool, #"""
            {"action":"measure","path":"p.floecad","op":"body","handles":["face:\#(bodyID.uuidString):1"]}
            """#)
        }
        #expect(await host.threeDRequests.count == requestCount,
                "a refused handle must not issue a native request")
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
        // S3-D compatibility: the synthetic host export is asserted through
        // the supported legacy direct binding (no tool-call and no task),
        // keeping the pre-publication summary identical. Bound-run publication
        // with a real committed file is covered by RunOutputPublication
        // ProducerTests in this suite.
        let export = try await execute(tool, #"{"action":"export","path":"plans/plate.dwg"}"#,
                                       context: ToolContext(runID: UUID(), scope: .local,
                                                            workspaceRootURL: URL(fileURLWithPath: "/tmp/workspace"),
                                                            cancellation: CancellationToken(),
                                                            environmentID: "env-1"))
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

    // MARK: - R2 native create / import / capability discovery

    @Test("create action validates a .floecad target and delegates to the host factory")
    func createActionRoutesToHostFactory() async throws {
        let host = FakeCadHost()
        let tool = CadDocumentTool(host: host)
        let output = try await execute(
            tool, #"{"action":"create","path":"parts/Bracket.floecad","name":"Bracket"}"#)
        #expect(output.summary.contains("cad.document created"))
        #expect(output.summary.contains("parts/Bracket.floecad"))
        let created = await host.createdPackages
        #expect(created == ["parts/Bracket.floecad"])
    }

    @Test("create refuses a DWG/DXF target: the tool never builds drawings")
    func createRefusesTwoDTarget() throws {
        let tool = CadDocumentTool(host: FakeCadHost())
        #expect(throws: FloeError.self) {
            try tool.validate(try decode(#"{"action":"create","path":"plate.dwg"}"#))
        }
    }

    @Test("create requires an explicit path (no implicit package location)")
    func createRequiresPath() throws {
        let tool = CadDocumentTool(host: FakeCadHost())
        #expect(throws: FloeError.self) {
            try tool.validate(try decode(#"{"action":"create"}"#))
        }
    }

    @Test("create rejects path traversal/control characters in the target")
    func createRejectsUnsafeNames() throws {
        let tool = CadDocumentTool(host: FakeCadHost())
        // The tool only validates the `.floecad` shape; the shared host
        // factory is the authority that resolves the path and rejects
        // traversal/outside-root targets (covered by the App-level factory
        // test). Here the tool-level contract is the NUL-byte refusal:
        // `validate` must reject a path containing a control character
        // BEFORE any host call. (JSON cannot encode a NUL byte, so the
        // arguments are built programmatically.)
        var args = try decode(#"{"action":"create","path":"x.floecad"}"#)
        args.path = "a\u{0000}.floecad"
        #expect(throws: FloeError.self) {
            try tool.validate(args)
        }
    }

    @Test("import requires an existing .floecad target and a workspace source_path")
    func importValidation() throws {
        let tool = CadDocumentTool(host: FakeCadHost())
        // DWG target is not an import destination.
        #expect(throws: FloeError.self) {
            try tool.validate(try decode(
                #"{"action":"import","path":"plate.dwg","source_path":"a.step"}"#))
        }
        // Missing source.
        #expect(throws: FloeError.self) {
            try tool.validate(try decode(#"{"action":"import","path":"part.floecad"}"#))
        }
        // Unsupported extension.
        #expect(throws: FloeError.self) {
            try tool.validate(try decode(
                #"{"action":"import","path":"part.floecad","source_path":"model.3mf"}"#))
        }
        // An explicit format that is not a supported exchange is refused.
        #expect(throws: FloeError.self) {
            try tool.validate(try decode(
                #"{"action":"import","path":"part.floecad","source_path":"a.step","format":"dwg"}"#))
        }
        // A mismatched explicit format against the extension is refused.
        #expect(throws: FloeError.self) {
            try tool.validate(try decode(
                #"{"action":"import","path":"part.floecad","source_path":"a.step","format":"stl"}"#))
        }
        // Non-positive scale.
        #expect(throws: FloeError.self) {
            try tool.validate(try decode(
                #"{"action":"import","path":"part.floecad","source_path":"a.stl","unit_scale":0}"#))
        }
        // Accepted combinations.
        for json in [
            #"{"action":"import","path":"part.floecad","source_path":"a.step"}"#,
            #"{"action":"import","path":"part.floecad","source_path":"a.IGS"}"#,
            #"{"action":"import","path":"part.floecad","source_path":"mesh.gltf","format":"gltf"}"#,
            #"{"action":"import","path":"part.floecad","source_path":"m.stl","unit_scale":2.5}"#,
        ] {
            try tool.validate(try decode(json))
        }
    }

    @Test("import action drafts a proposal, requires confirmation and never writes directly")
    func importActionDraftsProposal() async throws {
        let host = FakeCadHost()
        await host.setThreeDReply(#"{"ok":true,"proposal":{"id":"00000000-0000-0000-0000-000000000000"}}"#)
        let tool = CadDocumentTool(host: host)
        let output = try await execute(tool, #"""
        {"action":"import","path":"part.floecad","source_path":"vendor/bracket.step","format":"step"}
        """#)
        // The import is a proposal too: no forced human pause, no write.
        #expect(output.requiresUserAction == false)
        #expect(output.summary.contains("cad.document import proposal"))
        let requests = await host.threeDRequests
        #expect(requests.count == 1)
        let envelope = try JSONSerialization.jsonObject(with: Data(requests[0].utf8)) as? [String: Any]
        #expect(envelope?["kind"] as? String == "import")
        let payload = try #require(envelope?["payload"] as? [String: Any])
        #expect(payload["path"] as? String == "vendor/bracket.step")
        #expect(payload["format"] as? String == "step")
    }

    @Test("capabilities without a path report both 2D and native engines separately")
    func capabilitiesReportBothEngines() async throws {
        let host = FakeCadHost()
        await host.setThreeDReply(#"{"unused":true}"#)
        let tool = CadDocumentTool(host: host)
        let output = try await execute(tool, #"{"action":"capabilities"}"#)
        #expect(output.summary.contains("two_dimensional"))
        #expect(output.summary.contains("native_three_dimensional"))
        // The native matrix lists create and per-format import/view/edit/export.
        #expect(output.summary.contains("\"available\":true"))
        #expect(await host.threeDRequests.isEmpty, "no-document capabilities must not open a document")
    }

    @Test("a host without the native kernel reports the native engine honestly")
    func capabilitiesHonestMissingKernel() async throws {
        struct KernellessHost: CadDocumentHost {
            func authorizeAccess(access: CadDocumentAccess) async throws {}
            func capabilities(access: CadDocumentAccess) async throws -> String {
                #"{"version":2}"#
            }
            func snapshot(documentID: String, access: CadDocumentAccess) async throws -> CadDocumentSnapshot {
                throw FloeError.notFound("x")
            }
            func query(documentID: String, requestJSON: String, access: CadDocumentAccess) async throws -> String { "" }
            func prepareProposal(documentID: String, snapshot: CadDocumentSnapshot, summary: String,
                                 operationsJSON: String, access: CadDocumentAccess) async throws -> CadProposal {
                throw FloeError.notFound("x")
            }
            func storeProposal(_ proposal: CadProposal) async throws {}
            func loadProposal(id: UUID, access: CadDocumentAccess) async throws -> CadProposal? { nil }
            func loadProposalOutcome(id: UUID, access: CadDocumentAccess) async throws -> CadProposalOutcome? { nil }
            func verifyProposalBinding(_ proposal: CadProposal, documentID: String,
                                       access: CadDocumentAccess) async throws {}
            func removeProposal(id: UUID) async throws {}
            func consumeGrant(grantID: String, proposalID: UUID, documentID: String,
                              revision: Int64, sha256: String) async -> CadGrantDecision { .unknownGrant }
            func apply(proposal: CadProposal, grantID: String, requestID: String,
                       access: CadDocumentAccess) async throws -> CadDocumentReceipt {
                throw FloeError.notFound("x")
            }
            func save(documentID: String, expectedSHA256: String, requestID: String,
                      access: CadDocumentAccess) async throws -> CadDocumentReceipt {
                throw FloeError.notFound("x")
            }
            func export(documentID: String, relativeOutput: String,
                        access: CadDocumentAccess) async throws -> CadExportReceipt {
                throw FloeError.notFound("x")
            }
        }
        let tool = CadDocumentTool(host: KernellessHost())
        let output = try await execute(tool, #"{"action":"capabilities"}"#)
        #expect(output.summary.contains("\"available\":false"))
        #expect(output.summary.contains("two_dimensional"))
    }

    @Test("schema enum advertises create and import and their fields")
    func schemaAdvertisesCreateImport() throws {
        let schema = CadDocumentTool.parametersJSON
        #expect(schema.contains("\"create\""))
        #expect(schema.contains("\"import\""))
        #expect(schema.contains("source_path"))
        #expect(schema.contains("unit_scale"))
        #expect(schema.contains("\"name\""))
        let object = try JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any]
        let properties = try #require(object?["properties"] as? [String: Any])
        let action = try #require(properties["action"] as? [String: Any])
        let enumValues = Set(try #require(action["enum"] as? [String]))
        #expect(enumValues.contains("create"))
        #expect(enumValues.contains("import"))
        let runtime = Set(CadDocumentAction.allCases.map(\.rawValue))
        #expect(enumValues == runtime)
    }
}

// MARK: - Runtime-approved automatic apply

/// The automatic path must derive EXACTLY the values the runtime minted:
/// canonical target, base revision and payload digest. These tests compare the
/// consumer derivation against `RuntimeAuthorityDigest` +
/// `MutationTargetResolver` (the runtime's own mint helpers) rather than
/// against a hand-written expectation, so a format drift between the two
/// sides fails here.
@Suite("cad.document runtime-approved automatic apply")
struct CadAutomaticApplyTests {
    func makeContext(conversation: UUID? = UUID(), runID: UUID = UUID(),
                     toolCallID: String = "call-apply-1",
                     workspace: URL = URL(fileURLWithPath: "/tmp/workspace")) -> ToolContext {
        ToolContext(runID: runID, toolCallID: toolCallID, scope: .local,
                    workspaceRootURL: workspace,
                    cancellation: CancellationToken(), environmentID: "env-1",
                    conversationID: conversation)
    }

    func decode(_ json: String) throws -> CadDocumentArguments {
        try JSONDecoder().decode(CadDocumentArguments.self, from: Data(json.utf8))
    }

    /// Mint a token exactly the way the runtime does: the evidence IS the
    /// binding the consumer derives from the approved call.
    @discardableResult
    func issueAuthority(for args: CadDocumentArguments, context: ToolContext,
                        ttl: TimeInterval = 300) async throws -> RuntimeTaskAuthority {
        let binding = try CadDocumentTool.runtimeAuthorityBinding(for: args, context: context)
        return await RuntimeAuthorityStore.shared.issue(
            RuntimeAuthorityEvidence(
                runID: binding.runID,
                taskID: binding.taskID,
                environmentBinding: binding.environmentBinding,
                canonicalTarget: binding.canonicalTarget,
                toolName: binding.toolName,
                operation: binding.operation,
                operationID: binding.operationID,
                idempotencyKey: binding.idempotencyKey,
                baseRevision: binding.baseRevision,
                payloadDigest: binding.payloadDigest,
                approvalGrantID: UUID()),
            ttl: ttl)
    }

    func carrying(_ base: ToolContext, _ token: RuntimeTaskAuthority) -> ToolContext {
        var context = base
        context.runtimeAuthority = token
        return context
    }

    /// validate + execute, exactly like the module's other tests.
    func run(_ tool: CadDocumentTool, _ json: String,
             context: ToolContext) async throws -> ToolExecutionOutput {
        let args = try decode(json)
        try tool.validate(args)
        return try await tool.execute(args, context: context)
    }

    @Test("canonical target and payload digest re-derive the runtime's own values")
    func bindingParityWithRuntimeDerivation() throws {
        ToolCatalog.register(CadDocumentTool.self)
        let descriptor = try #require(ToolCatalog.descriptor(named: CadDocumentTool.name))
        let root = URL(fileURLWithPath: "/tmp/workspace")
        let arguments = [
            #"{"action":"apply","path":"parts/plate.dwg","proposal_id":"E621E1F8-1234-4ABC-8DEF-000000000001"}"#,
            // The id exactly as a model echoes it (any case is part of the
            // approved payload; the consumer must not normalize it).
            #"{"action":"apply","path":"parts/plate.dwg","proposal_id":"e621e1f8-1234-4abc-8def-000000000001"}"#,
            #"{"action":"apply","path":"parts/plate.floecad","proposal_id":"E621E1F8-1234-4ABC-8DEF-000000000001","revision":3,"request_id":"r-1"}"#,
            #"{"action":"apply","path":"plate.dwg","proposal_id":"E621E1F8-1234-4ABC-8DEF-000000000001","grant_id":"ui-grant"}"#,
        ]
        for raw in arguments {
            let args = try decode(raw)
            let payload = try CadDocumentTool.canonicalApprovedPayload(args)
            // The runtime hashes the RAW approved arguments; the consumer
            // re-encodes the decoded arguments. Both canonicalize identically.
            #expect(RuntimeAuthorityDigest.payloadDigest(Data(raw.utf8))
                        == RuntimeAuthorityDigest.payloadDigest(payload),
                    "payload digest drift for \(raw)")
            let call = try ToolCall(id: "call-1", toolName: CadDocumentTool.name,
                                    argumentsJSON: Data(raw.utf8), scope: .local)
            #expect(CadDocumentTool.canonicalTarget(for: args, workspaceRoot: root)
                        == RuntimeAuthorityDigest.canonicalTarget(for: call, descriptor: descriptor,
                                                                  workspaceRootURL: root),
                    "canonical target drift for \(raw)")
            // A revision pin is part of both the digest and the base-revision
            // binding the runtime parses.
            let runtimeRevision = RuntimeAuthorityDigest.baseRevision(in: Data(raw.utf8))
            let consumerRevision = RuntimeAuthorityDigest.baseRevision(in: payload)
            #expect(runtimeRevision == consumerRevision,
                    "base revision drift for \(raw): \(runtimeRevision ?? "nil") vs \(consumerRevision ?? "nil")")
        }
    }

    @Test("a null placeholder or an unknown extra field refuses instead of widening authority")
    func nonCanonicalArgumentsRefuse() throws {
        let canonical = try decode(#"{"action":"apply","path":"plate.dwg","proposal_id":"E621E1F8-1234-4ABC-8DEF-000000000001"}"#)
        let canonicalDigest = RuntimeAuthorityDigest.payloadDigest(
            try CadDocumentTool.canonicalApprovedPayload(canonical))
        for raw in [
            #"{"action":"apply","path":"plate.dwg","proposal_id":"E621E1F8-1234-4ABC-8DEF-000000000001","grant_id":null}"#,
            #"{"action":"apply","path":"plate.dwg","proposal_id":"E621E1F8-1234-4ABC-8DEF-000000000001","unknown_field":1}"#,
        ] {
            let rawDigest = RuntimeAuthorityDigest.payloadDigest(Data(raw.utf8))
            let decoded = try decode(raw)
            let consumerDigest = RuntimeAuthorityDigest.payloadDigest(
                try CadDocumentTool.canonicalApprovedPayload(decoded))
            // `null` decodes to nil and is therefore OMITTED by the consumer
            // while the runtime hashed the null: the digests differ and the
            // automatic path refuses (fail closed, documented in the error).
            #expect(rawDigest != canonicalDigest)
            #expect(consumerDigest == canonicalDigest)
        }
    }

    @Test("a 2D apply without a grant runs on the runtime authority exactly once")
    func twoDimensionalAutomaticApply() async throws {
        let host = FakeCadHost()
        let tool = CadDocumentTool(host: host)
        let context = makeContext()
        _ = try await run(tool, #"""
        {"action":"propose","path":"plate.dwg","operations":[{"operation":"delete","handle":"AB"}]}
        """#, context: context)
        let proposal = try #require(await host.storedProposal)
        let applyJSON = """
        {"action":"apply","path":"plate.dwg","proposal_id":"\(proposal.id.uuidString)"}
        """
        let args = try decode(applyJSON)

        // Without any authority the call refuses before touching the host.
        do {
            _ = try await tool.execute(args, context: context)
            Issue.record("an apply without a UI grant and without runtime authority must refuse")
        } catch let error as FloeError {
            if case .validationFailed(let message) = error {
                #expect(message.contains("runtime-approved call authority"))
            } else {
                Issue.record("unexpected refusal: \(error)")
            }
        }
        #expect(await host.automaticApplies == 0)

        // A REAL runtime-issued token for this exact call authorizes it.
        let token = try await issueAuthority(for: args, context: context)
        let output = try await tool.execute(args, context: carrying(context, token))
        #expect(output.summary.contains("\"saved\":true"))
        #expect(await host.automaticApplies == 1)
        let authorization = try #require(await host.lastAutomaticAuthorization)
        #expect(authorization.binding.toolName == CadDocumentTool.name)
        #expect(authorization.binding.operation == "apply")
        #expect(authorization.operationID == context.toolCallID)
        #expect(authorization.runID == context.runID)
        #expect(authorization.taskID == context.conversationID)

        // A completed identical request returns the saved receipt without
        // consuming authority or applying the drawing again.
        let replay = try await tool.execute(args, context: carrying(context, token))
        func receipt(_ output: ToolExecutionOutput) throws -> CadDocumentReceipt {
            let prefix = "cad.document apply: "
            #expect(output.summary.hasPrefix(prefix))
            return try JSONDecoder().decode(CadDocumentReceipt.self,
                from: Data(output.summary.dropFirst(prefix.count).utf8))
        }
        var expectedReplay = try receipt(output)
        #expect(!expectedReplay.replay)
        expectedReplay.replay = true
        #expect(try receipt(replay) == expectedReplay)
        #expect(await host.automaticApplies == 1)

        // Receipt replay never makes the consumed authority reusable.
        do {
            _ = try await CadDocumentTool.consumeAutomaticAuthorization(
                args: args, context: carrying(context, token))
            Issue.record("a consumed authority must not authorize a second apply")
        } catch let error as FloeError {
            if case .validationFailed(let message) = error {
                #expect(message.contains("already consumed"))
            } else {
                Issue.record("unexpected consumed-authority refusal: \(error)")
            }
        }

        let newRequest = try decode("""
        {"action":"apply","path":"plate.dwg","proposal_id":"\(proposal.id.uuidString)","request_id":"another-request"}
        """)
        await expectAutomaticRefusal(tool: tool, args: newRequest,
                                     context: carrying(context, token), host: host,
                                     contains: "different request")
        #expect(await host.automaticApplies == 1)
    }

    @Test("forged, foreign-target and foreign-payload tokens are refused")
    func forgedAndMismatchedAuthoritiesRefuse() async throws {
        let host = FakeCadHost()
        let tool = CadDocumentTool(host: host)
        let context = makeContext()
        _ = try await run(tool, #"""
        {"action":"propose","path":"plate.dwg","operations":[{"operation":"delete","handle":"AB"}]}
        """#, context: context)
        let proposal = try #require(await host.storedProposal)
        let applyJSON = """
        {"action":"apply","path":"plate.dwg","proposal_id":"\(proposal.id.uuidString)"}
        """
        let args = try decode(applyJSON)
        let genuine = try CadDocumentTool.runtimeAuthorityBinding(for: args, context: context)

        // A struct-shaped twin that was never issued is not authority.
        let forged = RuntimeTaskAuthority(
            id: UUID(), runID: genuine.runID, taskID: genuine.taskID,
            environmentBinding: genuine.environmentBinding,
            canonicalTarget: genuine.canonicalTarget, toolName: genuine.toolName,
            operation: genuine.operation, operationID: genuine.operationID,
            idempotencyKey: genuine.idempotencyKey, baseRevision: genuine.baseRevision,
            payloadDigest: genuine.payloadDigest, approvalGrantID: UUID(),
            issuedAt: Date(), expiresAt: Date().addingTimeInterval(300))
        await expectAutomaticRefusal(tool: tool, args: args,
                                     context: carrying(context, forged),
                                     host: host, contains: "not issued")

        // A token issued for ANOTHER target cannot authorize this document.
        let otherArgs = try decode("""
        {"action":"apply","path":"other/frame.dwg","proposal_id":"\(proposal.id.uuidString)"}
        """)
        let otherContext = makeContext(conversation: context.conversationID, runID: context.runID)
        let otherToken = try await issueAuthority(for: otherArgs, context: otherContext)
        await expectAutomaticRefusal(tool: tool, args: args,
                                     context: carrying(context, otherToken),
                                     host: host, contains: "different canonical target")

        // A token issued for ANOTHER approved call (different proposal id)
        // cannot authorize this proposal.
        let otherProposal = UUID()
        let otherPayloadArgs = try decode("""
        {"action":"apply","path":"plate.dwg","proposal_id":"\(otherProposal.uuidString)"}
        """)
        let payloadToken = try await issueAuthority(for: otherPayloadArgs, context: context)
        await expectAutomaticRefusal(tool: tool, args: args,
                                     context: carrying(context, payloadToken),
                                     host: host, contains: "approved payload")

        // A token minted for another task is the same refusal.
        let foreignContext = makeContext(conversation: UUID(), runID: context.runID)
        let foreignToken = try await issueAuthority(for: args, context: foreignContext)
        await expectAutomaticRefusal(tool: tool, args: args,
                                     context: carrying(context, foreignToken),
                                     host: host, contains: "different task")
        #expect(await host.automaticApplies == 0)
    }

    func expectAutomaticRefusal(tool: CadDocumentTool, args: CadDocumentArguments,
                                context: ToolContext, host: FakeCadHost,
                                contains fragment: String) async {
        do {
            _ = try await tool.execute(args, context: context)
            Issue.record("expected refusal containing '\(fragment)'")
        } catch let error as FloeError {
            guard case .validationFailed(let message) = error else {
                Issue.record("unexpected refusal: \(error)")
                return
            }
            #expect(message.contains(fragment), "refusal should mention '\(fragment)': \(message)")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("a .floecad apply without a grant runs through the host's automatic path")
    func nativeAutomaticApply() async throws {
        let host = FakeCadHost()
        let tool = CadDocumentTool(host: host)
        let context = makeContext()
        await host.setThreeDReply(#"{"ok":true}"#)
        // Propose on the native representation records the proposal through
        // the bridge request surface.
        _ = try await run(tool, #"""
        {"action":"propose","path":"part.floecad","op":"feature.extrude","args":"{\"sketchID\":\"x\",\"seedPoint\":[1,1],\"distance\":5}"}
        """#, context: context)

        let proposalID = UUID()
        let applyJSON = """
        {"action":"apply","path":"part.floecad","proposal_id":"\(proposalID.uuidString)"}
        """
        let args = try decode(applyJSON)
        // Missing authority refuses before the host (no grant exists at all).
        do {
            _ = try await tool.execute(args, context: context)
            Issue.record("a native apply without a grant or authority must refuse")
        } catch let error as FloeError {
            guard case .validationFailed = error else {
                Issue.record("unexpected refusal: \(error)")
                return
            }
        }
        #expect(await host.nativeAutomaticApplies == 0)

        let token = try await issueAuthority(for: args, context: context)
        let output = try await tool.execute(args, context: carrying(context, token))
        #expect(output.summary.contains("runtime-authority"), "the native apply reply must show the automatic mode")
        #expect(await host.nativeAutomaticApplies == 1)
        // The automatic apply must not fall back to a grant request.
        #expect(await host.threeDRequests.count == 1)
    }
}

// MARK: - Workbench service request contract (drawing / assembly discovery)

@Suite("cad.document workbench service request contract")
struct CadDocumentServiceRequestTests {
    func makeContext(conversation: UUID? = UUID()) -> ToolContext {
        ToolContext(runID: UUID(), toolCallID: "call-service-1", scope: .local,
                    workspaceRootURL: URL(fileURLWithPath: "/tmp/workspace"),
                    cancellation: CancellationToken(), environmentID: "env-1",
                    conversationID: conversation)
    }

    func decode(_ json: String) throws -> CadDocumentArguments {
        try JSONDecoder().decode(CadDocumentArguments.self, from: Data(json.utf8))
    }

    func requestJSON(_ raw: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(raw.utf8))
        return try #require(object as? [String: Any])
    }

    /// The JSON object inside a tool output summary (the tool prefixes a label).
    func payloadObject(_ output: ToolExecutionOutput) throws -> [String: Any] {
        let json = output.summary.drop { $0 != "{" }
        return try requestJSON(String(json))
    }

    /// validate + execute, exactly like the module's other tests.
    func run(_ tool: CadDocumentTool, _ json: String,
             context: ToolContext) async throws -> ToolExecutionOutput {
        let args = try decode(json)
        try tool.validate(args)
        return try await tool.execute(args, context: context)
    }

    func execute(_ tool: CadDocumentTool, _ json: String) async throws -> ToolExecutionOutput {
        try await run(tool, json, context: makeContext())
    }

    @Test("a service alias without a recognizable action is refused, never defaulted to a read")
    func missingAndUnknownActionsAreRefused() throws {
        let tool = CadDocumentTool(host: FakeCadHost())
        // The exact reported failure shape: a payload that names no action.
        do {
            try tool.validate(try decode(#"{"action":"three_d_drawing","path":"p.floecad"}"#))
            Issue.record("an action-less service payload must be refused")
        } catch let error as FloeError {
            guard case .validationFailed(let message) = error else {
                Issue.record("unexpected refusal: \(error)")
                return
            }
            #expect(message.contains("missing_action"))
            #expect(message.contains("addPage"))
            #expect(message.contains("standardSheet"))
            #expect(message.contains("capabilities"))
        }
        // The model's guessed op must be refused with the real action named.
        do {
            try tool.validate(try decode(
                #"{"action":"three_d_drawing","path":"p.floecad","payload":"{\"op\":\"drawing.createPage\"}"}"#))
            Issue.record("an unknown op must be refused")
        } catch let error as FloeError {
            guard case .validationFailed(let message) = error else {
                Issue.record("unexpected refusal: \(error)")
                return
            }
            #expect(message.contains("unknown_op"))
            #expect(message.contains("Did you mean 'addPage'?"))
        }
        // A malformed payload is refused too.
        #expect(throws: FloeError.self) {
            try tool.validate(try decode(
                #"{"action":"three_d_assembly","path":"p.floecad","payload":"[]"}"#))
        }
        // The aliases remain native-only.
        #expect(throws: FloeError.self) {
            try tool.validate(try decode(
                #"{"action":"three_d_drawing","path":"plate.dwg","payload":"{\"action\":\"pages\"}"}"#))
        }
        // Valid forms validate: canonical action, legacy prefixed op, and the
        // propose-shaped args envelope.
        try tool.validate(try decode(
            #"{"action":"three_d_drawing","path":"p.floecad","payload":"{\"action\":\"pages\"}"}"#))
        try tool.validate(try decode(
            #"{"action":"three_d_assembly","path":"p.floecad","payload":"{\"op\":\"assembly.report\"}"}"#))
        try tool.validate(try decode(
            #"{"action":"three_d_drawing","path":"p.floecad","payload":"{\"op\":\"drawing.addPage\",\"args\":{\"kind\":\"front\",\"bodyIDs\":[\"8A9B3C6F-2B1D-4A44-9C29-3B0A8F1E5D77\"]}}"}"#))
    }

    @Test("the tool forwards the canonical action and flattened arguments")
    func serviceRequestsAreNormalized() async throws {
        let host = FakeCadHost()
        await host.setThreeDReply(#"{"ok":true,"count":0,"pages":[]}"#)
        let tool = CadDocumentTool(host: host)
        let context = makeContext()
        // Mutating legacy op: the host receives the canonical action (and, on
        // the real host, answers proposal_required with the exact propose op).
        _ = try await run(tool, #"""
        {"action":"three_d_drawing","path":"part.floecad","payload":"{\"op\":\"drawing.addPage\",\"kind\":\"front\",\"bodyIDs\":[\"8A9B3C6F-2B1D-4A44-9C29-3B0A8F1E5D77\"]}"}
        """#, context: context)
        var requests = await host.threeDRequests
        var request = try requestJSON(try #require(requests.last))
        #expect(request["kind"] as? String == "drawing")
        var payload = try #require(request["payload"] as? [String: Any])
        #expect(payload["action"] as? String == "addPage")
        #expect(payload["kind"] as? String == "front")
        #expect((payload["bodyIDs"] as? [String])?.count == 1)
        #expect(payload["op"] == nil, "the legacy selector must not reach the engine")

        // Read-only nested-args form: same normalization, args flattened.
        _ = try await run(tool, #"""
        {"action":"three_d_assembly","path":"part.floecad","payload":"{\"op\":\"assembly.interference\",\"args\":{\"toleranceMM\":0.01}}"}
        """#, context: context)
        requests = await host.threeDRequests
        request = try requestJSON(try #require(requests.last))
        payload = try #require(request["payload"] as? [String: Any])
        #expect(request["kind"] as? String == "assembly")
        #expect(payload["action"] as? String == "interference")
        #expect((payload["toleranceMM"] as? NSNumber)?.doubleValue == 0.01)
    }

    @Test("capabilities serves the authoritative operation detail on demand")
    func capabilitiesCarryTheCatalog() async throws {
        let nativeHost = FakeCadHost()
        await nativeHost.setThreeDReply(#"{"ok":true,"available":true}"#)
        let nativeTool = CadDocumentTool(host: nativeHost)
        let output = try await execute(nativeTool,
            #"{"action":"capabilities","path":"part.floecad","kind":"drawing","offset":2,"limit":1}"#)
        #expect(output.summary.contains("service_operations"))
        // The reply must stay inside the runtime's 4 KiB model-visible cap so
        // the JSON is never silently truncated.
        #expect(output.summary.utf8.count <= 4096)
        let object = try payloadObject(output)
        let catalog = try #require(object["service_operations"] as? [String: Any])
        let detail = try #require(catalog["detail"] as? [String: Any])
        #expect(detail["kind"] as? String == "drawing")
        #expect(detail["total"] as? Int == 19)
        let operations = try #require(detail["operations"] as? [[String: Any]])
        let addPage = try #require(operations.first)
        #expect(addPage["action"] as? String == "addPage")
        #expect(addPage["mutating"] as? Bool == true)
        #expect((addPage["args"] as? [[String: Any]])?.isEmpty == false)
        #expect((addPage["examples"] as? [String])?.isEmpty == false)
        // The engine capabilities are fetched normally (the catalog is served
        // by the tool so the reply stays inside the budget).
        let requests = await nativeHost.threeDRequests
        let request = try requestJSON(try #require(requests.last))
        #expect(request["kind"] as? String == "capabilities")

        // A misspelled detail kind is a structured refusal, never a silent
        // engine reply (with or without a document).
        #expect(throws: FloeError.self) {
            try nativeTool.validate(try decode(
                #"{"action":"capabilities","path":"part.floecad","kind":"drawings"}"#))
        }
        #expect(throws: FloeError.self) {
            try nativeTool.validate(try decode(#"{"action":"capabilities","kind":"drawings"}"#))
        }
        // A native service kind on a 2D capabilities path is refused too.
        #expect(throws: FloeError.self) {
            try nativeTool.validate(try decode(
                #"{"action":"capabilities","path":"plate.dwg","kind":"drawing"}"#))
        }
        // Without a document the detail request is served the same way.
        let noPath = try await execute(CadDocumentTool(host: FakeCadHost()),
                                       #"{"action":"capabilities","kind":"assembly"}"#)
        #expect(noPath.summary.utf8.count <= 4096)
        let noPathObject = try payloadObject(noPath)
        let noPathDetail = try #require((noPathObject["service_operations"] as? [String: Any])?["detail"] as? [String: Any])
        #expect(noPathDetail["kind"] as? String == "assembly")

        // Discovery without a document carries the compact catalog under the
        // native surface when it fits.
        let discoveryHost = FakeCadHost()
        let discovery = try await execute(CadDocumentTool(host: discoveryHost),
                                          #"{"action":"capabilities"}"#)
        let discoveryObject = try payloadObject(discovery)
        let nativeCaps = try #require(discoveryObject["native_three_dimensional"] as? [String: Any])
        #expect((nativeCaps["service_operations"] as? [String: Any])?["kinds"] != nil)
    }

    @Test("a drawing export carries the page id; page_id is validated")
    func exportCarriesPageID() async throws {
        let host = FakeCadHost()
        await host.setThreeDReply(#"{"ok":true,"output":"drawing.pdf","format":"pdf"}"#)
        let tool = CadDocumentTool(host: host)
        let page = UUID().uuidString
        _ = try await execute(tool, """
        {"action":"export","path":"part.floecad","output":"drawing.pdf","page_id":"\(page)"}
        """)
        let requests = await host.threeDRequests
        let request = try requestJSON(try #require(requests.last))
        #expect(request["kind"] as? String == "export")
        let payload = try #require(request["payload"] as? [String: Any])
        #expect(payload["page_id"] as? String == page)
        #expect(payload["format"] as? String == "pdf")

        // A malformed id refuses; the 2D path has no drawing pages to address.
        #expect(throws: FloeError.self) {
            try tool.validate(try decode(
                #"{"action":"export","path":"part.floecad","output":"d.pdf","page_id":"not-a-uuid"}"#))
        }
        #expect(throws: FloeError.self) {
            try tool.validate(try decode(
                #"{"action":"export","path":"plate.dwg","output":"d.pdf","page_id":"\#(page)"}"#))
        }
    }
}

// MARK: - Material / parameter / capture actions

extension FakeCadHost {
    func captureViewport(documentID: String, width: Int, height: Int,
                         expectedRevision: Int64?,
                         access: CadDocumentAccess) async throws -> CadViewportCapture {
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )!
        return CadViewportCapture(
            pngData: png, width: width, height: height,
            revision: expectedRevision ?? revision, changeCount: 9,
            contentSHA256: String(repeating: "a", count: 64),
            sha256: String(repeating: "e", count: 64),
            renderer: "engineering", note: "actual test viewport")
    }
}

@Suite("cad.document material, parameter and capture actions")
struct CadNativeEditToolTests {
    func makeContext() -> ToolContext {
        ToolContext(runID: UUID(), toolCallID: "call-edit-1", scope: .local,
                    workspaceRootURL: URL(fileURLWithPath: "/tmp/workspace"),
                    cancellation: CancellationToken(), environmentID: "env-1",
                    conversationID: UUID())
    }

    func decode(_ json: String) throws -> CadDocumentArguments {
        try JSONDecoder().decode(CadDocumentArguments.self, from: Data(json.utf8))
    }

    func execute(_ tool: CadDocumentTool, _ json: String,
                 context: ToolContext) async throws -> ToolExecutionOutput {
        let args = try decode(json)
        try tool.validate(args)
        return try await tool.execute(args, context: context)
    }

    @Test("material create/apply requests reach the host as the material kind")
    func materialActionRoutes() async throws {
        let host = FakeCadHost()
        await host.setThreeDReply(#"{"ok":true,"mutated":true,"revision":5,"change_count":3}"#)
        let tool = CadDocumentTool(host: host)
        // The caller supplies the revision it read from the document; the
        // explicit top-level pin must reach the host unchanged.
        let output = try await execute(tool, """
        {"action":"material","path":"part.floecad","revision":4,"payload":
         "{\\"action\\":\\"create\\",\\"name\\":\\"Copper\\",\\"color\\":[0.8,0.4,0.2,1.0],\\"metallic\\":1.0}"}
        """, context: makeContext())
        #expect(output.summary.contains("cad.document material"))
        let requests = await host.threeDRequests
        let lastRequest = try #require(requests.last)
        let request = try #require((try JSONSerialization.jsonObject(
            with: Data(lastRequest.utf8))) as? [String: Any])
        #expect(request["kind"] as? String == "material")
        #expect(request["revision"] as? Int == 4,
                "the optional revision pin must be forwarded, not dropped")
        let payload = try #require(request["payload"] as? [String: Any])
        #expect(payload["action"] as? String == "create")
        #expect(payload["name"] as? String == "Copper")
    }

    @Test("an unknown material action is refused before the host")
    func materialUnknownActionRefused() throws {
        let tool = CadDocumentTool(host: FakeCadHost())
        let args = try decode("""
        {"action":"material","path":"part.floecad","payload":"{\\"action\\":\\"explode\\"}"}
        """)
        #expect(throws: FloeError.self) { try tool.validate(args) }
    }

    @Test("parameters update requires the typed feature/changes contract")
    func parametersActionRoutesAndValidates() async throws {
        let host = FakeCadHost()
        await host.setThreeDReply(#"{"ok":true,"mutated":true,"revision":6}"#)
        let tool = CadDocumentTool(host: host)
        let feature = UUID().uuidString
        _ = try await execute(tool, """
        {"action":"parameters","path":"part.floecad","payload":
         "{\\"action\\":\\"update\\",\\"feature_id\\":\\"\(feature)\\",\\"changes\\":{\\"distance\\":12.5}}"}
        """, context: makeContext())
        let requests = await host.threeDRequests
        let lastRequest = try #require(requests.last)
        let request = try #require((try JSONSerialization.jsonObject(
            with: Data(lastRequest.utf8))) as? [String: Any])
        #expect(request["kind"] as? String == "parameters")

        let missing = try decode("""
        {"action":"parameters","path":"part.floecad","payload":"{\\"action\\":\\"update\\"}"}
        """)
        #expect(throws: FloeError.self) { try tool.validate(missing) }
    }

    @Test("create refuses a run with no task workspace before touching the host factory")
    func createRequiresTaskWorkspace() async throws {
        let host = FakeCadHost()
        let tool = CadDocumentTool(host: host)
        let context = ToolContext(
            runID: UUID(), toolCallID: "call-no-root", scope: .local,
            workspaceRootURL: nil, cancellation: CancellationToken(),
            environmentID: "env-1", conversationID: UUID())
        let args = try decode(#"{"action":"create","path":"toycar.floecad"}"#)
        try tool.validate(args)
        do {
            _ = try await tool.execute(args, context: context)
            Issue.record("create without a task workspace must refuse")
        } catch let error as FloeError {
            #expect(error.reason.contains("task workspace"))
        }
        let created = await host.createdPackages
        #expect(created.isEmpty, "the host factory must not be reached without a task root")
    }

    @Test("new parameter actions validate and forward their typed payload")
    func newParameterActionsRouteAndValidate() async throws {
        let host = FakeCadHost()
        await host.setThreeDReply(#"{"ok":true,"mutated":true,"revision":7,"change_count":4}"#)
        let tool = CadDocumentTool(host: host)
        let sketch = UUID().uuidString
        let entity = UUID().uuidString
        let feature = UUID().uuidString
        let dimension = UUID().uuidString

        let cases: [(String, [String: Any])] = [
            ("updateSketchEntity", ["sketch_id": sketch, "entity_id": entity, "a": [0, 0], "b": [10, 0]]),
            ("setSketchDimension", ["sketch_id": sketch, "entity_id": entity, "kind": "length", "value": 20]),
            ("removeSketchDimension", ["sketch_id": sketch, "dimension_id": dimension]),
            ("feature.suppress", ["feature_id": feature, "suppressed": true]),
            ("feature.delete", ["feature_id": feature]),
            ("feature.move", ["feature_id": feature, "to_index": 1]),
        ]
        for (action, fields) in cases {
            var body = fields
            body["action"] = action
            let payloadJSON = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
            let json = String(decoding: try JSONSerialization.data(withJSONObject: [
                "action": "parameters", "path": "part.floecad", "payload": payloadJSON
            ]), as: UTF8.self)
            _ = try await execute(tool, json, context: makeContext())
            let requests = await host.threeDRequests
            let lastRequest = try #require(requests.last)
            let request = try #require((try JSONSerialization.jsonObject(
                with: Data(lastRequest.utf8))) as? [String: Any])
            #expect(request["kind"] as? String == "parameters")
            let payload = try #require(request["payload"] as? [String: Any])
            #expect(payload["action"] as? String == action)
        }

        // Missing/invalid typed fields are refused before the host.
        let invalid: [String] = [
            #"{"action":"parameters","path":"part.floecad","payload":"{\"action\":\"updateSketchEntity\",\"sketch_id\":\"x\",\"entity_id\":\"y\"}"}"#,
            #"{"action":"parameters","path":"part.floecad","payload":"{\"action\":\"setSketchDimension\",\"sketch_id\":\"x\",\"entity_id\":\"y\",\"kind\":\"explode\",\"value\":1}"}"#,
            #"{"action":"parameters","path":"part.floecad","payload":"{\"action\":\"feature.move\",\"feature_id\":\"x\",\"to_index\":-1}"}"#,
            #"{"action":"parameters","path":"part.floecad","payload":"{\"action\":\"feature.suppress\",\"feature_id\":\"x\"}"}"#,
        ]
        for json in invalid {
            let args = try decode(json)
            #expect(throws: FloeError.self) { try tool.validate(args) }
        }
    }

    @Test("capture returns a real image artifact bound to revision/change count")
    func captureReturnsArtifact() async throws {
        let host = FakeCadHost()
        let tool = CadDocumentTool(host: host)
        let context = makeContext()
        let output = try await execute(tool, """
        {"action":"capture","path":"part.floecad","revision":4,"payload":"{\\"width\\":640,\\"height\\":480}"}
        """, context: context)
        let artifact = try #require(output.artifacts.first)
        #expect(artifact.mimeType == "image/png")
        #expect(artifact.sha256 == String(repeating: "e", count: 64))
        #expect(artifact.byteCount > 0)
        #expect(output.summary.contains("\"revision\":4"))
        #expect(output.summary.contains("\"renderer\":\"engineering\""))
        #expect(output.summary.contains("\"content_sha256\":\"\(String(repeating: "a", count: 64))\""))
        #expect(output.summary.contains("\"image_sha256\":\"\(String(repeating: "e", count: 64))\""))
        #expect(output.summary.contains("vision"))

        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false)
        let url = support.appendingPathComponent("FloeAgent")
            .appendingPathComponent(artifact.relativePath)
        #expect(FileManager.default.fileExists(atPath: url.path))
        try? FileManager.default.removeItem(
            at: support.appendingPathComponent("FloeAgent")
                .appendingPathComponent("CADViewportArtifacts/\(context.runID.uuidString)"))
    }

    @Test("temporary chat refuses a global material-library export (it writes a file)")
    func temporaryGlobalLibraryExportRefused() async throws {
        let host = FakeCadHost()
        await host.setThreeDReply(#"{"ok":true,"mutated":true}"#)
        let tool = CadDocumentTool(host: host)
        let args = try decode(#"""
        {"action":"material","path":"part.floecad","payload":
         "{\"action\":\"libraryExport\",\"global\":true}"}
        """#)
        let context = ToolContext(
            runID: UUID(), toolCallID: "call-temp-1", scope: .local,
            workspaceRootURL: URL(fileURLWithPath: "/tmp/workspace"),
            cancellation: CancellationToken(), environmentID: "env-1",
            conversationID: UUID(), temporaryReadOnly: true)
        do {
            _ = try await tool.execute(args, context: context)
            Issue.record("temporary chat must refuse a global library export")
        } catch let error as FloeError {
            guard case .unauthorized = error else {
                Issue.record("unexpected refusal: \(error)")
                return
            }
        }
        #expect(await host.threeDRequests.isEmpty)

        // A non-global export only returns JSON bytes; it remains a read.
        await host.setThreeDReply(#"{"ok":true,"library_json":"{}"}"#)
        let readArgs = try decode(#"""
        {"action":"material","path":"part.floecad","payload":"{\"action\":\"libraryExport\"}"}
        """#)
        _ = try await tool.execute(readArgs, context: context)
        #expect(await host.threeDRequests.count == 1)
    }

    @Test("canvas-cad authority/canonical target use the frozen serviceStorePaths map only")
    func canvasCadUsesFrozenTrustedMap() throws {
        let canvas = UUID()
        let key = "canvas-cad:\(canvas.uuidString)/Part.floecad"
        let path = "/tmp/CanvasCAD/\(canvas.uuidString)/Part.floecad"
        var context = ToolContext(
            runID: UUID(), toolCallID: "call-canvas-1", scope: .local,
            workspaceRootURL: nil, cancellation: CancellationToken(),
            environmentID: "env-1", conversationID: UUID())
        context.serviceStorePaths[
            TypedMutationContract.cadCanvasBindingPrefix + key] = path
        let args = try decode("""
        {"action":"apply","path":"\(key)","proposal_id":"\(UUID().uuidString)"}
        """)
        #expect(CadDocumentTool.authorityTarget(for: args, context: context)
            == "file:" + URL(fileURLWithPath: path).standardizedFileURL
                .resolvingSymlinksInPath().path)
        do {
            try CadDocumentTool.authorizeDocumentPath(key, context: context)
        } catch {
            Issue.record("a frozen trusted canvas map must authorize its exact key: \(error)")
        }

        // A missing/frozen-out entry fails closed; the key's text alone grants
        // nothing.
        var withoutMap = context
        withoutMap.serviceStorePaths = [:]
        #expect(CadDocumentTool.authorityTarget(for: args, context: withoutMap)
            == "unresolved:canvas-cad")
        #expect(throws: FloeError.self) {
            try CadDocumentTool.authorizeDocumentPath(key, context: withoutMap)
        }
    }

    @Test("capture validates size bounds and revision before the host")
    func captureValidation() throws {
        let tool = CadDocumentTool(host: FakeCadHost())
        for json in [
            #"{"action":"capture","path":"part.floecad","payload":"{\"width\":12}"}"#,
            #"{"action":"capture","path":"part.dwg"}"#,
            #"{"action":"capture","path":"part.floecad","revision":-1}"#,
        ] {
            let args = try decode(json)
            #expect(throws: FloeError.self) { try tool.validate(args) }
        }
    }

    // MARK: Animation

    func makeLegacyContext() -> ToolContext {
        ToolContext(runID: UUID(), toolCallID: nil, scope: .local,
                    workspaceRootURL: URL(fileURLWithPath: "/tmp/workspace"),
                    cancellation: CancellationToken(), environmentID: "env-1",
                    conversationID: nil)
    }

    @Test("animation list and authored edits route through the animation kind")
    func animationRoutes() async throws {
        let host = FakeCadHost()
        await host.setThreeDReply(#"{"ok":true,"clip_count":1,"clips":[]}"#)
        let tool = CadDocumentTool(host: host)
        let output = try await execute(
            tool,
            #"{"action":"animation","path":"part.floecad","revision":4,"payload":"{\"action\":\"list\"}"}"#,
            context: makeContext())
        #expect(output.summary.contains("cad.document animation"))
        let requests = await host.threeDRequests
        #expect(requests.count == 1)
        let request = try #require(
            try JSONSerialization.jsonObject(with: Data(requests[0].utf8)) as? [String: Any])
        #expect(request["kind"] as? String == "animation")
        #expect((request["payload"] as? [String: Any])?["action"] as? String == "list")
        #expect((request["revision"] as? NSNumber)?.intValue == 4)
    }

    @Test("animation unknown action is refused before the host")
    func animationUnknownActionRefused() throws {
        let tool = CadDocumentTool(host: FakeCadHost())
        let args = try decode(
            #"{"action":"animation","path":"part.floecad","payload":"{\"action\":\"explodeAll\"}"}"#)
        #expect(throws: FloeError.self) { try tool.validate(args) }
    }

    @Test("animation capture returns the actual host frame artifact")
    func animationCapture() async throws {
        let host = FakeCadHost()
        let clipID = UUID()
        let tool = CadDocumentTool(host: host)
        let context = makeContext()
        let output = try await execute(
            tool,
            #"{"action":"animation","path":"part.floecad","payload":"{\"action\":\"capture\",\"clip_id\":\"\#(clipID.uuidString)\",\"frame\":30,\"fps\":30,\"width\":320,\"height\":240,\"format\":\"png\"}"}"#,
            context: context)
        #expect(output.summary.contains("animation.capture"))
        #expect(output.summary.contains("presentation"))
        let requests = await host.animationCaptureRequests
        #expect(requests.count == 1)
        #expect(requests[0].clipID == clipID)
        #expect(requests[0].frame == 30)
        #expect(output.artifacts.count == 1)
        #expect(output.artifacts[0].mimeType == "image/png")
    }

    @Test("animation export validates the MP4 target and returns the host receipt")
    func animationExport() async throws {
        let host = FakeCadHost()
        let tool = CadDocumentTool(host: host)
        let output = try await execute(
            tool,
            #"{"action":"animation","path":"part.floecad","output":"part.animation.mp4","payload":"{\"action\":\"export\",\"width\":640,\"height\":360,\"fps\":30,\"codec\":\"h264\"}"}"#,
            context: makeLegacyContext())
        #expect(output.summary.contains("animation.export"))
        let taskID = await host.animationExportTask
        #expect(output.summary.contains(taskID.uuidString))
        let requests = await host.animationExportRequests
        #expect(requests.count == 1)
        #expect(requests[0].0 == "part.animation.mp4")
        #expect(requests[0].1.width == 640)
        #expect(requests[0].1.height == 360)
    }

    @Test("temporary chat refuses animation edits and export but allows a timeline read")
    func animationTemporaryPolicy() async throws {
        let host = FakeCadHost()
        let tool = CadDocumentTool(host: host)
        var context = makeContext()
        context.temporaryReadOnly = true
        for json in [
            #"{"action":"animation","path":"part.floecad","payload":"{\"action\":\"createClip\"}"}"#,
            #"{"action":"animation","path":"part.floecad","output":"part.animation.mp4","payload":"{\"action\":\"export\"}"}"#,
        ] {
            let args = try decode(json)
            try tool.validate(args)
            do {
                _ = try await tool.execute(args, context: context)
                Issue.record("temporary chat must refuse animation write/export")
            } catch {
                // expected
            }
        }
        let read = try decode(
            #"{"action":"animation","path":"part.floecad","payload":"{\"action\":\"list\"}"}"#)
        try tool.validate(read)
        _ = try await tool.execute(read, context: context)
    }

    @Test("schema advertises the complete animation vocabulary")
    func animationSchema() throws {
        let schema = CadDocumentTool.parametersJSON
        #expect(schema.contains(#""animation""#))
        for action in CadNativeEditActions.animation {
            #expect(schema.contains(action), "animation action \(action) must be advertised")
        }
        #expect(schema.contains("verified MP4"))
    }
}
