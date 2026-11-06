// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCanvasCore

/// Bidirectional Excalidraw codec (element schema per Excalidraw v0.18.x,
/// provenance: see interop-fixtures/PROVENANCE.json). Editable subset:
/// rectangle / ellipse / diamond / text / arrow / line / freedraw / frame /
/// image, with rotation, bindings, groupIds and deleted-element tombstones
/// handled per the documented support matrix.
///
/// Mapping decisions (FORMAT_SUPPORT.md):
/// - shapes  <-> `CanvasContent.shape` (kind mapping is 1:1 for the three
///   closed shapes; line/arrow carry geometry from their frame, original
///   point lists survive through the import sidecar).
/// - text    -> standalone text becomes single-run rich text; text bound to
///   a shape (`containerId`) becomes the shape's text.
/// - freedraw -> `CanvasStrokeSnapshot` (absolute world points).
/// - frame   -> `CanvasRegionRecord`; an element's `frameId` becomes its
///   `regionID` cache.
/// - groupIds -> `CanvasGroupRecord` (each foreign group id maps to one
///   deterministic group; nesting order follows the `groupIds` array).
/// - image   -> `CanvasContent.media` with bytes taken from the `files`
///   dictionary on import and supplied by the injected resolver on export.
/// - isDeleted tombstones are dropped from the editable model, counted and
///   preserved verbatim in the sidecar.
public enum CanvasExcalidrawCodec {
    public static let namespace = "floe.excalidraw.v1"

    // MARK: Decode

    public struct ImportOptions: Sendable {
        public var canvasID: UUID
        public var canvasName: String
        public var namespace: String
        public init(canvasID: UUID = UUID(), canvasName: String = "Imported Excalidraw", namespace: String = CanvasExcalidrawCodec.namespace) {
            self.canvasID = canvasID
            self.canvasName = canvasName
            self.namespace = namespace
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
            throw CanvasExchangeError.invalid("Excalidraw root must be an object")
        }
        // The elements array is the authority; a missing or foreign
        // top-level "type" is tolerated rather than fatal.
        guard let elements = root["elements"]?.arrayValue else {
            throw CanvasExchangeError.invalid("Excalidraw document has no \"elements\" array")
        }
        guard elements.count <= CanvasExchangeLimits.maxForeignElements else {
            throw CanvasExchangeError.limitExceeded("Excalidraw document has \(elements.count) elements; the limit is \(CanvasExchangeLimits.maxForeignElements)")
        }

        var issues: [CanvasExchangeIssue] = []
        var nodes: [CanvasNodeSnapshot] = []
        var strokes: [CanvasStrokeSnapshot] = []
        var regions: [CanvasRegionRecord] = []
        var groups: [CanvasGroupRecord] = []
        var connections: [CanvasConnectionSnapshot] = []
        var assets: [UUID: Data] = [:]
        var originalNodes: [UUID: JSONValue] = [:]
        var originalEdges: [UUID: JSONValue] = [:]
        var externalIDs: [UUID: String] = [:]
        var seenIDs: Set<String> = []
        var tombstones = 0
        /// element id -> resolved uuid (bindings reference elements).
        var elementUUIDs: [String: UUID] = [:]
        /// frame element id -> region uuid.
        var frameRegions: [String: UUID] = [:]
        /// group id string -> group record index.
        var groupIndex: [String: Int] = [:]
        /// element uuid -> list of group id strings (order preserved).
        var memberGroups: [UUID: [String]] = [:]
        /// Bound text elements collected before their container exists:
        /// container raw id -> bound texts.
        var pendingBoundText: [String: [(uuid: UUID, text: String)]] = [:]
        /// arrows/lines that also carry bindings.
        struct BoundLine { var uuid: UUID; var raw: [String: JSONValue]; var shape: CanvasShapeKind; var frame: CanvasGeometry.Frame; var rotation: Double }
        var boundLines: [BoundLine] = []

