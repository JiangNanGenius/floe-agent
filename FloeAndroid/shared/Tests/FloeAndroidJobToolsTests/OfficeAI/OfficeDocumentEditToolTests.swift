// SPDX-License-Identifier: MPL-2.0
//
// Authored-only focused regression for the Android `document.office.edit`
// tool (job-1db1a7a8d5da457a). NOT executed by this lane (no compile/test
// authority here; Main runs the single grouped batch). Every assertion pins
// an ACCEPTED invariant: typed-surface refusals; the capture / model-think /
// apply contract (apply only ever references the SAME opaque context — a
// fresh silent capture at apply time is a violation, not a fallback);
// verified-saved gating before publication; publication only under the real
// submitting call; UNKNOWN/retention honesty; the `jobs.*` executor-context
// refusal; and collect's durable-store-only ownership. All fixtures are
// synthetic; nothing touches a device, engine, provider or credential.

import XCTest
import Foundation
import FloeCore
import FloeModels
import FloeTools
import FloePersistence
@testable import FloeAndroidJobTools

// MARK: - Scripted port (recording, lock-protected; not an actor so sync
// methods like adopt/publish can record without races)

private final class PortRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: [Any]] = [:]
    func add(_ key: String, _ value: Any) { lock.lock(); storage[key, default: []].append(value); lock.unlock() }
    func all(_ key: String) -> [Any] { lock.lock(); defer { lock.unlock() }; return storage[key] ?? [] }
    var counts: [String: Int] {
        lock.lock(); defer { lock.unlock() }
        return storage.reduce(into: [:]) { $0[$1.key] = $1.value.count }
    }
}

private final class ScriptedPort: OfficeEditEnginePort, @unchecked Sendable {
    struct Fact {
        static let taskID = UUID()
        static let workspaceID = UUID()
    }
    let recorder = PortRecorder()
    let contextID = "ctx" + String(repeating: "a", count: 32)

    var live = true
    var readOnlyMount = false
    var document = OfficeEditDocumentFacts(
        sessionToken: "sess-a", nativeGeneration: 7, viewerIncarnation: 3, hostGeneration: "9",
        nativeEpoch: "42", ownerTaskID: Fact.taskID, workspaceID: Fact.workspaceID,
        sourceLogicalPath: "docs/report.docx", sourceID: "src-1",
        sourceRevision: "11111111-2222-3333-4444-555555555555",
        family: .docx, editable: true,
        originalSnapshotSha256: String(repeating: "a", count: 64), originalSnapshotBytes: 1234,
        workingCopySha256: String(repeating: "b", count: 64), workingCopyBytes: 1234,
        displayName: "report.docx", route: .workspace)
    var readResult = OfficeEditCommandResult(state: .queryObserved, attestation: "status")
    var contentResult: OfficeEditContentOutcome?
    var snapshot = OfficeEditSavedSnapshot(
        kind: .stagedExport, path: "/tmp/synthetic-not-read-by-scripted-port.docx",
        sha256: String(repeating: "d", count: 64), byteCount: 2048, format: .docx,
        displayName: "report.edited.docx", attestation: "jni-saveas-sync+output-verified",
        sessionToken: "sess-a", nativeGeneration: 7)
    // Amendment/2 contract change (marked, not weakened): the default fixture
    // now carries the OWNED v2 proof facts — the intended content matched at
    // the captured target AND a trusted semantic-delta proof — because global
    // text presence alone no longer passes the production gate.
    var semantic = OfficeEditSemanticFacts(inspectedSavedPackage: true, partName: "word/document.xml",
                                           expectedTextFound: true, occurrenceCount: 1,
                                           replacementScope: "selectionReplaced",
                                           changedFromOriginal: true,
                                           expectedContentMatches: true,
                                           semanticDeltaVerified: true)
    var publishReceipt: RunOutputFile?
    var publishError: Error?
    var preparatory = OfficeEditPreparatoryOutcome(
        result: OfficeEditCommandResult(state: .nativeCompleted, attestation: "gettextselection"),
        refreshedContext: nil)

    func isHostLaneLive() -> Bool { live }

    func openEditContext(runID: UUID, conversationID: UUID, workspaceRelativePath: String?,
                         cancellation: CancellationToken) async throws -> OfficeEditContext {
        recorder.add("open", ["conversation": conversationID, "path": workspaceRelativePath as Any])
        guard live else { throw OfficeEditHostError.hostLaneUnavailable }
        return OfficeEditContext(contextID: contextID, document: document, captureAttested: true,
                                 capturedAtElapsedMillis: 1)
    }

    func read(_ command: OfficeEditReadCommand, contextID: String, conversationID: UUID,
              seed: String, cancellation: CancellationToken) async throws -> OfficeEditCommandResult {
        recorder.add("read", ["contextID": contextID, "command": command])
        return readResult
    }

    func executePreparatory(_ command: OfficeEditPreparatoryCommand, contextID: String,
                            conversationID: UUID, seed: String,
                            cancellation: CancellationToken) async throws -> OfficeEditPreparatoryOutcome {
        recorder.add("preparatory", ["contextID": contextID])
        return preparatory
    }

