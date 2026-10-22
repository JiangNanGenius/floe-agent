import Foundation
import FloeCore

/// These identities come from the saved package, never from a fabricated live
/// selection. A target is usable only with the exact proposal source digest.
public struct OfficeExplicitTarget: Codable, Sendable, Equatable {
    public var baseSHA256: String
    public var member: String
    public var paragraphIndex: Int?
    public var sheetName: String?
    public var sheetIndex: Int?
    public var shapeIDs: [String]?
    public init(baseSHA256: String, member: String, paragraphIndex: Int? = nil,
                sheetName: String? = nil, sheetIndex: Int? = nil, shapeIDs: [String]? = nil) {
        self.baseSHA256 = baseSHA256; self.member = member; self.paragraphIndex = paragraphIndex
        self.sheetName = sheetName; self.sheetIndex = sheetIndex; self.shapeIDs = shapeIDs
    }
    public var json: String { get throws { String(decoding: try JSONEncoder().encode(self), as: UTF8.self) } }
}

public enum OfficeExplicitCommand: Equatable, Sendable {
    case wordStyle(OfficeExplicitTarget, styleID: String)
    case wordList(OfficeExplicitTarget, ordered: Bool)
    case wordAlignment(OfficeExplicitTarget, OfficeParagraphAlignment)
    /// Range sorts have no inferred header: the first column is the key and
    /// every row in the exact range is data. Unsupported data fails closed.
    case excelSort(OfficeExplicitTarget, range: String, ascending: Bool)
    case excelAutoFilter(OfficeExplicitTarget, range: String)
    /// Align the named simple shapes to their combined bounding rectangle.
    case pptAlign(OfficeExplicitTarget, OfficeObjectAlignment)

