// FloePersistenceTests — execution experience store contract.
//
// Covers the acceptance-critical behaviours of the persisted layer:
// duplicate ingestion and reopen, source-evidence binding, scope fences
// (workspace isolation + fail-closed activation relevance), current tool
// availability filtering, bounded recall, caps/retention/deletion, and the
// rule that the store NEVER lazily creates the migration's tables.
//
// The tests install the canonical V60 DDL out-of-band via
// `V60ExecutionExperiences.apply(_:)` because production registration in
// `DatabaseManager.registerMigrations` is the mainline owner's pending
// wiring step; this is the same single DDL source, not a second schema.

import Foundation
import GRDB
import Testing
@testable import FloePersistence
import FloeModels

private let settledDate = Date(timeIntervalSince1970: 1_700_000_000)

private func hexDigest(_ value: Int) -> String {
    String(format: "%064x", value)
}

private func makeRecord(
    tools: [String],
    scope: ExecutionExperienceScope,
    evidence: ExecutionEvidenceStrength = .observedCompletion,
    observedAt: Date = settledDate,
    originWorkspaceID: UUID? = nil,
    occurrence: Int = 1,
    groupId: Int = 0
) -> ExecutionExperienceRecord {
    let steps = tools.enumerated().map { offset, tool in
        ExecutionProcedureStep(
            toolName: tool,
            outcome: .completed,
            role: .primary,
            producesSealedOutput: evidence == .sealedOutputEvidence,
            // Sequential by default: each tool its own attested group so
            // the store signature matches the real ordering contract.
            groupId: groupId == 0 ? offset : groupId
        )
    }
    let signature = ExecutionExperienceRecord.signature(scope: scope, steps: steps)
    return ExecutionExperienceRecord(
        signature: signature,
        scope: scope,
        originWorkspaceID: originWorkspaceID ?? scope.workspaceID,
        steps: steps,
        recoveryPatterns: [],
        evidence: evidence,
        occurrenceCount: occurrence,
        completedStepObservations: tools.count,
        failedStepObservations: 0,
        partialStepObservations: 0,
        waitingStepObservations: 0,
        recoveredFailureObservations: 0,
        closedRunObservations: 0,
        firstObservedAt: observedAt,
        lastObservedAt: observedAt
    )
}

@Suite("Execution experience store")
struct ExecutionExperienceStoreTests {
    /// Fresh in-memory database with the canonical V60 DDL applied
    /// out-of-band (production registration belongs to DatabaseManager).
    private func makeSetup() async throws -> (DatabaseManager, ExecutionExperienceStore) {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        try await database.writer { db in try V60ExecutionExperiences.apply(db) }
        return (database, ExecutionExperienceStore(database: database))
    }

