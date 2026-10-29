import GRDB

/// Durable background jobs submitted via the jobs.* tool group. Payloads and
/// results are Floe-owned bookkeeping; secrets never enter these tables.
enum V39BackgroundJobs {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v39") { db in
            try db.create(table: "background_jobs") { table in
                table.column("id", .text).primaryKey()
                table.column("conversation_id", .text).notNull()
                table.column("run_id", .text).notNull()
                table.column("tool_call_id", .text)
                /// "tool" (in-process runner) or "download" (background URLSession).
                table.column("kind", .text).notNull()
                table.column("target_tool", .text).notNull()
                table.column("payload_json", .blob).notNull()
                table.column("state", .text).notNull()
                table.column("progress_json", .blob)
                table.column("result_summary", .text)
                table.column("result_digest", .text)
                /// Workspace-relative path when a large result was spilled to disk.
                table.column("result_path", .text)
                table.column("last_error", .text)
                /// Absolute path of the task workspace root at submit time,
                /// so a relaunched process can still deliver download results.
                table.column("workspace_root_path", .text)
                table.column("retry_count", .integer).notNull().defaults(to: 0)
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
                table.column("completed_at", .datetime)
            }
            try db.create(index: "background_jobs_state", on: "background_jobs", columns: ["state", "updated_at"])
            try db.create(index: "background_jobs_conversation", on: "background_jobs", columns: ["conversation_id", "created_at"])
            // Idempotent submit: a retried tool call returns its original job.
            try db.create(index: "background_jobs_run_call", on: "background_jobs", columns: ["run_id", "tool_call_id"], unique: true)

            // Conversation-level deferred-schema discovery state, so a new run
            // keeps the previously loaded tool schemas instead of re-guessing
            // them from the user goal text.
            try db.create(table: "conversation_discovery") { table in
                table.column("conversation_id", .text).primaryKey()
                table.column("tool_names_json", .blob).notNull()
                table.column("priority_json", .blob).notNull()
                table.column("updated_at", .datetime).notNull()
            }
            try db.execute(sql: "PRAGMA user_version = 39")
        }
    }
}
