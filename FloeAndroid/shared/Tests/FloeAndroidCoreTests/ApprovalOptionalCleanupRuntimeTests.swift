// SPDX-License-Identifier: MPL-2.0
//
// n08 optional-cleanup corrective opportunity, runtime-level regressions.
// These drive the REAL FloeAgentRuntime tool-resolution, denial settlement
// and provider-loop protocol with a synthetic provider, executor and sink:
//   * the first unrequested destructive cleanup is never dispatched, its
//     result is an honest non-dispatched denial, and the safe follow-up
//     command completes in the same run without a human approval card;
//   * an explicitly user-authorized deletion still parks the exact call on
//     the normal human approval surface, a genuine deny is settled, and a
//     late allow after completion cannot revive the call;
//   * manual Always Ask keeps the human card even for a command that the
//     automatic model-reviewed path would hand back with a replan.
// Synthetic fixtures only; no provider network, device, shell, ADB or App
// run. AUTHORED, NOT EXECUTED — compilation and the unified test run stay
// with the primary coordinator.

import XCTest
import Foundation
import FloeCore
import FloeModels
import FloeProviders
import FloePersistence
import FloeSecurity
import FloeTools
@testable import FloeAgentRuntime

final class ApprovalOptionalCleanupRuntimeTests: XCTestCase {
    private let profile = ProviderProfile(
        kind: .openAI,
        wireProtocol: .openAIChatCompletions,
        baseURL: URL(string: "https://fixtures.invalid/v1")!
    )

    private var model: ModelProfile {
        ModelProfile(
            providerID: profile.id,
            remoteModelID: "optional-cleanup-fixture",
            displayName: "Optional Cleanup Fixture",
            limits: ModelLimits(contextTokens: 16_000, maxOutputTokens: 1_024),
            capabilities: [.text, .tools]
        )
    }

    private func cleanupCall() throws -> ToolCall {
        try ToolCall(
            id: "call-optional-cleanup",
            toolName: "exec.shell",
            argumentsJSON: Data(
                #"{"command":"cd /workspace/demo_event && ls -la && rm -rf '{sources,images' 2>/dev/null; mkdir -p sources images/raw images/posters"}"#.utf8
            ),
            scope: .local
        )
    }

    private func safeSetupCall() throws -> ToolCall {
        try ToolCall(
            id: "call-safe-setup",
            toolName: "exec.shell",
            argumentsJSON: Data(
                #"{"command":"mkdir -p sources images/raw images/processed poster video docs"}"#.utf8
            ),
            scope: .local
        )
    }

    private func makeRuntime(
        provider: any ProviderAdapter,
        executor: any ToolExecutor,
        policy: any ApprovalPolicy,
        sink: any AgentEventSink,
        runID: UUID = UUID()
    ) -> FloeAgentRuntime {
        FloeAgentRuntime(
            configuration: .init(
                conversationID: UUID(),
                provider: profile,
                model: model,
                maxProviderRetries: 0,
                localLinuxShellTarget: true
            ),
            adapter: provider,
            // Production wraps the task policy in the dynamic reference so a
            // composer mode change can be observed; exercise that exact path.
            policy: DynamicApprovalPolicy(policy),
            executor: executor,
            sink: sink,
            runID: runID
        )
    }

    private func waitUntil(
        timeoutSeconds: Double = 6,
        _ predicate: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await predicate()
    }

    // MARK: - 1. Unrequested cleanup is not dispatched; safe work continues

