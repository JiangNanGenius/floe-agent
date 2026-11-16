// SPDX-License-Identifier: MPL-2.0
//
// Focused regression coverage for the background-job capture contract:
// the tool's already-sanitized capture (not the 4096-character display
// summary) is what the durable spool retains, and the artifact footer
// discloses whether that retained text is the complete execution output.
//
// Authored only: Main/recording owns the device and shared build resources.
// These tests use an in-memory database, a temporary spool root and a
// scripted runner; they execute no device command, model call or engine.
import XCTest
import Foundation
import FloeCore
import FloeTools
import FloePersistence
@testable import FloeAndroidJobTools

final class BackgroundJobCaptureTests: XCTestCase {

    // MARK: - Fixture

    /// One conversation + run for the durable ownership join BackgroundJobService
    /// and jobs.result both enforce.
    private func fixture() async throws -> (DatabaseManager, UUID, UUID) {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let conversation = UUID(), run = UUID()
        let now = ISO8601DateFormatter().string(from: Date())
        try await database.writer { db in
            try db.execute(sql: """
                INSERT INTO conversations (id, title, created_at, updated_at)
                VALUES (?, 'capture-tests', ?, ?)
                """, arguments: [conversation.uuidString, now, now])
            try db.execute(sql: """
                INSERT INTO runs (id, conversation_id, state, goal, started_at)
                VALUES (?, ?, 'running', 'capture-tests', ?)
                """, arguments: [run.uuidString, conversation.uuidString, now])
        }
        return (database, conversation, run)
    }

    private func runner(
        _ body: @escaping @Sendable (Data, ToolContext) async throws -> ToolExecutionOutput
    ) -> AnyAgentTool {
        AnyAgentTool(
            descriptor: ToolCatalog.Descriptor(
                name: "exec.shell",
                toolDescription: "scripted capture fixture",
                parametersJSON: #"{"type":"object"}"#,
                riskLabels: [],
                isSideEffecting: false),
            run: body)
    }

    /// The ORIGINAL service over a temporary explicit spool root (J2).
    private func makeService(
        database: DatabaseManager,
        root: URL,
        runner: AnyAgentTool
    ) -> BackgroundJobService {
        let registry = ToolRunnerRegistry()
        registry.register(runner)
        return BackgroundJobService(
            store: BackgroundJobStore(database: database),
            registry: registry,
            outputSpooler: { jobID, text, captureTruncated in
                guard let spooled = BackgroundJobOutputSpool.write(
                    jobID: jobID, text: text, root: root,
                    captureTruncated: captureTruncated) else {
                    throw FloeError.internalError("test spool write failed")
                }
                return spooled
            })
    }

    private func submit(_ service: BackgroundJobService, runID: UUID, root: URL,
                        callID: String) async throws -> BackgroundJob {
        try await service.submit(
            runID: runID, toolCallID: callID, targetTool: "exec.shell",
            payloadJSON: Data("{}".utf8), scope: .local,
            workspaceRootURL: root, allowedWorkspacePaths: [],
            submissionSource: .nativeService)
    }

