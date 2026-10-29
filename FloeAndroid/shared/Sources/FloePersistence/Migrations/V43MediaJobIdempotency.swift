import GRDB

/// Schema v43: per-operation idempotency for durable media jobs.
///
/// `idempotency_key` records the submitting operation (`runID:toolCallID` for
/// ordinary Agent tool calls, NULL for canvas submissions and legacy rows).
/// Dedupe is keyed on it so a replayed tool call attaches to the existing job
/// instead of paying for a second submission, while two distinct user requests
/// that happen to have identical bodies are never merged into one job.
///
/// The column is nullable and additive, so existing rows and the legacy
/// owner+model+request fallback keep working unchanged.
public enum V43MediaJobIdempotency {
    public static let identifier = "v43_media_job_idempotency"

    public static let statements: [String] = [
        "ALTER TABLE media_generation_jobs ADD COLUMN idempotency_key TEXT",
        "CREATE INDEX media_jobs_idempotency ON media_generation_jobs(owner_kind, owner_id, idempotency_key)",
        "PRAGMA user_version = 43"
    ]

    public static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration(identifier) { db in
            for statement in statements {
                try db.execute(sql: statement)
            }
        }
    }
}
