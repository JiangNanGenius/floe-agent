// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCanvasCore

/// Bidirectional JSON Canvas 1.0 (https://jsoncanvas.org/spec/1.0/) codec.
///
/// Mapping decisions (deliberate, documented in FORMAT_SUPPORT.md):
/// - `text`  <-> `CanvasContent.text` (markdown source kept verbatim).
/// - `link`  <-> `CanvasContent.web`; the original url string is retained
///   in the import sidecar and re-emitted verbatim on export.
/// - `file`  -> `CanvasContent.unknown(kind: "floe.jsoncanvas.file")` with
///   the exact `file`/`subpath` payload, plus an issue asking the host
///   importer to resolve the bytes (never by this module). When the caller
///   supplies a trusted asset root and opts in, bytes resolve to
///   `CanvasContent.media` instead.
/// - `group` <-> `CanvasRegionRecord` (a JSON Canvas group is a labelled
///   backdrop = a collapsible region; grouping that moves members together
///   remains `CanvasGroupRecord` and is NOT exported to JSON Canvas).
/// - edges   -> `CanvasConnectionSnapshot` with side mapping
///   left/right/top/bottom <-> leading/trailing/top/bottom; raw
///   `fromEnd`/`toEnd`/color survive through the import sidecar.
/// - Multipage: JSON Canvas is one page per file. Export is always explicit
///   (`selectedPageOnly` with a per-page loss issue, or `oneFilePerPage`).
public enum CanvasJSONCanvasCodec {
    public static let namespace = "floe.jsoncanvas.v1"

    // MARK: Decode

    public struct ImportOptions: Sendable {
        /// Canvas identity fallback when the file has none of its own.
        public var canvasID: UUID
        public var canvasName: String
        /// Deterministic id namespace.
        public var namespace: String
        /// When set, `file` nodes may be resolved to bytes, confined to
        /// this root (symlink-escape safe). nil means references only.
        public var trustedAssetRoot: URL?
        /// Resolve `file` node bytes (only effective with a trusted root).
        public var resolveAssetBytes: Bool

        public init(canvasID: UUID = UUID(), canvasName: String = "Imported Canvas", namespace: String = CanvasJSONCanvasCodec.namespace, trustedAssetRoot: URL? = nil, resolveAssetBytes: Bool = false) {
            self.canvasID = canvasID
            self.canvasName = canvasName
            self.namespace = namespace
            self.trustedAssetRoot = trustedAssetRoot
            self.resolveAssetBytes = resolveAssetBytes
        }
    }

