import Foundation

/// Snapshot DTOs are the portable, Codable/Sendable interchange form of a
/// canvas project. They are NOT the production store: hosts persist their own
/// authoritative models and translate at the boundary. Identity is always a
/// stable UUID; ordering and revision authority is always an Int64 revision.

/// A group moves/locks its members together. Distinct from a region: a group
/// has no collapsed presentation of its own.
public struct CanvasGroupRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var memberNodeIDs: [UUID]

    public init(id: UUID = UUID(), name: String, memberNodeIDs: [UUID] = []) {
        self.id = id
        self.name = name
        self.memberNodeIDs = memberNodeIDs
    }
}

/// A collapsible region: owns a rect of canvas space, can be folded to a
/// chip, and contains nodes by containment (not by membership list alone).
public struct CanvasRegionRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var frame: CanvasGeometry.Frame
    public var isCollapsed: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        frame: CanvasGeometry.Frame,
        isCollapsed: Bool = false
    ) {
        self.id = id
        self.name = name
        self.frame = frame
        self.isCollapsed = isCollapsed
    }
}

/// A named viewport scene: camera pose plus the region/node set it focuses,
/// so a canvas can be presented in an ordered sequence.
public struct CanvasSceneRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var viewportCenter: CanvasGeometry.Point
    public var viewportScale: Double
    public var focusedNodeIDs: [UUID]
    public var focusedRegionIDs: [UUID]
    /// Ordered presentation position among sibling scenes.
    public var order: Int

    public init(
        id: UUID = UUID(),
        name: String,
        viewportCenter: CanvasGeometry.Point = .zero,
        viewportScale: Double = 1,
        focusedNodeIDs: [UUID] = [],
        focusedRegionIDs: [UUID] = [],
        order: Int = 0
    ) {
        self.id = id
        self.name = name
        self.viewportCenter = viewportCenter
        self.viewportScale = viewportScale
        self.focusedNodeIDs = focusedNodeIDs
        self.focusedRegionIDs = focusedRegionIDs
        self.order = order
    }
}

public enum CanvasNodeKind: String, Codable, Hashable, Sendable, CaseIterable {
    /// Ordinary editable node (text/markdown/code/… via `content`).
    case content
    /// A generation task placeholder with explicit configuration.
    case generationTask
    /// 3D/CAD preview node backed by an editor reference.
    case scene3D
    /// Group container visual (legacy `group` kind); modern grouping is
    /// expressed via `CanvasGroupRecord` and this kind is retained for
    /// legacy mapping only.
    case legacyGroup
    /// Content from a source reference (imported note/PDF/web fragment).
    case sourced
    /// Unrecognized legacy node kind, preserved verbatim.
    case unknown
}

/// A node in the snapshot. Geometry is center-anchored like the legacy
/// canvas so adapters translate without sign flips.
public struct CanvasNodeSnapshot: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var kind: CanvasNodeKind
    public var title: String?
    public var content: CanvasContent
    public var frame: CanvasGeometry.Frame
    public var rotationDegrees: Double
    public var zIndex: Int
    public var isLocked: Bool
    public var groupID: UUID?
    /// Region containment is derived by geometry at edit time; this cache
    /// records the last computed containment for persistence.
    public var regionID: UUID?
    public var source: CanvasSourceReference?
    /// Run that produced this node, if any. Cleared by copy/fork.
    public var createdByRunID: UUID?
    /// Free-form metadata retained verbatim.
    public var metadata: [String: String]

    public init(
        id: UUID = UUID(),
        kind: CanvasNodeKind = .content,
        title: String? = nil,
        content: CanvasContent,
        frame: CanvasGeometry.Frame,
        rotationDegrees: Double = 0,
        zIndex: Int = 0,
        isLocked: Bool = false,
        groupID: UUID? = nil,
        regionID: UUID? = nil,
        source: CanvasSourceReference? = nil,
        createdByRunID: UUID? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.content = content
        self.frame = frame
        self.rotationDegrees = rotationDegrees
        self.zIndex = zIndex
        self.isLocked = isLocked
        self.groupID = groupID
        self.regionID = regionID
        self.source = source
        self.createdByRunID = createdByRunID
        self.metadata = metadata
    }
}

/// Ordinary canvas relations: how nodes relate visually/semantically.
/// These never carry execution data. Flow data edges are separate
/// (`FlowEdge`, Flow module) and only a typed flow connection executes.
public enum CanvasRelationKind: String, Codable, Hashable, Sendable {
    case line, arrow, source, generatedFrom
}

