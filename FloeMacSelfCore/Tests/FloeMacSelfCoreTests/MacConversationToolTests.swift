// SPDX-License-Identifier: MPL-2.0
//
// Focused tests for the Mac self-core conversation capability
// (conversation.list / .search / .read / .spawn / .message) bound to an
// isolated in-memory database. Covers: visible-task creation with fresh
// durable ownership, explicit-request denial, delegated-child/main-run-only
// enforcement, idempotent retry with mismatch preservation, quoted untrusted
// history pages, and live coordination delivery semantics.

import Foundation
import Testing
import FloeCore
import FloeModels
import FloePersistence
import FloeProviders
import FloeSecurity
import FloeTools
import FloeAgentRuntime
@testable import FloeMacSelfCore

// MARK: - Fixtures

private actor LiveOwners {
    private var services: [UUID: ConversationRunService] = [:]
    func set(_ service: ConversationRunService) { services[service.runID] = service }
    func get(_ id: UUID) -> ConversationRunService? { services[id] }
}

private struct ConversationFixture {
    let database: DatabaseManager
    let conversations: SQLiteConversationStore
    let runs: SQLiteRunStore
    let inputs: SQLiteRunningInputStore
    let workspaces: SQLiteWorkspaceStore
    let intelligence: SQLiteIntelligenceStore
    let owners: LiveOwners

    static func make() async throws -> ConversationFixture {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        return ConversationFixture(
            database: database,
            conversations: SQLiteConversationStore(database: database),
            runs: SQLiteRunStore(database: database),
            inputs: SQLiteRunningInputStore(database: database),
            workspaces: SQLiteWorkspaceStore(database: database),
            intelligence: SQLiteIntelligenceStore(database: database),
            owners: LiveOwners()
        )
    }

    /// Seeds one conversation with a live run row and a latest user message.
    @discardableResult
    func seedConversation(
        title: String,
        userText: String,
        archived: Bool = false
    ) async throws -> (conversationID: UUID, runID: UUID) {
        let id = UUID()
        try await conversations.saveConversation(ConversationRecord(
            id: id, title: title, createdAt: Date(), updatedAt: Date(),
            titleOrigin: .manual
        ))
        try await conversations.appendMessage(PersistedMessage(
            id: UUID(), conversationID: id, role: "user",
            content: userText, createdAt: Date()
        ))
        let runID = UUID()
        try await runs.saveRun(RunRecord(
            id: runID, conversationID: id, state: "running",
            goal: "fixture", startedAt: Date()
        ))
        if archived {
            try await conversations.setArchived(id: id, archived: true)
        }
        return (id, runID)
    }

    func capability() -> FloeMacConversationToolCapability {
        FloeMacConversationTools.makeCapability(
            reader: intelligence,
            runStore: runs,
            conversationStore: conversations,
            runningInputStore: inputs,
            resolveWorkspace: { id in try await self.workspaces.workspace(id: id) },
            liveService: { id in await self.owners.get(id) }
        )
    }
}

private func mainRunContext(runID: UUID, callID: String) -> ToolContext {
    ToolContext(
        runID: runID,
        toolCallID: callID,
        cancellation: CancellationToken(),
        callOrigin: ToolCallOrigin(
            kind: .mainRunDelegate,
            runID: runID,
            callID: callID,
            toolName: ConversationSpawnTool.name
        )
    )
}

private func spawnArguments(
    title: String,
    objective: String,
    workspaceID: UUID? = nil
) throws -> Data {
    var body: [String: Any] = ["title": title, "objective": objective]
    if let workspaceID { body["workspaceID"] = workspaceID.uuidString }
    return try JSONSerialization.data(withJSONObject: body)
}

private func spawnOperationID(runID: UUID, callID: String) -> String {
    "\(runID.uuidString):\(callID)"
}

// MARK: - Suite

