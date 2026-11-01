// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 — additive design wire envelopes used by the REAL design service.
//
// The public DTOs in `G09R2Contracts.swift` are the frozen consumer shapes.
// These small envelopes only extend the existing closed BridgeV6 action names
// with routing metadata; they are not a second protocol and carry no path or
// storage authority.
import Foundation
import FloeCore

/// One read action that may also create the explicit owner envelope. A plain
/// `state` request sends only `binding`; `bindTarget` adds the two optional
/// fields. The native side derives the operation from their presence, so the
/// frozen action vocabulary does not need a new `design.bind` action.
public struct G09R2DesignStateEnvelope: Decodable, Sendable {
    /// Required for every state/bind/mutation route. The two read-only
    /// creative inventory routes (`assets`/`pending`) carry no target binding:
    /// they are scoped to the bound service/root and are reachable only through
    /// the trusted App bridge.
    public var binding: G09R2DesignBindingDTO?
    public var expectedRevision: Int64?
    public var opID: String?
    /// Additive creative-owner routing carried by the existing
    /// `design.owner.state` action. The closed action list is unchanged; this
    /// envelope only tells the host whether the call is a real creative START
    /// (awaiting first result), the verified first-result bind, the direct
    /// retained-asset bind, the verified staged import+bind, or one of the two
    /// bounded read-only inventory routes.
    public var creative: G09R2DesignCreativeRouteDTO?

    public init(binding: G09R2DesignBindingDTO? = nil,
                expectedRevision: Int64? = nil,
                opID: String? = nil,
                creative: G09R2DesignCreativeRouteDTO? = nil) {
        self.binding = binding
        self.expectedRevision = expectedRevision
        self.opID = opID
        self.creative = creative
    }
}

/// Routing envelope for the single frozen `design.canvas.mutate` action. The
/// exact request DTO is still the frozen `G09R2Design*Request`; the enum only
/// tells the host which canvas-CAS workflow it must execute.
public enum G09R2DesignCanvasMutationKind: String, Codable, Sendable {
    case brief
    case spec
    case freeze
    case propose
    case reject
}

public struct G09R2DesignCanvasMutationEnvelope: Decodable, Sendable {
    public var kind: G09R2DesignCanvasMutationKind
    public var brief: G09R2DesignBriefRequest?
    public var spec: G09R2DesignSpecRequest?
    public var freeze: G09R2DesignFreezeRequest?
    public var propose: G09R2DesignProposeRequest?
    public var reject: G09R2DesignRejectRequest?

    public init(
        kind: G09R2DesignCanvasMutationKind,
        brief: G09R2DesignBriefRequest? = nil,
        spec: G09R2DesignSpecRequest? = nil,
        freeze: G09R2DesignFreezeRequest? = nil,
        propose: G09R2DesignProposeRequest? = nil,
        reject: G09R2DesignRejectRequest? = nil
    ) {
        self.kind = kind
        self.brief = brief
        self.spec = spec
        self.freeze = freeze
        self.propose = propose
        self.reject = reject
    }
}

/// The immutable payload of a real Canvas snapshot preview/export.
///
/// It carries the ACTUAL authoritative `CanvasProject` document at the exact
/// same revision as the design snapshot (documents, selected node, shapes/text/
/// positions/sizes and asset REFERENCES), so the App can render the real scene
/// through its existing Canvas renderer. It is never labelled as an image
/// format and never claims a rendered bitmap. `project` is the workflow design
/// metadata detail (brief/spec/candidates), not a substitute for the document.
///
/// Asset references are descriptive ids/digests only. The App must resolve
/// bytes through the native verified asset reader (the captured-owner host and
/// its digest), never through a recorded root/path.
struct G09R2DesignCanvasSnapshot: Encodable, Sendable {
    /// A canvas preview document is bounded independently of the 15 MiB
    /// persisted-canvas cap. A larger document is a typed refusal, never a
    /// truncated scene.
    static let maximumPreviewBytes = 4 * 1024 * 1024
    /// Bounded verified-asset summary for the actual document.
    static let maximumAssetReferences = 64

