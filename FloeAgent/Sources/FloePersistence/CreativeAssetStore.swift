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

public enum GeneratedAssetReservationState: String, Sendable, Codable, Hashable {
    case preparing
    case reserved
    case committed
    case abandoned
}

public struct GeneratedAssetReservationSlotDraft: Sendable, Hashable {
    public var index: Int
    public var resultNodeID: UUID
    public var candidateAssetID: UUID
    public var contentHash: String
    public var candidateRelativePath: String

    public init(
        index: Int,
        resultNodeID: UUID,
        candidateAssetID: UUID,
        contentHash: String,
        candidateRelativePath: String
    ) {
        self.index = index
        self.resultNodeID = resultNodeID
        self.candidateAssetID = candidateAssetID
        self.contentHash = contentHash
        self.candidateRelativePath = candidateRelativePath
    }
}

public struct GeneratedAssetReservationSlotRecord: Sendable, Hashable {
    public var index: Int
    public var resultNodeID: UUID
    public var candidateAssetID: UUID
    public var contentHash: String
    public var candidateRelativePath: String
    public var canonicalAssetID: UUID?
    public var wasInserted: Bool
    public var state: GeneratedAssetReservationState

    public init(
        index: Int,
        resultNodeID: UUID,
        candidateAssetID: UUID,
        contentHash: String,
        candidateRelativePath: String,
        canonicalAssetID: UUID?,
        wasInserted: Bool,
        state: GeneratedAssetReservationState
    ) {
        self.index = index
        self.resultNodeID = resultNodeID
        self.candidateAssetID = candidateAssetID
        self.contentHash = contentHash
        self.candidateRelativePath = candidateRelativePath
        self.canonicalAssetID = canonicalAssetID
        self.wasInserted = wasInserted
        self.state = state
    }
}

public struct GeneratedAssetReservationBatchRecord: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var canvasID: UUID
    public var documentID: UUID
    public var configurationNodeID: UUID
    public var generationAttemptID: String
    public var expectedCount: Int
    public var state: GeneratedAssetReservationState
    public var slots: [GeneratedAssetReservationSlotRecord]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID,
        canvasID: UUID,
        documentID: UUID,
        configurationNodeID: UUID,
        generationAttemptID: String,
        expectedCount: Int,
        state: GeneratedAssetReservationState,
        slots: [GeneratedAssetReservationSlotRecord],
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.canvasID = canvasID
        self.documentID = documentID
        self.configurationNodeID = configurationNodeID
        self.generationAttemptID = generationAttemptID
        self.expectedCount = expectedCount
        self.state = state
        self.slots = slots
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct GeneratedAssetReservationAbandonment: Sendable, Hashable {
    public var slots: [GeneratedAssetReservationSlotRecord]
    /// Local files whose catalog rows were deleted by the same transaction
    /// that released this batch's provisional references.
    public var deletedLocalRelativePaths: [String]

    public init(
        slots: [GeneratedAssetReservationSlotRecord] = [],
        deletedLocalRelativePaths: [String] = []
    ) {
        self.slots = slots
        self.deletedLocalRelativePaths = deletedLocalRelativePaths
    }
}

