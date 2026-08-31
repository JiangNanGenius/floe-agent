import Foundation

public struct CanvasPoint: Sendable, Codable, Hashable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct CanvasSize: Sendable, Codable, Hashable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
}

public enum CanvasNodeKind: String, Sendable, Codable, CaseIterable, Hashable {
    case text, stickyNote, card, shape, image, video, audio, file, group, generationTask, scene3D
}

public enum CanvasShapeKind: String, Sendable, Codable, CaseIterable, Hashable {
    case rectangle, roundedRectangle, ellipse, diamond, triangle
}

public enum CanvasBackgroundStyle: String, Sendable, Codable, CaseIterable, Hashable {
    case blank, grid, dots
}

public struct CanvasVector3: Sendable, Codable, Hashable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double = 0, y: Double = 0, z: Double = 0) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = CanvasVector3()
    public static let one = CanvasVector3(x: 1, y: 1, z: 1)
}

public enum CanvasSceneObjectKind: String, Sendable, Codable, CaseIterable, Hashable {
    case box, sphere, cylinder, cone, plane
}

public enum CanvasSceneBackground: String, Sendable, Codable, CaseIterable, Hashable {
    case studio, graphite, midnight, chromaGreen
}

public struct CanvasSceneObject: Sendable, Codable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var kind: CanvasSceneObjectKind
    public var position: CanvasVector3
    /// Euler angles in degrees. Degrees make persisted values legible to users,
    /// tools and future schema migrations.
    public var rotation: CanvasVector3
    public var scale: CanvasVector3
    public var colorHex: String
    public var roughness: Double
    public var metallic: Bool
    public var isHidden: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        kind: CanvasSceneObjectKind,
        position: CanvasVector3 = .zero,
        rotation: CanvasVector3 = .zero,
        scale: CanvasVector3 = .one,
        colorHex: String = "#5B8DEF",
        roughness: Double = 0.35,
        metallic: Bool = false,
        isHidden: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.position = position
        self.rotation = rotation
        self.scale = scale
        self.colorHex = colorHex
        self.roughness = roughness
        self.metallic = metallic
        self.isHidden = isHidden
    }
}

public struct CanvasSceneCamera: Sendable, Codable, Hashable {
    public var orbitYaw: Double
    public var orbitPitch: Double
    public var distance: Double
    public var target: CanvasVector3
    public var fieldOfView: Double

    public init(
        orbitYaw: Double = 38,
        orbitPitch: Double = -22,
        distance: Double = 6.5,
        target: CanvasVector3 = .zero,
        fieldOfView: Double = 48
    ) {
        self.orbitYaw = orbitYaw
        self.orbitPitch = orbitPitch
        self.distance = distance
        self.target = target
        self.fieldOfView = fieldOfView
    }
}

public struct CanvasSceneLighting: Sendable, Codable, Hashable {
    public var keyIntensity: Double
    public var fillIntensity: Double
    public var castsShadows: Bool

    public init(
        keyIntensity: Double = 28_000,
        fillIntensity: Double = 7_000,
        castsShadows: Bool = true
    ) {
        self.keyIntensity = keyIntensity
        self.fillIntensity = fillIntensity
        self.castsShadows = castsShadows
    }
}

public struct CanvasScene3D: Sendable, Codable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var objects: [CanvasSceneObject]
    public var camera: CanvasSceneCamera
    public var lighting: CanvasSceneLighting
    public var background: CanvasSceneBackground
    public var showsGrid: Bool
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String = "3D 场景",
        objects: [CanvasSceneObject] = [],
        camera: CanvasSceneCamera = .init(),
        lighting: CanvasSceneLighting = .init(),
        background: CanvasSceneBackground = .studio,
        showsGrid: Bool = true,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.objects = objects
        self.camera = camera
        self.lighting = lighting
        self.background = background
        self.showsGrid = showsGrid
        self.updatedAt = updatedAt
    }

    public static func starter() -> CanvasScene3D {
        CanvasScene3D(objects: [
            CanvasSceneObject(
                name: "主体",
                kind: .box,
                position: CanvasVector3(x: 0, y: 0.6, z: 0),
                scale: CanvasVector3(x: 1.4, y: 1.2, z: 1.4)
            )
        ])
    }
}

