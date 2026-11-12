// SPDX-License-Identifier: MPL-2.0
//
// n03-recovery112: recovered-call replay admission versus new device
// navigation. These regressions drive the REAL AgentRuntime restore,
// repair and tool-batch settlement protocol with a synthetic provider,
// executor and checkpoint store:
//   * a new launch with equal arguments after an intervening Home in a
//     resumed run must reach the executor;
//   * a regenerated completed original call at the restored boundary still
//     reuses its prior evidence;
//   * a dispatched-but-uncommitted call stays an unknown outcome even when
//     the same route completed on an earlier turn;
//   * pre-rename `phone.act` completed/unknown receipts still match the
//     canonical `device.act` route through the ONE closed alias authority,
//     while unrelated `phone.*` names are not broadened;
//   * synthetic recovery answers never become fresh execution evidence and
//     never nest "Prior evidence:" across repeated recoveries;
//   * cancellation still owns the approval/terminal boundary.
// Synthetic fixtures only; no provider network, no device and no ADB.
// AUTHORED, NOT EXECUTED — native/object compilation and the unified
// candidate test run stay with the primary coordinator.
import XCTest
import Foundation
import FloeCore
import FloeModels
import FloeProviders
import FloePersistence
import FloeSecurity
import FloeTools
@testable import FloeAgentRuntime
@testable import FloeAndroidCore

final class RecoveryReplayAdmissionTests: XCTestCase {
    private var root: URL!
    private var checkpoints: FileCheckpointStore!
    private var conversationID = UUID()
    private let profile = ProviderProfile(
        kind: .openAI,
        wireProtocol: .openAIChatCompletions,
        baseURL: URL(string: "https://fixtures.invalid/v1")!
    )

