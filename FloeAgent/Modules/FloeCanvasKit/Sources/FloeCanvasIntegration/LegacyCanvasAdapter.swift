import CryptoKit
import Foundation
import FloeCanvasCore

/// Result of importing legacy Floe canvas JSON bytes.
public struct LegacyImportResult: Hashable, Sendable {
    public var snapshot: CanvasSnapshot
    public var plan: LegacyMigrationPlan
    /// The complete original document tree, parsed with exact number
    /// literals. Export overlays new values onto this tree so unknown data
    /// survives read/write.
    public var originalTree: JSONValue
    /// The complete original input bytes: the compatibility authority for
    /// this import. If a field cannot be modified losslessly, hosts keep
    /// these bytes rather than trusting a re-encode.
    public var rawBytes: Data

    public init(snapshot: CanvasSnapshot, plan: LegacyMigrationPlan, originalTree: JSONValue, rawBytes: Data) {
        self.snapshot = snapshot
        self.plan = plan
        self.originalTree = originalTree
        self.rawBytes = rawBytes
    }
}

public struct LegacyMigrationPlan: Codable, Hashable, Sendable {
    /// Legacy fields that were mapped into kit DTO fields.
    public var mappedFields: [String]
    /// Host-side normalization edits the adapter recommends; each entry is
    /// data the future host adapter can translate into its own patch type.
    public var plannedPatches: [LegacyPatchPlan]
    /// Fields the kit does not model; they were preserved verbatim.
    public var preservedKeys: [String]
    public var warnings: [LegacyImportWarning]

    public init(
        mappedFields: [String] = [],
        plannedPatches: [LegacyPatchPlan] = [],
        preservedKeys: [String] = [],
        warnings: [LegacyImportWarning] = []
    ) {
        self.mappedFields = mappedFields
        self.plannedPatches = plannedPatches
        self.preservedKeys = preservedKeys
        self.warnings = warnings
    }
}

public struct LegacyPatchPlan: Codable, Hashable, Sendable {
    public enum Action: String, Codable, Hashable, Sendable {
        /// Point the project at an existing document (legacy files with a
        /// stale/absent selectedDocumentID).
        case setSelectedDocumentID
        /// Mark the persisted schema as current after migration.
        case markSchemaCurrent
        /// Unknown node kinds were imported as `.unknown`; the host may
        /// surface them for recovery instead of dropping them.
        case recordUnknownNodeKinds
    }

    public var action: Action
    public var detail: String

    public init(action: Action, detail: String) {
        self.action = action
        self.detail = detail
    }
}

public struct LegacyImportWarning: Codable, Hashable, Sendable {
    public enum Code: String, Codable, Hashable, Sendable {
        case unknownNodeKind
        case unknownTopLevelKey
        case missingDocument
        case unparsableDate
        /// A durable identity (project/document/node) was absent and had to
        /// be minted; the original bytes remain the recovery authority.
        case missingIdentity
        /// A connection references a node that cannot be located; the
        /// reference is preserved for recovery instead of dropped.
        case danglingReference
    }

    public var code: Code
    public var path: String
    public var detail: String

    public init(code: Code, path: String, detail: String) {
        self.code = code
        self.path = path
        self.detail = detail
    }
}

/// Legacy Floe canvas JSON adapter. Tolerant by design: it reads the known
/// schema (v1...7 shape) from raw bytes, keeps the complete original tree,
/// and never invents defaults it cannot back with the source bytes. It has
/// no dependency on FloeCore; a future host adapter imports both sides and
/// forwards the mapping.
public enum LegacyCanvasAdapter {
    public static let acceptedSchemaRange = 1...7

    // MARK: Import

