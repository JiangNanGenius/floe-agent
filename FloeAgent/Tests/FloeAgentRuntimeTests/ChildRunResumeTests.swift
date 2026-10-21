// FloeAgentRuntimeTests — durable child checkpoint resume (S7 audit17).
//
// TRUE independent child continuation: an interrupted child resumes from a
// bounded legal checkpoint of its real loop state under an ACTUAL current
// authorized parent — same child id, original history preserved, effective
// rights revalidated against the current parent, spent budget retained
// (never a fresh ceiling per resume), unknown in-flight mutating calls held
// with truthful results instead of blindly replayed, and a durable lease/CAS
// that converges concurrent resumes. Crash conditions are simulated the way
// they really occur: durable running state + checkpoint, then launch
// reconciliation to interrupted (a providerError outcome is terminal and is
// never resumable).

import Foundation
import Testing
import FloeCore
import FloeModels
@testable import FloeProviders
import FloeTools
import FloeTestSupport
@testable import FloePersistence
@testable import FloeAgentRuntime

@Suite("FloeAgentRuntime.ChildRunResume")
struct ChildRunResumeTests {

    // MARK: - Mocks

    /// Records every dispatch the child routes through the canonical seam.
    final class RecordingDispatcher: @unchecked Sendable {
        private let storage = AsyncLock<[(call: ToolCall, context: ToolContext)]>([])
        var calls: [ToolCall] { storage.withLock { $0.map(\.call) } }
        var contexts: [ToolContext] { storage.withLock { $0.map(\.context) } }

        func dispatch(_ call: ToolCall, context: ToolContext) async -> ToolResult {
            storage.withLock { $0.append((call, context)) }
            return ToolResult(callID: call.id, status: .ok, outputSummary: "dispatched", outputDigest: "d")
        }
    }

