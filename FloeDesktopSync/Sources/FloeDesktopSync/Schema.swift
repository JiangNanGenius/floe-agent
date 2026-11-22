import Foundation

/// Schema v3 adds the receiving side of the snapshot protocol: durable
/// per-scope subscriptions, staged inbound snapshots, staged pages and staged
/// records. Migration is additive; v1/v2 records, commands, conflicts and the
/// legacy per-peer global cursor remain untouched. The legacy global cursor is
/// deliberately not promoted into a subscription: only a complete verified
/// snapshot can establish a scope cursor.
enum SyncSchema {
    static let version: Int32 = 5

    static let requiredTables = [
        "meta",
        "records",
        "changes",
        "commands",
        "execution_heads",
        "snapshots",
        "snapshot_entries",
        "applied_cursors",
        "local_workspace_bindings",
        "legacy_bridge_mappings",
        "conflicts",
        "sync_subscriptions",
        "snapshot_imports",
        "snapshot_import_pages",
        "snapshot_import_records",
        "sync_scope_authorizations",
        "incremental_receipts"
    ]

    static func migrateIfNeeded(_ connection: SQLiteConnection) throws {
        let current = try connection.userVersionValue()
        if current == 0 {
            do {
                try connection.execute("BEGIN IMMEDIATE")
                for statement in createStatements {
                    try connection.execute(statement)
                }
                try connection.setUserVersion(version)
                // A failed schema check must roll back this version and all
                // schema changes, rather than leaving a committed partial DB.
                try verify(connection)
                try connection.execute("COMMIT")
            } catch {
                _ = try? connection.execute("ROLLBACK")
                throw error
            }
            try verify(connection)
            return
        }
        if current == version {
            try verify(connection)
            return
        }
        if current == 1 || current == 2 || current == 3 || current == 4 {
            do {
                try connection.execute("BEGIN IMMEDIATE")
                if current == 1 {
                    for statement in migrateV1ToV2Statements {
                        try connection.execute(statement)
                    }
                }
                if current <= 2 {
                    for statement in migrateV2ToV3Statements {
                        try connection.execute(statement)
                    }
                }
                if current <= 3 {
                    // Existing snapshots have no provable tombstone
                    // provenance. Preserve their rows, but never export them
                    // as complete.
                    try connection.execute("ALTER TABLE snapshots ADD COLUMN manifest_complete INTEGER NOT NULL DEFAULT 0")
                }
                if current <= 4 {
                    // v4 -> v5 adds only receiver-side authorization and
                    // incremental replay receipts. Existing records, commands,
                    // conflicts, snapshots and subscriptions are untouched.
                    for statement in migrateV4ToV5Statements {
                        try connection.execute(statement)
                    }
                }
                try connection.setUserVersion(version)
                try verify(connection)
                try connection.execute("COMMIT")
            } catch {
                _ = try? connection.execute("ROLLBACK")
                throw error
            }
            try verify(connection)
            return
        }
        if current > version {
            throw SyncStoreError.unsupportedSchemaVersion(current)
        }
        throw SyncStoreError.schemaCorrupt("no migration path from schema version \(current)")
    }

    static func verify(_ connection: SQLiteConnection) throws {
        for table in requiredTables {
            let statement = try connection.prepare(
                "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?"
            )
            try statement.bind(1, table)
            guard try statement.step() else {
                throw SyncStoreError.schemaCorrupt("missing table \(table)")
            }
        }
        for (table, column) in requiredColumns {
            let statement = try connection.prepare("PRAGMA table_info(\(table))")
            var found = false
            while try statement.step() {
                if statement.text(1) == column {
                    found = true
                    break
                }
            }
            guard found else {
                throw SyncStoreError.schemaCorrupt("missing column \(table).\(column)")
            }
        }
        guard try connection.userVersionValue() == version else {
            throw SyncStoreError.schemaCorrupt("user_version does not match schema \(version)")
        }
    }

