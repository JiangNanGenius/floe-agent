import Foundation
import GRDB
import FloeCore

public struct CreativeAssetRecord: Sendable, Codable, Identifiable, Hashable {
    public var id: UUID
    public var contentHash: String
    public var kind: MediaKind
    public var displayName: String
    public var mimeType: String?
    public var localRelativePath: String?
    public var cloudRecordName: String?
    public var byteCount: Int64
    public var sourceURL: URL?
    public var license: String?
    public var tags: [String]
    public var referenceCount: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID,
        contentHash: String,
        kind: MediaKind,
        displayName: String,
        mimeType: String? = nil,
        localRelativePath: String? = nil,
        cloudRecordName: String? = nil,
        byteCount: Int64 = 0,
        sourceURL: URL? = nil,
        license: String? = nil,
        tags: [String] = [],
        referenceCount: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.contentHash = contentHash
        self.kind = kind
        self.displayName = displayName
        self.mimeType = mimeType
        self.localRelativePath = localRelativePath
        self.cloudRecordName = cloudRecordName
        self.byteCount = byteCount
        self.sourceURL = sourceURL
        self.license = license
        self.tags = tags
        self.referenceCount = referenceCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct PendingCloudAssetRelease: Sendable, Hashable {
    public var release: CloudAssetRelease
    public var cloudRecordName: String
}

public actor CreativeAssetStore {
    private let database: DatabaseManager
    public init(database: DatabaseManager) { self.database = database }

    public func save(_ asset: CreativeAssetRecord) async throws {
        let tags = try JSONEncoder().encode(asset.tags)
        try await database.writer { db in
            try db.execute(sql: """
                INSERT INTO creative_assets (
                    id, content_hash, kind, display_name, mime_type,
                    local_relative_path, cloud_record_name, byte_count,
                    source_url, license, tags_json, reference_count,
                    created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(content_hash) DO UPDATE SET
                    local_relative_path=COALESCE(excluded.local_relative_path, local_relative_path),
                    cloud_record_name=COALESCE(excluded.cloud_record_name, cloud_record_name),
                    display_name=excluded.display_name, mime_type=excluded.mime_type,
                    byte_count=excluded.byte_count, source_url=excluded.source_url,
                    license=excluded.license, tags_json=excluded.tags_json,
                    reference_count=MAX(reference_count, excluded.reference_count),
                    updated_at=excluded.updated_at
                """, arguments: [
                    asset.id.uuidString, asset.contentHash, asset.kind.rawValue,
                    asset.displayName, asset.mimeType, asset.localRelativePath,
                    asset.cloudRecordName, asset.byteCount,
                    asset.sourceURL?.absoluteString, asset.license, tags,
                    asset.referenceCount, asset.createdAt, asset.updatedAt
                ])
        }
    }

    public func asset(id: UUID) async throws -> CreativeAssetRecord? {
        try await database.reader { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM creative_assets WHERE id = ?", arguments: [id.uuidString]) else { return nil }
            return Self.asset(from: row)
        }
    }

    public func asset(contentHash: String) async throws -> CreativeAssetRecord? {
        try await database.reader { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT * FROM creative_assets WHERE content_hash = ?",
                arguments: [contentHash]
            ) else { return nil }
            return Self.asset(from: row)
        }
    }

    public func setCloudRecordName(assetID: UUID, recordName: String) async throws {
        try await database.writer { db in
            try db.execute(
                sql: "UPDATE creative_assets SET cloud_record_name = ?, updated_at = ? WHERE id = ?",
                arguments: [recordName, Date(), assetID.uuidString]
            )
        }
    }

    public func allAssets() async throws -> [CreativeAssetRecord] {
        try await database.reader { db in
            try Row.fetchAll(
                db, sql: "SELECT * FROM creative_assets ORDER BY updated_at DESC"
            ).compactMap(Self.asset(from:))
        }
    }

    /// Finds catalog rows that no canvas node references and no unfinished
    /// media job owns. This is audit-only; callers must never delete the
    /// returned records without explicit user confirmation.
    public func orphanedAssets() async throws -> [CreativeAssetRecord] {
        try await database.reader { db in
            try Row.fetchAll(db, sql: """
                SELECT a.* FROM creative_assets a
                WHERE a.reference_count = 0
                  AND NOT EXISTS (
                    SELECT 1 FROM media_generation_jobs j
                    WHERE j.local_asset_id = a.id
                      AND j.state NOT IN ('ready','failed','cancelled','expired')
                  )
                ORDER BY a.updated_at DESC
                """).compactMap(Self.asset(from:))
        }
    }