    /// In-memory child store + checkpoint store with a REAL simulated lease
    /// CAS (live lease refusal, expiry re-acquire), a checkpoint history
    /// (survives terminal finish, like production durability before the
    /// terminal cleanup), and injectable checkpoint save failures.
    private actor FakeChildStore: ChildRunStoring, ChildRunCheckpointStoring {
        private(set) var log: [String] = []
        private var records: [UUID: ChildRunRecord] = [:]
        private var entries: [UUID: [ChildRunEntry]] = [:]
        private var checkpoints: [UUID: ChildRunCheckpoint] = [:]
        private(set) var checkpointHistory: [UUID: [ChildRunCheckpoint]] = [:]
        private var leaseOwner: UUID?
        private var leaseExpiresAt: Date?
        private var resumeParent: UUID?
        /// Number of successful checkpoint saves before saves start throwing.
        var failCheckpointSaveAfter: Int?
        private var checkpointSaveCount = 0

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

        func finish(id: UUID, state: ChildRunState, iterationCount: Int, resultSummary: String?, errorText: String?, digest: String?) async throws {
            log.append("finish:\(state.rawValue)")
            guard var record = records[id] else { return }
            record.state = state
            record.iterationCount = iterationCount
            record.resultSummary = resultSummary
            records[id] = record
            // Mirror production: a terminal child leaves no resumable state.
            checkpoints[id] = nil
        }

        func child(id: UUID) async throws -> ChildRunRecord? { records[id] }

        func children(parentRunID: UUID) async throws -> [ChildRunRecord] {
            records.values.filter { $0.parentRunID == parentRunID }
        }

        func children(conversationID: UUID) async throws -> [ChildRunRecord] {
            records.values.filter { $0.conversationID == conversationID }
        }

        func entries(childRunID: UUID, afterSequence: Int, limit: Int) async throws -> ChildRunEntryPage {
            let all = (entries[childRunID] ?? []).filter { $0.sequence > afterSequence }
            return ChildRunEntryPage(entries: Array(all.prefix(limit)), nextSequence: nil)
        }

        func reconcileInterruptedOnLaunch() async throws -> Int {
            let ids = records.filter { $0.value.state == .registered || $0.value.state == .running }.map(\.key)
            for id in ids {
                records[id]?.state = .interrupted
                leaseOwner = nil
                leaseExpiresAt = nil
                resumeParent = nil
            }
            return ids.count
        }

        func setCheckpointFailure(after count: Int?) { failCheckpointSaveAfter = count }

        func saveCheckpoint(_ checkpoint: ChildRunCheckpoint, owner: UUID, leaseExpiresAt: Date) async throws {
            guard leaseOwner == owner, let expiry = self.leaseExpiresAt, expiry > Date() else {
                throw FloeError.storageCorrupted("lost lease")
            }
            try await saveCheckpoint(checkpoint)
            self.leaseExpiresAt = leaseExpiresAt
        }

        func finishResumedChild(id: UUID, owner: UUID, state: ChildRunState, iterationCount: Int,
                                resultSummary: String?, errorText: String?, digest: String?) async throws {
            guard leaseOwner == owner, let expiry = leaseExpiresAt, expiry > Date() else {
                throw FloeError.storageCorrupted("lost lease")
            }
            try await finish(id: id, state: state, iterationCount: iterationCount,
                             resultSummary: resultSummary, errorText: errorText, digest: digest)
            leaseOwner = nil
            leaseExpiresAt = nil
        }

        func saveCheckpoint(_ checkpoint: ChildRunCheckpoint) async throws {
            checkpointSaveCount += 1
            if let failCheckpointSaveAfter, checkpointSaveCount > failCheckpointSaveAfter {
                log.append("checkpoint:failed")
                throw FloeError.storageCorrupted("simulated checkpoint save failure")
            }
            log.append("checkpoint:\(checkpoint.kind.rawValue)")
            checkpoints[checkpoint.childID] = checkpoint
            checkpointHistory[checkpoint.childID, default: []].append(checkpoint)
        }

        func checkpoint(childRunID: UUID) async throws -> ChildRunCheckpoint? {
            checkpoints[childRunID]
        }

        func deleteCheckpoint(childRunID: UUID) async throws {
            checkpoints[childRunID] = nil
        }

        func acquireResume(childRunID: UUID, owner: UUID, resumingParentRunID: UUID, leaseExpiresAt: Date, expectedCheckpoint: ChildRunCheckpoint? = nil) async throws -> Bool {
            // Mirrors the SQL CAS: grant only from an interrupted child with
            // no live lease.
            guard records[childRunID]?.state == .interrupted else { return false }
            if let expectedCheckpoint, checkpoints[childRunID] != expectedCheckpoint { return false }
            if let existingExpiry = self.leaseExpiresAt, existingExpiry > Date(), leaseOwner != nil {
                return false
            }
            self.leaseOwner = owner
            self.leaseExpiresAt = leaseExpiresAt
            self.resumeParent = resumingParentRunID
            records[childRunID]?.state = .running
            return true
        }

        func markResumeStarted(childRunID: UUID, owner: UUID) async throws -> Bool {
            leaseOwner == owner
        }

        func extendResumeLease(childRunID: UUID, owner: UUID, leaseExpiresAt: Date) async throws {
            if leaseOwner == owner { self.leaseExpiresAt = leaseExpiresAt }
        }

        func finishResume(childRunID: UUID, owner: UUID) async throws {
            guard leaseOwner == owner else { return }
            leaseOwner = nil
            leaseExpiresAt = nil
        }

        func cancelResume(childRunID: UUID, owner: UUID) async throws {
            guard leaseOwner == owner else { return }
            leaseOwner = nil
            leaseExpiresAt = nil
            resumeParent = nil
            if records[childRunID]?.state == .running {
                records[childRunID]?.state = .interrupted
            }
        }

        // Test inspection
        func recordedEntries(_ id: UUID) -> [ChildRunEntry] { entries[id] ?? [] }
        func resumeParentBound() -> UUID? { resumeParent }
    }

    // MARK: - Harness

    private func makeRunner(
        adapter: MockAdapter,
        store: FakeChildStore,
        provider: ProviderProfile = TestFixtures.localhostProvider()
    ) -> SubagentRunner {
        SubagentRunner(
            provider: provider,
            model: TestFixtures.testModel(providerID: provider.id),
            adapter: adapter,
            credentials: ProviderCredentials(),
            executor: makeExecutor(),
            childRunStore: store,
            checkpointStore: store
        )
    }

