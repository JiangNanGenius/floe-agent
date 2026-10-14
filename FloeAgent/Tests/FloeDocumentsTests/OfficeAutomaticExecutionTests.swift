// FloeDocumentsTests — authorized automatic Office copy execution.
//
// The tests run the REAL executor against real OOXML packages and a fake
// service-owned engine session (the device engine lives in the app target).
// They prove: the original is never modified, the verified copy is reopened
// and checked, selection-relative commands are refused, stale formula caches
// fail the run, output conflicts never overwrite, and a repeated request
// replays rather than re-running.

import Foundation
import Testing
import ZIPFoundation
import FloeCore
import FloeTools
@testable import FloeDocuments

/// Programmable fake of the app's service-owned engine session.
final class FakeServiceSession: OfficeServiceEngineSession, @unchecked Sendable {
    let workingCopyURL: URL
    let engineLabel = "fake-service-engine"
    private let plan: @Sendable (URL) throws -> Void
    private let statusValue: OfficeServiceSessionStatus
    private let saveError: Error?
    private let closeError: Error?
    private let statusDelayNanoseconds: UInt64
    private(set) var appliedCommands: [[String]] = []
    private(set) var saved = false
    private(set) var closed = false

    init(workingCopyURL: URL,
         status: OfficeServiceSessionStatus = OfficeServiceSessionStatus(editable: true),
         saveError: Error? = nil,
         closeError: Error? = nil,
         statusDelayNanoseconds: UInt64 = 0,
         plan: @escaping @Sendable (URL) throws -> Void) {
        self.workingCopyURL = workingCopyURL
        self.statusValue = status
        self.saveError = saveError
        self.closeError = closeError
        self.statusDelayNanoseconds = statusDelayNanoseconds
        self.plan = plan
    }

    func status() async throws -> OfficeServiceSessionStatus {
        if statusDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: statusDelayNanoseconds)
        }
        return statusValue
    }

    func apply(commands: [OfficeEngineCommand], batchID: String) async throws {
        appliedCommands.append(commands.map(\.id))
        try plan(workingCopyURL)
    }

    func save() async throws {
        saved = true
        if let saveError { throw saveError }
    }

    func close() async throws {
        if let closeError { throw closeError }
        closed = true
    }
}

actor FakeServiceSessionFactory: OfficeServiceEngineSessionFactory {
    private let plan: @Sendable (URL) throws -> Void
    private let status: OfficeServiceSessionStatus
    private let saveError: Error?
    private let closeError: Error?
    private let statusDelayNanoseconds: UInt64
    private let openError: Error?
    private let reopen: OfficeEngineReopenEvidence
    private(set) var openCount = 0
    private(set) var sessions: [FakeServiceSession] = []

    init(status: OfficeServiceSessionStatus = OfficeServiceSessionStatus(editable: true),
         saveError: Error? = nil,
         closeError: Error? = nil,
         statusDelayNanoseconds: UInt64 = 0,
         openError: Error? = nil,
         reopen: OfficeEngineReopenEvidence = .engineOpened,
         plan: @escaping @Sendable (URL) throws -> Void) {
        self.status = status
        self.saveError = saveError
        self.closeError = closeError
        self.statusDelayNanoseconds = statusDelayNanoseconds
        self.openError = openError
        self.reopen = reopen
        self.plan = plan
    }

    func openServiceSession(workingCopyURL: URL, format: OfficeDocumentFormat,
                            originalURL: URL,
                            access: OfficeCommandAccess) async throws -> any OfficeServiceEngineSession {
        openCount += 1
        if let openError { throw openError }
        let session = FakeServiceSession(workingCopyURL: workingCopyURL, status: status,
                                         saveError: saveError, closeError: closeError,
                                         statusDelayNanoseconds: statusDelayNanoseconds, plan: plan)
        sessions.append(session)
        return session
    }

    func verifyEngineReopen(savedCopyURL: URL, format: OfficeDocumentFormat,
                            access: OfficeCommandAccess) async -> OfficeEngineReopenEvidence {
        reopen
    }
}

