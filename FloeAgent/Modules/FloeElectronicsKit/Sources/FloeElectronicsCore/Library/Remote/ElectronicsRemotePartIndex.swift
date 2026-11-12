// SPDX-License-Identifier: MPL-2.0
import Foundation

/// One search-index row inside a per-library 2D exchange ZIP. The row is the
/// publisher's normalized identity; the chunk record is the actual normalized
/// geometry, never inferred from the library name.
public struct ElectronicsRemotePartSummary: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: String
    public var name: String
    public var library: String
    public var status: String
    public var path: String
    public var line: Int
    public var sha256: String
    public var sourcePath: String

    public init(id: String, kind: String, name: String, library: String, status: String,
                path: String, line: Int, sha256: String, sourcePath: String) {
        self.id = id; self.kind = kind; self.name = name; self.library = library; self.status = status
        self.path = path; self.line = line; self.sha256 = sha256; self.sourcePath = sourcePath
    }

    public func validate() throws {
        guard schemaVersionSafeID, !name.isEmpty, name.utf8.count <= 4_096,
              ["symbol", "footprint", "component"].contains(kind),
              ["converted", "reviewRequired", "unsupported"].contains(status),
              library.utf8.count <= 1_024,
              ElectronicsRemoteValidation.safeRelativePath(path),
              ElectronicsRemoteValidation.safeRelativePath(sourcePath),
              line >= 1, ElectronicsRemoteDigest.isSHA256(sha256) else {
            throw ElectronicsRemoteError.invalidCatalog("normalized search row is invalid")
        }
    }

    private var schemaVersionSafeID: Bool {
        id.hasPrefix("floe:electronics:") && id.utf8.count <= 8_192
    }
}

public struct ElectronicsRemotePartQuery: Codable, Hashable, Sendable {
    public var text: String
    public var kind: String?
    public var status: String?
    public var offset: Int
    public var limit: Int

    public init(text: String = "", kind: String? = nil, status: String? = nil,
                offset: Int = 0, limit: Int = 50) {
        self.text = text; self.kind = kind; self.status = status; self.offset = offset; self.limit = limit
    }
}

public struct ElectronicsRemotePartPage: Codable, Hashable, Sendable {
    public let total: Int
    public let nextOffset: Int?
    public let parts: [ElectronicsRemotePartSummary]
}

public struct ElectronicsRemotePartIndex: Sendable {
    public let sourceID: String
    public let rows: [ElectronicsRemotePartSummary]
    public let rowSHA256: String
    private let positions: [String: Int]

    public init(sourceID: String, rows: [ElectronicsRemotePartSummary], rowSHA256: String) throws {
        guard ElectronicsRemoteValidation.safeSourceID(sourceID),
              rows.count <= 250_000,
              ElectronicsRemoteDigest.isSHA256(rowSHA256) else {
            throw ElectronicsRemoteError.invalidCatalog("part index identity is invalid")
        }
        var positions: [String: Int] = [:]
        positions.reserveCapacity(rows.count)
        for (index, row) in rows.enumerated() {
            try row.validate()
            guard positions.updateValue(index, forKey: row.id) == nil else {
                throw ElectronicsRemoteError.invalidCatalog("duplicate normalized row \(row.id)")
            }
        }
        self.sourceID = sourceID; self.rows = rows; self.rowSHA256 = rowSHA256; self.positions = positions
    }

    public static func decode(compressed: Data, sourceID: String, catalog: ElectronicsRemoteCatalog) throws -> Self {
        let source = try catalog.source(id: sourceID)
        guard compressed.count == source.index.bytes,
              ElectronicsRemoteDigest.sha256(compressed) == source.index.sha256 else {
            throw ElectronicsRemoteError.integrity("library \(sourceID) search index differs from its receipt")
        }
        let expanded = try ElectronicsRemoteGzip.decompress(compressed,
            maximumBytes: ElectronicsRemoteLimits.modelIndexExpandedBytes)
        var rows: [ElectronicsRemotePartSummary] = []
        var start = expanded.startIndex
        while start < expanded.endIndex {
            guard let newline = expanded[start...].firstIndex(of: 0x0A) else {
                let line = expanded[start..<expanded.endIndex]
                if !line.isEmpty { try append(line, to: &rows) }
                break
            }
            let line = expanded[start..<newline]
            if !line.isEmpty { try append(line, to: &rows) }
            start = expanded.index(after: newline)
            if rows.count > 250_000 { throw ElectronicsRemoteError.limits("normalized row count") }
        }
        return try Self(sourceID: sourceID, rows: rows, rowSHA256: source.index.sha256)
    }