    private func makeExecutor() -> MockExecutor {
        let executor = MockExecutor()
        executor.descriptors["test.read"] = .init(
            name: "test.read", riskLabels: [], isSideEffecting: false
        )
        executor.descriptors["test.write"] = .init(
            name: "test.write", riskLabels: [.writesFiles], isSideEffecting: true
        )
        return executor
    }

    private func budget(_ maximum: Int = 6) -> ChildBudgetContext {
        ChildBudgetContext(maximumIterations: maximum, reserve: { true }, finish: {})
    }

    private func makeIdentity(runID: UUID) -> ChildExecutionIdentity {
        ChildExecutionIdentity(
            parentRunID: runID,
            rootTaskID: UUID(),
            delegateCallID: "delegate-1"
        )
    }

    private func childContext(
        identity: ChildExecutionIdentity,
        dispatcher: RecordingDispatcher,
        allowedToolNames: Set<String>? = ["test.read", "test.write"],
        cancellation: CancellationToken = CancellationToken()
    ) -> ToolContext {
        let bus = SubagentPeerBus()
        return ToolContext(
            runID: identity.parentRunID,
            scope: .local,
            allowedToolNames: allowedToolNames,
            cancellation: cancellation,
            childBudget: budget(),
            conversationID: identity.rootTaskID,
            childExecution: ChildExecutionHandoff(
                identity: identity,
                dispatcher: ChildToolDispatcher(
                    descriptorProvider: { _ in nil },
                    allDescriptors: { [] },
                    dispatch: { call, context in
                        await dispatcher.dispatch(call, context: context)
                    }
                ),
                peers: bus.handle(for: identity)
            )
        )
    }

    /// Simulates process death + relaunch faithfully: a durable RUNNING child
    /// whose checkpoint was committed at a safe boundary, then launch
    /// reconciliation marks it interrupted. A terminal outcome would never be
    /// resumable, so crash tests must build durable state, not a failed run.
    private func makeInterruptedChild(
        store: FakeChildStore,
        spentIterations: Int = 1,
        pendingCalls: [ChildRunCheckpoint.CallIntent] = [],
        pendingSettled: [ChildRunCheckpoint.SettledPair] = [],
        kind: ChildRunCheckpointKind = .postCall,
        task: String = "inspect then answer"
    ) async throws -> (childID: UUID, conversationID: UUID, originalParent: UUID) {
        let originalParent = UUID()
        let root = UUID()
        let childID = UUID()
        try await store.register(ChildRunRecord(
            id: childID,
            parentRunID: originalParent,
            rootRunID: root,
            conversationID: root,
            childIndex: 1,
            kind: "explore",
            taskSummary: task,
            state: .running,
            iterationCount: spentIterations
        ))
        try await store.saveCheckpoint(ChildRunCheckpoint(
            childID: childID,
            kind: kind,
            iterationsUsed: spentIterations,
            hardCeiling: 6,
            requestKind: "explore",
            task: task,
            context: nil,
            messages: [
                .init(role: "system", content: "You are a delegated subagent."),
                .init(role: "user", content: task),
            ],
            replayedPairs: [],
            pendingCalls: pendingCalls,
            pendingSettled: pendingSettled,
            pendingReasoning: nil,
            discovery: .init(loadedNames: ["tools.search", "tools.list"], priorityNames: [], revision: 0),
            skillRevisions: [:],
            activeSkillIDs: [],
            droppedReplayedPairs: 0,
            droppedAssistantMessages: 0,
            truncatedResultOutputs: 0,
            peerMessagesDelivered: 0,
            evidence: ["test.read abcdef12"],
            pendingRoutes: ["test.read abcdef12"],
            lastAssistantText: "",
            providerID: UUID().uuidString,
            modelID: UUID().uuidString,
            originalParentRunID: originalParent,
            rootRunID: root,
            conversationID: root,
            startedAt: Date(),
            savedAt: Date(),
            resumedParentRunID: nil,
            resumeCount: 0,
            recoveryHoldCallIDs: []
        ))
        let reconciled = try await store.reconcileInterruptedOnLaunch()
        #expect(reconciled == 1)
        return (childID, root, originalParent)
    }

