import Foundation
import Testing
@testable import FloeAgentRuntime
@testable import FloeModels
@testable import FloeProviders
@testable import FloeCore
@testable import FloeSecurity
import FloeTestSupport

@Suite("FloeAgentRuntime.HarnessInvariants")
struct HarnessInvariantTests {
    /// Bounded poll for a controlled gate signal: fails the test after 15
    /// seconds instead of holding the shared native window on a regression.
    private static func waitUntil(
        _ label: String,
        timeout: Duration = .seconds(15),
        condition: @Sendable () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for \(label)")
        throw TestTimeout.waiting(label)
    }

    private enum TestTimeout: Error { case waiting(String) }

    @Test("Provider dispatch requires a complete committed one-to-one tool pair")
    func providerBoundaryRequiresCommittedPair() throws {
        let call = try TestFixtures.toolCall(id: "paired-call")
        let result = ToolResult(
            callID: call.id,
            status: .ok,
            outputSummary: "done",
            outputDigest: "digest"
        )

        let missingLifecycle = HarnessInvariantRegistry.validateProviderBoundary(
            calls: [call],
            results: [result],
            lifecycleByCallID: [:]
        )
        #expect(missingLifecycle.contains { $0.name == "provider.lifecycleMissing" })

        let valid = HarnessInvariantRegistry.validateProviderBoundary(
            calls: [call],
            results: [result],
            lifecycleByCallID: [call.id: AgentToolLifecycleEntry(
                callID: call.id,
                toolName: call.toolName,
                phase: .resultCommitted
            )]
        )
        #expect(valid.isEmpty)
    }