public actor CreativeAssetStore {
    private let database: DatabaseManager
    public init(database: DatabaseManager) { self.database = database }

    /// Persists the complete owner/slot set before the first generated file is
    /// written. A later process can therefore locate both unbound candidate
    /// files and reservations whose canonical upsert already committed.
    public func beginGeneratedAssetReservationBatch(
        id: UUID,
        canvasID: UUID,
        documentID: UUID,
        configurationNodeID: UUID,
        generationAttemptID: String,
        slots: [GeneratedAssetReservationSlotDraft],
        now: Date = Date()
    ) async throws {
        guard (1...4).contains(slots.count),
              !generationAttemptID.isEmpty,
              Set(slots.map(\.index)).count == slots.count,
              Set(slots.map(\.resultNodeID)).count == slots.count,
              slots.allSatisfy({ $0.index >= 0 && !$0.contentHash.isEmpty
                  && !$0.candidateRelativePath.isEmpty }) else {
            throw FloeError.validationFailed(
                "Generated asset reservation owner or slots are invalid"
            )
        }
        try await database.writer { db in
            try db.execute(sql: """
                INSERT INTO generated_asset_reservation_batches (
                    id, canvas_id, document_id, configuration_node_id,
                    generation_attempt_id, expected_count, state,
                    created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, 'preparing', ?, ?)
                """, arguments: [
                    id.uuidString, canvasID.uuidString, documentID.uuidString,
                    configurationNodeID.uuidString, generationAttemptID,
                    slots.count, now, now
                ])
            for slot in slots.sorted(by: { $0.index < $1.index }) {
                try db.execute(sql: """
                    INSERT INTO generated_asset_reservations (
                        batch_id, slot_index, result_node_id,
                        candidate_asset_id, content_hash,
                        candidate_relative_path, canonical_asset_id,
                        was_inserted, state, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, NULL, 0, 'preparing', ?, ?)
                    """, arguments: [
                        id.uuidString, slot.index, slot.resultNodeID.uuidString,
                        slot.candidateAssetID.uuidString, slot.contentHash,
                        slot.candidateRelativePath, now, now
                    ])
            }
        }
    }

    /// Resolves one generated slot to its canonical hash row and establishes
    /// exactly one provisional reference in the same transaction. Repeating
    /// the same batch/slot returns the prior canonical row without incrementing
    /// `reference_count` again.
    public func reserveGeneratedAsset(
        batchID: UUID,
        slotIndex: Int,
        candidate: CreativeAssetRecord,
        now: Date = Date()
    ) async throws -> CreativeAssetRecord {
        guard candidate.referenceCount == 0 else {
            throw FloeError.validationFailed(
                "Generated reservation candidates must start unreferenced"
            )
        }
        let tags = try JSONEncoder().encode(candidate.tags)
        return try await database.writer { db in
            guard let slot = try Row.fetchOne(db, sql: """
                SELECT * FROM generated_asset_reservations
                WHERE batch_id = ? AND slot_index = ?
                """, arguments: [batchID.uuidString, slotIndex]),
                  let state = GeneratedAssetReservationState(
                    rawValue: slot["state"]
                  ),
                  let candidateAssetID = UUID(
                    uuidString: slot["candidate_asset_id"]
                  ) else {
                throw FloeError.storageCorrupted(
                    "Generated asset reservation slot is missing"
                )
            }
            guard slot["content_hash"] == candidate.contentHash,
                  candidateAssetID == candidate.id,
                  slot["candidate_relative_path"] == candidate.localRelativePath else {
                throw FloeError.validationFailed(
                    "Generated asset reservation candidate does not match its slot"
                )
            }
            if state == .reserved || state == .committed {
                guard let canonicalIDText: String = slot["canonical_asset_id"],
                      let row = try Row.fetchOne(
                        db,
                        sql: "SELECT * FROM creative_assets WHERE id = ?",
                        arguments: [canonicalIDText]
                      ), let canonical = Self.asset(from: row) else {
                    throw FloeError.storageCorrupted(
                        "Generated reservation lost its canonical asset"
                    )
                }
                return canonical
            }
            guard state == .preparing else {
                throw FloeError.validationFailed(
                    "Abandoned generated reservation cannot be reused"
                )
            }
            let batchState = try String.fetchOne(db, sql: """
                SELECT state FROM generated_asset_reservation_batches WHERE id = ?
                """, arguments: [batchID.uuidString])
            guard batchState == GeneratedAssetReservationState.preparing.rawValue
                    || batchState == GeneratedAssetReservationState.reserved.rawValue else {
                throw FloeError.validationFailed(
                    "Generated reservation batch is no longer pending"
                )
            }
            let existingID = try String.fetchOne(
                db,
                sql: "SELECT id FROM creative_assets WHERE content_hash = ?",
                arguments: [candidate.contentHash]
            )
            try db.execute(sql: """
                INSERT INTO creative_assets (
                    id, content_hash, kind, display_name, mime_type,
                    local_relative_path, cloud_record_name, byte_count,
                    source_url, license, tags_json, reference_count,
                    created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
                ON CONFLICT(content_hash) DO UPDATE SET
                    local_relative_path=creative_assets.local_relative_path,
                    cloud_record_name=COALESCE(
                        creative_assets.cloud_record_name,
                        excluded.cloud_record_name
                    ),
                    mime_type=COALESCE(creative_assets.mime_type, excluded.mime_type),
                    byte_count=MAX(creative_assets.byte_count, excluded.byte_count),
                    reference_count=creative_assets.reference_count + 1,
                    updated_at=MAX(creative_assets.updated_at, excluded.updated_at)
                """, arguments: [
                    candidate.id.uuidString, candidate.contentHash,
                    candidate.kind.rawValue, candidate.displayName,
                    candidate.mimeType, candidate.localRelativePath,
                    candidate.cloudRecordName, candidate.byteCount,
                    candidate.sourceURL?.absoluteString, candidate.license,
                    tags, candidate.createdAt, candidate.updatedAt
                ])
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM creative_assets WHERE content_hash = ?",
                arguments: [candidate.contentHash]
            ), let canonical = Self.asset(from: row) else {
                throw FloeError.storageCorrupted(
                    "Creative asset canonical row was not readable after reservation"
                )
            }
            try db.execute(sql: """
                UPDATE generated_asset_reservations
                SET canonical_asset_id = ?, was_inserted = ?,
                    state = 'reserved', updated_at = ?
                WHERE batch_id = ? AND slot_index = ? AND state = 'preparing'
                """, arguments: [
                    canonical.id.uuidString, existingID == nil, now,
                    batchID.uuidString, slotIndex
                ])
            guard db.changesCount == 1 else {
                throw FloeError.storageCorrupted(
                    "Generated asset reservation slot could not be bound"
                )
            }
            let remaining = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM generated_asset_reservations
                WHERE batch_id = ? AND state != 'reserved'
                """, arguments: [batchID.uuidString]) ?? 0
            try db.execute(sql: """
                UPDATE generated_asset_reservation_batches
                SET state = ?, updated_at = ? WHERE id = ?
                """, arguments: [
                    remaining == 0
                        ? GeneratedAssetReservationState.reserved.rawValue
                        : GeneratedAssetReservationState.preparing.rawValue,
                    now, batchID.uuidString
                ])
            return canonical
        }
    }

    /// Converts a fully-bound provisional batch into ordinary live references.
    /// The count itself is unchanged; only the durable ownership state moves.
    public func finalizeGeneratedAssetReservationBatch(
        id: UUID,
        now: Date = Date()
    ) async throws {
        try await database.writer { db in
            guard let stateText = try String.fetchOne(
                db,
                sql: "SELECT state FROM generated_asset_reservation_batches WHERE id = ?",
                arguments: [id.uuidString]
            ), let state = GeneratedAssetReservationState(rawValue: stateText) else {
                throw FloeError.storageCorrupted(
                    "Generated asset reservation batch is missing"
                )
            }
            if state == .committed { return }
            guard state != .abandoned else {
                throw FloeError.validationFailed(
                    "Abandoned generated reservation cannot be committed"
                )
            }
            let expected = try Int.fetchOne(db, sql: """
                SELECT expected_count FROM generated_asset_reservation_batches WHERE id = ?
                """, arguments: [id.uuidString]) ?? 0
            let reserved = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM generated_asset_reservations
                WHERE batch_id = ? AND state = 'reserved'
                  AND canonical_asset_id IS NOT NULL
                """, arguments: [id.uuidString]) ?? 0
            guard expected > 0, reserved == expected else {
                throw FloeError.storageCorrupted(
                    "Generated asset reservation batch is only partially bound"
                )
            }
            try db.execute(sql: """
                UPDATE generated_asset_reservations
                SET state = 'committed', updated_at = ?
                WHERE batch_id = ? AND state = 'reserved'
                """, arguments: [now, id.uuidString])
            try db.execute(sql: """
                UPDATE generated_asset_reservation_batches
                SET state = 'committed', updated_at = ? WHERE id = ?
                """, arguments: [now, id.uuidString])
        }
    }

    /// Releases every still-provisional slot in one transaction. Terminal
    /// batches are no-ops, making retries after cancellation or relaunch safe.
    @discardableResult
    public func abandonGeneratedAssetReservationBatch(
        id: UUID,
        now: Date = Date()
    ) async throws -> GeneratedAssetReservationAbandonment {
        try await database.writer { db in
            guard let stateText = try String.fetchOne(
                db,
                sql: "SELECT state FROM generated_asset_reservation_batches WHERE id = ?",
                arguments: [id.uuidString]
            ), let state = GeneratedAssetReservationState(rawValue: stateText) else {
                throw FloeError.storageCorrupted(
                    "Generated asset reservation batch is missing"
                )
            }
            if state == .abandoned || state == .committed {
                return GeneratedAssetReservationAbandonment()
            }
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM generated_asset_reservations
                WHERE batch_id = ? ORDER BY slot_index
                """, arguments: [id.uuidString])
            let slots = try rows.map { row in
                guard let slot = Self.generatedReservationSlot(from: row) else {
                    throw FloeError.storageCorrupted(
                        "Generated asset reservation slot is unreadable"
                    )
                }
                return slot
            }
            let reservedIDs = slots.filter { $0.state == .reserved }
                .compactMap(\.canonicalAssetID)
            let counts = Dictionary(grouping: reservedIDs, by: { $0 })
                .mapValues(\.count)
            for assetID in counts.keys.sorted(by: {
                $0.uuidString < $1.uuidString
            }) {
                guard let count = counts[assetID] else { continue }
                try db.execute(sql: """
                    UPDATE creative_assets
                    SET reference_count = reference_count - ?, updated_at = ?
                    WHERE id = ? AND reference_count >= ?
                    """, arguments: [
                        count, now, assetID.uuidString, count
                    ])
                guard db.changesCount == 1 else {
                    throw FloeError.storageCorrupted(
                        "Generated asset reservation could not be released"
                    )
                }
            }
            try db.execute(sql: """
                UPDATE generated_asset_reservations
                SET state = 'abandoned', updated_at = ?
                WHERE batch_id = ? AND state IN ('preparing','reserved')
                """, arguments: [now, id.uuidString])
            try db.execute(sql: """
                UPDATE generated_asset_reservation_batches
                SET state = 'abandoned', updated_at = ? WHERE id = ?
                """, arguments: [now, id.uuidString])

            // Cleanup eligibility follows the canonical asset's complete
            // reservation history, not only the batch being abandoned. This
            // matters when two batches share identical bytes and the creator
            // abandons first: the later batch can delete the canonical row
            // after releasing the final reference, while a pre-existing or
            // ever-committed asset is never auto-deleted.
            var deletedLocalRelativePaths: [String] = []
            let canonicalIDs = Set(slots.compactMap(\.canonicalAssetID))
                .sorted { $0.uuidString < $1.uuidString }
            for assetID in canonicalIDs {
                guard let row = try Row.fetchOne(
                    db,
                    sql: "SELECT * FROM creative_assets WHERE id = ?",
                    arguments: [assetID.uuidString]
                ), let asset = Self.asset(from: row),
                      asset.referenceCount == 0 else { continue }
                let reservationInserted = try Bool.fetchOne(db, sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM generated_asset_reservations
                        WHERE canonical_asset_id = ? AND was_inserted = 1
                    )
                    """, arguments: [assetID.uuidString]) ?? false
                let wasEverCommitted = try Bool.fetchOne(db, sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM generated_asset_reservations
                        WHERE canonical_asset_id = ? AND state = 'committed'
                    )
                    """, arguments: [assetID.uuidString]) ?? false
                let hasUnfinishedJob = try Bool.fetchOne(db, sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM media_generation_jobs
                        WHERE local_asset_id = ?
                          AND state NOT IN ('ready','failed','cancelled','expired')
                    )
                    """, arguments: [assetID.uuidString]) ?? false
                guard reservationInserted, !wasEverCommitted,
                      !hasUnfinishedJob else { continue }

                if asset.cloudRecordName != nil {
                    let release = CloudAssetRelease(
                        assetID: asset.id,
                        contentHash: asset.contentHash,
                        estimatedBytes: asset.byteCount,
                        deleteLocalAfterRelease: true
                    )
                    try db.execute(sql: """
                        INSERT INTO cloud_asset_releases (
                            id, asset_id, content_hash, estimated_bytes,
                            delete_local_after_release, state,
                            retry_count, last_error, created_at, updated_at
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, arguments: [
                            release.id.uuidString, release.assetID.uuidString,
                            release.contentHash, release.estimatedBytes,
                            release.deleteLocalAfterRelease,
                            release.state.rawValue, release.retryCount,
                            release.lastError, release.createdAt,
                            release.updatedAt
                        ])
                    continue
                }

                try db.execute(sql: """
                    DELETE FROM creative_assets
                    WHERE id = ? AND reference_count = 0
                      AND EXISTS (
                        SELECT 1 FROM generated_asset_reservations
                        WHERE canonical_asset_id = ? AND was_inserted = 1
                      )
                      AND NOT EXISTS (
                        SELECT 1 FROM generated_asset_reservations
                        WHERE canonical_asset_id = ? AND state = 'committed'
                      )
                      AND NOT EXISTS (
                        SELECT 1 FROM media_generation_jobs
                        WHERE local_asset_id = ?
                          AND state NOT IN ('ready','failed','cancelled','expired')
                      )
                    """, arguments: [
                        assetID.uuidString, assetID.uuidString,
                        assetID.uuidString, assetID.uuidString
                    ])
                if db.changesCount == 1, let path = asset.localRelativePath {
                    deletedLocalRelativePaths.append(path)
                }
            }
            return GeneratedAssetReservationAbandonment(
                slots: slots,
                deletedLocalRelativePaths: deletedLocalRelativePaths
            )
        }
    }

    public func generatedAssetReservationBatch(
        id: UUID
    ) async throws -> GeneratedAssetReservationBatchRecord? {
        try await database.reader { db in
            try Self.generatedReservationBatch(id: id, database: db)
        }
    }

    public func pendingGeneratedAssetReservationBatches(
    ) async throws -> [GeneratedAssetReservationBatchRecord] {
        try await database.reader { db in
            let ids = try String.fetchAll(db, sql: """
                SELECT id FROM generated_asset_reservation_batches
                WHERE state IN ('preparing','reserved')
                ORDER BY created_at, id
                """)
            return try ids.compactMap { value in
                guard let id = UUID(uuidString: value) else {
                    throw FloeError.storageCorrupted(
                        "Generated asset reservation batch ID is invalid"
                    )
                }
                return try Self.generatedReservationBatch(id: id, database: db)
            }
        }
    }

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

    /// Inserts generated content or resolves the existing content-hash row in
    /// one serialized database write. Callers must use the returned record:
    /// its ID is the canonical foreign key when concurrent requests produce
    /// identical bytes. Generated outputs may reserve references in this same
    /// transaction, closing the deletion window before their canvas patch is
    /// durably committed.
    public func saveResolvingCanonical(
        _ candidate: CreativeAssetRecord,
        reservingReferences reservationCount: Int = 0
    ) async throws -> CreativeAssetRecord {
        guard reservationCount >= 0 else {
            throw FloeError.validationFailed(
                "Creative asset reservation count cannot be negative"
            )
        }
        let tags = try JSONEncoder().encode(candidate.tags)
        return try await database.writer { db in
            // A losing candidate UUID must never become the durable path of
            // an existing canonical row. Missing copies are repaired at the
            // canonical ID path by the media service before publication.
            try db.execute(sql: """
                INSERT INTO creative_assets (
                    id, content_hash, kind, display_name, mime_type,
                    local_relative_path, cloud_record_name, byte_count,
                    source_url, license, tags_json, reference_count,
                    created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(content_hash) DO UPDATE SET
                    local_relative_path=creative_assets.local_relative_path,
                    cloud_record_name=COALESCE(
                        creative_assets.cloud_record_name,
                        excluded.cloud_record_name
                    ),
                    mime_type=COALESCE(creative_assets.mime_type, excluded.mime_type),
                    byte_count=MAX(creative_assets.byte_count, excluded.byte_count),
                    reference_count=creative_assets.reference_count + ?,
                    updated_at=MAX(creative_assets.updated_at, excluded.updated_at)
                """, arguments: [
                    candidate.id.uuidString, candidate.contentHash,
                    candidate.kind.rawValue, candidate.displayName,
                    candidate.mimeType, candidate.localRelativePath,
                    candidate.cloudRecordName, candidate.byteCount,
                    candidate.sourceURL?.absoluteString, candidate.license, tags,
                    candidate.referenceCount + reservationCount,
                    candidate.createdAt, candidate.updatedAt,
                    reservationCount
                ])
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM creative_assets WHERE content_hash = ?",
                arguments: [candidate.contentHash]
            ), let canonical = Self.asset(from: row) else {
                throw FloeError.storageCorrupted(
                    "Creative asset canonical row was not readable after save"
                )
            }
            return canonical
        }
    }

    /// Releases exactly one provisional reference for every occurrence in
    /// `assetIDs`. Duplicate IDs are intentionally counted: a four-output
    /// batch containing identical bytes owns four independent reservations.
    public func releaseReferenceReservations(assetIDs: [UUID]) async throws {
        guard !assetIDs.isEmpty else { return }
        let counts = Dictionary(grouping: assetIDs, by: { $0 }).mapValues(\.count)
        try await database.writer { db in
            for assetID in counts.keys.sorted(by: {
                $0.uuidString < $1.uuidString
            }) {
                guard let count = counts[assetID] else { continue }
                try db.execute(sql: """
                    UPDATE creative_assets
                    SET reference_count = reference_count - ?, updated_at = ?
                    WHERE id = ? AND reference_count >= ?
                    """, arguments: [
                        count, Date(), assetID.uuidString, count
                    ])
                guard db.changesCount == 1 else {
                    throw FloeError.storageCorrupted(
                        "Creative asset reservation could not be released"
                    )
                }
            }
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
            guard db.changesCount == 1 else {
                throw FloeError.storageCorrupted(
                    "Creative asset reference target does not exist"
                )
            }
        }
    }

    /// Atomically proves an asset is unreferenced and either removes its local
    /// database row or queues its CloudKit record for confirmed release. A
    /// local path is returned only when that row was actually deleted; cloud
    /// releases retain the local copy until their asynchronous confirmation.
    public func requestPermanentDeletion(assetID: UUID) async throws -> String? {
        try await database.writer { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM creative_assets WHERE id = ?",
                arguments: [assetID.uuidString]
            ), let asset = Self.asset(from: row) else { return nil }
            guard asset.referenceCount == 0 else {
                throw FloeError.validationFailed(
                    "这个素材仍被 \(asset.referenceCount) 个画布节点引用。请先移除引用。"
                )
            }
            let hasUnfinishedJob = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(
                    SELECT 1 FROM media_generation_jobs
                    WHERE local_asset_id = ?
                      AND state NOT IN ('ready','failed','cancelled','expired')
                )
                """, arguments: [assetID.uuidString]) ?? false
            guard !hasUnfinishedJob else {
                throw FloeError.validationFailed(
                    "这个素材仍属于未完成的媒体任务，任务结束前不会释放。"
                )
            }

            if asset.cloudRecordName != nil {
                let release = CloudAssetRelease(
                    assetID: asset.id,
                    contentHash: asset.contentHash,
                    estimatedBytes: asset.byteCount,
                    deleteLocalAfterRelease: true
                )
                try db.execute(sql: """
                    INSERT INTO cloud_asset_releases (
                        id, asset_id, content_hash, estimated_bytes,
                        delete_local_after_release, state,
                        retry_count, last_error, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET state=excluded.state,
                        retry_count=excluded.retry_count,
                        last_error=excluded.last_error,
                        updated_at=excluded.updated_at
                    """, arguments: [
                        release.id.uuidString, release.assetID.uuidString,
                        release.contentHash, release.estimatedBytes,
                        release.deleteLocalAfterRelease,
                        release.state.rawValue, release.retryCount,
                        release.lastError, release.createdAt, release.updatedAt
                    ])
                return nil
            }

            try db.execute(sql: """
                DELETE FROM creative_assets
                WHERE id = ? AND reference_count = 0
                  AND NOT EXISTS (
                    SELECT 1 FROM media_generation_jobs
                    WHERE local_asset_id = ?
                      AND state NOT IN ('ready','failed','cancelled','expired')
                  )
                """, arguments: [assetID.uuidString, assetID.uuidString])
            guard db.changesCount == 1 else {
                throw FloeError.validationFailed(
                    "素材引用状态已变化，本次没有删除本地文件。"
                )
            }
            return asset.localRelativePath
        }
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

    /// Completes a release only after CloudKit has confirmed the remote record
    /// is absent. Local deletion runs inside the same writer transaction after
    /// the guarded row deletion; a filesystem error rolls the row and release
    /// queue back so the cleanup remains retryable. The returned path records
    /// which local copy was successfully removed.
    public func confirmRelease(
        id: UUID,
        assetID: UUID,
        deleteLocalAfterRelease: Bool,
        deleteLocalFile: @escaping @Sendable (String) throws -> Void
    ) async throws -> String? {
        try await database.writer { db in
            guard let releaseRow = try Row.fetchOne(
                db,
                sql: """
                    SELECT asset_id, delete_local_after_release
                    FROM cloud_asset_releases WHERE id = ?
                    """,
                arguments: [id.uuidString]
            ) else { return nil }
            let queuedAssetID: String = releaseRow["asset_id"]
            guard queuedAssetID == assetID.uuidString else {
                throw FloeError.storageCorrupted(
                    "Cloud asset release points at a different asset"
                )
            }
            let queuedDeleteLocal: Bool = releaseRow["delete_local_after_release"]
            guard queuedDeleteLocal == deleteLocalAfterRelease else {
                throw FloeError.storageCorrupted(
                    "Cloud asset release mode changed before confirmation"
                )
            }

            guard let assetRow = try Row.fetchOne(
                db,
                sql: "SELECT * FROM creative_assets WHERE id = ?",
                arguments: [assetID.uuidString]
            ), let asset = Self.asset(from: assetRow) else {
                try db.execute(
                    sql: "DELETE FROM cloud_asset_releases WHERE id = ?",
                    arguments: [id.uuidString]
                )
                return nil
            }

            var authorizedLocalPath: String?
            if deleteLocalAfterRelease {
                try db.execute(sql: """
                    DELETE FROM creative_assets
                    WHERE id = ? AND reference_count = 0
                      AND NOT EXISTS (
                        SELECT 1 FROM media_generation_jobs
                        WHERE local_asset_id = ?
                          AND state NOT IN ('ready','failed','cancelled','expired')
                      )
                    """, arguments: [assetID.uuidString, assetID.uuidString])
                if db.changesCount == 1 {
                    authorizedLocalPath = asset.localRelativePath
                    if let authorizedLocalPath {
                        // This runs before the GRDB writer transaction commits.
                        // A filesystem failure throws and rolls the asset row
                        // plus its release queue entry back for a later retry.
                        try deleteLocalFile(authorizedLocalPath)
                    }
                } else {
                    // The remote record is already gone, but a concurrent
                    // reference or active job won the race. Keep the local
                    // asset and make its cloud state truthful.
                    try db.execute(
                        sql: """
                            UPDATE creative_assets
                            SET cloud_record_name = NULL, updated_at = ?
                            WHERE id = ?
                            """,
                        arguments: [Date(), assetID.uuidString]
                    )
                }
            } else {
                try db.execute(
                    sql: "UPDATE creative_assets SET cloud_record_name = NULL, updated_at = ? WHERE id = ?",
                    arguments: [Date(), assetID.uuidString]
                )
            }
            try db.execute(
                sql: "DELETE FROM cloud_asset_releases WHERE id = ?",
                arguments: [id.uuidString]
            )
            return authorizedLocalPath
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

    private static func generatedReservationBatch(
        id: UUID,
        database db: Database
    ) throws -> GeneratedAssetReservationBatchRecord? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM generated_asset_reservation_batches WHERE id = ?",
            arguments: [id.uuidString]
        ) else { return nil }
        guard let canvasID = UUID(uuidString: row["canvas_id"]),
              let documentID = UUID(uuidString: row["document_id"]),
              let configurationNodeID = UUID(
                uuidString: row["configuration_node_id"]
              ),
              let state = GeneratedAssetReservationState(rawValue: row["state"])
        else {
            throw FloeError.storageCorrupted(
                "Generated asset reservation owner is unreadable"
            )
        }
        let slotRows = try Row.fetchAll(db, sql: """
            SELECT * FROM generated_asset_reservations
            WHERE batch_id = ? ORDER BY slot_index
            """, arguments: [id.uuidString])
        let slots = try slotRows.map { slotRow in
            guard let slot = generatedReservationSlot(from: slotRow) else {
                throw FloeError.storageCorrupted(
                    "Generated asset reservation slot is unreadable"
                )
            }
            return slot
        }
        return GeneratedAssetReservationBatchRecord(
            id: id,
            canvasID: canvasID,
            documentID: documentID,
            configurationNodeID: configurationNodeID,
            generationAttemptID: row["generation_attempt_id"],
            expectedCount: row["expected_count"],
            state: state,
            slots: slots,
            createdAt: row["created_at"],
            updatedAt: row["updated_at"]
        )
    }

    private static func generatedReservationSlot(
        from row: Row
    ) -> GeneratedAssetReservationSlotRecord? {
        guard let resultNodeID = UUID(uuidString: row["result_node_id"]),
              let candidateAssetID = UUID(
                uuidString: row["candidate_asset_id"]
              ),
              let state = GeneratedAssetReservationState(rawValue: row["state"])
        else { return nil }
        let canonicalText: String? = row["canonical_asset_id"]
        let canonicalID = canonicalText.flatMap(UUID.init(uuidString:))
        if canonicalText != nil, canonicalID == nil { return nil }
        return GeneratedAssetReservationSlotRecord(
            index: row["slot_index"],
            resultNodeID: resultNodeID,
            candidateAssetID: candidateAssetID,
            contentHash: row["content_hash"],
            candidateRelativePath: row["candidate_relative_path"],
            canonicalAssetID: canonicalID,
            wasInserted: row["was_inserted"],
            state: state
        )
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