public struct CanvasConnectionSnapshot: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var sourceNodeID: UUID
    public var destinationNodeID: UUID
    public var kind: CanvasRelationKind
    public var label: String?
    public var sourcePort: CanvasConnectionPort?
    public var destinationPort: CanvasConnectionPort?

    public init(
        id: UUID = UUID(),
        sourceNodeID: UUID,
        destinationNodeID: UUID,
        kind: CanvasRelationKind = .arrow,
        label: String? = nil,
        sourcePort: CanvasConnectionPort? = nil,
        destinationPort: CanvasConnectionPort? = nil
    ) {
        self.id = id
        self.sourceNodeID = sourceNodeID
        self.destinationNodeID = destinationNodeID
        self.kind = kind
        self.label = label
        self.sourcePort = sourcePort
        self.destinationPort = destinationPort
    }
}

public enum CanvasConnectionPort: String, Codable, Hashable, Sendable, CaseIterable {
    case top, trailing, bottom, leading
}

/// Freehand stroke points (PencilKit data, when present, is an opaque asset
/// referenced through `metadata["pencilKitDataID"]`).
public struct CanvasStrokeSnapshot: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var points: [CanvasGeometry.Point]
    public var width: Double
    public var color: String
    public var isEraser: Bool

    public init(
        id: UUID = UUID(),
        points: [CanvasGeometry.Point],
        width: Double = 3,
        color: String = "primary",
        isEraser: Bool = false
    ) {
        self.id = id
        self.points = points
        self.width = width
        self.color = color
        self.isEraser = isEraser
    }
}

public enum CanvasBackgroundStyle: String, Codable, Hashable, Sendable {
    case blank, grid, dots
}

/// One page of a canvas. Pages have independent content identity.
public struct CanvasPageSnapshot: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var nodes: [CanvasNodeSnapshot]
    public var connections: [CanvasConnectionSnapshot]
    public var strokes: [CanvasStrokeSnapshot]
    public var groups: [CanvasGroupRecord]
    public var regions: [CanvasRegionRecord]
    public var scenes: [CanvasSceneRecord]
    public var background: CanvasBackgroundStyle
    /// Flow definitions attached to this page (P0.1, additive). Missing
    /// field decodes as `[]` so every P0 snapshot stays readable; flow
    /// visuals share the canvas world coordinates (`FlowNode.position`).
    /// Execution records/checkpoints NEVER live here — they belong to the
    /// runtime, not to editable/undoable document state.
    public var flowGraphs: [FlowGraph]
    /// Lossless PencilKit drawing bytes for the whole page (ICQA08):
    /// original strokes, pressure and styles. Absent field decodes as nil.
    /// This is the durable original; the discrete `strokes` array is only a
    /// derived view. Bounded by `maxPencilDrawingByteCount`.
    public var pencilDrawingData: Data?

    /// Hard cap for `pencilDrawingData`: original strokes must stay
    /// lossless, but a document commit must never accept an unbounded blob.
    public static let maxPencilDrawingByteCount = 32 * 1024 * 1024

    public init(
        id: UUID = UUID(),
        name: String = "Page 1",
        nodes: [CanvasNodeSnapshot] = [],
        connections: [CanvasConnectionSnapshot] = [],
        strokes: [CanvasStrokeSnapshot] = [],
        groups: [CanvasGroupRecord] = [],
        regions: [CanvasRegionRecord] = [],
        scenes: [CanvasSceneRecord] = [],
        background: CanvasBackgroundStyle = .grid,
        flowGraphs: [FlowGraph] = [],
        pencilDrawingData: Data? = nil
    ) {
        self.id = id
        self.name = name
        self.nodes = nodes
        self.connections = connections
        self.strokes = strokes
        self.groups = groups
        self.regions = regions
        self.scenes = scenes
        self.background = background
        self.flowGraphs = flowGraphs
        self.pencilDrawingData = pencilDrawingData
    }
}