    /// Imports legacy Floe canvas JSON bytes.
    ///
    /// Identity: the canvas ID comes from the document's own `id` field.
    /// When that field is missing/corrupt, the host-supplied trusted
    /// `fallbackCanvasID` is used (mirroring `CanvasProjectCodec`'s
    /// fallback-ID behavior for schema-v1 files whose ID came from their
    /// filename). When neither exists, import fails loudly instead of
    /// minting an identity and pretending it is the original.
    public static func `import`(
        _ bytes: Data,
        fallbackCanvasID: UUID? = nil
    ) throws -> LegacyImportResult {
        let tree: JSONValue
        do {
            tree = try JSONFidelity.parse(bytes)
        } catch {
            throw CanvasKitError.io("legacy canvas bytes are not valid JSON: \(error)")
        }
        guard let root = tree.objectValue else {
            throw CanvasKitError.io("legacy canvas root is not a JSON object")
        }
        let schema = root["schemaVersion"]?.intValue ?? 1
        guard acceptedSchemaRange.contains(schema) else {
            throw CanvasKitError.unsupportedLegacySchema(schema)
        }

        var plan = LegacyMigrationPlan()
        guard let canvasID = root["id"]?.uuidValue ?? fallbackCanvasID else {
            throw CanvasKitError.missingEntity(
                "canvas identity missing and no fallbackCanvasID supplied")
        }
        if root["id"]?.uuidValue == nil {
            plan.warnings.append(.init(
                code: .missingIdentity, path: "id",
                detail: "project id missing; using supplied fallbackCanvasID"))
        }
        let name = root["name"]?.stringValue ?? "Canvas"
        let projectRevision = root["revision"]?.int64Value ?? 0

        let documentTrees = root["documents"]?.arrayValue ?? []
        if documentTrees.isEmpty {
            plan.warnings.append(.init(
                code: .missingDocument, path: "documents",
                detail: "legacy package has no documents"))
        }
        var pages: [CanvasPageSnapshot] = []
        var unknownKinds = Set<String>()
        for (documentIndex, documentTree) in documentTrees.enumerated() {
            let document = documentTree.objectValue ?? [:]
            let pageID = document["id"]?.uuidValue ?? derivedID(
                path: "documents[\(documentIndex)]",
                subtree: documentTree, namespace: canvasID)
            if document["id"]?.uuidValue == nil {
                plan.warnings.append(.init(
                    code: .missingIdentity,
                    path: "documents[\(documentIndex)].id",
                    detail: "document id missing; derived deterministically "
                        + "as \(pageID.uuidString) — supply explicit document "
                        + "IDs for durable identity across edits; the original "
                        + "bytes remain the recovery authority"))
            }
            var page = CanvasPageSnapshot(
                id: pageID,
                name: document["name"]?.stringValue ?? "Page \(documentIndex + 1)",
                background: CanvasBackgroundStyle(
                    rawValue: document["backgroundStyle"]?.stringValue ?? ""
                ) ?? .grid)
            if let pencilLiteral = document["pencilDrawingData"]?.stringValue,
               let pencil = Data(base64Encoded: pencilLiteral) {
                page.pencilDrawingData = pencil
            }
            plan.mappedFields.append("documents[\(documentIndex)]")

            for (nodeIndex, nodeTree) in (document["nodes"]?.arrayValue ?? []).enumerated() {
                let node = nodeTree.objectValue ?? [:]
                let path = "documents[\(documentIndex)].nodes[\(nodeIndex)]"
                let rawKind = node["kind"]?.stringValue ?? "text"
                let mapped = mapNodeKind(rawKind)
                if mapped == .unknown { unknownKinds.insert(rawKind) }

                let position: CanvasGeometry.Point
                let size: CanvasGeometry.Size
                if let point = node["position"]?.pointValue {
                    position = point
                    size = node["size"]?.sizeValue ?? CanvasGeometry.Size(width: 260, height: 150)
                } else {
                    // Legacy files may store flat x/y/width/height instead
                    // of the nested position/size objects the current codec
                    // emits; the decoder accepts both spellings.
                    position = CanvasGeometry.Point(
                        x: node["x"]?.doubleValue ?? 0,
                        y: node["y"]?.doubleValue ?? 0)
                    size = CanvasGeometry.Size(
                        width: node["width"]?.doubleValue ?? 260,
                        height: node["height"]?.doubleValue ?? 150)
                }

                var metadata: [String: String] = [:]
                if let meta = node["metadata"]?.objectValue {
                    for (key, value) in meta {
                        // Only string values enter the DTO map. Non-string
                        // values (numbers, objects) stay in the original
                        // tree and survive write-back untouched — importing
                        // them as empty strings would overwrite the real
                        // payloads on export.
                        if let string = value.stringValue {
                            metadata[key] = string
                        }
                    }
                }
                if let shape = node["shape"]?.stringValue {
                    metadata["legacy.shape"] = shape
                }
                metadata["legacy.kind"] = rawKind
                if let license = node["licenseStatus"]?.stringValue {
                    metadata["licenseStatus"] = license
                }
                let sourceURLs = (node["sourceURLs"]?.arrayValue ?? [])
                    .compactMap(\.urlValue)
                if !sourceURLs.isEmpty {
                    metadata["legacy.sourceURLs"] = sourceURLs
                        .map(\.absoluteString).joined(separator: " ")
                }

                var content: CanvasContent
                switch mapped {
                case .content, .sourced:
                    content = .text(node["text"]?.stringValue ?? "")
                case .generationTask:
                    content = .text(node["text"]?.stringValue ?? "")
                case .scene3D:
                    content = .unknown(
                        kind: "scene3D",
                        payload: node["scene3D"] ?? .null)
                case .legacyGroup:
                    content = .text(node["text"]?.stringValue ?? "")
                case .unknown:
                    content = .unknown(kind: rawKind, payload: nodeTree)
                }
                if mapped == .sourced, let sourceURL = sourceURLs.first {
                    content = .web(sourceURL, title: node["title"]?.stringValue)
                }
                if mapped == .content,
                   let asset = mapAsset(node["asset"], namespace: canvasID) {
                    switch rawKind {
                    case "image", "video", "audio", "file":
                        content = .media(asset)
                    default:
                        break
                    }
                }

                let nodeID = node["id"]?.uuidValue ?? derivedID(
                    path: "\(path).id", subtree: nodeTree, namespace: canvasID)
                if node["id"]?.uuidValue == nil {
                    plan.warnings.append(.init(
                        code: .missingIdentity,
                        path: "\(path).id",
                        detail: "node id missing; derived deterministically "
                            + "as \(nodeID.uuidString) from content — reopening "
                            + "the same bytes yields the same ID; supply "
                            + "explicit node IDs for durable identity"))
                }
                page.nodes.append(CanvasNodeSnapshot(
                    id: nodeID,
                    kind: mapped,
                    title: node["title"]?.stringValue,
                    content: content,
                    frame: CanvasGeometry.Frame(center: position, size: size),
                    rotationDegrees: node["rotation"]?.doubleValue ?? 0,
                    zIndex: node["zIndex"]?.intValue ?? 0,
                    isLocked: node["isLocked"]?.boolValue ?? false,
                    groupID: node["groupID"]?.uuidValue,
                    createdByRunID: node["createdByRunID"]?.uuidValue,
                    metadata: metadata
                ))
                plan.mappedFields.append("\(path).id")
            }

            for (connectionIndex, connectionTree) in (document["connections"]?.arrayValue ?? []).enumerated() {
                let connection = connectionTree.objectValue ?? [:]
                let sourceNodeID = connection["sourceNodeID"]?.uuidValue
                let destinationNodeID = connection["destinationNodeID"]?.uuidValue
                let nodeIDs = Set(page.nodes.map(\.id))
                if sourceNodeID == nil || destinationNodeID == nil
                    || !nodeIDs.contains(sourceNodeID!)
                    || !nodeIDs.contains(destinationNodeID!) {
                    plan.warnings.append(.init(
                        code: .danglingReference,
                        path: "documents[\(documentIndex)].connections[\(connectionIndex)]",
                        detail: "connection endpoint cannot be located; reference preserved"))
                }
                page.connections.append(CanvasConnectionSnapshot(
                    id: connection["id"]?.uuidValue ?? derivedID(
                        path: "documents[\(documentIndex)].connections[\(connectionIndex)].id",
                        subtree: connectionTree, namespace: canvasID),
                    sourceNodeID: sourceNodeID ?? derivedID(
                        path: "documents[\(documentIndex)].connections[\(connectionIndex)].source",
                        subtree: connectionTree, namespace: canvasID),
                    destinationNodeID: destinationNodeID ?? derivedID(
                        path: "documents[\(documentIndex)].connections[\(connectionIndex)].destination",
                        subtree: connectionTree, namespace: canvasID),
                    kind: CanvasRelationKind(
                        rawValue: connection["kind"]?.stringValue ?? "arrow"
                    ) ?? .arrow,
                    label: connection["label"]?.stringValue,
                    sourcePort: CanvasConnectionPort(
                        rawValue: connection["sourcePort"]?.stringValue ?? ""),
                    destinationPort: CanvasConnectionPort(
                        rawValue: connection["destinationPort"]?.stringValue ?? "")
                ))
            }

            for (strokeIndex, strokeTree) in (document["strokes"]?.arrayValue ?? []).enumerated() {
                let stroke = strokeTree.objectValue ?? [:]
                page.strokes.append(CanvasStrokeSnapshot(
                    id: stroke["id"]?.uuidValue ?? derivedID(
                        path: "documents[\(documentIndex)].strokes[\(strokeIndex)].id",
                        subtree: strokeTree, namespace: canvasID),
                    points: (stroke["points"]?.arrayValue ?? [])
                        .compactMap(\.pointValue),
                    width: stroke["width"]?.doubleValue ?? 3,
                    color: stroke["color"]?.stringValue ?? "primary",
                    isEraser: stroke["isEraser"]?.boolValue ?? false
                ))
            }
            pages.append(page)
        }

        var viewports: [UUID: CanvasViewport] = [:]
        if let viewportTree = root["viewports"]?.objectValue {
            for (key, value) in viewportTree {
                guard let pageID = UUID(uuidString: key),
                      let center = value["center"]?.pointValue else { continue }
                viewports[pageID] = CanvasViewport(
                    center: center,
                    scale: value["scale"]?.doubleValue ?? 1)
            }
        }

        let selectedPageID = root["selectedDocumentID"]?.uuidValue
            ?? pages.first?.id
            ?? UUID()
        if selectedPageID != root["selectedDocumentID"]?.uuidValue {
            plan.plannedPatches.append(.init(
                action: .setSelectedDocumentID,
                detail: "selectedDocumentID missing or stale; point at \(selectedPageID.uuidString)"))
        }
        plan.plannedPatches.append(.init(
            action: .markSchemaCurrent,
            detail: "schemaVersion \(schema) → \(CanvasSnapshot.currentSchemaVersion)"))
        if !unknownKinds.isEmpty {
            plan.plannedPatches.append(.init(
                action: .recordUnknownNodeKinds,
                detail: unknownKinds.sorted().joined(separator: ",")))
            for kind in unknownKinds.sorted() {
                plan.warnings.append(.init(
                    code: .unknownNodeKind, path: "nodes",
                    detail: "kind '\(kind)' imported as .unknown"))
            }
        }

        let knownTopLevel: Set<String> = [
            "id", "schemaVersion", "workspaceID", "name", "documents",
            "selectedDocumentID", "agentConversationID", "assistantSessions",
            "selectedAssistantSessionID", "agentConversationIDsByDocument",
            "viewports", "revision", "sync", "designProjectAuthority",
            "createdAt", "updatedAt"
        ]
        plan.preservedKeys = root.keys.filter { !knownTopLevel.contains($0) }.sorted()
        for key in plan.preservedKeys {
            plan.warnings.append(.init(
                code: .unknownTopLevelKey, path: key,
                detail: "preserved verbatim"))
        }

        let snapshot = CanvasSnapshot(
            id: canvasID,
            schemaVersion: CanvasSnapshot.currentSchemaVersion,
            name: name,
            pages: pages,
            selectedPageID: selectedPageID,
            viewports: viewports,
            revision: projectRevision,
            createdAt: root["createdAt"]?.dateValue ?? Date(),
            updatedAt: root["updatedAt"]?.dateValue ?? Date()
        )
        return LegacyImportResult(
            snapshot: snapshot, plan: plan, originalTree: tree, rawBytes: bytes)
    }

