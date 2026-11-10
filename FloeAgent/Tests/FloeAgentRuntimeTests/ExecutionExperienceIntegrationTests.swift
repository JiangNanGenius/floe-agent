import Foundation
import Testing
import FloeCore
import FloeModels
import FloePersistence
@testable import FloeAgentRuntime

@Suite("Execution experience native integration")
struct ExecutionExperienceIntegrationTests {
    private struct Fixture: Sendable {
        let database: DatabaseManager
        let runs: SQLiteRunStore
        let conversations: SQLiteConversationStore
        let workspaces: SQLiteWorkspaceStore
        let service: ExecutionExperienceService

        init() async throws {
            let db = try DatabaseManager.inMemory()
            try await db.migrate()
            database = db
            runs = SQLiteRunStore(database: db)
            conversations = SQLiteConversationStore(database: db)
            workspaces = SQLiteWorkspaceStore(database: db)
            service = ExecutionExperienceService(database: db, runs: runs,
                conversations: conversations, workspaces: workspaces)
        }

        func source(state: String = "completed") async throws -> RunRecord {
            let conversation = ConversationRecord(id: UUID(), title: "Synthetic task",
                createdAt: Date(), updatedAt: Date())
            try await conversations.saveConversation(conversation)
            _ = try await workspaces.ensureWorkspace(conversationID: conversation.id, title: conversation.title)
            let run = RunRecord(id: UUID(), conversationID: conversation.id, state: state,
                goal: "Synthetic evidence", startedAt: Date(), endedAt: Date())
            try await runs.saveRun(run)
            return run
        }

        func receipt(run: RunRecord, callID: String, tool: String) async throws -> ToolOutcomeClassification {
            func payload(_ extra: [String: String]) throws -> String {
                var body = ["id": callID, "tool": tool]
                body.merge(extra, uniquingKeysWith: { _, new in new })
                return String(decoding: try JSONEncoder().encode(body), as: UTF8.self)
            }
            _ = try await runs.appendEvent(runID: run.id, kind: .toolRequest,
                payloadJSON: payload(["input": "PRIVATE_PROJECT_LITERAL"]))
            _ = try await runs.appendEvent(runID: run.id, kind: .toolResult,
                payloadJSON: payload(["status": "ok", "dispatched": "true",
                    "summary": "PRIVATE_OUTPUT_LITERAL", "outputDigest": String(repeating: "a", count: 64)]))
            return .init(callID: callID, toolName: tool, status: "ok", kind: .completed,
                recovery: .none, reason: "Synthetic native completion")
        }
    }

    @Test("Native receipts produce content-free guidance in a different task")
    func nativeToCrossTaskRecall() async throws {
        let fixture = try await Fixture()
        let run = try await fixture.source()
        let read = try await fixture.receipt(run: run, callID: "read", tool: "notes.read")
        let edit = try await fixture.receipt(run: run, callID: "edit", tool: "notes.edit")
        let result = try await fixture.service.recordCompletedRun(runID: run.id,
            conversationID: run.conversationID, stateName: "completed", outcomes: [read, edit], isTemporary: false)
        #expect(result?.status == .created)
        let guidance = try await fixture.service.guidance(workspaceID: UUID(), isTemporary: false,
            availableToolNames: ["notes.read", "notes.edit"], activatedToolNames: ["notes.read", "notes.edit"])
        #expect(guidance?.contains("notes.edit") == true)
        #expect(guidance?.contains("PRIVATE_PROJECT_LITERAL") == false)
        #expect(guidance?.contains("PRIVATE_OUTPUT_LITERAL") == false)
        #expect(guidance?.contains(run.id.uuidString) == false)
        #expect(guidance?.contains("native operation") == true)
    }

    @Test("A completion claim cannot promote missing, unfinished or temporary runs")
    func sourceOwnershipAndTemporaryFence() async throws {
        let fixture = try await Fixture()
        let run = try await fixture.source(state: "checkpointed")
        let outcome = try await fixture.receipt(run: run, callID: "read", tool: "notes.read")
        let missing = try await fixture.service.recordCompletedRun(runID: UUID(),
            conversationID: run.conversationID, stateName: "completed", outcomes: [outcome], isTemporary: false)
        #expect(missing == nil)
        let unfinished = try await fixture.service.recordCompletedRun(runID: run.id,
            conversationID: run.conversationID, stateName: "completed", outcomes: [outcome], isTemporary: false)
        #expect(unfinished == nil)
        let temporary = try await fixture.service.recordCompletedRun(runID: run.id,
            conversationID: run.conversationID, stateName: "completed", outcomes: [outcome], isTemporary: true)
        #expect(temporary == nil)
        #expect(try await ExecutionExperienceStore(database: fixture.database).visibleRecords(workspaceID: nil).isEmpty)
    }

    @Test("Waiting jobs and missing classifications never become completed methods")
    func pendingAndMissingNativeClassifications() async throws {
        let fixture = try await Fixture()
        let run = try await fixture.source()
        var outcome = try await fixture.receipt(run: run, callID: "job", tool: "studio.run")
        outcome.kind = .waitingForResource
        outcome.recovery = .waitForResource
        let waiting = try await fixture.service.recordCompletedRun(runID: run.id,
            conversationID: run.conversationID, stateName: "completed", outcomes: [outcome], isTemporary: false)
        #expect(waiting == nil)
        let missing = try await fixture.service.recordCompletedRun(runID: run.id,
            conversationID: run.conversationID, stateName: "completed", outcomes: [], isTemporary: false)
        #expect(missing == nil)
    }

