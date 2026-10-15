// FloeExecutionTests — the model-facing `task.schedule` service interface:
// create must work without a caller-supplied id, bindings are frozen from the
// APP's trusted resolver (never from model arguments), and after-success is
// bound to a concrete upstream run.

import Foundation
import Testing
import FloeCore
import FloeModels
import FloeTools
@testable import FloePersistence
@testable import FloeExecution

@Suite("task.schedule tool")
struct TaskScheduleToolTests {

    /// Counts shared-pass invocations from the @Sendable `onScheduleDue`
    /// closure (self-contained: this file also compiles in the SwiftPM
    /// FloeExecutionTests target, which has no cross-file test helpers).
    private actor PassCounter {
        private(set) var count = 0
        func increment() { count += 1 }
    }

    private func makeStore() async throws -> (DatabaseManager, SQLiteTaskScheduleStore) {
        let db = try DatabaseManager.inMemory()
        try await db.migrate()
        return (db, SQLiteTaskScheduleStore(database: db))
    }

    @Test("create works without a caller id and refuses without the trusted resolver")
    func createNeedsResolverNotCallerID() async throws {
        let (_, store) = try await makeStore()
        let tool = TaskScheduleTool(store: store)
        // Validation alone never demands an id for create.
        try tool.validate(
            .init(action: "create", prompt: "daily report", cadence: "daily"))
        await #expect(throws: (any Error).self) {
            try await tool.execute(
                .init(action: "create", prompt: "daily report", cadence: "daily"),
                context: ToolContext(runID: UUID(), cancellation: CancellationToken()))
        }
        // Nothing was persisted by the refused create.
        #expect(try await store.schedules().isEmpty)
    }

    @Test("Bindings are frozen from the trusted resolver, not model arguments")
    func bindingsComeFromResolver() async throws {
        let (db, store) = try await makeStore()
        let workspaceID = UUID()
        // The workspace FK requires a real row; the resolver names a real,
        // app-known workspace rather than a model-supplied string.
        try await db.writer { db in
            try db.execute(sql: """
                INSERT INTO workspaces (id, name, root_bookmark, created_at, updated_at)
                VALUES (?, 'Sched', ?, ?, ?)
                """, arguments: [workspaceID.uuidString, Data(),
                                 ISO8601DateFormatter().string(from: Date()),
                                 ISO8601DateFormatter().string(from: Date())])
        }
        let environmentID = "env-session-1"
        let modelID = UUID()
        let policyJSON = String(
            decoding: try JSONEncoder().encode(DraftTaskPolicy(approvalMode: .automatic)),
            as: UTF8.self)
        let tool = TaskScheduleTool(
            store: store,
            bindingResolver: { _ in
                TaskScheduleBinding(
                    workspaceID: workspaceID,
                    environmentID: environmentID,
                    modelID: modelID,
                    permissionJSON: policyJSON,
                    anchorTimezone: "America/New_York")
            })
        let output = try await tool.execute(
            .init(action: "create", prompt: "sync the repo", cadence: "weekly"),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken()))
        #expect(output.summary.contains("status=ok"))
        let record = try #require(try await store.schedules().first)
        #expect(record.workspaceID == workspaceID)
        #expect(record.environmentID == environmentID)
        #expect(record.modelID == modelID)
        #expect(record.permissionJSON == policyJSON)
        #expect(record.anchorTimezone == "America/New_York")
        #expect(record.cadence == .weekly)
        // The schema exposes no way for the model to mint these bindings.
        #expect(!TaskScheduleTool.parametersJSON.contains("\"modelID\""))
        #expect(!TaskScheduleTool.parametersJSON.contains("\"workspaceID\""))
        #expect(!TaskScheduleTool.parametersJSON.contains("approvalMode"))
    }

    @Test("afterSuccess requires a concrete upstream run id")
    func afterSuccessRequiresUpstreamRun() async throws {
        let (_, store) = try await makeStore()
        let tool = TaskScheduleTool(
            store: store,
            bindingResolver: { _ in TaskScheduleBinding() })
        await #expect(throws: (any Error).self) {
            try await tool.execute(
                .init(action: "create", prompt: "publish", cadence: "afterSuccess"),
                context: ToolContext(runID: UUID(), cancellation: CancellationToken()))
        }
        let upstreamRunID = UUID()
        let output = try await tool.execute(
            .init(action: "create", prompt: "publish", cadence: "afterSuccess",
                  upstreamRunID: upstreamRunID.uuidString),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken()))
        #expect(output.summary.contains(upstreamRunID.uuidString))
        let record = try #require(try await store.schedules().first)
        #expect(record.upstreamRunID == upstreamRunID)
        #expect(record.nextExpectedAt == nil)
    }

    @Test("update/enable/disable/delete/runNow/history still require an id")
    func lifecycleActionsRequireID() async throws {
        let (_, store) = try await makeStore()
        let tool = TaskScheduleTool(store: store, bindingResolver: { _ in TaskScheduleBinding() })
        for action in ["update", "enable", "disable", "delete", "runNow", "history"] {
            #expect(throws: (any Error).self) {
                try tool.validate(.init(action: action))
            }
        }
    }

    @Test("runNow creates a pending occurrence and history reads it back")
    func runNowAndHistory() async throws {
        let (_, store) = try await makeStore()
        let tool = TaskScheduleTool(store: store, bindingResolver: { _ in TaskScheduleBinding() })
        _ = try await tool.execute(
            .init(action: "create", prompt: "go", cadence: "once",
                  scheduledAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken()))
        let record = try #require(try await store.schedules().first)
        let runOutput = try await tool.execute(
            .init(action: "runNow", id: record.id.uuidString),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken()))
        #expect(runOutput.summary.contains("action=runNow"))
        let history = try await tool.execute(
            .init(action: "history", id: record.id.uuidString),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken()))
        #expect(history.summary.contains("state=pending"))
    }

    @Test("delete and disable both run the shared reminder-reconciliation pass")
    func destructiveActionsRunTheSharedPass() async throws {
        let (_, store) = try await makeStore()
        let passes = PassCounter()
        let tool = TaskScheduleTool(
            store: store,
            onScheduleDue: { await passes.increment() },
            bindingResolver: { _ in TaskScheduleBinding() })
        func create(_ prompt: String) async throws -> UUID {
            _ = try await tool.execute(
                .init(action: "create", prompt: prompt, cadence: "daily"),
                context: ToolContext(runID: UUID(), cancellation: CancellationToken()))
            return try #require(try await store.schedules().last).id
        }
        let first = try await create("first")
        let second = try await create("second")
        let afterCreate = await passes.count
        #expect(afterCreate == 2)

        _ = try await tool.execute(
            .init(action: "disable", id: first.uuidString),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken()))
        #expect(await passes.count == afterCreate + 1)

        _ = try await tool.execute(
            .init(action: "delete", id: second.uuidString),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken()))
        #expect(await passes.count == afterCreate + 2)
    }

    @Test("Changing cadence away from afterSuccess clears the stale upstream binding")
    func cadenceEditClearsStaleUpstream() async throws {
        let (_, store) = try await makeStore()
        let tool = TaskScheduleTool(store: store, bindingResolver: { _ in TaskScheduleBinding() })
        let upstream = UUID()
        _ = try await tool.execute(
            .init(action: "create", prompt: "publish", cadence: "afterSuccess",
                  upstreamRunID: upstream.uuidString),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken()))
        var record = try #require(try await store.schedules().first)
        #expect(record.upstreamRunID == upstream)

        _ = try await tool.execute(
            .init(action: "update", id: record.id.uuidString, cadence: "daily"),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken()))
        record = try #require(try await store.schedule(id: record.id))
        #expect(record.cadence == .daily)
        #expect(record.upstreamRunID == nil)
        #expect(record.nextExpectedAt != nil)
    }
}
