// FloeDocuments — bounded native Office Open XML inspection and editing.

import Foundation
import ZIPFoundation
import FloeCore

public enum OfficeDocumentKind: String, Codable, Sendable, CaseIterable {
    case word = "docx"
    case workbook = "xlsx"
    case presentation = "pptx"

    public init?(url: URL) {
        self.init(rawValue: url.pathExtension.lowercased())
    }
}

/// A user- or model-editable text surface inside an OOXML package. The stable
/// identifier addresses an archive member and an ordinal/cell reference; it
/// never contains raw document content.
public struct OfficeEditableField: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var section: String
    public var label: String
    public var text: String

    public init(id: String, section: String, label: String, text: String) {
        self.id = id
        self.section = section
        self.label = label
        self.text = text
    }
}

public struct OfficeDocumentSnapshot: Codable, Sendable, Equatable {
    public var kind: OfficeDocumentKind
    public var fields: [OfficeEditableField]
    public var packageEntries: Int
    public var packageBytes: Int64

    public init(
        kind: OfficeDocumentKind,
        fields: [OfficeEditableField],
        packageEntries: Int,
        packageBytes: Int64
    ) {
        self.kind = kind
        self.fields = fields
        self.packageEntries = packageEntries
        self.packageBytes = packageBytes
    }
}

public enum OfficeDocumentError: LocalizedError, Sendable {
    case unsupportedFormat
    case packageTooLarge
    case tooManyEntries
    case unsafeEntry(String)
    case oversizedEntry(String)
    case missingEntry(String)
    case invalidXML(String)
    case unknownField(String)
    case emptyDocument

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "Only .docx, .xlsx, and .pptx are supported"
        case .packageTooLarge: "Office document exceeds the 128 MiB safety limit"
        case .tooManyEntries: "Office package contains too many archive members"
        case .unsafeEntry(let path): "Office package contains an unsafe path: \(path)"
        case .oversizedEntry(let path): "Office package member is too large: \(path)"
        case .missingEntry(let path): "Office package is missing \(path)"
        case .invalidXML(let path): "Office package contains invalid XML in \(path)"
        case .unknownField(let field): "Office edit refers to an unknown field: \(field)"
        case .emptyDocument: "Office document has no editable text or cells"
        }
    }
}

/// Native OOXML text/cell service shared by model tools and the manual editor.
/// It rewrites only selected XML members and streams every other archive member
/// unchanged into a new atomic package, preserving themes, media and relations.
public enum OfficeDocumentService {
    private static let maximumArchiveBytes: Int64 = 128 * 1_024 * 1_024
    private static let maximumEntries = 4_096
    private static let maximumMemberBytes: UInt32 = 64 * 1_024 * 1_024
    private static let maximumXMLBytes: UInt32 = 16 * 1_024 * 1_024
    private static let maximumFields = 20_000

    public static func inspect(url: URL) throws -> OfficeDocumentSnapshot {
        guard let kind = OfficeDocumentKind(url: url) else {
            throw OfficeDocumentError.unsupportedFormat
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw OfficeDocumentError.unsupportedFormat }
        guard Int64(values.fileSize ?? 0) <= maximumArchiveBytes else {
            throw OfficeDocumentError.packageTooLarge
        }
        let package = try OfficeArchive(url: url, maximumEntries: maximumEntries)
        var fields: [OfficeEditableField] = []
        switch kind {
        case .word:
            let members = package.paths.filter {
                $0 == "word/document.xml"
                    || $0.hasPrefix("word/header") && $0.hasSuffix(".xml")
                    || $0.hasPrefix("word/footer") && $0.hasSuffix(".xml")
            }.sorted(by: OfficePathOrder.less)
            guard members.contains("word/document.xml") else {
                throw OfficeDocumentError.missingEntry("word/document.xml")
            }
            for member in members {
                let xml = try package.xml(path: member, limit: maximumXMLBytes)
                fields.append(contentsOf: XMLTextCodec.fields(
                    source: xml,
                    entry: member,
                    paragraphTag: "w:p",
                    textTag: "w:t",
                    section: member == "word/document.xml" ? "Document" : member
                ))
            }
        case .presentation:
            let members = package.paths.filter {
                ($0.hasPrefix("ppt/slides/slide") || $0.hasPrefix("ppt/notesSlides/notesSlide"))
                    && $0.hasSuffix(".xml")
                    && !$0.contains("/_rels/")
            }.sorted(by: OfficePathOrder.less)
            guard members.contains(where: { $0.hasPrefix("ppt/slides/slide") }) else {
                throw OfficeDocumentError.missingEntry("ppt/slides/slide1.xml")
            }
            for member in members {
                let xml = try package.xml(path: member, limit: maximumXMLBytes)
                let section = member.contains("notesSlides")
                    ? "Notes \(OfficePathOrder.trailingNumber(member) ?? 0)"
                    : "Slide \(OfficePathOrder.trailingNumber(member) ?? 0)"
                fields.append(contentsOf: XMLTextCodec.fields(
                    source: xml,
                    entry: member,
                    paragraphTag: "a:p",
                    textTag: "a:t",
                    section: section
                ))
            }
        case .workbook:
            let shared = try SharedStringTable.load(from: package, limit: maximumXMLBytes)
            let members = package.paths.filter {
                $0.hasPrefix("xl/worksheets/sheet")
                    && $0.hasSuffix(".xml")
                    && !$0.contains("/_rels/")
            }.sorted(by: OfficePathOrder.less)
            guard !members.isEmpty else {
                throw OfficeDocumentError.missingEntry("xl/worksheets/sheet1.xml")
            }
            for member in members {
                let xml = try package.xml(path: member, limit: maximumXMLBytes)
                fields.append(contentsOf: XLSXCellCodec.fields(
                    source: xml,
                    entry: member,
                    sharedStrings: shared,
                    section: "Sheet \(OfficePathOrder.trailingNumber(member) ?? 0)"
                ))
            }
        }
        if fields.count > maximumFields {
            fields = Array(fields.prefix(maximumFields))
        }
        return OfficeDocumentSnapshot(
            kind: kind,
            fields: fields,
            packageEntries: package.paths.count,
            packageBytes: Int64(values.fileSize ?? 0)
        )
    }

