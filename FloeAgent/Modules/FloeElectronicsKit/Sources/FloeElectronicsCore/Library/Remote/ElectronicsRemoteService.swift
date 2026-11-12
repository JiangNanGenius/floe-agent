// SPDX-License-Identifier: MPL-2.0
import Foundation

public struct ElectronicsRemoteProgress: Sendable {
    private let handler: @Sendable (Int64, Int64?) -> Void
    public init(_ handler: @escaping @Sendable (Int64, Int64?) -> Void) { self.handler = handler }
    public func report(received: Int64, expected: Int64?) { handler(received, expected) }
}

/// Injected byte transport. Canonical publication bytes are fetched directly;
/// mirrored data/file routes may fail over only inside the injected transport.
public struct ElectronicsRemoteNetwork: Sendable {
    public var canonicalBytes: @Sendable (URL, Int) async throws -> Data
    public var mirroredBytes: @Sendable (ElectronicsRemoteTarget, Int) async throws -> Data
    public var mirroredFile: @Sendable (ElectronicsRemoteTarget, Int, URL, ElectronicsRemoteProgress) async throws -> Void
    public var archiveEntry: @Sendable (URL, String) async throws -> Data

    public init(canonicalBytes: @escaping @Sendable (URL, Int) async throws -> Data,
                mirroredBytes: @escaping @Sendable (ElectronicsRemoteTarget, Int) async throws -> Data,
                mirroredFile: @escaping @Sendable (ElectronicsRemoteTarget, Int, URL, ElectronicsRemoteProgress) async throws -> Void,
                archiveEntry: @escaping @Sendable (URL, String) async throws -> Data) {
        self.canonicalBytes = canonicalBytes; self.mirroredBytes = mirroredBytes
        self.mirroredFile = mirroredFile; self.archiveEntry = archiveEntry
    }
}

public struct ElectronicsRemoteStatus: Codable, Hashable, Sendable {
    public let installed: Bool
    public let tag: String?
    public let dataVersion: String?
    public let datasetSHA256: String?
    public let sourceCount: Int
    public let modelCount: Int
    public let installedAt: String?
    public let cache: ElectronicsRemoteCacheStatus
}

public struct ElectronicsRemoteLibrarySummary: Codable, Hashable, Sendable {
    public let id: String
    public let repository: String
    public let commit: String
    public let licenseID: String?
    public let attribution: String?
    public let recordCount: Int
    public let sourceStatus: String
    public let statuses: [String: Int]
    public let kinds: [String: Int]
    public let downloadAssetName: String
    public let packageBytes: Int?
    public let packageSHA256: String?
}

public struct ElectronicsRemoteLibraryQuery: Codable, Hashable, Sendable {
    public var text: String
    public var status: String?
    public var offset: Int
    public var limit: Int

    public init(text: String = "", status: String? = nil, offset: Int = 0, limit: Int = 50) {
        self.text = text; self.status = status; self.offset = offset; self.limit = limit
    }
}

public struct ElectronicsRemoteLibraryPage: Codable, Hashable, Sendable {
    public let total: Int
    public let nextOffset: Int?
    public let libraries: [ElectronicsRemoteLibrarySummary]
}

public struct ElectronicsRemoteLibraryRead: Codable, Hashable, Sendable {
    public let library: ElectronicsRemoteLibrarySummary
    public let source: ElectronicsRemoteCatalog.Source
}

public struct ElectronicsRemotePartRead: Codable, Hashable, Sendable {
    public let libraryID: String
    public let part: ElectronicsRemotePartSummary
    public let recordJSON: String
    public let recordSHA256: String
    public let sourcePath: String
}

