// FloeExecutionTests — action-aware native long-job admission, preflight,
// provenance and reconciliation.

import Foundation
import Testing
import FloeTools
import FloeCore
@testable import FloePersistence
@testable import FloeExecution

@Suite("Native job policy and adapters")
struct NativeJobPolicyTests {
    private func fixture() async throws -> (DatabaseManager, UUID, UUID, URL) {
        let db = try DatabaseManager.inMemory()
        try await db.migrate()
        let conversation = UUID(), run = UUID()
        let now = ISO8601DateFormatter().string(from: Date())
        try await db.writer { db in
            try db.execute(sql: """
                INSERT INTO conversations (id, title, created_at, updated_at)
                VALUES (?, 'Native jobs', ?, ?)
                """, arguments: [conversation.uuidString, now, now])
            try db.execute(sql: """
                INSERT INTO runs (id, conversation_id, state, goal, started_at)
                VALUES (?, ?, 'running', 'Test', ?)
                """, arguments: [run.uuidString, conversation.uuidString, now])
        }
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-job-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return (db, conversation, run, workspace)
    }

    private func registerEcho(_ registry: ToolRunnerRegistry, name: String,
                              boundary: ToolExecutionBoundary = .any,
                              effect: ToolEffect = .mutating) -> Recorder {
        let recorder = Recorder()
        registry.register(AnyAgentTool(descriptor: ToolCatalog.Descriptor(
            name: name, toolDescription: name, parametersJSON: #"{"type":"object"}"#,
            riskLabels: [], isSideEffecting: true, effect: effect,
            executionBoundary: boundary
        )) { arguments, context in
            await recorder.record(context: context, payload: arguments)
            return ToolExecutionOutput(summary: "done", fullOutputSHA256: "d")
        })
        return recorder
    }

    actor Recorder {
        private(set) var contexts: [(workspace: String?, conversation: UUID?, environment: String?)] = []
        private(set) var payloads: [Data] = []
        func record(context: ToolContext, payload: Data) {
            contexts.append((context.workspaceRootURL?.path, context.conversationID, context.environmentID))
            payloads.append(payload)
        }
    }

    private func waitForTerminal(_ service: BackgroundJobService, id: UUID) async throws -> BackgroundJob {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let job = try await service.job(id: id), job.state.isTerminal { return job }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw FloeError.internalError("job did not settle")
    }

    @Test("action admission rejects apply actions that must stay with their approving call")
    func actionAdmission() async throws {
        let (db, conversation, run, workspace) = try await fixture()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let registry = ToolRunnerRegistry()
        _ = registerEcho(registry, name: "media.project")
        _ = registerEcho(registry, name: "document.office.edit")
        let store = BackgroundJobStore(database: db)
        let service = BackgroundJobService(store: store, registry: registry)

        await #expect(throws: (any Error).self) {
            try await service.submit(runID: run, toolCallID: "c1", targetTool: "media.project",
                                     payloadJSON: Data(#"{"action":"apply","project_id":"x"}"#.utf8),
                                     scope: .local, workspaceRootURL: workspace, allowedWorkspacePaths: [])
        }
        await #expect(throws: (any Error).self) {
            try await service.submit(runID: run, toolCallID: "c2", targetTool: "document.office.edit",
                                     payloadJSON: Data(#"{"action":"apply"}"#.utf8),
                                     scope: .local, workspaceRootURL: workspace, allowedWorkspacePaths: [])
        }
        await #expect(throws: (any Error).self) {
            try await service.submit(runID: run, toolCallID: "c3", targetTool: "delegate",
                                     payloadJSON: Data("{}".utf8),
                                     scope: .local, workspaceRootURL: workspace, allowedWorkspacePaths: [])
        }
        // Export actions are admitted.
        let export = try await service.submit(
            runID: run, toolCallID: "c4", targetTool: "media.project",
            payloadJSON: Data(#"{"action":"export","project_id":"00000000-0000-0000-0000-000000000000"}"#.utf8),
            scope: .local, workspaceRootURL: workspace, allowedWorkspacePaths: [],
            submissionSource: .nativeService)
        #expect(export.targetTool == "media.project")
        _ = try await waitForTerminal(service, id: export.id)
        // Nothing refused above was persisted.
        #expect(try await store.jobs(conversationID: conversation).count == 1)
    }

