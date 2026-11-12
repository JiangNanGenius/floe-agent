// FloePersistence — complete read-only App DB environment-reference projection.
//
// A narrow, single-read-snapshot projection over the four durable tables that
// can name an execution environment:
//
//   task_execution_bindings   one task pin per conversation (hidden/archived too)
//   runs                      every pinned run, plus unpinned resumable runs
//   background_jobs           every queued/running (and unrecognized) job,
//                             including managed services in their `running`
//                             stopping state; never capped by activeJobs(...)
//   task_environment_migrations
//                             BOTH ends of every non-completed/cancelled
//                             migration, including failed/preparation-unknown
//
// It never returns chat text, titles, goals, payloads, progress blobs,
// credentials or arbitrary JSON bodies. Decoding/read incompleteness is
// explicit: a failed body or an unapplied schema field makes `isComplete`
// false instead of being swallowed into an empty reference set.
//
// Semantics used here are the existing stores', not new guesses:
//  * a pinned run is retained (historical, checkpointed and failed included);
//  * a pinned run whose state is not one of the non-terminal exclusions
//    (completed/failed/checkpointed/interrupted/cancelled/canceled) is active;
//  * an unpinned run in a state the binding store can still rebind
//    (`state NOT IN ('completed','cancelled')`) is an explicit UNKNOWN
//    reference, never "no reference";
//  * a job's explicit environment wins; nil falls back to its run pin; when
//    neither resolves, the job is UNKNOWN;
//  * a migration contributes active source and target references until the
//    row is completed/cancelled.
//
// A retained reference does not mean the disk is open, and no reference grants
// maintenance permission. Byte-preserving maintenance keeps all referenced
// bytes; this projection only supplies the complete owner/reference side of the
// authority's evidence.

import Foundation
import GRDB
import FloeCore
import FloeModels

public struct EnvironmentReference: Sendable, Hashable {
    public enum Source: String, Sendable, Codable, CaseIterable, Hashable {
        case taskBinding
        case runBinding
        case runWithoutBinding
        case backgroundJob
        case migrationSource
        case migrationTarget
    }

    public enum Classification: String, Sendable, Codable, CaseIterable, Hashable {
        /// A currently live execution reference (non-terminal run, queued or
        /// running job, unresolved migration end).
        case active
        /// A historical/recoverable reference whose bytes must be retained but
        /// which is not currently executing.
        case retained
        /// The reference exists but its environment cannot be attributed from
        /// the stored facts. Never treated as "no reference".
        case unknown
    }

    public var source: Source
    /// Internal durable owner key (task, run, job or migration id).
    public var ownerID: UUID
    public var conversationID: UUID
    public var environmentID: String?
    public var backend: TaskExecutionTarget.Backend?
    public var bindingGeneration: Int64?
    public var runtimeGeneration: String?
    /// The durable run/job/migration state label (fixed internal vocabulary),
    /// never message text.
    public var state: String?
    public var classification: Classification
    /// True when this reference can currently execute/hold work (active run,
    /// queued/running job, unresolved migration end). A resumable unpinned run
    /// is an explicit unknown reference but is not live until it resumes; the
    /// maintenance barrier already blocks that future start, so it is surfaced
    /// without blocking unrelated byte-preserving maintenance.
    public var isLive: Bool
    /// Fixed internal reason code for an unknown/retained classification.
    public var reason: String?

    public init(
        source: Source, ownerID: UUID, conversationID: UUID,
        environmentID: String?, backend: TaskExecutionTarget.Backend? = nil,
        bindingGeneration: Int64? = nil, runtimeGeneration: String? = nil,
        state: String? = nil, classification: Classification,
        isLive: Bool, reason: String? = nil
    ) {
        self.source = source
        self.ownerID = ownerID
        self.conversationID = conversationID
        self.environmentID = environmentID
        self.backend = backend
        self.bindingGeneration = bindingGeneration
        self.runtimeGeneration = runtimeGeneration
        self.state = state
        self.classification = classification
        self.isLive = isLive
        self.reason = reason
    }
}

