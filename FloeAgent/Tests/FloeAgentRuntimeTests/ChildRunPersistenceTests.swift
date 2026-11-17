// FloeAgentRuntimeTests — a delegated child's identity is persisted BEFORE
// its first provider turn and its real transcript/result land in the durable
// store, so the child panel can show a finished child after UI close or a
// relaunch instead of "no subagents".

import Foundation
import Testing
import FloeCore
import FloeModels
import FloeSecurity
@testable import FloePersistence
@testable import FloeProviders
import FloeTools
import FloeTestSupport
@testable import FloeAgentRuntime

/// In-memory ChildRunStoring with an ordered event log so the test can prove
/// registration happened before the first provider request. Optional fail
/// flags inject real store errors without changing execution semantics.
private actor BackgroundLookupGate {
    private(set) var entered = false
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}

private actor FakeChildRunStore: ChildRunStoring, ChildRunCheckpointStoring {
    private(set) var log: [String] = []
    private var records: [UUID: ChildRunRecord] = [:]
    private var entries: [UUID: [ChildRunEntry]] = [:]
    private var checkpoints: [UUID: ChildRunCheckpoint] = [:]
    private var backgroundOwners: [UUID: BackgroundChildOwner] = [:]
    private var poisonedChildren: Set<UUID> = []
    func poisonEntries(for id: UUID) { poisonedChildren.insert(id) }
    private let failTransition: Bool
    private let failAppendKinds: Set<ChildRunEntryKind>
    private let failFinish: Bool
    private let lookupGate: BackgroundLookupGate?
    private let seedStaleResult: Bool
    private let failCheckpoint: Bool

    init(
        failTransition: Bool = false,
        failAppendKinds: Set<ChildRunEntryKind> = [],
        failFinish: Bool = false,
        lookupGate: BackgroundLookupGate? = nil,
        seedStaleResult: Bool = false,
        failCheckpoint: Bool = false
    ) {
        self.failTransition = failTransition
        self.failAppendKinds = failAppendKinds
        self.failFinish = failFinish
        self.lookupGate = lookupGate
        self.seedStaleResult = seedStaleResult
        self.failCheckpoint = failCheckpoint
    }

    func register(_ record: ChildRunRecord) async throws -> ChildRunRecord {
        log.append("register")
        records[record.id] = record
        if seedStaleResult {
            entries[record.id] = [ChildRunEntry(childRunID: record.id, sequence: 1, kind: .result,
                payloadJSON: #"{"status":"completed","findings":"OLD RESULT"}"#)]
        }
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
        await lookupGate?.wait()
        return records.values.filter { $0.parentRunID == parentRunID }
    }
    func children(conversationID: UUID) async throws -> [ChildRunRecord] {
        records.values.filter { $0.conversationID == conversationID }
    }
    func entries(childRunID: UUID, afterSequence: Int, limit: Int) async throws -> ChildRunEntryPage {
        if poisonedChildren.contains(childRunID) { throw FloeError.storageCorrupted("unrelated history is unreadable") }
        let all = (entries[childRunID] ?? []).filter { $0.sequence > afterSequence }.prefix(limit)
        return ChildRunEntryPage(entries: Array(all), nextSequence: nil)
    }
    func assignBackgroundOwner(childID: UUID, parentRunID: UUID, conversationID: UUID,
                               resumeOwner: UUID?, payloadJSON: String) async throws {
        guard let child = records[childID], child.conversationID == conversationID,
              resumeOwner != nil || child.parentRunID == parentRunID else {
            throw FloeError.validationFailed("owner mismatch")
        }
        if resumeOwner == nil, let owner = backgroundOwners[childID], owner.parentRunID != parentRunID {
            throw FloeError.validationFailed("owner already moved")
        }
        try await appendEntry(id: childID, kind: .state, payloadJSON: payloadJSON)
        backgroundOwners[childID] = .init(childID: childID, parentRunID: parentRunID, conversationID: conversationID)
    }
    func recordBackgroundStartFailure(childID: UUID, parentRunID: UUID, conversationID: UUID) async throws {
        guard let owner = backgroundOwners[childID], owner.parentRunID == parentRunID,
              owner.conversationID == conversationID, let record = records[childID],
              record.state == .registered || record.state == .interrupted,
              let history = entries[childID], history.count == 1, history[0].kind == .state,
              let data = history[0].payloadJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json.count == 1, json["backgroundDelegate"] as? Bool == true else {
            throw FloeError.storageCorrupted("startup cannot be proven unexecuted")
        }
        try await appendEntry(id: childID, kind: .state, payloadJSON: #"{"backgroundStartFailed":true}"#)
    }
    func backgroundOwner(childID: UUID) async throws -> BackgroundChildOwner? { backgroundOwners[childID] }
    func backgroundChildren(parentRunID: UUID, conversationID: UUID) async throws -> [ChildRunRecord] {
        backgroundOwners.values.filter { $0.parentRunID == parentRunID && $0.conversationID == conversationID }
            .compactMap { records[$0.childID] }
    }
    func reconcileInterruptedOnLaunch() async throws -> Int { 0 }
    func saveCheckpoint(_ checkpoint: ChildRunCheckpoint) async throws {
        if failCheckpoint { throw FloeError.storageCorrupted("simulated checkpoint failure") }
        checkpoints[checkpoint.childID] = checkpoint
    }
    func saveCheckpoint(_ checkpoint: ChildRunCheckpoint, owner: UUID, leaseExpiresAt: Date) async throws { checkpoints[checkpoint.childID] = checkpoint }
    func checkpoint(childRunID: UUID) async throws -> ChildRunCheckpoint? { checkpoints[childRunID] }
    func deleteCheckpoint(childRunID: UUID) async throws { checkpoints[childRunID] = nil }
    func finishResumedChild(id: UUID, owner: UUID, state: ChildRunState, iterationCount: Int,
        resultSummary: String?, errorText: String?, digest: String?) async throws {
        try await finish(id: id, state: state, iterationCount: iterationCount, resultSummary: resultSummary, errorText: errorText, digest: digest)
    }
    func acquireResume(childRunID: UUID, owner: UUID, resumingParentRunID: UUID,
        leaseExpiresAt: Date, expectedCheckpoint: ChildRunCheckpoint?) async throws -> Bool { false }
    func markResumeStarted(childRunID: UUID, owner: UUID) async throws -> Bool { false }
    func extendResumeLease(childRunID: UUID, owner: UUID, leaseExpiresAt: Date) async throws {}
    func finishResume(childRunID: UUID, owner: UUID) async throws {}
    func cancelResume(childRunID: UUID, owner: UUID) async throws {}

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

private final class GatedChildProvider: ProviderAdapter, @unchecked Sendable {
    let protocolKind: ModelProtocol = .openAIResponses
    private let streams = AsyncLock<[AsyncThrowingStream<AgentEvent, Error>.Continuation]>([])
    var count: Int { streams.withLock { $0.count } }
    func stream(request: ProviderStreamRequest, credentials: ProviderCredentials) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            streams.withLock { $0.append(continuation) }
        }
    }
    func release(_ events: [AgentEvent] = [.textDelta(.init(text: "child result")), .completed(.init(stopReason: .endTurn))]) {
        let all = streams.withLock { $0 }
        for stream in all {
            for event in events { stream.yield(event) }
            stream.finish()
        }
    }
    func listModels(provider: ProviderProfile, credentials: ProviderCredentials) async throws -> [ModelProfile] { [] }
}

private struct BackgroundIndependentTool: AgentTool {
    struct Arguments: Decodable, Sendable {}
    static let name = "test.backgroundIndependent"
    static let toolDescription = "Perform independent parent work"
    static let parametersJSON = #"{"type":"object","properties":{},"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    let executed: AsyncLock<Bool>
    func validate(_ args: Arguments) throws {}
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        executed.withLock { $0 = true }
        return ToolExecutionOutput(summary: "parent worked", fullOutputSHA256: "d", exitStatus: 0)
    }
}

private struct BackgroundApprovalPolicy: ApprovalPolicy {
    let policyName = "background-test"
    func decide(_ action: ProposedAction) async throws -> ApprovalDecision {
        if action.toolCall.toolName == "delegate" {
            return .allow(scope: ApprovalScope(toolName: "delegate", singleUse: true), expiresAt: nil)
        }
        return .escalateToHuman(reason: "approve child write")
    }
}

private struct BackgroundWriteTool: AgentTool {
    struct Arguments: Decodable, Sendable {}
    static let name = "test.backgroundWrite"
    static let toolDescription = "A child write requiring explicit approval"
    static let parametersJSON = #"{"type":"object","properties":{},"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.writesFiles]
    static let isSideEffecting = true
    let count: AsyncLock<Int>
    func validate(_ args: Arguments) throws {}
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        count.withLock { $0 += 1 }
        return ToolExecutionOutput(summary: "wrote", fullOutputSHA256: "d", exitStatus: 0)
    }
}