    private var model: ModelProfile {
        ModelProfile(
            providerID: profile.id,
            remoteModelID: "recovery-replay-fixture",
            displayName: "Recovery Replay Fixture",
            limits: ModelLimits(contextTokens: 16_000, maxOutputTokens: 2_048),
            capabilities: [.text, .tools]
        )
    }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("recovery-replay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        checkpoints = FileCheckpointStore(directory: root.appendingPathComponent("checkpoints"))
        conversationID = UUID()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    private func launchCall(
        id: String,
        toolName: String = RecoveryReplayFixture.launchTool
    ) throws -> ToolCall {
        try ToolCall(
            id: id,
            toolName: toolName,
            argumentsJSON: Data(
                #"{"action":"launch","packageName":"com.samsung.android.calendar"}"#.utf8
            ),
            scope: .local
        )
    }

    private func homeCall(
        id: String,
        toolName: String = RecoveryReplayFixture.launchTool
    ) throws -> ToolCall {
        try ToolCall(
            id: id,
            toolName: toolName,
            argumentsJSON: Data(#"{"action":"home"}"#.utf8),
            scope: .local
        )
    }

    private func observeCall(id: String) throws -> ToolCall {
        try ToolCall(
            id: id,
            toolName: RecoveryReplayFixture.observeTool,
            argumentsJSON: Data("{}".utf8),
            scope: .local
        )
    }

    /// Builds one real ledger record through production logic. The ledger
    /// fingerprint is internal, so fixtures never hand-roll matching bytes.
    private func completedLedger(
        call: ToolCall,
        excerpt: String
    ) -> [AgentExecutionLedgerEntry] {
        var ledger = HarnessExecutionLedger()
        ledger.record(
            call: call,
            result: ToolResult(
                callID: call.id,
                status: .ok,
                outputSummary: excerpt,
                outputDigest: ""
            ),
            isSideEffecting: true
        )
        return ledger.checkpointRecords()
    }

    /// Builds one real unknown-outcome receipt through production logic.
    private func unknownLedger(call: ToolCall) -> [AgentExecutionLedgerEntry] {
        var ledger = HarnessExecutionLedger()
        ledger.record(
            call: call,
            result: ToolResult(
                callID: call.id,
                status: .failed,
                outputSummary: "interrupted after dispatch",
                outputDigest: ""
            ),
            isSideEffecting: true,
            outcomeUnknown: true,
            outcomeUnknownReason: .interruptedDispatch
        )
        return ledger.checkpointRecords()
    }

    private func checkpoint(
        runID: UUID,
        ledgerEntries: [AgentExecutionLedgerEntry],
        pendingCalls: [ToolCall] = [],
        pendingResults: [ToolResult] = [],
        lifecycle: [AgentToolLifecycleEntry] = []
    ) -> AgentCheckpoint {
        AgentCheckpoint(
            runID: runID,
            conversationID: conversationID,
            state: .preparing(.init(goal: "Continue the recovered demo.")),
            messages: [.init(role: "user", content: "Continue the recovered demo.")],
            pendingToolCalls: pendingCalls,
            pendingToolResults: pendingResults,
            executionLedgerEntries: ledgerEntries,
            toolLifecycleEntries: lifecycle.isEmpty ? nil : lifecycle
        )
    }

    private func makeRuntime(
        runID: UUID,
        provider: any ProviderAdapter,
        executor: any ToolExecutor,
        policy: any ApprovalPolicy,
        sink: any AgentEventSink
    ) -> FloeAgentRuntime {
        FloeAgentRuntime(
            configuration: .init(
                conversationID: conversationID,
                provider: profile,
                model: model,
                maxProviderRetries: 0
            ),
            adapter: provider,
            policy: policy,
            executor: executor,
            checkpointStore: checkpoints,
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

    // MARK: - 1. A new equal-argument navigation after Home must execute

    func testNewLaunchAfterInterveningHomeInResumedRunReachesExecutor() async throws {
        let runID = UUID()
        let prior = try launchCall(id: "call-prior-launch")
        let firstRetry = try launchCall(id: "call-retry-launch-1")
        let home = try homeCall(id: "call-home")
        let secondRetry = try launchCall(id: "call-retry-launch-2")
        let provider = ScriptedRecoveryProvider([
            [.toolRequest(firstRetry), .completed(.init(stopReason: .endTurn))],
            [.toolRequest(home), .completed(.init(stopReason: .endTurn))],
            [.toolRequest(secondRetry), .completed(.init(stopReason: .endTurn))],
            [.textDelta(.init(text: "Recovered demo complete.")), .completed(.init(stopReason: .endTurn))],
        ])
        let executor = RecoveryReplayExecutor()
        let sink = RecordingReplaySink()
        let runtime = makeRuntime(
            runID: runID,
            provider: provider,
            executor: executor,
            policy: AllowRecoveryReplayPolicy(),
            sink: sink
        )
        let saved = checkpoint(
            runID: runID,
            ledgerEntries: completedLedger(
                call: prior,
                excerpt: "action=launch dispatch=ACCEPTED call=\(prior.id)"
            )
        )

        try await runtime.resume(from: saved)

        XCTAssertEqual(
            executor.executedCallIDs,
            [home.id, secondRetry.id],
            "only the restored boundary may treat an equal-argument launch as a replay; after Home the launch is a new navigation"
        )
        let firstValue = await sink.result(callID: firstRetry.id)
        let first = try XCTUnwrap(firstValue)
        XCTAssertTrue(first.outputSummary.hasPrefix(
            "Skipped duplicate completed tool call after recovery."
        ))
        XCTAssertTrue(first.outputSummary.contains(
            "Prior evidence: action=launch dispatch=ACCEPTED call=\(prior.id)"
        ))
        XCTAssertEqual(first.outputDigest, "")
        let secondValue = await sink.result(callID: secondRetry.id)
        let second = try XCTUnwrap(secondValue)
        XCTAssertEqual(second.status, .ok)
        XCTAssertFalse(second.outputSummary.contains("Skipped duplicate"))

        let loadedValue = try await checkpoints.load(runID: runID)
        let loaded = try XCTUnwrap(loadedValue)
        let entries = try XCTUnwrap(loaded.executionLedgerEntries)
        XCTAssertFalse(entries.contains {
            $0.excerpt.hasPrefix("Skipped duplicate completed tool call after recovery.")
        }, "a synthetic replay answer must never be stored as execution evidence")
        XCTAssertTrue(entries.contains {
            $0.excerpt.contains("call=\(secondRetry.id)")
        }, "the real post-Home launch must be the recorded evidence")
    }

    // MARK: - 2. A regenerated completed original call still reuses evidence

    func testCompletedOriginalCallReplayAtRestoreBoundaryReusesPriorEvidence() async throws {
        let runID = UUID()
        let prior = try launchCall(id: "call-prior-launch")
        let retry = try launchCall(id: "call-regenerated-launch")
        let provider = ScriptedRecoveryProvider([
            [.toolRequest(retry), .completed(.init(stopReason: .endTurn))],
            [.textDelta(.init(text: "Done.")), .completed(.init(stopReason: .endTurn))],
        ])
        let executor = RecoveryReplayExecutor()
        let sink = RecordingReplaySink()
        let runtime = makeRuntime(
            runID: runID,
            provider: provider,
            executor: executor,
            policy: AllowRecoveryReplayPolicy(),
            sink: sink
        )
        let original = "action=launch dispatch=ACCEPTED call=\(prior.id)"
        try await runtime.resume(
            from: checkpoint(runID: runID, ledgerEntries: completedLedger(call: prior, excerpt: original))
        )

        XCTAssertEqual(executor.executionCount, 0)
        let value = await sink.result(callID: retry.id)
        let result = try XCTUnwrap(value)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.outputSummary.hasPrefix(
            "Skipped duplicate completed tool call after recovery."
        ))
        XCTAssertTrue(result.outputSummary.hasSuffix("Prior evidence: \(original)"))

        let loadedValue = try await checkpoints.load(runID: runID)
        let loaded = try XCTUnwrap(loadedValue)
        let entries = try XCTUnwrap(loaded.executionLedgerEntries)
        XCTAssertEqual(entries.count, 1, "the synthetic replay answer must not be appended")
        XCTAssertEqual(entries.first?.excerpt, original)
    }

    // MARK: - 3. Repeated recovery never nests Prior evidence

    func testRepeatedRecoveryOfTheSameCompletedCallDoesNotNestPriorEvidence() async throws {
        let runID = UUID()
        let prior = try launchCall(id: "call-prior-launch")
        let original = "action=launch dispatch=ACCEPTED call=\(prior.id)"
        let firstRetry = try launchCall(id: "call-regenerated-1")
        let firstProvider = ScriptedRecoveryProvider([
            [.toolRequest(firstRetry), .completed(.init(stopReason: .endTurn))],
            [.textDelta(.init(text: "Done.")), .completed(.init(stopReason: .endTurn))],
        ])
        let firstRuntime = makeRuntime(
            runID: runID,
            provider: firstProvider,
            executor: RecoveryReplayExecutor(),
            policy: AllowRecoveryReplayPolicy(),
            sink: RecordingReplaySink()
        )
        try await firstRuntime.resume(
            from: checkpoint(runID: runID, ledgerEntries: completedLedger(call: prior, excerpt: original))
        )

        // Resume from the checkpoint the first recovered activation really
        // wrote, without its last provider-dispatch snapshot so the fixture
        // exercises a normal rebuilt request boundary.
        let firstCheckpoint = try await checkpoints.load(runID: runID)
        var resumed = try XCTUnwrap(firstCheckpoint)
        resumed.providerDispatchEnvelope = nil
        resumed.providerDispatchRequest = nil
        resumed.pendingAssistantReasoning = nil
        resumed.state = .preparing(.init(goal: "Continue the recovered demo."))

        let secondRetry = try launchCall(id: "call-regenerated-2")
        let secondProvider = ScriptedRecoveryProvider([
            [.toolRequest(secondRetry), .completed(.init(stopReason: .endTurn))],
            [.textDelta(.init(text: "Done.")), .completed(.init(stopReason: .endTurn))],
        ])
        let executor = RecoveryReplayExecutor()
        let sink = RecordingReplaySink()
        let secondRuntime = makeRuntime(
            runID: runID,
            provider: secondProvider,
            executor: executor,
            policy: AllowRecoveryReplayPolicy(),
            sink: sink
        )
        try await secondRuntime.resume(from: resumed)

        XCTAssertEqual(executor.executionCount, 0)
        let value = await sink.result(callID: secondRetry.id)
        let result = try XCTUnwrap(value)
        XCTAssertEqual(
            result.outputSummary.components(
                separatedBy: "Skipped duplicate completed tool call after recovery."
            ).count - 1,
            1,
            "the synthetic prefix must stay single-layered across recoveries"
        )
        XCTAssertEqual(
            result.outputSummary.components(separatedBy: "Prior evidence:").count - 1,
            1
        )
        XCTAssertTrue(result.outputSummary.hasSuffix("Prior evidence: \(original)"))

        let loadedValue = try await checkpoints.load(runID: runID)
        let loaded = try XCTUnwrap(loadedValue)
        let entries = try XCTUnwrap(loaded.executionLedgerEntries)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.excerpt, original)
    }

    // MARK: - 4. Dispatched-but-uncommitted stays an unknown outcome

    func testDispatchedPendingCallStaysUnknownEvenWhenRouteCompletedBefore() async throws {
        let runID = UUID()
        let prior = try launchCall(id: "call-prior-launch")
        let inFlight = try launchCall(id: "call-inflight-launch")
        let retry = try launchCall(id: "call-after-unknown")
        let provider = ScriptedRecoveryProvider([
            [.toolRequest(retry), .completed(.init(stopReason: .endTurn))],
            [.textDelta(.init(text: "Stopping after the unknown outcome.")), .completed(.init(stopReason: .endTurn))],
        ])
        let executor = RecoveryReplayExecutor()
        let sink = RecordingReplaySink()
        let runtime = makeRuntime(
            runID: runID,
            provider: provider,
            executor: executor,
            policy: AllowRecoveryReplayPolicy(),
            sink: sink
        )
        let saved = checkpoint(
            runID: runID,
            ledgerEntries: completedLedger(
                call: prior,
                excerpt: "action=launch dispatch=ACCEPTED call=\(prior.id)"
            ),
            pendingCalls: [inFlight],
            lifecycle: [.init(
                callID: inFlight.id,
                toolName: inFlight.toolName,
                isSideEffecting: true,
                phase: .dispatched
            )]
        )

        try await runtime.resume(from: saved)

        XCTAssertEqual(executor.executionCount, 0)
        let inFlightValue = await sink.result(callID: inFlight.id)
        let interrupted = try XCTUnwrap(inFlightValue)
        XCTAssertEqual(interrupted.status, .failed)
        XCTAssertTrue(interrupted.outputSummary.contains("interrupted after dispatch"))
        XCTAssertFalse(interrupted.outputSummary.contains("Skipped duplicate completed"))

        let retryValue = await sink.result(callID: retry.id)
        let suppressed = try XCTUnwrap(retryValue)
        XCTAssertEqual(suppressed.status, .failed)
        XCTAssertTrue(suppressed.outputSummary.contains("Harness suppression"))
        XCTAssertFalse(suppressed.outputSummary.contains("Skipped duplicate completed"))

        let loadedValue = try await checkpoints.load(runID: runID)
        let loaded = try XCTUnwrap(loadedValue)
        let entries = try XCTUnwrap(loaded.executionLedgerEntries)
        XCTAssertTrue(entries.contains {
            $0.resultFingerprint.hasPrefix(HarnessExecutionLedger.unknownInterruptedFingerprintPrefix)
        })
        XCTAssertFalse(entries.contains {
            $0.excerpt.hasPrefix("Skipped duplicate completed tool call after recovery.")
        })
    }

    // MARK: - 5. A recorded-but-never-dispatched replay is not execution

    func testRecordedButNeverDispatchedReplayReusesEvidenceWithoutBecomingExecution() async throws {
        let runID = UUID()
        let prior = try launchCall(id: "call-prior-launch")
        let pending = try launchCall(id: "call-recorded-launch")
        let provider = ScriptedRecoveryProvider([
            [.textDelta(.init(text: "Done.")), .completed(.init(stopReason: .endTurn))],
        ])
        let executor = RecoveryReplayExecutor()
        let sink = RecordingReplaySink()
        let runtime = makeRuntime(
            runID: runID,
            provider: provider,
            executor: executor,
            policy: AllowRecoveryReplayPolicy(),
            sink: sink
        )
        let original = "action=launch dispatch=ACCEPTED call=\(prior.id)"
        let saved = checkpoint(
            runID: runID,
            ledgerEntries: completedLedger(call: prior, excerpt: original),
            pendingCalls: [pending],
            lifecycle: [.init(
                callID: pending.id,
                toolName: pending.toolName,
                isSideEffecting: true,
                phase: .recorded
            )]
        )

        try await runtime.resume(from: saved)

        XCTAssertEqual(executor.executionCount, 0)
        let value = await sink.result(callID: pending.id)
        let result = try XCTUnwrap(value)
        XCTAssertTrue(result.outputSummary.hasPrefix(
            "Skipped duplicate completed tool call after recovery."
        ))
        XCTAssertTrue(result.outputSummary.hasSuffix("Prior evidence: \(original)"))

        let loadedValue = try await checkpoints.load(runID: runID)
        let loaded = try XCTUnwrap(loadedValue)
        let entries = try XCTUnwrap(loaded.executionLedgerEntries)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.excerpt, original)
    }

    // MARK: - 6. Cancellation still owns an approval-parked new operation

    func testCancellationAfterFreshObservationPreventsEqualRouteFromSlippingThrough() async throws {
        let runID = UUID()
        let prior = try launchCall(id: "call-prior-launch")
        let observation = try observeCall(id: "call-fresh-observe")
        let launch = try launchCall(id: "call-new-launch")
        let provider = ScriptedRecoveryProvider([
            [.toolRequest(observation), .completed(.init(stopReason: .endTurn))],
            [.toolRequest(launch), .completed(.init(stopReason: .endTurn))],
        ])
        let executor = RecoveryReplayExecutor()
        let sink = RecordingReplaySink()
        let runtime = makeRuntime(
            runID: runID,
            provider: provider,
            executor: executor,
            policy: EscalateRecoveryReplayPolicy(),
            sink: sink
        )
        let saved = checkpoint(
            runID: runID,
            ledgerEntries: completedLedger(
                call: prior,
                excerpt: "action=launch dispatch=ACCEPTED call=\(prior.id)"
            )
        )
        let task = Task {
            try await runtime.resume(from: saved)
        }
        let parked = await waitUntil {
            let current = await runtime.state
            return current.name == "waitingApproval"
        }
        guard parked else {
            await runtime.cancel()
            try await task.value
            return XCTFail("the post-observation equal-argument launch never reached approval")
        }
        await runtime.cancel()
        try await task.value

        XCTAssertEqual(
            executor.executedCallIDs,
            [observation.id],
            "cancellation must prevent the pending new launch from executing"
        )
        let state = await runtime.state
        XCTAssertEqual(state.name, "checkpointed")
    }

    // MARK: - 7. Legacy phone.act receipts protect canonical device.act

    func testLegacyPhoneActCompletionProtectsCanonicalDeviceActAndNewNavigationStaysLive() async throws {
        let runID = UUID()
        let prior = try launchCall(id: "call-prior-phone", toolName: "phone.act")
        let firstRetry = try launchCall(
            id: "call-retry-device-1", toolName: RecoveryReplayFixture.deviceActTool
        )
        let home = try homeCall(
            id: "call-home-device", toolName: RecoveryReplayFixture.deviceActTool
        )
        let secondRetry = try launchCall(
            id: "call-retry-device-2", toolName: RecoveryReplayFixture.deviceActTool
        )
        let priorEvidence = "action=launch dispatch=ACCEPTED tool=phone.act call=\(prior.id)"
        let provider = ScriptedRecoveryProvider([
            [.toolRequest(firstRetry), .completed(.init(stopReason: .endTurn))],
            [.toolRequest(home), .completed(.init(stopReason: .endTurn))],
            [.toolRequest(secondRetry), .completed(.init(stopReason: .endTurn))],
            [.textDelta(.init(text: "Recovered demo complete.")), .completed(.init(stopReason: .endTurn))],
        ])
        let executor = RecoveryReplayExecutor()
        let sink = RecordingReplaySink()
        let runtime = makeRuntime(
            runID: runID,
            provider: provider,
            executor: executor,
            policy: AllowRecoveryReplayPolicy(),
            sink: sink
        )
        try await runtime.resume(
            from: checkpoint(
                runID: runID,
                ledgerEntries: completedLedger(call: prior, excerpt: priorEvidence)
            )
        )

        XCTAssertEqual(
            executor.executedCallIDs,
            [home.id, secondRetry.id],
            "the pre-rename receipt must protect the first canonical retry, but a post-Home navigation is new work"
        )
        let firstValue = await sink.result(callID: firstRetry.id)
        let first = try XCTUnwrap(firstValue)
        XCTAssertTrue(first.outputSummary.hasPrefix(
            "Skipped duplicate completed tool call after recovery."
        ))
        XCTAssertTrue(first.outputSummary.hasSuffix("Prior evidence: \(priorEvidence)"))

        let loadedValue = try await checkpoints.load(runID: runID)
        let loaded = try XCTUnwrap(loadedValue)
        let entries = try XCTUnwrap(loaded.executionLedgerEntries)
        XCTAssertTrue(entries.contains {
            $0.excerpt.contains("call=\(secondRetry.id)")
        }, "the intentional post-Home canonical launch must execute and be recorded")
        XCTAssertFalse(entries.contains {
            $0.excerpt.hasPrefix("Skipped duplicate completed tool call after recovery.")
        })
    }

    // MARK: - 8. A legacy phone.act unknown receipt still suppresses

    func testLegacyPhoneActUnknownOutcomeSuppressesCanonicalDeviceActRetry() async throws {
        let runID = UUID()
        let legacyInFlight = try launchCall(id: "call-phone-unknown", toolName: "phone.act")
        let retry = try launchCall(
            id: "call-retry-device-unknown", toolName: RecoveryReplayFixture.deviceActTool
        )
        let provider = ScriptedRecoveryProvider([
            [.toolRequest(retry), .completed(.init(stopReason: .endTurn))],
            [.textDelta(.init(text: "Stopping after the unknown outcome.")), .completed(.init(stopReason: .endTurn))],
        ])
        let executor = RecoveryReplayExecutor()
        let sink = RecordingReplaySink()
        let runtime = makeRuntime(
            runID: runID,
            provider: provider,
            executor: executor,
            policy: AllowRecoveryReplayPolicy(),
            sink: sink
        )
        let saved = checkpoint(
            runID: runID,
            ledgerEntries: unknownLedger(call: legacyInFlight)
        )

        try await runtime.resume(from: saved)

        XCTAssertEqual(executor.executionCount, 0)
        let value = await sink.result(callID: retry.id)
        let result = try XCTUnwrap(value)
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.outputSummary.contains("Harness suppression"))
        XCTAssertFalse(result.outputSummary.contains("Skipped duplicate completed"))

        let loadedValue = try await checkpoints.load(runID: runID)
        let loaded = try XCTUnwrap(loadedValue)
        let entries = try XCTUnwrap(loaded.executionLedgerEntries)
        XCTAssertTrue(entries.contains {
            $0.toolName == "phone.act"
                && $0.resultFingerprint.hasPrefix(
                    HarnessExecutionLedger.unknownInterruptedFingerprintPrefix
                )
        }, "the historical receipt keeps its original spelling in the checkpoint")
    }