    private static let requiredColumns: [(String, String)] = [
        ("records", "base_revision"),
        ("records", "base_digest"),
        ("changes", "base_revision"),
        ("changes", "base_digest"),
        ("commands", "target_entity_kind"),
        ("commands", "target_entity_id"),
        ("snapshots", "scope_kind"),
        ("snapshots", "scope_id"),
        ("snapshots", "tombstone_count"),
        ("snapshots", "manifest_complete"),
        ("snapshot_entries", "base_revision"),
        ("snapshot_entries", "base_digest"),
        ("snapshot_entries", "deleted"),
        ("sync_subscriptions", "subscription_version"),
        ("sync_subscriptions", "established"),
        ("snapshot_imports", "manifest_digest"),
        ("snapshot_imports", "next_page_index"),
        ("snapshot_imports", "state"),
        ("snapshot_import_pages", "page_digest"),
        ("snapshot_import_records", "position"),
        ("sync_scope_authorizations", "granted_at"),
        ("incremental_receipts", "through_cursor"),
        ("incremental_receipts", "content_digest")
    ]

    /// The v1 tables remain readable. New columns are nullable (or carry a
    /// default), so the ALTERs do not rewrite or lose existing rows.
    private static let migrateV1ToV2Statements: [String] = [
        "ALTER TABLE records ADD COLUMN base_revision INTEGER",
        "ALTER TABLE records ADD COLUMN base_digest TEXT",
        "ALTER TABLE changes ADD COLUMN base_revision INTEGER",
        "ALTER TABLE changes ADD COLUMN base_digest TEXT",
        "ALTER TABLE commands ADD COLUMN target_entity_kind TEXT",
        "ALTER TABLE commands ADD COLUMN target_entity_id TEXT",
        "ALTER TABLE snapshots ADD COLUMN scope_kind TEXT NOT NULL DEFAULT 'all'",
        "ALTER TABLE snapshots ADD COLUMN scope_id TEXT",
        "ALTER TABLE snapshots ADD COLUMN tombstone_count INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE snapshot_entries ADD COLUMN base_revision INTEGER",
        "ALTER TABLE snapshot_entries ADD COLUMN base_digest TEXT",
        "ALTER TABLE snapshot_entries ADD COLUMN deleted INTEGER NOT NULL DEFAULT 0",
        conflictTableStatement,
        conflictOpenIndexStatement
    ]

    /// v3 only creates new tables and indexes. It does not rewrite or backfill
    /// `applied_cursors`: a legacy peer-wide position cannot prove that any
    /// particular scope was received completely.
    private static let migrateV2ToV3Statements: [String] = v3TableStatements

    /// v4 -> v5 adds the receiver-side scope authorization registry and a
    /// bounded replay-receipt log for authenticated incremental batches. No
    /// existing row is rewritten; old databases gain empty tables only.
    private static let migrateV4ToV5Statements: [String] = v5TableStatements

