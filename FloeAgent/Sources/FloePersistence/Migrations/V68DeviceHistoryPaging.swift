// SPDX-License-Identifier: MPL-2.0

import GRDB

enum V68DeviceHistoryPaging {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v68-device-history-paging") { db in
            try db.execute(sql: """
                CREATE TABLE device_history_sequences (
                    conversation_id TEXT PRIMARY KEY NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
                    generation TEXT NOT NULL DEFAULT (lower(hex(randomblob(16)))),
                    sequence INTEGER NOT NULL
                ) STRICT;
                CREATE TABLE device_history_order (
                    message_id TEXT PRIMARY KEY NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
                    conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
                    sequence INTEGER NOT NULL,
                    UNIQUE(conversation_id, sequence)
                ) STRICT;
                INSERT INTO device_history_order (message_id, conversation_id, sequence)
                    SELECT id, conversation_id, row_number() OVER (PARTITION BY conversation_id ORDER BY rowid)
                    FROM messages WHERE role IN ('user', 'assistant');
                INSERT INTO device_history_sequences (conversation_id, sequence)
                    SELECT conversation_id, max(sequence) FROM device_history_order GROUP BY conversation_id;

                CREATE TABLE device_history_receive_cursors (
                    peer_id TEXT NOT NULL,
                    conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
                    cursor TEXT NOT NULL,
                    PRIMARY KEY(peer_id, conversation_id)
                ) STRICT;
                CREATE INDEX device_history_receive_conversation
                    ON device_history_receive_cursors(conversation_id);
                """)

            // The sequence follows durable changes, including edits to a
            // message initially imported from a peer. The latest projection
            // of an edited message is offered again so conflicts stay visible.
            try db.execute(sql: """
                CREATE TRIGGER device_history_message_insert AFTER INSERT ON messages
                WHEN NEW.role IN ('user', 'assistant')
                BEGIN
                    \(bump(message: "NEW.id"))
                END;
                CREATE TRIGGER device_history_message_update AFTER UPDATE OF content ON messages
                WHEN OLD.content IS NOT NEW.content AND NEW.role IN ('user', 'assistant')
                BEGIN
                    \(bump(message: "NEW.id"))
                END;
                CREATE TRIGGER device_history_text_insert AFTER INSERT ON message_parts
                WHEN NEW.kind = 'text'
                BEGIN
                    \(bump(message: "NEW.message_id"))
                END;
                CREATE TRIGGER device_history_text_update AFTER UPDATE OF kind, text ON message_parts
                WHEN (OLD.kind = 'text' OR NEW.kind = 'text')
                    AND (OLD.kind IS NOT NEW.kind OR OLD.text IS NOT NEW.text)
                BEGIN
                    \(bump(message: "NEW.message_id"))
                END;
                CREATE TRIGGER device_history_text_delete AFTER DELETE ON message_parts
                WHEN OLD.kind = 'text'
                BEGIN
                    \(bump(message: "OLD.message_id"))
                END;
                """)
            try db.execute(sql: "PRAGMA user_version = 68")
        }
    }

    /// Only invoked by the static trigger definitions above.
    private static func bump(message: String) -> String {
        """
        INSERT INTO device_history_sequences (conversation_id, sequence)
            SELECT conversation_id, 1 FROM messages
            WHERE id = \(message) AND role IN ('user', 'assistant')
            ON CONFLICT(conversation_id) DO UPDATE SET sequence = sequence + 1;
        INSERT INTO device_history_order (message_id, conversation_id, sequence)
            SELECT m.id, m.conversation_id, s.sequence
            FROM messages AS m JOIN device_history_sequences AS s ON s.conversation_id = m.conversation_id
            WHERE m.id = \(message) AND m.role IN ('user', 'assistant')
            ON CONFLICT(message_id) DO UPDATE SET sequence = excluded.sequence;
        """
    }
}