    public func updateMetadata(
        assetID: UUID, displayName: String, tags: [String],
        sourceURL: URL?, license: String?
    ) async throws {
        let tagsData = try JSONEncoder().encode(tags)
        try await database.writer { db in
            try db.execute(sql: """
                UPDATE creative_assets SET display_name = ?, tags_json = ?,
                    source_url = ?, license = ?, updated_at = ? WHERE id = ?
                """, arguments: [
                    displayName, tagsData, sourceURL?.absoluteString,
                    license, Date(), assetID.uuidString
                ])
        }
    }

    public func adjustReference(assetID: UUID, by delta: Int) async throws {
        try await database.writer { db in
            try db.execute(sql: """
                UPDATE creative_assets SET reference_count = MAX(0, reference_count + ?),
                    updated_at = ? WHERE id = ?
                """, arguments: [delta, Date(), assetID.uuidString])
        }
    }

    /// Removes an unreferenced local asset and either deletes its DB row or
    /// queues its CloudKit record for confirmed permanent release.
    public func requestPermanentDeletion(assetID: UUID) async throws -> String? {
        guard let asset = try await asset(id: assetID) else { return nil }
        guard asset.referenceCount == 0 else {
            throw FloeError.validationFailed("这个素材仍被 \(asset.referenceCount) 个画布节点引用。请先移除引用。")
        }
        let hasUnfinishedJob = try await database.reader { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS(
                    SELECT 1 FROM media_generation_jobs
                    WHERE local_asset_id = ?
                      AND state NOT IN ('ready','failed','cancelled','expired')
                )
                """, arguments: [assetID.uuidString]) ?? false
        }
        guard !hasUnfinishedJob else {
            throw FloeError.validationFailed("这个素材仍属于未完成的媒体任务，任务结束前不会释放。")
        }
        if asset.cloudRecordName != nil {
            try await enqueueCloudRelease(CloudAssetRelease(
                assetID: asset.id, contentHash: asset.contentHash,
                estimatedBytes: asset.byteCount, deleteLocalAfterRelease: true
            ))
        } else {
            try await database.writer { db in
                try db.execute(
                    sql: "DELETE FROM creative_assets WHERE id = ? AND reference_count = 0",
                    arguments: [assetID.uuidString]
                )
            }
        }
        return asset.localRelativePath
    }

    /// Removes only the private CloudKit object. The local file and metadata
    /// stay available, and a later sync can upload it again only after an
    /// explicit user action creates a new operation.
    public func requestCloudCopyDeletion(assetID: UUID) async throws {
        guard let asset = try await asset(id: assetID), asset.cloudRecordName != nil else { return }
        try await enqueueCloudRelease(CloudAssetRelease(
            assetID: asset.id, contentHash: asset.contentHash,
            estimatedBytes: asset.byteCount, deleteLocalAfterRelease: false
        ))
    }

    public func enqueueCloudRelease(_ release: CloudAssetRelease) async throws {
        try await database.writer { db in
            try db.execute(sql: """
                INSERT INTO cloud_asset_releases (
                    id, asset_id, content_hash, estimated_bytes,
                    delete_local_after_release, state,
                    retry_count, last_error, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET state=excluded.state,
                    retry_count=excluded.retry_count, last_error=excluded.last_error,
                    updated_at=excluded.updated_at
                """, arguments: [
                    release.id.uuidString, release.assetID.uuidString,
                    release.contentHash, release.estimatedBytes,
                    release.deleteLocalAfterRelease,
                    release.state.rawValue, release.retryCount, release.lastError,
                    release.createdAt, release.updatedAt
                ])
        }
    }

    public func pendingReleases() async throws -> [CloudAssetRelease] {
        try await database.reader { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM cloud_asset_releases
                WHERE state IN ('pending','failed') ORDER BY created_at
                """).compactMap(Self.release(from:))
        }
    }

    public func pendingReleaseRecords() async throws -> [PendingCloudAssetRelease] {
        try await database.reader { db in
            try Row.fetchAll(db, sql: """
                SELECT r.*, a.cloud_record_name
                FROM cloud_asset_releases r
                JOIN creative_assets a ON a.id = r.asset_id
                WHERE r.state IN ('pending','failed')
                  AND a.cloud_record_name IS NOT NULL
                ORDER BY r.created_at
                """).compactMap { row in
                    guard let release = Self.release(from: row),
                          let recordName: String = row["cloud_record_name"] else { return nil }
                    return PendingCloudAssetRelease(release: release, cloudRecordName: recordName)
                }
        }
    }

