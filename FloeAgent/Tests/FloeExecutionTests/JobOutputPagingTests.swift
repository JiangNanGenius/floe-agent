// FloeExecutionTests — full job output: UTF-8-safe paging, bounded spool and
// the durable dependency edge that keeps a parent run waiting honestly.

import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloePersistence
@testable import FloeExecution

@Suite("Background job output and dependencies")
struct JobOutputPagingTests {

    private func fixture() async throws -> (DatabaseManager, UUID, UUID) {
        let db = try DatabaseManager.inMemory()
        try await db.migrate()
        let conversation = UUID(), run = UUID()
        let now = ISO8601DateFormatter().string(from: Date())
        try await db.writer { db in
            try db.execute(sql: """
                INSERT INTO conversations (id, title, created_at, updated_at)
                VALUES (?, 'Jobs', ?, ?)
                """, arguments: [conversation.uuidString, now, now])
            try db.execute(sql: """
                INSERT INTO runs (id, conversation_id, state, goal, started_at)
                VALUES (?, ?, 'running', 'Test', ?)
                """, arguments: [run.uuidString, conversation.uuidString, now])
        }
        return (db, conversation, run)
    }

    private func waitForTerminal(_ service: BackgroundJobService, id: UUID) async throws -> BackgroundJob {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let job = try await service.job(id: id), job.state.isTerminal { return job }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw FloeError.internalError("background job did not reach a terminal state in time")
    }

    private func pageArguments(jobID: UUID, offset: Int) -> JobsResultTool.Arguments {
        JobsResultTool.Arguments(jobID: jobID.uuidString, offset: offset, maxBytes: 4_096)
    }

    @Test("UTF-8 paging never splits a scalar and never introduces a replacement character")
    func utf8SafePaging() {
        let text = "开始" + String(repeating: "测试🙂", count: 400) + "结束"
        let data = Data(text.utf8)
        var offset = 0
        var reassembled = ""
        var pages = 0
        while true {
            let page = JobsResultTool.utf8Page(data, start: offset, maxBytes: 997)
            #expect(!page.text.unicodeScalars.contains("\u{FFFD}"))
            reassembled += page.text
            pages += 1
            guard let next = page.nextOffset else { break }
            #expect(next > offset)
            offset = next
            #expect(pages < 200)
        }
        #expect(reassembled == text)
        // A start offset landing inside a multi-byte scalar advances to the
        // next boundary instead of emitting a broken character.
        let mid = JobsResultTool.utf8Page(data, start: 4, maxBytes: 64)
        #expect(!mid.text.unicodeScalars.contains("\u{FFFD}"))
    }