        for element in elements {
            guard let object = element.objectValue else {
                issues.append(.init("excalidraw.element.notAnObject", "an element is not an object and was skipped", contentClass: "node", severity: .rejected))
                continue
            }
            guard let rawID = object["id"]?.stringValue, !rawID.isEmpty else {
                issues.append(.init("excalidraw.element.missingID", "an element has no id and was skipped", contentClass: "node", severity: .rejected))
                continue
            }
            guard seenIDs.insert(rawID).inserted else {
                throw CanvasExchangeError.invalid("duplicate Excalidraw element id \"\(rawID)\"; refusing ambiguous import")
            }
            if CanvasExchangeJSON.bool(object["isDeleted"]) == true {
                tombstones += 1
                continue
            }
            let uuid = CanvasExchangeIDs.stable(options.namespace, rawID)
            elementUUIDs[rawID] = uuid
            externalIDs[uuid] = rawID
            originalNodes[uuid] = element

            guard let type = object["type"]?.stringValue else {
                issues.append(.init("excalidraw.element.missingType", "element \"\(rawID)\" has no type and was skipped", contentClass: "node", severity: .rejected))
                continue
            }
            let x = CanvasExchangeJSON.finiteNumber(object["x"]) ?? 0
            let y = CanvasExchangeJSON.finiteNumber(object["y"]) ?? 0
            let width = CanvasExchangeJSON.finiteNumber(object["width"]) ?? 0
            let height = CanvasExchangeJSON.finiteNumber(object["height"]) ?? 0
            if object["x"] != nil || object["y"] != nil {
                if CanvasExchangeJSON.finiteNumber(object["x"]) == nil || CanvasExchangeJSON.finiteNumber(object["y"]) == nil {
                    issues.append(.init("excalidraw.element.badPosition", "element \"\(rawID)\" has a non-finite position; clamped to 0", contentClass: "node", severity: .preserved))
                }
            }
            let angle = CanvasExchangeJSON.finiteNumber(object["angle"]) ?? 0
            let frame = CanvasGeometry.Frame(
                center: .init(x: x + width / 2, y: y + height / 2),
                size: .init(width: abs(width), height: abs(height))
            )
            var metadata: [String: String] = [:]
            if let stroke = object["strokeColor"]?.stringValue { metadata[CanvasExchangeStyleKey.strokeColor] = stroke }
            if let fill = object["backgroundColor"]?.stringValue, fill != "transparent" { metadata[CanvasExchangeStyleKey.fillColor] = fill }
            if let lineWidth = CanvasExchangeJSON.number(object["strokeWidth"]) { metadata[CanvasExchangeStyleKey.strokeWidth] = CanvasExchangeGeometry.number(lineWidth) }
            if let rawGroups = object["groupIds"]?.arrayValue {
                memberGroups[uuid] = rawGroups.compactMap(\.stringValue)
            }
            switch type {
            case "rectangle", "ellipse", "diamond":
                let kind: CanvasShapeKind = type == "rectangle" ? .rectangle : (type == "ellipse" ? .ellipse : .diamond)
                nodes.append(CanvasNodeSnapshot(
                    id: uuid, kind: .content, title: nil,
                    content: .shape(kind: kind, text: ""),
                    frame: frame, rotationDegrees: angle * 180 / .pi,
                    metadata: metadata
                ))
            case "line", "arrow":
                boundLines.append(BoundLine(uuid: uuid, raw: object, shape: type == "line" ? .line : .arrow, frame: frame, rotation: angle * 180 / .pi))
                nodes.append(CanvasNodeSnapshot(
                    id: uuid, kind: .content, title: nil,
                    content: .shape(kind: type == "line" ? .line : .arrow, text: ""),
                    frame: frame, rotationDegrees: angle * 180 / .pi,
                    metadata: metadata
                ))
            case "text":
                let text = object["text"]?.stringValue ?? ""
                if let containerRaw = object["containerId"]?.stringValue, !containerRaw.isEmpty {
                    // Bound text: folded into its container's shape text in
                    // the post-pass (containers may appear later in the file).
                    pendingBoundText[containerRaw, default: []].append((uuid, text))
                } else {
                    nodes.append(CanvasNodeSnapshot(
                        id: uuid, kind: .content, title: nil,
                        content: CanvasExchangeContent.richText([CanvasRichTextRun(text: text)]),
                        frame: frame, rotationDegrees: angle * 180 / .pi,
                        metadata: metadata
                    ))
                }
            case "freedraw":
                let rawPoints = object["points"]?.arrayValue ?? []
                guard rawPoints.count <= CanvasExchangeLimits.maxPointsPerStroke else {
                    issues.append(.init("excalidraw.stroke.tooManyPoints", "freedraw \"\(rawID)\" has \(rawPoints.count) points; the limit is \(CanvasExchangeLimits.maxPointsPerStroke) — stroke skipped", contentClass: "stroke", severity: .rejected))
                    continue
                }
                var points: [CanvasGeometry.Point] = []
                points.reserveCapacity(rawPoints.count)
                var usable = true
                for point in rawPoints {
                    guard let pair = point.arrayValue, pair.count == 2,
                          let px = CanvasExchangeJSON.finiteNumber(pair[0]),
                          let py = CanvasExchangeJSON.finiteNumber(pair[1]) else {
                        usable = false
                        break
                    }
                    points.append(.init(x: x + px, y: y + py))
                }
                guard usable else {
                    issues.append(.init("excalidraw.stroke.badPoint", "freedraw \"\(rawID)\" has a non-finite point and was skipped", contentClass: "stroke", severity: .rejected))
                    continue
                }
                strokes.append(CanvasStrokeSnapshot(
                    id: uuid,
                    points: points,
                    width: CanvasExchangeJSON.number(object["strokeWidth"]) ?? 1,
                    color: object["strokeColor"]?.stringValue ?? "#1e293b",
                    isEraser: false
                ))
            case "frame":
                let region = CanvasRegionRecord(id: uuid, name: object["name"]?.stringValue ?? "", frame: frame, isCollapsed: false)
                regions.append(region)
                frameRegions[rawID] = uuid
                // Elements referencing this frame appear later; patch after.
            case "image":
                guard let fileID = object["fileId"]?.stringValue, !fileID.isEmpty else {
                    issues.append(.init("excalidraw.image.noFile", "image \"\(rawID)\" has no fileId; preserved as unknown content", contentClass: "media", severity: .preserved))
                    nodes.append(CanvasNodeSnapshot(id: uuid, kind: .content, title: nil, content: .unknown(kind: "floe.excalidraw.image", payload: element), frame: frame, rotationDegrees: angle * 180 / .pi, metadata: metadata))
                    continue
                }
                let locator = CanvasAssetLocator(
                    id: CanvasExchangeIDs.stable(options.namespace + ".file", fileID),
                    relativePath: nil,
                    mimeType: object["fileMimeType"]?.stringValue,
                    byteCount: nil
                )
                nodes.append(CanvasNodeSnapshot(
                    id: uuid, kind: .content, title: nil,
                    content: .media(locator),
                    frame: frame, rotationDegrees: angle * 180 / .pi,
                    metadata: metadata
                ))
            default:
                issues.append(.init("excalidraw.element.unsupportedType", "element \"\(rawID)\" has unsupported type \"\(type)\"; preserved as unknown content", contentClass: "unknownContent", severity: .preserved))
                nodes.append(CanvasNodeSnapshot(id: uuid, kind: .content, title: nil, content: .unknown(kind: "floe.excalidraw.\(type)", payload: element), frame: frame, rotationDegrees: angle * 180 / .pi, metadata: metadata))
            }
        }

