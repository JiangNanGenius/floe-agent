import Foundation

// FloeCore — Design workflow domain model.
//
// The approved design flow is: brief → design spec/template → generate/import →
// edit/preview → anchored feedback → revision-bound candidate → compare/adopt →
// verified export. The Canvas project graph keeps owning layout/connections;
// specialized editors own the content edits. This model is the shared,
// deterministic state machine both the UI and the agent tools drive, so every
// stage is auditable and recovery-safe:
//
// - Inputs are frozen per run (`DesignRunFrozen`): the exact input revision, spec
//   hash, target revision and operation ID.
// - AI proposals are `DesignCandidate`s until the user adopts them.
// - Adopting updates the original node by default (name/position/size/connections
//   preserved via `DesignArtifactIdentity`); an explicit variant creates a branch.
// - Feedback is anchored to a specific artifact revision plus region/time/page or
//   stable object ID; changing the revision makes older anchors stale until they
//   are explicitly relocated.
// - Revisions are append-only and restorable (drafts/history recoverable).

public enum DesignContentType: String, Codable, Sendable, CaseIterable {
    case webpage
    case prototype
    case presentation
    case image
    case video
    case officeDocument
    case notes
    case pdf
    case cad
    /// A Canvas layout/composition object (shape/group/card/audio/generation
    /// task). This is deliberately NOT `webpage`: an ordinary Canvas node has
    /// no verified web bytes, and pretending otherwise would offer web
    /// generation/editing for a layout object. Only verified HTML/SVG
    /// built-in source plugins freeze/adopt as real webpage content.
    case composition
}

/// Project (canvas) level brief/spec authority. Stored ON the CanvasProject
/// itself — not a parallel store — so every update commits through the same
/// Canvas revision CAS. The full-payload identity is a SHA-256 over the
/// canonical encoded payload: a later apply of a DIFFERENT payload has a
/// different identity and is never deduped against an older one, while an
/// exact replay is an idempotent no-op. Nodes that inherit are recorded so
/// unrelated node edits can never change which payload is authoritative.
public struct DesignProjectAuthority: Codable, Sendable, Equatable, Hashable {
    public var brief: DesignBrief?
    public var spec: DesignSpec?
    /// Full-payload identity: SHA-256 over the canonical brief+spec payload.
    public var contentSHA256: String
    public var updatedAt: Date
    /// Bounded project-level replay keys: operationID → full-payload identity.
    /// A replayed operation whose identity differs is a changed request and
    /// must be rejected, never silently deduped against the old payload.
    public var appliedOperations: [String: String]
    /// Nodes whose design subdocument carries this exact payload.
    public var inheritedNodeIDs: [String]

    public init(
        brief: DesignBrief? = nil,
        spec: DesignSpec? = nil,
        contentSHA256: String,
        updatedAt: Date = Date(),
        appliedOperations: [String: String] = [:],
        inheritedNodeIDs: [String] = []
    ) {
        self.brief = brief
        self.spec = spec
        self.contentSHA256 = contentSHA256
        self.updatedAt = updatedAt
        self.appliedOperations = appliedOperations
        self.inheritedNodeIDs = inheritedNodeIDs
    }

    /// Canonical full-payload identity. The identity covers every field a
    /// node would inherit (brief + the complete spec, including rawMarkdown),
    /// so "same operationID, different payload" can never replay the old one.
    public static func identity(brief: DesignBrief?, spec: DesignSpec?) -> String {
        struct Payload: Codable {
            let goal: String?
            let audience: String?
            let constraints: [String]
            let palette: [String]?
            let typography: String?
            let layout: String?
            let spacing: String?
            let brandAssetRefs: [String]?
            let voice: String?
            let prohibitions: [String]?
            let rawMarkdown: String?
        }
        let payload = Payload(
            goal: brief?.goal,
            audience: brief?.audience,
            constraints: brief?.constraints ?? [],
            palette: spec?.palette,
            typography: spec?.typography,
            layout: spec?.layout,
            spacing: spec?.spacing,
            brandAssetRefs: spec?.brandAssetRefs,
            voice: spec?.voice,
            prohibitions: spec?.prohibitions,
            rawMarkdown: spec?.rawMarkdown
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(payload)) ?? Data()
        return FloeDigest.sha256Hex(data)
    }
}

/// The brief stage: the user's goal, audience and constraints.
public struct DesignBrief: Codable, Sendable, Equatable, Hashable {
    public var goal: String
    public var audience: String?
    public var constraints: [String]
    public var createdAt: Date

    public init(goal: String, audience: String? = nil, constraints: [String] = [], createdAt: Date = Date()) {
        self.goal = goal
        self.audience = audience
        self.constraints = constraints
        self.createdAt = createdAt
    }
}

/// Optional design spec. Only the values the user/template actually set are
/// stored; everything else stays nil so the UI can omit it and so a spec can be
/// exported as human-editable DESIGN.md without inventing empty sections.
public struct DesignSpec: Codable, Sendable, Equatable, Hashable {
    public var palette: [String]?
    public var typography: String?
    public var layout: String?
    public var spacing: String?
    public var brandAssetRefs: [String]?
    public var voice: String?
    public var prohibitions: [String]?
    /// The raw DESIGN.md text as imported/edited. Unknown sections are preserved
    /// verbatim on round-trip; Floe never rewrites or drops them.
    public var rawMarkdown: String?

    public init(
        palette: [String]? = nil,
        typography: String? = nil,
        layout: String? = nil,
        spacing: String? = nil,
        brandAssetRefs: [String]? = nil,
        voice: String? = nil,
        prohibitions: [String]? = nil,
        rawMarkdown: String? = nil
    ) {
        self.palette = palette
        self.typography = typography
        self.layout = layout
        self.spacing = spacing
        self.brandAssetRefs = brandAssetRefs
        self.voice = voice
        self.prohibitions = prohibitions
        self.rawMarkdown = rawMarkdown
    }