@Suite("Office automatic copy execution")
struct OfficeAutomaticExecutionTests {
    // MARK: - Fixtures

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-auto-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writePackage(_ url: URL, entries: [String: String]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let archive = try Archive(url: url, accessMode: .create)
        for (path, value) in entries {
            try archive.addFloeEntry(path: path, data: Data(value.utf8))
        }
    }

    /// One-sheet workbook with the exact sheetData XML.
    private func workbookData(sheetData: String) -> [String: String] {
        [
            "[Content_Types].xml": #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>"#,
            "xl/workbook.xml": #"<workbook><sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>"#,
            "xl/_rels/workbook.xml.rels": #"<Relationships><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>"#,
            "xl/styles.xml": #"<styleSheet><cellXfs count="1"><xf numFmtId="0"/></cellXfs></styleSheet>"#,
            "xl/worksheets/sheet1.xml": #"<worksheet><sheetData>\#(sheetData)</sheetData></worksheet>"#,
        ]
    }

    private func proposal(for documentID: String, baseSHA256: String,
                          commands: [OfficeEngineCommand]) throws -> OfficeCommandProposal {
        OfficeCommandProposal(documentID: documentID, format: "xlsx", baseSHA256: baseSHA256,
                              summary: "automatic edit",
                              commandsJSON: try OfficeCommandCodec.encode(commands),
                              expectations: OfficeCommandCodec.expectations(commands))
    }

    private func access(root: URL) -> OfficeCommandAccess {
        OfficeCommandAccess(environmentID: nil, workspacePath: root.path,
                            ownerKind: "chat", ownerID: UUID(), conversationID: UUID())
    }

    private func authorization(runID: UUID, taskID: UUID) -> (OfficeAutomaticAuthorization,
                                                              RuntimeAuthorityBinding) {
        let binding = RuntimeAuthorityBinding(
            runID: runID, taskID: taskID, environmentBinding: "task:\(taskID.uuidString)|ws:x",
            canonicalTarget: "workspace:x", toolName: "document.office.edit",
            operation: "apply", operationID: "call-1", idempotencyKey: "key-1",
            baseRevision: nil, payloadDigest: String(repeating: "a", count: 64))
        let proof = OfficeAutomaticAuthorization(runID: runID, taskID: taskID,
                                                 operationID: "call-1", idempotencyKey: "key-1",
                                                 approvalGrantID: UUID(), binding: binding)
        return (proof, binding)
    }

    // MARK: - Tests

