// FloeOfficeAutomationQualification — native macOS proof for the T4 Office
// automation and native-job adapters. Synthetic fixtures only; no engine
// binary, no user content.

import Foundation
import FloeCore
import FloeTools
import FloeDocuments
import FloePersistence
import FloeExecution
import FloeMedia

// MARK: - Fixture-backed fake engine session

/// Programmable service-owned engine stand-in. It never fakes verification:
/// the executor still reopens and checks whatever bytes this session leaves
/// on the working copy.
actor QualificationSession: OfficeServiceEngineSession {
    nonisolated let workingCopyURL: URL
    nonisolated let engineLabel = "qualification-fixture-engine"
    private let plan: @Sendable (URL) throws -> Void
    private let editable: Bool
    private(set) var appliedBatches = 0
    private(set) var closed = false

    func isClosed() -> Bool { closed }

    init(workingCopyURL: URL, editable: Bool = true,
         plan: @escaping @Sendable (URL) throws -> Void) {
        self.workingCopyURL = workingCopyURL
        self.editable = editable
        self.plan = plan
    }

    func status() async throws -> OfficeServiceSessionStatus {
        OfficeServiceSessionStatus(editable: editable,
                                   unavailableReason: editable ? nil : "qualification read-only")
    }

    func apply(commands: [OfficeEngineCommand], batchID: String) async throws {
        appliedBatches += 1
        try plan(workingCopyURL)
    }

    func save() async throws {}

    func close() async throws { closed = true }
}

final class QualificationFactory: OfficeServiceEngineSessionFactory, @unchecked Sendable {
    private let plan: @Sendable (URL) throws -> Void
    private let editable: Bool
    private(set) var opens = 0
    private(set) var sessions: [QualificationSession] = []

    init(editable: Bool = true, plan: @escaping @Sendable (URL) throws -> Void) {
        self.editable = editable
        self.plan = plan
    }

    func openServiceSession(workingCopyURL: URL, format: OfficeDocumentFormat,
                            originalURL: URL,
                            access: OfficeCommandAccess) async throws -> any OfficeServiceEngineSession {
        opens += 1
        let session = QualificationSession(workingCopyURL: workingCopyURL, editable: editable, plan: plan)
        sessions.append(session)
        return session
    }

    func verifyEngineReopen(savedCopyURL: URL, format: OfficeDocumentFormat,
                            access: OfficeCommandAccess) async -> OfficeEngineReopenEvidence {
        .unavailable(reason: "qualification host has no engine binary")
    }
}

// MARK: - Tool host (authority gate proof)

actor QualificationOfficeHost: OfficeCommandHost {
    private var proposals: [UUID: OfficeCommandProposal] = [:]
    private var accessByProposal: [UUID: OfficeCommandAccess] = [:]
    private let executor: OfficeAutomaticExecutor
    private(set) var automaticCalls = 0

    init(executor: OfficeAutomaticExecutor) { self.executor = executor }

    func authorizeAccess(_ access: OfficeCommandAccess) async throws {
        guard access.workspacePath?.isEmpty == false else { throw FloeError.unauthorized }
    }
    func status(documentID: String, access: OfficeCommandAccess) async throws -> OfficeLiveStatus {
        OfficeLiveStatus(documentID: documentID, format: "xlsx",
                         revisionSHA256: String(repeating: "0", count: 64),
                         liveSession: false, editable: false, readOnlyReason: "service session only")
    }
    func prepareProposal(documentID: String, baseSHA256: String, summary: String,
                         commandsJSON: String, access: OfficeCommandAccess) async throws -> OfficeCommandProposal {
        OfficeCommandProposal(documentID: documentID, format: "xlsx", baseSHA256: baseSHA256,
                              summary: summary, commandsJSON: commandsJSON, expectations: [])
    }
    func storeProposal(_ proposal: OfficeCommandProposal) async throws { proposals[proposal.id] = proposal }
    func loadProposal(id: UUID, access: OfficeCommandAccess) async throws -> OfficeCommandProposal? {
        proposals[id]
    }
    func verifyProposalBinding(_ proposal: OfficeCommandProposal, documentID: String,
                               access: OfficeCommandAccess) async throws {
        guard accessByProposal[proposal.id] == access else { throw FloeError.unauthorized }
    }
    func removeProposal(id: UUID) async throws { proposals[id] = nil }
    func consumeGrant(grantID: String, proposalID: UUID, documentID: String,
                      sha256: String) async -> OfficeGrantDecision { .unknownGrant }
    func apply(proposal: OfficeCommandProposal, grantID: String, requestID: String,
               access: OfficeCommandAccess) async throws -> OfficeCommandReceipt {
        throw FloeError.validationFailed("interactive path is not part of this qualification")
    }
    func export(documentID: String, relativeOutput: String,
                access: OfficeCommandAccess) async throws -> OfficeExportReceipt {
        throw FloeError.validationFailed("export is not part of this qualification")
    }
    func applyAutomatic(proposal: OfficeCommandProposal,
                        authorization: OfficeAutomaticAuthorization,
                        relativeOutput: String?,
                        requestID: String,
                        access: OfficeCommandAccess) async throws -> OfficeAutomaticReceipt {
        automaticCalls += 1
        return try await executor.execute(proposal: proposal, authorization: authorization,
                                          relativeOutput: relativeOutput, requestID: requestID,
                                          access: access)
    }
    func seed(_ proposal: OfficeCommandProposal, access: OfficeCommandAccess) {
        proposals[proposal.id] = proposal
        accessByProposal[proposal.id] = access
    }
}


// MARK: - Prepared-job adapter fixtures

actor QualificationCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