    public var isEmpty: Bool {
        palette == nil && typography == nil && layout == nil && spacing == nil
            && brandAssetRefs == nil && voice == nil && prohibitions == nil
            && (rawMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// Canonical hash used to freeze the spec for a run.
    public var sha256: String { DesignMDCodec.sha256(of: self) }
}

/// Honest template descriptor. Capabilities list only what the template truly
/// supports; `rollbackVersion` records the version this was updated from so an
/// update can be rolled back. User templates are independent and survive app
/// upgrades; installed templates are versioned by the signed content service.
public struct DesignTemplateManifest: Codable, Sendable, Equatable, Identifiable {
    public enum Origin: String, Codable, Sendable {
        case user
        case signedContent
        case builtIn
    }

    public var id: String
    public var name: String
    public var contentType: DesignContentType
    /// Real capabilities this template can produce (e.g. "responsive layout").
    public var capabilities: [String]
    /// Required inputs the user must supply before generation.
    public var inputs: [String]
    /// External dependencies (models/providers/services) that must be connected.
    public var dependencies: [String]
    public var outputFormats: [String]
    public var license: String
    public var source: String
    public var version: String
    public var contentSHA256: String
    /// Version this template was last updated from, when applicable.
    public var rollbackVersion: String?
    public var rollbackContentSHA256: String?
    public var origin: Origin

    public init(
        id: String,
        name: String,
        contentType: DesignContentType,
        capabilities: [String],
        inputs: [String],
        dependencies: [String],
        outputFormats: [String],
        license: String,
        source: String,
        version: String,
        contentSHA256: String,
        rollbackVersion: String? = nil,
        rollbackContentSHA256: String? = nil,
        origin: Origin
    ) {
        self.id = id
        self.name = name
        self.contentType = contentType
        self.capabilities = capabilities
        self.inputs = inputs
        self.dependencies = dependencies
        self.outputFormats = outputFormats
        self.license = license
        self.source = source
        self.version = version
        self.contentSHA256 = contentSHA256
        self.rollbackVersion = rollbackVersion
        self.rollbackContentSHA256 = rollbackContentSHA256
        self.origin = origin
    }
}

/// Inputs frozen for one generation/edit run. Later edits/regeneration must not
/// silently change what a run was based on.
public struct DesignRunFrozen: Codable, Sendable, Equatable {
    public var operationID: String
    public var inputRevisionID: String?
    public var specSHA256: String?
    public var targetRevisionID: String?
    /// The ACTUAL desired output format frozen with the run (e.g. "pptx"),
    /// when the run was started from a typed work intent. Optional so runs
    /// frozen before this field decode unchanged.
    public var desiredFormat: String?
    /// Work mode frozen with the run when it was started from a typed work
    /// intent (nil for legacy runs: mode-agnostic modify work).
    public var workMode: DesignWorkMode?
    /// Digest of the preservation constraints whose trusted claim was
    /// verified by the freeze-before-generation seam for a restructure run.
    /// nil for create/modify and for legacy runs.
    public var preservationDigest: String?
    public var frozenAt: Date

    public init(
        operationID: String,
        inputRevisionID: String? = nil,
        specSHA256: String? = nil,
        targetRevisionID: String? = nil,
        desiredFormat: String? = nil,
        workMode: DesignWorkMode? = nil,
        preservationDigest: String? = nil,
        frozenAt: Date = Date()
    ) {
        self.operationID = operationID
        self.inputRevisionID = inputRevisionID
        self.specSHA256 = specSHA256
        self.targetRevisionID = targetRevisionID
        self.desiredFormat = desiredFormat
        self.workMode = workMode
        self.preservationDigest = preservationDigest
        self.frozenAt = frozenAt
    }
}

/// Node identity that must survive an "update original" adoption. Canvas owns
/// these values; the design engine only preserves them.
public struct DesignArtifactIdentity: Codable, Sendable, Equatable {
    public var name: String
    public var positionX: Double
    public var positionY: Double
    public var width: Double
    public var height: Double
    public var connections: [String]

    public init(name: String, positionX: Double, positionY: Double, width: Double, height: Double, connections: [String] = []) {
        self.name = name
        self.positionX = positionX
        self.positionY = positionY
        self.width = width
        self.height = height
        self.connections = connections
    }
}

/// Where a revision came from. `adopt` is a user adoption of a candidate;
/// `restore` recovers a previous revision from history.
public enum DesignRevisionOrigin: String, Codable, Sendable {
    case importFile
    case generate
    case edit
    case adopt
    case restore
    case variant
    /// Frozen from content that already exists on the Canvas node (text,
    /// retained asset bytes, CAD/Office workspace document) without an
    /// external export/reimport.
    case currentNode

    /// Capture-as-revision: bytes frozen from EXISTING content (a file/Chat
    /// import or the current node). A capture is never reported as
    /// generation — e.g. capturing a webpage into a revision must not be
    /// presented as "made a webpage".
    public var isCapture: Bool {
        switch self {
        case .importFile, .currentNode: return true
        case .generate, .edit, .adopt, .restore, .variant: return false
        }
    }

    /// An actual generation/edit produced new candidate content (as opposed
    /// to capturing or re-pointing at existing bytes).
    public var isGeneration: Bool {
        switch self {
        case .generate: return true
        case .importFile, .currentNode, .edit, .adopt, .restore, .variant: return false
        }
    }
}

public struct DesignRevision: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var artifactID: String
    public var number: Int
    /// SHA-256 of the revision's content bytes. Comparing hashes is what makes
    /// "an actual change happened" verifiable rather than trusting model text.
    public var contentSHA256: String
    public var origin: DesignRevisionOrigin
    public var parentRevisionID: String?
    public var createdAt: Date
    /// Relative app-storage path of the revision's payload, when persisted.
    public var payloadRelativePath: String?
    /// The real content format of the payload bytes (e.g. "png", "pdf"), used
    /// to choose the actual reopen parser on export. Optional so revisions
    /// written before this field decode unchanged.
    public var payloadFormat: String?
    /// Owner-side frozen base token (e.g. the workspace
    /// "workspace:<id>:sha:<hex>:mtime:<n>" token) captured when this
    /// revision became the adoptable base of an in-place owner. Recorded so
    /// a later adoption can re-gate the commit on the FROZEN digest even
    /// when the caller addresses the target without a revision token.
    /// Optional so revisions written before this field decode unchanged.
    public var ownerBaseToken: String?

    public init(
        id: String = UUID().uuidString.lowercased(),
        artifactID: String,
        number: Int,
        contentSHA256: String,
        origin: DesignRevisionOrigin,
        parentRevisionID: String? = nil,
        createdAt: Date = Date(),
        payloadRelativePath: String? = nil,
        payloadFormat: String? = nil,
        ownerBaseToken: String? = nil
    ) {
        self.id = id
        self.artifactID = artifactID
        self.number = number
        self.contentSHA256 = contentSHA256
        self.origin = origin
        self.parentRevisionID = parentRevisionID
        self.createdAt = createdAt
        self.payloadRelativePath = payloadRelativePath
        self.payloadFormat = payloadFormat
        self.ownerBaseToken = ownerBaseToken
    }
}

/// A design artifact (one canvas node's editable content) and its revision
/// history. The Canvas node keeps layout; this owns revisions.
public struct DesignArtifact: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var contentType: DesignContentType
    /// The Canvas node this artifact is bound to, when any. Canvas owns the
    /// node's layout; the design engine owns its content revisions.
    public var canvasNodeID: String?
    public var identity: DesignArtifactIdentity
    public var currentRevisionID: String?
    public var revisions: [DesignRevision]
    /// Explicit branch points created by variant adoption: candidate revision →
    /// new artifact ID.
    public var branches: [String: String]

    public init(
        id: String = UUID().uuidString.lowercased(),
        contentType: DesignContentType,
        canvasNodeID: String? = nil,
        identity: DesignArtifactIdentity
    ) {
        self.id = id
        self.contentType = contentType
        self.canvasNodeID = canvasNodeID
        self.identity = identity
        self.currentRevisionID = nil
        self.revisions = []
        self.branches = [:]
    }

    public var currentRevision: DesignRevision? {
        guard let currentRevisionID else { return nil }
        return revisions.first { $0.id == currentRevisionID }
    }

    public func revision(_ id: String) -> DesignRevision? {
        revisions.first { $0.id == id }
    }

    /// Unknown nested keys preserved verbatim across migrations.
    public var unknownFields: [String: DesignJSONValue] = [:]

    private enum CodingKeys: String, CodingKey {
        case id, contentType, canvasNodeID, identity, currentRevisionID
        case revisions, branches
    }

    static let artifactKnownFields: Set<String> = [
        "id", "contentType", "canvasNodeID", "identity",
        "currentRevisionID", "revisions", "branches"
    ]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        contentType = try c.decodeIfPresent(DesignContentType.self, forKey: .contentType) ?? .webpage
        canvasNodeID = try c.decodeIfPresent(String.self, forKey: .canvasNodeID)
        identity = try c.decode(DesignArtifactIdentity.self, forKey: .identity)
        currentRevisionID = try c.decodeIfPresent(String.self, forKey: .currentRevisionID)
        revisions = try c.decodeIfPresent([DesignRevision].self, forKey: .revisions) ?? []
        branches = try c.decodeIfPresent([String: String].self, forKey: .branches) ?? [:]
        unknownFields = try DesignUnknownPreservation.capture(
            decoder: decoder, known: Self.artifactKnownFields
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(contentType, forKey: .contentType)
        try c.encodeIfPresent(canvasNodeID, forKey: .canvasNodeID)
        try c.encode(identity, forKey: .identity)
        try c.encodeIfPresent(currentRevisionID, forKey: .currentRevisionID)
        try c.encode(revisions, forKey: .revisions)
        try c.encode(branches, forKey: .branches)
        try DesignUnknownPreservation.write(unknownFields, to: encoder)
    }
}

/// Anchored feedback. The anchor is bound to one artifact revision plus at most
/// one locator (region/time/page/stable object ID). When the artifact's current
/// revision no longer matches, the anchor is stale and must be explicitly
/// relocated before the feedback can be resolved.
public enum DesignFeedbackAnchor: Codable, Sendable, Equatable {
    case region(x: Double, y: Double, width: Double, height: Double)
    case time(seconds: Double)
    case page(index: Int)
    case objectID(String)

    public var kind: String {
        switch self {
        case .region: return "region"
        case .time: return "time"
        case .page: return "page"
        case .objectID: return "object"
        }
    }
}

public enum DesignFeedbackStatus: String, Codable, Sendable {
    case open
    case solved
    /// The bound revision moved; the anchor must be relocated first.
    case staleAnchor
    case dismissed
}

public enum DesignFeedbackAuthor: String, Codable, Sendable {
    case user
    case ai
}