    func testUnrequestedCleanupDenialLetsSafeSetupCompleteWithoutApproval() async throws {
        let cleanup = try cleanupCall()
        let safe = try safeSetupCall()
        let provider = ScriptedCleanupProvider([
            [.toolRequest(cleanup), .completed(.init(stopReason: .endTurn))],
            [.toolRequest(safe), .completed(.init(stopReason: .endTurn))],
            [.textDelta(.init(text: "Created the event folders.")), .completed(.init(stopReason: .endTurn))],
        ])
        let executor = CleanupReplanExecutor()
        let sink = CleanupReplanSink()
        let runtime = makeRuntime(
            provider: provider,
            executor: executor,
            policy: CleanupEscalationPolicy(),
            sink: sink
        )

        try await runtime.start(goal: "Prepare a Sydney event folder with sources, images, a poster, video and docs.")

        XCTAssertEqual(executor.executedCallIDs, [safe.id], "the destructive cleanup must never reach the executor")
        let deniedValue = await sink.result(callID: cleanup.id)
        let denied = try XCTUnwrap(deniedValue)
        XCTAssertEqual(denied.status, .denied)
        XCTAssertTrue(denied.outputSummary.contains(LocalGuestCleanupReplan.denialMarker))
        XCTAssertTrue(denied.outputSummary.contains("NOT dispatched"))
        let safeValue = await sink.result(callID: safe.id)
        let safeResult = try XCTUnwrap(safeValue)
        XCTAssertEqual(safeResult.status, .ok)
        let sawWaiting = await sink.sawWaitingApproval
        XCTAssertFalse(sawWaiting, "the corrective path must not publish a human approval card")
        let state = await runtime.state
        XCTAssertEqual(state.name, "completed")
    }

    func testLateAllowAfterReplanDenialCannotAuthorizeTheCleanup() async throws {
        let cleanup = try cleanupCall()
        let safe = try safeSetupCall()
        let provider = ScriptedCleanupProvider([
            [.toolRequest(cleanup), .completed(.init(stopReason: .endTurn))],
            [.toolRequest(safe), .completed(.init(stopReason: .endTurn))],
            [.textDelta(.init(text: "Created the event folders.")), .completed(.init(stopReason: .endTurn))],
        ])
        let executor = CleanupReplanExecutor()
        let sink = CleanupReplanSink()
        let runtime = makeRuntime(
            provider: provider,
            executor: executor,
            policy: CleanupEscalationPolicy(),
            sink: sink
        )

        try await runtime.start(goal: "Prepare a Sydney event folder with sources, images, a poster, video and docs.")

        let accepted = await runtime.resolveApproval(
            .allow(scope: ApprovalScope(toolName: cleanup.toolName), expiresAt: nil),
            for: cleanup.id
        )
        XCTAssertFalse(accepted, "no approval gate exists for a call the runtime already settled as a denial")
        XCTAssertEqual(executor.executedCallIDs, [safe.id])
    }

    // MARK: - 2. Genuine user authority still reaches the exact human card

    func testAuthorizedDeletionParksForExactHumanDecisionAndSettlesDeny() async throws {
        let cleanup = try cleanupCall()
        let provider = ScriptedCleanupProvider([
            [.toolRequest(cleanup), .completed(.init(stopReason: .endTurn))],
            [.textDelta(.init(text: "I left the existing folder untouched.")), .completed(.init(stopReason: .endTurn))],
        ])
        let executor = CleanupReplanExecutor()
        let sink = CleanupReplanSink()
        let runtime = makeRuntime(
            provider: provider,
            executor: executor,
            policy: CleanupEscalationPolicy(),
            sink: sink
        )

        let runTask = Task {
            try await runtime.start(goal: "Delete the old demo_event folder, then recreate the required sources and images folders.")
        }
        let parked = await waitUntil {
            await runtime.state.name == "waitingApproval"
        }
        XCTAssertTrue(parked, "an explicitly user-authorized deletion must keep the normal human approval card")
        let sawWaiting = await sink.sawWaitingApproval
        XCTAssertTrue(sawWaiting)
        XCTAssertTrue(executor.executedCallIDs.isEmpty, "nothing may be dispatched while the exact call waits for the user")

        let accepted = await runtime.resolveApproval(.deny(reason: "user declined"), for: cleanup.id)
        XCTAssertTrue(accepted)
        try await runTask.value

        let deniedValue = await sink.result(callID: cleanup.id)
        let denied = try XCTUnwrap(deniedValue)
        XCTAssertEqual(denied.status, .denied)
        XCTAssertTrue(denied.outputSummary.contains("user declined"))
        XCTAssertTrue(executor.executedCallIDs.isEmpty, "a genuine deny must never be rerouted into execution")
    }

    // MARK: - 3. Manual Always Ask is unchanged

