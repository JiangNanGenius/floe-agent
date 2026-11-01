// SPDX-License-Identifier: MPL-2.0
//
// G09-R1 — typed request/response contracts shared by the bridge, the
// storage hosts and the authored Swift tests. These are HOST DTOs; the
// Kotlin UI contracts mirror the exact same JSON field names.
import Foundation
import FloeCore
import FloeAndroidWorkbench

// MARK: - Storage layer

/// Explicit storage authority supplied by the caller. It is validated
/// against the accepted composition; it is never inferred from a recorded
/// project field, a first project or a temporary directory.
public struct G09StorageLayerDTO: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case appOwned
        case workspace
    }

    public var kind: Kind
    public var workspaceID: UUID?

    public init(kind: Kind, workspaceID: UUID? = nil) {
        self.kind = kind
        self.workspaceID = workspaceID
    }

    public func validatedWorkspaceID() throws -> UUID? {
        switch kind {
        case .appOwned:
            guard workspaceID == nil else {
                throw G09CreativeError.invalidPayload("appOwnedMustNotNameWorkspace")
            }
            return nil
        case .workspace:
            guard let workspaceID else {
                throw G09CreativeError.invalidPayload("workspaceIDRequired")
            }
            return workspaceID
        }
    }
}

// MARK: - Trusted origin (provenance, never storage authority)

/// Actual source/owner context supplied by the App route when it exists. It
/// is validated against the accepted composition and persisted verbatim; it
/// never selects a storage root and never fabricates an AI task.
public struct G09CreativeOriginDTO: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case standalone
        case files
        case workspace
        case canvas
        case chat
    }

    public var kind: Kind
    public var ownerID: UUID?
    public var environmentID: String?

    public init(kind: Kind, ownerID: UUID? = nil, environmentID: String? = nil) {
        self.kind = kind
        self.ownerID = ownerID
        self.environmentID = environmentID
    }
}

// MARK: - Canvas

public struct G09CanvasSummaryDTO: Encodable, Sendable {
    public var id: UUID
    public var name: String
    public var revision: Int64
    public var updatedAt: Date
    public var schemaVersion: Int
    public var documentCount: Int
    public var corrupt: Bool
    public var writable: Bool
}

public struct G09CanvasEnvelopeDTO: Encodable, Sendable {
    public var project: CanvasProject
    public var assetsBasePath: String
    public var writable: Bool
    public var recoveryWarnings: [String]
}

public struct G09CanvasCreateRequest: Decodable, Sendable {
    public var name: String
    public var workspaceID: UUID?
    public var sessionToken: String
}

public struct G09CanvasLoadRequest: Decodable, Sendable {
    public var canvasID: UUID
    public var sessionToken: String?
}

public struct G09CanvasPatchRequest: Decodable, Sendable {
    public var canvasID: UUID
    public var expectedRevision: Int64
    public var sessionToken: String
    public var opID: String
    public var patch: CanvasPatch
}

public struct G09CanvasOperationReceiptDTO: Encodable, Sendable {
    public var canvasID: UUID
    public var documentID: UUID?
    public var previousRevision: Int64
    public var revision: Int64
    public var changedNodeIDs: [UUID]
    public var changedConnectionIDs: [UUID]
    public var undoToken: UUID?
    public var opID: String
    public var idempotent: Bool
}

public struct G09CanvasMutationReceiptDTO: Encodable, Sendable {
    public var canvasID: UUID
    public var name: String?
    public var revision: Int64
    public var deleted: Bool
    public var opID: String
    public var idempotent: Bool
}

public struct G09CanvasRenameRequest: Decodable, Sendable {
    public var canvasID: UUID
    public var expectedRevision: Int64
    public var name: String
    public var sessionToken: String
    public var opID: String?
}

public struct G09CanvasSessionCloseRequest: Decodable, Sendable {
    public var canvasID: UUID
    public var sessionToken: String
}

public struct G09CanvasSessionCloseReceiptDTO: Encodable, Sendable {
    public var canvasID: UUID
    public var closed: Bool
    public var replaced: Bool
}

public struct G09CanvasDeleteRequest: Decodable, Sendable {
    public var canvasID: UUID
    public var expectedRevision: Int64
    public var sessionToken: String
    public var opID: String?
}

public struct G09AssetReferenceOperationDTO: Codable, Sendable {
    public var opID: String
    public var assetID: UUID
    public var delta: Int
}

public struct G09AssetReferenceOpRequest: Decodable, Sendable {
    public var canvasID: UUID
    public var sessionToken: String
    public var operations: [G09AssetReferenceOperationDTO]
}

public struct G09AssetReferenceReceiptDTO: Encodable, Sendable {
    public var canvasID: UUID
    public var applied: Int
    public var pending: Int
}

