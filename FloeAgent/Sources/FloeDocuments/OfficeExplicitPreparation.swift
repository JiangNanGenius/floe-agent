import Foundation
import FloeCore

/// Normalizes ONLY an isolated, authorized working copy. Package preparations
/// never dispatch a no-op command and claim it edited the native document: the
/// caller must open, save, close, reopen and verify the resulting package.
enum OfficeExplicitPreparation {
    struct Verification {
        let key: String
        let member: String
        let command: OfficeExplicitCommand
        let expected: [String: String]
        let unchangedParagraphText: [String]?
    }
    struct Prepared {
        let engineCommands: [OfficeEngineCommand]
        let verification: Verification
    }
    static let w = OfficeXMLNamespace.word, s = OfficeXMLNamespace.sheet
    static let a = OfficeXMLNamespace.drawing, p = OfficeXMLNamespace.presentation

    static func validateBinding(_ command: OfficeExplicitCommand, sourceURL: URL, baseSHA256: String) throws {
        try command.validate()
        guard command.target.baseSHA256.lowercased() == baseSHA256.lowercased() else { throw OfficeDocumentError.revisionConflict }
        let manifest = try OfficeExplicitTargets.read(url: sourceURL)
        guard manifest.baseSHA256.lowercased() == baseSHA256.lowercased() else { throw OfficeDocumentError.revisionConflict }
        switch command {
        case .wordStyle(let t, let style):
            guard manifest.paragraphs.contains(t), manifest.paragraphStyles[style] != nil else { throw invalid("paragraph or actual style is absent") }
        case .wordList(let t, _), .wordAlignment(let t, _):
            guard manifest.paragraphs.contains(t) else { throw invalid("paragraph is absent") }
        case .excelSort(let t, _, _), .excelAutoFilter(let t, _):
            guard manifest.sheets.contains(t) else { throw invalid("worksheet identity/order changed") }
        case .pptAlign(let t, _):
            let actualIDs = Set(manifest.slides.filter { $0.member == t.member }.flatMap { $0.shapeIDs ?? [] })
            guard let ids = t.shapeIDs, ids.allSatisfy({ actualIDs.contains($0) }) else { throw invalid("shape is absent, grouped, rotated, or has unsupported geometry") }
        }
    }

