// FloeDocumentsTests — document.office.edit automatic apply authorization.
//
// The automatic path must be gated by the runtime-issued task authority for
// THIS exact call. These tests mint real tokens through the production
// RuntimeAuthorityStore and verify: an authorized call runs the automatic
// executor, a missing/forged token is refused with no host effect, a token for
// a different payload is refused, and grant_id + output is rejected.

import Foundation
import Testing
import ZIPFoundation
import FloeCore
import FloeTools
@testable import FloeDocuments

actor AutomaticOfficeHost: OfficeCommandHost {
    private var proposals: [UUID: OfficeCommandProposal] = [:]
    private var proposalAccess: [UUID: OfficeCommandAccess] = [:]
    private let executor: OfficeAutomaticExecutor
    private(set) var applyAutomaticCalls = 0
    private(set) var lastAuthorization: OfficeAutomaticAuthorization?
    private(set) var lastOutput: String?
    private(set) var lastCancellation: CancellationToken?

    init(executor: OfficeAutomaticExecutor) {
        self.executor = executor
    }

    func authorizeAccess(_ access: OfficeCommandAccess) async throws {
        guard access.workspacePath?.isEmpty == false else { throw FloeError.unauthorized }
    }

    func status(documentID: String, access: OfficeCommandAccess) async throws -> OfficeLiveStatus {
        OfficeLiveStatus(documentID: documentID, format: "xlsx",
                         revisionSHA256: String(repeating: "0", count: 64),
                         liveSession: false, editable: false,
                         readOnlyReason: "service session only")
    }

    func prepareProposal(documentID: String, baseSHA256: String, summary: String,
                         commandsJSON: String, access: OfficeCommandAccess) async throws -> OfficeCommandProposal {
        OfficeCommandProposal(documentID: documentID, format: "xlsx", baseSHA256: baseSHA256,
                              summary: summary, commandsJSON: commandsJSON, expectations: [])
    }

    func storeProposal(_ proposal: OfficeCommandProposal) async throws {
        proposals[proposal.id] = proposal
    }

    func loadProposal(id: UUID, access: OfficeCommandAccess) async throws -> OfficeCommandProposal? {
        guard proposalAccess[id] == access else { return nil }
        return proposals[id]
    }

    func verifyProposalBinding(_ proposal: OfficeCommandProposal, documentID: String,
                               access: OfficeCommandAccess) async throws {
        guard proposalAccess[proposal.id] == access else { throw FloeError.unauthorized }
    }

    func removeProposal(id: UUID) async throws { proposals[id] = nil }

    func consumeGrant(grantID: String, proposalID: UUID, documentID: String,
                      sha256: String) async -> OfficeGrantDecision { .unknownGrant }

    func apply(proposal: OfficeCommandProposal, grantID: String, requestID: String,
               access: OfficeCommandAccess) async throws -> OfficeCommandReceipt {
        throw FloeError.validationFailed("interactive path not used in this test")
    }

    func export(documentID: String, relativeOutput: String,
                access: OfficeCommandAccess) async throws -> OfficeExportReceipt {
        throw FloeError.validationFailed("export not used in this test")
    }

    func applyAutomatic(proposal: OfficeCommandProposal,
                        authorization: OfficeAutomaticAuthorization,
                        relativeOutput: String?,
                        requestID: String,
                        access: OfficeCommandAccess,
                        cancellation: CancellationToken?) async throws -> OfficeAutomaticReceipt {
        lastCancellation = cancellation
        return try await applyAutomatic(proposal: proposal, authorization: authorization,
                                        relativeOutput: relativeOutput, requestID: requestID,
                                        access: access)
    }

    func applyAutomatic(proposal: OfficeCommandProposal,
                        authorization: OfficeAutomaticAuthorization,
                        relativeOutput: String?,
                        requestID: String,
                        access: OfficeCommandAccess) async throws -> OfficeAutomaticReceipt {
        applyAutomaticCalls += 1
        lastAuthorization = authorization
        lastOutput = relativeOutput
        return try await executor.execute(proposal: proposal, authorization: authorization,
                                          relativeOutput: relativeOutput, requestID: requestID,
                                          access: access)
    }

    func seed(_ proposal: OfficeCommandProposal, access: OfficeCommandAccess) {
        proposals[proposal.id] = proposal
        proposalAccess[proposal.id] = access
    }
}