public struct CanvasAssetReference: Sendable, Codable, Identifiable, Hashable {
    public var id: UUID
    public var contentHash: String?
    public var localRelativePath: String?
    public var cloudRecordName: String?
    public var mimeType: String?
    public var byteCount: Int64?
    public var sourceURL: URL?
    public var license: String?

    public init(
        id: UUID = UUID(), contentHash: String? = nil,
        localRelativePath: String? = nil, cloudRecordName: String? = nil,
        mimeType: String? = nil, byteCount: Int64? = nil,
        sourceURL: URL? = nil, license: String? = nil
    ) {
        self.id = id; self.contentHash = contentHash
        self.localRelativePath = localRelativePath; self.cloudRecordName = cloudRecordName
        self.mimeType = mimeType; self.byteCount = byteCount
        self.sourceURL = sourceURL; self.license = license
    }
}

public struct CanvasNode: Sendable, Codable, Identifiable, Hashable {
    public var id: UUID
    public var kind: CanvasNodeKind
    public var title: String?
    public var text: String
    public var position: CanvasPoint
    public var size: CanvasSize
    public var rotation: Double
    public var zIndex: Int
    public var isLocked: Bool
    public var groupID: UUID?
    public var shape: CanvasShapeKind?
    public var asset: CanvasAssetReference?
    public var generationJobID: UUID?
    public var scene3D: CanvasScene3D?
    public var sourceURLs: [URL]
    public var createdByRunID: UUID?
    public var metadata: [String: String]

    public init(
        id: UUID = UUID(), kind: CanvasNodeKind,
        title: String? = nil, text: String = "",
        position: CanvasPoint, size: CanvasSize,
        rotation: Double = 0, zIndex: Int = 0, isLocked: Bool = false,
        groupID: UUID? = nil, shape: CanvasShapeKind? = nil,
        asset: CanvasAssetReference? = nil, generationJobID: UUID? = nil,
        scene3D: CanvasScene3D? = nil,
        sourceURLs: [URL] = [], createdByRunID: UUID? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id; self.kind = kind; self.title = title; self.text = text
        self.position = position; self.size = size; self.rotation = rotation
        self.zIndex = zIndex; self.isLocked = isLocked; self.groupID = groupID
        self.shape = shape; self.asset = asset; self.generationJobID = generationJobID
        self.scene3D = scene3D
        self.sourceURLs = sourceURLs; self.createdByRunID = createdByRunID
        self.metadata = metadata
    }

    /// Compatibility initializer for schema-v1...v4 canvas coordinates. New
    /// callers should prefer `position` and `size`.
    public init(
        id: UUID = UUID(), text: String, x: Double, y: Double,
        width: Double = 260, height: Double = 150,
        sourceURLs: [String]? = nil, licenseStatus: String? = nil,
        createdByRunID: UUID? = nil, kind: CanvasNodeKind? = nil,
        rotation: Double? = nil, zIndex: Int? = nil, isLocked: Bool? = nil,
        groupID: UUID? = nil, shape: CanvasShapeKind? = nil,
        asset: CanvasAssetReference? = nil, generationJobID: UUID? = nil,
        scene3D: CanvasScene3D? = nil, metadata: [String: String]? = nil
    ) {
        var canonicalMetadata = metadata ?? [:]
        if let licenseStatus { canonicalMetadata["licenseStatus"] = licenseStatus }
        self.init(
            id: id, kind: kind ?? .text, text: text,
            position: .init(x: x, y: y), size: .init(width: width, height: height),
            rotation: rotation ?? 0, zIndex: zIndex ?? 0,
            isLocked: isLocked ?? false, groupID: groupID, shape: shape,
            asset: asset, generationJobID: generationJobID, scene3D: scene3D,
            sourceURLs: (sourceURLs ?? []).compactMap(URL.init(string:)),
            createdByRunID: createdByRunID, metadata: canonicalMetadata
        )
    }

