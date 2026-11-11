import Foundation
import Testing
import FloeCore
import FloeModels
import FloeProviders
import FloeTools
import FloeSecurity
import FloePersistence
import FloeTestSupport
@testable import FloeAgentRuntime

private final class WaitTestLock<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try body(&value)
    }
}
private final class WaitScriptAdapter: ProviderAdapter, @unchecked Sendable {
    let protocolKind: ModelProtocol = .openAIResponses
    private struct State { var script: [[AgentEvent]] = []; var requests: [ProviderStreamRequest] = [] }
    private let state = WaitTestLock(State())
    var script: [[AgentEvent]] {
        get { state.withLock { $0.script } }
        set { state.withLock { $0.script = newValue } }
    }
    var requests: [ProviderStreamRequest] { state.withLock { $0.requests } }
    func stream(request: ProviderStreamRequest, credentials: ProviderCredentials) -> AsyncThrowingStream<AgentEvent, Error> {
        let events = state.withLock { value -> [AgentEvent] in
            let index = value.requests.count; value.requests.append(request)
            return index < value.script.count ? value.script[index] : []
        }
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }; continuation.finish()
        }
    }
    func listModels(provider: ProviderProfile, credentials: ProviderCredentials) async throws -> [ModelProfile] { [] }
}
private final class WaitMemoryCheckpointStore: CheckpointStore, @unchecked Sendable {
    private let state = WaitTestLock<[AgentCheckpoint]>([])
    var saved: [AgentCheckpoint] { state.withLock { $0 } }
    func save(_ checkpoint: AgentCheckpoint) async throws { state.withLock { $0.append(checkpoint) } }
    func load(runID: UUID) async throws -> AgentCheckpoint? { saved.last { $0.runID == runID } }
}
private struct WaitNoopSink: AgentEventSink {
    var clock: WaitTestClock? = nil
    var generation: UUID? = nil
    func agentRuntime(_ runtime: FloeAgentRuntime, didTransitionTo state: AgentState) async {}
    func agentRuntime(_ runtime: FloeAgentRuntime, didEmit event: AgentEvent) async {}
    func agentRuntime(_ runtime: FloeAgentRuntime, didChangeLiveness snapshot: AgentLivenessSnapshot) async {
        if snapshot.phase == .waitingTool, let generation { clock?.report(.waiting, generation: generation) }
    }
    func agentRuntime(_ runtime: FloeAgentRuntime, didFinishToolCall call: ToolCall, result: ToolResult, at stamp: ToolTimingStamp) async {
        if call.toolName == AgentWaitTool.name, let generation {
            clock?.report(.finished(result.outputSummary), generation: generation)
        }
    }
}
private enum WaitTestStage: Sendable { case sleeping, waiting, finished(String) }
private struct WaitFixtureError: Error { let message: String }


private final class WaitTestClock: @unchecked Sendable {
    private struct Sleep {
        let deadline: Date
        let continuation: CheckedContinuation<Void, Error>
    }
    private struct State {
        var date = Date(timeIntervalSince1970: 1_800_000_000)
        var sleepers: [UUID: Sleep] = [:]
        var cancelled: Set<UUID> = []
        var registrations = 0
        var generation = UUID()
    }
    private let state = WaitTestLock(State())
    private let registrations = AsyncStream<(UUID, WaitTestStage)>.makeStream()
    var now: Date { state.withLock { $0.date } }
    var clock: AgentWaitClock {
        AgentWaitClock(now: { self.now }, sleepUntil: { try await self.sleep(until: $0) })
    }
    var deadlines: [Date] { state.withLock { $0.sleepers.values.map(\.deadline) } }
    func beginRuntime() -> UUID { state.withLock { $0.generation = UUID(); return $0.generation } }
    func report(_ stage: WaitTestStage, generation: UUID) { registrations.continuation.yield((generation, stage)) }
    func nextRegistration() async throws { try await nextStage(waiting: false) }
    func nextWaiting() async throws { try await nextStage(waiting: true) }
    private func nextStage(waiting: Bool) async throws {
        let generation = state.withLock { $0.generation }
        for await (observed, stage) in registrations.stream {
            guard observed == generation else { continue }
            switch stage {
            case .sleeping: if !waiting { return }
            case .waiting: if waiting { return }
            case .finished(let summary): throw WaitFixtureError(message: "Tool finished before a real suspension: " + summary)
            }
        }
        throw CancellationError()
    }
    func advance(_ seconds: TimeInterval) {
        let ready = state.withLock { value -> [CheckedContinuation<Void, Error>] in
            value.date.addTimeInterval(seconds)
            let ready = value.sleepers.filter { $0.value.deadline <= value.date }
            for id in ready.keys { value.sleepers[id] = nil }
            return ready.values.map(\.continuation)
        }
        for continuation in ready { continuation.resume() }
    }
    private func sleep(until deadline: Date) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let immediate = state.withLock { value -> Int in
                    if value.cancelled.remove(id) != nil || Task.isCancelled { return -1 }
                    if value.date >= deadline { return 1 }
                    value.sleepers[id] = Sleep(deadline: deadline, continuation: continuation)
                    value.registrations += 1
                    return 0
                }
                if immediate < 0 { continuation.resume(throwing: CancellationError()) }
                else if immediate > 0 { continuation.resume() }
                else { report(.sleeping, generation: state.withLock { $0.generation }) }
            }
        } onCancel: {
            let continuation = self.state.withLock { value -> CheckedContinuation<Void, Error>? in
                guard let sleep = value.sleepers.removeValue(forKey: id) else {
                    value.cancelled.insert(id); return nil
                }
                return sleep.continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }
}

