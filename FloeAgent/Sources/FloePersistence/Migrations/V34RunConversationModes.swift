import GRDB

/// Persists the execution contract on the immutable run identity. A
/// conversation's current mode is mutable and therefore cannot safely decide
/// how an older interrupted run resumes.
enum V34RunConversationModes {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v34") { db in
            try db.execute(sql: """
                ALTER TABLE runs ADD COLUMN conversation_mode TEXT
                    CHECK(conversation_mode IN ('chat', 'plan', 'goal'));
                PRAGMA user_version = 34;
                """)
        }
    }
}
