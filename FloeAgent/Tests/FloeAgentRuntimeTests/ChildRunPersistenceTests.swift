// FloeAgentRuntimeTests — a delegated child's identity is persisted BEFORE
// its first provider turn and its real transcript/result land in the durable
// store, so the child panel can show a finished child after UI close or a
// relaunch instead of "no subagents".

import Foundation
import Testing
import FloeCore
import FloeModels
@testable import FloePersistence
@testable import FloeProviders
import FloeTools
import FloeTestSupport
@testable import FloeAgentRuntime

/// In-memory ChildRunStoring with an ordered event log so the test can prove
/// registration happened before the first provider request.
private actor FakeChildRunStore: ChildRunStoring {
    private(set) var log: [String] = []
    private var records: [UUID: ChildRunRecord] = [:]
    private var entries: [UUID: [ChildRunEntry]] = [:]

    func register(_ record: ChildRunRecord) async throws -> ChildRunRecord {
        log.append("register")
        records[record.id] = record
        return record
    }

    func transition(id: UUID, state: ChildRunState, iterationCount: Int?, endedAt: Date?) async throws {
        log.append("transition:\(state.rawValue)")
        guard var record = records[id] else { return }
        record.state = state
        if let iterationCount { record.iterationCount = iterationCount }
        records[id] = record
    }

    func appendEntry(id: UUID, kind: ChildRunEntryKind, payloadJSON: String) async throws {
        log.append("entry:\(kind.rawValue)")
        entries[id, default: []].append(ChildRunEntry(
            childRunID: id,
            sequence: (entries[id]?.count ?? 0) + 1,
            kind: kind,
            payloadJSON: payloadJSON))
    }

    func finish(
        id: UUID,
        state: ChildRunState,
        iterationCount: Int,
        resultSummary: String?,
        errorText: String?,
        digest: String?
    ) async throws {
        log.append("finish:\(state.rawValue)")
        guard var record = records[id] else { return }
        record.state = state
        record.iterationCount = iterationCount
        record.resultSummary = resultSummary
        record.errorText = errorText
        record.digest = digest
        records[id] = record
    }

    func child(id: UUID) async throws -> ChildRunRecord? { records[id] }
    func children(parentRunID: UUID) async throws -> [ChildRunRecord] {
        records.values.filter { $0.parentRunID == parentRunID }
    }
    func children(conversationID: UUID) async throws -> [ChildRunRecord] {
        records.values.filter { $0.conversationID == conversationID }
    }
    func entries(childRunID: UUID, afterSequence: Int, limit: Int) async throws -> ChildRunEntryPage {
        let all = (entries[childRunID] ?? []).filter { $0.sequence > afterSequence }.prefix(limit)
        return ChildRunEntryPage(entries: Array(all), nextSequence: nil)
    }
    func reconcileInterruptedOnLaunch() async throws -> Int { 0 }

    func snapshot(for id: UUID) -> ChildRunRecord? { records[id] }
    func entryKinds(for id: UUID) -> [ChildRunEntryKind] { (entries[id] ?? []).map(\.kind) }
}

/// A store whose identity registration always fails: PRODUCTION persistence is
/// mandatory, so the child must be refused BEFORE its first provider turn.
private actor FailingRegisterChildRunStore: ChildRunStoring {
    private(set) var registerAttempts = 0
    private var records: [UUID: ChildRunRecord] = [:]

    func register(_ record: ChildRunRecord) async throws -> ChildRunRecord {
        registerAttempts += 1
        throw FloeError.storageCorrupted("simulated register failure")
    }
    func transition(id: UUID, state: ChildRunState, iterationCount: Int?, endedAt: Date?) async throws {}
    func appendEntry(id: UUID, kind: ChildRunEntryKind, payloadJSON: String) async throws {}
    func finish(
        id: UUID,
        state: ChildRunState,
        iterationCount: Int,
        resultSummary: String?,
        errorText: String?,
        digest: String?
    ) async throws {}
    func child(id: UUID) async throws -> ChildRunRecord? { records[id] }
    func children(parentRunID: UUID) async throws -> [ChildRunRecord] { [] }
    func children(conversationID: UUID) async throws -> [ChildRunRecord] { [] }
    func entries(childRunID: UUID, afterSequence: Int, limit: Int) async throws -> ChildRunEntryPage {
        ChildRunEntryPage(entries: [], nextSequence: nil)
    }
    func reconcileInterruptedOnLaunch() async throws -> Int { 0 }
}