    private func waitForTerminal(_ service: BackgroundJobService,
                                 id: UUID) async throws -> BackgroundJob {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let job = try await service.job(id: id), job.state.isTerminal {
                return job
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw FloeError.internalError("background job did not reach a terminal state in time")
    }

    private func pageArguments(jobID: UUID, offset: Int) -> JobsResultTool.Arguments {
        JobsResultTool.Arguments(jobID: jobID.uuidString, offset: offset, maxBytes: 4_096)
    }

    /// Pages the whole stored artifact through the REAL jobs.result path and
    /// returns the reassembled text plus the final page/note fields.
    private func reassemblePages(
        service: BackgroundJobService,
        root: URL,
        jobID: UUID,
        runID: UUID
    ) async throws -> (text: String, lastPage: [String: Any], lastNote: String?) {
        let tool = JobsResultTool(service: service, outputRoot: root)
        var offset = 0
        var collected = ""
        var lastPage: [String: Any] = [:]
        var lastNote: String?
        for _ in 0..<400 {
            let output = try await tool.execute(
                pageArguments(jobID: jobID, offset: offset),
                context: ToolContext(runID: runID, cancellation: CancellationToken()))
            guard let response = try JSONSerialization.jsonObject(
                with: Data(output.summary.utf8)) as? [String: Any] else {
                throw FloeError.internalError("jobs.result returned a non-object response")
            }
            guard let page = response["output"] as? [String: Any] else {
                throw FloeError.internalError(
                    "jobs.result returned no output page: \(output.summary)")
            }
            collected += (page["text"] as? String) ?? ""
            lastPage = page
            lastNote = response["note"] as? String
            guard let next = page["nextOffset"] as? Int else {
                return (collected, lastPage, lastNote)
            }
            offset = next
        }
        throw FloeError.internalError("jobs.result paging did not terminate")
    }

    // MARK: - Regression: capture is the result, summary is only a display bound

    /// The pre-fix defect: `fullOutput = output.summary` spooled only the 4096
    /// character display projection while `resultDigest` covered the full
    /// text. The retained artifact must now hold the whole sanitized capture.
    func testCapturedOutputBeyondDisplaySummarySurvivesSpoolAndReadback() async throws {
        let (database, _, runID) = try await fixture()
        let root = try JobTestRoot.make(name: "job-capture-full")
        defer { try? FileManager.default.removeItem(at: root) }

        let rows = (0..<500).map { "line-\($0)-result-payload-abcdefghij" }
        let fullText = rows.joined(separator: "\n") + "\nTAIL-MARKER-capture-closed"
        let service = makeService(
            database: database, root: root,
            runner: runner { _, _ in ToolExecutionOutput(digesting: fullText) })

        let submitted = try await submit(service, runID: runID, root: root,
                                         callID: "call-capture-full")
        let terminal = try await waitForTerminal(service, id: submitted.id)
        XCTAssertEqual(terminal.state, .completed)

        // The durable summary stays bounded and cannot contain the tail.
        let summary = try XCTUnwrap(terminal.resultSummary)
        XCTAssertLessThanOrEqual(summary.count, 4_096)
        XCTAssertFalse(summary.contains("TAIL-MARKER-capture-closed"))

        let outputBytes = try XCTUnwrap(terminal.outputBytes)
        XCTAssertGreaterThan(outputBytes, 4_096,
                             "the spool must retain the capture, not the summary")
        let path = try XCTUnwrap(terminal.outputPath)
        let metadata = try XCTUnwrap(BackgroundJobOutputSpool.readMetadata(
            path: path, jobID: terminal.id, root: root))
        XCTAssertFalse(metadata.truncated)
        XCTAssertFalse(metadata.captureTruncated)
        XCTAssertEqual(metadata.originalBytes, metadata.savedBytes)

        let paged = try await reassemblePages(
            service: service, root: root, jobID: terminal.id, runID: runID)
        XCTAssertTrue(paged.text.contains("line-499-result-payload-abcdefghij"))
        XCTAssertTrue(paged.text.contains("TAIL-MARKER-capture-closed"))
        // The stored payload is exactly the text the producer digested.
        XCTAssertEqual(FloeDigest.sha256Hex(Data(paged.text.utf8)),
                       try XCTUnwrap(terminal.resultDigest))
        XCTAssertEqual(paged.lastPage["complete"] as? Bool, true)
        XCTAssertEqual(paged.lastPage["captureTruncated"] as? Bool, false)
        XCTAssertTrue(paged.lastNote?.contains("last page of the complete output") == true)
    }

    /// A producer that declares its own capture incomplete must never be
    /// presented as a complete job output, even when the spool itself did not
    /// cut anything.
    func testProducerTruncatedCaptureStaysHonest() async throws {
        let (database, _, runID) = try await fixture()
        let root = try JobTestRoot.make(name: "job-capture-upstream")
        defer { try? FileManager.default.removeItem(at: root) }

        let rows = (0..<300).map { "row-\($0)-retained-payload" }
        let retained = rows.joined(separator: "\n") + "\nRETAINED-TAIL"
        let service = makeService(
            database: database, root: root,
            runner: runner { _, _ in
                ToolExecutionOutput(
                    summary: "retained head",
                    fullOutputSHA256: FloeDigest.sha256Hex(Data(retained.utf8)),
                    capturedOutput: retained,
                    capturedOutputTruncated: true)
            })

        let submitted = try await submit(service, runID: runID, root: root,
                                         callID: "call-capture-upstream")
        let terminal = try await waitForTerminal(service, id: submitted.id)
        XCTAssertEqual(terminal.state, .completed)

        let path = try XCTUnwrap(terminal.outputPath)
        let metadata = try XCTUnwrap(BackgroundJobOutputSpool.readMetadata(
            path: path, jobID: terminal.id, root: root))
        XCTAssertTrue(metadata.truncated)
        XCTAssertTrue(metadata.captureTruncated)
        XCTAssertNil(metadata.originalBytes,
                     "an already-truncated upstream capture has no known original size")

        let paged = try await reassemblePages(
            service: service, root: root, jobID: terminal.id, runID: runID)
        // Everything retained is readable and matches the producer's digest...
        XCTAssertTrue(paged.text.contains("RETAINED-TAIL"))
        XCTAssertEqual(FloeDigest.sha256Hex(Data(paged.text.utf8)),
                       try XCTUnwrap(terminal.resultDigest))
        // ...but the artifact is never presented as the complete output.
        XCTAssertEqual(paged.lastPage["complete"] as? Bool, false)
        XCTAssertEqual(paged.lastPage["captureTruncated"] as? Bool, true)
        XCTAssertTrue(paged.lastNote?.contains("original output size is unknown") == true)
    }

    /// Fallback case: a producer supplies no capture while its summary was
    /// already clipped. The service may only spool that clipped summary, but it
    /// must mark the artifact incomplete instead of claiming completeness.
    func testSummaryOnlyFallbackCannotClaimComplete() async throws {
        let (database, _, runID) = try await fixture()
        let root = try JobTestRoot.make(name: "job-capture-fallback")
        defer { try? FileManager.default.removeItem(at: root) }

        let fullText = String(repeating: "0123456789", count: 900)
        let service = makeService(
            database: database, root: root,
            runner: runner { _, _ in
                var output = ToolExecutionOutput(digesting: fullText)
                // Simulate a producer that dropped its own capture and left
                // only the display summary.
                output.capturedOutput = nil
                output.summaryTruncated = true
                return output
            })

        let submitted = try await submit(service, runID: runID, root: root,
                                         callID: "call-capture-fallback")
        let terminal = try await waitForTerminal(service, id: submitted.id)
        XCTAssertEqual(terminal.state, .completed)

        let path = try XCTUnwrap(terminal.outputPath)
        let metadata = try XCTUnwrap(BackgroundJobOutputSpool.readMetadata(
            path: path, jobID: terminal.id, root: root))
        XCTAssertTrue(metadata.truncated)
        XCTAssertTrue(metadata.captureTruncated)
        XCTAssertNil(metadata.originalBytes)
        XCTAssertEqual(metadata.savedBytes, 4_096)

        let paged = try await reassemblePages(
            service: service, root: root, jobID: terminal.id, runID: runID)
        XCTAssertEqual(paged.text.utf8.count, 4_096)
        // The retained summary is not the digested full text; claiming it
        // complete would repeat the original false-completeness defect.
        XCTAssertNotEqual(FloeDigest.sha256Hex(Data(paged.text.utf8)),
                          try XCTUnwrap(terminal.resultDigest))
        XCTAssertEqual(paged.lastPage["complete"] as? Bool, false)
        XCTAssertTrue(paged.lastNote?.contains("original output size is unknown") == true)
        XCTAssertLessThanOrEqual((terminal.resultSummary ?? "").count, 4_096)
    }

    /// An explicitly empty capture is authoritative: the display caption is
    /// not spooled as output, and the verified empty artifact reads back as a
    /// complete empty first page instead of "no longer available".
    func testExplicitEmptyCaptureStaysEmptyAndReadsAsComplete() async throws {
        let (database, _, runID) = try await fixture()
        let root = try JobTestRoot.make(name: "job-capture-empty")
        defer { try? FileManager.default.removeItem(at: root) }

        let service = makeService(
            database: database, root: root,
            runner: runner { _, _ in
                ToolExecutionOutput(
                    summary: "DISPLAY-ONLY-CAPTION",
                    fullOutputSHA256: FloeDigest.sha256Hex(Data()),
                    capturedOutput: "")
            })

        let submitted = try await submit(service, runID: runID, root: root,
                                         callID: "call-capture-empty")
        let terminal = try await waitForTerminal(service, id: submitted.id)
        XCTAssertEqual(terminal.state, .completed)
        XCTAssertEqual(terminal.resultSummary, "DISPLAY-ONLY-CAPTION")

        let path = try XCTUnwrap(terminal.outputPath)
        let metadata = try XCTUnwrap(BackgroundJobOutputSpool.readMetadata(
            path: path, jobID: terminal.id, root: root))
        XCTAssertEqual(metadata.savedBytes, 0)
        XCTAssertEqual(metadata.originalBytes, 0)
        XCTAssertFalse(metadata.truncated)
        XCTAssertEqual(terminal.resultDigest, FloeDigest.sha256Hex(Data()))

        let paged = try await reassemblePages(
            service: service, root: root, jobID: terminal.id, runID: runID)
        XCTAssertEqual(paged.text, "")
        XCTAssertEqual(paged.lastPage["pageBytes"] as? Int, 0)
        XCTAssertEqual(paged.lastPage["complete"] as? Bool, true)
    }

    /// The spool cap still applies to an already-sanitized capture; when the
    /// producer did not itself truncate, the cut is reported with a KNOWN
    /// original size and the cap is named as the reason.
    func testCapCutKeepsSpoolBoundAndReportsKnownSize() async throws {
        let (database, _, runID) = try await fixture()
        let root = try JobTestRoot.make(name: "job-capture-cap")
        defer { try? FileManager.default.removeItem(at: root) }

        let fullText = String(repeating: "b", count: 1_200_000)
        let service = makeService(
            database: database, root: root,
            runner: runner { _, _ in
                ToolExecutionOutput(
                    summary: "head",
                    fullOutputSHA256: FloeDigest.sha256Hex(Data(fullText.utf8)),
                    capturedOutput: fullText)
            })

        let submitted = try await submit(service, runID: runID, root: root,
                                         callID: "call-capture-cap")
        let terminal = try await waitForTerminal(service, id: submitted.id)
        XCTAssertEqual(terminal.state, .completed)

        let path = try XCTUnwrap(terminal.outputPath)
        let metadata = try XCTUnwrap(BackgroundJobOutputSpool.readMetadata(
            path: path, jobID: terminal.id, root: root))
        XCTAssertTrue(metadata.truncated)
        XCTAssertFalse(metadata.captureTruncated)
        XCTAssertEqual(metadata.savedBytes, BackgroundJobOutputSpool.maximumArtifactBytes)
        XCTAssertEqual(metadata.originalBytes, 1_200_000)

        let tool = JobsResultTool(service: service, outputRoot: root)
        let output = try await tool.execute(
            JobsResultTool.Arguments(
                jobID: terminal.id.uuidString,
                offset: BackgroundJobOutputSpool.maximumArtifactBytes - 64,
                maxBytes: 256),
            context: ToolContext(runID: runID, cancellation: CancellationToken()))
        let response = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(output.summary.utf8))
                as? [String: Any])
        let page = try XCTUnwrap(response["output"] as? [String: Any])
        XCTAssertEqual(page["complete"] as? Bool, false)
        XCTAssertTrue((response["note"] as? String)?.contains("bounded prefix") == true)
    }
}