    @Test("declared input, workspace confinement and base revision are preflighted before persistence")
    func preflight() async throws {
        let (db, conversation, run, workspace) = try await fixture()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let input = workspace.appendingPathComponent("clip.mp4")
        try Data("media-bytes".utf8).write(to: input)
        let digest = try FloeDigest.sha256Hex(ofFileAt: input)
        let registry = ToolRunnerRegistry()
        _ = registerEcho(registry, name: "video.interpolate")
        let store = BackgroundJobStore(database: db)
        let service = BackgroundJobService(store: store, registry: registry)

        // Missing input refused before the durable record exists.
        await #expect(throws: (any Error).self) {
            try await service.submit(runID: run, toolCallID: "p1", targetTool: "video.interpolate",
                                     payloadJSON: Data(#"{"input":"missing.mp4","output":"out.mp4","targetFPS":60,"mode":"quality"}"#.utf8),
                                     scope: .local, workspaceRootURL: workspace, allowedWorkspacePaths: [])
        }
        // Path escape refused.
        await #expect(throws: (any Error).self) {
            try await service.submit(runID: run, toolCallID: "p2", targetTool: "video.interpolate",
                                     payloadJSON: Data(#"{"input":"../outside.mp4","output":"out.mp4","targetFPS":60,"mode":"quality"}"#.utf8),
                                     scope: .local, workspaceRootURL: workspace, allowedWorkspacePaths: [])
        }
        // Stale revision refused: the declared digest is not the file's.
        await #expect(throws: (any Error).self) {
            try await service.submit(runID: run, toolCallID: "p3", targetTool: "video.interpolate",
                                     payloadJSON: Data(#"{"input":"clip.mp4","output":"out.mp4","targetFPS":60,"mode":"quality","expectedSHA256":"\#(String(repeating: "a", count: 64))"}"#.utf8),
                                     scope: .local, workspaceRootURL: workspace, allowedWorkspacePaths: [])
        }
        #expect(try await store.jobs(conversationID: conversation).isEmpty)

        // Correct revision passes and the job runs on the frozen workspace.
        let job = try await service.submit(
            runID: run, toolCallID: "p4", targetTool: "video.interpolate",
            payloadJSON: Data(#"{"input":"clip.mp4","output":"out.mp4","targetFPS":60,"mode":"quality","expectedSHA256":"\#(digest)"}"#.utf8),
            scope: .local, workspaceRootURL: workspace, allowedWorkspacePaths: [],
            environmentID: "env-1", submissionSource: .nativeService)
        let terminal = try await waitForTerminal(service, id: job.id)
        #expect(terminal.state == .completed)
        #expect(terminal.workspaceRootPath == workspace.path)
        #expect(terminal.environmentID == "env-1")
    }

    @Test("a child-origin submission without the runtime child handoff is refused")
    func childRefusedWithoutHandoff() async throws {
        let (db, conversation, run, workspace) = try await fixture()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let registry = ToolRunnerRegistry()
        _ = registerEcho(registry, name: "exec.localPython")
        let store = BackgroundJobStore(database: db)
        let service = BackgroundJobService(store: store, registry: registry)
        // A reconstructed delegated-child origin with no runtime-issued child
        // handoff is exactly the wrapper case that must fail closed under the
        // runtime source.
        let childOrigin = ToolCallOrigin(kind: .delegatedChild, runID: run, callID: "child-call",
                                         toolName: "jobs.submit", childID: UUID(), rootTaskID: UUID())
        await #expect(throws: (any Error).self) {
            try await service.submit(runID: run, toolCallID: "child-1", targetTool: "exec.localPython",
                                     payloadJSON: Data(#"{"script":"1"}"#.utf8),
                                     scope: .local, workspaceRootURL: workspace, allowedWorkspacePaths: [],
                                     callOrigin: childOrigin, submissionSource: .runtime)
        }
        #expect(try await store.jobs(conversationID: conversation).isEmpty)
    }

    @Test("a main-run-only capability can never become deferred work")
    func mainOnlyRefused() async throws {
        let (db, conversation, run, workspace) = try await fixture()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let registry = ToolRunnerRegistry()
        _ = registerEcho(registry, name: "test.mainonly", boundary: .mainRunOnly)
        let policy = NativeJobActionPolicy(handlers: [
            "test.mainonly": NativeJobHandler(allowedActions: ["*"])
        ])
        let store = BackgroundJobStore(database: db)
        let service = BackgroundJobService(store: store, registry: registry,
                                           policy: policy)
        await #expect(throws: (any Error).self) {
            try await service.submit(runID: run, toolCallID: "m1", targetTool: "test.mainonly",
                                     payloadJSON: Data("{}".utf8),
                                     scope: .local, workspaceRootURL: workspace, allowedWorkspacePaths: [],
                                     submissionSource: .nativeService)
        }
        #expect(try await store.jobs(conversationID: conversation).isEmpty)
    }

