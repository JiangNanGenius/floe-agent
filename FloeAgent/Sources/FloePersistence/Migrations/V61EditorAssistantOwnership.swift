// SPDX-License-Identifier: MPL-2.0
import GRDB

/// Additive ownership, independent of runtime purpose and archive state.
/// Native binding reconciliation backfills only exact stored identifiers.
public enum V61EditorAssistantOwnership {
    public static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v61_editor_assistant_ownership") { db in
            try db.execute(sql: """
                ALTER TABLE conversations ADD COLUMN editor_owner_kind TEXT;
                ALTER TABLE conversations ADD COLUMN editor_document_id TEXT;
                ALTER TABLE conversations ADD COLUMN editor_container_id TEXT
                    CHECK ((editor_owner_kind IS NULL AND editor_document_id IS NULL AND editor_container_id IS NULL)
                        OR (editor_owner_kind IS NOT NULL AND editor_owner_kind IN ('file','canvas')
                            AND editor_document_id IS NOT NULL AND length(editor_document_id)=36
                            AND editor_container_id IS NOT NULL AND length(editor_container_id)=36
                            AND purpose='ordinary' AND visibility='normal'
                            AND (editor_owner_kind='canvas' OR editor_document_id=editor_container_id)));
                CREATE INDEX conversations_editor_ownership
                    ON conversations(editor_owner_kind, editor_container_id, editor_document_id);
                PRAGMA user_version = 61;
                """)
        }
    }
}