    public static func decode(_ data: Data, options: ImportOptions = ImportOptions()) throws -> CanvasExchangeBundle {
        try CanvasExchangeLimits.validateInputSize(data)
        let root: JSONValue
        do {
            root = try JSONFidelity.parse(data)
        } catch {
            throw CanvasExchangeError.invalid("not valid JSON: \(error)")
        }
        guard root.objectValue != nil else {
            throw CanvasExchangeError.invalid("JSON Canvas root must be an object")
        }
        if root["nodes"] != nil, root["nodes"]?.arrayValue == nil {
            throw CanvasExchangeError.invalid("JSON Canvas \"nodes\" must be an array when present")
        }
        let nodeValues = root["nodes"]?.arrayValue ?? []
        guard nodeValues.count <= CanvasExchangeLimits.maxForeignElements else {
            throw CanvasExchangeError.limitExceeded("JSON Canvas has \(nodeValues.count) nodes; the limit is \(CanvasExchangeLimits.maxForeignElements)")
        }

        var issues: [CanvasExchangeIssue] = []
        var nodes: [CanvasNodeSnapshot] = []
        var regions: [CanvasRegionRecord] = []
        var originalNodes: [UUID: JSONValue] = [:]
        var externalIDs: [UUID: String] = [:]
        var seenRawIDs: Set<String> = []
        var pendingFiles: [(uuid: UUID, rawID: String, file: String, subpath: String?)] = []

        for (index, nodeValue) in nodeValues.enumerated() {
            guard let object = nodeValue.objectValue else {
                issues.append(.init("jsoncanvas.node.notAnObject", "node at index \(index) is not an object and was skipped", contentClass: "node", severity: .rejected))
                continue
            }
            guard let rawID = object["id"]?.stringValue, !rawID.isEmpty else {
                issues.append(.init("jsoncanvas.node.missingID", "node at index \(index) has no id and was skipped", contentClass: "node", severity: .rejected))
                continue
            }
            guard seenRawIDs.insert(rawID).inserted else {
                throw CanvasExchangeError.invalid("duplicate JSON Canvas node id \"\(rawID)\"; refusing to import ambiguous identity")
            }
            let uuid = CanvasExchangeIDs.stable(options.namespace, rawID)
            externalIDs[uuid] = rawID
            originalNodes[uuid] = nodeValue

            let type = object["type"]?.stringValue ?? "text"
            guard let x = CanvasExchangeJSON.finiteNumber(object["x"]),
                  let y = CanvasExchangeJSON.finiteNumber(object["y"]) else {
                issues.append(.init("jsoncanvas.node.badPosition", "node \"\(rawID)\" has a non-finite or out-of-range position and was skipped", contentClass: "node", severity: .rejected))
                continue
            }
            var width = CanvasExchangeJSON.finiteNumber(object["width"]) ?? 240
            var height = CanvasExchangeJSON.finiteNumber(object["height"]) ?? 120
            if width <= 0 || height <= 0 {
                issues.append(.init("jsoncanvas.node.nonPositiveSize", "node \"\(rawID)\" has a non-positive size and it was clamped", contentClass: "node", severity: .preserved))
                width = max(1, abs(width))
                height = max(1, abs(height))
            }
            let frame = CanvasGeometry.Frame(
                center: .init(x: x + width / 2, y: y + height / 2),
                size: .init(width: width, height: height)
            )
            var metadata: [String: String] = [:]
            if let color = object["color"]?.stringValue { metadata[CanvasExchangeStyleKey.fillColor] = color }

            let content: CanvasContent
            switch type {
            case "text":
                let text = object["text"]?.stringValue ?? ""
                content = .text(text)
            case "link":
                guard let rawURL = object["url"]?.stringValue, let url = URL(string: rawURL) else {
                    issues.append(.init("jsoncanvas.link.badURL", "link node \"\(rawID)\" has no usable url; kept as unknown payload", contentClass: "web", severity: .preserved))
                    content = .unknown(kind: "floe.jsoncanvas.link", payload: nodeValue)
                    break
                }
                content = .web(url, title: nil)
            case "file":
                guard let file = object["file"]?.stringValue, !file.isEmpty else {
                    issues.append(.init("jsoncanvas.file.missingPath", "file node \"\(rawID)\" has no file path; kept as unknown payload", contentClass: "unknownContent", severity: .preserved))
                    content = .unknown(kind: "floe.jsoncanvas.file", payload: nodeValue)
                    break
                }
                let subpath = object["subpath"]?.stringValue
                pendingFiles.append((uuid, rawID, file, subpath))
                content = .unknown(kind: "floe.jsoncanvas.file", payload: .object([
                    "file": .string(file),
                    "subpath": subpath.map(JSONValue.string) ?? .null,
                ]))
            case "group":
                regions.append(CanvasRegionRecord(id: uuid, name: object["label"]?.stringValue ?? "", frame: frame, isCollapsed: false))
                continue
            default:
                issues.append(.init("jsoncanvas.node.unknownType", "node \"\(rawID)\" has unknown type \"\(type)\"; preserved as unknown content", contentClass: "unknownContent", severity: .preserved))
                content = .unknown(kind: "floe.jsoncanvas.\(type)", payload: nodeValue)
            }

            nodes.append(CanvasNodeSnapshot(
                id: uuid,
                kind: .content,
                title: CanvasJSONCanvasCodec.title(for: content),
                content: content,
                frame: frame,
                metadata: metadata
            ))
        }

        // Region containment is derived from geometry (JSON Canvas groups
        // are backdrops; the legacy region cache records it for persistence).
        for index in nodes.indices {
            let frame = nodes[index].frame
            if let region = regions.first(where: {
                frame.center.x > $0.frame.minX && frame.center.x < $0.frame.maxX
                    && frame.center.y > $0.frame.minY && frame.center.y < $0.frame.maxY
            }) {
                nodes[index].regionID = region.id
            }
        }

        // Optional file-byte resolution, strictly inside the trusted root
        // (same confinement rules as CanvasTrustedFileAssetResolver, applied
        // synchronously so decode stays a pure function of its inputs).
        var assets: [UUID: Data] = [:]
        for pending in pendingFiles {
            guard let root = options.trustedAssetRoot?.standardizedFileURL else {
                issues.append(.init("jsoncanvas.file.reference", "file node \"\(pending.rawID)\" references \"\(pending.file)\"; the host importer resolves it through its own asset channel", contentClass: "asset", severity: .preserved))
                continue
            }
            let candidate = URL(fileURLWithPath: pending.file, relativeTo: root).standardizedFileURL
            let resolved = candidate.resolvingSymlinksInPath()
            let contained = resolved.path.hasPrefix(root.path + "/")
            guard options.resolveAssetBytes else {
                issues.append(.init("jsoncanvas.file.reference", "file node \"\(pending.rawID)\" references \"\(pending.file)\"; byte resolution was not requested", contentClass: "asset", severity: .preserved))
                continue
            }
            guard contained else {
                issues.append(.init("jsoncanvas.file.outsideRoot", "file node \"\(pending.rawID)\" resolves outside the trusted root and stays a reference", contentClass: "asset", severity: .unavailable))
                continue
            }
            do {
                // Bounded chunked read through a per-call FileHandle
                // (regular-file verified, no unbounded memory mapping).
                let bytes = try CanvasBoundedFileReader.read(
                    resolved,
                    maximumBytes: CanvasExchangeLimits.maxSingleEntryBytes
                )
                let locator = CanvasAssetLocator(
                    id: pending.uuid,
                    contentHash: CanvasDigest.sha256(bytes),
                    relativePath: pending.file,
                    mimeType: CanvasJSONCanvasCodec.mimeType(for: pending.file),
                    byteCount: Int64(bytes.count)
                )
                assets[pending.uuid] = bytes
                if let index = nodes.firstIndex(where: { $0.id == pending.uuid }) {
                    nodes[index].content = .media(locator)
                }
            } catch {
                issues.append(.init("jsoncanvas.file.unresolved", "file node \"\(pending.rawID)\" could not be resolved: \(error)", contentClass: "asset", severity: .unavailable))
            }
        }

        // Edges.
        var connections: [CanvasConnectionSnapshot] = []
        var originalEdges: [UUID: JSONValue] = [:]
        if let edgeValues = root["edges"]?.arrayValue {
            var seenEdgeIDs: Set<String> = []
            for edgeValue in edgeValues {
                guard let object = edgeValue.objectValue,
                      let rawID = object["id"]?.stringValue, !rawID.isEmpty else {
                    issues.append(.init("jsoncanvas.edge.missingID", "an edge has no id and was skipped", contentClass: "connection", severity: .rejected))
                    continue
                }
                guard seenEdgeIDs.insert(rawID).inserted else {
                    throw CanvasExchangeError.invalid("duplicate JSON Canvas edge id \"\(rawID)\"")
                }
                let uuid = CanvasExchangeIDs.stable(options.namespace + ".edge", rawID)
                externalIDs[uuid] = rawID
                originalEdges[uuid] = edgeValue
                guard let fromRaw = object["fromNode"]?.stringValue,
                      let toRaw = object["toNode"]?.stringValue else {
                    issues.append(.init("jsoncanvas.edge.missingEndpoint", "edge \"\(rawID)\" lacks fromNode/toNode and was skipped", contentClass: "connection", severity: .rejected))
                    continue
                }
                let fromID = CanvasExchangeIDs.stable(options.namespace, fromRaw)
                let toID = CanvasExchangeIDs.stable(options.namespace, toRaw)
                let nodeIDs = Set(nodes.map(\.id))
                if !nodeIDs.contains(fromID) || !nodeIDs.contains(toID) {
                    issues.append(.init("jsoncanvas.edge.danglingEndpoint", "edge \"\(rawID)\" references a node that was skipped or missing; the reference is preserved", contentClass: "connection", severity: .preserved))
                }
                let fromEnd = object["fromEnd"]?.stringValue ?? "none"
                let toEnd = object["toEnd"]?.stringValue ?? "arrow"
                let kind: CanvasRelationKind = (fromEnd == "arrow" || toEnd == "arrow") ? .arrow : .line
                connections.append(CanvasConnectionSnapshot(
                    id: uuid,
                    sourceNodeID: fromID,
                    destinationNodeID: toID,
                    kind: kind,
                    label: object["label"]?.stringValue,
                    sourcePort: CanvasJSONCanvasCodec.port(object["fromSide"]?.stringValue, rawID: rawID, issues: &issues),
                    destinationPort: CanvasJSONCanvasCodec.port(object["toSide"]?.stringValue, rawID: rawID, issues: &issues)
                ))
            }
        }

        let page = CanvasPageSnapshot(
            id: UUID(),
            name: options.canvasName,
            nodes: nodes,
            connections: connections,
            regions: regions,
            background: .blank
        )
        let snapshot = CanvasSnapshot(id: options.canvasID, name: options.canvasName, pages: [page])
        let source = CanvasOriginalSource(
            kind: .jsonCanvasOriginal,
            suggestedName: "\(options.canvasID.uuidString).canvas",
            byteCount: data.count,
            sha256: CanvasDigest.sha256(data),
            nodeIDs: nodes.map(\.id)
        )
        return CanvasExchangeBundle(
            snapshot: snapshot,
            assets: assets,
            originalSources: [source],
            externalIDs: externalIDs,
            originalNodes: originalNodes,
            originalEdges: originalEdges,
            originalDocument: root,
            issues: issues
        )
    }

