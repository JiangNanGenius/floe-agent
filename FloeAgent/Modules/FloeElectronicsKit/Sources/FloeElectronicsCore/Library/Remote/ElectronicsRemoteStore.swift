// SPDX-License-Identifier: MPL-2.0
import Foundation

public struct ElectronicsRemoteSnapshot: Sendable {
    public let directory: URL
    public let publication: ElectronicsRemotePublication
    public let catalog: ElectronicsRemoteCatalog
    public let manifest: ElectronicsRemoteManifest
    public let modelIndex: ElectronicsRemoteModelIndex
    public let releaseSHA256: String
    public let installedAt: Date?
}

public struct ElectronicsRemoteRefreshReceipt: Codable, Hashable, Sendable {
    public let tag: String
    public let dataVersion: String
    public let datasetSHA256: String
    public let producerRevision: String
    public let sourceCount: Int
    public let modelCount: Int
    public let catalogBytes: Int
    public let modelIndexBytes: Int
    public let changed: Bool
}

public struct ElectronicsRemoteAssetReceipt: Codable, Hashable, Sendable {
    public let kind: String
    public let name: String
    public let path: String
    public let byteCount: Int
    public let sha256: String
    public let role: String
    public let tag: String
    public let cached: Bool
}

public struct ElectronicsRemoteModelReceipt: Codable, Hashable, Sendable {
    public let id: String
    public let sourceID: String
    public let repository: String
    public let revision: String
    public let path: String
    public let gitBlobSHA1: String
    public let format: String
    public let licenseSourceID: String
    public let byteCount: Int
    public let sha256: String
    public let cached: Bool
    public let displayName: String
    /// App-owned verified cache location. Never a model-facing file reference.
    public let cachePath: String
}

public struct ElectronicsRemoteCacheStatus: Codable, Hashable, Sendable {
    public let assets: Int
    public let models: Int
    public let indexes: Int
    public let bytes: Int
}

private struct ElectronicsRemoteSnapshotPointer: Codable {
    var schemaVersion: Int
    var dataVersion: String
    var tag: String
    var releaseSHA256: String
    var catalogSHA256: String
    var manifestSHA256: String
    var modelIndexSHA256: String
    var modelsSHA256: String
    var installedAt: String
}

private struct ElectronicsRemoteStoredSnapshot: Codable {
    var schemaVersion: Int
    var dataVersion: String
    var tag: String
    var releaseSHA256: String
    var catalogSHA256: String
    var manifestSHA256: String
    var modelIndexSHA256: String
    var modelsSHA256: String
    var modelsByteCount: Int
    var installedAt: String
}

private struct ElectronicsRemoteAssetRecord: Codable {
    var schemaVersion: Int
    var name: String
    var sha256: String
    var bytes: Int
    var role: String
    var tag: String
    var downloadedAt: String
}

private struct ElectronicsRemoteModelRecordReceipt: Codable {
    var schemaVersion: Int
    var id: String
    var sourceID: String
    var gitBlobSHA1: String
    var sha256: String
    var bytes: Int
    var displayName: String
    var downloadedAt: String
}