    public func confirmRelease(
        id: UUID, assetID: UUID, deleteLocalAfterRelease: Bool
    ) async throws {
        try await database.writer { db in
            try db.execute(sql: "DELETE FROM cloud_asset_releases WHERE id = ?", arguments: [id.uuidString])
            if deleteLocalAfterRelease {
                try db.execute(sql: "DELETE FROM creative_assets WHERE id = ? AND reference_count = 0", arguments: [assetID.uuidString])
            } else {
                try db.execute(
                    sql: "UPDATE creative_assets SET cloud_record_name = NULL, updated_at = ? WHERE id = ?",
                    arguments: [Date(), assetID.uuidString]
                )
            }
        }
    }

    public func markRelease(
        id: UUID, state: CloudAssetReleaseState, error: String? = nil
    ) async throws {
        try await database.writer { db in
            try db.execute(sql: """
                UPDATE cloud_asset_releases SET state = ?, last_error = ?,
                    retry_count = retry_count + CASE WHEN ? = 'failed' THEN 1 ELSE 0 END,
                    updated_at = ? WHERE id = ?
                """, arguments: [state.rawValue, error, state.rawValue, Date(), id.uuidString])
        }
    }

    public func storageSummary() async throws -> (local: Int64, cloud: Int64, pendingDownload: Int64, pendingRelease: Int64, releaseCount: Int) {
        try await database.reader { db in
            let local = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(byte_count),0) FROM creative_assets WHERE local_relative_path IS NOT NULL") ?? 0
            let cloud = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(byte_count),0) FROM creative_assets WHERE cloud_record_name IS NOT NULL") ?? 0
            let pendingDownload = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(byte_count),0) FROM creative_assets WHERE cloud_record_name IS NOT NULL AND local_relative_path IS NULL") ?? 0
            let pendingRelease = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(estimated_bytes),0) FROM cloud_asset_releases WHERE state IN ('pending','releasing','failed')") ?? 0
            let releaseCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cloud_asset_releases WHERE state IN ('pending','releasing','failed')") ?? 0
            return (local, cloud, pendingDownload, pendingRelease, releaseCount)
        }
    }

    private static func release(from row: Row) -> CloudAssetRelease? {
        guard let id = UUID(uuidString: row["id"]),
              let assetID = UUID(uuidString: row["asset_id"]),
              let state = CloudAssetReleaseState(rawValue: row["state"]) else { return nil }
        return CloudAssetRelease(
            id: id, assetID: assetID, contentHash: row["content_hash"],
            estimatedBytes: row["estimated_bytes"],
            deleteLocalAfterRelease: row["delete_local_after_release"], state: state,
            retryCount: row["retry_count"], lastError: row["last_error"],
            createdAt: row["created_at"], updatedAt: row["updated_at"]
        )
    }

    private static func asset(from row: Row) -> CreativeAssetRecord? {
        guard let id = UUID(uuidString: row["id"]),
              let kind = MediaKind(rawValue: row["kind"]),
              let tagsData: Data = row["tags_json"],
              let tags = try? JSONDecoder().decode([String].self, from: tagsData)
        else { return nil }
        return CreativeAssetRecord(
            id: id, contentHash: row["content_hash"], kind: kind,
            displayName: row["display_name"], mimeType: row["mime_type"],
            localRelativePath: row["local_relative_path"],
            cloudRecordName: row["cloud_record_name"],
            byteCount: row["byte_count"],
            sourceURL: (row["source_url"] as String?).flatMap(URL.init(string:)),
            license: row["license"], tags: tags,
            referenceCount: row["reference_count"],
            createdAt: row["created_at"], updatedAt: row["updated_at"]
        )
    }
}

public actor CanvasSyncPreferenceStore {
    private let database: DatabaseManager
    public init(database: DatabaseManager) { self.database = database }

    public func setEnabled(_ enabled: Bool, canvasID: UUID) async throws {
        try await database.writer { db in
            try db.execute(sql: """
                INSERT INTO canvas_sync_preferences (canvas_id, is_enabled, revision, updated_at)
                VALUES (?, ?, 1, ?)
                ON CONFLICT(canvas_id) DO UPDATE SET
                    is_enabled=excluded.is_enabled, revision=revision+1, updated_at=excluded.updated_at
                """, arguments: [canvasID.uuidString, enabled, Date()])
        }
    }

    public func isEnabled(canvasID: UUID) async throws -> Bool {
        try await database.reader { db in
            try Bool.fetchOne(db, sql: "SELECT is_enabled FROM canvas_sync_preferences WHERE canvas_id = ?", arguments: [canvasID.uuidString]) ?? true
        }
    }
}