    /// Applies exact field updates. Unknown/stale IDs fail closed so a model or
    /// UI cannot accidentally edit a different package revision.
    @discardableResult
    public static func update(
        sourceURL: URL,
        outputURL: URL? = nil,
        updates: [String: String]
    ) throws -> OfficeDocumentSnapshot {
        let current = try inspect(url: sourceURL)
        let known = Set(current.fields.map(\.id))
        if let unknown = updates.keys.first(where: { !known.contains($0) }) {
            throw OfficeDocumentError.unknownField(unknown)
        }
        guard !updates.isEmpty else { return current }
        let destination = outputURL ?? sourceURL
        let package = try OfficeArchive(url: sourceURL, maximumEntries: maximumEntries)
        var rewritten: [String: Data] = [:]
        let entries = Set(updates.keys.compactMap { $0.split(separator: "|", maxSplits: 1).first.map(String.init) })
        for entry in entries {
            let source = try package.xml(path: entry, limit: maximumXMLBytes)
            let result: String
            switch current.kind {
            case .word:
                result = try XMLTextCodec.rewrite(
                    source: source, entry: entry, paragraphTag: "w:p", textTag: "w:t", updates: updates
                )
            case .presentation:
                result = try XMLTextCodec.rewrite(
                    source: source, entry: entry, paragraphTag: "a:p", textTag: "a:t", updates: updates
                )
            case .workbook:
                result = try XLSXCellCodec.rewrite(source: source, entry: entry, updates: updates)
            }
            rewritten[entry] = Data(result.utf8)
        }
        try package.writeCopy(
            to: destination,
            replacements: rewritten,
            maximumMemberBytes: maximumMemberBytes,
            maximumTotalBytes: 256 * 1_024 * 1_024
        )
        return try inspect(url: destination)
    }
}

private struct OfficeArchive {
    let url: URL
    let archive: Archive
    let paths: [String]

    init(url: URL, maximumEntries: Int) throws {
        self.url = url
        self.archive = try Archive(url: url, accessMode: .read)
        var discovered: [String] = []
        for entry in archive {
            guard discovered.count < maximumEntries else { throw OfficeDocumentError.tooManyEntries }
            guard Self.isSafe(path: entry.path) else { throw OfficeDocumentError.unsafeEntry(entry.path) }
            discovered.append(entry.path)
        }
        self.paths = discovered
    }

    func xml(path: String, limit: UInt32) throws -> String {
        let data = try data(path: path, limit: limit)
        guard !data.contains(Data("<!DOCTYPE".utf8)),
              !data.contains(Data("<!ENTITY".utf8)),
              let value = String(data: data, encoding: .utf8) else {
            throw OfficeDocumentError.invalidXML(path)
        }
        return value
    }

