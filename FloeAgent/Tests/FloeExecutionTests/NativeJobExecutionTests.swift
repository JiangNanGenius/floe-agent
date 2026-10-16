// FloeExecutionTests — native job closure: runtime-verified provenance,
// service-owned prepared operations, real bounded progress and truthful
// cancellation.

import Foundation
import Testing
import FloeTools
import FloeCore
import FloeModels
@testable import FloePersistence
@testable import FloeExecution

@Suite("Native job execution closure")
struct NativeJobExecutionTests {
    // MARK: - Fixtures

    private func fixture() async throws -> (DatabaseManager, UUID, UUID, URL) {
        let db = try DatabaseManager.inMemory()
        try await db.migrate()
        let conversation = UUID(), run = UUID()
        let now = ISO8601DateFormatter().string(from: Date())
        try await db.writer { db in
            try db.execute(sql: """
                INSERT INTO conversations (id, title, created_at, updated_at)
                VALUES (?, 'Native execution', ?, ?)
                """, arguments: [conversation.uuidString, now, now])
            try db.execute(sql: """
                INSERT INTO runs (id, conversation_id, state, goal, started_at)
                VALUES (?, ?, 'running', 'Test', ?)
                """, arguments: [run.uuidString, conversation.uuidString, now])
        }
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-job-exec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return (db, conversation, run, workspace)
    }

    private actor ExecutedTargets {
        private(set) var names: [String] = []
        func record(_ name: String) { names.append(name) }
    }

    private func registerEcho(_ registry: ToolRunnerRegistry, name: String,
                              boundary: ToolExecutionBoundary = .any,
                              executed: ExecutedTargets? = nil) {
        registry.register(AnyAgentTool(descriptor: ToolCatalog.Descriptor(
            name: name, toolDescription: name, parametersJSON: #"{"type":"object"}"#,
            riskLabels: [], isSideEffecting: true, effect: .mutating,
            executionBoundary: boundary
        )) { arguments, _ in
            await executed?.record(name)
            return ToolExecutionOutput(summary: "echo:\(name)", fullOutputSHA256: "digest-\(name)")
        })
    }

    private func makeHandoff(identity: ChildExecutionIdentity) -> ChildExecutionHandoff {
        ChildExecutionHandoff(
            identity: identity,
            dispatcher: ChildToolDispatcher(
                descriptorProvider: { _ in nil },
                allDescriptors: { [] },
                dispatch: { call, _ in
                    ToolResult(callID: call.id, status: .denied,
                               outputSummary: "fixture dispatcher is not used", outputDigest: "")
                }),
            peers: PeerCollaborationHandle(
                register: { _ in },
                unregister: {},
                drain: { [] },
                peers: { _ in [] },
                send: { _, _, _ in SubagentPeerSendReceipt(accepted: false, reason: "fixture") }
            )
        )
    }

    private func waitForTerminal(_ service: BackgroundJobService, id: UUID,
                                 timeout: TimeInterval = 15) async throws -> BackgroundJob {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let job = try await service.job(id: id), job.state.isTerminal { return job }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        throw FloeError.internalError("job did not settle")
    }

    private func waitForState(_ service: BackgroundJobService, id: UUID,
                              _ predicate: @Sendable (BackgroundJob) -> Bool,
                              timeout: TimeInterval = 10) async throws -> BackgroundJob {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let job = try await service.job(id: id), predicate(job) { return job }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        throw FloeError.internalError("job did not reach the expected state")
    }

    private actor TerminalCollector {
        private(set) var jobs: [BackgroundJob] = []
        func record(_ job: BackgroundJob) { jobs.append(job) }
        var count: Int { jobs.count }
    }

    // MARK: - Provenance