    public var x: Double { get { position.x } set { position.x = newValue } }
    public var y: Double { get { position.y } set { position.y = newValue } }
    public var width: Double { get { size.width } set { size.width = newValue } }
    public var height: Double { get { size.height } set { size.height = newValue } }
    public var licenseStatus: String? {
        get { metadata["licenseStatus"] }
        set { metadata["licenseStatus"] = newValue }
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, text, position, size, rotation, zIndex, isLocked
        case groupID, shape, asset, generationJobID, scene3D, sourceURLs
        case createdByRunID, metadata
        case x, y, width, height, licenseStatus
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try values.decodeIfPresent(CanvasNodeKind.self, forKey: .kind) ?? .text
        title = try values.decodeIfPresent(String.self, forKey: .title)
        text = try values.decodeIfPresent(String.self, forKey: .text) ?? ""
        position = try values.decodeIfPresent(CanvasPoint.self, forKey: .position)
            ?? CanvasPoint(
                x: try values.decodeIfPresent(Double.self, forKey: .x) ?? 0,
                y: try values.decodeIfPresent(Double.self, forKey: .y) ?? 0
            )
        size = try values.decodeIfPresent(CanvasSize.self, forKey: .size)
            ?? CanvasSize(
                width: try values.decodeIfPresent(Double.self, forKey: .width) ?? 260,
                height: try values.decodeIfPresent(Double.self, forKey: .height) ?? 150
            )
        rotation = try values.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        zIndex = try values.decodeIfPresent(Int.self, forKey: .zIndex) ?? 0
        isLocked = try values.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        groupID = try values.decodeIfPresent(UUID.self, forKey: .groupID)
        shape = try values.decodeIfPresent(CanvasShapeKind.self, forKey: .shape)
        asset = try values.decodeIfPresent(CanvasAssetReference.self, forKey: .asset)
        generationJobID = try values.decodeIfPresent(UUID.self, forKey: .generationJobID)
        scene3D = try values.decodeIfPresent(CanvasScene3D.self, forKey: .scene3D)
        sourceURLs = try values.decodeIfPresent([URL].self, forKey: .sourceURLs) ?? []
        createdByRunID = try values.decodeIfPresent(UUID.self, forKey: .createdByRunID)
        metadata = try values.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
        if let legacyLicense = try values.decodeIfPresent(String.self, forKey: .licenseStatus) {
            metadata["licenseStatus"] = legacyLicense
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id); try values.encode(kind, forKey: .kind)
        try values.encodeIfPresent(title, forKey: .title); try values.encode(text, forKey: .text)
        try values.encode(position, forKey: .position); try values.encode(size, forKey: .size)
        try values.encode(rotation, forKey: .rotation); try values.encode(zIndex, forKey: .zIndex)
        try values.encode(isLocked, forKey: .isLocked); try values.encodeIfPresent(groupID, forKey: .groupID)
        try values.encodeIfPresent(shape, forKey: .shape); try values.encodeIfPresent(asset, forKey: .asset)
        try values.encodeIfPresent(generationJobID, forKey: .generationJobID)
        try values.encodeIfPresent(scene3D, forKey: .scene3D)
        if !sourceURLs.isEmpty { try values.encode(sourceURLs, forKey: .sourceURLs) }
        try values.encodeIfPresent(createdByRunID, forKey: .createdByRunID)
        if !metadata.isEmpty { try values.encode(metadata, forKey: .metadata) }
    }
}

public extension CanvasNode {
    /// Creates an editable native node before external content exists. Media
    /// placeholders can later receive an asset; generation placeholders can
    /// later receive a durable provider job. Keeping this factory in FloeCore
    /// gives every canvas entry point the same defaults.
    static func placeholder(
        kind: CanvasNodeKind,
        position: CanvasPoint,
        zIndex: Int = 0
    ) -> CanvasNode {
        let defaults: (text: String, size: CanvasSize) = switch kind {
        case .text: ("新建文本", .init(width: 260, height: 150))
        case .stickyNote: ("新建便签", .init(width: 260, height: 180))
        case .card: ("新建卡片", .init(width: 300, height: 200))
        case .shape: ("", .init(width: 220, height: 140))
        case .image: ("图片", .init(width: 320, height: 260))
        case .video: ("视频", .init(width: 320, height: 220))
        case .audio: ("音频", .init(width: 320, height: 170))
        case .file: ("文件", .init(width: 320, height: 170))
        case .group: ("新建分组", .init(width: 420, height: 280))
        case .generationTask: ("生成配置", .init(width: 340, height: 210))
        case .scene3D: ("3D 场景", .init(width: 420, height: 300))
        }
        return CanvasNode(
            kind: kind,
            text: defaults.text,
            position: position,
            size: defaults.size,
            zIndex: zIndex,
            shape: kind == .shape ? .roundedRectangle : nil,
            scene3D: kind == .scene3D ? .starter() : nil,
            metadata: [.image, .video, .audio, .file, .generationTask].contains(kind)
                ? ["placeholder": "true"] : [:]
        )
    }
}