@Suite("document.office.edit automatic apply authorization")
struct OfficeAutomaticApplyToolTests {
    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-auto-tool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeSource(_ url: URL) throws {
        let archive = try Archive(url: url, accessMode: .create)
        let entries: [String: String] = [
            "[Content_Types].xml": "<Types/>",
            "xl/workbook.xml": #"<workbook><sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>"#,
            "xl/styles.xml": #"<styleSheet><cellXfs count="1"><xf numFmtId="0"/></cellXfs></styleSheet>"#,
            "xl/worksheets/sheet1.xml": #"<worksheet><sheetData><row r="1"><c r="A1"><v>1</v></c></row></sheetData></worksheet>"#,
        ]
        for (path, value) in entries { try archive.addFloeEntry(path: path, data: Data(value.utf8)) }
    }

    private func afterEntries() -> [String: String] {
        [
            "[Content_Types].xml": "<Types/>",
            "xl/workbook.xml": #"<workbook><sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>"#,
            "xl/styles.xml": #"<styleSheet><cellXfs count="1"><xf numFmtId="0"/></cellXfs></styleSheet>"#,
            "xl/worksheets/sheet1.xml": #"<worksheet><sheetData><row r="1"><c r="A1"><v>1</v></c></row><row r="2"><c r="A2"><v>2</v></c></row></sheetData></worksheet>"#,
        ]
    }

    private func makeToolHost(root: URL) -> (AutomaticOfficeHost, OfficeEditTool, FakeServiceSessionFactory) {
        let after = afterEntries()
        let factory = FakeServiceSessionFactory { working in
            try? FileManager.default.removeItem(at: working)
            let archive = try Archive(url: working, accessMode: .create)
            for (path, value) in after { try archive.addFloeEntry(path: path, data: Data(value.utf8)) }
        }
        let executor = OfficeAutomaticExecutor(factory: factory)
        let host = AutomaticOfficeHost(executor: executor)
        let tool = OfficeEditTool(host: host, workspaceRoot: { root })
        return (host, tool, factory)
    }

    private func argsFor(source: String, output: String?) -> OfficeEditArguments {
        OfficeEditArguments(
            action: .apply, path: nil, summary: nil,
            commands: nil, proposalID: nil, grantID: nil, requestID: nil,
            expectedSHA256: nil, output: output, image: nil, imagePath: nil)
    }

    private func mintAuthority(args: OfficeEditArguments, runID: UUID, taskID: UUID,
                               toolCallID: String, idempotencyKey: String, grantID: UUID,
                               root: URL) async throws -> RuntimeTaskAuthority {
        let payload = try OfficeEditTool.canonicalApprovedPayload(args)
        let evidence = RuntimeAuthorityEvidence(
            runID: runID, taskID: taskID,
            environmentBinding: RuntimeAuthorityDigest.environmentBinding(
                workspaceRootURL: root, conversationID: taskID),
            canonicalTarget: OfficeEditTool.canonicalTarget(for: args, workspaceRoot: root),
            toolName: OfficeEditTool.name, operation: "apply", operationID: toolCallID,
            idempotencyKey: idempotencyKey, baseRevision: nil,
            payloadDigest: RuntimeAuthorityDigest.payloadDigest(payload),
            approvalGrantID: grantID)
        return await RuntimeAuthorityStore.shared.issue(evidence)
    }

    @Test("an authorized apply runs the automatic executor and publishes a copy")
    func authorizedAutomaticApply() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.xlsx")
        try writeSource(source)
        let sourceSHA = try FloeDigest.sha256Hex(ofFileAt: source)
        let (host, tool, _) = makeToolHost(root: root)
        let conversationID = UUID()
        let access = OfficeCommandAccess(environmentID: nil, workspacePath: root.path,
                                         ownerKind: "chat", ownerID: conversationID,
                                         conversationID: conversationID)
        let commandsJSON = try OfficeCommandCodec.encode([.excelInsertRows(count: 1, at: "A1")])
        let proposal = OfficeCommandProposal(documentID: "book.xlsx", format: "xlsx",
                                             baseSHA256: sourceSHA, summary: "auto",
                                             commandsJSON: commandsJSON, expectations: [])
        await host.seed(proposal, access: access)

