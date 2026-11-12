// SPDX-License-Identifier: MPL-2.0
import CryptoKit
import Foundation

public enum EDALibraryDigest {
    public static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    public static func identifier(_ value: String) -> UUID {
        let hash = sha256(Data(value.utf8))
        let s = Array(hash)
        let groups = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(s[$0]) }
        return UUID(uuidString: groups.joined(separator: "-"))!
    }
    public static func validSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    public static func validSHA1(_ value: String) -> Bool {
        value.utf8.count == 40 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

public struct EDALibraryNotice: Codable, Hashable, Sendable {
    public enum Severity: String, Codable, Sendable { case information, warning, blocking }
    public var code: String
    public var severity: Severity
    public var path: String
    public var detail: String
    public init(_ code: String, _ severity: Severity, path: String, detail: String) {
        self.code = code; self.severity = severity; self.path = path; self.detail = detail
    }
}
public struct EDALibrarySource: Codable, Hashable, Sendable {
    public var path: String
    public var sha256: String
    public var byteCount: Int
    public var url: String?
    public var revision: String?
    public init(path: String, data: Data, url: String? = nil, revision: String? = nil) {
        self.path = path; sha256 = EDALibraryDigest.sha256(data); byteCount = data.count
        self.url = url; self.revision = revision
    }
}
public struct EDALibraryLicense: Codable, Hashable, Sendable {
    public var id: String
    public var attribution: String
    public var text: String
    public var url: String?
    public var modifications: String
    public init(id: String, attribution: String, text: String, url: String? = nil, modifications: String = "") {
        self.id = id; self.attribution = attribution; self.text = text; self.url = url; self.modifications = modifications
    }
}

/// Explicit physical mapping. Empty values are an intentional unconnected
/// logical pin; extra electrical pads must be declared, never guessed by name.
public struct EDALibraryPinMap: Codable, Hashable, Sendable {
    public var pinToPads: [String: [String]]
    public var unconnectedPads: [String]
    public init(pinToPads: [String: [String]], unconnectedPads: [String] = []) {
        self.pinToPads = pinToPads; self.unconnectedPads = unconnectedPads
    }
    private enum CodingKeys: String, CodingKey { case pinToPads, unconnectedPads }
    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        self.init(pinToPads: try fields.decode([String: [String]].self, forKey: .pinToPads),
            unconnectedPads: try fields.decodeIfPresent([String].self, forKey: .unconnectedPads) ?? [])
    }
    public static func matchingNumbers(symbol: EDASymbolDefinition, footprint: EDAFootprintDefinition) throws -> Self {
        let pins = Set(symbol.pins.map(\.number)), pads = Set(footprint.pads.map(\.number).filter { !$0.isEmpty })
        guard pins == pads else { throw EDAError.invalid("pin/pad numbers differ; an explicit mapping is required") }
        return .init(pinToPads: Dictionary(uniqueKeysWithValues: pins.map { ($0, [$0]) }))
    }
    public func validate(symbol: EDASymbolDefinition, footprint: EDAFootprintDefinition) throws {
        let pins = Set(symbol.pins.map(\.number)), pads = Set(footprint.pads.map(\.number).filter { !$0.isEmpty })
        guard Set(pinToPads.keys) == pins, Set(unconnectedPads).count == unconnectedPads.count,
              Set(unconnectedPads).isSubset(of: pads) else { throw EDAError.invalid("incomplete pin/pad mapping") }
        var mapped: Set<String> = []
        for values in pinToPads.values {
            guard Set(values).count == values.count, Set(values).isSubset(of: pads) else { throw EDAError.invalid("unknown or repeated mapped pad") }
            mapped.formUnion(values)
        }
        guard mapped.isDisjoint(with: unconnectedPads), mapped.union(unconnectedPads) == pads else {
            throw EDAError.invalid("unaccounted footprint pads")
        }
    }
    public func padNets(pinNets: [String: String]) throws -> [String: String] {
        var result: [String: String] = [:]
        for (pin, pads) in pinToPads {
            guard let net = pinNets[pin], !net.isEmpty else { continue }
            for pad in pads {
                guard result[pad] == nil || result[pad] == net else { throw EDAError.invalid("mapped pins with different nets share a pad") }
                result[pad] = net
            }
        }
        return result
    }
}