public enum EnvironmentReferenceMaintenanceVerdict: Sendable, Equatable {
    /// Projection is complete and no active/unknown reference can reach the
    /// queried environment. Retained references may exist.
    case clear
    /// Active or unknown references can reach the environment, or unattributed
    /// active/unknown references prevent a complete scope answer.
    case busy([String])
    /// The projection itself is incomplete; no maintenance decision is allowed.
    case incomplete([String])
}

public struct EnvironmentReferenceProjection: Sendable, Equatable {
    public var capturedAt: Date
    public var isComplete: Bool
    /// Fixed internal codes only (for example `run_binding_unreadable`).
    public var blockers: [String]
    public var references: [EnvironmentReference]
    /// SHA-256 of the canonical, timestamp-free reference set. Two projections
    /// can be compared inside a maintenance barrier without holding a DB write
    /// transaction across rewrite IO.
    public var fingerprint: String

    public init(
        capturedAt: Date = Date(),
        isComplete: Bool,
        blockers: [String],
        references: [EnvironmentReference]
    ) {
        self.capturedAt = capturedAt
        self.isComplete = isComplete
        self.blockers = Array(Set(blockers)).sorted()
        self.references = Self.canonical(references)
        self.fingerprint = Self.fingerprint(
            isComplete: isComplete, blockers: self.blockers, references: self.references
        )
    }

    /// Conservative verdict for one target environment. The five fixed rules:
    ///  1. an incomplete projection refuses (`.incomplete`);
    ///  2. an active or unknown reference naming the target refuses;
    ///  3. an unattributed active/unknown reference refuses (scope unknown);
    ///  4. retained references do not refuse byte-preserving maintenance;
    ///  5. otherwise it is clear.
    public func maintenanceVerdict(environmentID: String) -> EnvironmentReferenceMaintenanceVerdict {
        guard isComplete, blockers.isEmpty else {
            return .incomplete(blockers.isEmpty ? ["projection_incomplete"] : blockers)
        }
        var reasons: [String] = []
        for reference in references {
            switch reference.classification {
            case .retained:
                continue
            case .active:
                if let named = reference.environmentID {
                    if named == environmentID {
                        reasons.append("active:\(reference.source.rawValue):\(reference.ownerID.uuidString)")
                    }
                } else {
                    reasons.append("active:unattributed:\(reference.source.rawValue):\(reference.ownerID.uuidString)")
                }
            case .unknown:
                if let named = reference.environmentID {
                    if named == environmentID {
                        reasons.append("unknown:\(reference.source.rawValue):\(reference.ownerID.uuidString)")
                    }
                } else if reference.isLive {
                    // A queued/running job or unreadable live body with no
                    // environment cannot be scoped; fail closed. A resumable
                    // unpinned run is surfaced but not live, and the domain
                    // barrier blocks its future start.
                    reasons.append("unknown-live:unattributed:\(reference.source.rawValue):\(reference.ownerID.uuidString)")
                }
            }
        }
        return reasons.isEmpty ? .clear : .busy(Array(Set(reasons)).sorted())
    }

    private static func canonical(_ references: [EnvironmentReference]) -> [EnvironmentReference] {
        references.sorted { lhs, rhs in
            let left = [lhs.source.rawValue, lhs.ownerID.uuidString,
                        lhs.environmentID ?? "", lhs.classification.rawValue,
                        lhs.bindingGeneration.map(String.init) ?? ""]
            let right = [rhs.source.rawValue, rhs.ownerID.uuidString,
                         rhs.environmentID ?? "", rhs.classification.rawValue,
                         rhs.bindingGeneration.map(String.init) ?? ""]
            return left.lexicographicallyPrecedes(right)
        }
    }

    private static func fingerprint(
        isComplete: Bool, blockers: [String], references: [EnvironmentReference]
    ) -> String {
        var lines: [String] = ["complete=\(isComplete)", "blockers=\(blockers.joined(separator: ","))"]
        for reference in references {
            lines.append([
                reference.source.rawValue,
                reference.ownerID.uuidString,
                reference.conversationID.uuidString,
                reference.environmentID ?? "-",
                reference.backend?.rawValue ?? "-",
                reference.bindingGeneration.map(String.init) ?? "-",
                reference.runtimeGeneration ?? "-",
                reference.state ?? "-",
                reference.classification.rawValue,
                reference.isLive ? "live" : "idle",
                reference.reason ?? "-"
            ].joined(separator: "|"))
        }
        return FloeDigest.sha256Hex(Data(lines.joined(separator: "\n").utf8))
    }
}