    var canvasID: UUID
    var canvasRevision: Int64
    var documentID: UUID?
    var nodeID: UUID
    /// EXACT canonical schema-7 Canvas document object, the SAME
    /// `project` shape the existing `canvas.load` envelope returns (not a new
    /// DTO and no re-encoding of UUID dictionaries into another wire shape).
    var canvasDocument: CanvasProject
    /// Bounded, verified metadata for asset references in `document`.
    var assets: [G09R2DesignCanvasSnapshotAsset]
    var assetsTruncated: Bool
    /// Workflow metadata details (brief/spec/candidates) for the design panel.
    var project: DesignProject
}

/// One asset reference in the actual Canvas document, resolved against the
/// SAME creative asset store. `verified` is true only when a real row exists
/// and (when the reference carries a hash) its content hash matches. The App
/// reads bytes through the native host reader using `assetID`, never a path.
struct G09R2DesignCanvasSnapshotAsset: Encodable, Sendable, Equatable {
    var assetID: UUID
    var contentHash: String?
    var kind: String
    var mimeType: String?
    var byteCount: Int64?
    var verified: Bool
}

/// Additive creative-owner route inside `design.owner.state`. Only the
/// host-bound design editor may call the mutation routes; the service
/// additionally requires a registered creative editor session for the exact
/// target. `assets`/`pending` are bounded read-only inventory routes.
public enum G09R2DesignCreativeRouteKind: String, Codable, Sendable {
    case begin
    case bind
    /// Direct bind of a REAL existing retained asset; native reads and verifies
    /// the asset bytes (no payload token, no bridge bytes).
    case bindRetained
    /// Stage-once import into the existing `CreativeAssetStore`, then the same
    /// shared first-result transaction.
    case importBind
    /// Bounded retained-asset metadata page (no bytes, no paths).
    case assets
    /// Bounded pending creative-request page from the SAME owner envelope store.
    case pending
}

public struct G09R2DesignCreativeBeginDTO: Codable, Sendable, Equatable {
    public var brief: DesignBrief?
    public var spec: DesignSpec?

    public init(brief: DesignBrief? = nil, spec: DesignSpec? = nil) {
        self.brief = brief
        self.spec = spec
    }
}

public struct G09R2DesignCreativeBindDTO: Codable, Sendable, Equatable {
    public var boundResultID: String
    public var payload: G09R2StagedDesignPayloadDTO
    public var displayName: String?

    public init(
        boundResultID: String,
        payload: G09R2StagedDesignPayloadDTO,
        displayName: String? = nil
    ) {
        self.boundResultID = boundResultID
        self.payload = payload
        self.displayName = displayName
    }
}

/// Direct retained-asset bind: the asset id is a REAL row in the existing
/// creative library and native reads its verified bytes itself.
public struct G09R2DesignCreativeRetainedBindDTO: Codable, Sendable, Equatable {
    public var boundResultID: String
    public var displayName: String?

    public init(boundResultID: String, displayName: String? = nil) {
        self.boundResultID = boundResultID
        self.displayName = displayName
    }
}

/// SAF/manual staged source imported into the existing creative library before
/// the SAME shared first-result transaction.
public struct G09R2DesignCreativeImportBindDTO: Codable, Sendable, Equatable {
    public var payload: G09R2StagedDesignPayloadDTO
    public var displayName: String?

    public init(
        payload: G09R2StagedDesignPayloadDTO,
        displayName: String? = nil
    ) {
        self.payload = payload
        self.displayName = displayName
    }
}

/// Bounded query. `limit` is clamped to 1...24 and `cursor` is an opaque value
/// from the previous page; a blank/malformed cursor is refused.
public struct G09R2DesignCreativePageQueryDTO: Codable, Sendable, Equatable {
    public var cursor: String?
    public var limit: Int?

    public init(cursor: String? = nil, limit: Int? = nil) {
        self.cursor = cursor
        self.limit = limit
    }
}