public struct EDALibraryPart: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case device, generic, symbol, footprint }
    public var id: String
    public var name: String
    public var kind: Kind
    public var category: String
    public var manufacturer: String
    public var aliases: [String]
    public var parameters: [String: String]
    public var symbol: EDASymbolDefinition?
    public var footprint: EDAFootprintDefinition?
    public var pinMap: EDALibraryPinMap?
    public var sources: [EDALibrarySource]
    public var notices: [EDALibraryNotice]
    public init(id: String, name: String, kind: Kind, category: String, manufacturer: String = "",
                aliases: [String] = [], parameters: [String: String] = [:], symbol: EDASymbolDefinition? = nil,
                footprint: EDAFootprintDefinition? = nil, pinMap: EDALibraryPinMap? = nil,
                sources: [EDALibrarySource] = [], notices: [EDALibraryNotice] = []) {
        self.id = id; self.name = name; self.kind = kind; self.category = category; self.manufacturer = manufacturer
        self.aliases = aliases; self.parameters = parameters; self.symbol = symbol; self.footprint = footprint
        self.pinMap = pinMap; self.sources = sources; self.notices = notices
    }
    public var pinCount: Int { Set(symbol?.pins.map(\.number) ?? []).count }
    public var isPlaceable: Bool { (symbol != nil || footprint != nil) && !notices.contains { $0.severity == .blocking } }
    public var supportsBoundPCB: Bool { symbol != nil && footprint != nil && pinMap != nil && isPlaceable }
    public var contentSHA256: String { get throws { try EDALibraryDigest.sha256(EDALibraryDigest.encoded(self)) } }
    public func validate() throws {
        guard !id.isEmpty, id.utf8.count <= 1_024, !name.isEmpty, name.utf8.count <= 4_096,
              symbol != nil || footprint != nil, sources.count <= 256, notices.count <= 1_024 else { throw EDAError.invalid("library part identity or budget") }
        if let symbol, let footprint {
            guard let pinMap else { throw EDAError.invalid("a combined device needs an explicit pin/pad mapping") }
            try pinMap.validate(symbol: symbol, footprint: footprint)
        } else if pinMap != nil { throw EDAError.invalid("mapping needs a symbol and footprint") }
        var project = EDAProject(title: name)
        project.symbols = symbol.map { [$0] } ?? []; project.footprints = footprint.map { [$0] } ?? []
        try EDAValidation.validate(project)
    }
}