        // Second pass: frameId references may point at frames declared later.
        for element in elements {
            guard let object = element.objectValue,
                  let rawID = object["id"]?.stringValue,
                  let frameRaw = object["frameId"]?.stringValue,
                  let region = frameRegions[frameRaw],
                  let uuid = elementUUIDs[rawID],
                  let index = nodes.firstIndex(where: { $0.id == uuid }) else { continue }
            nodes[index].regionID = region
        }

        // Group records from foreign group id strings.
        for (uuid, rawGroups) in memberGroups {
            for rawGroup in rawGroups {
                let groupUUID = CanvasExchangeIDs.stable(options.namespace + ".group", rawGroup)
                if let index = groupIndex[rawGroup] {
                    if !groups[index].memberNodeIDs.contains(uuid) {
                        groups[index].memberNodeIDs.append(uuid)
                    }
                } else {
                    groupIndex[rawGroup] = groups.count
                    groups.append(CanvasGroupRecord(id: groupUUID, name: rawGroup, memberNodeIDs: [uuid]))
                }
                externalIDs[groupUUID] = rawGroup
            }
        }

        // Bindings on arrows -> semantic connections (geometry stays on the
        // shape; the connection is the editable relation).
        var connectionByArrowUUID: [UUID: UUID] = [:]
        for line in boundLines {
            func endpoint(_ key: String) -> UUID? {
                guard let binding = line.raw[key]?.objectValue,
                      let target = binding["elementId"]?.stringValue else { return nil }
                return elementUUIDs[target]
            }
            guard let sourceID = endpoint("startBinding"), let destinationID = endpoint("endBinding") else { continue }
            let connectionID = CanvasExchangeIDs.stable(options.namespace + ".binding", externalIDs[line.uuid] ?? line.uuid.uuidString)
            connections.append(CanvasConnectionSnapshot(
                id: connectionID,
                sourceNodeID: sourceID,
                destinationNodeID: destinationID,
                kind: .arrow,
                label: nil
            ))
            connectionByArrowUUID[line.uuid] = connectionID
            if let original = originalNodes[line.uuid] {
                originalEdges[connectionID] = original
            }
        }
        // Bound text collected once every element has been seen. A text
        // bound to a connection-carrying arrow is the CONNECTION label (not
        // shape text); otherwise it folds into its container shape. Orphans
        // become standalone rich text.
        for (containerRaw, texts) in pendingBoundText {
            guard let containerUUID = elementUUIDs[containerRaw] else {
                for entry in texts {
                    issues.append(.init("excalidraw.text.orphan", "bound text \(entry.uuid) has no resolvable container \"\(containerRaw)\"; imported as standalone text", contentClass: "richText", severity: .preserved))
                    nodes.append(CanvasNodeSnapshot(
                        id: entry.uuid,
                        kind: .content,
                        title: nil,
                        content: CanvasExchangeContent.richText([CanvasRichTextRun(text: entry.text)]),
                        frame: .init(center: .zero, size: .init(width: 240, height: 60))
                    ))
                }
                continue
            }
            let combined = texts.map(\.text).joined(separator: "\n")
            if let connectionID = connectionByArrowUUID[containerUUID],
               let index = connections.firstIndex(where: { $0.id == connectionID }) {
                connections[index].label = combined
                continue
            }
            guard let index = nodes.firstIndex(where: { $0.id == containerUUID }) else { continue }
            if case .shape(let kind, let existing) = nodes[index].content {
                nodes[index].content = .shape(kind: kind, text: existing.isEmpty ? combined : existing + "\n" + combined)
            }
        }
        // files dictionary -> asset bytes.
        if let files = root["files"]?.objectValue {
            guard files.count <= CanvasExchangeLimits.maxArchiveEntries else {
                throw CanvasExchangeError.limitExceeded("Excalidraw files dictionary has \(files.count) entries; the limit is \(CanvasExchangeLimits.maxArchiveEntries)")
            }
            for (fileID, fileValue) in files {
                guard let fileObject = fileValue.objectValue else { continue }
                let assetID = CanvasExchangeIDs.stable(options.namespace + ".file", fileID)
                guard let dataURL = fileObject["dataURL"]?.stringValue,
                      dataURL.hasPrefix("data:"),
                      let comma = dataURL.firstIndex(of: ",") else {
                    issues.append(.init("excalidraw.file.noDataURL", "file \"\(fileID)\" has no embedded dataURL; the image stays a reference", contentClass: "media", severity: .unavailable))
                    continue
                }
                let payload = String(dataURL[comma...].dropFirst())
                guard let bytes = Data(base64Encoded: payload) else {
                    issues.append(.init("excalidraw.file.badDataURL", "file \"\(fileID)\" has invalid base64 data", contentClass: "media", severity: .rejected))
                    continue
                }
                guard bytes.count <= CanvasExchangeLimits.maxSingleEntryBytes else {
                    throw CanvasExchangeError.limitExceeded("embedded file \"\(fileID)\" exceeds the byte bound")
                }
                assets[assetID] = bytes
            }
        }

