// FloeExecutionTests — Background job store, service lifecycle, and tools.

import Foundation
import Testing
import FloeTools
import FloeCore
@testable import FloePersistence
@testable import FloeExecution

@Suite("Background jobs")
struct BackgroundJobTests {
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

    @Test("Store persists jobs, enforces the state machine, and dedupes by tool call")
    func storeContract() async throws {
        let (db, conversation, run) = try await fixture()
        let store = BackgroundJobStore(database: db)
        #expect(try await store.conversationID(runID: run) == conversation)

        let job = BackgroundJob(
            conversationID: conversation, runID: run, toolCallID: "call-1",
            kind: .tool, targetTool: "exec.localPython", payloadJSON: Data(#"{"script":"1"}"#.utf8)
        )
        let saved = try await store.submit(job)
        // Idempotent replay returns the original job.
        let replay = try await store.submit(BackgroundJob(
            conversationID: conversation, runID: run, toolCallID: "call-1",
            kind: .tool, targetTool: "exec.localPython", payloadJSON: Data(#"{"script":"2"}"#.utf8)
        ))
        #expect(replay.id == saved.id)

        let running = try await store.transition(id: saved.id, to: .running)
        #expect(running.state == .running)
        let completed = try await store.transition(id: saved.id, to: .completed) { $0.resultSummary = "done" }
        #expect(completed.state == .completed && completed.completedAt != nil)
        await #expect(throws: BackgroundJobStoreError.self) {
            try await store.transition(id: saved.id, to: .running)
        }
        #expect(try await store.jobs(conversationID: conversation).count == 1)
        #expect(try await store.activeJobs().isEmpty)
    }

    @Test("Service submits, executes off the run path, and reports terminal state")
    func serviceLifecycle() async throws {
        let (db, _, run) = try await fixture()
        let registry = ToolRunnerRegistry()
        registry.register(AnyAgentTool(
            descriptor: ToolCatalog.Descriptor(
                name: "exec.localPython", toolDescription: "test python",
                parametersJSON: #"{"type":"object"}"#, riskLabels: [], isSideEffecting: true
            )
        ) { arguments, context in
            // Simulate a slow cleaning job that honors cooperative cancellation.
            for _ in 0..<100 {
                try context.cancellation.throwIfCancelled()
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            return ToolExecutionOutput(summary: "cleaned rows: 42", fullOutputSHA256: "d")
        })
        let terminalJobs = TerminalJobCollector()
        let service = BackgroundJobService(
            store: BackgroundJobStore(database: db), registry: registry,
            onTerminal: { job in await terminalJobs.record(job.id) }
        )

        let submitTool = JobsSubmitTool(service: service)
        let output = try await submitTool.execute(
            .init(tool: "exec.localPython", arguments: #"{"script":"print(1)"}"#, purpose: "test"),
            context: .init(runID: run, toolCallID: "call-9", cancellation: CancellationToken())
        )
        let jobID = try #require(extractJobID(output.summary))
        // The submit returned immediately, long before the 500ms runner ends.
        let early = try #require(await service.job(id: jobID))
        #expect(early.state == .queued || early.state == .running)

        // Idempotent retry of the same tool call returns the same job.
        let retry = try await submitTool.execute(
            .init(tool: "exec.localPython", arguments: #"{"script":"changed"}"#),
            context: .init(runID: run, toolCallID: "call-9", cancellation: CancellationToken())
        )
        #expect(retry.summary.contains(jobID.uuidString))

        let terminal = try await waitForTerminal(service, id: jobID)
        #expect(terminal.state == .completed)
        #expect(terminal.resultSummary == "cleaned rows: 42")
        #expect(await terminalJobs.contains(jobID))

        // jobs.result surfaces the stored output.
        let resultTool = JobsResultTool(service: service)
        let collected = try await resultTool.execute(
            .init(jobID: jobID.uuidString),
            context: .init(runID: run, cancellation: CancellationToken())
        )
        #expect(collected.summary.contains("cleaned rows: 42"))

        // Status of an unknown job is a validation error, not a crash.
        await #expect(throws: (any Error).self) {
            try await JobsStatusTool(service: service).execute(
                .init(jobID: UUID().uuidString),
                context: .init(runID: run, cancellation: CancellationToken())
            )
        }
    }

    @Test("Cancelling a running job lands in the cancelled terminal state")
    func cancelRunningJob() async throws {
        let (db, _, run) = try await fixture()
        let registry = ToolRunnerRegistry()
        registry.register(AnyAgentTool(
            descriptor: ToolCatalog.Descriptor(
                name: "exec.localPython", toolDescription: "test python",
                parametersJSON: #"{"type":"object"}"#, riskLabels: [], isSideEffecting: true
            )
        ) { _, context in
            while true {
                try context.cancellation.throwIfCancelled()
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        })
        let service = BackgroundJobService(store: BackgroundJobStore(database: db), registry: registry)
        let submit = JobsSubmitTool(service: service)
        let output = try await submit.execute(
            .init(tool: "exec.localPython", arguments: #"{"script":"loop"}"#),
            context: .init(runID: run, toolCallID: "call-c", cancellation: CancellationToken())
        )
        let jobID = try #require(extractJobID(output.summary))
        try await Task.sleep(nanoseconds: 100_000_000)
        let cancelled = try await JobsCancelTool(service: service).execute(
            .init(jobID: jobID.uuidString),
            context: .init(runID: run, cancellation: CancellationToken())
        )
        #expect(cancelled.summary.contains("\"state\":\"cancelled\""))
        let terminal = try await waitForTerminal(service, id: jobID)
        #expect(terminal.state == .cancelled)
    }

    @Test("Launch reconciliation marks orphaned jobs interrupted")
    func reconcileInterrupted() async throws {
        let (db, conversation, run) = try await fixture()
        let store = BackgroundJobStore(database: db)
        let orphaned = try await store.save(BackgroundJob(
            conversationID: conversation, runID: run,
            kind: .tool, targetTool: "exec.localPython",
            payloadJSON: Data("{}".utf8), state: .running
        ))
        let service = BackgroundJobService(store: store, registry: ToolRunnerRegistry())
        #expect(try await service.reconcileInterruptedOnLaunch() == 1)
        #expect(try await store.job(id: orphaned.id)?.state == .interrupted)
    }

    @Test("Submit validates target allowlist and JSON object arguments")
    func submitValidation() async throws {
        let (db, _, run) = try await fixture()
        let service = BackgroundJobService(store: BackgroundJobStore(database: db), registry: ToolRunnerRegistry())
        let tool = JobsSubmitTool(service: service)
        #expect(throws: (any Error).self) {
            try tool.validate(.init(tool: "workspace.deleteEverything", arguments: "{}"))
        }
        #expect(throws: (any Error).self) {
            try tool.validate(.init(tool: "exec.localPython", arguments: "[1,2]"))
        }
        // A supported target without a registered runner fails honestly.
        await #expect(throws: (any Error).self) {
            try await tool.execute(
                .init(tool: "web.fetch", arguments: #"{"url":"https://example.com"}"#),
                context: .init(runID: run, toolCallID: "call-x", cancellation: CancellationToken())
            )
        }
    }

    private func extractJobID(_ summary: String) -> UUID? {
        guard let data = summary.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["jobID"] as? String else { return nil }
        return UUID(uuidString: raw)
    }
}

private actor TerminalJobCollector {
    private var ids: [UUID] = []
    func record(_ id: UUID) { ids.append(id) }
    func contains(_ id: UUID) -> Bool { ids.contains(id) }
}