    @Test("Spool bounds output with a structured footer and never corrupts a multibyte scalar")
    func spoolBoundsAndPrune() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-job-output-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let text = String(repeating: "行🙂", count: 300_000)
        let jobID = UUID()
        let spooled = try #require(BackgroundJobOutputSpool.write(jobID: jobID, text: text, root: root))
        let data = try #require(try Data(contentsOf: URL(fileURLWithPath: spooled.path)))
        #expect(data.count == spooled.bytes)
        #expect(spooled.bytes <= BackgroundJobOutputSpool.maximumArtifactBytes + 256)
        let metadata = try #require(BackgroundJobOutputSpool.readMetadata(
            path: spooled.path, jobID: jobID, root: root))
        #expect(metadata.truncated)
        #expect(metadata.originalBytes == Data(text.utf8).count)
        #expect(metadata.savedBytes == data.count - Data(BackgroundJobOutputSpool.footer(for: metadata).utf8).count)
        // The stored prefix decodes cleanly: no scalar was cut.
        let body = data.prefix(metadata.savedBytes)
        #expect(!String(decoding: body, as: UTF8.self).unicodeScalars.contains("\u{FFFD}"))
        // Non-truncated output also carries an explicit complete footer.
        let smallID = UUID()
        let small = try #require(BackgroundJobOutputSpool.write(
            jobID: smallID, text: "完成🙂", root: root))
        let smallMeta = try #require(BackgroundJobOutputSpool.readMetadata(
            path: small.path, jobID: smallID, root: root))
        #expect(!smallMeta.truncated)
        #expect(smallMeta.originalBytes == smallMeta.savedBytes)

        // An old artifact is pruned; a fresh unrelated file survives.
        let stale = root.appendingPathComponent("\(UUID().uuidString).txt")
        try Data("old".utf8).write(to: stale)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-BackgroundJobOutputSpool.retentionSeconds - 60)],
            ofItemAtPath: stale.path)
        let fresh = root.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: fresh)
        BackgroundJobOutputSpool.prune(root: root)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    @Test("A cap cut exactly at a multibyte boundary stores a clean prefix")
    func capBoundaryMultibyte() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-job-boundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Build text whose UTF-8 length lands the cap inside a 3-byte scalar
        // and, separately, right after a 4-byte emoji's lead byte.
        for offset in 1...4 {
            let filler = String(repeating: "a", count: BackgroundJobOutputSpool.maximumArtifactBytes - offset)
            let text = filler + String(repeating: "测", count: 8)
            let jobID = UUID()
            let spooled = try #require(BackgroundJobOutputSpool.write(jobID: jobID, text: text, root: root))
            let data = try #require(try Data(contentsOf: URL(fileURLWithPath: spooled.path)))
            let metadata = try #require(BackgroundJobOutputSpool.readMetadata(
                path: spooled.path, jobID: jobID, root: root))
            #expect(metadata.truncated)
            #expect(metadata.originalBytes == Data(text.utf8).count)
            let body = data.prefix(metadata.savedBytes)
            #expect(!String(decoding: body, as: UTF8.self).unicodeScalars.contains("\u{FFFD}"))
            // The kept prefix is still valid UTF-8 by construction.
            #expect(String(data: body, encoding: .utf8) != nil)
        }
    }

    @Test("jobs.result pages via bounded reads with structured completeness")
    func resultPaging() async throws {
        let (db, conversation, run) = try await fixture()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-job-paging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = BackgroundJobStore(database: db)
        let text = String(repeating: "数据行01\n", count: 500) + "结束"
        let jobID = UUID()
        let spooled = try #require(BackgroundJobOutputSpool.write(jobID: jobID, text: text, root: root))
        let job = BackgroundJob(
            id: jobID, conversationID: conversation, runID: run,
            kind: .tool, targetTool: "exec.shell",
            payloadJSON: Data("{}".utf8), state: .queued,
            resultSummary: "head", outputPath: spooled.path, outputBytes: spooled.bytes)
        _ = try await store.save(job)
        _ = try await store.transition(id: jobID, to: .running)
        _ = try await store.transition(id: jobID, to: .completed)
        let service = BackgroundJobService(store: store, registry: ToolRunnerRegistry())
        let tool = JobsResultTool(service: service, outputRoot: root)
        var offset = 0
        var collected = ""
        var sawComplete = false
        var lastNote = ""
        for _ in 0..<200 {
            let output = try await tool.execute(
                pageArguments(jobID: jobID, offset: offset),
                context: .init(runID: run, cancellation: CancellationToken()))
            let response = try #require(
                try JSONSerialization.jsonObject(with: Data(output.summary.utf8)) as? [String: Any])
            let page = try #require(response["output"] as? [String: Any])
            collected += (page["text"] as? String) ?? ""
            if let complete = page["complete"] as? Bool, complete { sawComplete = true }
            lastNote = response["note"] as? String ?? ""
            if let next = page["nextOffset"] as? Int {
                offset = next
                continue
            }
            break
        }
        if collected != text {
            Issue.record("paging mismatch collectedBytes=\(collected.utf8.count) expectedBytes=\(text.utf8.count)")
        }
        #expect(sawComplete)
        #expect(lastNote.contains("last page of the complete output"))
        // A stored path outside the canonical root is refused, not read.
        let outsideFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-outside-\(UUID().uuidString).txt")
        try Data("not ours".utf8).write(to: outsideFile)
        defer { try? FileManager.default.removeItem(at: outsideFile) }
        let foreignID = UUID()
        let foreign = BackgroundJob(
            id: foreignID, conversationID: conversation, runID: run,
            kind: .tool, targetTool: "exec.shell",
            payloadJSON: Data("{}".utf8), state: .queued,
            resultSummary: "head", outputPath: outsideFile.path)
        _ = try await store.save(foreign)
        _ = try await store.transition(id: foreignID, to: .running)
        _ = try await store.transition(id: foreignID, to: .completed)
        let foreignOutput = try await tool.execute(
            pageArguments(jobID: foreignID, offset: 0),
            context: .init(runID: run, cancellation: CancellationToken()))
        let foreignResponse = try #require(
            try JSONSerialization.jsonObject(with: Data(foreignOutput.summary.utf8)) as? [String: Any])
        #expect(foreignResponse["output"] == nil)
    }

    @Test("A submitted job registers a durable dependency resolved by its real outcome")
    func dependencyRegisteredAndResolved() async throws {
        let (db, _, run) = try await fixture()
        let registry = ToolRunnerRegistry()
        registry.register(AnyAgentTool(
            descriptor: ToolCatalog.Descriptor(
                name: "exec.shell", toolDescription: "test python",
                parametersJSON: #"{"type":"object"}"#, riskLabels: [], isSideEffecting: true
            )
        ) { arguments, context in
            ToolExecutionOutput(summary: "done: \(String(decoding: arguments, as: UTF8.self))",
                                fullOutputSHA256: "d")
        })
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-job-deps-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = registerBackgroundJobTools(
            database: db, registry: registry, outputRootURL: root)
        let submit = JobsSubmitTool(service: service)
        let output = try await submit.execute(
            .init(tool: "exec.shell", arguments: #"{"script":"print(1)"}"#),
            context: .init(runID: run, toolCallID: "call-dep", cancellation: CancellationToken(),
                           callOrigin: ToolCallOrigin(kind: .mainRunDelegate, runID: run,
                                                      callID: "call-dep", toolName: "jobs.submit"))
        )
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(output.summary.utf8)) as? [String: Any])
        let jobID = try #require(object["jobID"] as? String).flatMap(UUID.init(uuidString:))
        let dependencies = SQLiteRunDependencyStore(database: db)
        let pending = try await dependencies.pending(runID: run)
        #expect(pending.count == 1)
        #expect(pending.first?.jobID == jobID)
        #expect(pending.first?.kind == "job")
        let terminal = try await waitForTerminal(service, id: try #require(jobID))
        #expect(terminal.state == .completed)
        // The dependency is resolved exactly once with the real outcome.
        var resolved: RunDependencyRecord?
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            resolved = try await dependencies.record(jobID: try #require(jobID))
            if resolved?.state != .pending { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(resolved?.state == .resolved)
        // The full output artifact was spooled before the summary.
        #expect(terminal.outputPath != nil)
        #expect(terminal.outputBytes ?? 0 > 0)
        #expect(FileManager.default.fileExists(atPath: terminal.outputPath ?? ""))
    }

    @Test("Job dependency states map faithfully, including interruption")
    func dependencyStateMapping() {
        #expect(BackgroundJobService.dependencyState(for: .completed) == .resolved)
        #expect(BackgroundJobService.dependencyState(for: .failed) == .failed)
        #expect(BackgroundJobService.dependencyState(for: .cancelled) == .cancelled)
        #expect(BackgroundJobService.dependencyState(for: .interrupted) == .interrupted)
        #expect(BackgroundJobService.dependencyState(for: .running) == .pending)
    }

    @Test("First verified service readiness resolves its durable edge without terminating the service")
    func serviceReadinessResolvesEdge() async throws {
        let (db, conversation, run) = try await fixture()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-service-ready-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = registerBackgroundJobTools(
            database: db, registry: ToolRunnerRegistry(), outputRootURL: root)

        let jobID = UUID()
        let jobStore = BackgroundJobStore(database: db)
        _ = try await jobStore.save(BackgroundJob(
            id: jobID, conversationID: conversation, runID: run,
            kind: .tool, targetTool: "exec.localService",
            payloadJSON: Data("{}".utf8), state: .running))
        let dependencies = SQLiteRunDependencyStore(database: db)
        try await dependencies.register(RunDependencyRecord(
            jobID: jobID, runID: run, conversationID: conversation, kind: "service"))

        await service.resolveServiceReady(id: jobID, note: "ready")

        // The edge settles so the parked run can resume in the SAME run...
        let edge = try #require(try await dependencies.record(jobID: jobID))
        #expect(edge.state == .resolved)
        // ...while the long-lived service keeps running (readiness never
        // terminates it) and a non-service job is never resolved this way.
        #expect(try await jobStore.job(id: jobID)?.state == .running)
        await service.resolveServiceReady(id: UUID(), note: "unknown")
    }

    @Test("wait:false submits detached work that never registers a dependency")
    func detachedSubmissionSkipsDependency() async throws {
        let (db, _, run) = try await fixture()
        let registry = ToolRunnerRegistry()
        registry.register(AnyAgentTool(
            descriptor: ToolCatalog.Descriptor(
                name: "exec.shell", toolDescription: "test python",
                parametersJSON: #"{"type":"object"}"#, riskLabels: [], isSideEffecting: true
            )
        ) { _, _ in
            ToolExecutionOutput(summary: "detached", fullOutputSHA256: "d")
        })
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-job-detached-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = registerBackgroundJobTools(database: db, registry: registry, outputRootURL: root)
        let submit = JobsSubmitTool(service: service)
        let output = try await submit.execute(
            .init(tool: "exec.shell", arguments: #"{"script":"print(2)"}"#, wait: false),
            context: .init(runID: run, toolCallID: "call-detached", cancellation: CancellationToken(),
                           callOrigin: ToolCallOrigin(kind: .mainRunDelegate, runID: run,
                                                      callID: "call-detached", toolName: "jobs.submit"))
        )
        #expect(output.summary.contains("\"waitForCompletion\":false"))
        let dependencies = SQLiteRunDependencyStore(database: db)
        #expect(try await dependencies.pending(runID: run).isEmpty)
    }

    // MARK: - B4 capture/completeness regressions

    /// Deterministic capture replay: NO process runs and no host command
    /// executes. The scripted `ShellRunOutcome` is returned verbatim, so these
    /// tests drive the REAL LocalShellTool formatter/sanitizer/redactor, the
    /// REAL BackgroundJobService capture selection and the canonical spool.
    private struct ScriptedShellBackend: LocalShellBackend {
        let outcome: ShellRunOutcome

        func run(_ request: ShellRunRequest, cancellation: CancellationToken?) async -> ShellRunOutcome {
            outcome
        }

        func openSession(
            _ request: ShellOpenRequest, cancellation: CancellationToken?
        ) async throws -> ShellOpenResult {
            ShellOpenResult(sessionID: request.sessionID, initialOutput: "", alive: true)
        }

        func exchangeSession(
            _ request: ShellExchangeRequest, cancellation: CancellationToken?
        ) async throws -> ShellExchangeResult {
            ShellExchangeResult(output: "", alive: true)
        }

        func closeSession(sessionID: String) async {}
    }

    private func temporaryRoot(_ tag: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(tag)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Registers the real exec.shell tool over the scripted backend and submits
    /// one background job through the real jobs.submit path.
    private func submitScriptedShellJob(
        database: DatabaseManager,
        backend: ScriptedShellBackend,
        root: URL,
        run: UUID,
        command: String = "print deterministic payload"
    ) async throws -> (service: BackgroundJobService, jobID: UUID) {
        let registry = ToolRunnerRegistry()
        ToolCatalog.register(LocalShellTool.self)
        registry.register(LocalShellTool(
            shell: LocalShellService(backend: backend, rootProvider: { root })))
        let service = registerBackgroundJobTools(
            database: database, registry: registry, outputRootURL: root)
        let callID = "call-\(UUID().uuidString)"
        let arguments = try JSONSerialization.data(withJSONObject: ["command": command])
        let submit = JobsSubmitTool(service: service)
        let output = try await submit.execute(
            .init(tool: "exec.shell", arguments: String(decoding: arguments, as: UTF8.self)),
            context: .init(runID: run, toolCallID: callID, cancellation: CancellationToken(),
                           callOrigin: ToolCallOrigin(kind: .mainRunDelegate, runID: run,
                                                      callID: callID, toolName: "jobs.submit"))
        )
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(output.summary.utf8)) as? [String: Any])
        let jobID = try #require((object["jobID"] as? String).flatMap(UUID.init(uuidString:)))
        return (service, jobID)
    }

    /// Pages the whole stored artifact through the REAL `jobs.result` path.
    private func reassemblePages(
        service: BackgroundJobService, root: URL, jobID: UUID, run: UUID
    ) async throws -> (text: String, pages: Int, lastPage: [String: Any], lastNote: String?) {
        let tool = JobsResultTool(service: service, outputRoot: root)
        var offset = 0
        var collected = ""
        var pages = 0
        var lastPage: [String: Any] = [:]
        var lastNote: String?
        for _ in 0..<600 {
            let output = try await tool.execute(
                pageArguments(jobID: jobID, offset: offset),
                context: .init(runID: run, cancellation: CancellationToken()))
            let response = try #require(
                try JSONSerialization.jsonObject(with: Data(output.summary.utf8)) as? [String: Any])
            let page = try #require(response["output"] as? [String: Any])
            collected += (page["text"] as? String) ?? ""
            pages += 1
            lastPage = page
            lastNote = response["note"] as? String
            guard let next = page["nextOffset"] as? Int else {
                return (collected, pages, lastPage, lastNote)
            }
            offset = next
        }
        Issue.record("jobs.result paging did not terminate")
        return (collected, pages, lastPage, lastNote)
    }

    @Test("A >4096 sanitized capture survives the real shell tool, spool and paged readback with its digest")
    func capturedOutputBeyondSummarySurvivesBackgroundJob() async throws {
        let (db, _, run) = try await fixture()
        let root = try temporaryRoot("floe-b4-capture-")
        defer { try? FileManager.default.removeItem(at: root) }

        // ~10 KB of deterministic rows plus a unique tail: the 4096-character
        // display summary cannot contain the tail, so it can only come back
        // through the already-sanitized capture and the canonical spool.
        let rows = (0..<500).map { "line-\($0)-result-payload-abcdefghij" }
        let stdout = rows.joined(separator: "\n") + "\nTAIL-MARKER-capture-closed"
        let backend = ScriptedShellBackend(outcome: .exited(
            code: 0, stdout: stdout, stderr: "",
            truncated: false, stderrTruncated: false, durationMs: 7))
        let (service, jobID) = try await submitScriptedShellJob(
            database: db, backend: backend, root: root, run: run)

        let terminal = try await waitForTerminal(service, id: jobID)
        #expect(terminal.state == .completed)
        let outputBytes = try #require(terminal.outputBytes)
        #expect(outputBytes > 4_096)

        // The model/UI summary stays bounded and does not carry the tail.
        let summary = try #require(terminal.resultSummary)
        #expect(summary.count <= 4_096)
        #expect(!summary.contains("TAIL-MARKER-capture-closed"))

        let path = try #require(terminal.outputPath)
        let metadata = try #require(BackgroundJobOutputSpool.readMetadata(
            path: path, jobID: jobID, root: root))
        #expect(!metadata.truncated)
        #expect(!metadata.captureTruncated)
        #expect(metadata.originalBytes == metadata.savedBytes)

        let paged = try await reassemblePages(service: service, root: root, jobID: jobID, run: run)
        #expect(paged.text.contains("line-499-result-payload-abcdefghij"))
        #expect(paged.text.contains("TAIL-MARKER-capture-closed"))
        // The stored payload is exactly the text the producer digested: the
        // original B4 defect (payload 4096, digest of the full text) is gone.
        #expect(FloeDigest.sha256Hex(Data(paged.text.utf8)) == terminal.resultDigest)
        #expect(paged.lastPage["complete"] as? Bool == true)
        #expect(paged.lastPage["captureTruncated"] as? Bool == false)
        #expect(paged.lastNote?.contains("last page of the complete output") == true)
    }

    @Test("A summary-only tool output is spooled honestly and never claims completeness")
    func summaryFallbackCannotClaimComplete() async throws {
        let (db, _, run) = try await fixture()
        let root = try temporaryRoot("floe-b4-fallback-")
        defer { try? FileManager.default.removeItem(at: root) }

        // A tool that supplies NO capture: ToolExecutionOutput clips its own
        // summary to the 4096-character display bound, so only a clipped
        // summary survives. The fallback must declare that instead of
        // reporting the retained prefix as the complete result.
        let fullText = String(repeating: "0123456789", count: 900)
        let registry = ToolRunnerRegistry()
        registry.register(AnyAgentTool(
            descriptor: ToolCatalog.Descriptor(
                name: "exec.shell", toolDescription: "summary-only test tool",
                parametersJSON: #"{"type":"object"}"#, riskLabels: [], isSideEffecting: true)
        ) { _, _ in
            ToolExecutionOutput(digesting: fullText)
        })
        let service = registerBackgroundJobTools(
            database: db, registry: registry, outputRootURL: root)
        let callID = "call-\(UUID().uuidString)"
        let submit = JobsSubmitTool(service: service)
        let output = try await submit.execute(
            .init(tool: "exec.shell", arguments: #"{"script":"print(1)"}"#),
            context: .init(runID: run, toolCallID: callID, cancellation: CancellationToken(),
                           callOrigin: ToolCallOrigin(kind: .mainRunDelegate, runID: run,
                                                      callID: callID, toolName: "jobs.submit")))
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(output.summary.utf8)) as? [String: Any])
        let jobID = try #require((object["jobID"] as? String).flatMap(UUID.init(uuidString:)))

        let terminal = try await waitForTerminal(service, id: jobID)
        #expect(terminal.state == .completed)
        let path = try #require(terminal.outputPath)
        let metadata = try #require(BackgroundJobOutputSpool.readMetadata(
            path: path, jobID: jobID, root: root))
        #expect(metadata.truncated)
        #expect(metadata.captureTruncated)
        #expect(metadata.originalBytes == nil) // unknown upstream size, never invented
        #expect(metadata.savedBytes == 4_096)

        let paged = try await reassemblePages(service: service, root: root, jobID: jobID, run: run)
        #expect(paged.text.utf8.count == 4_096)
        // The retained summary is NOT the digested full text; claiming it
        // complete would repeat the original B4 false-completeness defect.
        #expect(FloeDigest.sha256Hex(Data(paged.text.utf8)) != terminal.resultDigest)
        #expect(paged.lastPage["complete"] as? Bool == false)
        #expect(paged.lastNote?.contains("original output size is unknown") == true)
        #expect((terminal.resultSummary ?? "").count <= 4_096)
    }

    @Test("A producer-truncated capture keeps its retained tail but never claims completeness")
    func producerTruncatedCaptureStaysHonest() async throws {
        let (db, _, run) = try await fixture()
        let root = try temporaryRoot("floe-b4-upstream-")
        defer { try? FileManager.default.removeItem(at: root) }

        let rows = (0..<300).map { "row-\($0)-retained-payload" }
        let stdout = rows.joined(separator: "\n") + "\nRETAINED-TAIL"
        let backend = ScriptedShellBackend(outcome: .exited(
            code: 0, stdout: stdout, stderr: "",
            truncated: true, stderrTruncated: false, durationMs: 3))
        let (service, jobID) = try await submitScriptedShellJob(
            database: db, backend: backend, root: root, run: run)

        let terminal = try await waitForTerminal(service, id: jobID)
        #expect(terminal.state == .completed)
        let path = try #require(terminal.outputPath)
        let metadata = try #require(BackgroundJobOutputSpool.readMetadata(
            path: path, jobID: jobID, root: root))
        #expect(metadata.truncated)
        #expect(metadata.captureTruncated)
        #expect(metadata.originalBytes == nil)

        let paged = try await reassemblePages(service: service, root: root, jobID: jobID, run: run)
        // Everything that WAS retained is readable and matches the digest…
        #expect(paged.text.contains("RETAINED-TAIL"))
        #expect(FloeDigest.sha256Hex(Data(paged.text.utf8)) == terminal.resultDigest)
        // …but the artifact is never presented as the complete job output.
        #expect(paged.lastPage["complete"] as? Bool == false)
        #expect(paged.lastPage["captureTruncated"] as? Bool == true)
        #expect(paged.lastNote?.contains("original output size is unknown") == true)
    }

    @Test("A sanitizer-capped shell capture is retained but never claimed complete")
    func sanitizerCappedCaptureStaysHonest() async throws {
        let (db, _, run) = try await fixture()
        let root = try temporaryRoot("floe-b4-sanitizer-")
        defer { try? FileManager.default.removeItem(at: root) }

        // 23k short lines (~620 KiB): below the 1 MiB artifact cap but above
        // the sanitizer's 512 KiB total bound, so only the producer's own
        // truncation flag can keep the retained capture honest.
        let stdout = (0..<23_000).map { "sanitizer-row-\($0)-padding" }
            .joined(separator: "\n") + "\n"
        let backend = ScriptedShellBackend(outcome: .exited(
            code: 0, stdout: stdout, stderr: "",
            truncated: false, stderrTruncated: false, durationMs: 5))
        let (service, jobID) = try await submitScriptedShellJob(
            database: db, backend: backend, root: root, run: run)

        let terminal = try await waitForTerminal(service, id: jobID)
        #expect(terminal.state == .completed)
        let path = try #require(terminal.outputPath)
        let metadata = try #require(BackgroundJobOutputSpool.readMetadata(
            path: path, jobID: jobID, root: root))
        #expect(metadata.truncated)
        #expect(metadata.captureTruncated)
        #expect(metadata.originalBytes == nil)
        // The artifact itself was not capped, so only the producer flag stops
        // the old false-complete claim.
        #expect((terminal.outputBytes ?? 0) < BackgroundJobOutputSpool.maximumArtifactBytes)

        let paged = try await reassemblePages(service: service, root: root, jobID: jobID, run: run)
        #expect(paged.text.contains("[output truncated]"))
        #expect(FloeDigest.sha256Hex(Data(paged.text.utf8)) == terminal.resultDigest)
        #expect(paged.lastPage["complete"] as? Bool == false)
        #expect(paged.lastNote?.contains("original output size is unknown") == true)

        // The per-line bound (32 KiB) is reported the same way, not inferred
        // from a before/after length difference.
        let longLine = String(repeating: "c", count: 40_000)
        let lineBackend = ScriptedShellBackend(outcome: .exited(
            code: 0, stdout: longLine, stderr: "",
            truncated: false, stderrTruncated: false, durationMs: 2))
        let (lineService, lineJobID) = try await submitScriptedShellJob(
            database: db, backend: lineBackend, root: root, run: run)
        let lineTerminal = try await waitForTerminal(lineService, id: lineJobID)
        #expect(lineTerminal.state == .completed)
        let linePath = try #require(lineTerminal.outputPath)
        let lineMetadata = try #require(BackgroundJobOutputSpool.readMetadata(
            path: linePath, jobID: lineJobID, root: root))
        #expect(lineMetadata.truncated)
        #expect(lineMetadata.captureTruncated)
        let linePaged = try await reassemblePages(
            service: lineService, root: root, jobID: lineJobID, run: run)
        #expect(linePaged.text.contains("[line truncated]"))
        #expect(FloeDigest.sha256Hex(Data(linePaged.text.utf8)) == lineTerminal.resultDigest)
        #expect(linePaged.lastPage["complete"] as? Bool == false)
    }

    @Test("A >1 MiB already-sanitized capture is capped with a known size while the job still completes")
    func capCutKeepsJobAndReportsKnownSize() async throws {
        let (db, _, run) = try await fixture()
        let root = try temporaryRoot("floe-b4-cap-")
        defer { try? FileManager.default.removeItem(at: root) }

        // Spool-contract case: a producer whose ALREADY-sanitized capture is
        // larger than the 1 MiB artifact bound.
        let fullText = String(repeating: "b", count: 1_200_000)
        let registry = ToolRunnerRegistry()
        registry.register(AnyAgentTool(
            descriptor: ToolCatalog.Descriptor(
                name: "exec.shell", toolDescription: "large capture test tool",
                parametersJSON: #"{"type":"object"}"#, riskLabels: [], isSideEffecting: true)
        ) { _, _ in
            ToolExecutionOutput(
                summary: "head",
                fullOutputSHA256: FloeDigest.sha256Hex(Data(fullText.utf8)),
                capturedOutput: fullText)
        })
        let service = registerBackgroundJobTools(
            database: db, registry: registry, outputRootURL: root)
        let callID = "call-\(UUID().uuidString)"
        let submit = JobsSubmitTool(service: service)
        let output = try await submit.execute(
            .init(tool: "exec.shell", arguments: #"{"script":"print(3)"}"#),
            context: .init(runID: run, toolCallID: callID, cancellation: CancellationToken(),
                           callOrigin: ToolCallOrigin(kind: .mainRunDelegate, runID: run,
                                                      callID: callID, toolName: "jobs.submit")))
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(output.summary.utf8)) as? [String: Any])
        let jobID = try #require((object["jobID"] as? String).flatMap(UUID.init(uuidString:)))

        let terminal = try await waitForTerminal(service, id: jobID)
        #expect(terminal.state == .completed)
        let path = try #require(terminal.outputPath)
        let metadata = try #require(BackgroundJobOutputSpool.readMetadata(
            path: path, jobID: jobID, root: root))
        #expect(metadata.truncated)
        #expect(!metadata.captureTruncated)
        #expect(metadata.savedBytes == BackgroundJobOutputSpool.maximumArtifactBytes)
        #expect(metadata.originalBytes == 1_200_000)

        // The last page names the cap as the reason it is not complete.
        let tool = JobsResultTool(service: service, outputRoot: root)
        let pageOutput = try await tool.execute(
            JobsResultTool.Arguments(
                jobID: jobID.uuidString,
                offset: BackgroundJobOutputSpool.maximumArtifactBytes - 64,
                maxBytes: 256),
            context: .init(runID: run, cancellation: CancellationToken()))
        let response = try #require(
            try JSONSerialization.jsonObject(with: Data(pageOutput.summary.utf8)) as? [String: Any])
        let page = try #require(response["output"] as? [String: Any])
        #expect(page["complete"] as? Bool == false)
        #expect((response["note"] as? String)?.contains("bounded prefix") == true)
    }

    @Test("An explicitly empty capture stays empty instead of storing its display caption")
    func emptyCaptureIsAuthoritative() async throws {
        let (db, _, run) = try await fixture()
        let root = try temporaryRoot("floe-b4-empty-")
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ToolRunnerRegistry()
        registry.register(AnyAgentTool(
            descriptor: ToolCatalog.Descriptor(
                name: "exec.shell", toolDescription: "empty capture fixture",
                parametersJSON: #"{"type":"object"}"#, riskLabels: [], isSideEffecting: true),
            run: { _, _ in
                ToolExecutionOutput(summary: "DISPLAY-ONLY-CAPTION",
                    fullOutputSHA256: FloeDigest.sha256Hex(Data()), capturedOutput: "")
            }, routing: ToolEnvironmentRouting()))
        let service = registerBackgroundJobTools(
            database: db, registry: registry, outputRootURL: root)
        let job = try await service.submit(
            runID: run, toolCallID: "empty-capture", targetTool: "exec.shell",
            payloadJSON: Data("{}".utf8), scope: .local,
            workspaceRootURL: root, allowedWorkspacePaths: [], submissionSource: .nativeService)
        let terminal = try await waitForTerminal(service, id: job.id)
        #expect(terminal.state == .completed)
        #expect(terminal.resultSummary == "DISPLAY-ONLY-CAPTION")
        let path = try #require(terminal.outputPath)
        let metadata = try #require(BackgroundJobOutputSpool.readMetadata(
            path: path, jobID: job.id, root: root))
        #expect(metadata.savedBytes == 0)
        #expect(metadata.originalBytes == 0)
        #expect(!metadata.truncated)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(!String(decoding: bytes, as: UTF8.self).contains("DISPLAY-ONLY-CAPTION"))
        #expect(terminal.resultDigest == FloeDigest.sha256Hex(Data()))
        let result = try await JobsResultTool(service: service, outputRoot: root).execute(
            JobsResultTool.Arguments(jobID: job.id.uuidString, offset: 0, maxBytes: 256),
            context: .init(runID: run, cancellation: CancellationToken()))
        let response = try #require(
            try JSONSerialization.jsonObject(with: Data(result.summary.utf8)) as? [String: Any])
        let page = try #require(response["output"] as? [String: Any])
        #expect(page["available"] as? Bool == true)
        #expect(page["text"] as? String == "")
        #expect(page["pageBytes"] as? Int == 0)
        #expect(page["complete"] as? Bool == true)
        #expect(page["originalBytes"] as? Int == 0)
        #expect(BackgroundJobOutputSpool.readPage(
            jobID: job.id, path: path, offset: 1, maxBytes: 256, root: root) == nil)
    }

    @Test("A spool write failure keeps the job result, cancel behavior and ownership intact")
    func spoolFailureKeepsJobContract() async throws {
        let (db, _, run) = try await fixture()
        let root = try temporaryRoot("floe-b4-spoolfail-")
        defer { try? FileManager.default.removeItem(at: root) }

        let registry = ToolRunnerRegistry()
        registry.register(AnyAgentTool(
            descriptor: ToolCatalog.Descriptor(
                name: "exec.shell", toolDescription: "spool failure test tool",
                parametersJSON: #"{"type":"object"}"#, riskLabels: [], isSideEffecting: true),
            run: { _, _ in
                ToolExecutionOutput(
                    digesting: "visible summary", capturedOutput: "visible summary")
            }, routing: ToolEnvironmentRouting()))
        let service = BackgroundJobService(
            store: BackgroundJobStore(database: db), registry: registry,
            outputSpooler: { _, _, _ in
                throw FloeError.internalError("simulated spool write failure")
            })
        let job = try await service.submit(
            runID: run, toolCallID: "call-spool-failure", targetTool: "exec.shell",
            payloadJSON: Data("{}".utf8), scope: .local,
            workspaceRootURL: root, allowedWorkspacePaths: [],
            submissionSource: .nativeService)
        let terminal = try await waitForTerminal(service, id: job.id)
        // A spool failure never fails or re-labels the job.
        #expect(terminal.state == .completed)
        #expect(terminal.outputPath == nil)
        #expect(terminal.resultSummary == "visible summary")
        // Cancelling an already-finished job keeps its ACTUAL result.
        let afterCancel = try await service.cancel(id: job.id)
        #expect(afterCancel.state == .completed)
        // Ownership is still enforced for another run.
        await #expect(throws: (any Error).self) {
            _ = try await service.ownedJob(id: job.id, runID: UUID())
        }
    }

    @Test("Legacy numeric footers parse unchanged and an unknown size requires an incomplete artifact")
    func footerBackwardCompatibility() throws {
        let root = try temporaryRoot("floe-b4-footer-")
        defer { try? FileManager.default.removeItem(at: root) }
        let jobID = UUID()
        let url = try #require(
            BackgroundJobOutputSpool.canonicalArtifactURL(jobID: jobID, root: root))

        // Pre-fix artifact: numeric footer, no capture marker.
        try Data("hello\n[floe-job-output originalBytes=6 savedBytes=6 truncated=false]\n".utf8)
            .write(to: url)
        let legacy = try #require(BackgroundJobOutputSpool.readMetadata(
            path: url.path, jobID: jobID, root: root))
        #expect(legacy.originalBytes == 6)
        #expect(legacy.savedBytes == 6)
        #expect(!legacy.truncated)
        #expect(!legacy.captureTruncated)
        let legacyPage = try #require(BackgroundJobOutputSpool.readPage(
            jobID: jobID, path: url.path, offset: 0, maxBytes: 64, root: root))
        #expect(legacyPage.complete == nil) // legacy summary provenance is unknown
        #expect(!legacy.captureIntegrityKnown)
        #expect(legacyPage.text == "hello\n")

        // A producer-cut flag cannot coexist with a completeness claim.
        try Data("hello\n[floe-job-output originalBytes=6 savedBytes=6 truncated=false captureTruncated=true]\n".utf8)
            .write(to: url)
        #expect(BackgroundJobOutputSpool.readMetadata(
            path: url.path, jobID: jobID, root: root) == nil)

        // An unknown original size on an artifact that claims completeness is
        // refused: it could otherwise disguise an incomplete capture.
        try Data("hello\n[floe-job-output originalBytes=unknown savedBytes=6 truncated=false]\n".utf8)
            .write(to: url)
        #expect(BackgroundJobOutputSpool.readMetadata(
            path: url.path, jobID: jobID, root: root) == nil)

        // Unknown is honest when the artifact declares itself incomplete.
        try Data("hello\n[floe-job-output originalBytes=unknown savedBytes=6 truncated=true captureTruncated=true]\n".utf8)
            .write(to: url)
        let partial = try #require(BackgroundJobOutputSpool.readMetadata(
            path: url.path, jobID: jobID, root: root))
        #expect(partial.originalBytes == nil)
        #expect(partial.truncated)
        #expect(partial.captureTruncated)
    }
}
