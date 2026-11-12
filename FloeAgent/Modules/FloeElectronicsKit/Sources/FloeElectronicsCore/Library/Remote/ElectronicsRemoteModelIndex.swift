// SPDX-License-Identifier: MPL-2.0
import Foundation
import zlib

/// Bounded gzip decoding for the model index. A corrupt or oversized index is
/// rejected before any row is interpreted.
public enum ElectronicsRemoteGzip {
    public static func decompress(_ data: Data, maximumBytes: Int) throws -> Data {
        guard maximumBytes > 0, data.count >= 18, data[0] == 0x1f, data[1] == 0x8b, data[2] == 8 else {
            throw ElectronicsRemoteError.integrity("model index is not gzip data")
        }
        var stream = z_stream()
        let initialized = inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initialized == Z_OK else { throw ElectronicsRemoteError.integrity("gzip decoder is unavailable") }
        defer { inflateEnd(&stream) }
        return try data.withUnsafeBytes { raw -> Data in
            guard let base = raw.bindMemory(to: Bytef.self).baseAddress else {
                throw ElectronicsRemoteError.integrity("empty compressed stream")
            }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(raw.count)
            let capacity = 64 * 1_024
            let buffer = UnsafeMutablePointer<Bytef>.allocate(capacity: capacity)
            defer { buffer.deallocate() }
            var output = Data()
            while true {
                stream.next_out = buffer
                stream.avail_out = uInt(capacity)
                let status = inflate(&stream, Z_NO_FLUSH)
                guard status == Z_OK || status == Z_STREAM_END else {
                    throw ElectronicsRemoteError.integrity("model index gzip stream is invalid")
                }
                let produced = capacity - Int(stream.avail_out)
                if produced > 0 {
                    guard produced <= maximumBytes - output.count else {
                        throw ElectronicsRemoteError.limits("model index expands beyond \(maximumBytes) bytes")
                    }
                    output.append(contentsOf: UnsafeBufferPointer(start: buffer, count: produced))
                }
                if status == Z_STREAM_END {
                    guard stream.avail_in == 0 else {
                        throw ElectronicsRemoteError.integrity("model index has trailing compressed bytes")
                    }
                    return output
                }
                if stream.avail_in == 0 && produced == 0 {
                    throw ElectronicsRemoteError.integrity("model index gzip stream is truncated")
                }
            }
        }
    }
}

public struct ElectronicsRemoteModelRecord: Codable, Hashable, Sendable, Identifiable {
    public var schemaVersion: Int
    public var id: String
    public var kind: String
    public var sourceID: String
    public var repository: String
    public var revision: String
    public var path: String
    public var gitBlobSHA1: String
    public var format: String
    public var licenseSourceID: String
    public var modelBinaryBundled: Bool
    public var verification: String
    public var byteCount: Int?
    public var sha256: String?

    public init(schemaVersion: Int = 1, id: String, kind: String = "model3d", sourceID: String,
                repository: String, revision: String, path: String, gitBlobSHA1: String,
                format: String, licenseSourceID: String, modelBinaryBundled: Bool = false,
                verification: String = "git-source-object; SHA-256 computed after download",
                byteCount: Int? = nil, sha256: String? = nil) {
        self.schemaVersion = schemaVersion; self.id = id; self.kind = kind; self.sourceID = sourceID
        self.repository = repository; self.revision = revision; self.path = path
        self.gitBlobSHA1 = gitBlobSHA1; self.format = format; self.licenseSourceID = licenseSourceID
        self.modelBinaryBundled = modelBinaryBundled; self.verification = verification
        self.byteCount = byteCount; self.sha256 = sha256
    }

    public var displayName: String { path.split(separator: "/").last.map(String.init) ?? "model" }

