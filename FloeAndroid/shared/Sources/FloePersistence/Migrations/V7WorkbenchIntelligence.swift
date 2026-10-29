// FloePersistence — Schema v7: workbench intelligence.
//
// This append-only migration adds durable plans/goals, bounded memory,
// installable instruction skills, visible-browser metadata, child-run
// relationships and context-compaction evidence. Secret values and browser
// cookies are deliberately excluded.

import GRDB

enum V7WorkbenchIntelligence {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v7") { db in
            try db.execute(sql: sql)
            try db.execute(sql: "PRAGMA user_version = 7")
        }
    }

    static let sql = """
    ALTER TABLE conversations ADD COLUMN mode TEXT NOT NULL DEFAULT 'chat';
    ALTER TABLE conversations ADD COLUMN is_searchable INTEGER NOT NULL DEFAULT 1;

    CREATE TABLE plan_drafts (
        id TEXT NOT NULL,
        conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
        workspace_id TEXT REFERENCES workspaces(id) ON DELETE SET NULL,
        revision INTEGER NOT NULL,
        status TEXT NOT NULL,
        title TEXT NOT NULL DEFAULT '',
        summary TEXT NOT NULL DEFAULT '',
        sections_json TEXT NOT NULL DEFAULT '[]',
        assumptions_json TEXT NOT NULL DEFAULT '[]',
        risks_json TEXT NOT NULL DEFAULT '[]',
        criteria_json TEXT NOT NULL DEFAULT '[]',
        source_message_ids_json TEXT NOT NULL DEFAULT '[]',
        source_conversation_refs_json TEXT NOT NULL DEFAULT '[]',
        digest TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        PRIMARY KEY(id, revision),
        UNIQUE(conversation_id, revision)
    ) STRICT;
    CREATE INDEX idx_plan_drafts_conversation
        ON plan_drafts(conversation_id, revision DESC);

    CREATE VIRTUAL TABLE plan_fts USING fts5(
        title,
        summary,
        content='plan_drafts',
        content_rowid='rowid',
        tokenize='unicode61'
    );
    CREATE TRIGGER plan_drafts_ai AFTER INSERT ON plan_drafts BEGIN
        INSERT INTO plan_fts(rowid, title, summary)
        VALUES (new.rowid, new.title, new.summary);
    END;
    CREATE TRIGGER plan_drafts_ad AFTER DELETE ON plan_drafts BEGIN
        INSERT INTO plan_fts(plan_fts, rowid, title, summary)
        VALUES ('delete', old.rowid, old.title, old.summary);
    END;
    CREATE TRIGGER plan_drafts_au AFTER UPDATE ON plan_drafts BEGIN
        INSERT INTO plan_fts(plan_fts, rowid, title, summary)
        VALUES ('delete', old.rowid, old.title, old.summary);
        INSERT INTO plan_fts(rowid, title, summary)
        VALUES (new.rowid, new.title, new.summary);
    END;

    CREATE TABLE conversation_goals (
        id TEXT PRIMARY KEY,
        conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
        source_plan_id TEXT,
        source_plan_digest TEXT,
        objective TEXT NOT NULL,
        status TEXT NOT NULL,
        criteria_json TEXT NOT NULL DEFAULT '[]',
        steps_json TEXT NOT NULL DEFAULT '[]',
        evidence_json TEXT NOT NULL DEFAULT '[]',
        budgets_json TEXT NOT NULL DEFAULT '{}',
        progress_json TEXT NOT NULL DEFAULT '{}',
        blocking_fingerprint TEXT,
        consecutive_blocked_cycles INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
    ) STRICT;
    CREATE INDEX idx_conversation_goals_conversation
        ON conversation_goals(conversation_id, updated_at DESC);
    CREATE INDEX idx_conversation_goals_status
        ON conversation_goals(status, updated_at DESC);

    CREATE TABLE goal_criteria (
        id TEXT PRIMARY KEY,
        goal_id TEXT NOT NULL REFERENCES conversation_goals(id) ON DELETE CASCADE,
        criterion_index INTEGER NOT NULL,
        text TEXT NOT NULL,
        status TEXT NOT NULL,
        evidence_json TEXT NOT NULL DEFAULT '[]',
        updated_at TEXT NOT NULL,
        UNIQUE(goal_id, criterion_index)
    ) STRICT;

    CREATE TABLE goal_steps (
        id TEXT PRIMARY KEY,
        goal_id TEXT NOT NULL REFERENCES conversation_goals(id) ON DELETE CASCADE,
        step_index INTEGER NOT NULL,
        title TEXT NOT NULL,
        detail TEXT NOT NULL DEFAULT '',
        status TEXT NOT NULL,
        evidence_json TEXT NOT NULL DEFAULT '[]',
        updated_at TEXT NOT NULL,
        UNIQUE(goal_id, step_index)
    ) STRICT;

    CREATE TABLE goal_events (
        id TEXT PRIMARY KEY,
        goal_id TEXT NOT NULL REFERENCES conversation_goals(id) ON DELETE CASCADE,
        run_id TEXT REFERENCES runs(id) ON DELETE SET NULL,
        sequence INTEGER NOT NULL,
        kind TEXT NOT NULL,
        payload_json TEXT NOT NULL DEFAULT '{}',
        created_at TEXT NOT NULL,
        UNIQUE(goal_id, sequence)
    ) STRICT;
    CREATE INDEX idx_goal_events_goal ON goal_events(goal_id, sequence);

    CREATE TABLE run_relations (
        parent_run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
        child_run_id TEXT NOT NULL UNIQUE REFERENCES runs(id) ON DELETE CASCADE,
        child_index INTEGER NOT NULL,
        task_summary TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL,
        PRIMARY KEY(parent_run_id, child_index),
        CHECK(parent_run_id <> child_run_id)
    ) STRICT;

    CREATE TABLE context_compactions (
        id TEXT PRIMARY KEY,
        run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
        source_message_ids_json TEXT NOT NULL DEFAULT '[]',
        boundary_start_id TEXT,
        boundary_end_id TEXT,
        summary TEXT NOT NULL,
        source_digest TEXT NOT NULL,
        input_tokens INTEGER NOT NULL DEFAULT 0,
        output_tokens INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL
    ) STRICT;
    CREATE INDEX idx_context_compactions_run
        ON context_compactions(run_id, created_at);

    CREATE TABLE memory_entries (
        id TEXT PRIMARY KEY,
        scope TEXT NOT NULL,
        workspace_id TEXT REFERENCES workspaces(id) ON DELETE CASCADE,
        status TEXT NOT NULL,
        content TEXT NOT NULL,
        normalized_content TEXT NOT NULL,
        confidence REAL NOT NULL DEFAULT 0,
        importance REAL NOT NULL DEFAULT 0,
        is_pinned INTEGER NOT NULL DEFAULT 0,
        source_kind TEXT NOT NULL,
        expires_at TEXT,
        sync_revision INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        UNIQUE(scope, workspace_id, normalized_content)
    ) STRICT;
    CREATE INDEX idx_memory_entries_scope
        ON memory_entries(scope, workspace_id, status, is_pinned, updated_at DESC);
    CREATE UNIQUE INDEX idx_memory_entries_unique_global
        ON memory_entries(scope, normalized_content) WHERE workspace_id IS NULL;
    CREATE UNIQUE INDEX idx_memory_entries_unique_workspace
        ON memory_entries(scope, workspace_id, normalized_content) WHERE workspace_id IS NOT NULL;

    CREATE TABLE memory_evidence (
        id TEXT PRIMARY KEY,
        memory_id TEXT NOT NULL REFERENCES memory_entries(id) ON DELETE CASCADE,
        conversation_id TEXT REFERENCES conversations(id) ON DELETE SET NULL,
        message_id TEXT REFERENCES messages(id) ON DELETE SET NULL,
        run_id TEXT REFERENCES runs(id) ON DELETE SET NULL,
        excerpt_digest TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL
    ) STRICT;
    CREATE INDEX idx_memory_evidence_memory ON memory_evidence(memory_id);

    CREATE TABLE memory_tombstones (
        memory_id TEXT PRIMARY KEY,
        deleted_at TEXT NOT NULL,
        sync_revision INTEGER NOT NULL DEFAULT 0
    ) STRICT;

    CREATE VIRTUAL TABLE memory_fts USING fts5(
        content,
        content='memory_entries',
        content_rowid='rowid',
        tokenize='unicode61'
    );
    CREATE TRIGGER memory_entries_ai AFTER INSERT ON memory_entries BEGIN
        INSERT INTO memory_fts(rowid, content) VALUES (new.rowid, new.content);
    END;
    CREATE TRIGGER memory_entries_ad AFTER DELETE ON memory_entries BEGIN
        INSERT INTO memory_fts(memory_fts, rowid, content)
        VALUES ('delete', old.rowid, old.content);
    END;
    CREATE TRIGGER memory_entries_au AFTER UPDATE ON memory_entries BEGIN
        INSERT INTO memory_fts(memory_fts, rowid, content)
        VALUES ('delete', old.rowid, old.content);
        INSERT INTO memory_fts(rowid, content) VALUES (new.rowid, new.content);
    END;

    CREATE TABLE skills (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL UNIQUE COLLATE NOCASE,
        version TEXT NOT NULL,
        status TEXT NOT NULL,
        skill_markdown TEXT NOT NULL,
        manifest_json TEXT NOT NULL,
        declared_capabilities_json TEXT NOT NULL DEFAULT '[]',
        effective_capabilities_json TEXT NOT NULL DEFAULT '[]',
        source_url TEXT,
        source_digest TEXT,
        rewritten_digest TEXT NOT NULL,
        selected_by_model_id TEXT,
        rewrite_model_id TEXT,
        compatibility_report_json TEXT NOT NULL DEFAULT '{}',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
    ) STRICT;

    CREATE TABLE skill_resources (
        id TEXT PRIMARY KEY,
        skill_id TEXT NOT NULL REFERENCES skills(id) ON DELETE CASCADE,
        path TEXT NOT NULL,
        kind TEXT NOT NULL,
        relative_path TEXT NOT NULL,
        digest TEXT NOT NULL,
        byte_count INTEGER NOT NULL,
        UNIQUE(skill_id, path)
    ) STRICT;

    CREATE TABLE skill_permissions (
        skill_id TEXT NOT NULL REFERENCES skills(id) ON DELETE CASCADE,
        capability TEXT NOT NULL,
        decision TEXT NOT NULL,
        scope_json TEXT NOT NULL DEFAULT '{}',
        granted_at TEXT,
        expires_at TEXT,
        PRIMARY KEY(skill_id, capability)
    ) STRICT;

    CREATE TABLE workspace_skills (
        workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
        skill_id TEXT NOT NULL REFERENCES skills(id) ON DELETE CASCADE,
        is_enabled INTEGER NOT NULL DEFAULT 1,
        PRIMARY KEY(workspace_id, skill_id)
    ) STRICT;

    CREATE TABLE browser_sessions (
        id TEXT PRIMARY KEY,
        owner_run_id TEXT REFERENCES runs(id) ON DELETE SET NULL,
        state TEXT NOT NULL,
        active_tab_id TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
    ) STRICT;

    CREATE TABLE browser_tabs (
        id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL REFERENCES browser_sessions(id) ON DELETE CASCADE,
        tab_index INTEGER NOT NULL,
        url TEXT NOT NULL DEFAULT '',
        title TEXT NOT NULL DEFAULT '',
        document_id TEXT,
        state TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        UNIQUE(session_id, tab_index)
    ) STRICT;
    CREATE INDEX idx_browser_tabs_session ON browser_tabs(session_id, tab_index);

    CREATE TABLE browser_artifacts (
        id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL REFERENCES browser_sessions(id) ON DELETE CASCADE,
        tab_id TEXT REFERENCES browser_tabs(id) ON DELETE SET NULL,
        run_id TEXT REFERENCES runs(id) ON DELETE SET NULL,
        document_id TEXT,
        attachment_id TEXT REFERENCES attachments(id) ON DELETE SET NULL,
        kind TEXT NOT NULL,
        digest TEXT NOT NULL,
        created_at TEXT NOT NULL
    ) STRICT;
    CREATE INDEX idx_browser_artifacts_session
        ON browser_artifacts(session_id, created_at);
    """
}