extension CanvasPageSnapshot: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, nodes, connections, strokes, groups, regions, scenes
        case background, flowGraphs, pencilDrawingData
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(UUID.self, forKey: .id),
            name: try values.decodeIfPresent(String.self, forKey: .name) ?? "Page 1",
            nodes: try values.decodeIfPresent([CanvasNodeSnapshot].self, forKey: .nodes) ?? [],
            connections: try values.decodeIfPresent(
                [CanvasConnectionSnapshot].self, forKey: .connections) ?? [],
            strokes: try values.decodeIfPresent(
                [CanvasStrokeSnapshot].self, forKey: .strokes) ?? [],
            groups: try values.decodeIfPresent(
                [CanvasGroupRecord].self, forKey: .groups) ?? [],
            regions: try values.decodeIfPresent(
                [CanvasRegionRecord].self, forKey: .regions) ?? [],
            scenes: try values.decodeIfPresent(
                [CanvasSceneRecord].self, forKey: .scenes) ?? [],
            background: try values.decodeIfPresent(
                CanvasBackgroundStyle.self, forKey: .background) ?? .grid,
            flowGraphs: try values.decodeIfPresent(
                [FlowGraph].self, forKey: .flowGraphs) ?? [],
            pencilDrawingData: try values.decodeIfPresent(
                Data.self, forKey: .pencilDrawingData))
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(nodes, forKey: .nodes)
        try values.encode(connections, forKey: .connections)
        try values.encode(strokes, forKey: .strokes)
        try values.encode(groups, forKey: .groups)
        try values.encode(regions, forKey: .regions)
        try values.encode(scenes, forKey: .scenes)
        try values.encode(background, forKey: .background)
        try values.encode(flowGraphs, forKey: .flowGraphs)
        try values.encodeIfPresent(pencilDrawingData, forKey: .pencilDrawingData)
    }
}

/// Whole-canvas snapshot: multi-page, per-page viewport memories, revision.
public struct CanvasSnapshot: Codable, Hashable, Sendable, Identifiable {
    public static let currentSchemaVersion = 1

    public var id: UUID
    public var schemaVersion: Int
    public var name: String
    public var pages: [CanvasPageSnapshot]
    public var selectedPageID: UUID
    /// Per-page last-viewed viewport, keyed by page ID.
    public var viewports: [UUID: CanvasViewport]
    public var revision: Int64
    public var createdAt: Date
    public var updatedAt: Date
    /// Additive host-owned document metadata. Template instances and scoped
    /// creation context share the document's existing CAS/undo authority.
    public var metadata: [String: String]

    public init(
        id: UUID = UUID(),
        schemaVersion: Int = CanvasSnapshot.currentSchemaVersion,
        name: String,
        pages: [CanvasPageSnapshot],
        selectedPageID: UUID? = nil,
        viewports: [UUID: CanvasViewport] = [:],
        revision: Int64 = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.name = name
        self.pages = pages
        self.selectedPageID = selectedPageID ?? pages.first?.id ?? UUID()
        self.viewports = viewports
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.metadata = metadata
    }

    public var selectedPage: CanvasPageSnapshot? {
        pages.first(where: { $0.id == selectedPageID })
    }
}

extension CanvasSnapshot {
    private enum CodingKeys: String, CodingKey {
        case id, schemaVersion, name, pages, selectedPageID, viewports, revision
        case createdAt, updatedAt, metadata
    }
    public init(from decoder: any Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try v.decode(UUID.self, forKey: .id),
            schemaVersion: try v.decode(Int.self, forKey: .schemaVersion),
            name: try v.decode(String.self, forKey: .name),
            pages: try v.decode([CanvasPageSnapshot].self, forKey: .pages),
            selectedPageID: try v.decode(UUID.self, forKey: .selectedPageID),
            viewports: try v.decode([UUID: CanvasViewport].self, forKey: .viewports),
            revision: try v.decode(Int64.self, forKey: .revision),
            createdAt: try v.decode(Date.self, forKey: .createdAt),
            updatedAt: try v.decode(Date.self, forKey: .updatedAt),
            metadata: try v.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:])
    }
    public func encode(to encoder: any Encoder) throws {
        var v = encoder.container(keyedBy: CodingKeys.self)
        try v.encode(id, forKey: .id); try v.encode(schemaVersion, forKey: .schemaVersion)
        try v.encode(name, forKey: .name); try v.encode(pages, forKey: .pages)
        try v.encode(selectedPageID, forKey: .selectedPageID); try v.encode(viewports, forKey: .viewports)
        try v.encode(revision, forKey: .revision); try v.encode(createdAt, forKey: .createdAt)
        try v.encode(updatedAt, forKey: .updatedAt); try v.encode(metadata, forKey: .metadata)
    }
}

public struct CanvasViewport: Codable, Hashable, Sendable {
    public var center: CanvasGeometry.Point
    public var scale: Double

    public init(center: CanvasGeometry.Point = .zero, scale: Double = 1) {
        self.center = center
        self.scale = min(3, max(0.3, scale))
    }
}
