// SPDX-License-Identifier: MPL-2.0
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import FloeDiagramCore

final class DiagramXMLNode {
    var name: String
    var attributes: [String: String]
    var text = ""
    var children: [DiagramXMLNode] = []
    weak var parent: DiagramXMLNode?
    init(_ name: String, attributes: [String: String] = [:]) { self.name = name; self.attributes = attributes }
    func child(_ name: String) -> DiagramXMLNode? { children.first { $0.name == name } }
    func descendants(_ name: String) -> [DiagramXMLNode] {
        var queue = children, cursor = 0, result: [DiagramXMLNode] = []
        while cursor < queue.count { let node = queue[cursor]; cursor += 1; if node.name == name { result.append(node) }; queue += node.children }
        return result
    }
    var allText: String {
        var stack = [self], output = ""
        while let next = stack.popLast() { output += next.text; stack += next.children.reversed() }
        return output
    }
}
private final class DiagramXMLDelegate: NSObject, XMLParserDelegate {
    var root: DiagramXMLNode?
    var stack: [DiagramXMLNode] = []
    var count = 0
    var textCount = 0
    var rejected = false
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        count += 1
        guard count <= 200_000, stack.count < 256 else { rejected = true; parser.abortParsing(); return }
        let node = DiagramXMLNode(elementName, attributes: attributes)
        if let parent = stack.last { node.parent = parent; parent.children.append(node) }
        else if root == nil { root = node }
        else { rejected = true; parser.abortParsing(); return }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { if !stack.isEmpty { stack.removeLast() } }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textCount += string.utf8.count
        guard textCount <= 32*1_024*1_024 else { rejected = true; parser.abortParsing(); return }
        stack.last?.text += string
    }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { self.parser(parser, foundCharacters: String(decoding: CDATABlock, as: UTF8.self)) }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { rejected = true; parser.abortParsing(); return nil }
}
enum DiagramXML {
    static func parse(_ data: Data) throws -> DiagramXMLNode {
        guard data.count <= 32*1_024*1_024, let string = String(data: data, encoding: .utf8),
              string.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
              string.range(of: "<!ENTITY", options: .caseInsensitive) == nil else { throw DiagramError.invalid("XML size, encoding or declarations") }
        let parser = XMLParser(data: data), delegate = DiagramXMLDelegate()
        parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), !delegate.rejected, let root = delegate.root else { throw DiagramError.invalid("XML structure") }
        return root
    }
}
