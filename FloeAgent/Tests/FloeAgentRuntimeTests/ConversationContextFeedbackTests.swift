// FloeAgentRuntimeTests — typed context-compression and tool-outcome feedback.
//
// These tests cover the production projection seam, not a parallel feedback
// system:
//  * the runtime's `didChangeContextCompression` sink reaches the service
//    snapshot with the real phase (failure, sizing, overflow recovery,
//    compaction, schema reduction) and never invents a different one;
//  * a late callback from an older turn or a finished run cannot overwrite a
//    newer honest phase;
//  * the runtime's `didClassifyToolOutcome` sink reaches the snapshot keyed by
//    the exact call id and does not change loop/terminal semantics.
//
// The App-side generation fence that applies these values to the inline status
// is deliberately not exercised here: ThreadDetailViewModel belongs to the App
// target. Its source-level guard is covered by static review; the Primary runs
// the App-hosted tests after the freeze.

import Foundation
import Testing
@testable import FloeAgentRuntime
@testable import FloeProviders
@testable import FloeModels
@testable import FloeSecurity
@testable import FloeTools
@testable import FloeCore
@testable import FloePersistence
import FloeTestSupport

@Suite("FloeAgentRuntime.ConversationContextFeedback")
struct ConversationContextFeedbackTests {

    private struct ProbeFailure: Error {}

    /// A context engine that fails exactly where a real summarizer/provider
    /// failure surfaces: `prepareContext`. `compact` fails too so no path can
    /// silently degrade into a fake success.
    private struct FailingContextEngine: ContextEngine {
        func prepareContext(for request: ContextRequest) async throws -> PreparedContext {
            throw ProbeFailure()
        }

        func observeUsage(_ usage: UsageSnapshot) async {}

        func compact(_ request: CompactionRequest) async throws -> CompactionResult {
            throw ProbeFailure()
        }
    }

