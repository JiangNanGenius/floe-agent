// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCanvasCore
import FloeDiagramCore
import FloeDiagramIntegration
import FloeDiagramExchange

/// Bidirectional draw.io (diagrams.net) codec built on the proven public
/// DiagramKit exchange codec (`DiagramExchange.importData/export` with
/// `.drawio`): real compressed-payload support, bounded XML parsing with
/// DTD/external-entity refusal, and multipage `<diagram>` handling all come
/// from DiagramKit unchanged. This file only maps between
/// `CanvasSnapshot` and `DiagramDocument`.
///
/// Semantics (root decision 2026-11-03): flow cards and their relations
/// export as ordinary editable visual projections; execution definitions
/// and typed flow edges are never represented as executable in the target,
/// and the per-class loss table in FORMAT_SUPPORT.md says exactly what is
/// visual-only. Importing visual objects never creates execution
/// permissions or schedules anything.
public enum CanvasDrawIOCodec {
    public static let namespace = "floe.drawio.v1"

    // MARK: Import

    public struct ImportOptions: Sendable {
        public var canvasID: UUID
        public var canvasName: String
        public var namespace: String
        public init(canvasID: UUID = UUID(), canvasName: String = "Imported draw.io", namespace: String = CanvasDrawIOCodec.namespace) {
            self.canvasID = canvasID
            self.canvasName = canvasName
            self.namespace = namespace
        }
    }

    public static func decode(_ data: Data, options: ImportOptions = ImportOptions()) throws -> CanvasExchangeBundle {
        try CanvasExchangeLimits.validateInputSize(data)
        let result: DiagramImportResult
        do {
            result = try DiagramExchange.importData(data, format: .drawio, title: options.canvasName)
        } catch let error as DiagramError {
            throw mapDiagramError(error)
        }
        return try mapDocument(result, options: options)
    }

