// Focused behavioral regression for the bounded provider reconnect on the
// Android shared runtime (port of the iOS fix e7bd98815, "Bound silent model
// reconnects", onto the byte-shared FloeAgentRuntime).
//
// Invariants pinned here:
//   * The first-event wait follows the previously observed request→activity
//     latency inside a hard ceiling, and a silent timeout grants the full
//     ceiling exactly once (`firstEventWait`).
//   * ONE silent reconnect: a first-attempt timeout before any provider
//     event reconnects quietly (no user-visible error while the attempt
//     snapshot says "retrying"); a second silent attempt stops with exactly
//     ONE terminal error and an exhausted attempt snapshot — the run never
//     hangs on dead air, whether the app watchdog or the transport times
//     out first.
//   * A terminally completed provider turn is not failed by the idle
//     watchdog while finalization legitimately awaits outstanding
//     dependencies.
//
// Registered in the shared package's FloeAgentRuntimeTests target; it does
// not build or drive the Android App.
import Foundation
import XCTest
@testable import FloeAgentRuntime
import FloeProviders
import FloeModels
import FloeTools
import FloeCore
import FloeSecurity

final class BoundedProviderReconnectTests: XCTestCase {

    // MARK: - Adaptive first-event wait

    func testFirstResponseWaitFollowsObservedLatencyWithinWindow() {
        XCTAssertEqual(
            FloeAgentRuntime.firstEventWait(base: 120, lastActivityDelay: 1,
                                            afterSilentTimeout: false), 120)
        XCTAssertEqual(
            FloeAgentRuntime.firstEventWait(base: 120, lastActivityDelay: 110,
                                            afterSilentTimeout: false), 165)
        XCTAssertEqual(
            FloeAgentRuntime.firstEventWait(base: 120, lastActivityDelay: 300,
                                            afterSilentTimeout: false), 180)
        XCTAssertEqual(
            FloeAgentRuntime.firstEventWait(base: 120, lastActivityDelay: 0,
                                            afterSilentTimeout: true), 180)
        XCTAssertEqual(
            FloeAgentRuntime.firstEventWait(base: 0, lastActivityDelay: 110,
                                            afterSilentTimeout: true), 0)
    }

    // MARK: - One quiet silent reconnect, bounded stop after the second

    func testMissingFirstEventReconnectsWithoutVisibleError() async throws {
        let adapter = SilentFirstAttemptsAdapter()
        let sink = MockSink()
        let runtime = FloeAgentRuntime(
            configuration: configuration(firstEventTimeout: 0.02),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: MockExecutor(),
            checkpointStore: MockCheckpointStore(),
            sink: sink
        )

        try await runtime.start(goal: "watch the first packet")

        let errorEvents = sink.events.withLock { events in
            events.filter { event in
                if case .error = event { return true }
                return false
            }
        }
        let liveness = await runtime.liveness()
        let attempt = await runtime.providerAttempt()
        XCTAssertTrue(errorEvents.isEmpty)
        XCTAssertEqual(adapter.callCount, 2)
        XCTAssertEqual(liveness.phase, .completed)
        XCTAssertEqual(attempt?.attempt, 2)
    }

    func testRepeatedSilentAttemptsStopWithOneTerminalError() async throws {
        for transportTimesOut in [false, true] {
            let adapter = SilentFirstAttemptsAdapter(
                silentAttempts: 2, transportTimesOut: transportTimesOut)
            let sink = MockSink()
            let runtime = FloeAgentRuntime(
                configuration: configuration(
                    maxProviderRetries: 5, firstEventTimeout: 0.02),
                adapter: adapter,
                policy: HumanApprovalPolicy(),
                executor: MockExecutor(),
                checkpointStore: MockCheckpointStore(),
                sink: sink
            )

            try await runtime.start(goal: "bound silent retries")

            let errorEvents = sink.events.withLock { events in
                events.filter { event in
                    if case .error = event { return true }
                    return false
                }
            }
            let liveness = await runtime.liveness()
            let attempt = await runtime.providerAttempt()
            XCTAssertEqual(adapter.callCount, 2)
            XCTAssertEqual(errorEvents.count, 1)
            XCTAssertEqual(attempt?.status, .exhausted)
            XCTAssertEqual(liveness.phase, .failed)
        }
    }