    // MARK: Export (write-back preserving unknown fields)

    /// Result of a legacy write-back: the serialized bytes plus an explicit
    /// list of what the legacy schema cannot express. The original import
    /// bytes stay the compatibility authority for everything in `losses`.
    public struct LegacyExportReport: Hashable, Sendable {
        public var data: Data
        public var losses: [String]

        public init(data: Data, losses: [String]) {
            self.data = data
            self.losses = losses
        }
    }

    /// Serializes the snapshot as legacy-compatible JSON by overlaying the
    /// kit values onto the original tree BY STABLE ID: unknown keys,
    /// unmapped subtrees, unknown connection/stroke fields, non-string
    /// metadata values and original text survive every read/write round
    /// trip. Capabilities the legacy schema cannot express are reported in
    /// `LegacyExportReport.losses` — this never claims a complete legacy
    /// write-back.
    public static func exportPreservingLegacy(_ result: LegacyImportResult) throws -> Data {
        try exportPreservingLegacyWithReport(result).data
    }

    public static func exportPreservingLegacyWithReport(
        _ result: LegacyImportResult
    ) throws -> LegacyExportReport {
        var losses: [String] = []
        var root = result.originalTree.objectValue ?? [:]
        let snapshot = result.snapshot
        root["id"] = .string(snapshot.id.uuidString)
        root["schemaVersion"] = .number("\(CanvasSnapshot.currentSchemaVersion)")
        root["name"] = .string(snapshot.name)
        root["revision"] = .number("\(snapshot.revision)")
        root["selectedDocumentID"] = .string(snapshot.selectedPageID.uuidString)

        let originalDocuments = result.originalTree["documents"]?.arrayValue ?? []
        var documents: [JSONValue] = []
        for page in snapshot.pages {
            let originalDocument = originalDocuments
                .first(where: { $0["id"]?.uuidValue == page.id })?
                .objectValue ?? [:]
            var document = originalDocument
            document["id"] = .string(page.id.uuidString)
            document["name"] = .string(page.name)
            document["backgroundStyle"] = .string(page.background.rawValue)
            if let pencil = page.pencilDrawingData {
                document["pencilDrawingData"] =
                    .string(pencil.base64EncodedString())
            } else {
                document["pencilDrawingData"] = nil
            }
            if !page.groups.isEmpty || !page.regions.isEmpty
                || !page.scenes.isEmpty || !page.flowGraphs.isEmpty {
                losses.append(
                    "page \(page.id.uuidString): groups/regions/scenes/flow "
                        + "graphs are not representable in the legacy schema")
            }

            let originalNodes = originalDocument["nodes"]?.arrayValue ?? []
            var nodes: [JSONValue] = []
            for node in page.nodes {
                let originalNode = originalNodes
                    .first(where: { $0["id"]?.uuidValue == node.id })?
                    .objectValue
                var legacyNode = originalNode ?? [:]
                legacyNode["id"] = .string(node.id.uuidString)
                legacyNode["kind"] = .string(
                    node.metadata["legacy.kind"] ?? legacyKind(for: node))
                if let title = node.title {
                    legacyNode["title"] = .string(title)
                } else {
                    legacyNode["title"] = nil
                }
                // Text is only written back for text-bearing content;
                // structured content keeps its original fields verbatim.
                switch node.content {
                case .text, .markdown, .code, .formula:
                    legacyNode["text"] = .string(node.textContent)
                case .richText(let document):
                    legacyNode["text"] = .string(document.plainText)
                    losses.append(
                        "node \(node.id.uuidString): rich-text runs/styles are "
                            + "not representable in the legacy schema; plain "
                            + "text was written")
                case .shape(_, let text):
                    legacyNode["text"] = .string(text)
                    losses.append(
                        "node \(node.id.uuidString): shape kind and geometry "
                            + "styling are not representable in the legacy "
                            + "schema; text and original fields were kept")
                case .table, .media, .pdf, .web, .editor:
                    losses.append(
                        "node \(node.id.uuidString): content kind "
                            + "\(legacyKind(for: node)) is not representable in "
                            + "the legacy schema; original fields were preserved")
                case .unknown(_, let payload):
                    let originalPayload: JSONValue? = node.kind == .scene3D
                        ? originalNode?["scene3D"]
                        : originalNode.map { .object($0) }
                    if let originalPayload, originalPayload != payload {
                        losses.append(
                            "node \(node.id.uuidString): edited "
                                + "\(node.content.unknownKind ?? "unknown") "
                                + "payload is not representable in the legacy "
                                + "schema; the original payload was preserved")
                    }
                }
                legacyNode["position"] = .object([
                    "x": .number("\(node.frame.center.x)"),
                    "y": .number("\(node.frame.center.y)")
                ])
                legacyNode["size"] = .object([
                    "width": .number("\(node.frame.size.width)"),
                    "height": .number("\(node.frame.size.height)")
                ])
                legacyNode["rotation"] = .number("\(node.rotationDegrees)")
                legacyNode["zIndex"] = .number("\(node.zIndex)")
                legacyNode["isLocked"] = .bool(node.isLocked)
                // Clearing a group must also remove the original key.
                if let groupID = node.groupID {
                    legacyNode["groupID"] = .string(groupID.uuidString)
                } else {
                    legacyNode["groupID"] = nil
                }
                // Metadata: start from the ORIGINAL values (numbers, objects
                // and unknown payloads survive untouched) and overlay only
                // the string values this snapshot actually carries.
                var metadata = originalNode?["metadata"]?.objectValue ?? [:]
                for (key, value) in node.metadata where !key.hasPrefix("legacy.") {
                    metadata[key] = .string(value)
                }
                if metadata.isEmpty {
                    legacyNode["metadata"] = nil
                } else {
                    legacyNode["metadata"] = .object(metadata)
                }
                nodes.append(.object(legacyNode))
            }
            document["nodes"] = .array(nodes)

            // Connections overlay by stable ID: label, ports and unknown
            // connection fields survive; connections the snapshot no longer
            // has are dropped (same semantics as nodes).
            let originalConnections = originalDocument["connections"]?
                .arrayValue ?? []
            var connections: [JSONValue] = []
            for connection in page.connections {
                var legacyConnection = originalConnections
                    .first(where: { $0["id"]?.uuidValue == connection.id })?
                    .objectValue ?? [:]
                legacyConnection["id"] = .string(connection.id.uuidString)
                legacyConnection["sourceNodeID"] =
                    .string(connection.sourceNodeID.uuidString)
                legacyConnection["destinationNodeID"] =
                    .string(connection.destinationNodeID.uuidString)
                legacyConnection["kind"] = .string(connection.kind.rawValue)
                if let label = connection.label {
                    legacyConnection["label"] = .string(label)
                } else {
                    legacyConnection["label"] = nil
                }
                if let port = connection.sourcePort {
                    legacyConnection["sourcePort"] = .string(port.rawValue)
                } else {
                    legacyConnection["sourcePort"] = nil
                }
                if let port = connection.destinationPort {
                    legacyConnection["destinationPort"] = .string(port.rawValue)
                } else {
                    legacyConnection["destinationPort"] = nil
                }
                connections.append(.object(legacyConnection))
            }
            document["connections"] = .array(connections)

            // Strokes overlay by stable ID: edits land, unknown stroke
            // fields survive, removed strokes disappear.
            let originalStrokes = originalDocument["strokes"]?.arrayValue ?? []
            var strokes: [JSONValue] = []
            for stroke in page.strokes {
                var legacyStroke = originalStrokes
                    .first(where: { $0["id"]?.uuidValue == stroke.id })?
                    .objectValue ?? [:]
                legacyStroke["id"] = .string(stroke.id.uuidString)
                legacyStroke["points"] = .array(stroke.points.map {
                    .object([
                        "x": .number("\($0.x)"),
                        "y": .number("\($0.y)")
                    ])
                })
                legacyStroke["width"] = .number("\(stroke.width)")
                legacyStroke["color"] = .string(stroke.color)
                legacyStroke["isEraser"] = .bool(stroke.isEraser)
                strokes.append(.object(legacyStroke))
            }
            document["strokes"] = .array(strokes)
            documents.append(.object(document))
        }
        root["documents"] = .array(documents)

        // High-fidelity serializer: unknown values keep their exact numeric
        // literals; only key order/whitespace may normalize.
        let data = try JSONFidelity.serialize(
            .object(root),
            options: .init(sortedKeys: true, prettyPrinted: true))
        return LegacyExportReport(data: data, losses: losses)
    }