    @Test("automatic execution publishes a verified copy and never touches the source")
    func verifiedCopy() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("report.xlsx")
        try writePackage(source, entries: workbookData(
            sheetData: #"<row r="1"><c r="A1"><v>1</v></c></row>"#))
        let sourceSHA = try FloeDigest.sha256Hex(ofFileAt: source)
        let afterData = #"<row r="1"><c r="A1"><v>1</v></c></row><row r="2"><c r="A2"><v>2</v></c></row><row r="3"><c r="A3"><v>3</v></c></row>"#

        let afterEntries = workbookData(sheetData: afterData)
        let factory = FakeServiceSessionFactory { working in
            try? FileManager.default.removeItem(at: working)
            let archive = try Archive(url: working, accessMode: .create)
            for (path, value) in afterEntries {
                try archive.addFloeEntry(path: path, data: Data(value.utf8))
            }
        }
        let executor = OfficeAutomaticExecutor(factory: factory)
        let runID = UUID(), taskID = UUID()
        let (proof, _) = authorization(runID: runID, taskID: taskID)
        let receipt = try await executor.execute(
            proposal: try proposal(for: "report.xlsx", baseSHA256: sourceSHA,
                                   commands: [.excelInsertRows(count: 2, at: "A1")]),
            authorization: proof, relativeOutput: "report.edited.xlsx",
            requestID: "req-1", access: access(root: root))

        #expect(receipt.saved)
        #expect(receipt.sourceUnchanged)
        #expect(receipt.sourceSHA256 == sourceSHA)
        #expect(receipt.outputRelativePath == "report.edited.xlsx")
        #expect(receipt.engineReopen == "engine-opened")
        #expect(receipt.sessionEngine == "fake-service-engine")
        #expect(!receipt.verified.isEmpty)

        // The source bytes are exactly the approved revision.
        #expect(try FloeDigest.sha256Hex(ofFileAt: source) == sourceSHA)
        // The published copy exists with the verified digest and reopens.
        let output = root.appendingPathComponent("report.edited.xlsx")
        #expect(try FloeDigest.sha256Hex(ofFileAt: output) == receipt.outputSHA256)
        let snapshot = try OfficeOutputSnapshot.capture(url: output)
        #expect(snapshot.sheetRowCounts.first == 3)
        // Staging is removed.
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".floe-automation").path))
        // The session was closed.
        #expect(await factory.sessions.first?.closed == true)
        #expect(await factory.sessions.first?.saved == true)
    }

    @Test("selection-relative commands are refused before a session opens")
    func selectionDependentRefused() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("doc.xlsx")
        try writePackage(source, entries: workbookData(sheetData: #"<row r="1"><c r="A1"><v>1</v></c></row>"#))
        let sourceSHA = try FloeDigest.sha256Hex(ofFileAt: source)
        let factory = FakeServiceSessionFactory { _ in }
        let executor = OfficeAutomaticExecutor(factory: factory)
        let (proof, _) = authorization(runID: UUID(), taskID: UUID())
        await #expect(throws: OfficeAutomaticExecutionError.self) {
            try await executor.execute(
                proposal: try self.proposal(for: "doc.xlsx", baseSHA256: sourceSHA,
                                            commands: [.excelSort(ascending: true, range: "A1:A2")]),
                authorization: proof, relativeOutput: nil,
                requestID: "req-sort", access: self.access(root: root))
        }
        #expect(await factory.openCount == 0)
        #expect(try FloeDigest.sha256Hex(ofFileAt: source) == sourceSHA)
    }

    @Test("a stale formula cache fails the reopened verification and publishes nothing")
    func staleFormulaCacheRefused() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("calc.xlsx")
        let stale = #"<row r="1"><c r="A1"><v>1</v></c><c r="B1"><f>SUM(A1:A3)</f><v>5</v></c></row><row r="2"><c r="A2"><v>2</v></c></row><row r="3"><c r="A3"><v>3</v></c></row>"#
        try writePackage(source, entries: workbookData(sheetData: stale))
        let sourceSHA = try FloeDigest.sha256Hex(ofFileAt: source)
        // The fake engine "recalculates" but saves the same stale cache.
        let factory = FakeServiceSessionFactory { _ in }
        let executor = OfficeAutomaticExecutor(factory: factory)
        let (proof, _) = authorization(runID: UUID(), taskID: UUID())
        await #expect(throws: OfficeAutomaticExecutionError.self) {
            try await executor.execute(
                proposal: try self.proposal(for: "calc.xlsx", baseSHA256: sourceSHA,
                                            commands: [.excelRecalculate]),
                authorization: proof, relativeOutput: "calc.edited.xlsx",
                requestID: "req-recalc", access: self.access(root: root))
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("calc.edited.xlsx").path))
        #expect(try FloeDigest.sha256Hex(ofFileAt: source) == sourceSHA)
    }

    @Test("a recalculated fresh cache verifies and reports the formula summary")
    func freshFormulaCacheVerified() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("calc.xlsx")
        try writePackage(source, entries: workbookData(sheetData:
            #"<row r="1"><c r="A1"><v>1</v></c><c r="B1"><f>SUM(A1:A3)</f><v>5</v></c></row><row r="2"><c r="A2"><v>2</v></c></row><row r="3"><c r="A3"><v>3</v></c></row>"#))
        let sourceSHA = try FloeDigest.sha256Hex(ofFileAt: source)
        let fresh = #"<row r="1"><c r="A1"><v>1</v></c><c r="B1"><f>SUM(A1:A3)</f><v>6</v></c></row><row r="2"><c r="A2"><v>2</v></c></row><row r="3"><c r="A3"><v>3</v></c></row>"#
        let freshEntries = workbookData(sheetData: fresh)
        let factory = FakeServiceSessionFactory { working in
            try? FileManager.default.removeItem(at: working)
            let archive = try Archive(url: working, accessMode: .create)
            for (path, value) in freshEntries {
                try archive.addFloeEntry(path: path, data: Data(value.utf8))
            }
        }
        let executor = OfficeAutomaticExecutor(factory: factory)
        let (proof, _) = authorization(runID: UUID(), taskID: UUID())
        let receipt = try await executor.execute(
            proposal: try proposal(for: "calc.xlsx", baseSHA256: sourceSHA,
                                   commands: [.excelRecalculate]),
            authorization: proof, relativeOutput: nil,
            requestID: "req-fresh", access: access(root: root))
        #expect(receipt.formulaSummary?.contains("verified=1") == true)
        #expect(try FloeDigest.sha256Hex(ofFileAt: source) == sourceSHA)
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("calc.edited.xlsx").path))
    }

    @Test("an existing different output is never overwritten")
    func outputConflict() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("report.xlsx")
        try writePackage(source, entries: workbookData(sheetData: #"<row r="1"><c r="A1"><v>1</v></c></row>"#))
        let sourceSHA = try FloeDigest.sha256Hex(ofFileAt: source)
        let output = root.appendingPathComponent("report.edited.xlsx")
        try Data("existing user file".utf8).write(to: output)
        let factory = FakeServiceSessionFactory { _ in }
        let executor = OfficeAutomaticExecutor(factory: factory)
        let (proof, _) = authorization(runID: UUID(), taskID: UUID())
        await #expect(throws: OfficeAutomaticExecutionError.self) {
            try await executor.execute(
                proposal: try self.proposal(for: "report.xlsx", baseSHA256: sourceSHA,
                                            commands: [.excelInsertRows(count: 1, at: "A1")]),
                authorization: proof, relativeOutput: "report.edited.xlsx",
                requestID: "req-conflict", access: self.access(root: root))
        }
        #expect(try Data(contentsOf: output) == Data("existing user file".utf8))
    }

    @Test("a repeated request replays the receipt without re-running the session")
    func replay() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("report.xlsx")
        try writePackage(source, entries: workbookData(sheetData: #"<row r="1"><c r="A1"><v>1</v></c></row>"#))
        let sourceSHA = try FloeDigest.sha256Hex(ofFileAt: source)
        let after = #"<row r="1"><c r="A1"><v>1</v></c></row><row r="2"><c r="A2"><v>2</v></c></row>"#
        let replayEntries = workbookData(sheetData: after)
        let factory = FakeServiceSessionFactory { working in
            try? FileManager.default.removeItem(at: working)
            let archive = try Archive(url: working, accessMode: .create)
            for (path, value) in replayEntries {
                try archive.addFloeEntry(path: path, data: Data(value.utf8))
            }
        }
        let executor = OfficeAutomaticExecutor(factory: factory)
        let (proof, _) = authorization(runID: UUID(), taskID: UUID())
        let request = try proposal(for: "report.xlsx", baseSHA256: sourceSHA,
                                   commands: [.excelInsertRows(count: 1, at: "A1")])
        let first = try await executor.execute(proposal: request, authorization: proof,
                                               relativeOutput: "report.edited.xlsx",
                                               requestID: "req-1", access: access(root: root))
        let second = try await executor.execute(proposal: request, authorization: proof,
                                                relativeOutput: "report.edited.xlsx",
                                                requestID: "req-1", access: access(root: root))
        #expect(!first.replay)
        #expect(second.replay)
        #expect(second.outputSHA256 == first.outputSHA256)
        #expect(await factory.openCount == 1)
    }

    @Test("a session that is not editable fails closed")
    func notEditable() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("report.xlsx")
        try writePackage(source, entries: workbookData(sheetData: #"<row r="1"><c r="A1"><v>1</v></c></row>"#))
        let sourceSHA = try FloeDigest.sha256Hex(ofFileAt: source)
        let factory = FakeServiceSessionFactory(
            status: OfficeServiceSessionStatus(editable: false,
                                               unavailableReason: "read-only protected"),
            plan: { _ in })
        let executor = OfficeAutomaticExecutor(factory: factory)
        let (proof, _) = authorization(runID: UUID(), taskID: UUID())
        await #expect(throws: OfficeAutomaticExecutionError.self) {
            try await executor.execute(
                proposal: try self.proposal(for: "report.xlsx", baseSHA256: sourceSHA,
                                            commands: [.excelInsertRows(count: 1, at: "A1")]),
                authorization: proof, relativeOutput: nil, requestID: "req-ro",
                access: self.access(root: root))
        }
        #expect(await factory.sessions.first?.appliedCommands.isEmpty == true)
        #expect(await factory.sessions.first?.closed == true)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("report.edited.xlsx").path))
    }

    @Test("a mismatched authorization proof is refused before any session")
    func mismatchedAuthorization() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("report.xlsx")
        try writePackage(source, entries: workbookData(sheetData: #"<row r="1"><c r="A1"><v>1</v></c></row>"#))
        let sourceSHA = try FloeDigest.sha256Hex(ofFileAt: source)
        let factory = FakeServiceSessionFactory { _ in }
        let executor = OfficeAutomaticExecutor(factory: factory)
        let badBinding = RuntimeAuthorityBinding(
            runID: UUID(), taskID: nil, environmentBinding: "x", canonicalTarget: "workspace:x",
            toolName: "media.project", operation: "export", operationID: "c", idempotencyKey: "k",
            baseRevision: nil, payloadDigest: "d")
        let proof = OfficeAutomaticAuthorization(runID: UUID(), taskID: nil, operationID: "c",
                                                 idempotencyKey: "k", approvalGrantID: nil,
                                                 binding: badBinding)
        await #expect(throws: OfficeAutomaticExecutionError.self) {
            try await executor.execute(
                proposal: try self.proposal(for: "report.xlsx", baseSHA256: sourceSHA,
                                            commands: [.excelInsertRows(count: 1, at: "A1")]),
                authorization: proof, relativeOutput: nil, requestID: "req-bad",
                access: self.access(root: root))
        }
        #expect(await factory.openCount == 0)
    }

    @Test("an unacknowledged close retains the working copy and never publishes success")
    func unacknowledgedCloseRetainsStaging() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("close-fail.xlsx")
        try writePackage(source, entries: workbookData(sheetData: #"<row r="1"><c r="A1"><v>1</v></c></row>"#))
        let sourceSHA = try FloeDigest.sha256Hex(ofFileAt: source)
        // The session saves the "recalculated" bytes, but its close fails.
        let factory = FakeServiceSessionFactory(
            closeError: FakeCloseFailure(),
            plan: { _ in }
        )
        let executor = OfficeAutomaticExecutor(factory: factory)
        let (proof, _) = authorization(runID: UUID(), taskID: UUID())
        await #expect(throws: OfficeAutomaticExecutionError.self) {
            try await executor.execute(
                proposal: try self.proposal(for: "close-fail.xlsx", baseSHA256: sourceSHA,
                                            commands: [.excelInsertRows(count: 1, at: "A1")]),
                authorization: proof, relativeOutput: "close-fail.edited.xlsx", requestID: "req-close",
                access: self.access(root: root))
        }
        // No output was published and the source is unchanged...
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("close-fail.edited.xlsx").path))
        #expect(try FloeDigest.sha256Hex(ofFileAt: source) == sourceSHA)
        // ...while the staging working copy is RETAINED for recovery.
        let retained = root.appendingPathComponent(".floe-automation")
        #expect(FileManager.default.fileExists(atPath: retained.path),
                "the working copy must be retained while a close is unacknowledged")
        // The typed failure says exactly what happened.
        do {
            _ = try await executor.execute(
                proposal: try self.proposal(for: "close-fail.xlsx", baseSHA256: sourceSHA,
                                            commands: [.excelInsertRows(count: 1, at: "A1")]),
                authorization: proof, relativeOutput: "close-fail.edited.xlsx", requestID: "req-close-2",
                access: self.access(root: root))
            Issue.record("an unacknowledged close must not report success")
        } catch let error as OfficeAutomaticExecutionError {
            if case .sessionCloseUnacknowledged = error {
                #expect(error.isUnsafeResourceState)
            } else {
                Issue.record("unexpected error: \(error)")
            }
        }
    }

    @Test("an unsafe open failure retains the working copy and reports the typed failure")
    func unsafeOpenRetainsStaging() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("open-fail.xlsx")
        try writePackage(source, entries: workbookData(sheetData: #"<row r="1"><c r="A1"><v>1</v></c></row>"#))
        let sourceSHA = try FloeDigest.sha256Hex(ofFileAt: source)
        let factory = FakeServiceSessionFactory(
            openError: OfficeAutomaticExecutionError.sessionOpenUnsafe("close was not acknowledged"),
            plan: { _ in })
        let executor = OfficeAutomaticExecutor(factory: factory)
        let (proof, _) = authorization(runID: UUID(), taskID: UUID())
        do {
            _ = try await executor.execute(
                proposal: try self.proposal(for: "open-fail.xlsx", baseSHA256: sourceSHA,
                                            commands: [.excelInsertRows(count: 1, at: "A1")]),
                authorization: proof, relativeOutput: "open-fail.edited.xlsx", requestID: "req-open",
                access: self.access(root: root))
            Issue.record("an unsafe open must not report success")
        } catch let error as OfficeAutomaticExecutionError {
            #expect(error.isUnsafeResourceState)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("open-fail.edited.xlsx").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".floe-automation").path),
                "the working copy must be retained when the open left native resources behind")
    }

    @Test("a successful run still cleans its staging directory")
    func successfulRunCleansStaging() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("clean.xlsx")
        try writePackage(source, entries: workbookData(sheetData: #"<row r="1"><c r="A1"><v>1</v></c></row>"#))
        let sourceSHA = try FloeDigest.sha256Hex(ofFileAt: source)
        // The fake engine really inserts the promised row so the executor's
        // saved-package verification passes.
        let afterEntries = workbookData(
            sheetData: #"<row r="1"><c r="A1"><v>1</v></c></row><row r="2"><c r="A2"><v></v></c></row>"#)
        let factory = FakeServiceSessionFactory { working in
            try? FileManager.default.removeItem(at: working)
            let archive = try Archive(url: working, accessMode: .create)
            for (path, value) in afterEntries {
                try archive.addFloeEntry(path: path, data: Data(value.utf8))
            }
        }
        let executor = OfficeAutomaticExecutor(factory: factory)
        let (proof, _) = authorization(runID: UUID(), taskID: UUID())
        _ = try await executor.execute(
            proposal: try self.proposal(for: "clean.xlsx", baseSHA256: sourceSHA,
                                        commands: [.excelInsertRows(count: 1, at: "A1")]),
            authorization: proof, relativeOutput: "clean.edited.xlsx", requestID: "req-clean",
            access: self.access(root: root))
        #expect(await factory.sessions.first?.closed == true)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".floe-automation").path),
                "a settled run must remove its staging")
    }

    @Test("Task cancellation at a safe boundary cancels the run and closes the session")
    func taskCancellationAtBoundaryCancels() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("task-cancel.xlsx")
        try writePackage(source, entries: workbookData(sheetData: #"<row r="1"><c r="A1"><v>1</v></c></row>"#))
        let sourceSHA = try FloeDigest.sha256Hex(ofFileAt: source)
        // A slow status step gives the test a deterministic safe boundary to
        // cancel the Task at (between open and apply).
        let factory = FakeServiceSessionFactory(statusDelayNanoseconds: 500_000_000) { _ in }
        let executor = OfficeAutomaticExecutor(factory: factory)
        let (proof, _) = authorization(runID: UUID(), taskID: UUID())
        let proposal = try self.proposal(for: "task-cancel.xlsx", baseSHA256: sourceSHA,
                                         commands: [.excelInsertRows(count: 1, at: "A1")])
        let task = Task {
            try await executor.execute(proposal: proposal, authorization: proof,
                                       relativeOutput: "task-cancel.edited.xlsx", requestID: "req-task",
                                       access: self.access(root: root))
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("a cancelled Task must not complete the automatic run")
        } catch let error as OfficeAutomaticExecutionError {
            if case .cancelled = error {
                // Expected: the run left at its safe pre-effect boundary.
            } else {
                Issue.record("unexpected error: \(error)")
            }
        }
        #expect(await factory.sessions.first?.closed == true,
                "the session must be closed after a Task cancellation")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("task-cancel.edited.xlsx").path))
    }

    @Test("a cancelled run whose close fails keeps the unsafe truth and staging")
    func cancellationWithUnacknowledgedClose() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("cancel-close.xlsx")
        try writePackage(source, entries: workbookData(sheetData: #"<row r="1"><c r="A1"><v>1</v></c></row>"#))
        let sourceSHA = try FloeDigest.sha256Hex(ofFileAt: source)
        // The engine reports cancellation mid-save, and its close is never
        // acknowledged: the run must NOT be reported as a clean cancellation.
        let factory = FakeServiceSessionFactory(
            saveError: FloeError.cancelled,
            closeError: FakeCloseFailure(),
            plan: { _ in })
        let executor = OfficeAutomaticExecutor(factory: factory)
        let (proof, _) = authorization(runID: UUID(), taskID: UUID())
        do {
            _ = try await executor.execute(
                proposal: try self.proposal(for: "cancel-close.xlsx", baseSHA256: sourceSHA,
                                            commands: [.excelInsertRows(count: 1, at: "A1")]),
                authorization: proof, relativeOutput: "cancel-close.edited.xlsx", requestID: "req-cc",
                access: self.access(root: root))
            Issue.record("an unacknowledged close must not be reported as a clean cancellation")
        } catch let error as OfficeAutomaticExecutionError {
            if case .sessionCloseUnacknowledged = error {
                #expect(error.isUnsafeResourceState)
            } else {
                Issue.record("unexpected error (a clean cancellation would hide live workers): \(error)")
            }
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("cancel-close.edited.xlsx").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".floe-automation").path),
                "staging must be retained while the engine may still hold the working copy")
    }

    /// The shared safety contract's discriminant, measured on the REAL enum:
    /// conformance alone is not unsafe. Exactly the two lifecycle failures are
    /// unsafe; cancellation and every ordinary refusal keep the normal error
    /// path (a job service must not print retained-staging/live-worker text for
    /// them).
    @Test("the real Office enum marks exactly the two unsafe lifecycle failures as unsafe")
    func unsafeDiscriminantIsExact() {
        let all: [(OfficeAutomaticExecutionError, Bool)] = [
            (.notFound("missing.pptx"), false),
            (.sourceChanged, false),
            (.outputConflict("out.xlsx"), false),
            (.commandFormatMismatch(command: "excel.insertRows", format: "pptx"), false),
            (.selectionDependent(command: "word.style"), false),
            (.sessionUnavailable("no workspace"), false),
            (.sessionNotEditable("read-only"), false),
            (.sessionNotReady("starting"), false),
            (.saveFailed("engine refused"), false),
            (.verificationFailed("reopened copy mismatch"), false),
            (.cancelled, false),
            (.sessionCloseUnacknowledged("close timed out"), true),
            (.sessionOpenUnsafe("open left resources"), true),
        ]
        for (error, expected) in all {
            let label = "\(error)"
            #expect(error.isUnsafeResourceState == expected,
                    "\(label): the enum discriminant disagrees with the exact unsafe set")
            // The same decision must be visible through the shared contract the
            // job service reads (a bare `is UnsafeResourceStateError` cast is
            // NOT the decision).
            let contract = error as any UnsafeResourceStateError
            #expect(contract.isUnsafeResourceState == expected,
                    "\(label): the shared-contract discriminant must match the enum")
        }
        // A clean cancellation is explicitly not an unsafe resource state.
        #expect(OfficeAutomaticExecutionError.cancelled.isUnsafeResourceState == false)
        #expect((OfficeAutomaticExecutionError.outputConflict("out.xlsx") as any UnsafeResourceStateError)
            .isUnsafeResourceState == false)
        // ...and the two lifecycle failures are.
        #expect(OfficeAutomaticExecutionError.sessionCloseUnacknowledged("x").isUnsafeResourceState)
        #expect(OfficeAutomaticExecutionError.sessionOpenUnsafe("x").isUnsafeResourceState)
    }
}

/// A close failure for the fake service session.
struct FakeCloseFailure: LocalizedError {
    var errorDescription: String? { "fake engine did not acknowledge the close" }
}