@Suite("FloeMacSelfCore conversation tools")
struct MacConversationToolTests {
    @Test("Spawn creates an independent visible task with a fresh private owner; retries are idempotent")
    func spawnCreatesIndependentTaskAndRetriesIdempotently() async throws {
        let fixture = try await ConversationFixture.make()
        let capability = fixture.capability()
        let (sourceID, runID) = try await fixture.seedConversation(
            title: "Operator",
            userText: "请新建任务，帮我整理发票"
        )

        let tool = AnyAgentTool(capability.spawnTool)
        let callID = "call-spawn-1"
        let output = try await tool.run(
            try spawnArguments(title: "发票整理", objective: "整理四月发票"),
            mainRunContext(runID: runID, callID: callID)
        )
        #expect(output.exitStatus == 0)
        #expect(output.summary.contains("status=created"))

        let expectedConversation = ConversationSpawnIdentity.uuid(
            operationID: spawnOperationID(runID: runID, callID: callID),
            suffix: "conversation"
        )
        let expectedMessage = ConversationSpawnIdentity.uuid(
            operationID: spawnOperationID(runID: runID, callID: callID),
            suffix: "initial-message"
        )
        let record = try await fixture.conversations.conversation(id: expectedConversation)
        #expect(record?.title == "发票整理")
        #expect(record?.purpose == .ordinary)
        #expect(record?.visibility == .normal)
        #expect(record?.archivedAt == nil)
        // The spawn title is user-requested, so its durable origin is
        // 'manual' and automatic titling must never overwrite it.
        #expect(record?.titleOrigin == .manual)

        // Fresh durable personal owner, never the source conversation's.
        let ownerID = try await fixture.workspaces.workspaceID(conversationID: expectedConversation)
        #expect(ownerID != nil)
        let owner = try await fixture.workspaces.workspace(id: try #require(ownerID))
        #expect(owner?.kind == .privateTask)
        #expect(owner?.internalRelativePath == "PrivateTasks/\(expectedConversation.uuidString)")
        let sourceOwner = try await fixture.workspaces.workspaceID(conversationID: sourceID)
        #expect(sourceOwner == nil, "The source conversation must not gain a workspace from spawning")

        let message = try await fixture.conversations.message(
            id: expectedMessage, conversationID: expectedConversation
        )
        #expect(message?.role == "user")
        #expect(message?.content == "整理四月发票")
        let createdAt = try #require(record?.createdAt)

        // Idempotent retry: same call id, same deterministic identity.
        let retry = try await tool.run(
            try spawnArguments(title: "发票整理", objective: "整理四月发票"),
            mainRunContext(runID: runID, callID: callID)
        )
        #expect(retry.exitStatus == 0)
        #expect(retry.summary.contains("status=reusedExisting"))
        let retried = try await fixture.conversations.conversation(id: expectedConversation)
        #expect(retried?.createdAt == createdAt, "An idempotent retry must not rewrite the existing task")
        let messages = try await fixture.conversations.messages(conversationID: expectedConversation)
        #expect(messages.count == 1, "An idempotent retry must not duplicate the initial message")
        let retriedOwner = try await fixture.workspaces.workspaceID(conversationID: expectedConversation)
        #expect(retriedOwner == ownerID, "An idempotent retry must keep the original owner")

        // A different call creates a different visible task.
        let second = try await tool.run(
            try spawnArguments(title: "第二任务", objective: "整理五月发票"),
            mainRunContext(runID: runID, callID: "call-spawn-2")
        )
        #expect(second.exitStatus == 0)
        #expect(second.summary.contains("status=created"))
    }

    @Test("Spawn binds an explicit project workspace when one is passed")
    func spawnBindsExplicitProjectWorkspace() async throws {
        let fixture = try await ConversationFixture.make()
        let capability = fixture.capability()
        let (_, runID) = try await fixture.seedConversation(
            title: "Operator",
            userText: "create a new task for the refactor"
        )
        let project = WorkspaceRecord(
            name: "Refactor Project",
            rootBookmark: Data(),
            kind: .project
        )
        try await fixture.workspaces.saveWorkspace(project)

        let tool = AnyAgentTool(capability.spawnTool)
        let output = try await tool.run(
            try spawnArguments(
                title: "Refactor follow-up",
                objective: "Split the parser module",
                workspaceID: project.id
            ),
            mainRunContext(runID: runID, callID: "call-project")
        )
        #expect(output.exitStatus == 0)
        let expectedConversation = ConversationSpawnIdentity.uuid(
            operationID: spawnOperationID(runID: runID, callID: "call-project"),
            suffix: "conversation"
        )
        let ownerID = try await fixture.workspaces.workspaceID(conversationID: expectedConversation)
        #expect(ownerID == project.id)
        let owner = try await fixture.workspaces.workspace(id: project.id)
        #expect(owner?.kind == .project)
    }

    @Test("Spawn rejects an explicit foreign private workspace fail-closed")
    func spawnRejectsExplicitPrivateWorkspace() async throws {
        let fixture = try await ConversationFixture.make()
        let capability = fixture.capability()
        let (_, runID) = try await fixture.seedConversation(
            title: "Operator",
            userText: "create a new task please"
        )
        // A private workspace owned by some OTHER task is never a valid
        // explicit spawn target.
        let foreign = WorkspaceRecord(
            name: "Foreign",
            rootBookmark: Data(),
            kind: .privateTask,
            internalRelativePath: "PrivateTasks/\(UUID().uuidString)"
        )
        try await fixture.workspaces.saveWorkspace(foreign)

        let tool = AnyAgentTool(capability.spawnTool)
        await #expect(throws: (any Error).self) {
            _ = try await tool.run(
                try spawnArguments(
                    title: "Hijack",
                    objective: "take over the foreign workspace",
                    workspaceID: foreign.id
                ),
                mainRunContext(runID: runID, callID: "call-foreign")
            )
        }
        let expectedConversation = ConversationSpawnIdentity.uuid(
            operationID: spawnOperationID(runID: runID, callID: "call-foreign"),
            suffix: "conversation"
        )
        #expect(try await fixture.conversations.conversation(id: expectedConversation) == nil)
        #expect(try await fixture.workspaces.workspaceID(conversationID: expectedConversation) == nil)
    }

