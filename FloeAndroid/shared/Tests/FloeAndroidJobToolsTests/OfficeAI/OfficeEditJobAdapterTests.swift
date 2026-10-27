// SPDX-License-Identifier: MPL-2.0
//
// Authored-only focused regression for the Office AI durable job adapter
// (job-1db1a7a8d5da457a). NOT executed by this lane (Main's grouped batch
// decides). Pinned invariants:
//  * the adapter is the ORIGINAL `NativeJobServiceAdapter` shape keyed by
//    `document.office.edit`, owning ONLY the `apply` action, declaring
//    `requiresRuntimeAuthorization` (the ORIGINAL service consumes the exact
//    jobs.submit authority BEFORE prepare — prepare re-asserts the proof);
//  * prepare freezes the concrete operation and refuses (with nothing
//    durable created) when the consumed proof, the host lane, the payload
//    shape or the captured context is missing/expired;
//  * the frozen seed is the durable row's own run/call/payload digest, so
//    the reconcile path recomputes the IDENTICAL export opId (idempotency
//    without fresh-id replay);
//  * run reports a real verified terminal or throws; an UNKNOWN dispatch
//    throws the ORIGINAL `NativeJobSafetyFailure` (retained — never a clean
//    cancellation); success records the REAL artifact SHA-256 as the digest;
//  * reconcile accepts `.completed` ONLY when the port proves a real,
//    structurally valid, semantically matching artifact of the exact export
//    operation; nil keeps the honest `interrupted` outcome.

import XCTest
import Foundation
import FloeCore
import FloeModels
import FloeTools
import FloePersistence
@testable import FloeAndroidJobTools

private final class AdapterScriptPort: OfficeEditEnginePort, @unchecked Sendable {
    let contextID = "ctx" + String(repeating: "c", count: 32)
    var live = true
    var document = OfficeEditDocumentFacts(
        sessionToken: "sess-j", nativeGeneration: 4, viewerIncarnation: 2, hostGeneration: "8",
        nativeEpoch: "77", ownerTaskID: AdapterScriptPort.conversationID, workspaceID: UUID(),
        sourceLogicalPath: "docs/book.xlsx", sourceID: nil, sourceRevision: nil,
        family: .xlsx, editable: true,
        originalSnapshotSha256: String(repeating: "1", count: 64), originalSnapshotBytes: 900,
        workingCopySha256: String(repeating: "2", count: 64), workingCopyBytes: 900,
        displayName: "book.xlsx", route: .workspace)
    static let conversationID = UUID()
    private let callLock = NSLock()
    private var _contentCalls: [(contextID: String, seed: String)] = []
    var contentCalls: [(contextID: String, seed: String)] {
        callLock.lock(); defer { callLock.unlock() }; return _contentCalls
    }
    private func recordContentCall(_ contextID: String, _ seed: String) {
        callLock.lock(); _contentCalls.append((contextID, seed)); callLock.unlock()
    }
    var outcome = OfficeEditContentOutcome(
        result: OfficeEditCommandResult(state: .mutationVerified, attestation: "pasteresult"),
        flush: OfficeEditFlushReceipt(state: .flushed, workingCopySha256: String(repeating: "3", count: 64),
                                       workingCopyBytes: 1024),
        snapshot: OfficeEditSavedSnapshot(kind: .stagedExport, path: "/tmp/export.docx",
                                          sha256: String(repeating: "4", count: 64), byteCount: 1024,
                                          format: .xlsx, displayName: "book.edited.xlsx",
                                          attestation: "jni-saveas-sync+output-verified",
                                          sessionToken: "sess-j", nativeGeneration: 4),
        semantic: OfficeEditSemanticFacts(inspectedSavedPackage: true,
                                          partName: "xl/worksheets/sheet1.xml",
                                          cellTypeAttribute: "", cellHasFormula: true,
                                          cellTypeMatchesIntent: true,
                                          expectedContentMatches: true),
        contextConsumed: true)
    var reconcileArtifact: OfficeEditSavedSnapshot?
    var reconcileRequests: [String] = []
    private(set) var reconcileExpectations: [OfficeEditExpectations] = []
    /// Amendment/2: captured producer facts behind the scripted context (the
    /// captured LOGICAL sheet index for the xlsx fixture document).
    var capturedFacts = OfficeEditQueryFacts(docType: "calc", partIndex: 1)