public struct DesignFeedback: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var artifactID: String
    /// Artifact revision this anchor was placed against.
    public var revisionID: String
    public var anchor: DesignFeedbackAnchor
    public var comment: String
    public var author: DesignFeedbackAuthor
    public var status: DesignFeedbackStatus
    public var createdAt: Date
    /// Revision whose actual change resolved this feedback (never model text).
    public var resolvedByRevisionID: String?

    public init(
        id: String = UUID().uuidString.lowercased(),
        artifactID: String,
        revisionID: String,
        anchor: DesignFeedbackAnchor,
        comment: String,
        author: DesignFeedbackAuthor,
        status: DesignFeedbackStatus = .open,
        createdAt: Date = Date(),
        resolvedByRevisionID: String? = nil
    ) {
        self.id = id
        self.artifactID = artifactID
        self.revisionID = revisionID
        self.anchor = anchor
        self.comment = comment
        self.author = author
        self.status = status
        self.createdAt = createdAt
        self.resolvedByRevisionID = resolvedByRevisionID
    }
}

public enum DesignCandidateStatus: String, Codable, Sendable {
    case pending
    case adopted
    case rejected
    case superseded
}

/// An AI proposal. It stays a candidate until the user explicitly adopts it.
public struct DesignCandidate: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var artifactID: String
    public var baseRevisionID: String
    public var proposedRevisionID: String
    public var feedbackIDs: [String]
    public var summary: String
    /// Human-readable diff lines for compare (from the shared diff helpers).
    public var diff: [String]
    public var status: DesignCandidateStatus
    public var createdAt: Date
    public var resolvedAt: Date?
    /// Artifact created by an explicit variant adoption, when chosen.
    public var variantArtifactID: String?
    /// Originating task persisted at PROPOSAL time; durable notices go here
    /// — never the currently selected conversation. Optional so candidates
    /// written before this field decode unchanged.
    public var originConversationID: String?
    /// Originating environment/container identity, when any.
    public var originEnvironmentID: String?
    /// Idempotency record: the `operationID` that created this candidate. A
    /// repeated `propose` carrying this operationID returns THIS candidate
    /// (and its recorded payload) when every semantic input matches, and
    /// fails `replayMismatch` otherwise. Optional so candidates written
    /// before the record decode unchanged; an applied operation without a
    /// record replays fail-closed rather than guessing.
    public var proposalOperationID: String?
    /// Canonical SHA-256 over the proposal's exact semantic inputs
    /// (artifact, resolved base revision, payload format, content digest,
    /// summary, diff, feedback ids and origin). Guards replay against
    /// changed bytes/format/artifact/base/summary/feedback/origin.
    public var proposalFingerprint: String?
    /// The work mode this proposal belongs to, when it was created from a
    /// typed work intent. Optional so candidates written before this field
    /// decode unchanged (legacy candidates are mode-agnostic modify work).
    public var workMode: DesignWorkMode?
    /// Digest of the preservation constraints confirmed for a restructure
    /// proposal (`DesignPreservationConstraints.canonicalDigest`). nil for
    /// create/modify. A restructure candidate ALWAYS carries both this and a
    /// valid confirmation was required at propose time.
    public var preservationDigest: String?

    public init(
        id: String = UUID().uuidString.lowercased(),
        artifactID: String,
        baseRevisionID: String,
        proposedRevisionID: String,
        feedbackIDs: [String] = [],
        summary: String,
        diff: [String] = [],
        status: DesignCandidateStatus = .pending,
        createdAt: Date = Date(),
        resolvedAt: Date? = nil,
        variantArtifactID: String? = nil,
        originConversationID: String? = nil,
        originEnvironmentID: String? = nil,
        proposalOperationID: String? = nil,
        proposalFingerprint: String? = nil,
        workMode: DesignWorkMode? = nil,
        preservationDigest: String? = nil
    ) {
        self.id = id
        self.artifactID = artifactID
        self.baseRevisionID = baseRevisionID
        self.proposedRevisionID = proposedRevisionID
        self.feedbackIDs = feedbackIDs
        self.summary = summary
        self.diff = diff
        self.status = status
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
        self.variantArtifactID = variantArtifactID
        self.originConversationID = originConversationID
        self.originEnvironmentID = originEnvironmentID
        self.proposalOperationID = proposalOperationID
        self.proposalFingerprint = proposalFingerprint
        self.workMode = workMode
        self.preservationDigest = preservationDigest
    }
}

public enum DesignAdoptMode: String, Codable, Sendable {
    /// Update the original node, retaining name/position/size/connections.
    case updateOriginal
    /// Create a branch (new artifact) and keep the original untouched.
    case variant
}

/// A creative START request that exists BEFORE any material does. The user
/// fills the requested output kind + brief/spec and the shared design state
/// persists them; the first REAL generated result is later bound to this
/// exact target (same envelope). This is metadata-stage capability only: it
/// never fabricates bytes, never creates a hidden canvas and never reports
/// the request as a webpage.
public struct DesignCreativeRequest: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        /// Requirements/spec saved; no result generated yet.
        case awaitingFirstResult
        /// The first real result is bound to this request's target.
        case firstResultBound
    }

    /// Explicitly requested output kind (from the approved creation flow).
    public var requestedKind: DesignContentType
    public var state: State
    /// The owner-side binding recorded when the first result materialized
    /// (creation/asset identity; opaque string).
    public var boundResultID: String?
    public var boundFormat: String?
    public var boundContentSHA256: String?
    public var originConversationID: String?
    public var environmentID: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        requestedKind: DesignContentType,
        state: State = .awaitingFirstResult,
        boundResultID: String? = nil,
        boundFormat: String? = nil,
        boundContentSHA256: String? = nil,
        originConversationID: String? = nil,
        environmentID: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.requestedKind = requestedKind
        self.state = state
        self.boundResultID = boundResultID
        self.boundFormat = boundFormat
        self.boundContentSHA256 = boundContentSHA256
        self.originConversationID = originConversationID
        self.environmentID = environmentID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// The three approved work modes (制作/修改/重构). A request names exactly
/// one; mode transitions keep the current artifact and constraints instead
/// of restarting another task.
public enum DesignWorkMode: String, Codable, Sendable, CaseIterable {
    /// 制作: create a NEW real, editable result in its own target. No
    /// mandatory audience/form gate; missing substantive input is asked in
    /// the conversation, not enforced by a requirements form.
    case create
    /// 修改: scoped, reversible edits inside the frozen base. Content outside
    /// the scope is preserved; "优化一下" of a local region is modify, not a
    /// rebuild.
    case modify
    /// 重构: structural reorganization (narrative order, layout system,
    /// document structure). Requires explicit preservation constraints
    /// confirmed by the trusted UI BEFORE any mutation; the model can never
    /// mint that confirmation.
    case restructure
}

// MARK: - Work intent (frozen typed request contract)

/// Typed failure of a `DesignWorkIntent` validation. Distinct from
/// `DesignWorkflowError` so conversational creators can ask for the missing
/// piece instead of surfacing a generic conflict.
public enum DesignWorkIntentError: Error, Equatable {
    /// 重构 without a trusted preservation confirmation (or with one whose
    /// digest does not match its constraints).
    case preservationConfirmationRequired
    case preservationConfirmationInvalid(String)
    /// Scope locators are malformed (negative page, empty object id, an
    /// inverted time range...).
    case invalidScope(String)
    /// `actualDesiredFormat` does not map to the artifact's content family:
    /// a desired format is a real routing decision, never a guess.
    case formatFamilyMismatch(format: String, family: DesignContentType)
}

/// Exact scope of a modify/restructure request: the user points at a real
/// object/page/time range/region and the operation must address exactly that.
/// An empty scope means the whole artifact (allowed for modify; restructure
/// SHOULD still name what may change, but a whole-artifact restructure with
/// confirmed preservation constraints is legitimate).
public struct DesignWorkScope: Codable, Sendable, Equatable, Hashable {
    /// Stable object identifiers inside the artifact (slide shape, CAD body,
    /// image layer, table range...). Opaque to the core; owner adapters map
    /// them to real objects.
    public var objectIDs: [String]
    /// Zero-based page/slide/sheet indexes for paged families.
    public var pageIndexes: [Int]
    /// Normalized region inside one page/object, when the request is spatial.
    public var region: Region?
    /// Seconds range inside a timeline (video/audio).
    public var timeRange: TimeRange?