        if tombstones > 0 {
            issues.append(.init("excalidraw.tombstones", "\(tombstones) deleted element tombstone(s) dropped from the editable model; they remain in the original document sidecar", contentClass: "node", severity: .preserved))
        }

        let page = CanvasPageSnapshot(
            id: UUID(),
            name: options.canvasName,
            nodes: nodes,
            connections: connections,
            strokes: strokes,
            groups: groups,
            regions: regions,
            background: .blank
        )
        let snapshot = CanvasSnapshot(id: options.canvasID, name: options.canvasName, pages: [page])
        let source = CanvasOriginalSource(
            kind: .excalidrawOriginal,
            suggestedName: "\(options.canvasID.uuidString).excalidraw",
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
        /// uuid -> original external id.
        public var externalIDs: [UUID: String]
        /// uuid -> original foreign element tree (unknown fields re-injected).
        public var originalNodes: [UUID: JSONValue]
        /// Asset bytes for media nodes (image elements + files entries).
        public var assetBytes: [UUID: Data]
        /// uuid -> bound-text original (fontSize etc. re-injected verbatim).
        public var originalEdges: [UUID: JSONValue]
        public var originalDocument: JSONValue?

        public init(pageID: UUID? = nil, multiPageStrategy: CanvasMultiPageStrategy = .selectedPageOnly, externalIDs: [UUID: String] = [:], originalNodes: [UUID: JSONValue] = [:], assetBytes: [UUID: Data] = [:], originalEdges: [UUID: JSONValue] = [:], originalDocument: JSONValue? = nil) {
            self.pageID = pageID
            self.multiPageStrategy = multiPageStrategy
            self.externalIDs = externalIDs
            self.originalNodes = originalNodes
            self.assetBytes = assetBytes
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
                issues.append(skippedPages(snapshot, exported: page))
            }
            pages = [page]
        } else if options.multiPageStrategy == .oneFilePerPage {
            pages = snapshot.pages
        } else {
            guard let page = snapshot.selectedPage ?? snapshot.pages.first else {
                throw CanvasExchangeError.invalid("canvas has no pages")
            }
            if snapshot.pages.count > 1 {
                issues.append(skippedPages(snapshot, exported: page))
            }
            pages = [page]
        }

        let files: [CanvasExchangeFile] = try pages.map { page in
            var document = try exportPage(page, snapshot: snapshot, options: options, issues: &issues)
            if let original = options.originalDocument?.objectValue {
                for (key, value) in original where key != "elements" && key != "files" {
                    if document[key] == nil { document[key] = value }
                }
            }
            let data = try JSONFidelity.serialize(.object(document), options: .init(sortedKeys: true, prettyPrinted: true))
            let name = pages.count == 1
                ? CanvasExchangeFilename.sanitized(snapshot.name, extension: "excalidraw")
                : CanvasExchangeFilename.sanitized("\(snapshot.name)-\(page.name)", extension: "excalidraw", fallback: "page")
            return CanvasExchangeFile(name: name, data: data)
        }
        return CanvasExchangeOutput(files: files, issues: issues)
    }