    private static let v3TableStatements: [String] = [
        """
        CREATE TABLE IF NOT EXISTS sync_subscriptions (
            peer_device_id TEXT NOT NULL,
            scope_kind TEXT NOT NULL CHECK (scope_kind IN ('all', 'task', 'workspace')),
            scope_id TEXT NOT NULL DEFAULT '',
            subscription_version INTEGER NOT NULL CHECK (subscription_version > 0),
            applied_cursor INTEGER NOT NULL DEFAULT 0 CHECK (applied_cursor >= 0),
            established INTEGER NOT NULL DEFAULT 0 CHECK (established IN (0, 1)),
            last_snapshot_id TEXT,
            updated_at INTEGER NOT NULL,
            PRIMARY KEY (peer_device_id, scope_kind, scope_id)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS snapshot_imports (
            peer_device_id TEXT NOT NULL,
            snapshot_id TEXT NOT NULL,
            scope_kind TEXT NOT NULL CHECK (scope_kind IN ('all', 'task', 'workspace')),
            scope_id TEXT NOT NULL DEFAULT '',
            subscription_version INTEGER NOT NULL CHECK (subscription_version > 0),
            base_cursor INTEGER NOT NULL CHECK (base_cursor >= 0),
            manifest_digest TEXT NOT NULL,
            manifest_blob BLOB NOT NULL,
            entry_count INTEGER NOT NULL CHECK (entry_count >= 0),
            record_count INTEGER NOT NULL CHECK (record_count >= 0),
            tombstone_count INTEGER NOT NULL CHECK (tombstone_count >= 0),
            page_count INTEGER NOT NULL CHECK (page_count >= 0),
            next_page_index INTEGER NOT NULL DEFAULT 0,
            received_page_count INTEGER NOT NULL DEFAULT 0,
            received_entry_count INTEGER NOT NULL DEFAULT 0,
            staged_bytes INTEGER NOT NULL DEFAULT 0,
            state TEXT NOT NULL CHECK (state IN ('staging', 'committed')),
            created_at INTEGER NOT NULL,
            expires_at INTEGER NOT NULL,
            committed_at INTEGER,
            receipt BLOB,
            PRIMARY KEY (peer_device_id, snapshot_id)
        )
        """,
        """
        CREATE UNIQUE INDEX IF NOT EXISTS snapshot_imports_staging_scope_idx
        ON snapshot_imports(peer_device_id, scope_kind, scope_id)
        WHERE state = 'staging'
        """,
        """
        CREATE TABLE IF NOT EXISTS snapshot_import_pages (
            peer_device_id TEXT NOT NULL,
            snapshot_id TEXT NOT NULL,
            page_index INTEGER NOT NULL CHECK (page_index >= 0),
            first_position INTEGER NOT NULL CHECK (first_position >= 1),
            last_position INTEGER NOT NULL CHECK (last_position >= first_position),
            entry_count INTEGER NOT NULL CHECK (entry_count >= 1),
            byte_count INTEGER NOT NULL CHECK (byte_count >= 0),
            page_digest TEXT NOT NULL,
            received_at INTEGER NOT NULL,
            PRIMARY KEY (peer_device_id, snapshot_id, page_index),
            FOREIGN KEY (peer_device_id, snapshot_id)
                REFERENCES snapshot_imports(peer_device_id, snapshot_id)
                ON DELETE CASCADE
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS snapshot_import_records (
            peer_device_id TEXT NOT NULL,
            snapshot_id TEXT NOT NULL,
            position INTEGER NOT NULL CHECK (position >= 1),
            entity_kind TEXT NOT NULL,
            entity_id TEXT NOT NULL,
            task_id TEXT,
            workspace_id TEXT,
            revision INTEGER NOT NULL,
            base_revision INTEGER,
            base_digest TEXT,
            origin_device_id TEXT NOT NULL,
            payload BLOB NOT NULL,
            payload_digest TEXT NOT NULL,
            deleted INTEGER NOT NULL DEFAULT 0 CHECK (deleted IN (0, 1)),
            PRIMARY KEY (peer_device_id, snapshot_id, position),
            UNIQUE (peer_device_id, snapshot_id, entity_kind, entity_id),
            FOREIGN KEY (peer_device_id, snapshot_id)
                REFERENCES snapshot_imports(peer_device_id, snapshot_id)
                ON DELETE CASCADE
        )
        """,
        """
        CREATE INDEX IF NOT EXISTS snapshot_import_records_entity_idx
        ON snapshot_import_records(peer_device_id, snapshot_id, entity_kind, entity_id)
        """
    ]

