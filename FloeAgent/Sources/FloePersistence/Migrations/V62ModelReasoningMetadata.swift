// SPDX-License-Identifier: MPL-2.0
import GRDB

/// Optional provider facts and an independent user-controlled omission flag.
/// Existing models remain unknown/default-off without a network refresh.
enum V62ModelReasoningMetadata {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v62_model_reasoning_metadata") { db in
            try db.execute(sql: """
                ALTER TABLE models ADD COLUMN reasoning_metadata_json TEXT;
                ALTER TABLE models ADD COLUMN omit_reasoning_parameters INTEGER NOT NULL DEFAULT 0
                    CHECK (omit_reasoning_parameters IN (0, 1));
                PRAGMA user_version = 62;
                """)
        }
    }
}