    func data(path: String, limit: UInt32) throws -> Data {
        guard let entry = archive[path] else { throw OfficeDocumentError.missingEntry(path) }
        guard entry.uncompressedSize <= limit else { throw OfficeDocumentError.oversizedEntry(path) }
        var result = Data()
        result.reserveCapacity(Int(entry.uncompressedSize))
        _ = try archive.extract(entry) { chunk in
            guard result.count <= Int(limit) - chunk.count else {
                throw OfficeDocumentError.oversizedEntry(path)
            }
            result.append(chunk)
        }
        return result
    }

    func writeCopy(
        to destination: URL,
        replacements: [String: Data],
        maximumMemberBytes: UInt32,
        maximumTotalBytes: Int
    ) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".floe-office-\(UUID().uuidString).tmp")
        defer { try? manager.removeItem(at: temporary) }
        let output = try Archive(url: temporary, accessMode: .create)
        var total = 0
        for entry in archive {
            guard entry.type == .file else { continue }
            let bytes: Data
            if let replacement = replacements[entry.path] {
                bytes = replacement
            } else {
                guard entry.uncompressedSize <= maximumMemberBytes else {
                    throw OfficeDocumentError.oversizedEntry(entry.path)
                }
                bytes = try data(path: entry.path, limit: maximumMemberBytes)
            }
            total += bytes.count
            guard total <= maximumTotalBytes else { throw OfficeDocumentError.packageTooLarge }
            try output.addFloeEntry(path: entry.path, data: bytes)
        }
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try manager.moveItem(at: temporary, to: destination)
        }
    }

    private static func isSafe(path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }
}

extension Archive {
    func addFloeEntry(path: String, data: Data) throws {
        try addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: .deflate,
            provider: { position, size in
                let start = Int(position)
                return data.subdata(in: start..<(start + size))
            }
        )
    }
}

private enum OfficePathOrder {
    static func trailingNumber(_ path: String) -> Int? {
        let stem = (path as NSString).deletingPathExtension
        let digits = stem.reversed().prefix(while: \.isNumber).reversed()
        return Int(String(digits))
    }

    static func less(_ lhs: String, _ rhs: String) -> Bool {
        let left = trailingNumber(lhs) ?? 0
        let right = trailingNumber(rhs) ?? 0
        return left == right ? lhs < rhs : left < right
    }
}

private enum XMLTextCodec {
    static func fields(
        source: String,
        entry: String,
        paragraphTag: String,
        textTag: String,
        section: String
    ) -> [OfficeEditableField] {
        elementRanges(source, tag: paragraphTag).enumerated().compactMap { index, range in
            let block = String(source[range])
            let text = textContents(block, tag: textTag).joined()
            guard !text.isEmpty else { return nil }
            return OfficeEditableField(
                id: "\(entry)|p|\(index)",
                section: section,
                label: "Text \(index + 1)",
                text: text
            )
        }
    }

    static func rewrite(
        source: String,
        entry: String,
        paragraphTag: String,
        textTag: String,
        updates: [String: String]
    ) throws -> String {
        var output = source
        let ranges = elementRanges(source, tag: paragraphTag)
        for (index, range) in ranges.enumerated().reversed() {
            let id = "\(entry)|p|\(index)"
            guard let replacement = updates[id] else { continue }
            let original = String(source[range])
            let rewritten = replaceTextContents(original, tag: textTag, text: replacement)
            output.replaceSubrange(range, with: rewritten)
        }
        return output
    }

    static func elementRanges(_ source: String, tag: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var cursor = source.startIndex
        let opener = "<\(tag)"
        let closer = "</\(tag)>"
        while let candidate = source.range(of: opener, range: cursor..<source.endIndex) {
            let boundary = candidate.upperBound
            if boundary < source.endIndex {
                let scalar = source[boundary]
                guard scalar == ">" || scalar == "/" || scalar.isWhitespace else {
                    cursor = boundary
                    continue
                }
            }
            guard let openEnd = source[candidate.lowerBound...].firstIndex(of: ">"),
                  let close = source.range(of: closer, range: source.index(after: openEnd)..<source.endIndex)
            else { break }
            let end = close.upperBound
            ranges.append(candidate.lowerBound..<end)
            cursor = end
        }
        return ranges
    }

    static func textContents(_ source: String, tag: String) -> [String] {
        elementRanges(source, tag: tag).compactMap { range in
            let element = source[range]
            guard let openEnd = element.firstIndex(of: ">"),
                  let closeStart = element.range(of: "</\(tag)>")?.lowerBound else { return nil }
            return XMLText.unescape(String(element[element.index(after: openEnd)..<closeStart]))
        }
    }

