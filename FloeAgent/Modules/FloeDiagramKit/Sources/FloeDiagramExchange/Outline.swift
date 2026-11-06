// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeDiagramCore

enum OutlineCodec {
    static func decodeXML(_ data: Data, format: DiagramFormat, title: String) throws -> DiagramImportResult {
        let xml = try DiagramXML.parse(data), namespace = DiagramCodec.digest(data)
        let isFreeMind = format == .freemind
        guard xml.name == (isFreeMind ? "map" : "opml") else { throw DiagramError.invalid("outline root") }
        let tag = isFreeMind ? "node" : "outline"
        let rootNodes = isFreeMind ? xml.children.filter { $0.name == tag } : xml.child("body")?.children.filter { $0.name == tag } ?? []
        var elements: [DiagramElement] = [], tasks: [DiagramTask] = [], relations: [(UUID, DiagramXMLNode)] = [], externalIDs: [String: UUID] = [:], issues: [DiagramExchangeIssue] = []
        var stack = rootNodes.reversed().map { ($0, nil as UUID?) }, ordinal = 0
        while let (node, parent) = stack.popLast() {
            let rawID = node.attributes[isFreeMind ? "ID" : "id"] ?? "outline-\(ordinal)"
            let id = ExchangeText.stableID(namespace, rawID)
            guard externalIDs[rawID] == nil else { throw DiagramError.invalid("duplicate outline identity") }; externalIDs[rawID] = id
            var content: [DiagramContentBlock] = []
            if let note = node.attributes["_note"], !note.isEmpty { content.append(.note(note)) }
            for rich in node.children where rich.name == "richcontent" {
                let text = rich.allText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { content.append(.note(text)) }
            }
            let label = node.attributes[isFreeMind ? "TEXT" : "text"] ?? node.attributes["title"] ?? "Topic"
            let text = node.child("richcontent")?.attributes["TYPE"] == "NODE" && label.isEmpty ? node.child("richcontent")!.allText : label
            let icons = node.children.filter { $0.name == "icon" }.compactMap { $0.attributes["BUILTIN"] }
            var taskID: UUID? = nil
            if let complete = node.attributes["isCompleted"] {
                let task = DiagramTask(title: text, status: complete == "true" ? .done : .todo); taskID = task.id; tasks.append(task)
            }
            let structure: DiagramStructure? = node.attributes["POSITION"].map { $0 == "left" ? .left : .right }
            let style = DiagramStyle(fill: node.attributes["BACKGROUND_COLOR"] ?? "surface", text: node.attributes["COLOR"] ?? "text",
                                     fontSize: Double(node.child("font")?.attributes["SIZE"] ?? "") ?? 15,
                                     bold: node.child("font")?.attributes["BOLD"] == "true")
            elements.append(.init(id: id, title: text, parentID: parent, order: ordinal, structure: structure,
                                  collapsed: node.attributes["FOLDED"] == "true", content: content, style: style,
                                  tags: node.attributes["category"].map { $0.components(separatedBy: ",") } ?? [], markers: icons,
                                  taskID: taskID, links: (node.attributes["LINK"] ?? node.attributes["url"]).map { [.init(url: $0)] } ?? [],
                                  metadata: ["externalID": rawID]))
            ordinal += 1
            for arrow in node.children where arrow.name == "arrowlink" { relations.append((id, arrow)) }
            stack += node.children.filter { $0.name == tag }.reversed().map { ($0, Optional(id)) }
        }
        var edges: [DiagramConnection] = []
        for (from, xml) in relations {
            if let destination = xml.attributes["DESTINATION"].flatMap({ externalIDs[$0] }) {
                edges.append(.init(from: from, to: destination, label: xml.attributes["MIDDLE_LABEL"] ?? "", endArrow: true))
            } else { issues.append(.init("missingArrowTarget", "An outline relationship points to a missing topic.")) }
        }
        guard !elements.isEmpty else { throw DiagramError.invalid("empty outline") }
        let document = DiagramDocument(id: ExchangeText.stableID(namespace, "document"),
                                       title: isFreeMind ? (elements.first!.title.isEmpty ? title : elements.first!.title) : (xml.child("head")?.child("title")?.allText).flatMap { $0.isEmpty ? nil : $0 } ?? title,
                                       pages: [.init(id: ExchangeText.stableID(namespace, "page"), title: "Overview", elements: elements, connections: edges)],
                                       tasks: tasks, metadata: ["importFormat": format.rawValue])
        return .init(document: document, issues: issues)
    }
    static func decodeMarkdown(_ data: Data, title: String) throws -> DiagramImportResult {
        guard let text = String(data: data, encoding: .utf8) else { throw DiagramError.invalid("Markdown encoding") }
        let namespace = DiagramCodec.digest(data)
        var elements: [DiagramElement] = [], tasks: [DiagramTask] = [], parents: [(depth: Int, id: UUID)] = []
        var code: [String]? = nil, language = "", ordinal = 0
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("~~~") || trimmed.hasPrefix("\u{60}\u{60}\u{60}") {
                if let lines = code {
                    if !elements.isEmpty { elements[elements.count-1].content.append(.code(language: language, text: lines.joined(separator: "\n"))) }
                    code = nil
                } else { code = []; language = String(trimmed.dropFirst(3)) }
                continue
            }
            if code != nil { code!.append(line); continue }
            if trimmed.isEmpty { continue }
            let heading = trimmed.prefix { $0 == "#" }.count
            let prefixCount = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0+($1 == "\t" ? 4 : 1) }
            var label: String?, depth = prefixCount/2+8
            if (1...6).contains(heading), trimmed.dropFirst(heading).first == " " { label = String(trimmed.dropFirst(heading+1)); depth = heading-1 }
            else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") { label = String(trimmed.dropFirst(2)) }
            if var label {
                var taskID: UUID? = nil
                let checked = label.lowercased().hasPrefix("[x] ")
                if checked || label.hasPrefix("[ ] ") {
                    label = String(label.dropFirst(4))
                    let task = DiagramTask(id: ExchangeText.stableID(namespace, "task-\(ordinal)"), title: label, status: checked ? .done : .todo)
                    tasks.append(task); taskID = task.id
                }
                while parents.last.map({ $0.depth >= depth }) == true { parents.removeLast() }
                let id = ExchangeText.stableID(namespace, "topic-\(ordinal)")
                elements.append(.init(id: id, title: label, parentID: parents.last?.id, order: ordinal, taskID: taskID))
                parents.append((depth, id)); ordinal += 1
            } else if !elements.isEmpty { elements[elements.count-1].content.append(.note(trimmed)) }
            else { elements.append(.init(id: ExchangeText.stableID(namespace, "topic-\(ordinal)"), title: title, content: [.note(trimmed)])); ordinal += 1 }
        }
        guard code == nil else { throw DiagramError.invalid("unclosed Markdown code block") }
        guard !elements.isEmpty else { throw DiagramError.invalid("empty Markdown") }
        return .init(document: .init(id: ExchangeText.stableID(namespace, "document"), title: title,
                                     pages: [.init(id: ExchangeText.stableID(namespace, "page"), elements: elements)], tasks: tasks,
                                     metadata: ["importFormat": "markdown"]))
    }

    static func encode(_ document: DiagramDocument, page: DiagramPage, format: DiagramFormat) throws -> DiagramExportResult {
        let index = DiagramPageIndex(page), taskIndex = Dictionary(uniqueKeysWithValues: document.tasks.map { ($0.id, $0) })
        let roots = page.elements.filter { $0.parentID == nil }.sorted { $0.order < $1.order }
        var output = "", stack: [(DiagramElement, Int, Bool)] = roots.reversed().map { ($0, 0, false) }
        if format == .freemind { output = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><map version=\"1.0.1\">" }
        else if format == .opml { output = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><opml version=\"2.0\"><head><title>\(ExchangeText.escape(document.title))</title></head><body>" }
        if format == .freemind, roots.count > 1 { output += "<node TEXT=\"\(ExchangeText.escape(page.title))\">" }
        while let (node, depth, closing) = stack.popLast() {
            guard depth < 256 else { throw DiagramError.unsupported("outline depth exceeds 255") }
            let text = ExchangeText.escape(node.title), note = node.content.map(\.plainText).filter { !$0.isEmpty }.joined(separator: "\n")
            let task = node.taskID.flatMap { taskIndex[$0] }
            if closing { if format == .freemind { output += "</node>" }; if format == .opml { output += "</outline>" }; continue }
            if format == .freemind {
                output += "<node ID=\"\(node.id.uuidString)\" TEXT=\"\(text)\" FOLDED=\"\(node.collapsed)\""
                if let structure = node.structure { output += " POSITION=\"\(structure == .left ? "left" : "right")\"" }
                let fill = ExchangeText.colorHex(node.style.fill), foreground = ExchangeText.colorHex(node.style.text)
                if fill != "none" { output += " BACKGROUND_COLOR=\"\(fill)\"" }; if foreground != "none" { output += " COLOR=\"\(foreground)\"" }
                output += "><font SIZE=\"\(Int(node.style.fontSize))\" BOLD=\"\(node.style.bold)\"/>"
                if !note.isEmpty { output += "<richcontent TYPE=\"NOTE\"><html><body><p>\(ExchangeText.escape(note))</p></body></html></richcontent>" }
                for edge in page.connections where edge.from == node.id { output += "<arrowlink DESTINATION=\"\(edge.to.uuidString)\" MIDDLE_LABEL=\"\(ExchangeText.escape(edge.label))\" ENDARROW=\"Default\"/>" }
            } else if format == .opml {
                output += "<outline id=\"\(node.id.uuidString)\" text=\"\(text)\""
                if !note.isEmpty { output += " _note=\"\(ExchangeText.escape(note))\"" }
                if let task { output += " isCompleted=\"\(task.status == .done)\"" }
                output += ">"
            } else {
                let prefix = String(repeating: "  ", count: depth)
                output += prefix+"- "+(task.map { $0.status == .done ? "[x] " : "[ ] " } ?? "")+node.title.replacingOccurrences(of: "\n", with: " ")+"\n"
                if !note.isEmpty { output += note.components(separatedBy: "\n").map { prefix+"  "+$0 }.joined(separator: "\n")+"\n" }
            }
            stack.append((node, depth, true))
            stack += (index.children[node.id] ?? []).reversed().compactMap { index.elements[$0].map { ($0, depth+1, false) } }
        }
        if format == .freemind { if roots.count > 1 { output += "</node>" }; output += "</map>" }
        if format == .opml { output += "</body></opml>" }
        var issues = ExchangeText.outlineIssues(page, tasks: document.tasks)
        if format == .freemind, roots.count > 1 { issues.append(.init("syntheticRoot", "FreeMind requires one root; multiple roots are grouped under the page title.")) }
        if format == .freemind { issues.removeAll { $0.code == "relationships" } }
        if page.ink != nil { issues.append(.init("handwriting", "Handwriting is retained in the native file only.")) }
        return .init(data: Data(output.utf8), format: format, issues: issues)
    }
}
