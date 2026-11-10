// FloePersistence — SQLite store for execution experience records.
//
// The store is a dumb-but-safe boundary: it persists ONLY already-derived,
// already-validated `ExecutionExperienceRecord` values plus observation
// dedup keys and evidence anchors. It re-runs structural validation and the
// data-minimality property on every write so a policy bypass cannot persist
// content. It NEVER creates tables: schema installation is exclusively the
// registered `V60ExecutionExperiences` migration's job (the coordinator
// wires `register(into:)` into `DatabaseManager.registerMigrations`).
// Calling the store before that migration exists fails honestly with the
// GRDB "no such table" error — there is no lazy second migration system.
//
// Transaction semantics: `DatabaseManager.performWrite` already runs every
// writer block inside GRDB's write transaction (`DatabasePool.write`), so
// multi-statement flows here MUST NOT nest `db.inTransaction` (that would
// raise "cannot start a transaction within a transaction"). Atomicity comes
// from the outer write: any throw rolls the whole block back. This is
// verified by real DatabaseManager+GRDB ingest/reopen/dedup/purge tests.
//
// Scope and relevance fences enforced here, independent of the runtime
// policy:
//  * a `workspace` row is recalled only for the exact same workspace id;
//  * a query without a workspace id sees only `generic` rows;
//  * recall REQUIRES a non-empty task activation signal: the procedure's
//    step tools must be a subset of the current catalog AND overlap the
//    activated tool family above the query's ratio — full-catalog
//    availability alone never admits an unrelated-domain procedure;
//  * rows are bounded per scope and in total (deterministic oldest-first
//    eviction);
//  * retention, workspace deletion and evidence purging are explicit.
//
// Nothing environment-, permission- or secret-related is accepted at any
// entry point, and no raw arguments/outputs are ever stored.

import Foundation
import GRDB
import FloeCore
import FloeModels

public struct ExecutionExperienceStore: Sendable {
    private let database: DatabaseManager

    public init(database: DatabaseManager) { self.database = database }

    public enum UpsertStatus: String, Sendable, Equatable {
        case created
        case merged
        /// The exact observation identity was already ingested; counters
        /// were NOT touched. Crash-replaying the same settled sequence is
        /// a no-op, never double-counting.
        case duplicate
    }

    public struct UpsertOutcome: Sendable, Equatable {
        public var status: UpsertStatus
        public var recordID: String
        public var storedRecord: ExecutionExperienceRecord
    }

    // MARK: - Ingestion

