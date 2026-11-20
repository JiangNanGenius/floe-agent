// SPDX-License-Identifier: MPL-2.0
// Read-only migration compatibility check for the pinned shared schema.
// Keep this list aligned with DatabaseManager.registerMigrations. Unknown
// migrations require an explicit source update, not a best-effort downgrade.

import FloePersistence
import GRDB

enum FloeMacSelfSchemaGate {
    static let maximumVersion = 65
    static let knownMigrations: Set<String> = Set((1...39).map { "v\($0)" }).union([
        "v40_execution_environments", "v41_conversation_purpose",
        "v42_media_job_owners", "v43_media_job_idempotency",
        "v44_conversation_search_index_repair", "v45_asset_reference_ops",
        "v46_task_lifecycle", "v47_shortcut_inbox", "v48_system_alarms",
        "v49_child_run_checkpoints", "v50_schedule_cleanup_reminders",
        "v51_chat_preferences", "v52_personalization_retention",
        "v53_conversation_visibility", "v54_job_advisory_groups",
        "v55_conversation_pinning", "v56", "v57_schedule_presentation",
        "v58_task_execution_bindings", "v59_skill_configuration",
        "v60_execution_experiences", "v61_editor_assistant_ownership",
        "v62_model_reasoning_metadata", "v63_linux_cache_cleanup_tasks",
        "v64_background_child_owners", "v65",
    ])

    static func validateBeforeMigration(_ database: DatabaseManager) async throws {
        try await database.reader { db in
            let version = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
            guard version >= 0, version <= maximumVersion else {
                throw FloeMacSelfCoreError.schemaMismatch(expected: maximumVersion, actual: version)
            }
            guard try db.tableExists("grdb_migrations") else {
                guard version == 0 else {
                    throw FloeMacSelfCoreError.authoritySchemaUnsupported("missing_migration_history")
                }
                return
            }
            let applied = try Set(String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations"))
            guard applied.isSubset(of: knownMigrations) else {
                throw FloeMacSelfCoreError.authoritySchemaUnsupported("unknown_migration")
            }
        }
    }
}