public struct G09R2DesignCreativeRouteDTO: Codable, Sendable, Equatable {
    public var kind: G09R2DesignCreativeRouteKind
    public var begin: G09R2DesignCreativeBeginDTO?
    public var bind: G09R2DesignCreativeBindDTO?
    public var bindRetained: G09R2DesignCreativeRetainedBindDTO?
    public var importBind: G09R2DesignCreativeImportBindDTO?
    public var assets: G09R2DesignCreativePageQueryDTO?
    public var pending: G09R2DesignCreativePageQueryDTO?

    public init(
        kind: G09R2DesignCreativeRouteKind,
        begin: G09R2DesignCreativeBeginDTO? = nil,
        bind: G09R2DesignCreativeBindDTO? = nil,
        bindRetained: G09R2DesignCreativeRetainedBindDTO? = nil,
        importBind: G09R2DesignCreativeImportBindDTO? = nil,
        assets: G09R2DesignCreativePageQueryDTO? = nil,
        pending: G09R2DesignCreativePageQueryDTO? = nil
    ) {
        self.kind = kind
        self.begin = begin
        self.bind = bind
        self.bindRetained = bindRetained
        self.importBind = importBind
        self.assets = assets
        self.pending = pending
    }
}

/// Metadata for one real retained creative asset. Bytes and paths never cross
/// the bridge; `selectable` only means the row has a contained Materials path
/// with a usable format extension (the bind still verifies the real bytes).
public struct G09R2DesignCreativeAssetDTO: Codable, Sendable, Equatable {
    public var assetID: String
    public var displayName: String
    public var kind: String
    public var format: String
    public var byteCount: Int64
    public var contentSHA256: String
    public var updatedAt: Date
    public var selectable: Bool

    public init(
        assetID: String, displayName: String, kind: String, format: String,
        byteCount: Int64, contentSHA256: String, updatedAt: Date,
        selectable: Bool
    ) {
        self.assetID = assetID
        self.displayName = displayName
        self.kind = kind
        self.format = format
        self.byteCount = byteCount
        self.contentSHA256 = contentSHA256
        self.updatedAt = updatedAt
        self.selectable = selectable
    }
}

public struct G09R2DesignCreativeAssetPageDTO: Codable, Sendable, Equatable {
    public var assets: [G09R2DesignCreativeAssetDTO]
    public var nextCursor: String?

    public init(
        assets: [G09R2DesignCreativeAssetDTO], nextCursor: String?
    ) {
        self.assets = assets
        self.nextCursor = nextCursor
    }
}

/// One reachable pending creative request. `target` is the exact frozen target
/// identity from the SAME owner envelope store the workflow writes; the App
/// reopens it through the ordinary `bindTarget` with an app-owned storage layer
/// and a fresh editor session. No second request database exists.
public struct G09R2DesignCreativePendingRequestDTO: Codable, Sendable, Equatable {
    public var targetKey: String
    public var ownerRevision: Int64
    public var target: DesignTarget
    public var storage: G09StorageLayerDTO
    public var requestedOutputKind: DesignContentType
    public var state: DesignCreativeRequest.State
    public var boundResultID: String?
    public var boundFormat: String?
    public var boundContentSHA256: String?
    public var originConversationID: String?
    public var environmentID: String?
    public var updatedAt: Date

    public init(
        targetKey: String, ownerRevision: Int64, target: DesignTarget,
        storage: G09StorageLayerDTO, requestedOutputKind: DesignContentType,
        state: DesignCreativeRequest.State, boundResultID: String?,
        boundFormat: String?, boundContentSHA256: String?,
        originConversationID: String?, environmentID: String?,
        updatedAt: Date
    ) {
        self.targetKey = targetKey
        self.ownerRevision = ownerRevision
        self.target = target
        self.storage = storage
        self.requestedOutputKind = requestedOutputKind
        self.state = state
        self.boundResultID = boundResultID
        self.boundFormat = boundFormat
        self.boundContentSHA256 = boundContentSHA256
        self.originConversationID = originConversationID
        self.environmentID = environmentID
        self.updatedAt = updatedAt
    }
}