    /// Idempotent upsert of one derived record for one observation identity.
    /// `observedAt` timestamps the accepted receipts (the anchors' settled
    /// time); it does not override the record's own timeline.
    public func ingest(
        record: ExecutionExperienceRecord,
        observationID: String,
        evidenceAnchors: [ExecutionExperienceEvidenceAnchor],
        observedAt: Date = Date(),
        sourceRunID: UUID? = nil,
        sourceConversationID: UUID? = nil
    ) async throws -> UpsertOutcome {
        guard (sourceRunID == nil) == (sourceConversationID == nil) else {
            throw FloeError.validationFailed("Incomplete experience source identity")
        }
        if let sourceRunID {
            guard !evidenceAnchors.isEmpty,
                  evidenceAnchors.allSatisfy({ $0.runID == sourceRunID }) else {
                throw FloeError.validationFailed("Experience anchors contradict their native source")
            }
        }
        if let issue = record.structuralValidationIssue() {
            throw FloeError.validationFailed(issue)
        }
        guard record.satisfiesDataMinimality() else {
            throw FloeError.validationFailed(
                "Experience record failed data minimization at the store boundary"
            )
        }
        guard ExecutionExperienceLimits.isSafeDigestID(observationID) else {
            throw FloeError.validationFailed("Observation identity is not a canonical digest")
        }
        if evidenceAnchors.count > ExecutionExperienceLimits.maximumEvidenceAnchors {
            throw FloeError.validationFailed("Evidence anchors exceed the bounded count")
        }
        for anchor in evidenceAnchors {
            if let issue = anchor.structuralValidationIssue() {
                throw FloeError.validationFailed(issue)
            }
        }
        let stored = record
        // The whole block below runs inside the write transaction that
        // `DatabaseManager.performWrite`'s `pool.write` already opened.
        // Any throw rolls back all of it; a nested db.inTransaction would
        // fail with "cannot start a transaction within a transaction".
        return try await database.writer { db in
            // Check source ownership INSIDE the same transaction as the
            // upsert. An async liveness check alone leaves a delete/write gap.
            if let sourceRunID, let sourceConversationID {
                let exists = try Int.fetchOne(db, sql: """
                    SELECT 1 FROM runs r JOIN conversations c ON c.id = r.conversation_id
                    WHERE r.id = ? AND r.conversation_id = ? AND r.state = 'completed'
                      AND r.ended_at IS NOT NULL AND c.purpose != 'temporary'
                    LIMIT 1
                    """, arguments: [sourceRunID.uuidString, sourceConversationID.uuidString])
                guard exists != nil else {
                    throw FloeError.validationFailed("Experience source was deleted or is not completed")
                }
            }
            if let existingID: String = try String.fetchOne(db, sql: """
                SELECT experience_id FROM execution_experience_ingress
                WHERE observation_id = ?
                """, arguments: [observationID]) {
                let fetched = try Self.loadRecord(db, id: existingID)
                return UpsertOutcome(
                    status: .duplicate,
                    recordID: existingID,
                    storedRecord: fetched ?? stored
                )
            }
            let loaded = try Self.loadRecord(db, id: stored.id)
            let final: ExecutionExperienceRecord
            let status: UpsertStatus
            if let existing = loaded {
                guard existing.scope == stored.scope,
                      existing.signature == stored.signature,
                      existing.sameGroupedProcedureStructure(as: stored) else {
                    throw FloeError.storageCorrupted(
                        "Experience identity collision (same id, different structure)"
                    )
                }
                final = existing.merged(with: stored)
                guard final.structuralValidationIssue() == nil,
                      final.satisfiesDataMinimality() else {
                    throw FloeError.storageCorrupted(
                        "Merged experience record failed validation"
                    )
                }
                status = .merged
            } else {
                final = stored
                status = .created
            }
            // The persisted JSON is the MERGED record, never the incoming
            // single-observation form.
            let encoded = try final.canonicalJSON()
            let scopeKind: String
            let workspaceArgument: String?
            switch final.scope {
            case .generic:
                scopeKind = "generic"
                workspaceArgument = nil
            case .workspace(let id):
                scopeKind = "workspace"
                workspaceArgument = id.uuidString
            }
            try db.execute(sql: """
                INSERT INTO execution_experiences(
                    id, signature, scope_kind, workspace_id, evidence,
                    occurrence_count, completed_step_observations,
                    failed_step_observations, partial_step_observations,
                    waiting_step_observations, recovered_failure_observations,
                    closed_run_observations, first_observed_ms, last_observed_ms,
                    record_json)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET
                    occurrence_count = excluded.occurrence_count,
                    completed_step_observations = excluded.completed_step_observations,
                    failed_step_observations = excluded.failed_step_observations,
                    partial_step_observations = excluded.partial_step_observations,
                    waiting_step_observations = excluded.waiting_step_observations,
                    recovered_failure_observations = excluded.recovered_failure_observations,
                    closed_run_observations = excluded.closed_run_observations,
                    first_observed_ms = excluded.first_observed_ms,
                    last_observed_ms = excluded.last_observed_ms,
                    evidence = excluded.evidence,
                    record_json = excluded.record_json
                """, arguments: [
                    final.id, final.signature, scopeKind, workspaceArgument,
                    final.evidence.rawValue,
                    final.occurrenceCount, final.completedStepObservations,
                    final.failedStepObservations, final.partialStepObservations,
                    final.waitingStepObservations, final.recoveredFailureObservations,
                    final.closedRunObservations,
                    Int64(final.firstObservedAt.timeIntervalSince1970 * 1_000),
                    Int64(final.lastObservedAt.timeIntervalSince1970 * 1_000),
                    encoded
                ])
            // Anchors: bounded, deduplicated by (experience, run, call).
            for anchor in evidenceAnchors {
                let anchorCount = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM execution_experience_evidence
                    WHERE experience_id = ?
                    """, arguments: [final.id]) ?? 0
                if anchorCount >= ExecutionExperienceLimits.maximumEvidenceAnchors {
                    break
                }
                try db.execute(sql: """
                    INSERT INTO execution_experience_evidence(
                        experience_id, run_id, call_id, capture_ref, settled_ms)
                    VALUES(?,?,?,?,?)
                    ON CONFLICT(experience_id, run_id, call_id) DO UPDATE SET
                        capture_ref = COALESCE(excluded.capture_ref, capture_ref)
                    """, arguments: [
                        final.id, anchor.runID.uuidString, anchor.callID,
                        anchor.captureRef,
                        Int64(observedAt.timeIntervalSince1970 * 1_000)
                    ])
            }
            try db.execute(sql: """
                INSERT INTO execution_experience_ingress(
                    observation_id, experience_id, observed_at_ms)
                VALUES(?,?,?)
                """, arguments: [
                    observationID, final.id,
                    Int64(observedAt.timeIntervalSince1970 * 1_000)
                ])
            try Self.enforceCaps(
                db,
                keeping: final.id,
                scopeKind: scopeKind,
                workspaceID: workspaceArgument ?? ""
            )
            return UpsertOutcome(status: status, recordID: final.id, storedRecord: final)
        }
    }

    /// Deterministic oldest-first eviction beyond the per-scope and global
    /// bounds. Ties break on the record id, so the same content always
    /// evicts the same rows.
    private static func enforceCaps(
        _ db: Database,
        keeping currentID: String,
        scopeKind: String,
        workspaceID: String
    ) throws {
        if scopeKind == "workspace" {
            try evict(
                db,
                clause: "scope_kind = 'workspace' AND workspace_id = ? AND id != ?",
                scopeArguments: [workspaceID, currentID],
                limit: ExecutionExperienceLimits.maximumRecordsPerScope
            )
        } else {
            try evict(
                db,
                clause: "scope_kind = 'generic' AND id != ?",
                scopeArguments: [currentID],
                limit: ExecutionExperienceLimits.maximumRecordsPerScope
            )
        }
        try evict(
            db,
            clause: "id != ?",
            scopeArguments: [currentID],
            limit: ExecutionExperienceLimits.maximumTotalRecords
        )
    }

    private static func evict(
        _ db: Database,
        clause: String,
        scopeArguments: [String],
        limit cap: Int
    ) throws {
        let rows = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM execution_experiences WHERE \(clause)",
            arguments: StatementArguments(scopeArguments)
        ) ?? 0
        // `clause` always excludes the just-written record, so the other
        // rows must stay at `cap - 1` for the total to remain `cap`.
        let excess = rows - (cap - 1)
        guard excess > 0 else { return }
        // `excess` is a computed Int row count, not caller input; the
        // interpolated LIMIT is therefore injection-safe.
        try db.execute(
            sql: """
                DELETE FROM execution_experiences WHERE id IN (
                    SELECT id FROM execution_experiences
                    WHERE \(clause)
                    ORDER BY last_observed_ms ASC, id ASC
                    LIMIT \(excess)
                )
                """,
            arguments: StatementArguments(scopeArguments)
        )
    }

    // MARK: - Reads

    public func record(id: String) async throws -> ExecutionExperienceRecord? {
        guard ExecutionExperienceLimits.isSafeDigestID(id) else {
            throw FloeError.validationFailed("Experience record id is not a canonical digest")
        }
        return try await database.reader { db in
            try Self.loadRecord(db, id: id)
        }
    }

    /// Rows visible to a context: the exact workspace's own records plus
    /// generic records. A nil workspace sees ONLY generic rows. This is a
    /// bounded browsing read; task recall must go through `recall(_:)`,
    /// which additionally enforces the activation-relevance fence.
    public func visibleRecords(workspaceID: UUID?) async throws -> [ExecutionExperienceRecord] {
        try await database.reader { db in
            let rows: [String]
            if let workspaceID {
                rows = try String.fetchAll(db, sql: """
                    SELECT record_json FROM execution_experiences
                    WHERE (scope_kind = 'workspace' AND workspace_id = ?)
                       OR scope_kind = 'generic'
                    ORDER BY CASE evidence WHEN 'sealedOutputEvidence' THEN 0 ELSE 1 END,
                             last_observed_ms DESC, occurrence_count DESC, id ASC
                    """, arguments: [workspaceID.uuidString])
            } else {
                rows = try String.fetchAll(db, sql: """
                    SELECT record_json FROM execution_experiences
                    WHERE scope_kind = 'generic'
                    ORDER BY CASE evidence WHEN 'sealedOutputEvidence' THEN 0 ELSE 1 END,
                             last_observed_ms DESC, occurrence_count DESC, id ASC
                    """)
            }
            return try rows.map { try Self.decode(ExecutionExperienceRecord.self, $0) }
        }
    }

    /// Bounded, scope-fenced, availability-checked AND activation-relevance
    /// recall. A query without a non-empty `activatedToolNames` recallS
    /// NOTHING (fail closed): full-catalog availability alone can never
    /// inject an unrelated-domain procedure into a new task.
    public func recall(_ query: ExecutionExperienceRecallQuery) async throws -> [ExecutionExperienceRecord] {
        let activated = query.activatedToolNames ?? []
        guard !activated.isEmpty else { return [] }
        let all = try await visibleRecords(workspaceID: query.workspaceID)
        var result: [ExecutionExperienceRecord] = []
        let maxRecords = max(1, query.maxRecords ?? ExecutionExperienceLimits.recallDefaultMaxRecords)
        for record in all {
            if let available = query.availableToolNames,
               !record.toolNames.isSubset(of: available) {
                continue
            }
            let ratio = ExecutionExperienceRecallQuery.activationOverlapRatio(
                record: record, activated: activated
            )
            guard ratio >= query.activationMinimumOverlapRatio else { continue }
            if let notOlderThan = query.notOlderThan, record.lastObservedAt < notOlderThan {
                continue
            }
            if let minimum = query.minimumEvidence, record.evidence < minimum {
                continue
            }
            result.append(record)
            if result.count >= maxRecords { break }
        }
        return result
    }

    /// Evidence anchors for one record: opaque identities pointing into the
    /// runtime's authoritative ledgers/retention store.
    public func evidenceAnchors(experienceID: String) async throws -> [ExecutionExperienceEvidenceAnchor] {
        guard ExecutionExperienceLimits.isSafeDigestID(experienceID) else {
            throw FloeError.validationFailed("Experience record id is not a canonical digest")
        }
        return try await database.reader { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT run_id, call_id, capture_ref FROM execution_experience_evidence
                WHERE experience_id = ?
                ORDER BY settled_ms DESC, call_id ASC
                """, arguments: [experienceID])
            return try rows.map { row in
                let runString: String = row["run_id"]
                guard let runID = UUID(uuidString: runString) else {
                    throw FloeError.storageCorrupted("Evidence anchor run identity is unreadable")
                }
                return ExecutionExperienceEvidenceAnchor(
                    runID: runID,
                    callID: row["call_id"],
                    captureRef: row["capture_ref"]
                )
            }
        }
    }

