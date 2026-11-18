// SPDX-License-Identifier: MPL-2.0
//
// G02 durable-memory / cross-task-history registration tests. AUTHORED, NOT
// EXECUTED in this lane (the task forbids the shared Swift/Gradle build).
//
// These tests pin the REAL registration seam used by `G02DomainServices`:
//   * every memory tool is backed by the actual `SQLiteIntelligenceStore`;
//   * a memory write with no proven owner task fails closed and writes nothing;
//   * the generation availability closure removes retired tools from both
//     discovery and execution;
//   * the three conversation read tools are registered while the side-effecting
//     spawn remains unadvertised without a real producer;
//   * the current task is excluded from search/list and refused by read.
import XCTest
import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeSecurity
import FloeTools
import FloeAgentRuntime

final class HarnessToolRegistrationTests: XCTestCase {

    private static let memoryToolNames: Set<String> = [
        "memory.remember", "memory.recall", "memory.search", "memory.list",
        "memory.update", "memory.forget", "memory.organizePreview",
        "memory.batchApply",
    ]

    private static let conversationReadNames: Set<String> = [
        "conversation.list", "conversation.search", "conversation.read",
    ]

    // MARK: - Memory

    func testMemoryToolsRegisterAgainstTheRealStoreAndRecordOwnedFacts() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = SQLiteIntelligenceStore(database: database)
        let registry = ToolRunnerRegistry()
        let runID = UUID()
        let conversationID = UUID()

        _ = registerMemoryTools(
            registry: registry,
            store: store,
            taskIDForRun: { id in id == runID ? conversationID : nil },
            includeGlobalMemoryInspection: true
        )

        for name in Self.memoryToolNames {
            XCTAssertNotNil(registry.descriptor(named: name), "runner \(name)")
            XCTAssertNotNil(ToolCatalog.descriptor(named: name), "catalog \(name)")
        }
        XCTAssertEqual(registry.allDescriptors.count, Self.memoryToolNames.count)

        let remember = try XCTUnwrap(registry.runner(named: MemoryRememberTool.name))
        let output = try await remember.run(
            Data(#"{"content":"durable registration probe","scope":"global"}"#.utf8),
            ToolContext(runID: runID, cancellation: CancellationToken())
        )
        XCTAssertEqual(output.exitStatus, 0)
        XCTAssertTrue(output.summary.contains("status=remembered"))

        let entries = try await store.memories(scope: .agentGlobal, status: .active)
        let recorded = try XCTUnwrap(entries.first { $0.content == "durable registration probe" })
        // The durable origin is the OWNING conversation resolved from the run,
        // never a model-supplied task id and never a fabricated nil owner.
        XCTAssertEqual(recorded.originConversationID, conversationID)

        let recall = try XCTUnwrap(registry.runner(named: MemoryRecallTool.name))
        let recalled = try await recall.run(
            Data(#"{"scope":"global"}"#.utf8),
            ToolContext(runID: runID, cancellation: CancellationToken())
        )
        XCTAssertEqual(recalled.exitStatus, 0)
        XCTAssertTrue(recalled.summary.contains("durable registration probe"))
    }

    func testCompositionRegistersOnlyTheOwnedMemorySubset() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = SQLiteIntelligenceStore(database: database)
        let registry = ToolRunnerRegistry()

        registerMemoryTools(
            registry: registry,
            store: store,
            taskIDForRun: { _ in UUID() },
            includeGlobalMemoryInspection: false
        )
        XCTAssertEqual(
            Set(registry.allDescriptors.map(\.name)),
            Set([MemoryRememberTool.name, MemoryRecallTool.name])
        )
        // Cross-task inspection/maintenance stays unexposed until per-entry
        // ownership exists; a discoverable name must never imply a runner.
        for name in [
            "memory.search", "memory.list", "memory.update",
            "memory.forget", "memory.organizePreview", "memory.batchApply",
        ] {
            XCTAssertNil(registry.descriptor(named: name), name)
        }
    }

