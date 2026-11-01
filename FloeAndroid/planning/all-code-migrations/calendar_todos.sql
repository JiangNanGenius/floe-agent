-- SPDX-License-Identifier: MPL-2.0
--
-- C06 App-local todo schema — DECLARATIVE FRAGMENT ONLY.
--
-- Main owns the single next coordinated SQLite migration. Do NOT allocate a
-- version here, do NOT write PRAGMA user_version, and do NOT register a
-- separate migration in DatabaseManager. Insert this body into Main's next
-- migration after the current schema (v51 with V51MailAccounts) and keep the
-- existing R2 selected_at repair untouched.
--
-- The table/index definitions are the same as C06TodoSchema in
-- shared/Sources/FloeAndroidCore/C06TodoStore.swift. There is intentionally
-- NO foreign key/cascade to conversations/tasks: a todo is independently
-- owned user data and survives deletion of a chat task.

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
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS calendar_todos_due
ON calendar_todos(completed, due_at);

CREATE INDEX IF NOT EXISTS calendar_todos_updated
ON calendar_todos(updated_at);