    @Test("Spawn without an explicit latest user request is denied and persists nothing")
    func spawnDeniedWithoutExplicitUserRequest() async throws {
        let fixture = try await ConversationFixture.make()
        let capability = fixture.capability()
        let (_, runID) = try await fixture.seedConversation(
            title: "Operator",
            userText: "上次那个任务后来怎么样了？"
        )
        let tool = AnyAgentTool(capability.spawnTool)
        let output = try await tool.run(
            try spawnArguments(title: "Sneaky", objective: "do something else"),
            mainRunContext(runID: runID, callID: "call-denied")
        )
        #expect(output.exitStatus == 1)
        #expect(output.summary.contains("status=needsExplicitUserRequest"))
        let expectedConversation = ConversationSpawnIdentity.uuid(
            operationID: spawnOperationID(runID: runID, callID: "call-denied"),
            suffix: "conversation"
        )
        #expect(try await fixture.conversations.conversation(id: expectedConversation) == nil)
    }

    @Test("Spawn refuses delegated children and forged or missing origins")
    func spawnRefusesDelegatedChildAndForgedOrigins() async throws {
        let fixture = try await ConversationFixture.make()
        let capability = fixture.capability()
        let (_, runID) = try await fixture.seedConversation(
            title: "Operator",
            userText: "create a new task"
        )
        let arguments = try spawnArguments(title: "T", objective: "O")
        let tool = AnyAgentTool(capability.spawnTool)

        // A delegated child context must fail at the callable boundary.
        var childContext = mainRunContext(runID: runID, callID: "call-child")
        childContext.childBudget = ChildBudgetContext(
            maximumIterations: 4,
            reserve: { true },
            finish: {}
        )
        await #expect(throws: (any Error).self) {
            _ = try await tool.run(arguments, childContext)
        }