    private func makeService(
        conversationID: UUID,
        adapter: MockAdapter,
        executor: MockExecutor = MockExecutor(),
        contextEngine: (any ContextEngine)? = HybridContextEngine()
    ) async throws -> (service: ConversationRunService, conversations: SQLiteConversationStore, runs: SQLiteRunStore) {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let conversations = SQLiteConversationStore(database: database)
        let runs = SQLiteRunStore(database: database)
        try await conversations.saveConversation(ConversationRecord(
            id: conversationID,
            title: "Context feedback",
            createdAt: Date(),
            updatedAt: Date()
        ))
        let provider = TestFixtures.localhostProvider()
        let service = ConversationRunService(
            configuration: .init(
                conversationID: conversationID,
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                providerRetryBaseDelay: 0,
                providerRetryMaxDelay: 0
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: executor,
            contextEngine: contextEngine,
            conversationStore: conversations,
            runStore: runs
        )
        return (service: service, conversations: conversations, runs: runs)
    }

    @Test("A real compaction failure reaches the snapshot as failed, never as compacted")
    func compactionFailureIsForwarded() async throws {
        let adapter = MockAdapter()
        adapter.script = [[
            .textDelta(.init(text: "The answer still goes out.")),
            .completed(.init(stopReason: .endTurn))
        ]]
        let (service, _, _) = try await makeService(
            conversationID: UUID(),
            adapter: adapter,
            contextEngine: FailingContextEngine()
        )

        try await service.start(goal: "Keep going after a compaction failure")

        let snapshot = await service.snapshot()
        #expect(snapshot.isTerminal)
        #expect(snapshot.stateName == "completed")
        #expect(snapshot.contextCompression?.phase == .failed)
        #expect(snapshot.contextCompression?.reason?.isEmpty == false)
        // A failure did not replace history, so no compacted token pair may be
        // fabricated and no message count may claim a replacement.
        #expect(snapshot.contextCompression?.afterTokens == nil)
        #expect(snapshot.contextCompression?.compactedMessageCount == 0)
    }

    @Test("A late compression callback after terminal cannot revive compaction")
    func lateCompressionAfterTerminalIsIgnored() async throws {
        let adapter = MockAdapter()
        adapter.script = [[
            .textDelta(.init(text: "Done.")),
            .completed(.init(stopReason: .endTurn))
        ]]
        let (service, _, _) = try await makeService(conversationID: UUID(), adapter: adapter)
        try await service.start(goal: "Finish before the late callback")

        let terminalSnapshot = await service.snapshot()
        #expect(terminalSnapshot.isTerminal)
        let storedPhase = terminalSnapshot.contextCompression?.phase
        #expect(storedPhase == .sizing)

        // A late callback from the finished run must not overwrite the last
        // real phase with an active-compaction indicator.
        await service.handleContextCompression(ContextCompressionSnapshot(
            phase: .compacting,
            beforeTokens: 1_000,
            at: Date().addingTimeInterval(60)
        ))
        let afterLate = await service.snapshot()
        #expect(afterLate.contextCompression?.phase == storedPhase)
        #expect(afterLate.contextCompression?.phase != .compacting)
    }

    @Test("A resource-wait tool outcome is forwarded by call id without changing completion")
    func toolOutcomeClassificationIsForwarded() async throws {
        let call = try TestFixtures.toolCall(id: "waiting-job")
        let adapter = MockAdapter()
        adapter.script = [
            [.toolRequest(call)],
            [.textDelta(.init(text: "The job is still running.")), .completed(.init(stopReason: .endTurn))]
        ]
        let executor = MockExecutor()
        executor.descriptors[call.toolName] = ToolCatalog.Descriptor(
            name: call.toolName,
            riskLabels: [],
            isSideEffecting: false
        )
        executor.results = [ToolResult(
            callID: call.id,
            status: .failed,
            outputSummary: "The background job is still running; try again after it finishes.",
            outputDigest: "fixture-digest"
        )]
        let (service, _, runs) = try await makeService(
            conversationID: UUID(),
            adapter: adapter,
            executor: executor
        )

        try await service.start(goal: "Check the background job")

        let snapshot = await service.snapshot()
        // Presentation classification never changes the run's real terminal
        // state: the tool genuinely failed, the loop continued, and the run
        // completed only because the model produced a final answer.
        #expect(snapshot.stateName == "completed")
        #expect(snapshot.lastToolOutcome?.kind == .waitingForResource)
        #expect(snapshot.lastToolOutcome?.recovery == .waitForResource)
        #expect(snapshot.toolOutcome(callID: call.id)?.callID == call.id)
        #expect(snapshot.toolOutcome(callID: "never-settled") == nil)

        // The classification is presentation truth about a settled FAILED
        // result; it must never rewrite the durable result into a success.
        let events = try await runs.recentEvents(runID: service.runID, limit: 50)
        let resultEvent = try #require(events.last(where: { $0.kind == .toolResult }))
        let payload = try JSONDecoder().decode(
            [String: String].self,
            from: Data(resultEvent.payloadJSON.utf8)
        )
        #expect(payload["status"] == ToolResult.Status.failed.rawValue)
        #expect(payload["id"] == call.id)
    }

    @Test("Compression phases stay distinct and an older snapshot cannot regress them")
    func compressionPhasesStayDistinct() async throws {
        let (service, _, _) = try await makeService(conversationID: UUID(), adapter: MockAdapter())
        let base = Date()

        await service.handleContextCompression(ContextCompressionSnapshot(
            phase: .sizing,
            beforeTokens: 90_000,
            availableInputTokens: 100_000,
            at: base
        ))
        #expect(await service.snapshot().contextCompression?.phase == .sizing)

        await service.handleContextCompression(ContextCompressionSnapshot(
            phase: .schemasReduced,
            reason: "fixture schema reduction",
            toolSchemaTokens: 4_000,
            at: base.addingTimeInterval(1)
        ))
        var snapshot = await service.snapshot()
        #expect(snapshot.contextCompression?.phase == .schemasReduced)
        // A schema-only reduction is not a history replacement.
        #expect(snapshot.contextCompression?.compactedMessageCount == 0)

        await service.handleContextCompression(ContextCompressionSnapshot(
            phase: .overflowRecovery,
            reason: "fixture provider overflow",
            at: base.addingTimeInterval(2)
        ))
        await service.handleContextCompression(ContextCompressionSnapshot(
            phase: .compacting,
            beforeTokens: 90_000,
            at: base.addingTimeInterval(3)
        ))
        await service.handleContextCompression(ContextCompressionSnapshot(
            phase: .compacted,
            beforeTokens: 90_000,
            afterTokens: 30_000,
            availableInputTokens: 100_000,
            compactedMessageCount: 7,
            at: base.addingTimeInterval(4)
        ))
        snapshot = await service.snapshot()
        #expect(snapshot.contextCompression?.phase == .compacted)
        #expect(snapshot.contextCompression?.beforeTokens == 90_000)
        #expect(snapshot.contextCompression?.afterTokens == 30_000)
        #expect(snapshot.contextCompression?.compactedMessageCount == 7)
        // The projection itself is not a terminal state change.
        #expect(!snapshot.isTerminal)

        // A delayed snapshot from an older turn carries an older emission
        // stamp; it must not replace the verified compacted phase.
        await service.handleContextCompression(ContextCompressionSnapshot(
            phase: .compacting,
            beforeTokens: 90_000,
            at: base.addingTimeInterval(2.5)
        ))
        snapshot = await service.snapshot()
        #expect(snapshot.contextCompression?.phase == .compacted)
        #expect(snapshot.contextCompression?.afterTokens == 30_000)
    }

    @Test("Settled outcomes are bounded and keep the exact call identity")
    func recentOutcomesAreBoundedAndCorrelated() async throws {
        let (service, _, _) = try await makeService(conversationID: UUID(), adapter: MockAdapter())
        for index in 0..<40 {
            await service.handleToolOutcomeClassification(ToolOutcomeClassification(
                callID: "call-\(index)",
                toolName: "test.echo",
                status: "failed",
                kind: .waitingForResource,
                recovery: .waitForResource,
                reason: "fixture waiting"
            ))
        }
        let snapshot = await service.snapshot()
        #expect(snapshot.recentToolOutcomes.count == 32)
        #expect(snapshot.lastToolOutcome?.callID == "call-39")
        #expect(snapshot.toolOutcome(callID: "call-39") != nil)
        // The oldest entries were evicted, not retained without bound.
        #expect(snapshot.toolOutcome(callID: "call-0") == nil)
    }
}