private actor WaitNativeFixture {
    var observation: AgentWaitNativeTimerObservation
    private var listeners: [UUID: AsyncStream<Void>.Continuation] = [:]
    private let reads = AsyncStream<Int>.makeStream()
    private var readCount = 0
    init(owner: AgentWaitOwner, now: Date) {
        observation = .init(binding: .init(alarmID: UUID(), ownerTaskID: owner.conversationID,
            producerRunID: owner.runID, producerCallID: "native-create", creationReceiptID: UUID(),
            payloadDigest: "synthetic-payload", createdAt: now), ledgerState: "created",
            nativeState: "countdown", fireDate: now.addingTimeInterval(30), totalDuration: 30,
            previousElapsed: 0, startDate: now, timelineFingerprint: "one", revision: 1)
    }
    nonisolated var bridge: AgentWaitNativeTimerBridge {
        .init(status: { _, _ in await self.status() }, updates: { await self.updates() })
    }
    func status() -> AgentWaitNativeTimerObservation {
        readCount += 1; reads.continuation.yield(readCount); return observation
    }
    func updates() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            listeners[id] = continuation
            continuation.onTermination = { _ in Task { await self.remove(id) } }
        }
    }
    private func remove(_ id: UUID) { listeners[id] = nil }
    func nextRead() async {
        var iterator = reads.stream.makeAsyncIterator(); _ = await iterator.next()
    }
    func change(state: String?, ledger: String = "created", preserved: String? = nil,
                fireDate: Date? = nil, replaceReceipt: Bool = false) {
        observation.nativeState = state; observation.ledgerState = ledger
        observation.preservedNativeState = preserved; observation.fireDate = fireDate
        observation.revision += 1
        if replaceReceipt { observation.binding.creationReceiptID = UUID() }
        for listener in listeners.values { listener.yield(()) }
    }
    func finish() { for listener in listeners.values { listener.finish() }; listeners.removeAll() }
}

private final class WaitFailingStore: CheckpointStore, @unchecked Sendable {
    private struct State { var count = 0; var saved: [AgentCheckpoint] = [] }
    private let state = WaitTestLock(State())
    var saved: [AgentCheckpoint] { state.withLock { $0.saved } }
    func save(_ checkpoint: AgentCheckpoint) async throws {
        try state.withLock { value in
            value.count += 1
            if value.count == 2 { throw FloeError.validationFailed("synthetic wait save failure") }
            value.saved.append(checkpoint)
        }
    }
    func load(runID: UUID) async throws -> AgentCheckpoint? { saved.last { $0.runID == runID } }
}

@Suite("FloeAgentRuntime.TaskWait", .timeLimit(.minutes(1)))
struct AgentWaitTests {
    private func call(_ seconds: Double, id: String = "wait-1") throws -> ToolCall {
        try ToolCall(id: id, toolName: AgentWaitTool.name,
                     argumentsJSON: JSONEncoder().encode(RuntimeWaitRequest(seconds: seconds)), scope: .local)
    }
    private func fixture(clock: WaitTestClock, calls: [ToolCall], runID: UUID = UUID(),
                         conversationID: UUID = UUID(), native: AgentWaitNativeTimerBridge? = nil,
                         checkpoint: (any CheckpointStore)? = nil) -> (FloeAgentRuntime, WaitScriptAdapter, WaitMemoryCheckpointStore) {
        let registry = ToolRunnerRegistry(); registerAgentWaitTool(registry: registry)
        let adapter = WaitScriptAdapter()
        adapter.script = [calls.map { .toolRequest($0) } + [.completed(.init(stopReason: .toolUse))],
                          [.textDelta(.init(text: "Ready.")), .completed(.init(stopReason: .endTurn))]]
        let provider = TestFixtures.localhostProvider()
        let store = WaitMemoryCheckpointStore()
        let generation = clock.beginRuntime()
        let runtime = FloeAgentRuntime(configuration: .init(conversationID: conversationID, provider: provider,
            model: TestFixtures.testModel(providerID: provider.id),
            agentWaitClock: clock.clock, agentWaitNativeTimerBridge: native),
            adapter: adapter, policy: AutomaticApprovalPolicy(), executor: CatalogToolExecutor(runners: registry),
            checkpointStore: checkpoint ?? store, sink: WaitNoopSink(clock: clock, generation: generation), runID: runID)
        return (runtime, adapter, store)
    }