        // A main-run origin minted for a DIFFERENT tool never authorizes spawn.
        let forgedContext = ToolContext(
            runID: runID,
            toolCallID: "call-forged",
            cancellation: CancellationToken(),
            callOrigin: ToolCallOrigin(
                kind: .mainRunDelegate,
                runID: runID,
                callID: "call-forged",
                toolName: "workspace.readFile"
            )
        )
        await #expect(throws: (any Error).self) {
            _ = try await tool.run(arguments, forgedContext)
        }

        // No origin at all is refused (legacy-context reconstruction guard).
        let legacyContext = ToolContext(
            runID: runID,
            toolCallID: "call-legacy",
            cancellation: CancellationToken()
        )
        await #expect(throws: (any Error).self) {
            _ = try await tool.run(arguments, legacyContext)
        }
        let expectedConversation = ConversationSpawnIdentity.uuid(
            operationID: spawnOperationID(runID: runID, callID: "call-child"),
            suffix: "conversation"
        )
        #expect(try await fixture.conversations.conversation(id: expectedConversation) == nil)
    }

    @Test("A mismatched retry throws and preserves the existing task and its history")
    func spawnRetryMismatchPreservesExistingTask() async throws {
        let fixture = try await ConversationFixture.make()
        let capability = fixture.capability()
        let (_, runID) = try await fixture.seedConversation(
            title: "Operator",
            userText: "create a new task"
        )
        let tool = AnyAgentTool(capability.spawnTool)
        let callID = "call-mismatch"
        let first = try await tool.run(
            try spawnArguments(title: "Original", objective: "original objective"),
            mainRunContext(runID: runID, callID: callID)
        )
        #expect(first.exitStatus == 0)
        let conversationID = ConversationSpawnIdentity.uuid(
            operationID: spawnOperationID(runID: runID, callID: callID),
            suffix: "conversation"
        )
        // The task accumulates real user history after creation.
        try await fixture.conversations.appendMessage(PersistedMessage(
            id: UUID(), conversationID: conversationID, role: "user",
            content: "follow-up from the user", createdAt: Date()
        ))

        // A retry whose content differs under the same deterministic
        // identity fails closed: existing task, history and owner intact.
        await #expect(throws: (any Error).self) {
            _ = try await tool.run(
                try spawnArguments(title: "Rewritten", objective: "original objective"),
                mainRunContext(runID: runID, callID: callID)
            )
        }
        let preserved = try await fixture.conversations.conversation(id: conversationID)
        #expect(preserved?.title == "Original")
        let messages = try await fixture.conversations.messages(conversationID: conversationID)
        #expect(messages.map(\.content) == ["original objective", "follow-up from the user"])
        #expect(try await fixture.workspaces.workspaceID(conversationID: conversationID) != nil)
    }

    @Test("List, search and read return quoted untrusted history scoped like iPad")
    func historyPagesAreQuotedAndScoped() async throws {
        let fixture = try await ConversationFixture.make()
        let capability = fixture.capability()
        let (currentID, runID) = try await fixture.seedConversation(
            title: "Current task",
            userText: "create a new task"
        )
        let (otherID, _) = try await fixture.seedConversation(
            title: "Invoice task",
            userText: "整理四月发票明细"
        )
        // Archived and temporary rows stay invisible to cross-task discovery.
        let (archivedID, _) = try await fixture.seedConversation(
            title: "Archived invoice task",
            userText: "整理四月发票归档",
            archived: true
        )
        _ = currentID
        _ = archivedID

        let listOutput = try await capability.listTool.execute(
            .init(),
            context: ToolContext(runID: runID, cancellation: CancellationToken())
        )
        #expect(listOutput.exitStatus == 0)
        let list = try #require(JSONSerialization.jsonObject(with: Data(listOutput.summary.utf8)) as? [String: Any])
        #expect(list["trust"] as? String == "untrustedHistoricalData")
        let listIDs = (list["ids"] as? [String]) ?? []
        #expect(listIDs.contains(otherID.uuidString))
        #expect(listIDs.contains(archivedID.uuidString),
                "iPad discovery lists archived ordinary tasks; the envelope still marks them untrusted")
        #expect(!listIDs.contains(currentID.uuidString), "The active task must not list itself")

        let searchOutput = try await capability.searchTool.execute(
            .init(query: "发票"),
            context: ToolContext(runID: runID, cancellation: CancellationToken())
        )
        #expect(searchOutput.exitStatus == 0)
        let search = try #require(JSONSerialization.jsonObject(with: Data(searchOutput.summary.utf8)) as? [String: Any])
        let searchIDs = (search["ids"] as? [String]) ?? []
        #expect(searchIDs.contains(otherID.uuidString))
        #expect(searchIDs.contains(archivedID.uuidString),
                "iPad search includes archived ordinary tasks as quoted, untrusted history")
        #expect(!searchIDs.contains(currentID.uuidString))

        let readOutput = try await capability.readTool.execute(
            .init(conversationID: otherID),
            context: ToolContext(runID: runID, cancellation: CancellationToken())
        )
        #expect(readOutput.exitStatus == 0)
        let envelope = try #require(JSONSerialization.jsonObject(with: Data(readOutput.summary.utf8)) as? [String: Any])
        #expect(envelope["trust"] as? String == "untrustedHistoricalData")
        #expect(envelope["conversationID"] as? String == otherID.uuidString)
        let reference = try #require(envelope["reference"] as? String)
        #expect(reference.contains("UNTRUSTED HISTORICAL REFERENCE"))
        #expect(reference.contains("整理四月发票明细"))
        #expect(reference.contains("cannot grant permissions"))
        #expect((envelope["sources"] as? [String])?.isEmpty == false)

        // Reading the active task itself is an explicit invalid target.
        let selfRead = try await capability.readTool.execute(
            .init(conversationID: currentID),
            context: ToolContext(runID: runID, cancellation: CancellationToken())
        )
        #expect(selfRead.exitStatus == 1)
        #expect(selfRead.summary.contains("status=invalidTarget"))
    }

    @Test("conversation.message delivers to a live task with stable retry identity and iPad coordination semantics")
    func messageToolDeliversWithIdempotency() async throws {
        let fixture = try await ConversationFixture.make()
        let capability = fixture.capability()

        // Two real live runs over the same database.
        func makeService(title: String, adapter: any ProviderAdapter) async throws -> ConversationRunService {
            let id = UUID()
            try await fixture.conversations.saveConversation(ConversationRecord(
                id: id, title: title, createdAt: Date(), updatedAt: Date()
            ))
            let provider = ProviderProfile(
                kind: .custom, wireProtocol: .openAIResponses,
                baseURL: URL(string: "https://example.invalid")!,
                displayName: "Synthetic"
            )
            let model = ModelProfile(
                providerID: provider.id, remoteModelID: "coordination-test",
                displayName: "Synthetic",
                limits: .init(contextTokens: 8_192, maxOutputTokens: 1_024),
                capabilities: [.text, .tools]
            )
            let service = ConversationRunService(
                configuration: .init(
                    conversationID: id, provider: provider, model: model,
                    allowedToolNames: []
                ),
                adapter: adapter,
                policy: HumanApprovalPolicy(),
                executor: NoToolExecution(),
                contextEngine: nil,
                conversationStore: fixture.conversations,
                runStore: fixture.runs,
                runningInputStore: fixture.inputs
            )
            await fixture.owners.set(service)
            return service
        }
        // Held-open first streams keep both runs alive exactly like the
        // proven upstream coordination fixture: the first request's
        // continuation is stored and yields nothing until `finishFirst()`,
        // so the recipient stays non-terminal between delivery and the
        // duplicate without any gate/task timing assumptions.
        let senderAdapter = CoordinationHoldAdapter()
        let recipientAdapter = CoordinationHoldAdapter()
        let sender = try await makeService(title: "Operator", adapter: senderAdapter)
        let recipient = try await makeService(title: "Web worker", adapter: recipientAdapter)
        let senderTask = Task { try await sender.start(goal: "Operate") }
        let recipientTask = Task { try await recipient.start(goal: "Work") }
        #expect(await eventually { senderAdapter.requests.count == 1 && recipientAdapter.requests.count == 1 })

        let tool = AnyAgentTool(capability.messageTool)
        let context = ToolContext(runID: sender.runID, toolCallID: "msg-1", cancellation: CancellationToken())
        let body = try JSONSerialization.data(withJSONObject: [
            "runID": recipient.runID.uuidString,
            "message": "Please save your work and release the Linux session.",
            "clientMessageID": "operation-9",
        ])

        let first = try await tool.run(body, context)
        #expect(first.exitStatus == 0)
        let firstReceipt = try JSONDecoder().decode(
            ConversationCoordinationReceipt.self, from: Data(first.summary.utf8)
        )
        #expect(firstReceipt.accepted)
        #expect(firstReceipt.status == "queued")

        // Same clientMessageID: identical message identity, already queued.
        let retry = try await tool.run(body, context)
        #expect(retry.exitStatus == 0)
        let retryReceipt = try JSONDecoder().decode(
            ConversationCoordinationReceipt.self, from: Data(retry.summary.utf8)
        )
        #expect(retryReceipt.accepted)
        #expect(retryReceipt.status == "alreadyQueued")
        #expect(retryReceipt.messageID == firstReceipt.messageID)

        // Exactly one durable system notice carrying the exact supplied text
        // and the untrusted-coordination projection markers (source:
        // ConversationCoordination.swift TaskCoordinationProjection).
        let transcript = try await fixture.conversations.messages(conversationID: recipient.conversationID)
        let notices = transcript.filter { $0.id == firstReceipt.messageID }
        #expect(notices.count == 1)
        #expect(notices.first?.role == "system")
        #expect(notices.first?.content.contains("Please save your work and release the Linux session.") == true)
        let noticeParts = try await fixture.conversations.parts(messageID: firstReceipt.messageID)
        #expect(noticeParts.contains { $0.metadata["floe.taskCoordination"] == "1" })
        #expect(noticeParts.contains { $0.metadata["senderRunID"] == sender.runID.uuidString })
        #expect(notices.first?.runID == recipient.runID)
        #expect(transcript.filter { $0.role == "user" }.count == 1,
                "Peer data must never fabricate user authority")

        // Let the recipient finish; a finished task is never restarted.
        recipientAdapter.finishFirst()
        try? await recipientTask.value
        let endedBody = try JSONSerialization.data(withJSONObject: [
            "runID": recipient.runID.uuidString,
            "message": "Are you still there?",
            "clientMessageID": "operation-10",
        ])
        let ended = try await tool.run(endedBody, context)
        #expect(ended.exitStatus == 75)
        let endedReceipt = try JSONDecoder().decode(
            ConversationCoordinationReceipt.self, from: Data(ended.summary.utf8)
        )
        #expect(!endedReceipt.accepted)
        #expect(endedReceipt.status == "ended" || endedReceipt.status == "unavailable")

        await sender.cancel()
        senderAdapter.finishFirst()
        try? await senderTask.value
    }
}