    private static func mapDocument(_ result: DiagramImportResult, options: ImportOptions) throws -> CanvasExchangeBundle {
        var issues: [CanvasExchangeIssue] = result.issues.map {
            CanvasExchangeIssue("drawio." + $0.code, $0.detail, contentClass: "node", severity: .preserved)
        }
        var pages: [CanvasPageSnapshot] = []
        var externalIDs: [UUID: String] = [:]
        var originalNodes: [UUID: JSONValue] = [:]
        var originalEdges: [UUID: JSONValue] = [:]
        var assets: [UUID: Data] = [:]

        for (pageIndex, diagramPage) in result.document.pages.enumerated() {
            var nodes: [CanvasNodeSnapshot] = []
            var regions: [CanvasRegionRecord] = []
            var groupsByID: [UUID: CanvasGroupRecord] = [:]
            var connections: [CanvasConnectionSnapshot] = []

            // Group containers reach this page through two shapes: foreign
            // files mark the container with `floeGroup=1` in its style, and
            // exports from this codec bind members with the `floeParent`
            // attribute while the container itself keeps an empty member
            // list. Both keep move-together groups distinct from regions.
            var groupContainerIDs: Set<UUID> = []
            for element in diagramPage.elements where element.kind == .group {
                if element.metadata["drawioStyle"]?.contains("floeGroup=1") == true {
                    groupContainerIDs.insert(element.id)
                }
            }
            for element in diagramPage.elements {
                if let parent = element.parentID, element.metadata["derivedBranch"] != "true" {
                    groupContainerIDs.insert(parent)
                }
            }

            for element in diagramPage.elements {
                externalIDs[element.id] = element.metadata["externalID"]
                if let rawStyle = element.metadata["drawioStyle"] {
                    originalNodes[element.id] = .object(["style": .string(rawStyle), "value": .string(element.metadata["drawioValue"] ?? "")])
                }
                guard let frame = element.frame else {
                    issues.append(.init("drawio.element.noFrame", "element \(element.id) has no geometry and was skipped", contentClass: "node", severity: .rejected))
                    continue
                }
                let canvasFrame = CanvasGeometry.Frame(
                    center: .init(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2),
                    size: .init(width: frame.width, height: frame.height)
                )
                var metadata: [String: String] = [:]
                metadata[CanvasExchangeStyleKey.fillColor] = element.style.fill
                metadata[CanvasExchangeStyleKey.strokeColor] = element.style.stroke
                metadata[CanvasExchangeStyleKey.strokeWidth] = CanvasExchangeGeometry.number(element.style.lineWidth)
                metadata[CanvasExchangeStyleKey.textColor] = element.style.text

                let content: CanvasContent
                switch element.kind {
                case .group where groupContainerIDs.contains(element.id):
                    // Group container: members arrive through their
                    // containerID; the record is created here.
                    groupsByID[element.id] = CanvasGroupRecord(
                        id: element.id,
                        name: element.title,
                        memberNodeIDs: groupsByID[element.id]?.memberNodeIDs ?? []
                    )
                    continue
                case .group, .swimlane, .swimlanePool:
                    regions.append(CanvasRegionRecord(id: element.id, name: element.title, frame: canvasFrame, isCollapsed: element.collapsed))
                    continue
                case .rectangle, .roundedRectangle:
                    content = .shape(kind: .roundedRectangle, text: element.content.isEmpty ? element.title : "")
                case .ellipse:
                    content = .shape(kind: .ellipse, text: element.content.isEmpty ? element.title : "")
                case .diamond:
                    content = .shape(kind: .diamond, text: element.content.isEmpty ? element.title : "")
                case .text:
                    content = CanvasExchangeContent.richText([CanvasRichTextRun(text: element.title)])
                case .parallelogram, .summary, .boundary, .topic, .floatingTopic:
                    content = .unknown(kind: "floe.drawio.\(element.kind.rawValue)", payload: .object(["style": .string(element.metadata["drawioStyle"] ?? ""), "title": .string(element.title)]))
                    issues.append(.init("drawio.shape.projected", "element \(element.id) kind \(element.kind.rawValue) has no native canvas shape; kept as unknown with its original style", contentClass: "shape", severity: .preserved))
                }

                // Rich content blocks.
                var richContent: CanvasContent = content
                var plainParts: [String] = []
                var runs: [CanvasRichTextRun] = []
                for block in element.content {
                    switch block {
                    case .note(let text):
                        plainParts.append(text)
                    case .code(_, let source):
                        richContent = .code(language: nil, source: source)
                    case .table(let table):
                        var rows = table.rows
                        let header: [String] = table.header && !rows.isEmpty ? rows.removeFirst() : []
                        richContent = .table(header: header, rows: rows)
                    case .formula(let latex):
                        richContent = .formula(source: latex, renderedAssetID: nil)
                    case .image(let id, _):
                        if let bytes = result.assets[id] {
                            let locator = CanvasAssetLocator(
                                id: id,
                                contentHash: CanvasDigest.sha256(bytes),
                                mimeType: result.document.assets.first(where: { $0.id == id })?.mediaType,
                                byteCount: Int64(bytes.count)
                            )
                            assets[id] = bytes
                            richContent = .media(locator)
                        } else {
                            issues.append(.init("drawio.image.missingBytes", "element \(element.id) references image \(id) with no resolved bytes; kept as text", contentClass: "media", severity: .unavailable))
                        }
                    case .richText(let textRuns):
                        runs = textRuns.map {
                            CanvasRichTextRun(text: $0.text, bold: $0.bold, italic: $0.italic, underline: $0.underline, link: $0.link.flatMap(URL.init(string:)))
                        }
                    case .attachment(let id):
                        if let asset = result.document.assets.first(where: { $0.id == id }) {
                            richContent = .media(CanvasAssetLocator(id: id, mimeType: asset.mediaType, byteCount: Int64(asset.byteCount)))
                        }
                    }
                }
                if !runs.isEmpty {
                    richContent = CanvasExchangeContent.richText(runs)
                } else if plainParts.count > 1 {
                    richContent = .text(plainParts.joined(separator: "\n"))
                } else if plainParts.count == 1, case .shape(let kind, _) = content {
                    richContent = .shape(kind: kind, text: plainParts[0])
                }

                var node = CanvasNodeSnapshot(
                    id: element.id,
                    kind: .content,
                    title: element.kind.isContainer ? nil : element.title,
                    content: richContent,
                    frame: canvasFrame,
                    isLocked: element.isLocked,
                    metadata: metadata
                )
                // draw.io `floeParent` (legacy exports) -> canvas group
                // membership; containerID against a marked group element is
                // the current encoding.
                func addMember(_ groupID: UUID) {
                    if groupsByID[groupID] != nil {
                        if groupsByID[groupID]?.memberNodeIDs.contains(node.id) != true {
                            groupsByID[groupID]?.memberNodeIDs.append(node.id)
                        }
                    } else {
                        groupsByID[groupID] = CanvasGroupRecord(id: groupID, name: "", memberNodeIDs: [node.id])
                    }
                }
                if let parentID = element.parentID, element.metadata["derivedBranch"] != "true" {
                    addMember(parentID)
                }
                if let container = element.containerID {
                    if groupContainerIDs.contains(container) {
                        node.groupID = container
                        addMember(container)
                    } else {
                        node.regionID = container
                    }
                }
                nodes.append(node)
            }

            // Region containment for nodes without an explicit container.
            for index in nodes.indices where nodes[index].regionID == nil {
                let frame = nodes[index].frame
                if let region = regions.first(where: {
                    frame.center.x > $0.frame.minX && frame.center.x < $0.frame.maxX
                        && frame.center.y > $0.frame.minY && frame.center.y < $0.frame.maxY
                }) {
                    nodes[index].regionID = region.id
                }
            }

            for connection in diagramPage.connections where connection.metadata["derivedBranch"] != "true" {
                let kind: CanvasRelationKind
                if connection.endArrow || connection.startArrow {
                    kind = .arrow
                } else {
                    kind = .line
                }
                let canvasConnection = CanvasConnectionSnapshot(
                    id: connection.id,
                    sourceNodeID: connection.from,
                    destinationNodeID: connection.to,
                    kind: kind,
                    label: connection.label.isEmpty ? nil : connection.label,
                    sourcePort: mapPort(connection.sourceAnchor),
                    destinationPort: mapPort(connection.targetAnchor)
                )
                connections.append(canvasConnection)
                if let style = connection.metadata["drawioStyle"] {
                    originalEdges[connection.id] = .object(["style": .string(style), "value": .string(connection.label)])
                }
                if !connection.waypoints.isEmpty {
                    issues.append(.init("drawio.waypoints", "connection \(connection.id) has \(connection.waypoints.count) waypoints the canvas relation model does not store; kept in the original payload", contentClass: "connection", severity: .preserved))
                }
            }

            let groupRecords = groupsByID
                .sorted { $0.key.uuidString < $1.key.uuidString }
                .map(\.value)
            pages.append(CanvasPageSnapshot(
                id: diagramPage.id,
                name: diagramPage.title,
                nodes: nodes,
                connections: connections,
                groups: groupRecords,
                regions: regions,
                background: .blank
            ))
            if diagramPage.ink != nil {
                issues.append(.init("drawio.ink", "draw.io page \(pageIndex + 1) carries ink data the canvas snapshot does not embed; keep the native archive", contentClass: "pencil", severity: .loss))
            }
        }

        let snapshot = CanvasSnapshot(id: options.canvasID, name: options.canvasName, pages: pages)
        let originalBytes = result.document.legacyPayload ?? Data()
        let source = CanvasOriginalSource(
            kind: .drawioOriginal,
            suggestedName: "\(options.canvasID.uuidString).drawio",
            byteCount: originalBytes.count,
            sha256: CanvasDigest.sha256(originalBytes),
            nodeIDs: pages.flatMap { $0.nodes.map(\.id) }
        )
        return CanvasExchangeBundle(
            snapshot: snapshot,
            assets: assets,
            originalSources: [source],
            externalIDs: externalIDs,
            originalNodes: originalNodes,
            originalEdges: originalEdges,
            issues: issues
        )
    }