private final class BackgroundApprovalSink: AgentEventSink, @unchecked Sendable {
    let approvals = AsyncLock<[AgentState.WaitingApproval]>([])
    let states = AsyncLock<[AgentState]>([])
    let receipts = AsyncLock<[String]>([])
    func agentRuntime(_ runtime: FloeAgentRuntime, didTransitionTo state: AgentState) async { states.withLock { $0.append(state) } }
    func agentRuntime(_ runtime: FloeAgentRuntime, didRecordApprovalDecision receipt: ApprovalDecisionReceipt) async { receipts.withLock { $0.append(receipt.callID) } }
    func agentRuntime(_ runtime: FloeAgentRuntime, didEmit event: AgentEvent) async {}
    func agentRuntime(_ runtime: FloeAgentRuntime, didChangeBackgroundApproval waiting: AgentState.WaitingApproval?) async {
        if let waiting { approvals.withLock { $0.append(waiting) } }
    }
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
    @Test("background children overlap and durable results are owned, replayed and deduplicated")
    func backgroundChildrenOverlapAndRecover() async throws {
        let store = FakeChildRunStore()
        let provider = TestFixtures.localhostProvider()
        let adapter = GatedChildProvider()
        let runner = SubagentRunner(provider: provider,
            model: TestFixtures.testModel(providerID: provider.id), adapter: adapter,
            credentials: ProviderCredentials(), executor: MockExecutor(), childRunStore: store, checkpointStore: store)
        let registry = SubagentRunnerRegistry()
        let runID = UUID(), conversationID = UUID()
        await registry.register(runner, for: runID)
        await registry.enableBackground(for: runID)
        let bus = SubagentPeerBus()
        let dispatcher = ChildToolDispatcher(descriptorProvider: { _ in nil }, allDescriptors: { [] },
            dispatch: { call, _ in ToolResult(callID: call.id, status: .ok, outputSummary: "ok", outputDigest: "d") })
        func context(_ callID: String) -> ToolContext {
            let identity = ChildExecutionIdentity(parentRunID: runID, rootTaskID: conversationID, delegateCallID: callID)
            return ToolContext(runID: runID, toolCallID: callID, scope: .local,
                cancellation: CancellationToken(), childBudget: ChildBudgetContext(maximumIterations: 6, reserve: { true }, finish: {}),
                conversationID: conversationID, childExecution: ChildExecutionHandoff(identity: identity,
                    dispatcher: dispatcher, peers: bus.handle(for: identity)))
        }
        let request = SubagentRequest(task: "independent research", kind: .research, runID: runID)
        let first = try await registry.startBackground(request, context: context("a"))
        let second = try await registry.startBackground(request, context: context("b"))
        for _ in 0..<100 where adapter.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(adapter.count == 2)
        #expect(try await registry.backgroundSnapshot(runID: runID, conversationID: conversationID, childID: first).state == .running)
        #expect(try await registry.startBackground(request, context: context("a")) == first)
        #expect(try await store.children(parentRunID: runID).count == 2)
        await #expect(throws: (any Error).self) {
            _ = try await registry.backgroundSnapshot(runID: runID, conversationID: UUID(), childID: first)
        }
        let wait = DelegateWaitTool(runners: registry)
        let waitContext = ToolContext(runID: runID, toolCallID: "wait", scope: .local,
            cancellation: CancellationToken(), conversationID: conversationID,
            callOrigin: ToolCallOrigin(kind: .mainRunDelegate, runID: runID, callID: "wait", toolName: "delegate.wait"))
        let check = try await wait.execute(.init(childID: first, seconds: 0), context: waitContext)
        #expect(check.summary.contains("status=running"))
        let finished = AsyncLock(false)
        let waiting = Task {
            let result = try await wait.execute(.init(childID: first, seconds: 5), context: waitContext)
            finished.withLock { $0 = true }
            return result
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(!finished.withLock { $0 })
        adapter.release()
        let result = try await waiting.value
        #expect(result.summary.contains("child result"))
        let settled = try await registry.settleBackground(runID: runID, conversationID: conversationID)
        #expect(Set(settled.map(\.id)) == Set([first, second]))
        #expect(settled.allSatisfy { $0.outcome?.status == .completed })
        // Simulate a new process with the same durable store: no work reruns,
        // and both results remain available until the parent marks delivery.
        let recovered = SubagentRunnerRegistry()
        await recovered.register(runner, for: runID)
        await recovered.enableBackground(for: runID)
        #expect(try await recovered.settleBackground(runID: runID, conversationID: conversationID).count == 2)
        try await recovered.markBackgroundDelivered(runID: runID, conversationID: conversationID, childIDs: [first, second])
        #expect(try await recovered.settleBackground(runID: runID, conversationID: conversationID).isEmpty)
        #expect(adapter.count == 2)
    }