        var args = argsFor(source: "book.xlsx", output: "book.edited.xlsx")
        args.proposalID = proposal.id
        let runID = UUID(), grantID = UUID()
        let token = try await mintAuthority(args: args, runID: runID, taskID: conversationID,
                                            toolCallID: "call-1", idempotencyKey: "key-1",
                                            grantID: grantID, root: root)
        let context = ToolContext(runID: runID, toolCallID: "call-1", toolIdempotencyKey: "key-1",
                                  approvalGrantID: grantID, workspaceRootURL: root,
                                  cancellation: CancellationToken(), conversationID: conversationID,
                                  runtimeAuthority: token)
        let output = try await tool.execute(args, context: context)
        #expect(output.exitStatus == 0)
        #expect(output.summary.contains("mode=automatic-copy"))
        #expect(output.summary.contains("sourceUnchanged=true"))
        #expect(await host.applyAutomaticCalls == 1)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("book.edited.xlsx").path))
        #expect(try FloeDigest.sha256Hex(ofFileAt: source) == sourceSHA)
        // The consumed token is single-use.
        let replay = try await tool.execute(args, context: context)
        #expect(replay.exitStatus == 2)
    }

    @Test("apply without grant or issued authority is refused with no host effect")
    func missingAuthorityRefused() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.xlsx")
        try writeSource(source)
        let sourceSHA = try FloeDigest.sha256Hex(ofFileAt: source)
        let (host, tool, _) = makeToolHost(root: root)
        let conversationID = UUID()
        let access = OfficeCommandAccess(environmentID: nil, workspacePath: root.path,
                                         ownerKind: "chat", ownerID: conversationID,
                                         conversationID: conversationID)
        let commandsJSON = try OfficeCommandCodec.encode([.excelInsertRows(count: 1, at: "A1")])
        let proposal = OfficeCommandProposal(documentID: "book.xlsx", format: "xlsx",
                                             baseSHA256: sourceSHA, summary: "auto",
                                             commandsJSON: commandsJSON, expectations: [])
        await host.seed(proposal, access: access)
        var args = argsFor(source: "book.xlsx", output: nil)
        args.proposalID = proposal.id
        let context = ToolContext(runID: UUID(), toolCallID: "call-2", toolIdempotencyKey: "key-2",
                                  workspaceRootURL: root, cancellation: CancellationToken(),
                                  conversationID: conversationID)
        let output = try await tool.execute(args, context: context)
        #expect(output.exitStatus == 2)
        #expect(output.summary.contains("runtime-approved call authority"))
        #expect(await host.applyAutomaticCalls == 0)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("book.edited.xlsx").path))
    }

    @Test("a token minted for a different payload never authorizes this call")
    func payloadMismatchRefused() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.xlsx")
        try writeSource(source)
        let sourceSHA = try FloeDigest.sha256Hex(ofFileAt: source)
        let (host, tool, _) = makeToolHost(root: root)
        let conversationID = UUID()
        let access = OfficeCommandAccess(environmentID: nil, workspacePath: root.path,
                                         ownerKind: "chat", ownerID: conversationID,
                                         conversationID: conversationID)
        let commandsJSON = try OfficeCommandCodec.encode([.excelInsertRows(count: 1, at: "A1")])
        let proposal = OfficeCommandProposal(documentID: "book.xlsx", format: "xlsx",
                                             baseSHA256: sourceSHA, summary: "auto",
                                             commandsJSON: commandsJSON, expectations: [])
        await host.seed(proposal, access: access)
        var args = argsFor(source: "book.xlsx", output: "book.edited.xlsx")
        args.proposalID = proposal.id
        let runID = UUID(), grantID = UUID()
        // Mint for a DIFFERENT output path.
        var otherArgs = args
        otherArgs.output = "other.xlsx"
        let token = try await mintAuthority(args: otherArgs, runID: runID, taskID: conversationID,
                                            toolCallID: "call-3", idempotencyKey: "key-3",
                                            grantID: grantID, root: root)
        let context = ToolContext(runID: runID, toolCallID: "call-3", toolIdempotencyKey: "key-3",
                                  approvalGrantID: grantID, workspaceRootURL: root,
                                  cancellation: CancellationToken(), conversationID: conversationID,
                                  runtimeAuthority: token)
        let output = try await tool.execute(args, context: context)
        #expect(output.exitStatus == 2)
        #expect(await host.applyAutomaticCalls == 0)
    }

    @Test("grant_id together with output is rejected before any host call")
    func grantWithOutputRejected() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.xlsx")
        try writeSource(source)
        let (host, tool, _) = makeToolHost(root: root)
        var args = argsFor(source: "book.xlsx", output: "book.edited.xlsx")
        args.proposalID = UUID()
        args.grantID = "ui-grant"
        let context = ToolContext(runID: UUID(), toolCallID: "call-4",
                                  workspaceRootURL: root, cancellation: CancellationToken())
        let output = try await tool.execute(args, context: context)
        #expect(output.exitStatus == 2)
        #expect(output.summary.contains("output only for an authorized automatic"))
        #expect(await host.applyAutomaticCalls == 0)
    }

    @Test("the tool forwards the context cancellation into the automatic host")
    func forwardsContextCancellation() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.xlsx")
        try writeSource(source)
        let sourceSHA = try FloeDigest.sha256Hex(ofFileAt: source)
        let (host, tool, _) = makeToolHost(root: root)
        let conversationID = UUID()
        let access = OfficeCommandAccess(environmentID: nil, workspacePath: root.path,
                                         ownerKind: "chat", ownerID: conversationID,
                                         conversationID: conversationID)
        let commandsJSON = try OfficeCommandCodec.encode([.excelInsertRows(count: 1, at: "A1")])
        let proposal = OfficeCommandProposal(documentID: "book.xlsx", format: "xlsx",
                                             baseSHA256: sourceSHA, summary: "auto",
                                             commandsJSON: commandsJSON, expectations: [])
        await host.seed(proposal, access: access)
        var args = argsFor(source: "book.xlsx", output: "book.edited.xlsx")
        args.proposalID = proposal.id
        let runID = UUID(), grantID = UUID()
        let token = try await mintAuthority(args: args, runID: runID, taskID: conversationID,
                                            toolCallID: "call-cancel", idempotencyKey: "key-cancel",
                                            grantID: grantID, root: root)
        let cancellation = CancellationToken()
        let context = ToolContext(runID: runID, toolCallID: "call-cancel",
                                  toolIdempotencyKey: "key-cancel",
                                  approvalGrantID: grantID, workspaceRootURL: root,
                                  cancellation: cancellation, conversationID: conversationID,
                                  runtimeAuthority: token)
        _ = try await tool.execute(args, context: context)
        #expect(await host.lastCancellation === cancellation,
                "the inline tool must forward the real operation cancellation token")
    }

    @Test("a cancelled context never reaches the automatic host and writes nothing")
    func cancelledContextHasNoHostEffect() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.xlsx")
        try writeSource(source)
        let sourceSHA = try FloeDigest.sha256Hex(ofFileAt: source)
        let (host, tool, _) = makeToolHost(root: root)
        let conversationID = UUID()
        let access = OfficeCommandAccess(environmentID: nil, workspacePath: root.path,
                                         ownerKind: "chat", ownerID: conversationID,
                                         conversationID: conversationID)
        let commandsJSON = try OfficeCommandCodec.encode([.excelInsertRows(count: 1, at: "A1")])
        let proposal = OfficeCommandProposal(documentID: "book.xlsx", format: "xlsx",
                                             baseSHA256: sourceSHA, summary: "auto",
                                             commandsJSON: commandsJSON, expectations: [])
        await host.seed(proposal, access: access)
        var args = argsFor(source: "book.xlsx", output: "book.edited.xlsx")
        args.proposalID = proposal.id
        let runID = UUID(), grantID = UUID()
        let token = try await mintAuthority(args: args, runID: runID, taskID: conversationID,
                                            toolCallID: "call-pre", idempotencyKey: "key-pre",
                                            grantID: grantID, root: root)
        let cancelled = CancellationToken()
        cancelled.cancel()
        let context = ToolContext(runID: runID, toolCallID: "call-pre",
                                  toolIdempotencyKey: "key-pre",
                                  approvalGrantID: grantID, workspaceRootURL: root,
                                  cancellation: cancelled, conversationID: conversationID,
                                  runtimeAuthority: token)
        var threw = false
        do {
            _ = try await tool.execute(args, context: context)
        } catch {
            threw = true
        }
        #expect(threw, "a pre-cancelled context must leave at its safe pre-effect boundary")
        #expect(await host.applyAutomaticCalls == 0)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("book.edited.xlsx").path))
    }

}
