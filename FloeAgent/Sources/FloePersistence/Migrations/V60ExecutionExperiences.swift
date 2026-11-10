import GRDB

/// Execution experience: evidence-backed, data-minimal procedure records.
///
/// Three tables, no content columns:
///  * `execution_experiences` holds the canonical derived record JSON plus
///    deterministic identity/scope/ordering keys. Nothing else about the
///    procedure is queryable, so no path/argument/output can drift in.
///  * `execution_experience_evidence` stores ONLY run/call identity and the
///    optional deterministic `tr_` capture ref. These are pointers into
///    the runtime's existing authoritative ledgers/retention store, never
///    copies of their payloads. Cascade-deleted with the record.
///  * `execution_experience_ingress` remembers each accepted observation
///    identity so crash-retries and duplicate deliveries can never
///    double-count a settled sequence.
///
/// No environment identifiers, no permission/approval material, no secrets
/// and no workspace names/paths are persisted anywhere. Registration of
/// `register(into:)` in `DatabaseManager.registerMigrations` and the
/// `currentSchemaVersion` bump are the coordinator's (mainline) job; this
/// migration file only provides the single registration entry point. The
/// store NEVER creates tables itself: `apply(_:)` exists so this lane's
/// tests (and integration harnesses) can install the exact same canonical
/// DDL out-of-band while registration stays centrally owned. It is not a
/// lazy-creation fallback for production code paths.
public enum V60ExecutionExperiences {
    public static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v60_execution_experiences") { db in
            try apply(db)
        }
    }

    /// Canonical DDL. Idempotent (`IF NOT EXISTS`) so an out-of-band test
    /// install and the registered migration describe the same schema; the
    /// `user_version` write only happens when this DDL actually runs.
    public static func apply(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS execution_experiences (
                id TEXT PRIMARY KEY NOT NULL,
                signature TEXT NOT NULL,
                scope_kind TEXT NOT NULL CHECK(scope_kind IN ('generic', 'workspace')),
                workspace_id TEXT,
                evidence TEXT NOT NULL CHECK(evidence IN ('observedCompletion', 'sealedOutputEvidence')),
                occurrence_count INTEGER NOT NULL CHECK(occurrence_count >= 1),
                completed_step_observations INTEGER NOT NULL DEFAULT 0 CHECK(completed_step_observations >= 0),
                failed_step_observations INTEGER NOT NULL DEFAULT 0 CHECK(failed_step_observations >= 0),
                partial_step_observations INTEGER NOT NULL DEFAULT 0 CHECK(partial_step_observations >= 0),
                waiting_step_observations INTEGER NOT NULL DEFAULT 0 CHECK(waiting_step_observations >= 0),
                recovered_failure_observations INTEGER NOT NULL DEFAULT 0 CHECK(recovered_failure_observations >= 0),
                closed_run_observations INTEGER NOT NULL DEFAULT 0 CHECK(closed_run_observations >= 0),
                first_observed_ms INTEGER NOT NULL,
                last_observed_ms INTEGER NOT NULL,
                record_json TEXT NOT NULL,
                CHECK((scope_kind = 'generic' AND workspace_id IS NULL)
                      OR (scope_kind = 'workspace' AND workspace_id IS NOT NULL)),
                CHECK(first_observed_ms <= last_observed_ms),
                UNIQUE(signature, scope_kind, workspace_id)
            ) STRICT;

            CREATE INDEX IF NOT EXISTS execution_experiences_scope_recency
                ON execution_experiences(scope_kind, workspace_id, last_observed_ms);

            CREATE TABLE IF NOT EXISTS execution_experience_evidence (
                experience_id TEXT NOT NULL
                    REFERENCES execution_experiences(id) ON DELETE CASCADE,
                run_id TEXT NOT NULL,
                call_id TEXT NOT NULL,
                capture_ref TEXT,
                settled_ms INTEGER NOT NULL,
                PRIMARY KEY(experience_id, run_id, call_id)
            ) STRICT;

            CREATE INDEX IF NOT EXISTS execution_experience_evidence_run
                ON execution_experience_evidence(run_id);

            CREATE TABLE IF NOT EXISTS execution_experience_ingress (
                observation_id TEXT PRIMARY KEY NOT NULL,
                experience_id TEXT NOT NULL
                    REFERENCES execution_experiences(id) ON DELETE CASCADE,
                observed_at_ms INTEGER NOT NULL
            ) STRICT;

            CREATE TRIGGER IF NOT EXISTS execution_experience_source_run_deleted
            AFTER DELETE ON runs
            BEGIN
                DELETE FROM execution_experience_evidence WHERE run_id = OLD.id;
            END;

            CREATE TRIGGER IF NOT EXISTS execution_experience_workspace_deleted
            AFTER DELETE ON workspaces
            BEGIN
                DELETE FROM execution_experiences
                    WHERE scope_kind = 'workspace' AND workspace_id = OLD.id;
                UPDATE execution_experiences
                    SET record_json = json_remove(record_json, '$.originWorkspaceID')
                    WHERE scope_kind = 'generic'
                      AND CASE WHEN json_valid(record_json)
                          THEN json_extract(record_json, '$.originWorkspaceID') = OLD.id
                          ELSE 0 END;
            END;
            """)
        try db.execute(sql: "PRAGMA user_version = 60")
    }
}