    @Test("Provider dispatch rejects malformed, duplicated, or overlapping replayed pairs")
    func providerBoundaryRejectsInvalidReplayedPairs() throws {
        let settledCall = try TestFixtures.toolCall(id: "settled")
        let settledResult = ToolResult(
            callID: settledCall.id,
            status: .ok,
            outputSummary: "done",
            outputDigest: "digest"
        )
        let pendingCall = try TestFixtures.toolCall(id: "pending")
        let pendingResult = ToolResult(
            callID: pendingCall.id,
            status: .ok,
            outputSummary: "done",
            outputDigest: "digest"
        )
        let lifecycle: [String: AgentToolLifecycleEntry] = [
            pendingCall.id: AgentToolLifecycleEntry(
                callID: pendingCall.id,
                toolName: pendingCall.toolName,
                phase: .resultCommitted
            )
        ]

        let mismatched = ReplayedToolPair(
            call: settledCall,
            result: ToolResult(callID: "other", status: .ok, outputSummary: "done", outputDigest: "d")
        )
        #expect(HarnessInvariantRegistry.validateProviderBoundary(
            calls: [pendingCall],
            results: [pendingResult],
            lifecycleByCallID: lifecycle,
            replayedPairs: [mismatched]
        ).contains { $0.name == "provider.replayPairing" })

        let duplicate = ReplayedToolPair(call: settledCall, result: settledResult)
        #expect(HarnessInvariantRegistry.validateProviderBoundary(
            calls: [pendingCall],
            results: [pendingResult],
            lifecycleByCallID: lifecycle,
            replayedPairs: [duplicate, duplicate]
        ).contains { $0.name == "provider.replayDuplicate" })

        let overlapping = ReplayedToolPair(call: pendingCall, result: pendingResult)
        #expect(HarnessInvariantRegistry.validateProviderBoundary(
            calls: [pendingCall],
            results: [pendingResult],
            lifecycleByCallID: lifecycle,
            replayedPairs: [overlapping]
        ).contains { $0.name == "provider.replayOverlapsPending" })

        // A complete replayed pair disjoint from the pending batch passes.
        #expect(HarnessInvariantRegistry.validateProviderBoundary(
            calls: [pendingCall],
            results: [pendingResult],
            lifecycleByCallID: lifecycle,
            replayedPairs: [duplicate]
        ).isEmpty)
    }

    @Test("Checkpoint rejects a result that is not lifecycle committed")
    func checkpointRejectsUncommittedResult() throws {
        let call = try TestFixtures.toolCall(id: "uncommitted-result")
        let checkpoint = AgentCheckpoint(
            runID: UUID(),
            conversationID: UUID(),
            state: .preparing(.init(goal: "test")),
            messages: [ConversationMessage(role: "user", content: "test")],
            pendingToolCalls: [call],
            pendingToolResults: [ToolResult(
                callID: call.id,
                status: .ok,
                outputSummary: "done",
                outputDigest: "digest"
            )],
            toolLifecycleEntries: [AgentToolLifecycleEntry(
                callID: call.id,
                toolName: call.toolName,
                phase: .dispatched
            )]
        )

        let violations = HarnessInvariantRegistry.validateCheckpoint(checkpoint)
        #expect(violations.contains { $0.name == "checkpoint.uncommittedResult" })
    }

    @Test("Provider dispatch preserves assistant tool-call order")
    func providerBoundaryRejectsReorderedResults() throws {
        let first = try TestFixtures.toolCall(id: "first")
        let second = try TestFixtures.toolCall(id: "second")
        let results = [second, first].map {
            ToolResult(
                callID: $0.id,
                status: .ok,
                outputSummary: "done",
                outputDigest: "digest"
            )
        }
        let lifecycle = Dictionary(uniqueKeysWithValues: [first, second].map {
            ($0.id, AgentToolLifecycleEntry(
                callID: $0.id,
                toolName: $0.toolName,
                phase: .resultCommitted
            ))
        })

        let violations = HarnessInvariantRegistry.validateProviderBoundary(
            calls: [first, second],
            results: results,
            lifecycleByCallID: lifecycle
        )
        #expect(violations.contains { $0.name == "provider.callResultPairing" })
    }

    @Test("Checkpoint rejects duplicate and orphan open lifecycle entries")
    func checkpointRejectsInvalidLifecycleSet() throws {
        let call = try TestFixtures.toolCall(id: "pending")
        let duplicate = AgentToolLifecycleEntry(
            callID: call.id,
            toolName: call.toolName,
            phase: .recorded
        )
        let checkpoint = AgentCheckpoint(
            runID: UUID(),
            conversationID: UUID(),
            state: .preparing(.init(goal: "test")),
            messages: [ConversationMessage(role: "user", content: "test")],
            pendingToolCalls: [call],
            toolLifecycleEntries: [
                duplicate,
                duplicate,
                AgentToolLifecycleEntry(
                    callID: "orphan",
                    toolName: call.toolName,
                    phase: .dispatched
                )
            ]
        )

        let violations = HarnessInvariantRegistry.validateCheckpoint(checkpoint)
        #expect(violations.contains { $0.name == "checkpoint.duplicateLifecycleID" })
        #expect(violations.contains { $0.name == "checkpoint.orphanOpenLifecycle" })
    }

    @Test("Checkpoint rejects an incomplete provider dispatch envelope")
    func checkpointRejectsInvalidDispatchEnvelope() {
        let checkpoint = AgentCheckpoint(
            runID: UUID(),
            conversationID: UUID(),
            state: .preparing(.init(goal: "test")),
            messages: [ConversationMessage(role: "user", content: "test")],
            providerDispatchEnvelope: ProviderDispatchEnvelope(
                providerID: UUID(),
                providerKind: "openAICompatible",
                wireProtocol: "responsesAPI",
                modelID: UUID(),
                remoteModelID: "model",
                conversationMode: "agent",
                messagesDigest: "",
                toolSchemasDigest: "schema",
                pendingCallIDs: ["first"],
                pendingResultCallIDs: ["second"]
            )
        )

        let violations = HarnessInvariantRegistry.validateCheckpoint(checkpoint)
        #expect(violations.contains { $0.name == "checkpoint.dispatchDigestMissing" })
        #expect(violations.contains { $0.name == "checkpoint.dispatchPairingMismatch" })
    }

    @Test("Checkpoint rejects a mixed-generation call/result snapshot")
    func checkpointRejectsMixedGenerationSnapshot() throws {
        let first = try TestFixtures.toolCall(id: "first-generation")
        let second = try TestFixtures.toolCall(id: "second-generation")
        // The exact interleaving the reentrancy fix prevents: calls captured
        // before a batch settle, results captured after the next request.
        let checkpoint = AgentCheckpoint(
            runID: UUID(),
            conversationID: UUID(),
            state: .preparing(.init(goal: "test")),
            messages: [ConversationMessage(role: "user", content: "test")],
            pendingToolCalls: [first],
            pendingToolResults: [ToolResult(
                callID: second.id,
                status: .ok,
                outputSummary: "done",
                outputDigest: "digest"
            )],
            toolLifecycleEntries: [
                AgentToolLifecycleEntry(callID: first.id, toolName: first.toolName, phase: .resultCommitted),
                AgentToolLifecycleEntry(callID: second.id, toolName: second.toolName, phase: .resultCommitted)
            ]
        )

        let violations = HarnessInvariantRegistry.validateCheckpoint(checkpoint)
        #expect(violations.contains { $0.name == "checkpoint.orphanResult" })
        #expect(violations.contains { $0.name == "checkpoint.missingCommittedResult" })
    }

    @Test("A failed checkpoint write carries its capture generation and redacted identity")
    func checkpointWriteErrorCarriesGenerationAndIdentity() async throws {
        let store = FailingCheckpointStore()
        let provider = TestFixtures.localhostProvider()
        let subject = FloeAgentRuntime(
            configuration: .init(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                providerRetryBaseDelay: 0,
                providerRetryMaxDelay: 0
            ),
            adapter: MockAdapter(),
            policy: AutomaticApprovalPolicy(backend: RecordingApprovalBackend()),
            executor: MockExecutor(),
            checkpointStore: store,
            sink: MockSink(),
            runID: UUID()
        )

        do {
            _ = try await subject.persistRecoveryPoint()
            Issue.record("Expected the checkpoint write to fail")
        } catch let error as CheckpointWriteError {
            #expect(error.generation == 1)
            #expect(error.errorIdentity.contains("FloeAgentRuntimeTests.Checkpoint"))
        }
        // The next capture gets a strictly newer generation.
        do {
            _ = try await subject.persistRecoveryPoint()
            Issue.record("Expected the second checkpoint write to fail")
        } catch let error as CheckpointWriteError {
            #expect(error.generation == 2)
        }
    }

    @Test("A recovery snapshot stays consistent when a tool batch settles mid-save")
    func recoverySnapshotConsistentWhenBatchSettlesMidSave() async throws {
        let run = UUID()
        let checkpointStore = MockCheckpointStore()
        let executor = MockExecutor()
        let streamGate = AsyncGate()
        let executorGate = AsyncGate()
        let questionRecovery = SelectiveQuestionRecovery()
        let sink = MockSink()
        let adapter = HookedAdapter()
        let first = try TestFixtures.toolCall(id: "first-call", toolName: "workspace.readFile",
                                              arguments: #"{"path":"a.txt"}"#)
        let second = try TestFixtures.toolCall(id: "second-call", toolName: "workspace.writeFile",
                                               arguments: #"{"path":"b.txt","content":"x"}"#)
        executor.descriptors[first.toolName] = .init(name: first.toolName, riskLabels: [], isSideEffecting: false)
        executor.descriptors[second.toolName] = .init(name: second.toolName, riskLabels: [], isSideEffecting: true)
        adapter.script = [
            [.toolRequest(first), .completed(.init(stopReason: .toolUse))],
            [.textDelta(.init(text: "继续。")), .toolRequest(second), .completed(.init(stopReason: .toolUse))],
            [.textDelta(.init(text: "完成。")), .completed(.init(stopReason: .endTurn))]
        ]
        // Park the second request's stream right before the second tool call
        // (the run is mid-stream with the first batch already settled), and
        // park the second call's execution AFTER it crossed its own
        // pre-dispatch checkpoint.
        adapter.streamHook = { requestIndex, eventIndex in
            if requestIndex == 1 && eventIndex == 1 { await streamGate.wait() }
        }
        executor.executionGate = {
            if await executor.executedCalls.count >= 1 { await executorGate.wait() }
        }
        let provider = TestFixtures.localhostProvider()
        let subject = FloeAgentRuntime(
            configuration: .init(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                providerRetryBaseDelay: 0,
                providerRetryMaxDelay: 0,
                userQuestionRecovery: questionRecovery
            ),
            adapter: adapter,
            policy: AutomaticApprovalPolicy(backend: RecordingApprovalBackend()),
            executor: executor,
            checkpointStore: checkpointStore,
            sink: sink,
            runID: run
        )

        async let runResult: () = try await subject.start(goal: "读取并写入文件")
        // Wait until the run is parked mid-stream with the first batch
        // settled (its dispatch checkpoint already saved, so the write gate
        // is free).
        try await Self.waitUntil("stream parked") { await streamGate.isParked }
        // Let the second call through its own pre-dispatch checkpoint first;
        // it then parks INSIDE the executor.
        streamGate.open()
        try await Self.waitUntil("second call parked in executor") { await executorGate.isParked }
        // Only now trigger the external snapshot: its capture is a
        // consistent pre-settle view (pending call, no result), and it holds
        // the serialized write gate while parked.
        questionRecovery.parkNextCall()
        async let externalSnapshot: RecoveryPointSnapshot = try await subject.persistRecoveryPoint()
        try await Self.waitUntil("external snapshot parked mid-save") { await questionRecovery.isParked }
        // Let the second call settle. The settle loop's append is the
        // immediate synchronous step after its classification callback
        // returns, so the durable result exists before any later write can
        // be captured; the settlement checkpoint itself queues behind the
        // external snapshot on the serialized write gate.
        executorGate.open()
        try await Self.waitUntil("second call settled") { await sink.toolOutcomeClassifications.count >= 2 }
        // Release the external snapshot: it saves its pre-settle capture,
        // then the queued settlement and dispatch checkpoints save the newer
        // state in capture order.
        questionRecovery.open()

        _ = try await runResult
        let snapshot = try await externalSnapshot
        #expect(snapshot.persisted)
        #expect(snapshot.pendingCallCount == 1)
        #expect(snapshot.pendingResultCount == 0)
        #expect(await subject.state.name == "completed")
        // Every persisted snapshot — including the one captured mid-settle —
        // is a consistent point-in-time view, and the store never regresses:
        // the newest state is the last one written.
        for checkpoint in checkpointStore.saved {
            #expect(HarnessInvariantRegistry.validateCheckpoint(checkpoint).isEmpty)
        }
        let latest = try #require(checkpointStore.saved.last)
        #expect(latest.pendingToolCalls.map(\.id) == ["second-call"])
        #expect(latest.pendingToolResults.map(\.callID) == ["second-call"])
    }

    @Test("An older blocked recovery write never overwrites a newer snapshot")
    func olderBlockedRecoveryWriteNeverOverwritesNewerSnapshot() async throws {
        let run = UUID()
        let checkpointStore = MockCheckpointStore()
        let executor = MockExecutor()
        let executorGate = AsyncGate()
        let questionRecovery = SelectiveQuestionRecovery()
        let sink = MockSink()
        let adapter = MockAdapter()
        let first = try TestFixtures.toolCall(id: "first-call", toolName: "workspace.writeFile",
                                              arguments: #"{"path":"a.txt","content":"x"}"#)
        executor.descriptors[first.toolName] = .init(name: first.toolName, riskLabels: [], isSideEffecting: true)
        adapter.script = [
            [.toolRequest(first), .completed(.init(stopReason: .toolUse))],
            [.textDelta(.init(text: "完成。")), .completed(.init(stopReason: .endTurn))]
        ]
        executor.executionGate = { await executorGate.wait() }
        let provider = TestFixtures.localhostProvider()
        let subject = FloeAgentRuntime(
            configuration: .init(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                providerRetryBaseDelay: 0,
                providerRetryMaxDelay: 0,
                userQuestionRecovery: questionRecovery
            ),
            adapter: adapter,
            policy: AutomaticApprovalPolicy(backend: RecordingApprovalBackend()),
            executor: executor,
            checkpointStore: checkpointStore,
            sink: sink,
            runID: run
        )

        async let runResult: () = try await subject.start(goal: "写入文件")
        // The only tool call parks inside the executor AFTER crossing its
        // own pre-dispatch checkpoint; the run is held mid-flight with
        // exactly one pending call.
        try await Self.waitUntil("call parked in executor") { await executorGate.isParked }
        // The older write blocks mid-save (holding the serialized write
        // gate) with its pre-settle capture.
        questionRecovery.parkNextCall()
        async let olderSnapshot: RecoveryPointSnapshot = try await subject.persistRecoveryPoint()
        try await Self.waitUntil("older write parked mid-save") { await questionRecovery.isParked }
        // Let the tool settle while the older write is still blocked: the
        // settlement checkpoint queues behind it on the serialized gate.
        executorGate.open()
        try await Self.waitUntil("call settled") { await sink.toolOutcomeClassifications.count >= 1 }
        // Release the older write LAST: without serialization its pre-settle
        // save would land after the settlement checkpoint and regress the
        // store; with serialization it saves first and the newer state wins.
        questionRecovery.open()
        _ = try await runResult
        let older = try await olderSnapshot
        #expect(older.persisted)
        #expect(older.pendingCallCount == 1)
        #expect(older.pendingResultCount == 0)
        #expect(await subject.state.name == "completed")
        // Read-back of the latest store: the last write carries the SETTLED
        // result; the older pre-settle write never regressed it.
        let readBack = try await checkpointStore.load(runID: run)
        let latest = try #require(readBack)
        #expect(latest.pendingToolResults.map(\.callID) == ["first-call"])
        for checkpoint in checkpointStore.saved {
            #expect(HarnessInvariantRegistry.validateCheckpoint(checkpoint).isEmpty)
        }
    }
}

/// Async gate that parks `wait()` calls while closed and releases them on
/// `open()` (staying open). `isParked` is the REAL park signal (a call is
/// currently suspended inside); `parkedCount` is only a total of calls that
/// reached the gate, including pass-throughs.
final class AsyncGate: @unchecked Sendable {
    private let state = AsyncLock<(open: Bool, parkedCount: Int, waiters: [CheckedContinuation<Void, Never>])>((false, 0, []))
    var parkedCount: Int { state.withLock { $0.parkedCount } }
    var isParked: Bool { state.withLock { !$0.waiters.isEmpty } }
    func wait() async {
        await withCheckedContinuation { continuation in
            let park = state.withLock { st -> Bool in
                st.parkedCount += 1
                if st.open { return false }
                st.waiters.append(continuation)
                return true
            }
            if !park { continuation.resume() }
        }
    }
    func open() {
        let waiters = state.withLock { st -> [CheckedContinuation<Void, Never>] in
            st.open = true
            let waiters = st.waiters
            st.waiters = []
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

/// Adapter whose stream can be parked at chosen (request, event) boundaries.
final class HookedAdapter: ProviderAdapter, @unchecked Sendable {
    let protocolKind: ModelProtocol = .openAIResponses
    private struct Storage {
        var script: [[AgentEvent]] = []
        var callCount = 0
        var requests: [ProviderStreamRequest] = []
    }
    private let storage = AsyncLock(Storage())
    var script: [[AgentEvent]] {
        get { storage.withLock { $0.script } }
        set { storage.withLock { $0.script = newValue } }
    }
    var requests: [ProviderStreamRequest] { storage.withLock { $0.requests } }
    var streamHook: (@Sendable (Int, Int) async -> Void)?

    func stream(
        request: ProviderStreamRequest,
        credentials: ProviderCredentials
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        let (events, index, hook) = storage.withLock { state -> ([AgentEvent], Int, (@Sendable (Int, Int) async -> Void)?) in
            state.requests.append(request)
            let events = state.callCount < state.script.count ? state.script[state.callCount] : []
            let index = state.callCount
            state.callCount += 1
            return (events, index, streamHook)
        }
        return AsyncThrowingStream { continuation in
            Task {
                for (eventIndex, event) in events.enumerated() {
                    await hook?(index, eventIndex)
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }

    func listModels(provider: ProviderProfile, credentials: ProviderCredentials) async throws -> [ModelProfile] { [] }
}

/// Question-recovery double whose `waitingQuestionRequestIDs` can be parked
/// for the next call (or a chosen call index) while a snapshot is mid-save.
final class SelectiveQuestionRecovery: UserQuestionRuntimeRecovery, @unchecked Sendable {
    private let state = AsyncLock<(parkNext: Bool, parkedCount: Int, waiters: [CheckedContinuation<Void, Never>])>((false, 0, []))
    var parkedCount: Int { state.withLock { $0.parkedCount } }
    /// REAL park signal: a call is currently suspended inside the gate.
    var isParked: Bool { state.withLock { !$0.waiters.isEmpty } }
    func parkNextCall() { state.withLock { $0.parkNext = true } }
    func open() {
        let waiters = state.withLock { st -> [CheckedContinuation<Void, Never>] in
            st.parkNext = false
            let waiters = st.waiters
            st.waiters = []
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func waitingQuestionRequestIDs(runID: UUID) async -> [String] {
        await withCheckedContinuation { continuation in
            let park = state.withLock { st -> Bool in
                st.parkedCount += 1
                if st.parkNext {
                    st.parkNext = false
                    st.waiters.append(continuation)
                    return true
                }
                return false
            }
            if !park { continuation.resume() }
        }
        return []
    }

    func recoverInterruptedQuestion(
        runID: UUID,
        conversationID: UUID,
        call: ToolCall
    ) async -> ToolResult? { nil }

    func cancelPendingQuestions(runID: UUID) async {}
}