    public struct Region: Codable, Sendable, Equatable, Hashable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }
    }

    public struct TimeRange: Codable, Sendable, Equatable, Hashable {
        public var startSeconds: Double
        public var endSeconds: Double
        public init(startSeconds: Double, endSeconds: Double) {
            self.startSeconds = startSeconds; self.endSeconds = endSeconds
        }
    }

    public init(
        objectIDs: [String] = [],
        pageIndexes: [Int] = [],
        region: Region? = nil,
        timeRange: TimeRange? = nil
    ) {
        self.objectIDs = objectIDs
        self.pageIndexes = pageIndexes
        self.region = region
        self.timeRange = timeRange
    }

    public var isEmpty: Bool {
        objectIDs.isEmpty && pageIndexes.isEmpty && region == nil && timeRange == nil
    }

    /// Structural validation; returns the first problem found.
    public func validated() throws -> DesignWorkScope {
        for id in objectIDs where id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw DesignWorkIntentError.invalidScope("object id is empty")
        }
        for index in pageIndexes where index < 0 {
            throw DesignWorkIntentError.invalidScope("page index \(index) is negative")
        }
        if let region {
            guard region.width > 0, region.height > 0, region.x >= 0, region.y >= 0 else {
                throw DesignWorkIntentError.invalidScope("region must be positive and origin-non-negative")
            }
        }
        if let timeRange {
            guard timeRange.startSeconds >= 0, timeRange.endSeconds > timeRange.startSeconds else {
                throw DesignWorkIntentError.invalidScope("time range must be non-negative and increasing")
            }
        }
        return self
    }
}

/// What a 重构 MUST preserve, in the user's own words, confirmed before any
/// mutation. Each entry is an explicit preservation requirement (content,
/// data, behavior, format bounds); adoption verification checks them one by
/// one rather than asserting "done".
public struct DesignPreservationConstraints: Codable, Sendable, Equatable, Hashable {
    /// Content that must survive (pages, sections, named objects, wording).
    public var content: [String]
    /// Data/values that must survive (numbers, formulas, datasets, units).
    public var data: [String]
    /// Behavior/interactions that must keep working (links, navigation,
    /// playback, form submission).
    public var behavior: [String]
    /// Format boundaries that may not change (e.g. "stays .pptx", "no
    /// conversion to images", "keeps vector layers").
    public var formatBounds: [String]

    public init(
        content: [String] = [],
        data: [String] = [],
        behavior: [String] = [],
        formatBounds: [String] = []
    ) {
        self.content = content
        self.data = data
        self.behavior = behavior
        self.formatBounds = formatBounds
    }

    public var isEmpty: Bool {
        content.isEmpty && data.isEmpty && behavior.isEmpty && formatBounds.isEmpty
    }

    /// Canonical digest binding a confirmation to EXACTLY these constraints:
    /// a confirmation over different wording is invalid, so a model (or a
    /// stale UI sheet) cannot re-attach a confirmation to new requirements.
    public var canonicalDigest: String {
        struct Payload: Codable {
            let content: [String]
            let data: [String]
            let behavior: [String]
            let formatBounds: [String]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(Payload(
            content: content.sorted(), data: data.sorted(),
            behavior: behavior.sorted(), formatBounds: formatBounds.sorted()
        ))) ?? Data()
        return FloeDigest.sha256Hex(data)
    }
}

/// Who produced a preservation confirmation. Only the trusted UI may mint
/// one; model output, tool results and imported metadata can never become a
/// confirmation by carrying the right strings.
public enum DesignConfirmationSource: String, Codable, Sendable {
    /// The user tapped through the preservation-confirmation sheet in the
    /// app; the claim is burned through the existing approval-grant store
    /// before the first mutation (see `DesignOwnerWorkflow.adopt`).
    case trustedUI
}

/// A trusted confirmation that the preservation constraints for one
/// restructure are exactly what the user approved. Verified by digest, so a
/// tampered confirmation fails closed before any state changes.
public struct DesignPreservationConfirmation: Codable, Sendable, Equatable, Hashable {
    public var constraints: DesignPreservationConstraints
    public var source: DesignConfirmationSource
    public var confirmedAt: Date
    /// Must equal `constraints.canonicalDigest`; checked on every use.
    public var constraintsDigest: String

    public init(
        constraints: DesignPreservationConstraints,
        source: DesignConfirmationSource = .trustedUI,
        confirmedAt: Date = Date(),
        constraintsDigest: String? = nil
    ) {
        self.constraints = constraints
        self.source = source
        self.confirmedAt = confirmedAt
        self.constraintsDigest = constraintsDigest ?? constraints.canonicalDigest
    }

    /// False for a digest computed over anything other than `constraints`.
    public var isValid: Bool {
        constraintsDigest == constraints.canonicalDigest
    }
}

/// The frozen typed request every 制作/修改/重构 run addresses. It extends
/// the existing envelope/revision/candidate flow — it never replaces target
/// identity, never creates a second store and never auto-starts work.
public struct DesignWorkIntent: Codable, Sendable, Equatable, Hashable {
    public var mode: DesignWorkMode
    /// The ACTUAL desired output format (extension, e.g. "pptx", "png",
    /// "docx"), taken from the real request — not a capability default and
    /// never a webpage fallback. Must map to the artifact's content family.
    public var actualDesiredFormat: String
    /// Exact object/page/time/region scope for modify/restructure; nil (or
    /// empty) means the whole artifact. Ignored for create.
    public var scope: DesignWorkScope?
    /// Preservation requirements; REQUIRED for restructure and carried into
    /// the trusted confirmation.
    public var preservation: DesignPreservationConstraints?
    /// The input revision frozen when this intent was recorded.
    public var frozenRevisionID: String?
    /// The ORIGINATING task the adopted result belongs to (opaque
    /// conversation identity); attribution, never store identity.
    public var originalTaskOwnerID: String?
    /// Trusted confirmation for restructure; nil for create/modify.
    public var confirmation: DesignPreservationConfirmation?
    /// Idempotency key of the operation that recorded this intent.
    public var operationID: String

    public init(
        mode: DesignWorkMode,
        actualDesiredFormat: String,
        scope: DesignWorkScope? = nil,
        preservation: DesignPreservationConstraints? = nil,
        frozenRevisionID: String? = nil,
        originalTaskOwnerID: String? = nil,
        confirmation: DesignPreservationConfirmation? = nil,
        operationID: String
    ) {
        self.mode = mode
        self.actualDesiredFormat = actualDesiredFormat
        self.scope = scope
        self.preservation = preservation
        self.frozenRevisionID = frozenRevisionID
        self.originalTaskOwnerID = originalTaskOwnerID
        self.confirmation = confirmation
        self.operationID = operationID
    }

    /// Structural + semantic validation against the artifact's real family.
    /// - 重构 requires a valid trusted confirmation over non-empty
    ///   preservation constraints BEFORE any mutation is proposed.
    /// - `actualDesiredFormat` must classify into `family` (extension-based
    ///   routing; the owner adapter's reopen verification remains the real
    ///   format proof on adopt/export).
    public func validated(family: DesignContentType) throws -> DesignWorkIntent {
        _ = try scope?.validated()
        guard let routed = DesignContentType.from(format: actualDesiredFormat) else {
            throw DesignWorkIntentError.formatFamilyMismatch(
                format: actualDesiredFormat, family: family
            )
        }
        guard routed == family else {
            throw DesignWorkIntentError.formatFamilyMismatch(
                format: actualDesiredFormat, family: family
            )
        }
        if mode == .restructure {
            guard let preservation, !preservation.isEmpty else {
                throw DesignWorkIntentError.preservationConfirmationRequired
            }
            guard let confirmation else {
                throw DesignWorkIntentError.preservationConfirmationRequired
            }
            guard confirmation.isValid,
                  confirmation.constraints == preservation else {
                 throw DesignWorkIntentError.preservationConfirmationInvalid(
                    "restructure requires a trusted confirmation whose digest matches the preservation constraints"
                )
            }
        }
        return self
    }
}

// MARK: - Trusted restructure authority (service-native, NON-Codable)
//
// `DesignPreservationConfirmation` is DATA: it is Codable, its
// `constraintsDigest` is publicly computable, and its only source case is a
// plain string — so raw model JSON can mint a structurally perfect
// confirmation (`.trustedUI` + matching digest). Structural validation can
// therefore never authorize a restructure. Authority lives ONLY in a claim
// burned by the trusted UI through the existing approval-grant store, and it
// crosses the service boundary as the NON-Codable types below: model tool
// arguments, tool results and imported metadata are all JSON and can never
// mint or carry them. A closure hook can likewise never arrive through tool
// arguments. Data records what was confirmed; authority proves the trusted
// UI confirmed it.