public enum CanvasConnectionKind: String, Sendable, Codable, Hashable {
    case line, arrow, source, generatedFrom
}

public enum CanvasConnectionPort: String, Sendable, Codable, CaseIterable, Hashable {
    case top, trailing, bottom, leading
}

public struct CanvasConnection: Sendable, Codable, Identifiable, Hashable {
    public var id: UUID
    public var sourceNodeID: UUID
    public var destinationNodeID: UUID
    public var kind: CanvasConnectionKind
    public var label: String?
    public var sourcePort: CanvasConnectionPort?
    public var destinationPort: CanvasConnectionPort?

    public init(
        id: UUID = UUID(), sourceNodeID: UUID, destinationNodeID: UUID,
        kind: CanvasConnectionKind = .arrow, label: String? = nil,
        sourcePort: CanvasConnectionPort? = nil,
        destinationPort: CanvasConnectionPort? = nil
    ) {
        self.id = id; self.sourceNodeID = sourceNodeID
        self.destinationNodeID = destinationNodeID; self.kind = kind; self.label = label
        self.sourcePort = sourcePort; self.destinationPort = destinationPort
    }
}

public struct CanvasStroke: Sendable, Codable, Identifiable, Hashable {
    public var id: UUID
    public var points: [CanvasPoint]
    public var width: Double
    public var color: String
    public var isEraser: Bool

    public init(
        id: UUID = UUID(), points: [CanvasPoint], width: Double = 3,
        color: String = "primary", isEraser: Bool = false
    ) {
        self.id = id; self.points = points; self.width = width
        self.color = color; self.isEraser = isEraser
    }

    private enum CodingKeys: String, CodingKey { case id, points, width, color, isEraser }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        points = try values.decodeIfPresent([CanvasPoint].self, forKey: .points) ?? []
        width = try values.decodeIfPresent(Double.self, forKey: .width) ?? 3
        color = try values.decodeIfPresent(String.self, forKey: .color) ?? "primary"
        isEraser = try values.decodeIfPresent(Bool.self, forKey: .isEraser) ?? false
    }
}

public struct CanvasDocument: Sendable, Codable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var nodes: [CanvasNode]
    public var connections: [CanvasConnection]
    public var strokes: [CanvasStroke]
    /// Native PencilKit representation. Optional for lossless migration from
    /// schema v3 and for consumers that only understand vector point strokes.
    public var pencilDrawingData: Data?
    public var backgroundStyle: CanvasBackgroundStyle?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), name: String, nodes: [CanvasNode] = [],
        connections: [CanvasConnection] = [], strokes: [CanvasStroke] = [],
        pencilDrawingData: Data? = nil,
        backgroundStyle: CanvasBackgroundStyle? = .grid,
        createdAt: Date = Date(), updatedAt: Date = Date()
    ) {
        self.id = id; self.name = name; self.nodes = nodes
        self.connections = connections; self.strokes = strokes
        self.pencilDrawingData = pencilDrawingData
        self.backgroundStyle = backgroundStyle
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, nodes, connections, strokes, pencilDrawingData
        case backgroundStyle, createdAt, updatedAt
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "画布"
        nodes = try values.decodeIfPresent([CanvasNode].self, forKey: .nodes) ?? []
        connections = try values.decodeIfPresent([CanvasConnection].self, forKey: .connections) ?? []
        strokes = try values.decodeIfPresent([CanvasStroke].self, forKey: .strokes) ?? []
        pencilDrawingData = try values.decodeIfPresent(Data.self, forKey: .pencilDrawingData)
        backgroundStyle = try values.decodeIfPresent(CanvasBackgroundStyle.self, forKey: .backgroundStyle) ?? .grid
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }
}

