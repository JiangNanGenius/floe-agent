import Foundation

// FloeCore — Typed stable targets for the shared design workflow.
//
// A design run can start from more than a Canvas node: an existing Canvas
// node, a file the workspace is authorized to read, the original attachment
// of a chat task, or the existing creative-mode creation target. `DesignTarget`
// is the frozen, typed identity every later stage (freeze input, propose,
// adopt, export) addresses. It is intentionally a VALUE with opaque string
// ids — the storage layer must never treat an id (or a model-supplied
// absolute path) as authority. Only a registered `DesignOwnerAdapter` can
// resolve a target, and it re-derives permission/containment from the live
// owner services on every call.
//
// Invariants:
// - The discriminator (`kind`) never changes after freeze.
// - The identity is stable and hashable; `stableKey` canonicalizes it.
// - Canvas update always addresses the SAME node; the chat original
//   attachment is read-only and the adopted result belongs to the ORIGINAL
//   task; creative start uses the existing creation target (no new primary
//   workspace, no hidden canvas).
// - Arbitrary absolute paths are never accepted as a file target: the file
//   adapter only resolves workspace-scoped references through its port.

public enum DesignTargetKind: String, Codable, Sendable, CaseIterable {
    /// An existing Canvas node (`ownerID` = canvas UUID, `documentID` =
    /// canvas document UUID, `sourceID` = node UUID). Retained adapter.
    case canvasNode
    /// A workspace-permission-scoped file document (`ownerID` = workspace
    /// identity, `sourceID` = a workspace-relative/owned reference — never
    /// an arbitrary absolute path).
    case fileDocument
    /// The original attachment of the originating chat task
    /// (`ownerID` = conversation UUID, `documentID` = message UUID,
    /// `sourceID` = attachment reference). Read-only source.
    case chatAttachment
    /// The existing creative-mode creation target (`ownerID` = creative
    /// workspace/owner identity, `sourceID` = creation identifier).
    case creativeDocument
}

extension DesignContentType {
    /// Derives the CANDIDATE content family from a verified format
    /// extension. Returns nil for unrecognized formats: callers must fail
    /// or ask explicitly rather than silently treating every foreign file
    /// as a webpage. This mapping classifies bytes for routing only — it
    /// does NOT prove the bytes parse or are editable in that family.
    /// Editable claims require the owner adapter's real reopen
    /// verification (image decode, PDFKit, OOXML package, CAD reparse,
    /// bounded SVG parse), exactly as the Canvas design adapters enforce.
    public static func from(format rawFormat: String) -> DesignContentType? {
        let format = rawFormat.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch format {
        case "md", "markdown", "txt":
            return .notes
        case "html", "htm", "svg", "json":
            return .webpage
        case "png", "jpg", "jpeg", "webp", "gif", "heic", "heif", "tiff":
            return .image
        case "mp4", "mov", "m4v", "webm":
            return .video
        case "pdf":
            return .pdf
        case "docx", "doc", "xlsx", "xls", "csv", "odt", "ods":
            return .officeDocument
        case "pptx", "ppt", "odp", "key":
            return .presentation
        case "floecad", "dwg", "dxf", "step", "stp", "stl", "obj",
             "3mf", "glb", "gltf", "usdz", "usd":
            return .cad
        default:
            return nil
        }
    }
}

public enum DesignTargetError: Error, Equatable {
    /// No registered owner adapter can resolve this kind.
    case unsupportedKind(String)
    /// The adapter declined: the caller is not allowed to read the source
    /// through the live workspace permissions.
    case notAuthorized(String)
    /// The referenced source no longer exists (deleted canvas node/file).
    case notFound(String)
    /// A caller attempted to construct/resolve a file target from an
    /// absolute or traversing path; such strings are never authority.
    case invalidReference(String)
    /// The resolved bytes failed verification (empty/digest mismatch).
    case unverifiable(String)
    /// The operation is not connected for this target; the string is the
    /// honest reason surfaced by the capability registry.
    case unavailable(String)
    /// The target's frozen base moved. `frozen` is the token captured at
    /// freeze time; `actual` is what the owner holds now.
    case moved(frozen: String, actual: String)
    /// A creative start request exists but its first REAL result has not
    /// been generated/bound yet. The string is the requested output kind.
    case pendingFirstResult(String)
    /// The creative request already bound its first real result; further
    /// edits go through the ordinary revision/candidate flow.
    case firstResultAlreadyBound(String)
}