/// Frozen service-owned operation for one authorized Office apply submitted
/// through jobs.submit. This is the exact shape the app adapter uses: the
/// concrete proposal/revision/binding were frozen at submission and the run
/// only executes + verifies them.
final class QualificationAuthorizedApplyOperation: NativeJobPreparedOperation, @unchecked Sendable {
    let operationID: String
    let frozenRevision: String?
    let serviceLabel = "office-automatic"

    private let host: QualificationOfficeHost
    private let proposal: OfficeCommandProposal
    private let access: OfficeCommandAccess
    private let submitBinding: RuntimeAuthorityBinding
    private let requestID: String
    private let relativeOutput: String
    private(set) var receiptSHA: String?

    init(host: QualificationOfficeHost, proposal: OfficeCommandProposal,
         access: OfficeCommandAccess, submitBinding: RuntimeAuthorityBinding,
         requestID: String, relativeOutput: String) {
        self.host = host
        self.proposal = proposal
        self.access = access
        self.submitBinding = submitBinding
        self.requestID = requestID
        self.relativeOutput = relativeOutput
        self.operationID = requestID
        self.frozenRevision = proposal.baseSHA256
    }

    func run(hooks: NativeJobRunHooks) async throws -> NativeJobOutcome {
        await hooks.report(NativeJobProgress(stage: .running, phase: "engine-session",
                                             completedUnits: 1, totalUnits: 3))
        let authorization = OfficeAutomaticAuthorization(
            runID: submitBinding.runID,
            taskID: submitBinding.taskID,
            operationID: submitBinding.operationID,
            idempotencyKey: submitBinding.idempotencyKey,
            approvalGrantID: nil,
            binding: submitBinding,
            origin: .approvedBackgroundJob(submitBinding: submitBinding))
        let receipt = try await host.applyAutomatic(
            proposal: proposal, authorization: authorization,
            relativeOutput: relativeOutput, requestID: requestID, access: access)
        receiptSHA = receipt.outputSHA256
        await hooks.report(NativeJobProgress(stage: .verifying, phase: "reopened-copy",
                                             completedUnits: 3, totalUnits: 3))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: (try? encoder.encode(receipt)) ?? Data("{}".utf8), as: UTF8.self)
        // The published copy is a REAL absolute file; a relative path would
        // (correctly) fail the job service's existence re-check.
        let artifact = access.workspacePath.map {
            ($0 as NSString).appendingPathComponent(receipt.outputRelativePath)
        }
        return NativeJobOutcome(
            summary: "status=applied mode=background-job replay=\(receipt.replay) \n\(json)",
            digest: receipt.outputSHA256,
            verified: receipt.verified,
            artifactPath: artifact,
            frozenRevision: receipt.baseSHA256)
    }

    func requestCancellation() async {}
}

/// Fixture engine for the media job progress case. It reports REAL units
/// through the request's progress callback and writes the expected output; it
/// never performs inference (labeled fixture processor).
final class QualificationFrameProcessing: FrameProcessing, @unchecked Sendable {
    private(set) var sawWorkspaceRoot: URL?

    func interpolate(input: URL, output: URL, targetFPS: Double, mode: String, modelID: String?) async throws -> String {
        try Data("fixture".utf8).write(to: output)
        return "engine=qualification-fixture mode=\(mode) targetFPS=\(targetFPS)"
    }

    func superResolution(input: URL, output: URL, scaleFactor: Int, mode: String, modelID: String?) async throws -> String {
        try Data("fixture".utf8).write(to: output)
        return "engine=qualification-fixture mode=\(mode) scale=\(scaleFactor)"
    }

    func process(_ request: FrameProcessingRequest) async throws -> String {
        sawWorkspaceRoot = request.workspaceRoot
        request.progress(MediaEnhancementProgress(phase: .preflight, completedUnits: 0, totalUnits: 10))
        request.progress(MediaEnhancementProgress(phase: .processing, completedUnits: 3, totalUnits: 10))
        try Data("fixture-interpolated".utf8).write(to: request.output)
        return "engine=qualification-fixture workspace=\(request.workspaceRoot?.lastPathComponent ?? "missing")"
    }
}

// MARK: - Qualification

struct CaseResult: Codable {
    var name: String
    var status: String
    var facts: [String]
}

struct FinalReport: Codable {
    var schema: String
    var generatedAt: String
    var host: String
    var fixtureDigests: [String: String]
    var cases: [CaseResult]
    var passed: Int
    var failed: Int
}

