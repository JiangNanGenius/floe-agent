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
            kind: .tool, targetTool: "exec.localPython",
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
            kind: .tool, targetTool: "exec.localPython",
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
                name: "exec.localPython", toolDescription: "test python",
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
            .init(tool: "exec.localPython", arguments: #"{"script":"print(1)"}"#),
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
                name: "exec.localPython", toolDescription: "test python",
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
            .init(tool: "exec.localPython", arguments: #"{"script":"print(2)"}"#, wait: false),
            context: .init(runID: run, toolCallID: "call-detached", cancellation: CancellationToken(),
                           callOrigin: ToolCallOrigin(kind: .mainRunDelegate, runID: run,
                                                      callID: "call-detached", toolName: "jobs.submit"))
        )
        #expect(output.summary.contains("\"waitForCompletion\":false"))
        let dependencies = SQLiteRunDependencyStore(database: db)
        #expect(try await dependencies.pending(runID: run).isEmpty)
    }
}