    // MARK: Export

    public struct ExportOptions: Sendable {
        /// Asset resolver for image elements (bytes embedded by DiagramKit).
        public var assetResolver: (any DiagramAssetResolver)?
        /// Compress draw.io page payloads (standard diagrams.net encoding).
        public var compressed: Bool
        public init(assetResolver: (any DiagramAssetResolver)? = nil, compressed: Bool = false) {
            self.assetResolver = assetResolver
            self.compressed = compressed
        }
    }

    /// Bridges the canvas asset channel onto DiagramKit's resolver protocol.
    /// DiagramKit's public draw.io geometry path consumes no asset bytes
    /// today; the bridge keeps the option honest (it resolves real bytes if a
    /// future DiagramKit revision embeds images) instead of silently dropping
    /// the resolver.
    struct CanvasDiagramAssetResolverAdapter: DiagramAssetResolver {
        let base: any CanvasAssetResolver
        func data(for asset: DiagramAsset) async throws -> Data {
            try await base.data(for: CanvasAssetLocator(id: asset.id))
        }
    }

    public static func export(_ snapshot: CanvasSnapshot, options: ExportOptions = ExportOptions()) async throws -> CanvasExchangeOutput {
        let mapped = try mapSnapshot(snapshot)
        let result: DiagramExportResult
        do {
            result = try await DiagramExchange.export(mapped.document, format: .drawio, assets: options.assetResolver)
        } catch let error as DiagramError {
            throw mapDiagramError(error)
        }
        var issues: [CanvasExchangeIssue] = mapped.issues + result.issues.map {
            CanvasExchangeIssue("drawio." + $0.code, $0.detail, contentClass: "node", severity: .preserved)
        }
        var data = result.data
        if options.compressed {
            // Standard diagrams.net page encoding on top of the public
            // geometry export: URI-encode -> raw DEFLATE -> base64 per page.
            guard let xml = String(data: data, encoding: .utf8) else {
                throw CanvasExchangeError.io("draw.io: exported XML is not UTF-8")
            }
            data = Data(try CanvasDrawIOPageCompression.compressPages(ofMXFile: xml).utf8)
        }
        appendLossReport(snapshot, issues: &issues)
        return CanvasExchangeOutput(
            files: [CanvasExchangeFile(name: CanvasExchangeFilename.sanitized(snapshot.name, extension: "drawio"), data: data)],
            issues: issues
        )
    }

