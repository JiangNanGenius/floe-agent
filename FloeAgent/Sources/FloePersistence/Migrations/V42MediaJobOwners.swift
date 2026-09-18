import GRDB

/// Schema v42: explicit ownership for durable media jobs.
///
/// - `owner_kind` / `owner_id` are always present. Legacy rows are backfilled
///   as canvas jobs pointing at their existing `canvas_id`.
/// - `canvas_id` / `document_id` become nullable so ordinary chat jobs can be
///   owned by a conversation without inventing canvas identifiers.
/// - `origin_run_id` records which run submitted the job so a completion can be
///   delivered back to the conversation as a steer/queued input.
///
/// The rebuild uses plain SQL statements (exposed for fixture tests) because
/// SQLite cannot drop NOT NULL constraints in place.
public enum V42MediaJobOwners {
    public static let identifier = "v42_media_job_owners"

    public static let statements: [String] = [
        "ALTER TABLE media_generation_jobs ADD COLUMN owner_kind TEXT NOT NULL DEFAULT 'canvas'",
        "ALTER TABLE media_generation_jobs ADD COLUMN owner_id TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE media_generation_jobs ADD COLUMN origin_run_id TEXT",
        "UPDATE media_generation_jobs SET owner_id = canvas_id WHERE owner_id = '' OR owner_id IS NULL",
        """
        CREATE TABLE media_generation_jobs_v42 (
            id TEXT PRIMARY KEY,
            provider_task_id TEXT,
            provider_id TEXT NOT NULL REFERENCES providers(id) ON DELETE RESTRICT,
            model_id TEXT NOT NULL REFERENCES models(id) ON DELETE RESTRICT,
            media_kind TEXT NOT NULL,
            credential_reference_json BLOB,
            canvas_id TEXT,
            document_id TEXT,
            source_node_ids_json BLOB NOT NULL,
            result_node_id TEXT NOT NULL,
            request_json BLOB NOT NULL,
            asset_references_json BLOB NOT NULL,
            state TEXT NOT NULL,
            created_at DATETIME NOT NULL,
            estimated_completion_at DATETIME,
            result_retention_expires_at DATETIME,
            last_polled_at DATETIME,
            next_poll_at DATETIME,
            retry_count INTEGER NOT NULL DEFAULT 0,
            last_error TEXT,
            result_url TEXT,
            result_url_expires_at DATETIME,
            local_asset_id TEXT,
            updated_at DATETIME NOT NULL,
            owner_kind TEXT NOT NULL DEFAULT 'canvas',
            owner_id TEXT NOT NULL DEFAULT '',
            origin_run_id TEXT
        )
        """,
        """
        INSERT INTO media_generation_jobs_v42 (
            id, provider_task_id, provider_id, model_id, media_kind,
            credential_reference_json, canvas_id, document_id,
            source_node_ids_json, result_node_id, request_json,
            asset_references_json, state, created_at,
            estimated_completion_at, result_retention_expires_at,
            last_polled_at, next_poll_at, retry_count, last_error,
            result_url, result_url_expires_at, local_asset_id, updated_at,
            owner_kind, owner_id, origin_run_id
        )
        SELECT
            id, provider_task_id, provider_id, model_id, media_kind,
            credential_reference_json, canvas_id, document_id,
            source_node_ids_json, result_node_id, request_json,
            asset_references_json, state, created_at,
            estimated_completion_at, result_retention_expires_at,
            last_polled_at, next_poll_at, retry_count, last_error,
            result_url, result_url_expires_at, local_asset_id, updated_at,
            owner_kind, owner_id, origin_run_id
        FROM media_generation_jobs
        """,
        "DROP TABLE media_generation_jobs",
        "ALTER TABLE media_generation_jobs_v42 RENAME TO media_generation_jobs",
        "CREATE INDEX media_jobs_due ON media_generation_jobs(state, next_poll_at)",
        "CREATE INDEX media_jobs_canvas ON media_generation_jobs(canvas_id, created_at)",
        "CREATE INDEX media_jobs_owner ON media_generation_jobs(owner_kind, owner_id, created_at)",
        "PRAGMA user_version = 42"
    ]

    public static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration(identifier) { db in
            for statement in statements {
                try db.execute(sql: statement)
            }
        }
    }
}
