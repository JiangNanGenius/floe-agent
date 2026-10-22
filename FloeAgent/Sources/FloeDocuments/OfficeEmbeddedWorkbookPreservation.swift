import Foundation
import FloeCore

/// The engine may renumber styles/shared strings when it saves chart data.
/// Retain the original embedded XLSX package and merge only representable cell
/// DATA into it. Never restore styles.xml onto engine-renumbered cell indices.
public enum OfficeEmbeddedWorkbookPreservation {
    /// Call only on a stable saved copy, after persistence/close acknowledgement,
    /// or on an export/recovery snapshot that the engine cannot still write.
    /// Failures leave that copy and its baseline available for recovery.
    @discardableResult
    public static func preserve(originalURL: URL, savedURL: URL) throws -> [String] {
        guard originalURL.pathExtension.lowercased() == "pptx", savedURL.pathExtension.lowercased() == "pptx" else { return [] }
        guard originalURL.standardizedFileURL != savedURL.standardizedFileURL else { throw invalid("a separate saved snapshot is required") }
        let original = try OfficeArchive(url: originalURL, maximumEntries: 4096)
        let saved = try OfficeArchive(url: savedURL, maximumEntries: 4096)
        let before = try chartWorkbooks(original), after = try chartWorkbooks(saved)
        var replacements: [String: Data] = [:], facts: [String] = []
        let scratch = savedURL.deletingLastPathComponent().appendingPathComponent(".floe-chart-data-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        for chart in Set(before.keys).intersection(after.keys).sorted() {
            let oldMember = before[chart]!, newMember = after[chart]!
            let oldBytes = try original.data(path: oldMember, limit: 16 * 1_024 * 1_024)
            let newBytes = try saved.data(path: newMember, limit: 16 * 1_024 * 1_024)
            guard oldBytes != newBytes else { continue }
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let oldURL = scratch.appendingPathComponent("original.xlsx"), newURL = scratch.appendingPathComponent("engine.xlsx"), mergedURL = scratch.appendingPathComponent("merged.xlsx")
            try oldBytes.write(to: oldURL, options: .atomic); try newBytes.write(to: newURL, options: .atomic)
            let oldBook = try OfficeArchive(url: oldURL, maximumEntries: 4096), newBook = try OfficeArchive(url: newURL, maximumEntries: 4096)
            let oldSheets = try OfficeExplicitTargets.worksheetIdentities(oldBook), newSheets = try OfficeExplicitTargets.worksheetIdentities(newBook)
            guard oldSheets.map(\.name) == newSheets.map(\.name) else { throw invalid("embedded worksheet structure changed") }
            var members: [String: Data] = [:]
            for (oldSheet, newSheet) in zip(oldSheets, newSheets) {
                let oldTree = try OfficeExplicitTargets.tree(oldBook, oldSheet.member), newTree = try OfficeExplicitTargets.tree(newBook, newSheet.member)
                let oldCells = try cells(oldTree), newCells = try cells(newTree)
                let oldStrings = try strings(oldBook), newStrings = try strings(newBook)
                var changed = false
                // Existing add-series behavior may create ordinary populated
                // cells. Their engine style index cannot be transplanted into
                // the original table: use the original workbook default style.
                for ref in newCells.keys.sorted() where oldCells[ref] == nil {
                    let cell = newCells[ref]!
                    guard !(try payload(cell, shared: newStrings)).isEmpty else { continue }
                    guard cell.child("f", OfficeXMLNamespace.sheet) == nil else { throw invalid("new embedded formulas are unsupported") }
                    let added = OfficeXMLNode("c", namespace: OfficeXMLNamespace.sheet, attributes: ["xmlns": OfficeXMLNamespace.sheet, "r": ref])
                    try mergeData(from: cell, shared: newStrings, into: added, originalShared: [])
                    try insert(added, reference: ref, into: oldTree)
                    changed = true
                    facts.append("new chart data cell uses the original workbook default style: " + ref)
                }
                for (ref, cell) in oldCells {
                    let newCell = newCells[ref]
                    let oldFormula = cell.child("f", OfficeXMLNamespace.sheet)
                    let newFormula = newCell?.child("f", OfficeXMLNamespace.sheet)
                    guard oldFormula?.text == newFormula?.text, oldFormula?.attributes == newFormula?.attributes else { throw invalid("embedded formula structure changed") }
                    let oldValue = try payload(cell, shared: oldStrings)
                    let newValue = try newCell.map { try payload($0, shared: newStrings) } ?? ""
                    guard oldValue != newValue else { continue }
                    if let newCell { try mergeData(from: newCell, shared: newStrings, into: cell, originalShared: oldStrings) }
                    else { removeData(cell); cell.attributes.removeValue(forKey: "t") }
                    changed = true
                }
                if changed { members[oldSheet.member] = Data(oldTree.xml.utf8) }
            }
            let preservedBytes: Data
            if members.isEmpty { preservedBytes = oldBytes }
            else {
                try oldBook.writeCopy(to: mergedURL, replacements: members,
                    maximumMemberBytes: 16 * 1_024 * 1_024, maximumTotalBytes: 128 * 1_024 * 1_024, verify: { candidate in
                        let merged = try OfficeArchive(url: candidate, maximumEntries: 4096)
                        for (oldSheet, newSheet) in zip(oldSheets, newSheets) {
                            let left = try cells(OfficeExplicitTargets.tree(merged, oldSheet.member)), right = try cells(OfficeExplicitTargets.tree(newBook, newSheet.member))
                            let leftStrings = try strings(merged), rightStrings = try strings(newBook)
                            for ref in Set(left.keys).union(right.keys) {
                                let lhs = try left[ref].map { try payload($0, shared: leftStrings) } ?? ""
                                let rhs = try right[ref].map { try payload($0, shared: rightStrings) } ?? ""
                                guard lhs == rhs else { throw invalid("merged embedded data differs from engine output") }
                            }
                        }
                        // Style tables, relationships and other non-data
                        // members come from the original archive byte for byte.
                        for path in oldBook.paths where members[path] == nil {
                            guard try merged.data(path: path, limit: 16 * 1_024 * 1_024) == oldBook.data(path: path, limit: 16 * 1_024 * 1_024) else { throw invalid("an untouched embedded member changed") }
                        }
                    })
                preservedBytes = try Data(contentsOf: mergedURL)
            }
            if let existing = replacements[newMember], existing != preservedBytes { throw invalid("shared embedded workbook has conflicting chart baselines") }
            replacements[newMember] = preservedBytes
            facts.append("embedded workbook data merged with original formatting: " + chart)
        }
        guard !replacements.isEmpty else { return facts }
        // Multiple charts may share one embedded workbook. Conflicting merges
        // are rejected by identical bytes rather than silently choosing one.
        try saved.writeCopy(to: savedURL, replacements: replacements, maximumMemberBytes: 32 * 1_024 * 1_024,
            maximumTotalBytes: 128 * 1_024 * 1_024, verify: { candidate in
                try OfficeNativeSaveValidation.validate(candidate)
                let reopened = try OfficeArchive(url: candidate, maximumEntries: 4096)
                for (member, data) in replacements {
                    guard try reopened.data(path: member, limit: 32 * 1_024 * 1_024) == data else { throw invalid("saved embedded workbook did not persist") }
                }
            })
        return facts
    }