public struct EDALibraryPackage: Codable, Hashable, Sendable {
    public var schemaVersion = 1
    public var id: String
    public var version: String
    public var title: String
    public var parts: [EDALibraryPart]
    public var licenses: [EDALibraryLicense]
    /// Exact original input, including unsupported objects, retained as data.
    public var sourcePayloads: [String: Data]
    public init(id: String, version: String, title: String, parts: [EDALibraryPart],
                licenses: [EDALibraryLicense], sourcePayloads: [String: Data] = [:]) {
        self.id = id; self.version = version; self.title = title; self.parts = parts
        self.licenses = licenses; self.sourcePayloads = sourcePayloads
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 256 * 1_024 * 1_024 else { throw EDAError.invalid("native library package byte limit") }
        let value = try JSONDecoder().decode(Self.self, from: data)
        let raw = try JSONSerialization.jsonObject(with: data)
        let canonical = try JSONSerialization.jsonObject(with: EDALibraryDigest.encoded(value))
        var work = 0
        func known(_ a: Any, _ b: Any, path: String, depth: Int) throws {
            work += 1
            guard work <= 1_000_000, depth <= 96 else { throw EDAError.invalid("native library structure budget") }
            if let a = a as? [String: Any], let b = b as? [String: Any] {
                for key in a.keys {
                    guard let existing = b[key] else { throw EDAError.unsupported("native library field " + path + "." + key) }
                    try known(a[key]!, existing, path: path + "." + key, depth: depth + 1)
                }
            } else if let a = a as? [Any], let b = b as? [Any] {
                guard a.count == b.count else { throw EDAError.invalid("native library array length") }
                for i in a.indices { try known(a[i], b[i], path: path + "[\(i)]", depth: depth + 1) }
            }
        }
        try known(raw, canonical, path: "$", depth: 0)
        try value.validate(); return value
    }
    public func validate() throws {
        guard schemaVersion == 1, !id.isEmpty, id.utf8.count <= 256, !version.isEmpty, version.utf8.count <= 128,
              parts.count <= 100_000, !licenses.isEmpty, licenses.count <= 64,
              Set(parts.map(\.id)).count == parts.count, sourcePayloads.count <= 4_096 else { throw EDAError.invalid("library package identity or limits") }
        var total = 0
        for (path, bytes) in sourcePayloads {
            guard Self.safeRelativePath(path), bytes.count <= 32 * 1_024 * 1_024 else { throw EDAError.invalid("library source path or limit") }
            total += bytes.count
        }
        guard total <= 128 * 1_024 * 1_024 else { throw EDAError.invalid("library source budget") }
        for license in licenses {
            guard !license.id.isEmpty, !license.attribution.isEmpty, !license.text.isEmpty, license.text.utf8.count <= 1_048_576 else { throw EDAError.invalid("library attribution missing") }
        }
        for part in parts {
            try part.validate()
            for source in part.sources {
                guard Self.safeRelativePath(source.path), let bytes = sourcePayloads[source.path],
                      bytes.count == source.byteCount, EDALibraryDigest.sha256(bytes) == source.sha256 else {
                    throw EDAError.invalid("library original source is missing or changed")
                }
            }
        }
    }
    public static func safeRelativePath(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1_024 && !value.hasPrefix("/") && !value.contains("\\")
            && value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

public struct EDALibraryQuery: Codable, Hashable, Sendable {
    public var text: String
    public var category: String?
    public var manufacturer: String?
    public var pinCount: Int?
    public var footprint: String?
    public var offset: Int
    public var limit: Int
    public init(text: String = "", category: String? = nil, manufacturer: String? = nil, pinCount: Int? = nil,
                footprint: String? = nil, offset: Int = 0, limit: Int = 50) {
        self.text = text; self.category = category; self.manufacturer = manufacturer; self.pinCount = pinCount
        self.footprint = footprint; self.offset = offset; self.limit = limit
    }
    private enum CodingKeys: String, CodingKey { case text, category, manufacturer, pinCount, footprint, offset, limit }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(text: try values.decodeIfPresent(String.self, forKey: .text) ?? "",
            category: try values.decodeIfPresent(String.self, forKey: .category),
            manufacturer: try values.decodeIfPresent(String.self, forKey: .manufacturer),
            pinCount: try values.decodeIfPresent(Int.self, forKey: .pinCount),
            footprint: try values.decodeIfPresent(String.self, forKey: .footprint),
            offset: try values.decodeIfPresent(Int.self, forKey: .offset) ?? 0,
            limit: try values.decodeIfPresent(Int.self, forKey: .limit) ?? 50)
    }

}
public struct EDALibrarySearchPage: Codable, Hashable, Sendable {
    public let total: Int
    public let nextOffset: Int?
    public let parts: [EDALibraryPart]
}
public enum EDALibrarySearch {
    public static func search(_ parts: [EDALibraryPart], query: EDALibraryQuery,
                              cancelled: @Sendable () -> Bool = { false }) throws -> EDALibrarySearchPage {
        let matches = try ranked(parts, part: { $0 }, query: query, cancelled: cancelled)
        guard query.offset <= matches.count else { throw EDAError.invalid("library page offset") }
        let end = min(matches.count, query.offset + query.limit)
        return .init(total: matches.count, nextOffset: end < matches.count ? end : nil, parts: Array(matches[query.offset..<end]))
    }
    static func ranked<T>(_ items: [T], part: (T) -> EDALibraryPart, query: EDALibraryQuery,
                          cancelled: @Sendable () -> Bool) throws -> [T] {
        guard query.text.utf8.count <= 1_024, query.offset >= 0, (1...200).contains(query.limit), items.count <= 100_000 else { throw EDAError.invalid("library query limits") }
        guard !cancelled() else { throw EDAError.cancelled }
        func fold(_ text: String) -> String { text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
        func identifier(_ text: String) -> String { String(fold(text).unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }) }
        let tokens = fold(query.text).split(whereSeparator: \.isWhitespace).map(String.init)
        var matches: [(score: Int, index: Int, name: String, item: T)] = []
        for (index, item) in items.enumerated() {
            if index.isMultiple(of: 128), cancelled() { throw EDAError.cancelled }
            let value = part(item)
            if let category = query.category, value.category != category { continue }
            if let manufacturer = query.manufacturer, fold(value.manufacturer) != fold(manufacturer) { continue }
            if let count = query.pinCount, value.pinCount != count { continue }
            if let footprint = query.footprint, !fold(value.footprint?.name ?? "").contains(fold(footprint)) { continue }
            let identifiers = [value.id, value.name, value.footprint?.name ?? ""] + value.aliases
            let haystack = fold((identifiers + [value.manufacturer, value.category]
                + value.parameters.sorted { $0.key < $1.key }.flatMap { [$0.key, $0.value] }).joined(separator: " "))
            guard tokens.allSatisfy({ token in haystack.contains(token) || (!identifier(token).isEmpty && identifiers.contains { identifier($0).contains(identifier(token)) }) }) else { continue }
            let score = fold(value.name) == fold(query.text) ? 0 : fold(value.name).hasPrefix(fold(query.text)) ? 1 : 2
            matches.append((score, index, value.name, item))
        }
        matches.sort {
            if $0.score != $1.score { return $0.score < $1.score }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.index < $1.index : order == .orderedAscending
        }
        return matches.map(\.item)
    }
}