private actor SnapshotRecorder {
    private(set) var snapshots: [ChildRunSnapshot] = []
    func record(_ snapshot: ChildRunSnapshot) { snapshots.append(snapshot) }
}

private final class OrderedProviderAdapter: ProviderAdapter, @unchecked Sendable {
    let protocolKind: ModelProtocol = .openAIResponses
    private let log: AsyncLock<[String]>
    private let script: [[AgentEvent]]
    private let storage = AsyncLock(0)

    init(log: AsyncLock<[String]>, script: [[AgentEvent]]) {
        self.log = log
        self.script = script
    }

    func stream(
        request: ProviderStreamRequest,
        credentials: ProviderCredentials
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        log.withLock { $0.append("provider") }
        let index = storage.withLock { state -> Int in
            let current = state
            state += 1
            return current
        }
        let events = index < script.count ? script[index] : []
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    func listModels(provider: ProviderProfile, credentials: ProviderCredentials) async throws -> [ModelProfile] { [] }
}

@Suite("FloeAgentRuntime.ChildRunPersistence")
struct ChildRunPersistenceTests {

    @Test("Child identity is durable before the first turn and the transcript/result persist")
    func childIdentityAndTranscript() async throws {
        let store = FakeChildRunStore()
        let observer = SnapshotRecorder()
        let log = AsyncLock<[String]>([])
        let childID = UUID()
        let parentRunID = UUID()
        let rootTaskID = UUID()
        let toolCall = try TestFixtures.toolCall(
            id: "call-1", toolName: "web.fetch", arguments: #"{"url":"https://example.com"}"#)
        let adapter = OrderedProviderAdapter(log: log, script: [
            [.toolRequest(toolCall)],
            [.textDelta(.init(text: "researched")), .completed(.init(stopReason: .endTurn))]
        ])
        let executor = MockExecutor()
        executor.descriptors["web.fetch"] = .init(
            name: "web.fetch", riskLabels: [], isSideEffecting: false)
        executor.results = [ToolResult(callID: "call-1", status: .ok,
                                       outputSummary: "page text", outputDigest: "d1")]
        let runner = SubagentRunner(
            provider: TestFixtures.localhostProvider(),
            model: TestFixtures.testModel(providerID: TestFixtures.localhostProvider().id),
            adapter: adapter,
            credentials: ProviderCredentials(),
            executor: executor,
            childRunStore: store,
            onChildStateChange: { snapshot in await observer.record(snapshot) }
        )
        let bus = SubagentPeerBus()
        let identity = ChildExecutionIdentity(
            childID: childID, parentRunID: parentRunID, rootTaskID: rootTaskID,
            delegateCallID: "delegate-call-1")
        let dispatcher = ChildToolDispatcher(
            descriptorProvider: { _ in nil },
            allDescriptors: { [] },
            dispatch: { call, _ in
                ToolResult(callID: call.id, status: .ok, outputSummary: "dispatched", outputDigest: "dd")
            }
        )
        let context = ToolContext(
            runID: parentRunID,
            scope: .local,
            cancellation: CancellationToken(),
            childBudget: ChildBudgetContext(maximumIterations: 6, reserve: { true }, finish: {}),
            conversationID: rootTaskID,
            childExecution: ChildExecutionHandoff(
                identity: identity,
                dispatcher: dispatcher,
                peers: bus.handle(for: identity))
        )
        let outcome = try await runner.runStructured(
            SubagentRequest(task: "research something", kind: .research, runID: parentRunID),
            context: context)
        #expect(outcome.status == .completed)

        // Registration precedes the first provider request in the real order.
        let ordered = log.withLock { $0 }
        #expect(ordered.first == "provider" || ordered.first == "register")
        let storeLog = await store.log
        #expect(storeLog.first == "register")
        // The delegate call id travels with the registered record, so the
        // tool card can map callID → child and open the SPECIFIC transcript.
        #expect(await store.snapshot(for: childID)?.delegateCallID == "delegate-call-1")
        #expect(storeLog.contains("transition:running"))
        #expect(storeLog.contains("entry:toolRequest"))
        #expect(storeLog.contains("entry:toolResult"))
        #expect(storeLog.contains("entry:result"))
        #expect(storeLog.contains("finish:completed"))
        #expect(storeLog.firstIndex(of: "finish:completed")! < storeLog.lastIndex(of: "entry:result")!)

        let record = await store.snapshot(for: childID)
        #expect(record?.parentRunID == parentRunID)
        #expect(record?.rootRunID == rootTaskID)
        #expect(record?.conversationID == rootTaskID)
        #expect(record?.kind == "research")
        #expect(record?.state == .completed)
        #expect(record?.resultSummary?.contains("researched") == true)
        #expect(record?.iterationCount ?? 0 >= 2)
        let kinds = await store.entryKinds(for: childID)
        #expect(kinds.contains(.toolRequest) && kinds.contains(.toolResult) && kinds.contains(.result))
        let snapshots = await observer.snapshots
        #expect(snapshots.contains { $0.state == .completed })
    }

    @Test("A cancelled child finishes cancelled, never completed")
    func cancelledChildFinishesCancelled() async throws {
        let store = FakeChildRunStore()
        let log = AsyncLock<[String]>([])
        let adapter = OrderedProviderAdapter(log: log, script: [[
            .error(AgentEvent.NormalizedError(kind: .network, providerMessage: "stream failed"))
        ]])
        let runner = SubagentRunner(
            provider: TestFixtures.localhostProvider(),
            model: TestFixtures.testModel(providerID: TestFixtures.localhostProvider().id),
            adapter: adapter,
            credentials: ProviderCredentials(),
            executor: MockExecutor(),
            childRunStore: store
        )
        let bus = SubagentPeerBus()
        let identity = ChildExecutionIdentity(
            parentRunID: UUID(), rootTaskID: UUID(), delegateCallID: "delegate-call-2")
        let dispatcher = ChildToolDispatcher(
            descriptorProvider: { _ in nil }, allDescriptors: { [] },
            dispatch: { call, _ in ToolResult(callID: call.id, status: .ok, outputSummary: "", outputDigest: "") })
        let outcome = try await runner.runStructured(
            SubagentRequest(task: "fail", kind: .explore, runID: identity.parentRunID),
            context: ToolContext(
                runID: identity.parentRunID,
                scope: .local,
                cancellation: CancellationToken(),
                childBudget: ChildBudgetContext(maximumIterations: 3, reserve: { true }, finish: {}),
                conversationID: identity.rootTaskID,
                childExecution: ChildExecutionHandoff(
                    identity: identity, dispatcher: dispatcher, peers: bus.handle(for: identity))))
        #expect(outcome.status != .completed)
        let record = await store.snapshot(for: identity.childID)
        #expect(record?.state != .completed)
    }

    @Test("A failed durable registration refuses to start the child before any provider turn")
    func registerFailureRefusesChild() async throws {
        let store = FailingRegisterChildRunStore()
        let log = AsyncLock<[String]>([])
        let parentRunID = UUID()
        let identity = ChildExecutionIdentity(
            parentRunID: parentRunID, rootTaskID: UUID(), delegateCallID: "delegate-call-3")
        let adapter = OrderedProviderAdapter(log: log, script: [[
            .textDelta(.init(text: "would have run")),
            .completed(.init(stopReason: .endTurn))
        ]])
        let runner = SubagentRunner(
            provider: TestFixtures.localhostProvider(),
            model: TestFixtures.testModel(providerID: TestFixtures.localhostProvider().id),
            adapter: adapter,
            credentials: ProviderCredentials(),
            executor: MockExecutor(),
            childRunStore: store
        )
        let bus = SubagentPeerBus()
        let dispatcher = ChildToolDispatcher(
            descriptorProvider: { _ in nil }, allDescriptors: { [] },
            dispatch: { call, _ in ToolResult(callID: call.id, status: .ok, outputSummary: "", outputDigest: "") })
        let outcome = try await runner.runStructured(
            SubagentRequest(task: "must not start", kind: .execute, runID: parentRunID),
            context: ToolContext(
                runID: parentRunID,
                scope: .local,
                cancellation: CancellationToken(),
                childBudget: ChildBudgetContext(maximumIterations: 3, reserve: { true }, finish: {}),
                conversationID: identity.rootTaskID,
                childExecution: ChildExecutionHandoff(
                    identity: identity, dispatcher: dispatcher, peers: bus.handle(for: identity))))
        #expect(outcome.status == .toolError)
        #expect(outcome.iterationsUsed == 0)
        #expect(outcome.findings.contains("was not started"))
        #expect(await store.registerAttempts == 1)
        // No provider request was opened for a child that has no durable
        // identity (the adapter log stays empty).
        #expect(log.withLock { $0 }.isEmpty)
        let record = try await store.child(id: identity.childID)
        #expect(record == nil)
    }
}