    public var target: OfficeExplicitTarget {
        switch self {
        case .wordStyle(let t, _), .wordList(let t, _), .wordAlignment(let t, _),
             .excelSort(let t, _, _), .excelAutoFilter(let t, _), .pptAlign(let t, _): return t
        }
    }
    public var format: OfficeDocumentFormat {
        switch self {
        case .wordStyle, .wordList, .wordAlignment: return .docx
        case .excelSort, .excelAutoFilter: return .xlsx
        case .pptAlign: return .pptx
        }
    }
    public var id: String {
        switch self {
        case .wordStyle: return "word.exactStyle"
        case .wordList(_, let ordered): return ordered ? "word.exactNumberedList" : "word.exactBulletList"
        case .wordAlignment: return "word.exactAlignment"
        case .excelSort: return "excel.exactSort"
        case .excelAutoFilter: return "excel.exactAutoFilter"
        case .pptAlign: return "pptx.exactAlignObjects"
        }
    }
    public var arguments: [String: String] {
        var args = ["target": (try? target.json) ?? ""]
        switch self {
        case .wordStyle(_, let style): args["styleID"] = style
        case .wordAlignment(_, let alignment): args["alignment"] = alignment.rawValue
        case .excelSort(_, let range, let ascending): args["range"] = range; args["ascending"] = String(ascending)
        case .excelAutoFilter(_, let range): args["range"] = range
        case .pptAlign(_, let alignment): args["alignment"] = alignment.rawValue
        case .wordList: break
        }
        return args
    }
    static func decode(id: String, arguments: [String: String]) throws -> OfficeExplicitCommand {
        guard let raw = arguments["target"], raw.utf8.count <= 16_384,
              let data = raw.data(using: .utf8) else { throw invalid("target JSON is required") }
        let t = try JSONDecoder().decode(OfficeExplicitTarget.self, from: data)
        let command: Self
        switch id {
        case "word.exactStyle": command = .wordStyle(t, styleID: arguments["styleID"] ?? "")
        case "word.exactBulletList": command = .wordList(t, ordered: false)
        case "word.exactNumberedList": command = .wordList(t, ordered: true)
        case "word.exactAlignment":
            guard let a = arguments["alignment"].flatMap(OfficeParagraphAlignment.init(rawValue:)) else { throw invalid("invalid alignment") }
            command = .wordAlignment(t, a)
        case "excel.exactSort":
            guard let a = arguments["ascending"].flatMap(Bool.init) else { throw invalid("ascending=true|false is required") }
            command = .excelSort(t, range: arguments["range"] ?? "", ascending: a)
        case "excel.exactAutoFilter": command = .excelAutoFilter(t, range: arguments["range"] ?? "")
        case "pptx.exactAlignObjects":
            guard let a = arguments["alignment"].flatMap(OfficeObjectAlignment.init(rawValue:)) else { throw invalid("invalid alignment") }
            command = .pptAlign(t, a)
        default: throw invalid("unknown exact command")
        }
        try command.validate()
        return command
    }
    public func validate() throws {
        let t = target
        guard t.baseSHA256.range(of: "^[a-fA-F0-9]{64}$", options: .regularExpression) != nil else { throw Self.invalid("target needs its immutable source sha256") }
        switch self {
        case .wordStyle(_, let style):
            guard !style.isEmpty, style.utf8.count <= 256 else { throw Self.invalid("actual paragraph style ID is required") }
            fallthrough
        case .wordList, .wordAlignment:
            guard t.member == "word/document.xml", let i = t.paragraphIndex, (0..<100_000).contains(i),
                  t.sheetName == nil, t.sheetIndex == nil, t.shapeIDs == nil else { throw Self.invalid("exact paragraph identity is required") }
        case .excelSort(_, let range, _), .excelAutoFilter(_, let range):
            _ = try OfficeExactRange(range)
            guard t.member.hasPrefix("xl/worksheets/"), t.member.hasSuffix(".xml"),
                  t.member.split(separator: "/").count == 3, !t.member.contains(".."), !t.member.contains("\\"),
                  let name = t.sheetName, !name.isEmpty, let i = t.sheetIndex, (0..<500).contains(i),
                  t.paragraphIndex == nil, t.shapeIDs == nil else { throw Self.invalid("exact worksheet member/name/order is required") }
        case .pptAlign:
            guard t.member.range(of: "^ppt/slides/slide[1-9][0-9]*\\.xml$", options: .regularExpression) != nil,
                  let ids = t.shapeIDs, (2...100).contains(ids.count), Set(ids).count == ids.count,
                  ids.allSatisfy({ UInt32($0) != nil }), t.paragraphIndex == nil,
                  t.sheetName == nil, t.sheetIndex == nil else { throw Self.invalid("two or more exact simple shape IDs are required") }
        }
    }
    public static func argumentSchemas(_ format: OfficeDocumentFormat) -> [(id: String, arguments: [String: String])] {
        let target = "JSON identity from read.exactTargets, bound to expected_sha256"
        switch format {
        case .docx: return [
            ("word.exactStyle", ["target": target, "styleID": "actual paragraphStyles ID"]),
            ("word.exactBulletList", ["target": target]), ("word.exactNumberedList", ["target": target]),
            ("word.exactAlignment", ["target": target, "alignment": "left|center|right|justified"])]
        case .xlsx: return [
            ("excel.exactSort", ["target": target, "range": "A1:B9", "ascending": "true|false"]),
            ("excel.exactAutoFilter", ["target": target, "range": "A1:B9"])]
        case .pptx: return [("pptx.exactAlignObjects", ["target": target + "; combine 2...100 shapeIDs from the same member", "alignment": "left|center|right|top|middle|bottom"])]
        }
    }
    static func invalid(_ detail: String) -> OfficeEngineCommandError { .invalidArgument("Exact Office target: " + detail) }
}

