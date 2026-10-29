// FloePersistence — Schema v5: workspace (project) tables.
// See docs/ARCHITECTURE_AGENT_WORKSPACE.md §5.2. Append-only migration:
// v1–v4 are frozen; v5 only adds tables. File contents and secrets are
// never persisted — only relative paths, metadata and bookmark BLOBs.

import GRDB

enum V5Workspace {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v5") { db in
            try db.execute(sql: """
                -- Workspaces (projects). root_bookmark is a security-scoped
                -- bookmark; it contains no secret material.
                CREATE TABLE workspaces (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL DEFAULT '',
                    root_bookmark BLOB NOT NULL,
                    last_opened_at TEXT,
                    active_target_kind TEXT NOT NULL DEFAULT 'local',
                    active_target_host_id TEXT REFERENCES hosts(id) ON DELETE SET NULL,
                    inspector_state_json TEXT NOT NULL DEFAULT '{}',
                    instructions_rel_path TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                ) STRICT;

                -- Workspace ↔ conversation association (many-to-many;
                -- deleting either side cascades the association).
                CREATE TABLE workspace_conversations (
                    workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
                    conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
                    created_at TEXT NOT NULL,
                    PRIMARY KEY (workspace_id, conversation_id)
                ) STRICT;
                CREATE INDEX idx_workspace_conversations_conversation
                    ON workspace_conversations(conversation_id);

                -- Per-workspace recent files. Only relative paths and
                -- metadata are stored; file bodies never enter the database.
                CREATE TABLE workspace_recent_files (
                    workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
                    relative_path TEXT NOT NULL,
                    display_name TEXT NOT NULL DEFAULT '',
                    last_opened_at TEXT NOT NULL,
                    PRIMARY KEY (workspace_id, relative_path)
                ) STRICT;

                -- Cross-run remembered approval scopes ("this task / current
                -- project / host"). Only tool names, normalised relative
                -- paths and expiry are stored — never argument bodies or
                -- secrets.
                CREATE TABLE approval_grants (
                    id TEXT PRIMARY KEY,
                    workspace_id TEXT REFERENCES workspaces(id) ON DELETE CASCADE,
                    host_id TEXT REFERENCES hosts(id) ON DELETE CASCADE,
                    tool_name TEXT NOT NULL,
                    paths_json TEXT NOT NULL DEFAULT '[]',
                    single_use INTEGER NOT NULL DEFAULT 1,
                    policy_name TEXT NOT NULL,
                    decided_at TEXT NOT NULL,
                    expires_at TEXT
                ) STRICT;
                CREATE INDEX idx_approval_grants_lookup
                    ON approval_grants(tool_name, workspace_id, host_id);

                PRAGMA user_version = 5;
                """)
        }
    }
}
