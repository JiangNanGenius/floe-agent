// FloeAgentRuntimeTests — R3: unknown-outcome receipts carry an honest reason
// category, and only narrowly-typed, evidence-backed lifecycle reconciliation
// can dissolve them. Arbitrary commands and unknown paid submits stay
// inhibited; the overflow sentinel is never reconciled.

import Foundation
import Testing
@testable import FloeAgentRuntime
@testable import FloeProviders
@testable import FloeModels
@testable import FloeSecurity
@testable import FloeTools
@testable import FloeCore
import FloeTestSupport

@Suite("FloeAgentRuntime.UnknownOutcomeReconciliation")
struct UnknownOutcomeReconciliationTests {

    private let startLinuxCall = try! TestFixtures.toolCall(
        id: "start-1",
        toolName: "environment.startLinux",
        arguments: #"{"vcpus":2,"memoryMB":512}"#
    )
    private let shellCall = try! TestFixtures.toolCall(
        id: "shell-1",
        toolName: "exec.shell",
        arguments: #"{"command":"make install"}"#
    )

    private func interruptedResult(for call: ToolCall) -> ToolResult {
        ToolResult(
            callID: call.id,
            status: .failed,
            outputSummary: "Execution was interrupted after dispatch but before its result was committed. The real-world outcome is unknown. Inspect current external state before deciding whether any action should be retried; the real-world outcome is unknown.",
            outputDigest: ""
        )
    }

    private func ledgerWithReceipts() -> HarnessExecutionLedger {
        var ledger = HarnessExecutionLedger()
        ledger.record(
            call: startLinuxCall,
            result: interruptedResult(for: startLinuxCall),
            isSideEffecting: true,
            outcomeUnknown: true,
            outcomeUnknownReason: .interruptedDispatch
        )
        ledger.record(
            call: shellCall,
            result: interruptedResult(for: shellCall),
            isSideEffecting: true,
            outcomeUnknown: true,
            outcomeUnknownReason: .interruptedDispatch
        )
        return ledger
    }

    @Test("suppression wording distinguishes interrupted dispatch from capability removal")
    func suppressionWordingIsReasonCategorized() {
        var ledger = HarnessExecutionLedger()
        ledger.record(
            call: startLinuxCall,
            result: interruptedResult(for: startLinuxCall),
            isSideEffecting: true,
            outcomeUnknown: true,
            outcomeUnknownReason: .interruptedDispatch
        )
        let interrupted = ledger.suppressedUnknownOutcomeResult(for: startLinuxCall, isSideEffecting: true)
        let interruptedText = try! #require(interrupted?.outputSummary)
        #expect(interruptedText.contains("interrupted"))
        #expect(interruptedText.contains("app relaunch or suspension"))
        #expect(interruptedText.contains("was not executed again"))
        #expect(interruptedText.contains("Escape paths"))

        var removedLedger = HarnessExecutionLedger()
        removedLedger.record(
            call: startLinuxCall,
            result: interruptedResult(for: startLinuxCall),
            isSideEffecting: true,
            outcomeUnknown: true,
            outcomeUnknownReason: .capabilityRemoved
        )
        let removed = removedLedger.suppressedUnknownOutcomeResult(for: startLinuxCall, isSideEffecting: true)
        let removedText = try! #require(removed?.outputSummary)
        #expect(removedText.contains("capability was removed or replaced"))
        #expect(!removedText.contains("app relaunch"))
    }