    @Test("Deleted source and unrelated active tools do not produce new guidance")
    func deletionAndActivationFence() async throws {
        let fixture = try await Fixture()
        let run = try await fixture.source()
        let outcome = try await fixture.receipt(run: run, callID: "read", tool: "notes.read")
        _ = try await fixture.service.recordCompletedRun(runID: run.id,
            conversationID: run.conversationID, stateName: "completed", outcomes: [outcome], isTemporary: false)
        let unrelated = try await fixture.service.guidance(workspaceID: nil, isTemporary: false,
            availableToolNames: ["notes.read", "studio.run"], activatedToolNames: ["studio.run"])
        #expect(unrelated == nil)
        try await fixture.conversations.deleteConversation(id: run.conversationID)
        let deleted = try await fixture.service.recordCompletedRun(runID: run.id,
            conversationID: run.conversationID, stateName: "completed", outcomes: [outcome], isTemporary: false)
        #expect(deleted == nil)
    }

    @Test("A long settled window still ingests with bounded evidence anchors")
    func longWindow() async throws {
        let fixture = try await Fixture()
        let run = try await fixture.source()
        var outcomes: [ToolOutcomeClassification] = []
        for index in 0..<21 {
            outcomes.append(try await fixture.receipt(run: run, callID: "read_\(index)", tool: "notes.read"))
        }
        let result = try await fixture.service.recordCompletedRun(runID: run.id,
            conversationID: run.conversationID, stateName: "completed", outcomes: outcomes, isTemporary: false)
        #expect(result?.status == .created)
        #expect((result?.storedRecord.steps.count ?? 0) <= ExecutionExperienceLimits.maximumRetainedProcedureSteps)
    }

    @Test("A source deleted after the async guard cannot race the SQL upsert")
    func deletionBetweenGuardAndWrite() async throws {
        let fixture = try await Fixture()
        let run = try await fixture.source()
        let outcome = try await fixture.receipt(run: run, callID: "read", tool: "notes.read")
        let events = try await fixture.runs.recentEvents(runID: run.id, limit: 20)
        let observation = try #require(ExecutionExperienceObservationBuilder.observation(
            runID: run.id, conversationID: run.conversationID, workspaceID: nil,
            isTemporary: false, sourceRunCompleted: true, events: events,
            outcomes: [outcome], observedAt: Date()))
        let record = try ExecutionExperiencePolicy().derive(observation, scopeChoice: .generic)
        let store = ExecutionExperienceStore(database: fixture.database)
        do {
            _ = try await store.ingest(guarded: .init(record: record,
                observationID: observation.id,
                evidenceAnchors: [.init(runID: run.id, callID: "read", captureRef: nil)],
                sourceRunID: run.id, sourceConversationID: run.conversationID,
                originIsLive: {
                    try? await fixture.conversations.deleteConversation(id: run.conversationID)
                    return true // Deliberately stale result from the async check.
                }))
            Issue.record("A deleted native source must reject the entire write")
        } catch {
            #expect(error is FloeError)
        }
        #expect(try await store.storedRecordCount() == 0)
    }

    @Test("Native deletion transactions purge source pointers and workspace-scoped methods")
    func automaticSourceAndWorkspaceDeletion() async throws {
        let fixture = try await Fixture()
        let run = try await fixture.source()
        let workspaceID = try #require(await fixture.workspaces.workspaceID(conversationID: run.conversationID))
        let read = try await fixture.receipt(run: run, callID: "read", tool: "notes.read")
        let firstEvents = try await fixture.runs.recentEvents(runID: run.id, limit: 20)
        let first = try #require(ExecutionExperienceObservationBuilder.observation(
            runID: run.id, conversationID: run.conversationID, workspaceID: workspaceID,
            isTemporary: false, sourceRunCompleted: true, events: firstEvents,
            outcomes: [read], observedAt: Date()))
        let scoped = try ExecutionExperiencePolicy().derive(first, scopeChoice: .workspace)
        let store = ExecutionExperienceStore(database: fixture.database)
        _ = try await store.ingest(record: scoped, observationID: first.id,
            evidenceAnchors: [.init(runID: run.id, callID: "read", captureRef: nil)],
            sourceRunID: run.id, sourceConversationID: run.conversationID)
        let edit = try await fixture.receipt(run: run, callID: "edit", tool: "notes.edit")
        let generic = try #require(try await fixture.service.recordCompletedRun(runID: run.id,
            conversationID: run.conversationID, stateName: "completed", outcomes: [read, edit], isTemporary: false))
        #expect(try await store.evidenceAnchors(experienceID: generic.recordID).count == 2)
        try await fixture.conversations.deleteConversation(id: run.conversationID)
        #expect(try await store.evidenceAnchors(experienceID: generic.recordID).isEmpty)
        #expect(try await store.record(id: generic.recordID) != nil)
        try await fixture.workspaces.deleteWorkspace(id: workspaceID)
        #expect(try await store.record(id: scoped.id) == nil)
        #expect(try await store.record(id: generic.recordID)?.originWorkspaceID == nil)
    }
}