public struct EnvironmentReferenceProjectionStore: Sendable {
    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    /// One read-only GRDB read (a consistent snapshot). All four tables are
    /// fully scanned for the required rows. There is no LIMIT that could hide a
    /// reference, and `activeJobs(limit:)` is never used.
    public func project() async throws -> EnvironmentReferenceProjection {
        try await database.reader { db in
            try Self.project(db)
        }
    }

    static func project(_ db: Database) throws -> EnvironmentReferenceProjection {
        var references: [EnvironmentReference] = []
        var blockers: Set<String> = []

        // 1. Task pins (all conversations, including hidden/archived).
        for row in try Row.fetchAll(db, sql: """
            SELECT conversation_id,generation,body_json
            FROM task_execution_bindings ORDER BY conversation_id
            """) {
            guard let conversationID = UUID(uuidString: row["conversation_id"] as String) else {
                blockers.insert("task_binding_identity_invalid")
                continue
            }
            let generation: Int64 = row["generation"]
            do {
                let body: String = row["body_json"]
                let binding = try TaskExecutionBinding.decoded(body)
                guard binding.conversationID == conversationID,
                      binding.generation == generation,
                      binding.generation > 0 else {
                    throw FloeError.storageCorrupted("Task binding identity mismatch")
                }
                references.append(EnvironmentReference(
                    source: .taskBinding, ownerID: conversationID,
                    conversationID: conversationID,
                    environmentID: binding.target.environmentID,
                    backend: binding.target.backend,
                    bindingGeneration: binding.generation,
                    runtimeGeneration: binding.target.runtimeGeneration,
                    state: nil, classification: .retained, isLive: false, reason: nil
                ))
            } catch {
                blockers.insert("task_binding_unreadable")
                references.append(EnvironmentReference(
                    source: .taskBinding, ownerID: conversationID,
                    conversationID: conversationID, environmentID: nil,
                    classification: .unknown, isLive: false, reason: "task_binding_unreadable"
                ))
            }
        }

        // 2. Runs: every pinned run (including terminal/checkpointed/failed) and
        //    every unpinned run the binding store could still rebind. Terminal
        //    completed/cancelled runs without a pin are not an environment
        //    reference; they are intentionally omitted, not treated as bound.
        for row in try Row.fetchAll(db, sql: """
            SELECT id,conversation_id,state,execution_binding_json
            FROM runs
            WHERE execution_binding_json IS NOT NULL
               OR state NOT IN ('completed','cancelled','canceled')
            ORDER BY id
            """) {
            guard let runID = UUID(uuidString: row["id"] as String),
                  let conversationID = UUID(uuidString: row["conversation_id"] as String) else {
                blockers.insert("run_identity_invalid")
                continue
            }
            let state: String = row["state"]
            let bindingJSON: String? = row["execution_binding_json"]
            if let bindingJSON {
                do {
                    let binding = try TaskExecutionBinding.decoded(bindingJSON)
                    guard binding.conversationID == conversationID,
                          binding.generation > 0 else {
                        throw FloeError.storageCorrupted("Run binding identity mismatch")
                    }
                    references.append(EnvironmentReference(
                        source: .runBinding, ownerID: runID,
                        conversationID: conversationID,
                        environmentID: binding.target.environmentID,
                        backend: binding.target.backend,
                        bindingGeneration: binding.generation,
                        runtimeGeneration: binding.target.runtimeGeneration,
                        state: Self.safeState(state),
                        classification: Self.isLiveRunState(state) ? .active : .retained,
                        isLive: Self.isLiveRunState(state), reason: nil
                    ))
                } catch {
                    blockers.insert("run_binding_unreadable")
                    references.append(EnvironmentReference(
                        source: .runBinding, ownerID: runID,
                        conversationID: conversationID, environmentID: nil,
                        state: Self.safeState(state), classification: .unknown,
                        isLive: Self.isLiveRunState(state), reason: "run_binding_unreadable"
                    ))
                }
            } else {
                // The binding store can still rebind this run; without a pin its
                // future environment is genuinely unknown. The projection says
                // so instead of dropping the row.
                references.append(EnvironmentReference(
                    source: .runWithoutBinding, ownerID: runID,
                    conversationID: conversationID, environmentID: nil,
                    state: Self.safeState(state), classification: .unknown,
                    isLive: Self.isLiveRunState(state), reason: "run_without_binding"
                ))
            }
        }

        // 3. Background jobs: every queued/running row, plus every row whose
        //    state vocabulary is not recognized (so a future/unknown state can
        //    never be silently ignored). Terminal known states are omitted.
        for row in try Row.fetchAll(db, sql: """
            SELECT j.id,j.conversation_id,j.run_id,j.state,j.environment_id,
                   r.execution_binding_json AS run_binding_json,
                   r.state AS run_state
            FROM background_jobs j
            LEFT JOIN runs r ON r.id = j.run_id
            WHERE j.state IN ('queued','running')
               OR j.state NOT IN ('queued','running','completed','failed','cancelled','interrupted')
            ORDER BY j.id
            """) {
            guard let jobID = UUID(uuidString: row["id"] as String),
                  let conversationID = UUID(uuidString: row["conversation_id"] as String),
                  let runID = UUID(uuidString: row["run_id"] as String) else {
                blockers.insert("job_identity_invalid")
                continue
            }
            let rawState: String = row["state"]
            let recognized = BackgroundJobState(rawValue: rawState) != nil
            if !recognized { blockers.insert("job_state_unrecognized") }
            let rawEnvironment: String? = row["environment_id"]
            let environmentID = rawEnvironment.flatMap { $0.isEmpty ? nil : $0 }

            if let environmentID {
                // An explicit job environment wins. It is active while the row
                // is queued/running; an unrecognized state is unknown.
                var reason: String?
                if let bindingJSON: String = row["run_binding_json"] {
                    do {
                        let binding = try TaskExecutionBinding.decoded(bindingJSON)
                        if binding.target.environmentID != environmentID {
                            blockers.insert("job_environment_conflicts_with_run_pin")
                        }
                    } catch {
                        blockers.insert("job_run_binding_unreadable")
                    }
                }
                if !recognized { reason = "job_state_unrecognized" }
                references.append(EnvironmentReference(
                    source: .backgroundJob, ownerID: jobID,
                    conversationID: conversationID,
                    environmentID: environmentID,
                    bindingGeneration: nil, runtimeGeneration: nil,
                    state: Self.safeState(rawState),
                    classification: recognized ? .active : .unknown,
                    isLive: true, reason: reason
                ))
                continue
            }

            // No explicit environment: the run pin is the only attribution.
            if let bindingJSON: String = row["run_binding_json"] {
                do {
                    let binding = try TaskExecutionBinding.decoded(bindingJSON)
                    guard binding.conversationID == conversationID, binding.generation > 0 else {
                        throw FloeError.storageCorrupted("Job run binding identity mismatch")
                    }
                    references.append(EnvironmentReference(
                        source: .backgroundJob, ownerID: jobID,
                        conversationID: conversationID,
                        environmentID: binding.target.environmentID,
                        backend: binding.target.backend,
                        bindingGeneration: binding.generation,
                        runtimeGeneration: binding.target.runtimeGeneration,
                        state: Self.safeState(rawState),
                        classification: recognized ? .active : .unknown,
                        isLive: true,
                        reason: recognized ? "environment_from_run_pin" : "job_state_unrecognized"
                    ))
                } catch {
                    blockers.insert("job_run_binding_unreadable")
                    references.append(EnvironmentReference(
                        source: .backgroundJob, ownerID: jobID,
                        conversationID: conversationID, environmentID: nil,
                        state: Self.safeState(rawState), classification: .unknown,
                        isLive: true, reason: "job_run_binding_unreadable"
                    ))
                }
            } else {
                let runState: String? = row["run_state"]
                references.append(EnvironmentReference(
                    source: .backgroundJob, ownerID: jobID,
                    conversationID: conversationID, environmentID: nil,
                    state: Self.safeState(rawState), classification: .unknown,
                    isLive: true,
                    reason: runState == nil ? "job_run_missing" : "job_environment_unresolved"
                ))
            }
        }

        // 4. Incomplete migrations: BOTH ends are retained references until the
        //    migration is completed or cancelled. `failed` is non-terminal here
        //    exactly as the store's own queries treat it.
        for row in try Row.fetchAll(db, sql: """
            SELECT id,conversation_id,phase,revision,body_json
            FROM task_environment_migrations
            WHERE phase NOT IN ('completed','cancelled')
            ORDER BY id
            """) {
            guard let migrationID = UUID(uuidString: row["id"] as String),
                  let conversationID = UUID(uuidString: row["conversation_id"] as String) else {
                blockers.insert("migration_identity_invalid")
                continue
            }
            let phase: String = row["phase"]
            let revision: Int64 = row["revision"]
            do {
                let body: String = row["body_json"]
                guard let migration = try Self.decodeMigration(body),
                      migration.id == migrationID,
                      migration.source.conversationID == conversationID,
                      migration.revision > 0 else {
                    throw FloeError.storageCorrupted("Migration identity mismatch")
                }
                if migration.phase.rawValue != phase { blockers.insert("migration_phase_mismatch") }
                if migration.revision != revision { blockers.insert("migration_revision_mismatch") }
                if migration.preparationOutcomeUnknown == true {
                    blockers.insert("migration_preparation_outcome_unknown")
                }
                if let operations = migration.preparationOperationIDs, !operations.isEmpty {
                    blockers.insert("migration_preparation_operation_open")
                }
                references.append(EnvironmentReference(
                    source: .migrationSource, ownerID: migrationID,
                    conversationID: conversationID,
                    environmentID: migration.source.target.environmentID,
                    backend: migration.source.target.backend,
                    bindingGeneration: migration.source.generation,
                    runtimeGeneration: migration.source.target.runtimeGeneration,
                    state: Self.safeState(phase), classification: .active, isLive: true, reason: nil
                ))
                references.append(EnvironmentReference(
                    source: .migrationTarget, ownerID: migrationID,
                    conversationID: conversationID,
                    environmentID: migration.target.environmentID,
                    backend: migration.target.backend,
                    bindingGeneration: nil,
                    runtimeGeneration: migration.target.runtimeGeneration,
                    state: Self.safeState(phase), classification: .active, isLive: true, reason: nil
                ))
            } catch {
                blockers.insert("migration_unreadable")
                references.append(EnvironmentReference(
                    source: .migrationSource, ownerID: migrationID,
                    conversationID: conversationID, environmentID: nil,
                    state: Self.safeState(phase), classification: .unknown,
                    isLive: true, reason: "migration_unreadable"
                ))
            }
        }

        return EnvironmentReferenceProjection(
            capturedAt: Date(), isComplete: blockers.isEmpty,
            blockers: Array(blockers), references: references
        )
    }

    /// Resumable is not the same as currently executing. A paused run has
    /// stopped its model stream and must pass admission again before resuming.
    /// Its pin remains retained; independent jobs and native owners are still
    /// checked separately before byte-preserving maintenance may begin.
    private static func isLiveRunState(_ state: String) -> Bool {
        !["completed", "failed", "checkpointed", "paused", "interrupted", "cancelled", "canceled"].contains(state)
    }

    /// Internal state labels are fixed vocabulary. Anything else is reported as
    /// `unrecognized`, never echoed as arbitrary stored text.
    private static func safeState(_ value: String) -> String {
        guard value.count <= 64,
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == ".") }) else {
            return "unrecognized"
        }
        return value
    }

    private static func decodeMigration(_ json: String?) throws -> TaskEnvironmentMigration? {
        guard let json else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(TaskEnvironmentMigration.self, from: Data(json.utf8))
    }
}
