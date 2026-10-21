// FloePersistenceTests — durable child checkpoints and the resume lease/CAS
// boundary (schema v49, S7 audit17).
//
// Covers: the v49 table provisioning (including coexistence with the v48
// alarm schema), checkpoint save/load round trips through the shared bounded
// payload codec, exact-state bounding (oversized checkpoints are refused
// without clipping identity or intent), and every lease/CAS transition — finished-child
// refusal, single-resumer convergence, expired-lease re-acquire after a
// crash, launch reconciliation of stale leases, and cancel restoring the
// honest interrupted state.

import Foundation
import GRDB
import Testing
@testable import FloePersistence

@Suite("FloePersistence.ChildRunCheckpoints")
struct ChildRunStoreTests {

    // MARK: - Schema

    @Test("the v49 checkpoint table provisions standalone and coexists with the v48 alarm schema")
    func schemaProvisionsAndCoexists() async throws {
        let queue = try DatabaseQueue()
        try await queue.write { db in
            try SystemAlarmSchema.apply(db)
            try ChildRunCheckpointSchema.apply(db)
            try db.execute(sql: "PRAGMA user_version = 49")
        }
        let tables = try await queue.read { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master WHERE type = 'table'
                    AND name IN ('child_run_checkpoints', 'system_alarms')
                ORDER BY name
                """)
        }
        #expect(tables == ["child_run_checkpoints", "system_alarms"])
        let version = try await queue.read { db in
            try Int.fetchOne(db, sql: "PRAGMA user_version")
        }
        #expect(version == 49)
    }

    @Test("the v49 migration registers under its own identifier and does not compete with v48")
    func migrationRegistration() async throws {
        var migrator = DatabaseMigrator()
        V49ChildRunCheckpoints.register(into: &migrator)
        let queue = try DatabaseQueue()
        try migrator.migrate(queue)
        let version = try await queue.read { db in
            try Int.fetchOne(db, sql: "PRAGMA user_version")
        }
        #expect(version == 49)
        let applied = try await queue.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }
        #expect(applied == ["v49_child_run_checkpoints"])
    }

    @Test("oversized continuation state is refused; bounded intent round trips exactly")
    func payloadCodecBoundsOversizedValues() throws {
        let checkpoint = ChildRunCheckpoint(
            childID: UUID(),
            kind: .postCall,
            iterationsUsed: 2,
            hardCeiling: 6,
            requestKind: "explore",
            task: String(repeating: "task-", count: 120_000),
            context: nil,
            messages: [.init(role: "user", content: String(repeating: "m", count: 100_000))],
            replayedPairs: [],
            pendingCalls: [],
            pendingSettled: [],
            pendingReasoning: nil,
            discovery: .init(loadedNames: [], priorityNames: [], revision: 0),
            skillRevisions: [:],
            activeSkillIDs: [],
            droppedReplayedPairs: 0,
            droppedAssistantMessages: 0,
            truncatedResultOutputs: 0,
            peerMessagesDelivered: 0,
            evidence: [],
            pendingRoutes: [],
            lastAssistantText: "",
            providerID: UUID().uuidString,
            modelID: UUID().uuidString,
            originalParentRunID: UUID(),
            rootRunID: UUID(),
            conversationID: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            savedAt: Date(timeIntervalSince1970: 1_700_000_001),
            resumedParentRunID: nil,
            resumeCount: 0,
            recoveryHoldCallIDs: []
        )
        #expect(throws: (any Error).self) { try SQLiteChildRunStore.encodeCheckpoint(checkpoint) }
        var exact = checkpoint
        exact.task = "bounded task"
        exact.messages = [.init(role: "user", content: "resume exact state")]
        exact.pendingCalls = [.init(id: "write-exact", toolName: "test.write",
                                    argumentsJSON: "{\"text\":\"" + String(repeating: "字", count: 20_000) + "\"}")]
        let encoded = try SQLiteChildRunStore.encodeCheckpoint(exact)
        let decoded = try SQLiteChildRunStore.decodeCheckpoint(encoded)
        #expect(decoded == exact)
        #expect(decoded.pendingCalls[0].argumentsJSON == exact.pendingCalls[0].argumentsJSON)

    }

    // MARK: - Store round trips (SQLite, table provisioned directly)

    private func makeStore() async throws -> SQLiteChildRunStore {
        let manager = try DatabaseManager.inMemory()
        try await manager.migrate()
        // The v49 registration patch is the integrator's to apply; provision
        // the table directly so these tests stand alone.
        try await manager.writer { db in
            try ChildRunCheckpointSchema.apply(db)
        }
        return SQLiteChildRunStore(database: manager)
    }

    private func sampleCheckpoint(
        childID: UUID,
        parentRunID: UUID,
        rootRunID: UUID,
        kind: ChildRunCheckpointKind = .postCall,
        iterationsUsed: Int = 1
    ) -> ChildRunCheckpoint {
        ChildRunCheckpoint(
            childID: childID,
            kind: kind,
            iterationsUsed: iterationsUsed,
            hardCeiling: 6,
            requestKind: "explore",
            task: "inspect",
            context: nil,
            messages: [.init(role: "system", content: "sys"), .init(role: "user", content: "inspect")],
            replayedPairs: [],
            pendingCalls: [],
            pendingSettled: [],
            pendingReasoning: nil,
            discovery: .init(loadedNames: ["tools.search"], priorityNames: [], revision: 0),
            skillRevisions: ["skill.a": "rev1"],
            activeSkillIDs: ["skill.a"],
            droppedReplayedPairs: 0,
            droppedAssistantMessages: 0,
            truncatedResultOutputs: 0,
            peerMessagesDelivered: 0,
            evidence: ["evidence"],
            pendingRoutes: ["test.read deadbeef"],
            lastAssistantText: "",
            providerID: UUID().uuidString,
            modelID: UUID().uuidString,
            originalParentRunID: parentRunID,
            rootRunID: rootRunID,
            conversationID: rootRunID,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            savedAt: Date(timeIntervalSince1970: 1_700_000_001),
            resumedParentRunID: nil,
            resumeCount: 0,
            recoveryHoldCallIDs: []
        )
    }

    @Test("checkpoint save/load round trips through SQLite with full fidelity")
    func saveLoadRoundTrip() async throws {
        let store = try await makeStore()
        let childID = UUID()
        let parent = UUID()
        let root = UUID()
        try await store.register(ChildRunRecord(
            id: childID, parentRunID: parent, rootRunID: root, conversationID: root,
            childIndex: 1, kind: "explore", taskSummary: "inspect", state: .interrupted
        ))
        let checkpoint = sampleCheckpoint(childID: childID, parentRunID: parent, rootRunID: root)
        try await store.saveCheckpoint(checkpoint)
        let loaded = try #require(await store.checkpoint(childRunID: childID))
        #expect(loaded == checkpoint)
        // A plain save does NOT create a live lease: the very next acquire
        // succeeds immediately.
        #expect(try await store.acquireResume(
            childRunID: childID, owner: UUID(), resumingParentRunID: UUID(),
            leaseExpiresAt: Date().addingTimeInterval(60)
        ))
        // Upsert replaces the payload.
        var updated = checkpoint
        updated.iterationsUsed = 3
        try await store.saveCheckpoint(updated)
        #expect(try #require(await store.checkpoint(childRunID: childID)).iterationsUsed == 3)
        try await store.deleteCheckpoint(childRunID: childID)
        #expect(try await store.checkpoint(childRunID: childID) == nil)
    }

    // MARK: - Lease / CAS transitions

    @Test("acquireResume refuses terminal children, grants once, and re-acquires after lease expiry")
    func acquireRefusesTerminalAndConverges() async throws {
        let store = try await makeStore()
        let childID = UUID()
        let parent = UUID()
        let root = UUID()
        try await store.register(ChildRunRecord(
            id: childID, parentRunID: parent, rootRunID: root, conversationID: root,
            childIndex: 1, kind: "explore", taskSummary: "inspect", state: .interrupted
        ))
        try await store.saveCheckpoint(sampleCheckpoint(
            childID: childID, parentRunID: parent, rootRunID: root
        ))

        let owner = UUID()
        let resumer = UUID()
        // First acquire wins and flips the child back to running.
        #expect(try await store.acquireResume(
            childRunID: childID, owner: owner, resumingParentRunID: resumer,
            leaseExpiresAt: Date().addingTimeInterval(60)
        ))
        let record = try #require(await store.child(id: childID))
        #expect(record.state == .running)
        // A second acquire with a live lease is refused.
        #expect(!(try await store.acquireResume(
            childRunID: childID, owner: UUID(), resumingParentRunID: UUID(),
            leaseExpiresAt: Date().addingTimeInterval(60)
        )))
        // Passing an expired NEW lease cannot replace an existing live owner.
        #expect(!(try await store.acquireResume(
            childRunID: childID, owner: UUID(), resumingParentRunID: resumer,
            leaseExpiresAt: Date().addingTimeInterval(-1)
        )))
        try await store.cancelResume(childRunID: childID, owner: owner)
        let nextOwner = UUID()
        #expect(try await store.acquireResume(
            childRunID: childID, owner: nextOwner, resumingParentRunID: resumer,
            leaseExpiresAt: Date().addingTimeInterval(60)))
        try await store.finishResume(childRunID: childID, owner: nextOwner)
        try await store.transition(id: childID, state: .completed, iterationCount: 1, endedAt: Date())
        #expect(!(try await store.acquireResume(
            childRunID: childID, owner: UUID(), resumingParentRunID: resumer,
            leaseExpiresAt: Date().addingTimeInterval(60)
        )))
    }

    @Test("a child interrupted after a mid-resume crash is resumable again after reconciliation")
    func reconcileResetsStaleLease() async throws {
        let store = try await makeStore()
        let childID = UUID()
        let parent = UUID()
        let root = UUID()
        try await store.register(ChildRunRecord(
            id: childID, parentRunID: parent, rootRunID: root, conversationID: root,
            childIndex: 1, kind: "explore", taskSummary: "inspect", state: .interrupted
        ))
        try await store.saveCheckpoint(sampleCheckpoint(
            childID: childID, parentRunID: parent, rootRunID: root
        ))
        // A resume starts (lease granted, row back to running), then the
        // process dies: the row is still 'running', the lease still names the
        // dead owner.
        let deadOwner = UUID()
        #expect(try await store.acquireResume(
            childRunID: childID, owner: deadOwner, resumingParentRunID: UUID(),
            leaseExpiresAt: Date().addingTimeInterval(60)
        ))
        // Relaunch reconciliation: running → interrupted AND the stale lease
        // resets, so a new resume can acquire.
        let count = try await store.reconcileInterruptedOnLaunch()
        #expect(count == 1)
        let record = try #require(await store.child(id: childID))
        #expect(record.state == .interrupted)
        #expect(try await store.acquireResume(
            childRunID: childID, owner: UUID(), resumingParentRunID: UUID(),
            leaseExpiresAt: Date().addingTimeInterval(60)
        ))
    }

    @Test("cancelResume releases the lease and restores the interrupted state")
    func cancelRestoresInterrupted() async throws {
        let store = try await makeStore()
        let childID = UUID()
        let parent = UUID()
        let root = UUID()
        try await store.register(ChildRunRecord(
            id: childID, parentRunID: parent, rootRunID: root, conversationID: root,
            childIndex: 1, kind: "explore", taskSummary: "inspect", state: .interrupted
        ))
        try await store.saveCheckpoint(sampleCheckpoint(
            childID: childID, parentRunID: parent, rootRunID: root
        ))
        let owner = UUID()
        #expect(try await store.acquireResume(
            childRunID: childID, owner: owner, resumingParentRunID: UUID(),
            leaseExpiresAt: Date().addingTimeInterval(60)
        ))
        try await store.cancelResume(childRunID: childID, owner: owner)
        let record = try #require(await store.child(id: childID))
        #expect(record.state == .interrupted)
        // Re-acquirable immediately.
        #expect(try await store.acquireResume(
            childRunID: childID, owner: UUID(), resumingParentRunID: UUID(),
            leaseExpiresAt: Date().addingTimeInterval(60)
        ))
    }
    @Test("a stale owner cannot save, cancel or settle the new owner's continuation")
    func staleOwnerCannotMutateContinuation() async throws {
        let store = try await makeStore()
        let id = UUID(), parent = UUID(), root = UUID(), first = UUID(), second = UUID()
        try await store.register(ChildRunRecord(id: id, parentRunID: parent, rootRunID: root,
            conversationID: root, childIndex: 1, kind: "explore", taskSummary: "inspect", state: .interrupted))
        let checkpoint = sampleCheckpoint(childID: id, parentRunID: parent, rootRunID: root)
        try await store.saveCheckpoint(checkpoint)
        #expect(try await store.acquireResume(childRunID: id, owner: first, resumingParentRunID: parent,
            leaseExpiresAt: Date().addingTimeInterval(60), expectedCheckpoint: checkpoint))
        #expect(try await store.markResumeStarted(childRunID: id, owner: first))
        try await store.cancelResume(childRunID: id, owner: first)
        #expect(try await store.acquireResume(childRunID: id, owner: second, resumingParentRunID: parent,
            leaseExpiresAt: Date().addingTimeInterval(60), expectedCheckpoint: checkpoint))
        #expect(try await store.markResumeStarted(childRunID: id, owner: second))
        await #expect(throws: (any Error).self) {
            try await store.saveCheckpoint(checkpoint, owner: first, leaseExpiresAt: Date().addingTimeInterval(60))
        }
        await #expect(throws: (any Error).self) { try await store.cancelResume(childRunID: id, owner: first) }
        await #expect(throws: (any Error).self) {
            try await store.finishResumedChild(id: id, owner: first, state: .completed,
                iterationCount: 2, resultSummary: "stale", errorText: nil, digest: nil)
        }
        #expect(try await store.child(id: id)?.state == .running)
        #expect(try await store.checkpoint(childRunID: id) == checkpoint)
        try await store.saveCheckpoint(checkpoint, owner: second, leaseExpiresAt: Date().addingTimeInterval(60))
        try await store.finishResumedChild(id: id, owner: second, state: .completed,
            iterationCount: 2, resultSummary: "actual", errorText: nil, digest: nil)
        #expect(try await store.child(id: id)?.resultSummary == "actual")
        #expect(try await store.checkpoint(childRunID: id) == nil)
    }

    @Test("resume admission binds the exact checkpoint, not only its child ID")
    func admissionBindsExactPayload() async throws {
        let store = try await makeStore()
        let id = UUID(), parent = UUID(), root = UUID()
        try await store.register(ChildRunRecord(id: id, parentRunID: parent, rootRunID: root,
            conversationID: root, childIndex: 1, kind: "explore", taskSummary: "inspect", state: .interrupted))
        var snapshot = sampleCheckpoint(childID: id, parentRunID: parent, rootRunID: root)
        try await store.saveCheckpoint(snapshot)
        snapshot.iterationsUsed += 1
        #expect(!(try await store.acquireResume(childRunID: id, owner: UUID(), resumingParentRunID: parent,
            leaseExpiresAt: Date().addingTimeInterval(60), expectedCheckpoint: snapshot)))
        #expect(try await store.child(id: id)?.state == .interrupted)
    }

}