    // MARK: - Watchdog does not own the finalization boundary

    func testCompletedTurnSurvivesFinalizationDependencyWait() async throws {
        // The provider has terminally completed (its dispatch envelope is
        // cleared), then the runtime legitimately awaits outstanding
        // dependencies. The idle watchdog must not remain armed across that
        // non-provider wait; otherwise it turns the successful turn into a
        // spurious "stalled"/failed run.
        let adapter = MockAdapter()
        adapter.script.withLock {
            $0 = [[
                .textDelta(.init(text: "answer")),
                .completed(.init(stopReason: .endTurn))
            ]]
        }
        var config = configuration(
            maxProviderRetries: 0,
            firstEventTimeout: 1,
            outstandingDependencies: {
                try? await Task.sleep(for: .milliseconds(300))
                return []
            }
        )
        config.providerStreamIdleTimeout = 0.03
        config.providerReasoningIdleTimeout = 0.03
        let runtime = FloeAgentRuntime(
            configuration: config,
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: MockExecutor(),
            checkpointStore: MockCheckpointStore()
        )

        try await runtime.start(goal: "finish without a provider wait")

        let liveness = await runtime.liveness()
        let state = await runtime.state
        XCTAssertEqual(liveness.phase, .completed)
        XCTAssertEqual(state.name, "completed")
        XCTAssertEqual(adapter.requests.withLock { $0.count }, 1)
    }

    // MARK: - Fixtures

    private func configuration(
        conversationID: UUID = UUID(),
        maxProviderRetries: Int = 2,
        firstEventTimeout: TimeInterval = 30,
        outstandingDependencies: (@Sendable () async -> [RunDependencyLabel])? = nil
    ) -> FloeAgentRuntime.Configuration {
        let provider = ProviderProfile(
            kind: .openAI,
            wireProtocol: .openAIResponses,
            baseURL: URL(string: "http://127.0.0.1")!,
            displayName: "Recovery fixture",
            isEnabled: true,
            allowsPlainHTTP: true
        )
        return FloeAgentRuntime.Configuration(
            conversationID: conversationID,
            provider: provider,
            model: ModelProfile(
                providerID: provider.id,
                remoteModelID: "recovery-fixture",
                displayName: "Recovery fixture",
                limits: ModelLimits(contextTokens: 128_000, maxOutputTokens: 8_192),
                capabilities: [.text, .tools]
            ),
            maxProviderRetries: maxProviderRetries,
            providerFirstEventTimeout: firstEventTimeout,
            providerStreamIdleTimeout: 30,
            providerRetryBaseDelay: 0,
            providerRetryMaxDelay: 0,
            providerRetryJitterRatio: 0,
            outstandingDependencies: outstandingDependencies
        )
    }
}

// MARK: - Test doubles

/// Lock-guarded box; `NSLock` is `Sendable`, so the box needs no actor hop
/// for the tiny critical sections these fixtures use.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

private final class MockAdapter: ProviderAdapter, @unchecked Sendable {
    let protocolKind: ModelProtocol = .openAIResponses
    let requests = Locked<[ProviderStreamRequest]>([])
    let script = Locked<[[AgentEvent]]>([])