/// A frozen, typed design target. All IDs are strings on purpose: chat and
/// workspace identities are not Canvas UUIDs and must not be coerced into
/// UUIDs to fit the canvas authority.
public struct DesignTarget: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let kind: DesignTargetKind
    /// Owning container: canvas UUID / workspace id / conversation UUID /
    /// creative owner id.
    public let ownerID: String
    /// Containing document: canvas document UUID / file document id /
    /// chat message id. Empty when the owner kind has no document layer.
    public let documentID: String
    /// Source identifier inside the document: node UUID / workspace file
    /// reference / attachment reference / creation id.
    public let sourceID: String
    /// Explicit environment identity when the source lives in one.
    public let environmentID: String?
    /// Frozen base-revision token captured at freeze time. It is compared
    /// on every later mutation; a mismatch is `DesignTargetError.moved`.
    public let revision: String?
    /// The originating task when the target was started from chat. The
    /// adopted result is delivered ONLY to this conversation.
    public let originConversationID: String?
    /// For a not-yet-materialized creative request: the explicitly requested
    /// output kind. Part of the frozen request identity (changing it is a
    /// different request), never a fallback webpage guess. nil for sources
    /// that already carry real bytes.
    public let requestedOutputKind: DesignContentType?

    public init(
        kind: DesignTargetKind,
        ownerID: String,
        documentID: String = "",
        sourceID: String,
        environmentID: String? = nil,
        revision: String? = nil,
        originConversationID: String? = nil,
        requestedOutputKind: DesignContentType? = nil
    ) {
        self.kind = kind
        // Opaque owner/document/source ids are stored EXACTLY as supplied:
        // workspace and creative ids can be case-sensitive tokens. UUID
        // normalization happens only at the point a host adapter parses one
        // (UUID(uuidString:) is case-insensitive), never globally here.
        self.ownerID = ownerID
        self.documentID = documentID
        self.sourceID = sourceID
        self.environmentID = environmentID
        self.revision = revision
        self.originConversationID = originConversationID
        self.requestedOutputKind = requestedOutputKind
    }

    /// Stable identity used for Identifiable conformance and UI identity.
    /// This is the length-prefixed canonical identity — never the raw colon
    /// display string, which can alias distinct id/path combinations and
    /// would make SwiftUI merge unrelated targets.
    public var id: String { stableKey }

    /// Human-readable colon form for logs/UI only. Never a dedupe key.
    public var displayID: String {
        [kind.rawValue, ownerID, documentID, sourceID].joined(separator: ":")
    }

    /// Canonical SOURCE identity over kind/owner/document/source/environment.
    /// The originating task is deliberately EXCLUDED: the same authorized
    /// workspace file opened directly and from different tasks is ONE
    /// source with ONE design history; task attribution lives on frozen
    /// requests, candidates and decision intents (never on store identity).
    /// Each field is length-prefixed (`<count>:<value>`) so no id/path
    /// combination can collide with another, and the encoding is versioned
    /// so a future change is detectable.
    public var sourceIdentity: String {
        Self.encodeIdentity(
            version: 2,
            fields: [
                kind.rawValue, ownerID, documentID, sourceID,
                environmentID ?? "",
                requestedOutputKind?.rawValue ?? ""
            ]
        )
    }

    /// SHA-256 over `sourceIdentity`: the store/envelope/UI identity key.
    /// Stable across originating tasks for the same source.
    public var stableKey: String {
        FloeDigest.sha256Hex(Data(sourceIdentity.utf8))
    }

    /// Unambiguous length-prefixed encoding: `v<version>` followed by
    /// `<utf8-count>:<value>` per field. This is the ONLY identity encoding
    /// decision logic may rely on — never raw separator concatenation.
    static func encodeIdentity(version: Int, fields: [String]) -> String {
        var out = "v\(version)"
        for field in fields {
            out += "|\(field.utf8.count):\(field)"
        }
        return out
    }

    /// Same concrete source, regardless of frozen revision/origin extras.
    /// The environment participates: the same owner/reference in different
    /// environments are distinct sources and must never alias.
    public func isSameSource(as other: DesignTarget) -> Bool {
        kind == other.kind && ownerID == other.ownerID
            && documentID == other.documentID && sourceID == other.sourceID
            && (environmentID ?? "") == (other.environmentID ?? "")
            && requestedOutputKind == other.requestedOutputKind
    }

    /// Returns the target with a frozen revision token (freeze).
    public func freezing(revision: String?) -> DesignTarget {
        DesignTarget(
            kind: kind, ownerID: ownerID, documentID: documentID,
            sourceID: sourceID, environmentID: environmentID,
            revision: revision, originConversationID: originConversationID,
            requestedOutputKind: requestedOutputKind
        )
    }
}