    static func prepare(_ command: OfficeExplicitCommand, workingURL: URL, sourceURL: URL,
                        baseSHA256: String) throws -> Prepared {
        try validateBinding(command, sourceURL: sourceURL, baseSHA256: baseSHA256)
        let package = try OfficeArchive(url: workingURL, maximumEntries: 4096)
        let t = command.target
        let root = try OfficeExplicitTargets.tree(package, t.member)
        var replacements: [String: Data] = [:]
        var expected: [String: String] = [:]
        var texts: [String]?
        var engine: [OfficeEngineCommand] = []
        let key: String
        switch command {
        case .wordStyle, .wordList, .wordAlignment:
            let paragraphs = root.descendants("p", w)
            let original = try OfficeExplicitTargets.tree(OfficeArchive(url: sourceURL, maximumEntries: 4096), t.member).descendants("p", w)
            guard let index = t.paragraphIndex, index < paragraphs.count,
                  paragraphs.count == original.count,
                  zip(paragraphs, original).allSatisfy({ paragraphText($0.0) == paragraphText($0.1) }) else { throw invalid("paragraph structure changed before its exact edit") }
            texts = paragraphs.map(paragraphText)
            let paragraph = paragraphs[index]
            let properties = paragraph.child("pPr", w) ?? word("pPr")
            if paragraph.child("pPr", w) == nil { paragraph.replace("pPr", w, with: properties, first: true) }
            switch command {
            case .wordStyle(_, let style):
                let styles = try OfficeExplicitTargets.tree(package, "word/styles.xml")
                guard styles.children.contains(where: { $0.local == "style" && $0.namespace == w && $0.attribute("styleId") == style && $0.attribute("type") == "paragraph" }) else { throw invalid("style disappeared from working copy") }
                properties.replace("pStyle", w, with: word("pStyle", ["w:val": style]), first: true)
                expected["style"] = style
            case .wordAlignment(_, let alignment):
                let value = alignment == .justified ? "both" : alignment.rawValue
                properties.replace("jc", w, with: word("jc", ["w:val": value]))
                expected["alignment"] = value
            case .wordList(_, let ordered):
                let numbering = package.paths.contains("word/numbering.xml")
                    ? try OfficeExplicitTargets.tree(package, "word/numbering.xml") : word("numbering")
                let abstractID = try nextID(numbering.children.filter { $0.local == "abstractNum" }.compactMap { $0.attribute("abstractNumId") })
                let numID = try nextID(numbering.children.filter { $0.local == "num" }.compactMap { $0.attribute("numId") })
                let abstract = word("abstractNum", ["w:abstractNumId": String(abstractID)])
                abstract.append(word("multiLevelType", ["w:val": "singleLevel"]))
                let level = word("lvl", ["w:ilvl": "0"])
                level.append(word("start", ["w:val": "1"]))
                level.append(word("numFmt", ["w:val": ordered ? "decimal" : "bullet"]))
                level.append(word("lvlText", ["w:val": ordered ? "%1." : "•"]))
                level.append(word("lvlJc", ["w:val": "left"]))
                abstract.append(level)
                // abstractNum precedes num in the numbering content model.
                if let firstNum = numbering.content.firstIndex(where: { if case .node(let n) = $0 { return n.local == "num" && n.namespace == w }; return false }) { numbering.content.insert(.node(abstract), at: firstNum) }
                else { numbering.append(abstract) }
                let num = word("num", ["w:numId": String(numID)])
                num.append(word("abstractNumId", ["w:val": String(abstractID)])); numbering.append(num)
                replacements["word/numbering.xml"] = Data(numbering.xml.utf8)
                try ensureNumberingParts(package, replacements: &replacements)
                let numPr = word("numPr")
                numPr.append(word("ilvl", ["w:val": "0"])); numPr.append(word("numId", ["w:val": String(numID)]))
                properties.replace("numPr", w, with: numPr)
                expected["list"] = ordered ? "decimal" : "bullet"
            default: break
            }
            // Keep the relevant pPr children in schema order; unrelated
            // children keep their relative order and contents.
            orderParagraphProperties(properties)
            expected["paragraphProperties"] = try json(paragraphs.enumerated().filter { $0.offset != index }.map { paragraphProperties($0.element) })
            replacements[t.member] = Data(root.xml.utf8)
            key = "\(t.member):paragraph:\(index):\(expected.keys.sorted().joined())"
        case .excelSort(_, let reference, let ascending):
            try validateSheet(command, package: package)
            let range = try OfficeExactRange(reference)
            let rows = try matrix(package: package, sheet: root, range: range)
            let keys = rows.map { $0.first ?? "" }
            let numeric = keys.compactMap(Double.init)
            guard !keys.contains(""), numeric.isEmpty || numeric.count == keys.count,
                  numeric.allSatisfy(\.isFinite), Set(keys).count == keys.count else { throw invalid("sort supports unique homogeneous numeric or text keys without blank/header inference") }
            let indices = rows.indices.sorted { i, j in
                let less = numeric.count == keys.count ? numeric[i] < numeric[j] : keys[i] < keys[j]
                return ascending ? less : !less
            }
            expected["matrix"] = try json(indices.map { rows[$0] })
            expected["outside"] = try json(try cellsOutside(package: package, sheet: root, range: range))
            engine = [.explicit(command)]
            key = "\(t.member):sort:\(range.reference)"
        case .excelAutoFilter(_, let reference):
            try validateSheet(command, package: package)
            let range = try OfficeExactRange(reference)
            // Toggling an existing filter (possibly on another range) is not
            // equivalent to creating the requested one: refuse that ambiguity.
            guard root.child("autoFilter", s) == nil else { throw invalid("worksheet already has an AutoFilter; exact creation would toggle or replace it") }
            expected["filter"] = range.reference
            engine = [.explicit(command)]
            key = "\(t.member):filter"
        case .pptAlign(_, let alignment):
            let all = try OfficeExplicitTargets.simpleShapes(root)
            let ids = Set(t.shapeIDs ?? [])
            let shapes = all.filter { ids.contains($0.id) }
            guard shapes.count == ids.count, let minX = shapes.map(\.x).min(), let minY = shapes.map(\.y).min(),
                  let maxX = shapes.map({ $0.x + $0.width }).max(), let maxY = shapes.map({ $0.y + $0.height }).max() else { throw invalid("shape geometry changed") }
            for shape in shapes {
                var x = shape.x, y = shape.y
                switch alignment {
                case .left: x = minX
                case .center: x = minX + (maxX - minX - shape.width) / 2
                case .right: x = maxX - shape.width
                case .top: y = minY
                case .middle: y = minY + (maxY - minY - shape.height) / 2
                case .bottom: y = maxY - shape.height
                }
                shape.off.attributes["x"] = String(x); shape.off.attributes["y"] = String(y)
            }
            // Verify all supported shapes, including the untouched ones.
            for shape in try OfficeExplicitTargets.simpleShapes(root) { expected[shape.id] = geometry(shape) }
            replacements[t.member] = Data(root.xml.utf8)
            key = "\(t.member):geometry"
        }
        let verification = Verification(key: key, member: t.member, command: command, expected: expected, unchangedParagraphText: texts)
        if !replacements.isEmpty {
            try package.writeCopy(to: workingURL, replacements: replacements, maximumMemberBytes: OfficeExplicitTargets.limit,
                                  maximumTotalBytes: 128 * 1_024 * 1_024, verify: { try verify(verification, url: $0) })
        }
        return Prepared(engineCommands: engine, verification: verification)
    }

