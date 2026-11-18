// SPDX-License-Identifier: MPL-2.0
import GRDB

/// Records the App composer's EXPLICIT `agent|chat|plan|goal` selection
/// beside the immutable three-value execution contract.
///
/// Both columns are NULLABLE on purpose:
///   * legacy rows keep NULL — absence is "never recorded", never a
///     retroactive claim that the user selected a mode;
///   * internal launches (goal continuation, plan accept, scheduled launches,
///     Notes, temporary sessions) and old envelopes that never carried an
///     explicit mode also stay NULL;
///   * `runs.conversation_mode` and every historical CHECK/row are untouched,
///     so the original `chat|plan|goal` contract, R2 data and rollback remain
///     exactly as before.
///
/// The values can only ever describe UI/restart provenance. The effective
/// permission contract is still the persisted task policy, compiled tool
/// availability and the ORIGINAL approvals; Plan keeps its read-only
/// projection and temporary sessions keep their separate frozen ceiling.
///
/// Version marker: like the immediately preceding additive v53 migration, this
/// release does NOT move the pinned `PRAGMA user_version`/`currentSchemaVersion`
/// (52). GRDB applies the migration by identifier; the coordinated 53/54 bump
/// and its version-pinned test update belong to the integration owner.
enum V54ExplicitExecutionMode {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v54_explicit_execution_mode") { db in
            try db.execute(sql: """
                ALTER TABLE runs ADD COLUMN explicit_execution_mode TEXT
                    CHECK(explicit_execution_mode IN ('agent', 'chat', 'plan', 'goal'));
                ALTER TABLE pending_user_inputs ADD COLUMN explicit_execution_mode TEXT
                    CHECK(explicit_execution_mode IN ('agent', 'chat', 'plan', 'goal'));
                """)
        }
    }
}