/// App-owned, atomically switched catalogue and content cache. A failed or
/// cancelled operation never moves the current pointer or replaces bytes that
/// still verify; only this actor's own temporary paths are removed.
public actor ElectronicsRemoteStore {
    public let root: URL
    private var snapshot: ElectronicsRemoteSnapshot?
    private var loaded = false
    private let formatter = ISO8601DateFormatter()

    public init(root: URL) { self.root = root }

    private var snapshotsRoot: URL { root.appendingPathComponent("Snapshots", isDirectory: true) }
    private var assetsRoot: URL { root.appendingPathComponent("Assets", isDirectory: true) }
    private var modelsRoot: URL { root.appendingPathComponent("Models", isDirectory: true) }
    private var indexesRoot: URL { root.appendingPathComponent("Indexes", isDirectory: true) }
    private var pointerURL: URL { root.appendingPathComponent("current.json") }

    public func loadSnapshot() throws -> ElectronicsRemoteSnapshot? {
        if loaded { return snapshot }
        loaded = true
        guard FileManager.default.fileExists(atPath: pointerURL.path) else { return nil }
        let pointerData = try Data(contentsOf: pointerURL, options: [.mappedIfSafe])
        guard pointerData.count <= 64 * 1_024 else { throw ElectronicsRemoteError.conflict("snapshot pointer is oversized") }
        let pointer: ElectronicsRemoteSnapshotPointer
        do { pointer = try JSONDecoder().decode(ElectronicsRemoteSnapshotPointer.self, from: pointerData) }
        catch { throw ElectronicsRemoteError.conflict("snapshot pointer is invalid") }
        guard pointer.schemaVersion == 1,
              pointer.dataVersion.range(of: "^v1-[0-9a-f]{20}$", options: .regularExpression) != nil,
              pointer.tag == "data-" + pointer.dataVersion,
              ElectronicsRemoteDigest.isSHA256(pointer.releaseSHA256),
              ElectronicsRemoteDigest.isSHA256(pointer.catalogSHA256),
              ElectronicsRemoteDigest.isSHA256(pointer.manifestSHA256),
              ElectronicsRemoteDigest.isSHA256(pointer.modelsSHA256) else {
            throw ElectronicsRemoteError.conflict("snapshot pointer identity is invalid")
        }
        let directory = snapshotsRoot.appendingPathComponent(pointer.dataVersion, isDirectory: true)
        let release = try read(directory.appendingPathComponent("release.json"), maximum: ElectronicsRemoteLimits.releaseReceiptBytes)
        let catalogBytes = try read(directory.appendingPathComponent("catalog.json"), maximum: ElectronicsRemoteLimits.catalogBytes)
        let manifestBytes = try read(directory.appendingPathComponent("manifest.json"), maximum: ElectronicsRemoteLimits.manifestBytes)
        let modelsBytes = try read(directory.appendingPathComponent("models.jsonl"), maximum: ElectronicsRemoteLimits.modelIndexExpandedBytes)
        let storedBytes = try read(directory.appendingPathComponent("snapshot.json"), maximum: 64 * 1_024)
        guard ElectronicsRemoteDigest.sha256(release) == pointer.releaseSHA256,
              ElectronicsRemoteDigest.sha256(catalogBytes) == pointer.catalogSHA256,
              ElectronicsRemoteDigest.sha256(manifestBytes) == pointer.manifestSHA256,
              ElectronicsRemoteDigest.sha256(modelsBytes) == pointer.modelsSHA256 else {
            throw ElectronicsRemoteError.conflict("installed snapshot bytes differ from their pointer")
        }
        let stored: ElectronicsRemoteStoredSnapshot
        do { stored = try JSONDecoder().decode(ElectronicsRemoteStoredSnapshot.self, from: storedBytes) }
        catch { throw ElectronicsRemoteError.conflict("stored snapshot metadata is invalid") }
        guard stored.schemaVersion == 1, stored.dataVersion == pointer.dataVersion,
              stored.tag == pointer.tag, stored.releaseSHA256 == pointer.releaseSHA256,
              stored.catalogSHA256 == pointer.catalogSHA256, stored.manifestSHA256 == pointer.manifestSHA256,
              stored.modelIndexSHA256 == pointer.modelIndexSHA256, stored.modelsSHA256 == pointer.modelsSHA256 else {
            throw ElectronicsRemoteError.conflict("snapshot metadata differs from its pointer")
        }
        let publication = try ElectronicsRemotePublication.decode(release)
        let catalog = try ElectronicsRemoteCatalog.decode(catalogBytes)
        let manifest = try ElectronicsRemoteManifest.decode(manifestBytes)
        let records = try ElectronicsRemoteModelIndex.decodeJSONL(modelsBytes, catalog: catalog)
        let index = try ElectronicsRemoteModelIndex(records: records, catalog: catalog)
        try ElectronicsRemoteBinding.validate(publication: publication, catalog: catalog, manifest: manifest,
                                               modelIndexBytes: catalog.modelIndex?.bytes)
        let value = ElectronicsRemoteSnapshot(directory: directory, publication: publication,
            catalog: catalog, manifest: manifest, modelIndex: index, releaseSHA256: pointer.releaseSHA256,
            installedAt: formatter.date(from: stored.installedAt))
        snapshot = value
        return value
    }

    @discardableResult
    public func installSnapshot(releaseData: Data, publication: ElectronicsRemotePublication,
                                catalogData: Data, catalog: ElectronicsRemoteCatalog,
                                manifestData: Data, manifest: ElectronicsRemoteManifest,
                                modelIndexGzip: Data?, records: [ElectronicsRemoteModelRecord]) throws -> ElectronicsRemoteSnapshot {
        let verifiedPublication = try ElectronicsRemotePublication.decode(releaseData)
        guard verifiedPublication == publication else {
            throw ElectronicsRemoteError.integrity("release bytes do not match the verified publication")
        }
        let catalogAsset = try publication.asset(named: "catalog.json")
        let manifestAsset = try publication.asset(named: "manifest.json")
        guard catalogData.count == catalogAsset.bytes,
              ElectronicsRemoteDigest.sha256(catalogData) == catalogAsset.sha256,
              manifestData.count == manifestAsset.bytes,
              ElectronicsRemoteDigest.sha256(manifestData) == manifestAsset.sha256 else {
            throw ElectronicsRemoteError.integrity("catalogue or manifest bytes differ from the release receipt")
        }
        if let modelIndex = catalog.modelIndex {
            guard let modelIndexGzip, modelIndexGzip.count == modelIndex.bytes,
                  ElectronicsRemoteDigest.sha256(modelIndexGzip) == modelIndex.sha256 else {
                throw ElectronicsRemoteError.integrity("model index bytes differ from the catalogue receipt")
            }
        } else if modelIndexGzip != nil || !records.isEmpty {
            throw ElectronicsRemoteError.integrity("unexpected model index bytes")
        }
        let index = try ElectronicsRemoteModelIndex(records: records, catalog: catalog)
        try ElectronicsRemoteBinding.validate(publication: publication, catalog: catalog, manifest: manifest,
                                               modelIndexBytes: catalog.modelIndex?.bytes)
        let modelsData = try Self.encodeJSONL(records)
        let installedAt = formatter.string(from: Date())
        let stored = ElectronicsRemoteStoredSnapshot(schemaVersion: 1, dataVersion: catalog.dataVersion,
            tag: publication.tag, releaseSHA256: ElectronicsRemoteDigest.sha256(releaseData),
            catalogSHA256: ElectronicsRemoteDigest.sha256(catalogData),
            manifestSHA256: ElectronicsRemoteDigest.sha256(manifestData),
            modelIndexSHA256: catalog.modelIndex?.sha256 ?? ElectronicsRemoteDigest.sha256(Data()),
            modelsSHA256: ElectronicsRemoteDigest.sha256(modelsData),
            modelsByteCount: modelsData.count, installedAt: installedAt)
        let pointer = ElectronicsRemoteSnapshotPointer(schemaVersion: 1, dataVersion: stored.dataVersion,
            tag: stored.tag, releaseSHA256: stored.releaseSHA256, catalogSHA256: stored.catalogSHA256,
            manifestSHA256: stored.manifestSHA256, modelIndexSHA256: stored.modelIndexSHA256,
            modelsSHA256: stored.modelsSHA256, installedAt: installedAt)

        if let existing = snapshot, existing.publication.tag == publication.tag,
           existing.catalog.datasetSHA256 == catalog.datasetSHA256,
           existing.releaseSHA256 == stored.releaseSHA256 {
            return existing
        }
        try ensureDirectory(snapshotsRoot)
        let staging = snapshotsRoot.appendingPathComponent(".staging-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: staging) } }
        try releaseData.write(to: staging.appendingPathComponent("release.json"), options: .atomic)
        try catalogData.write(to: staging.appendingPathComponent("catalog.json"), options: .atomic)
        try manifestData.write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
        if let modelIndexGzip {
            try modelIndexGzip.write(to: staging.appendingPathComponent("models.jsonl.gz"), options: .atomic)
        }
        try modelsData.write(to: staging.appendingPathComponent("models.jsonl"), options: .atomic)
        try JSONEncoder().encode(stored).write(to: staging.appendingPathComponent("snapshot.json"), options: .atomic)
        let final = snapshotsRoot.appendingPathComponent(catalog.dataVersion, isDirectory: true)
        if FileManager.default.fileExists(atPath: final.path) {
            let existingSnapshot = try read(final.appendingPathComponent("snapshot.json"), maximum: 64 * 1_024)
            let existingStored = try? JSONDecoder().decode(ElectronicsRemoteStoredSnapshot.self, from: existingSnapshot)
            guard existingStored?.modelsSHA256 == stored.modelsSHA256,
                  existingStored?.catalogSHA256 == stored.catalogSHA256,
                  existingStored?.manifestSHA256 == stored.manifestSHA256 else {
                throw ElectronicsRemoteError.conflict("another snapshot already uses \(catalog.dataVersion)")
            }
            try? FileManager.default.removeItem(at: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: final)
        }
        committed = true
        let pointerData = try JSONEncoder().encode(pointer)
        guard pointerData.count <= 64 * 1_024 else { throw ElectronicsRemoteError.limits("snapshot pointer") }
        try pointerData.write(to: pointerURL, options: .atomic)
        let value = ElectronicsRemoteSnapshot(directory: final, publication: publication, catalog: catalog,
            manifest: manifest, modelIndex: index, releaseSHA256: stored.releaseSHA256,
            installedAt: formatter.date(from: installedAt))
        snapshot = value; loaded = true
        return value
    }

    // MARK: - Verified content cache

    public func cachedAsset(name: String, sha256: String, bytes: Int) -> URL? {
        guard ElectronicsRemoteValidation.safeAssetName(name), ElectronicsRemoteDigest.isSHA256(sha256) else { return nil }
        let directory = assetsRoot.appendingPathComponent(sha256, isDirectory: true)
        let url = directory.appendingPathComponent(name)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              size.isRegularFile == true, size.fileSize == bytes,
              (try? ElectronicsRemoteDigest.sha256(fileAt: url)) == sha256 else { return nil }
        return url
    }

    @discardableResult
    public func promoteAsset(staged: URL, name: String, sha256: String, bytes: Int, role: String, tag: String) throws -> URL {
        guard ElectronicsRemoteValidation.safeAssetName(name), ElectronicsRemoteDigest.isSHA256(sha256),
              (1...ElectronicsRemoteLimits.packageBytes).contains(bytes),
              (try? ElectronicsRemoteDigest.sha256(fileAt: staged)) == sha256,
              (try? staged.resourceValues(forKeys: [.fileSizeKey]).fileSize) == bytes else {
            throw ElectronicsRemoteError.integrity("staged asset differs from its receipt")
        }
        let directory = assetsRoot.appendingPathComponent(sha256, isDirectory: true)
        try ensureDirectory(directory)
        let destination = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: destination.path) {
            if (try? ElectronicsRemoteDigest.sha256(fileAt: destination)) == sha256 {
                try? FileManager.default.removeItem(at: staged)
                return destination
            }
            throw ElectronicsRemoteError.conflict("cached \(name) exists with different bytes")
        }
        try FileManager.default.moveItem(at: staged, to: destination)
        let record = ElectronicsRemoteAssetRecord(schemaVersion: 1, name: name, sha256: sha256,
            bytes: bytes, role: role, tag: tag, downloadedAt: formatter.string(from: Date()))
        try JSONEncoder().encode(record).write(to: directory.appendingPathComponent("receipt.json"), options: .atomic)
        return destination
    }

    public func cachedModel(record: ElectronicsRemoteModelRecord) -> (url: URL, sha256: String)? {
        let directory = modelsRoot.appendingPathComponent(record.gitBlobSHA1, isDirectory: true)
        let url = directory.appendingPathComponent(record.displayName)
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              let bytes = values.fileSize, (1...ElectronicsRemoteLimits.modelBytes).contains(bytes),
              record.byteCount.map({ $0 == bytes }) ?? true,
              (try? ElectronicsRemoteDigest.gitBlobSHA1(fileAt: url, byteCount: bytes)) == record.gitBlobSHA1 else {
            return nil
        }
        let receiptData = try? Data(contentsOf: directory.appendingPathComponent("receipt.json"))
        let receipt = receiptData.flatMap { try? JSONDecoder().decode(ElectronicsRemoteModelRecordReceipt.self, from: $0) }
        let digest = receipt?.sha256 ?? (try? ElectronicsRemoteDigest.sha256(fileAt: url))
        guard let digest, ElectronicsRemoteDigest.isSHA256(digest),
              record.sha256.map({ $0 == digest }) ?? true else { return nil }
        return (url, digest)
    }

    /// Looks up the App-owned verified cache using only immutable identity
    /// fields from a footprint's model reference. Never accepts a model path
    /// from a caller; the reference was built from a verified catalogue record.
    public func cachedModel(reference: EDAFootprintModelReference) -> (url: URL, sha256: String)? {
        guard let gitBlobSHA1 = reference.gitBlobSHA1,
              ElectronicsRemoteDigest.isGitObjectHash(gitBlobSHA1),
              ElectronicsRemoteValidation.safeAssetName(reference.fileName) else { return nil }
        let url = modelsRoot.appendingPathComponent(gitBlobSHA1, isDirectory: true)
            .appendingPathComponent(reference.fileName)
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true, let bytes = values.fileSize,
              (1...ElectronicsRemoteLimits.modelBytes).contains(bytes),
              reference.byteCount.map({ $0 == bytes }) ?? true,
              (try? ElectronicsRemoteDigest.gitBlobSHA1(fileAt: url, byteCount: bytes)) == gitBlobSHA1 else {
            return nil
        }
        let receiptData = try? Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent("receipt.json"))
        let receipt = receiptData.flatMap { try? JSONDecoder().decode(ElectronicsRemoteModelRecordReceipt.self, from: $0) }
        guard let digest = receipt?.sha256 ?? (try? ElectronicsRemoteDigest.sha256(fileAt: url)),
              ElectronicsRemoteDigest.isSHA256(digest),
              reference.sha256.map({ $0 == digest }) ?? true else { return nil }
        return (url, digest)
    }

    @discardableResult
    public func promoteModel(staged: URL, record: ElectronicsRemoteModelRecord, sha256: String, bytes: Int) throws -> URL {
        guard ElectronicsRemoteDigest.isSHA256(sha256),
              (1...ElectronicsRemoteLimits.modelBytes).contains(bytes),
              record.byteCount.map({ $0 == bytes }) ?? true,
              record.sha256.map({ $0 == sha256 }) ?? true,
              (try? staged.resourceValues(forKeys: [.fileSizeKey]).fileSize) == bytes,
              (try? ElectronicsRemoteDigest.sha256(fileAt: staged)) == sha256,
              (try? ElectronicsRemoteDigest.gitBlobSHA1(fileAt: staged, byteCount: bytes)) == record.gitBlobSHA1 else {
            throw ElectronicsRemoteError.integrity("staged model is not the recorded Git object")
        }
        let directory = modelsRoot.appendingPathComponent(record.gitBlobSHA1, isDirectory: true)
        try ensureDirectory(directory)
        let destination = directory.appendingPathComponent(record.displayName)
        if FileManager.default.fileExists(atPath: destination.path) {
            if let existing = cachedModel(record: record) {
                try? FileManager.default.removeItem(at: staged)
                return existing.url
            }
            // An unverifiable cache entry is not usable; the new staged bytes
            // already passed the full identity check before this replacement.
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: staged, to: destination)
        let receipt = ElectronicsRemoteModelRecordReceipt(schemaVersion: 1, id: record.id, sourceID: record.sourceID,
            gitBlobSHA1: record.gitBlobSHA1, sha256: sha256, bytes: bytes, displayName: record.displayName,
            downloadedAt: formatter.string(from: Date()))
        try JSONEncoder().encode(receipt).write(to: directory.appendingPathComponent("receipt.json"), options: .atomic)
        return destination
    }

    // MARK: - Per-library normalized index cache

    public func cachedPartIndex(sourceID: String, sha256: String, bytes: Int) -> Data? {
        guard ElectronicsRemoteValidation.safeSourceID(sourceID), ElectronicsRemoteDigest.isSHA256(sha256) else { return nil }
        let directory = indexesRoot.appendingPathComponent(sourceID, isDirectory: true)
        let url = directory.appendingPathComponent(sha256 + ".jsonl.gz")
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true, values.fileSize == bytes,
              let data = try? Data(contentsOf: url), ElectronicsRemoteDigest.sha256(data) == sha256 else { return nil }
        return data
    }

    @discardableResult
    public func promotePartIndex(sourceID: String, gzip: Data, sha256: String, bytes: Int) throws -> URL {
        guard ElectronicsRemoteValidation.safeSourceID(sourceID), ElectronicsRemoteDigest.isSHA256(sha256),
              gzip.count == bytes, ElectronicsRemoteDigest.sha256(gzip) == sha256 else {
            throw ElectronicsRemoteError.integrity("staged part index differs from its receipt")
        }
        let directory = indexesRoot.appendingPathComponent(sourceID, isDirectory: true)
        try ensureDirectory(directory)
        let destination = directory.appendingPathComponent(sha256 + ".jsonl.gz")
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        try gzip.write(to: destination, options: .atomic)
        return destination
    }

    public func cacheStatus() -> ElectronicsRemoteCacheStatus {
        var assets = 0, models = 0, indexes = 0, bytes = 0
        func scan(_ root: URL, files: inout Int) {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return }
            for case let url as URL in enumerator {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                if url.lastPathComponent == "receipt.json" { continue }
                files += 1
                bytes += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            }
        }
        scan(assetsRoot, files: &assets)
        scan(modelsRoot, files: &models)
        scan(indexesRoot, files: &indexes)
        return .init(assets: assets, models: models, indexes: indexes, bytes: bytes)
    }

    // MARK: - Helpers

    private func read(_ url: URL, maximum: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= maximum else {
            throw ElectronicsRemoteError.conflict("snapshot file \(url.lastPathComponent) is unavailable")
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    private func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private static func encodeJSONL(_ records: [ElectronicsRemoteModelRecord]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data()
        for record in records {
            data.append(try encoder.encode(record))
            data.append(0x0A)
        }
        return data
    }
}