    @Test("forged or contradictory provenance is refused before anything is persisted")
    func provenanceDenials() async throws {
        let (db, conversation, run, workspace) = try await fixture()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let registry = ToolRunnerRegistry()
        registerEcho(registry, name: "exec.shell")
        let service = BackgroundJobService(store: BackgroundJobStore(database: db), registry: registry)
        let childID = UUID()
        let identity = ChildExecutionIdentity(parentRunID: run, rootTaskID: conversation, delegateCallID: "delegate-1")
        let handoff = makeHandoff(identity: identity)
        func payload() -> Data { Data(#"{"script":"1"}"#.utf8) }

        // (1) A delegated-child origin WITHOUT the runtime child handoff.
        await #expect(throws: (any Error).self) {
            try await service.submit(runID: run, toolCallID: "f1", targetTool: "exec.shell",
                payloadJSON: payload(), scope: .local, workspaceRootURL: workspace, allowedWorkspacePaths: [],
                callOrigin: ToolCallOrigin(kind: .delegatedChild, runID: run, callID: "f1",
                                           toolName: "jobs.submit", childID: childID, rootTaskID: conversation),
                submissionSource: .runtime)
        }
        // (2) A child handoff with NO origin.
        await #expect(throws: (any Error).self) {
            try await service.submit(runID: run, toolCallID: "f2", targetTool: "exec.shell",
                payloadJSON: payload(), scope: .local, workspaceRootURL: workspace, allowedWorkspacePaths: [],
                childExecution: handoff, submissionSource: .runtime)
        }
        // (3) A child handoff contradicted by a main-run origin.
        await #expect(throws: (any Error).self) {
            try await service.submit(runID: run, toolCallID: "f3", targetTool: "exec.shell",
                payloadJSON: payload(), scope: .local, workspaceRootURL: workspace, allowedWorkspacePaths: [],
                callOrigin: ToolCallOrigin(kind: .mainRunDelegate, runID: run, callID: "f3", toolName: "jobs.submit"),
                childExecution: handoff, submissionSource: .runtime)
        }
        // (4) A child origin whose child identity does not match the handoff.
        await #expect(throws: (any Error).self) {
            try await service.submit(runID: run, toolCallID: "f4", targetTool: "exec.shell",
                payloadJSON: payload(), scope: .local, workspaceRootURL: workspace, allowedWorkspacePaths: [],
                callOrigin: ToolCallOrigin(kind: .delegatedChild, runID: run, callID: "f4",
                                           toolName: "jobs.submit", childID: UUID(), rootTaskID: conversation),
                childExecution: handoff, submissionSource: .runtime)
        }
        // (5) An origin bound to a different tool (tool-name binding).
        await #expect(throws: (any Error).self) {
            try await service.submit(runID: run, toolCallID: "f5", targetTool: "exec.shell",
                payloadJSON: payload(), scope: .local, workspaceRootURL: workspace, allowedWorkspacePaths: [],
                callOrigin: ToolCallOrigin(kind: .delegatedChild, runID: run, callID: "f5",
                                           toolName: "delegate", childID: identity.childID, rootTaskID: conversation),
                childExecution: handoff, submissionSource: .runtime)
        }
        // (6) A main-run origin carrying a child identity.
        await #expect(throws: (any Error).self) {
            try await service.submit(runID: run, toolCallID: "f6", targetTool: "exec.shell",
                payloadJSON: payload(), scope: .local, workspaceRootURL: workspace, allowedWorkspacePaths: [],
                callOrigin: ToolCallOrigin(kind: .mainRunDelegate, runID: run, callID: "f6",
                                           toolName: "jobs.submit", childID: childID),
                submissionSource: .runtime)
        }
        // (7) A main-run origin for a different run.
        await #expect(throws: (any Error).self) {
            try await service.submit(runID: run, toolCallID: "f7", targetTool: "exec.shell",
                payloadJSON: payload(), scope: .local, workspaceRootURL: workspace, allowedWorkspacePaths: [],
                callOrigin: ToolCallOrigin(kind: .mainRunDelegate, runID: UUID(), callID: "f7", toolName: "jobs.submit"),
                submissionSource: .runtime)
        }
        // (8) NO origin at all: there is no nil-origin fallback to main-run
        // for a runtime-dispatched submission.
        await #expect(throws: (any Error).self) {
            try await service.submit(runID: run, toolCallID: "f8", targetTool: "exec.shell",
                payloadJSON: payload(), scope: .local, workspaceRootURL: workspace, allowedWorkspacePaths: [],
                submissionSource: .runtime)
        }
        // (9) A wrapper tool forwarding the same run/call identity but bound to
        // its own tool name is refused.
        await #expect(throws: (any Error).self) {
            try await service.submit(runID: run, toolCallID: "f9", targetTool: "exec.shell",
                payloadJSON: payload(), scope: .local, workspaceRootURL: workspace, allowedWorkspacePaths: [],
                callOrigin: ToolCallOrigin(kind: .mainRunDelegate, runID: run, callID: "f9",
                                           toolName: "workspace.writeFile"),
                submissionSource: .runtime)
        }
        // (10) The runtime source requires the provider call id too: an
        // origin alone (a reconstructed context that dropped only the call id)
        // is refused.
        await #expect(throws: (any Error).self) {
            try await service.submit(runID: run, toolCallID: nil, targetTool: "exec.shell",
                payloadJSON: payload(), scope: .local, workspaceRootURL: workspace, allowedWorkspacePaths: [],
                callOrigin: ToolCallOrigin(kind: .mainRunDelegate, runID: run, callID: "f10", toolName: "jobs.submit"),
                submissionSource: .runtime)
        }
        #expect(try await storeJobs(db).isEmpty)
    }

    @Test("a trusted child submits the same eligible targets as the parent ceiling admits")
    func childParity() async throws {
        let (db, conversation, run, workspace) = try await fixture()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let registry = ToolRunnerRegistry()
        registerEcho(registry, name: "exec.shell")
        registerEcho(registry, name: "network.http")
        let store = BackgroundJobStore(database: db)
        let service = BackgroundJobService(store: store, registry: registry)
        let identity = ChildExecutionIdentity(parentRunID: run, rootTaskID: conversation, delegateCallID: "delegate-1")
        let handoff = makeHandoff(identity: identity)
        let childOrigin = ToolCallOrigin(kind: .delegatedChild, runID: run, callID: "c1",
                                         toolName: "jobs.submit", childID: identity.childID,
                                         rootTaskID: conversation)

        // Same target as a main-run call with the parent's effective ceiling.
        let job = try await service.submit(
            runID: run, toolCallID: "c1", targetTool: "exec.shell",
            payloadJSON: Data(#"{"script":"1"}"#.utf8), scope: .local,
            workspaceRootURL: workspace, allowedWorkspacePaths: ["scripts"],
            environmentID: "env-1", allowedToolNames: ["jobs.submit", "exec.shell"],
            callOrigin: childOrigin, childExecution: handoff, submissionSource: .runtime)
        let terminal = try await waitForTerminal(service, id: job.id)
        #expect(terminal.state == .completed)
        #expect(terminal.resultSummary == "echo:exec.shell")
        let document = try #require(NativeJobProgressDocument.decode(terminal.progressJSON))
        #expect(document.origin?.kind == .delegatedChild)
        #expect(document.origin?.childID == identity.childID)
        #expect(document.origin?.rootTaskID == conversation)

        // A target OUTSIDE the child's inherited ceiling is refused.
        await #expect(throws: (any Error).self) {
            try await service.submit(
                runID: run, toolCallID: "c2", targetTool: "network.http",
                payloadJSON: Data(#"{"command":"true"}"#.utf8), scope: .local,
                workspaceRootURL: workspace, allowedWorkspacePaths: [],
                allowedToolNames: ["jobs.submit", "exec.shell"],
                callOrigin: ToolCallOrigin(kind: .delegatedChild, runID: run, callID: "c2",
                                           toolName: "jobs.submit", childID: identity.childID,
                                           rootTaskID: conversation),
                childExecution: handoff, submissionSource: .runtime)
        }
        // A child origin for a DIFFERENT root task than the run's owner is refused.
        let otherTask = UUID()
        await #expect(throws: (any Error).self) {
            try await service.submit(
                runID: run, toolCallID: "c3", targetTool: "exec.shell",
                payloadJSON: Data(#"{"script":"1"}"#.utf8), scope: .local,
                workspaceRootURL: workspace, allowedWorkspacePaths: [],
                allowedToolNames: ["jobs.submit", "exec.shell"],
                callOrigin: ToolCallOrigin(kind: .delegatedChild, runID: run, callID: "c3",
                                           toolName: "jobs.submit", childID: identity.childID,
                                           rootTaskID: otherTask),
                childExecution: makeHandoff(identity: ChildExecutionIdentity(
                    parentRunID: run, rootTaskID: otherTask, delegateCallID: "delegate-2")),
                submissionSource: .runtime)
        }
        #expect(try await store.jobs(conversationID: conversation).count == 1)
    }

    @Test("in-process native submissions stay admitted with honest provenance")
    func nativeServiceSubmissions() async throws {
        let (db, conversation, run, workspace) = try await fixture()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let registry = ToolRunnerRegistry()
        registerEcho(registry, name: "exec.localService")
        let store = BackgroundJobStore(database: db)
        let service = BackgroundJobService(store: store, registry: registry)

        // The app's `floe-service`/IDE shape: no call id, no origin, and no
        // explicit source either — the service API default IS the explicit
        // in-process native source (`NativeJobSubmissionSource.nativeService`),
        // which is why these trusted App callsites need no App-side change.
        let native = try await service.submit(
            runID: run, toolCallID: nil, targetTool: "exec.localService",
            payloadJSON: Data("{}".utf8), scope: .local,
            workspaceRootURL: workspace, allowedWorkspacePaths: [], environmentID: "env-1")
        let nativeTerminal = try await waitForTerminal(service, id: native.id)
        #expect(nativeTerminal.state == .completed)
        #expect(NativeJobProgressDocument.decode(nativeTerminal.progressJSON)?.origin?.kind == .mainRun)

        // A child-context in-process action keeps the real child identity even
        // though no jobs.submit call was dispatched.
        let identity = ChildExecutionIdentity(parentRunID: run, rootTaskID: conversation,
                                              delegateCallID: "delegate-native")
        let childJob = try await service.submit(
            runID: run, toolCallID: "shell-call", targetTool: "exec.localService",
            payloadJSON: Data("{}".utf8), scope: .local,
            workspaceRootURL: workspace, allowedWorkspacePaths: [],
            callOrigin: ToolCallOrigin(kind: .delegatedChild, runID: run, callID: "shell-call",
                                       toolName: "exec.shell", childID: identity.childID,
                                       rootTaskID: conversation),
            childExecution: makeHandoff(identity: identity),
            submissionSource: .nativeService)
        let childTerminal = try await waitForTerminal(service, id: childJob.id)
        #expect(childTerminal.state == .completed)
        let document = try #require(NativeJobProgressDocument.decode(childTerminal.progressJSON))
        #expect(document.origin?.kind == .delegatedChild)
        #expect(document.origin?.childID == identity.childID)
        #expect(document.origin?.rootTaskID == conversation)
    }

    @Test("a raw registered jobs.submit with stripped provenance is refused before any record or effect")
    func rawRegisteredSubmitRefusesStrippedProvenance() async throws {
        let (db, conversation, run, workspace) = try await fixture()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let registry = ToolRunnerRegistry()
        let executed = ExecutedTargets()
        registerEcho(registry, name: "exec.shell", executed: executed)
        let store = BackgroundJobStore(database: db)
        // Register the REAL jobs.* tools through the production registration
        // path, then reach jobs.submit exactly like a reconstructed wrapper
        // context would: through the raw registered registry entry.
        let service = registerBackgroundJobTools(database: db, registry: registry)
        let raw = try #require(registry.runner(named: JobsSubmitTool.name))
        let arguments = Data(#"{"tool":"exec.shell","arguments":"{\"script\":\"1\"}"}"#.utf8)

        // (a) ALL provenance stripped: no call id, no origin, no child
        // handoff. Before this fix the runtime source admitted this shape as an
        // in-process submission and persisted an ordinary job.
        let stripped = ToolContext(runID: run, scope: .local,
                                   workspaceRootURL: workspace, allowedWorkspacePaths: [],
                                   cancellation: CancellationToken(),
                                   conversationID: conversation)
        do {
            _ = try await raw.execute(argumentsJSON: arguments, context: stripped)
            Issue.record("Expected the all-nil raw jobs.submit submission to be refused")
        } catch {
            #expect(String(describing: error).contains("refused without the runtime-issued provenance"))
        }
        #expect(try await store.jobs(conversationID: conversation).isEmpty)
        #expect(await executed.names.isEmpty)

        // (b) The call id kept but the runtime origin stripped: same escape,
        // same refusal before the durable record exists.
        let missingOrigin = ToolContext(runID: run, toolCallID: "forwarded-call", scope: .local,
                                        workspaceRootURL: workspace, allowedWorkspacePaths: [],
                                        cancellation: CancellationToken(),
                                        conversationID: conversation)
        do {
            _ = try await raw.execute(argumentsJSON: arguments, context: missingOrigin)
            Issue.record("Expected the call-id-only raw jobs.submit submission to be refused")
        } catch {
            #expect(String(describing: error).contains("refused without the runtime-issued provenance"))
        }
        #expect(try await store.jobs(conversationID: conversation).isEmpty)
        #expect(await executed.names.isEmpty)

        // (c) The genuine main-run runtime call through the SAME raw entry
        // still submits and runs: the origin is bound to jobs.submit for this
        // exact nonnil call id.
        let genuine = ToolContext(
            runID: run, toolCallID: "genuine-call", scope: .local,
            workspaceRootURL: workspace, allowedWorkspacePaths: [],
            cancellation: CancellationToken(), conversationID: conversation,
            callOrigin: ToolCallOrigin(kind: .mainRunDelegate, runID: run,
                                       callID: "genuine-call", toolName: JobsSubmitTool.name))
        let output = try await raw.execute(argumentsJSON: arguments, context: genuine)
        #expect(output.summary.contains("\"payloadMatches\":true"))
        let jobID = try #require(extractJobID(output.summary))
        let terminal = try await waitForTerminal(service, id: jobID)
        #expect(terminal.state == .completed)
        #expect(terminal.resultSummary == "echo:exec.shell")
        #expect(await executed.names == ["exec.shell"])
        #expect(try await store.jobs(conversationID: conversation).count == 1)
    }

    @Test("delegation itself and main-run-only/child-only capabilities can never become jobs")
    func structuralDenials() async throws {
        let (db, _, run, workspace) = try await fixture()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let registry = ToolRunnerRegistry()
        registerEcho(registry, name: "delegate", boundary: .mainRunOnly)
        registerEcho(registry, name: "test.childonly", boundary: .childOnly)
        let policy = NativeJobActionPolicy(handlers: [
            "delegate": NativeJobHandler(allowedActions: ["*"]),
            "test.childonly": NativeJobHandler(allowedActions: ["*"]),
        ])
        let store = BackgroundJobStore(database: db)
        let service = BackgroundJobService(store: store, registry: registry, policy: policy)
        await #expect(throws: (any Error).self) {
            try await service.submit(runID: run, toolCallID: "d1", targetTool: "delegate",
                payloadJSON: Data("{}".utf8), scope: .local, workspaceRootURL: workspace,
                allowedWorkspacePaths: [], submissionSource: .nativeService)
        }
        await #expect(throws: (any Error).self) {
            try await service.submit(runID: run, toolCallID: "d2", targetTool: "test.childonly",
                payloadJSON: Data("{}".utf8), scope: .local, workspaceRootURL: workspace,
                allowedWorkspacePaths: [], submissionSource: .nativeService)
        }
        #expect(try await storeJobs(db).isEmpty)
    }

    @Test("payload declarations of another task/environment are refused")
    func crossScopeDeclarations() async throws {
        let (db, conversation, run, workspace) = try await fixture()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let registry = ToolRunnerRegistry()
        registerEcho(registry, name: "exec.shell")
        let store = BackgroundJobStore(database: db)
        let service = BackgroundJobService(store: store, registry: registry)
        // A different task id in the payload is refused.
        await #expect(throws: (any Error).self) {
            try await service.submit(runID: run, toolCallID: "s1", targetTool: "exec.shell",
                payloadJSON: Data(#"{"script":"1","task_id":"\#(UUID().uuidString)"}"#.utf8),
                scope: .local, workspaceRootURL: workspace, allowedWorkspacePaths: [],
                submissionSource: .nativeService)
        }
        // A different environment is refused.
        await #expect(throws: (any Error).self) {
            try await service.submit(runID: run, toolCallID: "s2", targetTool: "exec.shell",
                payloadJSON: Data(#"{"script":"1","environment_id":"other"}"#.utf8),
                scope: .local, workspaceRootURL: workspace, allowedWorkspacePaths: [],
                environmentID: "env-1", submissionSource: .nativeService)
        }
        // The submitting task/environment themselves are admitted.
        let job = try await service.submit(runID: run, toolCallID: "s3", targetTool: "exec.shell",
            payloadJSON: Data(#"{"script":"1","task_id":"\#(conversation.uuidString)","environment_id":"env-1"}"#.utf8),
            scope: .local, workspaceRootURL: workspace, allowedWorkspacePaths: [],
            environmentID: "env-1", submissionSource: .nativeService)
        let terminal = try await waitForTerminal(service, id: job.id)
        #expect(terminal.state == .completed)
        #expect(terminal.environmentID == "env-1")
    }

    // MARK: - Prepared service operations (adapters)

    private func applyContext(run: UUID, conversation: UUID, workspace: URL,
                              toolCallID: String, idempotencyKey: String,
                              approvalGrantID: UUID? = nil,
                              authority: RuntimeTaskAuthority? = nil) -> ToolContext {
        ToolContext(
            runID: run, toolCallID: toolCallID, toolIdempotencyKey: idempotencyKey,
            approvalGrantID: approvalGrantID, scope: .local,
            allowedToolNames: ["jobs.submit", "document.office.edit"],
            workspaceRootURL: workspace, cancellation: CancellationToken(),
            conversationID: conversation, runtimeAuthority: authority,
            callOrigin: ToolCallOrigin(kind: .mainRunDelegate, runID: run,
                                       callID: toolCallID, toolName: "jobs.submit"))
    }

    private func officeBinding(context: ToolContext) throws -> RuntimeAuthorityBinding {
        try JobsSubmitTool.runtimeAuthorityBinding(
            for: .init(tool: "document.office.edit",
                       arguments: #"{"action":"apply","proposal_id":"11111111-1111-1111-1111-111111111111"}"#),
            context: context)
    }

    private func issueAuthority(_ binding: RuntimeAuthorityBinding) async -> RuntimeTaskAuthority {
        await RuntimeAuthorityStore.shared.issue(RuntimeAuthorityEvidence(
            runID: binding.runID, taskID: binding.taskID,
            environmentBinding: binding.environmentBinding,
            canonicalTarget: binding.canonicalTarget,
            toolName: binding.toolName, operation: binding.operation,
            operationID: binding.operationID, idempotencyKey: binding.idempotencyKey,
            baseRevision: binding.baseRevision, payloadDigest: binding.payloadDigest,
            approvalGrantID: UUID()))
    }

    private func makeAdapter(operation: FixturePreparedOperation,
                             preparedRequests: PreparedRequestRecorder) -> NativeJobServiceAdapter {
        NativeJobServiceAdapter(
            targetTool: "document.office.edit",
            adaptedActions: ["apply"],
            requiresRuntimeAuthorization: true,
            prepare: { request in
                await preparedRequests.record(request)
                return operation
            })
    }

    @Test("an authorized apply is prepared with the consumed submission binding and verified artifact")
    func authorizedAdapterRuns() async throws {
        let (db, conversation, run, workspace) = try await fixture()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let registry = ToolRunnerRegistry()
        let executed = ExecutedTargets()
        registerEcho(registry, name: "document.office.edit", executed: executed)
        let store = BackgroundJobStore(database: db)
        let requests = PreparedRequestRecorder()
        let artifact = workspace.appendingPathComponent("deck.edited.pptx").path
        let operation = FixturePreparedOperation(
            behavior: .complete, frozenRevision: "base-sha-1", artifactPath: artifact)
        let service = BackgroundJobService(
            store: store, registry: registry,
            policy: .withAdaptedApplyActions(["document.office.edit": ["apply"]]),
            adapters: ["document.office.edit": makeAdapter(operation: operation, preparedRequests: requests)])
        let grantID = UUID()
        let context = applyContext(run: run, conversation: conversation, workspace: workspace,
                                   toolCallID: "call-apply", idempotencyKey: "idem-apply",
                                   approvalGrantID: grantID)
        let binding = try officeBinding(context: context)
        let authority = await issueAuthority(binding)
        let submit = JobsSubmitTool(service: service)
        let output = try await submit.execute(
            .init(tool: "document.office.edit",
                  arguments: #"{"action":"apply","proposal_id":"11111111-1111-1111-1111-111111111111"}"#),
            context: applyContext(run: run, conversation: conversation, workspace: workspace,
                                  toolCallID: "call-apply", idempotencyKey: "idem-apply",
                                  approvalGrantID: grantID, authority: authority))
        let jobID = try #require(extractJobID(output.summary))
        let terminal = try await waitForTerminal(service, id: jobID)
        #expect(terminal.state == .completed)
        #expect(terminal.resultSummary == "fixture operation completed")
        #expect(terminal.resultDigest == "fixture-digest")
        #expect(terminal.resultPath == artifact)
        // The adapter ran; the raw registry target did NOT.
        #expect(await executed.names.isEmpty)
        let request = try #require(await requests.first)
        #expect(request.origin.kind == .mainRun)
        #expect(request.operationID.count == 32)
        let consumed = try #require(request.consumedBinding)
        #expect(consumed == binding)
        #expect(request.approvalGrantID == grantID)
        // Progress: the terminal document keeps the last real units + origin.
        let document = try #require(NativeJobProgressDocument.decode(terminal.progressJSON))
        #expect(document.origin?.kind == .mainRun)
        #expect(document.progress?.completedUnits == 4)
        #expect(document.progress?.totalUnits == 4)
        #expect(document.prepared?.operationID == operation.operationID)
    }

    @Test("an authorized adapter refuses a missing or mismatched submission authority")
    func authorizedAdapterRefusals() async throws {
        let (db, conversation, run, workspace) = try await fixture()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let registry = ToolRunnerRegistry()
        registerEcho(registry, name: "document.office.edit")
        let store = BackgroundJobStore(database: db)
        let requests = PreparedRequestRecorder()
        let operation = FixturePreparedOperation(behavior: .complete)
        let service = BackgroundJobService(
            store: store, registry: registry,
            policy: .withAdaptedApplyActions(["document.office.edit": ["apply"]]),
            adapters: ["document.office.edit": makeAdapter(operation: operation, preparedRequests: requests)])
        let tool = JobsSubmitTool(service: service)
        func makeContext(_ authority: RuntimeTaskAuthority?) -> ToolContext {
            applyContext(run: run, conversation: conversation, workspace: workspace,
                         toolCallID: "call-refuse", idempotencyKey: "idem-refuse",
                         authority: authority)
        }
        // No runtime authority at all: refused, nothing prepared, nothing persisted.
        await #expect(throws: (any Error).self) {
            try await tool.execute(.init(tool: "document.office.edit",
                arguments: #"{"action":"apply","proposal_id":"11111111-1111-1111-1111-111111111111"}"#),
                context: makeContext(nil))
        }
        #expect(await requests.count == 0)
        #expect(try await storeJobs(db).isEmpty)
        // A mismatched token (minted for a different payload) is refused.
        let context = makeContext(nil)
        var wrongBinding = try officeBinding(context: context)
        wrongBinding.payloadDigest = "different-digest"
        let wrongAuthority = await issueAuthority(wrongBinding)
        await #expect(throws: (any Error).self) {
            try await tool.execute(.init(tool: "document.office.edit",
                arguments: #"{"action":"apply","proposal_id":"11111111-1111-1111-1111-111111111111"}"#),
                context: makeContext(wrongAuthority))
        }
        #expect(await requests.count == 0)
        #expect(try await storeJobs(db).isEmpty)
    }

    @Test("a prepared operation that lacks a required artifact fails closed")
    func missingArtifactFailsClosed() async throws {
        let (db, _, run, workspace) = try await fixture()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let registry = ToolRunnerRegistry()
        registerEcho(registry, name: "document.office.edit")
        let requests = PreparedRequestRecorder()
        let operation = FixturePreparedOperation(
            behavior: .complete, artifactPath: workspace.appendingPathComponent("never-written.pptx").path,
            writesArtifact: false)
        let service = BackgroundJobService(
            store: storeOf(db), registry: registry,
            policy: .withAdaptedApplyActions(["document.office.edit": ["apply"]]),
            adapters: ["document.office.edit": makeAdapter(operation: operation, preparedRequests: requests)])
        let context = applyContext(run: run, conversation: try await requireConversation(db, run),
                                   workspace: workspace, toolCallID: "call-artifact",
                                   idempotencyKey: "idem-artifact")
        let authority = await issueAuthority(try officeBinding(context: context))
        let output = try await JobsSubmitTool(service: service).execute(
            .init(tool: "document.office.edit",
                  arguments: #"{"action":"apply","proposal_id":"11111111-1111-1111-1111-111111111111"}"#),
            context: applyContext(run: run, conversation: try await requireConversation(db, run),
                                  workspace: workspace, toolCallID: "call-artifact",
                                  idempotencyKey: "idem-artifact", authority: authority))
        let jobID = try #require(extractJobID(output.summary))
        let terminal = try await waitForTerminal(service, id: jobID)
        #expect(terminal.state == .failed)
        #expect(terminal.resultPath == nil)
        #expect(terminal.lastError?.contains("does not exist") == true)
    }

    // MARK: - Truthful cancellation and progress

    @Test("running cancellation stays non-terminal through a deliberately blocked cleanup")
    func cancellationWaitsForCleanup() async throws {
        let (db, _, run, workspace) = try await fixture()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let registry = ToolRunnerRegistry()
        registerEcho(registry, name: "document.office.edit")
        let requests = PreparedRequestRecorder()
        // Cleanup deliberately blocks for ~600ms after the stop request.
        let operation = FixturePreparedOperation(
            behavior: .cancelAfterCleanup(cleanupNanoseconds: 600_000_000), frozenRevision: "rev-9")
        let terminals = TerminalCollector()
        let service = BackgroundJobService(
            store: storeOf(db), registry: registry,
            policy: .withAdaptedApplyActions(["document.office.edit": ["apply"]]),
            adapters: ["document.office.edit": makeAdapter(operation: operation, preparedRequests: requests)],
            onTerminal: { job in await terminals.record(job) })
        let conversation = try await requireConversation(db, run)
        let context = applyContext(run: run, conversation: conversation, workspace: workspace,
                                   toolCallID: "call-cancel", idempotencyKey: "idem-cancel")
        let authority = await issueAuthority(try officeBinding(context: context))
        let output = try await JobsSubmitTool(service: service).execute(
            .init(tool: "document.office.edit",
                  arguments: #"{"action":"apply","proposal_id":"11111111-1111-1111-1111-111111111111"}"#),
            context: applyContext(run: run, conversation: conversation, workspace: workspace,
                                  toolCallID: "call-cancel", idempotencyKey: "idem-cancel",
                                  authority: authority))
        let jobID = try #require(extractJobID(output.summary))
        _ = try await waitForState(service, id: jobID) { $0.state == .running }

        let requested = try await service.cancel(id: jobID)
        #expect(requested.state == .running)
        let document = try #require(NativeJobProgressDocument.decode(requested.progressJSON))
        #expect(document.cancellationRequested == true)
        #expect(document.progress?.stage == .cancelling)
        // The deliberately blocked cleanup is still in flight: no premature
        // terminal transition and NO premature terminal notification.
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(try await service.job(id: jobID)?.state == .running)
        #expect(await terminals.count == 0)
        #expect(operation.cleanupCompleted == false)

        let terminal = try await waitForTerminal(service, id: jobID)
        #expect(terminal.state == .cancelled)
        #expect(operation.cleanupCompleted == true)
        #expect(terminal.lastError?.contains("staging was cleaned") == true)
        #expect(await terminals.count == 1)
        #expect(await terminals.jobs.first?.state == .cancelled)
    }

    @Test("a job that reaches its commit boundary despite a cancel request reports the actual result")
    func cancellationRaceReportsActualResult() async throws {
        let (db, _, run, workspace) = try await fixture()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let registry = ToolRunnerRegistry()
        registerEcho(registry, name: "document.office.edit")
        let requests = PreparedRequestRecorder()
        let terminals = TerminalCollector()
        let artifact = workspace.appendingPathComponent("race.edited.xlsx").path
        let operation = FixturePreparedOperation(
            behavior: .completeDespiteCancellation, artifactPath: artifact)
        let service = BackgroundJobService(
            store: storeOf(db), registry: registry,
            policy: .withAdaptedApplyActions(["document.office.edit": ["apply"]]),
            adapters: ["document.office.edit": makeAdapter(operation: operation, preparedRequests: requests)],
            onTerminal: { job in await terminals.record(job) })
        let conversation = try await requireConversation(db, run)
        let context = applyContext(run: run, conversation: conversation, workspace: workspace,
                                   toolCallID: "call-race", idempotencyKey: "idem-race")
        let authority = await issueAuthority(try officeBinding(context: context))
        let output = try await JobsSubmitTool(service: service).execute(
            .init(tool: "document.office.edit",
                  arguments: #"{"action":"apply","proposal_id":"11111111-1111-1111-1111-111111111111"}"#),
            context: applyContext(run: run, conversation: conversation, workspace: workspace,
                                  toolCallID: "call-race", idempotencyKey: "idem-race",
                                  authority: authority))
        let jobID = try #require(extractJobID(output.summary))
        _ = try await waitForState(service, id: jobID, { _ in operation.started })
        _ = try await service.cancel(id: jobID)
        let terminal = try await waitForTerminal(service, id: jobID)
        // The operation had already reached its verified commit boundary; the
        // ACTUAL result is reported, never a falsely cancelled success.
        #expect(terminal.state == .completed)
        #expect(terminal.resultPath == artifact)
        #expect(terminal.resultSummary?.contains("already completing") == true)
    }

    @Test("jobs.status exposes real bounded progress with units while the job runs")
    func liveProgressVisible() async throws {
        let (db, _, run, workspace) = try await fixture()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let registry = ToolRunnerRegistry()
        registerEcho(registry, name: "document.office.edit")
        let requests = PreparedRequestRecorder()
        let release = AsyncGate()
        let operation = FixturePreparedOperation(behavior: .holdAtUnits(release: release))
        let service = BackgroundJobService(
            store: storeOf(db), registry: registry,
            policy: .withAdaptedApplyActions(["document.office.edit": ["apply"]]),
            adapters: ["document.office.edit": makeAdapter(operation: operation, preparedRequests: requests)])
        let conversation = try await requireConversation(db, run)
        let context = applyContext(run: run, conversation: conversation, workspace: workspace,
                                   toolCallID: "call-progress", idempotencyKey: "idem-progress")
        let authority = await issueAuthority(try officeBinding(context: context))
        let output = try await JobsSubmitTool(service: service).execute(
            .init(tool: "document.office.edit",
                  arguments: #"{"action":"apply","proposal_id":"11111111-1111-1111-1111-111111111111"}"#),
            context: applyContext(run: run, conversation: conversation, workspace: workspace,
                                  toolCallID: "call-progress", idempotencyKey: "idem-progress",
                                  authority: authority))
        let jobID = try #require(extractJobID(output.summary))
        _ = try await waitForState(service, id: jobID, { job in
            NativeJobProgressDocument.decode(job.progressJSON)?.progress?.completedUnits == 2
        }, timeout: 10)
        let status = try await JobsStatusTool(service: service).execute(
            .init(jobID: jobID.uuidString),
            context: .init(runID: run, cancellation: CancellationToken()))
        #expect(status.summary.contains("\"completedUnits\":2"))
        #expect(status.summary.contains("\"totalUnits\":4"))
        #expect(status.summary.contains("\"phase\":\"processing\""))
        await release.open()
        let terminal = try await waitForTerminal(service, id: jobID)
        #expect(terminal.state == .completed)
    }

    @Test("progress writes are coalesced and the last real update survives")
    func progressCoalescing() async throws {
        let (db, conversation, run, _) = try await fixture()
        let store = BackgroundJobStore(database: db)
        let job = try await store.save(BackgroundJob(
            conversationID: conversation, runID: run, kind: .tool,
            targetTool: "video.interpolate", payloadJSON: Data("{}".utf8), state: .running))
        let recorder = NativeJobProgressRecorder(store: store, jobID: job.id,
                                                 document: NativeJobProgressDocument())
        for unit in 1...40 {
            await recorder.record(NativeJobProgress(stage: .running, phase: "frame",
                                                    completedUnits: unit, totalUnits: 40))
        }
        await recorder.finish()
        let writes = await recorder.writeCount
        #expect(writes <= 3) // 40 rapid same-stage updates coalesce
        let document = try #require(NativeJobProgressDocument.decode(try await store.job(id: job.id)?.progressJSON))
        #expect(document.progress?.completedUnits == 40)
        #expect(document.progress?.stage == .running)
    }

    @Test("interrupted and cancelled notes never claim nothing happened")
    func honestInterruptedNote() async throws {
        let (db, conversation, run, _) = try await fixture()
        let store = BackgroundJobStore(database: db)
        let interrupted = try await store.save(BackgroundJob(
            conversationID: conversation, runID: run, kind: .tool,
            targetTool: "exec.shell", payloadJSON: Data("{}".utf8),
            state: .running))
        let service = BackgroundJobService(store: store, registry: ToolRunnerRegistry())
        _ = try await service.reconcileInterruptedOnLaunch()
        #expect(try await service.job(id: interrupted.id)?.state == .interrupted)
        let result = try await JobsResultTool(service: service).execute(
            .init(jobID: interrupted.id.uuidString),
            context: .init(runID: run, cancellation: CancellationToken()))
        #expect(result.summary.contains("UNKNOWN"))
        #expect(result.summary.contains("do not blindly rerun"))
    }

    // MARK: - Helpers

    private func requireConversation(_ db: DatabaseManager, _ run: UUID) async throws -> UUID {
        guard let conversation = try await storeOf(db).conversationID(runID: run) else {
            throw FloeError.internalError("run has no owning task")
        }
        return conversation
    }

    private func storeJobs(_ db: DatabaseManager) async throws -> [BackgroundJob] {
        try await BackgroundJobStore(database: db).activeJobs()
    }

    private func storeOf(_ db: DatabaseManager) -> BackgroundJobStore {
        BackgroundJobStore(database: db)
    }

    private func extractJobID(_ summary: String) -> UUID? {
        guard let data = summary.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["jobID"] as? String else { return nil }
        return UUID(uuidString: raw)
    }
}

// MARK: - Fixtures

private actor PreparedRequestRecorder {
    private(set) var requests: [NativeJobPreparationRequest] = []
    func record(_ request: NativeJobPreparationRequest) { requests.append(request) }
    var count: Int { requests.count }
    var first: NativeJobPreparationRequest? { requests.first }
}

private actor AsyncGate {
    private var isOpen = false
    func open() { isOpen = true }
    var opened: Bool { isOpen }
    func waitUntilOpen() async {
        while !isOpen { try? await Task.sleep(nanoseconds: 10_000_000) }
    }
}

/// Fixture service-owned operation. `@unchecked Sendable` under an internal
/// lock; the job service only calls it as `any NativeJobPreparedOperation`.
private final class FixturePreparedOperation: NativeJobPreparedOperation, @unchecked Sendable {
    enum Behavior {
        case complete
        case completeDespiteCancellation
        case cancelAfterCleanup(cleanupNanoseconds: UInt64)
        case holdAtUnits(release: AsyncGate)
    }

    let operationID: String
    let frozenRevision: String?
    let serviceLabel = "fixture-service"
    private let behavior: Behavior
    private let artifactPath: String?
    private let writesArtifact: Bool
    private let lock = NSLock()
    private var _cleanupCompleted = false
    private var _started = false

    init(behavior: Behavior, operationID: String = "fixture-operation-1",
         frozenRevision: String? = nil, artifactPath: String? = nil,
         writesArtifact: Bool = true) {
        self.behavior = behavior
        self.operationID = operationID
        self.frozenRevision = frozenRevision
        self.artifactPath = artifactPath
        self.writesArtifact = writesArtifact
    }

    var cleanupCompleted: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cleanupCompleted
    }

    var started: Bool {
        lock.lock(); defer { lock.unlock() }
        return _started
    }

    private func markStarted() {
        lock.lock(); _started = true; lock.unlock()
    }

    private func markCleanup() {
        lock.lock(); _cleanupCompleted = true; lock.unlock()
    }

    func run(hooks: NativeJobRunHooks) async throws -> NativeJobOutcome {
        markStarted()
        await hooks.report(NativeJobProgress(stage: .running, phase: "processing",
                                             completedUnits: 1, totalUnits: 4))
        switch behavior {
        case .complete:
            await hooks.report(NativeJobProgress(stage: .running, phase: "processing",
                                                 completedUnits: 2, totalUnits: 4))
            if let artifactPath, writesArtifact {
                try Data("verified-artifact".utf8).write(to: URL(fileURLWithPath: artifactPath))
            }
            await hooks.report(NativeJobProgress(stage: .verifying, phase: "artifact",
                                                 completedUnits: 4, totalUnits: 4))
            return NativeJobOutcome(summary: "fixture operation completed",
                                    digest: "fixture-digest", verified: ["fixture-artifact"],
                                    artifactPath: artifactPath, frozenRevision: frozenRevision)
        case .completeDespiteCancellation:
            while !hooks.isCancellationRequested() {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            if let artifactPath, writesArtifact {
                try Data("verified-artifact".utf8).write(to: URL(fileURLWithPath: artifactPath))
            }
            return NativeJobOutcome(summary: "fixture operation completed",
                                    digest: "fixture-digest", verified: ["fixture-artifact"],
                                    artifactPath: artifactPath, frozenRevision: frozenRevision)
        case .cancelAfterCleanup(let cleanupNanoseconds):
            while !hooks.isCancellationRequested() {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            // Simulate a deliberately blocked staging cleanup.
            if cleanupNanoseconds > 0 {
                try await Task.sleep(nanoseconds: cleanupNanoseconds)
            }
            markCleanup()
            throw FloeError.cancelled
        case .holdAtUnits(let release):
            await hooks.report(NativeJobProgress(stage: .running, phase: "processing",
                                                 completedUnits: 2, totalUnits: 4))
            await release.waitUntilOpen()
            return NativeJobOutcome(summary: "fixture operation completed", digest: "fixture-digest",
                                    artifactPath: artifactPath, frozenRevision: frozenRevision)
        }
    }

    func requestCancellation() async {}
}