    func testTaskScopedMemoryResolvesOnlyTheOwningRun() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = SQLiteIntelligenceStore(database: database)
        let registry = ToolRunnerRegistry()
        let runID = UUID()
        let conversationID = UUID()
        registerMemoryTools(
            registry: registry,
            store: store,
            taskIDForRun: { id in id == runID ? conversationID : nil },
            includeGlobalMemoryInspection: true
        )
        let remember = try XCTUnwrap(registry.runner(named: MemoryRememberTool.name))
        _ = try await remember.run(
            Data(#"{"content":"task scoped probe","scope":"task"}"#.utf8),
            ToolContext(runID: runID, cancellation: CancellationToken())
        )
        let recall = try XCTUnwrap(registry.runner(named: MemoryRecallTool.name))
        let own = try await recall.run(
            Data(#"{"scope":"task"}"#.utf8),
            ToolContext(runID: runID, cancellation: CancellationToken())
        )
        XCTAssertEqual(own.exitStatus, 0)
        XCTAssertTrue(own.summary.contains("task scoped probe"))

        // A different/unknown run can never read that task scope.
        let foreign = try await recall.run(
            Data(#"{"scope":"task"}"#.utf8),
            ToolContext(runID: UUID(), cancellation: CancellationToken())
        )
        XCTAssertEqual(foreign.exitStatus, 1)
        XCTAssertTrue(foreign.summary.contains("memory owner task is unavailable"))
    }

    func testMemoryWriteWithoutAProvenOwnerTaskFailsClosedAndStoresNothing() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = SQLiteIntelligenceStore(database: database)
        let registry = ToolRunnerRegistry()

        registerMemoryTools(
            registry: registry,
            store: store,
            taskIDForRun: { _ in nil },
            includeGlobalMemoryInspection: true
        )
        let remember = try XCTUnwrap(registry.runner(named: MemoryRememberTool.name))
        let output = try await remember.run(
            Data(#"{"content":"orphan fact","scope":"global"}"#.utf8),
            ToolContext(runID: UUID(), cancellation: CancellationToken())
        )
        XCTAssertEqual(output.exitStatus, 1)
        XCTAssertTrue(output.summary.contains("memory owner task is unavailable"))
        let entries = try await store.memories(scope: .agentGlobal, status: .active)
        XCTAssertFalse(entries.contains { $0.content == "orphan fact" })
    }

    func testRetiredGenerationIsInvisibleToDiscoveryAndExecution() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = SQLiteIntelligenceStore(database: database)
        let registry = ToolRunnerRegistry()

        registerMemoryTools(
            registry: registry,
            store: store,
            taskIDForRun: { _ in UUID() },
            isAvailable: { false }
        )
        XCTAssertTrue(registry.allDescriptors.isEmpty)
        for name in Self.memoryToolNames {
            XCTAssertNil(registry.descriptor(named: name), "runner \(name)")
            XCTAssertNil(registry.runner(named: name), "callable \(name)")
        }
    }

    func testMemoryWriteNeedsHumanApproval() async throws {
        let writeCall = try ToolCall(
            id: "memory-write",
            toolName: MemoryRememberTool.name,
            argumentsJSON: Data(#"{"content":"needs approval"}"#.utf8),
            scope: .local
        )
        let writeAction = ProposedAction(
            toolCall: writeCall,
            riskLabels: [RiskLabel.persistsPersonalData.rawValue],
            userGoal: "remember this preference",
            hostAndPathScope: .local
        )
        switch try await HumanApprovalPolicy().decide(writeAction) {
        case .escalateToHuman:
            break
        case .allow:
            XCTFail("A durable personal-data write must not auto-allow in Ask mode")
        default:
            XCTFail("A durable personal-data write must reach the human approval card")
        }

        // Recall is a pure read: the runtime bypasses the side-effecting
        // approval path for it (it is not sent through `policy.decide`).
        XCTAssertFalse(MemoryRecallTool.isSideEffecting)
        XCTAssertEqual(MemoryRecallTool.toolEffect, .readOnly)
    }

    // MARK: - Conversation history

    func testConversationReadToolsRegisterAndSpawnStaysUnadvertised() async throws {
        let reader = FixtureHistoryReader(current: UUID(), other: UUID())
        let registry = ToolRunnerRegistry()

        registerConversationTools(
            registry: registry,
            reader: reader,
            authorize: FixtureHistoryReader.authorizer(for: reader)
        )

        for name in Self.conversationReadNames {
            XCTAssertNotNil(registry.descriptor(named: name), "runner \(name)")
        }
        // No spawner was supplied: the side-effecting tool is neither
        // discoverable nor callable through this registry.
        XCTAssertNil(registry.descriptor(named: ConversationSpawnTool.name))
        XCTAssertNil(registry.runner(named: ConversationSpawnTool.name))
    }

    func testConversationSearchAndListExcludeTheOwningTask() async throws {
        let current = UUID()
        let other = UUID()
        let reader = FixtureHistoryReader(current: current, other: other)
        let registry = ToolRunnerRegistry()
        let runID = UUID()
        registerConversationTools(
            registry: registry,
            reader: reader,
            authorize: FixtureHistoryReader.authorizer(for: reader)
        )

        let search = try XCTUnwrap(registry.runner(named: ConversationSearchTool.name))
        let searchOutput = try await search.run(
            Data(#"{"query":"match"}"#.utf8),
            ToolContext(
                runID: runID,
                cancellation: CancellationToken(),
                conversationID: current
            )
        )
        XCTAssertEqual(searchOutput.exitStatus, 0)
        XCTAssertTrue(searchOutput.summary.contains(other.uuidString))
        XCTAssertFalse(searchOutput.summary.contains(current.uuidString))

        let list = try XCTUnwrap(registry.runner(named: ConversationListTool.name))
        let listOutput = try await list.run(
            Data(#"{}"#.utf8),
            ToolContext(
                runID: runID,
                cancellation: CancellationToken(),
                conversationID: current
            )
        )
        XCTAssertEqual(listOutput.exitStatus, 0)
        XCTAssertTrue(listOutput.summary.contains(other.uuidString))
        XCTAssertFalse(listOutput.summary.contains(current.uuidString))
    }

    func testConversationToolsFailClosedWithoutAnActiveOwnedRun() async throws {
        let reader = FixtureHistoryReader(current: UUID(), other: UUID())
        let registry = ToolRunnerRegistry()
        registerConversationTools(
            registry: registry,
            reader: reader,
            authorize: FixtureHistoryReader.authorizer(for: reader)
        )
        // No runtime-issued conversation identity: an unknown/stale run must
        // never be treated as "no current task, therefore show everything".
        let context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        let search = try XCTUnwrap(registry.runner(named: ConversationSearchTool.name))
        let searchOutput = try await search.run(
            Data(#"{"query":"match"}"#.utf8), context)
        XCTAssertEqual(searchOutput.exitStatus, 1)
        XCTAssertTrue(searchOutput.summary.contains("active task owner is unavailable"))

        let list = try XCTUnwrap(registry.runner(named: ConversationListTool.name))
        let listOutput = try await list.run(Data(#"{}"#.utf8), context)
        XCTAssertEqual(listOutput.exitStatus, 1)
        XCTAssertTrue(listOutput.summary.contains("active task owner is unavailable"))

        let read = try XCTUnwrap(registry.runner(named: ConversationReadTool.name))
        let readOutput = try await read.run(
            try JSONSerialization.data(withJSONObject: ["conversationID": reader.other.uuidString]),
            context
        )
        XCTAssertEqual(readOutput.exitStatus, 1)
        XCTAssertTrue(readOutput.summary.contains("outside the active task"))
    }

    func testModelArgumentsCannotWidenTheTrustedWorkspaceScope() async throws {
        let current = UUID()
        let other = UUID()
        let reader = FixtureHistoryReader(current: current, other: other)
        let registry = ToolRunnerRegistry()
        let runID = UUID()
        registerConversationTools(
            registry: registry,
            reader: reader,
            authorize: FixtureHistoryReader.authorizer(for: reader)
        )
        let context = ToolContext(
            runID: runID,
            cancellation: CancellationToken(),
            conversationID: current
        )
        let search = try XCTUnwrap(registry.runner(named: ConversationSearchTool.name))

        let allWorkspaces = try await search.run(
            Data(#"{"query":"match","includeAllWorkspaces":true}"#.utf8), context)
        XCTAssertEqual(allWorkspaces.exitStatus, 1)
        XCTAssertTrue(allWorkspaces.summary.contains("cross-workspace"))

        let foreignWorkspace = try await search.run(
            try JSONSerialization.data(withJSONObject: [
                "query": "match",
                "workspaceID": UUID().uuidString,
            ]),
            context
        )
        XCTAssertEqual(foreignWorkspace.exitStatus, 1)
        XCTAssertTrue(foreignWorkspace.summary.contains("outside the active task's scope"))

        let list = try XCTUnwrap(registry.runner(named: ConversationListTool.name))
        let listOutput = try await list.run(
            try JSONSerialization.data(withJSONObject: [
                "workspaceID": UUID().uuidString,
            ]),
            context
        )
        XCTAssertEqual(listOutput.exitStatus, 1)
        XCTAssertTrue(listOutput.summary.contains("outside the active task's scope"))
    }

    func testConversationReadRefusesTheOwningTaskAndReturnsQuotedOtherHistory() async throws {
        let current = UUID()
        let other = UUID()
        let reader = FixtureHistoryReader(current: current, other: other)
        let registry = ToolRunnerRegistry()
        let runID = UUID()
        registerConversationTools(
            registry: registry,
            reader: reader,
            authorize: FixtureHistoryReader.authorizer(for: reader)
        )
        let read = try XCTUnwrap(registry.runner(named: ConversationReadTool.name))
        let context = ToolContext(
            runID: runID,
            cancellation: CancellationToken(),
            conversationID: current
        )

        let selfRead = try await read.run(
            try JSONSerialization.data(withJSONObject: ["conversationID": current.uuidString]),
            context
        )
        XCTAssertEqual(selfRead.exitStatus, 1)
        XCTAssertTrue(selfRead.summary.contains("already the active task context"))

        let otherRead = try await read.run(
            try JSONSerialization.data(withJSONObject: ["conversationID": other.uuidString]),
            context
        )
        XCTAssertEqual(otherRead.exitStatus, 0)
        XCTAssertTrue(otherRead.summary.contains("quoted-other-body"))
        XCTAssertTrue(otherRead.summary.contains(other.uuidString))
    }

    func testRetiredGenerationRemovesConversationReadTools() async throws {
        let reader = FixtureHistoryReader(current: UUID(), other: UUID())
        let registry = ToolRunnerRegistry()
        registerConversationTools(
            registry: registry,
            reader: reader,
            authorize: FixtureHistoryReader.authorizer(for: reader),
            isAvailable: { false }
        )
        XCTAssertTrue(registry.allDescriptors.isEmpty)
        for name in Self.conversationReadNames {
            XCTAssertNil(registry.descriptor(named: name), "runner \(name)")
        }
    }
}

/// Minimal deterministic reader: one hit in the current task and one in
/// another task. Reads always return one quoted message so the tool's
/// current-task refusal and body envelope are both exercised.
private struct FixtureHistoryReader: ConversationHistoryReader {
    let current: UUID
    let other: UUID
    let workspace: UUID

    init(current: UUID, other: UUID, workspace: UUID = UUID()) {
        self.current = current
        self.other = other
        self.workspace = workspace
    }

    /// A real composition authorizes from durable run + conversation +
    /// workspace ownership. This fixture mirrors that contract: the runtime
    /// context must carry the SAME conversation, and only the two known tasks
    /// are inside the trusted workspace scope.
    static func authorizer(for reader: FixtureHistoryReader) -> ConversationHistoryAuthorizer {
        { context, targetConversationID in
            guard context.conversationID == reader.current else { return nil }
            if let targetConversationID,
               targetConversationID != reader.current,
               targetConversationID != reader.other {
                return nil
            }
            return ConversationHistoryScope(
                conversationID: reader.current,
                workspaceID: reader.workspace
            )
        }
    }

    func search(_ request: ConversationSearchRequest) async throws -> [ConversationSearchHit] {
        [
            ConversationSearchHit(
                conversationID: current,
                messageID: UUID(),
                conversationTitle: "Current task",
                snippet: "current-only-match",
                createdAt: Date()
            ),
            ConversationSearchHit(
                conversationID: other,
                messageID: UUID(),
                conversationTitle: "Other task",
                snippet: "other-only-match",
                createdAt: Date()
            ),
        ]
    }

    func read(_ request: ConversationPageRequest) async throws -> ConversationHistoryPage {
        ConversationHistoryPage(
            conversationID: request.conversationID,
            messages: [
                ConversationHistoryMessage(
                    id: UUID(),
                    role: "user",
                    content: "quoted-other-body",
                    createdAt: Date()
                )
            ]
        )
    }

    func readMessages(ids: [UUID]) async throws -> [ConversationHistoryMessage] { [] }

    func list(_ request: ConversationListRequest) async throws -> [ConversationListEntry] {
        [
            ConversationListEntry(
                conversationID: current, title: "Current task", updatedAt: Date()),
            ConversationListEntry(
                conversationID: other, title: "Other task", updatedAt: Date()),
        ]
    }
}
