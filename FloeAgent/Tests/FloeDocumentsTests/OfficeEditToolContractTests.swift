import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeDocuments

/// In-memory Office host used to exercise the tool contract (ownership, SHA
/// binding, grants, idempotency, export) without a device engine. The live
/// engine paths themselves are dispatched by the app bridge.
actor FakeOfficeHost: OfficeCommandHost {
    struct Failure: Error, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    var statusValue: OfficeLiveStatus
    var applyReceipt: OfficeCommandReceipt
    var exportReceipt: OfficeExportReceipt
    var applyError: Error?
    private(set) var proposals: [UUID: OfficeCommandProposal] = [:]
    private(set) var proposalAccess: [UUID: OfficeCommandAccess] = [:]
    private(set) var applyCount = 0
    private(set) var lastGrantID: String?
    private(set) var lastRequestID: String?
    private(set) var exportOutput: String?

    init(status: OfficeLiveStatus, receipt: OfficeCommandReceipt, export: OfficeExportReceipt) {
        statusValue = status
        applyReceipt = receipt
        exportReceipt = export
    }

    func authorizeAccess(_ access: OfficeCommandAccess) async throws {
        guard access.workspacePath?.isEmpty == false else { throw FloeError.unauthorized }
    }

    func status(documentID: String, access: OfficeCommandAccess) async throws -> OfficeLiveStatus {
        var value = statusValue
        value.documentID = documentID
        return value
    }

    func prepareProposal(documentID: String, baseSHA256: String, summary: String,
                         commandsJSON: String, access: OfficeCommandAccess) async throws -> OfficeCommandProposal {
        let commands = try OfficeCommandCodec.decode(commandsJSON)
        let proposal = OfficeCommandProposal(documentID: documentID, format: statusValue.format,
                                             baseSHA256: baseSHA256, summary: summary,
                                             commandsJSON: commandsJSON,
                                             expectations: OfficeCommandCodec.expectations(commands),
                                             selectionFingerprint: commands.contains(where: \.requiresSelectionFingerprint) ? "fp" : nil,
                                             targetSummary: commands.map(\.targetSummary).joined(separator: "; "))
        proposalAccess[proposal.id] = access
        return proposal
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
        guard proposal.documentID == documentID else {
            throw FloeError.validationFailed("proposal belongs to \(proposal.documentID)")
        }
    }

    func removeProposal(id: UUID) async throws {
        proposals[id] = nil
    }

    func consumeGrant(grantID: String, proposalID: UUID, documentID: String,
                      sha256: String) async -> OfficeGrantDecision {
        grantID == "grant" ? .authorized : .unknownGrant
    }

    func apply(proposal: OfficeCommandProposal, grantID: String, requestID: String,
               access: OfficeCommandAccess) async throws -> OfficeCommandReceipt {
        if let applyError { throw applyError }
        applyCount += 1
        lastGrantID = grantID
        lastRequestID = requestID
        return applyReceipt
    }

    func export(documentID: String, relativeOutput: String,
                access: OfficeCommandAccess) async throws -> OfficeExportReceipt {
        exportOutput = relativeOutput
        var receipt = exportReceipt
        receipt.relativePath = relativeOutput
        return receipt
    }
}

@Suite("document.office.edit tool contract")
struct OfficeEditToolContractTests {
    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-office-tool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func context(root: URL, conversationID: UUID? = nil,
                         toolCallID: String? = "call-1") -> ToolContext {
        ToolContext(runID: UUID(), toolCallID: toolCallID,
                    workspaceRootURL: root, cancellation: CancellationToken(),
                    conversationID: conversationID)
    }

    private func sha(_ url: URL) throws -> String {
        try FloeDigest.sha256Hex(ofFileAt: url)
    }