    // MARK: Mapping helpers

    private static func mapNodeKind(_ raw: String) -> CanvasNodeKind {
        switch raw {
        case "text", "stickyNote", "card", "shape": return .content
        case "image", "video", "audio", "file": return .content
        case "group": return .legacyGroup
        case "generationTask": return .generationTask
        case "scene3D": return .scene3D
        default: return .unknown
        }
    }

    private static func legacyKind(for node: CanvasNodeSnapshot) -> String {
        if let unknown = node.content.unknownKind { return unknown }
        switch node.kind {
        case .content: return "text"
        case .generationTask: return "generationTask"
        case .scene3D: return "scene3D"
        case .legacyGroup: return "group"
        case .sourced: return "text"
        case .unknown: return "text"
        }
    }

    /// Deterministic identity for a legacy entity whose ID is missing:
    /// derived from the stable import path, the canvas namespace and the
    /// EXACT subtree bytes, so reopening the same bytes yields the same
    /// identity. The original bytes remain the recovery authority; hosts
    /// that need durable identity across edits must supply explicit IDs.
    static func derivedID(
        path: String, subtree: JSONValue, namespace: UUID
    ) -> UUID {
        var bytes = Array(path.utf8)
        bytes.append(contentsOf: namespace.uuidString.utf8)
        if let serialized = try? JSONFidelity.serialize(.object(["s": subtree])) {
            bytes.append(contentsOf: serialized)
        }
        let digest = SHA256.hash(data: Data(bytes))
        let uuidBytes = Array(digest.prefix(16))
        return UUID(uuid: (
            uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3],
            uuidBytes[4], uuidBytes[5], uuidBytes[6], uuidBytes[7],
            uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11],
            uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]))
    }

    private static func mapAsset(
        _ value: JSONValue?, namespace: UUID
    ) -> CanvasAssetLocator? {
        guard let asset = value?.objectValue else { return nil }
        return CanvasAssetLocator(
            id: asset["id"]?.uuidValue ?? derivedID(
                path: "asset.id", subtree: value ?? .null, namespace: namespace),
            contentHash: asset["contentHash"]?.stringValue,
            relativePath: asset["localRelativePath"]?.stringValue,
            mimeType: asset["mimeType"]?.stringValue,
            byteCount: asset["byteCount"]?.int64Value,
            sourceURL: asset["sourceURL"]?.urlValue,
            license: asset["license"]?.stringValue
        )
    }
}