    // MARK: - 9. The closed alias authority is symmetric and not broadened

    func testClosedAliasAuthorityMatchesBothDirectionsWithoutBroadeningNames() throws {
        let legacyCall = try launchCall(id: "call-legacy-phone", toolName: "phone.act")
        let canonicalCall = try launchCall(
            id: "call-canonical-device", toolName: RecoveryReplayFixture.deviceActTool
        )
        func successResult(_ call: ToolCall) -> ToolResult {
            ToolResult(
                callID: call.id, status: .ok,
                outputSummary: "action=launch dispatch=ACCEPTED", outputDigest: ""
            )
        }

        var legacyLedger = HarnessExecutionLedger()
        legacyLedger.record(
            call: legacyCall, result: successResult(legacyCall), isSideEffecting: true
        )
        XCTAssertNotNil(legacyLedger.recoveredResult(for: canonicalCall, isSideEffecting: true))

        var canonicalLedger = HarnessExecutionLedger()
        canonicalLedger.record(
            call: canonicalCall, result: successResult(canonicalCall), isSideEffecting: true
        )
        XCTAssertNotNil(canonicalLedger.recoveredResult(for: legacyCall, isSideEffecting: true))

        // A checkpoint written before the effect bit existed must still treat
        // the legacy device action as a mutation.
        let sourceRecord = try XCTUnwrap(legacyLedger.checkpointRecords().first)
        let legacyRecord = AgentExecutionLedgerEntry(
            toolName: "phone.act",
            callFingerprint: sourceRecord.callFingerprint,
            status: sourceRecord.status,
            resultFingerprint: sourceRecord.resultFingerprint,
            excerpt: sourceRecord.excerpt,
            occurrenceCount: sourceRecord.occurrenceCount,
            isSideEffecting: nil
        )
        let restored = HarnessExecutionLedger(records: [legacyRecord])
        XCTAssertNotNil(restored.recoveredResult(for: canonicalCall, isSideEffecting: true))

        // Unknown-outcome receipts use the same identity for suppression and
        // for reconcile dissolution.
        var unknownReceipts = HarnessExecutionLedger()
        unknownReceipts.record(
            call: legacyCall,
            result: ToolResult(
                callID: legacyCall.id, status: .failed,
                outputSummary: "interrupted after dispatch", outputDigest: ""
            ),
            isSideEffecting: true,
            outcomeUnknown: true,
            outcomeUnknownReason: .interruptedDispatch
        )
        XCTAssertNotNil(unknownReceipts.suppressedUnknownOutcomeResult(
            for: canonicalCall, isSideEffecting: true
        ))
        var reconciled = unknownReceipts
        reconciled.dissolveUnknownOutcomeReceipt(matching: canonicalCall)
        XCTAssertNil(reconciled.suppressedUnknownOutcomeResult(
            for: legacyCall, isSideEffecting: true
        ))

        // Unrelated/unknown phone.* names never enter the closed alias set.
        let stranger = try launchCall(id: "call-phone-stranger", toolName: "phone.teleport")
        XCTAssertNil(legacyLedger.recoveredResult(for: stranger, isSideEffecting: true))
        XCTAssertNil(unknownReceipts.suppressedUnknownOutcomeResult(
            for: stranger, isSideEffecting: true
        ))
    }

