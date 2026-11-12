// FloePersistence — create-only purpose record for the one-tap Linux cache
// cleanup task. See V63LinuxCacheCleanupTasks and LinuxCacheCleanupTaskProfile.
//
// This is deliberately not folded into task_policies: that table is edited by
// the ordinary task-permissions UI. The purpose profile must remain the outer
// ceiling even if a later policy row asks for more tools.

import Foundation
import GRDB
import FloeCore
import FloeModels

public struct LinuxCacheCleanupTaskStore: Sendable {
    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    /// First writer wins. Returns the stored row; a conflicting second writer
    /// gets the original row and must not broaden it.
    @discardableResult
    public func create(_ profile: LinuxCacheCleanupTaskProfile) async throws -> LinuxCacheCleanupTaskProfile {
        guard profile.isValid else {
            throw FloeError.validationFailed(
                "The Linux cleanup task profile is invalid; create a new cleanup task.")
        }
        try await database.writer { db in
            try Self.write(profile, in: db)
        }
        guard let saved = try await self.profile(conversationID: profile.conversationID) else {
            throw FloeError.storageCorrupted("The Linux cleanup task profile was not saved")
        }
        guard saved.environmentID == profile.environmentID,
              saved.backend == profile.backend,
              saved.profile == profile.profile,
              saved.runtimeGeneration == profile.runtimeGeneration else {
            throw FloeError.validationFailed(
                "This task already owns a different Linux cleanup purpose; create a new cleanup task.")
        }
        return saved
    }

    /// Internal transaction seam: conversation publication must not commit
    /// without its immutable purpose. Conflicting existing rows abort it.
    static func write(_ profile: LinuxCacheCleanupTaskProfile, in db: Database) throws {
        guard profile.isValid else { throw FloeError.validationFailed("Invalid Linux cleanup purpose") }
        try db.execute(sql: """
            INSERT INTO linux_cache_cleanup_tasks (
                conversation_id, profile, environment_id, backend,
                runtime_generation, created_at, revision
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(conversation_id) DO NOTHING
            """, arguments: [
                profile.conversationID.uuidString,
                profile.profile,
                profile.environmentID,
                profile.backend.rawValue,
                profile.runtimeGeneration,
                PersistenceCodec.encode(profile.createdAt),
                profile.revision
            ])
        guard let row = try Row.fetchOne(db, sql: """
            SELECT profile, environment_id, backend, runtime_generation, revision
            FROM linux_cache_cleanup_tasks WHERE conversation_id = ?
            """, arguments: [profile.conversationID.uuidString]),
              row["profile"] as String == profile.profile,
              row["environment_id"] as String == profile.environmentID,
              row["backend"] as String == profile.backend.rawValue,
              row["runtime_generation"] as String? == profile.runtimeGeneration,
              row["revision"] as Int64 == profile.revision else {
            throw FloeError.validationFailed("This task already owns a different Linux cleanup purpose")
        }
    }

    public func profile(conversationID: UUID) async throws -> LinuxCacheCleanupTaskProfile? {
        try await database.reader { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT conversation_id, profile, environment_id, backend,
                       runtime_generation, created_at, revision
                FROM linux_cache_cleanup_tasks
                WHERE conversation_id = ?
                """, arguments: [conversationID.uuidString]) else { return nil }
            guard let backend = TaskExecutionTarget.Backend(rawValue: row["backend"]),
                  let conversationID = UUID(uuidString: row["conversation_id"]) else {
                throw FloeError.storageCorrupted("The Linux cleanup task identity is unreadable")
            }
            let saved = LinuxCacheCleanupTaskProfile(
                conversationID: conversationID,
                environmentID: row["environment_id"],
                backend: backend,
                runtimeGeneration: row["runtime_generation"] as String?,
                profile: row["profile"],
                createdAt: try PersistenceCodec.decodeDate(row["created_at"]),
                revision: row["revision"]
            )
            guard saved.isValid else {
                throw FloeError.storageCorrupted("The Linux cleanup task profile is invalid")
            }
            return saved
        }
    }

    public func isCleanupConversation(_ conversationID: UUID) async throws -> Bool {
        let saved = try await profile(conversationID: conversationID)
        return saved != nil
    }

    /// Cleanup conversation identities that still exist. Used only for
    /// diagnostics/cleanup of app-owned bookkeeping; it is not a permission
    /// projection and never an enumeration tool for a model.
    public func conversationIDs(limit: Int = 256) async throws -> [UUID] {
        let bounded = min(1_000, max(1, limit))
        return try await database.reader { db in
            try String.fetchAll(db, sql: """
                SELECT conversation_id FROM linux_cache_cleanup_tasks
                ORDER BY created_at DESC LIMIT ?
                """, arguments: [bounded]).compactMap(UUID.init(uuidString:))
        }
    }
}