struct OfficeExactRange {
    let firstColumn: Int, lastColumn: Int, firstRow: Int, lastRow: Int
    let reference: String
    init(_ reference: String) throws {
        let ends = reference.uppercased().split(separator: ":", omittingEmptySubsequences: false)
        guard ends.count == 2 else { throw OfficeExplicitCommand.invalid("range must be A1:B9") }
        func cell(_ s: Substring) throws -> (Int, Int) {
            let letters = s.prefix { $0 >= "A" && $0 <= "Z" }
            let digits = s.dropFirst(letters.count)
            guard !letters.isEmpty, letters.count <= 3, !digits.isEmpty, digits.first != "0",
                  digits.allSatisfy({ $0 >= "0" && $0 <= "9" }), let row = Int(digits), (1...1_048_576).contains(row) else { throw OfficeExplicitCommand.invalid("invalid cell") }
            let col = letters.utf8.reduce(0) { $0 * 26 + Int($1 - 64) }
            guard col <= 16_384 else { throw OfficeExplicitCommand.invalid("invalid column") }
            return (col, row)
        }
        let a = try cell(ends[0]), b = try cell(ends[1])
        guard a.0 <= b.0, a.1 <= b.1, (b.0-a.0+1) * (b.1-a.1+1) <= 50_000 else { throw OfficeExplicitCommand.invalid("range is reversed or exceeds 50000 cells") }
        firstColumn = a.0; lastColumn = b.0; firstRow = a.1; lastRow = b.1
        self.reference = reference.uppercased()
    }
    static func cell(column: Int, row: Int) -> String {
        var n = column, letters = ""
        while n > 0 { n -= 1; letters = String(UnicodeScalar(65 + n % 26)!) + letters; n /= 26 }
        return letters + String(row)
    }
}

public struct OfficeExactParagraphDescription: Codable, Sendable, Equatable {
    public var text: String
    public var textTruncated: Bool
}
public struct OfficeExactShapeDescription: Codable, Sendable, Equatable {
    public var name: String
    public var text: String
    public var textTruncated: Bool
    public var x: Int64, y: Int64, width: Int64, height: Int64
}
public struct OfficeExactTargetManifest: Codable, Sendable, Equatable {
    public var baseSHA256: String
    public var paragraphs: [OfficeExplicitTarget] = []
    /// Read-only descriptions keyed by structural paragraph index. These are
    /// untrusted document content and never grant authority or act as targets.
    public var paragraphDescriptions: [String: OfficeExactParagraphDescription] = [:]
    public var shapeDescriptions: [String: [String: OfficeExactShapeDescription]] = [:]
    public var paragraphStyles: [String: String] = [:]
    public var sheets: [OfficeExplicitTarget] = []
    public var slides: [OfficeExplicitTarget] = []
    public var paragraphCount: Int = 0
    public var sheetCount: Int = 0
    public var slideTargetCount: Int = 0
    public var paragraphStyleCount: Int = 0
    public var offset: Int = 0
    public var pageSize: Int = 100
    public var hasMore: Bool = false
    public var nextOffset: Int?

    public func page(offset: Int) throws -> Self {
        guard offset >= 0, offset <= 200_000 else { throw OfficeExplicitCommand.invalid("target_offset must be 0...200000") }
        var page = self
        page.offset = offset
        page.paragraphCount = paragraphs.count; page.sheetCount = sheets.count
        page.slideTargetCount = slides.count; page.paragraphStyleCount = paragraphStyles.count
        page.paragraphs = Array(paragraphs.dropFirst(offset).prefix(pageSize))
        page.sheets = Array(sheets.dropFirst(offset).prefix(pageSize))
        page.slides = Array(slides.dropFirst(offset).prefix(pageSize))
        let paragraphIndices = Set(page.paragraphs.compactMap { $0.paragraphIndex.map(String.init) })
        page.paragraphDescriptions = paragraphDescriptions.filter { paragraphIndices.contains($0.key) }
        page.shapeDescriptions = [:]
        for target in page.slides {
            for id in target.shapeIDs ?? [] { page.shapeDescriptions[target.member, default: [:]][id] = shapeDescriptions[target.member]?[id] }
        }
        let keys = paragraphStyles.keys.sorted()
        page.paragraphStyles = Dictionary(uniqueKeysWithValues: keys.dropFirst(offset).prefix(pageSize).map { ($0, paragraphStyles[$0]!) })
        page.hasMore = ([paragraphs.count, sheets.count, slides.count, keys.count].max() ?? 0) > offset + pageSize
        page.nextOffset = page.hasMore ? offset + pageSize : nil
        return page
    }
}