    @Test("the reason category round-trips through checkpoint records")
    func reasonRoundTripsThroughCheckpoint() {
        let ledger = ledgerWithReceipts()
        let records = ledger.checkpointRecords()
        #expect(records.contains { $0.resultFingerprint.hasPrefix("unknown-outcome:interrupted:") })
        let restored = HarnessExecutionLedger(records: records)
        let verdict = restored.suppressedUnknownOutcomeResult(for: startLinuxCall, isSideEffecting: true)
        let text = try! #require(verdict?.outputSummary)
        #expect(text.contains("interrupted"))
        // A legacy unattributed prefix still suppresses with the generic wording.
        var legacy = HarnessExecutionLedger()
        legacy.record(
            call: startLinuxCall,
            result: interruptedResult(for: startLinuxCall),
            isSideEffecting: true,
            outcomeUnknown: true
        )
        let legacyText = try! #require(legacy.suppressedUnknownOutcomeResult(for: startLinuxCall, isSideEffecting: true)?.outputSummary)
        #expect(legacyText.contains("unknown real-world outcome"))
        #expect(legacyText.contains("interrupted mid-flight or its capability removed"))
    }

    private struct AllowStartLinux: UnknownOutcomeReconciler {
        func reconcileUnknownOutcome(
            receipt: UnknownOutcomeReceipt,
            retryCall: ToolCall
        ) async -> UnknownOutcomeReconciliation {
            guard receipt.toolName == "environment.startLinux" else { return .suppressed }
            return .reconciled(explanation: "fixture: quietly stopped, saved shape matches")
        }
    }

    private struct StrictReconciler: UnknownOutcomeReconciler {
        func reconcileUnknownOutcome(
            receipt: UnknownOutcomeReceipt,
            retryCall: ToolCall
        ) async -> UnknownOutcomeReconciliation { .suppressed }
    }

    @Test("a typed reconciler dissolves only the matching lifecycle receipt")
    func reconcilerDissolvesOnlyMatchingReceipt() async {
        var ledger = ledgerWithReceipts()
        switch await ledger.unknownOutcomeVerdict(
            for: startLinuxCall,
            isSideEffecting: true,
            reconciler: AllowStartLinux()
        ) {
        case .reconciled(let explanation):
            #expect(explanation.contains("quietly stopped"))
        default:
            Issue.record("expected the startLinux receipt to be reconciled")
        }
        // Dissolved: a second verdict no longer finds a receipt.
        ledger.dissolveUnknownOutcomeReceipt(matching: startLinuxCall)
        let second = await ledger.unknownOutcomeVerdict(
            for: startLinuxCall,
            isSideEffecting: true,
            reconciler: AllowStartLinux()
        )
        if case .noReceipt = second {} else {
            Issue.record("expected the receipt to be dissolved after reconciliation")
        }
        // Dissolving is idempotent and never touches other receipts.
        ledger.dissolveUnknownOutcomeReceipt(matching: startLinuxCall)
        let shellVerdict = await ledger.unknownOutcomeVerdict(
            for: shellCall,
            isSideEffecting: true,
            reconciler: AllowStartLinux()
        )
        guard case .suppressed(let result) = shellVerdict else {
            Issue.record("expected the exec.shell route to stay suppressed")
            return
        }
        #expect(result.outputSummary.contains("was not executed again"))
    }

    @Test("a strict reconciler keeps every receipt suppressed")
    func strictReconcilerSuppressesEverything() async {
        let ledger = ledgerWithReceipts()
        let verdict = await ledger.unknownOutcomeVerdict(
            for: startLinuxCall,
            isSideEffecting: true,
            reconciler: StrictReconciler()
        )
        guard case .suppressed = verdict else {
            Issue.record("expected suppression with a strict reconciler")
            return
        }
        // Without any reconciler the behavior is unchanged suppression.
        let bare = ledgerWithReceipts()
        let bareVerdict = await bare.unknownOutcomeVerdict(
            for: startLinuxCall,
            isSideEffecting: true,
            reconciler: nil
        )
        guard case .suppressed = bareVerdict else {
            Issue.record("expected suppression without a reconciler")
            return
        }
    }

