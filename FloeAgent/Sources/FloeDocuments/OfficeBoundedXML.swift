import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Small namespace-aware tree for bounded OOXML package preparations. No DTD,
/// entities, external resources, code, or XPath supplied by callers is accepted.
final class OfficeXMLNode {
    let name: String
    let namespace: String
    var attributes: [String: String]
    var content: [Content] = []
    enum Content { case text(String), node(OfficeXMLNode) }
    var local: String { String(name.split(separator: ":").last ?? "") }
    var children: [OfficeXMLNode] { content.compactMap { if case .node(let n) = $0 { return n }; return nil } }
    var text: String { content.map { switch $0 { case .text(let s): return s; case .node(let n): return n.text } }.joined() }
    init(_ name: String, namespace: String, attributes: [String: String] = [:]) {
        self.name = name; self.namespace = namespace; self.attributes = attributes
    }
    func child(_ local: String, _ ns: String) -> OfficeXMLNode? {
        children.first { $0.local == local && $0.namespace == ns }
    }
    func descendants(_ local: String, _ ns: String) -> [OfficeXMLNode] {
        children.flatMap { ($0.local == local && $0.namespace == ns ? [$0] : []) + $0.descendants(local, ns) }
    }
    func append(_ node: OfficeXMLNode) { content.append(.node(node)) }
    func replace(_ local: String, _ ns: String, with node: OfficeXMLNode, first: Bool = false) {
        content.removeAll { if case .node(let n) = $0 { return n.local == local && n.namespace == ns }; return false }
        if first { content.insert(.node(node), at: 0) } else { append(node) }
    }
    func attribute(_ local: String) -> String? {
        attributes.first { String($0.key.split(separator: ":").last ?? "") == local && !$0.key.hasPrefix("xmlns") }?.value
    }
    var xml: String {
        let attrs = attributes.keys.sorted().map { " \($0)=\"\(Self.escape(attributes[$0]!, attribute: true))\"" }.joined()
        let body = content.map { switch $0 { case .text(let s): return Self.escape(s); case .node(let n): return n.xml } }.joined()
        return "<\(name)\(attrs)>\(body)</\(name)>"
    }
    static func escape(_ string: String, attribute: Bool = false) -> String {
        var s = string.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        if attribute { s = s.replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "\r", with: "&#13;").replacingOccurrences(of: "\n", with: "&#10;").replacingOccurrences(of: "\t", with: "&#9;") }
        return s
    }
    static func parse(_ xml: String) throws -> OfficeXMLNode {
        guard xml.utf8.count <= 16 * 1_024 * 1_024,
              !xml.contains("<!DOCTYPE"), !xml.contains("<!ENTITY") else { throw OfficeDocumentError.invalidXML("bounded OOXML") }
        let reader = Reader()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse(), !reader.invalid, let root = reader.root else { throw OfficeDocumentError.invalidXML("bounded OOXML") }
        return root
    }
    private final class Reader: NSObject, XMLParserDelegate {
        var root: OfficeXMLNode?
        var stack: [OfficeXMLNode] = []
        var mappings: [[String: String]] = []
        var count = 0
        var invalid = false
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
            count += 1
            guard count <= 200_000, stack.count < 128 else { invalid = true; parser.abortParsing(); return }
            var map = mappings.last ?? [:]
            for (key, value) in attributes {
                if key == "xmlns" { map[""] = value }
                else if key.hasPrefix("xmlns:") { map[String(key.dropFirst(6))] = value }
            }
            let parts = elementName.split(separator: ":")
            let prefix = parts.count == 2 ? String(parts[0]) : ""
            guard parts.count <= 2, prefix.isEmpty || map[prefix] != nil else { invalid = true; parser.abortParsing(); return }
            let node = OfficeXMLNode(elementName, namespace: map[prefix] ?? "", attributes: attributes)
            if let parent = stack.last { parent.append(node) }
            else if root == nil { root = node }
            else { invalid = true; parser.abortParsing(); return }
            stack.append(node); mappings.append(map)
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.content.append(.text(string)) }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard let string = String(data: CDATABlock, encoding: .utf8) else { invalid = true; parser.abortParsing(); return }
            stack.last?.content.append(.text(string))
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { _ = stack.popLast(); _ = mappings.popLast() }
    }
}

enum OfficeXMLNamespace {
    static let word = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    static let sheet = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    static let presentation = "http://schemas.openxmlformats.org/presentationml/2006/main"
    static let drawing = "http://schemas.openxmlformats.org/drawingml/2006/main"
    static let relationships = "http://schemas.openxmlformats.org/package/2006/relationships"
    static let officeRelationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
}