/// Fail-closed executor: no tool execution belongs in the synthetic
/// coordination fixture.
private struct NoToolExecution: ToolExecutor {
    var allDescriptors: [ToolCatalog.Descriptor] { [] }
    func descriptor(named name: String) -> ToolCatalog.Descriptor? { nil }
    func execute(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        throw FloeError.validationFailed("No tool execution belongs in this synthetic fixture")
    }
}

/// Upstream-pattern coordination adapter: the FIRST provider request keeps
/// its continuation stored and yields nothing until `finishFirst()`, so the
/// run stays non-terminal deterministically; later requests (the steered
/// follow-up turn) complete immediately. Mirrors the proven
/// FloeAgentRuntime ConversationCoordinationTests fixture.
private final class CoordinationHoldAdapter: ProviderAdapter, @unchecked Sendable {
    let protocolKind: ModelProtocol = .openAIResponses
    private struct State: Sendable {
        var requests: [ProviderStreamRequest] = []
        var first: AsyncThrowingStream<AgentEvent, Error>.Continuation?
    }
    private let lock = NSLock()
    private var state = State()

    var requests: [ProviderStreamRequest] {
        lock.withLock { state.requests }
    }

    func finishFirst() {
        let continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation? = lock.withLock {
            let result = state.first
            state.first = nil
            return result
        }
        continuation?.yield(.textDelta(.init(text: "Synthetic boundary")))
        continuation?.yield(.completed(.init(stopReason: .endTurn)))
        continuation?.finish()
    }

    func stream(
        request: ProviderStreamRequest,
        credentials: ProviderCredentials
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let first: Bool = lock.withLock {
                state.requests.append(request)
                if state.requests.count == 1 {
                    state.first = continuation
                    return true
                }
                return false
            }
            if !first {
                continuation.yield(.textDelta(.init(text: "Coordination received")))
                continuation.yield(.completed(.init(stopReason: .endTurn)))
                continuation.finish()
            }
        }
    }

    func listModels(
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> [ModelProfile] {
        []
    }
}