    @Test("The real catalog runner rejects missing authority, invalid and temporary requests")
    func registeredRunnerAndBounds() async throws {
        let registry = ToolRunnerRegistry(); registerAgentWaitTool(registry: registry)
        let runner = try #require(registry.runner(named: AgentWaitTool.name))
        #expect(runner.descriptor.effect == .internalState)
        #expect(runner.descriptor.executionBoundary == .mainRunOnly)
        #expect(runner.descriptor.supportsConcurrentBatchDispatch == false)
        for request in [RuntimeWaitRequest(), .init(seconds: -1), .init(seconds: .infinity),
                        .init(seconds: .nan), .init(seconds: 86401), .init(seconds: 1, alarmID: UUID())] {
            #expect(throws: (any Error).self) { try request.validate() }
        }
        let context = ToolContext(runID: UUID(), toolCallID: "no-handle", cancellation: .init(), conversationID: UUID())
        await #expect(throws: (any Error).self) {
            try await runner.execute(argumentsJSON: Data(#"{"seconds":0}"#.utf8), context: context)
        }
        var temporary = context
        temporary.temporaryReadOnly = true
        temporary.runtimeWait = RuntimeWaitHandle { _ in Issue.record("temporary wait must not dispatch"); return .init(summary: "bad", fullOutputSHA256: "bad") }
        await #expect(throws: (any Error).self) { try await AgentWaitTool().execute(.init(seconds: 0), context: temporary) }
    }

    @Test("65-second actual invocation remains pending beyond ordinary 30 seconds and saves its disk marker")
    func actualLongWaitAndMarker() async throws {
        let clock = WaitTestClock()
        let (runtime, adapter, store) = fixture(clock: clock, calls: [try call(65)])
        let run = Task { try await runtime.start(goal: "Wait, then report ready.") }
        try await clock.nextRegistration()
        let checkpoint = try #require(store.saved.last)
        guard case .checkpointed(let reference) = checkpoint.state else { Issue.record("missing durable wait marker"); return }
        #expect(reference.reason?.hasPrefix(AgentWaitRecovery.markerPrefix) == true)
        #expect(checkpoint.runtimeWaits?.first?.deadline == clock.now.addingTimeInterval(65))
        #expect(checkpoint.pendingToolResults.isEmpty)
        await #expect(throws: (any Error).self) { try await runtime.resume(from: checkpoint) }
        clock.advance(35)
        #expect(adapter.requests.count == 1)
        #expect(store.saved.last?.pendingToolResults.isEmpty == true)
        clock.advance(30)
        try await run.value
        #expect(adapter.requests.count == 2)
        #expect(await runtime.state.name == "completed")
        let result = try #require(adapter.requests.last?.toolResults.first)
        let receipt = try JSONDecoder.waitDecoder.decode(AgentWaitReceipt.self, from: Data(result.output.utf8))
        #expect(receipt.status == .completed)
        #expect(receipt.waitID == checkpoint.runtimeWaits?.first?.waitID)
        #expect(receipt.continuationInputID == checkpoint.runtimeWaits?.first?.continuationInputID)
        #expect(receipt.remainingSeconds == 0)
    }

    @Test("Zero completes without a sleep; two different same-duration calls have distinct identities")
    func zeroAndDistinctCalls() async throws {
        let clock = WaitTestClock()
        let (runtime, adapter, _) = fixture(clock: clock, calls: [try call(0, id: "zero-1"), try call(0, id: "zero-2")])
        try await runtime.start(goal: "Wait twice.")
        let results = try #require(adapter.requests.last?.toolResults)
        #expect(results.count == 2)
        let receipts = try results.map { try JSONDecoder.waitDecoder.decode(AgentWaitReceipt.self, from: Data($0.output.utf8)) }
        #expect(Set(receipts.map(\.waitID)).count == 2)
        #expect(Set(receipts.map(\.continuationInputID)).count == 2)
        #expect(clock.deadlines.isEmpty)
    }

    @Test("Stop joins the owned suspension without a late provider turn")
    func cancellationFencesWait() async throws {
        let clock = WaitTestClock()
        let (runtime, adapter, store) = fixture(clock: clock, calls: [try call(600)])
        let run = Task { try await runtime.start(goal: "Wait.") }
        try await clock.nextRegistration()
        await runtime.cancel()
        try await run.value
        #expect(adapter.requests.count == 1)
        #expect(clock.deadlines.isEmpty)
        #expect(store.saved.last?.runtimeWaits?.first?.receipt?.status == .cancelled)
        #expect(AgentWaitRecovery.pending(in: try #require(store.saved.last)).isEmpty)
        clock.advance(600)
        #expect(adapter.requests.count == 1)
    }

    @Test("Accepted guidance interrupts with real remaining time; a queued store row does not")
    func guidanceAndQueue() async throws {
        let clock = WaitTestClock()
        let conversation = UUID()
        let (runtime, adapter, _) = fixture(clock: clock, calls: [try call(100)], conversationID: conversation)
        let run = Task { try await runtime.start(goal: "Wait.") }
        try await clock.nextRegistration()
        // Queue writes have no runtime callback. A queued input stays queued
        // while this exact invocation remains suspended.
        let database = try DatabaseManager.inMemory(); try await database.migrate()
        try await SQLiteConversationStore(database: database).saveConversation(.init(id: conversation, title: "Synthetic queue", createdAt: clock.now, updatedAt: clock.now))
        let inputs = SQLiteRunningInputStore(database: database)
        let queued = PendingUserInput(conversationID: conversation, content: "Later", mode: .queue)
        _ = try await inputs.enqueue(queued)
        clock.advance(40)
        #expect(adapter.requests.count == 1)
        #expect(try await inputs.input(id: queued.id)?.status == .queued)
        #expect(await runtime.steer(.init(id: UUID(), content: "Continue now"), expectedRunID: runtime.runID) == .accepted)
        try await run.value
        let receipt = try JSONDecoder.waitDecoder.decode(AgentWaitReceipt.self,
            from: Data(try #require(adapter.requests.last?.toolResults.first).output.utf8))
        #expect(receipt.status == .interrupted)
        #expect(receipt.remainingSeconds == 60)
        #expect(adapter.requests.last?.messages.contains(where: { $0.content == "Continue now" }) == true)
        #expect(try await inputs.input(id: queued.id)?.status == .queued)
    }

    @Test("Cold recovery preserves same-call deadline, receipt and fixed continuation input identity")
    func coldRemainingAndReceipt() async throws {
        let clock = WaitTestClock()
        let (original, _, store) = fixture(clock: clock, calls: [try call(100)])
        let run = Task { try await original.start(goal: "Wait.") }
        try await clock.nextRegistration()
        let saved = try #require(store.saved.last)
        let decoded = try AgentCheckpoint.decoded(from: saved.encoded())
        let record = try #require(decoded.runtimeWaits?.first)
        await original.cancel(); try await run.value
        clock.advance(40)
        let (restored, adapter, _) = fixture(clock: clock, calls: [], runID: saved.runID, conversationID: saved.conversationID)
        adapter.script = [[.textDelta(.init(text: "Ready.")), .completed(.init(stopReason: .endTurn))]]
        let resumed = Task { try await restored.resume(from: decoded) }
        try await clock.nextRegistration()
        let savedDeadline = try #require(record.deadline)
        #expect(clock.deadlines == [savedDeadline])
        #expect(adapter.requests.isEmpty)
        clock.advance(60)
        try await resumed.value
        let result = try #require(adapter.requests.last?.toolResults.first)
        let receipt = try JSONDecoder.waitDecoder.decode(AgentWaitReceipt.self, from: Data(result.output.utf8))
        #expect(receipt.waitID == record.waitID)
        #expect(receipt.continuationInputID == record.continuationInputID)
        #expect(receipt.status == .completed)
        let settled = AgentCheckpoint(runID: saved.runID, conversationID: saved.conversationID,
            state: .checkpointed(.init(reason: AgentWaitRecovery.markerPrefix)), messages: saved.messages,
            pendingToolCalls: saved.pendingToolCalls, pendingToolResults: [.init(callID: result.callID, status: .ok,
                outputSummary: result.output, outputDigest: "synthetic")], runtimeWaits: [record])
        #expect(AgentWaitRecovery.pending(in: settled).isEmpty)
    }

    @Test("Wait persistence failure never starts a sleep or publishes a parked success")
    func saveFailurePreservesHonestResult() async throws {
        let clock = WaitTestClock(); let store = WaitFailingStore()
        let (runtime, adapter, _) = fixture(clock: clock, calls: [try call(100)], checkpoint: store)
        try await runtime.start(goal: "Wait.")
        #expect(clock.deadlines.isEmpty)
        let result = try #require(adapter.requests.last?.toolResults.first)
        #expect(result.output.contains("synthetic wait save failure"))
        #expect(store.saved.allSatisfy {
            if case .checkpointed(let reference) = $0.state {
                return reference.reason?.hasPrefix(AgentWaitRecovery.markerPrefix) != true
            }
            return true
        })
    }

    @Test("The actual filesystem checkpoint retains the waiting marker and cold remaining time")
    func diskCheckpointMarker() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FloeWaitTest-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = FileCheckpointStore(directory: directory)
        let clock = WaitTestClock()
        let (runtime, _, _) = fixture(clock: clock, calls: [try call(100)], checkpoint: disk)
        let run = Task { try await runtime.start(goal: "Wait.") }
        try await clock.nextRegistration()
        try await runtime.checkpoint()
        let independent = FileCheckpointStore(directory: directory)
        let checkpoint = try #require(try await independent.load(runID: runtime.runID))
        guard case .checkpointed(let reference) = checkpoint.state else { Issue.record("disk did not retain marker"); return }
        #expect(reference.reason?.hasPrefix(AgentWaitRecovery.markerPrefix) == true)
        #expect(checkpoint.runtimeWaits?.first?.remaining(at: clock.now.addingTimeInterval(40)) == 60)
        await runtime.cancel(); try await run.value
    }