    public func validate(against catalog: ElectronicsRemoteCatalog) throws {
        guard schemaVersion == 1, kind == "model3d", !modelBinaryBundled,
              ElectronicsRemoteValidation.safeSourceID(sourceID),
              ElectronicsRemoteValidation.safeRelativePath(path),
              ElectronicsRemoteDigest.isGitObjectHash(revision),
              ElectronicsRemoteDigest.isGitObjectHash(gitBlobSHA1),
              id == "model:" + sourceID + ":" + path,
              verification.utf8.count <= 256 else {
            throw ElectronicsRemoteError.invalidModel("identity, path or Git object fields are invalid")
        }
        let suffix = (path as NSString).pathExtension.lowercased()
        let supported: Set<String> = ["step", "stp", "stpz", "wrl", "wrz", "glb", "gltf", "obj", "stl", "iges", "igs"]
        guard supported.contains(suffix), format == suffix else {
            throw ElectronicsRemoteError.invalidModel("format must be the actual lowercased model suffix")
        }
        if let byteCount { guard (1...ElectronicsRemoteLimits.modelBytes).contains(byteCount) else {
            throw ElectronicsRemoteError.invalidModel("declared model size is out of bounds")
        } }
        if let sha256 { guard ElectronicsRemoteDigest.isSHA256(sha256) else {
            throw ElectronicsRemoteError.invalidModel("declared model SHA-256 is malformed")
        } }
        let normalized = try ElectronicsRemoteValidation.normalizeRepository(repository)
        if let source = catalog.sources.first(where: { $0.id == sourceID }) {
            let catalogRepository = try ElectronicsRemoteValidation.normalizeRepository(source.repository)
            guard normalized == catalogRepository, revision == source.commit,
                  licenseSourceID == source.id else {
                throw ElectronicsRemoteError.invalidModel("model is not bound to its catalogue source revision")
            }
        } else if let source = try catalog.modelSource(id: sourceID) {
            let catalogRepository = try ElectronicsRemoteValidation.normalizeRepository(source.repository)
            guard normalized == catalogRepository, revision == source.commit,
                  licenseSourceID == source.licenseSourceID else {
                throw ElectronicsRemoteError.invalidModel("model is not bound to its pinned model source")
            }
        } else {
            throw ElectronicsRemoteError.invalidModel("model source \(sourceID) is absent from the catalogue")
        }
    }

    public var target: ElectronicsRemoteTarget {
        get throws {
            try .repositoryFile(repository: repository, revision: revision, path: path)
        }
    }
}

public struct ElectronicsRemoteModelQuery: Codable, Hashable, Sendable {
    public var text: String
    public var sourceID: String?
    public var format: String?
    public var offset: Int
    public var limit: Int

    public init(text: String = "", sourceID: String? = nil, format: String? = nil,
                offset: Int = 0, limit: Int = 50) {
        self.text = text; self.sourceID = sourceID; self.format = format; self.offset = offset; self.limit = limit
    }
}

public struct ElectronicsRemoteModelPage: Codable, Hashable, Sendable {
    public let total: Int
    public let nextOffset: Int?
    public let models: [ElectronicsRemoteModelRecord]
}

public struct ElectronicsRemoteModelIndex: Sendable {
    public let records: [ElectronicsRemoteModelRecord]
    private let positions: [String: Int]

    public init(records: [ElectronicsRemoteModelRecord], catalog: ElectronicsRemoteCatalog) throws {
        guard records.count <= ElectronicsRemoteLimits.modelIndexRows else {
            throw ElectronicsRemoteError.limits("model index row count")
        }
        var positions: [String: Int] = [:]
        positions.reserveCapacity(records.count)
        for (index, record) in records.enumerated() {
            try record.validate(against: catalog)
            guard positions.updateValue(index, forKey: record.id) == nil else {
                throw ElectronicsRemoteError.invalidModel("duplicate model identity \(record.id)")
            }
        }
        if let declared = catalog.modelCount, declared != records.count {
            throw ElectronicsRemoteError.invalidModel("catalogue model count differs from its index")
        }
        self.records = records; self.positions = positions
    }

    public static func decode(compressed: Data, catalog: ElectronicsRemoteCatalog) throws -> Self {
        guard compressed.count <= ElectronicsRemoteLimits.modelIndexCompressedBytes else {
            throw ElectronicsRemoteError.limits("model index compressed size")
        }
        let expanded = try ElectronicsRemoteGzip.decompress(compressed,
            maximumBytes: ElectronicsRemoteLimits.modelIndexExpandedBytes)
        let records = try decodeJSONL(expanded, catalog: catalog)
        return try Self(records: records, catalog: catalog)
    }

