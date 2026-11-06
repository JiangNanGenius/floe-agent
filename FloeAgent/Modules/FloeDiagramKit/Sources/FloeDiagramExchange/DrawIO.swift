// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeDiagramCore
import FloeDiagramLayout

enum DrawIOCodec {
    static func styles(_ value: String) -> [String: String] {
        var result: [String: String] = [:]
        for item in value.split(separator: ";") {
            let parts = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            result[String(parts[0])] = parts.count == 2 ? String(parts[1]) : "1"
        }
        return result
    }
    static func decode(_ data: Data, title: String) throws -> DiagramImportResult {
        let xml = try DiagramXML.parse(data), namespace = DiagramCodec.digest(data)
        let diagrams = xml.name == "mxfile" ? xml.children.filter { $0.name == "diagram" } : [xml]
        var pages: [DiagramPage] = [], issues: [DiagramExchangeIssue] = []
        for (number, diagram) in diagrams.enumerated() {
            let graph: DiagramXMLNode
            if diagram.name == "mxGraphModel" { graph = diagram }
            else if let model = diagram.child("mxGraphModel") { graph = model }
            else {
                let compressedText = diagram.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if compressedText.hasPrefix("<") { graph = try DiagramXML.parse(Data(compressedText.utf8)) }
                else {
                    guard let compressed = Data(base64Encoded: compressedText) else { throw DiagramError.invalid("draw.io encoded page") }
                    let inflated = try DiagramRawDeflate.decode(compressed)
                    guard let encoded = String(data: inflated, encoding: .utf8), let plain = encoded.removingPercentEncoding else { throw DiagramError.invalid("draw.io URI content") }
                    graph = try DiagramXML.parse(Data(plain.utf8))
                }
            }
            guard graph.name == "mxGraphModel", let root = graph.child("root") else { throw DiagramError.invalid("draw.io graph model") }
            let cells = root.descendants("mxCell")
            var rawCells: [String: DiagramXMLNode] = [:], attributes: [String: [String: String]] = [:]
            for cell in cells {
                var attrs = cell.attributes
                if let wrapper = cell.parent, wrapper.name != "root" && wrapper.name != "mxCell" {
                    attrs["id"] = attrs["id"] ?? wrapper.attributes["id"]
                    attrs["value"] = attrs["value"] ?? wrapper.attributes["label"]
                    attrs["link"] = attrs["link"] ?? wrapper.attributes["link"]
                }
                guard let id = attrs["id"], rawCells[id] == nil else { throw DiagramError.invalid("draw.io cell identity") }
                rawCells[id] = cell; attributes[id] = attrs
            }
            let vertexIDs = Set(attributes.filter { $0.value["vertex"] == "1" }.map(\.key))
            let ids = Dictionary(uniqueKeysWithValues: vertexIDs.map { ($0, ExchangeText.stableID(namespace, $0)) })
            func offset(_ raw: String) throws -> DiagramPoint {
                var p = DiagramPoint.zero, current: String? = raw, visited: Set<String> = []
                while let id = current {
                    guard visited.insert(id).inserted else { throw DiagramError.invalid("draw.io parent cycle") }
                    if let geometry = rawCells[id]?.child("mxGeometry") {
                        if geometry.attributes["relative"] == "1", vertexIDs.contains(id) { throw DiagramError.unsupported("relative draw.io vertex geometry") }
                        p.x += Double(geometry.attributes["x"] ?? "") ?? 0; p.y += Double(geometry.attributes["y"] ?? "") ?? 0
                    }
                    current = attributes[id]?["parent"]
                }
                return p
            }
            var elements: [DiagramElement] = [], connections: [DiagramConnection] = []
            for raw in vertexIDs.sorted() {
                let cell = rawCells[raw]!, attrs = attributes[raw]!, properties = styles(attrs["style"] ?? "")
                let g = cell.child("mxGeometry"), position = try offset(raw)
                let kind: DiagramElementKind
                if properties["swimlane"] != nil || properties["shape"] == "swimlane" { kind = .swimlane }
                else if properties["group"] != nil { kind = .group }
                else if properties["ellipse"] != nil || properties["shape"] == "ellipse" { kind = .ellipse }
                else if properties["rhombus"] != nil || properties["shape"] == "rhombus" { kind = .diamond }
                else if properties["shape"] == "parallelogram" { kind = .parallelogram }
                else if properties["text"] != nil { kind = .text }
                else { kind = properties["rounded"] == "1" ? .roundedRectangle : .rectangle }
                let container = attrs["parent"].flatMap { ids[$0] }
                var links: [DiagramLink] = []
                if let link = attrs["link"] {
                    if link.hasPrefix("data:page/id,") { links.append(.init(pageID: ExchangeText.stableID(namespace, String(link.dropFirst(13))))) }
                    else if link.hasPrefix("data:page/") { links.append(.init(pageID: ExchangeText.stableID(namespace, String(link.dropFirst(10))))) }
                    else { links.append(.init(url: link)) }
                }
                let rawKind = attrs["floeKind"].flatMap(DiagramElementKind.init(rawValue:))
                let parent = attrs["floeParent"].flatMap { ids[$0] }
                elements.append(.init(id: ids[raw]!, kind: rawKind ?? kind, title: ExchangeText.plain(attrs["value"] ?? ""),
                                      parentID: parent, containerID: container, order: elements.count,
                                      frame: .init(x: position.x, y: position.y, width: Double(g?.attributes["width"] ?? "") ?? 160, height: Double(g?.attributes["height"] ?? "") ?? 56),
                                      collapsed: attrs["floeCollapsed"] == "true",
                                      isLocked: properties["locked"] == "1" || properties["movable"] == "0",
                                      style: .init(fill: properties["fillColor"] == "none" ? "transparent" : properties["fillColor"] ?? "surface",
                                                   stroke: properties["strokeColor"] ?? "border", text: properties["fontColor"] ?? "text",
                                                   lineWidth: Double(properties["strokeWidth"] ?? "") ?? 1.5,
                                                   fontSize: Double(properties["fontSize"] ?? "") ?? 15, bold: properties["fontStyle"] == "1"),
                                      links: links, metadata: ["drawioStyle": attrs["style"] ?? "", "drawioValue": attrs["value"] ?? "", "externalID": raw]))
                if properties["image"] != nil { issues.append(.init("drawioImage", "External/custom image shapes remain in the original draw.io payload.")) }
            }
            // Layers without vertex geometry are intentionally not native containers.
            let native = Dictionary(uniqueKeysWithValues: elements.map { ($0.id, $0) })
            for i in elements.indices { if let parent = elements[i].containerID, native[parent]?.kind.isContainer != true { elements[i].containerID = nil } }
            for raw in attributes.keys.sorted() where attributes[raw]?["edge"] == "1" {
                let attrs = attributes[raw]!, cell = rawCells[raw]!, style = styles(attrs["style"] ?? ""), g = cell.child("mxGeometry")
                if attrs["floeBranch"] == "1" { continue }
                func endpoint(_ key: String, pointKey: String) throws -> UUID {
                    if let id = attrs[key].flatMap({ ids[$0] }) { return id }
                    guard let point = g?.children.first(where: { $0.name == "mxPoint" && $0.attributes["as"] == pointKey }),
                          let x = Double(point.attributes["x"] ?? ""), let y = Double(point.attributes["y"] ?? "") else { throw DiagramError.unsupported("draw.io dangling edge without coordinates") }
                    let id = ExchangeText.stableID(namespace, raw+":"+key)
                    elements.append(.init(id: id, kind: .ellipse, title: "", frame: .init(x: x-1, y: y-1, width: 2, height: 2), metadata: ["connectorEndpoint": "true"]))
                    return id
                }
                let from = try endpoint("source", pointKey: "sourcePoint"), to = try endpoint("target", pointKey: "targetPoint")
                let route: DiagramRouteKind = style["curved"] == "1" ? .curve : style["edgeStyle"]?.contains("orthogonal") == true || style["edgeStyle"]?.contains("elbow") == true ? .orthogonal : .straight
                let points = g?.children.first(where: { $0.name == "Array" && $0.attributes["as"] == "points" })?.children.compactMap { p -> DiagramPoint? in
                    guard let x = Double(p.attributes["x"] ?? ""), let y = Double(p.attributes["y"] ?? "") else { return nil }; return .init(x: x, y: y)
                } ?? []
                let sourceSide = portSide(x: style["exitX"], y: style["exitY"]), targetSide = portSide(x: style["entryX"], y: style["entryY"])
                connections.append(.init(id: ExchangeText.stableID(namespace, raw), from: from, to: to, kind: .flow,
                                         route: route, sourceAnchor: sourceSide, targetAnchor: targetSide, waypoints: points,
                                         label: ExchangeText.plain(attrs["value"] ?? ""), labelPosition: min(1, max(0, ((Double(g?.attributes["x"] ?? "") ?? 0)+1)/2)),
                                         color: style["strokeColor"] ?? "edge", width: Double(style["strokeWidth"] ?? "") ?? 1.5,
                                         dashed: style["dashed"] == "1", startArrow: style["startArrow"].map { $0 != "none" } ?? false,
                                         endArrow: style["endArrow"].map { $0 != "none" } ?? true,
                                         isLocked: style["locked"] == "1", metadata: ["drawioStyle": attrs["style"] ?? ""]))
            }
            pages.append(.init(id: ExchangeText.stableID(namespace, diagram.attributes["id"] ?? "page-\(number)"),
                               title: diagram.attributes["name"] ?? "Page \(number+1)", structure: .flow, elements: elements, connections: connections))
        }
        guard !pages.isEmpty else { throw DiagramError.invalid("draw.io pages") }
        return .init(document: .init(id: ExchangeText.stableID(namespace, "document"), title: title, pages: pages, metadata: ["importFormat": "drawio"], legacyPayload: data), issues: Array(Set(issues)))
    }
    private static func portSide(x: String?, y: String?) -> DiagramAnchorSide {
        if x == "0" { return .left }; if x == "1" { return .right }; if y == "0" { return .top }; if y == "1" { return .bottom }; return .automatic
    }
    private static func portStyle(_ side: DiagramAnchorSide, prefix: String) -> String {
        switch side {
        case .left: "\(prefix)X=0;\(prefix)Y=0.5;"
        case .right: "\(prefix)X=1;\(prefix)Y=0.5;"
        case .top: "\(prefix)X=0.5;\(prefix)Y=0;"
        case .bottom: "\(prefix)X=0.5;\(prefix)Y=1;"
        case .automatic: ""
        }
    }
    static func encode(_ document: DiagramDocument, compressed: Bool = false) throws -> DiagramExportResult {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><mxfile host=\"FloeDiagramKit\">", issues: [DiagramExchangeIssue] = []
        for page in document.pages {
            var expanded = page
            for i in expanded.elements.indices { expanded.elements[i].collapsed = false }
            let layout = try DiagramLayoutEngine.layout(expanded)
            var model = "<mxGraphModel><root><mxCell id=\"0\"/><mxCell id=\"1\" parent=\"0\"/>"
            for node in page.elements {
                guard let frame = layout.frames[node.id] ?? node.frame else { continue }
                var style = node.metadata["drawioStyle"] ?? ""
                switch node.kind {
                case .ellipse: style += ";ellipse;"
                case .diamond: style += ";rhombus;"
                case .parallelogram: style += ";shape=parallelogram;"
                case .swimlane, .swimlanePool: style += ";swimlane;horizontal=1;startSize=36;"
                case .group: style += ";group;"
                case .text: style += ";text;"
                default: style += ";rounded=1;"
                }
                style += "whiteSpace=wrap;html=0;fillColor=\(node.kind == .text || node.kind == .boundary ? "none" : ExchangeText.colorHex(node.style.fill));strokeColor=\(ExchangeText.colorHex(node.style.stroke));fontColor=\(ExchangeText.colorHex(node.style.text));fontSize=\(node.style.fontSize);"
                if node.isLocked { style += "locked=1;" }
                let parent = node.containerID?.uuidString ?? "1", parentFrame = node.containerID.flatMap { layout.frames[$0] }
                let x = frame.x-(parentFrame?.x ?? 0), y = frame.y-(parentFrame?.y ?? 0)
                let link = node.links.first.map { $0.pageID.map { "data:page/id,"+$0.uuidString } ?? $0.url ?? "" } ?? ""
                model += "<object id=\"\(node.id.uuidString)\" label=\"\(ExchangeText.escape(node.title))\" link=\"\(ExchangeText.escape(link))\"><mxCell vertex=\"1\" parent=\"\(parent)\" floeKind=\"\(node.kind.rawValue)\""
                if let p = node.parentID { model += " floeParent=\"\(p.uuidString)\"" }
                model += " floeCollapsed=\"\(node.collapsed)\" style=\"\(ExchangeText.escape(style))\"><mxGeometry x=\"\(x)\" y=\"\(y)\" width=\"\(frame.width)\" height=\"\(frame.height)\" as=\"geometry\"/></mxCell></object>"
            }
            var edges = page.connections
            for node in page.elements {
                if let parent = node.parentID {
                    edges.append(.init(id: ExchangeText.stableID(node.id.uuidString, "branch"), from: parent, to: node.id, kind: .flow, route: .curve, metadata: ["derivedBranch": "true"]))
                }
            }
            for edge in edges {
                let route = edge.route == .orthogonal ? "edgeStyle=orthogonalEdgeStyle;rounded=1;" : edge.route == .curve ? "curved=1;" : ""
                let style = route+"endArrow=\(edge.endArrow ? "classic" : "none");startArrow=\(edge.startArrow ? "classic" : "none");strokeColor=\(ExchangeText.colorHex(edge.color));strokeWidth=\(edge.width);dashed=\(edge.dashed ? 1 : 0);"+portStyle(edge.sourceAnchor, prefix: "exit")+portStyle(edge.targetAnchor, prefix: "entry")
                model += "<mxCell id=\"\(edge.id.uuidString)\" value=\"\(ExchangeText.escape(edge.label))\" edge=\"1\" parent=\"1\" source=\"\(edge.from.uuidString)\" target=\"\(edge.to.uuidString)\" floeBranch=\"\(edge.metadata["derivedBranch"] == "true" ? 1 : 0)\" style=\"\(ExchangeText.escape(style))\"><mxGeometry relative=\"1\" x=\"\(edge.labelPosition*2-1)\" as=\"geometry\">"
                if !edge.waypoints.isEmpty { model += "<Array as=\"points\">"+edge.waypoints.map { "<mxPoint x=\"\($0.x)\" y=\"\($0.y)\"/>" }.joined()+"</Array>" }
                model += "</mxGeometry></mxCell>"
            }
            model += "</root></mxGraphModel>"
            xml += "<diagram id=\"\(page.id.uuidString)\" name=\"\(ExchangeText.escape(page.title))\">"
            if compressed {
                let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()"))
                guard let encoded = model.addingPercentEncoding(withAllowedCharacters: allowed) else { throw DiagramError.io("draw.io URI encoding") }
                xml += try DiagramRawDeflate.encode(Data(encoded.utf8)).base64EncodedString()
            } else { xml += model }
            xml += "</diagram>"
            if page.elements.contains(where: { !$0.content.isEmpty || $0.taskID != nil || !$0.sources.isEmpty }) { issues.append(.init("drawioContent", "Rich cards, task fields and sources are retained in the native file; draw.io receives editable shapes and connections.")) }
        }
        xml += "</mxfile>"
        return .init(data: Data(xml.utf8), format: .drawio, issues: Array(Set(issues)))
    }
}