    // MARK: - 10. A legacy synthetic record never nests directly

    func testLegacySyntheticLedgerRecordQuotesInnermostEvidence() throws {
        let call = try launchCall(id: "call-legacy")
        var ledger = HarnessExecutionLedger()
        ledger.record(
            call: call,
            result: ToolResult(
                callID: call.id,
                status: .ok,
                outputSummary: "Skipped duplicate completed tool call after recovery. Prior evidence: action=launch dispatch=ACCEPTED",
                outputDigest: ""
            ),
            isSideEffecting: true
        )
        let firstValue = ledger.recoveredResult(for: call, isSideEffecting: true)
        let first = try XCTUnwrap(firstValue)
        let secondValue = ledger.recoveredResult(for: call, isSideEffecting: true)
        let second = try XCTUnwrap(secondValue)
        XCTAssertEqual(first.outputSummary, second.outputSummary)
        XCTAssertEqual(
            second.outputSummary.components(
                separatedBy: "Skipped duplicate completed tool call after recovery."
            ).count - 1,
            1
        )
        XCTAssertTrue(second.outputSummary.hasSuffix(
            "Prior evidence: action=launch dispatch=ACCEPTED"
        ))
    }

    // MARK: - 11. Synthetic receipts are not committed steps

    func testSyntheticReplayReceiptIsNotACommittedApprovalStep() throws {
        let call = try launchCall(id: "call-synthetic-step")
        var ledger = HarnessExecutionLedger()
        ledger.record(
            call: call,
            result: ToolResult(
                callID: call.id,
                status: .ok,
                outputSummary: "Skipped duplicate completed tool call after recovery. Prior evidence: action=launch dispatch=ACCEPTED",
                outputDigest: ""
            ),
            isSideEffecting: true
        )
        let steps = FloeAgentRuntime.approvalCommittedSteps(
            from: ledger.entries, redactingSecret: nil
        )
        XCTAssertTrue(steps.isEmpty)
        let prompt = ledger.promptBlock()
        XCTAssertFalse(prompt?.contains("Skipped duplicate") == true)
        XCTAssertTrue(prompt?.contains("No structured tool call has executed") == true)
    }
}