    func executeContent(_ command: OfficeEditContentCommand, contextID: String, conversationID: UUID,
                        seed: String, cancellation: CancellationToken) async throws
        -> OfficeEditContentOutcome {
        recorder.add("content", ["contextID": contextID, "seed": seed])
        if let contentResult { return contentResult }
        var documentCopy = document
        documentCopy.editable = document.editable && !readOnlyMount
        return OfficeEditContentOutcome(result: OfficeEditCommandResult(state: .mutationVerified,
                                                                        attestation: "pasteresult"),
                                        flush: OfficeEditFlushReceipt(state: .flushed,
                                                                      workingCopySha256: String(repeating: "c", count: 64),
                                                                      workingCopyBytes: 2048,
                                                                      attestation: "uno-ack+digest"),
                                        snapshot: snapshot, semantic: semantic,
                                        contextConsumed: true, document: documentCopy)
    }

    func adoptVerifiedFile(path: String, expectedSha256: String, expectedBytes: Int64?,
                           format: OfficeEditDocumentFamily, displayName: String) throws
        -> OfficeEditSavedSnapshot {
        recorder.add("adopt", ["path": path, "sha": expectedSha256])
        return snapshot
    }

    func inspectSavedPackage(_ snapshot: OfficeEditSavedSnapshot,
                             expectations: OfficeEditExpectations,
                             cancellation: CancellationToken) async throws -> OfficeEditSemanticFacts {
        recorder.add("inspect", ["command": expectations.command.rawValue,
                                 "partIndex": expectations.partIndex as Any,
                                 "mode": expectations.verificationMode?.rawValue as Any,
                                 "preEdit": expectations.preEditSnapshotSha256 as Any])
        return semantic
    }

    func publishVerifiedOutput(_ snapshot: OfficeEditSavedSnapshot, semantic: OfficeEditSemanticFacts,
                               slot: String, context: ToolContext) throws -> RunOutputFile {
        recorder.add("publish", ["slot": slot, "sha": snapshot.sha256,
                                 "callID": context.toolCallID ?? "-"])
        if let publishError { throw publishError }
        guard let publishReceipt else {
            throw OfficeEditHostError.verificationFailed(code: "fixtureNoReceipt",
                                                         detail: "scripted publish receipt missing")
        }
        return publishReceipt
    }

    func saveOriginal(_ snapshot: OfficeEditSavedSnapshot, document: OfficeEditDocumentFacts,
                      cancellation: CancellationToken) async throws -> OfficeEditOriginalSaveOutcome {
        recorder.add("original", ["path": document.sourceLogicalPath ?? "-"])
        return OfficeEditOriginalSaveOutcome(local: .committed, provider: .committed,
                                             committedSHA256: snapshot.sha256,
                                             committedBytes: snapshot.byteCount)
    }

    func contextDocument(contextID: String, conversationID: UUID) -> OfficeEditDocumentFacts? {
        contextID == contextID && conversationID == document.ownerTaskID ? document : nil
    }

    func interruptedJobArtifact(operationID: String, exportOpId: String,
                                expectations: OfficeEditExpectations,
                                cancellation: CancellationToken) async throws
        -> OfficeEditSavedSnapshot? {
        recorder.add("reconcile", exportOpId)
        return nil
    }
}

// MARK: - Tests

final class OfficeDocumentEditToolTests: XCTestCase {

    private func makeTool(conversation: UUID = ScriptedPort.Fact.taskID)
        -> (OfficeDocumentEditTool, ScriptedPort) {
        let port = ScriptedPort()
        port.document.ownerTaskID = conversation
        return (OfficeDocumentEditTool(port: port) { nil }, port)
    }

    private func makeContext(callID: String? = "call-1", conversation: UUID,
                             temporary: Bool = false, run: UUID = UUID(),
                             workspaceRootURL: URL? = nil) -> ToolContext {
        ToolContext(runID: run, toolCallID: callID, scope: .local,
                    workspaceRootURL: workspaceRootURL, cancellation: CancellationToken(),
                    conversationID: conversation, temporaryReadOnly: temporary)
    }