    private static func append(_ line: Data.SubSequence, to rows: inout [ElectronicsRemotePartSummary]) throws {
        guard line.count <= 256 * 1_024 else {
            throw ElectronicsRemoteError.limits("normalized search row")
        }
        let row: ElectronicsRemotePartSummary
        do { row = try JSONDecoder().decode(ElectronicsRemotePartSummary.self, from: Data(line)) }
        catch { throw ElectronicsRemoteError.invalidCatalog("normalized search row is not valid JSON") }
        try row.validate()
        rows.append(row)
    }

    public func row(id: String) throws -> ElectronicsRemotePartSummary {
        guard let index = positions[id] else {
            throw ElectronicsRemoteError.invalidCatalog("part \(id) is absent from library \(sourceID)")
        }
        return rows[index]
    }

    public func search(_ query: ElectronicsRemotePartQuery) throws -> ElectronicsRemotePartPage {
        guard query.text.utf8.count <= 512, query.offset >= 0, (1...200).contains(query.limit),
              query.kind.map({ ["symbol", "footprint", "component"].contains($0) }) ?? true,
              query.status.map({ ["converted", "reviewRequired", "unsupported"].contains($0) }) ?? true else {
            throw ElectronicsRemoteError.invalidCatalog("part query limits")
        }
        let folded = query.text.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                        locale: Locale(identifier: "en_US_POSIX"))
        let tokens = folded.split(whereSeparator: \.isWhitespace).map(String.init)
        var matches: [(score: Int, name: String, row: ElectronicsRemotePartSummary)] = []
        for row in rows {
            if let kind = query.kind, row.kind != kind { continue }
            if let status = query.status, row.status != status { continue }
            let haystack = (row.name + " " + row.id + " " + row.library + " " + row.sourcePath + " " + row.path)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard tokens.allSatisfy({ haystack.contains($0) }) else { continue }
            let score = row.name.caseInsensitiveCompare(query.text) == .orderedSame ? 0
                : row.name.lowercased().hasPrefix(query.text.lowercased()) ? 1 : 2
            matches.append((score, row.name, row))
        }
        matches.sort {
            if $0.score != $1.score { return $0.score < $1.score }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.row.id < $1.row.id : order == .orderedAscending
        }
        guard query.offset <= matches.count else {
            throw ElectronicsRemoteError.invalidCatalog("part page offset exceeds matches")
        }
        let end = min(matches.count, query.offset + query.limit)
        return .init(total: matches.count, nextOffset: end < matches.count ? end : nil,
                     parts: matches[query.offset..<end].map(\.row))
    }

    /// Locates the publisher's chunk entry for a row and re-verifies its line.
    public static func recordJSON(row: ElectronicsRemotePartSummary, sourceID: String,
                                  catalog: ElectronicsRemoteCatalog, chunk: Data) throws -> (json: String, observedSHA256: String) {
        let source = try catalog.source(id: sourceID)
        guard let descriptor = source.chunks.first(where: { $0.path == row.path }) else {
            throw ElectronicsRemoteError.invalidCatalog("chunk \(row.path) is absent from the library manifest")
        }
        guard chunk.count == descriptor.bytes, ElectronicsRemoteDigest.sha256(chunk) == descriptor.sha256 else {
            throw ElectronicsRemoteError.integrity("normalized chunk differs from its published descriptor")
        }
        let expanded = try ElectronicsRemoteGzip.decompress(chunk, maximumBytes: 64 * 1_024 * 1_024)
        var current = 0
        var start = expanded.startIndex
        while start < expanded.endIndex {
            guard let newline = expanded[start...].firstIndex(of: 0x0A) else {
                throw ElectronicsRemoteError.integrity("normalized JSONL record has no LF terminator")
            }
            current += 1
            let line = expanded[start..<newline]
            if current == row.line { return try verified(line: line, row: row) }
            start = expanded.index(after: newline)
        }
        throw ElectronicsRemoteError.integrity("normalized record line \(row.line) is absent")
    }

    private static func verified(line: Data.SubSequence, row: ElectronicsRemotePartSummary) throws
        -> (json: String, observedSHA256: String) {
        guard line.count <= 32 * 1_024 * 1_024 else {
            throw ElectronicsRemoteError.limits("normalized record")
        }
        let data = Data(line)
        // Producer indexes the exact UTF-8 record including its JSONL LF.
        // The returned JSON string omits that separator for callers.
        let digest = ElectronicsRemoteDigest.sha256(data + Data([0x0A]))
        guard digest == row.sha256 else {
            throw ElectronicsRemoteError.integrity("normalized record line differs from its index digest")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object) else {
            throw ElectronicsRemoteError.invalidCatalog("normalized record is not valid JSON")
        }
        return (String(decoding: data, as: UTF8.self), digest)
    }
}