@main
struct OfficeAutomationQualification {
    static func main() async {
        let arguments = CommandLine.arguments
        let workRoot: URL
        if arguments.count > 1 {
            workRoot = URL(fileURLWithPath: arguments[1], isDirectory: true)
        } else {
            workRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("floe-office-qualification-\(UUID().uuidString)", isDirectory: true)
        }
        do {
            try FileManager.default.createDirectory(at: workRoot, withIntermediateDirectories: true)
        } catch {
            print("cannot create work directory: \(error)")
            exit(2)
        }
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Sources/FloeOfficeAutomationQualification
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // OfficeAutomation
            .appendingPathComponent("Fixtures", isDirectory: true)

        var cases: [CaseResult] = []
        var fixtureDigests: [String: String] = [:]
        for name in ["sheet-source.xlsx", "sheet-after-two-rows.xlsx",
                     "calc-stale.xlsx", "calc-recalculated.xlsx"] {
            if let digest = try? FloeDigest.sha256Hex(ofFileAt: fixtures.appendingPathComponent(name)) {
                fixtureDigests[name] = digest
            }
        }

        // Every run uses a fresh subdirectory so an earlier run's published
        // copies can never masquerade as this run's replay evidence.
        let runRoot = workRoot.appendingPathComponent("run-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: true)
        cases.append(await automaticCopyVerified(workRoot: runRoot, fixtures: fixtures))
        cases.append(await selectionRelativeRefused(workRoot: runRoot, fixtures: fixtures))
        cases.append(await staleRecalcRefused(workRoot: runRoot, fixtures: fixtures))
        cases.append(await freshRecalcVerified(workRoot: runRoot, fixtures: fixtures))
        cases.append(await outputConflictRefused(workRoot: runRoot, fixtures: fixtures))
        cases.append(await replayIdempotent(workRoot: runRoot, fixtures: fixtures))
        cases.append(await toolAuthorityGate(workRoot: runRoot, fixtures: fixtures))
        cases.append(await jobAdmissionAndPreflight(workRoot: runRoot))
        cases.append(await authorizedApplyBackgroundJob(workRoot: runRoot, fixtures: fixtures))
        cases.append(await mediaJobProgress(workRoot: runRoot))

        let report = FinalReport(
            schema: "floe-office-automation-qualification/1",
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            host: ProcessInfo.processInfo.operatingSystemVersionString,
            fixtureDigests: fixtureDigests,
            cases: cases,
            passed: cases.filter { $0.status == "passed" }.count,
            failed: cases.filter { $0.status != "passed" }.count)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(report) {
            try? data.write(to: workRoot.appendingPathComponent("qualification-final.json"), options: .atomic)
            print(String(decoding: data, as: UTF8.self))
        }
        if report.failed > 0 { exit(1) }
    }

    // MARK: Cases

    private static func fixture(_ name: String, in fixtures: URL, workRoot: URL,
                                as destination: String) throws -> URL {
        let url = workRoot.appendingPathComponent(destination)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent(name), to: url)
        return url
    }

    private static func proof(runID: UUID = UUID(), taskID: UUID = UUID(),
                              binding: RuntimeAuthorityBinding) -> OfficeAutomaticAuthorization {
        OfficeAutomaticAuthorization(runID: runID, taskID: taskID, operationID: "qual-call",
                                     idempotencyKey: "qual-key", approvalGrantID: UUID(),
                                     binding: binding)
    }

    private static func binding(target: String) -> RuntimeAuthorityBinding {
        RuntimeAuthorityBinding(runID: UUID(), taskID: UUID(), environmentBinding: "qual",
                                canonicalTarget: target, toolName: "document.office.edit",
                                operation: "apply", operationID: "qual-call",
                                idempotencyKey: "qual-key", baseRevision: nil,
                                payloadDigest: String(repeating: "a", count: 64))
    }

    private static func access(_ root: URL) -> OfficeCommandAccess {
        OfficeCommandAccess(environmentID: "qual", workspacePath: root.path,
                            ownerKind: "chat", ownerID: UUID(), conversationID: UUID())
    }

    private static func proposal(document: String, sha: String,
                                 commands: [OfficeEngineCommand]) throws -> OfficeCommandProposal {
        OfficeCommandProposal(documentID: document, format: "xlsx", baseSHA256: sha,
                              summary: "qualification", commandsJSON: try OfficeCommandCodec.encode(commands),
                              expectations: OfficeCommandCodec.expectations(commands))
    }

    private static func automaticCopyVerified(workRoot: URL, fixtures: URL) async -> CaseResult {
        let name = "automatic-copy-verified"
        do {
            let source = try fixture("sheet-source.xlsx", in: fixtures, workRoot: workRoot,
                                     as: "copy-source.xlsx")
            let sha = try FloeDigest.sha256Hex(ofFileAt: source)
            let after = fixtures.appendingPathComponent("sheet-after-two-rows.xlsx")
            let factory = QualificationFactory { working in
                try? FileManager.default.removeItem(at: working)
                try FileManager.default.copyItem(at: after, to: working)
            }
            let executor = OfficeAutomaticExecutor(factory: factory)
            let receipt = try await executor.execute(
                proposal: try proposal(document: "copy-source.xlsx", sha: sha,
                                       commands: [.excelInsertRows(count: 1, at: "A1")]),
                authorization: proof(binding: binding(target: "qual")),
                relativeOutput: "copy-verified.xlsx", requestID: "qual-copy",
                access: access(workRoot))
            let sourceAfter = try FloeDigest.sha256Hex(ofFileAt: source)
            let output = workRoot.appendingPathComponent("copy-verified.xlsx")
            let outputSHA = try FloeDigest.sha256Hex(ofFileAt: output)
            var facts = ["sourceUnchanged=\(sourceAfter == sha)",
                         "outputSHA=\(outputSHA.prefix(12))",
                         "verifiedFacts=\(receipt.verified.joined(separator: ","))"]
            guard sourceAfter == sha else { facts.append("FAIL source mutated"); return CaseResult(name: name, status: "failed", facts: facts) }
            guard receipt.saved, outputSHA == receipt.outputSHA256 else {
                facts.append("FAIL receipt/output digest mismatch")
                return CaseResult(name: name, status: "failed", facts: facts)
            }
            let snapshot = try OfficeOutputSnapshot.capture(url: output)
            guard snapshot.sheetRowCounts.first == 2 else {
                facts.append("FAIL reopened row count \(snapshot.sheetRowCounts.first ?? -1)")
                return CaseResult(name: name, status: "failed", facts: facts)
            }
            guard await factory.sessions.first?.isClosed() == true else {
                facts.append("FAIL session not released")
                return CaseResult(name: name, status: "failed", facts: facts)
            }
            return CaseResult(name: name, status: "passed", facts: facts)
        } catch {
            return CaseResult(name: name, status: "failed", facts: ["error=\(error)"])
        }
    }

