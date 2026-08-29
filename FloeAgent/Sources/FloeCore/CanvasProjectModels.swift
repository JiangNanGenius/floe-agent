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
    case text, stickyNote, shape, image, video, audio, file, group, generationTask, scene3D
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
    public var text: String?
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
        title: String? = nil, text: String? = nil,
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
}

public enum CanvasConnectionKind: String, Sendable, Codable, Hashable {
    case line, arrow, source, generatedFrom
}

public struct CanvasConnection: Sendable, Codable, Identifiable, Hashable {
    public var id: UUID
    public var sourceNodeID: UUID
    public var destinationNodeID: UUID
    public var kind: CanvasConnectionKind
    public var label: String?

    public init(
        id: UUID = UUID(), sourceNodeID: UUID, destinationNodeID: UUID,
        kind: CanvasConnectionKind = .arrow, label: String? = nil
    ) {
        self.id = id; self.sourceNodeID = sourceNodeID
        self.destinationNodeID = destinationNodeID; self.kind = kind; self.label = label
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

public struct CanvasProject: Sendable, Codable, Hashable, Identifiable {
    public static let currentSchemaVersion = 5

    public var id: UUID
    public var schemaVersion: Int
    public var workspaceID: UUID?
    public var name: String
    public var documents: [CanvasDocument]
    public var selectedDocumentID: UUID
    public var agentConversationID: UUID?
    public var sync: CanvasSyncSettings
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID, schemaVersion: Int = Self.currentSchemaVersion,
        workspaceID: UUID? = nil, name: String, documents: [CanvasDocument],
        selectedDocumentID: UUID, agentConversationID: UUID? = nil,
        sync: CanvasSyncSettings = .init(), createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id; self.schemaVersion = schemaVersion; self.workspaceID = workspaceID
        self.name = name; self.documents = documents
        self.selectedDocumentID = selectedDocumentID
        self.agentConversationID = agentConversationID; self.sync = sync
        self.createdAt = createdAt; self.updatedAt = updatedAt
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