// MARK: - JSONValue convenience extraction

extension JSONValue {
    var uuidValue: UUID? {
        stringValue.flatMap(UUID.init(uuidString:))
    }

    var doubleValue: Double? {
        numberLiteral.flatMap(Double.init)
    }

    var intValue: Int? {
        int64Value.flatMap(Int.init)
    }

    /// Exact integer only: a decimal literal like "12.0" is not treated as
    /// an integer, so values are never re-typed on the way in.
    var int64Value: Int64? {
        guard let literal = numberLiteral, !literal.contains(".") else { return nil }
        guard !literal.contains("e"), !literal.contains("E") else { return nil }
        return Int64(literal)
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var urlValue: URL? {
        stringValue.flatMap(URL.init(string:))
    }

    var pointValue: CanvasGeometry.Point? {
        guard let x = self["x"]?.doubleValue,
              let y = self["y"]?.doubleValue else { return nil }
        return CanvasGeometry.Point(x: x, y: y)
    }

    var sizeValue: CanvasGeometry.Size? {
        guard let width = self["width"]?.doubleValue,
              let height = self["height"]?.doubleValue else { return nil }
        return CanvasGeometry.Size(width: width, height: height)
    }

    /// Legacy timestamps follow `CanvasProjectCodec`'s real wire semantics:
    /// JSONEncoder's default date encoding — seconds since the 2001
    /// reference date (NOT 1970; a 1970 reading shifts every date by ~31
    /// years). ISO-8601 strings are accepted for foreign documents.
    var dateValue: Date? {
        guard let literal = numberLiteral else {
            return stringValue.flatMap { ISO8601DateFormatter().date(from: $0) }
        }
        if let integer = Int64(literal) {
            return Date(timeIntervalSinceReferenceDate: TimeInterval(integer))
        }
        return Double(literal).map { Date(timeIntervalSinceReferenceDate: $0) }
    }
}

extension CanvasNodeSnapshot {
    /// Plain-text projection used for legacy `text` write-back and tests.
    var textContent: String {
        get {
            switch content {
            case .text(let text): return text
            case .markdown(let document, _): return document
            case .code(_, let source): return source
            case .formula(let source, _): return source
            case .web(_, let title): return title ?? ""
            default: return ""
            }
        }
        set {
            content = .text(newValue)
        }
    }
}
