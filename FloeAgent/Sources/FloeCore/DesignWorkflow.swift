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
    public var frozenAt: Date

    public init(
        operationID: String,
        inputRevisionID: String? = nil,
        specSHA256: String? = nil,
        targetRevisionID: String? = nil,
        frozenAt: Date = Date()
    ) {
        self.operationID = operationID
        self.inputRevisionID = inputRevisionID
        self.specSHA256 = specSHA256
        self.targetRevisionID = targetRevisionID
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

    public init(
        id: String = UUID().uuidString.lowercased(),
        artifactID: String,
        number: Int,
        contentSHA256: String,
        origin: DesignRevisionOrigin,
        parentRevisionID: String? = nil,
        createdAt: Date = Date(),
        payloadRelativePath: String? = nil,
        payloadFormat: String? = nil
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
        originEnvironmentID: String? = nil
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
    }
}

public enum DesignAdoptMode: String, Codable, Sendable {
    /// Update the original node, retaining name/position/size/connections.
    case updateOriginal
    /// Create a branch (new artifact) and keep the original untouched.
    case variant
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
    public var createdAt: Date
    public var updatedAt: Date

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
        self.createdAt = Date()
        self.updatedAt = Date()
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
        targetRevisionID: String? = nil
    ) -> DesignRunFrozen {
        let frozen = DesignRunFrozen(
            operationID: operationID,
            inputRevisionID: inputRevisionID,
            specSHA256: project.spec?.sha256,
            targetRevisionID: targetRevisionID
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
        revisionID: String? = nil
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
            payloadFormat: payloadFormat
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
        originEnvironmentID: String? = nil
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
            originEnvironmentID: originEnvironmentID
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