    static func verify(_ v: Verification, url: URL, verifyUntouched: Bool = true) throws {
        let package = try OfficeArchive(url: url, maximumEntries: 4096)
        let root = try OfficeExplicitTargets.tree(package, v.member)
        let t = v.command.target
        switch v.command {
        case .wordStyle, .wordList, .wordAlignment:
            let paragraphs = root.descendants("p", w)
            guard let i = t.paragraphIndex, i < paragraphs.count,
                  paragraphs.map(paragraphText) == v.unchangedParagraphText,
                  let props = paragraphs[i].child("pPr", w) else { throw invalid("saved paragraph identity/text changed") }
            if verifyUntouched, let properties = v.expected["paragraphProperties"], try json(paragraphs.enumerated().filter { $0.offset != i }.map { paragraphProperties($0.element) }) != properties {
                throw invalid("saved paragraph formatting changed outside the prepared properties")
            }
            if let style = v.expected["style"], props.child("pStyle", w)?.attribute("val") != style { throw invalid("saved exact style differs") }
            if let alignment = v.expected["alignment"], props.child("jc", w)?.attribute("val") != alignment { throw invalid("saved exact alignment differs") }
            if let format = v.expected["list"] {
                guard let numID = props.child("numPr", w)?.child("numId", w)?.attribute("val") else { throw invalid("saved exact list is absent") }
                let numbering = try OfficeExplicitTargets.tree(package, "word/numbering.xml")
                guard let num = numbering.children.first(where: { $0.local == "num" && $0.namespace == w && $0.attribute("numId") == numID }),
                      let abstractID = num.child("abstractNumId", w)?.attribute("val"),
                      let abstract = numbering.children.first(where: { $0.local == "abstractNum" && $0.namespace == w && $0.attribute("abstractNumId") == abstractID }),
                      let level = abstract.children.first(where: { $0.local == "lvl" && $0.namespace == w && $0.attribute("ilvl") == "0" }),
                      level.child("numFmt", w)?.attribute("val") == format else { throw invalid("saved list does not resolve to its numbering definition") }
            }
        case .excelSort(_, let reference, _):
            try validateSheet(v.command, package: package)
            let range = try OfficeExactRange(reference)
            guard try json(matrix(package: package, sheet: root, range: range)) == v.expected["matrix"] else { throw invalid("saved exact range is not the requested full-row sort") }
            if verifyUntouched, try json(cellsOutside(package: package, sheet: root, range: range)) != v.expected["outside"] { throw invalid("cells outside the exact sort range changed") }
        case .excelAutoFilter:
            try validateSheet(v.command, package: package)
            guard root.child("autoFilter", s)?.attributes["ref"]?.uppercased() == v.expected["filter"] else { throw invalid("saved AutoFilter is absent or points to another range") }
        case .pptAlign:
            let actual = Dictionary(uniqueKeysWithValues: try OfficeExplicitTargets.simpleShapes(root).map { ($0.id, geometry($0)) })
            guard actual == v.expected else { throw invalid("saved exact shape geometry differs or an untouched shape moved") }
        }
    }

