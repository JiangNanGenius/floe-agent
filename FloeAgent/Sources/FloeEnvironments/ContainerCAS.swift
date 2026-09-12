import Foundation
import FloeCore

/// Content-addressable store shared by every container layer. Large
/// artifacts (models, wheels, debs, node packs) are stored once; layers only
/// keep references, so deleting a container frees nothing until no layer
/// references the blob.
public actor ContainerCAS {
    public struct Index: Codable, Sendable {
        public var refs: [String: Int]
        public var bytes: [String: Int64]
        public var createdAt: [String: Date]
    }

    public struct Stats: Sendable {
        public var blobCount: Int
        public var totalBytes: Int64
        public var referencedBytes: Int64
    }

    private let roots: EnvironmentRoots
    private var index = Index(refs: [:], bytes: [:], createdAt: [:])
    private var loaded = false
    private let fileManager = FileManager.default

    public init(roots: EnvironmentRoots = .shared) {
        self.roots = roots
    }

    private var indexURL: URL { roots.casURL.appendingPathComponent("index.json") }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(floeContentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        index = (try? decoder.decode(Index.self, from: data)) ?? Index(refs: [:], bytes: [:], createdAt: [:])
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(index) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    private func blobURL(_ digest: String) -> URL {
        roots.casURL
            .appendingPathComponent(String(digest.prefix(2)), isDirectory: true)
            .appendingPathComponent(digest)
    }

    /// Ingests a file into the store (moving it when possible). Returns the
    /// SHA-256 digest.
    @discardableResult
    public func ingest(fileAt url: URL) throws -> String {
        loadIfNeeded()
        let digest = try FloeDigest.sha256Hex(ofFileAt: url)
        let destination = blobURL(digest)
        if !fileManager.fileExists(atPath: destination.path) {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            do {
                try fileManager.moveItem(at: url, to: destination)
            } catch {
                try fileManager.copyItem(at: url, to: destination)
                try? fileManager.removeItem(at: url)
            }
            let size = (try? fileManager.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
            index.bytes[digest] = size
            index.createdAt[digest] = Date()
        }
        index.refs[digest, default: 0] += 1
        persist()
        return digest
    }

    /// Ingests raw data (for small manifests) and returns the digest.
    @discardableResult
    public func ingest(data: Data) throws -> String {
        loadIfNeeded()
        let digest = FloeDigest.sha256Hex(data)
        let destination = blobURL(digest)
        if !fileManager.fileExists(atPath: destination.path) {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destination, options: .atomic)
            index.bytes[digest] = Int64(data.count)
            index.createdAt[digest] = Date()
        }
        index.refs[digest, default: 0] += 1
        persist()
        return digest
    }

    /// Materializes a blob at `destination`, preferring APFS clone, then copy. Writable files must never share an inode with CAS.
    public func link(digest: String, to destination: URL) throws {
        loadIfNeeded()
        guard digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw FloeError.validationFailed("Invalid CAS digest")
        }
        let source = blobURL(digest)
        guard fileManager.fileExists(atPath: source.path) else {
            throw FloeError.notFound("CAS blob \(digest)")
        }
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? fileManager.removeItem(at: destination)
        if cloneFile(from: source, to: destination) { return }
        try fileManager.copyItem(at: source, to: destination)
    }

    /// Retains a set of blobs for one layer (idempotent per layer operation).
    public func retain(_ digests: [String]) {
        loadIfNeeded()
        for digest in digests {
            index.refs[digest, default: 0] += 1
        }
        persist()
    }

    /// Releases references previously retained for a layer.
    public func release(_ digests: [String]) {
        loadIfNeeded()
        for digest in digests {
            guard let count = index.refs[digest] else { continue }
            if count <= 1 {
                index.refs[digest] = 0
            } else {
                index.refs[digest] = count - 1
            }
        }
        persist()
    }

    /// Deletes unreferenced blobs older than the grace period.
    @discardableResult
    public func garbageCollect(grace: TimeInterval = 7 * 24 * 3600, now: Date = Date()) -> Int64 {
        loadIfNeeded()
        var reclaimed: Int64 = 0
        for digest in Array(index.bytes.keys) where index.refs[digest, default: 0] == 0 {
            let created = index.createdAt[digest] ?? now
            guard now.timeIntervalSince(created) >= grace else { continue }
            let url = blobURL(digest)
            if fileManager.fileExists(atPath: url.path) {
                do { try fileManager.removeItem(at: url) } catch { continue }
            }
            reclaimed += index.bytes[digest] ?? 0
            index.refs.removeValue(forKey: digest)
            index.bytes.removeValue(forKey: digest)
            index.createdAt.removeValue(forKey: digest)
        }
        persist()
        return reclaimed
    }

    public func stats() -> Stats {
        loadIfNeeded()
        let referenced = index.refs.filter { $0.value > 0 }.keys
        return Stats(
            blobCount: index.bytes.count,
            totalBytes: index.bytes.values.reduce(0, +),
            referencedBytes: referenced.reduce(Int64(0)) { $0 + (index.bytes[$1] ?? 0) }
        )
    }

    private func cloneFile(from source: URL, to destination: URL) -> Bool {
        #if canImport(Darwin)
        return clonefile(source.path, destination.path, 0) == 0
        #else
        return false
        #endif
    }
}