    @Test("Positive native cold wake uses one stable same-run input and the real runner returns its receipt")
    func nativeColdWakeAndSameRunInput() async throws {
        let clock = WaitTestClock()
        let owner = AgentWaitOwner(conversationID: UUID(), runID: UUID(), callID: "wait-native-cold",
                                   clientSessionID: "main")
        let native = WaitNativeFixture(owner: owner, now: clock.now)
        let initial = await native.observation
        let arguments = RuntimeWaitRequest(alarmID: initial.binding.alarmID)
        let call = try ToolCall(id: owner.callID, toolName: AgentWaitTool.name,
            argumentsJSON: JSONEncoder().encode(arguments), scope: .local)
        let (original, _, store) = fixture(clock: clock, calls: [call], runID: owner.runID,
            conversationID: owner.conversationID, native: native.bridge)
        let run = Task { try await original.start(goal: "Wait for the timer.") }
        await native.nextRead() // initial identity read
        try await clock.nextWaiting() // fail with the actual result if dispatch ended early
        await native.nextRead() // subscription's authoritative read after persistence
        let saved = try #require(store.saved.last)
        let decoded = try AgentCheckpoint.decoded(from: saved.encoded())
        let record = try #require(decoded.runtimeWaits?.first)
        // Teardown only. The cold fixture below deliberately restores the
        // pre-teardown serialized boundary, modelling process replacement.
        await original.cancel(); try await run.value
        let wakeTask = Task { () throws -> AgentWaitWake in
            for try await wake in AgentWaitRecovery.wakes(in: decoded, clock: clock.clock, native: native.bridge) { return wake }
            throw AgentWaitError.unavailable
        }
        await native.nextRead()
        await native.change(state: nil, ledger: "cancelled", preserved: "alerting")
        let wake = try await wakeTask.value
        #expect(wake.inputID == record.continuationInputID)
        #expect(wake.owner.runID == owner.runID)
        let database = try DatabaseManager.inMemory(); try await database.migrate()
        try await SQLiteConversationStore(database: database).saveConversation(.init(id: owner.conversationID,
            title: "Synthetic wake", createdAt: clock.now, updatedAt: clock.now))
        try await SQLiteRunStore(database: database).saveRun(.init(id: owner.runID, conversationID: owner.conversationID,
            state: "checkpointed", goal: "Wait for the timer", startedAt: record.startedAt))
        let inputs = SQLiteRunningInputStore(database: database)
        let delivery = PendingUserInput(id: wake.inputID, conversationID: owner.conversationID,
            targetRunID: owner.runID, content: "The timer state changed; verify and continue.", mode: .steer,
            executionMode: ConversationRunService.taskWaitCompletionExecutionMode)
        _ = try await inputs.enqueue(delivery)
        await #expect(throws: (any Error).self) { try await inputs.enqueue(delivery) }
        _ = try await inputs.beginSteerPromotion(id: delivery.id, expectedRunID: owner.runID)
        try await inputs.markSteerAccepted(id: delivery.id, runID: owner.runID)
        let conversations = SQLiteConversationStore(database: database)
        try await conversations.appendMessage(.init(id: delivery.id, conversationID: owner.conversationID,
            role: "system", content: delivery.content, createdAt: delivery.createdAt,
            parts: [], runID: owner.runID))
        let canonical = SQLiteRunCheckpointStore(database: database, legacyDirectory: nil)
        try await canonical.save(decoded)
        let registry = ToolRunnerRegistry(); registerAgentWaitTool(registry: registry)
        let adapter = WaitScriptAdapter()
        adapter.script = [[.textDelta(.init(text: "Ready.")), .completed(.init(stopReason: .endTurn))]]
        let provider = TestFixtures.localhostProvider()
        let service = ConversationRunService(configuration: .init(conversationID: owner.conversationID,
            provider: provider, model: TestFixtures.testModel(providerID: provider.id),
            agentWaitClock: clock.clock, agentWaitNativeTimerBridge: native.bridge),
            adapter: adapter, policy: AutomaticApprovalPolicy(), executor: CatalogToolExecutor(runners: registry),
            checkpointStore: canonical, contextEngine: nil, conversationStore: conversations,
            runStore: SQLiteRunStore(database: database), runningInputStore: inputs, runID: owner.runID)
        let nativeInput = RuntimeSteerInput(id: delivery.id, content: delivery.content,
            origin: .waitCompletion(waitID: wake.waitID))
        try await service.resumePrepared(from: decoded, resumption: nativeInput)
        // Consumption comes from the REAL runtime receipt checkpoint → sink
        // → service trusted-linkage path, not a manual markConsumed call.
        let consumed = try #require(try await inputs.input(id: delivery.id))
        await service.handleConsumedSteer(nativeInput)
        #expect(try await inputs.input(id: delivery.id) == consumed)
        let mirrors = try await conversations.messages(conversationID: owner.conversationID).filter { $0.id == delivery.id }
        #expect(mirrors.count == 1 && mirrors.first?.role == "system")
        #expect(try await inputs.input(id: delivery.id)?.consumedRunID == owner.runID)
        #expect(try await inputs.input(id: delivery.id)?.status == .consumed)
        let output = try #require(adapter.requests.last?.toolResults.first?.output)
        let receipt = try JSONDecoder.waitDecoder.decode(AgentWaitReceipt.self, from: Data(output.utf8))
        #expect(receipt.status == .completed)
        #expect(receipt.waitID == wake.waitID)
        #expect(adapter.requests.count == 1)
        #expect(adapter.requests.last?.messages.filter { $0.content == delivery.content }.count == 1)
    }

