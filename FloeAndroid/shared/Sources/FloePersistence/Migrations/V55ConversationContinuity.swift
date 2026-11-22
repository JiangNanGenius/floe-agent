// SPDX-License-Identifier: MPL-2.0
import GRDB

/// iOS conversation-metadata continuity (Android schema position 55).
///
/// The fixed iOS model carries two durable conversations features that
/// Android lacked: `visibility` (iOS v53, normal|skillAuthoring) and native
/// editor-assistant ownership (iOS v61, file|canvas). Both are preserved
/// HERE as real-table metadata with the same defaults and the same CHECK
/// contract as the unchanged iOS sources at
/// 7897f9c10bb70049bf5438cf3360694e628ceb1f, so iOS-originated rows keep
/// their semantics on Android instead of being flattened into ordinary
/// chats:
///
///   * `visibility TEXT NOT NULL DEFAULT 'normal'` — every pre-v55 row
///     decodes as `.normal` (exactly the value the default supplies), and a
///     `skillAuthoring` row can never claim a Notes conversation, mirroring
///     the iOS CHECK.
///   * `editor_owner_kind/document_id/container_id` stay NULL unless a
///     native editor assistant claims the row; the table-level CHECK binds
///     ownership to `purpose='ordinary' AND visibility='normal'` and keeps
///     file ownership document==container, exactly like iOS v61.
///
/// The ordinary-list projection filters these columns the same way iOS does;
/// no second store and no ownership fork is introduced. Like the additive
/// v53/v54 migrations this release does NOT move the pinned
/// `PRAGMA user_version`/`currentSchemaVersion` (52): GRDB applies the
/// migration by identifier, and the coordinated bump belongs to the
/// integration owner.
enum V55ConversationContinuity {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v55_conversation_continuity") { db in
            try db.execute(sql: """
                ALTER TABLE conversations ADD COLUMN visibility TEXT NOT NULL DEFAULT 'normal'
                    CHECK(visibility IN ('normal','skillAuthoring') AND (visibility = 'normal' OR purpose = 'ordinary'));
                ALTER TABLE conversations ADD COLUMN editor_owner_kind TEXT;
                ALTER TABLE conversations ADD COLUMN editor_document_id TEXT;
                ALTER TABLE conversations ADD COLUMN editor_container_id TEXT
                    CHECK ((editor_owner_kind IS NULL AND editor_document_id IS NULL AND editor_container_id IS NULL)
                        OR (editor_owner_kind IS NOT NULL AND editor_owner_kind IN ('file','canvas')
                            AND editor_document_id IS NOT NULL AND length(editor_document_id)=36
                            AND editor_container_id IS NOT NULL AND length(editor_container_id)=36
                            AND purpose='ordinary' AND visibility='normal'
                            AND (editor_owner_kind='canvas' OR editor_document_id=editor_container_id)));
                CREATE INDEX conversations_visibility_updated
                    ON conversations(purpose, visibility, archived_at, updated_at DESC, id);
                CREATE INDEX conversations_editor_ownership
                    ON conversations(editor_owner_kind, editor_container_id, editor_document_id);
                """)
        }
    }
}