public struct G09RecoveryRequest: Decodable, Sendable {
    public var canvasID: UUID
}

public struct G09RecoveryStateDTO: Encodable, Sendable {
    public var canvasID: UUID
    public var pendingOperations: Int
    public var appliedOperations: Int
    public var warnings: [String]
}

public struct G09AssetImportRequest: Decodable, Sendable {
    public var token: String
    public var opID: String
    public var fileName: String
    public var mimeType: String?
    public var byteCount: Int64
    public var sha256: String
    public var sessionToken: String
}

public struct G09AssetDiscardRequest: Decodable, Sendable {
    public var token: String
}

public struct G09AssetReceiptDTO: Encodable, Sendable {
    public var asset: CanvasAssetReference
    public var deduplicated: Bool
    public var opID: String
    public var idempotent: Bool
}

public struct G09AssetImportReceipt: Codable, Sendable, Equatable {
    public var opID: String
    public var asset: CanvasAssetReference
    public var deduplicated: Bool
    public var sessionDigest: String
    public var committedAt: Date

    public init(opID: String, asset: CanvasAssetReference, deduplicated: Bool,
                sessionDigest: String, committedAt: Date = Date()) {
        self.opID = opID
        self.asset = asset
        self.deduplicated = deduplicated
        self.sessionDigest = sessionDigest
        self.committedAt = committedAt
    }
}

// MARK: - Media

public struct G09MediaCreateRequest: Decodable, Sendable {
    public var name: String
    public var kind: String
    public var width: Int
    public var height: Int
    public var frameRate: Double?
    public var storage: G09StorageLayerDTO
    public var origin: G09CreativeOriginDTO
    public var sessionToken: String
}

public struct G09MediaProjectRequest: Decodable, Sendable {
    public var projectID: UUID
    public var storage: G09StorageLayerDTO?
    public var origin: G09CreativeOriginDTO?
    public var sessionToken: String?
}

public struct G09MediaApplyRequest: Decodable, Sendable {
    public var projectID: UUID
    public var expectedRevision: Int64
    public var sessionToken: String
    public var storage: G09StorageLayerDTO?
    public var origin: G09CreativeOriginDTO?
    public var opID: String
    public var commands: [G09MediaCommandWire]
}

public struct G09MediaUndoRedoRequest: Decodable, Sendable {
    public var projectID: UUID
    public var expectedRevision: Int64
    public var sessionToken: String
    public var storage: G09StorageLayerDTO?
    public var origin: G09CreativeOriginDTO?
    public var opID: String
}

public struct G09MediaRenameRequest: Decodable, Sendable {
    public var projectID: UUID
    public var expectedRevision: Int64
    public var name: String
    public var sessionToken: String
    public var storage: G09StorageLayerDTO?
    public var origin: G09CreativeOriginDTO?
    public var opID: String?
}

public struct G09MediaDeleteRequest: Decodable, Sendable {
    public var projectID: UUID
    public var expectedRevision: Int64
    public var sessionToken: String
    public var storage: G09StorageLayerDTO?
    public var origin: G09CreativeOriginDTO?
    public var opID: String?
}

public struct G09MediaAssetImportRequest: Decodable, Sendable {
    public var token: String
    public var opID: String
    public var projectID: UUID
    public var expectedRevision: Int64
    public var storage: G09StorageLayerDTO?
    public var origin: G09CreativeOriginDTO?
    public var sessionToken: String
    public var fileName: String
    public var mimeType: String?
    public var byteCount: Int64
    public var sha256: String
}

public struct G09MediaRelinkRequest: Decodable, Sendable {
    public var projectID: UUID
    public var expectedRevision: Int64
    public var storage: G09StorageLayerDTO?
    public var origin: G09CreativeOriginDTO?
    public var sessionToken: String
    public var assetID: UUID
    public var relativePath: String
    public var opID: String?
}

public struct G09MediaMutationReceiptDTO: Encodable, Sendable {
    public var projectID: UUID
    public var name: String?
    public var revision: Int64
    public var deleted: Bool
    public var canUndo: Bool
    public var canRedo: Bool
    public var opID: String
    public var idempotent: Bool
}

public struct G09CreativeStatusDTO: Encodable, Sendable {
    public var bound: Bool
    public var epoch: UInt64?
    public var rootFingerprint: String?
    public var bridgeVersion: Int
    public var schema: String
    public var actions: [String]
    public var canvasSchemaVersion: Int
    public var mediaSchemaVersion: Int
    public var requestMaxBytes: Int
    public var responseMaxBytes: Int
    public var canvasProjectMaxBytes: Int
    public var mediaProjectMaxBytes: Int
    public var assetMaxBytes: Int
}

