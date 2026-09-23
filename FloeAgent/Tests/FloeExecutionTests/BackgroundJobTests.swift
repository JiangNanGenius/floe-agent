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

    @Test("Submit rejects malformed target arguments at the call site")
    func submitValidatesTargetArguments() async throws {
        let (db, _, run) = try await fixture()
        let registry = ToolRunnerRegistry()
        registry.register(LocalPythonTool(service: LocalPythonService(version: "test") { _, _ in .cancelled }))
        let store = BackgroundJobStore(database: db)
        let service = BackgroundJobService(store: store, registry: registry)
        let tool = JobsSubmitTool(service: service)
        // exec.localPython requires `script`; a guessed `code` key must fail NOW,
        // not asynchronously, and the message must name the missing argument.
        do {
            _ = try await tool.execute(
                .init(tool: "exec.localPython", arguments: #"{"code":"print(1)","timeout":30}"#),
                context: .init(runID: run, toolCallID: "bad-args", cancellation: CancellationToken())
            )
            Issue.record("Expected submit-time argument validation")
        } catch {
            #expect(String(describing: error).contains("script"))
        }
        // No half-created job may linger after the fast failure.
        #expect(try await store.activeJobs().isEmpty)
    }

    @Test("Submit runs the tool's workspace preflight before persisting the job")
    func submitPreflightRejectsBeforePersist() async throws {
        let (db, _, run) = try await fixture()
        // The submit context carries the run's resolved workspace root; the
        // preflight is only meaningful against that root.
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-jobs-preflight-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let store = BackgroundJobStore(database: db)
        let registry = ToolRunnerRegistry()
        var runner = AnyAgentTool(descriptor: .init(name: "exec.localService", toolDescription: "test service",
            parametersJSON: #"{"type":"object"}"#, riskLabels: [], isSideEffecting: true)) { _, _ in
            ToolExecutionOutput(summary: "never", fullOutputSHA256: "never")
        }
        runner.preflightSubmission = { _, workspaceRoot in
            guard workspaceRoot != nil else { throw FloeError.validationFailed("no workspace") }
            throw FloeError.validationFailed("entry 'server.py' does not exist under the workspace")
        }
        registry.register(runner)
        let service = BackgroundJobService(store: store, registry: registry)
        let tool = JobsSubmitTool(service: service)
        do {
            _ = try await tool.execute(
                .init(tool: "exec.localService", arguments: #"{"runtime":"node","entry":"server.py","port":8080}"#),
                context: .init(
                    runID: run, toolCallID: "call-preflight",
                    workspaceRootURL: workspace, cancellation: CancellationToken()
                )
            )
            Issue.record("Expected the preflight failure at submit time")
        } catch {
            #expect(String(describing: error).contains("server.py"))
        }
        // Nothing may linger after the fast failure.
        #expect(try await store.activeJobs().isEmpty)
        // A passing preflight submits normally.
        runner.preflightSubmission = { _, workspaceRoot in
            guard workspaceRoot != nil else { throw FloeError.validationFailed("no workspace") }
        }
        registry.register(runner)
        let output = try await tool.execute(
            .init(tool: "exec.localService", arguments: #"{"runtime":"node","entry":"server.py","port":8080}"#),
            context: .init(
                runID: run, toolCallID: "call-preflight-ok",
                workspaceRootURL: workspace, cancellation: CancellationToken()
            )
        )
        #expect(output.summary.contains("jobID"))
    }

    @Test("Missing exec.localService port fails at submit time with an actionable message")
    func localServiceMissingPortFailsFast() async throws {
        let (db, _, run) = try await fixture()
        let registry = ToolRunnerRegistry()
        let parametersJSON = #"{"type":"object","properties":{"port":{"type":"integer","description":"Loopback port 1024..65535"}},"required":["port"]}"#
        // The runner mirrors the concrete exec.localService wiring: the same
        // typed decode of the required fields (so a missing argument names the
        // field AND its schema description) before the service persists.
        registry.register(AnyAgentTool(
            descriptor: .init(name: "exec.localService", toolDescription: "test service",
                parametersJSON: parametersJSON,
                riskLabels: [], isSideEffecting: true),
            run: { _, _ in ToolExecutionOutput(summary: "never", fullOutputSHA256: "never") },
            validateArguments: { payload in
                struct Payload: Decodable {
                    var runtime: String
                    var entry: String
                    var cwd: String?
                    var port: Int
                }
                do {
                    _ = try JSONDecoder().decode(Payload.self, from: payload)
                } catch let error as DecodingError {
                    throw FloeError.validationFailed(AnyAgentTool.describeDecodingError(
                        error, toolName: "exec.localService", parametersJSON: parametersJSON
                    ))
                }
            }
        ))
        let store = BackgroundJobStore(database: db)
        let service = BackgroundJobService(store: store, registry: registry)
        let tool = JobsSubmitTool(service: service)
        do {
            _ = try await tool.execute(
                .init(tool: "exec.localService", arguments: #"{"runtime":"node","entry":"server.py"}"#),
                context: .init(runID: run, toolCallID: "call-noport", cancellation: CancellationToken())
            )
            Issue.record("Expected a submit-time validation error")
        } catch {
            let message = String(describing: error)
            #expect(message.contains("port"))
            // The schema description is surfaced so the error is actionable.
            #expect(message.contains("Loopback port 1024..65535"))
        }
        #expect(try await store.activeJobs().isEmpty)
    }

    @Test("Local service preflight rejects missing entry and bad cwd before submit")
    func localServicePreflightPaths() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-preflight-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        try Data("console.log(1)".utf8).write(to: workspace.appendingPathComponent("server.js"))

        // Valid submission payload passes.
        try LocalServiceJobPreflight.validate(
            payloadJSON: Data(#"{"runtime":"node","entry":"server.js","port":8080}"#.utf8),
            workspaceRootURL: workspace)
        try LocalServiceJobPreflight.validate(
            payloadJSON: Data(#"{"runtime":"python","entry":"./server.js","cwd":".","port":65535}"#.utf8),
            workspaceRootURL: workspace)
        // Missing entry is rejected with the path and a fix hint.
        await #expect(throws: (any Error).self) {
            try LocalServiceJobPreflight.validate(
                payloadJSON: Data(#"{"runtime":"node","entry":"missing.js","port":8080}"#.utf8),
                workspaceRootURL: workspace)
        }
        do {
            try LocalServiceJobPreflight.validate(
                payloadJSON: Data(#"{"runtime":"node","entry":"missing.js","port":8080}"#.utf8),
                workspaceRootURL: workspace)
            Issue.record("Expected missing-entry rejection")
        } catch {
            #expect(String(describing: error).contains("missing.js"))
        }
        // Entry escaping the workspace is rejected.
        await #expect(throws: (any Error).self) {
            try LocalServiceJobPreflight.validate(
                payloadJSON: Data(#"{"runtime":"node","entry":"../outside.js","port":8080}"#.utf8),
                workspaceRootURL: workspace)
        }
        // Missing cwd directory is rejected.
        do {
            try LocalServiceJobPreflight.validate(
                payloadJSON: Data(#"{"runtime":"node","entry":"server.js","cwd":"no/such/dir","port":8080}"#.utf8),
                workspaceRootURL: workspace)
            Issue.record("Expected missing-cwd rejection")
        } catch {
            #expect(String(describing: error).contains("no/such/dir"))
        }
        // Port outside the managed range is rejected.
        await #expect(throws: (any Error).self) {
            try LocalServiceJobPreflight.validate(
                payloadJSON: Data(#"{"runtime":"node","entry":"server.js","port":80}"#.utf8),
                workspaceRootURL: workspace)
        }
        // A missing workspace root is actionable, not a silent pass.
        await #expect(throws: (any Error).self) {
            try LocalServiceJobPreflight.validate(
                payloadJSON: Data(#"{"runtime":"node","entry":"server.js","port":8080}"#.utf8),
                workspaceRootURL: nil)
        }
    }

    @Test("Persistent service cancellation stays running until the executor acknowledges exit")
    func serviceCancellationRetainsRunningState() async throws {
        let (db, _, run) = try await fixture()
        let store = BackgroundJobStore(database: db)
        let registry = ToolRunnerRegistry()
        let gate = ServiceExitGate()
        registry.register(AnyAgentTool(descriptor: .init(name: "exec.localService", toolDescription: "test service",
            parametersJSON: "{}", riskLabels: [], isSideEffecting: true)) { _, context in
                await gate.enter()
                while !context.cancellation.isCancelled { try await Task.sleep(for: .milliseconds(10)) }
                while !(await gate.canExit) { try await Task.sleep(for: .milliseconds(10)) }
                return ToolExecutionOutput(summary: "stopped", fullOutputSHA256: "stopped")
            })
        let service = BackgroundJobService(store: store, registry: registry)
        let job = try await service.submit(runID: run, toolCallID: "service", targetTool: "exec.localService",
            payloadJSON: Data("{}".utf8), scope: .local, workspaceRootURL: nil, allowedWorkspacePaths: [], environmentID: "owner")
        for _ in 0..<200 {
            if await gate.entered { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await gate.entered)
        let cancelled = try await service.cancel(id: job.id)
        #expect(cancelled.state == .running)
        try await store.updateProgress(id: job.id, data: Data(#"{"state":"stopping"}"#.utf8))
        #expect(try await store.activeJobs().contains(where: { $0.id == job.id }))
        await gate.allowExit()
        #expect(try await waitForTerminal(service, id: job.id).state == .cancelled)
        try await store.updateProgress(id: job.id, data: Data("late write".utf8))
        #expect(try await store.job(id: job.id)?.progressJSON == Data(#"{"state":"stopping"}"#.utf8))
        #expect(try await store.jobs(environmentID: "owner").count == 1)
        #expect(try await store.jobs(environmentID: "other").isEmpty)
    }

    @Test("Another task cannot read logs or cancel a background job")
    func jobOwnership() async throws {
        let (db, owner, run) = try await fixture()
        let otherRun = UUID()
        let now = ISO8601DateFormatter().string(from: Date())
        try await db.writer { db in
            let other = UUID().uuidString
            try db.execute(sql: "INSERT INTO conversations (id, title, created_at, updated_at) VALUES (?, 'Other', ?, ?)", arguments: [other, now, now])
            try db.execute(sql: "INSERT INTO runs (id, conversation_id, state, goal, started_at) VALUES (?, ?, 'running', 'Other', ?)", arguments: [otherRun.uuidString, other, now])
        }
        let store = BackgroundJobStore(database: db)
        let job = try await store.save(BackgroundJob(conversationID: owner, runID: run, kind: .tool,
            targetTool: "exec.localService", payloadJSON: Data("{}".utf8), state: .running))
        let service = BackgroundJobService(store: store, registry: ToolRunnerRegistry())
        let context = ToolContext(runID: otherRun, cancellation: CancellationToken())
        await #expect(throws: (any Error).self) { try await JobsStatusTool(service: service).execute(.init(jobID: job.id.uuidString), context: context) }
        await #expect(throws: (any Error).self) { try await JobsResultTool(service: service).execute(.init(jobID: job.id.uuidString), context: context) }
        await #expect(throws: (any Error).self) { try await JobsCancelTool(service: service).execute(.init(jobID: job.id.uuidString), context: context) }
        #expect(try await service.ownedJob(id: job.id, runID: run).state == .running)
        #expect(try await store.job(id: job.id)?.state == .running)
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

private actor ServiceExitGate {
    private(set) var entered = false
    private(set) var canExit = false
    func enter() { entered = true }
    func allowExit() { canExit = true }
}
