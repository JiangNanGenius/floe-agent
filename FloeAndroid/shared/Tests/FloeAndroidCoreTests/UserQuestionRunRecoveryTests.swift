// SPDX-License-Identifier: MPL-2.0
import XCTest
import Foundation
import FloeCore
import FloeModels
import FloeProviders
import FloePersistence
import FloeSecurity
import FloeTools
@testable import FloeAgentRuntime

/// Reproduces the dispatched required question left by process death. The
/// runtime and migrated SQLite store are real; the provider records requests
/// without using a network, and any attempt to redispatch a tool fails.
final class UserQuestionRunRecoveryTests: XCTestCase {
    private var root: URL!
    private var database: DatabaseManager!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("uq-run-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try DatabaseManager(path: root.appendingPathComponent("test.db"))
        try await database.migrate()
    }

    override func tearDown() async throws {
        try? await database.close()
        try? FileManager.default.removeItem(at: root)
    }

    private struct Pending: Sendable {
        let runID: UUID
        let conversationID: UUID
        let call: ToolCall
        let snapshot: UserQuestionWaitingSnapshot
    }

    private func ensureTask(conversationID: UUID, runID: UUID) async throws {
        try await database.writer { db in
            try db.execute(sql: """
                INSERT INTO conversations
                (id,title,created_at,updated_at,title_origin,mode,is_searchable,archived_at,purpose)
                VALUES (?, 'recovery', ?, ?, 'manual', 'chat', 1, NULL, 'ordinary')
                """, arguments: [conversationID.uuidString,
                    "2026-11-09T00:00:00.000Z", "2026-11-09T00:00:00.000Z"])
            try db.execute(sql: """
                INSERT INTO runs (id,conversation_id,state,goal,started_at)
                VALUES (?, ?, 'checkpointed', 'recovery', ?)
                """, arguments: [runID.uuidString, conversationID.uuidString,
                    "2026-11-09T00:00:00.000Z"])
        }
    }

    private func seed(policy: UserQuestionWaitPolicy = .required) async throws -> Pending {
        let runID = UUID(), conversationID = UUID()
        try await ensureTask(conversationID: conversationID, runID: runID)
        let request = try UserQuestionRequest(waitPolicy: policy, questions: [
            UserQuestionDraft(id: "continue", question: "Continue this task?",
                options: [UserQuestionOption(id: "yes", label: "Yes")], selection: .single)
        ])
        let call = try ToolCall(id: "ask-original", toolName: UserAskTool.name,
            argumentsJSON: JSONEncoder().encode(request), scope: .local).withIDContext(runID: runID)
        let requestID = UserQuestionCoordinator.requestID(runID: runID, toolCallID: call.id)
        let now = Date()
        let questions = try request.makeQuestions(requestID: requestID,
            conversationID: conversationID, runID: runID, toolCallID: call.id, createdAt: now)
        let snapshot = try await UserQuestionStore(database: database).register(
            UserQuestionRegistration(requestID: requestID,
                requestDigest: UserQuestionCoordinator.digest(request),
                conversationID: conversationID, runID: runID, toolCallID: call.id,
                waitPolicy: policy, questions: questions, createdAt: now, isEphemeral: false))
        return Pending(runID: runID, conversationID: conversationID, call: call, snapshot: snapshot)
    }

    private func checkpoint(_ pending: Pending) -> AgentCheckpoint {
        AgentCheckpoint(runID: pending.runID, conversationID: pending.conversationID,
            state: .preparing(.init(goal: "resume the existing question")),
            messages: [.init(role: "user", content: "Resume the existing question once.")],
            pendingToolCalls: [pending.call],
            toolLifecycleEntries: [.init(callID: pending.call.id, toolName: UserAskTool.name,
                isSideEffecting: false, phase: .dispatched)])
    }

