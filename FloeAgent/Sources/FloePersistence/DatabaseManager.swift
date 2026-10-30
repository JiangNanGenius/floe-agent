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

    /// Weak registry of live managers so the process-level suspension hook can
    /// drain every GRDB writer (the live store and any recovery store) without
    /// the App lifecycle coordinator holding one strong instance.
    private final class SuspensionDrainRegistry: @unchecked Sendable {
        private final class Entry {
            weak var manager: DatabaseManager?
            init(_ manager: DatabaseManager) { self.manager = manager }
        }
        private let lock = NSLock()
        private var entries: [Entry] = []

        func register(_ manager: DatabaseManager) {
            lock.lock()
            entries.removeAll { $0.manager == nil }
            entries.append(Entry(manager))
            lock.unlock()
        }

        func snapshot() -> [DatabaseManager] {
            lock.lock()
            defer { lock.unlock() }
            entries.removeAll { $0.manager == nil }
            return entries.compactMap(\.manager)
        }
    }
    private static let suspensionDrainRegistry = SuspensionDrainRegistry()

    private let pool: DatabasePool?
    private let queue: DatabaseQueue?
    private var migrator = DatabaseMigrator()

    /// Schema version tracked in `user_version`-aligned migrations. Must
    /// match the highest registered migration; every historical bump
    /// paired this constant with the new migration so that
    /// `user_version == currentSchemaVersion` after `migrate()`.
    /// Note: the v54 lane shipped `PRAGMA user_version = 54` while this
    /// constant still read 53; v55 restores the alignment invariant.
    /// v56 adds durable task-bound user questions; v57 adds the trusted
    /// conversation origin used by scheduled-task presentation.
    public static let currentSchemaVersion = 58

    public init(path: URL) throws {
        self.pool = try DatabasePool(path: path.path, configuration: Self.configuration())
        self.queue = nil
        Self.registerMigrations(into: &migrator)
        Self.suspensionDrainRegistry.register(self)
    }

    private init(inMemory: Void) throws {
        self.pool = nil
        self.queue = try DatabaseQueue(configuration: Self.configuration())
        Self.registerMigrations(into: &migrator)
        Self.suspensionDrainRegistry.register(self)
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
        V22RemoteDevices.register(into: &migrator)
        V23ModelPickerVisibility.register(into: &migrator)
        V24VideoModelRouting.register(into: &migrator)
        V25DeferredSyncPayloads.register(into: &migrator)
        V26CreativeMediaJobs.register(into: &migrator)
        V27CloudReleaseModes.register(into: &migrator)
        V28CanvasModelRouting.register(into: &migrator)
        V29ModelUseSurfaces.register(into: &migrator)
        V30MemoryOrganization.register(into: &migrator)
        V31TimelinePerformance.register(into: &migrator)
        V32CanvasRunContexts.register(into: &migrator)
        V33GeneratedAssetReservations.register(into: &migrator)
        V34RunConversationModes.register(into: &migrator)
        V35GeneralAuxiliaryLLM.register(into: &migrator)
        V36LocalWorkspaceCleanup.register(into: &migrator)
        V37TaskChecklists.register(into: &migrator)
        V38ImageAutonomy.register(into: &migrator)
        V39BackgroundJobs.register(into: &migrator)
        V40ExecutionEnvironments.register(into: &migrator)
        V41ConversationPurpose.register(into: &migrator)
        V42MediaJobOwners.register(into: &migrator)
        V43MediaJobIdempotency.register(into: &migrator)
        V44ConversationSearchIndexRepair.register(into: &migrator)
        V45AssetReferenceOps.register(into: &migrator)
        V46TaskLifecycle.register(into: &migrator)
        V47ShortcutInbox.register(into: &migrator)
        V48SystemAlarms.register(into: &migrator)
        V49ChildRunCheckpoints.register(into: &migrator)
        V50ScheduleCleanupReminders.register(into: &migrator)
        V51ChatPreferences.register(into: &migrator)
        V52PersonalizationRetention.register(into: &migrator)
        V53ConversationVisibility.register(into: &migrator)
        V54JobAdvisoryGroups.register(into: &migrator)
        V55ConversationPinning.register(into: &migrator)
        V56UserQuestions.register(into: &migrator)
        V57SchedulePresentation.register(into: &migrator)
        V58TaskExecutionBindings.register(into: &migrator)
    }

    private static func configuration() -> Configuration {
        var configuration = Configuration()
        configuration.observesSuspensionNotifications = true
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
    public func migrate() async throws {
        let lease = try await StorageOperationBudget.begin()
        defer { lease.finish() }
        try lease.check()
        if let queue {
            try migrator.migrate(queue)
            try await queue.write { db in
                try lease.check()
                try Self.repairPrereleaseChatSchemaVersion(db)
            }
        } else if let pool {
            try migrator.migrate(pool)
            try await pool.write { db in
                try lease.check()
                try Self.repairPrereleaseChatSchemaVersion(db)
            }
        }
    }

    /// Early v51 development builds recorded the migration without updating
    /// user_version. Repair metadata only after GRDB confirms v51 was applied;
    /// never replay its table creation or lower a newer database version.
    private static func repairPrereleaseChatSchemaVersion(_ db: Database) throws {
        let version = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
        guard version < 51,
              try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = ?",
                               arguments: ["v51_chat_preferences"]) == 1 else { return }
        try db.execute(sql: "PRAGMA user_version = 51")
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
        let lease = try await StorageOperationBudget.begin()
        defer { lease.finish() }
        try lease.check()
        if let queue {
            return try await queue.write { db in
                try lease.check()
                return try block(db)
            }
        }
        guard let pool else {
            throw FloeError.internalError("DatabaseManager has no configured writer")
        }
        return try await pool.write { db in
            try lease.check()
            return try block(db)
        }
    }

    /// GRDB interrupts unsafe transactions and prevents a suspended writer
    /// acquiring a SQLite lock. WAL readers can continue without that lock.
    public nonisolated static func suspendConnections() {
        NotificationCenter.default.post(name: Database.suspendNotification, object: nil)
    }

    public nonisolated static func resumeConnections() {
        NotificationCenter.default.post(name: Database.resumeNotification, object: nil)
    }

    /// Fences GRDB and joins the writer queues of every live manager before
    /// the caller returns the process's last background execution assertion.
    ///
    /// `suspendNotification` is intentionally not synchronous with respect to
    /// lock release: GRDB sets a suspension flag and calls
    /// `sqlite3_interrupt`, while the transaction that owns the database lock
    /// unwinds on the writer queue. An empty write barrier is therefore
    /// enqueued behind any in-flight writer; reaching it proves that the
    /// previous statement/transaction has ended. The barrier may observe
    /// `SQLITE_ABORT`/cancellation because the database is suspended; that is
    /// still a completed drain and is deliberately ignored.
    ///
    /// The notification is process-wide, so the drain matches every live
    /// manager (the main App store and any recovery/in-memory environment).
    public static func suspendConnectionsAndDrainWriter() async {
        Self.suspendConnections()
        await drainWriterQueues()
    }

    /// Joins the writer queue of every live manager without posting the
    /// process-wide suspension again. Callers that must record the posted
    /// state synchronously (before any await) call `suspendConnections()` and
    /// then this drain separately.
    public static func drainWriterQueues() async {
        for manager in suspensionDrainRegistry.snapshot() {
            await manager.drainWriterForSuspension()
        }
    }

    private func drainWriterForSuspension() async {
        if let queue {
            _ = try? await queue.writeWithoutTransaction { (_: Database) in () }
        } else if let pool {
            _ = try? await pool.writeWithoutTransaction { (_: Database) in () }
        }
    }

    /// The single underlying GRDB reader, exposed ONLY for read-only
    /// `ValueObservation` attachments by table owners. Returning the app's
    /// one connection prevents a second pool/queue (which could never see
    /// these commits anyway); the value conforms to `DatabaseReader`
    /// (AnyObject, Sendable) and carries no mutation surface. Observations
    /// grant no lifecycle power: they read.
    public func observationReader() throws -> any DatabaseReader {
        if let pool {
            return pool
        }
        guard let queue else {
            throw FloeError.internalError("DatabaseManager has no configured reader")
        }
        return queue
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

    /// Closes the underlying pool/queue so the database file can be removed
    /// without an open SQLite connection. Tests that unlink a file-backed
    /// store must call this first; after it, the manager is unusable.
    public func close() async throws {
        if let pool { try await pool.close() }
        if let queue { try queue.close() }
    }
}
