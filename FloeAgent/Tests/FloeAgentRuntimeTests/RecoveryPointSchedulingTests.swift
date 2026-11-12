// FloeAgentRuntimeTests — recovery-point scheduling.
//
// A provider turn's streamed text/reasoning is deliberately NOT part of a
// checkpoint: the runtime only persists committed messages, pending tool
// pairs and the exact dispatch boundary. Scheduling a full AgentCheckpoint
// encode+save on every delta therefore re-encodes the same durable graph
// several times per second for every active run without adding any resumable
// state (the actual 332 allocation-failure path). These tests lock that
// boundary:
//   1. many stream deltas do not multiply checkpoint saves;
//   2. real tool-settlement and dispatch boundaries still save;
//   3. the explicit recovery-point path (App background/suspension and the
//      public service API) still saves.

import Foundation
import Testing
import FloeCore
import FloeModels
import FloePersistence
import FloeProviders
import FloeSecurity
import FloeTools
@testable import FloeAgentRuntime
import FloeTestSupport

@Suite("FloeAgentRuntime.RecoveryPointScheduling")
struct RecoveryPointSchedulingTests {
    private final class PacedDeltaAdapter: ProviderAdapter, @unchecked Sendable {
        let protocolKind: ModelProtocol = .openAIChatCompletions
        private let deltaCount: Int
        private let spacingMilliseconds: UInt64

        init(deltaCount: Int, spacingMilliseconds: UInt64) {
            self.deltaCount = deltaCount
            self.spacingMilliseconds = spacingMilliseconds
        }

        func stream(
            request: ProviderStreamRequest,
            credentials: ProviderCredentials
        ) -> AsyncThrowingStream<AgentEvent, Error> {
            AsyncThrowingStream { continuation in
                let task = Task {
                    for _ in 0..<deltaCount {
                        if Task.isCancelled { continuation.finish(); return }
                        continuation.yield(.textDelta(.init(text: "d")))
                        if spacingMilliseconds > 0 {
                            try? await Task.sleep(for: .milliseconds(Int64(spacingMilliseconds)))
                        }
                    }
                    continuation.yield(.completed(.init(stopReason: .endTurn)))
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        func listModels(
            provider: ProviderProfile,
            credentials: ProviderCredentials
        ) async throws -> [ModelProfile] { [] }
    }

    private func runService(deltaCount: Int, spacingMilliseconds: UInt64) async throws -> MockCheckpointStore {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let conversations = SQLiteConversationStore(database: database)
        let runs = SQLiteRunStore(database: database)
        let conversationID = UUID()
        try await conversations.saveConversation(.init(
            id: conversationID,
            title: "Recovery-point scheduling",
            createdAt: Date(),
            updatedAt: Date()
        ))
        let store = MockCheckpointStore()
        let service = ConversationRunService(
            configuration: .init(
                conversationID: conversationID,
                provider: TestFixtures.localhostProvider(),
                model: TestFixtures.testModel(providerID: UUID()),
                providerRetryBaseDelay: 0,
                providerRetryMaxDelay: 0
            ),
            adapter: PacedDeltaAdapter(
                deltaCount: deltaCount,
                spacingMilliseconds: spacingMilliseconds
            ),
            policy: HumanApprovalPolicy(),
            executor: MockExecutor(),
            checkpointStore: store,
            conversationStore: conversations,
            runStore: runs
        )
        try await service.start(goal: "stream a bounded answer")
        // A removed/remaining delayed recovery task would fire here; this is
        // a test bound, not a production timeout or recovery deadline.
        try await Task.sleep(for: .milliseconds(400))
        return store
    }

    @Test("Many stream deltas do not multiply checkpoint saves")
    func streamDeltasDoNotMultiplyCheckpointSaves() async throws {
        let baseline = try await runService(deltaCount: 1, spacingMilliseconds: 0)
        let paced = try await runService(deltaCount: 20, spacingMilliseconds: 40)
        // 20 deltas span ~800 ms, so the old 250 ms coalescing would have
        // produced several extra full-snapshot saves. The committed graph is
        // identical for both runs; the save count must be identical too.
        #expect(paced.saved.count == baseline.saved.count)
        #expect(baseline.saved.count <= 2)
    }

    @Test("Tool-settlement and explicit recovery boundaries still save")
    func realBoundariesStillSave() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let conversations = SQLiteConversationStore(database: database)
        let runs = SQLiteRunStore(database: database)
        let conversationID = UUID()
        try await conversations.saveConversation(.init(
            id: conversationID,
            title: "Real boundaries",
            createdAt: Date(),
            updatedAt: Date()
        ))
        let call = try TestFixtures.toolCall(id: "boundary-read", toolName: "workspace.readFile",
                                             arguments: #"{"path":"a.txt"}"#)
        let adapter = MockAdapter()
        adapter.script = [
            [.toolRequest(call), .completed(.init(stopReason: .toolUse))],
            [.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]
        ]
        let executor = MockExecutor()
        executor.descriptors[call.toolName] = .init(
            name: call.toolName,
            riskLabels: [],
            isSideEffecting: false
        )
        let store = MockCheckpointStore()
        let service = ConversationRunService(
            configuration: .init(
                conversationID: conversationID,
                provider: TestFixtures.localhostProvider(),
                model: TestFixtures.testModel(providerID: UUID()),
                providerRetryBaseDelay: 0,
                providerRetryMaxDelay: 0
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: executor,
            checkpointStore: store,
            conversationStore: conversations,
            runStore: runs
        )
        try await service.start(goal: "settle one tool")
        // The pre-dispatch checkpoint and the tool-settlement checkpoint are
        // both required; the settlement snapshot must carry the real pending
        // result, so an interrupted run can pair it without replaying work.
        #expect(store.saved.count >= 2)
        #expect(store.saved.contains { !$0.pendingToolResults.isEmpty })
        #expect(store.saved.contains { $0.providerDispatchEnvelope != nil })

        // The same public entry point the App uses before background
        // suspension/explicit checkpoint remains a real save.
        let before = store.saved.count
        await service.persistRecoveryPoint()
        #expect(store.saved.count == before + 1)
    }
}