    private static func selectionRelativeRefused(workRoot: URL, fixtures: URL) async -> CaseResult {
        let name = "selection-relative-refused"
        do {
            let source = try fixture("sheet-source.xlsx", in: fixtures, workRoot: workRoot,
                                     as: "selection-source.xlsx")
            let sha = try FloeDigest.sha256Hex(ofFileAt: source)
            let factory = QualificationFactory { _ in }
            let executor = OfficeAutomaticExecutor(factory: factory)
            do {
                _ = try await executor.execute(
                    proposal: try proposal(document: "selection-source.xlsx", sha: sha,
                                           commands: [.excelSort(ascending: true, range: "A1:A2")]),
                    authorization: proof(binding: binding(target: "qual")),
                    relativeOutput: nil, requestID: "qual-sort", access: access(workRoot))
                return CaseResult(name: name, status: "failed", facts: ["no refusal was raised"])
            } catch let error as OfficeAutomaticExecutionError {
                let facts = ["refusal=\(error)", "sessionOpens=\(factory.opens)"]
                return CaseResult(name: name, status: factory.opens == 0 ? "passed" : "failed", facts: facts)
            }
        } catch {
            return CaseResult(name: name, status: "failed", facts: ["error=\(error)"])
        }
    }

    private static func staleRecalcRefused(workRoot: URL, fixtures: URL) async -> CaseResult {
        let name = "recalc-stale-refused"
        do {
            let source = try fixture("calc-stale.xlsx", in: fixtures, workRoot: workRoot,
                                     as: "recalc-stale.xlsx")
            let sha = try FloeDigest.sha256Hex(ofFileAt: source)
            // The engine saves the SAME stale bytes: verification must refuse.
            let factory = QualificationFactory { _ in }
            let executor = OfficeAutomaticExecutor(factory: factory)
            do {
                _ = try await executor.execute(
                    proposal: try proposal(document: "recalc-stale.xlsx", sha: sha,
                                           commands: [.excelRecalculate]),
                    authorization: proof(binding: binding(target: "qual")),
                    relativeOutput: "recalc-stale-edited.xlsx", requestID: "qual-stale",
                    access: access(workRoot))
                return CaseResult(name: name, status: "failed", facts: ["stale cache was accepted"])
            } catch let error as OfficeAutomaticExecutionError {
                let outputExists = FileManager.default.fileExists(
                    atPath: workRoot.appendingPathComponent("recalc-stale-edited.xlsx").path)
                return CaseResult(name: name, status: outputExists ? "failed" : "passed",
                                  facts: ["refusal=\(error)", "outputWritten=\(outputExists)"])
            }
        } catch {
            return CaseResult(name: name, status: "failed", facts: ["error=\(error)"])
        }
    }

    private static func freshRecalcVerified(workRoot: URL, fixtures: URL) async -> CaseResult {
        let name = "recalc-fresh-verified"
        do {
            let source = try fixture("calc-stale.xlsx", in: fixtures, workRoot: workRoot,
                                     as: "recalc-fresh.xlsx")
            let sha = try FloeDigest.sha256Hex(ofFileAt: source)
            let after = fixtures.appendingPathComponent("calc-recalculated.xlsx")
            let factory = QualificationFactory { working in
                try? FileManager.default.removeItem(at: working)
                try FileManager.default.copyItem(at: after, to: working)
            }
            let executor = OfficeAutomaticExecutor(factory: factory)
            let receipt = try await executor.execute(
                proposal: try proposal(document: "recalc-fresh.xlsx", sha: sha,
                                       commands: [.excelRecalculate]),
                authorization: proof(binding: binding(target: "qual")),
                relativeOutput: "recalc-fresh-edited.xlsx", requestID: "qual-fresh",
                access: access(workRoot))
            let sourceAfter = try FloeDigest.sha256Hex(ofFileAt: source)
            var facts = ["formulaSummary=\(receipt.formulaSummary ?? "none")",
                         "sourceUnchanged=\(sourceAfter == sha)"]
            guard receipt.formulaSummary?.contains("verified=1") == true, sourceAfter == sha else {
                facts.append("FAIL")
                return CaseResult(name: name, status: "failed", facts: facts)
            }
            let output = workRoot.appendingPathComponent("recalc-fresh-edited.xlsx")
            let snapshot = try OfficeOutputSnapshot.capture(url: output)
            let report = OfficeFormulaVerifier.verify(snapshot: snapshot)
            facts.append("reopenedFormulaClean=\(report.isClean)")
            return CaseResult(name: name, status: report.isClean ? "passed" : "failed", facts: facts)
        } catch {
            return CaseResult(name: name, status: "failed", facts: ["error=\(error)"])
        }
    }

    private static func outputConflictRefused(workRoot: URL, fixtures: URL) async -> CaseResult {
        let name = "output-conflict-refused"
        do {
            let source = try fixture("sheet-source.xlsx", in: fixtures, workRoot: workRoot,
                                     as: "conflict-source.xlsx")
            let sha = try FloeDigest.sha256Hex(ofFileAt: source)
            let existing = workRoot.appendingPathComponent("conflict-output.xlsx")
            try Data("existing user bytes".utf8).write(to: existing)
            let factory = QualificationFactory { _ in }
            let executor = OfficeAutomaticExecutor(factory: factory)
            do {
                _ = try await executor.execute(
                    proposal: try proposal(document: "conflict-source.xlsx", sha: sha,
                                           commands: [.excelInsertRows(count: 1, at: "A1")]),
                    authorization: proof(binding: binding(target: "qual")),
                    relativeOutput: "conflict-output.xlsx", requestID: "qual-conflict",
                    access: access(workRoot))
                return CaseResult(name: name, status: "failed", facts: ["conflict was accepted"])
            } catch {
                let preserved = (try? Data(contentsOf: existing)) == Data("existing user bytes".utf8)
                return CaseResult(name: name, status: preserved ? "passed" : "failed",
                                  facts: ["refusal=\(error)", "existingPreserved=\(preserved)"])
            }
        } catch {
            return CaseResult(name: name, status: "failed", facts: ["error=\(error)"])
        }
    }

