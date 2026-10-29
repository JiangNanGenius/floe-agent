import GRDB

/// Durable creative-media jobs, per-canvas sync preferences, material assets,
/// and immediate cloud-release work. Secrets are never stored in these tables.
enum V26CreativeMediaJobs {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v26") { db in
            try db.create(table: "media_generation_jobs") { table in
                table.column("id", .text).primaryKey()
                table.column("provider_task_id", .text)
                table.column("provider_id", .text).notNull()
                    .references("providers", onDelete: .restrict)
                table.column("model_id", .text).notNull()
                    .references("models", onDelete: .restrict)
                table.column("media_kind", .text).notNull()
                table.column("credential_reference_json", .blob)
                table.column("canvas_id", .text).notNull()
                table.column("document_id", .text).notNull()
                table.column("source_node_ids_json", .blob).notNull()
                table.column("result_node_id", .text).notNull()
                table.column("request_json", .blob).notNull()
                table.column("asset_references_json", .blob).notNull()
                table.column("state", .text).notNull()
                table.column("created_at", .datetime).notNull()
                table.column("estimated_completion_at", .datetime)
                table.column("result_retention_expires_at", .datetime)
                table.column("last_polled_at", .datetime)
                table.column("next_poll_at", .datetime)
                table.column("retry_count", .integer).notNull().defaults(to: 0)
                table.column("last_error", .text)
                table.column("result_url", .text)
                table.column("result_url_expires_at", .datetime)
                table.column("local_asset_id", .text)
                table.column("updated_at", .datetime).notNull()
            }
            try db.create(index: "media_jobs_due", on: "media_generation_jobs", columns: ["state", "next_poll_at"])
            try db.create(index: "media_jobs_canvas", on: "media_generation_jobs", columns: ["canvas_id", "created_at"])

            try db.create(table: "canvas_sync_preferences") { table in
                table.column("canvas_id", .text).primaryKey()
                table.column("is_enabled", .boolean).notNull().defaults(to: true)
                table.column("revision", .integer).notNull().defaults(to: 0)
                table.column("last_synced_at", .datetime)
                table.column("updated_at", .datetime).notNull()
            }

            try db.create(table: "creative_assets") { table in
                table.column("id", .text).primaryKey()
                table.column("content_hash", .text).notNull()
                table.column("kind", .text).notNull()
                table.column("display_name", .text).notNull()
                table.column("mime_type", .text)
                table.column("local_relative_path", .text)
                table.column("cloud_record_name", .text)
                table.column("byte_count", .integer).notNull().defaults(to: 0)
                table.column("source_url", .text)
                table.column("license", .text)
                table.column("tags_json", .blob).notNull()
                table.column("reference_count", .integer).notNull().defaults(to: 0)
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
                table.uniqueKey(["content_hash"])
            }

            try db.create(table: "cloud_asset_releases") { table in
                table.column("id", .text).primaryKey()
                table.column("asset_id", .text).notNull()
                    .references("creative_assets", onDelete: .cascade)
                table.column("content_hash", .text).notNull()
                table.column("estimated_bytes", .integer).notNull()
                table.column("state", .text).notNull()
                table.column("retry_count", .integer).notNull().defaults(to: 0)
                table.column("last_error", .text)
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
            }
            try db.create(index: "cloud_releases_state", on: "cloud_asset_releases", columns: ["state", "updated_at"])

            try db.create(table: "canvas_sync_operations") { table in
                table.column("operation_id", .text).primaryKey()
                table.column("canvas_id", .text).notNull()
                table.column("entity_kind", .text).notNull()
                table.column("entity_id", .text).notNull()
                table.column("mutation", .text).notNull()
                table.column("revision", .integer).notNull()
                table.column("payload", .blob)
                table.column("asset_hashes_json", .blob).notNull()
                table.column("state", .text).notNull().defaults(to: "pending")
                table.column("retry_count", .integer).notNull().defaults(to: 0)
                table.column("last_error", .text)
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
            }
            try db.create(index: "canvas_sync_pending", on: "canvas_sync_operations", columns: ["state", "created_at"])
            try db.create(index: "canvas_sync_entity_revision", on: "canvas_sync_operations", columns: ["canvas_id", "entity_kind", "entity_id", "revision"])

            try db.create(table: "canvas_deletion_tombstones") { table in
                table.column("id", .text).primaryKey()
                table.column("canvas_id", .text).notNull()
                table.column("operation_id", .text).notNull().unique()
                table.column("revision", .integer).notNull()
                table.column("deleted_at", .datetime).notNull()
                table.column("confirmed_at", .datetime)
            }

            try db.execute(sql: "PRAGMA user_version = 26")
        }
    }
}