    @Test("parent runs independent tools while child is gated and cannot finish before child result")
    func backgroundParentContinues() async throws {
        let store = FakeChildRunStore()
        let provider = TestFixtures.localhostProvider()
        let runID = UUID(), conversationID = UUID()
        let childAdapter = GatedChildProvider()
        let parentAdapter = MockAdapter()
        parentAdapter.script = [
            [.toolRequest(try TestFixtures.toolCall(id: "delegate", toolName: "delegate", arguments: #"{"task":"research","background":true}"#))],
            [.toolRequest(try TestFixtures.toolCall(id: "independent", toolName: "test.backgroundIndependent", arguments: "{}"))],
            [.textDelta(.init(text: "draft")), .completed(.init(stopReason: .endTurn))],
            [.textDelta(.init(text: "incorporated child")), .completed(.init(stopReason: .endTurn))]
        ]
        let registry = ToolRunnerRegistry(), runners = SubagentRunnerRegistry()
        let executed = AsyncLock(false)
        registry.register(BackgroundIndependentTool(executed: executed))
        registerDelegateTool(registry: registry, runners: runners)
        let executor = CatalogToolExecutor(runners: registry)
        await runners.register(SubagentRunner(provider: provider,
            model: TestFixtures.testModel(providerID: provider.id), adapter: childAdapter,
            credentials: ProviderCredentials(), executor: executor, childRunStore: store, checkpointStore: store), for: runID)
        await runners.enableBackground(for: runID)
        var config = FloeAgentRuntime.Configuration(conversationID: conversationID, provider: provider,
            model: TestFixtures.testModel(providerID: provider.id),
            allowedToolNames: ["delegate", "delegate.wait", "test.backgroundIndependent"], verifyFinalAnswer: false)
        config.settleBackgroundChildren = { try await runners.settleBackground(runID: runID, conversationID: conversationID) }
        config.markBackgroundChildrenDelivered = { try await runners.markBackgroundDelivered(runID: runID, conversationID: conversationID, childIDs: $0) }
        config.cancelBackgroundChildren = { await runners.cancelBackground(runID: runID) }
        config.markBackgroundChildrenInterrupted = { await runners.markBackgroundInterrupted(runID: runID) }
        let checkpoints = MockCheckpointStore()
        let runtime = FloeAgentRuntime(configuration: config, adapter: parentAdapter,
            policy: FullControlPolicy(grant: .init(hostID: UUID(), expiresAt: nil)), executor: executor,
            auditSink: MockAuditSink(), checkpointStore: checkpoints, runID: runID)
        let run = Task { try await runtime.start(goal: "research and work independently") }
        for _ in 0..<400 where !executed.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(executed.withLock { $0 })
        #expect(childAdapter.count == 1)
        let children = try await store.children(parentRunID: runID)
        #expect(children.count == 1)
        #expect(children.first?.state == .running)
        childAdapter.release()
        try await run.value
        #expect(checkpoints.saved.contains { checkpoint in
            checkpoint.messages.contains { $0.content.contains("child result") }
        })
        #expect(try await runners.settleBackground(runID: runID, conversationID: conversationID).isEmpty)
    }

    @Test("stopping during durable lookup fences late child registration")
    func stoppingDuringBackgroundLookup() async throws {
        let gate = BackgroundLookupGate(), store = FakeChildRunStore(lookupGate: gate)
        let provider = TestFixtures.localhostProvider(), adapter = GatedChildProvider()
        let runner = SubagentRunner(provider: provider, model: TestFixtures.testModel(providerID: provider.id),
            adapter: adapter, credentials: ProviderCredentials(), executor: MockExecutor(), childRunStore: store, checkpointStore: store)
        let registry = SubagentRunnerRegistry(), runID = UUID(), conversationID = UUID()
        await registry.register(runner, for: runID)
        await registry.enableBackground(for: runID)
        let identity = ChildExecutionIdentity(parentRunID: runID, rootTaskID: conversationID, delegateCallID: "call")
        let bus = SubagentPeerBus()
        let dispatcher = ChildToolDispatcher(descriptorProvider: { _ in nil }, allDescriptors: { [] },
            dispatch: { call, _ in ToolResult(callID: call.id, status: .ok, outputSummary: "", outputDigest: "") })
        let finishedBudget = AsyncLock(0)
        let context = ToolContext(runID: runID, toolCallID: "call", scope: .local, cancellation: CancellationToken(),
            childBudget: ChildBudgetContext(maximumIterations: 3, reserve: { true }, finish: { finishedBudget.withLock { $0 += 1 } }),
            conversationID: conversationID, childExecution: ChildExecutionHandoff(identity: identity,
                dispatcher: dispatcher, peers: bus.handle(for: identity)))
        let start = Task { try await registry.startBackground(.init(task: "blocked", runID: runID), context: context) }
        for _ in 0..<100 where await !gate.entered { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await gate.entered)
        await registry.cancelBackground(runID: runID)
        await gate.open()
        await #expect(throws: (any Error).self) { _ = try await start.value }
        #expect(adapter.count == 0)
        #expect(finishedBudget.withLock { $0 } == 1)
        #expect(try await store.children(parentRunID: runID).isEmpty)
    }

    @Test("failed new result cannot promote stale result to terminal")
    func failedBackgroundResultDoesNotUseStaleResult() async throws {
        let store = FakeChildRunStore(failAppendKinds: [.result], seedStaleResult: true)
        let provider = TestFixtures.localhostProvider()
        let adapter = OrderedProviderAdapter(log: AsyncLock([]), script: [[
            .textDelta(.init(text: "NEW RESULT")), .completed(.init(stopReason: .endTurn))]])
        let runner = SubagentRunner(provider: provider, model: TestFixtures.testModel(providerID: provider.id),
            adapter: adapter, credentials: ProviderCredentials(), executor: MockExecutor(), childRunStore: store, checkpointStore: store)
        let registry = SubagentRunnerRegistry(), runID = UUID(), conversationID = UUID()
        await registry.register(runner, for: runID)
        await registry.enableBackground(for: runID)
        let identity = ChildExecutionIdentity(parentRunID: runID, rootTaskID: conversationID, delegateCallID: "call")
        let bus = SubagentPeerBus()
        let dispatcher = ChildToolDispatcher(descriptorProvider: { _ in nil }, allDescriptors: { [] },
            dispatch: { call, _ in ToolResult(callID: call.id, status: .ok, outputSummary: "", outputDigest: "") })
        let context = ToolContext(runID: runID, toolCallID: "call", scope: .local, cancellation: CancellationToken(),
            childBudget: ChildBudgetContext(maximumIterations: 3, reserve: { true }, finish: {}),
            conversationID: conversationID, childExecution: ChildExecutionHandoff(identity: identity,
                dispatcher: dispatcher, peers: bus.handle(for: identity)))
        let childID = try await registry.startBackground(.init(task: "result", runID: runID), context: context)
        let children = try await registry.settleBackground(runID: runID, conversationID: conversationID)
        #expect(children.count == 1)
        #expect(children.first?.id == childID)
        #expect(children.first?.state == .interrupted)
        #expect(children.first?.outcome == nil)
    }

    @Test("background child approvals are serialized without pausing the parent or accepting stale cards")
    func backgroundApprovalsDoNotClobberParent() async throws {
        let store = FakeChildRunStore(), provider = TestFixtures.localhostProvider()
        let runID = UUID(), conversationID = UUID()
        let childAdapter = MockAdapter(), parentAdapter = MockAdapter()
        let childCall = try TestFixtures.toolCall(id: "same-child-call", toolName: "test.backgroundWrite", arguments: "{}")
        childAdapter.script = [
            [.toolRequest(childCall)], [.toolRequest(childCall)],
            [.textDelta(.init(text: "child A done")), .completed(.init(stopReason: .endTurn))],
            [.textDelta(.init(text: "child B done")), .completed(.init(stopReason: .endTurn))]
        ]
        parentAdapter.script = [
            [.toolRequest(try TestFixtures.toolCall(id: "a", toolName: "delegate", arguments: #"{"task":"child A","background":true}"#)),
             .toolRequest(try TestFixtures.toolCall(id: "b", toolName: "delegate", arguments: #"{"task":"child B","background":true}"#))],
            [.toolRequest(try TestFixtures.toolCall(id: "independent", toolName: "test.backgroundIndependent", arguments: "{}"))],
            [.textDelta(.init(text: "draft")), .completed(.init(stopReason: .endTurn))],
            [.textDelta(.init(text: "child results incorporated")), .completed(.init(stopReason: .endTurn))]
        ]
        let registry = ToolRunnerRegistry(), runners = SubagentRunnerRegistry()
        let independent = AsyncLock(false), writes = AsyncLock(0), sink = BackgroundApprovalSink()
        registry.register(BackgroundIndependentTool(executed: independent))
        registry.register(BackgroundWriteTool(count: writes))
        registerDelegateTool(registry: registry, runners: runners)
        let executor = CatalogToolExecutor(runners: registry)
        await runners.register(SubagentRunner(provider: provider, model: TestFixtures.testModel(providerID: provider.id),
            adapter: childAdapter, credentials: ProviderCredentials(), executor: executor,
            childRunStore: store, checkpointStore: store), for: runID)
        await runners.enableBackground(for: runID)
        var config = FloeAgentRuntime.Configuration(conversationID: conversationID, provider: provider,
            model: TestFixtures.testModel(providerID: provider.id), allowedToolNames:
                ["delegate", "delegate.wait", "test.backgroundIndependent", "test.backgroundWrite"])
        config.settleBackgroundChildren = { try await runners.settleBackground(runID: runID, conversationID: conversationID) }
        config.markBackgroundChildrenDelivered = { try await runners.markBackgroundDelivered(runID: runID, conversationID: conversationID, childIDs: $0) }
        config.cancelBackgroundChildren = { await runners.cancelBackground(runID: runID) }
        config.markBackgroundChildrenInterrupted = { await runners.markBackgroundInterrupted(runID: runID) }
        config.isBackgroundChild = { try await runners.isBackgroundChild(runID: runID, conversationID: conversationID, childID: $0) }
        let runtime = FloeAgentRuntime(configuration: config, adapter: parentAdapter, policy: BackgroundApprovalPolicy(),
            executor: executor, auditSink: MockAuditSink(), checkpointStore: MockCheckpointStore(), sink: sink, runID: runID)
        let finished = AsyncLock(false)
        let task = Task { defer { finished.withLock { $0 = true } }; try await runtime.start(goal: "work while children execute") }
        for _ in 0..<500 {
            if independent.withLock({ $0 }) && sink.approvals.withLock({ !$0.isEmpty }) && childAdapter.requests.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(independent.withLock { $0 })
        #expect(childAdapter.requests.count >= 2)
        let first = try #require(sink.approvals.withLock { $0.first })
        #expect(first.toolCall.id != childCall.id)
        #expect(writes.withLock { $0 } == 0)
        #expect(await runtime.resolveApproval(.allow(scope: .init(toolName: "test.backgroundWrite", singleUse: true), expiresAt: nil), for: first.toolCall.id))
        for _ in 0..<500 where sink.approvals.withLock({ $0.count }) < 2 { try await Task.sleep(for: .milliseconds(10)) }
        let second = try #require(sink.approvals.withLock { $0.count >= 2 ? $0[1] : nil })
        #expect(second.toolCall.id != first.toolCall.id)
        #expect(!(await runtime.resolveApproval(.allow(scope: .init(toolName: "test.backgroundWrite", singleUse: true), expiresAt: nil), for: first.toolCall.id)))
        #expect(await runtime.resolveApproval(.allow(scope: .init(toolName: "test.backgroundWrite", singleUse: true), expiresAt: nil), for: second.toolCall.id))
        for _ in 0..<500 where !finished.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) }
        if !finished.withLock({ $0 }) { await runtime.cancel() }
        _ = try? await task.value
        #expect(finished.withLock { $0 })
        #expect(writes.withLock { $0 } == 2)
    }

    @Test("stopping a parent with a child awaiting approval releases the gate and preserves recovery")
    func stoppingParentReleasesBackgroundApproval() async throws {
        let store = FakeChildRunStore(), provider = TestFixtures.localhostProvider()
        let runID = UUID(), conversationID = UUID(), sink = BackgroundApprovalSink()
        let parentAdapter = MockAdapter(), childAdapter = MockAdapter()
        childAdapter.script = [[.toolRequest(try TestFixtures.toolCall(id: "child-write", toolName: "test.backgroundWrite", arguments: "{}"))]]
        parentAdapter.script = [
            [.toolRequest(try TestFixtures.toolCall(id: "spawn", toolName: "delegate", arguments: #"{"task":"child","background":true}"#))],
            [.textDelta(.init(text: "working")), .completed(.init(stopReason: .endTurn))]
        ]
        let registry = ToolRunnerRegistry(), runners = SubagentRunnerRegistry(), writes = AsyncLock(0)
        registry.register(BackgroundWriteTool(count: writes))
        registerDelegateTool(registry: registry, runners: runners)
        let executor = CatalogToolExecutor(runners: registry)
        await runners.register(SubagentRunner(provider: provider, model: TestFixtures.testModel(providerID: provider.id),
            adapter: childAdapter, credentials: ProviderCredentials(), executor: executor,
            childRunStore: store, checkpointStore: store), for: runID)
        await runners.enableBackground(for: runID)
        var config = FloeAgentRuntime.Configuration(conversationID: conversationID, provider: provider,
            model: TestFixtures.testModel(providerID: provider.id), allowedToolNames: ["delegate", "test.backgroundWrite"])
        config.settleBackgroundChildren = { try await runners.settleBackground(runID: runID, conversationID: conversationID) }
        config.markBackgroundChildrenDelivered = { try await runners.markBackgroundDelivered(runID: runID, conversationID: conversationID, childIDs: $0) }
        config.cancelBackgroundChildren = { await runners.cancelBackground(runID: runID) }
        config.markBackgroundChildrenInterrupted = { await runners.markBackgroundInterrupted(runID: runID) }
        config.isBackgroundChild = { try await runners.isBackgroundChild(runID: runID, conversationID: conversationID, childID: $0) }
        let runtime = FloeAgentRuntime(configuration: config, adapter: parentAdapter, policy: BackgroundApprovalPolicy(),
            executor: executor, auditSink: MockAuditSink(), checkpointStore: MockCheckpointStore(), sink: sink, runID: runID)
        let run = Task { try await runtime.start(goal: "child work") }
        for _ in 0..<500 where sink.approvals.withLock({ $0.isEmpty }) { try await Task.sleep(for: .milliseconds(10)) }
        guard !sink.approvals.withLock({ $0.isEmpty }) else {
            Issue.record("Child did not request approval")
            run.cancel()
            return
        }
        let cancelled = AsyncLock(false)
        let stop = Task { await runtime.cancel(); cancelled.withLock { $0 = true } }
        for _ in 0..<500 where !cancelled.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) }
        guard cancelled.withLock({ $0 }) else {
            Issue.record("Stopping the parent deadlocked on child approval")
            stop.cancel(); run.cancel()
            return
        }
        await stop.value
        _ = try? await run.value
        #expect(writes.withLock { $0 } == 0)
        let child = try #require(try await store.children(parentRunID: runID).first)
        #expect(child.state == .interrupted)
        #expect(try await store.checkpoint(childRunID: child.id) != nil)
    }

    @Test("background start refuses before provider execution if initial checkpoint fails")
    func initialBackgroundCheckpointFailure() async throws {
        let store = FakeChildRunStore(failCheckpoint: true), provider = TestFixtures.localhostProvider()
        let adapter = GatedChildProvider(), runner = SubagentRunner(provider: provider,
            model: TestFixtures.testModel(providerID: provider.id), adapter: adapter,
            credentials: ProviderCredentials(), executor: MockExecutor(), childRunStore: store, checkpointStore: store)
        let registry = SubagentRunnerRegistry(), runID = UUID(), conversationID = UUID(), bus = SubagentPeerBus()
        await registry.register(runner, for: runID)
        await registry.enableBackground(for: runID)
        let identity = ChildExecutionIdentity(parentRunID: runID, rootTaskID: conversationID, delegateCallID: "initial")
        let dispatcher = ChildToolDispatcher(descriptorProvider: { _ in nil }, allDescriptors: { [] },
            dispatch: { call, _ in ToolResult(callID: call.id, status: .ok, outputSummary: "", outputDigest: "") })
        let budgetFinished = AsyncLock(0)
        let context = ToolContext(runID: runID, toolCallID: "initial", cancellation: CancellationToken(),
            childBudget: ChildBudgetContext(maximumIterations: 3, reserve: { true }, finish: { budgetFinished.withLock { $0 += 1 } }),
            conversationID: conversationID, childExecution: ChildExecutionHandoff(identity: identity,
                dispatcher: dispatcher, peers: bus.handle(for: identity)))
        await #expect(throws: (any Error).self) { _ = try await registry.startBackground(.init(task: "do not start", runID: runID), context: context) }
        #expect(adapter.count == 0)
        #expect(budgetFinished.withLock { $0 } == 1)
        let child = try #require(try await store.child(id: identity.childID))
        #expect(child.state == .interrupted)
        #expect(try await store.checkpoint(childRunID: child.id) == nil)
        #expect(try await store.backgroundOwner(childID: child.id)?.parentRunID == runID)
        let pending = try await registry.settleBackground(runID: runID, conversationID: conversationID)
        #expect(pending.first?.outcome?.status == .toolError)
    }

    @Test("background child with the same call ID cannot retire a parent's approval card")
    func backgroundChildCannotRetireParentApproval() async throws {
        let store = FakeChildRunStore(), provider = TestFixtures.localhostProvider(), runID = UUID(), conversationID = UUID()
        let childAdapter = GatedChildProvider(), parentAdapter = MockAdapter(), sink = BackgroundApprovalSink()
        parentAdapter.script = [
            [.toolRequest(try TestFixtures.toolCall(id: "spawn", toolName: "delegate", arguments: #"{"task":"child read","background":true}"#))],
            [.toolRequest(try TestFixtures.toolCall(id: "shared-id", toolName: "test.backgroundWrite", arguments: "{}"))],
            [.textDelta(.init(text: "parent and child done")), .completed(.init(stopReason: .endTurn))],
            [.textDelta(.init(text: "results received")), .completed(.init(stopReason: .endTurn))]
        ]
        let registry = ToolRunnerRegistry(), runners = SubagentRunnerRegistry()
        let read = AsyncLock(false), writes = AsyncLock(0)
        registry.register(BackgroundIndependentTool(executed: read))
        registry.register(BackgroundWriteTool(count: writes))
        registerDelegateTool(registry: registry, runners: runners)
        let executor = CatalogToolExecutor(runners: registry)
        await runners.register(SubagentRunner(provider: provider, model: TestFixtures.testModel(providerID: provider.id),
            adapter: childAdapter, credentials: ProviderCredentials(), executor: executor,
            childRunStore: store, checkpointStore: store), for: runID)
        await runners.enableBackground(for: runID)
        var config = FloeAgentRuntime.Configuration(conversationID: conversationID, provider: provider,
            model: TestFixtures.testModel(providerID: provider.id), allowedToolNames:
                ["delegate", "test.backgroundIndependent", "test.backgroundWrite"])
        config.settleBackgroundChildren = { try await runners.settleBackground(runID: runID, conversationID: conversationID) }
        config.markBackgroundChildrenDelivered = { try await runners.markBackgroundDelivered(runID: runID, conversationID: conversationID, childIDs: $0) }
        config.cancelBackgroundChildren = { await runners.cancelBackground(runID: runID) }
        config.markBackgroundChildrenInterrupted = { await runners.markBackgroundInterrupted(runID: runID) }
        config.isBackgroundChild = { try await runners.isBackgroundChild(runID: runID, conversationID: conversationID, childID: $0) }
        let runtime = FloeAgentRuntime(configuration: config, adapter: parentAdapter, policy: BackgroundApprovalPolicy(),
            executor: executor, auditSink: MockAuditSink(), checkpointStore: MockCheckpointStore(), sink: sink, runID: runID)
        let task = Task { try await runtime.start(goal: "wait for a human while the child reads") }
        for _ in 0..<500 {
            if childAdapter.count > 0, await runtime.state.name == "waitingApproval" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await runtime.state.name == "waitingApproval")
        let childRead = try TestFixtures.toolCall(id: "shared-id", toolName: "test.backgroundIndependent", arguments: "{}")
        childAdapter.release([.toolRequest(childRead)])
        for _ in 0..<500 where !read.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(read.withLock { $0 })
        #expect(!sink.receipts.withLock { $0.contains("shared-id") })
        #expect(await runtime.state.name == "waitingApproval")
        #expect(await runtime.resolveApproval(.allow(scope: .init(toolName: "test.backgroundWrite", singleUse: true), expiresAt: nil), for: "shared-id"))
        // Close the child's subsequent model turn, if requested.
        for _ in 0..<100 where childAdapter.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        childAdapter.release()
        _ = try? await task.value
        #expect(writes.withLock { $0 } == 1)
    }

    @Test("unrelated unreadable child history does not block a new task")
    func unrelatedChildHistoryDoesNotBlockCompletion() async throws {
        let store = FakeChildRunStore(), conversationID = UUID(), oldParent = UUID(), newParent = UUID(), oldChild = UUID()
        try await store.register(ChildRunRecord(id: oldChild, parentRunID: oldParent, rootRunID: conversationID,
            conversationID: conversationID, childIndex: 1, kind: "explore", taskSummary: "old foreground",
            state: .completed, delegateCallID: "old"))
        await store.poisonEntries(for: oldChild)
        let provider = TestFixtures.localhostProvider(), adapter = MockAdapter()
        let runner = SubagentRunner(provider: provider, model: TestFixtures.testModel(providerID: provider.id),
            adapter: adapter, credentials: ProviderCredentials(), executor: MockExecutor(), childRunStore: store, checkpointStore: store)
        let registry = SubagentRunnerRegistry()
        await registry.register(runner, for: newParent)
        #expect(try await registry.settleBackground(runID: newParent, conversationID: conversationID).isEmpty)
    }

    @Test("parent continues and reports a rejected background start after initial checkpoint failure")
    func parentCanReportBackgroundStartFailure() async throws {
        let store = FakeChildRunStore(failCheckpoint: true), provider = TestFixtures.localhostProvider()
        let runID = UUID(), conversationID = UUID(), parentAdapter = MockAdapter(), childAdapter = GatedChildProvider()
        parentAdapter.script = [
            [.toolRequest(try TestFixtures.toolCall(id: "spawn-fails", toolName: "delegate", arguments: #"{"task":"child","background":true}"#))],
            [.textDelta(.init(text: "The child could not start because its recovery point could not be saved.")), .completed(.init(stopReason: .endTurn))],
            [.textDelta(.init(text: "The background child did not run; the startup failure is retained.")), .completed(.init(stopReason: .endTurn))]
        ]
        let registry = ToolRunnerRegistry(), runners = SubagentRunnerRegistry()
        registerDelegateTool(registry: registry, runners: runners)
        let executor = CatalogToolExecutor(runners: registry)
        await runners.register(SubagentRunner(provider: provider, model: TestFixtures.testModel(providerID: provider.id),
            adapter: childAdapter, credentials: ProviderCredentials(), executor: executor,
            childRunStore: store, checkpointStore: store), for: runID)
        await runners.enableBackground(for: runID)
        var config = FloeAgentRuntime.Configuration(conversationID: conversationID, provider: provider,
            model: TestFixtures.testModel(providerID: provider.id), allowedToolNames: ["delegate"])
        config.settleBackgroundChildren = { try await runners.settleBackground(runID: runID, conversationID: conversationID) }
        config.markBackgroundChildrenDelivered = { try await runners.markBackgroundDelivered(runID: runID, conversationID: conversationID, childIDs: $0) }
        config.cancelBackgroundChildren = { await runners.cancelBackground(runID: runID) }
        config.markBackgroundChildrenInterrupted = { await runners.markBackgroundInterrupted(runID: runID) }
        config.isBackgroundChild = { try await runners.isBackgroundChild(runID: runID, conversationID: conversationID, childID: $0) }
        let runtime = FloeAgentRuntime(configuration: config, adapter: parentAdapter,
            policy: FullControlPolicy(grant: .init(hostID: UUID(), expiresAt: nil)), executor: executor,
            auditSink: MockAuditSink(), checkpointStore: MockCheckpointStore(), runID: runID)
        try await runtime.start(goal: "delegate a child")
        #expect(TaskClosureGate.acknowledgesUnfinished("The background child did not run; the startup failure is retained."))
        #expect(await runtime.state.name == "completed")
        #expect(childAdapter.count == 0)
        #expect(try await runners.settleBackground(runID: runID, conversationID: conversationID).isEmpty)
        let feedback = parentAdapter.requests.flatMap(\.toolResults)
        #expect(feedback.contains { $0.callID == "spawn-fails" && $0.output.contains("status=failed") })
        #expect(parentAdapter.requests.contains { request in
            request.messages.contains { $0.role == "system" && $0.content.contains("The background child did not start. No provider or tool ran") }
        })
        let children = try await store.children(parentRunID: runID)
        #expect(children.count == 1)
        #expect(children.first?.state == .interrupted)
    }

    @Test("crash before child ready persists a replayable failure without re-execution")
    func crashedBeforeReadyReplaysFailure() async throws {
        let store = FakeChildRunStore(), provider = TestFixtures.localhostProvider()
        let parent = UUID(), conversation = UUID(), childID = UUID()
        try await store.register(ChildRunRecord(id: childID, parentRunID: parent, rootRunID: conversation,
            conversationID: conversation, childIndex: 1, kind: "explore", taskSummary: "not started",
            state: .interrupted, delegateCallID: "crashed-spawn"))
        try await store.assignBackgroundOwner(childID: childID, parentRunID: parent, conversationID: conversation,
            resumeOwner: nil, payloadJSON: #"{"backgroundDelegate":true}"#)
        let adapter = GatedChildProvider(), runner = SubagentRunner(provider: provider,
            model: TestFixtures.testModel(providerID: provider.id), adapter: adapter,
            credentials: ProviderCredentials(), executor: MockExecutor(), childRunStore: store, checkpointStore: store)
        let first = SubagentRunnerRegistry()
        await first.register(runner, for: parent)
        let pending = try await first.settleBackground(runID: parent, conversationID: conversation)
        #expect(pending.count == 1)
        #expect(pending.first?.outcome?.status == .toolError)
        #expect(pending.first?.outcome?.findings.contains("did not start") == true)
        #expect(adapter.count == 0)
        // A second crash before the parent's checkpoint leaves the failure
        // indexed; the next activation sees the same child once again.
        let restarted = SubagentRunnerRegistry()
        await restarted.register(runner, for: parent)
        let replayed = try await restarted.settleBackground(runID: parent, conversationID: conversation)
        #expect(replayed.map(\.id) == [childID])
        try await restarted.markBackgroundDelivered(runID: parent, conversationID: conversation, childIDs: [childID])
        #expect(try await restarted.settleBackground(runID: parent, conversationID: conversation).isEmpty)
        #expect(adapter.count == 0)
    }

    @Test("a ready child with a missing checkpoint remains interrupted rather than being erased")
    func readyChildCannotBeClassifiedUnstarted() async throws {
        let store = FakeChildRunStore(), provider = TestFixtures.localhostProvider()
        let parent = UUID(), conversation = UUID(), childID = UUID()
        try await store.register(ChildRunRecord(id: childID, parentRunID: parent, rootRunID: conversation,
            conversationID: conversation, childIndex: 1, kind: "explore", taskSummary: "possibly executed",
            state: .interrupted, delegateCallID: "ready-spawn"))
        try await store.assignBackgroundOwner(childID: childID, parentRunID: parent, conversationID: conversation,
            resumeOwner: nil, payloadJSON: #"{"backgroundDelegate":true}"#)
        try await store.appendEntry(id: childID, kind: .state, payloadJSON: #"{"backgroundStartReady":true}"#)
        let runner = SubagentRunner(provider: provider, model: TestFixtures.testModel(providerID: provider.id),
            adapter: GatedChildProvider(), credentials: ProviderCredentials(), executor: MockExecutor(), childRunStore: store, checkpointStore: store)
        let registry = SubagentRunnerRegistry()
        await registry.register(runner, for: parent)
        let pending = try await registry.settleBackground(runID: parent, conversationID: conversation)
        #expect(pending.count == 1 && pending[0].state == .interrupted && pending[0].outcome == nil)
        #expect(try await store.backgroundOwner(childID: childID)?.parentRunID == parent)
    }

}