// MARK: - Synthetic fixture catalog (never registered globally)

private enum RecoveryReplayFixture {
    static let launchTool = "fixture.recovery.launch"
    static let observeTool = "fixture.recovery.observe"
    /// The real canonical device-action name. The fixture executor resolves
    /// both `device.act` and the closed legacy `phone.act` spelling to this
    /// descriptor, mirroring the production registry's alias lookup.
    static let deviceActTool = "device.act"

    static func descriptor(for name: String) -> ToolCatalog.Descriptor? {
        switch ToolAliasTable.canonical(name) {
        case launchTool:
            return ToolCatalog.Descriptor(
                name: launchTool,
                toolDescription: "Synthetic calendar launch/home action",
                riskLabels: [.writesFiles],
                isSideEffecting: true
            )
        case observeTool:
            return ToolCatalog.Descriptor(
                name: observeTool,
                toolDescription: "Synthetic device observation",
                riskLabels: [],
                isSideEffecting: false
            )
        case deviceActTool:
            return ToolCatalog.Descriptor(
                name: deviceActTool,
                toolDescription: "Synthetic canonical device action",
                riskLabels: [.writesFiles],
                isSideEffecting: true
            )
        default:
            return nil
        }
    }
}

// MARK: - Test doubles (synthetic; no network or device)