    @Test("A late native wake whose timer incarnation changed cannot advance the provider")
    func lateNativeWakeIsFencedAtResume() async throws {
        let clock = WaitTestClock()
        let owner = AgentWaitOwner(conversationID: UUID(), runID: UUID(), callID: "late-native")
        let native = WaitNativeFixture(owner: owner, now: clock.now)
        let initial = await native.observation
        let call = try ToolCall(id: owner.callID, toolName: AgentWaitTool.name,
            argumentsJSON: JSONEncoder().encode(RuntimeWaitRequest(alarmID: initial.binding.alarmID)), scope: .local)
        let (original, _, store) = fixture(clock: clock, calls: [call], runID: owner.runID,
            conversationID: owner.conversationID, native: native.bridge)
        let run = Task { try await original.start(goal: "Wait for the native timer.") }
        await native.nextRead(); try await clock.nextWaiting(); await native.nextRead()
        let saved = try #require(store.saved.last)
        await original.cancel(); try await run.value
        await native.change(state: "alerting")
        var wake: AgentWaitWake?
        for try await value in AgentWaitRecovery.wakes(in: saved, clock: clock.clock, native: native.bridge) {
            wake = value; break
        }
        let positive = try #require(wake)
        await native.change(state: "alerting", replaceReceipt: true)
        let (restored, adapter, _) = fixture(clock: clock, calls: [], runID: owner.runID,
            conversationID: owner.conversationID, native: native.bridge)
        adapter.script = [[.textDelta(.init(text: "This must never run.")), .completed(.init(stopReason: .endTurn))]]
        try await restored.resume(from: saved, resumptionInput: .init(id: positive.inputID,
            content: "A timer update arrived.", origin: .waitCompletion(waitID: positive.waitID)))
        #expect(adapter.requests.isEmpty)
        #expect(await restored.state.name == "failed")
    }