/// Exact binding a trusted restructure-preservation claim must cover. Built
/// by the service (never by the caller) and verified field-by-field against
/// the returned receipt, so a nil, forged, stale or wrong-owner claim is
/// refused before any side effect.
public struct DesignRestructureAuthorityRequest: Sendable, Equatable, Hashable {
    /// Exact owner target the restructure addresses (owner stable key).
    public var targetKey: String
    /// Idempotency key of the confirmed restructure (the intent's
    /// `operationID`): one confirmation authorizes exactly one restructure
    /// operation identity.
    public var operationID: String
    /// ORIGINATING task the confirmed result belongs to (attribution only).
    public var originalTaskOwnerID: String?
    /// Base revision the restructure starts from.
    public var baseRevisionID: String?
    /// Canonical digest of the preservation constraints the user confirmed.
    public var preservationDigest: String

    public init(
        targetKey: String,
        operationID: String,
        originalTaskOwnerID: String? = nil,
        baseRevisionID: String? = nil,
        preservationDigest: String
    ) {
        self.targetKey = targetKey
        self.operationID = operationID
        self.originalTaskOwnerID = originalTaskOwnerID
        self.baseRevisionID = baseRevisionID
        self.preservationDigest = preservationDigest
    }
}

/// Non-Codable receipt returned by the trusted handler AFTER it burned a
/// real claim through the existing approval-grant store. Because the type is
/// not Codable, a raw `DesignPreservationConfirmation` — however perfect its
/// source and digest — can never satisfy the propose/freeze gate, and the
/// field-by-field request binding refuses stale, wrong-owner or re-bound
/// claims.
public struct DesignRestructureAuthorityReceipt: Sendable, Equatable, Hashable {
    /// The exact request this receipt authorizes.
    public var request: DesignRestructureAuthorityRequest
    /// Identity of the claim burned in the trusted store (audit trail).
    public var claimID: UUID
    public var issuedAt: Date

    public init(
        request: DesignRestructureAuthorityRequest,
        claimID: UUID,
        issuedAt: Date = Date()
    ) {
        self.request = request
        self.claimID = claimID
        self.issuedAt = issuedAt
    }
}

/// Failure of the trusted restructure-authority gate. Distinct from the
/// data-validation errors: these fire only after structural validation
/// passed, when the actual trusted claim is missing or does not bind.
public enum DesignRestructureAuthorityError: Error, Sendable, Equatable {
    /// A restructure operation reached the gate without any trusted
    /// authority (no handler wired, or no receipt supplied on the sync
    /// engine/freeze path). A matching Codable confirmation is data, not
    /// authority — this fails closed with zero side effects.
    case claimRequired(String)
    /// A receipt/handler result was supplied but does not bind the exact
    /// target / task / base revision / constraints digest / operationID of
    /// this call (stale claim, wrong owner, re-bound digest...).
    case claimMismatch(String)
}

/// Typed trusted-authority hook. The interactive UI wires this to its
/// confirmation sheet plus the existing approval-grant store
/// (`ApprovalGrantStore.claimSingleUse`); the handler burns the single-use
/// grant and returns the bound receipt. A closure can never arrive through
/// model tool arguments, so the model layer can never satisfy this hook.
public typealias DesignRestructureAuthorityHandler =
    @Sendable (DesignRestructureAuthorityRequest) async throws -> DesignRestructureAuthorityReceipt

/// Shared builder/verifier for the trusted restructure-authority seam. Used
/// by the owner propose gate, the sync engine propose gate and the
/// freeze-before-generation seam so every path binds the identical fields.
public enum DesignRestructureAuthority {

    /// The exact request one validated restructure intent must claim.
    /// `targetKey` is the owner identity the calling service knows (owner
    /// stable key, or the design project node id on the Canvas engine path);
    /// `baseRevisionID` is the RESOLVED base so a stale claim over an older
    /// revision is refused.
    public static func request(
        for intent: DesignWorkIntent,
        targetKey: String,
        baseRevisionID: String?
    ) throws -> DesignRestructureAuthorityRequest {
        guard intent.mode == .restructure else {
            throw DesignRestructureAuthorityError.claimRequired(
                "trusted restructure authority is only defined for restructure intents, not \(intent.mode.rawValue)"
            )
        }
        guard let preservation = intent.preservation, !preservation.isEmpty else {
            throw DesignRestructureAuthorityError.claimRequired(
                "restructure authority requires non-empty preservation constraints confirmed by the trusted UI"
            )
        }
        return DesignRestructureAuthorityRequest(
            targetKey: targetKey,
            operationID: intent.operationID,
            originalTaskOwnerID: intent.originalTaskOwnerID,
            baseRevisionID: baseRevisionID ?? intent.frozenRevisionID,
            preservationDigest: preservation.canonicalDigest
        )
    }

    /// Verifies a receipt binds the exact request. nil, forged (hand-built
    /// outside the trusted handler), stale or wrong-owner receipts are
    /// refused here — before any bytes are staged or any state is recorded.
    @discardableResult
    public static func validate(
        _ receipt: DesignRestructureAuthorityReceipt?,
        for request: DesignRestructureAuthorityRequest
    ) throws -> DesignRestructureAuthorityReceipt {
        guard let receipt else {
            throw DesignRestructureAuthorityError.claimRequired(
                "restructure of \(request.targetKey) requires a trusted claim bound to operation \(request.operationID); a Codable confirmation (source/digest) is data, never authority"
            )
        }
        guard receipt.request == request else {
            var details: [String] = []
            if receipt.request.targetKey != request.targetKey {
                details.append("target \(receipt.request.targetKey) != \(request.targetKey)")
            }
            if receipt.request.operationID != request.operationID {
                details.append("operation \(receipt.request.operationID) != \(request.operationID)")
            }
            if receipt.request.originalTaskOwnerID != request.originalTaskOwnerID {
                details.append("original task mismatch")
            }
            if receipt.request.baseRevisionID != request.baseRevisionID {
                details.append("base revision \(receipt.request.baseRevisionID ?? "nil") != \(request.baseRevisionID ?? "nil")")
            }
            if receipt.request.preservationDigest != request.preservationDigest {
                details.append("preservation digest mismatch (stale or re-bound constraints)")
            }
            throw DesignRestructureAuthorityError.claimMismatch(
                "trusted claim does not bind this restructure: \(details.joined(separator: "; "))"
            )
        }
        return receipt
    }
}

public struct DesignProject: Codable, Sendable, Equatable, Identifiable {
    public static let currentSchemaVersion = 1

    /// The Canvas node this design state is attached to. This is the *only*
    /// identity: design state is a typed subdocument of the Canvas project,
    /// persisted through the Canvas compare-and-swap authority. There is no
    /// independent design project/gallery identity.
    public var nodeID: String
    public var id: String { nodeID }

    public var schemaVersion: Int
    public var contentType: DesignContentType
    public var brief: DesignBrief?
    public var spec: DesignSpec?
    public var template: DesignTemplateManifest?
    public var artifacts: [DesignArtifact]
    public var feedback: [DesignFeedback]
    public var candidates: [DesignCandidate]
    /// Explicit Canvas-owned workspace binding (office/presentation/CAD):
    /// the existing editors address this workspace-relative document. nil
    /// for byte-based content (image/video/pdf/notes/web).
    public var workspaceBinding: DesignWorkspaceBinding?
    /// The run currently frozen for generation/edit, if any.
    public var frozenRun: DesignRunFrozen?
    /// Applied idempotency keys, bounded. Replaying an operation ID is a no-op.
    public var appliedOperationIDs: [String]
    /// Creative START request: requirements + requested output kind persisted
    /// BEFORE the first real result exists. nil for every non-creative flow
    /// and for creative work that already materialized.
    public var creativeRequest: DesignCreativeRequest?
    public var createdAt: Date
    public var updatedAt: Date
    /// Unknown top-level fields from an older/newer payload, preserved
    /// verbatim (semantically) and re-emitted on the next write. This is
    /// what makes forward/back compatibility DEMONSTRABLE: a key this build
    /// does not model is never dropped by synthesized Codable. Known keys
    /// never appear here even when absent in the source payload.
    public var unknownFields: [String: DesignJSONValue]

