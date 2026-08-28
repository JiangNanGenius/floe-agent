#if canImport(CloudKit)
import Foundation
import CloudKit
import FloeCore
import FloePersistence

/// Deletes unreferenced canvas assets immediately from the private CloudKit
/// zone and only clears the local release queue after a confirming fetch
/// proves the remote record is gone.
public actor CanvasCloudAssetService {
    public static let zoneName = "FloeCreativeAssets"

    private let database: CKDatabase
    private let store: CreativeAssetStore
    private let operationStore: CanvasSyncOperationStore?
    private let zoneID = CKRecordZone.ID(
        zoneName: zoneName, ownerName: CKCurrentUserDefaultName
    )

    public init(
        container: CKContainer = .default(),
        store: CreativeAssetStore,
        operationStore: CanvasSyncOperationStore? = nil
    ) {
        self.database = container.privateCloudDatabase
        self.store = store
        self.operationStore = operationStore
    }

    public func prepare() async throws {
        _ = try await database.save(CKRecordZone(zoneID: zoneID))
    }

    public func releasePending() async {
        await pushPendingCanvasOperations()
        let records = (try? await store.pendingReleaseRecords()) ?? []
        guard !records.isEmpty else { return }
        try? await prepare()
        for item in records where !Task.isCancelled {
            do {
                try await store.markRelease(id: item.release.id, state: .releasing)
                let recordID = CKRecord.ID(recordName: item.cloudRecordName, zoneID: zoneID)
                do { _ = try await database.deleteRecord(withID: recordID) }
                catch let error as CKError where error.code == .unknownItem { }
                do {
                    _ = try await database.record(for: recordID)
                    try await store.markRelease(
                        id: item.release.id, state: .failed,
                        error: "CloudKit 删除后仍能查询到该素材。"
                    )
                } catch let error as CKError where error.code == .unknownItem {
                    try await store.confirmRelease(
                        id: item.release.id, assetID: item.release.assetID,
                        deleteLocalAfterRelease: item.release.deleteLocalAfterRelease
                    )
                }
            } catch {
                try? await store.markRelease(
                    id: item.release.id, state: .failed,
                    error: error.localizedDescription
                )
            }
        }
    }

    /// Sends durable canvas mutations in revision order. The CloudKit record
    /// name is the stable operation ID, so retries are idempotent. Deletions
    /// remain as tiny tombstone records to prevent an offline device from
    /// recreating content whose media has already been permanently released.
    public func pushPendingCanvasOperations() async {
        guard let operationStore else { return }
        let pending = (try? await operationStore.pending()) ?? []
        guard !pending.isEmpty else { return }
        try? await prepare()
        for item in pending where !Task.isCancelled {
            do {
                try await operationStore.mark(
                    operationID: item.operation.operationID,
                    state: .sending
                )
                let operation = item.operation
                for hash in operation.assetHashes {
                    try await uploadAssetIfNeeded(contentHash: hash)
                }
                let recordID = CKRecord.ID(
                    recordName: "CanvasOperation-\(operation.operationID.uuidString)",
                    zoneID: zoneID
                )
                let record = CKRecord(recordType: "CanvasOperation", recordID: recordID)
                record["canvasID"] = operation.canvasID.uuidString as CKRecordValue
                record["entityKind"] = operation.entityKind.rawValue as CKRecordValue
                record["entityID"] = operation.entityID.uuidString as CKRecordValue
                record["mutation"] = operation.mutation.rawValue as CKRecordValue
                record["revision"] = NSNumber(value: operation.revision)
                record["createdAt"] = operation.createdAt as CKRecordValue
                if let payload = operation.payload { record["payload"] = payload as CKRecordValue }
                record["assetHashes"] = operation.assetHashes as CKRecordValue
                _ = try await database.save(record)
                try await operationStore.confirm(operationID: operation.operationID)
            } catch {
                try? await operationStore.mark(
                    operationID: item.operation.operationID,
                    state: .failed, error: error.localizedDescription
                )
            }
        }
    }

    /// Fetches remote operations for one canvas. Record names are stable
    /// operation IDs and the reducer is deterministic, so receiving the same
    /// page again after interruption is harmless.
    public func pullCanvasOperations(canvasID: UUID) async -> [CanvasSyncOperation] {
        try? await prepare()
        let query = CKQuery(
            recordType: "CanvasOperation",
            predicate: NSPredicate(format: "canvasID == %@", canvasID.uuidString)
        )
        query.sortDescriptors = [NSSortDescriptor(key: "revision", ascending: true)]
        do {
            let (results, _) = try await database.records(
                matching: query, inZoneWith: zoneID,
                desiredKeys: [
                    "canvasID", "entityKind", "entityID", "mutation",
                    "revision", "createdAt", "payload", "assetHashes"
                ], resultsLimit: 500
            )
            return results.compactMap { _, result in
                guard case .success(let record) = result else { return nil }
                return Self.decodeOperation(record)
            }.sorted {
                ($0.revision, $0.createdAt, $0.operationID.uuidString)
                    < ($1.revision, $1.createdAt, $1.operationID.uuidString)
            }
        } catch {
            return []
        }
    }

    /// Lazily downloads a referenced private asset. The CloudKit asset is
    /// copied into Floe's durable material directory before the DB record is
    /// published, so interruption cannot leave a ready record pointing at a
    /// temporary CloudKit file.
    public func downloadAssetIfNeeded(contentHash: String) async throws -> CreativeAssetRecord? {
        if let existing = try await store.asset(contentHash: contentHash),
           let path = existing.localRelativePath,
           FileManager.default.fileExists(atPath: try materialURL(relativePath: path).path) {
            return existing
        }
        let recordName = "CreativeAsset-\(contentHash)"
        let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        let record = try await database.record(for: recordID)
        guard let cloudAsset = record["file"] as? CKAsset,
              let temporaryURL = cloudAsset.fileURL else { return nil }
        let id = UUID(uuidString: record["assetID"] as? String ?? "") ?? UUID()
        let fileName = (record["fileName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? "\(id.uuidString)-cloud.bin"
        let relativePath = "Materials/\(fileName)"
        let destination = try materialURL(relativePath: relativePath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: temporaryURL, to: destination)
        let kind = MediaKind(rawValue: record["kind"] as? String ?? "") ?? .image
        let saved = CreativeAssetRecord(
            id: id, contentHash: contentHash, kind: kind,
            displayName: record["displayName"] as? String ?? fileName,
            mimeType: record["mimeType"] as? String,
            localRelativePath: relativePath, cloudRecordName: recordName,
            byteCount: (record["byteCount"] as? NSNumber)?.int64Value ?? 0,
            sourceURL: (record["sourceURL"] as? String).flatMap(URL.init(string:)),
            license: record["license"] as? String,
            tags: record["tags"] as? [String] ?? [], referenceCount: 1
        )
        try await store.save(saved)
        return saved
    }

    private func uploadAssetIfNeeded(contentHash: String) async throws {
        guard let asset = try await store.asset(contentHash: contentHash),
              let relativePath = asset.localRelativePath else { return }
        let recordName = "CreativeAsset-\(contentHash)"
        let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        if (try? await database.record(for: recordID)) != nil {
            if asset.cloudRecordName != recordName {
                try await store.setCloudRecordName(assetID: asset.id, recordName: recordName)
            }
            return
        }
        let fileURL = try materialURL(relativePath: relativePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let record = CKRecord(recordType: "CreativeAsset", recordID: recordID)
        record["assetID"] = asset.id.uuidString as CKRecordValue
        record["contentHash"] = contentHash as CKRecordValue
        record["kind"] = asset.kind.rawValue as CKRecordValue
        record["displayName"] = asset.displayName as CKRecordValue
        record["fileName"] = fileURL.lastPathComponent as CKRecordValue
        record["byteCount"] = NSNumber(value: asset.byteCount)
        if let mimeType = asset.mimeType { record["mimeType"] = mimeType as CKRecordValue }
        if let sourceURL = asset.sourceURL { record["sourceURL"] = sourceURL.absoluteString as CKRecordValue }
        if let license = asset.license { record["license"] = license as CKRecordValue }
        record["tags"] = asset.tags as CKRecordValue
        record["file"] = CKAsset(fileURL: fileURL)
        _ = try await database.save(record)
        try await store.setCloudRecordName(assetID: asset.id, recordName: recordName)
    }

    private func materialURL(relativePath: String) throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        return support.appendingPathComponent("FloeAgent/\(relativePath)")
    }

    private static func decodeOperation(_ record: CKRecord) -> CanvasSyncOperation? {
        guard record.recordID.recordName.hasPrefix("CanvasOperation-"),
              let operationID = UUID(uuidString: String(record.recordID.recordName.dropFirst("CanvasOperation-".count))),
              let canvasID = UUID(uuidString: record["canvasID"] as? String ?? ""),
              let entityKind = CanvasSyncEntityKind(rawValue: record["entityKind"] as? String ?? ""),
              let entityID = UUID(uuidString: record["entityID"] as? String ?? ""),
              let mutation = CanvasSyncMutation(rawValue: record["mutation"] as? String ?? "")
        else { return nil }
        return CanvasSyncOperation(
            operationID: operationID, canvasID: canvasID,
            entityKind: entityKind, entityID: entityID, mutation: mutation,
            revision: (record["revision"] as? NSNumber)?.int64Value ?? 0,
            payload: record["payload"] as? Data,
            assetHashes: record["assetHashes"] as? [String] ?? [],
            createdAt: record["createdAt"] as? Date ?? record.creationDate ?? .distantPast
        )
    }
}
#endif
