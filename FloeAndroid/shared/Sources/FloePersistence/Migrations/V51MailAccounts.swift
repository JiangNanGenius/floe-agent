// SPDX-License-Identifier: MPL-2.0
//
// Android schema position 51: durable generic mail account settings.
//
// Additive table only. No existing table, column, index, trigger or migration
// is changed; the G09-R2 `selected_at` repair and every earlier v1-v50
// migration remain untouched. Passwords are NEVER stored here: the two
// credential-account columns hold opaque, bounded credential-gateway
// reference names. The matching Swift authority is
// FloeAndroidCore/C06MailDomain.swift (C06MailAccountStore); the SQL below is
// byte-identical to C06MailSchema.createTableSQL/createIndexSQL.
import GRDB

enum V51MailAccounts {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v51_mail_accounts") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS mail_accounts (
                    id TEXT PRIMARY KEY NOT NULL,
                    address TEXT NOT NULL,
                    display_name TEXT NOT NULL,
                    incoming_protocol TEXT NOT NULL,
                    incoming_host TEXT NOT NULL,
                    incoming_port INTEGER NOT NULL,
                    incoming_tls TEXT NOT NULL,
                    incoming_username TEXT NOT NULL,
                    incoming_credential_account TEXT NOT NULL,
                    outgoing_host TEXT NOT NULL,
                    outgoing_port INTEGER NOT NULL,
                    outgoing_tls TEXT NOT NULL,
                    outgoing_username TEXT NOT NULL,
                    outgoing_credential_account TEXT NOT NULL,
                    revision INTEGER NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS mail_accounts_updated_at
                ON mail_accounts(updated_at)
                """)
            try db.execute(sql: "PRAGMA user_version = 51")
        }
    }
}