    func isHostLaneLive() -> Bool { live }
    func openEditContext(runID: UUID, conversationID: UUID, workspaceRelativePath: String?,
                         cancellation: CancellationToken) async throws -> OfficeEditContext {
        OfficeEditContext(contextID: contextID, document: document, captureAttested: true,
                          capturedAtElapsedMillis: 1)
    }
    func read(_ command: OfficeEditReadCommand, contextID: String, conversationID: UUID,
              seed: String, cancellation: CancellationToken) async throws -> OfficeEditCommandResult {
        OfficeEditCommandResult(state: .queryObserved)
    }
    func executePreparatory(_ command: OfficeEditPreparatoryCommand, contextID: String,
                            conversationID: UUID, seed: String,
                            cancellation: CancellationToken) async throws -> OfficeEditPreparatoryOutcome {
        OfficeEditPreparatoryOutcome(result: OfficeEditCommandResult(state: .nativeCompleted),
                                     refreshedContext: nil)
    }
    func executeContent(_ command: OfficeEditContentCommand, contextID: String, conversationID: UUID,
                        seed: String, cancellation: CancellationToken) async throws
        -> OfficeEditContentOutcome {
        recordContentCall(contextID, seed)
        return outcome
    }
    func adoptVerifiedFile(path: String, expectedSha256: String, expectedBytes: Int64?,
                           format: OfficeEditDocumentFamily, displayName: String) throws
        -> OfficeEditSavedSnapshot { outcome.snapshot! }
    func inspectSavedPackage(_ snapshot: OfficeEditSavedSnapshot,
                             expectations: OfficeEditExpectations,
                             cancellation: CancellationToken) async throws -> OfficeEditSemanticFacts {
        outcome.semantic!
    }
    func publishVerifiedOutput(_ snapshot: OfficeEditSavedSnapshot, semantic: OfficeEditSemanticFacts,
                               slot: String, context: ToolContext) throws -> RunOutputFile {
        // The JOB path must never publish (no ToolContext exists there); any
        // call here is a bug the test fails on by crashing loudly.
        XCTFail("the durable job operation must not publish a run output")
        throw OfficeEditHostError.transport(code: "testFail")
    }
    func saveOriginal(_ snapshot: OfficeEditSavedSnapshot, document: OfficeEditDocumentFacts,
                      cancellation: CancellationToken) async throws -> OfficeEditOriginalSaveOutcome {
        OfficeEditOriginalSaveOutcome(local: .unsupported, provider: .refused)
    }
    func contextDocument(contextID: String, conversationID: UUID) -> OfficeEditDocumentFacts? {
        contextID == contextID && conversationID == Self.conversationID ? document : nil
    }
    func capturedContextFacts(contextID: String,
                              conversationID: UUID) -> OfficeEditQueryFacts? {
        contextID == contextID && conversationID == Self.conversationID ? capturedFacts : nil
    }
    func interruptedJobArtifact(operationID: String, exportOpId: String,
                                expectations: OfficeEditExpectations,
                                cancellation: CancellationToken) async throws
        -> OfficeEditSavedSnapshot? {
        reconcileRequests.append(exportOpId)
        reconcileExpectations.append(expectations)
        return reconcileArtifact
    }
}

final class OfficeEditJobAdapterTests: XCTestCase {