    static func enginePlan(_ command: OfficeExplicitCommand) -> OfficeDispatchPlan {
        guard let index = command.target.sheetIndex else { return OfficeDispatchPlan(steps: [], notes: ["This command requires authorized package preparation before engine open."]) }
        switch command {
        case .excelSort(_, let range, let ascending):
            return OfficeDispatchPlan(steps: [.selectPart(index), .uno(name: ".uno:GoToCell", arguments: ["ToPoint": .string(range.uppercased())]), .uno(name: ascending ? ".uno:SortAscending" : ".uno:SortDescending", arguments: [:])])
        case .excelAutoFilter(_, let range):
            return OfficeDispatchPlan(steps: [.selectPart(index), .uno(name: ".uno:GoToCell", arguments: ["ToPoint": .string(range.uppercased())]), .uno(name: ".uno:DataFilterAutoFilter", arguments: [:])])
        default: return OfficeDispatchPlan(steps: [])
        }
    }
    static func validateSheet(_ command: OfficeExplicitCommand, package: OfficeArchive) throws {
        let sheets = try OfficeExplicitTargets.worksheetIdentities(package), t = command.target
        guard let i = t.sheetIndex, i < sheets.count, sheets[i].member == t.member, sheets[i].name == t.sheetName else { throw invalid("working worksheet member/name/order changed") }
    }
    private static func matrix(package: OfficeArchive, sheet: OfficeXMLNode, range: OfficeExactRange) throws -> [[String]] {
        guard sheet.child("mergeCells", s) == nil else { throw invalid("exact sort does not support merged cells") }
        let cells = try semanticCells(package: package, sheet: sheet)
        return (range.firstRow...range.lastRow).map { row in (range.firstColumn...range.lastColumn).map { cells[OfficeExactRange.cell(column: $0, row: row)] ?? "" } }
    }
    private static func cellsOutside(package: OfficeArchive, sheet: OfficeXMLNode, range: OfficeExactRange) throws -> [String: String] {
        var cells = try semanticCells(package: package, sheet: sheet)
        for row in range.firstRow...range.lastRow { for col in range.firstColumn...range.lastColumn { cells.removeValue(forKey: OfficeExactRange.cell(column: col, row: row)) } }
        return cells
    }
    static func semanticCells(package: OfficeArchive, sheet: OfficeXMLNode) throws -> [String: String] {
        let shared = package.paths.contains("xl/sharedStrings.xml") ? try OfficeExplicitTargets.tree(package, "xl/sharedStrings.xml").children.filter { $0.local == "si" && $0.namespace == s }.map { $0.descendants("t", s).map(\.text).joined() } : []
        var cells: [String: String] = [:]
        for cell in sheet.descendants("c", s) {
            guard let ref = cell.attributes["r"], cells[ref] == nil else { throw invalid("ambiguous cell reference") }
            guard cell.child("f", s) == nil else { throw invalid("exact data sort does not support formula cells") }
            let value = cell.child("v", s)?.text ?? ""
            switch cell.attributes["t"] {
            case "s":
                guard let index = Int(value), shared.indices.contains(index) else { throw invalid("invalid shared string") }; cells[ref] = shared[index]
            case "inlineStr": cells[ref] = cell.descendants("t", s).map(\.text).joined()
            case "e": throw invalid("exact sort does not support error cells")
            case "b": cells[ref] = value == "1" ? "TRUE" : "FALSE"
            case nil, "n":
                if value.isEmpty { cells[ref] = "" }
                else if let n = Double(value), n.isFinite { cells[ref] = String(n) }
                else { throw invalid("invalid numeric cell") }
            case "str": cells[ref] = value
            default: throw invalid("unsupported cell type for exact sort")
            }
        }
        return cells.filter { !$0.value.isEmpty }
    }
    private static func ensureNumberingParts(_ package: OfficeArchive, replacements: inout [String: Data]) throws {
        let relPath = "word/_rels/document.xml.rels", relNS = OfficeXMLNamespace.relationships
        let rels = package.paths.contains(relPath) ? try OfficeExplicitTargets.tree(package, relPath) : OfficeXMLNode("Relationships", namespace: relNS, attributes: ["xmlns": relNS])
        let existing = rels.children.filter { $0.attributes["Type"]?.hasSuffix("/numbering") == true }
        if let relation = existing.first {
            guard existing.count == 1, relation.attributes["TargetMode"] != "External", let target = relation.attributes["Target"],
                  try OfficeExplicitTargets.resolvedMember(target, relativeTo: "word/document.xml") == "word/numbering.xml" else { throw invalid("unsupported numbering relationship") }
        } else {
            let used = Set(rels.children.compactMap { $0.attributes["Id"] })
            var id = 1; while used.contains("rIdFloe\(id)") { id += 1 }
            rels.append(OfficeXMLNode("Relationship", namespace: relNS, attributes: ["xmlns": relNS, "Id": "rIdFloe\(id)", "Type": OfficeXMLNamespace.officeRelationships + "/numbering", "Target": "numbering.xml"]))
            replacements[relPath] = Data(rels.xml.utf8)
        }
        let types = try OfficeExplicitTargets.tree(package, "[Content_Types].xml")
        let entries = types.children.filter { $0.attributes["PartName"] == "/word/numbering.xml" }
        let contentType = "application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"
        if let entry = entries.first { guard entries.count == 1, entry.attributes["ContentType"] == contentType else { throw invalid("numbering content type differs") } }
        else {
            let ns = "http://schemas.openxmlformats.org/package/2006/content-types"
            types.append(OfficeXMLNode("Override", namespace: ns, attributes: ["xmlns": ns, "PartName": "/word/numbering.xml", "ContentType": contentType]))
            replacements["[Content_Types].xml"] = Data(types.xml.utf8)
        }
    }
    private static func word(_ local: String, _ attributes: [String: String] = [:]) -> OfficeXMLNode {
        OfficeXMLNode("w:" + local, namespace: w, attributes: attributes.merging(["xmlns:w": w]) { a, _ in a })
    }
    private static func orderParagraphProperties(_ props: OfficeXMLNode) {
        let order = ["pStyle", "keepNext", "keepLines", "pageBreakBefore", "framePr", "widowControl", "numPr", "suppressLineNumbers", "pBdr", "shd", "tabs", "suppressAutoHyphens", "kinsoku", "wordWrap", "overflowPunct", "topLinePunct", "autoSpaceDE", "autoSpaceDN", "bidi", "adjustRightInd", "snapToGrid", "spacing", "ind", "contextualSpacing", "mirrorIndents", "suppressOverlap", "jc", "textDirection", "textAlignment", "textboxTightWrap", "outlineLvl", "divId", "cnfStyle", "rPr", "sectPr", "pPrChange"]
        let nodes = props.children.enumerated().sorted { lhs, rhs in
            let a = order.firstIndex(of: lhs.element.local) ?? order.count, b = order.firstIndex(of: rhs.element.local) ?? order.count
            return a == b ? lhs.offset < rhs.offset : a < b
        }.map { OfficeXMLNode.Content.node($0.element) }
        props.content = nodes
    }
    private static func nextID(_ strings: [String]) throws -> Int {
        let values = strings.compactMap(Int.init)
        guard values.count == strings.count, values.allSatisfy({ (0..<1_000_000_000).contains($0) }) else { throw invalid("numbering IDs are unsupported") }
        return (values.max() ?? 0) + 1
    }
    private static func paragraphProperties(_ paragraph: OfficeXMLNode) -> [String] {
        let props = paragraph.child("pPr", w)
        return [props?.child("pStyle", w)?.attribute("val") ?? "", props?.child("jc", w)?.attribute("val") ?? "", props?.child("numPr", w) == nil ? "plain" : "list"]
    }
    private static func paragraphText(_ p: OfficeXMLNode) -> String { p.descendants("t", w).map(\.text).joined() }
    private static func geometry(_ shape: OfficeExplicitTargets.Shape) -> String { "\(shape.x),\(shape.y),\(shape.width),\(shape.height)" }
    private static func json<T: Encodable>(_ value: T) throws -> String { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return String(decoding: try e.encode(value), as: UTF8.self) }
    private static func invalid(_ detail: String) -> OfficeEngineCommandError { OfficeExplicitCommand.invalid(detail) }
}