    private func json(_ output: ToolExecutionOutput) throws -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(output.summary.utf8))) as? [String: Any] ?? [:]
    }

    private func receipt(callID: String, runID: UUID, taskID: UUID) -> RunOutputFile {
        RunOutputFile(outputID: "out-1", slot: "office-document", runID: runID, taskID: taskID,
                      environmentID: nil, producerCallID: callID, producerTool: "document.office.edit",
                      relativePath: "RunOutputs/\(runID.uuidString)/out-1/report.edited.docx",
                      displayName: "report.edited.docx",
                      mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                      uti: nil, byteCount: 2048, sha256: String(repeating: "d", count: 64),
                      role: .userFile)
    }

    // MARK: schema refusals (typed surface)

    func testApplyRequiresOpaqueEditContextAndNeverCapturesSilently() {
        let (tool, port) = makeTool()
        XCTAssertThrowsError(try tool.validate(.init(action: .apply, command: "applyText",
                                                     text: "hello"))) { error in
            XCTAssertTrue(String(describing: error).contains("editContext"), "\(error)")
        }
        XCTAssertNoThrow(try tool.validate(.init(action: .apply, command: "applyText", text: "hello",
                                                 editContext: port.contextID)))
    }

    func testCellContentIntentAndSingleCellRules() {
        let (tool, port) = makeTool()
        let ctx = port.contextID
        func cell(_ text: String, _ kind: String?) -> OfficeDocumentEditTool.Arguments {
            .init(action: .apply, command: "setCellContent", text: text, cell: "C3",
                  contentType: kind, editContext: ctx)
        }
        // INTENTIONAL CONTRACT CHANGE (amendment/2): a leading-'=' literal is
        // now ACCEPTED — the trusted host applies it through its safe
        // apostrophe encoding and the saved string type + raw content are
        // verified. The old shared-side refusal was the defect.
        XCTAssertNoThrow(try tool.validate(cell("=A1+B1", "literal")))
        XCTAssertThrowsError(try tool.validate(cell("A1+B1", "formula")))    // formula without '='
        XCTAssertThrowsError(try tool.validate(cell("1\t2", "literal")))     // multi-cell spread
        XCTAssertThrowsError(try tool.validate(cell("00123", nil)))          // missing intent
        XCTAssertNoThrow(try tool.validate(cell("00123", "literal")))        // literal kept literal
        XCTAssertNoThrow(try tool.validate(cell("=SUM(A1:A2)", "formula")))
    }

    func testCrossActionArgumentsRefused() {
        let (tool, _) = makeTool()
        XCTAssertThrowsError(try tool.validate(.init(action: .read, command: "documentContext",
                                                     text: "smuggled")))
        XCTAssertThrowsError(try tool.validate(.init(action: .collect, command: "applyText",
                                                     jobID: UUID().uuidString)))
        XCTAssertThrowsError(try tool.validate(.init(action: .capabilities, command: "read")))
    }

    func testWorkspacePathShapeConfinement() {
        let (tool, _) = makeTool()
        func path(_ p: String) -> OfficeDocumentEditTool.Arguments {
            .init(action: .read, command: "documentContext", workspacePath: p)
        }
        XCTAssertThrowsError(try tool.validate(path("/etc/passwd")))
        XCTAssertThrowsError(try tool.validate(path("../escape.docx")))
        XCTAssertThrowsError(try tool.validate(path("notes.txt")))
        XCTAssertThrowsError(try tool.validate(path("docs//a.docx")))
        XCTAssertNoThrow(try tool.validate(path("docs/a.docx")))
    }

    // MARK: read

    func testReadOpensContextAndBindsSameContextToFacts() async throws {
        let conversation = ScriptedPort.Fact.taskID
        let (tool, port) = makeTool(conversation: conversation)
        port.readResult = OfficeEditCommandResult(state: .queryObserved, attestation: "status",
                                                  facts: OfficeEditQueryFacts(docType: "word",
                                                                             partsCount: 1,
                                                                             selectedPart: "0"))
        // The production confinement gate requires a REAL task workspace root
        // naming a regular OOXML file; give the read a genuine workspace.
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-office-read-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        try FileManager.default.createDirectory(
            at: workspace.appendingPathComponent("docs", isDirectory: true),
            withIntermediateDirectories: true)
        try Data("docx".utf8).write(to: workspace.appendingPathComponent("docs/report.docx"))
        let output = try await tool.execute(
            .init(action: .read, command: "documentContext", workspacePath: "docs/report.docx"),
            context: makeContext(conversation: conversation, workspaceRootURL: workspace))
        let payload = try json(output)
        XCTAssertEqual(payload["status"] as? String, "ok")
        XCTAssertEqual(payload["editContext"] as? String, port.contextID)
        let document = payload["document"] as? [String: Any]
        XCTAssertEqual(document?["logicalPath"] as? String, "docs/report.docx")
        XCTAssertEqual(port.recorder.all("open").count, 1)
        let reads = port.recorder.all("read")
        XCTAssertEqual((reads.first as? [String: Any])?["contextID"] as? String, port.contextID,
                       "the read must bind the SAME context it just opened")
        XCTAssertTrue(port.recorder.all("content").isEmpty)
    }

    func testReadOversizeSelectionSurfacesHonestTruncationFlag() async throws {
        let conversation = ScriptedPort.Fact.taskID
        let (tool, port) = makeTool(conversation: conversation)
        port.readResult = OfficeEditCommandResult(state: .queryObserved, attestation: "status",
                                                  facts: OfficeEditQueryFacts(
                                                    selectionByteCount: OfficeEditLimits.maximumReturnedSelectionBytes + 1,
                                                    selectionTruncated: true))
        let output = try await tool.execute(.init(action: .read, command: "textSelection"),
                                            context: makeContext(conversation: conversation))
        let payload = try json(output)
        let facts = payload["facts"] as? [String: Any]
        XCTAssertEqual(facts?["selectionTruncated"] as? Bool, true)
        XCTAssertNil(facts?["selectionText"], "truncated content must NOT be partially returned")
    }

    // MARK: apply contract

    func testApplyUsesOpaqueContextAndPublishesUnderTheRealCall() async throws {
        let conversation = ScriptedPort.Fact.taskID
        let run = UUID()
        let (tool, port) = makeTool(conversation: conversation)
        port.publishReceipt = receipt(callID: "call-1", runID: run, taskID: conversation)
        let output = try await tool.execute(
            .init(action: .apply, command: "applyText", text: "corrected paragraph",
                  editContext: port.contextID),
            context: makeContext(conversation: conversation, run: run))
        let payload = try json(output)
        XCTAssertEqual(payload["status"] as? String, "verifiedSaved")
        XCTAssertEqual(output.outputFiles.count, 1)
        XCTAssertEqual(outputFilesSealedCall(output.outputFiles.first), "call-1",
                       "the receipt must carry the REAL submitting call id")
        let publishes = port.recorder.all("publish")
        XCTAssertEqual(publishes.count, 1)
        XCTAssertEqual((publishes.first as? [String: Any])?["callID"] as? String, "call-1")
        let contents = port.recorder.all("content")
        XCTAssertEqual((contents.first as? [String: Any])?["contextID"] as? String, port.contextID,
                       "apply must reference the SAME captured context, never a silent fresh capture")
    }

    private func outputFilesSealedCall(_ file: RunOutputFile?) -> String? { file?.producerCallID }

    func testApplyCarriesStableSeedSoRetriesCannotReplayEffects() async throws {
        let conversation = ScriptedPort.Fact.taskID
        let run = UUID()
        let (tool, port) = makeTool(conversation: conversation)
        port.publishReceipt = receipt(callID: "c2", runID: run, taskID: conversation)
        let args = OfficeDocumentEditTool.Arguments(action: .apply, command: "applyText",
                                                    text: "same text", editContext: port.contextID)
        let context = makeContext(callID: "call-2", conversation: conversation, run: run)
        _ = try await tool.execute(args, context: context)
        _ = try await tool.execute(args, context: context)
        let contents = port.recorder.all("content")
        let first = (contents[0] as? [String: Any])?["seed"] as? String
        let second = (contents[1] as? [String: Any])?["seed"] as? String
        XCTAssertEqual(first, second, "the same call+payload retried MUST derive the same stage identities")
    }

    func testUnknownEffectTerminatesRefusedAndNeverPublishes() async throws {
        let conversation = ScriptedPort.Fact.taskID
        let (tool, port) = makeTool(conversation: conversation)
        port.contentResult = OfficeEditContentOutcome(
            result: OfficeEditCommandResult(state: .unknown, failureCode: "timeoutWithoutAck",
                                            detail: "no ack", attestation: "none"),
            flush: OfficeEditFlushReceipt(state: .unknown), contextConsumed: true,
            document: port.document)
        let output = try await tool.execute(
            .init(action: .apply, command: "applyText", text: "x", editContext: port.contextID),
            context: makeContext(conversation: conversation))
        XCTAssertEqual(output.exitStatus, 1)
        XCTAssertTrue(output.outputFiles.isEmpty, "UNKNOWN must never publish a receipt")
        XCTAssertTrue(port.recorder.all("publish").isEmpty)
        let payload = try json(output)
        XCTAssertEqual(payload["status"] as? String, "unknown")
        let text = output.summary
        XCTAssertTrue(text.contains("UNKNOWN") || text.contains("retained") || text.contains("resubmit")
            || (payload["note"] as? String)?.contains("UNKNOWN") == true, "must retain honestly")
    }

    func testUnprovenSemanticFactsFailClosedWithoutPublication() async throws {
        let conversation = ScriptedPort.Fact.taskID
        let (tool, port) = makeTool(conversation: conversation)
        port.semantic = OfficeEditSemanticFacts(inspectedSavedPackage: true,
                                                partName: "word/document.xml",
                                                expectedTextFound: false)
        do {
            _ = try await tool.execute(
                .init(action: .apply, command: "applyText", text: "x", editContext: port.contextID),
                context: makeContext(conversation: conversation))
            XCTFail("unproven saved content must fail closed")
        } catch let error as OfficeEditHostError {
            XCTAssertEqual(error.code, "savedPackageMissingAppliedText")
        }
        XCTAssertTrue(port.recorder.all("publish").isEmpty)
    }

    func testCellTypeMismatchIntentFailsClosed() async throws {
        let conversation = ScriptedPort.Fact.taskID
        let (tool, port) = makeTool(conversation: conversation)
        port.document.family = .xlsx
        port.snapshot.format = .xlsx
        port.semantic = OfficeEditSemanticFacts(inspectedSavedPackage: true, partName: "xl/worksheets/sheet1.xml",
                                                cellTypeAttribute: "n", cellHasFormula: false,
                                                cellTypeMatchesIntent: false)
        do {
            _ = try await tool.execute(
                .init(action: .apply, command: "setCellContent", text: "=SUM(A1:A2)", cell: "B4",
                      contentType: "formula", editContext: port.contextID),
                context: makeContext(conversation: conversation))
            XCTFail("mismatched saved cell type must fail closed")
        } catch let error as OfficeEditHostError {
            XCTAssertEqual(error.code, "savedCellTypeMismatch")
        }
    }

    // MARK: amendment/2 semantic gate — intended content at the trusted target

    func testSemanticGateRefusesPreExistingTextAndPresenceOnlyProof() {
        // The applied text is globally present (it may even pre-exist
        // elsewhere) but the saved content does not equal the intent at the
        // target — presence alone never passes.
        let presenceOnly = OfficeEditSemanticFacts(
            inspectedSavedPackage: true, partName: "word/document.xml",
            expectedTextFound: true, occurrenceCount: 3,
            expectedContentMatches: false, targetEffectVerified: false,
            semanticDeltaVerified: false)
        XCTAssertEqual(OfficeEditSemanticGate.failure(command: .applyText,
                                                      semantic: presenceOnly)?.code,
                       "savedContentMismatch")
        // Even with matching content, NO trusted target/delta/historical
        // proof refuses — a nativeCompleted ack is never success by itself.
        let noProof = OfficeEditSemanticFacts(
            inspectedSavedPackage: true, partName: "word/document.xml",
            expectedTextFound: true, expectedContentMatches: true)
        XCTAssertEqual(OfficeEditSemanticGate.failure(command: .applyText, semantic: noProof)?.code,
                       "savedContentProofMissing")
    }

    func testSemanticGateAcceptsRealTargetDeltaAndBoundHistoricalProof() {
        let delta = OfficeEditSemanticFacts(
            inspectedSavedPackage: true, partName: "word/document.xml",
            expectedTextFound: true, expectedContentMatches: true,
            semanticDeltaVerified: true)
        XCTAssertNil(OfficeEditSemanticGate.failure(command: .applyText, semantic: delta))
        let target = OfficeEditSemanticFacts(
            inspectedSavedPackage: true, partName: "word/document.xml",
            expectedTextFound: true, expectedContentMatches: true,
            targetEffectVerified: true)
        XCTAssertNil(OfficeEditSemanticGate.failure(command: .applyText, semantic: target))
        // A bound historical proof of the EXACT owned completed job passes.
        let historical = OfficeEditSemanticFacts(
            inspectedSavedPackage: true, partName: "word/document.xml",
            expectedTextFound: true, expectedContentMatches: true,
            proofReused: true)
        XCTAssertNil(OfficeEditSemanticGate.failure(command: .applyText, semantic: historical))
    }

    func testSemanticGateFormulaCachedResultTypeIsValidAndOldFormulaRefused() {
        // A formula whose cached result persisted t=str is VALID — the v1
        // refusal of every non-empty t alongside <f> was the actual defect.
        let cached = OfficeEditSemanticFacts(
            inspectedSavedPackage: true, partName: "xl/worksheets/sheet2.xml",
            cellTypeAttribute: "str", cellHasFormula: true,
            cellTypeMatchesIntent: true, expectedContentMatches: true)
        XCTAssertNil(OfficeEditSemanticGate.failure(command: .setCellContent, semantic: cached))
        // A different/old <f> than the intended formula refuses on content.
        let oldFormula = OfficeEditSemanticFacts(
            inspectedSavedPackage: true, partName: "xl/worksheets/sheet2.xml",
            cellTypeAttribute: "n", cellHasFormula: true,
            cellTypeMatchesIntent: true, expectedContentMatches: false)
        XCTAssertEqual(OfficeEditSemanticGate.failure(command: .setCellContent,
                                                      semantic: oldFormula)?.code,
                       "savedCellContentMismatch")
        // A literal intent saved as a numeric cell (00123 silently coerced)
        // refuses on the type gate.
        let coerced = OfficeEditSemanticFacts(
            inspectedSavedPackage: true, partName: "xl/worksheets/sheet2.xml",
            cellTypeAttribute: "n", cellHasFormula: false,
            cellTypeMatchesIntent: false, expectedContentMatches: true)
        XCTAssertEqual(OfficeEditSemanticGate.failure(command: .setCellContent,
                                                      semantic: coerced)?.code,
                       "savedCellTypeMismatch")
    }

    func testContentKindIntentsValidation() throws {
        let (tool, port) = makeTool()
        let ctx = port.contextID
        func cell(_ text: String, _ kind: String?) -> OfficeDocumentEditTool.Arguments {
            .init(action: .apply, command: "setCellContent", text: text, cell: "C3",
                  contentType: kind, editContext: ctx)
        }
        // literal: exact string incl 00123 and a leading '=' (host-encoded).
        XCTAssertNoThrow(try tool.validate(cell("00123", "literal")))
        XCTAssertNoThrow(try tool.validate(cell("=already-text", "literal")))
        // number: finite canonical decimal only; the intent is distinct from
        // the exact-string literal (00123 stays literal unless declared).
        XCTAssertNoThrow(try tool.validate(cell("123", "number")))
        XCTAssertNoThrow(try tool.validate(cell("-12.5", "number")))
        XCTAssertNoThrow(try tool.validate(cell("1.5e3", "number")))
        XCTAssertThrowsError(try tool.validate(cell("12,5", "number")))
        XCTAssertThrowsError(try tool.validate(cell("1e", "number")))
        XCTAssertThrowsError(try tool.validate(cell("NaN", "number")))
        // formula: leading '=' stays mandatory.
        XCTAssertNoThrow(try tool.validate(cell("=SUM(A1:A2)", "formula")))
        XCTAssertThrowsError(try tool.validate(cell("SUM(A1:A2)", "formula")))
    }

    func testNumberGrammarAcceptsOnlyCanonicalFiniteDecimals() {
        for valid in ["0", "123", "00123", "-12.5", "+3", ".5", "1.", "1.5e3", "2E-2"] {
            XCTAssertTrue(OfficeEditLimits.isValidFiniteNumberText(valid), valid)
        }
        for invalid in ["", ".", "1e", "1e+", "0x10", "NaN", "inf", "1 2", "1_000", "12,5",
                        "1\n2", "5.5.5", "--1"] {
            XCTAssertFalse(OfficeEditLimits.isValidFiniteNumberText(invalid), invalid)
        }
    }

    func testApplyWithPresenceOnlyProofFailsClosedWithoutPublication() async throws {
        let conversation = ScriptedPort.Fact.taskID
        let (tool, port) = makeTool(conversation: conversation)
        // nativeCompleted-grade facts: inspected + globally present, but no
        // intended-content match and no trusted proof.
        port.semantic = OfficeEditSemanticFacts(
            inspectedSavedPackage: true, partName: "word/document.xml",
            expectedTextFound: true, occurrenceCount: 1)
        do {
            _ = try await tool.execute(
                .init(action: .apply, command: "applyText", text: "x", editContext: port.contextID),
                context: makeContext(conversation: conversation))
            XCTFail("presence-only proof must fail closed")
        } catch let error as OfficeEditHostError {
            XCTAssertEqual(error.code, "savedContentMismatch")
        }
        XCTAssertTrue(port.recorder.all("publish").isEmpty)
    }

    func testSaveOriginalOnlyWhenExplicitlyRequestedAndReportedSeparately() async throws {
        let conversation = ScriptedPort.Fact.taskID
        let (tool, port) = makeTool(conversation: conversation)
        port.publishReceipt = receipt(callID: "call-1", runID: UUID(), taskID: conversation)
        _ = try await tool.execute(
            .init(action: .apply, command: "applyText", text: "x", editContext: port.contextID),
            context: makeContext(conversation: conversation))
        XCTAssertTrue(port.recorder.all("original").isEmpty, "no original write without an explicit request")
        let run = UUID()
        port.publishReceipt = receipt(callID: "call-1", runID: run, taskID: conversation)
        var withOriginal = OfficeDocumentEditTool.Arguments(action: .apply, command: "applyText",
                                                            text: "x", editContext: port.contextID)
        withOriginal.saveOriginal = true
        _ = try await tool.execute(withOriginal, context: makeContext(conversation: conversation, run: run))
        XCTAssertEqual(port.recorder.all("original").count, 1)
    }

    // MARK: executor-context + temporary fences

    func testBackgroundJobExecutorContextIsRefusedEntirely() async throws {
        let conversation = ScriptedPort.Fact.taskID
        let (tool, port) = makeTool(conversation: conversation)
        do {
            _ = try await tool.execute(.init(action: .read, command: "documentContext"),
                                       context: makeContext(callID: "jobs." + UUID().uuidString,
                                                            conversation: conversation))
            XCTFail("a jobs.* executor context must not execute the tool")
        } catch let error as FloeError {
            guard case .invalidConfiguration = error else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(port.recorder.all("open").isEmpty,
                      "a synthesized jobs context may not dispatch ANY office effect")
    }

    func testTemporaryChatRefused() async throws {
        let conversation = ScriptedPort.Fact.taskID
        let (tool, port) = makeTool(conversation: conversation)
        do {
            _ = try await tool.execute(.init(action: .capabilities),
                                       context: makeContext(conversation: conversation, temporary: true))
            XCTFail("temporary chat must not reach Office effects")
        } catch is FloeError {}
    }

    func testHostLaneDownMeansUnavailableNotSuccess() async throws {
        let conversation = ScriptedPort.Fact.taskID
        let (tool, port) = makeTool(conversation: conversation)
        port.live = false
        do {
            _ = try await tool.execute(.init(action: .read, command: "documentContext"),
                                       context: makeContext(conversation: conversation))
            XCTFail("unavailable lane must throw")
        } catch let error as OfficeEditHostError {
            guard case .hostLaneUnavailable = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: collect against the ORIGINAL durable store (no trust of quoted text)

    func testCollectRefusesForeignConversationWrongTargetAndNonTerminalRows() async throws {
        let mine = ScriptedPort.Fact.taskID
        let other = UUID()
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = BackgroundJobStore(database: database)
        func seed(conversation: UUID, target: String, state: BackgroundJobState) async throws -> UUID {
            var job = BackgroundJob(conversationID: conversation, runID: UUID(), toolCallID: "call-1",
                                    kind: .tool, targetTool: target,
                                    payloadJSON: Data(#"{"action":"apply","command":"applyText","text":"x","editContext":"ctx1"}"#.utf8))
            job = try await store.submit(job)
            if state == .running {
                _ = try await store.transition(id: job.id, to: .running) { row in row.lastError = "fixture" }
            } else if state != .queued {
                // The durable store enforces the REAL state machine:
                // terminal states are only reachable from .running.
                _ = try await store.transition(id: job.id, to: .running)
                _ = try await store.transition(id: job.id, to: state) { row in row.lastError = "fixture" }
            }
            return job.id
        }
        let foreign = await try seed(conversation: other, target: OfficeDocumentEditTool.name, state: .completed)
        let wrongTarget = await try seed(conversation: mine, target: "exec.shell", state: .completed)
        let running = await try seed(conversation: mine, target: OfficeDocumentEditTool.name, state: .running)

        let port = ScriptedPort()
        let service = BackgroundJobService(store: store)
        let tool = OfficeDocumentEditTool(port: port) { service }
        func collect(_ id: UUID) async -> Error? {
            do {
                _ = try await tool.execute(.init(action: .collect, jobID: id.uuidString),
                                           context: makeContext(conversation: mine))
                return nil
            } catch { return error }
        }
        func code(_ error: Error?) -> String? { (error as? OfficeEditHostError)?.code }
        let foreignCode = await collect(foreign)
        let wrongTargetCode = await collect(wrongTarget)
        let runningCode = await collect(running)
        XCTAssertEqual(code(foreignCode), "jobNotOwned")
        XCTAssertEqual(code(wrongTargetCode), "jobWrongTarget")
        XCTAssertEqual(code(runningCode), "jobNotTerminalCompleted")
        XCTAssertTrue(port.recorder.all("publish").isEmpty, "collect may only publish for OWNED completed rows")
    }

    // MARK: amendment/2 historical proof — durable v2 verified summary

    private func makeCollectService() async throws
        -> (store: BackgroundJobStore, service: BackgroundJobService, tool: OfficeDocumentEditTool,
            port: ScriptedPort, mine: UUID) {
        let mine = ScriptedPort.Fact.taskID
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = BackgroundJobStore(database: database)
        let port = ScriptedPort()
        let service = BackgroundJobService(store: store)
        let tool = OfficeDocumentEditTool(port: port) { service }
        return (store, service, tool, port, mine)
    }

    /// Seeds a COMPLETED owned row exactly as the ORIGINAL service settles it,
    /// with the durable result summary the adapter's verified run persisted.
    private func seedCompletedCollectRow(store: BackgroundJobStore, conversation: UUID,
                                         runID: UUID, payload: Data, artifactPath: String,
                                         artifactSHA: String, resultSummary: String,
                                         operationID: String, serviceLabel: String) async throws -> UUID {
        var job = BackgroundJob(conversationID: conversation, runID: runID, toolCallID: "call-jobs",
                                kind: .tool, targetTool: OfficeDocumentEditTool.name,
                                payloadJSON: payload)
        job = try await store.submit(job)
        // The REAL state machine only reaches .completed from .running.
        _ = try await store.transition(id: job.id, to: .running)
        _ = try await store.transition(id: job.id, to: .completed) { row in
            row.resultPath = artifactPath
            row.resultDigest = artifactSHA
            row.resultSummary = resultSummary
            row.progressJSON = NativeJobProgressDocument(prepared: NativeJobPreparationSummary(
                operationID: operationID, serviceLabel: serviceLabel, frozenRevision: nil)).encoded()
        }
        return job.id
    }

    private func xlsxCollectPayload() -> Data {
        Data(#"{"action":"apply","command":"setCellContent","text":"=SUM(A1:A2)","cell":"B4","contentType":"formula","editContext":"ctx1"}"#.utf8)
    }

    func testCollectBindsHistoricalProofToDurableV2TargetSummary() async throws {
        let fixture = try await makeCollectService()
        let mine = fixture.mine
        let payload = xlsxCollectPayload()
        let runID = UUID()
        // Re-derive the ORIGINAL job identity exactly as the adapter persisted it.
        let digest = RuntimeAuthorityDigest.payloadDigest(payload)
        let seed = OfficeEditOperationIdentity.derive(runID: runID, callID: "call-jobs",
                                                      payloadDigest: digest, step: "call")
        let artifactSHA = String(repeating: "d", count: 64)
        let baseline = String(repeating: "b", count: 64)
        var job = BackgroundJob(conversationID: mine, runID: runID, toolCallID: "call-jobs",
                                kind: .tool, targetTool: OfficeDocumentEditTool.name,
                                payloadJSON: payload)
        job = try await fixture.store.submit(job)
        let summary: [String: Any] = [
            "status": "verifiedSaved",
            "ownedV2Target": [
                "operation": "op-fixture",
                "seed": seed,
                "savedSHA256": artifactSHA,
                "format": "xlsx",
                "command": "setCellContent",
                "producerProofVersion": 2,
                "preEditSha256": baseline,
                "partIndex": 1,
            ] as [String: Any],
        ]
        let summaryJSON = String(decoding: try JSONSerialization.data(
            withJSONObject: summary, options: [.sortedKeys]), as: UTF8.self)
        _ = try await fixture.store.transition(id: job.id, to: .running)
        _ = try await fixture.store.transition(id: job.id, to: .completed) { row in
            row.resultPath = "/tmp/floe-office-outputs/7/oa-export-abc.xlsx"
            row.resultDigest = artifactSHA
            row.resultSummary = summaryJSON
            row.progressJSON = NativeJobProgressDocument(prepared: NativeJobPreparationSummary(
                operationID: "op-fixture", serviceLabel: "document.office.edit/xlsx",
                frozenRevision: nil)).encoded()
        }
        fixture.port.snapshot.format = .xlsx
        fixture.port.semantic = OfficeEditSemanticFacts(
            inspectedSavedPackage: true, partName: "xl/worksheets/sheet2.xml",
            cellTypeAttribute: "str", cellHasFormula: true, cellTypeMatchesIntent: true,
            expectedContentMatches: true, proofReused: true)
        let run = UUID()
        fixture.port.publishReceipt = receipt(callID: "call-1", runID: run, taskID: mine)
        let output = try await fixture.tool.execute(
            .init(action: .collect, jobID: job.id.uuidString),
            context: makeContext(conversation: mine, run: run))
        let payloadOut = try json(output)
        XCTAssertEqual(payloadOut["status"] as? String, "collectedVerified")
        XCTAssertEqual(output.outputFiles.count, 1)
        // The historical proof bound the REAL captured logical part from the
        // durable v2 summary — never frozen.slide, never a sheet1 default.
        let inspects = fixture.port.recorder.all("inspect")
        let bound = try XCTUnwrap(inspects.first as? [String: Any])
        XCTAssertEqual((bound["partIndex"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual(bound["mode"] as? String, "completedJob")
        XCTAssertEqual(bound["preEdit"] as? String, baseline)
    }

    func testCollectRefusesOldOrTamperedRowsWithoutDurableV2TargetSummary() async throws {
        let fixture = try await makeCollectService()
        let mine = fixture.mine
        let payload = xlsxCollectPayload()
        let digest = RuntimeAuthorityDigest.payloadDigest(payload)
        let artifactSHA = String(repeating: "d", count: 64)
        let baseline = String(repeating: "b", count: 64)
        // Old v1 row: a completed summary WITHOUT the durable v2 target block.
        let oldRow = try await seedCompletedCollectRow(
            store: fixture.store, conversation: mine, runID: UUID(), payload: payload,
            artifactPath: "/tmp/floe-office-outputs/7/oa-export-old.xlsx",
            artifactSHA: artifactSHA,
            resultSummary: #"{"status":"verifiedSaved"}"#,
            operationID: "op-fixture", serviceLabel: "document.office.edit/xlsx")
        // Tampered row: correct identity, but the persisted digest disagrees
        // with the row's recorded artifact digest.
        let tamperedRun = UUID()
        let tamperedSeed = OfficeEditOperationIdentity.derive(
            runID: tamperedRun, callID: "call-jobs", payloadDigest: digest, step: "call")
        let tamperedSummary = String(decoding: try JSONSerialization.data(withJSONObject: [
            "status": "verifiedSaved",
            "ownedV2Target": [
                "operation": "op-fixture", "seed": tamperedSeed,
                "savedSHA256": String(repeating: "e", count: 64),
                "format": "xlsx", "command": "setCellContent", "producerProofVersion": 2,
                "partIndex": 1,
            ] as [String: Any],
        ], options: [.sortedKeys]), as: UTF8.self)
        let tamperedRow = try await seedCompletedCollectRow(
            store: fixture.store, conversation: mine, runID: tamperedRun, payload: payload,
            artifactPath: "/tmp/floe-office-outputs/7/oa-export-tampered.xlsx",
            artifactSHA: artifactSHA,
            resultSummary: tamperedSummary,
            operationID: "op-fixture", serviceLabel: "document.office.edit/xlsx")
        // A v2 row whose captured part metadata is absent for an xlsx target.
        let noPartRun = UUID()
        let noPartSeed = OfficeEditOperationIdentity.derive(
            runID: noPartRun, callID: "call-jobs", payloadDigest: digest, step: "call")
        let noPartSummary = String(decoding: try JSONSerialization.data(withJSONObject: [
            "status": "verifiedSaved",
            "ownedV2Target": [
                "operation": "op-fixture", "seed": noPartSeed, "savedSHA256": artifactSHA,
                "format": "xlsx", "command": "setCellContent", "producerProofVersion": 2,
            ] as [String: Any],
        ], options: [.sortedKeys]), as: UTF8.self)
        let noPartRow = try await seedCompletedCollectRow(
            store: fixture.store, conversation: mine, runID: noPartRun, payload: payload,
            artifactPath: "/tmp/floe-office-outputs/7/oa-export-nopart.xlsx",
            artifactSHA: artifactSHA,
            resultSummary: noPartSummary,
            operationID: "op-fixture", serviceLabel: "document.office.edit/xlsx")
        fixture.port.snapshot.format = .xlsx
        fixture.port.semantic = OfficeEditSemanticFacts(
            inspectedSavedPackage: true, partName: "xl/worksheets/sheet2.xml",
            cellTypeAttribute: "str", cellHasFormula: true, cellTypeMatchesIntent: true,
            expectedContentMatches: true, proofReused: true)
        func collect(_ id: UUID) async -> String? {
            do {
                _ = try await fixture.tool.execute(.init(action: .collect, jobID: id.uuidString),
                                                   context: makeContext(conversation: mine))
                return nil
            } catch let error as OfficeEditHostError {
                return error.code
            } catch {
                return "unexpected"
            }
        }
        let oldRowCode = await collect(oldRow)
        let tamperedRowCode = await collect(tamperedRow)
        let noPartRowCode = await collect(noPartRow)
        XCTAssertEqual(oldRowCode, "jobV2TargetUnproven",
                       "an old v1 row must never qualify historical reuse")
        XCTAssertEqual(tamperedRowCode, "jobV2TargetUnproven",
                       "a digest-tampered v2 summary must not qualify historical reuse")
        XCTAssertEqual(noPartRowCode, "jobV2TargetUnproven",
                       "an xlsx target without captured part metadata stays refused")
        XCTAssertTrue(fixture.port.recorder.all("inspect").isEmpty,
                      "no host inspection may run for an unvalidated historical row")
        XCTAssertTrue(fixture.port.recorder.all("publish").isEmpty,
                      "no unproven historical row may publish")
    }

    // MARK: display name

    func testCollectedDisplayNameIsBoundedAndSafe() {
        let name = OfficeDocumentEditTool.collectedDisplayName(
            artifactPath: "/var/floe-office-outputs/7/oa-export-123abc.docx", format: .docx)
        XCTAssertTrue(name.hasSuffix(".edited.docx"), name)
        XCTAssertTrue(RunOutputFile.isValidDisplayName(name), name)
    }

    // MARK: seed stability (engine-opId replay protection at the derivation layer)

    func testStageOpIdsAreDeterministicPerSeedAndStageScoped() {
        let seed = OfficeEditOperationIdentity.derive(runID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                                                     callID: "call-9",
                                                     payloadDigest: String(repeating: "f", count: 64),
                                                     step: "call")
        XCTAssertTrue(OfficeEditOperationIdentity.isValid(seed))
        let apply1 = OfficeEditOperationIdentity.stageOpId(seed: seed, stage: "apply")
        let apply2 = OfficeEditOperationIdentity.stageOpId(seed: seed, stage: "apply")
        let export1 = OfficeEditOperationIdentity.stageOpId(seed: seed, stage: "export")
        XCTAssertEqual(apply1, apply2, "the same call+payload retry must reuse the SAME effect identity")
        XCTAssertNotEqual(apply1, export1)
        XCTAssertTrue(OfficeEditOperationIdentity.isValid(apply1))
        XCTAssertLessThanOrEqual(apply1.count, 64)
    }
}
