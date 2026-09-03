import GRDB

/// Durable ownership for generated-image files between provider completion
/// and the atomic Canvas project-file commit. A reservation remains pending
/// across process death until launch reconciliation can prove whether the
/// exact result node/attempt was published.
enum V33GeneratedAssetReservations {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v33") { db in
            try db.execute(sql: """
                CREATE TABLE generated_asset_reservation_batches (
                    id TEXT PRIMARY KEY,
                    canvas_id TEXT NOT NULL,
                    document_id TEXT NOT NULL,
                    configuration_node_id TEXT NOT NULL,
                    generation_attempt_id TEXT NOT NULL,
                    expected_count INTEGER NOT NULL CHECK(expected_count BETWEEN 1 AND 4),
                    state TEXT NOT NULL CHECK(state IN ('preparing','reserved','committed','abandoned')),
                    created_at DATETIME NOT NULL,
                    updated_at DATETIME NOT NULL,
                    UNIQUE(canvas_id, document_id, generation_attempt_id)
                );

                CREATE TABLE generated_asset_reservations (
                    batch_id TEXT NOT NULL
                        REFERENCES generated_asset_reservation_batches(id) ON DELETE CASCADE,
                    slot_index INTEGER NOT NULL,
                    result_node_id TEXT NOT NULL,
                    candidate_asset_id TEXT NOT NULL,
                    content_hash TEXT NOT NULL,
                    candidate_relative_path TEXT NOT NULL,
                    canonical_asset_id TEXT
                        REFERENCES creative_assets(id) ON DELETE SET NULL,
                    was_inserted INTEGER NOT NULL DEFAULT 0,
                    state TEXT NOT NULL CHECK(state IN ('preparing','reserved','committed','abandoned')),
                    created_at DATETIME NOT NULL,
                    updated_at DATETIME NOT NULL,
                    PRIMARY KEY(batch_id, slot_index),
                    UNIQUE(batch_id, result_node_id)
                );

                CREATE INDEX idx_generated_asset_reservations_state_v33
                    ON generated_asset_reservation_batches(state, updated_at);
                CREATE INDEX idx_generated_asset_reservations_asset_v33
                    ON generated_asset_reservations(canonical_asset_id, state);

                PRAGMA user_version = 33;
                """)
        }
    }
}
