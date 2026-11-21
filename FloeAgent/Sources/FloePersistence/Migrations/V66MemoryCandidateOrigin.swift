// SPDX-License-Identifier: MPL-2.0
import GRDB

enum V66MemoryCandidateOrigin {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v66") { db in
            try db.execute(sql: """
                ALTER TABLE memory_candidates ADD COLUMN origin_conversation_id TEXT;
                ALTER TABLE memory_candidates ADD COLUMN origin_workspace_id TEXT;

                UPDATE memory_candidates
                SET origin_conversation_id = conversation_id, origin_workspace_id = workspace_id;

                UPDATE memory_candidates AS candidate
                SET origin_conversation_id = (
                    SELECT MIN(message.conversation_id)
                    FROM json_each(candidate.evidence_json) AS evidence
                    JOIN messages AS message ON message.id = json_extract(evidence.value, '$.messageID')
                    HAVING COUNT(DISTINCT message.conversation_id) = 1
                )
                WHERE origin_conversation_id IS NULL AND scope IN ('user','agent')
                  AND json_valid(evidence_json);
                PRAGMA user_version = 66;
                """)
        }
    }
}
