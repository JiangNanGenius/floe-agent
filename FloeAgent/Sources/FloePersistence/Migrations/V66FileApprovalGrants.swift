import GRDB

/// A remembered file operation belongs to a workspace, and optionally one
/// conversation. Legacy host grants retain their original scope.
enum V66FileApprovalGrants {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v66") { db in
            try db.execute(sql: """
                ALTER TABLE approval_grants ADD COLUMN conversation_id TEXT REFERENCES conversations(id) ON DELETE CASCADE;
                ALTER TABLE approval_grants ADD COLUMN authorization_identity TEXT;
                CREATE INDEX approval_grants_file ON approval_grants(workspace_id, tool_name)
                    WHERE authorization_identity IS NOT NULL;
                PRAGMA user_version = 66;
                """)
        }
    }
}
