// FloeApp-hosted S3-C final-reply identity proof: REAL producer path.
//
// Unlike the injected-store suites, every case here runs the actual
// `ConversationRunService` + `FloeAgentRuntime` harness against the real
// SQLite conversation/run stores, then resolves the durable terminal
// marker's `finalMessageID` through the production
// `SQLiteRunReplyReader.provenFinalReplyText`. No test hand-writes a
// terminal payload and no test calls the seal/confirm handlers directly:
// the identity under proof is exactly what the production completion path
// persisted. Shared MockAdapter/MockExecutor helpers come from
// AgentRuntimeTests.swift, the established App-hosted runtime-fixture
// pattern; nothing here starts a provider, network or UI.

import Foundation
import Testing
@testable import FloeAgentRuntime
@testable import FloeProviders
@testable import FloeModels
@testable import FloeSecurity
@testable import FloeTools
@testable import FloeCore
import FloePersistence
import FloeTestSupport

@Suite("FloeApp.RunFinalReplyProof.Production")
struct FloeRunFinalReplyProofProductionTests {

    private struct Environment {
        let database: DatabaseManager
        let conversations: SQLiteConversationStore
        let runs: SQLiteRunStore
        let conversationID: UUID
    }

    private func makeEnvironment(title: String) async throws -> Environment {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let conversations = SQLiteConversationStore(database: database)
        let runs = SQLiteRunStore(database: database)
        let conversationID = UUID()
        try await conversations.saveConversation(ConversationRecord(
            id: conversationID, title: title, createdAt: Date(), updatedAt: Date()
        ))
        return Environment(
            database: database, conversations: conversations, runs: runs,
            conversationID: conversationID
        )
    }

    private func payload(_ event: RunEventRecord) throws -> [String: String] {
        try JSONDecoder().decode([String: String].self, from: Data(event.payloadJSON.utf8))
    }

    private func assistantRows(
        _ environment: Environment
    ) async throws -> [PersistedMessage] {
        try await environment.conversations
            .messages(conversationID: environment.conversationID)
            .filter { $0.role == "assistant" }
    }