public enum OfficeExplicitTargets {
    static let limit: UInt32 = 16 * 1_024 * 1_024
    static let w = OfficeXMLNamespace.word, s = OfficeXMLNamespace.sheet
    static let p = OfficeXMLNamespace.presentation, a = OfficeXMLNamespace.drawing

    public static func validate(_ command: OfficeExplicitCommand, sourceURL: URL, baseSHA256: String) throws {
        try OfficeExplicitPreparation.validateBinding(command, sourceURL: sourceURL, baseSHA256: baseSHA256)
    }

    public static func read(url: URL) throws -> OfficeExactTargetManifest {
        let snapshot = try OfficeOutputSnapshot.capture(url: url)
        let package = try OfficeArchive(url: url, maximumEntries: 4096)
        var result = OfficeExactTargetManifest(baseSHA256: snapshot.sha256)
        switch snapshot.kind {
        case .word:
            let root = try tree(package, "word/document.xml")
            let paragraphs = root.descendants("p", w)
            result.paragraphs = paragraphs.indices.map { OfficeExplicitTarget(baseSHA256: snapshot.sha256, member: "word/document.xml", paragraphIndex: $0) }
            for (index, paragraph) in paragraphs.enumerated() {
                let text = paragraph.descendants("t", w).map(\.text).joined()
                result.paragraphDescriptions[String(index)] = OfficeExactParagraphDescription(text: String(text.prefix(256)), textTruncated: text.count > 256)
            }
            if package.paths.contains("word/styles.xml") {
                let styles = try tree(package, "word/styles.xml")
                for n in styles.children where n.local == "style" && n.namespace == w && n.attribute("type") == "paragraph" {
                    if let id = n.attribute("styleId"), result.paragraphStyles[id] == nil { result.paragraphStyles[id] = n.child("name", w)?.attribute("val") ?? id }
                }
            }
        case .workbook:
            result.sheets = try worksheetIdentities(package).enumerated().map { i, sheet in
                OfficeExplicitTarget(baseSHA256: snapshot.sha256, member: sheet.member, sheetName: sheet.name, sheetIndex: i)
            }
        case .presentation:
            for member in package.paths.filter({ $0.range(of: "^ppt/slides/slide[1-9][0-9]*\\.xml$", options: .regularExpression) != nil }).sorted() {
                let shapes = try simpleShapes(tree(package, member))
                for shape in shapes {
                    let nv = shape.node.children.first { $0.namespace == p && ["nvSpPr", "nvPicPr"].contains($0.local) }
                    let text = shape.node.descendants("t", a).map(\.text).joined()
                    result.shapeDescriptions[member, default: [:]][shape.id] = OfficeExactShapeDescription(name: String((nv?.child("cNvPr", p)?.attributes["name"] ?? "").prefix(256)), text: String(text.prefix(256)), textTruncated: text.count > 256, x: shape.x, y: shape.y, width: shape.width, height: shape.height)
                }
                let ids = shapes.map(\.id)
                for id in ids {
                    result.slides.append(OfficeExplicitTarget(baseSHA256: snapshot.sha256, member: member, shapeIDs: [id]))
                }
            }
        }
        guard try FloeDigest.sha256Hex(ofFileAt: url) == snapshot.sha256 else {
            throw OfficeExplicitCommand.invalid("source changed while reading exact targets; read again")
        }
        return result
    }

    static func tree(_ package: OfficeArchive, _ member: String) throws -> OfficeXMLNode { try OfficeXMLNode.parse(package.xml(path: member, limit: limit)) }