    private func settledReadPair(
        _ call: ChildRunCheckpoint.CallIntent
    ) -> ChildRunCheckpoint.SettledPair {
        ChildRunCheckpoint.SettledPair(
            call: call,
            result: .init(
                callID: call.id,
                status: "ok",
                outputSummary: "read output",
                outputDigest: "digest-1"
            )
        )
    }

    // MARK: - Runner checkpoint persistence (the durable substrate)

    @Test("a running child persists preCall checkpoints before side effects and postCall checkpoints before continuation")
    func runnerPersistsBoundaryCheckpoints() async throws {
        let store = FakeChildStore()
        let dispatcher = RecordingDispatcher()
        let adapter = MockAdapter()
        let read = try TestFixtures.toolCall(id: "read-1", toolName: "test.read", arguments: #"{"path":"a.txt"}"#)
        adapter.script = [
            [.toolRequest(read)],
            [.textDelta(.init(text: "final answer")), .completed(.init(stopReason: .endTurn))],
        ]
        let parentRun = UUID()
        let identity = makeIdentity(runID: parentRun)
        let outcome = try await makeRunner(adapter: adapter, store: store).runStructured(
            SubagentRequest(task: "inspect then answer", kind: .explore, runID: parentRun),
            context: childContext(identity: identity, dispatcher: dispatcher)
        )
        #expect(outcome.status == .completed)
        let log = await store.log
        #expect(log.contains("checkpoint:preCall"))
        #expect(log.contains("checkpoint:postCall"))
        let lastPre = log.lastIndex(of: "checkpoint:preCall")
        let lastPost = log.lastIndex(of: "checkpoint:postCall")
        #expect(lastPost != nil && lastPre != nil && lastPost! > lastPre!)
        let history = await store.checkpointHistory
        let checkpoint = try #require(history[identity.childID]?.last)
        // The boundary capture holds the exact loop state: spent budget, the
        // original parent provenance and exactly what would ride the next
        // request (the read call + its real result) — resume feeds these
        // without re-executing anything.
        #expect(checkpoint.kind == .postCall)
        #expect(checkpoint.pendingCalls.map(\.id) == ["read-1"])
        #expect(checkpoint.pendingSettled.map { $0.result.callID } == ["read-1"])
        #expect(checkpoint.pendingSettled.first?.result.status == "ok")
        #expect(checkpoint.iterationsUsed == 1)
        #expect(checkpoint.hardCeiling == 6)
        #expect(checkpoint.originalParentRunID == parentRun)
        #expect(checkpoint.resumedParentRunID == nil)
        // Terminal finish leaves no live checkpoint behind.
        #expect(try await store.checkpoint(childRunID: identity.childID) == nil)
    }

    // MARK: - postCall crash → resume feeds real results without re-execution

    @Test("a postCall crash resumes by feeding the durable real results — tools are never re-executed")
    func postCallResumeFeedsRealResults() async throws {
        let store = FakeChildStore()
        let readIntent = ChildRunCheckpoint.CallIntent(id: "read-1", toolName: "test.read", argumentsJSON: #"{"path":"a.txt"}"#)
        let (childID, conversationID, originalParent) = try await makeInterruptedChild(
            store: store,
            spentIterations: 1,
            pendingSettled: [settledReadPair(readIntent)]
        )

        let service = ChildResumeService(store: store)
        let currentParent = UUID()
        let plan = try await service.begin(
            childID: childID,
            currentParentRunID: currentParent,
            currentParentConversationID: conversationID
        )
        #expect(plan.childID == childID)
        #expect(plan.record.parentRunID == originalParent)
        #expect(plan.resumedIdentity.parentRunID == currentParent)
        #expect(plan.resumedIdentity.childID == childID)
        #expect(plan.remainingIterations == 5)

        let resumeAdapter = MockAdapter()
        resumeAdapter.script = [[.textDelta(.init(text: "resumed final answer")), .completed(.init(stopReason: .endTurn))]]
        let resumeDispatcher = RecordingDispatcher()
        let resumeIdentity = plan.resumedIdentity
        let outcome = try await makeRunner(adapter: resumeAdapter, store: store).resumeStructured(
            plan,
            context: childContext(identity: resumeIdentity, dispatcher: resumeDispatcher),
            childBudget: budget(plan.remainingIterations)
        )
        #expect(outcome.status == .completed)
        #expect(outcome.findings.contains("resumed final answer"))
        // Spent budget retained: 1 pre-crash + 1 resumed, never reset.
        #expect(outcome.iterationsUsed == 2)
        // The settled call was fed back, NOT re-executed under the new parent.
        #expect(resumeDispatcher.calls.isEmpty)
        let resumedRequest = try #require(resumeAdapter.requests.first)
        #expect(resumedRequest.toolResults.contains(where: { $0.callID == "read-1" }))
        // Same durable identity; original history untouched; resume recorded.
        let record = try #require(await store.child(id: childID))
        #expect(record.parentRunID == originalParent)
        #expect(record.state == .completed)
        let resumedEntries = await store.recordedEntries(childID)
        #expect(resumedEntries.contains(where: {
            $0.kind == .state && $0.payloadJSON.contains("\"resumed\"")
        }))
        // The lease bound the ACTUAL resuming parent; checkpoint consumed.
        #expect(await store.resumeParentBound() == currentParent)
        #expect(try await store.checkpoint(childRunID: childID) == nil)
    }

    // MARK: - preCall crash → read-only re-executes, mutating held

    @Test("a preCall crash holds mutating calls with a truthful result and re-executes only read-only calls")
    func preCallResumeHoldsMutations() async throws {
        let store = FakeChildStore()
        let readIntent = ChildRunCheckpoint.CallIntent(id: "read-1", toolName: "test.read", argumentsJSON: #"{"path":"a.txt"}"#)
        let writeIntent = ChildRunCheckpoint.CallIntent(id: "write-1", toolName: "test.write", argumentsJSON: #"{"path":"b.txt"}"#)
        let (childID, conversationID, _) = try await makeInterruptedChild(
            store: store,
            kind: .preCall,
            pendingCalls: [readIntent, writeIntent],
            task: "read then write"
        )

        let service = ChildResumeService(store: store)
        let plan = try await service.begin(
            childID: childID,
            currentParentRunID: UUID(),
            currentParentConversationID: conversationID
        )
        let resumeAdapter = MockAdapter()
        resumeAdapter.script = [[.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]]
        let resumeDispatcher = RecordingDispatcher()
        let resumeIdentity = plan.resumedIdentity
        let resumed = try await makeRunner(adapter: resumeAdapter, store: store).resumeStructured(
            plan,
            context: childContext(identity: resumeIdentity, dispatcher: resumeDispatcher),
            childBudget: budget(plan.remainingIterations)
        )
        // Only reads may rerun; unknown writes pause before the provider.
        #expect(resumed.status == .toolError)
        #expect(resumeAdapter.requests.isEmpty)
        #expect(resumeDispatcher.calls.map(\.id) == ["read-1"])
        let saved = try #require(try await store.checkpoint(childRunID: childID))
        #expect(saved.recoveryHoldCallIDs == ["write-1"])
        #expect(saved.pendingSettled.contains { $0.call.id == "read-1" && $0.result.outputSummary == "dispatched" })
        #expect(try await store.child(id: childID)?.state == .interrupted)
        #expect(try await service.availability(childID: childID) == .recoveryHeld)
        await #expect(throws: ChildResumeError.recoveryHeld) {
            _ = try await service.begin(childID: childID, currentParentRunID: UUID(),
                                        currentParentConversationID: conversationID)
        }
        #expect(resumeAdapter.requests.isEmpty)

    }

    /// A post-call checkpoint save failure never changes the real outcome and
    /// never fabricates durable state: the failure is visible on the outcome
    /// and the child finishes honestly terminal (a completed child is NOT
    /// resumable — only process interruption is).
    @Test("a failed post-call checkpoint save is visible and the child still finishes honestly")
    func failedPostCallSaveIsVisible() async throws {
        let store = FakeChildStore()
        await store.setCheckpointFailure(after: 1) // preCall succeeds, postCall fails
        let dispatcher = RecordingDispatcher()
        let adapter = MockAdapter()
        let read = try TestFixtures.toolCall(id: "read-1", toolName: "test.read", arguments: #"{"path":"a.txt"}"#)
        adapter.script = [
            [.toolRequest(read)],
            [.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))],
        ]
        let parentRun = UUID()
        let identity = makeIdentity(runID: parentRun)
        let outcome = try await makeRunner(adapter: adapter, store: store).runStructured(
            SubagentRequest(task: "inspect", kind: .explore, runID: parentRun),
            context: childContext(identity: identity, dispatcher: dispatcher)
        )
        #expect(outcome.status == .toolError)
        #expect(adapter.requests.count == 1)
        #expect(dispatcher.calls.map(\.id) == ["read-1"])
        let children = try await store.children(parentRunID: parentRun)
        let child = try #require(children.first)
        #expect(child.state == .interrupted)
        let saved = try #require(try await store.checkpoint(childRunID: child.id))
        #expect(saved.kind == .preCall)
        #expect(saved.pendingCalls.map(\.id) == ["read-1"])

    }

    // MARK: - Budget continuity

    @Test("resume retains the spent total and continues inside the original allowance — no fresh ceiling")
    func resumeRetainsSpentBudget() async throws {
        let store = FakeChildStore()
        let readIntent = ChildRunCheckpoint.CallIntent(id: "read-1", toolName: "test.read", argumentsJSON: #"{"path":"a.txt"}"#)
        let (childID, conversationID, _) = try await makeInterruptedChild(
            store: store,
            spentIterations: 3,
            pendingSettled: [settledReadPair(readIntent)]
        )
        let service = ChildResumeService(store: store)
        let plan = try await service.begin(
            childID: childID,
            currentParentRunID: UUID(),
            currentParentConversationID: conversationID
        )
        // Original allowance 6, 3 spent → 3 remain. Not a fresh 20.
        #expect(plan.checkpoint.hardCeiling == 6)
        #expect(plan.checkpoint.iterationsUsed == 3)
        #expect(plan.remainingIterations == 3)

        let resumeAdapter = MockAdapter()
        resumeAdapter.script = [[.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]]
        let resumeIdentity = plan.resumedIdentity
        let resumed = try await makeRunner(adapter: resumeAdapter, store: store).resumeStructured(
            plan,
            context: childContext(identity: resumeIdentity, dispatcher: RecordingDispatcher()),
            childBudget: budget(plan.remainingIterations)
        )
        #expect(resumed.status == .completed)
        #expect(resumed.iterationsUsed == 4)
        #expect(resumeAdapter.requests.count == 1)
    }

    @Test("a fully spent child is refused — resume never mints fresh budget")
    func fullySpentChildRefused() async throws {
        let store = FakeChildStore()
        let (childID, conversationID, _) = try await makeInterruptedChild(
            store: store,
            spentIterations: 6,
            pendingSettled: []
        )
        await #expect(throws: ChildResumeError.budgetAlreadyExhausted(spent: 6, ceiling: 6)) {
            _ = try await ChildResumeService(store: store).begin(
                childID: childID,
                currentParentRunID: UUID(),
                currentParentConversationID: conversationID
            )
        }
    }

    // MARK: - Finished-child refusal and lease convergence

    @Test("a finished child never restarts and a live lease converges to one resumer")
    func finishedRefusedAndLeaseConverges() async throws {
        let store = FakeChildStore()
        let readIntent = ChildRunCheckpoint.CallIntent(id: "read-1", toolName: "test.read", argumentsJSON: #"{"path":"a.txt"}"#)
        let (childID, conversationID, _) = try await makeInterruptedChild(
            store: store,
            pendingSettled: [settledReadPair(readIntent)]
        )

        let service = ChildResumeService(store: store)
        // Concurrent begins: exactly one wins the lease.
        let first = try await service.begin(
            childID: childID,
            currentParentRunID: UUID(),
            currentParentConversationID: conversationID
        )
        await #expect(throws: ChildResumeError.leaseHeldByOther) {
            _ = try await service.begin(
                childID: childID,
                currentParentRunID: UUID(),
                currentParentConversationID: conversationID
            )
        }
        // The lease binds the ACTUAL resuming parent, not an arbitrary run.
        #expect(await store.resumeParentBound() == first.resumedIdentity.parentRunID)
        // Pre-start cancel restores the honest interrupted state.
        try await service.cancel(childID: childID, ownerToken: first.ownerToken)
        let record = try #require(await store.child(id: childID))
        #expect(record.state == .interrupted)
        // A finished child is refused even with a stale checkpoint row.
        try await store.transition(id: childID, state: .completed, iterationCount: 1, endedAt: Date())
        await #expect(throws: ChildResumeError.childNotResumable(state: .completed)) {
            _ = try await service.begin(
                childID: childID,
                currentParentRunID: UUID(),
                currentParentConversationID: conversationID
            )
        }
    }

    @Test("resume under a parent of another conversation is refused")
    func crossConversationRefused() async throws {
        let store = FakeChildStore()
        let readIntent = ChildRunCheckpoint.CallIntent(id: "read-1", toolName: "test.read", argumentsJSON: #"{"path":"a.txt"}"#)
        let (childID, _, _) = try await makeInterruptedChild(
            store: store,
            pendingSettled: [settledReadPair(readIntent)]
        )
        await #expect(throws: ChildResumeError.crossConversationResume) {
            _ = try await ChildResumeService(store: store).begin(
                childID: childID,
                currentParentRunID: UUID(),
                currentParentConversationID: UUID()
            )
        }
    }

    // MARK: - Permissions revalidation against the CURRENT parent

    @Test("a previously in-flight write stays held even after the current ceiling removes it")
    func recoveredCallOutsideCurrentCeilingDenied() async throws {
        let store = FakeChildStore()
        let writeIntent = ChildRunCheckpoint.CallIntent(id: "write-1", toolName: "test.write", argumentsJSON: #"{"path":"b.txt"}"#)
        let (childID, conversationID, _) = try await makeInterruptedChild(
            store: store,
            kind: .preCall,
            pendingCalls: [writeIntent]
        )
        let service = ChildResumeService(store: store)
        let plan = try await service.begin(
            childID: childID,
            currentParentRunID: UUID(),
            currentParentConversationID: conversationID
        )
        let resumeAdapter = MockAdapter()
        resumeAdapter.script = [[.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]]
        let dispatcher = RecordingDispatcher()
        // CURRENT parent no longer offers test.write.
        let resumeIdentity = plan.resumedIdentity
        let resumed = try await makeRunner(adapter: resumeAdapter, store: store).resumeStructured(
            plan,
            context: childContext(
                identity: resumeIdentity,
                dispatcher: dispatcher,
                allowedToolNames: ["test.read"]
            ),
            childBudget: budget(plan.remainingIterations)
        )
        #expect(resumed.status == .toolError)
        #expect(dispatcher.calls.isEmpty)
        #expect(resumeAdapter.requests.isEmpty)
        #expect(try await service.availability(childID: childID) == .recoveryHeld)

    }

    // MARK: - Save-failure visibility and the pre-call recovery gate

    @Test("a failed pre-call checkpoint withholds mutating calls with honest results and surfaces the failure")
    func preCallSaveFailureWithholdsMutations() async throws {
        let store = FakeChildStore()
        await store.setCheckpointFailure(after: 0) // every checkpoint save fails
        let dispatcher = RecordingDispatcher()
        let adapter = MockAdapter()
        let read = try TestFixtures.toolCall(id: "read-1", toolName: "test.read", arguments: #"{"path":"a.txt"}"#)
        let write = try TestFixtures.toolCall(id: "write-1", toolName: "test.write", arguments: #"{"path":"b.txt"}"#)
        adapter.script = [
            [.toolRequest(read), .toolRequest(write)],
            [.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))],
        ]
        let parentRun = UUID()
        let identity = makeIdentity(runID: parentRun)
        let outcome = try await makeRunner(adapter: adapter, store: store).runStructured(
            SubagentRequest(task: "work", kind: .execute, runID: parentRun),
            context: childContext(identity: identity, dispatcher: dispatcher)
        )
        #expect(outcome.status == .toolError)
        #expect(dispatcher.calls.isEmpty)
        #expect(adapter.requests.count == 1)
        #expect(outcome.findings.contains("No tool from this batch was executed"))
        #expect(try await store.children(parentRunID: parentRun).first?.state == .interrupted)

    }

    // MARK: - Provider provenance and resume note

    @Test("a provider/model switch is recorded in the resume note; the conversation continues")
    func providerSwitchRecorded() async throws {
        let store = FakeChildStore()
        let readIntent = ChildRunCheckpoint.CallIntent(id: "read-1", toolName: "test.read", argumentsJSON: #"{"path":"a.txt"}"#)
        let (childID, conversationID, _) = try await makeInterruptedChild(
            store: store,
            pendingSettled: [settledReadPair(readIntent)]
        )
        let service = ChildResumeService(store: store)
        let plan = try await service.begin(
            childID: childID,
            currentParentRunID: UUID(),
            currentParentConversationID: conversationID
        )
        let resumeAdapter = MockAdapter()
        resumeAdapter.script = [[.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]]
        let otherProvider = ProviderProfile(
            id: UUID(),
            kind: .custom,
            wireProtocol: .openAIResponses,
            baseURL: URL(string: "https://localhost:8443")!,
            secretRef: nil,
            region: nil,
            nonSecretHeaders: [:],
            isEnabled: true,
            allowsPlainHTTP: false,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            syncRevision: 0
        )
        let resumeIdentity = plan.resumedIdentity
        let resumed = try await makeRunner(adapter: resumeAdapter, store: store, provider: otherProvider).resumeStructured(
            plan,
            context: childContext(identity: resumeIdentity, dispatcher: RecordingDispatcher()),
            childBudget: budget(plan.remainingIterations)
        )
        #expect(resumed.status == .completed)
        let request = try #require(resumeAdapter.requests.first)
        let system = try #require(request.effectiveMessages.first(where: { $0.role == "system" }))
        let systemText = system.content.compactMap { part -> String? in
            if case .text(let text) = part { return text }
            return nil
        }.joined()
        #expect(systemText.contains("RESUMING"))
        #expect(systemText.contains("Provider/model binding changed"))
    }

    // MARK: - Cancellation

    @Test("cancelling the current parent during a resumed run reports cancelled and settles the lease")
    func cancellationDuringResume() async throws {
        let store = FakeChildStore()
        let readIntent = ChildRunCheckpoint.CallIntent(id: "read-1", toolName: "test.read", argumentsJSON: #"{"path":"a.txt"}"#)
        let (childID, conversationID, _) = try await makeInterruptedChild(
            store: store,
            pendingSettled: [settledReadPair(readIntent)]
        )
        let service = ChildResumeService(store: store)
        let plan = try await service.begin(
            childID: childID,
            currentParentRunID: UUID(),
            currentParentConversationID: conversationID
        )
        let resumeAdapter = MockAdapter()
        resumeAdapter.script = [[.textDelta(.init(text: "partial")), .completed(.init(stopReason: .endTurn))]]
        let token = CancellationToken()
        token.cancel()
        let resumeIdentity = plan.resumedIdentity
        let resumed = try await makeRunner(adapter: resumeAdapter, store: store).resumeStructured(
            plan,
            context: childContext(identity: resumeIdentity, dispatcher: RecordingDispatcher(), cancellation: token),
            childBudget: budget(plan.remainingIterations)
        )
        #expect(resumed.status == .cancelled)
        let record = try #require(await store.child(id: childID))
        #expect(record.state == .cancelled)
    }
}