public actor ElectronicsRemoteService {
    public let store: ElectronicsRemoteStore
    private let network: ElectronicsRemoteNetwork
    private var partIndexes: [String: ElectronicsRemotePartIndex] = [:]

    public init(store: ElectronicsRemoteStore, network: ElectronicsRemoteNetwork) {
        self.store = store; self.network = network
    }

    public init(storeRoot: URL, network: ElectronicsRemoteNetwork) {
        self.init(store: ElectronicsRemoteStore(root: storeRoot), network: network)
    }

    public func currentSnapshot() async throws -> ElectronicsRemoteSnapshot? {
        try await store.loadSnapshot()
    }

    public func status() async throws -> ElectronicsRemoteStatus {
        let cached = try await store.loadSnapshot()
        let cache = await store.cacheStatus()
        guard let cached else {
            return .init(installed: false, tag: nil, dataVersion: nil, datasetSHA256: nil,
                         sourceCount: 0, modelCount: 0, installedAt: nil, cache: cache)
        }
        return .init(installed: true, tag: cached.publication.tag, dataVersion: cached.catalog.dataVersion,
            datasetSHA256: cached.catalog.datasetSHA256, sourceCount: cached.catalog.sources.count,
            modelCount: cached.modelIndex.records.count,
            installedAt: cached.installedAt.map { ISO8601DateFormatter().string(from: $0) }, cache: cache)
    }

    /// Fetches only the mutable canonical `release.json` directly. Every data
    /// byte arrives through the injected mirror transport but is accepted only
    /// against the digest/size in that canonical receipt.
    public func refresh(progress: ElectronicsRemoteProgress = .init({ _, _ in })) async throws -> ElectronicsRemoteRefreshReceipt {
        try Task.checkCancellation()
        let latest = try ElectronicsRemoteTarget.officialLatestReleaseReceipt()
        let releaseData = try await network.canonicalBytes(latest.canonicalURL, ElectronicsRemoteLimits.releaseReceiptBytes)
        try Task.checkCancellation()
        let publication = try ElectronicsRemotePublication.decode(releaseData)
        let catalogAsset = try publication.asset(named: "catalog.json")
        let manifestAsset = try publication.asset(named: "manifest.json")
        let catalogTarget = try ElectronicsRemoteTarget.releaseAsset(tag: publication.tag, name: catalogAsset.name)
        let manifestTarget = try ElectronicsRemoteTarget.releaseAsset(tag: publication.tag, name: manifestAsset.name)
        let catalogData = try await network.mirroredBytes(catalogTarget, catalogAsset.bytes)
        try Task.checkCancellation()
        guard catalogData.count == catalogAsset.bytes,
              ElectronicsRemoteDigest.sha256(catalogData) == catalogAsset.sha256 else {
            throw ElectronicsRemoteError.integrity("catalogue bytes differ from the release receipt")
        }
        let manifestData = try await network.mirroredBytes(manifestTarget, manifestAsset.bytes)
        try Task.checkCancellation()
        guard manifestData.count == manifestAsset.bytes,
              ElectronicsRemoteDigest.sha256(manifestData) == manifestAsset.sha256 else {
            throw ElectronicsRemoteError.integrity("manifest bytes differ from the release receipt")
        }
        let catalog = try ElectronicsRemoteCatalog.decode(catalogData)
        let manifest = try ElectronicsRemoteManifest.decode(manifestData)
        var modelIndexGzip: Data?
        var records: [ElectronicsRemoteModelRecord] = []
        if let modelIndex = catalog.modelIndex {
            let target = try ElectronicsRemoteTarget.releaseAsset(tag: publication.tag, name: modelIndex.path)
            let data = try await network.mirroredBytes(target, modelIndex.bytes)
            try Task.checkCancellation()
            guard data.count == modelIndex.bytes,
                  ElectronicsRemoteDigest.sha256(data) == modelIndex.sha256 else {
                throw ElectronicsRemoteError.integrity("model index bytes differ from the catalogue receipt")
            }
            let index = try ElectronicsRemoteModelIndex.decode(compressed: data, catalog: catalog)
            modelIndexGzip = data; records = index.records
        }
        try ElectronicsRemoteBinding.validate(publication: publication, catalog: catalog, manifest: manifest,
                                               modelIndexBytes: modelIndexGzip?.count)
        try Task.checkCancellation()
        let previous = try await store.loadSnapshot()
        let snapshot = try await store.installSnapshot(releaseData: releaseData, publication: publication,
            catalogData: catalogData, catalog: catalog, manifestData: manifestData, manifest: manifest,
            modelIndexGzip: modelIndexGzip, records: records)
        partIndexes.removeAll()
        return .init(tag: publication.tag, dataVersion: catalog.dataVersion,
            datasetSHA256: catalog.datasetSHA256, producerRevision: catalog.producerRevision,
            sourceCount: catalog.sources.count, modelCount: records.count,
            catalogBytes: catalogData.count, modelIndexBytes: modelIndexGzip?.count ?? 0,
            changed: previous?.publication.tag != snapshot.publication.tag)
    }

    public func searchLibraries(_ query: ElectronicsRemoteLibraryQuery) async throws -> ElectronicsRemoteLibraryPage {
        let snapshot = try await requireSnapshot()
        guard query.text.utf8.count <= 512, query.offset >= 0, (1...200).contains(query.limit),
              query.status.map({ $0 == "normalized" || $0 == "empty-upstream" }) ?? true else {
            throw ElectronicsRemoteError.invalidCatalog("library query limits")
        }
        let folded = query.text.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                        locale: Locale(identifier: "en_US_POSIX"))
        let tokens = folded.split(whereSeparator: \.isWhitespace).map(String.init)
        var matches: [(score: Int, summary: ElectronicsRemoteLibrarySummary)] = []
        for source in snapshot.catalog.sources {
            if let status = query.status, source.sourceStatus != status { continue }
            let summary = librarySummary(source, publication: snapshot.publication)
            let haystack = (source.id + " " + source.repository + " " + summary.licenseID.orEmpty + " "
                + summary.attribution.orEmpty).folding(options: [.caseInsensitive, .diacriticInsensitive],
                                                       locale: Locale(identifier: "en_US_POSIX"))
            guard tokens.allSatisfy({ haystack.contains($0) }) else { continue }
            let score = source.id.caseInsensitiveCompare(query.text) == .orderedSame ? 0
                : source.id.lowercased().hasPrefix(query.text.lowercased()) ? 1 : 2
            matches.append((score, summary))
        }
        matches.sort {
            if $0.score != $1.score { return $0.score < $1.score }
            let order = $0.summary.id.localizedStandardCompare($1.summary.id)
            return order == .orderedSame ? $0.summary.id < $1.summary.id : order == .orderedAscending
        }
        guard query.offset <= matches.count else {
            throw ElectronicsRemoteError.invalidCatalog("library page offset exceeds matches")
        }
        let end = min(matches.count, query.offset + query.limit)
        return .init(total: matches.count, nextOffset: end < matches.count ? end : nil,
                     libraries: matches[query.offset..<end].map(\.summary))
    }

    public func readLibrary(id: String) async throws -> ElectronicsRemoteLibraryRead {
        let snapshot = try await requireSnapshot()
        let source = try snapshot.catalog.source(id: id)
        return .init(library: librarySummary(source, publication: snapshot.publication), source: source)
    }

    /// Downloads the exact per-library exchange ZIP when its normalized index
    /// is not cached, verifies it against the release receipt, then reads the
    /// publisher's actual `indexes/<source>.jsonl.gz`.
    public func searchParts(libraryID: String, query: ElectronicsRemotePartQuery,
                            progress: ElectronicsRemoteProgress = .init({ _, _ in })) async throws -> ElectronicsRemotePartPage {
        let snapshot = try await requireSnapshot()
        let index = try await partIndex(libraryID: libraryID, snapshot: snapshot, progress: progress)
        return try index.search(query)
    }

    public func readPart(libraryID: String, id: String,
                         progress: ElectronicsRemoteProgress = .init({ _, _ in })) async throws -> ElectronicsRemotePartRead {
        let snapshot = try await requireSnapshot()
        let index = try await partIndex(libraryID: libraryID, snapshot: snapshot, progress: progress)
        let row = try index.row(id: id)
        let zipURL = try await libraryEntrySource(libraryID: libraryID, snapshot: snapshot, progress: progress)
        let chunk = try await network.archiveEntry(zipURL, row.path)
        let record = try ElectronicsRemotePartIndex.recordJSON(row: row, sourceID: libraryID,
                                                              catalog: snapshot.catalog, chunk: chunk)
        return .init(libraryID: libraryID, part: row, recordJSON: record.json,
                     recordSHA256: record.observedSHA256, sourcePath: row.sourcePath)
    }

    public func searchModels(_ query: ElectronicsRemoteModelQuery) async throws -> ElectronicsRemoteModelPage {
        try await requireSnapshot().modelIndex.search(query)
    }

    public func readModel(id: String) async throws -> ElectronicsRemoteModelRecord {
        try await requireSnapshot().modelIndex.record(id: id)
    }

    /// Returns the exact verified normalized record plus the already-verified
    /// per-library archive URL and model index candidates. The App-owned
    /// installer reads the nested original/licence bytes through its existing
    /// bounded ZIP reader; this method never opens a caller path.
    public func partMaterial(libraryID: String, id: String,
                             progress: ElectronicsRemoteProgress = .init({ _, _ in }))
        async throws -> ElectronicsRemotePartMaterial {
        let snapshot = try await requireSnapshot()
        let index = try await partIndex(libraryID: libraryID, snapshot: snapshot, progress: progress)
        let row = try index.row(id: id)
        let zipURL = try await libraryEntrySource(libraryID: libraryID, snapshot: snapshot, progress: progress)
        let chunk = try await network.archiveEntry(zipURL, row.path)
        let record = try ElectronicsRemotePartIndex.recordJSON(row: row, sourceID: libraryID,
                                                              catalog: snapshot.catalog, chunk: chunk)
        return .init(libraryID: libraryID, record: row, recordJSON: record.json,
            recordSHA256: record.observedSHA256, source: try snapshot.catalog.source(id: libraryID),
            libraryArchiveURL: zipURL, modelRecords: snapshot.modelIndex.records, originalFiles: [:])
    }

    public func modelRecord(forPath path: String) async throws -> ElectronicsRemoteModelRecord? {
        let snapshot = try await requireSnapshot()
        return snapshot.modelIndex.records.first { record in
            record.path == path || record.path.hasSuffix("/" + path) || path.hasSuffix("/" + record.path)
        }
    }

    public func downloadLibrary(id: String,
                                progress: ElectronicsRemoteProgress = .init({ _, _ in })) async throws -> ElectronicsRemoteAssetReceipt {
        let snapshot = try await requireSnapshot()
        _ = try snapshot.catalog.source(id: id)
        let asset = try libraryAsset(libraryID: id, snapshot: snapshot)
        let cached = try await ensureAsset(asset, tag: snapshot.publication.tag, progress: progress)
        return .init(kind: "library", name: asset.name, path: cached.url.path, byteCount: asset.bytes,
                     sha256: asset.sha256, role: asset.role, tag: snapshot.publication.tag, cached: cached.cached)
    }

    public func downloadFull2D(progress: ElectronicsRemoteProgress = .init({ _, _ in }))
        async throws -> ElectronicsRemoteAssetReceipt {
        let snapshot = try await requireSnapshot()
        guard let asset = snapshot.publication.assets.first(where: { $0.role == "all-2d-libraries" }) else {
            throw ElectronicsRemoteError.invalidRelease("release has no full 2D package")
        }
        let cached = try await ensureAsset(asset, tag: snapshot.publication.tag, progress: progress)
        return .init(kind: "full2D", name: asset.name, path: cached.url.path, byteCount: asset.bytes,
                     sha256: asset.sha256, role: asset.role, tag: snapshot.publication.tag, cached: cached.cached)
    }

    public func downloadModel(id: String,
                              progress: ElectronicsRemoteProgress = .init({ _, _ in })) async throws -> ElectronicsRemoteModelReceipt {
        let snapshot = try await requireSnapshot()
        let record = try snapshot.modelIndex.record(id: id)
        if let cached = await store.cachedModel(record: record) {
            return .init(id: record.id, sourceID: record.sourceID, repository: record.repository,
                revision: record.revision, path: record.path, gitBlobSHA1: record.gitBlobSHA1,
                format: record.format, licenseSourceID: record.licenseSourceID,
                byteCount: (try? cached.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0,
                sha256: cached.sha256, cached: true, displayName: record.displayName,
                cachePath: cached.url.path)
        }
        try Task.checkCancellation()
        let target = try record.target
        let maximum = min(record.byteCount ?? ElectronicsRemoteLimits.modelBytes, ElectronicsRemoteLimits.modelBytes)
        let stagingRoot = store.root.appendingPathComponent("Temporary", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let staging = stagingRoot.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        try await network.mirroredFile(target, maximum, staging, progress)
        try Task.checkCancellation()
        let values = try staging.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let bytes = values.fileSize,
              (1...ElectronicsRemoteLimits.modelBytes).contains(bytes),
              record.byteCount.map({ $0 == bytes }) ?? true else {
            throw ElectronicsRemoteError.integrity("downloaded model size differs from its receipt")
        }
        let digest = try ElectronicsRemoteDigest.sha256(fileAt: staging)
        guard record.sha256.map({ $0 == digest }) ?? true,
              (try ElectronicsRemoteDigest.gitBlobSHA1(fileAt: staging, byteCount: bytes)) == record.gitBlobSHA1 else {
            throw ElectronicsRemoteError.integrity("downloaded bytes are not the recorded Git object")
        }
        let destination = try await store.promoteModel(staged: staging, record: record, sha256: digest, bytes: bytes)
        return .init(id: record.id, sourceID: record.sourceID, repository: record.repository,
            revision: record.revision, path: record.path, gitBlobSHA1: record.gitBlobSHA1,
            format: record.format, licenseSourceID: record.licenseSourceID,
            byteCount: bytes, sha256: digest, cached: false, displayName: record.displayName,
            cachePath: destination.path)
    }

    // MARK: - Internals

    private func requireSnapshot() async throws -> ElectronicsRemoteSnapshot {
        guard let snapshot = try await store.loadSnapshot() else {
            throw ElectronicsRemoteError.notReady("refresh the official catalogue first")
        }
        return snapshot
    }

    private func librarySummary(_ source: ElectronicsRemoteCatalog.Source,
                                publication: ElectronicsRemotePublication) -> ElectronicsRemoteLibrarySummary {
        let asset = publication.assets.first(where: { $0.name == source.downloadAssetName })
        return .init(id: source.id, repository: source.repository, commit: source.commit,
            licenseID: source.license?.id, attribution: source.license?.attribution,
            recordCount: source.recordCount, sourceStatus: source.sourceStatus,
            statuses: source.statuses, kinds: source.kinds, downloadAssetName: source.downloadAssetName,
            packageBytes: asset?.bytes, packageSHA256: asset?.sha256)
    }

    private func libraryAsset(libraryID: String,
                              snapshot: ElectronicsRemoteSnapshot) throws -> ElectronicsRemoteReleaseAsset {
        let source = try snapshot.catalog.source(id: libraryID)
        let asset = try snapshot.publication.asset(named: source.downloadAssetName)
        guard asset.role == "single-upstream-2d-library" else {
            throw ElectronicsRemoteError.invalidRelease("\(asset.name) is not a single-library package")
        }
        return asset
    }

    private func partIndex(libraryID: String, snapshot: ElectronicsRemoteSnapshot,
                           progress: ElectronicsRemoteProgress) async throws -> ElectronicsRemotePartIndex {
        if let cached = partIndexes[libraryID] { return cached }
        let source = try snapshot.catalog.source(id: libraryID)
        if let gzip = await store.cachedPartIndex(sourceID: libraryID, sha256: source.index.sha256,
                                                  bytes: source.index.bytes) {
            let index = try ElectronicsRemotePartIndex.decode(compressed: gzip, sourceID: libraryID,
                                                             catalog: snapshot.catalog)
            partIndexes[libraryID] = index
            return index
        }
        let zipURL = try await libraryEntrySource(libraryID: libraryID, snapshot: snapshot, progress: progress)
        try Task.checkCancellation()
        let gzip = try await network.archiveEntry(zipURL, source.index.path)
        let index = try ElectronicsRemotePartIndex.decode(compressed: gzip, sourceID: libraryID,
                                                         catalog: snapshot.catalog)
        _ = try await store.promotePartIndex(sourceID: libraryID, gzip: gzip,
                                             sha256: source.index.sha256, bytes: source.index.bytes)
        partIndexes[libraryID] = index
        return index
    }

    /// Both published ZIP forms contain the identical `indexes/<sid>` and
    /// `records/<sid>/...` entry paths. Prefer an already verified per-library
    /// ZIP, then an already verified full 2D ZIP, and only then download the
    /// per-library asset. All three are bound to the same publication hashes.
    private func libraryEntrySource(libraryID: String, snapshot: ElectronicsRemoteSnapshot,
                                    progress: ElectronicsRemoteProgress) async throws -> URL {
        let asset = try libraryAsset(libraryID: libraryID, snapshot: snapshot)
        if let cached = await store.cachedAsset(name: asset.name, sha256: asset.sha256, bytes: asset.bytes) {
            return cached
        }
        if let full = snapshot.publication.assets.first(where: { $0.role == "all-2d-libraries" }),
           let cached = await store.cachedAsset(name: full.name, sha256: full.sha256, bytes: full.bytes) {
            return cached
        }
        return try await ensureAsset(asset, tag: snapshot.publication.tag, progress: progress).url
    }

    private func ensureAsset(_ asset: ElectronicsRemoteReleaseAsset, tag: String,
                             progress: ElectronicsRemoteProgress) async throws -> (url: URL, cached: Bool) {
        if let cached = await store.cachedAsset(name: asset.name, sha256: asset.sha256, bytes: asset.bytes) {
            return (cached, true)
        }
        try Task.checkCancellation()
        let stagingRoot = store.root.appendingPathComponent("Temporary", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let staging = stagingRoot.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        let target = try ElectronicsRemoteTarget.releaseAsset(tag: tag, name: asset.name)
        try await network.mirroredFile(target, asset.bytes, staging, progress)
        try Task.checkCancellation()
        let values = try staging.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, values.fileSize == asset.bytes,
              (try? ElectronicsRemoteDigest.sha256(fileAt: staging)) == asset.sha256 else {
            throw ElectronicsRemoteError.integrity("downloaded \(asset.name) differs from the release receipt")
        }
        let promoted = try await store.promoteAsset(staged: staging, name: asset.name, sha256: asset.sha256,
                                                    bytes: asset.bytes, role: asset.role, tag: tag)
        return (promoted, false)
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}