    private static func skippedPages(_ snapshot: CanvasSnapshot, exported: CanvasPageSnapshot) -> CanvasExchangeIssue {
        let skipped = snapshot.pages.filter { $0.id != exported.id }
            .map { "\"\($0.name)\"" }.joined(separator: ", ")
        return .init(
            "excalidraw.multipage",
            "Excalidraw holds one scene per file; exported \"\(exported.name)\" only. Skipped: \(skipped). Use oneFilePerPage — nothing was silently dropped.",
            contentClass: "archive", severity: .loss
        )
    }

    private static func exportPage(_ page: CanvasPageSnapshot, snapshot: CanvasSnapshot, options: ExportOptions, issues: inout [CanvasExchangeIssue]) throws -> [String: JSONValue] {
        var elements: [JSONValue] = []
        var files: [String: JSONValue] = [:]
        /// Emitted node element index by external id, so a semantic
        /// connection that originated from a line/arrow element can merge
        /// back into it instead of duplicating a second arrow.
        var nodeElementIndex: [String: Int] = [:]

        func base(_ uuid: UUID, type: String, frame: CanvasGeometry.Frame, rotationDegrees: Double, style: CanvasExchangeContent.Style) -> [String: JSONValue] {
            var object: [String: JSONValue] = [
                "id": .string(options.externalIDs[uuid] ?? uuid.uuidString),
                "type": .string(type),
                "x": .number(CanvasExchangeGeometry.number(frame.minX)),
                "y": .number(CanvasExchangeGeometry.number(frame.minY)),
                "width": .number(CanvasExchangeGeometry.number(frame.size.width)),
                "height": .number(CanvasExchangeGeometry.number(frame.size.height)),
                "angle": .number(CanvasExchangeGeometry.number(rotationDegrees * .pi / 180)),
                "strokeColor": .string(style.stroke ?? "#1e293b"),
                "backgroundColor": .string(style.fill ?? "transparent"),
                "fillStyle": .string("solid"),
                "strokeWidth": .number(CanvasExchangeGeometry.number(style.strokeWidth ?? 2)),
                "strokeStyle": .string("solid"),
                "roundness": .null,
                "roughness": .number("0"),
                "opacity": .number("100"),
                "seed": .number(String(seed(for: uuid))),
                "version": .number("1"),
                "versionNonce": .number(String(seed(for: uuid) &+ 1)),
                "index": .null,
                "isDeleted": .bool(false),
                "groupIds": .array(groupIDs(for: uuid, page: page, options: options).map { .string($0) }),
                "frameId": regionFrameID(for: uuid, page: page, options: options).map { .string($0) } ?? .null,
                "boundElements": .null,
                "updated": .number("1"),
                "link": .null,
                "locked": .bool(false),
            ]
            return object
        }

        for node in page.nodes {
            let style = CanvasExchangeContent.style(of: node)
            switch node.content {
            case .shape(let kind, let text):
                let type: String
                switch kind {
                case .rectangle: type = "rectangle"
                case .roundedRectangle: type = "rectangle"
                case .ellipse: type = "ellipse"
                case .diamond: type = "diamond"
                case .line: type = "line"
                case .arrow: type = "arrow"
                }
                var object = base(node.id, type: type, frame: node.frame, rotationDegrees: node.rotationDegrees, style: style)
                if kind == .line || kind == .arrow {
                    object["points"] = .array([
                        .array([.number("0"), .number("0")]),
                        .array([.number(CanvasExchangeGeometry.number(node.frame.size.width)), .number(CanvasExchangeGeometry.number(node.frame.size.height))]),
                    ])
                    object["lastCommittedPoint"] = .null
                    object["startBinding"] = .null
                    object["endBinding"] = .null
                    object["startArrowhead"] = .null
                    object["endArrowhead"] = kind == .arrow ? .string("arrow") : .null
                    object["elbowed"] = .bool(false)
                    if let raw = object["id"]?.stringValue {
                        nodeElementIndex[raw] = elements.count
                    }
                }
                if !text.isEmpty {
                    object["boundElements"] = .array([.object(["id": .string(bindingTextID(for: node.id)), "type": .string("text")])])
                }
                reinject(&object, original: options.originalNodes[node.id])
                elements.append(.object(object))
                if !text.isEmpty {
                    var textObject = base(node.id, type: "text", frame: node.frame, rotationDegrees: 0, style: style)
                    textObject["id"] = .string(bindingTextID(for: node.id))
                    textObject["text"] = .string(text)
                    textObject["originalText"] = .string(text)
                    textObject["containerId"] = .string(options.externalIDs[node.id] ?? node.id.uuidString)
                    textObject["fontSize"] = .number("20")
                    textObject["fontFamily"] = .number("1")
                    textObject["textAlign"] = .string("center")
                    textObject["verticalAlign"] = .string("middle")
                    textObject["autoResize"] = .bool(true)
                    textObject["lineHeight"] = .number("1.25")
                    textObject["isDeleted"] = .bool(false)
                    reinject(&textObject, original: options.originalNodes[node.id].flatMap { $0["containerText"] })
                    elements.append(.object(textObject))
                }
            case .richText(let document):
                let text = CanvasExchangeContent.plainText(runs: document.runs)
                var object = base(node.id, type: "text", frame: node.frame, rotationDegrees: node.rotationDegrees, style: style)
                object["text"] = .string(text)
                object["originalText"] = .string(text)
                object["fontSize"] = .number("20")
                object["fontFamily"] = .number("1")
                object["textAlign"] = .string("left")
                object["verticalAlign"] = .string("top")
                object["containerId"] = .null
                object["autoResize"] = .bool(true)
                object["lineHeight"] = .number("1.25")
                if document.runs.count > 1 || document.runs.contains(where: { $0.bold || $0.italic || $0.underline || $0.strikethrough || $0.link != nil || $0.foregroundColor != nil }) {
                    issues.append(.init("excalidraw.richText", "node \(node.id): rich text runs are projected to plain text in Excalidraw; formatting retained in the native archive", contentClass: "richText", severity: .loss))
                }
                reinject(&object, original: options.originalNodes[node.id])
                elements.append(.object(object))
            case .text(let text), .markdown(let text, _):
                var object = base(node.id, type: "text", frame: node.frame, rotationDegrees: node.rotationDegrees, style: style)
                object["text"] = .string(text)
                object["originalText"] = .string(text)
                object["fontSize"] = .number("20")
                object["fontFamily"] = .number("1")
                object["textAlign"] = .string("left")
                object["verticalAlign"] = .string("top")
                object["containerId"] = .null
                object["autoResize"] = .bool(true)
                object["lineHeight"] = .number("1.25")
                reinject(&object, original: options.originalNodes[node.id])
                elements.append(.object(object))
            case .media(let locator):
                guard let bytes = options.assetBytes[locator.id] else {
                    issues.append(.init("excalidraw.media.unavailable", "media node \(node.id) has no injected bytes; the image is omitted from the export (never a blank placeholder)", contentClass: "media", severity: .unavailable))
                    continue
                }
                let fileID = options.externalIDs[locator.id] ?? locator.id.uuidString
                let mime = locator.mimeType ?? "application/octet-stream"
                var object = base(node.id, type: "image", frame: node.frame, rotationDegrees: node.rotationDegrees, style: style)
                object["fileId"] = .string(fileID)
                object["fileMimeType"] = .string(mime)
                object["scale"] = .array([.number("1"), .number("1")])
                files[fileID] = .object(["mimeType": .string(mime), "id": .string(fileID), "dataURL": .string("data:\(mime);base64,\(bytes.base64EncodedString())")])
                reinject(&object, original: options.originalNodes[node.id])
                elements.append(.object(object))
            case .pdf, .editor, .web, .formula, .table, .code:
                issues.append(.init("excalidraw.content.unsupported", "node \(node.id) content is not representable in Excalidraw; exported as text projection", contentClass: "node", severity: .loss))
                var object = base(node.id, type: "text", frame: node.frame, rotationDegrees: node.rotationDegrees, style: style)
                let text = CanvasExchangeContent.plainText(of: node.content)
                object["text"] = .string(text)
                object["originalText"] = .string(text)
                object["fontSize"] = .number("16")
                object["fontFamily"] = .number("1")
                object["textAlign"] = .string("left")
                object["verticalAlign"] = .string("top")
                object["containerId"] = .null
                object["autoResize"] = .bool(true)
                object["lineHeight"] = .number("1.25")
                elements.append(.object(object))
            case .unknown:
                issues.append(.init("excalidraw.content.unknown", "node \(node.id) keeps unknown content in the sidecar only; exported as text projection", contentClass: "unknownContent", severity: .loss))
                var object = base(node.id, type: "text", frame: node.frame, rotationDegrees: node.rotationDegrees, style: style)
                let text = CanvasExchangeContent.plainText(of: node.content)
                object["text"] = .string(text)
                object["originalText"] = .string(text)
                object["fontSize"] = .number("16")
                object["fontFamily"] = .number("1")
                object["textAlign"] = .string("left")
                object["verticalAlign"] = .string("top")
                object["containerId"] = .null
                object["autoResize"] = .bool(true)
                object["lineHeight"] = .number("1.25")
                elements.append(.object(object))
            }
        }

        // Discrete strokes -> freedraw elements (world points made relative).
        for stroke in page.strokes {
            guard stroke.points.count <= CanvasExchangeLimits.maxPointsPerStroke else {
                issues.append(.init("excalidraw.stroke.tooManyPoints", "stroke \(stroke.id) exceeds the point bound and was skipped", contentClass: "stroke", severity: .rejected))
                continue
            }
            guard let first = stroke.points.first else { continue }
            let xs = stroke.points.map(\.x), ys = stroke.points.map(\.y)
            let minX = xs.min()!, minY = ys.min()!
            var object = base(stroke.id, type: "freedraw", frame: .init(center: .init(x: minX + (xs.max()! - minX) / 2, y: minY + (ys.max()! - minY) / 2), size: .init(width: max(1, xs.max()! - minX), height: max(1, ys.max()! - minY))), rotationDegrees: 0, style: .init(stroke: stroke.color, strokeWidth: stroke.width))
            object["points"] = .array(stroke.points.map { .array([.number(CanvasExchangeGeometry.number($0.x - first.x)), .number(CanvasExchangeGeometry.number($0.y - first.y))]) })
            object["simulatePressure"] = .bool(false)
            object["lastCommittedPoint"] = .null
            if let original = options.originalNodes[stroke.id]?.objectValue, let pressures = original["pressures"] {
                object["pressures"] = pressures
            }
            elements.append(.object(object))
        }

        // Regions -> frames.
        for region in page.regions {
            var object = base(region.id, type: "frame", frame: region.frame, rotationDegrees: 0, style: .init())
            object["name"] = .string(region.name)
            reinject(&object, original: options.originalNodes[region.id])
            elements.append(.object(object))
        }

        // Semantic connections -> bound arrows (geometry auto-derived).
        // A connection imported from a foreign line/arrow merges back into
        // that same element (identified through the original sidecar), so a
        // round trip emits ONE arrow instead of a duplicated pair.
        for connection in page.connections {
            guard let source = page.nodes.first(where: { $0.id == connection.sourceNodeID }),
                  let target = page.nodes.first(where: { $0.id == connection.destinationNodeID }) else {
                issues.append(.init("excalidraw.connection.dangling", "connection \(connection.id) references a missing endpoint and was skipped", contentClass: "connection", severity: .rejected))
                continue
            }
            if let rawArrowID = options.originalEdges[connection.id]?["id"]?.stringValue,
               let index = nodeElementIndex[rawArrowID],
               case .object(var merged) = elements[index],
               merged["type"]?.stringValue == "line" || merged["type"]?.stringValue == "arrow" {
                let sourceExternal = options.externalIDs[source.id] ?? source.id.uuidString
                let targetExternal = options.externalIDs[target.id] ?? target.id.uuidString
                merged["startBinding"] = .object(["elementId": .string(sourceExternal), "focus": .number("0"), "gap": .number("0")])
                merged["endBinding"] = .object(["elementId": .string(targetExternal), "focus": .number("0"), "gap": .number("0")])
                merged["endArrowhead"] = connection.kind == .line ? .null : .string("arrow")
                merged["startArrowhead"] = connection.kind == .source ? .string("arrow") : .null
                if let label = connection.label {
                    let textID = bindingTextID(for: connection.id)
                    merged["boundElements"] = .array([.object(["id": .string(textID), "type": .string("text")])])
                    var textObject = base(connection.id, type: "text", frame: objectFrame(connection, source: source, target: target), rotationDegrees: 0, style: .init())
                    textObject["id"] = .string(textID)
                    textObject["text"] = .string(label)
                    textObject["originalText"] = .string(label)
                    textObject["containerId"] = .string(rawArrowID)
                    textObject["fontSize"] = .number("16")
                    textObject["fontFamily"] = .number("1")
                    textObject["textAlign"] = .string("center")
                    textObject["verticalAlign"] = .string("middle")
                    textObject["autoResize"] = .bool(true)
                    textObject["lineHeight"] = .number("1.25")
                    elements.append(.object(textObject))
                }
                reinject(&merged, original: options.originalEdges[connection.id])
                elements[index] = .object(merged)
                continue
            }
            let sourceExternal = options.externalIDs[source.id] ?? source.id.uuidString
            let targetExternal = options.externalIDs[target.id] ?? target.id.uuidString
            var object = base(connection.id, type: "arrow", frame: .init(center: .init(x: (source.frame.center.x + target.frame.center.x) / 2, y: (source.frame.center.y + target.frame.center.y) / 2), size: .init(width: abs(target.frame.center.x - source.frame.center.x), height: abs(target.frame.center.y - source.frame.center.y))), rotationDegrees: 0, style: .init())
            object["points"] = .array([
                .array([.number("0"), .number("0")]),
                .array([.number(CanvasExchangeGeometry.number(abs(target.frame.center.x - source.frame.center.x))), .number(CanvasExchangeGeometry.number(abs(target.frame.center.y - source.frame.center.y)))]),
            ])
            object["lastCommittedPoint"] = .null
            object["startBinding"] = .object(["elementId": .string(sourceExternal), "focus": .number("0"), "gap": .number("0")])
            object["endBinding"] = .object(["elementId": .string(targetExternal), "focus": .number("0"), "gap": .number("0")])
            object["startArrowhead"] = connection.kind == .line ? .null : (connection.kind == .source ? .string("arrow") : .null)
            object["endArrowhead"] = connection.kind == .line ? .null : .string("arrow")
            object["elbowed"] = .bool(false)
            if let label = connection.label {
                let textID = bindingTextID(for: connection.id)
                object["boundElements"] = .array([.object(["id": .string(textID), "type": .string("text")])])
                var textObject = base(connection.id, type: "text", frame: objectFrame(connection, source: source, target: target), rotationDegrees: 0, style: .init())
                textObject["id"] = .string(textID)
                textObject["text"] = .string(label)
                textObject["originalText"] = .string(label)
                textObject["containerId"] = .string(options.externalIDs[connection.id] ?? connection.id.uuidString)
                textObject["fontSize"] = .number("16")
                textObject["fontFamily"] = .number("1")
                textObject["textAlign"] = .string("center")
                textObject["verticalAlign"] = .string("middle")
                textObject["autoResize"] = .bool(true)
                textObject["lineHeight"] = .number("1.25")
                elements.append(.object(textObject))
            }
            reinject(&object, original: options.originalEdges[connection.id])
            elements.append(.object(object))
        }

        // Unrepresentable content classes (retained in the native archive).
        if CanvasExchangePencilSupport.drawingData(of: page) != nil {
            issues.append(.init("excalidraw.pencil.notRepresentable", "page \"\(page.name)\" carries PKDrawing ink; Excalidraw cannot preserve pressure/style — the native archive retains it and discrete strokes export as freedraw", contentClass: "pencil", severity: .loss))
        }
        if !CanvasExchangeFlowSupport.flowGraphs(of: page).isEmpty {
            issues.append(.init("excalidraw.flowGraphs.notRepresentable", "page \"\(page.name)\" carries flow graphs; open formats never execute or embed Floe flows — the native archive retains them", contentClass: "flowGraph", severity: .loss))
        }
        if !page.scenes.isEmpty {
            issues.append(.init("excalidraw.scenes.notRepresentable", "page \"\(page.name)\" carries \(page.scenes.count) scene(s); Excalidraw has no ordered scene concept", contentClass: "scene", severity: .loss))
        }

        var document: [String: JSONValue] = [
            "type": .string("excalidraw"),
            "version": .number("2"),
            "source": .string("FloeCanvasExchange"),
            "elements": .array(elements),
        ]
        if !files.isEmpty { document["files"] = .object(files) }
        if let appState = options.originalDocument?["appState"], appState != .null {
            document["appState"] = appState
        }
        return document
    }

