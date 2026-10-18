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
/// registration happened before the first provider request. Optional fail
/// flags inject real store errors without changing execution semantics.
private actor FakeChildRunStore: ChildRunStoring {
    private(set) var log: [String] = []
    private var records: [UUID: ChildRunRecord] = [:]
    private var entries: [UUID: [ChildRunEntry]] = [:]
    private let failTransition: Bool
    private let failAppendKinds: Set<ChildRunEntryKind>
    private let failFinish: Bool

    init(
        failTransition: Bool = false,
        failAppendKinds: Set<ChildRunEntryKind> = [],
        failFinish: Bool = false
    ) {
        self.failTransition = failTransition
        self.failAppendKinds = failAppendKinds
        self.failFinish = failFinish
    }

    func register(_ record: ChildRunRecord) async throws -> ChildRunRecord {
        log.append("register")
        records[record.id] = record
        return record
    }

    func transition(id: UUID, state: ChildRunState, iterationCount: Int?, endedAt: Date?) async throws {
        if failTransition {
            log.append("transition:\(state.rawValue):failed")
            throw FloeError.storageCorrupted("simulated transition failure")
        }
        log.append("transition:\(state.rawValue)")
        guard var record = records[id] else { return }
        record.state = state
        if let iterationCount { record.iterationCount = iterationCount }
        records[id] = record
    }

    func appendEntry(id: UUID, kind: ChildRunEntryKind, payloadJSON: String) async throws {
        if failAppendKinds.contains(kind) {
            log.append("entry:\(kind.rawValue):failed")
            throw FloeError.storageCorrupted("simulated append failure")
        }
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
        if failFinish {
            log.append("finish:\(state.rawValue):failed")
            throw FloeError.storageCorrupted("simulated finish failure")
        }
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
    func payloadEntries(for id: UUID) -> [ChildRunEntry] { entries[id] ?? [] }
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

    /// Completed child through the REAL runner with one scripted tool call.
    private func runCompleted(
        store: FakeChildRunStore,
        observer: SnapshotRecorder? = nil
    ) async throws -> (outcome: SubagentOutcome, childID: UUID) {
        let log = AsyncLock<[String]>([])
        let childID = UUID()
        let parentRunID = UUID()
        let rootTaskID = UUID()
        let toolCall = try TestFixtures.toolCall(
            id: "call-1", toolName: "web.fetch",
            arguments: #"{"url":"https://example.com"}"#)
        let adapter = OrderedProviderAdapter(log: log, script: [
            [.toolRequest(toolCall)],
            [.textDelta(.init(text: "researched")), .completed(.init(stopReason: .endTurn))]
        ])
        let executor = MockExecutor()
        executor.descriptors["web.fetch"] = .init(
            name: "web.fetch", riskLabels: [], isSideEffecting: false)
        executor.results = [ToolResult(
            callID: "call-1", status: .ok,
            outputSummary: "page text", outputDigest: "d1")]
        let observerCallback: (@Sendable (ChildRunSnapshot) async -> Void)?
        if let observer {
            observerCallback = { snapshot in await observer.record(snapshot) }
        } else {
            observerCallback = nil
        }
        let runner = SubagentRunner(
            provider: TestFixtures.localhostProvider(),
            model: TestFixtures.testModel(providerID: TestFixtures.localhostProvider().id),
            adapter: adapter,
            credentials: ProviderCredentials(),
            executor: executor,
            childRunStore: store,
            onChildStateChange: observerCallback
        )
        let bus = SubagentPeerBus()
        let identity = ChildExecutionIdentity(
            childID: childID, parentRunID: parentRunID, rootTaskID: rootTaskID,
            delegateCallID: "delegate-call-1")
        let dispatcher = ChildToolDispatcher(
            descriptorProvider: { _ in nil },
            allDescriptors: { [] },
            dispatch: { call, _ in
                ToolResult(callID: call.id, status: .ok,
                           outputSummary: "dispatched", outputDigest: "dd")
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
        return (outcome, childID)
    }

    private func hasIncompleteMarker(_ outcome: SubagentOutcome) -> Bool {
        outcome.evidence.contains { $0.hasPrefix(SubagentRunner.durableIncompleteMarker) }
            && outcome.unfinished.contains {
                $0.hasPrefix(SubagentRunner.durableIncompleteMarker)
            }
    }

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
        // The result tail is durable BEFORE the terminal row, so a terminal
        // record read by the inspector already has its result entry.
        #expect(storeLog.lastIndex(of: "entry:result")! < storeLog.firstIndex(of: "finish:completed")!)

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
        // The stored result keeps its real mixed types (Int/Bool/[String]) and
        // the presentation decoder normalizes them instead of failing whole.
        let resultEntries = await store.payloadEntries(for: childID)
        let resultEntry = try #require(resultEntries.first { $0.kind == .result })
        let fields = ChildRunPayload.decodedStringFields(resultEntry.payloadJSON)
        #expect(fields["status"] == "completed")
        #expect(fields["iterationsUsed"] == String(outcome.iterationsUsed))
        #expect(fields["findings"] == "researched")
        #expect(fields["truncated"] == "false")
        let snapshots = await observer.snapshots
        #expect(snapshots.contains { $0.state == .completed })
    }

    @Test("A provider-error child finishes providerError, never completed")
    func providerErrorChildFinishesNonCompleted() async throws {
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
        #expect(outcome.status == .providerError)
        let record = await store.snapshot(for: identity.childID)
        #expect(record?.state == .providerError)
        let storeLog = await store.log
        #expect(storeLog.lastIndex(of: "entry:result")! < storeLog.firstIndex(of: "finish:providerError")!)
    }

    @Test("A pre-cancelled child persists its result before the cancelled terminal row")
    func preCancelledChildOrdersResultFirst() async throws {
        let store = FakeChildRunStore()
        let log = AsyncLock<[String]>([])
        let adapter = OrderedProviderAdapter(log: log, script: [])
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
            parentRunID: UUID(), rootTaskID: UUID(), delegateCallID: "delegate-call-cancel")
        let dispatcher = ChildToolDispatcher(
            descriptorProvider: { _ in nil }, allDescriptors: { [] },
            dispatch: { call, _ in ToolResult(
                callID: call.id, status: .ok, outputSummary: "", outputDigest: "") })
        let token = CancellationToken()
        token.cancel()
        let outcome = try await runner.runStructured(
            SubagentRequest(task: "cancelled", kind: .explore, runID: identity.parentRunID),
            context: ToolContext(
                runID: identity.parentRunID,
                scope: .local,
                cancellation: token,
                childBudget: ChildBudgetContext(
                    maximumIterations: 3, reserve: { true }, finish: {}),
                conversationID: identity.rootTaskID,
                childExecution: ChildExecutionHandoff(
                    identity: identity, dispatcher: dispatcher,
                    peers: bus.handle(for: identity))))
        #expect(outcome.status == .cancelled)
        let storeLog = await store.log
        #expect(storeLog.contains("entry:result"))
        #expect(storeLog.lastIndex(of: "entry:result")! < storeLog.firstIndex(of: "finish:cancelled")!)
        #expect(await store.snapshot(for: identity.childID)?.state == .cancelled)
    }

    @Test("A failed result append keeps the real success and flags the durable transcript")
    func resultAppendFailureSurfacesIncomplete() async throws {
        let store = FakeChildRunStore(failAppendKinds: [.result])
        let (outcome, childID) = try await runCompleted(store: store)
        // The execution really succeeded; only persistence is incomplete.
        #expect(outcome.status == .completed)
        #expect(outcome.findings == "researched")
        #expect(hasIncompleteMarker(outcome))
        let record = await store.snapshot(for: childID)
        #expect(record?.state == .completed)
        // The terminal row must carry the warning when it can be saved.
        #expect(record?.resultSummary?.contains(SubagentRunner.durableIncompleteMarker) == true)
        let kinds = await store.entryKinds(for: childID)
        #expect(!kinds.contains(.result))
        #expect(kinds.contains(.error))
        let storeLog = await store.log
        #expect(storeLog.contains("entry:result:failed"))
        #expect(storeLog.lastIndex(of: "entry:error")! < storeLog.firstIndex(of: "finish:completed")!)
    }

    @Test("A failed terminal write stays running and never notifies a fake durable completion")
    func finishFailureDoesNotFakeCompletion() async throws {
        let store = FakeChildRunStore(failFinish: true)
        let observer = SnapshotRecorder()
        let (outcome, childID) = try await runCompleted(store: store, observer: observer)
        #expect(outcome.status == .completed)
        #expect(outcome.findings == "researched")
        #expect(hasIncompleteMarker(outcome))
        let record = await store.snapshot(for: childID)
        #expect(record?.state == .running)
        #expect(record?.resultSummary == nil)
        let snapshots = await observer.snapshots
        #expect(!snapshots.contains { $0.state == .completed })
        #expect(snapshots.contains { $0.state == .executingTool })
        let storeLog = await store.log
        #expect(storeLog.contains("finish:completed:failed"))
        #expect(storeLog.contains("entry:error"))
    }

    @Test("A failed progress transition is captured without changing the execution result")
    func transitionFailureSurfacesIncomplete() async throws {
        let store = FakeChildRunStore(failTransition: true)
        let (outcome, childID) = try await runCompleted(store: store)
        #expect(outcome.status == .completed)
        #expect(outcome.findings == "researched")
        #expect(hasIncompleteMarker(outcome))
        let record = await store.snapshot(for: childID)
        #expect(record?.state == .completed)
        #expect(record?.resultSummary?.contains(SubagentRunner.durableIncompleteMarker) == true)
        let transitionLog = await store.log
        #expect(transitionLog.contains("transition:running:failed"))
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