    @Test("a capability-removed or unattributed receipt is never reconciled")
    func nonInterruptedReceiptsAreNeverReconciled() async {
        // Quiet, matching external state can only settle "the app relaunched
        // mid-flight". It says nothing about a capability removed while
        // executing, and a legacy unattributed receipt stays strict.
        for reason in [UnknownOutcomeReason.capabilityRemoved, .unattributed] {
            var ledger = HarnessExecutionLedger()
            ledger.record(
                call: startLinuxCall,
                result: interruptedResult(for: startLinuxCall),
                isSideEffecting: true,
                outcomeUnknown: true,
                outcomeUnknownReason: reason
            )
            let verdict = await ledger.unknownOutcomeVerdict(
                for: startLinuxCall,
                isSideEffecting: true,
                reconciler: AllowStartLinux()
            )
            guard case .suppressed(let result) = verdict else {
                Issue.record("expected a \(reason) receipt to stay suppressed even with an allow reconciler")
                return
            }
            #expect(result.outputSummary.contains("was not executed again"))
        }
    }

    @Test("the overflow sentinel is never reconciled")
    func overflowSentinelIsNeverReconciled() async {
        var ledger = HarnessExecutionLedger()
        for index in 0..<14 {
            let call = try! TestFixtures.toolCall(
                id: "unknown-\(index)",
                toolName: "test.mutate",
                arguments: #"{"value":\#(index)}"#
            )
            ledger.record(
                call: call,
                result: interruptedResult(for: call),
                isSideEffecting: true,
                outcomeUnknown: true,
                outcomeUnknownReason: .interruptedDispatch
            )
        }
        #expect(ledger.hasUnknownOutcomeOverflow)
        let verdict = await ledger.unknownOutcomeVerdict(
            for: try! TestFixtures.toolCall(id: "x", toolName: "test.write", arguments: #"{"v":"y"}"#),
            isSideEffecting: true,
            reconciler: AllowStartLinux()
        )
        guard case .suppressed(let result) = verdict else {
            Issue.record("expected the overflow sentinel to stay suppressed even with a reconciler")
            return
        }
        #expect(result.outputSummary.contains("exceeded their bounded ledger"))
    }

    // MARK: - Runtime-level interrupted-dispatch bridge

    private func makeInterruptedCheckpoint() -> AgentCheckpoint {
        let ledger = ledgerWithReceipts()
        return AgentCheckpoint(
            runID: UUID(),
            conversationID: UUID(),
            state: .preparing(.init(goal: "recover the interrupted start")),
            messages: [ConversationMessage(role: "user", content: "recover the interrupted start")],
            pendingToolCalls: [startLinuxCall],
            pendingToolResults: [],
            executionLedgerEntries: ledger.checkpointRecords(),
            toolLifecycleEntries: [AgentToolLifecycleEntry(
                callID: startLinuxCall.id,
                toolName: startLinuxCall.toolName,
                isSideEffecting: true,
                phase: .dispatched
            )]
        )
    }

    private func makeRuntime(
        adapter: MockAdapter,
        registry: ToolRunnerRegistry,
        reconciler: (any UnknownOutcomeReconciler)?,
        executions: AsyncLock<Int>
    ) -> FloeAgentRuntime {
        registry.register(AnyAgentTool(
            descriptor: ToolCatalog.Descriptor(
                name: "environment.startLinux",
                riskLabels: [],
                isSideEffecting: true
            )
        ) { _, _ in
            executions.withLock { $0 += 1 }
            return .init(summary: "started", fullOutputSHA256: "started-digest")
        })
        let provider = TestFixtures.localhostProvider()
        return FloeAgentRuntime(
            configuration: .init(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                maxToolSteps: 20,
                unknownOutcomeReconciler: reconciler
            ),
            adapter: adapter,
            policy: ModelApprovalPolicy(backend: RecordingApprovalBackend()),
            executor: CatalogToolExecutor(runners: registry),
            checkpointStore: MockCheckpointStore()
        )
    }

    private func resumeScript() throws -> (MockAdapter, ToolCall) {
        // A recovered provider re-emits the same ROUTE with a FRESH call id
        // (the repaired original pair stays committed under its own id).
        let retry = try TestFixtures.toolCall(
            id: "start-2",
            toolName: "environment.startLinux",
            arguments: #"{"vcpus":2,"memoryMB":512}"#
        )
        let adapter = MockAdapter()
        adapter.script = [
            [.toolRequest(retry)],
            [.completed(.init(stopReason: .endTurn))]
        ]
        return (adapter, retry)
    }

    @Test("an interrupted startLinux retry is suppressed until authoritative evidence reconciles it")
    func interruptedStartIsSuppressedThenReconciledAtRuntime() async throws {
        let checkpoint = makeInterruptedCheckpoint()

        // Case 1 — no reconciler: the same-route retry is suppressed before
        // the executor and the model sees the interrupted-dispatch wording.
        let executions = AsyncLock(0)
        let (firstAdapter, _) = try resumeScript()
        let first = makeRuntime(
            adapter: firstAdapter,
            registry: ToolRunnerRegistry(),
            reconciler: nil,
            executions: executions
        )
        try await first.resume(from: checkpoint)
        #expect(executions.withLock { $0 } == 0)
        #expect(firstAdapter.requests.contains { request in
            request.toolResults.contains { $0.output.contains("was interrupted") }
        })

