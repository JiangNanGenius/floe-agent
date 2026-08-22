import Foundation
import Testing
import GRDB
import FloeCore
import FloeModels
@testable import FloePersistence

@Suite("FloePersistence.RunLaunchStore")
struct RunLaunchStoreTests {
    private func database() async throws -> DatabaseManager {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        return database
    }

    @Test("Unavailable provider/model fails preflight without creating a conversation")
    func unavailableModelFailsBeforeLaunch() async throws {
        let database = try await database()
        let launchStore = SQLiteRunLaunchStore(database: database)
        await #expect(throws: FloeError.self) {
            try await launchStore.prepare(RunLaunchRequest(
                conversationTitle: "Broken local launch",
                goal: "hello",
                providerID: ProviderProfile.onDeviceProviderID,
                modelID: UUID(uuidString: "A1480001-0000-4000-8000-000000000001")
            ))
        }
        let counts = try await database.reader { db in
            [
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversations") ?? -1,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM runs") ?? -1
            ]
        }
        #expect(counts == [0, 0])
    }

    @Test("New task commits conversation, run, message, attachments and workspace link together")
    func preparesCompleteNewTask() async throws {
        let database = try await database()
        let launchStore = SQLiteRunLaunchStore(database: database)
        let conversations = SQLiteConversationStore(database: database)
        let runs = SQLiteRunStore(database: database)
        let workspaces = SQLiteWorkspaceStore(database: database)
        let workspace = WorkspaceRecord(name: "Demo", rootBookmark: Data([1, 2, 3]))
        try await workspaces.saveWorkspace(workspace)
        let attachment = AttachmentRef(
            kind: .document,
            displayName: "notes.md",
            uti: "net.daringfireball.markdown",
            byteCount: 42,
            sha256: "abc"
        )

        let prepared = try await launchStore.prepare(RunLaunchRequest(
            conversationTitle: "Inspect notes",
            goal: "Inspect notes",
            workspaceID: workspace.id,
            attachments: [attachment],
            conversationMode: "goal"
        ))

        #expect(prepared.createdConversation)
        #expect(prepared.workspace.id == workspace.id)
        #expect(try await conversations.conversation(id: prepared.conversation.id) != nil)
        #expect(try await runs.run(id: prepared.run.id)?.conversationID == prepared.conversation.id)
        let messages = try await conversations.messages(conversationID: prepared.conversation.id)
        #expect(messages.count == 1)
        #expect(messages[0].runID == prepared.run.id)
        #expect(messages[0].parts.map(\.kind) == [.text, .file])
        #expect(try await conversations.attachments(conversationID: prepared.conversation.id).count == 1)
        #expect(try await workspaces.conversations(workspaceID: workspace.id) == [prepared.conversation.id])
        #expect(try await runs.events(runID: prepared.run.id).map(\.kind) == [.status])
        let mode = try await database.reader { db in
            try String.fetchOne(
                db, sql: "SELECT mode FROM conversations WHERE id = ?",
                arguments: [prepared.conversation.id.uuidString]
            )
        }
        #expect(mode == "goal")
    }

    @Test("Missing existing conversation inserts no run")
    func rejectsMissingConversationWithoutOrphan() async throws {
        let database = try await database()
        let launchStore = SQLiteRunLaunchStore(database: database)
        let runID = UUID()

        await #expect(throws: (any Error).self) {
            try await launchStore.prepare(RunLaunchRequest(
                conversationID: UUID(),
                runID: runID,
                goal: "orphan"
            ))
        }

        let count = try await database.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM runs WHERE id = ?", arguments: [runID.uuidString]) ?? -1
        }
        #expect(count == 0)
    }

    @Test("Workspace validation failure rolls back the newly-created conversation")
    func workspaceFailureRollsBackWholeLaunch() async throws {
        let database = try await database()
        let launchStore = SQLiteRunLaunchStore(database: database)

        await #expect(throws: (any Error).self) {
            try await launchStore.prepare(RunLaunchRequest(
                conversationTitle: "Must roll back",
                goal: "test",
                workspaceID: UUID()
            ))
        }

        let counts = try await database.reader { db in
            let conversations = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversations") ?? -1
            let runs = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM runs") ?? -1
            let messages = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages") ?? -1
            return [conversations, runs, messages]
        }
        #expect(counts == [0, 0, 0])
    }

    @Test("Unscoped task receives exactly one private workspace and policy")
    func createsPrivateTaskWorkspace() async throws {
        let database = try await database()
        let prepared = try await SQLiteRunLaunchStore(database: database).prepare(
            RunLaunchRequest(
                conversationTitle: "Private chat",
                goal: "hello",
                initialPolicy: DraftTaskPolicy(
                    approvalMode: .automatic,
                    recoveryPolicy: .alwaysRetry,
                    notificationPolicy: .critical
                )
            )
        )
        let values: (String?, String?, Int, Int, String?, String?, String?) = try await database.reader { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT w.kind, w.internal_relative_path,
                       (SELECT COUNT(*) FROM conversation_workspace_ownership
                        WHERE conversation_id = ?) AS owner_count,
                       (SELECT COUNT(*) FROM task_policies
                        WHERE conversation_id = ?) AS policy_count
                FROM conversation_workspace_ownership o
                JOIN workspaces w ON w.id = o.workspace_id
                WHERE o.conversation_id = ?
                """, arguments: [
                    prepared.conversation.id.uuidString,
                    prepared.conversation.id.uuidString,
                    prepared.conversation.id.uuidString
                ])
            return (
                row?["kind"], row?["internal_relative_path"],
                row?["owner_count"] ?? 0, row?["policy_count"] ?? 0,
                try String.fetchOne(db, sql: "SELECT approval_mode FROM task_policies WHERE conversation_id = ?", arguments: [prepared.conversation.id.uuidString]),
                try String.fetchOne(db, sql: "SELECT recovery_policy FROM task_policies WHERE conversation_id = ?", arguments: [prepared.conversation.id.uuidString]),
                try String.fetchOne(db, sql: "SELECT notification_policy FROM task_policies WHERE conversation_id = ?", arguments: [prepared.conversation.id.uuidString])
            )
        }
        #expect(values.0 == "privateTask")
        #expect(prepared.workspace.kind == .privateTask)
        #expect(values.1?.contains(prepared.conversation.id.uuidString) == true)
        #expect(values.2 == 1)
        #expect(values.3 == 1)
        #expect(values.4 == TaskApprovalMode.automatic.rawValue)
        #expect(values.5 == TaskRecoveryPolicy.alwaysRetry.rawValue)
        #expect(values.6 == TaskNotificationPolicy.critical.rawValue)
    }
}