public struct CanvasSyncSettings: Sendable, Codable, Hashable {
    public var isEnabled: Bool
    public var revision: Int64
    public var lastSyncedAt: Date?
    public var pendingReleaseBytes: Int64

    public init(
        isEnabled: Bool = true, revision: Int64 = 0,
        lastSyncedAt: Date? = nil, pendingReleaseBytes: Int64 = 0
    ) {
        self.isEnabled = isEnabled; self.revision = revision
        self.lastSyncedAt = lastSyncedAt; self.pendingReleaseBytes = pendingReleaseBytes
    }
}

public struct CanvasViewportState: Sendable, Codable, Hashable {
    public var center: CanvasPoint
    public var scale: Double

    public init(center: CanvasPoint = .init(x: 0, y: 0), scale: Double = 1) {
        self.center = center
        self.scale = min(3, max(0.3, scale))
    }
}

/// A platform-neutral transform shared by the native minimap and its tests.
/// It preserves aspect ratio, centers letterboxed content, and includes the
/// live viewport in the world bounds so an empty canvas remains navigable.
public struct CanvasMiniMapGeometry: Sendable, Hashable {
    public var worldOrigin: CanvasPoint
    public var worldSize: CanvasSize
    public var mapSize: CanvasSize
    public var scale: Double
    public var mapOffset: CanvasPoint

    public init(
        document: CanvasDocument,
        viewportCenter: CanvasPoint,
        viewportSize: CanvasSize,
        mapSize: CanvasSize,
        padding: Double = 90
    ) {
        let halfViewportWidth = max(1, viewportSize.width) / 2
        let halfViewportHeight = max(1, viewportSize.height) / 2
        var minX = viewportCenter.x - halfViewportWidth
        var maxX = viewportCenter.x + halfViewportWidth
        var minY = viewportCenter.y - halfViewportHeight
        var maxY = viewportCenter.y + halfViewportHeight

        for node in document.nodes {
            minX = min(minX, node.x - node.width / 2)
            maxX = max(maxX, node.x + node.width / 2)
            minY = min(minY, node.y - node.height / 2)
            maxY = max(maxY, node.y + node.height / 2)
        }
        for stroke in document.strokes {
            for point in stroke.points {
                minX = min(minX, point.x - stroke.width / 2)
                maxX = max(maxX, point.x + stroke.width / 2)
                minY = min(minY, point.y - stroke.width / 2)
                maxY = max(maxY, point.y + stroke.width / 2)
            }
        }

        let safePadding = max(0, padding)
        minX -= safePadding; maxX += safePadding
        minY -= safePadding; maxY += safePadding
        let worldWidth = max(1, maxX - minX)
        let worldHeight = max(1, maxY - minY)
        let safeMapWidth = max(1, mapSize.width)
        let safeMapHeight = max(1, mapSize.height)
        let fittedScale = max(0.000_001, min(
            safeMapWidth / worldWidth,
            safeMapHeight / worldHeight
        ))

        self.worldOrigin = CanvasPoint(x: minX, y: minY)
        self.worldSize = CanvasSize(width: worldWidth, height: worldHeight)
        self.mapSize = CanvasSize(width: safeMapWidth, height: safeMapHeight)
        self.scale = fittedScale
        self.mapOffset = CanvasPoint(
            x: (safeMapWidth - worldWidth * fittedScale) / 2,
            y: (safeMapHeight - worldHeight * fittedScale) / 2
        )
    }

    public func mapPoint(_ point: CanvasPoint) -> CanvasPoint {
        CanvasPoint(
            x: mapOffset.x + (point.x - worldOrigin.x) * scale,
            y: mapOffset.y + (point.y - worldOrigin.y) * scale
        )
    }

    public func canvasPoint(_ point: CanvasPoint) -> CanvasPoint {
        CanvasPoint(
            x: worldOrigin.x + (point.x - mapOffset.x) / scale,
            y: worldOrigin.y + (point.y - mapOffset.y) / scale
        )
    }

    public func mapSize(_ size: CanvasSize) -> CanvasSize {
        CanvasSize(width: size.width * scale, height: size.height * scale)
    }
}

