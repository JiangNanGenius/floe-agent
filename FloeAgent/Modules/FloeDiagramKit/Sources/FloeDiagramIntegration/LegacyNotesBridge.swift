// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeDiagramCore

/// Value-only bridge to NoteDocument schema 1–2. It has no dependency on the complete Floe App package graph.
public enum LegacyNotesBridge {
    private static func stableID(_ value: String) -> UUID {
        let h = DiagramCodec.digest(Data(value.utf8))
        let s = Array(h)
        return UUID(uuidString: String(s[0..<8]) + "-" + String(s[8..<12]) + "-" + String(s[12..<16]) + "-" + String(s[16..<20]) + "-" + String(s[20..<32]))!
    }
    private static func uuid(_ object: [String: Any], _ key: String) throws -> UUID {
        guard let string = object[key] as? String, let id = UUID(uuidString: string) else { throw DiagramError.invalid("legacy \(key)") }; return id
    }
    private static func json(_ object: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self)
    }
    private static func source(_ object: [String: Any]) throws -> DiagramSourceReference {
        let data = try json(object)
        return .init(id: stableID(data), documentID: try uuid(object, "documentID").uuidString,
                     kind: object["space"] as? String ?? "notes", locator: data,
                     title: "Source", sourceRevision: (object["revision"] as? Int).map(String.init))
    }
    public static func importJSON(_ data: Data, assets: [DiagramAsset] = []) throws -> DiagramDocument {
        guard data.count <= 64 * 1_024 * 1_024,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["kind"] as? String == "mindMap", (1...2).contains(object["schemaVersion"] as? Int ?? 1),
              let nodes = object["nodes"] as? [[String: Any]], !nodes.isEmpty else { throw DiagramError.invalid("legacy mind map") }
        let documentID = try uuid(object, "id")
        let direction = object["mindMapDirection"] as? Int ?? 2
        var elements: [DiagramElement] = []
        for node in nodes {
            let id = try uuid(node, "id")
            let parent = (node["parentID"] as? String).flatMap(UUID.init(uuidString:))
            var blocks: [DiagramContentBlock] = []
            if let note = node["note"] as? String, !note.isEmpty { blocks.append(.note(note)) }
            var images: Set<UUID> = []
            if let image = (node["imageResourceID"] as? String).flatMap(UUID.init(uuidString:)) {
                blocks.append(.image(assetID: image, caption: "")); images.insert(image)
            }
            var sources = try (node["source"] as? [String: Any]).map { [try source($0)] } ?? []
            for attachment in node["attachments"] as? [[String: Any]] ?? [] {
                let resource = try uuid(attachment, "resourceID")
                if attachment["kind"] as? String == "image" {
                    if images.insert(resource).inserted { blocks.append(.image(assetID: resource, caption: attachment["caption"] as? String ?? "")) }
                } else { blocks.append(.attachment(resource)) }
                if let reference = attachment["source"] as? [String: Any] { sources.append(try source(reference)) }
            }
            var frame: DiagramRect? = nil
            if let position = node["position"] as? [String: Any], let x = position["x"] as? Double, let y = position["y"] as? Double {
                frame = .init(x: x - 80, y: y - 28)
            }
            let rawStyle = node["style"] as? [String: String] ?? [:]
            let style = DiagramStyle(fill: node["color"] as? String ?? rawStyle["background"] ?? "surface",
                                     stroke: rawStyle["borderColor"] ?? "border", text: rawStyle["color"] ?? "text",
                                     lineWidth: Double(rawStyle["borderWidth"] ?? "") ?? 1,
                                     cornerRadius: Double(rawStyle["borderRadius"] ?? "") ?? 12,
                                     fontSize: Double(rawStyle["fontSize"] ?? "") ?? 15, bold: rawStyle["fontWeight"] == "bold")
            let localStructure: DiagramStructure? = (node["direction"] as? Int).map { $0 == 0 ? .left : .right }
            elements.append(.init(id: id, title: node["title"] as? String ?? "", parentID: parent,
                                  order: node["order"] as? Int ?? 0, frame: frame, structure: localStructure,
                                  collapsed: node["isCollapsed"] as? Bool ?? false, content: blocks, style: style,
                                  tags: node["tags"] as? [String] ?? [], markers: node["icons"] as? [String] ?? [],
                                  sources: sources, links: (node["hyperLink"] as? String).map { [.init(url: $0)] } ?? [],
                                  metadata: ["legacyNode": try json(node)]))
        }
        for summary in object["summaries"] as? [[String: Any]] ?? [] {
            let parent = try uuid(summary, "parent"), start = summary["start"] as? Int ?? 0, end = summary["end"] as? Int ?? 0
            let children = elements.filter { $0.parentID == parent }.sorted { $0.order < $1.order }
            guard start >= 0, end >= start, end < children.count else { throw DiagramError.invalid("legacy summary range") }
            elements.append(.init(id: try uuid(summary, "id"), kind: .summary, title: summary["label"] as? String ?? "",
                                  memberIDs: Array(children[start...end]).map(\.id), metadata: ["legacySummary": try json(summary)]))
        }
        let connections = try (object["connections"] as? [[String: Any]] ?? []).map { edge -> DiagramConnection in
            let style = edge["style"] as? [String: String] ?? [:]
            var metadata = ["legacyConnection": try json(edge)]
            if let offset = edge["delta1"] as? [String: Any] { metadata["legacyControl1"] = try json(offset) }
            if let offset = edge["delta2"] as? [String: Any] { metadata["legacyControl2"] = try json(offset) }
            return .init(id: try uuid(edge, "id"), from: try uuid(edge, "from"), to: try uuid(edge, "to"),
                         label: edge["title"] as? String ?? "", color: style["color"] ?? "edge",
                         width: Double(style["width"] ?? "") ?? 1.5, dashed: style["dashed"] == "true",
                         startArrow: edge["bidirectional"] as? Bool ?? false, endArrow: true, metadata: metadata)
        }
        let page = DiagramPage(id: stableID(documentID.uuidString + ":overview"), title: "总览",
                               structure: direction == 0 ? .left : direction == 1 ? .right : .balanced,
                               elements: elements, connections: connections)
        let document = DiagramDocument(id: documentID, revision: object["revision"] as? Int ?? 0,
                                       title: object["title"] as? String ?? "Imported", pages: [page], assets: assets,
                                       metadata: ["legacyFormat": "NoteDocument"], legacyPayload: data)
        try document.validate()
        return document
    }
    /// New features are explicitly refused. The original legacy bytes provide all unrelated fields unchanged.
    public static func exportJSON(_ document: DiagramDocument) throws -> Data {
        guard document.pages.count == 1, document.tasks.isEmpty, document.dependencies.isEmpty,
              let data = document.legacyPayload, var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["id"] as? String).flatMap(UUID.init(uuidString:)) == document.id
        else { throw DiagramError.unsupported("legacy export requires an imported single-page map") }
        let page = document.pages[0]
        let original = try importJSON(data, assets: document.assets)
        guard page.ink == nil, page.elements.allSatisfy({ $0.kind == .topic || $0.kind == .summary }),
              page.elements.allSatisfy({ $0.content.allSatisfy { if case .note = $0 { return true }; return $0.assetID != nil } && $0.containerID == nil && !$0.isLocked }),
              page.connections.allSatisfy({ $0.route == .curve && $0.waypoints.isEmpty && $0.endArrow && !$0.isLocked && $0.labelPosition == 0.5 && $0.sourceAnchor == .automatic && $0.targetAnchor == .automatic }),
              [.balanced, .left, .right].contains(page.structure),
              page.elements.filter({ $0.kind == .topic && $0.parentID == nil }).count == 1,
              page.elements.allSatisfy({ $0.sources == (original.element($0.id)?.sources ?? []) && $0.links.count <= 1 && $0.links.allSatisfy { $0.url != nil && $0.pageID == nil && $0.elementID == nil } }),
              page.elements.allSatisfy({ $0.frame.map { $0.width == 160 && $0.height == 56 } ?? true })
        else { throw DiagramError.unsupported("legacy format cannot preserve these features") }
        object["title"] = document.title; object["revision"] = document.revision
        object["mindMapDirection"] = page.structure == .left ? 0 : page.structure == .right ? 1 : 2
        object["nodes"] = try page.elements.filter { $0.kind == .topic }.map { node -> [String: Any] in
            var value = try node.metadata["legacyNode"].flatMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
            value["id"] = node.id.uuidString; value["parentID"] = node.parentID?.uuidString
            value["title"] = node.title; value["order"] = node.order; value["isCollapsed"] = node.collapsed
            value["note"] = node.content.compactMap { if case .note(let text) = $0 { return text }; return nil }.joined(separator: "\n")
            value["tags"] = node.tags; value["icons"] = node.markers; value["color"] = node.style.fill
            var style = value["style"] as? [String: String] ?? [:]
            style["background"] = node.style.fill; style["borderColor"] = node.style.stroke; style["color"] = node.style.text
            style["fontSize"] = String(node.style.fontSize); style["fontWeight"] = node.style.bold ? "bold" : "normal"
            style["borderWidth"] = String(node.style.lineWidth); style["borderRadius"] = String(node.style.cornerRadius); value["style"] = style
            value["direction"] = node.structure.map { $0 == .left ? 0 : 1 }; value["hyperLink"] = node.links.first?.url
            let blocks = node.content, images = blocks.compactMap { block -> UUID? in if case .image(let id, _) = block { id } else { nil } }
            value["imageResourceID"] = images.first?.uuidString
            let existing = value["attachments"] as? [[String: Any]] ?? []
            value["attachments"] = blocks.compactMap { block -> [String: Any]? in
                guard let id = block.assetID, let asset = document.assets.first(where: { $0.id == id }) else { return nil }
                var attachment = existing.first { $0["resourceID"] as? String == id.uuidString } ?? [:]
                attachment["resourceID"] = id.uuidString; attachment["fileName"] = asset.fileName; attachment["mediaType"] = asset.mediaType
                if case .image(_,let caption) = block { attachment["kind"] = "image"; attachment["caption"] = caption } else { attachment["kind"] = attachment["kind"] as? String ?? "file" }
                return attachment
            }
            if let frame = node.frame { value["position"] = ["x": frame.center.x, "y": frame.center.y] } else { value["position"] = nil }
            return value
        }
        object["connections"] = try page.connections.map { edge -> [String: Any] in
            var value = try edge.metadata["legacyConnection"].flatMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
            value["id"] = edge.id.uuidString; value["from"] = edge.from.uuidString; value["to"] = edge.to.uuidString
            value["title"] = edge.label; value["bidirectional"] = edge.startArrow
            var style = value["style"] as? [String: String] ?? [:]; style["color"] = edge.color; style["width"] = String(edge.width); style["dashed"] = String(edge.dashed); value["style"] = style
            for (field, key) in [("delta1", "legacyControl1"), ("delta2", "legacyControl2")] {
                value[field] = try edge.metadata[key].map { try JSONSerialization.jsonObject(with: Data($0.utf8)) }
            }
            return value
        }
        object["summaries"] = try page.elements.filter { $0.kind == .summary }.map { summary -> [String: Any] in
            let members = page.elements.filter { summary.memberIDs.contains($0.id) }
            guard let first = members.first, let parent = first.parentID, members.allSatisfy({ $0.parentID == parent }) else { throw DiagramError.unsupported("legacy summary requires sibling range") }
            let siblings = page.elements.filter { $0.parentID == parent }.sorted { $0.order < $1.order }, selected = siblings.indices.filter { summary.memberIDs.contains(siblings[$0].id) }
            guard let start = selected.first, let end = selected.last, end-start+1 == selected.count else { throw DiagramError.unsupported("noncontiguous summary range") }
            var value = try summary.metadata["legacySummary"].flatMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
            value["id"] = summary.id.uuidString; value["parent"] = parent.uuidString; value["start"] = start; value["end"] = end; value["label"] = summary.title; return value
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