    private func runtime(_ pending: Pending, coordinator: UserQuestionCoordinator,
                         provider: RecoveryProvider, executor: NoRedispatchExecutor,
                         sink: RecoverySink = RecoverySink()) -> FloeAgentRuntime {
        let profile = ProviderProfile(kind: .openAI, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://fixtures.invalid/v1")!)
        let model = ModelProfile(providerID: profile.id, remoteModelID: "recovery-fixture",
            displayName: "Recovery", limits: ModelLimits(contextTokens: 16_000, maxOutputTokens: 2_048),
            capabilities: [.text, .tools])
        return FloeAgentRuntime(configuration: .init(conversationID: pending.conversationID,
            provider: profile, model: model, maxProviderRetries: 0,
            userQuestionRecovery: coordinator), adapter: provider,
            policy: DenyRedispatch(), executor: executor, sink: sink, runID: pending.runID)
    }

    private func waitUntil(_ predicate: @Sendable () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(5)
        while Date() < end {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    func testReopenedRequiredQuestionParksUntilItsOriginalHumanAnswerWithoutRedispatch() async throws {
        let pending = try await seed()
        try await database.close()
        database = try DatabaseManager(path: root.appendingPathComponent("test.db"))
        try await database.migrate()
        let coordinator = UserQuestionCoordinator(store: UserQuestionStore(database: database))
        let provider = RecoveryProvider(), executor = NoRedispatchExecutor()
        let sink = RecoverySink()
        let runtime = runtime(pending, coordinator: coordinator, provider: provider, executor: executor, sink: sink)
        let saved = checkpoint(pending)
        let resumed = Task { try await runtime.resume(from: saved) }
        let waiting = await waitUntil {
            await coordinator.isActivelyWaiting(requestID: pending.snapshot.requestID)
        }
        if !waiting {
            await coordinator.cancelPendingQuestions(runID: pending.runID)
            try await resumed.value
            XCTFail("The original required question was not reattached")
            return
        }
        XCTAssertEqual(provider.requests.count, 0, "No provider request before the human answer")
        let currentValue = try await coordinator.snapshot(requestID: pending.snapshot.requestID)
        let current = try XCTUnwrap(currentValue)
        XCTAssertEqual(current.requestID, pending.snapshot.requestID)
        XCTAssertEqual(current.questions.count, 1)
        let receipt = try await coordinator.submitHumanAnswer(
            target: current.target(for: current.questions[0]),
            answer: .init(selectedOptionIDs: ["yes"]))
        XCTAssertTrue(receipt.accepted)
        try await resumed.value
        let request = try XCTUnwrap(provider.requests.first)
        let restoredValue = await sink.result(callID: pending.call.id)
        let result = try XCTUnwrap(restoredValue)
        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertEqual(executor.executionCount, 0)
        XCTAssertEqual(request.toolResults.first?.callID, pending.call.id)
        XCTAssertTrue(request.toolResults.first?.output.contains(pending.snapshot.requestID) == true)
        XCTAssertEqual(result.callID, pending.call.id)
        XCTAssertEqual(result.status, .ok)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.outputSummary.utf8))
            as? [String: Any])
        XCTAssertEqual(body["requestID"] as? String, pending.snapshot.requestID)
        XCTAssertEqual(body["status"] as? String, "answered")
    }

    func testStoppingRestoredQuestionCancelsItsRowAndNeverStartsTheProvider() async throws {
        let pending = try await seed()
        let coordinator = UserQuestionCoordinator(store: UserQuestionStore(database: database))
        let provider = RecoveryProvider(), executor = NoRedispatchExecutor()
        let runtime = runtime(pending, coordinator: coordinator, provider: provider, executor: executor)
        let saved = checkpoint(pending)
        let resumed = Task { try await runtime.resume(from: saved) }
        let waiting = await waitUntil {
            await coordinator.isActivelyWaiting(requestID: pending.snapshot.requestID)
        }
        if !waiting {
            await coordinator.cancelPendingQuestions(runID: pending.runID)
            try await resumed.value
            XCTFail("The cancellation case never reached its restored wait")
            return
        }
        await runtime.cancel()
        try await resumed.value
        let currentValue = try await coordinator.snapshot(requestID: pending.snapshot.requestID)
        let current = try XCTUnwrap(currentValue)
        XCTAssertEqual(current.state, .cancelled)
        let late = try await coordinator.submitHumanAnswer(
            target: pending.snapshot.target(for: pending.snapshot.questions[0]),
            answer: .init(selectedOptionIDs: ["yes"]))
        XCTAssertFalse(late.accepted)
        XCTAssertTrue(late.alreadySettled)
        XCTAssertEqual(provider.requests.count, 0)
        XCTAssertEqual(executor.executionCount, 0)
        let state = await runtime.state
        XCTAssertEqual(state.name, "checkpointed")
    }