    @Test("launch reconciliation consults a real side effect before reporting interrupted")
    func reconciliation() async throws {
        let (db, _, run, workspace) = try await fixture()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let registry = ToolRunnerRegistry()
        let store = BackgroundJobStore(database: db)
        let conversation = try #require(try await store.conversationID(runID: run))
        // One job whose handler proves the side effect landed, one without.
        let completedSideEffect = BackgroundJob(
            conversationID: conversation, runID: run, toolCallID: "r1",
            kind: .tool, targetTool: "test.reconcilable", payloadJSON: Data("{}".utf8),
            state: .running)
        let unknown = BackgroundJob(
            conversationID: conversation, runID: run, toolCallID: "r2",
            kind: .tool, targetTool: "test.plain", payloadJSON: Data("{}".utf8),
            state: .running)
        _ = try await store.save(completedSideEffect)
        _ = try await store.save(unknown)
        let policy = NativeJobActionPolicy(handlers: [
            "test.reconcilable": NativeJobHandler(allowedActions: ["*"], reconcile: { _ in .completed }),
            "test.plain": NativeJobHandler(allowedActions: ["*"]),
        ])
        let service = BackgroundJobService(store: store, registry: registry, policy: policy)
        let reconciled = try await service.reconcileInterruptedOnLaunch()
        #expect(reconciled == 2)
        #expect(try await service.job(id: completedSideEffect.id)?.state == .completed)
        #expect(try await service.job(id: unknown.id)?.state == .interrupted)
    }