    // MARK: Encode

    public struct ExportOptions: Sendable {
        public var pageID: UUID?
        public var multiPageStrategy: CanvasMultiPageStrategy
        /// uuid -> original external id (from a prior import).
        public var externalIDs: [UUID: String]
        /// uuid -> original foreign node tree (unknown fields re-injected).
        public var originalNodes: [UUID: JSONValue]
        /// connection uuid -> original foreign edge tree.
        public var originalEdges: [UUID: JSONValue]
        /// Original top-level document (unknown top-level keys re-injected).
        public var originalDocument: JSONValue?

        public init(pageID: UUID? = nil, multiPageStrategy: CanvasMultiPageStrategy = .selectedPageOnly, externalIDs: [UUID: String] = [:], originalNodes: [UUID: JSONValue] = [:], originalEdges: [UUID: JSONValue] = [:], originalDocument: JSONValue? = nil) {
            self.pageID = pageID
            self.multiPageStrategy = multiPageStrategy
            self.externalIDs = externalIDs
            self.originalNodes = originalNodes
            self.originalEdges = originalEdges
            self.originalDocument = originalDocument
        }
    }

    public static func export(_ snapshot: CanvasSnapshot, options: ExportOptions = ExportOptions()) throws -> CanvasExchangeOutput {
        let pages: [CanvasPageSnapshot]
        var issues: [CanvasExchangeIssue] = []
        if let pageID = options.pageID {
            guard let page = snapshot.pages.first(where: { $0.id == pageID }) else {
                throw CanvasExchangeError.invalid("page \(pageID) not found")
            }
            if snapshot.pages.count > 1 {
                issues.append(skippedPagesIssue(snapshot, exported: page))
            }
            pages = [page]
        } else if options.multiPageStrategy == .oneFilePerPage {
            pages = snapshot.pages
        } else {
            guard let page = snapshot.selectedPage ?? snapshot.pages.first else {
                throw CanvasExchangeError.invalid("canvas has no pages")
            }
            if snapshot.pages.count > 1 {
                issues.append(skippedPagesIssue(snapshot, exported: page))
            }
            pages = [page]
        }

        let files: [CanvasExchangeFile] = try pages.map { page in
            let document = try exportPage(page, snapshot: snapshot, options: options, issues: &issues)
            var object = document
            // Re-inject unknown top-level keys (e.g. fixtureExtension).
            if let original = options.originalDocument?.objectValue {
                for (key, value) in original where key != "nodes" && key != "edges" {
                    if object[key] == nil { object[key] = value }
                }
            }
            let data = try JSONFidelity.serialize(.object(object), options: .init(sortedKeys: true, prettyPrinted: true))
            let name = pages.count == 1
                ? CanvasExchangeFilename.sanitized(snapshot.name, extension: "canvas")
                : CanvasExchangeFilename.sanitized("\(snapshot.name)-\(page.name)", extension: "canvas", fallback: "page")
            return CanvasExchangeFile(name: name, data: data)
        }
        return CanvasExchangeOutput(files: files, issues: issues)
    }