    @Test("A normal completion proves the exact persisted final row inside the terminal marker")
    func completedRunProvesFinalMessageIdentity() async throws {
        let environment = try await makeEnvironment(title: "Proof run")
        let adapter = MockAdapter()
        adapter.script = [[
            .textDelta(.init(text: "The real ")), .textDelta(.init(text: "final answer")),
            .completed(.init(stopReason: .endTurn))
        ]]
        let service = ConversationRunService(
            configuration: .init(
                conversationID: environment.conversationID,
                provider: TestFixtures.localhostProvider(),
                model: TestFixtures.testModel(providerID: UUID())
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: MockExecutor(),
            conversationStore: environment.conversations,
            runStore: environment.runs
        )
        try await service.start(goal: "Answer with the final proof")

        let events = try await environment.runs.events(runID: service.runID)
        let terminal = try #require(events.last { $0.kind == .terminal })
        let marker = try #require(try payload(terminal)["finalMessageID"])
        let provenID = try #require(UUID(uuidString: marker))
        #expect(try payload(terminal)["stopReason"] == "endTurn")

        // The proven id is exactly the persisted final assistant row, and the
        // production exact reader resolves it.
        let rows = try await assistantRows(environment)
        #expect(rows.count == 1)
        #expect(rows[0].id == provenID)
        #expect(rows[0].content == "The real final answer")
        let reader = SQLiteRunReplyReader(database: environment.database)
        #expect(try await reader.provenFinalReplyText(
            runID: service.runID,
            conversationID: environment.conversationID,
            messageID: provenID
        ) == "The real final answer")
        // A proven success carries no false absence marker.
        #expect(!events.contains {
            $0.kind == .error && (try? payload($0)["message"]) == "noFinalText"
        })
        #expect(try await environment.runs.run(id: service.runID)?.state == "completed")
    }

    @Test("A verification CONFIRM proves the sealed draft row, not any later row")
    func verifiedConfirmProvesSealedDraftRow() async throws {
        let environment = try await makeEnvironment(title: "Confirm run")
        let adapter = MockAdapter()
        adapter.script = [
            [
                .textDelta(.init(text: "Sealed draft answer")),
                .completed(.init(stopReason: .endTurn))
            ],
            [
                .textDelta(.init(text: "CONFIRM")),
                .completed(.init(stopReason: .endTurn))
            ]
        ]
        let service = ConversationRunService(
            configuration: .init(
                conversationID: environment.conversationID,
                provider: TestFixtures.localhostProvider(),
                model: TestFixtures.testModel(providerID: UUID()),
                verifyFinalAnswer: true
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: MockExecutor(),
            conversationStore: environment.conversations,
            runStore: environment.runs
        )
        try await service.start(goal: "Answer carefully")

        let events = try await environment.runs.events(runID: service.runID)
        let terminal = try #require(events.last { $0.kind == .terminal })
        let terminalPayload = try payload(terminal)
        let provenIDString = try #require(terminalPayload["finalMessageID"])
        let provenID = try #require(UUID(uuidString: provenIDString))

        // The draft sealed exactly once; "CONFIRM" never became a row and no
        // finalAssistant duplicate was written. The terminal proves the very
        // draft row the verification pass confirmed.
        let rows = try await assistantRows(environment)
        #expect(rows.count == 1)
        #expect(rows[0].id == provenID)
        #expect(rows[0].content == "Sealed draft answer")
        let reader = SQLiteRunReplyReader(database: environment.database)
        #expect(try await reader.provenFinalReplyText(
            runID: service.runID,
            conversationID: environment.conversationID,
            messageID: provenID
        ) == "Sealed draft answer")
        #expect(!events.contains {
            $0.kind == .error && (try? payload($0)["message"]) == "noFinalText"
        })
        #expect(try await environment.runs.run(id: service.runID)?.state == "completed")
    }

    @Test("An empty completion after a deferred-action repair proves no final reply")
    func repairThenEmptyCompletionWritesNoFinalText() async throws {
        let environment = try await makeEnvironment(title: "Repair run")
        let adapter = MockAdapter()
        adapter.script = [
            [
                .textDelta(.init(text: "I will now inspect the logs")),
                .completed(.init(stopReason: .endTurn))
            ],
            [
                .completed(.init(stopReason: .endTurn))
            ]
        ]
        let executor = MockExecutor()
        executor.descriptors["test.echo"] = ToolCatalog.Descriptor(
            name: "test.echo", riskLabels: [], isSideEffecting: false
        )
        let service = ConversationRunService(
            configuration: .init(
                conversationID: environment.conversationID,
                provider: TestFixtures.localhostProvider(),
                model: TestFixtures.testModel(providerID: UUID()),
                verifyFinalAnswer: true
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: executor,
            conversationStore: environment.conversations,
            runStore: environment.runs
        )
        try await service.start(goal: "Check the logs and answer")

        #expect(adapter.requests.count == 2)
        let repairRequest = try #require(adapter.requests.dropFirst().first)
        #expect(repairRequest.messages.contains {
            $0.role == "system" && $0.content.contains("promised an immediate action but emitted no structured tool call")
        })
        let events = try await environment.runs.events(runID: service.runID)
        // The repair sealed "I will now inspect the logs" as a step. The empty
        // follow-up completion must write the honest noFinalText surface and
        // the terminal marker must carry NO final-message identity — the
        // step row is never re-proven as the answer.
        #expect(events.contains {
            $0.kind == .error && (try? payload($0)["message"]) == "noFinalText"
        })
        let terminal = try #require(events.last { $0.kind == .terminal })
        #expect(try payload(terminal)["finalMessageID"] == nil)
        #expect(try payload(terminal)["stopReason"] == "endTurn")

        let rows = try await assistantRows(environment)
        #expect(rows.map(\.content) == ["I will now inspect the logs"])
        #expect(try await environment.runs.run(id: service.runID)?.state == "completed")
    }

    @Test("Repeated identical text with failed saves never re-proves the older row")
    func duplicateStepTextFailedSavesProveNothing() async throws {
        let environment = try await makeEnvironment(title: "Stale draft run")
        let failingStore = FailpointMessageStore(
            upstream: environment.conversations,
            failAppendsFromOrdinal: 3
        )
        let duplicated = "I will now inspect the data"
        let adapter = MockAdapter()
        adapter.script = [
            // Turn 1: a deferred-action promise is repaired; step row A lands.
            [
                .textDelta(.init(text: duplicated)),
                .completed(.init(stopReason: .endTurn))
            ],
            // Turn 2: the model repeats byte-identical text; the verification
            // seal is attempted and its save fails (ordinal 3+).
            [
                .textDelta(.init(text: duplicated)),
                .completed(.init(stopReason: .endTurn))
            ],
            // Turn 3: a bare CONFIRM arrives. The confirm must find no
            // adoptable candidate: the sealed attempt never persisted, so the
            // older identical-text row cannot be re-proven.
            [
                .textDelta(.init(text: "CONFIRM")),
                .completed(.init(stopReason: .endTurn))
            ]
        ]
        let executor = MockExecutor()
        executor.descriptors["test.echo"] = ToolCatalog.Descriptor(
            name: "test.echo", riskLabels: [], isSideEffecting: false
        )
        let service = ConversationRunService(
            configuration: .init(
                conversationID: environment.conversationID,
                provider: TestFixtures.localhostProvider(),
                model: TestFixtures.testModel(providerID: UUID()),
                verifyFinalAnswer: true
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: executor,
            conversationStore: failingStore,
            runStore: environment.runs
        )
        try await service.start(goal: "Inspect the data and answer")

        #expect(adapter.requests.count == 3)
        let repairRequest = try #require(adapter.requests.dropFirst().first)
        #expect(repairRequest.messages.contains {
            $0.role == "system" && $0.content.contains("promised an immediate action but emitted no structured tool call")
        })
        let events = try await environment.runs.events(runID: service.runID)
        // Durability failure fully blocks the clean terminal: no terminal
        // marker exists at all, so there is no carrier for a false id.
        #expect(!events.contains { $0.kind == .terminal })
        #expect(try await environment.runs.run(id: service.runID)?.state == "failed")
        // Only step row A persisted. The failed draft seal and the failed
        // finalAssistant save produced no rows, and nothing in the durable
        // thread proves — or re-adopts through text equality — the older row.
        let rows = try await environment.conversations
            .messages(conversationID: environment.conversationID)
            .filter { $0.role == "assistant" }
        #expect(rows.map(\.content) == [duplicated])
    }
}