    @Test("cancelling a job reports cancelled and never deletes the source file")
    func cancellation() async throws {
        let (db, _, run, workspace) = try await fixture()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let input = workspace.appendingPathComponent("source.txt")
        try Data("keep me".utf8).write(to: input)
        let registry = ToolRunnerRegistry()
        registry.register(AnyAgentTool(descriptor: ToolCatalog.Descriptor(
            name: "test.slow", toolDescription: "slow", parametersJSON: #"{"type":"object"}"#,
            riskLabels: [], isSideEffecting: true, effect: .mutating
        )) { _, context in
            for _ in 0..<400 {
                try context.cancellation.throwIfCancelled()
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            return ToolExecutionOutput(summary: "finished", fullOutputSHA256: "d")
        })
        let policy = NativeJobActionPolicy(handlers: ["test.slow": NativeJobHandler(allowedActions: ["*"])])
        let service = BackgroundJobService(store: BackgroundJobStore(database: db), registry: registry,
                                           policy: policy)
        let job = try await service.submit(runID: run, toolCallID: "s1", targetTool: "test.slow",
                                           payloadJSON: Data("{}".utf8), scope: .local,
                                           workspaceRootURL: workspace, allowedWorkspacePaths: [],
                                           submissionSource: .nativeService)
        _ = try await service.cancel(id: job.id)
        let terminal = try await waitForTerminal(service, id: job.id)
        #expect(terminal.state == .cancelled)
        #expect(try Data(contentsOf: input) == Data("keep me".utf8))
    }

    @Test("a retried call id with different arguments runs the ORIGINAL payload and says so")
    func payloadMismatchIsHonest() async throws {
        let (db, conversation, run, workspace) = try await fixture()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let registry = ToolRunnerRegistry()
        _ = registerEcho(registry, name: "exec.localPython")
        let store = BackgroundJobStore(database: db)
        let service = BackgroundJobService(store: store, registry: registry)
        let tool = JobsSubmitTool(service: service)
        let context = ToolContext(runID: run, toolCallID: "same", workspaceRootURL: workspace,
                                  cancellation: CancellationToken(),
                                  callOrigin: ToolCallOrigin(kind: .mainRunDelegate, runID: run,
                                                             callID: "same", toolName: "jobs.submit"))
        let first = try await tool.execute(.init(tool: "exec.localPython", arguments: #"{"script":"a"}"#), context: context)
        #expect(first.summary.contains("\"payloadMatches\":true"))
        let retried = try await tool.execute(.init(tool: "exec.localPython", arguments: #"{"script":"b"}"#), context: context)
        #expect(retried.summary.contains("\"payloadMatches\":false"))
        #expect(try await store.jobs(conversationID: conversation).count == 1)
    }

    @Test("a cancelled job whose processor reports an unsafe state fails truthfully, never 'cancelled'")
    func cancelWithUnsafeStateIsNotCleanCancellation() async throws {
        let (db, _, run, workspace) = try await fixture()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let registry = ToolRunnerRegistry()
        // Submit-time availability checks the registered runner even though the
        // adapter intercepts the prepared operation.
        _ = registerEcho(registry, name: "exec.localPython")
        let adapter = NativeJobServiceAdapter(
            targetTool: "exec.localPython",
            adaptedActions: nil,
            requiresRuntimeAuthorization: false,
            prepare: { request in
                // Exactly the App Office adapter shape: the prepared operation
                // waits for the cancellation request, then reports the unsafe
                // resource state instead of claiming a clean stop.
                SafetyPreparedOperation(operationID: request.operationID)
            })
        let store = BackgroundJobStore(database: db)
        let service = BackgroundJobService(store: store, registry: registry,
                                           policy: .default,
                                           adapters: ["exec.localPython": adapter])
        let job = try await service.submit(runID: run, toolCallID: "safe-1",
                                           targetTool: "exec.localPython",
                                           payloadJSON: Data(#"{"script":"1"}"#.utf8),
                                           scope: .local, workspaceRootURL: workspace,
                                           allowedWorkspacePaths: [],
                                           submissionSource: .nativeService)
        // Wait until the prepared operation is genuinely running, then cancel.
        let runningDeadline = Date().addingTimeInterval(5)
        while Date() < runningDeadline, (try? await store.job(id: job.id))?.state != .running {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        _ = try await service.cancel(id: job.id)
        let terminal = try await waitForTerminal(service, id: job.id)
        #expect(terminal.state == .failed,
                "an unsafe resource state must outrank the cancellation request")
        #expect(terminal.lastError?.contains("Unsafe resource state") == true)
        #expect(terminal.lastError?.contains("staging was cleaned") != true)
    }

    @Test("a conforming SAFE contract error with a cancelled token stays a clean cancellation")
    func safeContractErrorIsNotUnsafe() async throws {
        let (db, _, run, workspace) = try await fixture()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let registry = ToolRunnerRegistry()
        _ = registerEcho(registry, name: "exec.localPython")
        let adapter = NativeJobServiceAdapter(
            targetTool: "exec.localPython",
            adaptedActions: nil,
            requiresRuntimeAuthorization: false,
            prepare: { request in
                // The shape of a clean Office cancellation: the family
                // conforms to the shared contract for its description
                // plumbing, the discriminant says "safe".
                SafeContractPreparedOperation(operationID: request.operationID)
            })
        let store = BackgroundJobStore(database: db)
        let service = BackgroundJobService(store: store, registry: registry,
                                           policy: .default,
                                           adapters: ["exec.localPython": adapter])
        let job = try await service.submit(runID: run, toolCallID: "safe-contract",
                                           targetTool: "exec.localPython",
                                           payloadJSON: Data(#"{"script":"1"}"#.utf8),
                                           scope: .local, workspaceRootURL: workspace,
                                           allowedWorkspacePaths: [],
                                           submissionSource: .nativeService)
        let runningDeadline = Date().addingTimeInterval(5)
        while Date() < runningDeadline, (try? await store.job(id: job.id))?.state != .running {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        _ = try await service.cancel(id: job.id)
        let terminal = try await waitForTerminal(service, id: job.id)
        // Conformance alone must not win: only the discriminant decides. A
        // wholesale `error is any UnsafeResourceStateError` check would mark
        // this clean cancellation as a failed retained-staging run.
        #expect(terminal.state == .cancelled,
                "a conforming error whose discriminant is false must keep the clean cancellation path")
        #expect(terminal.lastError?.contains("Unsafe resource state") != true)
        #expect(terminal.lastError?.contains("staging was cleaned") == true)
    }

    @Test("completion is delivered for the owning task only, with the frozen scope")
    func originCompletion() async throws {
        let (db, conversation, run, workspace) = try await fixture()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let registry = ToolRunnerRegistry()
        let recorder = registerEcho(registry, name: "exec.localPython")
        let terminalJobs = NativeTerminalCollector()
        let service = BackgroundJobService(
            store: BackgroundJobStore(database: db), registry: registry,
            onTerminal: { job in await terminalJobs.record(job.id) })
        let job = try await service.submit(runID: run, toolCallID: "o1", targetTool: "exec.localPython",
                                           payloadJSON: Data(#"{"script":"1"}"#.utf8),
                                           scope: .local, workspaceRootURL: workspace,
                                           allowedWorkspacePaths: [], environmentID: "env-9",
                                           submissionSource: .nativeService)
        _ = try await waitForTerminal(service, id: job.id)
        #expect(await terminalJobs.contains(job.id))
        let recorded = await recorder.contexts
        #expect(recorded.count == 1)
        #expect(recorded.first?.workspace == workspace.path)
        #expect(recorded.first?.conversation == conversation)
        #expect(recorded.first?.environment == "env-9")
    }
}


/// A prepared operation that reports the shared unsafe-resource-state failure
/// as soon as cancellation is requested (the App Office adapter shape).
private actor SafetyPreparedOperation: NativeJobPreparedOperation {
    let operationID: String
    let frozenRevision: String? = nil
    let serviceLabel = "safety-test"

    init(operationID: String) { self.operationID = operationID }

    func run(hooks: NativeJobRunHooks) async throws -> NativeJobOutcome {
        while !hooks.isCancellationRequested() {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        throw NativeJobSafetyFailure(reason: "the engine did not acknowledge its close",
                                     stagingRetained: true)
    }

    func requestCancellation() async {}
}

/// A prepared operation that reports a SAFE shared-contract failure as soon as
/// cancellation is requested: the family conforms (for its reason/description)
/// while `isUnsafeResourceState` is explicitly false, exactly like a clean
/// Office `OfficeAutomaticExecutionError.cancelled` reaching the shared
/// execution boundary.
private actor SafeContractPreparedOperation: NativeJobPreparedOperation {
    let operationID: String
    let frozenRevision: String? = nil
    let serviceLabel = "safe-contract-test"

    init(operationID: String) { self.operationID = operationID }

    func run(hooks: NativeJobRunHooks) async throws -> NativeJobOutcome {
        while !hooks.isCancellationRequested() {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        throw SafeContractFailure()
    }

    func requestCancellation() async {}
}

private struct SafeContractFailure: Error, UnsafeResourceStateError, LocalizedError {
    var unsafeResourceReason: String { "the processor stopped and cleaned its staging" }
    var isUnsafeResourceState: Bool { false }
    var errorDescription: String? { "the processor stopped and cleaned its staging" }
}

private actor NativeTerminalCollector {
    private var ids: [UUID] = []
    func record(_ id: UUID) { ids.append(id) }
    func contains(_ id: UUID) -> Bool { ids.contains(id) }
}