    private static func skippedPagesIssue(_ snapshot: CanvasSnapshot, exported: CanvasPageSnapshot) -> CanvasExchangeIssue {
        let skipped = snapshot.pages.filter { $0.id != exported.id }
            .map { "\"\($0.name)\"" }.joined(separator: ", ")
        return .init(
            "jsoncanvas.multipage",
            "JSON Canvas holds one page per file; exported \"\(exported.name)\" only. Skipped: \(skipped). Use oneFilePerPage or export each page explicitly — nothing was silently dropped.",
            contentClass: "archive", severity: .loss
        )
    }

    private static func exportPage(_ page: CanvasPageSnapshot, snapshot: CanvasSnapshot, options: ExportOptions, issues: inout [CanvasExchangeIssue]) throws -> [String: JSONValue] {
        var nodes: [JSONValue] = []
        var edges: [JSONValue] = []

        for node in page.nodes {
            var object: [String: JSONValue] = [:]
            let externalID = options.externalIDs[node.id] ?? node.id.uuidString
            object["id"] = .string(externalID)
            object["x"] = .number(CanvasExchangeGeometry.number(node.frame.minX))
            object["y"] = .number(CanvasExchangeGeometry.number(node.frame.minY))
            object["width"] = .number(CanvasExchangeGeometry.number(node.frame.size.width))
            object["height"] = .number(CanvasExchangeGeometry.number(node.frame.size.height))
            if let fill = node.metadata[CanvasExchangeStyleKey.fillColor] {
                object["color"] = .string(fill)
            }

            switch node.content {
            case .text(let text):
                object["type"] = .string("text")
                object["text"] = .string(text)
            case .markdown(let document, _):
                object["type"] = .string("text")
                object["text"] = .string(document)
                issues.append(.init("jsoncanvas.markdownPreview", "node \(node.id): markdown preview hint is not representable in JSON Canvas; source markdown exported", contentClass: "node", severity: .loss))
            case .web(let url, _):
                // Prefer the verbatim original url string when available.
                let raw = options.originalNodes[node.id]?["url"]?.stringValue ?? url.absoluteString
                object["type"] = .string("link")
                object["url"] = .string(raw)
            case .media(let locator):
                if let path = locator.relativePath {
                    object["type"] = .string("file")
                    object["file"] = .string(path)
                    if let subpath = options.originalNodes[node.id]?["subpath"]?.stringValue {
                        object["subpath"] = .string(subpath)
                    }
                } else {
                    issues.append(.init("jsoncanvas.media.noPath", "media node \(node.id) has no relative path; exported as a text placeholder — keep the native archive for the bytes", contentClass: "media", severity: .loss))
                    object["type"] = .string("text")
                    object["text"] = .string("[media \(locator.id.uuidString)]")
                }
            case .unknown(let kind, _) where kind == "floe.jsoncanvas.file":
                // A file reference that was never resolved: re-export as-is.
                object["type"] = .string("file")
                if let file = CanvasExchangeContent.plainText(of: node.content).isEmpty ? nil : nodeContentPayload(node, key: "file") {
                    object["file"] = file
                }
                if let subpath = nodeContentPayload(node, key: "subpath"), subpath != .null {
                    object["subpath"] = subpath
                }
                if object["file"] == nil {
                    object["type"] = .string("text")
                    object["text"] = .string("[unresolved file reference]")
                    issues.append(.init("jsoncanvas.file.unresolvedExport", "file node \(node.id) lost its path payload; exported placeholder", contentClass: "asset", severity: .loss))
                }
            default:
                // Rich/shape/code/formula/table/pdf/editor and unknown content
                // project to editable text; the loss report says exactly what.
                object["type"] = .string("text")
                object["text"] = .string(CanvasExchangeContent.plainText(of: node.content))
                issues.append(.init(
                    "jsoncanvas.projectedToText",
                    "node \(node.id) content class \"\(CanvasJSONCanvasCodec.contentClass(of: node.content))\" is not native to JSON Canvas; exported as editable text",
                    contentClass: CanvasJSONCanvasCodec.contentClass(of: node.content), severity: .loss
                ))
            }

            // Re-inject unknown per-node keys from the original document.
            if let original = options.originalNodes[node.id]?.objectValue {
                for (key, value) in original where object[key] == nil {
                    object[key] = value
                }
            }
            nodes.append(.object(object))
        }

        for region in page.regions {
            var object: [String: JSONValue] = [
                "id": .string(options.externalIDs[region.id] ?? region.id.uuidString),
                "type": .string("group"),
                "x": .number(CanvasExchangeGeometry.number(region.frame.minX)),
                "y": .number(CanvasExchangeGeometry.number(region.frame.minY)),
                "width": .number(CanvasExchangeGeometry.number(region.frame.size.width)),
                "height": .number(CanvasExchangeGeometry.number(region.frame.size.height)),
            ]
            if !region.name.isEmpty { object["label"] = .string(region.name) }
            if let original = options.originalNodes[region.id]?.objectValue {
                for (key, value) in original where object[key] == nil {
                    object[key] = value
                }
            }
            nodes.append(.object(object))
        }

        for connection in page.connections {
            var object: [String: JSONValue] = [:]
            let externalID = options.externalIDs[connection.id] ?? connection.id.uuidString
            object["id"] = .string(externalID)
            object["fromNode"] = .string(options.externalIDs[connection.sourceNodeID] ?? connection.sourceNodeID.uuidString)
            object["toNode"] = .string(options.externalIDs[connection.destinationNodeID] ?? connection.destinationNodeID.uuidString)
            if let port = connection.sourcePort { object["fromSide"] = .string(side(port)) }
            if let port = connection.destinationPort { object["toSide"] = .string(side(port)) }
            // Arrowheads: prefer the verbatim original ends (the core relation
            // model has no per-end arrows), else derive from the kind.
            let originalEnds = options.originalEdges[connection.id]
            if let fromEnd = originalEnds?["fromEnd"]?.stringValue {
                object["fromEnd"] = .string(fromEnd)
            }
            if let toEnd = originalEnds?["toEnd"]?.stringValue {
                object["toEnd"] = .string(toEnd)
            }
            if originalEnds?["fromEnd"] == nil || originalEnds?["toEnd"] == nil {
                switch connection.kind {
                case .arrow:
                    object["fromEnd"] = object["fromEnd"] ?? .string("none")
                    object["toEnd"] = object["toEnd"] ?? .string("arrow")
                case .line:
                    object["fromEnd"] = object["fromEnd"] ?? .string("none")
                    object["toEnd"] = object["toEnd"] ?? .string("none")
                case .source, .generatedFrom:
                    object["fromEnd"] = object["fromEnd"] ?? .string("arrow")
                    object["toEnd"] = object["toEnd"] ?? .string("arrow")
                    issues.append(.init("jsoncanvas.relationKind", "connection \(connection.id) kind \"\(connection.kind.rawValue)\" projected to a double-headed edge", contentClass: "connection", severity: .loss))
                }
            }
            if let label = connection.label { object["label"] = .string(label) }
            // Verbatim color from the original edge when present.
            if let color = originalEnds?["color"]?.stringValue {
                object["color"] = .string(color)
            }
            if let original = options.originalEdges[connection.id]?.objectValue {
                for (key, value) in original where object[key] == nil {
                    object[key] = value
                }
            }
            edges.append(.object(object))
        }

        var document: [String: JSONValue] = ["nodes": .array(nodes)]
        if !edges.isEmpty { document["edges"] = .array(edges) }
        return document
    }