    private static func replayIdempotent(workRoot: URL, fixtures: URL) async -> CaseResult {
        let name = "replay-idempotent"
        do {
            let source = try fixture("sheet-source.xlsx", in: fixtures, workRoot: workRoot,
                                     as: "replay-source.xlsx")
            let sha = try FloeDigest.sha256Hex(ofFileAt: source)
            let after = fixtures.appendingPathComponent("sheet-after-two-rows.xlsx")
            let factory = QualificationFactory { working in
                try? FileManager.default.removeItem(at: working)
                try FileManager.default.copyItem(at: after, to: working)
            }
            let executor = OfficeAutomaticExecutor(factory: factory)
            let request = try proposal(document: "replay-source.xlsx", sha: sha,
                                       commands: [.excelInsertRows(count: 1, at: "A1")])
            let first = try await executor.execute(proposal: request,
                                                   authorization: proof(binding: binding(target: "qual")),
                                                   relativeOutput: "replay-edited.xlsx",
                                                   requestID: "qual-replay", access: access(workRoot))
            let second = try await executor.execute(proposal: request,
                                                    authorization: proof(binding: binding(target: "qual")),
                                                    relativeOutput: "replay-edited.xlsx",
                                                    requestID: "qual-replay", access: access(workRoot))
            let facts = ["firstReplay=\(first.replay)", "secondReplay=\(second.replay)",
                         "sessionOpens=\(factory.opens)",
                         "digestStable=\(first.outputSHA256 == second.outputSHA256)"]
            let passed = !first.replay && second.replay && factory.opens == 1
                && first.outputSHA256 == second.outputSHA256
            return CaseResult(name: name, status: passed ? "passed" : "failed", facts: facts)
        } catch {
            return CaseResult(name: name, status: "failed", facts: ["error=\(error)"])
        }
    }

    private static func toolAuthorityGate(workRoot: URL, fixtures: URL) async -> CaseResult {
        let name = "tool-authority-gate"
        do {
            let source = try fixture("sheet-source.xlsx", in: fixtures, workRoot: workRoot,
                                     as: "gate-source.xlsx")
            let sha = try FloeDigest.sha256Hex(ofFileAt: source)
            let after = fixtures.appendingPathComponent("sheet-after-two-rows.xlsx")
            let factory = QualificationFactory { working in
                try? FileManager.default.removeItem(at: working)
                try FileManager.default.copyItem(at: after, to: working)
            }
            let executor = OfficeAutomaticExecutor(factory: factory)
            let host = QualificationOfficeHost(executor: executor)
            let tool = OfficeEditTool(host: host, workspaceRoot: { workRoot })
            let conversationID = UUID()
            // Exactly what OfficeEditTool.access(from:) derives from the tool
            // context used below (no environment id in this host).
            let access = OfficeCommandAccess(environmentID: nil, workspacePath: workRoot.path,
                                             ownerKind: "chat", ownerID: conversationID,
                                             conversationID: conversationID)
            let commandsJSON = try OfficeCommandCodec.encode([.excelInsertRows(count: 1, at: "A1")])
            let proposal = OfficeCommandProposal(documentID: "gate-source.xlsx", format: "xlsx",
                                                 baseSHA256: sha, summary: "gate",
                                                 commandsJSON: commandsJSON, expectations: [])
            await host.seed(proposal, access: access)
            let argsJSON = Data("""
            {"action":"apply","proposal_id":"\(proposal.id.uuidString.lowercased())","output":"gate-edited.xlsx"}
            """.utf8)
            let args = try JSONDecoder().decode(OfficeEditArguments.self, from: argsJSON)
            // 1. Without any runtime authority: refused, no host effect.
            let unauthenticated = try await tool.execute(args, context: ToolContext(
                runID: UUID(), toolCallID: "qual-gate", workspaceRootURL: workRoot,
                cancellation: CancellationToken(), conversationID: conversationID))
            let noEffect = await host.automaticCalls == 0
            // 2. With a real minted token for this exact call: succeeds.
            let runID = UUID(), grantID = UUID()
            let payload = try OfficeEditTool.canonicalApprovedPayload(args)
            let evidence = RuntimeAuthorityEvidence(
                runID: runID, taskID: conversationID,
                environmentBinding: RuntimeAuthorityDigest.environmentBinding(
                    workspaceRootURL: workRoot, conversationID: conversationID),
                canonicalTarget: OfficeEditTool.canonicalTarget(for: args, workspaceRoot: workRoot),
                toolName: OfficeEditTool.name, operation: "apply", operationID: "qual-gate",
                idempotencyKey: "qual-gate-key", baseRevision: nil,
                payloadDigest: RuntimeAuthorityDigest.payloadDigest(payload),
                approvalGrantID: grantID)
            let token = await RuntimeAuthorityStore.shared.issue(evidence)
            let context = ToolContext(runID: runID, toolCallID: "qual-gate",
                                      toolIdempotencyKey: "qual-gate-key",
                                      approvalGrantID: grantID, workspaceRootURL: workRoot,
                                      cancellation: CancellationToken(),
                                      conversationID: conversationID, runtimeAuthority: token)
            let authorized = try await tool.execute(args, context: context)
            let facts = ["unauthenticatedExit=\(unauthenticated.exitStatus)",
                         "noEffectWithoutAuthority=\(noEffect)",
                         "authorizedExit=\(authorized.exitStatus)",
                         "authorizedAutomatic=calls(\(await host.automaticCalls))"]
            let sourceUnchanged = (try FloeDigest.sha256Hex(ofFileAt: source)) == sha
            let passed = unauthenticated.exitStatus == 2 && noEffect
                && authorized.exitStatus == 0 && authorized.summary.contains("mode=automatic-copy")
                && sourceUnchanged
            return CaseResult(name: name, status: passed ? "passed" : "failed", facts: facts)
        } catch {
            return CaseResult(name: name, status: "failed", facts: ["error=\(error)"])
        }
    }