public struct CanvasAssistantSession: Sendable, Codable, Identifiable, Hashable {
    public var id: UUID
    public var conversationID: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), conversationID: UUID, title: String,
        createdAt: Date = Date(), updatedAt: Date = Date()
    ) {
        self.id = id; self.conversationID = conversationID; self.title = title
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

public struct CanvasProject: Sendable, Codable, Hashable, Identifiable {
    public static let currentSchemaVersion = 7

    public var id: UUID
    public var schemaVersion: Int
    public var workspaceID: UUID?
    public var name: String
    public var documents: [CanvasDocument]
    public var selectedDocumentID: UUID
    public var agentConversationID: UUID?
    public var assistantSessions: [CanvasAssistantSession]
    public var selectedAssistantSessionID: UUID?
    /// Canonical one-to-one ownership between a canvas document and its
    /// assistant conversation. The legacy project-wide fields above remain
    /// decodable so schema-v6 packages can be migrated without losing history.
    public var agentConversationIDsByDocument: [UUID: UUID]
    public var viewports: [UUID: CanvasViewportState]
    public var revision: Int64
    public var sync: CanvasSyncSettings
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID, schemaVersion: Int = Self.currentSchemaVersion,
        workspaceID: UUID? = nil, name: String, documents: [CanvasDocument],
        selectedDocumentID: UUID, agentConversationID: UUID? = nil,
        assistantSessions: [CanvasAssistantSession] = [],
        selectedAssistantSessionID: UUID? = nil,
        agentConversationIDsByDocument: [UUID: UUID] = [:],
        viewports: [UUID: CanvasViewportState] = [:], revision: Int64 = 0,
        sync: CanvasSyncSettings = .init(), createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id; self.schemaVersion = schemaVersion; self.workspaceID = workspaceID
        self.name = name; self.documents = documents
        self.selectedDocumentID = selectedDocumentID
        self.agentConversationID = agentConversationID
        self.assistantSessions = assistantSessions
        self.selectedAssistantSessionID = selectedAssistantSessionID
        self.agentConversationIDsByDocument = agentConversationIDsByDocument
        self.viewports = viewports; self.revision = revision; self.sync = sync
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, schemaVersion, workspaceID, name, documents, selectedDocumentID
        case agentConversationID, assistantSessions, selectedAssistantSessionID
        case agentConversationIDsByDocument
        case viewports, revision, sync, createdAt, updatedAt
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        workspaceID = try values.decodeIfPresent(UUID.self, forKey: .workspaceID)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "画布"
        documents = try values.decodeIfPresent([CanvasDocument].self, forKey: .documents) ?? []
        selectedDocumentID = try values.decodeIfPresent(UUID.self, forKey: .selectedDocumentID)
            ?? documents.first?.id ?? UUID()
        agentConversationID = try values.decodeIfPresent(UUID.self, forKey: .agentConversationID)
        assistantSessions = try values.decodeIfPresent(
            [CanvasAssistantSession].self, forKey: .assistantSessions
        ) ?? agentConversationID.map {
            [CanvasAssistantSession(conversationID: $0, title: "画布助手")]
        } ?? []
        selectedAssistantSessionID = try values.decodeIfPresent(
            UUID.self, forKey: .selectedAssistantSessionID
        ) ?? assistantSessions.first?.id
        agentConversationIDsByDocument = try values.decodeIfPresent(
            [UUID: UUID].self, forKey: .agentConversationIDsByDocument
        ) ?? [:]
        viewports = try values.decodeIfPresent(
            [UUID: CanvasViewportState].self, forKey: .viewports
        ) ?? [:]
        revision = try values.decodeIfPresent(Int64.self, forKey: .revision) ?? 0
        sync = try values.decodeIfPresent(CanvasSyncSettings.self, forKey: .sync) ?? .init()
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        if agentConversationIDsByDocument.isEmpty,
           documents.contains(where: { $0.id == selectedDocumentID }) {
            let selectedLegacyConversationID = assistantSessions.first(where: {
                $0.id == selectedAssistantSessionID
            })?.conversationID ?? assistantSessions.first?.conversationID ?? agentConversationID
            if let selectedLegacyConversationID {
                agentConversationIDsByDocument[selectedDocumentID] = selectedLegacyConversationID
            }
        }
    }
}