    private static let v5TableStatements: [String] = [
        """
        CREATE TABLE IF NOT EXISTS sync_scope_authorizations (
            peer_device_id TEXT NOT NULL,
            scope_kind TEXT NOT NULL CHECK (scope_kind IN ('all', 'task', 'workspace')),
            scope_id TEXT NOT NULL DEFAULT '',
            granted_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            PRIMARY KEY (peer_device_id, scope_kind, scope_id)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS incremental_receipts (
            receipt_id INTEGER PRIMARY KEY AUTOINCREMENT,
            peer_device_id TEXT NOT NULL,
            scope_kind TEXT NOT NULL CHECK (scope_kind IN ('all', 'task', 'workspace')),
            scope_id TEXT NOT NULL DEFAULT '',
            subscription_version INTEGER NOT NULL CHECK (subscription_version > 0),
            from_cursor INTEGER NOT NULL CHECK (from_cursor >= 0),
            through_cursor INTEGER NOT NULL CHECK (through_cursor >= from_cursor),
            content_digest TEXT NOT NULL,
            applied_at INTEGER NOT NULL,
            result BLOB NOT NULL,
            UNIQUE (
                peer_device_id, scope_kind, scope_id, subscription_version,
                from_cursor, through_cursor
            )
        )
        """,
        """
        CREATE INDEX IF NOT EXISTS incremental_receipts_scope_idx
        ON incremental_receipts(
            peer_device_id, scope_kind, scope_id, subscription_version, receipt_id
        )
        """
    ]

    private static let conflictTableStatement = """
        CREATE TABLE IF NOT EXISTS conflicts (
            conflict_id TEXT PRIMARY KEY NOT NULL,
            peer_device_id TEXT NOT NULL,
            entity_kind TEXT NOT NULL,
            entity_id TEXT NOT NULL,
            task_id TEXT,
            workspace_id TEXT,
            incoming_task_id TEXT,
            incoming_workspace_id TEXT,
            reason TEXT NOT NULL CHECK (reason IN (
                'staleRemoteRevision', 'localUnsyncedEdit',
                'revisionPayloadMismatch', 'concurrentDivergence',
                'missingBaseRevision'
            )),
            local_revision INTEGER NOT NULL,
            local_origin_device_id TEXT NOT NULL,
            local_base_revision INTEGER,
            local_base_digest TEXT,
            local_payload_digest TEXT NOT NULL,
            local_payload BLOB NOT NULL,
            local_deleted INTEGER NOT NULL CHECK (local_deleted IN (0, 1)),
            incoming_revision INTEGER NOT NULL,
            incoming_origin_device_id TEXT NOT NULL,
            incoming_base_revision INTEGER,
            incoming_base_digest TEXT,
            incoming_payload_digest TEXT NOT NULL,
            incoming_payload BLOB NOT NULL,
            incoming_deleted INTEGER NOT NULL CHECK (incoming_deleted IN (0, 1)),
            observed_cursor INTEGER NOT NULL,
            status TEXT NOT NULL CHECK (status IN ('open', 'resolved')),
            resolution TEXT,
            created_at INTEGER NOT NULL,
            resolved_at INTEGER
        )
        """

    private static let conflictOpenIndexStatement =
        "CREATE INDEX IF NOT EXISTS conflicts_open_idx ON conflicts(status, entity_kind, entity_id)"