    private static func chartWorkbooks(_ package: OfficeArchive) throws -> [String: String] {
        let c = "http://schemas.openxmlformats.org/drawingml/2006/chart", r = OfficeXMLNamespace.relationships
        var result: [String: String] = [:]
        for member in package.paths where member.range(of: "^ppt/charts/chart[1-9][0-9]*\\.xml$", options: .regularExpression) != nil {
            let chart = try OfficeExplicitTargets.tree(package, member)
            let external = chart.descendants("externalData", c)
            guard !external.isEmpty else { continue }
            guard external.count == 1, let id = external[0].attribute("id") else { throw invalid("ambiguous chart workbook relationship") }
            let parent = (member as NSString).deletingLastPathComponent
            let path = parent + "/_rels/" + (member as NSString).lastPathComponent + ".rels"
            let relations = try OfficeExplicitTargets.tree(package, path).children.filter { $0.local == "Relationship" && $0.namespace == r && $0.attributes["Id"] == id }
            guard relations.count == 1, let relation = relations.first else { throw invalid("chart workbook relationship is absent") }
            if relation.attributes["TargetMode"] == "External" { continue }
            guard relation.attributes["Type"]?.hasSuffix("/package") == true, let target = relation.attributes["Target"] else { throw invalid("unsupported embedded chart data") }
            let resolved = try OfficeExplicitTargets.resolvedMember(target, relativeTo: member)
            guard resolved.hasSuffix(".xlsx"), package.paths.contains(resolved) else { throw invalid("embedded workbook is absent") }
            result[member] = resolved
        }
        return result
    }
    private static func insert(_ cell: OfficeXMLNode, reference: String, into sheet: OfficeXMLNode) throws {
        let position = try OfficeExactRange(reference + ":" + reference), s = OfficeXMLNamespace.sheet
        guard let data = sheet.child("sheetData", s) else { throw invalid("embedded sheetData is absent") }
        let rowNumber = position.firstRow
        let row: OfficeXMLNode
        if let found = data.children.first(where: { $0.local == "row" && $0.namespace == s && $0.attributes["r"] == String(rowNumber) }) { row = found }
        else {
            row = OfficeXMLNode("row", namespace: s, attributes: ["xmlns": s, "r": String(rowNumber)])
            if let i = data.content.firstIndex(where: { if case .node(let n) = $0 { return n.local == "row" && (Int(n.attributes["r"] ?? "") ?? 0) > rowNumber }; return false }) { data.content.insert(.node(row), at: i) }
            else { data.append(row) }
        }
        if let i = row.content.firstIndex(where: { content in
            guard case .node(let node) = content, node.local == "c", let ref = node.attributes["r"], let existing = try? OfficeExactRange(ref + ":" + ref) else { return false }
            return existing.firstColumn > position.firstColumn
        }) { row.content.insert(.node(cell), at: i) }
        else { row.append(cell) }
        // Expand the dimension for new data without inheriting an engine style.
        if let dimension = sheet.child("dimension", s), let raw = dimension.attributes["ref"] {
            let previous = try OfficeExactRange(raw.contains(":") ? raw : raw + ":" + raw)
            dimension.attributes["ref"] = OfficeExactRange.cell(column: min(previous.firstColumn, position.firstColumn), row: min(previous.firstRow, position.firstRow)) + ":" + OfficeExactRange.cell(column: max(previous.lastColumn, position.lastColumn), row: max(previous.lastRow, position.lastRow))
        }
    }
    private static func cells(_ tree: OfficeXMLNode) throws -> [String: OfficeXMLNode] {
        var result: [String: OfficeXMLNode] = [:]
        for cell in tree.descendants("c", OfficeXMLNamespace.sheet) {
            guard let ref = cell.attributes["r"], result[ref] == nil else { throw invalid("ambiguous embedded cell") }
            result[ref] = cell
        }
        return result
    }
    private static func strings(_ package: OfficeArchive) throws -> [OfficeXMLNode] {
        guard package.paths.contains("xl/sharedStrings.xml") else { return [] }
        return try OfficeExplicitTargets.tree(package, "xl/sharedStrings.xml").children.filter { $0.local == "si" && $0.namespace == OfficeXMLNamespace.sheet }
    }
    private static func stringNode(_ cell: OfficeXMLNode, shared: [OfficeXMLNode]) throws -> OfficeXMLNode? {
        let s = OfficeXMLNamespace.sheet
        if cell.attributes["t"] == "s" {
            guard let i = cell.child("v", s).flatMap({ Int($0.text) }), shared.indices.contains(i) else { throw invalid("invalid embedded shared string") }
            return shared[i]
        }
        return cell.child("is", s)
    }
    private static func payload(_ cell: OfficeXMLNode, shared: [OfficeXMLNode]) throws -> String {
        let s = OfficeXMLNamespace.sheet
        let formula = cell.child("f", s).map { $0.text + $0.attributes.filter { !$0.key.hasPrefix("xmlns") }.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }.joined(separator: ";") } ?? ""
        if let string = try stringNode(cell, shared: shared) { return "string:" + string.descendants("t", s).map(\.text).joined() + "|" + formula }
        let value = cell.child("v", s)?.text ?? ""
        if value.isEmpty, formula.isEmpty { return "" }
        let type = cell.attributes["t"] ?? "n"
        if type == "n", let number = Double(value), number.isFinite { return "n:" + String(number) + "|" + formula }
        return type + ":" + value + "|" + formula
    }
    private static func mergeData(from source: OfficeXMLNode, shared: [OfficeXMLNode], into original: OfficeXMLNode, originalShared: [OfficeXMLNode]) throws {
        let s = OfficeXMLNamespace.sheet
        let newString = try stringNode(source, shared: shared)
        let oldString = try stringNode(original, shared: originalShared)
        if let newString {
            let value = newString.descendants("t", s).map(\.text).joined()
            let inline = OfficeXMLNode("is", namespace: s, attributes: ["xmlns": s])
            if let oldString {
                let copy = try clone(oldString)
                let texts = copy.descendants("t", s)
                guard texts.count == 1 else { throw invalid("a changed rich-text cell has multiple runs") }
                texts[0].content = [.text(value)]; texts[0].attributes["xml:space"] = "preserve"
                inline.content = copy.content
            } else {
                let text = OfficeXMLNode("t", namespace: s, attributes: ["xmlns": s, "xml:space": "preserve"])
                text.content = [.text(value)]; inline.append(text)
            }
            removeData(original); original.attributes["t"] = "inlineStr"; appendData(inline, to: original)
            // Formula string results use t=str/v, rather than inlineStr. The
            // finite preservation path refuses changing that representation.
            guard source.child("f", s) == nil else { throw invalid("formula string representation changed") }
        } else {
            removeData(original)
            original.attributes["t"] = source.attributes["t"]
            for child in source.children where child.namespace == s && ["f", "v"].contains(child.local) { appendData(try clone(child), to: original) }
        }
    }
    private static func appendData(_ node: OfficeXMLNode, to cell: OfficeXMLNode) {
        if let index = cell.content.firstIndex(where: { if case .node(let child) = $0 { return child.local == "extLst" }; return false }) { cell.content.insert(.node(node), at: index) }
        else { cell.append(node) }
    }
    private static func removeData(_ cell: OfficeXMLNode) {
        cell.content.removeAll { if case .node(let n) = $0 { return n.namespace == OfficeXMLNamespace.sheet && ["v", "is", "f"].contains(n.local) }; return false }
    }
    private static func clone(_ node: OfficeXMLNode) throws -> OfficeXMLNode {
        // Copied nodes may have inherited their namespace declaration from a
        // different workbook. Declare each copied element's actual namespace.
        let copy = OfficeXMLNode(node.name, namespace: node.namespace, attributes: node.attributes)
        if !node.namespace.isEmpty {
            let parts = node.name.split(separator: ":")
            copy.attributes[parts.count == 2 ? "xmlns:" + String(parts[0]) : "xmlns"] = node.namespace
        }
        for content in node.content { switch content { case .text(let text): copy.content.append(.text(text)); case .node(let child): copy.append(try clone(child)) } }
        return copy
    }
    private static func invalid(_ message: String) -> FloeError { .validationFailed("Embedded chart formatting could not be preserved: " + message) }
}