        // Case 2 — a typed reconciler with authoritative evidence dissolves
        // the receipt and the retry executes through the normal path.
        let reconciledExecutions = AsyncLock(0)
        let (secondAdapter, _) = try resumeScript()
        let second = makeRuntime(
            adapter: secondAdapter,
            registry: ToolRunnerRegistry(),
            reconciler: AllowStartLinux(),
            executions: reconciledExecutions
        )
        try await second.resume(from: checkpoint)
        #expect(reconciledExecutions.withLock { $0 } == 1)
        #expect(secondAdapter.requests.contains { request in
            request.toolResults.contains { $0.output.contains("started") }
        })

        // Case 3 — a strict reconciler keeps the suppression.
        let strictExecutions = AsyncLock(0)
        let (thirdAdapter, _) = try resumeScript()
        let third = makeRuntime(
            adapter: thirdAdapter,
            registry: ToolRunnerRegistry(),
            reconciler: StrictReconciler(),
            executions: strictExecutions
        )
        try await third.resume(from: checkpoint)
        #expect(strictExecutions.withLock { $0 } == 0)
    }

    @Test("an arbitrary shell command with an unknown-outcome receipt stays inhibited even when startLinux is allowed")
    func arbitraryCommandStaysInhibitedBesideReconciledStart() async throws {
        let checkpoint = makeInterruptedCheckpoint()
        let executions = AsyncLock(0)
        let adapter = MockAdapter()
        adapter.script = [
            [.toolRequest(shellCall)],
            [.completed(.init(stopReason: .endTurn))]
        ]
        let provider = TestFixtures.localhostProvider()
        let registry = ToolRunnerRegistry()
        registry.register(AnyAgentTool(
            descriptor: ToolCatalog.Descriptor(
                name: "exec.shell",
                riskLabels: [],
                isSideEffecting: true
            )
        ) { _, _ in
            executions.withLock { $0 += 1 }
            return .init(summary: "ran", fullOutputSHA256: "ran-digest")
        })
        let runtime = FloeAgentRuntime(
            configuration: .init(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                maxToolSteps: 20,
                unknownOutcomeReconciler: AllowStartLinux()
            ),
            adapter: adapter,
            policy: ModelApprovalPolicy(backend: RecordingApprovalBackend()),
            executor: CatalogToolExecutor(runners: registry),
            checkpointStore: MockCheckpointStore()
        )

        try await runtime.resume(from: checkpoint)

        #expect(executions.withLock { $0 } == 0)
        #expect(adapter.requests.contains { request in
            request.toolResults.contains { $0.output.contains("was not executed again") }
        })
    }
}