    static func mapSnapshot(_ snapshot: CanvasSnapshot) throws -> (document: DiagramDocument, issues: [CanvasExchangeIssue]) {
        var issues: [CanvasExchangeIssue] = []
        var pages: [DiagramPage] = []
        for page in snapshot.pages {
            var elements: [DiagramElement] = []
            var connections: [DiagramConnection] = []

            var regionFrames: [(id: UUID, frame: CanvasGeometry.Frame)] = []
            for region in page.regions {
                regionFrames.append((region.id, region.frame))
                elements.append(DiagramElement(
                    id: region.id,
                    kind: .group,
                    title: region.name,
                    order: 0,
                    frame: .init(x: region.frame.minX, y: region.frame.minY, width: region.frame.size.width, height: region.frame.size.height),
                    collapsed: region.isCollapsed
                ))
            }

            // Groups (move-together membership) become real container
            // elements marked `floeGroup=1`; regions stay unmarked
            // containers. The import side uses the marker to keep groups and
            // regions distinct — no semantic conflation either way.
            for group in page.groups {
                let memberFrames = group.memberNodeIDs.compactMap { id in
                    page.nodes.first(where: { $0.id == id })?.frame
                }
                guard !memberFrames.isEmpty else {
                    issues.append(.init("drawio.group.skipped", "group \(group.id) has no members with resolvable frames and was not exported", contentClass: "node", severity: .loss))
                    continue
                }
                let minX = memberFrames.map(\.minX).min()!
                let minY = memberFrames.map(\.minY).min()!
                let maxX = memberFrames.map(\.maxX).max()!
                let maxY = memberFrames.map(\.maxY).max()!
                elements.append(DiagramElement(
                    id: group.id,
                    kind: .group,
                    title: group.name,
                    order: 0,
                    frame: .init(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
                    collapsed: false,
                    style: .init(fill: "transparent", stroke: "border", text: "text", lineWidth: 0.5),
                    metadata: ["drawioStyle": "group;floeGroup=1;"]
                ))
            }

            // Membership is authoritative in the group records: nodes do
            // not always carry a derived `groupID` (fresh snapshots and
            // imports from foreign files keep it only in
            // `memberNodeIDs`). Resolve the effective container the same
            // way the importer re-derives it: marked group first, then an
            // explicit region, then geometric region containment.
            var groupMembership: [UUID: UUID] = [:]
            for group in page.groups {
                for memberID in group.memberNodeIDs where groupMembership[memberID] == nil {
                    groupMembership[memberID] = group.id
                }
            }

            for node in page.nodes.sorted(by: { $0.zIndex == $1.zIndex ? $0.id.uuidString < $1.id.uuidString : $0.zIndex < $1.zIndex }) {
                let style = CanvasExchangeContent.style(of: node)
                let diagramStyle = DiagramStyle(
                    fill: style.fill ?? "surface",
                    stroke: style.stroke ?? "border",
                    text: style.textColor ?? "text",
                    lineWidth: style.strokeWidth ?? 1.5
                )
                // DiagramKit's public draw.io encoder writes the element
                // title as the shape label and ignores content blocks, so
                // every visible payload is projected into the label here.
                // A node never exports as an empty card: each projection
                // carries the real text (or an explicit reference card) and
                // its own loss/issue entry.
                var title = node.title ?? ""
                var kind: DiagramElementKind = .roundedRectangle

                switch node.content {
                case .shape(let shapeKind, let text):
                    switch shapeKind {
                    case .rectangle: kind = .rectangle
                    case .roundedRectangle: kind = .roundedRectangle
                    case .ellipse: kind = .ellipse
                    case .diamond: kind = .diamond
                    case .line, .arrow:
                        // draw.io line/arrow shapes are represented as
                        // connections; a bare line/arrow with no text has
                        // nothing editable to carry.
                        if text.isEmpty {
                            issues.append(.init("drawio.lineShape.dropped", "node \(node.id) is a standalone line/arrow shape with no editable label; this projection omits it, while the native archive retains its geometry", contentClass: "shape", severity: .loss))
                            continue
                        }
                        kind = .text
                    }
                    title = text
                case .richText(let document):
                    kind = .text
                    title = CanvasExchangeContent.plainText(runs: document.runs)
                    if document.runs.count > 1 || document.runs.contains(where: { $0.bold || $0.italic || $0.underline || $0.strikethrough || $0.link != nil || $0.foregroundColor != nil }) {
                        issues.append(.init("drawio.richText.projected", "node \(node.id): character styles and links are projected to plain text — draw.io labels carry no run styles; formatting lives in the native archive", contentClass: "richText", severity: .loss))
                    }
                case .text(let text):
                    kind = .text
                    title = text
                case .markdown(let document, _):
                    kind = .text
                    title = document
                    issues.append(.init("drawio.markdown.projected", "node \(node.id): markdown exported as its raw source text; the preview hint lives in the native archive", contentClass: "node", severity: .loss))
                case .code(_, let source):
                    title = source
                    issues.append(.init("drawio.code.projected", "node \(node.id): code exported as an editable plain-text label; language metadata lives in the native archive", contentClass: "node", severity: .loss))
                case .formula(let source, _):
                    title = source
                    issues.append(.init("drawio.formula.projected", "node \(node.id): formula exported as its source text; the rendered asset lives in the native archive", contentClass: "node", severity: .loss))
                case .table(let header, let rows):
                    title = ([header] + rows)
                        .filter { !$0.isEmpty }
                        .map { $0.joined(separator: " | ") }
                        .joined(separator: "\n")
                    issues.append(.init("drawio.table.projected", "node \(node.id): table exported as editable text rows; the structured table lives in the native archive", contentClass: "table", severity: .loss))
                case .media(let locator):
                    title = title.isEmpty ? (locator.relativePath ?? "[media \(locator.id.uuidString)]") : title
                    issues.append(.init("drawio.media.notEmbeddable", "node \(node.id): the public draw.io geometry path embeds no image bytes; the media node exports as a labeled card — bytes live in the native archive", contentClass: "media", severity: .unavailable))
                case .pdf(let assetID, _):
                    title = title.isEmpty ? "PDF \(assetID?.uuidString ?? "unresolved")" : title
                    issues.append(.init("drawio.pdf.projected", "node \(node.id): PDF exported as a labeled card; the document bytes and page range live in the native archive", contentClass: "pdf", severity: .loss))
                case .web(let url, let pageTitle):
                    title = pageTitle ?? url.absoluteString
                case .editor(let reference):
                    title = "child project \(reference.projectID.uuidString) · \(reference.editorKind) @\(reference.appliedRevision)"
                    issues.append(.init("drawio.editor.projected", "node \(node.id): child project exported as a labeled card; the archived project bytes live in the native archive", contentClass: "editor", severity: .loss))
                case .unknown:
                    title = title.isEmpty ? CanvasExchangeContent.plainText(of: node.content) : title
                }

                // Visual projection of a flow card: an ordinary editable
                // shape; never an executable definition, and the flow
                // binding ids are never written into open output.
                if CanvasExchangeFlowBindingSupport.isFlowCard(node) {
                    if title.isEmpty {
                        title = CanvasExchangeContent.plainText(of: node.content)
                    }
                    issues.append(.init("drawio.flowCard.visualOnly", "node \(node.id) is a flow card; draw.io receives the visual projection only — execution lives in the native archive", contentClass: "flowGraph", severity: .loss))
                }

                let effectiveGroupID = node.groupID ?? groupMembership[node.id]
                let explicitRegionID = node.regionID ?? regionFrames.first(where: {
                    node.frame.center.x > $0.frame.minX && node.frame.center.x < $0.frame.maxX
                        && node.frame.center.y > $0.frame.minY && node.frame.center.y < $0.frame.maxY
                })?.id
                let element = DiagramElement(
                    id: node.id,
                    kind: kind,
                    title: title,
                    // Group membership rides the container channel only:
                    // DiagramKit validates that any `parentID` is a
                    // mind-map topic parent, which a canvas group is not.
                    // The decoder still honours legacy `floeParent` files.
                    containerID: effectiveGroupID ?? explicitRegionID,
                    order: node.zIndex,
                    frame: .init(x: node.frame.minX, y: node.frame.minY, width: node.frame.size.width, height: node.frame.size.height),
                    collapsed: false,
                    isLocked: node.isLocked,
                    style: diagramStyle
                )
                elements.append(element)
            }

            for connection in page.connections {
                connections.append(DiagramConnection(
                    id: connection.id,
                    from: connection.sourceNodeID,
                    to: connection.destinationNodeID,
                    kind: .flow,
                    route: .straight,
                    sourceAnchor: mapAnchor(connection.sourcePort),
                    targetAnchor: mapAnchor(connection.destinationPort),
                    label: connection.label ?? "",
                    startArrow: connection.kind == .source || connection.kind == .generatedFrom,
                    endArrow: connection.kind != .line
                ))
            }

            pages.append(DiagramPage(
                id: page.id,
                title: page.name,
                structure: .free,
                elements: elements,
                connections: connections
            ))
        }
        // Canvas identities are page scoped. DiagramKit validates its
        // entire document as one identity domain, so repeated imports and
        // cloned pages need deterministic export-only identity remapping.
        // Keep every reference within its original page and never mutate
        // the source snapshot or relax DiagramKit's validation.
        var used = Set([snapshot.id] + pages.map(\.id))
        var reserved = used
        for page in pages {
            reserved.formUnion(page.elements.map(\.id))
            reserved.formUnion(page.connections.map(\.id))
        }
        for index in pages.indices {
            let ids = pages[index].elements.map(\.id) + pages[index].connections.map(\.id)
            guard Set(ids).count == ids.count else {
                throw CanvasExchangeError.invalid("draw.io: duplicate identity within a page")
            }
            var remapping: [UUID: UUID] = [:]
            for id in ids {
                if used.insert(id).inserted { continue }
                var salt = 0
                var mapped: UUID
                repeat {
                    mapped = CanvasExchangeIDs.stable(namespace,
                        "export/\(pages[index].id)/\(id)/\(salt)")
                    salt += 1
                } while reserved.contains(mapped)
                remapping[id] = mapped
                reserved.insert(mapped)
                used.insert(mapped)
            }
            if !remapping.isEmpty {
                for elementIndex in pages[index].elements.indices {
                    var element = pages[index].elements[elementIndex]
                    element.id = remapping[element.id] ?? element.id
                    element.parentID = element.parentID.map { remapping[$0] ?? $0 }
                    element.containerID = element.containerID.map { remapping[$0] ?? $0 }
                    element.memberIDs = element.memberIDs.map { remapping[$0] ?? $0 }
                    pages[index].elements[elementIndex] = element
                }
                for edgeIndex in pages[index].connections.indices {
                    var edge = pages[index].connections[edgeIndex]
                    edge.id = remapping[edge.id] ?? edge.id
                    edge.from = remapping[edge.from] ?? edge.from
                    edge.to = remapping[edge.to] ?? edge.to
                    pages[index].connections[edgeIndex] = edge
                }
                issues.append(.init("drawio.identities.pageScoped", "page \(pages[index].id): \(remapping.count) repeated identities were deterministically remapped for the target document", contentClass: "page", severity: .preserved))
            }
        }
        var document = DiagramDocument(id: snapshot.id, title: snapshot.name, pages: pages)
        document.metadata["exportFormat"] = "drawio"
        return (document, issues)
    }

    private static func appendLossReport(_ snapshot: CanvasSnapshot, issues: inout [CanvasExchangeIssue]) {
        for page in snapshot.pages {
            if !CanvasExchangeFlowSupport.flowGraphs(of: page).isEmpty {
                issues.append(.init("drawio.flowGraphs.notRepresentable", "page \"\(page.name)\" carries flow graphs; draw.io receives visual cards only, never execution definitions or typed edges", contentClass: "flowGraph", severity: .loss))
            }
            if !page.strokes.isEmpty {
                issues.append(.init("drawio.strokes.notRepresentable", "page \"\(page.name)\" carries \(page.strokes.count) stroke(s); draw.io has no freehand stroke model here — kept in the native archive", contentClass: "stroke", severity: .loss))
            }
            if CanvasExchangePencilSupport.drawingData(of: page) != nil {
                issues.append(.init("drawio.pencil.notRepresentable", "page \"\(page.name)\" carries PKDrawing ink; not representable in draw.io — kept in the native archive", contentClass: "pencil", severity: .loss))
            }
            if !page.scenes.isEmpty {
                issues.append(.init("drawio.scenes.notRepresentable", "page \"\(page.name)\" carries \(page.scenes.count) scene(s); draw.io has no ordered scene concept", contentClass: "scene", severity: .loss))
            }
            if page.nodes.contains(where: { $0.rotationDegrees != 0 }) {
                issues.append(.init("drawio.rotation.notRepresentable", "page \"\(page.name)\" has rotated nodes; draw.io shapes lose rotation — angles kept in the native archive", contentClass: "node", severity: .loss))
            }
        }
    }

    // MARK: Mapping helpers

    private static func mapPort(_ anchor: DiagramAnchorSide) -> CanvasConnectionPort? {
        switch anchor {
        case .left: return .leading
        case .right: return .trailing
        case .top: return .top
        case .bottom: return .bottom
        case .automatic: return nil
        }
    }

    private static func mapAnchor(_ port: CanvasConnectionPort?) -> DiagramAnchorSide {
        switch port {
        case .leading: return .left
        case .trailing: return .right
        case .top: return .top
        case .bottom: return .bottom
        case nil: return .automatic
        }
    }

    static func mapDiagramError(_ error: DiagramError) -> CanvasExchangeError {
        switch error {
        case .invalid(let message): return .invalid("draw.io: \(message)")
        case .unsupported(let message): return .unsupported("draw.io: \(message)")
        case .io(let message): return .io("draw.io: \(message)")
        case .notFound(let id): return .invalid("draw.io: entity \(id) not found")
        case .conflict(let expected, let actual):
            return .invalid("draw.io: revision conflict (expected \(expected), current \(actual))")
        case .protectedContent(let id): return .invalid("draw.io: content \(id) is protected")
        case .outsideSelection(let id): return .invalid("draw.io: \(id) is outside the selection")
        case .closed: return .invalid("draw.io: document is closed")
        case .cancelled: return .invalid("draw.io: operation cancelled")
        case .duplicateRequest: return .invalid("draw.io: duplicate request")
        case .corruptRecord: return .integrity("draw.io: corrupt record")
        }
    }
}