    public init(
        nodeID: String,
        contentType: DesignContentType,
        brief: DesignBrief? = nil,
        spec: DesignSpec? = nil,
        template: DesignTemplateManifest? = nil,
        workspaceBinding: DesignWorkspaceBinding? = nil
    ) {
        self.nodeID = nodeID
        self.schemaVersion = Self.currentSchemaVersion
        self.contentType = contentType
        self.brief = brief
        self.spec = spec
        self.template = template
        self.workspaceBinding = workspaceBinding
        self.artifacts = []
        self.feedback = []
        self.candidates = []
        self.frozenRun = nil
        self.appliedOperationIDs = []
        self.creativeRequest = nil
        self.createdAt = Date()
        self.updatedAt = Date()
        self.unknownFields = [:]
    }

    private enum CodingKeys: String, CodingKey {
        case nodeID, schemaVersion, contentType, brief, spec, template
        case artifacts, feedback, candidates, workspaceBinding, frozenRun
        case appliedOperationIDs, creativeRequest, createdAt, updatedAt
    }

    /// Tolerant decode: every known field decodes with the same default as
    /// the memberwise initializer, and every UNKNOWN key is captured into
    /// `unknownFields` so the next encode emits it again. A corrupt known
    /// value still throws (unknown preservation never masks real damage).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodeID = try c.decode(String.self, forKey: .nodeID)
        let decodedSchema = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        schemaVersion = decodedSchema
        contentType = try c.decodeIfPresent(DesignContentType.self, forKey: .contentType) ?? .webpage
        brief = try c.decodeIfPresent(DesignBrief.self, forKey: .brief)
        spec = try c.decodeIfPresent(DesignSpec.self, forKey: .spec)
        template = try c.decodeIfPresent(DesignTemplateManifest.self, forKey: .template)
        artifacts = try c.decodeIfPresent([DesignArtifact].self, forKey: .artifacts) ?? []
        feedback = try c.decodeIfPresent([DesignFeedback].self, forKey: .feedback) ?? []
        candidates = try c.decodeIfPresent([DesignCandidate].self, forKey: .candidates) ?? []
        workspaceBinding = try c.decodeIfPresent(DesignWorkspaceBinding.self, forKey: .workspaceBinding)
        frozenRun = try c.decodeIfPresent(DesignRunFrozen.self, forKey: .frozenRun)
        appliedOperationIDs = try c.decodeIfPresent([String].self, forKey: .appliedOperationIDs) ?? []
        creativeRequest = try c.decodeIfPresent(DesignCreativeRequest.self, forKey: .creativeRequest)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        unknownFields = try Self.captureUnknownFields(decoder: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(nodeID, forKey: .nodeID)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(contentType, forKey: .contentType)
        try c.encodeIfPresent(brief, forKey: .brief)
        try c.encodeIfPresent(spec, forKey: .spec)
        try c.encodeIfPresent(template, forKey: .template)
        try c.encode(artifacts, forKey: .artifacts)
        try c.encode(feedback, forKey: .feedback)
        try c.encode(candidates, forKey: .candidates)
        try c.encodeIfPresent(workspaceBinding, forKey: .workspaceBinding)
        try c.encodeIfPresent(frozenRun, forKey: .frozenRun)
        try c.encode(appliedOperationIDs, forKey: .appliedOperationIDs)
        try c.encodeIfPresent(creativeRequest, forKey: .creativeRequest)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        // Unknown keys cannot use the synthesized CodingKeys (an arbitrary
        // stringValue initializer returns nil), so re-emit them through an
        // arbitrary-key container on the SAME encoder.
        if !unknownFields.isEmpty {
            var extra = encoder.container(keyedBy: ArbitraryKey.self)
            for (name, value) in unknownFields.sorted(by: { $0.key < $1.key }) {
                guard let key = ArbitraryKey(stringValue: name) else { continue }
                try extra.encode(value, forKey: key)
            }
        }
    }

    /// Modeled top-level keys; unknown keys outside this set are preserved.
    /// Extend this list whenever a new modeled field is added.
    static let knownFieldNames: Set<String> = [
        "nodeID", "schemaVersion", "contentType", "brief", "spec",
        "template", "artifacts", "feedback", "candidates",
        "workspaceBinding", "frozenRun", "appliedOperationIDs",
        "creativeRequest", "createdAt", "updatedAt"
    ]

    /// Decodes every top-level key not in the modeled set and returns its
    /// preserved JSON value.
    static func captureUnknownFields(decoder: Decoder) throws -> [String: DesignJSONValue] {
        let rawContainer = try decoder.container(keyedBy: ArbitraryKey.self)
        var preserved: [String: DesignJSONValue] = [:]
        for key in rawContainer.allKeys where !knownFieldNames.contains(key.stringValue) {
            preserved[key.stringValue] = try rawContainer.decode(DesignJSONValue.self, forKey: key)
        }
        return preserved
    }

    fileprivate struct ArbitraryKey: CodingKey {
        var stringValue: String
        var intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public func artifact(_ id: String) -> DesignArtifact? {
        artifacts.first { $0.id == id }
    }

    public func feedback(_ id: String) -> DesignFeedback? {
        feedback.first { $0.id == id }
    }

    public func candidate(_ id: String) -> DesignCandidate? {
        candidates.first { $0.id == id }
    }

    public func hasApplied(operationID: String) -> Bool {
        appliedOperationIDs.contains(operationID)
    }

    /// Feedback still needing work, including stale anchors.
    public var openFeedback: [DesignFeedback] {
        feedback.filter { $0.status == .open || $0.status == .staleAnchor }
    }
}

public enum DesignWorkflowError: Error, Equatable {
    case projectNotFound
    case artifactNotFound(String)
    case candidateNotFound(String)
    case revisionNotFound(String)
    case feedbackNotFound(String)
    /// Adopting requires the proposed revision to differ from the base.
    case noActualChange
    /// The artifact moved since the operation was frozen.
    case revisionConflict(expected: String?, actual: String?)
    case anchorNotRelocated
    case invalidAnchor
    case operationAlreadyApplied(String)
}

/// Deterministic, pure state machine. All mutating operations advance exactly
/// one revision and are idempotent by `operationID` where one is supplied.
public enum DesignWorkflowEngine {

    // MARK: - Project/brief/spec

    public static func createProject(
        nodeID: String,
        contentType: DesignContentType,
        brief: DesignBrief? = nil,
        spec: DesignSpec? = nil,
        template: DesignTemplateManifest? = nil
    ) -> DesignProject {
        DesignProject(nodeID: nodeID, contentType: contentType, brief: brief, spec: spec, template: template)
    }

    /// Record an idempotency key. Returns false when it was already applied, in
    /// which case the caller must not repeat the mutation.
    @discardableResult
    public static func recordOperation(_ operationID: String, in project: inout DesignProject) -> Bool {
        guard !operationID.isEmpty, !project.appliedOperationIDs.contains(operationID) else { return false }
        project.appliedOperationIDs.append(operationID)
        if project.appliedOperationIDs.count > 512 {
            project.appliedOperationIDs.removeFirst(project.appliedOperationIDs.count - 512)
        }
        project.updatedAt = Date()
        return true
    }

    public static func updateBrief(_ brief: DesignBrief, in project: inout DesignProject) {
        project.brief = brief
        project.updatedAt = Date()
    }

    public static func updateSpec(_ spec: DesignSpec, in project: inout DesignProject) {
        project.spec = spec
        project.updatedAt = Date()
    }

    // MARK: - Artifacts and revisions

    @discardableResult
    public static func addArtifact(
        _ artifact: DesignArtifact,
        to project: inout DesignProject
    ) -> DesignArtifact {
        project.artifacts.append(artifact)
        project.updatedAt = Date()
        return artifact
    }

    /// Freeze the run's inputs before generation/editing.
    public static func freezeRun(
        operationID: String,
        in project: inout DesignProject,
        inputRevisionID: String? = nil,
        targetRevisionID: String? = nil,
        desiredFormat: String? = nil
    ) -> DesignRunFrozen {
        let frozen = DesignRunFrozen(
            operationID: operationID,
            inputRevisionID: inputRevisionID,
            specSHA256: project.spec?.sha256,
            targetRevisionID: targetRevisionID,
            desiredFormat: desiredFormat
        )
        project.frozenRun = frozen
        project.updatedAt = Date()
        return frozen
    }