    public func storedRecordCount() async throws -> Int {
        try await database.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM execution_experiences") ?? 0
        }
    }

    // MARK: - Retention and deletion

    /// Removes records not reinforced within `retentionInterval`. Returns
    /// the deleted count.
    public func enforceRetention(now: Date, retentionInterval: TimeInterval) async throws -> Int {
        guard retentionInterval > 0 else {
            throw FloeError.validationFailed("Retention interval must be positive")
        }
        let cutoff = Int64(now.timeIntervalSince1970 * 1_000) - Int64(retentionInterval * 1_000)
        return try await database.writer { db in
            try db.execute(
                sql: "DELETE FROM execution_experiences WHERE last_observed_ms < ?",
                arguments: [cutoff]
            )
            return db.changesCount
        }
    }

    /// Workspace-deletion fence: removes every workspace-scoped record and
    /// its anchors, then clears the opaque `originWorkspaceID` locator from
    /// any surviving GENERIC record that pointed at this workspace (the
    /// reusable procedure structure stays, the pointer to deleted data does
    /// not). Returns the number of workspace-scoped records removed.
    @discardableResult
    public func purgeWorkspace(workspaceID: UUID) async throws -> Int {
        let target = workspaceID
        // Runs entirely inside the outer write transaction (atomic: the
        // scoped deletes and the generic-locator rewrites commit or roll
        // back together).
        return try await database.writer { db in
            try db.execute(
                sql: "DELETE FROM execution_experiences WHERE scope_kind = 'workspace' AND workspace_id = ?",
                arguments: [target.uuidString]
            )
            let removedWorkspaceRecords = db.changesCount
            for row in try Row.fetchAll(db, sql: """
                SELECT id, record_json FROM execution_experiences WHERE scope_kind = 'generic'
                """) {
                let id: String = row["id"]
                let json: String = row["record_json"]
                guard var record = try? Self.decode(ExecutionExperienceRecord.self, json),
                      record.originWorkspaceID == target else { continue }
                record.originWorkspaceID = nil
                let encoded = try record.canonicalJSON()
                try db.execute(
                    sql: "UPDATE execution_experiences SET record_json = ? WHERE id = ?",
                    arguments: [encoded, id]
                )
            }
            return removedWorkspaceRecords
        }
    }

    /// Run-deletion fence: removes evidence anchors pointing at deleted
    /// runs. Procedure structure may legitimately outlive a purged run;
    /// dangling evidence is never invented or left as a phantom pointer.
    public func purgeEvidence(runIDs: [UUID]) async throws -> Int {
        guard !runIDs.isEmpty else { return 0 }
        let strings = runIDs.map(\.uuidString)
        let placeholders = strings.map { _ in "?" }.joined(separator: ",")
        return try await database.writer { db in
            try db.execute(
                sql: "DELETE FROM execution_experience_evidence WHERE run_id IN (\(placeholders))",
                arguments: StatementArguments(strings)
            )
            return db.changesCount
        }
    }

    // MARK: - Lifecycle guards

    /// Integration-boundary cancellation fence helper: ingestion accepts an
    /// explicit origin guard evaluated immediately before the write. A
    /// cancelled/deleted source drops the observation without persisting a
    /// byte (see `ingest(guarded:)`).
    public struct GuardedIngest: Sendable {
        public var record: ExecutionExperienceRecord
        public var observationID: String
        public var evidenceAnchors: [ExecutionExperienceEvidenceAnchor]
        public var observedAt: Date
        public var sourceRunID: UUID?
        public var sourceConversationID: UUID?
        /// Returning false aborts before any SQL change.
        public var originIsLive: @Sendable () async -> Bool

        public init(
            record: ExecutionExperienceRecord,
            observationID: String,
            evidenceAnchors: [ExecutionExperienceEvidenceAnchor],
            observedAt: Date = Date(),
            sourceRunID: UUID? = nil,
            sourceConversationID: UUID? = nil,
            originIsLive: @escaping @Sendable () async -> Bool
        ) {
            self.record = record
            self.observationID = observationID
            self.evidenceAnchors = evidenceAnchors
            self.observedAt = observedAt
            self.sourceRunID = sourceRunID
            self.sourceConversationID = sourceConversationID
            self.originIsLive = originIsLive
        }
    }

    public func ingest(guarded ingest: GuardedIngest) async throws -> UpsertOutcome {
        guard await ingest.originIsLive() else {
            throw FloeError.validationFailed(
                "Experience origin was cancelled; nothing was persisted"
            )
        }
        return try await self.ingest(
            record: ingest.record,
            observationID: ingest.observationID,
            evidenceAnchors: ingest.evidenceAnchors,
            observedAt: ingest.observedAt,
            sourceRunID: ingest.sourceRunID,
            sourceConversationID: ingest.sourceConversationID
        )
    }

    // MARK: - Canonicalization / codec

    private static func loadRecord(_ db: Database, id: String) throws -> ExecutionExperienceRecord? {
        guard let json: String = try String.fetchOne(db, sql: """
            SELECT record_json FROM execution_experiences WHERE id = ?
            """, arguments: [id]) else {
            return nil
        }
        return try Self.decode(ExecutionExperienceRecord.self, json)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ value: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        do {
            return try decoder.decode(type, from: Data(value.utf8))
        } catch {
            throw FloeError.storageCorrupted(
                "Experience record is unreadable: \(String(describing: error))"
            )
        }
    }
}
