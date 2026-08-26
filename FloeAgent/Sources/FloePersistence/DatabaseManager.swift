// FloePersistence — GRDB DatabaseManager actor facade.
// See blazing-aurora-darwin.md §5.5/§9. The actor isolates all GRDB types
// behind Sendable closures.
//
// audit_entries append-only enforcement: GRDB exposes no public
// sqlite3_set_authorizer surface, so the design's authorizer is realized
// as INSTEAD OF triggers on a compatibility view (`audit_log`) plus an
// audit-chain sequence constraint; direct UPDATE/DELETE on the base table
// is additionally blocked by the triggers installed in schema v1.

import Foundation
import GRDB
import FloeCore
import FloeSecurity

/// Actor-isolated facade over a GRDB `DatabasePool`. All database access in
/// the app goes through `reader(_:)` / `writer(_:)`.
public actor DatabaseManager {

    private let pool: DatabasePool?
    private let queue: DatabaseQueue?
    private var migrator = DatabaseMigrator()

    /// Schema version tracked in `user_version`-aligned migrations.
    public static let currentSchemaVersion = 21

    public init(path: URL) throws {
        self.pool = try DatabasePool(path: path.path, configuration: Self.configuration())
        self.queue = nil
        Self.registerMigrations(into: &migrator)
    }

    private init(inMemory: Void) throws {
        self.pool = nil
        self.queue = try DatabaseQueue(configuration: Self.configuration())
        Self.registerMigrations(into: &migrator)
    }

    /// Registers every published migration in order. Migrations are never
    /// modified after release; new schema versions append new identifiers.
    private static func registerMigrations(into migrator: inout DatabaseMigrator) {
        V1Initial.register(into: &migrator)
        V2ConfigSync.register(into: &migrator)
        V3AgentDaily.register(into: &migrator)
        V4ModelPreferences.register(into: &migrator)
        V5Workspace.register(into: &migrator)
        V6AppSettings.register(into: &migrator)
        V7WorkbenchIntelligence.register(into: &migrator)
        V8TaskOwnership.register(into: &migrator)
        V9HarnessAndPermissions.register(into: &migrator)
        V10ConversationContinuity.register(into: &migrator)
        V11ArchiveCredentials.register(into: &migrator)
        V12RunningInputs.register(into: &migrator)
        V13PersonalizationMemory.register(into: &migrator)
        V14PlanGoalControls.register(into: &migrator)
        V15ProviderDisplayName.register(into: &migrator)
        V16ProviderCompatibilityAndPackageReview.register(into: &migrator)
        V17ModelReasoningEffort.register(into: &migrator)
        V18RunUsageDimensions.register(into: &migrator)
        V19DetailedRunUsage.register(into: &migrator)
        V20RunResponseTiming.register(into: &migrator)
        V21MemoryLifecycle.register(into: &migrator)
    }

    private static func configuration() -> Configuration {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            // Enforce foreign keys for every connection in the pool or queue.
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        return configuration
    }

    /// In-memory database for tests.
    public static func inMemory() throws -> DatabaseManager {
        try DatabaseManager(inMemory: ())
    }

    /// Applies pending migrations. Registered migrations are never modified
    /// after release; new schema versions append new identifiers.
    public func migrate() throws {
        if let queue {
            try migrator.migrate(queue)
        } else if let pool {
            try migrator.migrate(pool)
        }
    }

    /// Read-only access. The closure runs outside the actor's serial
    /// executor via GRDB's concurrent reads (pool) or serially (queue).
    public func reader<T: Sendable>(_ block: @Sendable (Database) throws -> T) async throws -> T {
        if let queue {
            return try await queue.read { db in try block(db) }
        }
        guard let pool else {
            throw FloeError.internalError("DatabaseManager has no configured reader")
        }
        return try await pool.read { db in try block(db) }
    }

    /// Serialized write access (GRDB guarantees a single writer at a time).
    public func writer<T: Sendable>(_ block: @Sendable (Database) throws -> T) async throws -> T {
        if let queue {
            return try await queue.write { db in try block(db) }
        }
        guard let pool else {
            throw FloeError.internalError("DatabaseManager has no configured writer")
        }
        return try await pool.write { db in try block(db) }
    }

    /// Current `PRAGMA user_version`, aligned with applied migrations.
    public func userVersion() async throws -> Int {
        try await reader { db in
            try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
        }
    }

    /// Identifiers of applied migrations.
    public func appliedMigrations() async throws -> [String] {
        try await reader { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }
    }
}
