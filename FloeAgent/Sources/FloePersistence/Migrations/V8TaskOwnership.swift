// FloePersistence — Schema v8: canonical task ownership and recovery policy.

import Foundation
import GRDB

enum V8TaskOwnership {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v8") { db in
            try db.execute(sql: """
                ALTER TABLE workspaces ADD COLUMN kind TEXT NOT NULL DEFAULT 'project'
                    CHECK (kind IN ('project', 'privateTask'));
                ALTER TABLE workspaces ADD COLUMN internal_relative_path TEXT;
                ALTER TABLE conversations ADD COLUMN title_origin TEXT NOT NULL DEFAULT 'autoPending'
                    CHECK (title_origin IN ('autoPending', 'automatic', 'manual'));
                ALTER TABLE model_preferences ADD COLUMN vision_model_id TEXT
                    REFERENCES models(id) ON DELETE SET NULL;
                ALTER TABLE memory_entries ADD COLUMN conversation_id TEXT
                    REFERENCES conversations(id) ON DELETE CASCADE;
                DROP INDEX IF EXISTS idx_memory_entries_unique_global;
                DROP INDEX IF EXISTS idx_memory_entries_unique_workspace;
                CREATE UNIQUE INDEX idx_memory_entries_unique_global_v8
                    ON memory_entries(scope, normalized_content)
                    WHERE workspace_id IS NULL AND conversation_id IS NULL;
                CREATE UNIQUE INDEX idx_memory_entries_unique_workspace_v8
                    ON memory_entries(scope, workspace_id, normalized_content)
                    WHERE workspace_id IS NOT NULL;
                CREATE UNIQUE INDEX idx_memory_entries_unique_task_v8
                    ON memory_entries(scope, conversation_id, normalized_content)
                    WHERE conversation_id IS NOT NULL;

                CREATE TABLE conversation_workspace_ownership (
                    conversation_id TEXT PRIMARY KEY
                        REFERENCES conversations(id) ON DELETE CASCADE,
                    workspace_id TEXT NOT NULL
                        REFERENCES workspaces(id) ON DELETE RESTRICT,
                    assigned_at TEXT NOT NULL
                ) STRICT;
                CREATE INDEX idx_conversation_workspace_owner
                    ON conversation_workspace_ownership(workspace_id, assigned_at);

                CREATE TABLE task_policies (
                    conversation_id TEXT PRIMARY KEY
                        REFERENCES conversations(id) ON DELETE CASCADE,
                    approval_mode TEXT,
                    allowed_tool_names_json TEXT,
                    file_paths_json TEXT NOT NULL DEFAULT '[]',
                    network_allowed INTEGER,
                    browser_control_allowed INTEGER,
                    upload_allowed INTEGER,
                    credentials_allowed INTEGER,
                    remote_execution_allowed INTEGER,
                    recovery_policy TEXT NOT NULL DEFAULT 'safePoint'
                        CHECK (recovery_policy IN ('safePoint', 'alwaysRetry')),
                    notification_policy TEXT NOT NULL DEFAULT 'stages'
                        CHECK (notification_policy IN ('off', 'terminal', 'critical', 'stages')),
                    updated_at TEXT NOT NULL
                ) STRICT;

                CREATE TABLE run_stream_checkpoints (
                    run_id TEXT PRIMARY KEY REFERENCES runs(id) ON DELETE CASCADE,
                    answer_text TEXT NOT NULL DEFAULT '',
                    reasoning_text TEXT NOT NULL DEFAULT '',
                    last_safe_boundary TEXT NOT NULL DEFAULT 'model',
                    has_uncertain_side_effect INTEGER NOT NULL DEFAULT 0,
                    updated_at TEXT NOT NULL
                ) STRICT;

                CREATE TABLE task_schedules (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    prompt TEXT NOT NULL,
                    workspace_id TEXT REFERENCES workspaces(id) ON DELETE SET NULL,
                    cadence TEXT NOT NULL CHECK (cadence IN ('once', 'daily', 'weekly')),
                    scheduled_at TEXT NOT NULL,
                    weekday INTEGER,
                    is_enabled INTEGER NOT NULL DEFAULT 1,
                    last_started_at TEXT,
                    next_expected_at TEXT,
                    policy_json TEXT NOT NULL DEFAULT '{}',
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                ) STRICT;
                CREATE INDEX idx_task_schedules_next
                    ON task_schedules(is_enabled, next_expected_at);

                CREATE TABLE migration_reports (
                    id TEXT PRIMARY KEY,
                    migration TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    subject_id TEXT,
                    detail_json TEXT NOT NULL DEFAULT '{}',
                    created_at TEXT NOT NULL
                ) STRICT;
                """)

            let now = Self.encode(Date())
            let conversations = try Row.fetchAll(
                db,
                sql: "SELECT id, title FROM conversations ORDER BY created_at, id"
            )
            for conversation in conversations {
                let conversationID: String = conversation["id"]
                let links = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT workspace_id, created_at
                        FROM workspace_conversations
                        WHERE conversation_id = ?
                        ORDER BY created_at DESC, workspace_id
                        """,
                    arguments: [conversationID]
                )
                let workspaceID: String
                if let selected = links.first {
                    workspaceID = selected["workspace_id"]
                    if links.count > 1 {
                        let discarded = links.dropFirst().map { $0["workspace_id"] as String }
                        let payload = try String(
                            data: JSONSerialization.data(withJSONObject: [
                                "selected": workspaceID,
                                "discarded": discarded
                            ], options: [.sortedKeys]),
                            encoding: .utf8
                        ) ?? "{}"
                        try db.execute(
                            sql: """
                                INSERT INTO migration_reports
                                    (id, migration, kind, subject_id, detail_json, created_at)
                                VALUES (?, 'v8', 'multipleWorkspaceOwnership', ?, ?, ?)
                                """,
                            arguments: [UUID().uuidString, conversationID, payload, now]
                        )
                    }
                } else {
                    workspaceID = UUID().uuidString
                    let title: String = conversation["title"]
                    let displayName = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "Chat" : String(title.prefix(80))
                    try db.execute(
                        sql: """
                            INSERT INTO workspaces (
                                id, name, root_bookmark, last_opened_at,
                                active_target_kind, active_target_host_id,
                                inspector_state_json, instructions_rel_path,
                                created_at, updated_at, kind, internal_relative_path
                            ) VALUES (?, ?, ?, NULL, 'local', NULL, '{}', NULL, ?, ?,
                                      'privateTask', ?)
                            """,
                        arguments: [
                            workspaceID, displayName, Data(), now, now,
                            "PrivateTasks/\(conversationID)"
                        ]
                    )
                }
                try db.execute(
                    sql: """
                        INSERT INTO conversation_workspace_ownership
                            (conversation_id, workspace_id, assigned_at)
                        VALUES (?, ?, ?)
                        """,
                    arguments: [conversationID, workspaceID, now]
                )
                try db.execute(
                    sql: """
                        INSERT INTO task_policies (conversation_id, updated_at)
                        VALUES (?, ?)
                        """,
                    arguments: [conversationID, now]
                )
            }
            try db.execute(sql: "PRAGMA user_version = 8")
        }
    }

    private static func encode(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