    public static func decodeJSONL(_ data: Data, catalog: ElectronicsRemoteCatalog) throws -> [ElectronicsRemoteModelRecord] {
        guard data.count <= ElectronicsRemoteLimits.modelIndexExpandedBytes else {
            throw ElectronicsRemoteError.limits("model index expanded size")
        }
        var records: [ElectronicsRemoteModelRecord] = []
        records.reserveCapacity(min(ElectronicsRemoteLimits.modelIndexRows, 1_024))
        var start = data.startIndex
        while start < data.endIndex {
            guard let newline = data[start...].firstIndex(of: 0x0A) else {
                if data.distance(from: start, to: data.endIndex) > ElectronicsRemoteLimits.modelLineBytes {
                    throw ElectronicsRemoteError.limits("model index line")
                }
                let line = data[start..<data.endIndex]
                if !line.isEmpty { try append(line, to: &records, catalog: catalog) }
                break
            }
            let line = data[start..<newline]
            if line.count > ElectronicsRemoteLimits.modelLineBytes {
                throw ElectronicsRemoteError.limits("model index line")
            }
            if !line.isEmpty { try append(line, to: &records, catalog: catalog) }
            start = data.index(after: newline)
        }
        return records
    }

    private static func append(_ line: Data.SubSequence, to records: inout [ElectronicsRemoteModelRecord],
                               catalog: ElectronicsRemoteCatalog) throws {
        guard records.count < ElectronicsRemoteLimits.modelIndexRows else {
            throw ElectronicsRemoteError.limits("model index row count")
        }
        let record: ElectronicsRemoteModelRecord
        do { record = try JSONDecoder().decode(ElectronicsRemoteModelRecord.self, from: Data(line)) }
        catch { throw ElectronicsRemoteError.invalidModel("model row is not valid JSON") }
        try record.validate(against: catalog)
        records.append(record)
    }

    public func record(id: String) throws -> ElectronicsRemoteModelRecord {
        guard let index = positions[id] else {
            throw ElectronicsRemoteError.invalidModel("model \(id) is absent from this index")
        }
        return records[index]
    }

    public func search(_ query: ElectronicsRemoteModelQuery) throws -> ElectronicsRemoteModelPage {
        guard query.text.utf8.count <= 512, query.offset >= 0, (1...200).contains(query.limit),
              query.sourceID.map(ElectronicsRemoteValidation.safeSourceID) ?? true,
              query.format.map({ !$0.isEmpty && $0.utf8.count <= 16 }) ?? true else {
            throw ElectronicsRemoteError.invalidModel("model query limits")
        }
        let folded = query.text.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                        locale: Locale(identifier: "en_US_POSIX"))
        let tokens = folded.split(whereSeparator: \.isWhitespace).map(String.init)
        var matches: [(score: Int, path: String, record: ElectronicsRemoteModelRecord)] = []
        for record in records {
            if let source = query.sourceID, record.sourceID != source { continue }
            if let format = query.format, record.format != format.lowercased() { continue }
            let name = record.displayName
            let haystack = (name + " " + record.path + " " + record.id + " " + record.repository + " " + record.sourceID)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard tokens.allSatisfy({ haystack.contains($0) }) else { continue }
            let score = name.caseInsensitiveCompare(query.text) == .orderedSame ? 0
                : name.lowercased().hasPrefix(query.text.lowercased()) ? 1 : 2
            matches.append((score, record.path, record))
        }
        matches.sort {
            if $0.score != $1.score { return $0.score < $1.score }
            let order = $0.path.localizedStandardCompare($1.path)
            return order == .orderedSame ? $0.record.id < $1.record.id : order == .orderedAscending
        }
        guard query.offset <= matches.count else {
            throw ElectronicsRemoteError.invalidModel("model page offset exceeds matches")
        }
        let end = min(matches.count, query.offset + query.limit)
        return .init(total: matches.count, nextOffset: end < matches.count ? end : nil,
                     models: matches[query.offset..<end].map(\.record))
    }
}