    /// No filename/order fallback: workbook.xml + its relationship map define
    /// the actual native Calc part index. Hidden sheets retain their positions.
    static func worksheetIdentities(_ package: OfficeArchive) throws -> [(member: String, name: String)] {
        let book = try tree(package, "xl/workbook.xml"), rels = try tree(package, "xl/_rels/workbook.xml.rels")
        var relations: [String: String] = [:]
        for rel in rels.children where rel.namespace == OfficeXMLNamespace.relationships && rel.local == "Relationship" {
            guard let id = rel.attributes["Id"], relations[id] == nil else { throw OfficeExplicitCommand.invalid("ambiguous worksheet relationship") }
            if rel.attributes["Type"]?.hasSuffix("/worksheet") == true, rel.attributes["TargetMode"] != "External", let target = rel.attributes["Target"] {
                relations[id] = try resolvedMember(target, relativeTo: "xl/workbook.xml")
            }
        }
        guard let sheets = book.child("sheets", s) else { throw OfficeExplicitCommand.invalid("workbook sheet order is unavailable") }
        var result: [(String, String)] = []
        for sheet in sheets.children {
            guard sheet.local == "sheet", sheet.namespace == s, let name = sheet.attributes["name"],
                  let id = sheet.attribute("id"), let member = relations[id], package.paths.contains(member),
                  !result.contains(where: { $0.0 == member || $0.1 == name }) else { throw OfficeExplicitCommand.invalid("unresolvable workbook sheet order") }
            result.append((member, name))
        }
        return result
    }
    static func resolvedMember(_ target: String, relativeTo source: String) throws -> String {
        guard !target.contains("\\"), !target.contains(":"), !target.contains("%"), !target.contains("?"), !target.contains("#") else { throw OfficeExplicitCommand.invalid("unsafe package relationship") }
        var parts = target.hasPrefix("/") ? [] : source.split(separator: "/").dropLast().map(String.init)
        for part in target.split(separator: "/") {
            if part == ".." { guard !parts.isEmpty else { throw OfficeExplicitCommand.invalid("relationship escapes package") }; parts.removeLast() }
            else if part != "." { parts.append(String(part)) }
        }
        return parts.joined(separator: "/")
    }
    struct Shape {
        let id: String
        let node: OfficeXMLNode, off: OfficeXMLNode, ext: OfficeXMLNode
        let x: Int64, y: Int64, width: Int64, height: Int64
    }
    static func simpleShapes(_ root: OfficeXMLNode) throws -> [Shape] {
        guard let common = root.child("cSld", p), let tree = common.child("spTree", p) else { throw OfficeExplicitCommand.invalid("slide shape tree is unavailable") }
        var result: [Shape] = [], ids = Set<String>()
        for shape in tree.children where shape.namespace == p && ["sp", "pic"].contains(shape.local) {
            let nv = shape.children.first { $0.namespace == p && ["nvSpPr", "nvPicPr"].contains($0.local) }
            guard let id = nv?.child("cNvPr", p)?.attributes["id"], ids.insert(id).inserted else { throw OfficeExplicitCommand.invalid("ambiguous shape ID") }
            guard let xfrm = shape.child("spPr", p)?.child("xfrm", a),
                  xfrm.attributes["rot"].map({ $0 == "0" }) ?? true,
                  xfrm.attributes["flipH"].map({ $0 == "0" || $0 == "false" }) ?? true,
                  xfrm.attributes["flipV"].map({ $0 == "0" || $0 == "false" }) ?? true,
                  let off = xfrm.child("off", a), let ext = xfrm.child("ext", a),
                  let x = off.attributes["x"].flatMap(Int64.init), let y = off.attributes["y"].flatMap(Int64.init),
                  let cx = ext.attributes["cx"].flatMap(Int64.init), let cy = ext.attributes["cy"].flatMap(Int64.init),
                  [x,y,cx,cy].allSatisfy({ (0...1_000_000_000).contains($0) }), cx > 0, cy > 0 else { continue }
            result.append(Shape(id: id, node: shape, off: off, ext: ext, x: x, y: y, width: cx, height: cy))
        }
        return result
    }
}