    static func replaceTextContents(_ source: String, tag: String, text: String) -> String {
        let ranges = elementRanges(source, tag: tag)
        guard !ranges.isEmpty else { return source }
        var output = source
        for (offset, range) in ranges.enumerated().reversed() {
            let element = source[range]
            guard let openEnd = element.firstIndex(of: ">"),
                  let close = element.range(of: "</\(tag)>") else { continue }
            let contentRange = element.index(after: openEnd)..<close.lowerBound
            let absoluteStart = source.index(range.lowerBound, offsetBy: element.distance(from: element.startIndex, to: contentRange.lowerBound))
            let absoluteEnd = source.index(range.lowerBound, offsetBy: element.distance(from: element.startIndex, to: contentRange.upperBound))
            output.replaceSubrange(absoluteStart..<absoluteEnd, with: offset == 0 ? XMLText.escape(text) : "")
        }
        return output
    }
}

private enum XLSXCellCodec {
    static func fields(
        source: String,
        entry: String,
        sharedStrings: [String],
        section: String
    ) -> [OfficeEditableField] {
        XMLTextCodec.elementRanges(source, tag: "c").compactMap { range in
            let cell = String(source[range])
            guard let reference = XMLText.attribute("r", inOpeningElement: cell) else { return nil }
            let type = XMLText.attribute("t", inOpeningElement: cell)
            let formula = XMLTextCodec.textContents(cell, tag: "f").first
            let value: String
            if let formula, !formula.isEmpty {
                value = "=" + formula
            } else if type == "s",
                      let raw = XMLTextCodec.textContents(cell, tag: "v").first,
                      let index = Int(raw), sharedStrings.indices.contains(index) {
                value = sharedStrings[index]
            } else if type == "inlineStr" {
                value = XMLTextCodec.textContents(cell, tag: "t").joined()
            } else {
                value = XMLTextCodec.textContents(cell, tag: "v").first ?? ""
            }
            return OfficeEditableField(
                id: "\(entry)|c|\(reference)", section: section, label: reference, text: value
            )
        }
    }

    static func rewrite(source: String, entry: String, updates: [String: String]) throws -> String {
        var output = source
        let ranges = XMLTextCodec.elementRanges(source, tag: "c")
        for range in ranges.reversed() {
            let cell = String(source[range])
            guard let reference = XMLText.attribute("r", inOpeningElement: cell),
                  let value = updates["\(entry)|c|\(reference)"] else { continue }
            let style = XMLText.attribute("s", inOpeningElement: cell)
                .map { " s=\"\(XMLText.escapeAttribute($0))\"" } ?? ""
            let replacement: String
            if value.hasPrefix("=") {
                replacement = "<c r=\"\(XMLText.escapeAttribute(reference))\"\(style)><f>\(XMLText.escape(String(value.dropFirst())))</f></c>"
            } else if Double(value) != nil, !value.trimmingCharacters(in: .whitespaces).isEmpty {
                replacement = "<c r=\"\(XMLText.escapeAttribute(reference))\"\(style)><v>\(XMLText.escape(value))</v></c>"
            } else {
                replacement = "<c r=\"\(XMLText.escapeAttribute(reference))\"\(style) t=\"inlineStr\"><is><t xml:space=\"preserve\">\(XMLText.escape(value))</t></is></c>"
            }
            output.replaceSubrange(range, with: replacement)
        }
        return output
    }
}

private enum SharedStringTable {
    static func load(from package: OfficeArchive, limit: UInt32) throws -> [String] {
        guard package.paths.contains("xl/sharedStrings.xml") else { return [] }
        let xml = try package.xml(path: "xl/sharedStrings.xml", limit: limit)
        return XMLTextCodec.elementRanges(xml, tag: "si").map { range in
            XMLTextCodec.textContents(String(xml[range]), tag: "t").joined()
        }
    }
}

enum XMLText {
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func escapeAttribute(_ value: String) -> String {
        escape(value).replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    static func unescape(_ value: String) -> String {
        value.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    static func attribute(_ name: String, inOpeningElement element: String) -> String? {
        guard let end = element.firstIndex(of: ">") else { return nil }
        let opening = element[..<end]
        for quote in ["\"", "'"] {
            let marker = "\(name)=\(quote)"
            guard let start = opening.range(of: marker) else { continue }
            let valueStart = start.upperBound
            guard let valueEnd = opening[valueStart...].firstIndex(of: Character(quote)) else { continue }
            return unescape(String(opening[valueStart..<valueEnd]))
        }
        return nil
    }
}
