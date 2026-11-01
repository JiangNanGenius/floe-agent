// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 — bounded creative inventory for the App first-material picker and
// pending-request reopen.
//
// This file adds NO new source of truth:
//  * asset metadata is read (never written) from the SAME `creative_assets`
//    table the existing `CreativeAssetStore` owns, with a bounded keyset page;
//  * pending requests are read from the SAME owner-envelope files the shared
//    `DesignOwnerWorkflow` writes, ordered by the write that advances
//    `updatedAt`, with a hard envelope-read cap.
//
// No free-form path is accepted or returned. The asset page carries metadata
// only (id/name/kind/format/size/digest/time); bytes are read by the bind path
// through `G09CreativeAssetHost.verifiedLocalBytes`, never through this file.
import Foundation
import FloeCore
import FloePersistence
import GRDB

enum G09R2DesignCreativeInventoryError: Error, Equatable {
    case invalidCursor
    case unavailable
}

/// One bounded inventory page. Exactly one of `database` / `ownerStore` is
/// set by the caller; the wrong route fails closed instead of falling back to a
/// second store.
struct G09R2DesignCreativeInventory {
    static let pageMaximum = 24
    private static let cursorBytes = 200
    private static let pendingMaxReads = 64
    private static let pendingScanCap = 1024

    let database: DatabaseManager?
    let ownerStore: G09R2DesignOwnerProjectStore?

    init(database: DatabaseManager) {
        self.database = database
        self.ownerStore = nil
    }

    init(ownerStore: G09R2DesignOwnerProjectStore) {
        self.database = nil
        self.ownerStore = ownerStore
    }

    // MARK: - Retained creative asset metadata

    func assets(
        limit rawLimit: Int,
        cursor: String?
    ) async throws -> G09R2DesignCreativeAssetPageDTO {
        guard let database = database else {
            throw G09R2DesignCreativeInventoryError.unavailable
        }
        let limit = Self.clampedLimit(rawLimit)
        let keyset = try Self.parseAssetCursor(cursor)
        return try await database.reader { db in
            var sql = """
                SELECT id, content_hash, kind, display_name,
                       local_relative_path, byte_count, updated_at
                FROM creative_assets
                WHERE local_relative_path IS NOT NULL
                """
            var arguments: [(any DatabaseValueConvertible)?] = []
            if let keyset {
                sql += " AND (updated_at, id) < (?, ?)"
                arguments.append(keyset.date)
                arguments.append(keyset.rowID)
            }
            sql += " ORDER BY updated_at DESC, id DESC LIMIT ?"
            arguments.append(limit + 1)
            let rows = try Row.fetchAll(
                db, sql: sql,
                arguments: StatementArguments(arguments))
            var assets: [G09R2DesignCreativeAssetDTO] = []
            var lastCursor: String?
            for (index, row) in rows.enumerated() {
                guard index < limit else { break }
                let rowID: String = row["id"]
                guard let assetID = UUID(uuidString: rowID) else { continue }
                let rawPath: String = row["local_relative_path"]
                let clean = G09CreativeAssetHost.canonicalAssetRelativePath(rawPath)
                let format = clean.map {
                    ($0 as NSString).pathExtension.lowercased()
                } ?? ""
                let selectable = clean != nil && !format.isEmpty
                let updatedAt: Date = row["updated_at"]
                assets.append(Self.assetDTO(
                    assetID: assetID,
                    displayName: row["display_name"],
                    kind: MediaKind(rawValue: row["kind"]) ?? .document,
                    format: format,
                    byteCount: row["byte_count"],
                    contentSHA256: row["content_hash"],
                    updatedAt: updatedAt,
                    selectable: selectable))
                lastCursor = Self.assetCursor(
                    updatedAt: updatedAt, rowID: rowID)
            }
            return G09R2DesignCreativeAssetPageDTO(
                assets: assets,
                nextCursor: rows.count > limit ? lastCursor : nil)
        }
    }

    static func assetDTO(
        assetID: UUID,
        displayName: String,
        kind: MediaKind,
        format: String,
        byteCount: Int64,
        contentSHA256: String,
        updatedAt: Date,
        selectable: Bool
    ) -> G09R2DesignCreativeAssetDTO {
        G09R2DesignCreativeAssetDTO(
            assetID: assetID.uuidString.lowercased(),
            displayName: displayName,
            kind: kind.rawValue,
            format: format,
            byteCount: byteCount,
            contentSHA256: contentSHA256.lowercased(),
            updatedAt: updatedAt,
            selectable: selectable)
    }