    private func host(for url: URL) throws -> (FakeOfficeHost, OfficeEditTool, String) {
        let digest = try sha(url)
        let format = url.pathExtension.lowercased()
        let status = OfficeLiveStatus(documentID: url.lastPathComponent, format: format,
                                      revisionSHA256: digest, liveSession: true,
                                      editable: true, readOnlyReason: nil, hasUnsavedChanges: false)
        let receipt = OfficeCommandReceipt(documentID: url.lastPathComponent,
                                           sha256: String(repeating: "f", count: 64),
                                           commands: ["word.insertTable"], verified: ["table=2x3"],
                                           saved: true)
        let export = OfficeExportReceipt(documentID: url.lastPathComponent, relativePath: "copy.docx",
                                         sha256: digest, byteCount: 100)
        let fake = try FakeOfficeHost(status: status, receipt: receipt, export: export)
        let tool = OfficeEditTool(host: fake, workspaceRoot: { url.deletingLastPathComponent() })
        return (fake, tool, digest)
    }

    @Test("propose binds the exact saved SHA and a validated command batch")
    func propose() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let document = root.appendingPathComponent("brief.docx")
        try OfficeDocumentBuilder.createWord(at: document, title: "Brief", paragraphs: ["One"])
        let (fake, tool, digest) = try host(for: document)
        let args = OfficeEditArguments(
            action: .propose, path: "brief.docx", summary: "insert table",
            commands: [OfficeCommandCodec.Entry(id: "word.insertTable", arguments: ["rows": "2", "columns": "3"])],
            expectedSHA256: digest)
        let output = try await tool.execute(args, context: context(root: root))
        #expect(output.exitStatus == 0)
        #expect(output.summary.contains("proposal_id="))
        #expect(output.summary.contains("status=needs_confirmation"))
        #expect(await fake.proposals.count == 1)
        let stored = try #require(await fake.proposals.values.first)
        #expect(stored.baseSHA256 == digest.lowercased())
        #expect(stored.expectations.contains { $0.contains("table") || $0.contains("3×3") || $0.contains("2×3") })

