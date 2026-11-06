// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeDiagramCore

enum MermaidCodec {
    static func decode(_ data: Data, title: String) throws -> DiagramImportResult {
        guard let text = String(data: data, encoding: .utf8) else { throw DiagramError.invalid("Mermaid encoding") }
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces) else { throw DiagramError.invalid("empty Mermaid") }
        if first == "gantt" { return try decodeGantt(lines, title: title, namespace: DiagramCodec.digest(data)) }
        if first == "mindmap" { return try decodeMindmap(lines, title: title, namespace: DiagramCodec.digest(data)) }
        guard first.hasPrefix("flowchart ") || first.hasPrefix("graph ") else { throw DiagramError.unsupported("Mermaid mindmap, flowchart and gantt are supported") }
        let namespace = DiagramCodec.digest(data)
        var elements: [DiagramElement] = [], mapping: [String: UUID] = [:], connections: [DiagramConnection] = [], groups: [UUID] = [], issues: [DiagramExchangeIssue] = []
        func register(_ text: String) throws -> UUID {
            let (raw, label, kind) = try parseNode(text)
            if let existing = mapping[raw] {
                if label != raw, let i = elements.firstIndex(where: { $0.id == existing }) { elements[i].title = label; elements[i].kind = kind }
                return existing
            }
            let id = ExchangeText.stableID(namespace, raw); mapping[raw] = id
            elements.append(.init(id: id, kind: kind, title: label, containerID: groups.last, order: elements.count, metadata: ["externalID": raw])); return id
        }
        for rawLine in lines.dropFirst() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("%%") { continue }
            if line.hasPrefix("subgraph ") {
                let name = String(line.dropFirst(9)), parts = (try? parseNode(name)) ?? (name, name, .rectangle)
                let id = ExchangeText.stableID(namespace, "group:"+parts.0)
                elements.append(.init(id: id, kind: .group, title: parts.1, containerID: groups.last)); groups.append(id); continue
            }
            if line == "end" { guard !groups.isEmpty else { throw DiagramError.invalid("Mermaid subgraph") }; groups.removeLast(); continue }
            if ["style ", "classDef ", "class ", "linkStyle ", "direction ", "click "].contains(where: line.hasPrefix) {
                issues.append(.init("mermaidDirectives", "Presentation and click directives are retained as source text and are not executed.")); continue
            }
            var expression = line.trimmingCharacters(in: CharacterSet(charactersIn: ";"))
            var found = false
            while let (left, op, rawRight) = splitConnection(expression) {
                var right = rawRight.trimmingCharacters(in: .whitespaces), label = ""
                if right.hasPrefix("|") {
                    guard let close = right.dropFirst().firstIndex(of: "|") else { throw DiagramError.invalid("Mermaid edge label") }
                    label = String(right[right.index(after: right.startIndex)..<close]); right = String(right[right.index(after: close)...]).trimmingCharacters(in: .whitespaces)
                }
                let next = splitConnection(right), target = next?.0 ?? right
                let from = try register(left), to = try register(target)
                connections.append(.init(from: from, to: to, kind: .flow, route: .orthogonal, label: label, width: op == "==>" ? 2.5 : 1.5, dashed: op == "-.->", endArrow: op != "---"))
                found = true
                if next == nil { break }; expression = right
            }
            if !found { _ = try register(expression) }
        }
        guard groups.isEmpty, !elements.isEmpty else { throw DiagramError.invalid("Mermaid graph") }
        return .init(document: .init(id: ExchangeText.stableID(namespace, "document"), title: title,
                                     pages: [.init(id: ExchangeText.stableID(namespace, "page"), title: title, structure: .flow, elements: elements, connections: connections, metadata: ["direction": first.components(separatedBy: " ").last ?? "LR"])],
                                     metadata: ["importFormat": "mermaid", "mermaidDirection": first.components(separatedBy: " ").last ?? "LR"], legacyPayload: data), issues: Array(Set(issues)))
    }
    private static func parseNode(_ input: String) throws -> (String, String, DiagramElementKind) {
        let text = input.trimmingCharacters(in: .whitespaces)
        let expression = try NSRegularExpression(pattern: #"^([\p{L}_][\p{L}\p{N}_-]*)(.*)$"#)
        guard let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let idRange = Range(match.range(at: 1), in: text), let tailRange = Range(match.range(at: 2), in: text) else { throw DiagramError.unsupported("Mermaid node syntax: \(text.prefix(80))") }
        let id = String(text[idRange]), tail = text[tailRange].trimmingCharacters(in: .whitespaces)
        if tail.isEmpty { return (id, id, .rectangle) }
        let variants: [(String, String, DiagramElementKind)] = [("((", "))", .ellipse), ("[[", "]]", .rectangle), ("[", "]", .rectangle), ("(", ")", .roundedRectangle), ("{", "}", .diamond)]
        for (a, b, kind) in variants where tail.hasPrefix(a) && tail.hasSuffix(b) {
            var label = String(tail.dropFirst(a.count).dropLast(b.count)).trimmingCharacters(in: .whitespaces)
            if label.hasPrefix("\"") && label.hasSuffix("\"") { label = String(label.dropFirst().dropLast()) }
            return (id, ExchangeText.plain(label.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "&quot;", with: "\"")), kind)
        }
        throw DiagramError.unsupported("Mermaid node shape")
    }
    private static func splitConnection(_ line: String) -> (String, String, String)? {
        var quote = false, depth = 0, i = line.startIndex
        while i < line.endIndex {
            let c = line[i]
            if c == "\"" { quote.toggle() }
            if !quote {
                if "([{".contains(c) { depth += 1 }; if ")]}".contains(c) { depth -= 1 }
                if depth == 0 {
                    for op in ["-.->", "-->", "==>", "---"] where line[i...].hasPrefix(op) {
                        return (String(line[..<i]), op, String(line[line.index(i, offsetBy: op.count)...]))
                    }
                }
            }
            i = line.index(after: i)
        }
        return nil
    }
    private static func decodeMindmap(_ lines: [String], title: String, namespace: String) throws -> DiagramImportResult {
        var elements: [DiagramElement] = [], parents: [(Int, UUID)] = []
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("%%") { continue }
            let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0+($1 == "\t" ? 4 : 1) }
            while parents.last.map({ $0.0 >= indent }) == true { parents.removeLast() }
            let parsed = try? parseNode(trimmed)
            let id = ExchangeText.stableID(namespace, parsed.map { $0.0 } ?? "topic-\(elements.count)")
            guard !elements.contains(where: { $0.id == id }) else { throw DiagramError.invalid("Mermaid duplicate topic ID") }
            let label = parsed.map { $0.1 } ?? trimmed
            elements.append(.init(id: id, title: label, parentID: parents.last?.1, order: elements.count))
            parents.append((indent, id))
        }
        guard !elements.isEmpty else { throw DiagramError.invalid("empty Mermaid mindmap") }
        return .init(document: .init(id: ExchangeText.stableID(namespace, "document"), title: title, pages: [.init(id: ExchangeText.stableID(namespace, "page"), elements: elements)], metadata: ["importFormat": "mermaid"]))
    }
    static func encode(_ document: DiagramDocument, page: DiagramPage) throws -> DiagramExportResult {
        func identifier(_ id: UUID) -> String { "n"+id.uuidString.replacingOccurrences(of: "-", with: "") }
        func label(_ text: String) -> String { text.replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "|", with: "&#124;") }
        var output = "", issues = ExchangeText.outlineIssues(page, tasks: document.tasks)
        if page.structure == .flow || page.elements.contains(where: { !$0.kind.isTopic }) || !page.connections.isEmpty {
            output = "flowchart LR\n"
            for node in page.elements {
                let a: String, b: String
                switch node.kind { case .diamond: a = "{"; b = "}"; case .ellipse: a = "(("; b = "))"; case .roundedRectangle: a = "("; b = ")"; default: a = "["; b = "]" }
                output += "  \(identifier(node.id))\(a)\"\(label(node.title))\"\(b)\n"
            }
            for node in page.elements { if let parent = node.parentID { output += "  \(identifier(parent)) --> \(identifier(node.id))\n" } }
            for edge in page.connections {
                let op = edge.dashed ? "-.->" : edge.endArrow ? "-->" : "---"
                let annotation = edge.label.isEmpty ? "" : "|\(label(edge.label))|"
                output += "  \(identifier(edge.from)) \(op)\(annotation) \(identifier(edge.to))\n"
            }
            issues.removeAll { $0.code == "relationships" }
            if page.elements.contains(where: \.kind.isContainer) { issues.append(.init("mermaidContainers", "Container titles are exported as nodes; native file retains containment.")) }
        } else {
            output = "mindmap\n"
            let index = DiagramPageIndex(page)
            var stack = page.elements.filter { $0.parentID == nil }.reversed().map { ($0, 1) }
            while let (node, depth) = stack.popLast() {
                guard depth <= 256 else { throw DiagramError.unsupported("Mermaid depth") }
                output += String(repeating: "  ", count: depth)+identifier(node.id)+"[\"\(label(node.title))\"]\n"
                stack += (index.children[node.id] ?? []).reversed().compactMap { index.elements[$0].map { ($0, depth+1) } }
            }
        }
        return .init(data: Data(output.utf8), format: .mermaid, issues: issues)
    }
    private static func date(_ string: String) -> Date? {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        return formatter.date(from: string)
    }
    private static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"; return formatter.string(from: date)
    }
    private static func decodeGantt(_ lines: [String], title: String, namespace: String) throws -> DiagramImportResult {
        var records: [(DiagramTask, String, [String], Int)] = [], ids: [String: UUID] = [:], calendar = DiagramWorkCalendar(workingWeekdays: Set(1...7))
        for raw in lines.dropFirst() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("%%") || line.hasPrefix("section ") || line.hasPrefix("title ") || line.hasPrefix("axisFormat ") || line.hasPrefix("tickInterval ") { continue }
            if line.hasPrefix("dateFormat ") { guard line == "dateFormat YYYY-MM-DD" else { throw DiagramError.unsupported("Mermaid Gantt date format") }; continue }
            if line.hasPrefix("excludes ") { if line.contains("weekends") { calendar = .init() }; continue }
            guard let colon = line.firstIndex(of: ":") else { throw DiagramError.invalid("Gantt task") }
            let label = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            var fields = line[line.index(after: colon)...].components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            var status = DiagramTaskStatus.todo, priority = 0
            while let flag = fields.first, ["done", "active", "crit", "milestone"].contains(flag) {
                fields.removeFirst(); if flag == "done" { status = .done }; if flag == "active" { status = .inProgress }; if flag == "crit" { priority = 3 }
            }
            guard fields.count == 3 else { throw DiagramError.unsupported("Gantt task requires id, start/after and duration/end") }
            let rawID = fields[0], id = ExchangeText.stableID(namespace, rawID)
            guard ids[rawID] == nil else { throw DiagramError.invalid("Gantt duplicate task") }; ids[rawID] = id
            let start = date(fields[1]), after = fields[1].hasPrefix("after ") ? fields[1].dropFirst(6).split(separator: " ").map(String.init) : []
            guard start != nil || !after.isEmpty else { throw DiagramError.invalid("Gantt start") }
            let duration: Int
            var end: Date? = nil
            if fields[2].hasSuffix("d"), let days = Int(fields[2].dropLast()), (1...36_500).contains(days) { duration = days }
            else if let parsedEnd = date(fields[2]), let start { end = parsedEnd; duration = max(1, (calendar.calendar.dateComponents([.day], from: start, to: parsedEnd).day ?? 0)+1) }
            else { throw DiagramError.unsupported("Gantt day duration") }
            let task = DiagramTask(id: id, title: label, status: status, progress: status == .inProgress ? 0.5 : 0, priority: priority, start: start, end: end)
            records.append((task, rawID, after, duration))
        }
        guard let baseline = records.compactMap({ $0.0.start }).min() else { throw DiagramError.invalid("Gantt needs an absolute starting date") }
        var tasks: [DiagramTask] = [], dependencies: [DiagramTaskDependency] = []
        for (record, _, after, duration) in records {
            var task = record; task.start = record.start ?? baseline
            if let end = record.end { task.end = end }
            else { task.end = try calendar.addingWorkingDays(duration-1, to: task.start!) }
            tasks.append(task)
            for key in after { guard let predecessor = ids[key] else { throw DiagramError.invalid("Gantt missing predecessor") }; dependencies.append(.init(predecessorID: predecessor, successorID: record.id)) }
        }
        let root = ExchangeText.stableID(namespace, "project")
        var document = DiagramDocument(id: ExchangeText.stableID(namespace, "document"), title: title,
                                       pages: [.init(id: ExchangeText.stableID(namespace, "page"), structure: .right, elements: [.init(id: root, title: title)] + tasks.enumerated().map { i, t in .init(id: ExchangeText.stableID(namespace, "topic:"+t.id.uuidString), title: t.title, parentID: root, order: i, taskID: t.id) })],
                                       tasks: tasks, dependencies: dependencies, metadata: ["importFormat": "mermaid-gantt"])
        let schedule = try DiagramPlanning.schedule(document, from: baseline, workCalendar: calendar)
        document.tasks = document.tasks.map { original in var task = original; task.start = schedule[task.id]?.start; task.end = schedule[task.id]?.end; return task }
        return .init(document: document)
    }
    static func encodeGantt(_ document: DiagramDocument) throws -> DiagramExportResult {
        guard document.tasks.allSatisfy({ $0.start != nil && $0.end != nil }), !document.tasks.isEmpty else { throw DiagramError.invalid("Gantt export requires task dates") }
        let calendar = document.workCalendar.calendar, formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"; formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = calendar.timeZone
        var output = "gantt\n  dateFormat YYYY-MM-DD\n  title \(document.title.replacingOccurrences(of: "\n", with: " "))\n  section Plan\n"
        for task in document.tasks {
            let id = "t"+task.id.uuidString.replacingOccurrences(of: "-", with: "")
            let flags = task.status == .done ? "done, " : task.status == .inProgress ? "active, " : ""
            let predecessors = document.dependencies.filter { $0.successorID == task.id && $0.lagDays == 0 }.map { "t"+$0.predecessorID.uuidString.replacingOccurrences(of: "-", with: "") }
            let start = predecessors.isEmpty ? formatter.string(from: task.start!) : "after "+predecessors.joined(separator: " ")
            let days = max(1,(calendar.dateComponents([.day],from: calendar.startOfDay(for: task.start!),to: calendar.startOfDay(for: task.end!)).day ?? 0)+1)
            output += "  \(task.title.replacingOccurrences(of: ":", with: "：").replacingOccurrences(of: "\n", with: " ")) :\(flags)\(id), \(start), \(days)d\n"
        }
        var issues = document.dependencies.contains(where: { $0.lagDays != 0 }) ? [DiagramExchangeIssue("dependencyLag", "Nonzero dependency lag is represented by dates rather than Mermaid after syntax.")] : []
        if !document.dependencies.isEmpty { issues.append(.init("dependencyScheduling", "Mermaid after dependencies may recalculate manually chosen dates. Keep the native file for exact schedules.")) }
        return .init(data: Data(output.utf8), format: .mermaid, issues: issues)
    }
}
extension DiagramExchange {
    public static func exportMermaidGantt(_ document: DiagramDocument) throws -> DiagramExportResult { try document.validate(); return try MermaidCodec.encodeGantt(document) }
}