    // MARK: - Pending creative requests (owner envelopes)

    func pendingRequests(
        limit rawLimit: Int,
        cursor: String?
    ) async throws -> G09R2DesignCreativePendingPageDTO {
        guard let ownerStore = ownerStore else {
            throw G09R2DesignCreativeInventoryError.unavailable
        }
        let limit = Self.clampedLimit(rawLimit)
        let after = try Self.parsePendingCursor(cursor)
        let scan = await ownerStore.scanCreativeRequests(
            limit: limit,
            maxReads: Self.pendingMaxReads,
            afterMS: after?.ms,
            afterKey: after?.key)
        let requests = scan.entries.compactMap {
            entry -> G09R2DesignCreativePendingRequestDTO? in
            let envelope = entry.envelope
            guard let request = envelope.project.creativeRequest else {
                return nil
            }
            return G09R2DesignCreativePendingRequestDTO(
                targetKey: envelope.target.stableKey,
                ownerRevision: envelope.revision,
                target: envelope.target,
                storage: G09StorageLayerDTO(kind: .appOwned),
                requestedOutputKind: request.requestedKind,
                state: request.state,
                boundResultID: request.boundResultID,
                boundFormat: request.boundFormat,
                boundContentSHA256: request.boundContentSHA256,
                originConversationID: request.originConversationID,
                environmentID: request.environmentID,
                updatedAt: envelope.updatedAt)
        }
        let nextCursor: String?
        if !scan.exhausted, let lastMS = scan.lastExaminedMS,
           let lastKey = scan.lastExaminedKey {
            nextCursor = Self.pendingCursor(ms: lastMS, key: lastKey)
        } else {
            nextCursor = nil
        }
        return G09R2DesignCreativePendingPageDTO(
            requests: requests, nextCursor: nextCursor)
    }

    // MARK: - Cursors

    private struct AssetKeyset {
        let date: Date
        let rowID: String
    }

    private static func assetCursor(updatedAt: Date, rowID: String) -> String {
        let ms = Int64((updatedAt.timeIntervalSince1970 * 1000).rounded(.down))
        return "\(ms):\(rowID)"
    }

    private static func parseAssetCursor(_ raw: String?) throws -> AssetKeyset? {
        guard let raw, !raw.isEmpty else { return nil }
        guard raw.utf8.count <= cursorBytes,
              let separator = raw.firstIndex(of: ":") else {
            throw G09R2DesignCreativeInventoryError.invalidCursor
        }
        let msPart = String(raw[raw.startIndex..<separator])
        let rowID = String(raw[raw.index(after: separator)...])
        guard let ms = Int64(msPart), ms >= 0,
              rowID.count == 36, UUID(uuidString: rowID) != nil else {
            throw G09R2DesignCreativeInventoryError.invalidCursor
        }
        return AssetKeyset(
            date: Date(timeIntervalSince1970: Double(ms) / 1000),
            rowID: rowID)
    }

    private struct PendingKeyset {
        let ms: Int64
        let key: String
    }

    private static func pendingCursor(ms: Int64, key: String) -> String {
        "\(ms):\(key)"
    }

    private static func parsePendingCursor(_ raw: String?) throws -> PendingKeyset? {
        guard let raw, !raw.isEmpty else { return nil }
        guard raw.utf8.count <= cursorBytes,
              let separator = raw.firstIndex(of: ":") else {
            throw G09R2DesignCreativeInventoryError.invalidCursor
        }
        let msPart = String(raw[raw.startIndex..<separator])
        let key = String(raw[raw.index(after: separator)...])
        guard let ms = Int64(msPart), ms >= 0,
              G09R2DesignOwnerProjectStore.isStableKey(key) else {
            throw G09R2DesignCreativeInventoryError.invalidCursor
        }
        return PendingKeyset(ms: ms, key: key)
    }

    static func clampedLimit(_ raw: Int) -> Int {
        min(max(raw, 1), pageMaximum)
    }
}