/// The one canonical codec used by the app, sync layer and imports. It knows
/// how to recover the project identifier that schema-v1 files derived from
/// their filename, then always emits the current canonical schema.
public enum CanvasProjectCodec {
    public static func decode(
        _ data: Data,
        fallbackID: UUID? = nil,
        decoder: JSONDecoder? = nil
    ) throws -> CanvasProject {
        let decoder = decoder ?? JSONDecoder()
        var project = try decoder.decode(CanvasProject.self, from: data)
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["id"] == nil, let fallbackID {
            project.id = fallbackID
        }
        guard (1...CanvasProject.currentSchemaVersion).contains(project.schemaVersion),
              !project.documents.isEmpty else {
            throw FloeError.validationFailed("Unsupported or empty Floe canvas package")
        }
        project.schemaVersion = CanvasProject.currentSchemaVersion
        if !project.documents.contains(where: { $0.id == project.selectedDocumentID }),
           let first = project.documents.first {
            project.selectedDocumentID = first.id
        }
        return project
    }

    public static func encode(
        _ project: CanvasProject,
        encoder: JSONEncoder? = nil
    ) throws -> Data {
        var canonical = project
        canonical.schemaVersion = CanvasProject.currentSchemaVersion
        return try (encoder ?? JSONEncoder()).encode(canonical)
    }
}

public struct CanvasDeletionTombstone: Sendable, Codable, Identifiable, Hashable {
    public var id: UUID
    public var canvasID: UUID
    public var operationID: UUID
    public var revision: Int64
    public var deletedAt: Date

    public init(
        id: UUID = UUID(), canvasID: UUID, operationID: UUID = UUID(),
        revision: Int64, deletedAt: Date = Date()
    ) {
        self.id = id; self.canvasID = canvasID; self.operationID = operationID
        self.revision = revision; self.deletedAt = deletedAt
    }
}

public enum CanvasSyncEntityKind: String, Sendable, Codable, CaseIterable, Hashable {
    case project, document, node, connection, stroke, thumbnail, mediaJob, asset, tombstone
}

public enum CanvasSyncMutation: String, Sendable, Codable, CaseIterable, Hashable {
    case upsert, delete
}

/// Durable, idempotent unit of canvas synchronization. `operationID` is
/// stable across retries; CloudKit accepts an operation at most once per
/// canvas revision even when devices deliver records out of order.
public struct CanvasSyncOperation: Sendable, Codable, Identifiable, Hashable {
    public var id: UUID { operationID }
    public var operationID: UUID
    public var canvasID: UUID
    public var entityKind: CanvasSyncEntityKind
    public var entityID: UUID
    public var mutation: CanvasSyncMutation
    public var revision: Int64
    public var payload: Data?
    public var assetHashes: [String]
    public var createdAt: Date

    public init(
        operationID: UUID = UUID(), canvasID: UUID,
        entityKind: CanvasSyncEntityKind, entityID: UUID,
        mutation: CanvasSyncMutation, revision: Int64,
        payload: Data? = nil, assetHashes: [String] = [],
        createdAt: Date = Date()
    ) {
        self.operationID = operationID
        self.canvasID = canvasID
        self.entityKind = entityKind
        self.entityID = entityID
        self.mutation = mutation
        self.revision = revision
        self.payload = payload
        self.assetHashes = assetHashes
        self.createdAt = createdAt
    }
}

public enum CanvasSyncReducer {
    /// Deterministic merge: highest revision wins; equal revisions use the
    /// stable operation ID, so every device reaches the same result.
    public static func newest(
        _ lhs: CanvasSyncOperation,
        _ rhs: CanvasSyncOperation
    ) -> CanvasSyncOperation {
        precondition(lhs.canvasID == rhs.canvasID)
        precondition(lhs.entityKind == rhs.entityKind)
        precondition(lhs.entityID == rhs.entityID)
        if lhs.revision != rhs.revision {
            return lhs.revision > rhs.revision ? lhs : rhs
        }
        return lhs.operationID.uuidString > rhs.operationID.uuidString ? lhs : rhs
    }
}