private final class ScriptedRecoveryProvider: ProviderAdapter, @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [[AgentEvent]]
    private var captured: [ProviderStreamRequest] = []

    init(_ scripts: [[AgentEvent]]) {
        self.scripts = scripts
    }

    var requests: [ProviderStreamRequest] { lock.withLock { captured } }
    var protocolKind: ModelProtocol { .openAIChatCompletions }

    func stream(
        request: ProviderStreamRequest,
        credentials: ProviderCredentials
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        let events = lock.withLock { () -> [AgentEvent] in
            captured.append(request)
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

private final class RecoveryReplayExecutor: ToolExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [ToolCall] = []

    var executedCallIDs: [String] { lock.withLock { calls.map(\.id) } }
    var executionCount: Int { lock.withLock { calls.count } }

    var allDescriptors: [ToolCatalog.Descriptor] {
        [
            RecoveryReplayFixture.descriptor(for: RecoveryReplayFixture.launchTool),
            RecoveryReplayFixture.descriptor(for: RecoveryReplayFixture.observeTool),
            RecoveryReplayFixture.descriptor(for: RecoveryReplayFixture.deviceActTool),
        ].compactMap { $0 }
    }

    func descriptor(named name: String) -> ToolCatalog.Descriptor? {
        RecoveryReplayFixture.descriptor(for: name)
    }

    func execute(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        lock.withLock { calls.append(call) }
        let object = try? JSONSerialization.jsonObject(with: call.argumentsJSON)
        let action = (object as? [String: Any])?["action"] as? String ?? "observe"
        return ToolResult(
            callID: call.id,
            status: .ok,
            outputSummary: "action=\(action) dispatch=ACCEPTED call=\(call.id)",
            outputDigest: ""
        )
    }
}

private actor RecordingReplaySink: AgentEventSink {
    private var results: [ToolResult] = []

    func result(callID: String) -> ToolResult? {
        results.first { $0.callID == callID }
    }

    func agentRuntime(_ runtime: FloeAgentRuntime, didTransitionTo state: AgentState) async {}

    func agentRuntime(_ runtime: FloeAgentRuntime, didEmit event: AgentEvent) async {
        if case .toolResult(let result) = event { results.append(result) }
    }
}

private struct AllowRecoveryReplayPolicy: ApprovalPolicy {
    var policyName: String { "recovery-replay-allow" }

    func decide(_ action: ProposedAction) async throws -> ApprovalDecision {
        .allow(scope: ApprovalScope(toolName: action.toolCall.toolName), expiresAt: nil)
    }
}

private struct EscalateRecoveryReplayPolicy: ApprovalPolicy {
    var policyName: String { "recovery-replay-escalate" }

    func decide(_ action: ProposedAction) async throws -> ApprovalDecision {
        .escalateToHuman(reason: "synthetic recovery replay approval")
    }
}