    /// Freeze-before-generation validation seam for a typed restructure
    /// intent. Integration calls this BEFORE the model runs so the trusted
    /// claim is confirmed up front — not only after generation. The supplied
    /// receipt must bind the intent's exact operation, this project's node,
    /// the frozen input revision and the confirmed constraints digest; a
    /// nil, forged, stale or wrong-owner receipt fails closed BEFORE the run
    /// is frozen (the project is left untouched). The frozen run records the
    /// mode/digest/desired format as auditable evidence of the confirmed
    /// constraints that authorized generation.
    @discardableResult
    public static func freezeRun(
        operationID: String,
        in project: inout DesignProject,
        workIntent: DesignWorkIntent,
        restructureReceipt: DesignRestructureAuthorityReceipt?,
        inputRevisionID: String? = nil,
        targetRevisionID: String? = nil
    ) throws -> DesignRunFrozen {
        let validated = try workIntent.validated(family: project.contentType)
        var preservationDigest: String? = nil
        if validated.mode == .restructure {
            let request = try DesignRestructureAuthority.request(
                for: validated, targetKey: project.nodeID,
                baseRevisionID: inputRevisionID
            )
            _ = try DesignRestructureAuthority.validate(restructureReceipt, for: request)
            preservationDigest = request.preservationDigest
        }
        let frozen = DesignRunFrozen(
            operationID: operationID,
            inputRevisionID: inputRevisionID,
            specSHA256: project.spec?.sha256,
            targetRevisionID: targetRevisionID,
            desiredFormat: validated.actualDesiredFormat,
            workMode: validated.mode,
            preservationDigest: preservationDigest
        )
        project.frozenRun = frozen
        project.updatedAt = Date()
        return frozen
    }

    /// Register a new revision. `expectedRevisionID` pins compare-and-swap: pass
    /// the revision the editor was working from; a mismatch is a conflict, never
    /// a silent overwrite.
    @discardableResult
    public static func registerRevision(
        in project: inout DesignProject,
        artifactID: String,
        contentSHA256: String,
        origin: DesignRevisionOrigin,
        expectedRevisionID: String? = nil,
        payloadRelativePath: String? = nil,
        payloadFormat: String? = nil,
        revisionID: String? = nil,
        ownerBaseToken: String? = nil
    ) throws -> DesignRevision {
        guard let index = project.artifacts.firstIndex(where: { $0.id == artifactID }) else {
            throw DesignWorkflowError.artifactNotFound(artifactID)
        }
        if let revisionID, project.artifacts[index].revisions.contains(where: { $0.id == revisionID }) {
            // Explicit revision ids are caller-chosen and must be unique.
            throw DesignWorkflowError.revisionConflict(expected: nil, actual: revisionID)
        }
        let current = project.artifacts[index].currentRevisionID
        if let expectedRevisionID, expectedRevisionID != current {
            throw DesignWorkflowError.revisionConflict(expected: expectedRevisionID, actual: current)
        }
        let number = (project.artifacts[index].revisions.map(\.number).max() ?? 0) + 1
        let revision = DesignRevision(
            id: revisionID ?? UUID().uuidString.lowercased(),
            artifactID: artifactID,
            number: number,
            contentSHA256: contentSHA256,
            origin: origin,
            parentRevisionID: current,
            payloadRelativePath: payloadRelativePath,
            payloadFormat: payloadFormat,
            ownerBaseToken: ownerBaseToken
        )
        project.artifacts[index].revisions.append(revision)
        project.artifacts[index].currentRevisionID = revision.id
        refreshAnchorStaleness(in: &project, artifactIndex: index)
        project.updatedAt = Date()
        return revision
    }

    /// Instantly replace the current revision's content (an editor save that
    /// keeps one revision) is not supported: every save is a revision so history
    /// and feedback anchors remain meaningful.

    // MARK: - Feedback

    @discardableResult
    public static func addFeedback(
        in project: inout DesignProject,
        artifactID: String,
        revisionID: String? = nil,
        anchor: DesignFeedbackAnchor,
        comment: String,
        author: DesignFeedbackAuthor
    ) throws -> DesignFeedback {
        guard let artifact = project.artifact(artifactID) else {
            throw DesignWorkflowError.artifactNotFound(artifactID)
        }
        guard let revisionID = revisionID ?? artifact.currentRevisionID else {
            throw DesignWorkflowError.revisionNotFound("current")
        }
        guard artifact.revision(revisionID) != nil else {
            throw DesignWorkflowError.revisionNotFound(revisionID)
        }
        switch anchor {
        case .region(let x, let y, let w, let h):
            guard w > 0, h > 0, x >= 0, y >= 0 else { throw DesignWorkflowError.invalidAnchor }
        case .time(let seconds):
            guard seconds >= 0 else { throw DesignWorkflowError.invalidAnchor }
        case .page(let index):
            guard index >= 0 else { throw DesignWorkflowError.invalidAnchor }
        case .objectID(let value):
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DesignWorkflowError.invalidAnchor
            }
        }
        let feedback = DesignFeedback(
            artifactID: artifactID,
            revisionID: revisionID,
            anchor: anchor,
            comment: comment,
            author: author,
            status: artifact.currentRevisionID == revisionID ? .open : .staleAnchor
        )
        project.feedback.append(feedback)
        project.updatedAt = Date()
        return feedback
    }

    /// Re-point a stale anchor at the artifact's current revision after the user
    /// confirms the new location.
    public static func relocateAnchor(
        in project: inout DesignProject,
        feedbackID: String,
        anchor: DesignFeedbackAnchor,
        toRevisionID: String? = nil
    ) throws {
        guard let index = project.feedback.firstIndex(where: { $0.id == feedbackID }) else {
            throw DesignWorkflowError.feedbackNotFound(feedbackID)
        }
        let artifactID = project.feedback[index].artifactID
        guard let artifact = project.artifact(artifactID),
              let current = toRevisionID ?? artifact.currentRevisionID,
              artifact.revision(current) != nil else {
            throw DesignWorkflowError.revisionNotFound(toRevisionID ?? "current")
        }
        project.feedback[index].anchor = anchor
        project.feedback[index].revisionID = current
        if project.feedback[index].status == .staleAnchor {
            project.feedback[index].status = .open
        }
        project.updatedAt = Date()
    }

    /// Resolve feedback only when the referenced revision is the artifact's
    /// current one and its content actually differs from the anchored revision.
    /// Model text can never resolve feedback.
    public static func resolveFeedback(
        in project: inout DesignProject,
        feedbackID: String,
        resolvedByRevisionID: String
    ) throws {
        guard let index = project.feedback.firstIndex(where: { $0.id == feedbackID }) else {
            throw DesignWorkflowError.feedbackNotFound(feedbackID)
        }
        let item = project.feedback[index]
        guard let artifact = project.artifact(item.artifactID) else {
            throw DesignWorkflowError.artifactNotFound(item.artifactID)
        }
        guard artifact.currentRevisionID == resolvedByRevisionID else {
            throw DesignWorkflowError.revisionConflict(expected: resolvedByRevisionID, actual: artifact.currentRevisionID)
        }
        guard let anchored = artifact.revision(item.revisionID),
              let resolving = artifact.revision(resolvedByRevisionID),
              anchored.contentSHA256 != resolving.contentSHA256 else {
            throw DesignWorkflowError.noActualChange
        }
        project.feedback[index].status = .solved
        project.feedback[index].resolvedByRevisionID = resolvedByRevisionID
        project.updatedAt = Date()
    }

    public static func dismissFeedback(in project: inout DesignProject, feedbackID: String) throws {
        guard let index = project.feedback.firstIndex(where: { $0.id == feedbackID }) else {
            throw DesignWorkflowError.feedbackNotFound(feedbackID)
        }
        project.feedback[index].status = .dismissed
        project.updatedAt = Date()
    }

    // MARK: - Candidates and adoption