    private func payload() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "action": "apply", "command": "setCellContent", "text": "=SUM(A1:A9)",
            "cell": "B4", "contentType": "formula",
            "editContext": AdapterScriptPort.sharedContextID,
        ] as [String: Any])
    }

    private let port = AdapterScriptPort()

    private func binding(runID: UUID, taskID: UUID) -> RuntimeAuthorityBinding {
        RuntimeAuthorityBinding(runID: runID, taskID: taskID, environmentBinding: "test",
                                canonicalTarget: "document:office:test",
                                toolName: "jobs.submit", operation: "jobs.submit",
                                operationID: "call-jobs", idempotencyKey: "", baseRevision: nil,
                                payloadDigest: String(repeating: "0", count: 64))
    }

    private func request(authorization: NativeJobAuthorization, runID: UUID,
                         payloadData: Data? = nil) throws
        -> NativeJobPreparationRequest {
        NativeJobPreparationRequest(
            operationID: "op-fixture", runID: runID,
            conversationID: AdapterScriptPort.conversationID,
            environmentID: nil, workspaceRootURL: nil, allowedWorkspacePaths: [],
            scope: .local, payloadJSON: try payloadData ?? payload(),
            origin: NativeJobOrigin(kind: .mainRun), authorization: authorization,
            approvalGrantID: nil, submittedCallID: "call-jobs", idempotencyKey: "idem")
    }

    func testAdapterShapeIsTheOriginalSeam() throws {
        let adapter = OfficeEditJobAdapter.make(port: port)
        XCTAssertEqual(adapter.targetTool, OfficeDocumentEditTool.name)
        XCTAssertEqual(adapter.adaptedActions, ["apply"],
                       "only content applies defer; reads/preparatory/collect stay inline")
        XCTAssertTrue(adapter.requiresRuntimeAuthorization,
                      "the ORIGINAL submit path consumes the jobs.submit authority before prepare")
        XCTAssertTrue(adapter.handles(action: "apply"))
        XCTAssertFalse(adapter.handles(action: "read"))
        XCTAssertFalse(adapter.handles(action: nil))
    }

    func testPrepareRefusesWithoutConsumedAuthorization() async throws {
        let adapter = OfficeEditJobAdapter.make(port: port)
        let runID = UUID()
        let prepared = try? await adapter.prepare(
            request(authorization: .notRequired, runID: runID))
        XCTAssertNil(prepared, "a preparation without the consumed binding must throw")
        XCTAssertTrue(port.contentCalls.isEmpty)
    }

    func testPrepareRefusesForeignConversationContext() async throws {
        let adapter = OfficeEditJobAdapter.make(port: port)
        let runID = UUID()
        let req = try request(authorization: .consumed(binding: binding(runID: runID,
                                                                         taskID: AdapterScriptPort.conversationID),
                                                       at: Date()),
                              runID: runID)
        var forged = req
        forged.conversationID = UUID() // context belongs to the FIRST conversation
        let prepared = try? await adapter.prepare(forged)
        XCTAssertNil(prepared, "prepare must refuse a context that is not the row's own conversation's")
    }

    func testPrepareAcceptsLiteralLeadingEqualsAndValidatesNumberIntent() async throws {
        let adapter = OfficeEditJobAdapter.make(port: port)
        let runID = UUID()
        func makePayload(_ text: String, _ kind: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "action": "apply", "command": "setCellContent", "text": text,
                "cell": "B4", "contentType": kind,
                "editContext": AdapterScriptPort.sharedContextID,
            ] as [String: Any])
        }
        func prepare(_ data: Data) async -> Bool {
            guard let prepared = try? request(
                authorization: .consumed(binding: binding(
                    runID: runID, taskID: AdapterScriptPort.conversationID), at: Date()),
                runID: runID, payloadData: data) else { return false }
            let result = try? await adapter.prepare(prepared)
            return result != nil
        }
        // amendment/2: a leading-'=' literal is the host-encoded exact string.
        let literalPrepared = try await prepare(makePayload("=kept-as-text", "literal"))
        XCTAssertTrue(literalPrepared)
        let numberPrepared = try await prepare(makePayload("123.5", "number"))
        XCTAssertTrue(numberPrepared)
        // malformed number intent refuses before anything durable exists.
        let malformedNumber = try await prepare(makePayload("12,5", "number"))
        XCTAssertFalse(malformedNumber)
        // formula without its mandatory '=' still refuses.
        let formulaMissingEquals = try await prepare(makePayload("SUM(A1:A9)", "formula"))
        XCTAssertFalse(formulaMissingEquals)
        let formulaPrepared = try await prepare(makePayload("=SUM(A1:A9)", "formula"))
        XCTAssertTrue(formulaPrepared)
    }

    func testRunReportsDigestOfTheRealArtifactAndNeverPublishes() async throws {
        let adapter = OfficeEditJobAdapter.make(port: port)
        let runID = UUID()
        let operation = try await adapter.prepare(
            try request(authorization: .consumed(binding: binding(runID: runID,
                                                                  taskID: AdapterScriptPort.conversationID),
                                                 at: Date()),
                      runID: runID))
        XCTAssertEqual(operation.operationID, "op-fixture")
        XCTAssertEqual(operation.frozenRevision, String(repeating: "1", count: 64),
                       "the frozen revision is the open-time original snapshot digest")
        let reported = ProgressBox()
        let hooks = NativeJobRunHooks(report: { reported.set($0) },
                                      isCancellationRequested: { false })
        let outcome = try await operation.run(hooks: hooks)
        XCTAssertEqual(outcome.digest, String(repeating: "4", count: 64),
                       "the durable result digest is the verified artifact's REAL SHA-256")
        XCTAssertEqual(outcome.artifactPath, "/tmp/export.docx")
        XCTAssertFalse(outcome.verified.isEmpty)
        let summary = try JSONSerialization.jsonObject(with: Data(outcome.summary.utf8))
            as? [String: Any]
        XCTAssertEqual(summary?["status"] as? String, "verifiedSaved")
        // Amendment/2: the durable outcome summary persists the bounded owned
        // v2 target metadata (operation/seed/artifact digest/format/command/
        // strong producer version + captured logical part) for a later
        // collect to validate against this exact row.
        let owned = try XCTUnwrap(summary?["ownedV2Target"] as? [String: Any])
        let expectedSeed = OfficeEditOperationIdentity.derive(
            runID: runID, callID: "call-jobs",
            payloadDigest: RuntimeAuthorityDigest.payloadDigest(try payload()), step: "call")
        XCTAssertEqual(owned["operation"] as? String, "op-fixture")
        XCTAssertEqual(owned["seed"] as? String, expectedSeed)
        XCTAssertEqual(owned["savedSHA256"] as? String, String(repeating: "4", count: 64))
        XCTAssertEqual(owned["format"] as? String, "xlsx")
        XCTAssertEqual(owned["command"] as? String, "setCellContent")
        XCTAssertEqual((owned["producerProofVersion"] as? NSNumber)?.intValue, 2)
        XCTAssertEqual((owned["partIndex"] as? NSNumber)?.intValue, 1,
                       "the REAL captured logical sheet index is persisted, never sheet1")
        XCTAssertEqual(owned["preEditSha256"] as? String, String(repeating: "2", count: 64))
        // The success summary points at collect; publishVerifiedOutput would
        // have XCTFail'ed (no ToolContext exists on this path).
        let text = outcome.summary
        XCTAssertTrue(text.contains("collect"), text)
    }

    func testRunMapsUnknownToUnsafeRetainedFailureNotCancellation() async throws {
        let adapter = OfficeEditJobAdapter.make(port: port)
        let runID = UUID()
        port.outcome = OfficeEditContentOutcome(
            result: OfficeEditCommandResult(state: .unknown, failureCode: "timeoutWithoutAck"),
            flush: OfficeEditFlushReceipt(state: .unknown), contextConsumed: true,
            document: port.document)
        let operation = try await adapter.prepare(
            try request(authorization: .consumed(binding: binding(runID: runID,
                                                                  taskID: AdapterScriptPort.conversationID),
                                                 at: Date()),
                      runID: runID))
        let hooks = NativeJobRunHooks(report: { _ in }, isCancellationRequested: { false })
        do {
            _ = try await operation.run(hooks: hooks)
            XCTFail("UNKNOWN must never settle as success")
        } catch let failure as NativeJobSafetyFailure {
            XCTAssertTrue(failure.isUnsafeResourceState,
                          "an uncertain native effect outranks cancellation and retains staging")
        }
    }

    private func docxPayload() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "action": "apply", "command": "applyText", "text": "corrected paragraph",
            "editContext": AdapterScriptPort.sharedContextID,
        ] as [String: Any])
    }

    func testReconcileUsesTheIdenticalDeterministicExportIdentity() async throws {
        let adapter = OfficeEditJobAdapter.make(port: port)
        let runID = UUID()
        let data = try docxPayload()
        let prepared = try await adapter.prepare(
            try request(authorization: .consumed(binding: binding(runID: runID,
                                                                  taskID: AdapterScriptPort.conversationID),
                                                 at: Date()),
                        runID: runID, payloadData: data))
        _ = prepared
        // Build a durable row exactly as the ORIGINAL service would after
        // prepare (prepared summary frozen at submit) and reconcile it.
        let digest = RuntimeAuthorityDigest.payloadDigest(data)
        let operationID = NativeJobOperationIdentity.derive(runID: runID, toolCallID: "call-jobs",
                                                            payloadDigest: digest)
        var job = BackgroundJob(conversationID: AdapterScriptPort.conversationID, runID: runID,
                                toolCallID: "call-jobs", kind: .tool,
                                targetTool: OfficeDocumentEditTool.name, payloadJSON: data)
        job.state = .running
        let document = NativeJobProgressDocument(prepared: NativeJobPreparationSummary(
            operationID: operationID, serviceLabel: "document.office.edit/docx",
            frozenRevision: nil))
        job.progressJSON = document.encoded()

        // No proof exists yet -> honest nil (the service keeps `interrupted`).
        let none = await OfficeEditJobAdapter.reconcile(port: port, job: job)
        XCTAssertNil(none)

        // A verified artifact of the EXACT export opId is proof -> .completed.
        port.reconcileArtifact = OfficeEditSavedSnapshot(kind: .stagedExport, path: "/tmp/e.docx",
                                                          sha256: String(repeating: "9", count: 64),
                                                          byteCount: 10, format: .docx,
                                                          displayName: "e.docx", attestation: "reconcile",
                                                          sessionToken: "", nativeGeneration: 0)
        let resolved = await OfficeEditJobAdapter.reconcile(port: port, job: job)
        XCTAssertEqual(resolved, .completed)
        // The port saw the deterministic export identity derived from the
        // row's own run/call/payload (never a fresh random id).
        XCTAssertEqual(port.reconcileRequests.count, 2)
        XCTAssertEqual(port.reconcileRequests.first, port.reconcileRequests.last)
        let seed = OfficeEditOperationIdentity.derive(runID: runID, callID: "call-jobs",
                                                       payloadDigest: digest, step: "call")
        XCTAssertEqual(port.reconcileRequests.first,
                       OfficeEditOperationIdentity.stageOpId(seed: seed, stage: "export"))
        // Amendment/2: the reconcile proof binds the RECOMPUTED ORIGINAL stage
        // identities and the durable row's own owner — never the reconcile
        // caller's identity, never a model-supplied one.
        let bound = try XCTUnwrap(port.reconcileExpectations.last)
        XCTAssertEqual(bound.verificationMode, .reconcile)
        XCTAssertEqual(bound.ownerTaskID, AdapterScriptPort.conversationID)
        XCTAssertEqual(bound.effectOpId,
                       OfficeEditOperationIdentity.stageOpId(seed: seed, stage: "apply"))
        XCTAssertEqual(bound.exportOpId,
                       OfficeEditOperationIdentity.stageOpId(seed: seed, stage: "export"))
    }

    func testReconcileRefusesPartAmbiguousFamiliesWithoutCapturedPartMetadata() async throws {
        // INTENTIONAL CONTRACT CHANGE (amendment/2, Main ruling): XLSX/PPTX
        // target effects REQUIRE the captured LOGICAL part identity. An
        // interrupted durable row carries none — the payload schema and the
        // prepared summary are unchanged and the in-memory capture is gone —
        // so reconciliation refuses honestly instead of guessing a part.
        let adapter = OfficeEditJobAdapter.make(port: port)
        let runID = UUID()
        let data = try payload() // setCellContent formula (xlsx)
        _ = try await adapter.prepare(
            try request(authorization: .consumed(binding: binding(runID: runID,
                                                                  taskID: AdapterScriptPort.conversationID),
                                                 at: Date()),
                        runID: runID))
        let digest = RuntimeAuthorityDigest.payloadDigest(data)
        let operationID = NativeJobOperationIdentity.derive(runID: runID, toolCallID: "call-jobs",
                                                            payloadDigest: digest)
        var job = BackgroundJob(conversationID: AdapterScriptPort.conversationID, runID: runID,
                                toolCallID: "call-jobs", kind: .tool,
                                targetTool: OfficeDocumentEditTool.name, payloadJSON: data)
        job.state = .running
        job.progressJSON = NativeJobProgressDocument(prepared: NativeJobPreparationSummary(
            operationID: operationID, serviceLabel: "document.office.edit/xlsx",
            frozenRevision: nil)).encoded()
        port.reconcileArtifact = OfficeEditSavedSnapshot(kind: .stagedExport, path: "/tmp/e.xlsx",
                                                          sha256: String(repeating: "9", count: 64),
                                                          byteCount: 10, format: .xlsx,
                                                          displayName: "e.xlsx", attestation: "reconcile",
                                                          sessionToken: "", nativeGeneration: 0)
        let resolved = await OfficeEditJobAdapter.reconcile(port: port, job: job)
        XCTAssertNil(resolved,
                     "xlsx reconcile without captured part metadata stays honestly interrupted")
        XCTAssertTrue(port.reconcileRequests.isEmpty,
                      "no host dispatch may be attempted for an unprovable part")
    }
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: NativeJobProgress?
    func set(_ progress: NativeJobProgress) { lock.lock(); value = progress; lock.unlock() }
    func get() -> NativeJobProgress? { lock.lock(); defer { lock.unlock() }; return value }
}

extension AdapterScriptPort {
    static let sharedContextID = "ctx" + String(repeating: "c", count: 32)
}