public struct G09MediaSessionCloseRequest: Decodable, Sendable {
    public var projectID: UUID
    public var sessionToken: String
}

public struct G09MediaSessionCloseReceiptDTO: Encodable, Sendable {
    public var projectID: UUID
    public var closed: Bool
    public var replaced: Bool
}

public struct G09MediaSummaryDTO: Encodable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: String
    public var revision: Int64
    public var updatedAt: Date
    public var ownerKind: String
    public var ownerID: UUID?
    public var environmentID: String?
    public var assetCount: Int
    public var layerCount: Int
    public var corrupt: Bool
    public var writable: Bool
    public var provenanceWarning: Bool
}

public struct G09MediaEnvelopeDTO: Encodable, Sendable {
    public var project: MediaProject
    public var mediaRootPath: String
    public var storage: G09StorageLayerDTO
    public var writable: Bool
    public var warnings: [String]
}

public struct G09MediaProjectReceiptDTO: Encodable, Sendable {
    public var projectID: UUID
    public var revision: Int64
    public var canUndo: Bool
    public var canRedo: Bool
    public var opID: String
    public var idempotent: Bool
}

public struct G09MediaAssetReceiptDTO: Encodable, Sendable {
    public var projectID: UUID
    public var asset: MediaAssetReference
    public var revision: Int64
    public var canUndo: Bool
    public var canRedo: Bool
    public var opID: String
    public var idempotent: Bool
}

// MARK: - Media command wire

/// Explicit three-way nullable update (unchanged / clear / set). The JSON
/// shape is a closed tagged object so Kotlin and Swift cannot disagree about
/// the meaning of an absent or null value.
public enum G09OptionalUpdateWire<Value: Codable & Sendable>: Decodable, Sendable {
    case unchanged
    case clear
    case set(Value)

    private enum CodingKeys: String, CodingKey { case state, value }
    private enum State: String, Codable { case unchanged, clear, set }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(State.self, forKey: .state) {
        case .unchanged: self = .unchanged
        case .clear: self = .clear
        case .set: self = .set(try container.decode(Value.self, forKey: .value))
        }
    }

    func mapped<Mapped: Sendable & Codable & Hashable>(
        _ transform: (Value) -> Mapped
    ) -> OptionalUpdate<Mapped> where Value: Equatable, Value: Hashable {
        switch self {
        case .unchanged: .unchanged
        case .clear: .clear
        case .set(let value): .set(transform(value))
        }
    }
}

/// R1 media edit vocabulary. It deliberately excludes timeline/music/caption
/// commands (R2), renderer-produced raster merges and selection fill/cut
/// (R2); those need renderer assets that direct R1 CORE does not own. Adding
/// a case here is additive; the host never accepts an unknown `type`.
public enum G09MediaCommandWire: Decodable, Sendable {
    case addAsset(MediaAssetReference)
    case relinkAsset(assetID: UUID, relativePath: String)
    case setCanvas(width: Int, height: Int, frameRate: Double?)
    case addImageLayer(ImageLayer)
    case updateLayer(id: UUID, transform: ImageLayerTransform?, opacity: Double?,
                     isHidden: Bool?, isLocked: Bool?, adjustment: ImageLayerAdjustment?,
                     text: ImageTextContent?, crop: G09OptionalUpdateWire<NormalizedRect>)
    case reorderLayers(orderedIDs: [UUID])
    case moveLayer(id: UUID, toIndex: Int)
    case removeLayer(id: UUID)
    case duplicateLayer(id: UUID, name: String?)
    case addFreehandStroke(id: UUID, stroke: ImageFreehandStroke)
    case setCanvasAdjustment(ImageLayerAdjustment)
    case setImageSelection(ImageSelection?)
    case flipLayer(id: UUID, horizontal: Bool)
    case clearLayerMask(id: UUID)
    case setLayerSelectionMask(id: UUID, selection: G09OptionalUpdateWire<ImageSelection>)

    private enum CodingKeys: String, CodingKey {
        case type
        case asset, assetID, relativePath, width, height, frameRate
        case layer, id, transform, opacity, isHidden, isLocked, adjustment, text, crop
        case orderedIDs, toIndex, name, stroke, selection, horizontal
    }

