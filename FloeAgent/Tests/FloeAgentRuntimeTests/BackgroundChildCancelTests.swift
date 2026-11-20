// FloeAgentRuntimeTests — the agreed parallel delegation lifecycle:
// cancel ONE background subagent from its detail view, and stop a parent
// run without touching unrelated tasks' children.
//
// A deliberate single-child cancel must settle durably as terminal
// `.cancelled` WITH a real outcome, so the parent run finishes by reconciling
// the actual result instead of failing on a resumable `.interrupted` child.
// A parent stop keeps its resumable `.interrupted` semantics and must leave
// every other run's children running.

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

/// In-memory child store with background ownership, mirroring the durable
/// SQL store's contract used by the production registry.
private actor CancelTestChildStore: ChildRunStoring, ChildRunCheckpointStoring {
    private var records: [UUID: ChildRunRecord] = [:]
    private var entries: [UUID: [ChildRunEntry]] = [:]
    private var backgroundOwners: [UUID: BackgroundChildOwner] = [:]

    func register(_ record: ChildRunRecord) async throws -> ChildRunRecord {
        records[record.id] = record
        return record
    }

    func transition(id: UUID, state: ChildRunState, iterationCount: Int?, endedAt: Date?) async throws {
        guard var record = records[id] else { return }
        record.state = state
        if let iterationCount { record.iterationCount = iterationCount }
        records[id] = record
    }

    func appendEntry(id: UUID, kind: ChildRunEntryKind, payloadJSON: String) async throws {
        entries[id, default: []].append(ChildRunEntry(
            childRunID: id,
            sequence: (entries[id]?.count ?? 0) + 1,
            kind: kind,
            payloadJSON: payloadJSON))
    }

    func finish(id: UUID, state: ChildRunState, iterationCount: Int, resultSummary: String?,
                errorText: String?, digest: String?) async throws {
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
    func assignBackgroundOwner(childID: UUID, parentRunID: UUID, conversationID: UUID,
                               resumeOwner: UUID?, payloadJSON: String) async throws {
        guard let child = records[childID], child.conversationID == conversationID,
              resumeOwner != nil || child.parentRunID == parentRunID else {
            throw FloeError.validationFailed("owner mismatch")
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
    func saveCheckpoint(_ checkpoint: ChildRunCheckpoint) async throws {}
    func saveCheckpoint(_ checkpoint: ChildRunCheckpoint, owner: UUID, leaseExpiresAt: Date) async throws {}
    func checkpoint(childRunID: UUID) async throws -> ChildRunCheckpoint? { nil }
    func deleteCheckpoint(childRunID: UUID) async throws {}
    func finishResumedChild(id: UUID, owner: UUID, state: ChildRunState, iterationCount: Int,
                            resultSummary: String?, errorText: String?, digest: String?) async throws {
        try await finish(id: id, state: state, iterationCount: iterationCount,
                         resultSummary: resultSummary, errorText: errorText, digest: digest)
    }
    func acquireResume(childRunID: UUID, owner: UUID, resumingParentRunID: UUID,
                       leaseExpiresAt: Date, expectedCheckpoint: ChildRunCheckpoint?) async throws -> Bool { false }
    func markResumeStarted(childRunID: UUID, owner: UUID) async throws -> Bool { false }
    func extendResumeLease(childRunID: UUID, owner: UUID, leaseExpiresAt: Date) async throws {}
    func finishResume(childRunID: UUID, owner: UUID) async throws {}
    func cancelResume(childRunID: UUID, owner: UUID) async throws {}

    func record(for id: UUID) -> ChildRunRecord? { records[id] }
}

/// Holds every child provider stream open until released, so a child can be
/// cancelled (or a parent stopped) while genuinely in flight.
private final class CancelGatedProvider: ProviderAdapter, @unchecked Sendable {
    let protocolKind: ModelProtocol = .openAIResponses
    private let streams = AsyncLock<[AsyncThrowingStream<AgentEvent, Error>.Continuation]>([])
    var count: Int { streams.withLock { $0.count } }
    func stream(request: ProviderStreamRequest, credentials: ProviderCredentials) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            streams.withLock { $0.append(continuation) }
        }
    }
    func release() {
        let all = streams.withLock { $0 }
        for stream in all {
            stream.yield(.textDelta(.init(text: "child result")))
            stream.yield(.completed(.init(stopReason: .endTurn)))
            stream.finish()
        }
    }
    func listModels(provider: ProviderProfile, credentials: ProviderCredentials) async throws -> [ModelProfile] { [] }
}

@Suite("FloeAgentRuntime.ParallelDelegationLifecycle")
struct BackgroundChildCancelTests {
    private func makeRunner(store: CancelTestChildStore, adapter: ProviderAdapter) -> SubagentRunner {
        let provider = TestFixtures.localhostProvider()
        return SubagentRunner(
            provider: provider,
            model: TestFixtures.testModel(providerID: provider.id),
            adapter: adapter,
            credentials: ProviderCredentials(),
            executor: MockExecutor(),
            childRunStore: store,
            checkpointStore: store)
    }

    private func makeContext(runID: UUID, conversationID: UUID, callID: String) -> ToolContext {
        let identity = ChildExecutionIdentity(
            parentRunID: runID, rootTaskID: conversationID, delegateCallID: callID)
        let dispatcher = ChildToolDispatcher(
            descriptorProvider: { _ in nil }, allDescriptors: { [] },
            dispatch: { call, _ in
                ToolResult(callID: call.id, status: .ok, outputSummary: "ok", outputDigest: "d")
            })
        return ToolContext(
            runID: runID, toolCallID: callID, scope: .local,
            cancellation: CancellationToken(),
            childBudget: ChildBudgetContext(maximumIterations: 6, reserve: { true }, finish: {}),
            conversationID: conversationID,
            childExecution: ChildExecutionHandoff(
                identity: identity, dispatcher: dispatcher,
                peers: SubagentPeerBus().handle(for: identity)))
    }

    @Test("Cancelling one background subagent settles it cancelled with a real outcome and leaves siblings running")
    func cancelOneBackgroundChildLeavesSiblingRunning() async throws {
        let store = CancelTestChildStore()
        let adapter = CancelGatedProvider()
        let registry = SubagentRunnerRegistry()
        let runID = UUID(), conversationID = UUID()
        await registry.register(makeRunner(store: store, adapter: adapter), for: runID)
        await registry.enableBackground(for: runID)

        let request = SubagentRequest(task: "independent research", kind: .research, runID: runID)
        let first = try await registry.startBackground(request, context: makeContext(runID: runID, conversationID: conversationID, callID: "a"))
        let second = try await registry.startBackground(request, context: makeContext(runID: runID, conversationID: conversationID, callID: "b"))
        for _ in 0..<200 where adapter.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(adapter.count == 2)
        #expect(try await registry.backgroundSnapshot(runID: runID, conversationID: conversationID, childID: first).state == .running)

        try await registry.cancelBackgroundChild(runID: runID, conversationID: conversationID, childID: first)

        // The cancelled child is terminal `.cancelled` WITH an outcome — the
        // parent reconciles the real result instead of failing on an
        // "interrupted" child.
        let record = await store.record(for: first)
        #expect(record?.state == .cancelled)
        #expect(record?.resultSummary?.isEmpty == false)
        let snapshot = try await registry.backgroundSnapshot(runID: runID, conversationID: conversationID, childID: first)
        #expect(snapshot.state == .cancelled)
        #expect(snapshot.outcome?.status == .cancelled)
        #expect(snapshot.delivered == false)

        // The sibling is untouched and still running; it completes normally.
        #expect(try await registry.backgroundSnapshot(runID: runID, conversationID: conversationID, childID: second).state == .running)
        adapter.release()
        let settled = try await registry.settleBackground(runID: runID, conversationID: conversationID)
        #expect(settled.count == 2)
        #expect(settled.first(where: { $0.id == first })?.outcome?.status == .cancelled)
        #expect(settled.first(where: { $0.id == second })?.outcome?.status == .completed)
        #expect(await store.record(for: second)?.state == .completed)

        // The model-facing wait tool reports the real cancelled status.
        let wait = DelegateWaitTool(runners: registry)
        let waitContext = ToolContext(
            runID: runID, toolCallID: "wait", scope: .local,
            cancellation: CancellationToken(), conversationID: conversationID,
            callOrigin: ToolCallOrigin(kind: .mainRunDelegate, runID: runID, callID: "wait", toolName: "delegate.wait"))
        let check = try await wait.execute(.init(childID: first, seconds: 0), context: waitContext)
        #expect(check.summary.contains("status=cancelled"))
        #expect(check.exitStatus == 1)
    }

    @Test("Cancelling a child of another conversation or run is refused")
    func cancelBackgroundChildRejectsForeignChild() async throws {
        let store = CancelTestChildStore()
        let adapter = CancelGatedProvider()
        let registry = SubagentRunnerRegistry()
        let runID = UUID(), conversationID = UUID()
        await registry.register(makeRunner(store: store, adapter: adapter), for: runID)
        await registry.enableBackground(for: runID)
        let request = SubagentRequest(task: "independent research", kind: .research, runID: runID)
        let child = try await registry.startBackground(request, context: makeContext(runID: runID, conversationID: conversationID, callID: "a"))
        for _ in 0..<200 where adapter.count < 1 { try await Task.sleep(for: .milliseconds(10)) }

        await #expect(throws: (any Error).self) {
            try await registry.cancelBackgroundChild(runID: runID, conversationID: UUID(), childID: child)
        }
        await #expect(throws: (any Error).self) {
            try await registry.cancelBackgroundChild(runID: UUID(), conversationID: conversationID, childID: child)
        }
        await #expect(throws: (any Error).self) {
            try await registry.cancelBackgroundChild(runID: runID, conversationID: conversationID, childID: UUID())
        }
        // Refusals changed nothing: the child is still running and completes.
        #expect(try await registry.backgroundSnapshot(runID: runID, conversationID: conversationID, childID: child).state == .running)
        adapter.release()
        _ = try await registry.settleBackground(runID: runID, conversationID: conversationID)
        #expect(await store.record(for: child)?.state == .completed)
    }

    @Test("Stopping one parent cancels only its own children; another run's children keep running")
    func stoppingOneParentLeavesOtherRunsChildrenRunning() async throws {
        let storeA = CancelTestChildStore(), storeB = CancelTestChildStore()
        let adapterA = CancelGatedProvider(), adapterB = CancelGatedProvider()
        let registry = SubagentRunnerRegistry()
        let runA = UUID(), runB = UUID(), conversationA = UUID(), conversationB = UUID()
        await registry.register(makeRunner(store: storeA, adapter: adapterA), for: runA)
        await registry.register(makeRunner(store: storeB, adapter: adapterB), for: runB)
        await registry.enableBackground(for: runA)
        await registry.enableBackground(for: runB)

        let childA = try await registry.startBackground(
            SubagentRequest(task: "work A", kind: .research, runID: runA),
            context: makeContext(runID: runA, conversationID: conversationA, callID: "a"))
        let childB = try await registry.startBackground(
            SubagentRequest(task: "work B", kind: .research, runID: runB),
            context: makeContext(runID: runB, conversationID: conversationB, callID: "b"))
        for _ in 0..<200 where adapterA.count < 1 || adapterB.count < 1 { try await Task.sleep(for: .milliseconds(10)) }

        // The parent-stop path the runtime uses: interrupt, then cancel+join
        // exactly this run's background children.
        await registry.cancelBackground(runID: runA)

        // A's child is ended and stays resumable-interrupted (parent stop,
        // not a deliberate single cancel); its snapshot carries no outcome.
        let snapshotA = try await registry.backgroundSnapshot(runID: runA, conversationID: conversationA, childID: childA)
        #expect(snapshotA.state == .interrupted)
        #expect(snapshotA.outcome == nil)
        // B's child is untouched and completes normally afterwards.
        #expect(try await registry.backgroundSnapshot(runID: runB, conversationID: conversationB, childID: childB).state == .running)
        adapterB.release()
        let settledB = try await registry.settleBackground(runID: runB, conversationID: conversationB)
        #expect(settledB.count == 1)
        #expect(settledB.first?.outcome?.status == .completed)
        #expect(await storeB.record(for: childB)?.state == .completed)
        adapterA.release()
    }

    @Test("Cancelling a background child twice and cancelling a terminal child are harmless")
    func cancelBackgroundChildIsIdempotentPastTerminal() async throws {
        let store = CancelTestChildStore()
        let adapter = CancelGatedProvider()
        let registry = SubagentRunnerRegistry()
        let runID = UUID(), conversationID = UUID()
        await registry.register(makeRunner(store: store, adapter: adapter), for: runID)
        await registry.enableBackground(for: runID)
        let request = SubagentRequest(task: "independent research", kind: .research, runID: runID)
        let child = try await registry.startBackground(request, context: makeContext(runID: runID, conversationID: conversationID, callID: "a"))
        for _ in 0..<200 where adapter.count < 1 { try await Task.sleep(for: .milliseconds(10)) }

        try await registry.cancelBackgroundChild(runID: runID, conversationID: conversationID, childID: child)
        // Second cancel sees a terminal record and returns without touching
        // the durable result.
        try await registry.cancelBackgroundChild(runID: runID, conversationID: conversationID, childID: child)
        let record = await store.record(for: child)
        #expect(record?.state == .cancelled)
        #expect(record?.resultSummary?.isEmpty == false)
        adapter.release()
    }
}