    @Test("The store never lazily creates tables (registration is the migration's job)")
    func noLazyTableCreation() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = ExecutionExperienceStore(database: database)
        // Production now registers V60. Explicitly simulate the unavailable
        // schema in this private fixture, preserving the negative contract.
        try await database.writer { db in
            try db.execute(sql: "DROP TRIGGER IF EXISTS execution_experience_source_run_deleted")
            try db.execute(sql: "DROP TRIGGER IF EXISTS execution_experience_workspace_deleted")
            try db.execute(sql: "DROP TABLE IF EXISTS execution_experience_ingress")
            try db.execute(sql: "DROP TABLE IF EXISTS execution_experience_evidence")
            try db.execute(sql: "DROP TABLE IF EXISTS execution_experiences")
        }
        let record = makeRecord(tools: ["a.one", "a.two"], scope: .generic)
        do {
            _ = try await store.ingest(
                record: record,
                observationID: hexDigest(1),
                evidenceAnchors: []
            )
            Issue.record("Ingest must fail without the registered migration")
        } catch {
            let described = String(describing: error)
            #expect(described.contains("no such table")
                    || described.contains("execution_experience"),
                    "Unexpected error: \(described)")
        }
    }

    @Test("Duplicate ingestion dedupes; a new observation merges monotonically")
    func duplicateAndMerge() async throws {
        let (_, store) = try await makeSetup()
        let record = makeRecord(tools: ["a.one", "a.two"], scope: .generic)
        let first = try await store.ingest(record: record, observationID: hexDigest(1),
                                           evidenceAnchors: [])
        #expect(first.status == .created)
        let replay = try await store.ingest(record: record, observationID: hexDigest(1),
                                            evidenceAnchors: [])
        #expect(replay.status == .duplicate)
        #expect(replay.storedRecord.occurrenceCount == 1)
        let newer = record
        let merged = try await store.ingest(record: newer, observationID: hexDigest(2),
                                            evidenceAnchors: [])
        #expect(merged.status == .merged)
        #expect(merged.storedRecord.occurrenceCount == 2)
        #expect(merged.storedRecord.completedStepObservations == record.completedStepObservations * 2)
        #expect(try await store.storedRecordCount() == 1)
        let reread = try #require(await store.record(id: record.id))
        #expect(reread.occurrenceCount == 2)
    }

    @Test("Evidence anchors bind run/call identity and dedupe, sealed refs kept")
    func evidenceBinding() async throws {
        let (_, store) = try await makeSetup()
        let runID = UUID()
        let record = makeRecord(tools: ["a.one", "a.two"], scope: .generic)
        let ref = "tr_" + String(repeating: "ab", count: 12)
        let anchors = [
            ExecutionExperienceEvidenceAnchor(runID: runID, callID: "call-1", captureRef: nil),
            ExecutionExperienceEvidenceAnchor(runID: runID, callID: "call-2", captureRef: ref)
        ]
        _ = try await store.ingest(record: record, observationID: hexDigest(3),
                                   evidenceAnchors: anchors)
        _ = try await store.ingest(record: record, observationID: hexDigest(4),
                                   evidenceAnchors: anchors)
        let stored = try await store.evidenceAnchors(experienceID: record.id)
        #expect(stored.count == 2)
        #expect(stored.contains { $0.runID == runID && $0.callID == "call-2" && $0.captureRef == ref })
    }

    @Test("File-backed persistence survives reopen")
    func reopen() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-experience-reopen-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let workspace = UUID()
        let record = makeRecord(tools: ["a.one", "a.two"], scope: .workspace(workspace))
        do {
            let database = try DatabaseManager(path: url)
            try await database.migrate()
            try await database.writer { db in try V60ExecutionExperiences.apply(db) }
            let store = ExecutionExperienceStore(database: database)
            _ = try await store.ingest(record: record, observationID: hexDigest(5),
                                       evidenceAnchors: [])
        }
        let reopened = try DatabaseManager(path: url)
        try await reopened.migrate()
        try await reopened.writer { db in try V60ExecutionExperiences.apply(db) }
        let store = ExecutionExperienceStore(database: reopened)
        let loaded = try #require(await store.record(id: record.id))
        #expect(loaded.occurrenceCount == 1)
        #expect(loaded.scope == .workspace(workspace))
        // Re-ingesting the same observation across a restart stays a no-op.
        let replay = try await store.ingest(record: record, observationID: hexDigest(5),
                                            evidenceAnchors: [])
        #expect(replay.status == .duplicate)
    }

    @Test("Workspace isolation: foreign rows never cross the fence")
    func workspaceIsolation() async throws {
        let (_, store) = try await makeSetup()
        let wsA = UUID()
        let wsB = UUID()
        let tools = ["x.one", "x.two"]
        _ = try await store.ingest(record: makeRecord(tools: tools, scope: .workspace(wsA)),
                                   observationID: hexDigest(6), evidenceAnchors: [])
        _ = try await store.ingest(record: makeRecord(tools: tools, scope: .workspace(wsB)),
                                   observationID: hexDigest(7), evidenceAnchors: [])
        _ = try await store.ingest(record: makeRecord(tools: tools, scope: .generic),
                                   observationID: hexDigest(8), evidenceAnchors: [])
        let queryA = ExecutionExperienceRecallQuery(
            workspaceID: wsA, availableToolNames: Set(tools), activatedToolNames: Set(tools)
        )
        let recallA = try await store.recall(queryA)
        #expect(recallA.count == 2)
        #expect(recallA.contains { $0.scope == .workspace(wsA) })
        #expect(recallA.contains { $0.scope == .generic })
        #expect(!recallA.contains { $0.scope == .workspace(wsB) })
        let queryNone = ExecutionExperienceRecallQuery(
            workspaceID: nil, availableToolNames: Set(tools), activatedToolNames: Set(tools)
        )
        let genericOnly = try await store.recall(queryNone)
        #expect(genericOnly.count == 1)
        #expect(genericOnly.first?.scope == .generic)
    }

    @Test("Activation is fail-closed: full catalog availability alone recalls nothing")
    func activationFailClosed() async throws {
        let (_, store) = try await makeSetup()
        let music = ["music.read", "music.render"]
        _ = try await store.ingest(record: makeRecord(tools: music, scope: .generic),
                                   observationID: hexDigest(9), evidenceAnchors: [])
        let fullCatalog = Set(music + ["exec.shell", "document.read"])
        let unrelatedActivation = Set(["exec.shell", "document.read"])
        let noActivation = try await store.recall(ExecutionExperienceRecallQuery(
            workspaceID: nil, availableToolNames: fullCatalog, activatedToolNames: nil
        ))
        #expect(noActivation.isEmpty)
        let emptyActivation = try await store.recall(ExecutionExperienceRecallQuery(
            workspaceID: nil, availableToolNames: fullCatalog, activatedToolNames: []
        ))
        #expect(emptyActivation.isEmpty)
        let otherFamily = try await store.recall(ExecutionExperienceRecallQuery(
            workspaceID: nil, availableToolNames: fullCatalog, activatedToolNames: unrelatedActivation
        ))
        #expect(otherFamily.isEmpty)
        let matched = try await store.recall(ExecutionExperienceRecallQuery(
            workspaceID: nil, availableToolNames: fullCatalog, activatedToolNames: Set(music)
        ))
        #expect(matched.count == 1)
    }

    @Test("Records using tools the current catalog no longer offers are dropped")
    func currentToolAvailability() async throws {
        let (_, store) = try await makeSetup()
        let tools = ["old.read", "old.write"]
        _ = try await store.ingest(record: makeRecord(tools: tools, scope: .generic),
                                   observationID: hexDigest(10), evidenceAnchors: [])
        let partialCatalog = try await store.recall(ExecutionExperienceRecallQuery(
            workspaceID: nil,
            availableToolNames: ["old.read"],
            activatedToolNames: Set(tools)
        ))
        #expect(partialCatalog.isEmpty)
        let fullCatalog = try await store.recall(ExecutionExperienceRecallQuery(
            workspaceID: nil,
            availableToolNames: Set(tools),
            activatedToolNames: Set(tools)
        ))
        #expect(fullCatalog.count == 1)
    }

    @Test("Recall honors the record bound and the recency window")
    func boundedRecall() async throws {
        let (_, store) = try await makeSetup()
        for index in 0..<5 {
            _ = try await store.ingest(
                record: makeRecord(tools: ["b.\(index)one", "b.\(index)two"], scope: .generic),
                observationID: hexDigest(20 + index),
                evidenceAnchors: []
            )
        }
        let bounded = try await store.recall(ExecutionExperienceRecallQuery(
            workspaceID: nil,
            availableToolNames: Set((0..<5).flatMap { ["b.\($0)one", "b.\($0)two"] }),
            activatedToolNames: Set((0..<5).flatMap { ["b.\($0)one", "b.\($0)two"] }),
            maxRecords: 2
        ))
        #expect(bounded.count == 2)
        let recentOnly = try await store.recall(ExecutionExperienceRecallQuery(
            workspaceID: nil,
            availableToolNames: Set((0..<5).flatMap { ["b.\($0)one", "b.\($0)two"] }),
            activatedToolNames: Set((0..<5).flatMap { ["b.\($0)one", "b.\($0)two"] }),
            notOlderThan: settledDate.addingTimeInterval(60),
            maxRecords: 5
        ))
        #expect(recentOnly.isEmpty)
    }

    @Test("Retention drops stale rows only")
    func retention() async throws {
        let (_, store) = try await makeSetup()
        let stale = settledDate.addingTimeInterval(-200 * 86_400)
        _ = try await store.ingest(
            record: makeRecord(tools: ["r.one", "r.two"], scope: .generic, observedAt: stale),
            observationID: hexDigest(30), evidenceAnchors: []
        )
        _ = try await store.ingest(
            record: makeRecord(tools: ["f.one", "f.two"], scope: .generic),
            observationID: hexDigest(31), evidenceAnchors: []
        )
        let removed = try await store.enforceRetention(
            now: settledDate, retentionInterval: 180 * 86_400
        )
        #expect(removed == 1)
        #expect(try await store.storedRecordCount() == 1)
    }

    @Test("Workspace purge deletes scoped rows and clears generic origin locators")
    func purgeWorkspace() async throws {
        let (_, store) = try await makeSetup()
        let doomed = UUID()
        let other = UUID()
        _ = try await store.ingest(
            record: makeRecord(tools: ["p.one", "p.two"], scope: .workspace(doomed)),
            observationID: hexDigest(40), evidenceAnchors: []
        )
        _ = try await store.ingest(
            record: makeRecord(tools: ["p.one", "p.two"], scope: .workspace(other)),
            observationID: hexDigest(41), evidenceAnchors: []
        )
        _ = try await store.ingest(
            record: makeRecord(tools: ["g.one", "g.two"], scope: .generic, originWorkspaceID: doomed),
            observationID: hexDigest(42), evidenceAnchors: []
        )
        let removed = try await store.purgeWorkspace(workspaceID: doomed)
        #expect(removed == 1)
        let survivors = try await store.visibleRecords(workspaceID: other)
        #expect(survivors.contains { $0.scope == .workspace(other) })
        let generic = survivors.first { $0.scope == .generic }
        #expect(generic?.originWorkspaceID == nil)
        let scopedDoomed = try await store.visibleRecords(workspaceID: doomed)
        #expect(!scopedDoomed.contains { $0.scope == .workspace(doomed) })
    }

    @Test("Evidence purge removes anchors pointing at deleted runs")
    func purgeEvidence() async throws {
        let (_, store) = try await makeSetup()
        let doomedRun = UUID()
        let keptRun = UUID()
        let record = makeRecord(tools: ["q.one", "q.two"], scope: .generic)
        _ = try await store.ingest(record: record, observationID: hexDigest(50), evidenceAnchors: [
            ExecutionExperienceEvidenceAnchor(runID: doomedRun, callID: "q1", captureRef: nil),
            ExecutionExperienceEvidenceAnchor(runID: keptRun, callID: "q2", captureRef: nil)
        ])
        let removed = try await store.purgeEvidence(runIDs: [doomedRun])
        #expect(removed == 1)
        let anchors = try await store.evidenceAnchors(experienceID: record.id)
        #expect(anchors.count == 1)
        #expect(anchors.first?.runID == keptRun)
    }

    @Test("Store boundary rejects records that are not data-minimal")
    func storeRejectsNonMinimalRecords() async throws {
        let (_, store) = try await makeSetup()
        var record = makeRecord(tools: ["a.one", "a.two"], scope: .generic)
        record.steps[0].toolName = "evil/path with output"
        await #expect(throws: (any Error).self) {
            // structural validation catches the unsafe identifier before
            // the signature check; either rejection path must not persist.
            try await store.ingest(record: record, observationID: hexDigest(60),
                                   evidenceAnchors: [])
        }
        #expect(try await store.storedRecordCount() == 0)
    }

    @Test("Per-scope bounds evict the oldest rows deterministically")
    func scopeCapEviction() async throws {
        let workspace = UUID()
        let (_, store) = try await makeSetup()
        let count = ExecutionExperienceLimits.maximumRecordsPerScope + 5
        for index in 0..<count {
            let observedAt = settledDate.addingTimeInterval(TimeInterval(index) * 10)
            _ = try await store.ingest(
                record: makeRecord(
                    tools: ["cap.\(index)one", "cap.\(index)two"],
                    scope: .workspace(workspace),
                    observedAt: observedAt
                ),
                observationID: hexDigest(100 + index),
                evidenceAnchors: []
            )
        }
        let visible = try await store.visibleRecords(workspaceID: workspace)
        #expect(visible.count == ExecutionExperienceLimits.maximumRecordsPerScope)
        // The most recently observed procedures survived the eviction.
        #expect(visible.contains { $0.steps.contains { step in step.toolName == "cap.\(count - 1)one" } })
        #expect(!visible.contains { $0.steps.contains { step in step.toolName == "cap.0one" } })
    }
}
