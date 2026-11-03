// SPDX-License-Identifier: MPL-2.0
import GRDB

/// The single additive migration for the C01-C08 closure. Historical v1-v51
/// migrations, media selection repairs and existing user rows stay unchanged.
enum V52AndroidCodeClosure {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v52_android_code_closure") { db in
            try db.execute(sql: schemaSQL)
            try db.execute(sql: "PRAGMA user_version = 52")
        }
    }

    static let schemaSQL = """
        CREATE TABLE IF NOT EXISTS calendar_todos (
            id TEXT PRIMARY KEY NOT NULL,
            title TEXT NOT NULL,
            notes TEXT NOT NULL,
            due_at TEXT,
            due_timezone TEXT NOT NULL,
            all_day INTEGER NOT NULL,
            recurrence TEXT NOT NULL,
            recurrence_interval INTEGER NOT NULL,
            recurrence_until TEXT,
            reminder_minutes_before INTEGER,
            completed INTEGER NOT NULL,
            completed_at TEXT,
            revision INTEGER NOT NULL,
            owner_conversation_id TEXT,
            owner_task_id TEXT,
            owner_environment_id TEXT,
            last_reminder_at TEXT,
            last_reminder_occurrence TEXT,
            reminders_suspended INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );

        CREATE INDEX IF NOT EXISTS calendar_todos_due
        ON calendar_todos(completed, due_at);

        CREATE INDEX IF NOT EXISTS calendar_todos_updated
        ON calendar_todos(updated_at);

        CREATE TABLE IF NOT EXISTS task_execution_targets (
            conversation_id TEXT PRIMARY KEY NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
            revision INTEGER NOT NULL CHECK(revision > 0),
            kind TEXT NOT NULL CHECK(kind IN ('localLinux','ssh')),
            environment_id TEXT NOT NULL,
            project_id TEXT,
            workspace_id TEXT NOT NULL,
            shell_root_hash TEXT NOT NULL,
            engine_owner_hash TEXT NOT NULL,
            root_epoch INTEGER NOT NULL CHECK(root_epoch > 0),
            remote_host_id TEXT,
            remote_root_path TEXT,
            remote_os TEXT,
            remote_architecture TEXT,
            remote_generation TEXT,
            provenance TEXT NOT NULL,
            body_json TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            CHECK (
                (kind = 'ssh' AND remote_host_id IS NOT NULL
                    AND remote_root_path IS NOT NULL
                    AND remote_generation IS NOT NULL AND length(remote_generation) > 0)
                OR
                (kind = 'localLinux' AND remote_host_id IS NULL
                    AND remote_root_path IS NULL AND remote_generation IS NULL)
            )
        );

        CREATE INDEX IF NOT EXISTS task_execution_targets_workspace
        ON task_execution_targets(workspace_id);

        CREATE INDEX IF NOT EXISTS task_execution_targets_remote_host
        ON task_execution_targets(remote_host_id);

        CREATE TABLE IF NOT EXISTS task_execution_target_migrations (
            id TEXT PRIMARY KEY NOT NULL,
            conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
            phase TEXT NOT NULL,
            revision INTEGER NOT NULL CHECK(revision > 0),
            source_revision INTEGER NOT NULL,
            body_json TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );

        CREATE UNIQUE INDEX IF NOT EXISTS task_execution_target_migration_active
        ON task_execution_target_migrations(conversation_id)
        WHERE phase NOT IN ('completed', 'cancelled', 'failed');

        CREATE INDEX IF NOT EXISTS task_execution_target_migration_status
        ON task_execution_target_migrations(conversation_id, phase, revision);

        CREATE TABLE IF NOT EXISTS task_run_execution_targets (
            run_id TEXT PRIMARY KEY NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
            conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
            target_revision INTEGER NOT NULL CHECK(target_revision > 0),
            environment_id TEXT NOT NULL,
            shell_root_hash TEXT NOT NULL,
            engine_owner_hash TEXT NOT NULL,
            root_epoch INTEGER NOT NULL CHECK(root_epoch > 0),
            body_json TEXT NOT NULL,
            pinned_at TEXT NOT NULL
        );

        CREATE INDEX IF NOT EXISTS task_run_execution_targets_task
        ON task_run_execution_targets(conversation_id, target_revision);

        CREATE TABLE IF NOT EXISTS task_remote_command_receipts (
            operation_id TEXT PRIMARY KEY NOT NULL,
            task_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
            run_id TEXT,
            tool_call_id TEXT,
            target_revision INTEGER NOT NULL CHECK(target_revision > 0),
            root_epoch INTEGER NOT NULL CHECK(root_epoch > 0),
            host_id TEXT NOT NULL,
            command_sha256 TEXT NOT NULL,
            state TEXT NOT NULL CHECK(state IN ('dispatched','notStarted','exited','cancelled','timedOut','outcomeUnknown')),
            exit_code INTEGER,
            started_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            detail_code TEXT,
            body_json TEXT NOT NULL
        );

        CREATE INDEX IF NOT EXISTS task_remote_command_receipts_task
        ON task_remote_command_receipts(task_id, updated_at);

        CREATE TABLE IF NOT EXISTS task_continuity_pauses (
            marker_id TEXT PRIMARY KEY NOT NULL,
            task_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
            run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
            root_epoch INTEGER NOT NULL CHECK(root_epoch > 0),
            root_fingerprint TEXT NOT NULL,
            reason TEXT NOT NULL CHECK(reason IN (
                'permissionRevoked','volumeMissing','volumeReadOnly',
                'volumeFull','databaseUnavailable')),
            state TEXT NOT NULL CHECK(state IN (
                'awaitingStorageRecovery','resumeInProgress',
                'resumeFailed','resumed')),
            durability TEXT NOT NULL CHECK(durability IN (
                'taskDatabase','recoveryMetadata','memoryOnly')),
            detected_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            resume_attempt INTEGER NOT NULL CHECK(resume_attempt >= 0),
            target_revision INTEGER,
            target_root_epoch INTEGER,
            environment_id TEXT,
            workspace_id TEXT,
            run_checkpointed INTEGER NOT NULL CHECK(run_checkpointed IN (0,1)),
            unknown_outcome_count INTEGER NOT NULL DEFAULT 0,
            body_json TEXT NOT NULL,
            UNIQUE (run_id)
        ) STRICT;

        CREATE INDEX IF NOT EXISTS task_continuity_pauses_task
        ON task_continuity_pauses(task_id, state, updated_at);

        CREATE INDEX IF NOT EXISTS task_continuity_pauses_run
        ON task_continuity_pauses(run_id, state);
        """
}