    /// Propose a candidate. `workIntent`, when supplied, is validated
    /// against the artifact's family: a 重构 intent without a valid trusted
    /// preservation confirmation is rejected BEFORE any revision or candidate
    /// is recorded. Structural validation alone is data validation — a raw
    /// model JSON can mint a matching Codable confirmation — so a
    /// restructure additionally requires `restructureReceipt`, the NON-
    /// Codable receipt a trusted service produced after burning a real claim
    /// (see `DesignRestructureAuthority`): it must bind the intent's exact
    /// operation, this project's node, the resolved base revision and the
    /// confirmed constraints digest, otherwise the call fails closed with
    /// zero staged bytes. The intent's mode/preservation digest are stamped
    /// on the candidate for adoption-time auditing.
    @discardableResult
    public static func proposeCandidate(
        in project: inout DesignProject,
        artifactID: String,
        baseRevisionID: String? = nil,
        proposedContentSHA256: String,
        summary: String,
        diff: [String] = [],
        feedbackIDs: [String] = [],
        proposedRevisionID: String? = nil,
        payloadRelativePath: String? = nil,
        payloadFormat: String? = nil,
        originConversationID: String? = nil,
        originEnvironmentID: String? = nil,
        workIntent: DesignWorkIntent? = nil,
        restructureReceipt: DesignRestructureAuthorityReceipt? = nil
    ) throws -> DesignCandidate {
        guard let index = project.artifacts.firstIndex(where: { $0.id == artifactID }) else {
            throw DesignWorkflowError.artifactNotFound(artifactID)
        }
        let artifact = project.artifacts[index]
        guard let base = baseRevisionID ?? artifact.currentRevisionID else {
            throw DesignWorkflowError.revisionNotFound("current")
        }
        guard let baseRevision = artifact.revision(base) else {
            throw DesignWorkflowError.revisionNotFound(base)
        }
        if let workIntent {
            let validated = try workIntent.validated(family: artifact.contentType)
            // TRUSTED AUTHORITY GATE (sync path): a restructure intent must
            // carry a receipt minted by the trusted service AFTER the actual
            // claim. It is verified BEFORE any mutation of `project` (no
            // frozen-run stamping, no revision, no candidate), so a missing
            // or forged receipt leaves the project untouched.
            if validated.mode == .restructure {
                let request = try DesignRestructureAuthority.request(
                    for: validated, targetKey: project.nodeID,
                    baseRevisionID: base
                )
                _ = try DesignRestructureAuthority.validate(restructureReceipt, for: request)
            }
        }
        // Freeze the actual desired format with the run that produced this
        // proposal: format claims are routing decisions, recorded where the
        // input revision is recorded.
        if let workIntent {
            if project.frozenRun != nil {
                project.frozenRun?.desiredFormat = workIntent.actualDesiredFormat
            } else {
                project.frozenRun = DesignRunFrozen(
                    operationID: workIntent.operationID,
                    desiredFormat: workIntent.actualDesiredFormat
                )
            }
        }
        // Proposals never mutate the artifact: the proposed bytes are stored as
        // a new revision that adoption will promote. If the proposed bytes are
        // identical to the base this is not a real change.
        guard proposedContentSHA256 != baseRevision.contentSHA256 else {
            throw DesignWorkflowError.noActualChange
        }
        let number = (artifact.revisions.map(\.number).max() ?? 0) + 1
        let revision = DesignRevision(
            id: proposedRevisionID ?? UUID().uuidString.lowercased(),
            artifactID: artifactID,
            number: number,
            contentSHA256: proposedContentSHA256,
            origin: .generate,
            parentRevisionID: base,
            payloadRelativePath: payloadRelativePath,
            payloadFormat: payloadFormat
        )
        project.artifacts[index].revisions.append(revision)

        let candidate = DesignCandidate(
            artifactID: artifactID,
            baseRevisionID: base,
            proposedRevisionID: revision.id,
            feedbackIDs: feedbackIDs,
            summary: summary,
            diff: diff,
            originConversationID: originConversationID,
            originEnvironmentID: originEnvironmentID,
            workMode: workIntent?.mode,
            preservationDigest: workIntent?.mode == .restructure
                ? workIntent?.preservation?.canonicalDigest : nil
        )
        // Supersede any older pending candidate for the same artifact.
        for i in project.candidates.indices
        where project.candidates[i].artifactID == artifactID && project.candidates[i].status == .pending {
            project.candidates[i].status = .superseded
        }
        project.candidates.append(candidate)
        project.updatedAt = Date()
        return candidate
    }

    /// Adopt a candidate. The default updates the original node and retains its
    /// identity; `.variant` creates a branch artifact and leaves the original.
    @discardableResult
    public static func adoptCandidate(
        in project: inout DesignProject,
        candidateID: String,
        mode: DesignAdoptMode = .updateOriginal,
        expectedRevisionID: String? = nil
    ) throws -> DesignArtifact {
        guard let candidateIndex = project.candidates.firstIndex(where: { $0.id == candidateID }) else {
            throw DesignWorkflowError.candidateNotFound(candidateID)
        }
        let candidate = project.candidates[candidateIndex]
        guard candidate.status == .pending else {
            throw DesignWorkflowError.operationAlreadyApplied(candidateID)
        }
        guard let artifactIndex = project.artifacts.firstIndex(where: { $0.id == candidate.artifactID }) else {
            throw DesignWorkflowError.artifactNotFound(candidate.artifactID)
        }
        if let expectedRevisionID, expectedRevisionID != project.artifacts[artifactIndex].currentRevisionID {
            throw DesignWorkflowError.revisionConflict(
                expected: expectedRevisionID,
                actual: project.artifacts[artifactIndex].currentRevisionID
            )
        }
        guard let proposed = project.artifacts[artifactIndex].revision(candidate.proposedRevisionID),
              let base = project.artifacts[artifactIndex].revision(candidate.baseRevisionID),
              proposed.contentSHA256 != base.contentSHA256 else {
            throw DesignWorkflowError.noActualChange
        }

        let result: DesignArtifact
        switch mode {
        case .updateOriginal:
            project.artifacts[artifactIndex].currentRevisionID = candidate.proposedRevisionID
            project.artifacts[artifactIndex].revisions[project.artifacts[artifactIndex].revisions.count - 1].origin = .adopt
            project.candidates[candidateIndex].status = .adopted
            project.candidates[candidateIndex].resolvedAt = Date()
            refreshAnchorStaleness(in: &project, artifactIndex: artifactIndex)
            result = project.artifacts[artifactIndex]
        case .variant:
            // Keep the proposed bytes as a new artifact that branches from the
            // original but does not disturb it.
            var variant = DesignArtifact(
                contentType: project.artifacts[artifactIndex].contentType,
                identity: project.artifacts[artifactIndex].identity
            )
            var variantRevision = proposed
            variantRevision.id = UUID().uuidString.lowercased()
            variantRevision.artifactID = variant.id
            variantRevision.origin = .variant
            variant.revisions = [variantRevision]
            variant.currentRevisionID = variantRevision.id
            project.artifacts.append(variant)
            project.artifacts[artifactIndex].branches[candidate.proposedRevisionID] = variant.id
            project.candidates[candidateIndex].status = .adopted
            project.candidates[candidateIndex].resolvedAt = Date()
            project.candidates[candidateIndex].variantArtifactID = variant.id
            result = variant
        }
        project.updatedAt = Date()
        return result
    }

    public static func rejectCandidate(in project: inout DesignProject, candidateID: String) throws {
        guard let index = project.candidates.firstIndex(where: { $0.id == candidateID }) else {
            throw DesignWorkflowError.candidateNotFound(candidateID)
        }
        project.candidates[index].status = .rejected
        project.candidates[index].resolvedAt = Date()
        project.updatedAt = Date()
    }

    /// Restore a previous revision from history as the current revision. The
    /// restored revision is appended (or re-pointed) and remains recoverable.
    @discardableResult
    public static func restoreRevision(
        in project: inout DesignProject,
        artifactID: String,
        revisionID: String
    ) throws -> DesignRevision {
        guard let index = project.artifacts.firstIndex(where: { $0.id == artifactID }) else {
            throw DesignWorkflowError.artifactNotFound(artifactID)
        }
        guard let source = project.artifacts[index].revision(revisionID) else {
            throw DesignWorkflowError.revisionNotFound(revisionID)
        }
        let number = (project.artifacts[index].revisions.map(\.number).max() ?? 0) + 1
        let revision = DesignRevision(
            artifactID: artifactID,
            number: number,
            contentSHA256: source.contentSHA256,
            origin: .restore,
            parentRevisionID: project.artifacts[index].currentRevisionID,
            payloadRelativePath: source.payloadRelativePath,
            payloadFormat: source.payloadFormat
        )
        project.artifacts[index].revisions.append(revision)
        project.artifacts[index].currentRevisionID = revision.id
        refreshAnchorStaleness(in: &project, artifactIndex: index)
        project.updatedAt = Date()
        return revision
    }

    // MARK: - Helpers

    private static func refreshAnchorStaleness(in project: inout DesignProject, artifactIndex: Int) {
        let artifact = project.artifacts[artifactIndex]
        for i in project.feedback.indices where project.feedback[i].artifactID == artifact.id {
            switch project.feedback[i].status {
            case .solved, .dismissed:
                continue
            case .open, .staleAnchor:
                if project.feedback[i].revisionID != artifact.currentRevisionID {
                    project.feedback[i].status = .staleAnchor
                }
            }
        }
    }
}