    func testMissingMatchingQuestionDoesNotAdoptAnotherRunsWaitOrReplayATool() async throws {
        let foreign = try await seed()
        let ownRun = UUID(), ownConversation = UUID()
        try await ensureTask(conversationID: ownConversation, runID: ownRun)
        let own = Pending(runID: ownRun, conversationID: ownConversation,
            call: foreign.call.withIDContext(runID: ownRun), snapshot: foreign.snapshot)
        let coordinator = UserQuestionCoordinator(store: UserQuestionStore(database: database))
        let provider = RecoveryProvider(), executor = NoRedispatchExecutor()
        let sink = RecoverySink()
        let runtime = runtime(own, coordinator: coordinator, provider: provider, executor: executor, sink: sink)
        try await runtime.resume(from: checkpoint(own))
        let restoredValue = await sink.result(callID: own.call.id)
        let result = try XCTUnwrap(restoredValue)
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.outputSummary.contains("interrupted after dispatch"))
        XCTAssertEqual(provider.requests.first?.toolResults.first?.callID, own.call.id)
        XCTAssertTrue(provider.requests.first?.toolResults.first?.output
            .contains("interrupted after dispatch") == true)
        XCTAssertEqual(executor.executionCount, 0)
        let foreignValue = try await coordinator.snapshot(requestID: foreign.snapshot.requestID)
        XCTAssertTrue(try XCTUnwrap(foreignValue).questions.contains(where: \.isPending))
    }

    func testOptionalContinueRecoveryPreservesItsPendingReceiptAndLateAnswer() async throws {
        let pending = try await seed(policy: .optionalContinue)
        let coordinator = UserQuestionCoordinator(store: UserQuestionStore(database: database))
        let provider = RecoveryProvider(), executor = NoRedispatchExecutor()
        let sink = RecoverySink()
        let runtime = runtime(pending, coordinator: coordinator, provider: provider, executor: executor, sink: sink)
        try await runtime.resume(from: checkpoint(pending))
        let restoredValue = await sink.result(callID: pending.call.id)
        let result = try XCTUnwrap(restoredValue)
        XCTAssertEqual(result.status, .ok)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.outputSummary.utf8))
            as? [String: Any])
        XCTAssertEqual(body["status"] as? String, "pending")
        let currentValue = try await coordinator.snapshot(requestID: pending.snapshot.requestID)
        let current = try XCTUnwrap(currentValue)
        XCTAssertTrue(current.questions.contains(where: \.isPending),
            "A normal completed turn must preserve optionalContinue delivery")
        let late = try await coordinator.submitHumanAnswer(
            target: current.target(for: current.questions[0]), answer: .init(selectedOptionIDs: ["yes"]))
        XCTAssertTrue(late.accepted)
        XCTAssertEqual(executor.executionCount, 0)
    }
}

private actor RecoverySink: AgentEventSink {
    private var results: [ToolResult] = []
    func result(callID: String) -> ToolResult? { results.first { $0.callID == callID } }
    func agentRuntime(_ runtime: FloeAgentRuntime, didTransitionTo state: AgentState) async {}
    func agentRuntime(_ runtime: FloeAgentRuntime, didEmit event: AgentEvent) async {
        if case .toolResult(let result) = event { results.append(result) }
    }
}

private final class RecoveryProvider: ProviderAdapter, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [ProviderStreamRequest] = []
    var requests: [ProviderStreamRequest] { lock.withLock { captured } }
    var protocolKind: ModelProtocol { .openAIChatCompletions }
    func stream(request: ProviderStreamRequest, credentials: ProviderCredentials)
        -> AsyncThrowingStream<AgentEvent, Error> {
        lock.withLock { captured.append(request) }
        return AsyncThrowingStream { continuation in
            continuation.yield(.completed(.init(stopReason: .endTurn)))
            continuation.finish()
        }
    }
    func listModels(provider: ProviderProfile, credentials: ProviderCredentials) async throws -> [ModelProfile] { [] }
}

private struct DenyRedispatch: ApprovalPolicy {
    var policyName: String { "recovery-deny" }
    func decide(_ action: ProposedAction) async throws -> ApprovalDecision {
        .deny(reason: "A recovered question must not redispatch a tool")
    }
}

private final class NoRedispatchExecutor: ToolExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var executionCount: Int { lock.withLock { count } }
    var allDescriptors: [ToolCatalog.Descriptor] { [] }
    func descriptor(named name: String) -> ToolCatalog.Descriptor? { nil }
    func execute(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        lock.withLock { count += 1 }
        throw FloeError.internalError("Unexpected tool redispatch")
    }
}