/// ConversationStore wrapper that fails every `appendMessage` from a given
/// call ordinal onward, simulating a durable save failure at the chosen
/// boundary while all other store operations stay real.
private actor FailpointMessageStore: ConversationStore {
    private let upstream: any ConversationStore
    private let failAppendsFromOrdinal: Int
    private var appendCount = 0

    init(upstream: any ConversationStore, failAppendsFromOrdinal: Int) {
        self.upstream = upstream
        self.failAppendsFromOrdinal = failAppendsFromOrdinal
    }

    func appendMessage(_ message: PersistedMessage) async throws {
        appendCount += 1
        if appendCount >= failAppendsFromOrdinal {
            throw FloeError.storageCorrupted("injected appendMessage failpoint \(appendCount)")
        }
        try await upstream.appendMessage(message)
    }

    func saveConversation(_ conversation: ConversationRecord) async throws {
        try await upstream.saveConversation(conversation)
    }
    func conversations() async throws -> [ConversationRecord] {
        try await upstream.conversations()
    }
    func conversations(includeArchived: Bool) async throws -> [ConversationRecord] {
        try await upstream.conversations(includeArchived: includeArchived)
    }
    func conversation(id: UUID) async throws -> ConversationRecord? {
        try await upstream.conversation(id: id)
    }
    func renameConversation(id: UUID, title: String) async throws {
        try await upstream.renameConversation(id: id, title: title)
    }
    @discardableResult
    func setAutomaticTitle(id: UUID, title: String) async throws -> Bool {
        try await upstream.setAutomaticTitle(id: id, title: title)
    }
    func deleteConversation(id: UUID) async throws {
        try await upstream.deleteConversation(id: id)
    }
    @discardableResult
    func deleteConversationIfVerifiedEmpty(id: UUID) async throws -> Bool {
        try await upstream.deleteConversationIfVerifiedEmpty(id: id)
    }
    func setArchived(id: UUID, archived: Bool) async throws {
        try await upstream.setArchived(id: id, archived: archived)
    }
    func messages(conversationID: UUID) async throws -> [PersistedMessage] {
        try await upstream.messages(conversationID: conversationID)
    }
    func recentMessages(conversationID: UUID, limit: Int) async throws -> [PersistedMessage] {
        try await upstream.recentMessages(conversationID: conversationID, limit: limit)
    }
    func messagePage(
        conversationID: UUID,
        before cursor: ConversationMessageCursor?,
        limit: Int
    ) async throws -> ConversationMessagePage {
        try await upstream.messagePage(
            conversationID: conversationID, before: cursor, limit: limit)
    }
    func parts(messageID: UUID) async throws -> [MessagePart] {
        try await upstream.parts(messageID: messageID)
    }
    func saveAttachment(_ attachment: AttachmentRef) async throws {
        try await upstream.saveAttachment(attachment)
    }
    func attachment(id: UUID) async throws -> AttachmentRef? {
        try await upstream.attachment(id: id)
    }
    func attachments(conversationID: UUID) async throws -> [AttachmentRef] {
        try await upstream.attachments(conversationID: conversationID)
    }
}