public struct G09R2DesignCreativePendingPageDTO: Codable, Sendable, Equatable {
    public var requests: [G09R2DesignCreativePendingRequestDTO]
    public var nextCursor: String?

    public init(
        requests: [G09R2DesignCreativePendingRequestDTO], nextCursor: String?
    ) {
        self.requests = requests
        self.nextCursor = nextCursor
    }
}

/// Receipt of the verified staged import + first-result bind. `imported` is
/// true only when this call created the canonical row; false means the content
/// hash already existed and the canonical asset was reused.
public struct G09R2DesignCreativeImportReceiptDTO: Codable, Sendable, Equatable {
    public var state: G09R2DesignStateDTO
    public var asset: G09R2DesignCreativeAssetDTO
    public var imported: Bool

    public init(
        state: G09R2DesignStateDTO, asset: G09R2DesignCreativeAssetDTO,
        imported: Bool
    ) {
        self.state = state
        self.asset = asset
        self.imported = imported
    }
}

/// Typed native entry points for the App host (bridged through the existing
/// `design.owner.state` envelope) and for a future native model tool host.
/// `runID` is a HOST-supplied execution identity, never decoded from model
/// JSON. `trustedUI` is only valid for a registered design editor session.
public struct G09R2DesignCreativeBeginRequest: Sendable {
    public var binding: G09R2DesignBindingDTO
    public var expectedRevision: Int64?
    public var opID: String
    public var brief: DesignBrief?
    public var spec: DesignSpec?

    public init(
        binding: G09R2DesignBindingDTO,
        expectedRevision: Int64? = nil,
        opID: String,
        brief: DesignBrief? = nil,
        spec: DesignSpec? = nil
    ) {
        self.binding = binding
        self.expectedRevision = expectedRevision
        self.opID = opID
        self.brief = brief
        self.spec = spec
    }
}

public struct G09R2DesignCreativeBindRequest: Sendable {
    public var binding: G09R2DesignBindingDTO
    public var expectedRevision: Int64
    public var opID: String
    public var boundResultID: String
    public var payload: G09R2StagedDesignPayloadDTO
    public var displayName: String?

    public init(
        binding: G09R2DesignBindingDTO,
        expectedRevision: Int64,
        opID: String,
        boundResultID: String,
        payload: G09R2StagedDesignPayloadDTO,
        displayName: String? = nil
    ) {
        self.binding = binding
        self.expectedRevision = expectedRevision
        self.opID = opID
        self.boundResultID = boundResultID
        self.payload = payload
        self.displayName = displayName
    }
}

/// Direct bind of an EXISTING retained creative asset: native reads and
/// verifies the asset bytes itself, so no payload token or bridge bytes are
/// accepted from the host.
public struct G09R2DesignCreativeRetainedBindRequest: Sendable {
    public var binding: G09R2DesignBindingDTO
    public var expectedRevision: Int64
    public var opID: String
    public var boundResultID: String
    public var displayName: String?

    public init(
        binding: G09R2DesignBindingDTO,
        expectedRevision: Int64,
        opID: String,
        boundResultID: String,
        displayName: String? = nil
    ) {
        self.binding = binding
        self.expectedRevision = expectedRevision
        self.opID = opID
        self.boundResultID = boundResultID
        self.displayName = displayName
    }
}

/// Import a staged SAF/manual source into the existing creative library, then
/// bind the resulting canonical asset through the same shared transaction.
public struct G09R2DesignCreativeImportBindRequest: Sendable {
    public var binding: G09R2DesignBindingDTO
    public var expectedRevision: Int64
    public var opID: String
    public var payload: G09R2StagedDesignPayloadDTO
    public var displayName: String?

    public init(
        binding: G09R2DesignBindingDTO,
        expectedRevision: Int64,
        opID: String,
        payload: G09R2StagedDesignPayloadDTO,
        displayName: String? = nil
    ) {
        self.binding = binding
        self.expectedRevision = expectedRevision
        self.opID = opID
        self.payload = payload
        self.displayName = displayName
    }
}
