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
    case text, stickyNote, shape, image, video, audio, file, group, generationTask
}

public enum CanvasShapeKind: String, Sendable, Codable, CaseIterable, Hashable {
    case rectangle, roundedRectangle, ellipse, diamond, triangle
}

public enum CanvasBackgroundStyle: String, Sendable, Codable, CaseIterable, Hashable {
    case blank, grid, dots
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
        sourceURLs: [URL] = [], createdByRunID: UUID? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id; self.kind = kind; self.title = title; self.text = text
        self.position = position; self.size = size; self.rotation = rotation
        self.zIndex = zIndex; self.isLocked = isLocked; self.groupID = groupID
        self.shape = shape; self.asset = asset; self.generationJobID = generationJobID
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
    public static let currentSchemaVersion = 4

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