/// Verified source content handed to later stages. This is the ONLY object a
/// frozen target resolves to: bytes stay hash-verified and the provenance
/// fields are filled by the owner adapter from live services.
public struct DesignResolvedSource: Sendable, Equatable {
    public let target: DesignTarget
    public let data: Data
    /// Real format of the bytes (extension, lowercased), e.g. "png"/"docx".
    public let format: String
    public let displayName: String
    public let contentSHA256: String
    /// Current owner-side revision token at resolve time.
    public let baseRevisionToken: String
    /// Read-only sources (chat attachment) can never be updated in place.
    public let allowsInPlaceUpdate: Bool
    /// The originating task, when the source carries one.
    public let originConversationID: String?
    /// Real content family of the resolved bytes. Canvas sources take it
    /// from the bound subdocument/node mapping; file/chat/creative sources
    /// derive it from the verified format. Never guessed as a catch-all
    /// webpage type.
    public let contentType: DesignContentType
    /// Canvas coordinates, present ONLY for canvas-node sources.
    public let canvas: CanvasCoordinates?

    public struct CanvasCoordinates: Sendable, Equatable {
        public let canvasID: UUID
        public let documentID: UUID?
        public let nodeID: UUID

        public init(canvasID: UUID, documentID: UUID?, nodeID: UUID) {
            self.canvasID = canvasID
            self.documentID = documentID
            self.nodeID = nodeID
        }
    }

    public init(
        target: DesignTarget,
        data: Data,
        format: String,
        displayName: String,
        contentSHA256: String,
        baseRevisionToken: String,
        allowsInPlaceUpdate: Bool,
        originConversationID: String? = nil,
        contentType: DesignContentType,
        canvas: CanvasCoordinates? = nil
    ) {
        self.target = target
        self.data = data
        self.format = format
        self.displayName = displayName
        self.contentSHA256 = contentSHA256
        self.baseRevisionToken = baseRevisionToken
        self.allowsInPlaceUpdate = allowsInPlaceUpdate
        self.originConversationID = originConversationID
        self.contentType = contentType
        self.canvas = canvas
    }
}

/// Result of a capability/existence probe without reading bytes.
public struct DesignTargetProbe: Sendable, Equatable {
    public let target: DesignTarget
    public let exists: Bool
    public let contains: Bool
    public let currentRevisionToken: String?
    public let format: String?
    /// Reason the target cannot be used, when any (honest capability text).
    public let unavailableReason: String?

    public init(
        target: DesignTarget,
        exists: Bool,
        contains: Bool,
        currentRevisionToken: String?,
        format: String?,
        unavailableReason: String?
    ) {
        self.target = target
        self.exists = exists
        self.contains = contains
        self.currentRevisionToken = currentRevisionToken
        self.format = format
        self.unavailableReason = unavailableReason
    }
}
