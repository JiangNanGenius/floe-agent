import GRDB

/// Advisory-group ownership for the one-time long-run duration advisory.
///
/// New time policy (2026-10-26): default execution is unlimited, and the
/// user receives ONE reminder after 600 seconds of host monotonic elapsed
/// execution. A multi-phase native operation (e.g. one MCP service creation
/// record across its bound build-phase jobs) is ONE logical unit of work:
/// its phases share a trusted native-owned `advisory_group_id` so the
/// advisory identity and its 600-second threshold belong to the whole
/// operation instead of resetting (or duplicating) at every phase handoff.
///
/// Additive and nullable: ungrouped jobs keep per-job advisory identity,
/// existing rows decode unchanged, and the column never affects job state,
/// payload binding, provenance or the terminal state machine. The group id
/// is accepted only from a trusted `.nativeService` submission (the app's
/// own operation owner, e.g. `MCPServiceCreationRecord.id`) — a
/// model/runtime submission can never supply it, so a model-authored alias
/// can never merge or split advisory ownership.
public enum V54JobAdvisoryGroups {
    public static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v54_job_advisory_groups") { db in
            try db.alter(table: "background_jobs") { table in
                table.add(column: "advisory_group_id", .text)
            }
            try db.create(
                index: "background_jobs_advisory_group",
                on: "background_jobs",
                columns: ["advisory_group_id", "state"]
            )
            try db.execute(sql: "PRAGMA user_version = 54")
        }
    }
}