    func stream(
        request: ProviderStreamRequest,
        credentials: ProviderCredentials
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        requests.withLock { $0.append(request) }
        let events = script.withLock { pending -> [AgentEvent] in
            pending.isEmpty ? [] : pending.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func listModels(
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> [ModelProfile] { [] }
}

/// Keeps the configured number of requests completely silent (watchdog
/// timeout) or fails them with a transport timeout before any event, then
/// answers normally.
private final class SilentFirstAttemptsAdapter: ProviderAdapter, @unchecked Sendable {
    let protocolKind: ModelProtocol = .openAIResponses
    private let calls = Locked(0)
    private let silentAttempts: Int
    private let transportTimesOut: Bool

    init(silentAttempts: Int = 1, transportTimesOut: Bool = false) {
        self.silentAttempts = silentAttempts
        self.transportTimesOut = transportTimesOut
    }

    var callCount: Int { calls.withLock { $0 } }

    func stream(
        request: ProviderStreamRequest,
        credentials: ProviderCredentials
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        let call = calls.withLock { value -> Int in
            value += 1
            return value
        }
        if call <= silentAttempts {
            return AsyncThrowingStream { continuation in
                if transportTimesOut {
                    continuation.finish(throwing: URLError(.timedOut))
                    return
                }
                let task = Task {
                    try? await Task.sleep(for: .seconds(60))
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta(.init(text: "watchdog recovered")))
            continuation.yield(.completed(.init(stopReason: .endTurn)))
            continuation.finish()
        }
    }

    func listModels(
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> [ModelProfile] { [] }
}

private final class MockSink: AgentEventSink, @unchecked Sendable {
    let events = Locked<[AgentEvent]>([])
    let states = Locked<[AgentState]>([])

    func agentRuntime(_ runtime: FloeAgentRuntime,
                      didTransitionTo state: AgentState) async {
        states.withLock { $0.append(state) }
    }

    func agentRuntime(_ runtime: FloeAgentRuntime,
                      didEmit event: AgentEvent) async {
        events.withLock { $0.append(event) }
    }

    func agentRuntime(_ runtime: FloeAgentRuntime,
                      didChangeLiveness snapshot: AgentLivenessSnapshot) async {}
    func agentRuntime(_ runtime: FloeAgentRuntime,
                      didChangeProviderAttempt snapshot: ProviderAttemptSnapshot) async {}
    func agentRuntime(_ runtime: FloeAgentRuntime,
                      didCompleteAssistantStep text: String) async {}
    func agentRuntime(_ runtime: FloeAgentRuntime,
                      didConsumeSteer input: RuntimeSteerInput) async {}
    func agentRuntime(_ runtime: FloeAgentRuntime,
                      didConsumeLifecycleNotice notice: RuntimeLifecycleNotice) async {}
    func agentRuntime(_ runtime: FloeAgentRuntime,
                      didCompact record: ContextCompactionRecord) async {}
    func agentRuntime(_ runtime: FloeAgentRuntime,
                      didChangeApprovalReview snapshot: ApprovalReviewSnapshot) async {}
    func agentRuntime(_ runtime: FloeAgentRuntime,
                      didRecordApprovalDecision receipt: ApprovalDecisionReceipt) async {}
    func agentRuntime(_ runtime: FloeAgentRuntime,
                      didDispatchToolCall call: ToolCall,
                      at stamp: ToolTimingStamp) async {}
    func agentRuntime(_ runtime: FloeAgentRuntime,
                      didFinishToolCall call: ToolCall,
                      result: ToolResult,
                      at stamp: ToolTimingStamp) async {}
}

private final class MockExecutor: ToolExecutor, @unchecked Sendable {
    let descriptors = Locked<[String: ToolCatalog.Descriptor]>([:])
    let executedCalls = Locked<[ToolCall]>([])

    func execute(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        executedCalls.withLock { $0.append(call) }
        return ToolResult(
            callID: call.id,
            status: .ok,
            outputSummary: "ok",
            outputDigest: "digest"
        )
    }

    func execute(
        _ call: ToolCall,
        expectedAuthorizationIdentity: String?,
        context: ToolContext
    ) async throws -> ToolResult {
        try await execute(call, context: context)
    }

    func descriptor(named name: String) -> ToolCatalog.Descriptor? {
        descriptors.withLock { $0[name] }
    }

    var allDescriptors: [ToolCatalog.Descriptor] {
        descriptors.withLock { Array($0.values) }
    }
}

private final class MockCheckpointStore: CheckpointStore, @unchecked Sendable {
    let saved = Locked<[AgentCheckpoint]>([])

    func save(_ checkpoint: AgentCheckpoint) async throws {
        saved.withLock { $0.append(checkpoint) }
    }

    func load(runID: UUID) async throws -> AgentCheckpoint? {
        saved.withLock { $0.last(where: { $0.runID == runID }) }
    }
}
