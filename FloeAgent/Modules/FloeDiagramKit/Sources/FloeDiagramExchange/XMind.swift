// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeDiagramCore
import FloeDiagramIntegration

/// Native subset of XMind's public content model. Source: xmindltd/xmind-sdk-js, common/model.ts.
enum XMindCodec {
    static func structure(_ value: String?) -> DiagramStructure {
        let value = value?.lowercased() ?? ""
        if value.contains("fishbone") { return .fishbone }; if value.contains("timeline") { return .timeline }
        if value.contains("org-chart") { return .organization }; if value.contains("tree") { return .tree }
        if value.contains("logic.left") { return .left }; if value.contains("logic.right") { return .right }
        return .balanced
    }
    static func structureClass(_ value: DiagramStructure) -> String {
        switch value {
        case .left: "org.xmind.ui.logic.left"
        case .right: "org.xmind.ui.logic.right"
        case .tree: "org.xmind.ui.tree.right"
        case .organization: "org.xmind.ui.org-chart.down"
        case .fishbone: "org.xmind.ui.fishbone.rightHeaded"
        case .timeline: "org.xmind.ui.timeline.horizontal"
        default: "org.xmind.ui.map.unbalanced"
        }
    }
    static func decode(_ data: Data) throws -> DiagramImportResult {
        let files = try DiagramZIP.unpack(data), namespace = DiagramCodec.digest(data)
        if let json = files["content.json"] {
            guard let sheets = try JSONSerialization.jsonObject(with: json) as? [[String: Any]], !sheets.isEmpty else { throw DiagramError.invalid("XMind sheets") }
            var pages: [DiagramPage] = [], assets: [DiagramAsset] = [], assetData: [UUID: Data] = [:], issues: [DiagramExchangeIssue] = []
            for (sheetNumber, sheet) in sheets.enumerated() {
                guard let root = sheet["rootTopic"] as? [String: Any] else { throw DiagramError.invalid("XMind root") }
                var elements: [DiagramElement] = [], external: [String: UUID] = [:]
                var stack: [([String: Any], UUID?, Bool, Int)] = [(root, nil, false, 0)], ordinal = 0
                while let (topic, parent, floating, depth) = stack.popLast() {
                    guard depth < 256 else { throw DiagramError.invalid("XMind topic depth") }
                    let rawID = topic["id"] as? String ?? "\(sheetNumber)-\(ordinal)"
                    guard external[rawID] == nil else { throw DiagramError.invalid("duplicate XMind identity") }
                    let id = ExchangeText.stableID(namespace, rawID); external[rawID] = id
                    var content: [DiagramContentBlock] = []
                    if let notes = topic["notes"] as? [String: Any], let plain = notes["plain"] as? [String: Any], let text = plain["content"] as? String, !text.isEmpty { content.append(.note(text)) }
                    if let image = topic["image"] as? [String: Any], let src = image["src"] as? String {
                        let path = src.hasPrefix("xap:") ? String(src.dropFirst(4)) : src
                        if DiagramZIP.validPath(path), let bytes = files[path] {
                            let assetID = ExchangeText.stableID(namespace, "asset:"+path)
                            if assetData[assetID] == nil {
                                let name = (path as NSString).lastPathComponent
                                assets.append(.init(id: assetID, fileName: name.isEmpty ? "image" : name, mediaType: imageMediaType(bytes), byteCount: bytes.count, sha256: DiagramCodec.digest(bytes)))
                                assetData[assetID] = bytes
                            }
                            content.append(.image(assetID: assetID, caption: ""))
                        } else { issues.append(.init("externalImage", "An XMind image is not present in the file; no remote resource was fetched.")) }
                    }
                    let properties = ((topic["style"] as? [String: Any])?["properties"] as? [String: String]) ?? [:]
                    var frame: DiagramRect? = nil
                    if let position = topic["position"] as? [String: Double], let x = position["x"], let y = position["y"] { frame = .init(x: x-80, y: y-28) }
                    let labels = topic["labels"] as? [String] ?? (topic["labels"] as? String).map { [$0] } ?? []
                    let markers = (topic["markers"] as? [[String: String]] ?? []).compactMap { $0["markerId"] }
                    let fontSize = Double((properties["fo:font-size"] ?? "15").replacingOccurrences(of: "pt", with: "")) ?? 15
                    elements.append(.init(id: id, kind: floating ? .floatingTopic : .topic, title: topic["title"] as? String ?? "",
                                          parentID: parent, order: ordinal, frame: frame,
                                          structure: (topic["structureClass"] as? String).map(structure),
                                          collapsed: topic["branch"] as? String == "folded", content: content,
                                          style: .init(fill: properties["svg:fill"] ?? "surface", text: properties["fo:color"] ?? "text", fontSize: min(200, max(8, fontSize)), bold: properties["fo:font-weight"] == "bold"),
                                          tags: labels, markers: markers, links: (topic["href"] as? String).map { [.init(url: $0)] } ?? [], metadata: ["externalID": rawID]))
                    ordinal += 1
                    if topic["boundaries"] != nil || topic["summaries"] != nil { issues.append(.init("xmindRanges", "XMind range decorations are retained in the original file payload; native range editing needs conversion.")) }
                    if let children = topic["children"] as? [String: [[String: Any]]] {
                        for key in children.keys.sorted().reversed() {
                            stack += children[key]!.reversed().map { ($0, key == "attached" ? Optional(id) : nil, key != "attached", depth+1) }
                        }
                    }
                }
                var connections: [DiagramConnection] = []
                for raw in sheet["relationships"] as? [[String: Any]] ?? [] {
                    guard let a = (raw["end1Id"] as? String).flatMap({ external[$0] }), let b = (raw["end2Id"] as? String).flatMap({ external[$0] }) else {
                        issues.append(.init("relationshipTarget", "An XMind relationship target is missing.")); continue
                    }
                    connections.append(.init(id: ExchangeText.stableID(namespace, raw["id"] as? String ?? UUID().uuidString), from: a, to: b, label: raw["title"] as? String ?? "", endArrow: true))
                }
                pages.append(.init(id: ExchangeText.stableID(namespace, sheet["id"] as? String ?? "sheet-\(sheetNumber)"), title: sheet["title"] as? String ?? "Sheet \(sheetNumber+1)",
                                   structure: structure(root["structureClass"] as? String), elements: elements, connections: connections))
            }
            let document = DiagramDocument(id: ExchangeText.stableID(namespace, "document"), title: pages[0].title, pages: pages, assets: assets,
                                           metadata: ["importFormat": "xmind"], legacyPayload: data)
            return .init(document: document, assets: assetData, issues: Array(Set(issues)).sorted { $0.code < $1.code })
        }
        guard let xmlData = files["content.xml"] else { throw DiagramError.invalid("XMind content missing") }
        let xml = try DiagramXML.parse(xmlData), sheets = xml.children.filter { $0.name == "sheet" }
        var pages: [DiagramPage] = [], issues: [DiagramExchangeIssue] = []
        for (number, sheet) in sheets.enumerated() {
            guard let root = sheet.child("topic") else { continue }
            var elements: [DiagramElement] = [], ids: [String: UUID] = [:], stack = [(root, nil as UUID?)], ordinal = 0
            while let (topic, parent) = stack.popLast() {
                let raw = topic.attributes["id"] ?? "topic-\(ordinal)", id = ExchangeText.stableID(namespace, raw); ids[raw] = id
                let note = topic.child("notes")?.child("plain")?.allText ?? ""
                elements.append(.init(id: id, title: topic.child("title")?.allText ?? "", parentID: parent, order: ordinal,
                                      structure: topic.attributes["structure-class"].map(structure), collapsed: topic.attributes["branch"] == "folded",
                                      content: note.isEmpty ? [] : [.note(note)], metadata: ["externalID": raw]))
                ordinal += 1
                for group in topic.child("children")?.children ?? [] where group.name == "topics" {
                    stack += group.children.filter { $0.name == "topic" }.reversed().map { ($0, group.attributes["type"] == "detached" ? nil : Optional(id)) }
                }
                if topic.child("image") != nil || topic.child("summaries") != nil || topic.child("boundaries") != nil { issues.append(.init("legacyXmindExtras", "Legacy images/ranges remain in the original XMind payload.")) }
            }
            let edges = (sheet.child("relationships")?.children ?? []).compactMap { raw -> DiagramConnection? in
                guard let a = raw.attributes["end1"].flatMap({ ids[$0] }), let b = raw.attributes["end2"].flatMap({ ids[$0] }) else { return nil }
                return .init(from: a, to: b, label: raw.child("title")?.allText ?? "", endArrow: true)
            }
            pages.append(.init(id: ExchangeText.stableID(namespace, sheet.attributes["id"] ?? "sheet-\(number)"), title: sheet.child("title")?.allText ?? "Sheet \(number+1)", structure: structure(root.attributes["structure-class"]), elements: elements, connections: edges))
        }
        guard !pages.isEmpty else { throw DiagramError.invalid("XMind XML sheets") }
        return .init(document: .init(id: ExchangeText.stableID(namespace, "document"), title: pages[0].title, pages: pages, metadata: ["importFormat": "xmind-xml"], legacyPayload: data), issues: Array(Set(issues)))
    }
    static func encode(_ document: DiagramDocument, resolver: (any DiagramAssetResolver)?) async throws -> DiagramExportResult {
        var sheets: [[String: Any]] = [], files: [String: Data] = [:], issues: [DiagramExchangeIssue] = []
        let assetMap = Dictionary(uniqueKeysWithValues: document.assets.map { ($0.id, $0) })
        for page in document.pages {
            let index = DiagramPageIndex(page)
            let roots = page.elements.filter { $0.parentID == nil && $0.kind.isTopic }.sorted { $0.order < $1.order }
            guard let root = roots.first else { throw DiagramError.unsupported("XMind export requires at least one topic per page") }
            var queue = [root.id], cursor = 0
            let extraRoots = page.elements.filter { $0.parentID == nil && $0.id != root.id }
            queue += extraRoots.map(\.id)
            while cursor < queue.count { let id = queue[cursor]; cursor += 1; queue += index.children[id] ?? [] }
            var topics: [UUID: [String: Any]] = [:]
            for id in queue.reversed() {
                try Task.checkCancellation()
                let node = index.elements[id]!
                var properties: [String: String] = ["fo:font-size": "\(node.style.fontSize)pt", "fo:font-weight": node.style.bold ? "bold" : "normal"]
                properties["svg:fill"] = ExchangeText.colorHex(node.style.fill); properties["fo:color"] = ExchangeText.colorHex(node.style.text)
                var value: [String: Any] = ["id": id.uuidString, "title": node.title, "labels": node.tags,
                                           "style": ["id": UUID().uuidString, "type": "topic", "properties": properties],
                                           "markers": node.markers.map { ["markerId": $0] }]
                if let s = node.structure { value["structureClass"] = structureClass(s) }
                if node.collapsed { value["branch"] = "folded" }
                if let frame = node.frame { value["position"] = ["x": frame.center.x, "y": frame.center.y] }
                if let url = node.links.first?.url { value["href"] = url }
                let notes = node.content.filter { $0.assetID == nil }.map(\.plainText).joined(separator: "\n")
                if !notes.isEmpty { value["notes"] = ["plain": ["content": notes]] }
                if let imageID = node.content.compactMap(\.assetID).first, let asset = assetMap[imageID], asset.mediaType.hasPrefix("image/") {
                    guard let resolver else { throw DiagramError.invalid("XMind image resolver required") }
                    let bytes = try await resolver.data(for: asset)
                    guard bytes.count == asset.byteCount, asset.sha256.map({ DiagramCodec.digest(bytes) == $0 }) ?? true else { throw DiagramError.invalid("XMind image integrity") }
                    let path = "resources/"+asset.id.uuidString
                    files[path] = bytes; value["image"] = ["src": "xap:"+path, "width": 160, "height": 96, "align": "center"]
                }
                let children = (index.children[id] ?? []).compactMap { topics[$0] }
                if !children.isEmpty { value["children"] = ["attached": children] }
                topics[id] = value
            }
            var rootTopic = topics[root.id]!
            rootTopic["structureClass"] = structureClass(page.structure)
            if !extraRoots.isEmpty {
                var children = rootTopic["children"] as? [String: [[String: Any]]] ?? [:]
                children["detached"] = extraRoots.compactMap { topics[$0.id] }; rootTopic["children"] = children
            }
            let relationships = page.connections.map { ["id": $0.id.uuidString, "end1Id": $0.from.uuidString, "end2Id": $0.to.uuidString, "title": $0.label] }
            sheets.append(["id": page.id.uuidString, "title": page.title, "rootTopic": rootTopic, "relationships": relationships])
            issues += ExchangeText.outlineIssues(page, tasks: document.tasks).filter { $0.code != "relationships" }
            if page.ink != nil { issues.append(.init("handwriting", "Pencil ink remains in the native file.")) }
        }
        files["content.json"] = try JSONSerialization.data(withJSONObject: sheets, options: [.sortedKeys])
        files["metadata.json"] = try JSONSerialization.data(withJSONObject: ["creator": ["name": "FloeDiagramKit"], "activeSheetId": document.pages[0].id.uuidString], options: [.sortedKeys])
        var entries: [String: [String: String]] = [:]; for key in files.keys { entries[key] = [:] }
        files["manifest.json"] = try JSONSerialization.data(withJSONObject: ["file-entries": entries], options: [.sortedKeys])
        return .init(data: try DiagramZIP.pack(files), format: .xmind, issues: Array(Set(issues)).sorted { $0.code < $1.code })
    }
    private static func imageMediaType(_ data: Data) -> String {
        if data.prefix(4) == Data([137, 80, 78, 71]) { return "image/png" }
        if data.prefix(2) == Data([255, 216]) { return "image/jpeg" }
        if String(data: data.prefix(6), encoding: .ascii)?.hasPrefix("GIF") == true { return "image/gif" }
        return "application/octet-stream"
    }
}
