import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import ZIPFoundation
import FloeCore

/// Prevent a known native PPTX export failure from replacing the user's file.
/// This validates chart data links, not complete visual or Office fidelity.
enum OfficeNativeSaveValidation {
    static func validate(_ url: URL) throws {
        guard url.pathExtension.lowercased() == "pptx" else { return }
        let archive = try Archive(url: url, accessMode: .read)
        for entry in archive where entry.path.hasPrefix("ppt/charts/")
            && !entry.path.dropFirst("ppt/charts/".count).contains("/")
            && entry.path.hasSuffix(".xml") {
            let chart = try XMLValues(data: read(entry, from: archive))
            guard chart.hasDataReferences else { continue }
            guard let relationshipID = chart.externalID, !relationshipID.isEmpty,
                  !chart.formulas.contains(where: { $0.isEmpty || Double($0) != nil || $0.hasPrefix("label ") }) else {
                throw invalidChart()
            }
            let parent = (entry.path as NSString).deletingLastPathComponent
            let relationPath = parent + "/_rels/" + (entry.path as NSString).lastPathComponent + ".rels"
            guard let relationshipEntry = archive[relationPath] else { throw invalidChart() }
            let relationships = try XMLValues(data: read(relationshipEntry, from: archive))
            guard let relation = relationships.relationships[relationshipID],
                  let target = relation["Target"], !target.isEmpty,
                  let type = relation["Type"], type.hasSuffix("/package") || type.hasSuffix("/oleObject") else {
                throw invalidChart()
            }
            // A deliberately linked external workbook is not an embedded file.
            if relation["TargetMode"] == "External" { continue }
            guard !target.contains("\\"), !target.contains(":"), !target.contains("%") else { throw invalidChart() }
            var components = target.hasPrefix("/") ? [String]() : parent.split(separator: "/").map(String.init)
            for part in target.split(separator: "/") {
                if part == ".." {
                    guard !components.isEmpty else { throw invalidChart() }
                    components.removeLast()
                } else if part != "." { components.append(String(part)) }
            }
            guard let payload = archive[components.joined(separator: "/")], payload.type == .file,
                  payload.uncompressedSize > 0 else { throw invalidChart() }
        }
    }

    private static func invalidChart() -> FloeError {
        .validationFailed("幻灯片图表的数据未完整保存，已保留编辑副本，原文件未被覆盖。")
    }

    private static func read(_ entry: Entry, from archive: Archive) throws -> Data {
        let limit = 16 * 1024 * 1024
        guard entry.type == .file, entry.uncompressedSize <= limit else { throw invalidChart() }
        var data = Data()
        _ = try archive.extract(entry) { chunk in
            guard chunk.count <= limit - data.count else { throw invalidChart() }
            data.append(chunk)
        }
        return data
    }

    private final class XMLValues: NSObject, XMLParserDelegate {
        var hasDataReferences = false
        var externalID: String?
        var formulas: [String] = []
        var relationships: [String: [String: String]] = [:]
        private var formula: String?
        private var invalid = false
        private var namespaces: [String: [String]] = [:]
        private let chartNamespace = "http://schemas.openxmlformats.org/drawingml/2006/chart"

        init(data: Data) throws {
            super.init()
            let parser = XMLParser(data: data)
            parser.shouldProcessNamespaces = true
            parser.shouldReportNamespacePrefixes = true
            parser.shouldResolveExternalEntities = false
            parser.delegate = self
            guard parser.parse(), !invalid else { throw OfficeNativeSaveValidation.invalidChart() }
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            if namespaceURI == chartNamespace || namespaceURI == "http://purl.oclc.org/ooxml/drawingml/chart" {
                if ["numRef", "strRef", "multiLvlStrRef"].contains(elementName) { hasDataReferences = true }
                if elementName == "f" { formula = "" }
                if elementName == "externalData" {
                    if externalID != nil { invalid = true }
                    externalID = attributeDict.first { key, _ in
                        let parts = key.split(separator: ":")
                        guard parts.count == 2, parts[1] == "id",
                              let uri = namespaces[String(parts[0])]?.last else { return false }
                        return uri == "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
                            || uri == "http://purl.oclc.org/ooxml/officeDocument/relationships"
                    }?.value
                }
            }
            if namespaceURI == "http://schemas.openxmlformats.org/package/2006/relationships", elementName == "Relationship" {
                guard let id = attributeDict["Id"], relationships[id] == nil else { invalid = true; return }
                relationships[id] = attributeDict
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if formula != nil { formula! += string }
        }

        func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
            namespaces[prefix, default: []].append(namespaceURI)
        }

        func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) {
            _ = namespaces[prefix]?.popLast()
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if elementName == "f", let value = formula {
                formulas.append(value.trimmingCharacters(in: .whitespacesAndNewlines)); formula = nil
            }
        }
    }
}