    // MARK: Helpers

    private static func seed(for uuid: UUID) -> Int {
        Int(CanvasDigest.sha256(Data(uuid.uuidString.utf8)).prefix(8), radix: 16) ?? 1
    }

    private static func bindingTextID(for uuid: UUID) -> String {
        CanvasDigest.sha256(Data(("text:" + uuid.uuidString).utf8)).prefix(12) + "-bound"
    }

    private static func objectFrame(_ connection: CanvasConnectionSnapshot, source: CanvasNodeSnapshot, target: CanvasNodeSnapshot) -> CanvasGeometry.Frame {
        let center = CanvasGeometry.Point(x: (source.frame.center.x + target.frame.center.x) / 2, y: (source.frame.center.y + target.frame.center.y) / 2)
        return .init(center: center, size: .init(width: max(120.0, Double(connection.label?.count ?? 0)), height: 40))
    }

    private static func groupIDs(for uuid: UUID, page: CanvasPageSnapshot, options: ExportOptions) -> [String] {
        page.groups
            .filter { $0.memberNodeIDs.contains(uuid) }
            .map { options.externalIDs[$0.id] ?? $0.id.uuidString }
    }

    private static func regionFrameID(for uuid: UUID, page: CanvasPageSnapshot, options: ExportOptions) -> String? {
        let explicit = page.nodes.first(where: { $0.id == uuid })?.regionID
        let derived = page.regions.first(where: { region in regionContains(region: region, nodeID: uuid, page: page) })?.id
        guard let regionID = explicit ?? derived else { return nil }
        return options.externalIDs[regionID] ?? regionID.uuidString
    }

    private static func regionContains(region: CanvasRegionRecord, nodeID: UUID, page: CanvasPageSnapshot) -> Bool {
        guard let node = page.nodes.first(where: { $0.id == nodeID }) else { return false }
        return node.frame.center.x > region.frame.minX && node.frame.center.x < region.frame.maxX
            && node.frame.center.y > region.frame.minY && node.frame.center.y < region.frame.maxY
    }

    private static func reinject(_ object: inout [String: JSONValue], original: JSONValue?) {
        guard let original = original?.objectValue else { return }
        for (key, value) in original where object[key] == nil {
            object[key] = value
        }
    }
}