    private static func jobAdmissionAndPreflight(workRoot: URL) async -> CaseResult {
        let name = "native-job-admission-preflight"
        do {
            let database = try DatabaseManager.inMemory()
            try await database.migrate()
            let conversation = UUID(), runID = UUID()
            let now = ISO8601DateFormatter().string(from: Date())
            try await database.writer { db in
                try db.execute(sql: """
                    INSERT INTO conversations (id, title, created_at, updated_at)
                    VALUES (?, 'Qualification', ?, ?)
                    """, arguments: [conversation.uuidString, now, now])
                try db.execute(sql: """
                    INSERT INTO runs (id, conversation_id, state, goal, started_at)
                    VALUES (?, ?, 'running', 'Qualification', ?)
                    """, arguments: [runID.uuidString, conversation.uuidString, now])
            }
            let registry = ToolRunnerRegistry()
            registry.register(AnyAgentTool(descriptor: ToolCatalog.Descriptor(
                name: "video.interpolate", toolDescription: "qualification", parametersJSON: #"{"type":"object"}"#,
                riskLabels: [], isSideEffecting: true, effect: .mutating
            )) { _, _ in ToolExecutionOutput(summary: "qualification ran", fullOutputSHA256: "d") })
            let service = BackgroundJobService(store: BackgroundJobStore(database: database),
                                               registry: registry)
            // media.project apply is not admitted.
            var applyRefused = false
            do {
                _ = try await service.submit(runID: runID, toolCallID: "qual-a",
                                             targetTool: "media.project",
                                             payloadJSON: Data(#"{"action":"apply","project_id":"x"}"#.utf8),
                                             scope: .local, workspaceRootURL: workRoot,
                                             allowedWorkspacePaths: [], submissionSource: .nativeService)
            } catch { applyRefused = true }
            // A stale declared revision is refused before persistence.
            let input = workRoot.appendingPathComponent("clip.mp4")
            try Data("qualification media bytes".utf8).write(to: input)
            var staleRefused = false
            do {
                _ = try await service.submit(
                    runID: runID, toolCallID: "qual-b", targetTool: "video.interpolate",
                    payloadJSON: Data(#"{"input":"clip.mp4","output":"out.mp4","targetFPS":60,"mode":"quality","expectedSHA256":"\#(String(repeating: "b", count: 64))"}"#.utf8),
                    scope: .local, workspaceRootURL: workRoot, allowedWorkspacePaths: [],
                    submissionSource: .nativeService)
            } catch { staleRefused = true }
            let inputSHA = try FloeDigest.sha256Hex(ofFileAt: input)
            let job = try await service.submit(
                runID: runID, toolCallID: "qual-c", targetTool: "video.interpolate",
                payloadJSON: Data(#"{"input":"clip.mp4","output":"out.mp4","targetFPS":60,"mode":"quality","expectedSHA256":"\#(inputSHA)"}"#.utf8),
                scope: .local, workspaceRootURL: workRoot, allowedWorkspacePaths: [],
                environmentID: "qual-env", submissionSource: .nativeService)
            var terminal: BackgroundJob?
            for _ in 0..<100 {
                if let current = try await service.job(id: job.id), current.state.isTerminal {
                    terminal = current
                    break
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            let facts = ["applyRefused=\(applyRefused)", "staleRevisionRefused=\(staleRefused)",
                         "jobState=\(terminal?.state.rawValue ?? "unknown")",
                         "frozenWorkspace=\(terminal?.workspaceRootPath == workRoot.path)"]
            let passed = applyRefused && staleRefused && terminal?.state == .completed
                && terminal?.workspaceRootPath == workRoot.path
            return CaseResult(name: name, status: passed ? "passed" : "failed", facts: facts)
        } catch {
            return CaseResult(name: name, status: "failed", facts: ["error=\(error)"])
        }
    }

    private static func authorizedApplyBackgroundJob(workRoot: URL, fixtures: URL) async -> CaseResult {
        let name = "authorized-apply-background-job"
        do {
            let database = try DatabaseManager.inMemory()
            try await database.migrate()
            let conversation = UUID(), runID = UUID()
            let now = ISO8601DateFormatter().string(from: Date())
            try await database.writer { db in
                try db.execute(sql: """
                    INSERT INTO conversations (id, title, created_at, updated_at)
                    VALUES (?, 'Qualification', ?, ?)
                    """, arguments: [conversation.uuidString, now, now])
                try db.execute(sql: """
                    INSERT INTO runs (id, conversation_id, state, goal, started_at)
                    VALUES (?, ?, 'running', 'Qualification', ?)
                    """, arguments: [runID.uuidString, conversation.uuidString, now])
            }
            let source = try fixture("sheet-source.xlsx", in: fixtures, workRoot: workRoot,
                                     as: "job-source.xlsx")
            let sha = try FloeDigest.sha256Hex(ofFileAt: source)
            let after = fixtures.appendingPathComponent("sheet-after-two-rows.xlsx")
            let factory = QualificationFactory { working in
                try? FileManager.default.removeItem(at: working)
                try? FileManager.default.copyItem(at: after, to: working)
            }
            let executor = OfficeAutomaticExecutor(factory: factory)
            let host = QualificationOfficeHost(executor: executor)
            let officeAccess = access(workRoot)
            let frozenProposal = try proposal(document: "job-source.xlsx", sha: sha,
                                              commands: [.excelInsertRows(count: 1, at: "A1")])
            await host.seed(frozenProposal, access: officeAccess)

            let rawExecutions = QualificationCounter()
            let registry = ToolRunnerRegistry()
            registry.register(AnyAgentTool(descriptor: ToolCatalog.Descriptor(
                name: "document.office.edit", toolDescription: "qualification",
                parametersJSON: #"{"type":"object"}"#, riskLabels: [],
                isSideEffecting: true, effect: .mutating
            )) { _, _ in
                await rawExecutions.increment()
                return ToolExecutionOutput(summary: "raw registry path ran", fullOutputSHA256: "raw")
            })
            let adapter = NativeJobServiceAdapter(
                targetTool: "document.office.edit",
                adaptedActions: ["apply"],
                requiresRuntimeAuthorization: true,
                prepare: { request in
                    guard let submitBinding = request.consumedBinding else {
                        throw FloeError.validationFailed("no consumed submission binding")
                    }
                    struct Payload: Decodable { let proposal_id: UUID }
                    let decoded = try JSONDecoder().decode(Payload.self, from: request.payloadJSON)
                    guard let frozen = try await host.loadProposal(id: decoded.proposal_id,
                                                                   access: officeAccess) else {
                        throw FloeError.notFound("proposal")
                    }
                    // Freeze only after re-reading the real revision.
                    let currentSHA = try FloeDigest.sha256Hex(ofFileAt: source)
                    guard currentSHA == frozen.baseSHA256 else {
                        throw FloeError.validationFailed("the proposal revision is stale")
                    }
                    return QualificationAuthorizedApplyOperation(
                        host: host, proposal: frozen, access: officeAccess,
                        submitBinding: submitBinding, requestID: request.operationID,
                        relativeOutput: "job-verified.xlsx")
                })
            let service = BackgroundJobService(
                store: BackgroundJobStore(database: database), registry: registry,
                policy: .withAdaptedApplyActions(["document.office.edit": ["apply"]]),
                adapters: ["document.office.edit": adapter])
            let arguments = #"{"action":"apply","proposal_id":"\#(frozenProposal.id.uuidString)"}"#
            let context = ToolContext(
                runID: runID, toolCallID: "qual-apply-job", toolIdempotencyKey: "qual-apply-job",
                scope: .local, allowedToolNames: ["jobs.submit", "document.office.edit"],
                workspaceRootURL: workRoot, cancellation: CancellationToken(),
                environmentID: "qual-env", conversationID: conversation,
                callOrigin: ToolCallOrigin(kind: .mainRunDelegate, runID: runID,
                                           callID: "qual-apply-job", toolName: "jobs.submit"))
            let binding = try JobsSubmitTool.runtimeAuthorityBinding(
                for: .init(tool: "document.office.edit", arguments: arguments), context: context)
            let authority = await RuntimeAuthorityStore.shared.issue(RuntimeAuthorityEvidence(
                runID: binding.runID, taskID: binding.taskID,
                environmentBinding: binding.environmentBinding,
                canonicalTarget: binding.canonicalTarget, toolName: binding.toolName,
                operation: binding.operation, operationID: binding.operationID,
                idempotencyKey: binding.idempotencyKey, baseRevision: binding.baseRevision,
                payloadDigest: binding.payloadDigest, approvalGrantID: UUID()))
            var missingAuthorityRefused = false
            do {
                _ = try await service.submit(
                    runID: runID, toolCallID: "qual-apply-noauth",
                    targetTool: "document.office.edit",
                    payloadJSON: Data(arguments.utf8), scope: .local,
                    workspaceRootURL: workRoot, allowedWorkspacePaths: [],
                    allowedToolNames: ["jobs.submit", "document.office.edit"],
                    callOrigin: ToolCallOrigin(kind: .mainRunDelegate, runID: runID,
                                               callID: "qual-apply-noauth", toolName: "jobs.submit"))
            } catch { missingAuthorityRefused = true }
            let output = try await JobsSubmitTool(service: service).execute(
                .init(tool: "document.office.edit", arguments: arguments),
                context: ToolContext(
                    runID: runID, toolCallID: "qual-apply-job", toolIdempotencyKey: "qual-apply-job",
                    scope: .local, allowedToolNames: ["jobs.submit", "document.office.edit"],
                    workspaceRootURL: workRoot, cancellation: CancellationToken(),
                    environmentID: "qual-env", conversationID: conversation,
                    runtimeAuthority: authority,
                    callOrigin: ToolCallOrigin(kind: .mainRunDelegate, runID: runID,
                                               callID: "qual-apply-job", toolName: "jobs.submit")))
            guard let jobID = jobID(from: output.summary) else {
                return CaseResult(name: name, status: "failed", facts: ["no jobID in submit response"])
            }
            var terminal: BackgroundJob?
            for _ in 0..<200 {
                if let current = try await service.job(id: jobID), current.state.isTerminal {
                    terminal = current
                    break
                }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            let sourceAfter = try FloeDigest.sha256Hex(ofFileAt: source)
            let published = workRoot.appendingPathComponent("job-verified.xlsx")
            let outputExists = FileManager.default.fileExists(atPath: published.path)
            let document = NativeJobProgressDocument.decode(terminal?.progressJSON)
            let rawCount = await rawExecutions.count
            let sessionClosed = await factory.sessions.first?.isClosed() == true
            let facts = [
                "jobState=\(terminal?.state.rawValue ?? "unknown")",
                "sourceUnchanged=\(sourceAfter == sha)",
                "outputExists=\(outputExists)",
                "rawRegistryExecutions=\(rawCount)",
                "missingAuthorityRefused=\(missingAuthorityRefused)",
                "origin=\(document?.origin?.kind.rawValue ?? "none")",
                "frozenRevisionMatches=\(document?.prepared?.frozenRevision == sha)",
                "progressFinalUnits=\(document?.progress?.completedUnits ?? -1)/\(document?.progress?.totalUnits ?? -1)",
                "sessionClosed=\(sessionClosed)",
                "receiptDigest=\(terminal?.resultDigest?.prefix(12) ?? "none")",
                "lastError=\(terminal?.lastError?.prefix(300) ?? "none")",
                "resultSummary=\(terminal?.resultSummary?.prefix(200) ?? "none")"
            ]
            let passed = terminal?.state == .completed
                && sourceAfter == sha
                && outputExists
                && rawCount == 0
                && missingAuthorityRefused
                && document?.origin?.kind == .mainRun
                && document?.prepared?.frozenRevision == sha
                && document?.progress?.completedUnits == 3
                && document?.progress?.totalUnits == 3
            return CaseResult(name: name, status: passed ? "passed" : "failed", facts: facts)
        } catch {
            return CaseResult(name: name, status: "failed", facts: ["error=\(error)"])
        }
    }

    private static func mediaJobProgress(workRoot: URL) async -> CaseResult {
        let name = "media-job-progress-and-scope"
        do {
            let database = try DatabaseManager.inMemory()
            try await database.migrate()
            let conversation = UUID(), runID = UUID()
            let now = ISO8601DateFormatter().string(from: Date())
            try await database.writer { db in
                try db.execute(sql: """
                    INSERT INTO conversations (id, title, created_at, updated_at)
                    VALUES (?, 'Qualification', ?, ?)
                    """, arguments: [conversation.uuidString, now, now])
                try db.execute(sql: """
                    INSERT INTO runs (id, conversation_id, state, goal, started_at)
                    VALUES (?, ?, 'running', 'Qualification', ?)
                    """, arguments: [runID.uuidString, conversation.uuidString, now])
            }
            let processor = QualificationFrameProcessing()
            let registry = ToolRunnerRegistry()
            registry.register(VideoInterpolateTool(processor: processor))
            let service = BackgroundJobService(store: BackgroundJobStore(database: database),
                                               registry: registry)
            let inputName = "media-clip.mp4"
            try Data("qualification media bytes".utf8)
                .write(to: workRoot.appendingPathComponent(inputName))
            let payload = Data(
                #"{"input":"\#(inputName)","output":"media-out.mp4","targetFPS":60,"mode":"quality"}"#.utf8)
            let job = try await service.submit(
                runID: runID, toolCallID: "qual-media", targetTool: "video.interpolate",
                payloadJSON: payload, scope: .local, workspaceRootURL: workRoot,
                allowedWorkspacePaths: [], environmentID: "qual-env",
                submissionSource: .nativeService)
            var terminal: BackgroundJob?
            for _ in 0..<200 {
                if let current = try await service.job(id: job.id), current.state.isTerminal {
                    terminal = current
                    break
                }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            let document = NativeJobProgressDocument.decode(terminal?.progressJSON)
            // The REAL production service refuses a request without the
            // immutable workspace scope (no first/current fallback).
            let realService = MediaEnhancementIntegration.makeFrameProcessing()
            var missingScopeRefused = false
            do {
                _ = try await realService.process(FrameProcessingRequest(
                    operation: .interpolation(targetFPS: 60),
                    input: workRoot.appendingPathComponent(inputName),
                    output: workRoot.appendingPathComponent("no-scope.mp4"),
                    mode: "quality", workspaceRoot: nil))
            } catch { missingScopeRefused = true }
            // The frozen plan helper resolves both paths against the frozen
            // root and rejects an escape.
            var escapeRefused = false
            do {
                _ = try MediaJobEnhancementPreparation.frameProcessingPlan(
                    payloadJSON: Data(#"{"input":"../escape.mp4","output":"out.mp4","targetFPS":60,"mode":"quality"}"#.utf8),
                    workspaceRootPath: workRoot.path, operationID: "qual-op")
            } catch { escapeRefused = true }
            let plan = try MediaJobEnhancementPreparation.frameProcessingPlan(
                payloadJSON: payload, workspaceRootPath: workRoot.path, operationID: "qual-op")
            let facts = [
                "jobState=\(terminal?.state.rawValue ?? "unknown")",
                "progressUnits=\(document?.progress?.completedUnits ?? -1)/\(document?.progress?.totalUnits ?? -1)",
                "progressPhase=\(document?.progress?.phase ?? "none")",
                "outputWritten=\(FileManager.default.fileExists(atPath: workRoot.appendingPathComponent("media-out.mp4").path))",
                "frozenWorkspaceReachedProcessor=\(processor.sawWorkspaceRoot?.path == workRoot.path)",
                "realServiceMissingScopeRefused=\(missingScopeRefused)",
                "planEscapeRefused=\(escapeRefused)",
                "planOutput=\(plan?.expectedOutputURL.lastPathComponent ?? "none")"
            ]
            let passed = terminal?.state == .completed
                && document?.progress?.completedUnits == 3
                && document?.progress?.totalUnits == 10
                && document?.progress?.phase == "processing"
                && processor.sawWorkspaceRoot?.path == workRoot.path
                && missingScopeRefused
                && escapeRefused
                && plan != nil
            return CaseResult(name: name, status: passed ? "passed" : "failed", facts: facts)
        } catch {
            return CaseResult(name: name, status: "failed", facts: ["error=\(error)"])
        }
    }

    private static func jobID(from summary: String) -> UUID? {
        guard let data = summary.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["jobID"] as? String else { return nil }
        return UUID(uuidString: raw)
    }
}