        // A stale SHA is refused before any proposal is stored.
        let stale = OfficeEditArguments(
            action: .propose, path: "brief.docx", summary: "insert table",
            commands: [OfficeCommandCodec.Entry(id: "word.insertTable", arguments: ["rows": "2", "columns": "3"])],
            expectedSHA256: String(repeating: "0", count: 64))
        let refused = try await tool.execute(stale, context: context(root: root))
        #expect(refused.exitStatus == 2)
        #expect(refused.summary.contains("error"))
        #expect(await fake.proposals.count == 1)
    }

    @Test("propose refuses a command from another format and unknown ids")
    func proposeFormatMismatch() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let document = root.appendingPathComponent("sheet.xlsx")
        try OfficeDocumentBuilder.createWorkbook(at: document, sheets: [.init(name: "Inputs", rows: [["A"], ["1"]])])
        let (_, tool, digest) = try host(for: document)
        let mismatch = OfficeEditArguments(
            action: .propose, path: "sheet.xlsx", summary: "style",
            commands: [OfficeCommandCodec.Entry(id: "word.style", arguments: ["style": "Heading 1"])],
            expectedSHA256: digest)
        let output = try await tool.execute(mismatch, context: context(root: root))
        #expect(output.exitStatus == 2)
        #expect(output.summary.contains("not available for xlsx"))
    }

    @Test("apply requires a UI grant, checks ownership, and returns verified facts")
    func apply() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let document = root.appendingPathComponent("brief.docx")
        try OfficeDocumentBuilder.createWord(at: document, title: "Brief", paragraphs: ["One"])
        let (fake, tool, digest) = try host(for: document)
        let owner = UUID()
        let proposalArgs = OfficeEditArguments(
            action: .propose, path: "brief.docx", summary: "insert table",
            commands: [OfficeCommandCodec.Entry(id: "word.insertTable", arguments: ["rows": "2", "columns": "3"])],
            expectedSHA256: digest)
        _ = try await tool.execute(proposalArgs, context: context(root: root, conversationID: owner))
        let proposal = try #require(await fake.proposals.values.first)

        // Missing grant fails validation before any host call.
        let ungranted = OfficeEditArguments(action: .apply, path: "brief.docx",
                                            proposalID: proposal.id, grantID: nil)
        let refused = try await tool.execute(ungranted, context: context(root: root, conversationID: owner))
        #expect(refused.exitStatus == 2)
        #expect(await fake.applyCount == 0)

        // A different task cannot even load the proposal (ownership denial),
        // so its apply cannot reach the engine.
        let foreign = OfficeEditArguments(action: .apply, path: "brief.docx",
                                          proposalID: proposal.id, grantID: "grant")
        let denied = try await tool.execute(foreign, context: context(root: root, conversationID: UUID()))
        #expect(denied.exitStatus == 2)
        #expect(await fake.applyCount == 0)

        // The owner applies with the UI grant.
        let granted = OfficeEditArguments(action: .apply, path: "brief.docx",
                                          proposalID: proposal.id, grantID: "grant",
                                          requestID: "req-1")
        let output = try await tool.execute(granted, context: context(root: root, conversationID: owner))
        #expect(output.exitStatus == 0)
        #expect(output.summary.contains("status=saved"))
        #expect(output.summary.contains("table=2x3"))
        #expect(await fake.applyCount == 1)
        #expect(await fake.lastGrantID == "grant")
        #expect(await fake.lastRequestID == "req-1")
    }

    @Test("read, errors and export use the saved package without touching the source")
    func readErrorsExport() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let workbook = root.appendingPathComponent("sheet.xlsx")
        try OfficeDocumentBuilder.createWorkbook(at: workbook,
                                                 sheets: [.init(name: "Inputs", rows: [["A", "=1/0"], ["1", "2"]])])
        let (fake, tool, digest) = try host(for: workbook)

        let read = try await tool.execute(OfficeEditArguments(action: .read, path: "sheet.xlsx"),
                                          context: context(root: root))
        #expect(read.exitStatus == 0)
        #expect(read.summary.contains(digest))
        #expect(read.summary.contains("hasUnsavedChanges"))

        let query = try await tool.execute(OfficeEditArguments(action: .query, path: "sheet.xlsx"),
                                           context: context(root: root))
        #expect(query.summary.contains("excel.numberFormat"))
        #expect(query.summary.contains("requiresSelectionFingerprint"))

        let export = try await tool.execute(OfficeEditArguments(action: .export, path: "sheet.xlsx",
                                                                output: "copy.xlsx"),
                                            context: context(root: root))
        #expect(export.exitStatus == 0)
        #expect(export.summary.contains("exported=copy.xlsx"))
        #expect(export.summary.contains("sourceUnchanged=true"))
        #expect(await fake.exportOutput == "copy.xlsx")
        #expect(try sha(workbook) == digest)
    }

    @Test("replaceImage atomically replaces same-format bytes and refuses a live dirty editor")
    func replaceImage() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let document = root.appendingPathComponent("deck.pptx")
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
        try OfficeDocumentBuilder.createPresentation(
            at: document, title: "Deck",
            slides: [.init(title: "One", bullets: ["a"],
                           objects: [.init(kind: .image, imageBase64: png.base64EncodedString())])])
        let (fake, tool, digest) = try host(for: document)
        let image = root.appendingPathComponent("replacement.png")
        let replacement = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        try replacement.write(to: image)

        // A dirty live editor blocks the package-level change.
        var dirtyStatus = await fake.statusValue
        dirtyStatus.hasUnsavedChanges = true
        await fake.setStatus(dirtyStatus)
        let blocked = try await tool.execute(
            OfficeEditArguments(action: .replaceImage, path: "deck.pptx", expectedSHA256: digest, image: "#1",
                                imagePath: "replacement.png"),
            context: context(root: root))
        #expect(blocked.exitStatus == 2)
        #expect(blocked.summary.contains("unsaved"))

        var cleanStatus = await fake.statusValue
        cleanStatus.hasUnsavedChanges = false
        await fake.setStatus(cleanStatus)
        let output = try await tool.execute(
            OfficeEditArguments(action: .replaceImage, path: "deck.pptx", expectedSHA256: digest, image: "#1",
                                imagePath: "replacement.png"),
            context: context(root: root))
        #expect(output.exitStatus == 0)
        #expect(output.summary.contains("verified=true"))
        #expect(try sha(document) != digest)
    }
}

private extension FakeOfficeHost {
    func setStatus(_ status: OfficeLiveStatus) { statusValue = status }
}