    private enum Kind: String, Decodable {
        case addAsset, relinkAsset, setCanvas, addImageLayer, updateLayer
        case reorderLayers, moveLayer, removeLayer, duplicateLayer
        case addFreehandStroke, setCanvasAdjustment, setImageSelection
        case flipLayer, clearLayerMask, setLayerSelectionMask
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .addAsset:
            self = .addAsset(try container.decode(MediaAssetReference.self, forKey: .asset))
        case .relinkAsset:
            self = .relinkAsset(
                assetID: try container.decode(UUID.self, forKey: .assetID),
                relativePath: try container.decode(String.self, forKey: .relativePath))
        case .setCanvas:
            self = .setCanvas(
                width: try container.decode(Int.self, forKey: .width),
                height: try container.decode(Int.self, forKey: .height),
                frameRate: try container.decodeIfPresent(Double.self, forKey: .frameRate))
        case .addImageLayer:
            self = .addImageLayer(try container.decode(ImageLayer.self, forKey: .layer))
        case .updateLayer:
            self = .updateLayer(
                id: try container.decode(UUID.self, forKey: .id),
                transform: try container.decodeIfPresent(ImageLayerTransform.self, forKey: .transform),
                opacity: try container.decodeIfPresent(Double.self, forKey: .opacity),
                isHidden: try container.decodeIfPresent(Bool.self, forKey: .isHidden),
                isLocked: try container.decodeIfPresent(Bool.self, forKey: .isLocked),
                adjustment: try container.decodeIfPresent(ImageLayerAdjustment.self, forKey: .adjustment),
                text: try container.decodeIfPresent(ImageTextContent.self, forKey: .text),
                crop: try container.decode(G09OptionalUpdateWire<NormalizedRect>.self, forKey: .crop))
        case .reorderLayers:
            self = .reorderLayers(orderedIDs: try container.decode([UUID].self, forKey: .orderedIDs))
        case .moveLayer:
            self = .moveLayer(
                id: try container.decode(UUID.self, forKey: .id),
                toIndex: try container.decode(Int.self, forKey: .toIndex))
        case .removeLayer:
            self = .removeLayer(id: try container.decode(UUID.self, forKey: .id))
        case .duplicateLayer:
            self = .duplicateLayer(
                id: try container.decode(UUID.self, forKey: .id),
                name: try container.decodeIfPresent(String.self, forKey: .name))
        case .addFreehandStroke:
            self = .addFreehandStroke(
                id: try container.decode(UUID.self, forKey: .id),
                stroke: try container.decode(ImageFreehandStroke.self, forKey: .stroke))
        case .setCanvasAdjustment:
            self = .setCanvasAdjustment(
                try container.decode(ImageLayerAdjustment.self, forKey: .adjustment))
        case .setImageSelection:
            self = .setImageSelection(
                try container.decodeIfPresent(ImageSelection.self, forKey: .selection))
        case .flipLayer:
            self = .flipLayer(
                id: try container.decode(UUID.self, forKey: .id),
                horizontal: try container.decode(Bool.self, forKey: .horizontal))
        case .clearLayerMask:
            self = .clearLayerMask(id: try container.decode(UUID.self, forKey: .id))
        case .setLayerSelectionMask:
            self = .setLayerSelectionMask(
                id: try container.decode(UUID.self, forKey: .id),
                selection: try container.decode(
                    G09OptionalUpdateWire<ImageSelection>.self, forKey: .selection))
        }
    }

    /// Converts the closed wire case into the original shared edit command.
    /// No second edit engine exists here.
    public func sharedCommand() -> MediaEditCommand {
        switch self {
        case .addAsset(let asset):
            return .addAsset(asset)
        case .relinkAsset(let assetID, let relativePath):
            return .relinkAsset(assetID: assetID, relativePath: relativePath)
        case .setCanvas(let width, let height, let frameRate):
            return .setCanvas(width: width, height: height, frameRate: frameRate)
        case .addImageLayer(let layer):
            return .addImageLayer(layer)
        case .updateLayer(let id, let transform, let opacity, let isHidden,
                          let isLocked, let adjustment, let text, let crop):
            return .updateLayer(
                id: id, transform: transform, opacity: opacity,
                isHidden: isHidden, isLocked: isLocked, adjustment: adjustment,
                text: text, crop: crop.mapped { $0 })
        case .reorderLayers(let orderedIDs):
            return .reorderLayers(orderedIDs: orderedIDs)
        case .moveLayer(let id, let toIndex):
            return .moveLayer(id: id, toIndex: toIndex)
        case .removeLayer(let id):
            return .removeLayer(id: id)
        case .duplicateLayer(let id, let name):
            return .duplicateLayer(id: id, name: name)
        case .addFreehandStroke(let id, let stroke):
            return .addFreehandStroke(id: id, stroke: stroke)
        case .setCanvasAdjustment(let adjustment):
            return .setCanvasAdjustment(adjustment)
        case .setImageSelection(let selection):
            return .setImageSelection(selection)
        case .flipLayer(let id, let horizontal):
            return .flipLayer(id: id, horizontal: horizontal)
        case .clearLayerMask(let id):
            return .clearLayerMask(id: id)
        case .setLayerSelectionMask(let id, let selection):
            return .setLayerSelectionMask(id: id, selection: selection.mapped { $0 })
        }
    }
}