    // MARK: Helpers

    private static func title(for content: CanvasContent) -> String? {
        switch content {
        case .text(let text), .markdown(let text, _):
            return text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
        default:
            return nil
        }
    }

    private static func contentClass(of content: CanvasContent) -> String {
        switch content {
        case .text: return "text"
        case .markdown: return "markdown"
        case .code: return "code"
        case .formula: return "formula"
        case .table: return "table"
        case .media: return "media"
        case .pdf: return "pdf"
        case .web: return "web"
        case .editor: return "editor"
        case .unknown(let kind, _): return kind
        case .richText: return "richText"
        case .shape: return "shape"
        }
    }

    private static func nodeContentPayload(_ node: CanvasNodeSnapshot, key: String) -> JSONValue? {
        guard case .unknown(_, let payload) = node.content else { return nil }
        return payload[key]
    }

    private static func port(_ side: String?, rawID: String, issues: inout [CanvasExchangeIssue]) -> CanvasConnectionPort? {
        guard let side, !side.isEmpty else { return nil }
        switch side {
        case "top": return .top
        case "right": return .trailing
        case "bottom": return .bottom
        case "left": return .leading
        default:
            issues.append(.init("jsoncanvas.edge.badSide", "edge \"\(rawID)\" has unsupported side \"\(side)\"; ignored", contentClass: "connection", severity: .preserved))
            return nil
        }
    }

    private static func side(_ port: CanvasConnectionPort) -> String {
        switch port {
        case .top: return "top"
        case .trailing: return "right"
        case .bottom: return "bottom"
        case .leading: return "left"
        }
    }

    static func mimeType(for path: String) -> String? {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "pdf": return "application/pdf"
        case "md", "markdown": return "text/markdown"
        case "txt": return "text/plain"
        default: return nil
        }
    }
}
