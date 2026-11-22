// SPDX-License-Identifier: MPL-2.0
import GRDB

/// The released iPad and Mac v66 stores used the same migration identifier
/// for different additive changes. Bring both shapes forward without
/// replaying v66 or rewriting existing grants, conversations, or events.
enum V67SessionSchemaAlignment {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v67_session_schema_alignment") { db in
            let grantColumns = Set(try db.columns(in: "approval_grants").map(\.name))
            if !grantColumns.contains("conversation_id") {
                try db.execute(sql: """
                    ALTER TABLE approval_grants ADD COLUMN conversation_id TEXT REFERENCES conversations(id) ON DELETE CASCADE
                    """)
            }
            if !grantColumns.contains("authorization_identity") {
                try db.execute(sql: "ALTER TABLE approval_grants ADD COLUMN authorization_identity TEXT")
            }
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS approval_grants_file ON approval_grants(workspace_id, tool_name)
                WHERE authorization_identity IS NOT NULL
                """)

            let memoryColumns = Set(try db.columns(in: "memory_candidates").map(\.name))
            if !memoryColumns.contains("origin_conversation_id") {
                try db.execute(sql: """
                    ALTER TABLE memory_candidates ADD COLUMN origin_conversation_id TEXT;
                    UPDATE memory_candidates SET origin_conversation_id = conversation_id;
                    UPDATE memory_candidates AS candidate
                    SET origin_conversation_id = (
                        SELECT MIN(message.conversation_id)
                        FROM json_each(candidate.evidence_json) AS evidence
                        JOIN messages AS message ON message.id = json_extract(evidence.value, '$.messageID')
                        HAVING COUNT(DISTINCT message.conversation_id) = 1
                    )
                    WHERE origin_conversation_id IS NULL AND scope IN ('user','agent')
                      AND json_valid(evidence_json);
                    """)
            }
            if !memoryColumns.contains("origin_workspace_id") {
                try db.execute(sql: """
                    ALTER TABLE memory_candidates ADD COLUMN origin_workspace_id TEXT;
                    UPDATE memory_candidates SET origin_workspace_id = workspace_id;
                    """)
            }
            try db.execute(sql: "PRAGMA user_version = 67")
        }
    }
}