    func testManualAlwaysAskKeepsTheHumanCard() async throws {
        let cleanup = try cleanupCall()
        let provider = ScriptedCleanupProvider([
            [.toolRequest(cleanup), .completed(.init(stopReason: .endTurn))],
            [.textDelta(.init(text: "Stopped.")), .completed(.init(stopReason: .endTurn))],
        ])
        let executor = CleanupReplanExecutor()
        let sink = CleanupReplanSink()
        let runtime = makeRuntime(
            provider: provider,
            executor: executor,
            policy: HumanApprovalPolicy(),
            sink: sink
        )

        let runTask = Task {
            try await runtime.start(goal: "Prepare a Sydney event folder with sources, images and docs.")
        }
        let parked = await waitUntil {
            await runtime.state.name == "waitingApproval"
        }
        XCTAssertTrue(parked, "manual Always Ask must not gain the automatic corrective path")
        let sawWaiting = await sink.sawWaitingApproval
        XCTAssertTrue(sawWaiting)
        XCTAssertTrue(executor.executedCallIDs.isEmpty)

        _ = await runtime.resolveApproval(.deny(reason: "user declined"), for: cleanup.id)
        try await runTask.value
        XCTAssertTrue(executor.executedCallIDs.isEmpty)
    }
}

// MARK: - Synthetic fixtures (never registered globally)

private final class ScriptedCleanupProvider: ProviderAdapter, @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [[AgentEvent]]

    init(_ scripts: [[AgentEvent]]) {
        self.scripts = scripts
    }

    var protocolKind: ModelProtocol { .openAIChatCompletions }

    func stream(
        request: ProviderStreamRequest,
        credentials: ProviderCredentials
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        let events = lock.withLock { () -> [AgentEvent] in
            guard !scripts.isEmpty else {
                return [.completed(.init(stopReason: .endTurn))]
            }
            return scripts.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    func listModels(
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> [ModelProfile] { [] }
}

private final class CleanupReplanExecutor: ToolExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [ToolCall] = []

    var executedCallIDs: [String] { lock.withLock { calls.map(\.id) } }

    private let shellDescriptor = ToolCatalog.Descriptor(
        name: "exec.shell",
        toolDescription: "Synthetic local guest shell",
        riskLabels: [.executesLocalCode, .deletesFiles],
        isSideEffecting: true
    )

    var allDescriptors: [ToolCatalog.Descriptor] { [shellDescriptor] }

    func descriptor(named name: String) -> ToolCatalog.Descriptor? {
        name == "exec.shell" ? shellDescriptor : nil
    }

    func execute(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        lock.withLock { calls.append(call) }
        return ToolResult(
            callID: call.id,
            status: .ok,
            outputSummary: "synthetic exec.shell completed",
            outputDigest: ""
        )
    }
}

private actor CleanupReplanSink: AgentEventSink {
    private var results: [ToolResult] = []
    private var transitions: [String] = []

    var sawWaitingApproval: Bool { transitions.contains("waitingApproval") }

    func result(callID: String) -> ToolResult? {
        results.first { $0.callID == callID }
    }

    func agentRuntime(_ runtime: FloeAgentRuntime, didTransitionTo state: AgentState) async {
        transitions.append(state.name)
    }

    func agentRuntime(_ runtime: FloeAgentRuntime, didEmit event: AgentEvent) async {
        if case .toolResult(let result) = event { results.append(result) }
    }
}

/// Automatic-mode reviewer fixture: asks about the destructive command and
/// allows ordinary setup. The production policy keeps its real classifier;
/// only the decision shape is synthetic.
private struct CleanupEscalationPolicy: ApprovalPolicy, ApprovalReviewRouting {
    var policyName: String { "approval-model" }

    func decide(_ action: ProposedAction) async throws -> ApprovalDecision {
        let object = try? JSONSerialization.jsonObject(with: action.toolCall.argumentsJSON) as? [String: Any]
        let command = object?["command"] as? String ?? ""
        if command.contains("rm -rf") {
            return .escalateToHuman(reason: "synthetic reviewer asked about the delete")
        }
        return .allow(
            scope: ApprovalScope(toolName: action.toolCall.toolName),
            expiresAt: nil
        )
    }

    func requiresModelReview(_ action: ProposedAction) -> Bool { true }
}