    @Test("Wrong run, changed call arguments and duplicate wait identities cannot cold-resume")
    func recoveryIdentityFences() async throws {
        let clock = WaitTestClock()
        let call = try call(100)
        let owner = AgentWaitOwner(conversationID: UUID(), runID: UUID(), callID: call.id)
        let record = try AgentWaitRecord(owner: owner, request: .init(seconds: 100), now: clock.now)
        let checkpoint = AgentCheckpoint(runID: owner.runID, conversationID: owner.conversationID,
            state: .checkpointed(.init(reason: AgentWaitRecovery.markerPrefix)), messages: [],
            pendingToolCalls: [call], runtimeWaits: [record])
        #expect(throws: (any Error).self) {
            try AgentWaitRecovery.validatedRecords(in: checkpoint, runID: UUID(), conversationID: owner.conversationID)
        }
        var altered = checkpoint
        altered.pendingToolCalls = [try self.call(101)]
        #expect(throws: (any Error).self) {
            try AgentWaitRecovery.validatedRecords(in: altered, runID: owner.runID, conversationID: owner.conversationID)
        }
        altered = checkpoint; altered.runtimeWaits = [record, record]
        #expect(throws: (any Error).self) {
            try AgentWaitRecovery.validatedRecords(in: altered, runID: owner.runID, conversationID: owner.conversationID)
        }
    }

    @Test("Canonical SQLite recovery excludes paired, stopped, deleted and replacement runs")
    func canonicalRecoveryCandidates() async throws {
        let database = try DatabaseManager.inMemory(); try await database.migrate()
        let conversations = SQLiteConversationStore(database: database)
        let runs = SQLiteRunStore(database: database)
        let store = SQLiteRunCheckpointStore(database: database, legacyDirectory: nil)
        let clock = WaitTestClock()
        func install() async throws -> AgentCheckpoint {
            let conversationID = UUID(), runID = UUID()
            try await conversations.saveConversation(.init(id: conversationID, title: "Wait fixture",
                createdAt: clock.now, updatedAt: clock.now))
            try await runs.saveRun(.init(id: runID, conversationID: conversationID, state: "executingTool",
                goal: "Wait", startedAt: clock.now))
            let call = try self.call(100)
            let record = try AgentWaitRecord(owner: .init(conversationID: conversationID, runID: runID, callID: call.id),
                request: .init(seconds: 100), now: clock.now)
            let checkpoint = AgentCheckpoint(runID: runID, conversationID: conversationID,
                state: .checkpointed(.init(reason: AgentWaitRecovery.markerPrefix + ":" + record.waitID.uuidString)),
                messages: [], pendingToolCalls: [call], runtimeWaits: [record])
            try await store.save(checkpoint); return checkpoint
        }
        let original = try await install()
        #expect(try await store.pendingRuntimeWaitCheckpoints().map(\.runID) == [original.runID])
        try await runs.saveRun(.init(id: UUID(), conversationID: original.conversationID, state: "preparing",
            goal: "Replacement", startedAt: clock.now.addingTimeInterval(1)))
        #expect(try await store.pendingRuntimeWaitCheckpoints().isEmpty)
        let stopped = try await install()
        try await store.save(AgentWaitRecovery.cancelling(stopped, at: clock.now))
        #expect(try await store.pendingRuntimeWaitCheckpoints().isEmpty)
        var paired = try await install()
        paired.pendingToolResults = [.init(callID: try #require(paired.pendingToolCalls.first?.id), status: .ok,
            outputSummary: "synthetic result", outputDigest: "synthetic")]
        try await store.save(paired)
        #expect(try await store.pendingRuntimeWaitCheckpoints().isEmpty)
        let deleted = try await install()
        try await conversations.deleteConversation(id: deleted.conversationID)
        #expect(try await store.pendingRuntimeWaitCheckpoints().isEmpty)
    }

    @Test("Parking CAS never resurrects a Stop, stale wait, replacement run or cancelled reservation")
    func parkingCASFencesStopAndReplacement() async throws {
        let database = try DatabaseManager.inMemory(); try await database.migrate()
        let conversations = SQLiteConversationStore(database: database)
        let runs = SQLiteRunStore(database: database)
        let store = SQLiteRunCheckpointStore(database: database, legacyDirectory: nil)
        let clock = WaitTestClock()
        func install() async throws -> AgentCheckpoint {
            let conversationID = UUID(), runID = UUID()
            try await conversations.saveConversation(.init(id: conversationID, title: "CAS fixture",
                createdAt: clock.now, updatedAt: clock.now))
            try await runs.saveRun(.init(id: runID, conversationID: conversationID, state: "executingTool",
                goal: "Wait", startedAt: clock.now))
            let call = try self.call(100)
            let record = try AgentWaitRecord(owner: .init(conversationID: conversationID, runID: runID, callID: call.id),
                request: .init(seconds: 100), now: clock.now)
            let checkpoint = AgentCheckpoint(runID: runID, conversationID: conversationID,
                state: .checkpointed(.init(reason: AgentWaitRecovery.markerPrefix + ":" + record.waitID.uuidString)),
                messages: [], pendingToolCalls: [call], runtimeWaits: [record])
            try await store.save(checkpoint); return checkpoint
        }
        let valid = try await install()
        #expect(try await store.parkRuntimeWaitIfCurrent(valid, cancellation: .init()))
        #expect(try await runs.run(id: valid.runID)?.state == "checkpointed")
        for state in ["cancelled", "cancelling", "completed", "failed", "checkpointed"] {
            let stale = try await install()
            try await runs.updateRunState(id: stale.runID, state: state, endedAt: clock.now)
            #expect(try await store.parkRuntimeWaitIfCurrent(stale, cancellation: .init()) == false)
            #expect(try await runs.run(id: stale.runID)?.state == state)
            #expect(try await runs.run(id: stale.runID)?.endedAt == clock.now)
        }
        let stopped = try await install()
        try await store.save(AgentWaitRecovery.cancelling(stopped, at: clock.now))
        #expect(try await store.parkRuntimeWaitIfCurrent(stopped, cancellation: .init()) == false)
        let replacement = try await install()
        try await runs.saveRun(.init(id: UUID(), conversationID: replacement.conversationID, state: "preparing",
            goal: "New run", startedAt: clock.now.addingTimeInterval(1)))
        #expect(try await store.parkRuntimeWaitIfCurrent(replacement, cancellation: .init()) == false)
        let cancelled = try await install(); let token = CancellationToken(); token.cancel()
        await #expect(throws: (any Error).self) { try await store.parkRuntimeWaitIfCurrent(cancelled, cancellation: token) }
        #expect(try await runs.run(id: cancelled.runID)?.state == "executingTool")
        let staleWait = try await install()
        var changed = staleWait
        var record = try #require(changed.runtimeWaits?.first)
        record.waitID = UUID(); record.continuationInputID = UUID()
        changed.runtimeWaits = [record]
        changed.state = .checkpointed(.init(reason: AgentWaitRecovery.markerPrefix + ":" + record.waitID.uuidString))
        try await store.save(changed)
        #expect(try await store.parkRuntimeWaitIfCurrent(staleWait, cancellation: .init()) == false)
        #expect(try await runs.run(id: staleWait.runID)?.state == "executingTool")
    }

    @Test("Background-job parking writes the intended checkpointed marker to actual disk")
    func dependencyDiskMarker() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FloeDependencyWait-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileCheckpointStore(directory: directory)
        let adapter = WaitScriptAdapter()
        adapter.script = [[.textDelta(.init(text: "The job is still running.")), .completed(.init(stopReason: .endTurn))]]
        let provider = TestFixtures.localhostProvider()
        let runtime = FloeAgentRuntime(configuration: .init(provider: provider,
            model: TestFixtures.testModel(providerID: provider.id), outstandingDependencies: {
                [.init(identifier: "synthetic-job", kind: "job", label: "synthetic work")]
            }), adapter: adapter, policy: AutomaticApprovalPolicy(), executor: CatalogToolExecutor(runners: .init()),
            checkpointStore: store, sink: WaitNoopSink())
        try await runtime.start(goal: "Wait for the required job.")
        let saved = try #require(try await FileCheckpointStore(directory: directory).load(runID: runtime.runID))
        guard case .checkpointed(let reason) = saved.state else { Issue.record("wrong disk state"); return }
        #expect(reason.reason == FloeAgentRuntime.dependencyWaitReasonPrefix + ":synthetic-job")
        #expect(await runtime.state.name == "checkpointed")
    }

    @Test("Native pause/resume uses real observations and never infers firing from elapsed initial duration")
    func nativePauseResumeAndPositiveProof() async throws {
        let clock = WaitTestClock()
        let owner = AgentWaitOwner(conversationID: UUID(), runID: UUID(), callID: "wait-native")
        let native = WaitNativeFixture(owner: owner, now: clock.now)
        let first = await native.observation
        let record = try AgentWaitRecord(owner: owner, request: .init(alarmID: first.binding.alarmID),
                                        now: clock.now, nativeBinding: first.binding)
        let task = Task { try await AgentWaitSuspension.wait(record: record, clock: clock.clock, native: native.bridge) }
        await native.nextRead()
        await native.change(state: "paused")
        await native.nextRead()
        clock.advance(1000)
        await native.change(state: "countdown", fireDate: clock.now.addingTimeInterval(50))
        await native.nextRead()
        // Only this positive observation releases the wait.
        await native.change(state: "alerting")
        let receipt = try await task.value
        #expect(receipt.status == .completed)
        #expect(receipt.waitID == record.waitID)
    }

    @Test("Native missing/cancelled/changed-incarnation states fail; preserved beforeStop proof completes")
    func nativeUnknownCancelledAndBinding() async throws {
        for variant in 0..<4 {
            let clock = WaitTestClock()
            let owner = AgentWaitOwner(conversationID: UUID(), runID: UUID(), callID: "native-\(variant)")
            let native = WaitNativeFixture(owner: owner, now: clock.now)
            let first = await native.observation
            let record = try AgentWaitRecord(owner: owner, request: .init(alarmID: first.binding.alarmID),
                                            now: clock.now, nativeBinding: first.binding)
            if variant == 0 { await native.change(state: nil) }
            if variant == 1 { await native.change(state: nil, ledger: "cancelled") }
            if variant == 2 { await native.change(state: "alerting", replaceReceipt: true) }
            if variant == 3 { await native.change(state: nil, ledger: "cancelled", preserved: "alerting") }
            if variant == 3 {
                let receipt = try await AgentWaitSuspension.wait(record: record, clock: clock.clock, native: native.bridge)
                #expect(receipt.status == .completed)
            } else {
                await #expect(throws: (any Error).self) {
                    try await AgentWaitSuspension.wait(record: record, clock: clock.clock, native: native.bridge)
                }
            }
        }
    }
}

private struct WaitReceiptDecoder {
    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let lines = data.split(separator: 10, omittingEmptySubsequences: false)
        guard let first = lines.first else { throw WaitFixtureError(message: "Missing receipt") }
        let envelope = (try? JSONSerialization.jsonObject(with: Data(first))) as? [String: Any]
        if envelope?["trustedSourceID"] != nil {
            guard envelope?["toolName"] as? String == AgentWaitTool.name,
                  let runID = envelope?["runID"] as? String, UUID(uuidString: runID) != nil,
                  lines.count > 1 else { throw WaitFixtureError(message: "Invalid runtime provenance envelope") }
            return try decoder.decode(type, from: Data(lines[1]))
        }
        return try decoder.decode(type, from: Data(first))
    }
}
private extension JSONDecoder {
    static var waitDecoder: WaitReceiptDecoder { WaitReceiptDecoder() }
}