    private static let createStatements: [String] = [
        """
        CREATE TABLE IF NOT EXISTS meta (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS records (
            entity_kind TEXT NOT NULL,
            entity_id TEXT NOT NULL,
            task_id TEXT,
            workspace_id TEXT,
            revision INTEGER NOT NULL CHECK (revision > 0),
            base_revision INTEGER,
            base_digest TEXT,
            origin_device_id TEXT NOT NULL,
            payload BLOB NOT NULL,
            payload_digest TEXT NOT NULL,
            deleted INTEGER NOT NULL DEFAULT 0 CHECK (deleted IN (0, 1)),
            local_dirty INTEGER NOT NULL DEFAULT 0 CHECK (local_dirty IN (0, 1)),
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            PRIMARY KEY (entity_kind, entity_id)
        )
        """,
        "CREATE INDEX IF NOT EXISTS records_task_idx ON records(task_id)",
        "CREATE INDEX IF NOT EXISTS records_workspace_idx ON records(workspace_id)",
        """
        CREATE TABLE IF NOT EXISTS changes (
            sequence INTEGER PRIMARY KEY AUTOINCREMENT,
            entity_kind TEXT NOT NULL,
            entity_id TEXT NOT NULL,
            task_id TEXT,
            workspace_id TEXT,
            revision INTEGER NOT NULL,
            base_revision INTEGER,
            base_digest TEXT,
            change_type TEXT NOT NULL CHECK (change_type IN ('upsert', 'delete')),
            origin_device_id TEXT NOT NULL,
            payload BLOB,
            payload_digest TEXT NOT NULL,
            recorded_at INTEGER NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS changes_entity_idx ON changes(entity_kind, entity_id)",
        """
        CREATE TABLE IF NOT EXISTS commands (
            command_id TEXT PRIMARY KEY NOT NULL,
            protocol_major INTEGER NOT NULL,
            protocol_minor INTEGER NOT NULL,
            kind TEXT NOT NULL,
            task_id TEXT,
            workspace_id TEXT,
            run_id TEXT,
            expected_revision INTEGER,
            execution_epoch INTEGER,
            target_entity_kind TEXT,
            target_entity_id TEXT,
            payload BLOB NOT NULL,
            payload_digest TEXT NOT NULL,
            command_digest TEXT NOT NULL,
            state TEXT NOT NULL CHECK (state IN (
                'accepted', 'started', 'completed', 'failed', 'cancelled', 'outcomeUnknown'
            )),
            result BLOB,
            accepted_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS commands_state_idx ON commands(state)",
        """
        CREATE TABLE IF NOT EXISTS execution_heads (
            run_id TEXT PRIMARY KEY NOT NULL,
            task_id TEXT NOT NULL,
            epoch INTEGER NOT NULL CHECK (epoch > 0),
            owner_device_id TEXT NOT NULL,
            updated_at INTEGER NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS snapshots (
            snapshot_id TEXT PRIMARY KEY NOT NULL,
            base_cursor INTEGER NOT NULL,
            record_count INTEGER NOT NULL,
            tombstone_count INTEGER NOT NULL DEFAULT 0,
            manifest_complete INTEGER NOT NULL DEFAULT 0 CHECK (manifest_complete IN (0, 1)),
            scope_kind TEXT NOT NULL DEFAULT 'all',
            scope_id TEXT,
            created_at INTEGER NOT NULL,
            expires_at INTEGER NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS snapshot_entries (
            snapshot_id TEXT NOT NULL,
            position INTEGER NOT NULL,
            entity_kind TEXT NOT NULL,
            entity_id TEXT NOT NULL,
            task_id TEXT,
            workspace_id TEXT,
            revision INTEGER NOT NULL,
            base_revision INTEGER,
            base_digest TEXT,
            origin_device_id TEXT NOT NULL,
            payload BLOB NOT NULL,
            payload_digest TEXT NOT NULL,
            deleted INTEGER NOT NULL DEFAULT 0 CHECK (deleted IN (0, 1)),
            updated_at INTEGER NOT NULL,
            PRIMARY KEY (snapshot_id, position),
            FOREIGN KEY (snapshot_id) REFERENCES snapshots(snapshot_id) ON DELETE CASCADE
        )
        """,
        "CREATE INDEX IF NOT EXISTS snapshot_entries_entity_idx ON snapshot_entries(snapshot_id, entity_kind, entity_id)",
        """
        CREATE TABLE IF NOT EXISTS applied_cursors (
            peer_device_id TEXT PRIMARY KEY NOT NULL,
            cursor INTEGER NOT NULL CHECK (cursor >= 0),
            updated_at INTEGER NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS local_workspace_bindings (
            workspace_id TEXT NOT NULL,
            device_id TEXT NOT NULL,
            root_path TEXT NOT NULL,
            bookmark BLOB,
            updated_at INTEGER NOT NULL,
            PRIMARY KEY (workspace_id, device_id)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS legacy_bridge_mappings (
            legacy_identifier TEXT PRIMARY KEY NOT NULL,
            entity_kind TEXT NOT NULL,
            stable_entity_id TEXT NOT NULL,
            created_at INTEGER NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS legacy_bridge_stable_idx ON legacy_bridge_mappings(entity_kind, stable_entity_id)",
        conflictTableStatement,
        conflictOpenIndexStatement
    ] + v3TableStatements + v5TableStatements
}
