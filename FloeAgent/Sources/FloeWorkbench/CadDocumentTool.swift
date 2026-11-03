// FloeWorkbench — cad.document tool.
//
// One tool, native and 2D actions at explicit effect levels. The material,
// parameters and capture actions are ordinary authorized native-document
// operations (no per-edit UI grant). Summary of actions:
//   capabilities — engine-declared capacities and limits (read-only)
//   create       — create a new EMPTY native `.floecad` package through the
//                  host factory (never hand-built bytes); non-overwriting,
//                  atomic, read back with its real identity
//   read         — document summary: format, revision, SHA-256, units, layers
//   query        — paginated entities/text/layers scoped to the document
//   locate       — representative point and bounds of one entity handle
//   measure      — deterministic geometric measurement (points or handles)
//   check        — zero-length/duplicate/layer/open-contour consistency
//   import       — add the geometry of a workspace STEP/STP/IGES/IGS/STL/OBJ/
//                  GLB/glTF file to an EXISTING native package by drafting an
//                  import proposal on a throwaway copy; changes nothing until
//                  preview + UI grant + apply
//   propose      — validates an atomic edit batch against an exact revision
//                  and SHA, stores a pending proposal and returns a diff
//                  preview; changes nothing on disk
//   preview      — returns the stored proposal preview (overlay data)
//   apply        — requires a trusted single-use UI grant bound to the
//                  proposal, document, revision and SHA; applies one atomic
//                  undoable transaction through the host engine
//   save         — commits the host engine's verified output (CAS on SHA)
//   export       — writes a separate verified presentation copy
//
// The tool never mints confirmation itself and never writes a document on
// propose/preview. Ownership is enforced by the injected `CadDocumentHost`,
// which the app supplies from ToolContext environment/workspace/conversation.

import Foundation
import CoreFoundation
import FloeCore
import FloeModels
import FloeTools

// MARK: - Ownership and values

/// Explicit ownership context a tool call must present for document access.
public struct CadDocumentAccess: Sendable, Hashable {
    public var environmentID: String?
    public var workspacePath: String?
    public var ownerKind: String?
    public var ownerID: UUID?

    public init(environmentID: String? = nil, workspacePath: String? = nil,
                ownerKind: String? = nil, ownerID: UUID? = nil) {
        self.environmentID = environmentID
        self.workspacePath = workspacePath
        self.ownerKind = ownerKind
        self.ownerID = ownerID
    }
}

/// JSON value used at the operation boundary. Integral numbers encode as
/// integers so engine integer fields (ACI colors, line weights) are never
/// turned into floating point.
public enum CadValue: Codable, Sendable, Hashable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case object([String: CadValue])
    case array([CadValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([CadValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: CadValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value):
            if value == value.rounded(), value.magnitude < 9_007_199_254_740_992 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case .boolean(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

/// One typed engine edit, preserved as an object so every engine operation
/// (including future ones) remains expressible without tool churn. The engine
/// rejects unknown fields and unsupported operations, and the tool additionally
/// allow-lists the operation name.
public struct CadEditOperation: Codable, Sendable, Hashable {
    public let fields: [String: CadValue]

    public init(fields: [String: CadValue]) {
        self.fields = fields
    }

    public init(from decoder: Decoder) throws {
        self.fields = try [String: CadValue](from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try fields.encode(to: encoder)
    }

    public var operation: String? {
        if case .string(let value) = fields["operation"] { return value }
        return nil
    }
}

// MARK: - Snapshots, proposals and receipts

public struct CadDocumentSnapshot: Codable, Sendable, Equatable {
    public var documentID: String
    public var format: String
    public var revision: Int64
    public var sha256: String
    public var unit: String
    public var activeLayer: String
    public var entityCount: Int
    public var layerCount: Int
    public var editable: Bool
    public var diagnostics: [String]
    public var capabilitiesJSON: String

    public init(documentID: String, format: String, revision: Int64, sha256: String,
                unit: String, activeLayer: String, entityCount: Int, layerCount: Int,
                editable: Bool, diagnostics: [String], capabilitiesJSON: String) {
        self.documentID = documentID
        self.format = format
        self.revision = revision
        self.sha256 = sha256
        self.unit = unit
        self.activeLayer = activeLayer
        self.entityCount = entityCount
        self.layerCount = layerCount
        self.editable = editable
        self.diagnostics = diagnostics
        self.capabilitiesJSON = capabilitiesJSON
    }
}

public struct CadBounds: Codable, Sendable, Equatable {
    public var min: [Double]
    public var max: [Double]

    public init(min: [Double], max: [Double]) {
        self.min = min
        self.max = max
    }
}

public struct CadEntityPreview: Codable, Sendable, Equatable {
    public var handle: String
    public var type: String
    public var layer: String
    public var bounds: CadBounds?
    /// World-space polyline approximating the actual entity geometry
    /// (line endpoints, sampled circle/arc, polyline vertices, text box).
    /// The overlay draws this instead of only the bounding rectangle.
    public var points: [[Double]]?

    public init(handle: String, type: String, layer: String, bounds: CadBounds?,
                points: [[Double]]? = nil) {
        self.handle = handle
        self.type = type
        self.layer = layer
        self.bounds = bounds
        self.points = points
    }
}

public struct CadDiffPreview: Codable, Sendable, Equatable {
    public var added: [CadEntityPreview]
    public var changed: [CadEntityPreview]
    public var deleted: [CadEntityPreview]
    public var counts: [String: Int]
    public var truncated: Bool
    public var note: String

    public init(added: [CadEntityPreview], changed: [CadEntityPreview], deleted: [CadEntityPreview],
                counts: [String: Int], truncated: Bool, note: String) {
        self.added = added
        self.changed = changed
        self.deleted = deleted
        self.counts = counts
        self.truncated = truncated
        self.note = note
    }
}

public struct CadProposal: Codable, Sendable, Equatable {
    public var id: UUID
    public var documentID: String
    public var baseRevision: Int64
    public var baseSHA256: String
    public var summary: String
    public var operationsJSON: String
    public var preview: CadDiffPreview
    public var createdAt: Date

    public init(id: UUID = UUID(), documentID: String, baseRevision: Int64, baseSHA256: String,
                summary: String, operationsJSON: String, preview: CadDiffPreview, createdAt: Date = Date()) {
        self.id = id
        self.documentID = documentID
        self.baseRevision = baseRevision
        self.baseSHA256 = baseSHA256
        self.summary = summary
        self.operationsJSON = operationsJSON
        self.preview = preview
        self.createdAt = createdAt
    }
}

/// Recorded result of an applied proposal, kept so a tool retry with the
/// same request id replays the original receipt instead of re-running the edit.
public struct CadProposalOutcome: Sendable, Equatable {
    public var requestID: String
    public var receipt: CadDocumentReceipt

    public init(requestID: String, receipt: CadDocumentReceipt) {
        self.requestID = requestID
        self.receipt = receipt
    }
}

public struct CadDocumentReceipt: Codable, Sendable, Equatable {    public var documentID: String
    public var revision: Int64
    public var sha256: String
    public var created: [String]
    public var saved: Bool
    public var replay: Bool
    public var note: String?

    public init(documentID: String, revision: Int64, sha256: String, created: [String],
                saved: Bool, replay: Bool = false, note: String? = nil) {
        self.documentID = documentID
        self.revision = revision
        self.sha256 = sha256
        self.created = created
        self.saved = saved
        self.replay = replay
        self.note = note
    }
}

public struct CadExportReceipt: Codable, Sendable, Equatable {
    public var documentID: String
    public var relativePath: String
    public var sha256: String
    public var byteCount: Int
    public var note: String?

    public init(documentID: String, relativePath: String, sha256: String, byteCount: Int, note: String? = nil) {
        self.documentID = documentID
        self.relativePath = relativePath
        self.sha256 = sha256
        self.byteCount = byteCount
        self.note = note
    }
}

/// Verified identity of a newly created native `.floecad` package. The host
/// factory creates the versioned package atomically and reads it back through
/// the real store before returning this receipt; the tool never writes the
/// package itself.
public struct CadNativePackageReceipt: Codable, Sendable, Equatable {
    /// Workspace-relative package path that was created.
    public var relativePath: String
    /// Human-readable display name stored INSIDE the package. It is the name
    /// the caller asked for (letters/digits of any language) and is
    /// independent of the file name, which is derived from the requested path
    /// and uniquified.
    public var name: String
    /// File stem of the created package (the `relativePath` file name without
    /// the `.floecad` extension). Present so a caller can tell the display
    /// name and the file name apart.
    public var fileName: String?
    public var revision: Int64
    public var schemaVersion: Int
    public var contentSHA256: String
    public var modelSHA256: String?
    public var note: String?

    public init(relativePath: String, name: String, fileName: String? = nil, revision: Int64,
                schemaVersion: Int, contentSHA256: String, modelSHA256: String? = nil,
                note: String? = nil) {
        self.relativePath = relativePath
        self.name = name
        self.fileName = fileName
        self.revision = revision
        self.schemaVersion = schemaVersion
        self.contentSHA256 = contentSHA256
        self.modelSHA256 = modelSHA256
        self.note = note
    }
}

public enum CadGrantDecision: Sendable, Equatable {
    case authorized
    case unknownGrant
    case expired
    case documentMismatch
    case alreadyConsumed
    case revisionMismatch(expected: Int64, actual: Int64)
    case shaMismatch(expected: String, actual: String)
}

/// Two-phase reservation outcome. A reservation blocks other consumers but is
/// only consumed once the commit actually succeeded; a failed transaction
/// releases it so the same authorized proposal can be retried within the TTL.
public enum CadGrantReservation: Sendable, Equatable {
    case reserved
    case unknownGrant
    case expired
    case documentMismatch
    case alreadyConsumed
    case alreadyReserved
    case revisionMismatch(expected: Int64, actual: Int64)
    case shaMismatch(expected: String, actual: String)
}

/// Proof that one automatic CAD apply runs under the runtime-approved call
/// authority: the tool builds this ONLY after `consumeRuntimeAuthority`
/// returned `.valid` for the exact approved `cad.document` apply call. It
/// carries the runtime-owned identity (run/task/operation/idempotency) and
/// the canonical binding (target, revision, payload digest), so the host can
/// re-verify that the apply it is asked to perform is the SAME operation the
/// runtime approved. A model cannot construct or smuggle one: the type is
/// never decoded from tool arguments, and the binding only matches the
/// approved payload the runtime hashed. The interactive UI grant path is
/// unchanged and remains the way a human-reviewed proposal is confirmed.
public struct CadAutomaticAuthorization: Sendable, Equatable {
    public var runID: UUID
    public var taskID: UUID?
    public var operationID: String
    public var idempotencyKey: String
    public var approvalGrantID: UUID?
    public var binding: RuntimeAuthorityBinding
    public var consumedAt: Date

    public init(runID: UUID, taskID: UUID?, operationID: String, idempotencyKey: String,
                approvalGrantID: UUID?, binding: RuntimeAuthorityBinding,
                consumedAt: Date = Date()) {
        self.runID = runID
        self.taskID = taskID
        self.operationID = operationID
        self.idempotencyKey = idempotencyKey
        self.approvalGrantID = approvalGrantID
        self.binding = binding
        self.consumedAt = consumedAt
    }
}

// MARK: - Host boundary

/// Implemented by the app, where the JavaScriptCore WASM engine, workspace
/// file services and the interactive UI live.
public protocol CadDocumentHost: Sendable {
    /// Refuses a caller whose environment/workspace/task does not own the
    /// document access it presents.
    func authorizeAccess(access: CadDocumentAccess) async throws
    /// Engine capability JSON; usable without any open document.
    func capabilities(access: CadDocumentAccess) async throws -> String
    /// Current summary; the host opens or reuses a session bound to the exact
    /// file revision and SHA.
    func snapshot(documentID: String, access: CadDocumentAccess) async throws -> CadDocumentSnapshot
    /// Read-only typed query (`entities`, `text`, `layers`, `drawing`, `snap`,
    /// `measure`, `check`, `locate`) executed by the engine.
    func query(documentID: String, requestJSON: String, access: CadDocumentAccess) async throws -> String
    /// Validates the batch on a scratch session, computes the overlay diff and
    /// returns the pending proposal. Must not touch the original document.
    func prepareProposal(documentID: String, snapshot: CadDocumentSnapshot, summary: String,
                         operationsJSON: String, access: CadDocumentAccess) async throws -> CadProposal
    func storeProposal(_ proposal: CadProposal) async throws
    /// Returns the proposal only when it was created by this exact
    /// environment/workspace/owner; a proposal stored by another task, root or
    /// environment must never be visible through a foreign access context.
    func loadProposal(id: UUID, access: CadDocumentAccess) async throws -> CadProposal?
    /// Returns the recorded outcome of an already-applied proposal for the
    /// same owner, so a retry carrying the same request id can replay the
    /// original receipt without re-mutating the document.
    func loadProposalOutcome(id: UUID, access: CadDocumentAccess) async throws -> CadProposalOutcome?
    /// Confirms `documentID` resolves to the proposal's canonical target for
    /// this access before preview/apply/replay touches it.
    func verifyProposalBinding(_ proposal: CadProposal, documentID: String,
                               access: CadDocumentAccess) async throws
    func removeProposal(id: UUID) async throws
    /// Consumes a single-use interactive grant bound to proposal/document/
    /// revision/SHA. Anything else is denied.
    func consumeGrant(grantID: String, proposalID: UUID, documentID: String,
                      revision: Int64, sha256: String) async -> CadGrantDecision
    /// Applies one atomic undoable transaction and commits it with compare-
    /// and-swap. `requestID` is the tool-call idempotency key.
    func apply(proposal: CadProposal, grantID: String, requestID: String,
               access: CadDocumentAccess) async throws -> CadDocumentReceipt
    /// Applies an already-authorized 2D proposal through the RUNTIME-APPROVED
    /// CALL path (no interactive UI grant). Same proof contract as the native
    /// automatic apply: the single-use runtime authority was consumed for this
    /// exact `cad.document` apply call and the host re-verifies the binding
    /// before the existing serialized transaction runs. Hosts without
    /// automatic apply refuse.
    func applyAutomatic(proposal: CadProposal, authorization: CadAutomaticAuthorization,
                        requestID: String, access: CadDocumentAccess) async throws -> CadDocumentReceipt
    /// Commits the current verified engine output (CAS on SHA).
    func save(documentID: String, expectedSHA256: String, requestID: String,
              access: CadDocumentAccess) async throws -> CadDocumentReceipt
    /// Writes a separate verified presentation copy; never overwrites the
    /// source document.
    func export(documentID: String, relativeOutput: String,
                access: CadDocumentAccess) async throws -> CadExportReceipt
    /// Native FloeCAD request. `requestJSON` carries a `kind` plus the typed
    /// operation/payload. Read-only kinds (`snapshot`, `measure`, `assembly`,
    /// `drawing` reads) return JSON; `propose`/`import_propose` validate on a
    /// throwaway copy and never write; `apply` requires a UI-issued single-use
    /// `grant_id` bound to the proposal and base revision/SHA.
    func threeDAction(documentID: String, requestJSON: String,
                      access: CadDocumentAccess) async throws -> String
    /// The same native request carrying the REAL runtime cancellation token.
    /// Import drafts poll it inside the real parse and refuse BEFORE any body
    /// or proposal record is committed; the import apply refuses before the
    /// mutation. A host that predates this overload keeps the legacy behavior
    /// through the default forwarding implementation below, which checks the
    /// token once before handing the request on.
    func threeDAction(documentID: String, requestJSON: String,
                      access: CadDocumentAccess,
                      cancellation: CancellationToken) async throws -> String
    /// App-owned external native part reference loop. The host resolves
    /// `source_path` through the SAME task-workspace/asset guard used by
    /// import; a model path is never treated as a grant. `check`/`inspect`
    /// are read-only; `attach`/`update` commit through one undoable reference
    /// command plus the normal CAS save. No per-edit UI grant is created.
    func reference(documentID: String, requestJSON: String,
                   access: CadDocumentAccess) async throws -> String
    /// The same reference loop carrying the REAL runtime cancellation token.
    /// The host rechecks it after every asynchronous source read and before
    /// the attach/update command mutates or starts its commit. A host that
    /// does not implement this overload keeps the legacy behavior through the
    /// default forwarding implementation below.
    func reference(documentID: String, requestJSON: String,
                   access: CadDocumentAccess,
                   cancellation: CancellationToken) async throws -> String
    /// Applies an already-authorized NATIVE `.floecad` proposal through the
    /// RUNTIME-APPROVED CALL path (no interactive UI grant). The caller
    /// consumed the single-use runtime authority for this exact `cad.document`
    /// apply call; the host re-verifies the proof is bound to this tool, this
    /// operation and this canonical document (and to the proposal's base
    /// revision when the approved call pinned one) and then runs the SAME
    /// all-or-nothing transaction as the interactive path (propose-time
    /// authority record, write-ahead intent, kernel revision/SHA re-check,
    /// single commit, idempotent replay). Hosts without automatic apply
    /// refuse.
    func applyAutomatic(proposalID: UUID, authorization: CadAutomaticAuthorization,
                        requestID: String, access: CadDocumentAccess) async throws -> String
    /// Creates a new EMPTY native `.floecad` package inside the caller's
    /// workspace through the versioned package factory: local workspace only,
    /// guarded relative path, sanitized unique name, non-overwriting atomic
    /// commit, then a real store read-back. The tool never writes package
    /// bytes itself. `relativePath` is the caller's desired package path; the
    /// host may unique-ify the file name and returns the verified identity.
    func createNativePackage(relativePath: String, name: String,
                             access: CadDocumentAccess) async throws -> CadNativePackageReceipt
    /// Engine-declared capabilities of the NATIVE 3D kernel without an open
    /// document: package creation, per-format import/view/edit/export matrix
    /// and limits. Environments without the kernel throw
    /// `FloeError.notFound("native_cad_kernel")`.
    func nativeCapabilities(access: CadDocumentAccess) async throws -> String
    /// Read-only observation of an original model OR an authorised native
    /// `.floecad` document. The host resolves ownership and the exact
    /// generation; identical image bytes are never used as document identity.
    func observeModel(documentID: String, request: CadModelObservationRequest,
                      access: CadDocumentAccess) async throws -> CadModelObservationResult
    /// Cancellation-aware observation used by the tool. Hosts that predate the
    /// runtime token keep the existing method and receive this forwarding
    /// default, which checks cancellation just before and after the call.
    func observeModel(documentID: String, request: CadModelObservationRequest,
                      access: CadDocumentAccess,
                      cancellation: CancellationToken) async throws -> CadModelObservationResult
    /// Actual offscreen viewport PNG of the live native scene, bound to the
    /// document's last committed revision and live change count. Hosts
    /// without a real viewport renderer throw instead of fabricating an image.
    func captureViewport(documentID: String, width: Int, height: Int,
                         expectedRevision: Int64?,
                         access: CadDocumentAccess) async throws -> CadViewportCapture
    /// One actual native animation frame. The host resolves the live document,
    /// applies the frame transiently and returns real rendered bytes bound to
    /// the document revision/change count.
    func captureAnimationFrame(documentID: String,
                               request: CadAnimationCaptureRequest,
                               access: CadDocumentAccess) async throws -> CadAnimationCapture
    /// Start/await a verified MP4 export into the guarded task workspace. The
    /// host owns the native task record, real progress/cancel and atomic file
    /// promotion; a string is never treated as a successful artifact.
    func exportAnimation(documentID: String, relativeOutput: String,
                         options: CadAnimationExportOptions,
                         access: CadDocumentAccess) async throws -> CadAnimationExportReceipt
}

public extension CadDocumentHost {
    func observeModel(documentID: String, request: CadModelObservationRequest,
                      access: CadDocumentAccess) async throws -> CadModelObservationResult {
        throw FloeError.notFound("model_observation")
    }
    /// Forwarding default for hosts that implement only the historical
    /// observation method: the token fences the call boundary, while a
    /// native-capable host overrides this with checks inside the render loop.
    func observeModel(documentID: String, request: CadModelObservationRequest,
                      access: CadDocumentAccess,
                      cancellation: CancellationToken) async throws -> CadModelObservationResult {
        try cancellation.throwIfCancelled()
        let result = try await observeModel(documentID: documentID, request: request,
                                            access: access)
        try cancellation.throwIfCancelled()
        return result
    }
    /// Environments without the native CAD kernel must answer honestly rather
    /// than pretending the action is unsupported per-file.
    func threeDAction(documentID: String, requestJSON: String,
                      access: CadDocumentAccess) async throws -> String {
        throw FloeError.notFound("native_cad_kernel")
    }
    /// Honest default for the token-aware requirement: conformers that cannot
    /// observe cancellation keep compiling and make the same request; the App
    /// host overrides this and polls inside the import parse. Only a
    /// pre-request check is performed here: a committed apply must never be
    /// reported as cancelled after the fact.
    func threeDAction(documentID: String, requestJSON: String,
                      access: CadDocumentAccess,
                      cancellation: CancellationToken) async throws -> String {
        try cancellation.throwIfCancelled()
        return try await threeDAction(documentID: documentID, requestJSON: requestJSON,
                                      access: access)
    }
    func reference(documentID: String, requestJSON: String,
                   access: CadDocumentAccess) async throws -> String {
        throw FloeError.notFound("native_cad_reference")
    }
    /// Honest default for the new requirement: conformers that predate the
    /// runtime token keep compiling and simply perform the same request. The
    /// app host overrides this with the token-aware implementation.
    func reference(documentID: String, requestJSON: String,
                   access: CadDocumentAccess,
                   cancellation: CancellationToken) async throws -> String {
        try await reference(documentID: documentID, requestJSON: requestJSON, access: access)
    }
    func createNativePackage(relativePath: String, name: String,
                             access: CadDocumentAccess) async throws -> CadNativePackageReceipt {
        throw FloeError.notFound("native_cad_kernel")
    }
    func nativeCapabilities(access: CadDocumentAccess) async throws -> String {
        throw FloeError.notFound("native_cad_kernel")
    }
    func captureViewport(documentID: String, width: Int, height: Int,
                         expectedRevision: Int64?,
                         access: CadDocumentAccess) async throws -> CadViewportCapture {
        throw FloeError.notFound("native_cad_kernel")
    }
    func captureAnimationFrame(documentID: String,
                               request: CadAnimationCaptureRequest,
                               access: CadDocumentAccess) async throws -> CadAnimationCapture {
        throw FloeError.notFound("native_cad_animation")
    }
    func exportAnimation(documentID: String, relativeOutput: String,
                         options: CadAnimationExportOptions,
                         access: CadDocumentAccess) async throws -> CadAnimationExportReceipt {
        throw FloeError.notFound("native_cad_animation")
    }
    /// A host that does not implement the runtime-authorized automatic apply
    /// refuses it; the interactive grant path stays available.
    func applyAutomatic(proposal: CadProposal, authorization: CadAutomaticAuthorization,
                        requestID: String, access: CadDocumentAccess) async throws -> CadDocumentReceipt {
        throw FloeError.unauthorized
    }
    func applyAutomatic(proposalID: UUID, authorization: CadAutomaticAuthorization,
                        requestID: String, access: CadDocumentAccess) async throws -> String {
        throw FloeError.unauthorized
    }
}

// MARK: - Trusted confirmation grants

/// Single-use, expiring, opaque grant store for CAD proposals. Only the
/// interactive UI calls `issueGrant`; a value arriving in a tool request is not
/// authority. Any revision/SHA change invalidates a pending grant.
public actor CadProposalGrantStore {
    private struct Entry {
        let proposalID: UUID
        let documentID: String
        let revision: Int64
        let sha256: String
        let expiresAt: Date
        var consumed: Bool
        var reserved: Bool
    }

    private var entries: [String: Entry] = [:]
    private let timeToLive: TimeInterval
    private let idProvider: @Sendable () -> String

    public init(timeToLive: TimeInterval = 300, idProvider: @escaping @Sendable () -> String = {
        (0..<4).map { _ in UUID().uuidString }.joined(separator: "")
    }) {
        self.timeToLive = timeToLive
        self.idProvider = idProvider
    }

    @discardableResult
    public func issueGrant(proposalID: UUID, documentID: String,
                           revision: Int64, sha256: String, now: Date = Date()) -> String {
        sweep(now: now)
        let id = idProvider()
        entries[id] = Entry(proposalID: proposalID, documentID: documentID,
                            revision: revision, sha256: sha256,
                            expiresAt: now.addingTimeInterval(timeToLive), consumed: false,
                            reserved: false)
        return id
    }

    @discardableResult
    public func issueGrant(proposal: CadProposal, now: Date = Date()) -> String {
        sweep(now: now)
        let id = idProvider()
        entries[id] = Entry(proposalID: proposal.id, documentID: proposal.documentID,
                            revision: proposal.baseRevision, sha256: proposal.baseSHA256,
                            expiresAt: now.addingTimeInterval(timeToLive), consumed: false,
                            reserved: false)
        return id
    }

    public func consume(grantID: String, proposalID: UUID, documentID: String,
                        revision: Int64, sha256: String, now: Date = Date()) -> CadGrantDecision {
        sweep(now: now)
        guard var entry = entries[grantID] else { return .unknownGrant }
        guard entry.proposalID == proposalID, entry.documentID == documentID else { return .documentMismatch }
        if entry.consumed || entry.reserved { return .alreadyConsumed }
        if entry.expiresAt <= now { return .expired }
        if entry.revision != revision { return .revisionMismatch(expected: entry.revision, actual: revision) }
        if entry.sha256.lowercased() != sha256.lowercased() {
            return .shaMismatch(expected: entry.sha256, actual: sha256)
        }
        entry.consumed = true
        entries[grantID] = entry
        return .authorized
    }

    /// Validates and marks the grant reserved without consuming it. Exactly
    /// one reservation can exist per grant; a second caller sees
    /// `.alreadyReserved`.
    public func reserve(grantID: String, proposalID: UUID, documentID: String,
                        revision: Int64, sha256: String, now: Date = Date()) -> CadGrantReservation {
        sweep(now: now)
        guard var entry = entries[grantID] else { return .unknownGrant }
        guard entry.proposalID == proposalID, entry.documentID == documentID else { return .documentMismatch }
        if entry.consumed { return .alreadyConsumed }
        if entry.reserved { return .alreadyReserved }
        if entry.expiresAt <= now { return .expired }
        if entry.revision != revision { return .revisionMismatch(expected: entry.revision, actual: revision) }
        if entry.sha256.lowercased() != sha256.lowercased() {
            return .shaMismatch(expected: entry.sha256, actual: sha256)
        }
        entry.reserved = true
        entries[grantID] = entry
        return .reserved
    }

    /// Consumes a reservation after the commit succeeded. Returns false when
    /// the grant is unknown or was not reserved.
    @discardableResult
    public func commitReservation(grantID: String) -> Bool {
        guard var entry = entries[grantID], entry.reserved, !entry.consumed else { return false }
        entry.reserved = false
        entry.consumed = true
        entries[grantID] = entry
        return true
    }

    /// Releases a reservation after a failed transaction so the user can retry
    /// with the same grant inside its TTL.
    public func releaseReservation(grantID: String) {
        guard var entry = entries[grantID], entry.reserved, !entry.consumed else { return }
        entry.reserved = false
        entries[grantID] = entry
    }

    public func revoke(grantID: String) {
        entries.removeValue(forKey: grantID)
    }

    @discardableResult
    private func sweep(now: Date) -> Int {
        let expired = entries.filter { $0.value.expiresAt <= now }.map(\.key)
        for key in expired { entries.removeValue(forKey: key) }
        return expired.count
    }
}

// MARK: - Arguments

public enum CadDocumentAction: String, Decodable, Sendable, CaseIterable {
    case capabilities, create, read, query, locate, measure, check, propose, `import`, preview, apply, save, export
    /// Native custom-material library/application, typed feature-parameter
    /// editing/undo, and real viewport capture. These are ordinary authorized
    /// document operations (no per-edit UI grant); a model-supplied grant is
    /// never consulted.
    case material, parameters, capture, animation
    /// X22 persisted section cut / measurement guides. `get` is read-only;
    /// other actions are ordinary undoable document edits on the existing
    /// additive sceneSettings record. This is an action of the SAME tool, not
    /// a new tool/alias or a separate approval path.
    case scene
    case observe
    /// App-owned external native part reference (attach/check/update/inspect)
    /// for an already-authorized workspace `.floecad` source. Direct ordinary
    /// CAD edit; source access is resolved by the host, never by a model path.
    case reference
    /// Durable native-task status and cancellation (long rebuild/export/mesh
    /// jobs). `status` lists or reports one task; `cancel` requires task_id.
    case status, cancel
    /// E34: explicit user-named whole-document checkpoints. Read-only
    /// list/compare/recoveries/record never write package bytes or draft
    /// state; create/restore/delete/recover/discard_recovery are ordinary
    /// task-authorized CAD edits with the document's own revision/ownership
    /// CAS (no model-supplied grant is consulted).
    case versions
    // Native FloeCAD compatibility aliases. The unified read/query/measure/
    // check/propose/preview/apply/save/export actions route on the document
    // representation (`.floecad` = native); these aliases stay for callers
    // written against the first native surface.
    case threeDSnapshot = "three_d_snapshot"
    case threeDMeasure = "three_d_measure"
    case threeDPropose = "three_d_propose"
    case threeDApply = "three_d_apply"
    case threeDAssembly = "three_d_assembly"
    case threeDDrawing = "three_d_drawing"
}

public struct CadDocumentArguments: Decodable, Sendable {
    public var action: CadDocumentAction
    public var path: String?
    public var summary: String?
    public var operations: [CadEditOperation]?
    public var proposalID: UUID?
    /// The proposal id EXACTLY as the approved call carried it. The runtime
    /// authority binds the raw argument payload, so the automatic apply must
    /// re-derive the same string (an id typed in a different case is a
    /// different payload and therefore not the approved call).
    public var proposalIDRaw: String?
    public var grantID: String?
    public var requestID: String?
    public var kind: String?
    public var points: [[Double]]?
    public var handles: [String]?
    public var tolerance: Double?
    public var scope: String?
    public var layer: String?
    public var entityType: String?
    public var text: String?
    public var offset: Int?
    public var limit: Int?
    public var output: String?
    /// Native CAD: the typed operation name (for example `feature.extrude`).
    public var op: String?
    /// Native CAD: the operation's `args` object, encoded as a JSON string.
    public var args: String?
    /// Native CAD: assembly/drawing/script/mesh request payload, encoded as a
    /// JSON string.
    public var payload: String?
    /// Durable native task id (status/cancel).
    public var taskID: String?
    /// `import`/`reference`: workspace-relative path of the source file.
    /// For `reference` this must be a native `.floecad` package; the host
    /// resolves it through the task workspace guard, never as a raw grant.
    public var sourcePath: String?
    /// `reference`: attach | check | update | inspect. Required.
    public var referenceAction: String?
    /// `reference`: durable reference id for check/update.
    public var referenceID: String?
    /// `reference`: optional CAS values serialized from a prior reply/query.
    public var expectedSourceSHA256: String?
    public var expectedStagedSHA256: String?
    /// `reference`: stable source body UUID for a multi-body source document.
    public var sourceBodyID: String?
    /// `import`: explicit source format; defaults to the source path
    /// extension. One of step/stp/iges/igs/stl/obj/glb/gltf.
    /// `export` (native): optional explicit container format. One of
    /// step/stp, stl, obj, obj_bundle, 3mf, glb, usdz, pdf, svg, dxf, csv;
    /// gltf is import-only (export writes glb). `obj_bundle` writes one
    /// self-contained .zip (model.obj + model.mtl + textures); plain `obj`
    /// remains a single .obj with UVs and no materials. pdf/svg/dxf/csv are
    /// drawing-page exports and need pageID. The output suffix must match.
    public var format: String?
    /// `import`: optional mm-per-file-unit scale for unitless mesh formats
    /// (STL/OBJ); ignored for exact B-rep formats and declared-unit glTF.
    public var unitScale: Double?
    /// `import`/`create`: optional explicit name for the imported body(ies)
    /// or the new document (defaults to the source stem / file stem).
    public var name: String?
    /// `apply`: optional base revision the approved call is pinned to. When
    /// present the automatic path binds it into the runtime authority and the
    /// host refuses a proposal drafted against a different revision.
    public var revision: Int64?
    /// `export`: optional drawing page id for the native PDF/SVG/DXF drawing
    /// exports and the complete BOM CSV table export (`query` with kind
    /// `drawings` lists the page ids). Kept as the raw string so the
    /// approved-call digest re-derives byte-identically.
    public var pageID: String?
    /// `export`: exact document bodies for scope=part. Empty/absent selects
    /// every body (the historical default). Strings stay raw until validated.
    public var bodyIDs: [String]?
    /// `export`: exact placed occurrences for scope=assembly. Empty/absent
    /// selects every visible placed part. Selecting a subassembly includes its
    /// visible descendants.
    public var instanceIDs: [String]?
    /// `export`: explicit acknowledgement that the coverage receipt is not
    /// complete. Never inferred.
    public var acceptPartial: Bool?
    /// `export`: return the coverage receipt without writing a file.
    public var dryRun: Bool?

    enum CodingKeys: String, CodingKey {
        case action, path, summary, operations, kind, points, handles, tolerance, scope, layer, text, offset, limit, output, op, args, payload, revision
        case proposalID = "proposal_id"
        case grantID = "grant_id"
        case requestID = "request_id"
        case taskID = "task_id"
        case entityType = "entity_type"
        case sourcePath = "source_path"
        case referenceAction = "reference_action"
        case referenceID = "reference_id"
        case expectedSourceSHA256 = "expected_source_sha256"
        case expectedStagedSHA256 = "expected_staged_sha256"
        case sourceBodyID = "source_body_id"
        case format = "format"
        case unitScale = "unit_scale"
        case name = "name"
        case pageID = "page_id"
        case bodyIDs = "body_ids"
        case instanceIDs = "instance_ids"
        case acceptPartial = "accept_partial"
        case dryRun = "dry_run"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = try container.decode(CadDocumentAction.self, forKey: .action)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        operations = try container.decodeIfPresent([CadEditOperation].self, forKey: .operations)
        if let raw = try container.decodeIfPresent(String.self, forKey: .proposalID) {
            guard let parsed = UUID(uuidString: raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .proposalID, in: container,
                    debugDescription: "proposal_id must be a UUID string")
            }
            proposalID = parsed
            proposalIDRaw = raw
        }
        grantID = try container.decodeIfPresent(String.self, forKey: .grantID)
        requestID = try container.decodeIfPresent(String.self, forKey: .requestID)
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
        points = try container.decodeIfPresent([[Double]].self, forKey: .points)
        handles = try container.decodeIfPresent([String].self, forKey: .handles)
        tolerance = try container.decodeIfPresent(Double.self, forKey: .tolerance)
        scope = try container.decodeIfPresent(String.self, forKey: .scope)
        layer = try container.decodeIfPresent(String.self, forKey: .layer)
        entityType = try container.decodeIfPresent(String.self, forKey: .entityType)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        offset = try container.decodeIfPresent(Int.self, forKey: .offset)
        limit = try container.decodeIfPresent(Int.self, forKey: .limit)
        output = try container.decodeIfPresent(String.self, forKey: .output)
        op = try container.decodeIfPresent(String.self, forKey: .op)
        args = try container.decodeIfPresent(String.self, forKey: .args)
        payload = try container.decodeIfPresent(String.self, forKey: .payload)
        taskID = try container.decodeIfPresent(String.self, forKey: .taskID)
        sourcePath = try container.decodeIfPresent(String.self, forKey: .sourcePath)
        referenceAction = try container.decodeIfPresent(String.self, forKey: .referenceAction)
        referenceID = try container.decodeIfPresent(String.self, forKey: .referenceID)
        expectedSourceSHA256 = try container.decodeIfPresent(String.self, forKey: .expectedSourceSHA256)
        expectedStagedSHA256 = try container.decodeIfPresent(String.self, forKey: .expectedStagedSHA256)
        sourceBodyID = try container.decodeIfPresent(String.self, forKey: .sourceBodyID)
        format = try container.decodeIfPresent(String.self, forKey: .format)
        unitScale = try container.decodeIfPresent(Double.self, forKey: .unitScale)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        pageID = try container.decodeIfPresent(String.self, forKey: .pageID)
        bodyIDs = try container.decodeIfPresent([String].self, forKey: .bodyIDs)
        instanceIDs = try container.decodeIfPresent([String].self, forKey: .instanceIDs)
        acceptPartial = try container.decodeIfPresent(Bool.self, forKey: .acceptPartial)
        dryRun = try container.decodeIfPresent(Bool.self, forKey: .dryRun)
        // The revision pin is lenient about its JSON spelling; a value that is
        // neither a number nor a numeric string stays absent, which only ever
        // makes the automatic binding refuse (it never widens authority).
        if let value = try? container.decodeIfPresent(Int64.self, forKey: .revision) {
            revision = value
        } else if let text = try? container.decodeIfPresent(String.self, forKey: .revision),
                  let parsed = Int64(text) {
            revision = parsed
        }
    }
}


// MARK: - Built-in, on-demand documentation

/// The complete authored documentation for `cad.document`, retained as public
/// static text instead of every-turn schema bytes. The concise canonical
/// definition points here; every old rich description is preserved verbatim.
/// Reading it never grants tool, file, approval or CAD authority.
public enum CadDocumentHelp {
    public struct Topic: Sendable, Equatable {
        public let name: String
        public let text: String

        public var byteCount: Int { text.utf8.count }
        public var characterCount: Int { text.count }
        public var sha256: String { FloeDigest.sha256Hex(Data(text.utf8)) }
    }

    public struct Request: Sendable, Equatable {
        public let topic: String
        public let page: Int
        public let pageSize: Int

        public init(topic: String, page: Int = 0, pageSize: Int = CadDocumentHelp.defaultPageSize) {
            self.topic = topic
            self.page = page
            self.pageSize = pageSize
        }
    }

    public struct Page: Sendable, Equatable {
        public let topic: String
        public let page: Int
        public let pageCount: Int
        public let pageSize: Int
        public let characterOffset: Int
        public let characterCount: Int
        public let byteOffset: Int
        public let byteCount: Int
        public let totalBytes: Int
        public let totalCharacters: Int
        public let nextPage: Int?
        public let contentSHA256: String
        public let topicSHA256: String
        public let guideSHA256Value: String
        public let text: String
    }

    /// Default page size is deliberately below the runtime's model-visible
    /// 4 KiB summary cap so a page never arrives truncated. Callers may request
    /// up to `maximumPageSize`; content identity is always reported.
    public static let defaultPageSize = 3_000
    public static let maximumPageSize = 3_500
    public static let guideVersion = 2

    public static let topics: [Topic] = [
        Topic(name: "overview", text: #"""
        Export native CAD with action "export": scope=part keeps the historical selected/all document-body behaviour; scope=assembly writes the saved placed occurrences (nested subassemblies, exact occurrence ids/paths and world transforms), never a flattened document.bodies copy. Add dry_run=true for the coverage receipt only; an incomplete receipt (for example STEP with mesh-only objects) writes nothing unless accept_partial=true is explicit. Observe an original mesh or CAD-surface file, or an authorised native `.floecad` document, with action "observe" without importing, copying or modifying it: choose 1...4 finite views and an optional projection (includeImages=false permits no views for hierarchy-only queries); for GLB/glTF only, a real scene/camera/clip/time; for native documents, optional expectedRevision/expectedChangeCount/expectedSourceSHA256 generation pins. Native frames are real ephemeral offscreen engineering renders of the live scene (renderer=engineering, never an active Present claim) with no change to the user's camera, selection, preferences, saved appearance, playback or undo history; camera/clip/time selections are refused and animated frames use action="animation". Consume actual image artifacts plus source/image hashes and the paged native object rows (stable ids + query_token/generation) bound to the same revision/change_count. GLB/glTF keep the three.js scene path; other originals use the bundled Online3DViewer and STEP/IGES/BREP keep their local display-triangulation conversion. A screenshot does not establish CAD face IDs, B-Rep topology or manufacturing dimensions. Create, import into, read, query, measure, propose changes to, apply confirmed proposals to, save and export a CAD document. The document representation decides the engine: a DWG/DXF drawing runs in the local 2D engine, a native `.floecad` package runs in the parametric 3D kernel. Use action "create" (path/name) to make a new EMPTY native `.floecad` package through the built-in factory — never create the folder, manifest or zip by hand and never guess the internal package layout. Use action "import" on an EXISTING `.floecad` to add the geometry of a workspace STEP/STP, IGES/IGS or native mesh file (STL/OBJ/GLB/glTF/USD/USDZ/Blender/ZIP): it drafts a proposal on a throwaway copy and returns a preview. STEP gives exact editable solids; IGES solids are exact and open shells/faces become exact surface bodies that can be moved/rotated/scaled, painted and re-exported to IGES, but cannot take solid boolean/fillet/shell; STL/OBJ/GLB are render meshes with no parametric history. Use action "reference" to attach/check/update/inspect an external native `.floecad` part from the authorized task workspace: source_path is a path request resolved by the host guard (never a model grant); attach/update are ordinary committed CAD edits with source/staged hash CAS, while inspect/check are read-only. Propose binds an exact document revision and SHA-256 and returns a preview without writing. Apply commits ONE atomic undoable transaction for the exact proposal the approved call names: a `grant_id` selects the human-reviewed CAD UI path, and WITHOUT one the runtime-approved call authority for that exact apply authorizes it automatically (the model cannot mint or replay either; the proposal's revision/SHA is re-verified against the live document at commit). 2D edits are lines, circles, arcs, LWPolylines, text, dimension/leader creation plus move/copy/rotate/scale/mirror/trim/extend/offset and layer management. Existing Linear/Aligned dimensions support text and placement updates; unattached leaders support vertex updates. setLineEndpoints updates supported direct native DIMASSOC relationships atomically; unknown, chained, external or unsupported affected relationships refuse the edit. Other dimension types remain read only when updating existing annotations. Query each entity operations list before editing. 3D, blocks, xrefs, splines and proxy graphics are retained read-only in the 2D engine; they are never flattened. Units stay drawing units when undefined. Native documents add parametric features, assembly constraints, drawings, ShapeScript and mesh operations through the typed operation vocabulary (`op` + `args`; feature.extrude, feature.hole, feature.boolean, ...) and the three_d_* aliases; status/cancel report durable native jobs. Workflow: create → propose sketch.create → apply → propose sketch.addEntities → apply → propose feature.extrude → apply → measure → export. For text use the native text-sketch route instead of the unavailable mesh.text: propose sketch.addText {sketchID,text,height,fontName?,origin?} → apply → propose feature.extrude on the resulting closed profiles (holes are real counter loops) → apply → measure. Every native propose sends op at the TOP LEVEL beside action and path. Its args is a serialized JSON object containing ONLY the operation parameters, never another {op,args} envelope. For extrusion, serialize {sketchID,seedPoint:[x,y],distance:mm} into args. Native `.floecad` documents additionally accept action "material" (custom PBR material library: list/read/create/update/remove/ apply/applyFaces/reassignFaces/mapping/textures/unresolved/libraryExport/ libraryImport/libraryList/undo/redo; applied appearances are snapshots and survive library deletion), action "parameters" (typed feature parameter list/update/undo/redo; updateSketchEntity for an existing line's endpoints, a rectangle's position/size or a circle's center/radius; setSketchDimension/removeSketchDimension for driving length/distance/ angle/radius/diameter/width/height values (setSketchDimension accepts a positive number or a PUBLIC-unit expression such as width / 8; the exact expression is stored on the dimension formula while an angle's formula text stays in degrees and its solved value is stored in radians); variable.create/update/delete for named scalar formulas (one atomic undo including every dependent feature/sketch rebuild; delete refuses while referenced and rename rewrites identifier tokens); feature.setExpression to bind a formula to an existing formula-capable feature scalar in its PUBLIC unit; feature.suppress/delete/move with dependency checks and checkpoint rollback — units and actions come from query kind=features/sketches/variables/constraints), action "animation" (native camera/assembly keyframe clips: list/query/evaluate, createClip/updateClip/deleteClip/setActiveClip, addTrack/deleteTrack, setKeyframe/setCameraKeyframe/setPartKeyframe/deleteKeyframe, turntable/explodeReturn presets and undo/redo; capture returns an actual animated native frame; export renders a verified MP4, default 1920x1080 at 30 fps H.264 with no audio, and reports a durable task_id for status/ cancel; authored edits are ordinary undoable document commands and playback/scrub never changes the geometry or assembly baseline), and action "capture" (actual viewport PNG artifact bound to the document revision/change_count; only a vision-capable model may inspect it — otherwise measure, never claim to have seen the image). Native `.floecad` also accepts action "scene" (the SAME persisted sceneSettings overlay the editor uses: get/setSection/setSectionEnabled/flipSection/removeSection/ setMeasurementsVisible/addMeasurement/removeMeasurement/clearMeasurements/ undo/redo; setSection takes origin [x,y,z] mm plus normal or x_axis/y_axis; addMeasurement takes start/end world mm and returns its id/length; every mutation is one ordinary undoable document command committed with CAS, and no geometry is edited). Section cut and guide lines appear in screenshots/video, but numeric values are not baked into pixels; model exchange (STEP/IGES/GLB/USDZ/OBJ/STL/3MF) carries geometry only. Action "versions" creates, lists, compares, restores and deletes user-named whole-document checkpoints through payload.action; it also lists retained unpublished checkpoints and can recover or discard one. Copy merge stays on this same versions action: merge_compare requires source_path (another authorized workspace .floecad) and base_version_id (the same verified named checkpoint in both copies); it returns an in-memory plan id, exact source/target/base identities, changes and conflict ids without saving. merge_apply requires plan_id and resolutions mapping each conflict id to current or incoming; it rechecks both packages, rebuilds the selected feature history, commits one undoable edit and saves with normal ownership/CAS. merge_cancel requires plan_id and writes nothing. Incoming sketch/variable/material/UV/resource or unknown-semantic changes that cannot be preserved are listed as unsupported and prevent apply; insertion is not a merge. Compare pages through every difference with identity pins, and record returns the exact stored record JSON (byte-bounded chunk pages) when a summary detail omits fields. Restore is revision/CAS-checked, the pre-restore state is kept as a recovery version, and in-memory undo does not cross a restore. Restore creates a named branch checkpoint of the restored state by default while keeping the same document identity; create_branch=false restricts it to the in-place restore. Nothing is written by propose/preview/import; material/parameter/animation edits are undoable document commands committed with compare-and-swap, and temporary chat remains read-only.

        This is the authored canonical overview retained as public static documentation. It is descriptive only and never grants permissions.
        """#),
        Topic(name: "actions", text: #"""
        # cad.document actions

        capabilities — read-only engine/service catalogs and built-in help. Without kind: the engine matrix. kind=drawing|assembly|script|mesh: that service's exact operations with arguments and examples. payload {documentation:"<topic>|topics",page:n,page_size:n} serves this guide.
        create — create a new EMPTY native .floecad package through the host factory (path/name). Never hand-write package files, manifest.json or zip bytes.
        import — add STEP/STP, IGES/IGS, STL, OBJ, GLB or glTF geometry to an EXISTING .floecad. It drafts a proposal on a throwaway copy and returns a preview; nothing is written until preview/apply. STEP gives exact editable solids. IGES solids are exact and open shells/faces become exact surface bodies that can be moved/rotated/scaled, painted and re-exported to IGES, but cannot take solid boolean/fillet/shell. STL/OBJ/GLB are render meshes with no parametric history.
        read — document summary: format, revision, SHA-256, units, layers.
        query — paginated 2D entities/text/layers/drawing/snap or native bodies/sketches/constraints/features/edges/faces/planes/variables/materials/assembly/drawings/scene/detail/snapshot/selection/animation.
        locate — representative point and bounds of one 2D entity handle.
        measure — deterministic 2D or native measurement.
        check — 2D consistency checks (zero-length, duplicate, layer, open contour).
        propose — validate ONE atomic edit batch against an exact revision/SHA, store a pending proposal and return a diff preview. Nothing is written.
        preview — return the stored proposal preview.
        apply — commit the exact approved proposal as ONE atomic undoable transaction. A grant_id selects the human-reviewed CAD UI path; without it the runtime-approved call authority for that exact apply authorizes automatically. The model cannot mint or replay either; revision/SHA is re-verified against the live document at commit.
        save — commit the host engine's verified output with CAS on SHA.
        export — write a separate verified presentation/export copy; scope=part or assembly; dry_run returns the coverage receipt only.
        status/cancel — durable native rebuild/export/mesh task status and cancellation.
        material — native custom PBR material library/application, mapping, textures, unresolved assets, library import/export and undo/redo. Ordinary authorized undoable document commands.
        parameters — typed feature parameters, existing sketch entities, driving dimensions, variables/formulas, datum offset planes, sketch support, feature suppress/delete/move and undo/redo. Ordinary authorized undoable document commands.
        capture — actual viewport PNG artifact bound to the document revision/change_count. A text-only model must measure/query, never claim to have seen the image.
        animation — native camera/assembly keyframe clips, presets, undo/redo, real frame capture and verified MP4/PNG-ZIP export with a durable task_id. Playback/scrub never changes geometry or the assembly baseline.
        scene — persisted section cut and measurement guides: get/setSection/setSectionEnabled/flipSection/removeSection/setMeasurementsVisible/addMeasurement/removeMeasurement/clearMeasurements/undo/redo. get is read-only; other actions are ordinary undoable document edits on the same additive sceneSettings record. This is the same tool, not a new executor or approval path.
        observe — read an ORIGINAL mesh/CAD-surface file or an authorized native .floecad document without importing, copying or modifying it: real views, actual hierarchy, generation pins, no mutation.
        versions — explicit user-named whole-document checkpoints: list/create/compare/restore/delete/recoveries/recover/discard_recovery/record. list/compare/recoveries/record are read-only; edits use the document's own ownership/revision CAS.
        reference — App-owned external native part reference: attach/check/update/inspect. source_path is resolved by the host workspace guard, never a model grant.
        three_d_snapshot, three_d_measure, three_d_propose, three_d_apply, three_d_assembly, three_d_drawing — native FloeCAD compatibility aliases. The unified actions above are preferred.

        """#),
        Topic(name: "fields", text: #"""
        # Field reference

        ## action
        Required. The enum is authoritative; see the actions topic for semantics.

        ## path
        Document path relative to the task workspace (an allowed absolute workspace path is accepted too). Required for every action except capabilities without a path. observe reads an original mesh or CAD-surface file without converting it into a Floe document (GLB/glTF use the three.js scene path; STL/OBJ/PLY/OFF/3DS/DAE/FBX/3MF/AMF/WRL/BIM use the static viewer; STEP/IGES/BREP use the local display-triangulation conversion) and also observes an AUTHORISED native .floecad document through the same public bridge without importing or copying the native model; .dwg/.dxf route to the 2D engine. For 'create' it is the new package location inside the task workspace (a missing parent directory is created inside the guarded workspace; a path outside it is refused; the file need not exist); for 'import' it is the EXISTING .floecad package that receives the geometry. Never write a .floecad directory, manifest.json or zip yourself: use create.

        ## name
        create: human-readable display name stored in the new native document. Letters and digits of ANY language (Chinese, Japanese, Cyrillic, ...), spaces and -_(). are accepted; it must not contain '/', '\\', control/invisible characters or a '..' path segment and must be at most 120 characters, otherwise the call is refused with a bilingual explanation. When omitted the display name defaults to the file stem. The FILE keeps the stem of 'path' and is uniquified, so the display name and the file name stay separate. import: optional name for the imported body(ies).

        ## source_path
        import/reference: workspace-relative path resolved by the host through the task workspace guard. import supports .step/.stp, .iges/.igs, .stl/.obj/.glb/.gltf. reference requires an existing native .floecad package; the source is opened only by the App-owned bridge and is never granted by this string alone. DWG/DXF go through the 2D engine instead.

        ## reference_action
        reference only: attach stages a new external native part and creates its first shared occurrence; check diagnoses source/version/hash state without mutation; update explicitly re-stages the SAME source body with source/staged hash CAS; inspect lists the source document's bodies so a multi-body source can be chosen with source_body_id.

        ## reference_id
        reference check/update: durable reference id from an attach reply or assembly references query.

        ## expected_source_sha256
        reference update CAS: the currently pinned source content SHA-256 (from references query).

        ## expected_staged_sha256
        reference update CAS: the currently pinned staged geometry SHA-256.

        ## source_body_id
        reference attach: stable source body UUID for a multi-body source; inspect returns the body ids. Omitted only when the source has exactly one body.

        ## format
        import or native export: explicit format. Import (step/stp, iges/igs, stl, obj, glb, gltf, usd/usda/usdc/usdz, blend, zip) defaults to the source_path extension. External glTF/OBJ resources must be supplied explicitly in payload.resources; missing resources are named and refuse the whole import. ZIP must contain one unambiguous model root. Static geometry, baked placement and supported materials are retained; unsupported editable scene semantics are reported before import. Native export accepts step/stp, iges/igs, stl, obj, obj_bundle, 3mf, glb, usdz, pdf, svg, dxf and csv; gltf is import-only (export writes glb), and 3mf plus pdf/svg/dxf/csv are export-only in this adapter. STEP writes closed exact solids; IGES writes exact closed solids AND open surfaces (surface bodies are never flattened to a mesh). obj_bundle writes one .zip containing model.obj, model.mtl and relative texture resources; plain obj remains a single .obj with UVs and no materials. pdf/svg/dxf/csv are drawing-page exports and require page_id; usdz is available where the platform USDZ writer is supported (otherwise usdz_unavailable). The output suffix must match the selected format: step/stp -> .step/.stp, iges/igs -> .iges/.igs, obj_bundle -> .zip, every other export -> .<format> (for example .3mf, .glb, .usdz, .pdf, .svg, .dxf, .csv); a mismatched suffix is refused rather than silently renamed.

        ## unit_scale
        import only: optional millimetres-per-file-unit scale for unitless meshes (STL/OBJ). Ignored for STEP/IGES and declared-unit glTF.

        ## summary
        Concise summary of the proposed document change (propose/import).

        ## operations
        Typed 2D engine edits (propose on a DWG/DXF drawing). Each object needs operation. Exact shapes: addLine{start:[x,y,z],end:[x,y,z],layer}; addCircle{center:[x,y,z],radius,layer}; addArc{center:[x,y,z],radius,startAngle,endAngle,layer}; addLwPolyline{points:[[x,y],...],closed?,layer} (2 numbers per point; rectangle = closed 4-point); addText{position:[x,y,z],text,height,layer}; addLeader{points:[[x,y,z],...],layer}; addDimension{kind:linear|aligned|angular|radius|diameter,points:[[x,y,z],...],layer,offset?,rotation?}; move|copy{handle,delta:[dx,dy,dz]}; rotate{handle,center:[x,y,z],angle}; scale{handle,center:[x,y,z],factor}; mirror{handle,axis:[[x,y,z],[x,y,z]]}; setText{handle,text}; setLineEndpoints{handle,start:[x,y,z],end:[x,y,z]}; updateDimension{handle,text?,textPosition:[x,y,z]?,linePosition:[x,y,z]?,textRotationDegrees?} (existing Linear/Aligned only, blank text restores measurement, same-handle native DIMASSOC references follow supported geometry edits atomically); updateLeader{handle,points:[[x,y,z],...]} (unattached leaders only); setRadius{handle,radius}; setLayer{handle,layer}; setColor{handle,color}; setLineWeight{handle,lineWeight}; delete{handle}; trim|extend{handle,boundary,pick:[x,y,z]}; offset{handle,distance,side:[x,y,z]}; addLayer{name,color?,lineType?,lineWeight?}; updateLayer{name,locked?,visible?,color?,lineType?,lineWeight?}; renameLayer{from,to}; deleteLayer{name}; batch{operations:[...]} nests the same canonical shapes. Canonical vectors are arrays [x,y] (omitted z = the 2D drawing plane) or [x,y,0]; a nonzero z is rejected, never projected. The validated aliases {x,y[,z]} and {dx,dy[,dz]} are accepted and normalized to those arrays; addLwPolyline vertices are [x,y] or [x,y,0].

        ## proposal_id
        Proposal id from propose (preview/apply). Send it exactly as the propose reply printed it.

        ## grant_id
        apply: OPTIONAL. When present, selects the human-reviewed CAD UI confirmation path (opaque single-use token the user's acceptance issued; the model cannot mint it). Omit it to let the runtime-approved call authority for this exact apply authorize the change automatically; a made-up or model-supplied value never authorizes anything.

        ## revision
        apply/capture/observe/material/parameters/animation: optional base revision pin. For apply it is bound into the approved call; for capture/observe/material/parameters/animation the host refuses with revision_mismatch before any mutation/capture when the live document is at a different revision. For observe it is the same native generation pin as payload.expectedRevision (disagreeing values are refused) and it is refused for an original model.

        ## request_id
        Optional caller idempotency key; defaults to the tool call id.

        ## task_id
        Durable native task id (status reports one task; cancel requires it).

        ## kind
        query/measure scope. 2D query: entities|text|layers|drawing|snap; 2D measure: distance|angle|radius|perimeter|area. Native .floecad query: bodies|sketches|constraints|features|edges|faces|planes|variables|materials|assembly|drawings|scene|detail|snapshot|selection|animation. selection returns the current live workbench bodies/faces/edges/sketch/instances with document revision and change_count; query it for deictic edits such as this face, then resolve exact face/edge query tokens before modifying. Features carry typed parameters/units/dependencies/actions; sketches carry entityRows with stable entity ids and each circle's current radius/diameter (the addressable source of an existing hole); faces/edges carry stable-matching indices, signatures and query_token/generation (revision, change_count, mesh_revision) required for index-based edits, and face rows identify planar/cylindrical kind with the actual radiusMM for a cylinder. Native measure: body|distance|bounds|dof|interference|mesh|rebuild (op may name the same kind). capabilities: pass drawing|assembly|script|mesh to get that service's exact operations with arguments and examples.

        ## scope
        export: part = selected/all document bodies (historical default); assembly = saved placed occurrences, including nested subassemblies and visible instances of hidden definitions. Hidden instances are excluded. Assembly export supports step, glb and usdz; IGES is part-scope only.

        ## points
        measure points: 2D distance exactly 2, angle exactly 3, area 3+; snap point (first row). Native distance exactly 2 [x,y,z] rows.

        ## handles
        2D entity handles: distance exactly 2, angle 2 lines, radius 1 circle/arc, perimeter 1+. Native: one handle per action, body:<uuid> / face:<uuid>:<index> / edge:<uuid>:<index>; body, mesh and bounds accept body:<uuid> (a bare body UUID is also accepted); bounds takes one or more body handles.

        ## tolerance
        snap/check tolerance in drawing units; native interference tolerance in mm.

        ## layer
        2D query filter.

        ## entity_type
        2D query filter: Line|Circle|Arc|LwPolyline|Text.

        ## text
        2D query filter: text content contains.

        ## offset
        query pagination offset.

        ## limit
        query pagination size.

        ## output
        export relative path. 2D defaults to <name>.export.dxf. Native defaults to <name>.export.step; accepted native formats: step/stp, iges/igs, stl, obj, obj_bundle, 3mf, glb, usdz, pdf, svg, dxf, csv; the path must stay inside the workspace and its suffix must match the format. obj_bundle writes a .zip (model.obj + model.mtl + relative textures) and requires a .zip output path; plain obj writes a single .obj with UVs and no materials. A pdf/svg/dxf export is a DRAWING-page export and also needs page_id (from query kind=drawings). A csv export writes the COMPLETE BOM table for that drawing page (all rows and columns, UTF-8 RFC 4180) and also needs page_id and a .csv output path. usdz export is platform-guarded and reports usdz_unavailable where the writer is unavailable. With scope=assembly use .step, .glb or .usdz (part-scope iges and obj_bundle are also available): placed occurrences are resolved from the saved assembly, not flattened document bodies.

        ## page_id
        export: the native drawing page id for pdf/svg/dxf drawing exports and the complete BOM CSV table export, exactly as query with kind=drawings returned it.

        ## body_ids
        export scope=part: exact document body ids. Omit/empty to export every body (historical default).

        ## instance_ids
        export scope=assembly: exact placed occurrence ids from query kind=assembly/report. Omit/empty for every visible placed part. A subassembly id includes its visible descendant parts.

        ## accept_partial
        export: explicit acknowledgement that the coverage receipt is incomplete (for example STEP with mesh-only objects or open surfaces, or IGES with mesh-only objects). Without it an incomplete plan returns coverage_incomplete and writes nothing.

        ## dry_run
        export: return the coverage receipt only (counts, included/excluded occurrence ids and reasons); no file is written. Requires an explicit scope.

        ## op
        Native typed operation name at the TOP LEVEL beside action and path, never inside args. Native propose requires it; native measure may use it to name the measurement kind. Exact executable vocabulary (also reported by capabilities as operation_names): sketch.create, sketch.addEntities, sketch.addText, feature.extrude, feature.revolve, feature.hole, feature.pattern, feature.mirror, feature.transform, feature.boolean, feature.split, feature.fillet, feature.chamfer, feature.shell, feature.sweep, feature.loft, feature.pushPull, feature.moveFace, feature.deleteFace, feature.replaceFace, feature.draftFace, body.setMaterial, item.setHidden. feature.scaleFace, feature.rotateFace are NOT executable in this build: the kernel returns exact_edit_unsupported without mutation and reports them under capabilities.unavailable_operations; use feature.transform for a whole-body transform instead. feature.pushPull supports mode=planarAxial and mode=cylinderRadial on exact cylindrical faces; feature.moveFace supports normal-axis (dn) movement only (tangential du/dv refuses).

        ## args
        JSON object STRING containing ONLY the typed operation's arguments, not an {op,args} envelope. Send op separately at the top level. Required for native propose (and the three_d_measure/three_d_propose aliases). Units are mm and degrees. RUNNABLE CONTRACT (exact argument names): sketch.create {name?, origin?[x,y,z], xAxis?[x,y,z], yAxis?[x,y,z]} defaults to the ground plane and returns sketchID; sketch.addEntities {sketchID, entities:[{kind:"line",a:[x,y],b:[x,y]} | {kind:"circle",center:[x,y],radius} | {kind:"arc",center:[x,y],radius,startAngle,endAngle} | {kind:"spline",points:[[x,y],...],closed?} | {kind:"rect",min:[x,y],max:[x,y]} | {kind:"polygon",center:[x,y],radius,sides,rotation?} | {kind:"ellipse",center:[x,y],radiusX,radiusY,rotation?}], construction?:[indexes]}; sketch.addText {sketchID, text, height (cap height, mm), fontName? (installed family or PostScript name; default Helvetica), origin?[x,y] (baseline start in sketch-plane mm; default [0,0])} creates closed line loops for the glyphs as ordinary sketch entities (counter loops are holes) in ONE undo step; the reply reports entityCount, glyphCount, outlineLoopCount, boundsMM, advanceWidthMM, heightMM, resolvedFontNames, fallbackFontNames, units:"mm" and undoSteps. This is the native text-sketch route; this service has no standalone mesh.text operation. A missing font or a visible character without a real vector outline refuses with unsupported_font / unsupported_glyphs and adds nothing; entity ids stay available through query kind=sketches. Example: {"sketchID":"<uuid from sketch.create>","text":"O","height":20,"origin":[10,5]}. feature.extrude {sketchID, seedPoint:[x,y] (a point INSIDE the closed profile), distance (mm, non-zero; optional only with end), symmetric?, taperDegrees? (|t|<89, 0 = straight), end?:"throughAll"|"upToNext"|"blind", boolean?:"newBody"|"union"|"subtract"|"intersect", booleanTargets?:[bodyID]}. Non-blind straight extrusions store an associative end: throughAll follows the selected upstream bodies and upToNext follows its original planar face; missing sources refuse rather than silently picking replacements. A non-blind end cannot be combined with taper; upToNext is one-sided. Example: {"sketchID":"<uuid from sketch.create>","seedPoint":[40,20],"distance":10}. feature.hole {sketchID, seedPoint:[x,y] inside the SINGLE locating circle, targetBodyID, type:"throughAll"|"blind"|"counterbore"|"countersink", depth? (blind, mm, flat bottom), counterboreDiameter?/counterboreDepth? (counterbore, mm; diameter > pilot), countersinkDiameter?/countersinkAngle? (countersink, mm; included angle 30…170 degrees; diameter > pilot), reversed? (drills along -plane.normal; a face sketch plane normal is the source face outward normal)}; the placement circle owns position and pilot diameter (bind its diameter formula with setSketchDimension or edit it with updateSketchEntity, never the hole), through/counterbore/countersink pilots are through-all, and the target must be an analytic B-rep body. Ops that act on an existing body take {bodyID} plus their own fields (feature.boolean {kind,targetBodyID,toolBodyIDs}, feature.fillet {bodyID,radius,edges,query_token?} / feature.chamfer {bodyID,setback,edges,query_token?}, feature.shell {bodyID,thickness,openFaces,query_token?}, feature.pattern {bodyID,kind,count,...}); Face/edge index operations require query_token from query kind=faces/edges (or the row's stable face signature/edge midpoint); index existence alone is rejected with requery_required because a rebuild can reuse an index for a different face/edge. measure accepts op to name the kind (body|distance|bounds|dof|interference|mesh|rebuild).

        ## payload
        JSON object string for native workbench services (three_d_assembly/three_d_drawing), material/parameters/capture/animation/scene, and the versions action. scene payload: {action:get|setSection|setSectionEnabled|flipSection|removeSection|setMeasurementsVisible|addMeasurement|removeMeasurement|clearMeasurements|undo|redo, origin?/normal? or x_axis?/y_axis? (mm), enabled?, flip?, size_mm?, start?/end? (mm), id?}. versions: {action:list|create|compare|restore|delete|recoveries|recover|discard_recovery|record, name? (create), version_id? (compare/restore/delete/recover/discard_recovery/record), against_version_id? (compare/record; omit = current committed document), expected_revision? (restore CAS), expected_content_sha256? (restore CAS), create_branch? (restore; default true), branch_name? (restore), offset?/limit? (compare page; limit 1...240), identity? (compare/record continuation: copy the exact from/to objects returned by the first page), section?/identifier? (record: the difference section and record id), chunk_offset?/chunk_limit? (record page over the exact stored JSON; byte-bounded chunks; limit 1...256)}. list/compare/compare pages/recoveries/record are read-only; create/restore/delete/recover/discard_recovery are ordinary task-authorized CAD edits with the document's own ownership/revision CAS. list also returns retained unpublished checkpoints under recoveries; recover publishes one only after it verifies, while discard_recovery deletes only that unpublished checkpoint. compare returns totalDifferences/nextOffset; a later page requires identity pins and a changed current revision is refused. record returns the exact stored record JSON (or the whole stored section for section-level records), its whole-value SHA-256, and byte-bounded chunk pages, so omitted summary fields can be fetched without inventing data. A named version is an explicit whole-document checkpoint, not automatic per-edit history; restore starts a new undo boundary and keeps the pre-restore state as a recovery version. Animation actions: list|query|evaluate (real timeline data), createClip|updateClip|deleteClip|setActiveClip, addTrack|deleteTrack, setKeyframe|setCameraKeyframe|setPartKeyframe|deleteKeyframe, preset {kind:turntable|explodeReturn}, undo|redo, capture {clip_id?,time?|frame?,fps?,width?,height?,format?}, export {output? (workspace .mp4 for mp4, .zip for png_zip),format?:mp4|png_zip,width?,height?,fps?,codec?,bitrate?,overwrite?,poster?,alpha?:opaque|transparent}. Animation edits are ordinary undoable document commands; capture returns a real animated native frame. export returns a verified MP4 (format mp4; codec/bitrate apply) or one ZIP of ordered lossless PNG frames plus manifest.json (format png_zip; codec must be png, no bitrate), with task_id and publishes it through RunOutput. alpha:transparent is refused before rendering: exports keep the scene's opaque background and MP4 H.264/HEVC has no alpha channel. Material actions: list|read|create|update|remove|apply|applyFaces|reassignFaces|mapping|textures|unresolved|libraryExport|libraryImport|libraryList|undo|redo; create/update/apply accept color [r,g,b(,a)] 0…1 (or #RRGGBB[AA]), metallic/roughness/opacity, emissive + emissive_strength, uv_mapping {source:mesh|planarProjection|boxProjection, axis:x|y|z, scale_mm:[u,v], rotation_degrees, offset:[u,v], flip_u, flip_v}, textures [{slot:baseColor|metallic|roughness|normal|emissive|opacity, asset_path? or asset_base64?, color_space?, orientation?}]. Parameter actions: list|update|updateSketchEntity|deleteSketchEntity|setSketchDimension|removeSketchDimension|variable.create|variable.update|variable.delete|feature.setExpression|datum.offsetPlane.create|datum.offsetPlane.update|datum.offsetPlane.delete|sketch.setSupport|sketch.clearSupport|feature.suppress|feature.delete|feature.move|undo|redo; update {feature_id, changes:{distance|angle|taper_angle|radius|setback|thickness|factor|count|spacing|total_angle|symmetric|rotate_instances|hole_type|depth|counterbore_diameter|counterbore_depth|countersink_diameter|countersink_angle|reversed:...}} uses the units query kind=features reports; updateSketchEntity {sketch_id, entity_id, a?, b? | min?, max?, center?, width?, height? | center?, radius?, diameter? | center?, radius?, diameter?, start_angle_deg?, end_angle_deg?, sweep_angle_deg? | center?, radius_x?, radius_y?, rotation_deg? | points? or point_index? + point?, expected_*} edits one existing line/rect/circle/arc/ellipse/spline by stable id and updates matching circle/arc radius or arc sweep dimensions in the same undo step (angles are degrees; an arc stores a CCW sweep under 360 degrees; spline point_index is the zero-based fit-point identity; refused as locked_entity for a Lock, dependent_reference for unsupported referenced geometry, or constraint_conflict if the saved sketch would become unsatisfied; polygon remains query-only); deleteSketchEntity {sketch_id, entity_id, remove_shared_references?, remove_pattern_link?} deletes exactly one entity by stable id in one undo step: references that only name it are removed and reported, a reference that also anchors another entity refuses with shared_references unless the explicit flag is true, and a pattern link refuses unless remove_pattern_link:true while every instance keeps its id; setSketchDimension {sketch_id, entity_id|entity_ids|refs, kind:length|distance|angle|diameter|radius|width|height, value|expression, expected_value?, expected_expression?, dimension_id?} creates or updates one driving value from exactly one of a positive finite number or a formula expression in the SAME public unit, solves with the existing solver and commits one undo step; sending both refuses ambiguous_value and a formula that references an unknown variable/function refuses before mutation. The expression text is stored on the dimension's formula (query kind=constraints exposes formula/formula_unit/formula_reference_names); an angle's formula stays in public degrees while its stored value is radians. expected_value fences the current public numeric value; expected_expression fences the exact stored formula (empty string means none). Variable fan-out re-evaluates the formula and commits every dependent sketch/feature rebuild with the variable edit as ONE undo step (angle is degrees; length is a line's distance; width/height store as horizontal/vertical); removeSketchDimension {sketch_id, dimension_id}; variable.create {name, expression} creates a named unitless scalar; variable.update {variable_id, name?, expression?, expected_expression?} edits/renames one variable and rewrites every variable/feature/sketch formula reference by identifier token (never substring); variable.delete {variable_id} refuses with exact dependent variable/feature/dimension ids while the name is still referenced; both create and update validate names, functions, references and cycles BEFORE commit, and one variable edit plus every dependent feature/sketch rebuild is ONE undo/redo transaction. feature.setExpression {feature_id, parameter, expression, expected_expression?} binds a formula to a parameter query kind=features reports with expression_action=feature.setExpression; expression is written in the PUBLIC unit (deg/mm/unitless) and a radian-persisted public-degree parameter stores an explicit radians(...) conversion rather than an unconverted degree value; expected_expression fences the exact stored `formula` row (radian-valued for a radian-persisted angle), not public_expression; parameters without a formula-capable Expr refuse unsupported_parameter instead of a value-only edit. feature.suppress {feature_id, suppressed}; feature.delete {feature_id, force?} refuses when later features consume its bodies unless forced and always rolls back a broken rebuild; feature.move {feature_id, to_index} verifies body dependency order before moving. datum.offsetPlane.create {body_id, face_index, query_token, expression, size?} creates an associative offset plane in mm from one exact named planar OCCT face; face_index is the kernel index from query kind=faces, never a render triangle. datum.offsetPlane.update {plane_id, expression?, expected_expression?, body_id?, face_index?, query_token?, size?} edits the same plane; source re-selection requires the complete fresh face triple. datum.offsetPlane.delete {plane_id} refuses while referenced. sketch.setSupport {sketch_id, plane_id} rehosts local sketch geometry on that construction plane; sketch.clearSupport {sketch_id} detaches at its current frame. All five operations are ordinary atomic undoable edits; invalid references/formulas refuse before commit. Discover exact ids/formulas/units/dependencies with query kind=planes/sketches/variables/constraints/features. Observe works for an ORIGINAL mesh/CAD-surface file and for an authorised native .floecad document. Original (GLB/glTF keep the three.js scene path): {views?:[{azimuthDegrees,elevationDegrees,distanceScale?}],width?,height?,projection?:perspective|orthographic,sceneIndex?,cameraIndex?,clipIndex?,timeSeconds?,expectedSourceSHA256?,maximumSourceBytes?,maximumResources?,includeImages?,nodeOffset?,nodeLimit?}; defaults to four real camera views and the viewer's actual camera projection. sceneIndex/cameraIndex/clipIndex/timeSeconds are actual GLB/glTF scene selections; static originals allow only sceneIndex 0 (or omitted) and refuse any camera, clip or nonzero time instead of returning a static first frame. Native .floecad uses the SAME request plus two optional live-generation pins: expectedRevision (last committed revision) and expectedChangeCount (the live in-memory generation, which also advances for an unsaved draft). expectedSourceSHA256 on a native document pins the last committed package content SHA-256, never a digest of unsaved mesh bytes. Omit pins for the first observation and reuse the revision/change_count/content_sha256 it returns; disagreeing payload/top-level revision pins and old pins are refused. Frames are real ephemeral offscreen engineering renders of the live scene with a locally fitted camera: the user's camera, selection, preferences, saved appearance, animation playback and undo history are not modified, and the image is not an active RealityKit Present capture (renderer=engineering, present_pixels=false). Native views support exact top/bottom pole frames; cameraIndex, clipIndex and timeSeconds>0 are refused instead of rendering an unrelated static frame — use action=animation with capture {clip_id,time} for actual animated frames. Both routes keep includeImages:false query-only, and the hierarchy is paged with nodeOffset/nodeLimit plus nextOffset; native object rows come from the deterministic body query at the same revision/change_count with stable ids and query_token/generation values. A native .floecad written by a newer app version opens read-only and is refused here. STEP/IGES/BREP pixels come from a lossy display triangulation, not native editable B-Rep; native frames show the actual kernel-built display scene, not CAD topology derived from pixels. This does not create CAD topology or authorize file writes. Capture: {width?,height?} returns a real viewport PNG artifact with renderer=presentation only while Present is active, otherwise renderer=engineering; it is bound to revision/change_count and image_sha256 is separate from content_sha256. applyFaces/reassignFaces require query_token from query kind=faces or face_signatures; index-only edits are refused with requery_required (query tokens are generation proof, not permission). Workbench service payloads MUST name one operation via payload.action or legacy payload.op; mutating workbench services still use propose→apply, while material/parameter edits are ordinary authorized undoable document commands. A global libraryExport/libraryImport uses the single app-owned personal library (libraryList reads it with global:true); global export writes a file so it is refused in temporary/read-only contexts. Never contains file paths other than the guarded asset_path/output/import fields above.

        Standard thread parameters use payload.action=thread.catalog (supported ISO metric BASIC sizes/pitches and limits) or thread.sources (current named cylinder rows and query_token). thread.create takes body_id, face_index, query_token, side:external|internal, diameter/pitch in mm, effective_length (number or variable expression), hand:right|left, ends:flatTrim|onePitchSetback, representation:geometry|schematic. Geometry models the ISO 68-1:2023 basic axial profile; no ISO 965 fit/tolerance is claimed. Schematic records intent and preserves the solid. thread.update takes the EXISTING feature_id plus changes, optionally expected_change_count. A size cannot require adding absent stock. Query kind=features reports representation and editable fields; update is one ordinary undoable edit and saves through the document's existing CAS. Unsupported stock, stale selections or invalid rebuilds commit nothing.
        """#),
        Topic(name: "native-operations", text: #"""
        # Native operations and 2D edit shapes

        ## Advanced edge blends
        The same feature.fillet and feature.chamfer operations accept optional advanced dimensions. For a variable fillet, radius is the radius at BOTH endpoints and middleRadius is the radius at the midpoint; the law is symmetric, requires an open single-edge contour and refuses a closed edge or an implicitly extended tangent chain. For two-distance chamfer add secondDistance beside setback. For distance-angle chamfer add angleDegrees (strictly between 0 and 90), separately from secondDistance. setback is measured on the stored first support face; flip:true swaps the two support sides. Omit extras for the original uniform-radius/equal-distance behavior. Parameters query returns the actual end_radius/middle_radius or first_distance/second_distance/angle expressions, chosen support_faces, limits and editable flags. Native and AI edits share exact geometry, persistent support identities and one undo step; invalid batches commit no partial result.

        ## op
        Native typed operation name at the TOP LEVEL beside action and path, never inside args. Native propose requires it; native measure may use it to name the measurement kind. Exact executable vocabulary (also reported by capabilities as operation_names): sketch.create, sketch.addEntities, sketch.addText, feature.extrude, feature.revolve, feature.hole, feature.pattern, feature.mirror, feature.transform, feature.boolean, feature.split, feature.fillet, feature.chamfer, feature.shell, feature.sweep, feature.loft, feature.pushPull, feature.moveFace, feature.deleteFace, feature.replaceFace, feature.draftFace, body.setMaterial, item.setHidden. feature.scaleFace, feature.rotateFace are NOT executable in this build: the kernel returns exact_edit_unsupported without mutation and reports them under capabilities.unavailable_operations; use feature.transform for a whole-body transform instead. feature.pushPull supports mode=planarAxial and mode=cylinderRadial on exact cylindrical faces; feature.moveFace supports normal-axis (dn) movement only (tangential du/dv refuses).

        ## args
        JSON object STRING containing ONLY the typed operation's arguments, not an {op,args} envelope. Send op separately at the top level. Required for native propose (and the three_d_measure/three_d_propose aliases). Units are mm and degrees. RUNNABLE CONTRACT (exact argument names): sketch.create {name?, origin?[x,y,z], xAxis?[x,y,z], yAxis?[x,y,z]} defaults to the ground plane and returns sketchID; sketch.addEntities {sketchID, entities:[{kind:"line",a:[x,y],b:[x,y]} | {kind:"circle",center:[x,y],radius} | {kind:"arc",center:[x,y],radius,startAngle,endAngle} | {kind:"spline",points:[[x,y],...],closed?} | {kind:"rect",min:[x,y],max:[x,y]} | {kind:"polygon",center:[x,y],radius,sides,rotation?} | {kind:"ellipse",center:[x,y],radiusX,radiusY,rotation?}], construction?:[indexes]}; sketch.addText {sketchID, text, height (cap height, mm), fontName? (installed family or PostScript name; default Helvetica), origin?[x,y] (baseline start in sketch-plane mm; default [0,0])} creates closed line loops for the glyphs as ordinary sketch entities (counter loops are holes) in ONE undo step; the reply reports entityCount, glyphCount, outlineLoopCount, boundsMM, advanceWidthMM, heightMM, resolvedFontNames, fallbackFontNames, units:"mm" and undoSteps. This is the native text-sketch route; this service has no standalone mesh.text operation. A missing font or a visible character without a real vector outline refuses with unsupported_font / unsupported_glyphs and adds nothing; entity ids stay available through query kind=sketches. Example: {"sketchID":"<uuid from sketch.create>","text":"O","height":20,"origin":[10,5]}. feature.extrude {sketchID, seedPoint:[x,y] (a point INSIDE the closed profile), distance (mm, non-zero; optional only with end), symmetric?, taperDegrees? (|t|<89, 0 = straight), end?:"throughAll"|"upToNext"|"blind", boolean?:"newBody"|"union"|"subtract"|"intersect", booleanTargets?:[bodyID]}. Example: {"sketchID":"<uuid from sketch.create>","seedPoint":[40,20],"distance":10}. feature.hole {sketchID, seedPoint:[x,y] inside the SINGLE locating circle, targetBodyID, type:"throughAll"|"blind"|"counterbore"|"countersink", depth? (blind, mm, flat bottom), counterboreDiameter?/counterboreDepth? (counterbore, mm; diameter > pilot), countersinkDiameter?/countersinkAngle? (countersink, mm; included angle 30…170 degrees; diameter > pilot), reversed? (drills along -plane.normal; a face sketch plane normal is the source face outward normal)}; the placement circle owns position and pilot diameter (bind its diameter formula with setSketchDimension or edit it with updateSketchEntity, never the hole), through/counterbore/countersink pilots are through-all, and the target must be an analytic B-rep body. Ops that act on an existing body take {bodyID} plus their own fields (feature.boolean {kind,targetBodyID,toolBodyIDs}, feature.fillet {bodyID,radius,edges,query_token?} / feature.chamfer {bodyID,setback,edges,query_token?}, feature.shell {bodyID,thickness,openFaces,query_token?}, feature.pattern {bodyID,kind,count,...}); Face/edge index operations require query_token from query kind=faces/edges (or the row's stable face signature/edge midpoint); index existence alone is rejected with requery_required because a rebuild can reuse an index for a different face/edge. measure accepts op to name the kind (body|distance|bounds|dof|interference|mesh|rebuild).

        ## Sweep paths and continued editing
        feature.sweep accepts {sketchID,seedPoint,path:{version:1,segments:[{sketchID,entityID,reversed:false}]},boolean?,booleanTargets?} to follow ordered open sketch edges by identity. Use path separately from a literal world-space spine or helix. Query features returns the actual resolved spine, path references and editable helix_radius/helix_pitch/helix_turns. Use action=parameters with payload {action:"update",feature_id,changes:{path:...}} to replace path edges on the SAME feature. Edit source sketch edges normally to update dependent sweeps. Explicit path:null detaches at the current resolved shape; changes.spine_points replaces a detached literal path. Missing/disconnected edges refuse rather than substituting similar geometry. Helix edits regenerate the render spine from the exact helix. Extrusion changes also accept end:"blind"|"throughAll"|"upToNext", end_targets:[upstream body UUIDs], reversed:Bool. A bound distance is derived/read-only; use end:"blind" (optionally with distance) to detach at the current resolved depth. End source selection evaluates the pre-feature geometry, never the feature’s own cut result. Failed edits preserve the previous model and undo history. feature.pushPull also supports mode:"cylinderRadial" on an exact cylindrical face: distance is the signed radius change in body-local mm, not a diameter or replacement radius. Query actual kernel faces for the current radius and pass face:[index], a one-element array with that fresh 1-based index. Positive increases outer or bore radius; negative decreases it. It keeps an exact solid and records an undoable replay feature. An unparameterized exact import captures its original native source once, without a sketch. Edit the SAME feature using action=parameters with payload {action:"update",feature_id,changes:{distance:...}} for continuous editing. Invalid radii or missing source faces refuse and keep the prior model.

        ## Exact executable operation vocabulary
        sketch.create, sketch.addEntities, sketch.addText, feature.extrude, feature.revolve, feature.hole, feature.pattern, feature.mirror, feature.transform, feature.boolean, feature.split, feature.fillet, feature.chamfer, feature.shell, feature.sweep, feature.loft, feature.pushPull, feature.moveFace, feature.deleteFace, feature.replaceFace, feature.draftFace, body.setMaterial, item.setHidden

        ## Guaranteed-refusal operations
        feature.scaleFace, feature.rotateFace are NOT executable in this build. The kernel returns exact_edit_unsupported without mutation and reports them under capabilities.unavailable_operations. Use feature.transform for a whole-body transform.

        ## 2D operations
        Typed 2D engine edits (propose on a DWG/DXF drawing). Each object needs operation. Exact shapes: addLine{start:[x,y,z],end:[x,y,z],layer}; addCircle{center:[x,y,z],radius,layer}; addArc{center:[x,y,z],radius,startAngle,endAngle,layer}; addLwPolyline{points:[[x,y],...],closed?,layer} (2 numbers per point; rectangle = closed 4-point); addText{position:[x,y,z],text,height,layer}; addLeader{points:[[x,y,z],...],layer}; addDimension{kind:linear|aligned|angular|radius|diameter,points:[[x,y,z],...],layer,offset?,rotation?}; move|copy{handle,delta:[dx,dy,dz]}; rotate{handle,center:[x,y,z],angle}; scale{handle,center:[x,y,z],factor}; mirror{handle,axis:[[x,y,z],[x,y,z]]}; setText{handle,text}; setRadius{handle,radius}; setLayer{handle,layer}; setColor{handle,color}; setLineWeight{handle,lineWeight}; delete{handle}; trim|extend{handle,boundary,pick:[x,y,z]}; offset{handle,distance,side:[x,y,z]}; addLayer{name,color?,lineType?,lineWeight?}; updateLayer{name,locked?,visible?,color?,lineType?,lineWeight?}; renameLayer{from,to}; deleteLayer{name}; batch{operations:[...]} nests the same canonical shapes. Canonical vectors are arrays [x,y] (omitted z = the 2D drawing plane) or [x,y,0]; a nonzero z is rejected, never projected. The validated aliases {x,y[,z]} and {dx,dy[,dz]} are accepted and normalized to those arrays; addLwPolyline vertices are [x,y] or [x,y,0].

        feature.pattern uses {bodyID,kind:"linear"|"circular"|"curve",count,axis?:[x,y,z],axisID?:"construction-axis UUID",center?:[x,y,z],spacing?:mm,totalAngleDegrees?:degrees,rotateInstances?:bool,seedFeatureID?:"feature UUID",path?:{version:1,segments:[{sketchID:"UUID",entityID:"UUID",reversed?:bool}]}}. Count includes the original. Omit seedFeatureID to copy bodies with distinct retained output IDs. Supply seedFeatureID to repeat the actual tool of an earlier hole, or a union/subtract extrude/revolve/sweep/loft/draft operation, on the explicitly selected body; it changes that body in place. Unsupported seeds and intersect refuse without changing the document; this is not a copy of the already-processed whole body. Source dimensions and tool placement are re-evaluated. After Split the retained original body ID is the seed's eligible target; new split fragments are never selected implicitly. Query features for the actual target/output IDs.
        Curve patterns require path and no axisID: ordered connected sketch lines, circular arcs or circles only, with exact arc-length positions. spacing=0 fits the path (closed paths omit the repeated end); positive spacing must fit without repeating a closed seam. rotateInstances follows the path tangent; false retains the source orientation. Missing/deleted/disconnected/unsupported edges refuse rather than switch sources. Native controls choose a single path edge; the API can supply an ordered chain. Update the same feature via action=parameters payload {action:"update",feature_id:"...",changes:{count:4,spacing:20,seed_feature_id:"...",path:{...}}}; null seed_feature_id returns to body copies. When removing path, pass path:null and an explicit kind:"linear" or "circular". Material/face identities use authored instance order and original exact tool ancestry, not kernel ordinal guesses. Source relationships survive undo, save/reopen and insertion.
        """#),
        Topic(name: "payloads", text: #"""
        # Payload reference

        The payload is one JSON object string. It is never an authorization grant; the host and the normal runtime still apply every permission, ownership, revision/SHA and approval check.

        JSON object string for native workbench services (three_d_assembly/three_d_drawing), material/parameters/capture/animation/scene, and the versions action. scene payload: {action:get|setSection|setSectionEnabled|flipSection|removeSection|setMeasurementsVisible|addMeasurement|removeMeasurement|clearMeasurements|undo|redo, origin?/normal? or x_axis?/y_axis? (mm), enabled?, flip?, size_mm?, start?/end? (mm), id?}. versions: {action:list|create|compare|restore|delete|recoveries|recover|discard_recovery|record, name? (create), version_id? (compare/restore/delete/recover/discard_recovery/record), against_version_id? (compare/record; omit = current committed document), expected_revision? (restore CAS), expected_content_sha256? (restore CAS), create_branch? (restore; default true), branch_name? (restore), offset?/limit? (compare page; limit 1...240), identity? (compare/record continuation: copy the exact from/to objects returned by the first page), section?/identifier? (record: the difference section and record id), chunk_offset?/chunk_limit? (record page over the exact stored JSON; byte-bounded chunks; limit 1...256)}. list/compare/compare pages/recoveries/record are read-only; create/restore/delete/recover/discard_recovery are ordinary task-authorized CAD edits with the document's own ownership/revision CAS. list also returns retained unpublished checkpoints under recoveries; recover publishes one only after it verifies, while discard_recovery deletes only that unpublished checkpoint. compare returns totalDifferences/nextOffset; a later page requires identity pins and a changed current revision is refused. record returns the exact stored record JSON (or the whole stored section for section-level records), its whole-value SHA-256, and byte-bounded chunk pages, so omitted summary fields can be fetched without inventing data. A named version is an explicit whole-document checkpoint, not automatic per-edit history; restore starts a new undo boundary and keeps the pre-restore state as a recovery version. Animation actions: list|query|evaluate (real timeline data), createClip|updateClip|deleteClip|setActiveClip, addTrack|deleteTrack, setKeyframe|setCameraKeyframe|setPartKeyframe|deleteKeyframe, preset {kind:turntable|explodeReturn}, undo|redo, capture {clip_id?,time?|frame?,fps?,width?,height?,format?}, export {output? (workspace .mp4 for mp4, .zip for png_zip),format?:mp4|png_zip,width?,height?,fps?,codec?,bitrate?,overwrite?,poster?,alpha?:opaque|transparent}. Animation edits are ordinary undoable document commands; capture returns a real animated native frame. export returns a verified MP4 (format mp4; codec/bitrate apply) or one ZIP of ordered lossless PNG frames plus manifest.json (format png_zip; codec must be png, no bitrate), with task_id and publishes it through RunOutput. alpha:transparent is refused before rendering: exports keep the scene's opaque background and MP4 H.264/HEVC has no alpha channel. Material actions: list|read|create|update|remove|apply|applyFaces|reassignFaces|mapping|textures|unresolved|libraryExport|libraryImport|libraryList|undo|redo; create/update/apply accept color [r,g,b(,a)] 0…1 (or #RRGGBB[AA]), metallic/roughness/opacity, emissive + emissive_strength, uv_mapping {source:mesh|planarProjection|boxProjection, axis:x|y|z, scale_mm:[u,v], rotation_degrees, offset:[u,v], flip_u, flip_v}, textures [{slot:baseColor|metallic|roughness|normal|emissive|opacity, asset_path? or asset_base64?, color_space?, orientation?}]. Parameter actions: list|update|updateSketchEntity|deleteSketchEntity|setSketchDimension|removeSketchDimension|variable.create|variable.update|variable.delete|feature.setExpression|datum.offsetPlane.create|datum.offsetPlane.update|datum.offsetPlane.delete|datum.axis.create|datum.axis.update|datum.axis.delete|datum.point.create|datum.point.update|datum.point.delete|sketch.setSupport|sketch.clearSupport|feature.suppress|feature.delete|feature.move|undo|redo; update {feature_id, changes:{distance|angle|taper_angle|radius|setback|thickness|factor|count|spacing|total_angle|symmetric|rotate_instances|axis_id|hole_type|depth|counterbore_diameter|counterbore_depth|countersink_diameter|countersink_angle|reversed:...}} uses the units query kind=features reports; updateSketchEntity {sketch_id, entity_id, a?, b? | min?, max?, center?, width?, height? | center?, radius?, diameter? | center?, radius?, diameter?, start_angle_deg?, end_angle_deg?, sweep_angle_deg? | center?, radius_x?, radius_y?, rotation_deg? | points? or point_index? + point?, expected_*} edits one existing line/rect/circle/arc/ellipse/spline by stable id and updates matching circle/arc radius or arc sweep dimensions in the same undo step (angles are degrees; an arc stores a CCW sweep under 360 degrees; spline point_index is the zero-based fit-point identity; refused as locked_entity for a Lock, dependent_reference for unsupported referenced geometry, or constraint_conflict if the saved sketch would become unsatisfied; polygon remains query-only); deleteSketchEntity {sketch_id, entity_id, remove_shared_references?, remove_pattern_link?} deletes exactly one entity by stable id in one undo step: references that only name it are removed and reported, a reference that also anchors another entity refuses with shared_references unless the explicit flag is true, and a pattern link refuses unless remove_pattern_link:true while every instance keeps its id; setSketchDimension {sketch_id, entity_id|entity_ids|refs, kind:length|distance|angle|diameter|radius|width|height, value|expression, expected_value?, expected_expression?, dimension_id?} creates or updates one driving value from exactly one of a positive finite number or a formula expression in the SAME public unit, solves with the existing solver and commits one undo step; sending both refuses ambiguous_value and a formula that references an unknown variable/function refuses before mutation. The expression text is stored on the dimension's formula (query kind=constraints exposes formula/formula_unit/formula_reference_names); an angle's formula stays in public degrees while its stored value is radians. expected_value fences the current public numeric value; expected_expression fences the exact stored formula (empty string means none). Variable fan-out re-evaluates the formula and commits every dependent sketch/feature rebuild with the variable edit as ONE undo step (angle is degrees; length is a line's distance; width/height store as horizontal/vertical); removeSketchDimension {sketch_id, dimension_id}; variable.create {name, expression} creates a named unitless scalar; variable.update {variable_id, name?, expression?, expected_expression?} edits/renames one variable and rewrites every variable/feature/sketch formula reference by identifier token (never substring); variable.delete {variable_id} refuses with exact dependent variable/feature/dimension ids while the name is still referenced; both create and update validate names, functions, references and cycles BEFORE commit, and one variable edit plus every dependent feature/sketch rebuild is ONE undo/redo transaction. feature.setExpression {feature_id, parameter, expression, expected_expression?} binds a formula to a parameter query kind=features reports with expression_action=feature.setExpression; expression is written in the PUBLIC unit (deg/mm/unitless) and a radian-persisted public-degree parameter stores an explicit radians(...) conversion rather than an unconverted degree value; expected_expression fences the exact stored `formula` row (radian-valued for a radian-persisted angle), not public_expression; parameters without a formula-capable Expr refuse unsupported_parameter instead of a value-only edit. feature.suppress {feature_id, suppressed}; feature.delete {feature_id, force?} refuses when later features consume its bodies unless forced and always rolls back a broken rebuild; feature.move {feature_id, to_index} verifies body dependency order before moving. datum.offsetPlane.create {body_id, face_index, query_token, expression, size?} creates an associative offset plane in mm from one exact named planar OCCT face; face_index is the kernel index from query kind=faces, never a render triangle. datum.offsetPlane.update {plane_id, expression?, expected_expression?, body_id?, face_index?, query_token?, size?} edits the same plane; source re-selection requires the complete fresh face triple. datum.offsetPlane.delete {plane_id} refuses while referenced. sketch.setSupport {sketch_id, plane_id} rehosts local sketch geometry on that construction plane; sketch.clearSupport {sketch_id} detaches at its current frame. All five operations are ordinary atomic undoable edits; invalid references/formulas refuse before commit. Discover exact ids/formulas/units/dependencies with query kind=planes/sketches/variables/constraints/features. Observe works for an ORIGINAL mesh/CAD-surface file and for an authorised native .floecad document. Original (GLB/glTF keep the three.js scene path): {views?:[{azimuthDegrees,elevationDegrees,distanceScale?}],width?,height?,projection?:perspective|orthographic,sceneIndex?,cameraIndex?,clipIndex?,timeSeconds?,expectedSourceSHA256?,maximumSourceBytes?,maximumResources?,includeImages?,nodeOffset?,nodeLimit?}; defaults to four real camera views and the viewer's actual camera projection. sceneIndex/cameraIndex/clipIndex/timeSeconds are actual GLB/glTF scene selections; static originals allow only sceneIndex 0 (or omitted) and refuse any camera, clip or nonzero time instead of returning a static first frame. Native .floecad uses the SAME request plus two optional live-generation pins: expectedRevision (last committed revision) and expectedChangeCount (the live in-memory generation, which also advances for an unsaved draft). expectedSourceSHA256 on a native document pins the last committed package content SHA-256, never a digest of unsaved mesh bytes. Omit pins for the first observation and reuse the revision/change_count/content_sha256 it returns; disagreeing payload/top-level revision pins and old pins are refused. Frames are real ephemeral offscreen engineering renders of the live scene with a locally fitted camera: the user's camera, selection, preferences, saved appearance, animation playback and undo history are not modified, and the image is not an active RealityKit Present capture (renderer=engineering, present_pixels=false). Native views support exact top/bottom pole frames; cameraIndex, clipIndex and timeSeconds>0 are refused instead of rendering an unrelated static frame — use action=animation with capture {clip_id,time} for actual animated frames. Both routes keep includeImages:false query-only, and the hierarchy is paged with nodeOffset/nodeLimit plus nextOffset; native object rows come from the deterministic body query at the same revision/change_count with stable ids and query_token/generation values. A native .floecad written by a newer app version opens read-only and is refused here. STEP/IGES/BREP pixels come from a lossy display triangulation, not native editable B-Rep; native frames show the actual kernel-built display scene, not CAD topology derived from pixels. This does not create CAD topology or authorize file writes. Capture: {width?,height?} returns a real viewport PNG artifact with renderer=presentation only while Present is active, otherwise renderer=engineering; it is bound to revision/change_count and image_sha256 is separate from content_sha256. applyFaces/reassignFaces require query_token from query kind=faces or face_signatures; index-only edits are refused with requery_required (query tokens are generation proof, not permission). Workbench service payloads MUST name one operation via payload.action or legacy payload.op; mutating workbench services still use propose→apply, while material/parameter edits are ordinary authorized undoable document commands. A global libraryExport/libraryImport uses the single app-owned personal library (libraryList reads it with global:true); global export writes a file so it is refused in temporary/read-only contexts. Never contains file paths other than the guarded asset_path/output/import fields above.

        Standard thread parameters use payload.action=thread.catalog (supported ISO metric BASIC sizes/pitches and limits) or thread.sources (current named cylinder rows and query_token). thread.create takes body_id, face_index, query_token, side:external|internal, diameter/pitch in mm, effective_length (number or variable expression), hand:right|left, ends:flatTrim|onePitchSetback, representation:geometry|schematic. Geometry models the ISO 68-1:2023 basic axial profile; no ISO 965 fit/tolerance is claimed. Schematic records intent and preserves the solid. thread.update takes the EXISTING feature_id plus changes, optionally expected_change_count. A size cannot require adding absent stock. Query kind=features reports representation and editable fields; update is one ordinary undoable edit and saves through the document's existing CAS. Unsupported stock, stale selections or invalid rebuilds commit nothing.

        feature.mirror accepts bodyID, keepOriginal?, and either planeID, sketchID, or the existing absolute planeOrigin/planeNormal. Named planes retain the actual record identity; edits to the original datum/sketch move the same mirrored result. Use parameters update on the same feature with changes.plane_id or changes.sketch_id to rebind it; keep_original controls source retention. Do not mix a named plane with coordinates. Imported exact roots are preserved in the same undo step.
        feature.split accepts bodyID plus exactly one cutter: planeID, sketchID, or planeOrigin + planeNormal. A sketchID without seedPoint splits by its infinite plane; add seedPoint:[u,v] to split by that sketch's enclosed profile, including holes. Both outputs are exact solids committed in one undo. Query kind=features returns their fixed output_body_ids and saved cutter; changing the original source dimensions, referenced plane or profile rebuilds the same outputs. Missing/deleted cutters fail without substituting another region. The first output retains the source bodyID.
        For feature.draftFace and feature.replaceFace, referencePlane accepts exactly one {planeID}, {sketchID}, or {bodyID,face,query_token} from the current native document. A face is a 1-based kernel index; another target body needs its own faces query_token (or face_signature). A target on the edited body may reuse the outer current face query_token. Do not also send neutralOrigin/neutralNormal or targetOrigin/targetNormal when referencePlane is present. The app captures stable named-face and writer identity; it never trusts caller-authored proof. Target changes rebuild the SAME feature. A removed/suppressed/stale target refuses instead of using cached coordinates. Query kind=features returns the saved reference_plane; angle/flip updates preserve it. Omit referencePlane for the existing absolute-plane behavior.

        ## Environment and scene lights

        material payload.action=environment.read returns the actual shared three presets, current environment, floor, shadows and change_count. environment.update accepts active_environment (studio|daylight|dark), target_environment (optional preset to edit; otherwise the active preset), settings {light_intensity:0...16, light_direction:[x,y,z] finite nonzero, background_color:[r,g,b] in0...1}, floor_visible, floor_color:[r,g,b], floor_size_mm:10...200000, shadows_enabled, and optional expected_change_count for a stale-edit check. Numeric and boolean fields are distinct JSON types. Omitted values and other presets are preserved; invalid payloads make no changes. Both the Environment inspector and this tool call the same document appearance command: one undoable edit, ordinary task-authorized CAD mutation, saved with the document. Identical settings do not add undo history. For independent scene lights, environment.update takes lights:[{id?,name,kind:directional|point|spot,enabled?,position_mm:[x,y,z],direction:[x,y,z],color:[r,g,b],intensity,radius_mm?,inner_angle_degrees?,outer_angle_degrees?,casts_shadow?}]. This replaces the light list; preserve returned IDs when editing. Maximum eight lights; positions/ranges are mm, directional intensity is lux, point/spot intensity lumens. Point shadows are unsupported. An empty list turns off dynamic lights; preset_lights:true restores the preset instead. environment.import asynchronously imports a panoramic 2:1 image using name and asset_base64, up to 64 MiB and 16 megapixels. Original HDR bytes are preserved. environment.update can change environment_map:{rotation_degrees,intensity:0...16,shows_background} or remove it with null. environment.read returns resource identity and metadata, never image bytes. The same lights and map feed Present, still capture and animation export; engineering Edit remains the simplified preview. Read the current values before editing. Capture returns real pixels of the current renderer; no generated preview substitutes for it.

        ## M07 associative datum planes (angle and three-point)

        These six actions extend the EXISTING parameters payload and the SAME parameters route; they do not add a top-level field, a new tool or a new executor:

        - datum.anglePlane.create {body_id, face_index, query_token, expression (degrees), hinge_x?, hinge_y? (unit direction in the source-face attachment frame; default 1,0), size?}
        - datum.anglePlane.update {plane_id, expression?, expected_expression?, hinge_x?+hinge_y?, body_id?, face_index?, query_token?, size?}
        - datum.anglePlane.delete {plane_id}
        - datum.threePointPlane.create {points:[{sketch_id, entity_id, role:endpointA|endpointB|center} exactly three distinct], size?}
        - datum.threePointPlane.update {plane_id, points? (all three) | point_index?+point?, expected_points?, size?}
        - datum.threePointPlane.delete {plane_id}

        Angle expressions are degrees end to end; conversion to radians happens once in the resolver. The hinge is a finite unit direction in the frozen source-face attachment frame and is normalized once; source-face reselection requires the complete fresh body/face/query_token triple. Three-point planes persist exactly three semantic sketch point identities; no world coordinate is stored. They resolve their current world millimetres from the source sketches' resolved support planes. Roles are endpointA/endpointB for line/rect and center for circle/arc/ellipse/polygon/open-spline endpoints; closed splines, arc rim points, rect centres, spline interior/control points and whole are not offered. Deleted or replaced entity ids are broken references; there is no nearest-point or index fallback. Collinear/coincident points, missing references, cycles, suppressed/rolled-back writers and forward dependencies refuse before commit. Query kind=planes reports kind angle|threePoints, definition_version, expression/formula/expression_unit (deg), hinge_local, points with sketch/entity/role/point_local/point_world/resolved, source ids/roles and supported_operations. Every create/update/delete is an ordinary atomic undoable document edit with the document's existing revision/ownership CAS; each matching delete refuses while referenced.

        ## Native import file groups and units (E27/E28/E30)

        action=import keeps the existing source_path and optional unit_scale (millimetres per file unit). payload may add {"units":"mm|cm|m|in|ft","resources":{"relative/reference.png":"workspace/path.png"}}. Each resource path is independently authorized through the same task-workspace guard; the model cannot grant access, auto-read sibling directories or fetch URLs. Select the corresponding exact files in the native picker, or supply one complete ZIP. OBJ/STL and unitless ZIP contents need an explicit unit; a heuristic is a preview hint only. Conflicting, boolean, non-finite or nonpositive scale input refuses. Missing/corrupt maps/buffers, unknown required extensions, sparse accessors and unsupported primitive/mapping modes report the actual source limitation without importing fewer parts. Read the proposal's static-import retained/discarded report before apply: editable hierarchy, animation/rig/morph/modifiers and unsupported channels remain in the unchanged original source. Loose USD external assets currently refuse and require a self-contained USDZ; .blend/USD recognition does not claim full scene editing. New mesh groups freeze source+resource digests and resolved units in an internal versioned proposal operation; apply refuses changed/missing resources, cancelled work and stale document identity. No new tool, approval, database schema or arbitrary host path is introduced.

        ## UV authoring (X09)

        Use the existing action=material with payload.action=uv.read|uv.seams|uv.unwrap|uv.pack|uv.transform|uv.createSet|uv.activateSet|uv.removeSet|uv.status|uv.cancel. These are ordinary document edits using the same Body, material snapshots, undo and save path; no new tool or approval exists. uv.read needs body_id and returns source_sha256, live_mesh_sha256, change_count, paged source edges (edge_offset/edge_limit 1...200), seams, UV set ids and island_ids. Every write requires body_id, exact source_sha256 and expected_change_count from that read. uv.seams replaces the whole seams array of zero-based source vertex pairs (seams:[] clears it). uv.unwrap accepts resolution 64...2048 and padding 0...32; marked sides are hard chart boundaries, and additional automatic cuts are allowed. uv.pack repacks the active set. uv.transform takes island_ids plus optional translate:[u,v], rotation_degrees and scale:[u,v] (positive 0.001...1000); transforms pivot around the selected islands' UV bounds. uv.createSet duplicates the current or named set_id, optionally name (1...64 characters); uv.activateSet and uv.removeSet need set_id; at most eight sets, at least one retained. Read actual_width/actual_height, never claim the requested size was achieved. The active set uses existing RenderMesh.texcoords and GLB TEXCOORD_0; all sets/seams remain in the native package. Only real UV records raise the shared unreleased package floor to 7; ordinary documents keep their existing floor.

        A geometry edit retains old UV bytes but source_changed=true makes them uneditable. To unwrap the changed mesh, explicitly pass rebase:true with source_sha256 set to the read's live_mesh_sha256 and the current change_count; there is no old-index or nearest-geometry fallback. The worker is off-main, input-limited to 50,000 triangles/150,000 vertices, globally serialized at the native adapter, cooperatively cancellable with the current 15-minute heavy-task budget explicitly passed to the bridge, and joined before return. Cancellation, document close or a changed live source discards output without a command. UV authoring changes no BRep, material binding or feature. Check texture appearance through the actual viewport capture and the existing material mapping; projected materials continue to use their explicitly chosen projection. This is UV authoring, not texture baking.

        ## Animation keyframe authoring (X23-X25)

        Supported authored targets are the presentation camera and VISIBLE placed leaf assembly instances (kind camera|instance); this build has no body/visibility/material/light/bone/physics tracks. addTrack kind=instance needs instance_id from the stable placed occurrence (query kind=assembly), never a source body id.

        setKeyframe updates the SAME record when keyframe_id is present: time alone moves it and keeps its value/interpolation/curve; an explicit camera or translation_mm/rotation/rotation_degrees replaces the value; interpolation is linear|easeInOut; optional timing_curve {x1,y1,x2,y2} is a cubic-Bezier timing curve for the segment from this key to the next (all four values in 0...1) and overrides interpolation while valid; clear_timing_curve removes it. Omitted value fields on a keyframe_id update keep the existing value instead of inventing one. A new key or a move onto another key's time refuses with animation_keyframe_exists or animation_keyframe_conflict; pass replace:true only to update the key already at that exact time. Decreasing a clip duration below an existing key time refuses with animation_duration_conflict instead of dropping keys.

        list/query expose every stable clip/track/keyframe id plus time, interpolation, timing_curve, camera/instance values and issues, so the same records can be edited again. evaluate samples those exact records at time or frame/fps and never writes the document, geometry or assembly baseline. The native timeline uses these same records for add/select/move/delete, value editing, interpolation and the timed curve; it does not keep a second keyframe store. A stored timing_curve raises the animation document to schema 2 and the package floor to the existing associative version 2; an older app version opens that package read-only instead of silently dropping the curve. An unreadable or future stored curve is preserved and reported uneditable; the curve is never replaced by linear/ease interpolation on a later edit.

        ## M08 associative construction axes and datum points

        These six actions use the same parameters payload/route and the same atomic undoable document transaction. They store semantic source identities plus an explicit definition version; the cached line/point is only display state.

        - datum.axis.create {kind:face|edge|cylinder|twoPoints|twoPlanes, ...} — face: body_id + face_index + query_token of one exact named planar face (the face normal through its anchored point); edge: body_id + edge_index + query_token of one straight kernel edge (the edge line); cylinder: body_id + face_index + query_token of one exact named cylindrical face (the face's own analytic axis line and its axis point, never a centroid or bbox guess); twoPoints: points:[{sketch_id,entity_id,role} or {point_id}, exactly two distinct]; twoPlanes: plane_ids:[two construction plane ids] (their intersection line). offset? moves a face axis in its frozen in-plane frame / an edge axis along its frozen perpendicular (mm); size? is the drawn length only.
        - datum.axis.update {axis_id, offset?, expected_offset?, size?, or the complete kind-specific source fields to reselect} — two-point/two-plane/cylinder axes follow their sources and have no offset; a cylinder reselect must name a cylindrical face.
        - datum.axis.delete {axis_id} — refuses while a pattern, revolve or datum point consumes the axis.
        - datum.point.create {kind:faceCenter|edgePoint|twoPointMidpoint|axisPoint|axisPlane, ...} — faceCenter: body_id + face_index + query_token; edgePoint: body_id + edge_index + query_token + offset? (signed mm along the edge from its midpoint); twoPointMidpoint: points:[two distinct sources]; axisPoint: axis_id + offset? (signed mm along the axis); axisPlane: axis_id + plane_id (their intersection).
        - datum.point.update {point_id, offset?, expected_offset?, or the complete kind-specific source fields to reselect}
        - datum.point.delete {point_id} — refuses while another axis/point consumes the point.

        A circular pattern and a REVOLVE both store the axis IDENTITY: feature.update changes.axis_id = construction axis UUID (or null) keeps the consumer's line resolved from that axis on every replay, so source edits carry the array/revolve and a broken source refuses instead of falling back to the cached line. Clearing it freezes the axis's CURRENT resolved line into the consumer, so the geometry at that moment is kept and later source edits no longer move it; clearing while the source is broken refuses. A revolve additionally requires the axis to lie in its sketch plane (the kernel's revolve axis is 2D there); a non-coplanar axis is refused, never projected. A parallel/coincident two-plane source, coincident two-point source and a parallel axis/plane point refuse explicitly; a missing, replaced, suppressed, rolled-back or forward writer is a broken reference. Query kind=axes reports kind, surface_mode (planar|cylinder), definition_version, source ids, frozen source radius for a cylinder, offset expression/formula (mm) where the kind has one, the CURRENT resolved frame, consumer ids (pattern/revolve/point) and status. Query kind=datumPoints reports the five point kinds the same way. An unreadable definition version opens the document read-only with its original bytes.
        """#),
        Topic(name: "loft-surfaces", text: #"""
        # Versioned loft and surface parameters

        Use the EXISTING cad.document action="parameters" with payload as one JSON object STRING. The inner payload.action selects loft.describe, loft.create, loft.update, surface.catalog, surface.create, surface.update or surface.inspect. Do not invent feature.surface, another tool, a nested {op,args} envelope or a permission grant. Read-only describe/catalog/inspect still obey document ownership; all mutations use the same atomic graph/undo/save authority.

        Closed solid loft: query features/sketches for real identities. loft.describe needs feature_id. loft.create needs ordered sections:[ProfileRef], optional definition:{version:1,ruled:boolean} and optional boolean: BooleanIntent; new creation always stores an explicit v1 definition. ProfileRef is {sketchID:{raw:UUID},entityIDs:[UUID],holeEntityIDs:[[UUID]],seedPoint?:[x,y]}. Pair each hole explicitly across every section. loft.update needs the EXISTING feature_id and changes:{sections?:[ProfileRef],definition?:{version:1,ruled:boolean}}; it replaces/reorders that same feature, preserves IDs and uses one undo. A legacy missing definition retains its old replay/quality until an explicit update migrates it; merely reading/saving does not upgrade it. Guides and specified start/end tangent/curvature constraints are refused, never replaced by global smoothing or fitted meshes.

        surface.catalog describes implemented operations/limits. surface.create needs definition; surface.update needs the EXISTING feature_id plus the complete updated definition and keeps its operation/first source BodyID. Use expected_change_count from a current query for writes. Definition: {version:1,operation:"loft"|"trim"|"patch"|"sew"|"thicken",sections?:[SweepPathDefinition],sources?:[BodyRef],ruled?:bool,tolerance?:mm,trim?:{uMin,uMax,vMin,vMax},thickness?:signed_mm,requireClosed?:bool}. BodyRef is {producer:{raw:current_writer_feature_UUID},bodyID:{raw:body_UUID}}. SweepPathDefinition is {version:1,segments:[{sketchID:UUID,entityID:UUID,reversed?:bool}]}; its sketchID is a UUID STRING, unlike ProfileRef.sketchID's raw wrapper. Each open section uses one sketch plane and equal edge counts. Replace/reorder selected edges explicitly; no mesh samples define a surface.

        loft creates an independent open surface from 2-64 open sections. trim accepts one certified rectangular face; call surface.inspect {body_id} and derive bounds from its actual face_domains, never assume 0...1. patch fills all closed PLANAR free-boundary wires; nonplanar cases refuse. sew needs at least two exact authored surfaces; requireClosed:true refuses remaining free edges. thicken takes one surface and a nonzero signed thickness (mm): open sheets follow the authored normal; positive on a closed shell grows outward from its enclosed volume. Closed-shell thickening forms a cavity; a merely valid original solid is not success. Inputs must be actual graph-owned surfaces, not unowned imported IGES roots. Actual geometry, closure and tolerance still decide whether a supported operation succeeds. A refusal changes no graph, undo entry or saved geometry.

        surface.inspect {body_id,before_feature_id?} returns actual quality, valid/closed/free_edges, face_domains, trim_supported/planar_patch_supported, document change_count and source:BodyRef. Use that source object directly; authoring_input:false means it cannot be consumed as an authored surface. For an existing step, pass before_feature_id=that feature_id to inspect its original input surface rather than its current solid output; scope=featureInput is explicit. Inspect before the next operation. Future semantic definitions remain opaque/read-only with their original bytes. Versioned authoring requires the existing unreleased package floor 7; ordinary legacy lofts retain their old floor. Image observation remains on the existing model vision capability path; an image never supplies a CAD reference or tool permission.

        ## Decodable payload examples
        The following use VALID SYNTHETIC UUIDS only to show exact JSON shapes. Replace them with current query identities, generations and observed trim bounds before execution:
        \#(CadNativeEditActions.loftSurfaceExamples.joined(separator:"\n"))
        """#),
        Topic(name: "formats", text: #"""
        # Formats and exports

        ## format
        import or native export: explicit format. Import (step/stp, iges/igs, stl, obj, glb, gltf, usd/usda/usdc/usdz, blend, zip) defaults to the source_path extension. External glTF/OBJ resources must be supplied explicitly in payload.resources; missing resources are named and refuse the whole import. ZIP must contain one unambiguous model root. Static geometry, baked placement and supported materials are retained; unsupported editable scene semantics are reported before import. Native export accepts step/stp, iges/igs, stl, obj, obj_bundle, 3mf, glb, usdz, pdf, svg, dxf and csv; gltf is import-only (export writes glb), and 3mf plus pdf/svg/dxf/csv are export-only in this adapter. STEP writes closed exact solids; IGES writes exact closed solids AND open surfaces (surface bodies are never flattened to a mesh). obj_bundle writes one .zip containing model.obj, model.mtl and relative texture resources; plain obj remains a single .obj with UVs and no materials. pdf/svg/dxf/csv are drawing-page exports and require page_id; usdz is available where the platform USDZ writer is supported (otherwise usdz_unavailable). The output suffix must match the selected format: step/stp -> .step/.stp, iges/igs -> .iges/.igs, obj_bundle -> .zip, every other export -> .<format> (for example .3mf, .glb, .usdz, .pdf, .svg, .dxf, .csv); a mismatched suffix is refused rather than silently renamed.

        ## output
        export relative path. 2D defaults to <name>.export.dxf. Native defaults to <name>.export.step; accepted native formats: step/stp, iges/igs, stl, obj, obj_bundle, 3mf, glb, usdz, pdf, svg, dxf, csv; the path must stay inside the workspace and its suffix must match the format. obj_bundle writes a .zip (model.obj + model.mtl + relative textures) and requires a .zip output path; plain obj writes a single .obj with UVs and no materials. A pdf/svg/dxf export is a DRAWING-page export and also needs page_id (from query kind=drawings). A csv export writes the COMPLETE BOM table for that drawing page (all rows and columns, UTF-8 RFC 4180) and also needs page_id and a .csv output path. usdz export is platform-guarded and reports usdz_unavailable where the writer is unavailable. With scope=assembly use .step, .glb or .usdz (part-scope iges and obj_bundle are also available): placed occurrences are resolved from the saved assembly, not flattened document bodies.

        ## scope
        export: part = selected/all document bodies (historical default); assembly = saved placed occurrences, including nested subassemblies and visible instances of hidden definitions. Hidden instances are excluded. Assembly export supports step, glb and usdz; IGES is part-scope only.

        ## page_id
        export: the native drawing page id for pdf/svg/dxf drawing exports and the complete BOM CSV table export, exactly as query with kind=drawings returned it.

        ## body_ids
        export scope=part: exact document body ids. Omit/empty to export every body (historical default).

        ## instance_ids
        export scope=assembly: exact placed occurrence ids from query kind=assembly/report. Omit/empty for every visible placed part. A subassembly id includes its visible descendant parts.

        ## accept_partial
        export: explicit acknowledgement that the coverage receipt is incomplete (for example STEP with mesh-only objects or open surfaces, or IGES with mesh-only objects). Without it an incomplete plan returns coverage_incomplete and writes nothing.

        ## dry_run
        export: return the coverage receipt only (counts, included/excluded occurrence ids and reasons); no file is written. Requires an explicit scope.
        """#),
        Topic(name: "workflows", text: #"""
        # Workflows

        Create and edit a native document
        1. action=create with path and optional name.
        2. action=propose with op=sketch.create and args={"origin":[0,0,0]} (or omit origin for the ground plane).
        3. action=apply with the exact proposal_id.
        4. action=propose with op=sketch.addEntities and args={sketchID,entities:[...]}; then apply.
        5. action=propose with op=feature.extrude and args={sketchID,seedPoint:[x,y],distance}; then apply.
        6. action=measure or query to verify; action=save; action=export for a separate verified copy.

        Text
        Use op=sketch.addText with args={sketchID,text,height,fontName?,origin?}. The glyphs become real closed line loops in ONE undo step (counter loops are holes). Apply, then extrude the closed profiles. A missing font or a visible character without a vector outline refuses with unsupported_font / unsupported_glyphs and adds nothing. There is no standalone mesh.text operation.

        Read and inspect
        read/query/measure/locate/check are deterministic. Never invent entity ids, face/edge indices, query tokens or visual observations. Use query kind=faces or edges for a query_token before an index-based edit; requery_required means the proof is stale.

        Apply authority
        action=apply names the exact stored proposal. A human-reviewed CAD UI grant_id and the runtime-approved call authority for that exact apply are alternative trusted paths; the model cannot mint or replay either.

        Versions
        list/compare/recoveries/record are read-only. create/restore/delete/recover/discard_recovery are ordinary task-authorized CAD edits with revision/ownership CAS. Restore keeps the pre-restore state as a recovery version, and in-memory undo does not cross a restore.

        Help
        Call capabilities with payload {"documentation":"topics"} to enumerate topics, then page exactly one topic. Every page reports page/page_count, total_bytes, next_page, topic_sha256, guide_sha256 and content_sha256. The built-in guide is descriptive and never grants permissions.

        """#),
        Topic(name: "limitations", text: #"""
        # Limitations and truthful evidence

        - This guide is description, not authority. It never grants tool, file, approval, environment, workspace or CAD authority. Every call still goes through the runtime's normal permission, approval, workspace, revision/SHA, environment and ownership checks.
        - Text-only local models do not receive images. capture/observe return real image artifacts plus hashes; a text-only model must measure/query rather than claim to have seen an image. Do not enable a saved vision capability unsupported by the engine.
        - Temporary chat keeps its existing read-only outer ceiling: material/parameter/animation/scene mutations, exports and long jobs are refused by that scope. This guide does not broaden it.
        - A native .floecad written by a newer app version opens read-only and is refused here.
        - STEP/IGES/BREP pixels come from a lossy display triangulation, not native editable B-Rep.
        - A screenshot does not establish face IDs, B-Rep topology or manufacturing dimensions.
        - Never claim an edit, measurement or visual observation without a tool result. A success string is not evidence.
        - Do not hand-write .floecad package files, manifest.json or zip bytes; use create.

        """#),
        Topic(name: "compatibility", text: #"""
        # Compatibility reference

        This section preserves the original interface descriptions for existing integrations and older tool records. Read the current topics and capabilities for current formats, additions and availability. It does not grant authority.

        ## Original overview
        Export native CAD with action "export": scope=part keeps the historical selected/all document-body behaviour; scope=assembly writes the saved placed occurrences (nested subassemblies, exact occurrence ids/paths and world transforms), never a flattened document.bodies copy. Add dry_run=true for the coverage receipt only; an incomplete receipt (for example STEP with mesh-only objects) writes nothing unless accept_partial=true is explicit. Observe an original mesh or CAD-surface file, or an authorised native `.floecad` document, with action "observe" without importing, copying or modifying it: choose 1...4 finite views and an optional projection (includeImages=false permits no views for hierarchy-only queries); for GLB/glTF only, a real scene/camera/clip/time; for native documents, optional expectedRevision/expectedChangeCount/expectedSourceSHA256 generation pins. Native frames are real ephemeral offscreen engineering renders of the live scene (renderer=engineering, never an active Present claim) with no change to the user's camera, selection, preferences, saved appearance, playback or undo history; camera/clip/time selections are refused and animated frames use action="animation". Consume actual image artifacts plus source/image hashes and the paged native object rows (stable ids + query_token/generation) bound to the same revision/change_count. GLB/glTF keep the three.js scene path; other originals use the bundled Online3DViewer and STEP/IGES/BREP keep their local display-triangulation conversion. A screenshot does not establish CAD face IDs, B-Rep topology or manufacturing dimensions. Create, import into, read, query, measure, propose changes to, apply confirmed proposals to, save and export a CAD document. The document representation decides the engine: a DWG/DXF drawing runs in the local 2D engine, a native `.floecad` package runs in the parametric 3D kernel. Use action "create" (path/name) to make a new EMPTY native `.floecad` package through the built-in factory — never create the folder, manifest or zip by hand and never guess the internal package layout. Use action "import" on an EXISTING `.floecad` to add the geometry of a workspace STEP/STP, IGES/IGS, STL, OBJ, GLB or glTF file: it drafts a proposal on a throwaway copy and returns a preview. STEP gives exact editable solids; IGES solids are exact and open shells/faces become exact surface bodies that can be moved/rotated/scaled, painted and re-exported to IGES, but cannot take solid boolean/fillet/shell; STL/OBJ/GLB are render meshes with no parametric history. Use action "reference" to attach/check/update/inspect an external native `.floecad` part from the authorized task workspace: source_path is a path request resolved by the host guard (never a model grant); attach/update are ordinary committed CAD edits with source/staged hash CAS, while inspect/check are read-only. Propose binds an exact document revision and SHA-256 and returns a preview without writing. Apply commits ONE atomic undoable transaction for the exact proposal the approved call names: a `grant_id` selects the human-reviewed CAD UI path, and WITHOUT one the runtime-approved call authority for that exact apply authorizes it automatically (the model cannot mint or replay either; the proposal's revision/SHA is re-verified against the live document at commit). 2D edits are lines, circles, arcs, LWPolylines, text, dimension/leader creation plus move/copy/rotate/scale/mirror/trim/extend/offset and layer management. Existing Linear/Aligned dimensions support text and placement updates; unattached leaders support vertex updates. setLineEndpoints updates supported direct native DIMASSOC relationships atomically; unknown, chained, external or unsupported affected relationships refuse the edit. Other dimension types remain read only when updating existing annotations. Query each entity operations list before editing. 3D, blocks, xrefs, splines and proxy graphics are retained read-only in the 2D engine; they are never flattened. Units stay drawing units when undefined. Native documents add parametric features, assembly constraints, drawings, ShapeScript and mesh operations through the typed operation vocabulary (`op` + `args`; feature.extrude, feature.hole, feature.boolean, ...) and the three_d_* aliases; status/cancel report durable native jobs. Workflow: create → propose sketch.create → apply → propose sketch.addEntities → apply → propose feature.extrude → apply → measure → export. For text use the native text-sketch route instead of the unavailable mesh.text: propose sketch.addText {sketchID,text,height,fontName?,origin?} → apply → propose feature.extrude on the resulting closed profiles (holes are real counter loops) → apply → measure. Every native propose sends op at the TOP LEVEL beside action and path. Its args is a serialized JSON object containing ONLY the operation parameters, never another {op,args} envelope. For extrusion, serialize {sketchID,seedPoint:[x,y],distance:mm} into args. Native `.floecad` documents additionally accept action "material" (custom PBR material library: list/read/create/update/remove/ apply/applyFaces/reassignFaces/mapping/textures/unresolved/libraryExport/ libraryImport/libraryList/undo/redo; applied appearances are snapshots and survive library deletion), action "parameters" (typed feature parameter list/update/undo/redo; updateSketchEntity for an existing line's endpoints, a rectangle's position/size or a circle's center/radius; setSketchDimension/removeSketchDimension for driving length/distance/ angle/radius/diameter/width/height values (setSketchDimension accepts a positive number or a PUBLIC-unit expression such as width / 8; the exact expression is stored on the dimension formula while an angle's formula text stays in degrees and its solved value is stored in radians); variable.create/update/delete for named scalar formulas (one atomic undo including every dependent feature/sketch rebuild; delete refuses while referenced and rename rewrites identifier tokens); feature.setExpression to bind a formula to an existing formula-capable feature scalar in its PUBLIC unit; feature.suppress/delete/move with dependency checks and checkpoint rollback — units and actions come from query kind=features/sketches/variables/constraints), action "animation" (native camera/assembly keyframe clips: list/query/evaluate, createClip/updateClip/deleteClip/setActiveClip, addTrack/deleteTrack, setKeyframe/setCameraKeyframe/setPartKeyframe/deleteKeyframe, turntable/explodeReturn presets and undo/redo; capture returns an actual animated native frame; export renders a verified MP4, default 1920x1080 at 30 fps H.264 with no audio, and reports a durable task_id for status/ cancel; authored edits are ordinary undoable document commands and playback/scrub never changes the geometry or assembly baseline), and action "capture" (actual viewport PNG artifact bound to the document revision/change_count; only a vision-capable model may inspect it — otherwise measure, never claim to have seen the image). Native `.floecad` also accepts action "scene" (the SAME persisted sceneSettings overlay the editor uses: get/setSection/setSectionEnabled/flipSection/removeSection/ setMeasurementsVisible/addMeasurement/removeMeasurement/clearMeasurements/ undo/redo; setSection takes origin [x,y,z] mm plus normal or x_axis/y_axis; addMeasurement takes start/end world mm and returns its id/length; every mutation is one ordinary undoable document command committed with CAS, and no geometry is edited). Section cut and guide lines appear in screenshots/video, but numeric values are not baked into pixels; model exchange (STEP/IGES/GLB/USDZ/OBJ/STL/3MF) carries geometry only. Action "versions" creates, lists, compares, restores and deletes user-named whole-document checkpoints through payload.action; it also lists retained unpublished checkpoints and can recover or discard one. Compare pages through every difference with identity pins, and record returns the exact stored record JSON (byte-bounded chunk pages) when a summary detail omits fields. Restore is revision/CAS-checked, the pre-restore state is kept as a recovery version, and in-memory undo does not cross a restore. Restore creates a named branch checkpoint of the restored state by default while keeping the same document identity; create_branch=false restricts it to the in-place restore. Nothing is written by propose/preview/import; material/parameter/animation edits are undoable document commands committed with compare-and-swap, and temporary chat remains read-only.

        ## Original format field
        import or native export: explicit format. Import (step/stp, iges/igs, stl, obj, glb, gltf) defaults to the source_path extension; a JSON .gltf imports only when its buffers/images are embedded data URIs, external .bin/texture references are reported unsupported, and a self-contained .glb always works. Native export accepts step/stp, iges/igs, stl, obj, obj_bundle, 3mf, glb, usdz, pdf, svg, dxf and csv; gltf is import-only (export writes glb), and 3mf/usdz plus pdf/svg/dxf/csv are export-only in this adapter. STEP writes closed exact solids; IGES writes exact closed solids AND open surfaces (surface bodies are never flattened to a mesh). obj_bundle writes one .zip containing model.obj, model.mtl and relative texture resources; plain obj remains a single .obj with UVs and no materials. pdf/svg/dxf/csv are drawing-page exports and require page_id; usdz is available where the platform USDZ writer is supported (otherwise usdz_unavailable). The output suffix must match the selected format: step/stp -> .step/.stp, iges/igs -> .iges/.igs, obj_bundle -> .zip, every other export -> .<format> (for example .3mf, .glb, .usdz, .pdf, .svg, .dxf, .csv); a mismatched suffix is refused rather than silently renamed.

        ## Original operation field
        Native typed operation name at the TOP LEVEL beside action and path, never inside args. Native propose requires it; native measure may use it to name the measurement kind. Exact executable vocabulary (also reported by capabilities as operation_names): sketch.create, sketch.addEntities, sketch.addText, feature.extrude, feature.revolve, feature.hole, feature.pattern, feature.mirror, feature.transform, feature.boolean, feature.fillet, feature.chamfer, feature.shell, feature.sweep, feature.loft, feature.pushPull, feature.moveFace, feature.deleteFace, feature.replaceFace, feature.draftFace, body.setMaterial, item.setHidden. feature.scaleFace, feature.rotateFace are NOT executable in this build: the kernel returns exact_edit_unsupported without mutation and reports them under capabilities.unavailable_operations; use feature.transform for a whole-body transform instead. feature.pushPull supports mode=planarAxial only (mode=cylinderRadial refuses with exact_edit_unsupported); feature.moveFace supports normal-axis (dn) movement only (tangential du/dv refuses).
        """#)
    ]

    public static let topicNames: [String] = topics.map(\.name)

    public static let guideSHA256: String = FloeDigest.sha256Hex(Data(
        topics.map { $0.name + "\u{1f}" + $0.text }.joined(separator: "\u{1e}").utf8
    ))

    public static func fullText(for topic: String) -> String? {
        topics.first { $0.name == topic.lowercased() }?.text
    }

    /// Parses the optional documentation selector from a capabilities payload.
    /// A payload without `documentation` keeps the historical capabilities
    /// behavior. A malformed selector is refused; it is never silently ignored.
    public static func requestIfPresent(from payload: String?) throws -> Request? {
        guard let payload = payload?.trimmingCharacters(in: .whitespacesAndNewlines),
              !payload.isEmpty else { return nil }
        guard let data = payload.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        guard let selector = object["documentation"] else { return nil }
        let allowed: Set<String> = ["documentation", "page", "page_size", "limit"]
        let unknown = Set(object.keys).subtracting(allowed)
        guard unknown.isEmpty else {
            throw FloeError.validationFailed(
                "capabilities documentation payload has unknown field(s) "
                    + unknown.sorted().joined(separator: ", ")
                    + "; allowed: documentation, page, page_size, limit")
        }
        var topic: String
        if let name = selector as? String {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmed.isEmpty else {
                throw FloeError.validationFailed(
                    "capabilities documentation needs a topic name or true")
            }
            topic = trimmed
        } else if let flag = booleanValue(selector) {
            // Only a real CFBoolean is `true`; numeric 1 is not accepted as a
            // boolean substitute for the documentation selector.
            guard flag else {
                throw FloeError.validationFailed(
                    "capabilities documentation must be a topic name or true")
            }
            topic = "topics"
        } else if let nested = selector as? [String: Any] {
            guard let rawName = (nested["topic"] as? String) ?? (nested["name"] as? String),
                  !rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw FloeError.validationFailed(
                    "capabilities documentation object needs topic")
            }
            topic = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        } else {
            throw FloeError.validationFailed(
                "capabilities documentation must be a topic name, true, or {topic,page,page_size}")
        }
        var page = 0
        var pageSize = defaultPageSize
        if let nested = selector as? [String: Any] {
            if let value = try integer(nested["page"], field: "page") { page = value }
            if let value = try integer(nested["page_size"] ?? nested["limit"], field: "page_size") {
                pageSize = value
            }
        }
        if let value = try integer(object["page"], field: "page") { page = value }
        if let value = try integer(object["page_size"] ?? object["limit"], field: "page_size") {
            pageSize = value
        }
        return Request(topic: topic, page: page, pageSize: pageSize)
    }

    public static func validate(_ request: Request) throws {
        guard request.page >= 0 else {
            throw FloeError.validationFailed("documentation page must be zero or greater")
        }
        guard request.pageSize >= 256, request.pageSize <= maximumPageSize else {
            throw FloeError.validationFailed(
                "documentation page_size must be 256...\(maximumPageSize)")
        }
        if request.topic == "topics" {
            guard request.page == 0 else {
                throw FloeError.validationFailed("documentation topics has exactly one page (page 0)")
            }
            return
        }
        guard let topic = topics.first(where: { $0.name == request.topic }) else {
            throw FloeError.validationFailed(
                "unknown documentation topic '\(request.topic)'; choose "
                    + topicNames.joined(separator: "|"))
        }
        let pages = split(topic.text, pageSize: request.pageSize)
        guard request.page < pages.count else {
            throw FloeError.validationFailed(
                "documentation topic '\(request.topic)' page must be 0...\(max(0, pages.count - 1)) "
                    + "(page_count=\(pages.count))")
        }
    }

    /// A page of one topic. `topics` is served by the catalog reply instead.
    public static func page(_ request: Request) throws -> Page? {
        try validate(request)
        guard request.topic != "topics",
              let topic = topics.first(where: { $0.name == request.topic }) else {
            return nil
        }
        let pages = split(topic.text, pageSize: request.pageSize)
        guard request.page < pages.count else { return nil }
        let slice = pages[request.page]
        return Page(
            topic: topic.name,
            page: request.page,
            pageCount: pages.count,
            pageSize: request.pageSize,
            characterOffset: slice.characterOffset,
            characterCount: slice.text.count,
            byteOffset: slice.byteOffset,
            byteCount: slice.text.utf8.count,
            totalBytes: topic.byteCount,
            totalCharacters: topic.characterCount,
            nextPage: request.page + 1 < pages.count ? request.page + 1 : nil,
            contentSHA256: FloeDigest.sha256Hex(Data(slice.text.utf8)),
            topicSHA256: topic.sha256,
            guideSHA256Value: guideSHA256,
            text: slice.text
        )
    }

    public static func responseJSON(for request: Request) throws -> String {
        try validate(request)
        if request.topic == "topics" {
            let rows: [[String: Any]] = topics.map { topic in
                let count = split(topic.text, pageSize: request.pageSize).count
                return [
                    "name": topic.name,
                    "bytes": topic.byteCount,
                    "characters": topic.characterCount,
                    "sha256": topic.sha256,
                    "page_count": count,
                ]
            }
            return try encode([
                "ok": true,
                "documentation": [
                    "guide_version": guideVersion,
                    "guide_sha256": guideSHA256,
                    "topics": rows,
                    "default_page_size": defaultPageSize,
                    "maximum_page_size": maximumPageSize,
                    "selector": "payload JSON {documentation:\"<topic>|topics\",page:0,page_size:3000}; page is zero-based; copy next_page",
                ],
                "permissions": "Documentation only; this reply never grants tool, file, or approval authority.",
            ])
        }
        guard let page = try page(request) else {
            throw FloeError.validationFailed("documentation topic '\(request.topic)' is not pageable")
        }
        var documentation: [String: Any] = [
            "topic": page.topic,
            "page": page.page,
            "page_count": page.pageCount,
            "page_size": page.pageSize,
            "character_offset": page.characterOffset,
            "characters": page.characterCount,
            "byte_offset": page.byteOffset,
            "bytes": page.byteCount,
            "total_bytes": page.totalBytes,
            "total_characters": page.totalCharacters,
            "topic_sha256": page.topicSHA256,
            "guide_sha256": page.guideSHA256Value,
            "content_sha256": page.contentSHA256,
            "text": page.text,
        ]
        documentation["next_page"] = page.nextPage ?? NSNull()
        return try encode([
            "ok": true,
            "documentation": documentation,
            "permissions": "Documentation only; this reply never grants tool, file, or approval authority.",
        ])
    }

    private struct Slice {
        let text: String
        let characterOffset: Int
        let byteOffset: Int
    }

    private static func split(_ text: String, pageSize: Int) -> [Slice] {
        let limit = max(256, min(pageSize, maximumPageSize))
        var result: [Slice] = []
        var start = text.startIndex
        var characterOffset = 0
        var byteOffset = 0
        while start < text.endIndex {
            var end = start
            var bytes = 0
            while end < text.endIndex {
                let next = text.index(after: end)
                let charBytes = String(text[end]).utf8.count
                if bytes + charBytes > limit, end > start { break }
                bytes += charBytes
                end = next
            }
            // Prefer a line boundary in the last third of the page, so a page
            // stays readable without ever dropping content. The next page
            // starts at the exact next character.
            if end < text.endIndex, bytes > limit * 7 / 10 {
                var candidate = end
                var backtrack = 0
                while candidate > start {
                    let previous = text.index(before: candidate)
                    backtrack += String(text[previous]).utf8.count
                    if backtrack > limit / 3 { break }
                    if text[previous] == "\n" {
                        candidate = text.index(after: previous)
                        break
                    }
                    candidate = previous
                }
                if candidate > start {
                    end = candidate
                    bytes = text[start..<end].utf8.count
                }
            }
            let body = String(text[start..<end])
            result.append(Slice(text: body, characterOffset: characterOffset, byteOffset: byteOffset))
            characterOffset += body.count
            byteOffset += body.utf8.count
            start = end
        }
        return result
    }

    /// True only for an actual JSON/CoreFoundation boolean. On Apple
    /// platforms an `NSNumber` carrying numeric 0 or 1 also satisfies
    /// `is Bool`, so a plain boolean cast rejected a legitimate `page: 0`.
    private static func booleanValue(_ value: Any) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID()
        else { return nil }
        return number.boolValue
    }

    private static func integer(_ value: Any?, field: String) throws -> Int? {
        guard let value, !(value is NSNull) else { return nil }
        if booleanValue(value) != nil {
            throw FloeError.validationFailed("documentation \(field) must be an integer")
        }
        if let number = value as? NSNumber {
            // Int(exactly:) is the exact, nontrapping conversion: it rejects
            // fractions, non-finite values, 2^63 and every other value that is
            // not representable as Int, instead of rounding or trapping.
            switch String(cString: number.objCType) {
            case "d", "f":
                guard let int = Int(exactly: number.doubleValue) else {
                    throw FloeError.validationFailed(
                        "documentation \(field) must be an integer")
                }
                return int
            case "Q", "L", "I", "S", "C":
                // JSONSerialization parses a positive integer above Int64.max
                // as an unsigned CFNumber; int64Value would wrap it.
                guard let int = Int(exactly: number.uint64Value) else {
                    throw FloeError.validationFailed(
                        "documentation \(field) must be an integer")
                }
                return int
            default:
                guard let int = Int(exactly: number.int64Value) else {
                    throw FloeError.validationFailed(
                        "documentation \(field) must be an integer")
                }
                return int
            }
        }
        if let int = value as? Int { return int }
        if let number = value as? Double, let int = Int(exactly: number) {
            return int
        }
        throw FloeError.validationFailed("documentation \(field) must be an integer")
    }

    private static func encode(_ object: [String: Any]) throws -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else {
            throw FloeError.validationFailed("documentation reply could not be encoded")
        }
        return text
    }
}


// MARK: - Tool

public struct CadDocumentTool: AgentTool {
    public typealias Arguments = CadDocumentArguments

    public static let name = "cad.document"
    public static let toolDescription = """
    Create, inspect and edit CAD with one tool. The path suffix selects the engine: .dwg/.dxf = local 2D drawing; .floecad = native parametric 3D package. Actions: capabilities (engine/service catalogs and built-in help, read-only); create (new empty native package through the host factory; never hand-write package bytes); import (add STEP/IGES/STL/OBJ/GLB/glTF geometry to an existing package as a previewed proposal); read/query/locate/measure/check (read the document; native query kinds include bodies/sketches/constraints/features/edges/faces/planes/axes/datumPoints/variables/materials/assembly/drawings/scene/selection/animation); reference (attach/check/update/inspect an authorized external native part); propose/preview/apply/save/export (one atomic undoable edit; apply is bound to the exact proposal and revision/SHA and uses the runtime-approved call authority unless a human grant_id is present); material/parameters/animation/scene/versions (native undoable document commands with payload.action); capture/observe (real images only); status/cancel (durable native jobs). Use sketch.addText for text; there is no standalone mesh.text operation. Never claim an edit, measurement or visual observation without a tool result. For complete action, field, payload and format reference with examples, call capabilities with payload JSON {documentation:"topics"} then page a topic; this built-in help is descriptive and never grants permissions.
    """
    public static let riskLabels: Set<RiskLabel> = [.readsFiles, .writesFiles]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating
    public static let requiresHostScope = false

    /// Exact operation names the engine accepts; anything else is refused
    /// before it reaches the host.
    public static let supportedOperations: Set<String> = [
        "addLine", "addCircle", "addArc", "addLwPolyline", "addText", "addLeader",
        "addDimension", "updateDimension", "updateLeader", "setLineEndpoints", "move", "copy", "rotate", "scale", "mirror", "setText",
        "setRadius", "setLayer", "setColor", "setLineWeight", "delete", "trim",
        "extend", "offset", "addLayer", "updateLayer", "renameLayer", "deleteLayer",
        "batch",
    ]

    public static let parametersJSON = #"""
    {"type":"object","additionalProperties":false,"required":["action"],"properties":{"action":{"type":"string","enum":["capabilities","create","read","query","locate","measure","check","propose","import","reference","preview","apply","save","export","status","cancel","material","parameters","capture","observe","animation","scene","versions","three_d_snapshot","three_d_measure","three_d_propose","three_d_apply","three_d_assembly","three_d_drawing"],"description":"Required. Operation to run; see the tool description and the capabilities help for semantics."},"path":{"type":"string","description":"Document path in the task workspace (absolute workspace path allowed). Required except capabilities without path. .dwg/.dxf = 2D; .floecad = native 3D. create: new package path (parent created; outside workspace refused). import: existing .floecad receiving geometry. observe: original mesh/CAD-surface file or authorized native document, read only. Never hand-write package/manifest/zip bytes; use create."},"name":{"type":"string","maxLength":120,"description":"create: display name (max 120; any language; no '/', '\\\\', control characters or '..'; defaults to file stem; file name is uniquified separately). import: optional body name."},"source_path":{"type":"string","description":"import/reference: workspace-relative source resolved by the host guard. import accepts .step/.stp, .iges/.igs, .stl, .obj, .glb, .gltf; reference needs an existing native .floecad. The string never grants access."},"reference_action":{"type":"string","enum":["attach","check","update","inspect"],"description":"reference: attach | check | update | inspect (attach stages the first occurrence; update re-stages the same source body with hash CAS; check/inspect are read-only)."},"reference_id":{"type":"string","format":"uuid","description":"reference check/update: durable reference id from attach or assembly references."},"expected_source_sha256":{"type":"string","description":"reference update CAS: pinned source SHA-256."},"expected_staged_sha256":{"type":"string","description":"reference update CAS: pinned staged geometry SHA-256."},"source_body_id":{"type":"string","format":"uuid","description":"reference attach: stable source body UUID for a multi-body source; omit only for one body."},"format":{"type":"string","enum":["step","stp","iges","igs","stl","obj","obj_bundle","3mf","glb","gltf","usdz","pdf","svg","dxf","csv"],"description":"import/export format; enum is authoritative. Import defaults to source_path extension. Export suffix must match; pdf/svg/dxf/csv require page_id; obj_bundle writes .zip; usdz is platform-guarded; gltf is import-only."},"unit_scale":{"type":"number","exclusiveMinimum":0,"description":"import only: millimetres per unitless mesh file unit (STL/OBJ); ignored for exact/declared-unit formats."},"summary":{"type":"string","maxLength":2000,"description":"propose/import: concise change summary (max 2000)."},"operations":{"type":"array","maxItems":64,"description":"2D edits for propose on .dwg/.dxf (max 64); each item requires operation. Exact shapes and examples: documentation topic native-operations. Vectors are [x,y] or [x,y,0]; nonzero z refused.","items":{"type":"object","required":["operation"],"properties":{"operation":{"type":"string"}}}},"proposal_id":{"type":"string","format":"uuid","description":"propose reply id for preview/apply; send it exactly as printed."},"grant_id":{"type":"string","description":"apply: OPTIONAL human-reviewed UI grant. Omit to use the runtime-approved call authority for this exact apply. The model cannot mint or replay either; made-up values authorize nothing."},"revision":{"type":"integer","minimum":0,"description":"apply/capture/observe/material/parameters/animation/scene: optional base revision pin; mismatch is refused before mutation/capture. For observe it is the same pin as payload.expectedRevision."},"request_id":{"type":"string","description":"optional idempotency key; defaults to the tool call id."},"task_id":{"type":"string","description":"durable native task id (status reports one; cancel requires it)."},"kind":{"type":"string","description":"query/measure scope. 2D query: entities|text|layers|drawing|snap; 2D measure: distance|angle|radius|perimeter|area. Native query: bodies|sketches|constraints|features|edges|faces|planes|axes|datumPoints|variables|materials|assembly|drawings|scene|detail|snapshot|selection|animation. Native measure: body|distance|bounds|dof|interference|mesh|rebuild. capabilities kind=drawing|assembly|script|mesh returns service operations; full semantics: topic fields."},"scope":{"type":"string","enum":["part","assembly"],"description":"export: part = document bodies (default); assembly = saved placed occurrences incl. nested subassemblies and visible instances of hidden definitions. Assembly export: step, glb, usdz; IGES is part-scope only."},"points":{"type":"array","items":{"type":"array","items":{"type":"number"}},"description":"measure points: 2D distance 2, angle 3, area 3+; snap first row. Native distance exactly 2 [x,y,z] rows."},"handles":{"type":"array","items":{"type":"string"},"description":"2D handles: distance 2, angle 2 lines, radius 1, perimeter 1+. Native: body:<uuid>, face:<uuid>:<index>, edge:<uuid>:<index>; body/mesh/bounds accept body:<uuid>; bounds takes 1+."},"tolerance":{"type":"number","description":"snap/check tolerance in drawing units; native interference tolerance in mm."},"layer":{"type":"string","description":"2D query filter."},"entity_type":{"type":"string","description":"2D query filter: Line|Circle|Arc|LwPolyline|Text."},"text":{"type":"string","description":"2D query text contains."},"offset":{"type":"integer","minimum":0,"description":"query page offset (>=0)."},"limit":{"type":"integer","minimum":1,"maximum":500,"description":"query page size (1...500)."},"output":{"type":"string","description":"export relative path inside the workspace. 2D defaults to <name>.export.dxf; native to <name>.export.step. Suffix must match; pdf/svg/dxf/csv are drawing-page exports and need page_id; csv is the complete BOM. obj_bundle requires .zip. usdz is platform-guarded. With scope=assembly use .step/.glb/.usdz."},"page_id":{"type":"string","format":"uuid","description":"export: native drawing page id for pdf/svg/dxf and BOM csv, from query kind=drawings."},"body_ids":{"type":"array","maxItems":512,"items":{"type":"string","format":"uuid"},"description":"export scope=part: exact body ids; omit/empty = all bodies."},"instance_ids":{"type":"array","maxItems":512,"items":{"type":"string","format":"uuid"},"description":"export scope=assembly: exact placed occurrence ids from query kind=assembly/report; omit/empty = all visible parts; a subassembly includes visible descendants."},"accept_partial":{"type":"boolean","description":"export: explicit acknowledgement that the coverage receipt is incomplete; without it an incomplete plan writes nothing."},"dry_run":{"type":"boolean","description":"export: return the coverage receipt only; no file; requires scope."},"op":{"type":"string","description":"Native typed operation at TOP LEVEL beside action/path, never inside args. propose requires it; measure may name the kind. Executable/unavailable vocabulary, per-op arguments and examples: documentation topic native-operations. Unavailable ops refuse with exact_edit_unsupported and are reported by capabilities.unavailable_operations; feature.transform is the whole-body transform; feature.pushPull supports planarAxial or cylinderRadial; feature.moveFace is normal-axis only."},"args":{"type":"string","description":"JSON object STRING of ONLY the typed operation arguments (not an {op,args} envelope); units mm and degrees. Exact per-op contract/examples: documentation topic native-operations. Text route: sketch.addText; there is no standalone mesh.text operation; unsupported_font/unsupported_glyphs refuse without mutation."},"payload":{"type":"string","description":"JSON object STRING for workbench services, material/parameters/capture/animation/scene, versions and observe. Exact action vocabularies, fields, examples, CAS/page rules and content identity: documentation topic payloads. Versioned loft/surface parameter actions and exact JSON shapes: documentation topic loft-surfaces. capabilities: payload {\"documentation\":\"topics\"|<topic>,page,page_size} serves this built-in guide. observe supports expectedRevision, expectedChangeCount, expectedSourceSHA256, includeImages, views, projection?:perspective|orthographic, nodeOffset/nodeLimit/nextOffset; native frames use renderer=engineering, present_pixels=false."}}}
    """#.replacingOccurrences(
        of: "__NATIVE_EXECUTABLE_OPERATIONS__",
        with: CadNativeOperationVocabulary.executable.joined(separator: ", ")
    ).replacingOccurrences(
        of: "__NATIVE_UNAVAILABLE_OPERATIONS__",
        with: CadNativeOperationVocabulary.unavailable.joined(separator: ", ")
    )

    private let host: CadDocumentHost
    private let grants: CadProposalGrantStore

    public init(host: CadDocumentHost, grants: CadProposalGrantStore = CadProposalGrantStore()) {
        self.host = host
        self.grants = grants
    }

    /// The trusted interactive path calls this after the user accepts a
    /// preview; the returned token is the only way `apply` can succeed.
    @discardableResult
    public func issueUserGrant(for proposal: CadProposal) async -> String {
        await grants.issueGrant(proposal: proposal)
    }

    public func validate(_ args: CadDocumentArguments) throws {
        // Built-in help is static, read-only documentation. It needs no file
        // target and never reaches the host; reading it grants no authority.
        if args.action == .capabilities,
           let helpRequest = try CadDocumentHelp.requestIfPresent(from: args.payload) {
            if let raw = args.kind?.trimmingCharacters(in: .whitespacesAndNewlines),
               !raw.isEmpty {
                throw FloeError.validationFailed(
                    "capabilities documentation and kind are separate selectors; send exactly one.")
            }
            try CadDocumentHelp.validate(helpRequest)
            return
        }
        if args.action == .capabilities, args.path == nil {
            // Engine capability discovery without a document stays on the 2D
            // engine; a `kind` still has to name a real workbench service.
            if let raw = args.kind?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
               !CadServiceOperationCatalog.isKnownKind(raw) {
                throw FloeError.validationFailed(
                    "capabilities kind must be one of "
                        + CadServiceOperationCatalog.kinds.joined(separator: "|")
                        + " (got '\(raw)'); omit kind for the engine matrix.")
            }
            return
        }
        guard let path = args.path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty,
              path.count <= 1024, !path.contains("\0") else {
            throw FloeError.validationFailed("path is required for \(args.action.rawValue)")
        }
        let native = Self.isNativeRepresentation(path)
        switch args.action {
        case .observe:
            let extensionName = (path as NSString).pathExtension.lowercased()
            guard native || Self.observableOriginalExtensions.contains(extensionName) else {
                throw FloeError.validationFailed(
                    "observe reads original mesh and CAD-surface files (STL, OBJ, PLY, OFF, 3DS, DAE, FBX, 3MF, AMF, WRL, BIM, STEP, IGES, BREP, GLB, glTF) and an authorised native .floecad document; drawings use their 2D tools and Gerber/other formats remain unsupported here.")
            }
            _ = try Self.modelObservationRequest(args, native: native)
        case .capabilities:
            // `kind` here selects the native workbench-service detail page;
            // a typo or a 2D path must not silently ignore it.
            if let raw = args.kind?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
                guard CadServiceOperationCatalog.isKnownKind(raw) else {
                    throw FloeError.validationFailed(
                        "capabilities kind must be one of "
                            + CadServiceOperationCatalog.kinds.joined(separator: "|")
                            + " (got '\(raw)'); omit kind for the engine matrix.")
                }
                guard native else {
                    throw FloeError.validationFailed(
                        "capabilities kind=\(raw) describes the native .floecad workbench services; "
                            + "omit kind for the 2D engine matrix.")
                }
            }
        case .animation:
            guard native else {
                throw FloeError.validationFailed(
                    "animation is available for native .floecad documents only")
            }
            let payload = try Self.servicePayloadObject(args)
            let rawAction = (payload["action"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let action = CadNativeEditActions.animation.first(where: {
                $0.lowercased() == rawAction.lowercased()
            }) else {
                throw FloeError.validationFailed(
                    "animation requires payload.action ("
                        + CadNativeEditActions.animation.sorted().joined(separator: "|")
                        + "); got '\(rawAction)'")
            }
            if action == "capture" {
                let width = Self.intValue(payload["width"] ?? 1920) ?? 1920
                let height = Self.intValue(payload["height"] ?? 1080) ?? 1080
                let fps = Self.intValue(payload["fps"] ?? 30) ?? 30
                let format = ((payload["format"] as? String) ?? "png").lowercased()
                guard (64...4096).contains(width), (64...4096).contains(height) else {
                    throw FloeError.validationFailed(
                        "animation capture width and height must be 64...4096")
                }
                guard (1...60).contains(fps) else {
                    throw FloeError.validationFailed("animation capture fps must be 1...60")
                }
                guard ["png", "jpeg", "jpg"].contains(format) else {
                    throw FloeError.validationFailed(
                        "animation capture format must be png or jpeg")
                }
                if let frame = Self.intValue(payload["frame"]), frame < 0 {
                    throw FloeError.validationFailed("animation frame must be zero or greater")
                }
                if let time = Self.doubleValue(payload["time"]), !time.isFinite || time < 0 {
                    throw FloeError.validationFailed(
                        "animation capture time must be a finite seconds value")
                }
            }
            if action == "export" {
                let format = ((payload["format"] as? String) ?? "mp4").lowercased()
                guard ["mp4", "png_zip"].contains(format) else {
                    throw FloeError.validationFailed(
                        "animation export format must be mp4 or png_zip")
                }
                let alpha = ((payload["alpha"] as? String) ?? "opaque").lowercased()
                guard ["opaque", "transparent"].contains(alpha) else {
                    throw FloeError.validationFailed(
                        "animation export alpha must be opaque or transparent")
                }
                guard alpha == "opaque" else {
                    throw FloeError.validationFailed(
                        "transparent animation output is not supported: the native renderer keeps the scene's opaque background, and MP4 H.264/HEVC has no alpha channel")
                }
                let expectedExtension = format == "mp4" ? "mp4" : "zip"
                if let output = args.output {
                    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, trimmed.count <= 1024,
                          !trimmed.contains("\0"),
                          !trimmed.split(separator: "/").contains(".."),
                          (trimmed as NSString).pathExtension.lowercased()
                            == expectedExtension else {
                        throw FloeError.validationFailed(
                            "animation export output must be a workspace-contained .\(expectedExtension) path")
                    }
                }
                let width = Self.intValue(payload["width"] ?? 1920) ?? 1920
                let height = Self.intValue(payload["height"] ?? 1080) ?? 1080
                let fps = Self.intValue(payload["fps"] ?? 30) ?? 30
                guard width % 2 == 0, height % 2 == 0,
                      (64...4096).contains(width), (64...4096).contains(height),
                      width * height <= 3840 * 2160 else {
                    throw FloeError.validationFailed(
                        "animation export dimensions must be even, 64...4096, and within 4K")
                }
                guard (1...60).contains(fps) else {
                    throw FloeError.validationFailed("animation export fps must be 1...60")
                }
                if format == "mp4" {
                    let codec = ((payload["codec"] as? String) ?? "h264").lowercased()
                    guard ["h264", "hevc"].contains(codec) else {
                        throw FloeError.validationFailed(
                            "animation export codec must be h264 or hevc")
                    }
                    if let bitrate = Self.intValue(payload["bitrate"]),
                       !(250_000...80_000_000).contains(bitrate) {
                        throw FloeError.validationFailed(
                            "animation export bitrate must be 250 kbps...80 Mbps")
                    }
                } else {
                    let codec = ((payload["codec"] as? String) ?? "png").lowercased()
                    guard codec == "png" else {
                        throw FloeError.validationFailed(
                            "png_zip animation export codec must be png")
                    }
                    guard payload["bitrate"] == nil else {
                        throw FloeError.validationFailed(
                            "png_zip animation export does not use a video bitrate")
                    }
                }
            }
        case .create:
            // Create targets a NEW native package through the host factory.
            // The file name is sanitized/unique-ified by the host; the tool
            // only checks it addresses a .floecad inside the workspace.
            guard native else {
                throw FloeError.validationFailed(
                    "create makes a native .floecad package; DWG/DXF drawings cannot be created by this tool")
            }
            if let name = args.name,
               let issue = NativeCADPolicy.validateName(name) {
                throw FloeError.validationFailed(issue)
            }
        case .import:
            // Import ADDS geometry to an existing native package by drafting
            // a proposal; it never targets the 2D engine (DWG/DXF stay on
            // their own read/edit surface) and never writes directly.
            guard native else {
                throw FloeError.validationFailed(
                    "import adds geometry to a native .floecad package; DWG/DXF are not import targets")
            }
            guard let source = args.sourcePath?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !source.isEmpty, source.count <= 1024, !source.contains("\0") else {
                throw FloeError.validationFailed("import requires source_path (a workspace file)")
            }
            let inferred = (source as NSString).pathExtension.lowercased()
            // An explicit format must itself be supported; the EXTENSION is
            // authoritative for routing (a model cannot disguise a mesh as a
            // B-rep exchange by lying about format). An explicit format that
            // conflicts with a supported extension is refused.
            let explicitFormat = NativeCADPolicy.normalizedImportFormat(args.format)
            if let explicit = args.format, !explicit.trimmingCharacters(in: .whitespaces).isEmpty,
               explicitFormat == nil {
                throw FloeError.validationFailed("import format '\(explicit)' is not supported")
            }
            let format = explicitFormat ?? NativeCADPolicy.normalizedImportFormat(inferred)
            guard format != nil else {
                throw FloeError.validationFailed(
                    "import supports STEP/STP, IGES/IGS and native mesh formats (STL/OBJ/GLB/glTF/USD/USDZ/Blender/ZIP) (got \(inferred.isEmpty ? "unknown" : inferred))")
            }
            if let inferredFormat = NativeCADPolicy.normalizedImportFormat(inferred),
               let explicitFormat, explicitFormat != inferredFormat {
                throw FloeError.validationFailed(
                    "import format '\(args.format ?? "")' does not match the source extension '\(inferred)'")
            }
            if let scale = args.unitScale, !(scale.isFinite && scale > 0) {
                throw FloeError.validationFailed("unit_scale must be a positive finite number")
            }
        case .reference:
            guard native else {
                throw FloeError.validationFailed(
                    "reference targets a native .floecad document; DWG/DXF are not reference targets")
            }
            guard let rawAction = args.referenceAction?.trimmingCharacters(in: .whitespacesAndNewlines),
                  ["attach", "check", "update", "inspect"].contains(rawAction.lowercased()) else {
                throw FloeError.validationFailed(
                    "reference requires reference_action attach|check|update|inspect")
            }
            guard let source = args.sourcePath?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !source.isEmpty, source.count <= 1024, !source.contains("\0") else {
                throw FloeError.validationFailed(
                    "reference requires source_path (a workspace .floecad package)")
            }
            guard (source as NSString).pathExtension.lowercased() == "floecad" else {
                throw FloeError.validationFailed(
                    "reference accepts a native .floecad source package, not another CAD format")
            }
            let action = rawAction.lowercased()
            if action == "check" || action == "update" {
                guard let raw = args.referenceID,
                      UUID(uuidString: raw) != nil else {
                    throw FloeError.validationFailed(
                        "reference \(action) requires reference_id (a UUID from attach/references)")
                }
            }
            if let raw = args.sourceBodyID, !raw.isEmpty, UUID(uuidString: raw) == nil {
                throw FloeError.validationFailed("source_body_id must be a UUID")
            }
            for (label, value) in [("expected_source_sha256", args.expectedSourceSHA256),
                                   ("expected_staged_sha256", args.expectedStagedSHA256)] {
                guard let value, !value.isEmpty else { continue }
                let hex = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else {
                    throw FloeError.validationFailed("\(label) must be a 64-character SHA-256 hex string")
                }
            }
            if let name = args.name {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed.count <= 120, !trimmed.contains("\0") else {
                    throw FloeError.validationFailed(
                        "reference name must be 1...120 characters with no NUL")
                }
            }
        case .read, .save, .export:
            if let raw = args.pageID {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, UUID(uuidString: trimmed) != nil else {
                    throw FloeError.validationFailed(
                        "page_id must be a drawing page UUID from query kind=drawings")
                }
                guard native else {
                    throw FloeError.validationFailed(
                        "page_id addresses a native .floecad drawing page; the 2D engine exports the drawing itself")
                }
            }
            if args.action == .export {
                let scope = args.scope?
                    .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if let scope, !scope.isEmpty {
                    guard ["part", "assembly"].contains(scope) else {
                        throw FloeError.validationFailed(
                            "export scope must be part or assembly")
                    }
                }
                if let ids = args.bodyIDs {
                    guard ids.count <= 512 else {
                        throw FloeError.validationFailed("body_ids is limited to 512 ids")
                    }
                    for id in ids {
                        guard UUID(uuidString: id) != nil else {
                            throw FloeError.validationFailed("body_ids contains a non-UUID value")
                        }
                    }
                }
                if let ids = args.instanceIDs {
                    guard ids.count <= 512 else {
                        throw FloeError.validationFailed("instance_ids is limited to 512 ids")
                    }
                    for id in ids {
                        guard UUID(uuidString: id) != nil else {
                            throw FloeError.validationFailed("instance_ids contains a non-UUID value")
                        }
                    }
                }
                let explicitScope = !(scope?.isEmpty ?? true)
                if !explicitScope,
                   (args.bodyIDs?.isEmpty == false || args.instanceIDs?.isEmpty == false
                    || args.acceptPartial == true || args.dryRun == true) {
                    throw FloeError.validationFailed(
                        "body_ids, instance_ids, accept_partial and dry_run require export scope=part|assembly")
                }
                if scope == "part", args.instanceIDs?.isEmpty == false {
                    throw FloeError.validationFailed("scope=part selects document bodies; use body_ids, not instance_ids")
                }
                if scope == "assembly", args.bodyIDs?.isEmpty == false {
                    throw FloeError.validationFailed("scope=assembly selects placed occurrences; use instance_ids, not body_ids")
                }
                if args.dryRun == true {
                    guard native else {
                        throw FloeError.validationFailed("dry_run coverage is available for native .floecad exports only")
                    }
                }
            }
        case .status:
            if let task = args.taskID, task.isEmpty {
                throw FloeError.validationFailed("task_id must not be empty")
            }
        case .cancel:
            guard let task = args.taskID, !task.isEmpty else {
                throw FloeError.validationFailed("cancel requires task_id")
            }
        case .preview:
            guard args.proposalID != nil else {
                throw FloeError.validationFailed("preview requires proposal_id")
            }
        case .apply, .threeDApply:
            guard args.proposalID != nil else {
                throw FloeError.validationFailed("\(args.action.rawValue) requires proposal_id")
            }
            // `grant_id` is OPTIONAL: when present it selects the interactive,
            // human-reviewed UI grant path; when absent the ONLY authority is
            // the runtime-issued task authority for this exact approved call.
            if let revision = args.revision, revision < 0 {
                throw FloeError.validationFailed("revision must be >= 0")
            }
        case .query:
            if native {
                guard let kind = args.kind, Self.nativeQueryScopes.contains(kind) else {
                    throw FloeError.validationFailed(
                        "native query requires kind (\(Self.nativeQueryScopes.sorted().joined(separator: "|")))")
                }
            } else {
                // A query must name a kind; "entities"/"text" additionally accept
                // pagination/filter fields and "snap" requires one finite point.
                guard let kind = args.kind,
                      ["entities", "text", "layers", "drawing", "snap"].contains(kind) else {
                    throw FloeError.validationFailed("query requires kind (entities|text|layers|drawing|snap)")
                }
                if kind == "snap" {
                    guard let point = args.points?.first, point.count >= 2,
                          point[0].isFinite, point[1].isFinite else {
                        throw FloeError.validationFailed("snap query requires a finite point")
                    }
                }
                if let offset = args.offset, offset < 0 {
                    throw FloeError.validationFailed("offset must be >= 0")
                }
                if let limit = args.limit, !(1...500).contains(limit) {
                    throw FloeError.validationFailed("limit must be between 1 and 500")
                }
            }
        case .locate:
            guard let handles = args.handles, handles.count == 1, handles[0].count <= 128 else {
                throw FloeError.validationFailed("locate requires exactly one handle")
            }
        case .measure:
            if native {
                guard let kind = args.op ?? args.kind,
                      Self.nativeMeasureKinds.contains(kind) else {
                    throw FloeError.validationFailed(
                        "native measure requires kind (\(Self.nativeMeasureKinds.sorted().joined(separator: "|")))")
                }
                switch kind {
                case "distance":
                    guard args.points?.count == 2 else {
                        throw FloeError.validationFailed("native distance measure needs two points")
                    }
                case "body", "mesh":
                    guard args.handles?.count == 1 else {
                        throw FloeError.validationFailed("native \(kind) measure needs one body handle")
                    }
                default:
                    break
                }
            } else {
                guard let kind = args.kind, ["distance", "angle", "radius", "perimeter", "area"].contains(kind) else {
                    throw FloeError.validationFailed("measure requires kind distance|angle|radius|perimeter|area")
                }
            }
        case .check:
            if let tolerance = args.tolerance, !(tolerance.isFinite && tolerance > 0) {
                throw FloeError.validationFailed("tolerance must be positive")
            }
        case .threeDSnapshot:
            break
        case .threeDAssembly, .threeDDrawing:
            // The workbench service aliases are PAYLOAD calls. The payload MUST
            // name exactly one operation (`payload.action`, or the documented
            // legacy `payload.op` spelling); an absent or unrecognized action
            // is a structured refusal, never a silent read default (`pages` /
            // `report`). Mutating operations stay reachable only through
            // propose → apply, exactly as before.
            guard native else {
                throw FloeError.validationFailed(
                    "\(args.action.rawValue) serves the native .floecad workbench services; "
                        + "a DWG/DXF drawing uses read/query/measure/propose/export without the three_d_* aliases.")
            }
            let serviceKind = args.action == .threeDAssembly ? "assembly" : "drawing"
            let payload = try Self.servicePayloadObject(args)
            _ = try Self.resolveService(kind: serviceKind, payload: payload)
        case .threeDMeasure, .threeDPropose:
            guard let op = args.op, !op.isEmpty else {
                throw FloeError.validationFailed("\(args.action.rawValue) requires op")
            }
            if let raw = args.args,
               (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] == nil {
                throw FloeError.validationFailed("args must be a JSON object string")
            }
        case .material:
            guard native else {
                throw FloeError.validationFailed(
                    "material edits a native .floecad document; a DWG/DXF drawing has no PBR material library.")
            }
            let payload = try Self.servicePayloadObject(args)
            guard let action = payload["action"] as? String,
                  CadNativeEditActions.material.contains(action) else {
                throw FloeError.validationFailed(
                    "material requires payload.action ("
                        + CadNativeEditActions.material.sorted().joined(separator: "|") + ").")
            }
            if let revision = args.revision, revision < 0 {
                throw FloeError.validationFailed("revision must be >= 0")
            }
        case .parameters:
            guard native else {
                throw FloeError.validationFailed(
                    "parameters edits the native feature graph and sketch profiles; "
                        + "a DWG/DXF drawing has no parametric features.")
            }
            let payload = try Self.servicePayloadObject(args)
            guard let action = payload["action"] as? String,
                  CadNativeEditActions.parameters.contains(action) else {
                throw FloeError.validationFailed(
                    "parameters requires payload.action ("
                        + CadNativeEditActions.parameters.sorted().joined(separator: "|") + ").")
            }
            if let revision = args.revision, revision < 0 {
                throw FloeError.validationFailed("revision must be >= 0")
            }
            if CadNativeEditActions.loftSurface.contains(action) {
                if ["loft.describe","loft.update","surface.update"].contains(action),payload["feature_id"] as? String == nil {
                    throw FloeError.validationFailed("parameters \(action) needs the existing feature_id; see documentation loft-surfaces.")
                }
                if action == "loft.create" {
                    guard let sections=payload["sections"] as? [[String:Any]],(2...64).contains(sections.count) else {
                        throw FloeError.validationFailed("parameters loft.create needs 2-64 ordered ProfileRef sections; see documentation loft-surfaces.")
                    }
                }
                if action == "loft.update" {
                    guard let changes=payload["changes"] as? [String:Any],!changes.isEmpty else {
                        throw FloeError.validationFailed("parameters loft.update needs changes.sections and/or changes.definition.")
                    }
                }
                if ["surface.create","surface.update"].contains(action) {
                    guard let definition=payload["definition"] as? [String:Any],
                          let operation=definition["operation"] as? String,
                          ["loft","trim","patch","sew","thicken"].contains(operation) else {
                        throw FloeError.validationFailed("parameters \(action) needs a versioned surface definition; see surface.catalog and documentation loft-surfaces.")
                    }
                }
                if action == "surface.inspect",payload["body_id"] as? String == nil {
                    throw FloeError.validationFailed("parameters surface.inspect needs body_id from the current document.")
                }
            }
            if action == "update" {
                guard payload["feature_id"] as? String != nil || payload["id"] as? String != nil else {
                    throw FloeError.validationFailed("parameters update requires feature_id (from query kind=features).")
                }
                guard let changes = payload["changes"] as? [String: Any], !changes.isEmpty else {
                    throw FloeError.validationFailed("parameters update requires changes (parameter -> value).")
                }
            }
            if action == "updateSketchEntity" {
                guard payload["sketch_id"] as? String != nil
                        || payload["sketchID"] as? String != nil else {
                    throw FloeError.validationFailed(
                        "parameters updateSketchEntity requires sketch_id (from query kind=sketches).")
                }
                guard payload["entity_id"] as? String != nil
                        || payload["entityID"] as? String != nil else {
                    throw FloeError.validationFailed(
                        "parameters updateSketchEntity requires entity_id (from query kind=sketches entityRows).")
                }
                let hasGeometry = ["a", "b", "start", "end", "endpointA", "endpointB",
                                   "min", "max", "low", "high", "center",
                                   "width", "height", "radius", "diameter",
                                   "start_angle_deg", "start_angle", "startAngleDegrees",
                                   "end_angle_deg", "end_angle", "endAngleDegrees",
                                   "sweep_angle_deg", "sweep_angle", "sweepAngleDegrees",
                                   "radius_x", "radiusX", "radius_y", "radiusY",
                                   "rotation_deg", "rotation",
                                   "points", "point", "point_index"]
                    .contains { payload[$0] != nil || payload["expected_\($0)"] != nil }
                guard hasGeometry else {
                    throw FloeError.validationFailed(
                        "parameters updateSketchEntity needs real geometry: line a/b; rect min/max or "
                            + "center/width/height; circle center/radius/diameter; arc center/radius/"
                            + "start_angle_deg/end_angle_deg/sweep_angle_deg; ellipse center/radius_x/"
                            + "radius_y/rotation_deg; spline points or point_index + point.")
                }
                for key in ["radius", "diameter", "width", "height",
                            "radius_x", "radiusX", "radius_y", "radiusY",
                            "expected_radius", "expected_diameter", "expected_width", "expected_height",
                            "expected_radius_x", "expected_radius_y"] {
                    if let raw = payload[key] {
                        guard let value = Self.doubleValue(raw), value.isFinite, value > 0 else {
                            throw FloeError.validationFailed(
                                "parameters updateSketchEntity \(key) must be a positive finite millimetre value.")
                        }
                    }
                }
                for key in ["start_angle_deg", "start_angle", "startAngleDegrees",
                            "end_angle_deg", "end_angle", "endAngleDegrees",
                            "sweep_angle_deg", "sweep_angle", "sweepAngleDegrees",
                            "rotation_deg", "rotation"] {
                    if let raw = payload[key] {
                        guard let value = Self.doubleValue(raw), value.isFinite else {
                            throw FloeError.validationFailed(
                                "parameters updateSketchEntity \(key) must be a finite angle in degrees.")
                        }
                    }
                }
                if let raw = payload["points"] {
                    guard let rows = raw as? [Any], rows.count >= 2 else {
                        throw FloeError.validationFailed(
                            "parameters updateSketchEntity points must be a list of at least two [x, y] points.")
                    }
                    for row in rows {
                        guard row is [Any] || row is [NSNumber] || row is [String: Any] else {
                            throw FloeError.validationFailed(
                                "parameters updateSketchEntity points must be [[x, y], ...] or [{x, y}, ...].")
                        }
                    }
                }
                if let raw = payload["point"] {
                    guard raw is [Any] || raw is [NSNumber] || raw is [String: Any] else {
                        throw FloeError.validationFailed(
                            "parameters updateSketchEntity point must be [x, y] or {x, y}.")
                    }
                }
                if payload["point_index"] != nil, payload["points"] != nil {
                    throw FloeError.validationFailed(
                        "parameters updateSketchEntity send either points or point_index + point, not both.")
                }
                if let raw = payload["point_index"] {
                    guard let index = Self.doubleValue(raw), index.isFinite,
                          index == index.rounded(), index >= 0 else {
                        throw FloeError.validationFailed(
                            "parameters updateSketchEntity point_index must be a non-negative whole number.")
                    }
                    guard payload["point"] != nil else {
                        throw FloeError.validationFailed(
                            "parameters updateSketchEntity point_index needs point; or send points to replace all.")
                    }
                }
            }
            if action == "deleteSketchEntity" {
                guard payload["sketch_id"] as? String != nil
                        || payload["sketchID"] as? String != nil else {
                    throw FloeError.validationFailed(
                        "parameters deleteSketchEntity requires sketch_id (from query kind=sketches).")
                }
                guard payload["entity_id"] as? String != nil
                        || payload["entityID"] as? String != nil else {
                    throw FloeError.validationFailed(
                        "parameters deleteSketchEntity requires entity_id (from query kind=sketches entityRows).")
                }
                for key in ["remove_shared_references", "remove_pattern_link"] {
                    if let raw = payload[key] {
                        // NSNumber 1 bridges to Bool; require the actual JSON
                        // boolean type rather than a numeric truthiness.
                        guard let number = raw as? NSNumber,
                              CFGetTypeID(number) == CFBooleanGetTypeID() else {
                            throw FloeError.validationFailed(
                                "parameters deleteSketchEntity \(key) must be true or false.")
                        }
                    }
                }
            }
            if action == "setSketchDimension" {
                guard payload["sketch_id"] as? String != nil
                        || payload["sketchID"] as? String != nil else {
                    throw FloeError.validationFailed(
                        "parameters setSketchDimension requires sketch_id (from query kind=sketches).")
                }
                guard let kind = payload["kind"] as? String,
                      CadNativeEditActions.sketchDimensionKinds.contains(kind.lowercased()) else {
                    throw FloeError.validationFailed(
                        "parameters setSketchDimension requires kind ("
                            + CadNativeEditActions.sketchDimensionKinds.sorted().joined(separator: "|") + ").")
                }
                guard payload["entity_id"] != nil || payload["entity_ids"] != nil
                        || payload["refs"] != nil else {
                    throw FloeError.validationFailed(
                        "parameters setSketchDimension requires entity_id, entity_ids or refs.")
                }
                let hasValue = payload["value"] != nil
                let hasExpression = payload["expression"] != nil
                guard hasValue != hasExpression else {
                    throw FloeError.validationFailed(
                        hasValue
                            ? "parameters setSketchDimension accepts value or expression, not both."
                            : "parameters setSketchDimension requires value or expression.")
                }
                if hasExpression {
                    guard let expression = payload["expression"] as? String,
                          !expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw FloeError.validationFailed(
                            "parameters setSketchDimension expression must be a non-empty formula string "
                                + "in the public unit (mm, or degrees for angle).")
                    }
                } else {
                    guard let value = Self.doubleValue(payload["value"]), value.isFinite, value > 0 else {
                        throw FloeError.validationFailed(
                            "parameters setSketchDimension requires value as a positive finite number "
                                + "(mm for lengths/radii, degrees for angle) or expression.")
                    }
                }
                if let expected = payload["expected_expression"], !(expected is String) {
                    throw FloeError.validationFailed(
                        "parameters setSketchDimension expected_expression must be the current stored "
                            + "formula string (empty string means none).")
                }
            }
            if action == "removeSketchDimension" {
                guard payload["dimension_id"] as? String != nil
                        || payload["dimensionID"] as? String != nil else {
                    throw FloeError.validationFailed(
                        "parameters removeSketchDimension requires dimension_id from query kind=constraints.")
                }
            }
            if action == "feature.suppress" {
                guard payload["feature_id"] as? String != nil
                        || payload["featureID"] as? String != nil else {
                    throw FloeError.validationFailed(
                        "parameters feature.suppress requires feature_id from query kind=features.")
                }
                guard payload["suppressed"] != nil || payload["restore"] != nil else {
                    throw FloeError.validationFailed(
                        "parameters feature.suppress requires suppressed:true|false (or restore:true).")
                }
            }
            if action == "feature.delete" {
                guard payload["feature_id"] as? String != nil
                        || payload["featureID"] as? String != nil else {
                    throw FloeError.validationFailed(
                        "parameters feature.delete requires feature_id from query kind=features.")
                }
            }
            if action == "feature.move" {
                guard payload["feature_id"] as? String != nil
                        || payload["featureID"] as? String != nil else {
                    throw FloeError.validationFailed(
                        "parameters feature.move requires feature_id from query kind=features.")
                }
                guard let raw = payload["to_index"] ?? payload["index"] ?? payload["to"],
                      let index = Self.intValue(raw), index >= 0 else {
                    throw FloeError.validationFailed(
                        "parameters feature.move requires to_index as a non-negative 0-based history position.")
                }
            }
            if action == "variable.create" {
                guard let name = payload["name"] as? String,
                      !name.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw FloeError.validationFailed(
                        "parameters variable.create requires a non-empty name.")
                }
                guard let expression = payload["expression"] as? String,
                      !expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw FloeError.validationFailed(
                        "parameters variable.create requires a non-empty expression.")
                }
            }
            if action == "variable.update" {
                guard payload["variable_id"] as? String != nil
                        || payload["variableID"] as? String != nil
                        || payload["id"] as? String != nil else {
                    throw FloeError.validationFailed(
                        "parameters variable.update requires variable_id from query kind=variables.")
                }
                let hasName = (payload["name"] as? String)?.trimmingCharacters(in: .whitespaces).isEmpty == false
                let hasExpression = payload["expression"] is String
                guard hasName || hasExpression else {
                    throw FloeError.validationFailed(
                        "parameters variable.update requires name and/or expression.")
                }
                if let expected = payload["expected_expression"], !(expected is String) {
                    throw FloeError.validationFailed(
                        "parameters variable.update expected_expression must be a string.")
                }
            }
            if action == "variable.delete" {
                guard payload["variable_id"] as? String != nil
                        || payload["variableID"] as? String != nil
                        || payload["id"] as? String != nil else {
                    throw FloeError.validationFailed(
                        "parameters variable.delete requires variable_id from query kind=variables.")
                }
            }
            if ["datum.offsetPlane.create", "datum.offsetPlane.update", "datum.offsetPlane.delete",
                "datum.anglePlane.create", "datum.anglePlane.update", "datum.anglePlane.delete",
                "datum.threePointPlane.create", "datum.threePointPlane.update",
                "datum.threePointPlane.delete",
                "sketch.setSupport", "sketch.clearSupport"].contains(action) {
                func requireString(_ key: String) throws {
                    guard let value = payload[key] as? String,
                          !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw FloeError.validationFailed("parameters \(action) requires \(key).")
                    }
                }
                func requirePoint(_ value: Any?, label: String) throws {
                    guard let point = value as? [String: Any],
                          let sketch = point["sketch_id"] as? String,
                          UUID(uuidString: sketch) != nil,
                          let entity = point["entity_id"] as? String,
                          UUID(uuidString: entity) != nil,
                          let role = point["role"] as? String,
                          ["endpointA", "endpointB", "center"].contains(role) else {
                        throw FloeError.validationFailed(
                            "parameters \(action) \(label) needs sketch_id, entity_id and role endpointA|endpointB|center.")
                    }
                }
                func requirePoints(_ value: Any?, label: String) throws {
                    guard let points = value as? [Any], points.count == 3 else {
                        throw FloeError.validationFailed(
                            "parameters \(action) \(label) must contain exactly three point references.")
                    }
                    for (index, point) in points.enumerated() {
                        try requirePoint(point, label: "\(label)[\(index)]")
                    }
                }
                let isOffset = action.hasPrefix("datum.offsetPlane.")
                let isAngle = action.hasPrefix("datum.anglePlane.")
                let isThreePoint = action.hasPrefix("datum.threePointPlane.")
                if action.hasSuffix(".update") || action.hasSuffix(".delete") {
                    try requireString("plane_id")
                }
                if action == "sketch.setSupport" || action == "sketch.clearSupport" {
                    try requireString("sketch_id")
                }
                if action == "sketch.setSupport" { try requireString("plane_id") }
                if isOffset || isAngle {
                    let hasSource = ["body_id", "face_index", "query_token"].contains { payload[$0] != nil }
                    if action.hasSuffix(".create") || (action.hasSuffix(".update") && hasSource) {
                        try requireString("body_id")
                        try requireString("query_token")
                        guard let index = Self.intValue(payload["face_index"]), index > 0,
                              Self.doubleValue(payload["face_index"]) == Double(index) else {
                            throw FloeError.validationFailed(
                                "parameters \(action) requires a positive integer face_index from query kind=faces.")
                        }
                    }
                    if action.hasSuffix(".create") || payload["expression"] != nil {
                        try requireString("expression")
                    }
                    let changesHinge = isAngle && (payload["hinge_x"] != nil || payload["hinge_y"] != nil)
                    if action.hasSuffix(".update"), !hasSource,
                       payload["expression"] == nil, payload["size"] == nil, !changesHinge {
                        throw FloeError.validationFailed(
                            "parameters \(action) requires expression, size, hinge or a complete source face.")
                    }
                }
                if isAngle {
                    let hasX = payload["hinge_x"] != nil
                    let hasY = payload["hinge_y"] != nil
                    guard hasX == hasY else {
                        throw FloeError.validationFailed(
                            "parameters \(action) hinge_x and hinge_y must be sent together.")
                    }
                    if hasX {
                        guard let x = Self.doubleValue(payload["hinge_x"]), x.isFinite,
                              let y = Self.doubleValue(payload["hinge_y"]), y.isFinite,
                              x * x + y * y > 1e-18 else {
                            throw FloeError.validationFailed(
                                "parameters \(action) hinge_x/hinge_y must be a finite non-zero in-plane direction.")
                        }
                    }
                }
                if isThreePoint {
                    if action.hasSuffix(".create") {
                        try requirePoints(payload["points"], label: "points")
                    }
                    if action.hasSuffix(".update") {
                        let hasPoints = payload["points"] != nil
                        let hasPoint = payload["point_index"] != nil || payload["point"] != nil
                        guard !(hasPoints && hasPoint) else {
                            throw FloeError.validationFailed(
                                "parameters \(action) accepts points or point_index + point, not both.")
                        }
                        if hasPoints { try requirePoints(payload["points"], label: "points") }
                        if hasPoint {
                            guard payload["point"] != nil else {
                                throw FloeError.validationFailed(
                                    "parameters \(action) point_index also requires point.")
                            }
                            guard let index = Self.intValue(payload["point_index"]), (0..<3).contains(index),
                                  Self.doubleValue(payload["point_index"]) == Double(index) else {
                                throw FloeError.validationFailed(
                                    "parameters \(action) point_index must be 0, 1 or 2.")
                            }
                            try requirePoint(payload["point"], label: "point")
                        }
                        guard hasPoints || hasPoint || payload["size"] != nil else {
                            throw FloeError.validationFailed(
                                "parameters \(action) requires points, point_index + point, or size.")
                        }
                    }
                    if let expected = payload["expected_points"] {
                        try requirePoints(expected, label: "expected_points")
                    }
                }
                if let size = payload["size"] {
                    guard let value = Self.doubleValue(size), value.isFinite, value > 0 else {
                        throw FloeError.validationFailed("parameters \(action) size must be positive finite millimetres.")
                    }
                }
                if let expected = payload["expected_expression"], !(expected is String) {
                    throw FloeError.validationFailed("parameters \(action) expected_expression must be a string.")
                }
            }
            if ["datum.axis.create", "datum.axis.update", "datum.axis.delete",
                "datum.point.create", "datum.point.update", "datum.point.delete"].contains(action) {
                func requireString(_ key: String) throws {
                    guard let value = payload[key] as? String,
                          !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw FloeError.validationFailed("parameters \(action) requires \(key).")
                    }
                }
                func requireUUID(_ key: String) throws {
                    try requireString(key)
                    guard UUID(uuidString: payload[key] as? String ?? "") != nil else {
                        throw FloeError.validationFailed(
                            "parameters \(action) \(key) must be a UUID from query kind=axes/datumPoints/planes.")
                    }
                }
                func requirePositiveIndex(_ key: String) throws {
                    guard let index = Self.intValue(payload[key]), index > 0,
                          Self.doubleValue(payload[key]) == Double(index) else {
                        throw FloeError.validationFailed(
                            "parameters \(action) requires a positive integer \(key) from query kind=faces/edges.")
                    }
                }
                func requirePointSource(_ value: Any?, label: String) throws {
                    guard let point = value as? [String: Any] else {
                        throw FloeError.validationFailed(
                            "parameters \(action) \(label) must be {sketch_id, entity_id, role} or {point_id}.")
                    }
                    if let pointID = point["point_id"] as? String {
                        guard UUID(uuidString: pointID) != nil, point.count == 1 else {
                            throw FloeError.validationFailed(
                                "parameters \(action) \(label) point_id must be a UUID and stand alone.")
                        }
                        return
                    }
                    guard let sketch = point["sketch_id"] as? String,
                          UUID(uuidString: sketch) != nil,
                          let entity = point["entity_id"] as? String,
                          UUID(uuidString: entity) != nil,
                          let role = point["role"] as? String,
                          ["endpointA", "endpointB", "center"].contains(role) else {
                        throw FloeError.validationFailed(
                            "parameters \(action) \(label) needs sketch_id, entity_id and role endpointA|endpointB|center.")
                    }
                    guard point.count == 3 else {
                        throw FloeError.validationFailed(
                            "parameters \(action) \(label) accepts only sketch_id, entity_id and role, or point_id.")
                    }
                }
                func requirePointSources(_ count: Int) throws {
                    guard let points = payload["points"] as? [Any], points.count == count else {
                        throw FloeError.validationFailed(
                            "parameters \(action) points must contain exactly \(count) point references.")
                    }
                    for (index, point) in points.enumerated() {
                        try requirePointSource(point, label: "points[\(index)]")
                    }
                }
                func requirePlaneIDs() throws {
                    guard let ids = payload["plane_ids"] as? [Any], ids.count == 2 else {
                        throw FloeError.validationFailed(
                            "parameters \(action) plane_ids must contain exactly two construction plane ids.")
                    }
                    for id in ids {
                        guard let text = id as? String, UUID(uuidString: text) != nil else {
                            throw FloeError.validationFailed(
                                "parameters \(action) plane_ids must be construction plane UUIDs.")
                        }
                    }
                }

                let kind = (payload["kind"] as? String)?.trimmingCharacters(in: .whitespaces)
                let supportedAxisKinds = ["face", "edge", "cylinder", "twoPoints", "twoPlanes"]
                let supportedPointKinds = ["faceCenter", "edgePoint", "twoPointMidpoint", "axisPoint", "axisPlane"]
                if action == "datum.axis.create" || action == "datum.axis.update" {
                    if action == "datum.axis.create" || payload["kind"] != nil {
                        guard let kind else {
                            throw FloeError.validationFailed(
                                "parameters \(action) requires kind \(supportedAxisKinds.joined(separator: "|")).")
                        }
                        guard supportedAxisKinds.contains(kind) else {
                            throw FloeError.validationFailed(
                                "parameters \(action) kind must be \(supportedAxisKinds.joined(separator: "|")).")
                        }
                        switch kind {
                        case "face", "edge", "cylinder":
                            try requireString("body_id")
                            try requireString("query_token")
                            try requirePositiveIndex(kind == "edge" ? "edge_index" : "face_index")
                            if payload["plane_ids"] != nil || payload["points"] != nil {
                                throw FloeError.validationFailed(
                                    "parameters \(action) a \(kind) axis accepts no plane_ids/points.")
                            }
                            if kind == "cylinder", payload["offset"] != nil {
                                throw FloeError.validationFailed(
                                    "parameters \(action) a cylinder axis is the face's own centre line; it has no offset.")
                            }
                        case "twoPoints":
                            try requirePointSources(2)
                            if payload["offset"] != nil {
                                throw FloeError.validationFailed(
                                    "parameters \(action) a two-point axis follows its points and has no offset.")
                            }
                        default:
                            try requirePlaneIDs()
                            if payload["offset"] != nil {
                                throw FloeError.validationFailed(
                                    "parameters \(action) a two-plane axis follows the plane intersection and has no offset.")
                            }
                        }
                    }
                }
                if action == "datum.point.create" || action == "datum.point.update" {
                    if action == "datum.point.create" || payload["kind"] != nil {
                        guard let kind else {
                            throw FloeError.validationFailed(
                                "parameters \(action) requires kind \(supportedPointKinds.joined(separator: "|")).")
                        }
                        guard supportedPointKinds.contains(kind) else {
                            throw FloeError.validationFailed(
                                "parameters \(action) kind must be \(supportedPointKinds.joined(separator: "|")).")
                        }
                        switch kind {
                        case "faceCenter":
                            try requireString("body_id")
                            try requireString("query_token")
                            try requirePositiveIndex("face_index")
                            if payload["offset"] != nil {
                                throw FloeError.validationFailed(
                                    "parameters \(action) a face-centre point has no offset.")
                            }
                        case "edgePoint":
                            try requireString("body_id")
                            try requireString("query_token")
                            try requirePositiveIndex("edge_index")
                        case "twoPointMidpoint":
                            try requirePointSources(2)
                            if payload["offset"] != nil {
                                throw FloeError.validationFailed(
                                    "parameters \(action) a midpoint has no offset.")
                            }
                        case "axisPoint":
                            try requireUUID("axis_id")
                        default:
                            try requireUUID("axis_id")
                            try requireUUID("plane_id")
                            if payload["offset"] != nil {
                                throw FloeError.validationFailed(
                                    "parameters \(action) an axis/plane point has no offset.")
                            }
                        }
                    }
                }
                if action.hasSuffix(".update") {
                    try requireUUID(action.hasPrefix("datum.axis") ? "axis_id" : "point_id")
                    let hasSource = ["kind", "body_id", "edge_index", "face_index", "plane_ids",
                                     "points", "axis_id", "plane_id"].contains { payload[$0] != nil }
                    if !hasSource, payload["offset"] == nil, payload["size"] == nil {
                        throw FloeError.validationFailed(
                            "parameters \(action) requires offset, size, or the complete kind-specific source fields.")
                    }
                }
                if action.hasSuffix(".delete") {
                    try requireUUID(action.hasPrefix("datum.axis") ? "axis_id" : "point_id")
                }
                if let offset = payload["offset"], !(offset is String) {
                    throw FloeError.validationFailed(
                        "parameters \(action) offset must be a distance expression string in mm.")
                }
                if let expected = payload["expected_offset"], !(expected is String) {
                    throw FloeError.validationFailed(
                        "parameters \(action) expected_offset must be the exact stored formula string.")
                }
                if let size = payload["size"] {
                    guard let value = Self.doubleValue(size), value.isFinite, value > 0 else {
                        throw FloeError.validationFailed(
                            "parameters \(action) size must be positive finite millimetres.")
                    }
                }
            }
            if action == "feature.setExpression" {
                guard payload["feature_id"] as? String != nil
                        || payload["featureID"] as? String != nil
                        || payload["id"] as? String != nil else {
                    throw FloeError.validationFailed(
                        "parameters feature.setExpression requires feature_id from query kind=features.")
                }
                guard let parameter = payload["parameter"] as? String,
                      !parameter.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw FloeError.validationFailed(
                        "parameters feature.setExpression requires parameter (query kind=features expression_parameters).")
                }
                guard let expression = payload["expression"] as? String,
                      !expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw FloeError.validationFailed(
                        "parameters feature.setExpression requires a non-empty expression.")
                }
                if let expected = payload["expected_expression"], !(expected is String) {
                    throw FloeError.validationFailed(
                        "parameters feature.setExpression expected_expression must be a string.")
                }
            }
        case .scene:
            guard native else {
                throw FloeError.validationFailed(
                    "scene edits the native .floecad view overlay; a DWG/DXF drawing has no 3D section or measurement guides.")
            }
            let payload = try Self.servicePayloadObject(args)
            let rawAction = (payload["action"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let action = CadNativeEditActions.scene.first(where: {
                $0.lowercased() == rawAction.lowercased()
            }) else {
                throw FloeError.validationFailed(
                    "scene requires payload.action ("
                        + CadNativeEditActions.scene.sorted().joined(separator: "|")
                        + "); got '\(rawAction)'")
            }
            func vector(_ raw: Any?) -> [Double]? {
                guard let values = raw as? [Any] else { return nil }
                let numbers = values.compactMap { Self.doubleValue($0) }
                guard numbers.count == 3,
                      numbers.allSatisfy({ $0.isFinite }) else { return nil }
                return numbers
            }
            if action == "setSection" {
                guard vector(payload["origin"] ?? payload["origin_mm"]) != nil else {
                    throw FloeError.validationFailed(
                        "scene setSection requires origin [x,y,z] in millimetres.")
                }
                let normal = vector(payload["normal"] ?? payload["normal_mm"])
                let xAxis = vector(payload["x_axis"] ?? payload["xAxis"])
                let yAxis = vector(payload["y_axis"] ?? payload["yAxis"])
                let hasFrame = xAxis != nil && yAxis != nil
                let hasNormal = normal.map { values in
                    let length = (values[0] * values[0] + values[1] * values[1]
                        + values[2] * values[2]).squareRoot()
                    return length.isFinite && length > 1e-9
                } ?? false
                guard hasFrame || hasNormal else {
                    throw FloeError.validationFailed(
                        "scene setSection requires x_axis+y_axis or a non-zero normal.")
                }
                if let size = payload["size_mm"] ?? payload["size"] {
                    guard let value = Self.doubleValue(size), value.isFinite,
                          value > 0 else {
                        throw FloeError.validationFailed(
                            "scene setSection size_mm must be a positive finite number.")
                    }
                }
                for key in ["flip", "flipped", "enabled"] where payload[key] != nil {
                    guard payload[key] is Bool || payload[key] is NSNumber else {
                        throw FloeError.validationFailed(
                            "scene setSection \(key) must be true or false.")
                    }
                }
            }
            if action == "setSectionEnabled" {
                guard payload["enabled"] is Bool || payload["enabled"] is NSNumber else {
                    throw FloeError.validationFailed(
                        "scene setSectionEnabled requires enabled:true|false.")
                }
            }
            if action == "setMeasurementsVisible" {
                guard payload["visible"] is Bool || payload["visible"] is NSNumber
                        || payload["enabled"] is Bool || payload["enabled"] is NSNumber else {
                    throw FloeError.validationFailed(
                        "scene setMeasurementsVisible requires visible:true|false.")
                }
            }
            if action == "addMeasurement" {
                guard vector(payload["start"] ?? payload["start_mm"]) != nil,
                      vector(payload["end"] ?? payload["end_mm"]) != nil else {
                    throw FloeError.validationFailed(
                        "scene addMeasurement requires start and end [x,y,z] in millimetres.")
                }
            }
            if action == "removeMeasurement" {
                guard let raw = payload["id"] as? String,
                      UUID(uuidString: raw.trimmingCharacters(
                        in: .whitespacesAndNewlines)) != nil else {
                    throw FloeError.validationFailed(
                        "scene removeMeasurement requires id (a measurement UUID from get).")
                }
            }
            if let revision = args.revision, revision < 0 {
                throw FloeError.validationFailed("revision must be >= 0")
            }

        case .capture:
            guard native else {
                throw FloeError.validationFailed(
                    "capture renders the native 3D viewport; use export for a 2D drawing.")
            }
            let payload = try Self.servicePayloadObject(args)
            for key in ["width", "height"] {
                if let raw = payload[key] {
                    guard let value = Self.intValue(raw), (64...4096).contains(value) else {
                        throw FloeError.validationFailed("capture \(key) must be an integer in 64…4096.")
                    }
                }
            }
            if let revision = args.revision, revision < 0 {
                throw FloeError.validationFailed("revision must be >= 0")
            }
        case .versions:
            guard native else {
                throw FloeError.validationFailed(
                    "versions is available for native .floecad documents only")
            }
            let payload = try Self.servicePayloadObject(args)
            let rawAction = (payload["action"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            let allowedActions: Set<String> = ["list", "create", "compare", "restore",
                                               "delete", "recoveries", "recover",
                                               "discard_recovery", "record", "merge_compare", "merge_apply", "merge_cancel"]
            guard allowedActions.contains(rawAction) else {
                throw FloeError.validationFailed(
                    "versions requires payload.action "
                        + "list|create|compare|restore|delete|recoveries|recover|discard_recovery|record|merge_compare|merge_apply|merge_cancel "
                        + "(got '\(rawAction)')")
            }
            if rawAction == "merge_compare" {
                guard let source = payload["source_path"] as? String, !source.isEmpty,
                      let raw = payload["base_version_id"] as? String, UUID(uuidString: raw) != nil else {
                    throw FloeError.validationFailed("versions merge_compare requires source_path and base_version_id")
                }
            }
            if ["merge_apply", "merge_cancel"].contains(rawAction) {
                guard let raw = payload["plan_id"] as? String, UUID(uuidString: raw) != nil else {
                    throw FloeError.validationFailed("versions merge_apply/merge_cancel requires plan_id")
                }
                if let raw = payload["resolutions"], !(raw is [String: String]) {
                    throw FloeError.validationFailed("resolutions must map conflict ids to current or incoming")
                }
            }
            if rawAction == "create" {
                guard let name = payload["name"] as? String,
                      !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw FloeError.validationFailed("versions create requires payload.name")
                }
            }
            let idActions: Set<String> = ["compare", "restore", "delete",
                                         "recover", "discard_recovery", "record"]
            if idActions.contains(rawAction) {
                guard let raw = payload["version_id"] as? String,
                      UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines)) != nil else {
                    throw FloeError.validationFailed(
                        "versions \(rawAction) requires payload.version_id (a version UUID)")
                }
            }
            if rawAction == "compare", let raw = payload["against_version_id"] as? String,
               !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines)) == nil {
                throw FloeError.validationFailed(
                    "versions compare against_version_id must be a version UUID")
            }
            if let raw = payload["expected_content_sha256"] as? String,
               !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let hex = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else {
                    throw FloeError.validationFailed(
                        "versions expected_content_sha256 must be a 64-character SHA-256 hex string")
                }
            }
            if let branch = payload["create_branch"], !(branch is Bool) {
                throw FloeError.validationFailed("versions create_branch must be true or false")
            }
            if let name = payload["branch_name"], !(name is String) {
                throw FloeError.validationFailed("versions branch_name must be a string")
            }
            if rawAction == "record" {
                guard let section = payload["section"] as? String,
                      !section.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw FloeError.validationFailed(
                        "versions record requires payload.section")
                }
                guard let identifier = payload["identifier"] as? String,
                      !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw FloeError.validationFailed(
                        "versions record requires payload.identifier")
                }
            }
            if let offset = payload["offset"], rawAction == "compare",
               !Self.isBoundedInt(offset, 0...10_000_000) {
                throw FloeError.validationFailed(
                    "versions compare offset must be a non-negative integer")
            }
            if let limit = payload["limit"], rawAction == "compare",
               !Self.isBoundedInt(limit, 1...240) {
                throw FloeError.validationFailed(
                    "versions compare limit must be an integer in 1...240")
            }
            if let offset = payload["chunk_offset"], rawAction == "record",
               !Self.isBoundedInt(offset, 0...10_000_000) {
                throw FloeError.validationFailed(
                    "versions record chunk_offset must be a non-negative integer")
            }
            if let limit = payload["chunk_limit"], rawAction == "record",
               !Self.isBoundedInt(limit, 1...256) {
                throw FloeError.validationFailed(
                    "versions record chunk_limit must be an integer in 1...256")
            }
            if let identity = payload["identity"],
               !(identity is [String: Any]) {
                throw FloeError.validationFailed(
                    "versions identity must be the from/to object returned by the first page")
            }
            if let revision = args.revision, revision < 0 {
                throw FloeError.validationFailed("revision must be >= 0")
            }
        case .propose:
            if native {
                // Native proposals use the typed operation vocabulary; the
                // representation decides, not the caller's wording.
                guard let op = args.op, !op.isEmpty else {
                    throw FloeError.validationFailed("native propose requires a top-level op beside action and path (for example feature.extrude); args contains only the operation parameters, not an op/args envelope")
                }
                if let raw = args.args,
                   (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] == nil {
                    throw FloeError.validationFailed("args must be a JSON object string")
                }
            } else {
                guard let operations = args.operations, !operations.isEmpty else {
                    throw FloeError.validationFailed("propose requires at least one operation")
                }
                guard operations.count <= 64 else {
                    throw FloeError.validationFailed("propose supports at most 64 operations")
                }
                for operation in operations {
                    guard let name = operation.operation else {
                        throw FloeError.validationFailed("every operation needs an operation name")
                    }
                    guard Self.supportedOperations.contains(name) else {
                        throw FloeError.validationFailed("unsupported CAD operation '\(name)'")
                    }
                }
            }
        }
    }

    /// True when the caller addressed a native `.floecad` package. The unified
    /// actions route on this, so a representation change never silently runs
    /// through the wrong engine.
    public static func isNativeRepresentation(_ path: String?) -> Bool {
        guard let path else { return false }
        return (path as NSString).pathExtension.lowercased() == "floecad"
    }

    /// Original formats already routed by the read-only engineering viewer.
    /// FloeWorkbench does not depend on FloeWorkspace, so this mirrors
    /// `EngineeringPreviewKind.mesh` and `.cadSurface` explicitly. Native
    /// `.floecad`, drawings, Gerber and formats whose decoder is not bundled
    /// stay out of the original-file observation route.
    static let observableOriginalExtensions: Set<String> = [
        "stl", "obj", "ply", "off", "3ds", "dae", "fbx", "3mf", "amf",
        "gltf", "glb", "wrl", "bim",
        "step", "stp", "iges", "igs", "brep",
    ]

    /// Decode and normalize the ONE observe request contract for both
    /// representations. `validate` and `execute` call this same helper so the
    /// accepted arguments and the host request can never drift.
    ///
    /// * Native `.floecad`: `sceneIndex` may only be 0/omitted; asset
    ///   cameras, clip indices and animation time are refused instead of
    ///   being rendered as an unrelated static frame. The top-level
    ///   `revision` is the same native generation pin as
    ///   `payload.expectedRevision`; disagreeing values are refused.
    /// * Original models: the native-only generation pins are refused (never
    ///   silently ignored); `expectedSourceSHA256` keeps its existing meaning.
    static func modelObservationRequest(_ args: CadDocumentArguments,
                                        native: Bool) throws
    -> CadModelObservationRequest {
        // The top-level `expected_source_sha256` is the reference-update CAS
        // field, not an observe pin. Refuse it here so a caller never believes
        // an observation was source-pinned when the value was ignored.
        if args.expectedSourceSHA256 != nil {
            throw FloeError.validationFailed(
                "observe takes expectedSourceSHA256 inside its payload JSON "
                    + "(with views/width/height), not as the top-level reference CAS field.")
        }
        var request = try JSONDecoder().decode(
            CadModelObservationRequest.self,
            from: Data((args.payload ?? "{}").utf8))
        // Reject the near-miss pin spellings instead of letting JSONDecoder
        // silently ignore a generation pin the caller believed it sent.
        if let raw = args.payload, !raw.isEmpty,
           let object = (try? JSONSerialization.jsonObject(with: Data(raw.utf8)))
            as? [String: Any] {
            if object["revision"] != nil {
                throw FloeError.validationFailed(
                    "payload.revision is not an observe pin. Send payload.expectedRevision "
                        + "(or the top-level revision) for a native .floecad document; an "
                        + "original model uses expectedSourceSHA256.")
            }
            if object["expected_revision"] != nil || object["expected_change_count"] != nil {
                throw FloeError.validationFailed(
                    "observe pins are camelCase: expectedRevision and expectedChangeCount.")
            }
        }
        if native {
            if let refusal = request.nativeSelectionRefusal() {
                throw FloeError.validationFailed(refusal)
            }
            if let topLevel = args.revision {
                guard topLevel >= 0 else {
                    throw FloeError.validationFailed("revision must be >= 0")
                }
                if let payloadPin = request.expectedRevision, payloadPin != topLevel {
                    throw FloeError.validationFailed(
                        "revision (\(topLevel)) and payload.expectedRevision (\(payloadPin)) disagree; "
                            + "send one native generation pin.")
                }
                request.expectedRevision = topLevel
            }
        } else {
            if args.revision != nil {
                throw FloeError.validationFailed(
                    "revision pins a native .floecad document's committed revision; omit it for an "
                        + "original model (use expectedSourceSHA256 to pin the source bytes).")
            }
            if request.hasNativeGenerationPins {
                throw FloeError.validationFailed(
                    "expectedRevision and expectedChangeCount pin the native .floecad live generation; "
                        + "omit them for an original model (use expectedSourceSHA256).")
            }
        }
        try request.validate()
        return request
    }

    /// Native read scopes served by `query` on a `.floecad` document.
    public static let nativeQueryScopes: Set<String> = [
        "bodies", "sketches", "constraints", "features", "edges", "faces",
        "planes",
        "variables", "materials", "assembly", "drawings", "scene", "detail",
        "snapshot", "selection", "animation",
    ]

    /// Native deterministic measurements served by `measure`.
    public static let nativeMeasureKinds: Set<String> = [
        "body", "distance", "bounds", "dof", "interference", "mesh", "rebuild",
    ]

    /// The document access for one execution. A verified Canvas staged
    /// document (seeded from the Drawing Assistant binding at launch, never
    /// from prompt text) authorizes exactly that staged draft under canvas
    /// ownership; everything else uses the ordinary workspace/chat identity.
    public static func access(for context: ToolContext) -> CadDocumentAccess {
        if let staged = context.canvasStagedDocument {
            return CadDocumentAccess(
                environmentID: context.environmentID,
                workspacePath: staged.draftRootPath,
                ownerKind: "canvas",
                ownerID: staged.canvasID)
        }
        return CadDocumentAccess(
            environmentID: context.environmentID,
            workspacePath: context.workspaceRootURL?.path,
            ownerKind: context.conversationID == nil ? "workspace" : "chat",
            ownerID: context.conversationID)
    }

    /// When a staged document is authorized, the tool may touch ONLY that
    /// exact staged document: quoting another path (under the draft root or
    /// elsewhere) grants nothing. The staged path is accepted in its exact
    /// relative form and in its canonical absolute form (the draft root is
    /// visible in the assistant context, and real model turns address the
    /// file that way) — both resolve to the SAME file, so the authorized set
    /// stays exactly one document. Anything else is denied. A nil path only
    /// reaches `capabilities` (every document action validates a non-empty
    /// path upstream), so nil is not an escape hatch and needs no staged
    /// check.
    public static func authorizeDocumentPath(_ path: String?, context: ToolContext) throws {
        if let path, CanvasCADBindingKey.isCanvasOwned(path) {
            // A canvas-cad key has authority ONLY through the run-frozen exact
            // key→canonical-path map. The host re-verifies node/conversation/
            // package ownership at execution; a missing entry fails closed.
            guard TypedMutationContract.canonicalCADCanvasDocumentPath(
                path, serviceStorePaths: context.serviceStorePaths) != nil else {
                throw FloeError.unauthorized
            }
        }
        guard let staged = context.canvasStagedDocument, let path else { return }
        if path == staged.stagedRelativePath { return }
        let root = URL(fileURLWithPath: staged.draftRootPath, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let expected = root.appendingPathComponent(staged.stagedRelativePath)
            .standardizedFileURL.resolvingSymlinksInPath()
        let candidate = URL(fileURLWithPath: path)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard !staged.stagedRelativePath.hasPrefix("/"),
              expected.path.hasPrefix(root.path + "/"),
              candidate == expected else {
            throw FloeError.unauthorized
        }
    }

    /// Build the native request envelope. `args.args`/`args.payload` are JSON
    /// object strings; anything else is refused before it reaches the kernel.
    /// `servicePayload` replaces the payload with the catalog-normalized
    /// service request (canonical `action` + flattened arguments) used by the
    /// `three_d_assembly`/`three_d_drawing` aliases.
    static func threeDRequestJSON(kind: String, args: CadDocumentArguments,
                                  servicePayload: [String: Any]? = nil) throws -> String {
        var object: [String: Any] = ["kind": kind]
        if let servicePayload {
            object["payload"] = servicePayload
        } else {
            if let op = args.op { object["op"] = op }
            if let raw = args.args {
                guard let data = raw.data(using: .utf8),
                      let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    throw FloeError.validationFailed("cad.document args must be a JSON object string.")
                }
                object["args"] = parsed
            }
            if let raw = args.payload {
                guard let data = raw.data(using: .utf8),
                      let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    throw FloeError.validationFailed("cad.document payload must be a JSON object string.")
                }
                object["payload"] = parsed
            }
        }
        if let summary = args.summary { object["summary"] = summary }
        if let proposalID = args.proposalID { object["proposal_id"] = proposalID.uuidString }
        if let grantID = args.grantID { object["grant_id"] = grantID }
        if let requestID = args.requestID { object["request_id"] = requestID }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            throw FloeError.validationFailed("cad.document request could not be encoded.")
        }
        return text
    }

    /// The decoded `payload` object of one workbench service alias call. An
    /// absent/blank payload is an empty object (the catalog then refuses the
    /// missing action); a malformed one is refused here.
    static func servicePayloadObject(_ args: CadDocumentArguments) throws -> [String: Any] {
        guard let raw = args.payload,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        guard let data = raw.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw FloeError.validationFailed("cad.document payload must be a JSON object string.")
        }
        return object
    }

    /// Resolves one workbench service payload through the authoritative
    /// catalog; a resolution failure becomes the tool's structured validation
    /// error (code + the known actions + where to read the args/examples).
    static func resolveService(kind: String, payload: [String: Any])
        throws -> (operation: CadServiceOperationCatalog.Operation, arguments: [String: Any]) {
        do {
            return try CadServiceOperationCatalog.resolve(kind: kind, payload: payload)
        } catch let failure as CadServiceOperationCatalog.ResolutionFailure {
            throw FloeError.validationFailed("\(failure.code): \(failure.message)")
        }
    }

    // MARK: - Runtime-approved-call binding (automatic apply)

    /// Canonical JSON of the DECODED approved arguments, in exactly the shape
    /// the runtime hashed when it minted this call's authority. Optional
    /// fields that were absent stay absent; a `null` placeholder (or any
    /// unknown field) changes the digest, so the automatic path refuses
    /// instead of guessing — the model must send canonical JSON and omit
    /// absent fields instead of writing null.
    public static func canonicalApprovedPayload(_ args: CadDocumentArguments) throws -> Data {
        var object: [String: Any] = ["action": args.action.rawValue]
        if let path = args.path { object["path"] = path }
        if let summary = args.summary { object["summary"] = summary }
        if let operations = args.operations {
            object["operations"] = try operations.map { operation -> [String: Any] in
                try operation.fields.mapValues { try Self.jsonValue($0) }
            }
        }
        // The RAW proposal-id spelling is the approved value: the model copies
        // the id from the propose reply, and a differently-cased id is a
        // different payload that must not bind.
        if let raw = args.proposalIDRaw ?? args.proposalID?.uuidString {
            object["proposal_id"] = raw
        }
        if let grant = args.grantID { object["grant_id"] = grant }
        if let request = args.requestID { object["request_id"] = request }
        if let kind = args.kind { object["kind"] = kind }
        if let points = args.points { object["points"] = points }
        if let handles = args.handles { object["handles"] = handles }
        if let tolerance = args.tolerance { object["tolerance"] = tolerance }
        if let scope = args.scope { object["scope"] = scope }
        if let layer = args.layer { object["layer"] = layer }
        if let entityType = args.entityType { object["entity_type"] = entityType }
        if let text = args.text { object["text"] = text }
        if let offset = args.offset { object["offset"] = offset }
        if let limit = args.limit { object["limit"] = limit }
        if let output = args.output { object["output"] = output }
        if let op = args.op { object["op"] = op }
        if let opArgs = args.args { object["args"] = opArgs }
        if let payload = args.payload { object["payload"] = payload }
        if let taskID = args.taskID { object["task_id"] = taskID }
        if let sourcePath = args.sourcePath { object["source_path"] = sourcePath }
        if let referenceAction = args.referenceAction {
            object["reference_action"] = referenceAction
        }
        if let referenceID = args.referenceID { object["reference_id"] = referenceID }
        if let expected = args.expectedSourceSHA256 {
            object["expected_source_sha256"] = expected
        }
        if let expected = args.expectedStagedSHA256 {
            object["expected_staged_sha256"] = expected
        }
        if let body = args.sourceBodyID { object["source_body_id"] = body }
        if let format = args.format { object["format"] = format }
        if let unitScale = args.unitScale { object["unit_scale"] = unitScale }
        if let name = args.name { object["name"] = name }
        if let revision = args.revision { object["revision"] = revision }
        if let pageID = args.pageID { object["page_id"] = pageID }
        if let ids = args.bodyIDs { object["body_ids"] = ids }
        if let ids = args.instanceIDs { object["instance_ids"] = ids }
        if let accept = args.acceptPartial { object["accept_partial"] = accept }
        if let dryRun = args.dryRun { object["dry_run"] = dryRun }
        guard JSONSerialization.isValidJSONObject(object) else {
            throw FloeError.validationFailed("cad.document approved arguments could not be canonicalized")
        }
        return try JSONSerialization.data(withJSONObject: object, options: [])
    }

    private static func jsonValue(_ value: CadValue) throws -> Any {
        switch value {
        case .string(let text): return text
        case .number(let number):
            if number == number.rounded(), number.magnitude < 9_007_199_254_740_992 {
                return Int64(number)
            }
            return number
        case .boolean(let flag): return flag
        case .object(let nested): return try nested.mapValues { try Self.jsonValue($0) }
        case .array(let rows): return try rows.map { try Self.jsonValue($0) }
        case .null: return NSNull()
        }
    }

    /// Mirrors `RuntimeAuthorityDigest.canonicalTarget` for this tool's exact
    /// resolution rules (a `path` argument resolves to `file:<canonical>`,
    /// anything else falls back to the workspace identity). Both sides must
    /// derive the same string or the authority refuses.
    public static func canonicalTarget(for args: CadDocumentArguments, workspaceRoot: URL?) -> String {
        if let raw = args.path?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty, raw.utf8.count <= 4_096 {
            var url: URL?
            if raw.hasPrefix("/") {
                url = URL(fileURLWithPath: raw)
            } else if let workspaceRoot {
                url = workspaceRoot.appendingPathComponent(raw)
            }
            if let url {
                return "file:" + url.standardizedFileURL.resolvingSymlinksInPath().path
            }
        }
        guard let workspaceRoot else { return "workspace:*" }
        return "workspace:" + workspaceRoot.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Builds the binding this automatic apply call implies, exactly like the
    /// runtime minted it. Throws only when the approved arguments cannot be
    /// canonicalized (itself a refusal, never a bypass).
    public static func runtimeAuthorityBinding(for args: CadDocumentArguments,
                                               context: ToolContext) throws -> RuntimeAuthorityBinding {
        let payload = try canonicalApprovedPayload(args)
        return context.runtimeAuthorityBinding(
            toolName: name,
            operation: "apply",
            canonicalTarget: authorityTarget(for: args, context: context),
            baseRevision: RuntimeAuthorityDigest.baseRevision(in: payload),
            payloadDigest: RuntimeAuthorityDigest.payloadDigest(payload))
    }

    /// Canonical target for the approved call through the SAME authorized
    /// root the host resolves — the issuer/consumer parity rule.
    ///
    /// With a Canvas staged binding, a path that addresses EXACTLY the staged
    /// document (its exact relative form or its canonical absolute form)
    /// pins to the staged draft root, never the ordinary run root: the
    /// runtime mints its token through `MutationTargetResolver` with the same
    /// staged document, so both sides must derive `file:<draftRoot/draft>`.
    /// Any other path keeps the ordinary resolution, so the staged binding
    /// can neither broaden the token nor move it to another document (a
    /// foreign path is still refused by `authorizeDocumentPath`/the host
    /// before any authority is consulted).
    static func authorityTarget(for args: CadDocumentArguments, context: ToolContext) -> String {
        if let raw = args.path?.trimmingCharacters(in: .whitespacesAndNewlines),
           CanvasCADBindingKey.isCanvasOwned(raw) {
            guard let canonical = TypedMutationContract.canonicalCADCanvasDocumentPath(
                raw, serviceStorePaths: context.serviceStorePaths) else {
                // Deliberately unmatched: the runtime and host both refuse.
                return "unresolved:canvas-cad"
            }
            return "file:" + canonical
        }
        if let staged = context.canvasStagedDocument,
           let raw = args.path?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty, raw.utf8.count <= 4_096 {
            let stagedRoot = URL(fileURLWithPath: staged.draftRootPath)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            let stagedCanonical = stagedRoot
                .appendingPathComponent(staged.stagedRelativePath)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
            if raw == staged.stagedRelativePath {
                return "file:" + stagedCanonical
            }
            if raw.hasPrefix("/") {
                let argumentCanonical = URL(fileURLWithPath: raw)
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                    .path
                if argumentCanonical == stagedCanonical {
                    return "file:" + stagedCanonical
                }
            }
        }
        return canonicalTarget(for: args, workspaceRoot: context.workspaceRootURL)
    }

    public func execute(_ args: CadDocumentArguments, context: ToolContext) async throws -> ToolExecutionOutput {
        // Built-in documentation is served by the SAME capabilities action
        // before any document/host access. A caller never needs a file target
        // just to read the authored tool contract, and this path grants no
        // tool, file, environment or approval authority.
        if args.action == .capabilities,
           let helpRequest = try CadDocumentHelp.requestIfPresent(from: args.payload) {
            if let raw = args.kind?.trimmingCharacters(in: .whitespacesAndNewlines),
               !raw.isEmpty {
                throw FloeError.validationFailed(
                    "capabilities documentation and kind are separate selectors; send exactly one.")
            }
            return completeOutput(
                "cad.document help: " + (try CadDocumentHelp.responseJSON(for: helpRequest)),
                24_000
            )
        }
        let access = Self.access(for: context)
        try Self.authorizeDocumentPath(args.path, context: context)
        // `import`'s source_path is scoped by the host's workspace resolver
        // (same authorized root as the package), NOT by the single staged
        // Canvas document, because the source is a STEP/mesh file rather than
        // the draft itself.
        if args.action == .create, context.canvasStagedDocument != nil {
            // A staged Canvas draft authorizes exactly one existing document;
            // creating a new package is not part of that grant.
            throw FloeError.unauthorized
        }
        try await host.authorizeAccess(access: access)
        let requestID = args.requestID ?? context.toolCallID ?? context.runID.uuidString
        // Temporary chat stays READ-ONLY: material/parameter mutations are
        // refused here even though the same actions are ordinary authorized
        // edits in a normal task. Reads/lists and a viewport capture remain
        // available.
        // Temporary chat's global tool ceiling excludes CAD entirely. Do not
        // use the internal read-only version/list defenses as temporary-chat
        // authorization.
        if context.temporaryReadOnly, args.action == .versions {
            throw FloeError.unauthorized
        }
        if context.temporaryReadOnly,
           args.action == .material || args.action == .parameters
            || args.action == .animation || args.action == .scene {
            let payload = (try? Self.servicePayloadObject(args)) ?? [:]
            let action = payload["action"] as? String ?? ""
            let readOnlyMaterial: Set<String> = ["list", "read", "unresolved",
                                                  "libraryExport", "libraryList", "environment.read"]
            let globalExport = action == "libraryExport"
                && (Self.boolValue(payload["global"]) == true)
            let mutating: Bool
            if args.action == .animation {
                // Temporary chat may inspect the timeline and capture a
                // frame, but must not author clips/keyframes or run a long
                // external video export.
                mutating = !(CadNativeEditActions.animationReads.contains(action)
                             || action == "capture")
            } else if args.action == .material {
                mutating = !readOnlyMaterial.contains(action) || globalExport
            } else if args.action == .scene {
                mutating = !CadNativeEditActions.sceneReads.contains(
                    action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            } else {
                mutating = action != "list"
            }
            if mutating {
                throw FloeError.unauthorized
            }
        }
        // Unified representation routing: a `.floecad` package is answered by
        // the native kernel and never by the 2D DWG/DXF loader.
        let native = Self.isNativeRepresentation(args.path)

        switch args.action {
        case .observe:
            let request = try Self.modelObservationRequest(args, native: native)
            let result = try await host.observeModel(documentID: args.path!, request: request,
                                                     access: access,
                                                     cancellation: context.cancellation)
            try context.cancellation.throwIfCancelled()
            guard (!request.includeImages || !result.frames.isEmpty),
                  request.includeImages || result.frames.isEmpty,
                  result.frames.count <= request.views.count,
                  result.frames.reduce(0, { $0 + $1.pngData.count }) <= 32 * 1024 * 1024 else {
                throw FloeError.validationFailed("The model observer did not return a bounded set of actual frames.")
            }
            let support = try FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
            let root = support.appendingPathComponent("FloeAgent", isDirectory: true)
            let directory = "EngineeringObservations/\(context.runID.uuidString)"
            try FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
            var artifacts: [ToolArtifactReference] = []
            var receipts: [String] = []
            for frame in result.frames {
                try context.cancellation.throwIfCancelled()
                guard !frame.pngData.isEmpty, frame.pngData.count <= 16 * 1024 * 1024,
                      ProviderImageEvidencePolicy.sniffedMIME(frame.pngData) == "image/png" else {
                    throw FloeError.validationFailed("The model observer did not return a bounded PNG frame.")
                }
                let digest = FloeDigest.sha256Hex(frame.pngData)
                let relative = "\(directory)/\(digest).png"
                try frame.pngData.write(to: root.appendingPathComponent(relative), options: .atomic)
                let artifact = ToolArtifactReference(id: UUID(), relativePath: relative,
                    mimeType: "image/png", byteCount: frame.pngData.count, sha256: digest)
                _ = try VerifiedToolImageArtifact.load(artifact, root: root)
                artifacts.append(artifact)
                receipts.append("imageSHA256=\(digest) artifact=\(relative) \(frame.metadataJSON)")
            }
            return completeOutput("cad.document observe: \(result.summaryJSON)\n" + receipts.joined(separator: "\n"),
                                  24_000, artifacts: artifacts)
        case .capabilities:
            // The authoritative workbench-service catalog (action names,
            // effects, exact arguments and runnable examples) is served HERE on
            // demand and stays out of the every-turn schema: asking with a
            // `kind` returns that service's bounded page of detail. The reply
            // is kept inside the runtime's 4 KiB model-visible summary cap so
            // the JSON is never silently truncated.
            let rawDetailKind = args.kind?.trimmingCharacters(in: .whitespacesAndNewlines)
            let detailKind = (rawDetailKind?.isEmpty ?? true) ? nil : rawDetailKind
            if let detailKind, !CadServiceOperationCatalog.isKnownKind(detailKind) {
                throw FloeError.validationFailed(
                    "capabilities kind must be one of "
                        + CadServiceOperationCatalog.kinds.joined(separator: "|")
                        + " (got '\(detailKind)'); omit kind for the engine matrix.")
            }
            let detailOffset = max(0, args.offset ?? 0)
            let detailLimit = args.limit.map { min(CadServiceOperationCatalog.maximumPageSize, max(1, $0)) }
            if native {
                let reply = try await host.threeDAction(documentID: args.path!,
                                                        requestJSON: #"{"kind":"capabilities"}"#,
                                                        access: access)
                let merged = CadServiceOperationCatalog.mergingCapabilities(
                    into: reply, detailKind: detailKind, offset: detailOffset, limit: detailLimit)
                return completeOutput("cad.document capabilities: \(merged)", 24_000)
            }
            if args.path == nil {
                // A `kind` asks for one native service's exact operation
                // contract, which is served by the catalog itself (the 2D /
                // native engine matrices would blow the 4 KiB model budget).
                if let detailKind {
                    let merged = CadServiceOperationCatalog.mergingCapabilities(
                        into: #"{"ok":true}"#, detailKind: detailKind,
                        offset: detailOffset, limit: detailLimit)
                    return completeOutput("cad.document capabilities: \(merged)", 24_000)
                }
                // Discovery without a document reports BOTH engines: the 2D
                // DWG/DXF surface and the native package/3D surface, each with
                // its own format matrix. A 2D-only limitation must never read
                // as "3D unavailable", and a missing kernel is stated honestly.
                let twoD: Any
                do {
                    let json = try await host.capabilities(access: access)
                    twoD = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) ?? ["raw": json]
                } catch {
                    twoD = ["available": false, "error": error.localizedDescription]
                }
                var nativeCaps: [String: Any]
                do {
                    let json = try await host.nativeCapabilities(access: access)
                    nativeCaps = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
                        ?? ["raw": json]
                } catch let error as FloeError {
                    if case .notFound(let what) = error, what == "native_cad_kernel" {
                        nativeCaps = ["available": false]
                    } else {
                        throw error
                    }
                }
                let nativeJSON = CadServiceOperationCatalog.mergingCapabilities(
                    into: nativeCaps, detailKind: nil, offset: 0, limit: nil)
                nativeCaps = (try? JSONSerialization.jsonObject(with: Data(nativeJSON.utf8))) as? [String: Any]
                    ?? nativeCaps
                let merged: [String: Any] = [
                    "two_dimensional": twoD,
                    "native_three_dimensional": nativeCaps,
                ]
                return completeOutput("cad.document capabilities: \(jsonString(merged))", 32_000)
            }
            let caps = try await host.capabilities(access: access)
            return completeOutput("cad.document capabilities: \(caps)", 24_000)

        case .create:
            let path = args.path!
            if access.workspacePath?.isEmpty != false {
                throw FloeError.validationFailed(
                    "cad.document create needs the run's task workspace, but this run has no "
                        + "workspace root bound. The CAD package is created inside the task workspace "
                        + "(use the ordinary task conversation; a project workspace is not required).")
            }
            let fallbackName = ((path as NSString).lastPathComponent as NSString)
                .deletingPathExtension
            // An OMITTED name defaults to the path stem; an explicitly
            // supplied name is validated and a blank one is REFUSED (never
            // silently replaced by the fallback, which would create a package
            // the caller did not ask for).
            let name: String
            if let rawName = args.name {
                let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                if let issue = NativeCADPolicy.validateName(rawName) {
                    throw FloeError.validationFailed(issue)
                }
                guard !trimmed.isEmpty else {
                    throw FloeError.validationFailed(
                        NativeCADPolicy.emptyNameMessage)
                }
                name = trimmed
            } else {
                name = fallbackName
            }
            let receipt = try await host.createNativePackage(relativePath: path, name: name,
                                                             access: access)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let json = String(data: try encoder.encode(receipt), encoding: .utf8) ?? "{}"
            return completeOutput("cad.document created: \(json)", 16_000)

        case .import:
            // Import is a PROPOSAL draft, exactly like geometry propose: the
            // host evaluates the import on a throwaway copy of the package and
            // returns the frozen proposal/preview. Nothing is written until
            // the user confirms in the CAD UI and a subsequent apply carries
            // that UI-issued grant. The model cannot mint the grant.
            let source = args.sourcePath!.trimmingCharacters(in: .whitespacesAndNewlines)
            let inferred = (source as NSString).pathExtension.lowercased()
            guard let format = NativeCADPolicy.normalizedImportFormat(args.format)
                ?? NativeCADPolicy.normalizedImportFormat(inferred) else {
                throw FloeError.validationFailed(
                    "import supports STEP/STP, IGES/IGS and native mesh formats (STL/OBJ/GLB/glTF/USD/USDZ/Blender/ZIP)")
            }
            var payload: [String: Any] = [
                "path": source,
                "format": format,
            ]
            if let name = args.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                payload["name"] = name
            }
            if let scale = args.unitScale { payload["unitScale"] = scale }
            if args.payload != nil {
                let extra = try Self.servicePayloadObject(args)
                guard Set(extra.keys).isSubset(of: ["units", "resources"]) else {
                    throw FloeError.validationFailed("import payload accepts units and an explicit resources map only")
                }
                if let units = extra["units"] { payload["units"] = units }
                if let resources = extra["resources"] {
                    guard let paths = resources as? [String: String], paths.count <= 5_000 else {
                        throw FloeError.validationFailed("resources maps relative resource names to authorized workspace paths")
                    }
                    payload["resources"] = paths
                }
            }
            var envelope: [String: Any] = ["kind": "import", "payload": payload]
            if let summary = args.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
               !summary.isEmpty {
                envelope["summary"] = summary
            }
            let request = try jsonString(envelope)
            let reply = try await host.threeDAction(documentID: args.path!, requestJSON: request,
                                                    access: access,
                                                    cancellation: context.cancellation)
            return completeOutput("cad.document import proposal: \(reply)", 24_000)

        case .reference:
            // The SOURCE path is resolved by the host through the same task
            // workspace guard as import; the model supplies a path request,
            // not a grant. attach/update are ordinary authorized CAD edits
            // committed with CAS; check/inspect are read-only. The REAL
            // runtime token travels with the request so a late source load
            // cannot mutate after cancellation.
            try context.cancellation.throwIfCancelled()
            let source = args.sourcePath!.trimmingCharacters(in: .whitespacesAndNewlines)
            let action = args.referenceAction!
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var payload: [String: Any] = ["action": action, "path": source]
            if let id = args.referenceID { payload["reference_id"] = id }
            if let expected = args.expectedSourceSHA256 {
                payload["expected_source_sha256"] = expected.lowercased()
            }
            if let expected = args.expectedStagedSHA256 {
                payload["expected_staged_sha256"] = expected.lowercased()
            }
            if let body = args.sourceBodyID, !body.isEmpty {
                payload["source_body_id"] = body
            }
            if let name = args.name?.trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty {
                payload["name"] = name
            }
            let request = try jsonString(["kind": "reference", "payload": payload])
            let reply = try await host.reference(documentID: args.path!, requestJSON: request,
                                                 access: access,
                                                 cancellation: context.cancellation)
            return completeOutput("cad.document reference: \(reply)", 24_000)

        case .read:
            if native {
                let reply = try await host.threeDAction(
                    documentID: args.path!, requestJSON: #"{"kind":"snapshot"}"#, access: access)
                return completeOutput("cad.document read: \(reply)", 48_000)
            }
            let snapshot = try await host.snapshot(documentID: args.path!, access: access)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let json = String(data: try encoder.encode(snapshot), encoding: .utf8) ?? "{}"
            return completeOutput("cad.document read: \(json)", 24_000)

        case .query:
            if native {
                let request = try nativeQueryRequest(args)
                let reply = try await host.threeDAction(documentID: args.path!, requestJSON: request,
                                                        access: access)
                return completeOutput("cad.document query: \(reply)", 48_000)
            }
            let request = try queryRequest(args)
            let reply = try await host.query(documentID: args.path!, requestJSON: request, access: access)
            return completeOutput("cad.document query: \(reply)", 48_000)

        case .locate:
            if native {
                let request = try jsonString(["kind": "locate",
                                              "payload": ["handle": args.handles![0]]])
                let reply = try await host.threeDAction(documentID: args.path!, requestJSON: request,
                                                        access: access)
                return completeOutput("cad.document locate: \(reply)", 8_000)
            }
            let request = jsonString(["operation": "locate", "handle": args.handles![0]])
            let reply = try await host.query(documentID: args.path!, requestJSON: request, access: access)
            return completeOutput("cad.document locate: \(reply)", 8_000)

        case .measure:
            if native {
                let request = try nativeMeasureRequest(args)
                let reply = try await host.threeDAction(documentID: args.path!, requestJSON: request,
                                                        access: access)
                return completeOutput("cad.document measure: \(reply)", 8_000)
            }
            // Exact engine arity per kind, checked BEFORE the worker so the
            // model receives a structured message instead of a worker
            // exception. These strings mirror the engine's own errors.
            let measurePoints = args.points ?? []
            let measureHandles = args.handles ?? []
            switch args.kind! {
            case "distance":
                guard measurePoints.count == 2 || measureHandles.count == 2 else {
                    throw FloeError.validationFailed("CAD distance needs two points or two handles")
                }
            case "angle":
                guard measurePoints.count == 3 || measureHandles.count == 2 else {
                    throw FloeError.validationFailed("CAD angle needs three points or two line handles")
                }
            case "radius":
                guard measureHandles.count == 1 else {
                    throw FloeError.validationFailed("CAD radius needs one circle or arc handle")
                }
            case "perimeter":
                guard !measureHandles.isEmpty else {
                    throw FloeError.validationFailed("CAD perimeter needs at least one handle")
                }
            case "area":
                guard measureHandles.count == 1 || measurePoints.count >= 3 else {
                    throw FloeError.validationFailed("CAD area needs one closed entity handle or 3+ points")
                }
            default:
                break
            }
            var fields: [String: Any] = ["operation": "measure", "kind": args.kind!]
            if let points = args.points, !points.isEmpty {
                guard points.allSatisfy({ $0.count >= 2 && $0.allSatisfy { $0.isFinite } }) else {
                    throw FloeError.validationFailed("measure points must have at least two rows of finite x/y")
                }
                fields["points"] = points.map { [Double($0[0]), Double($0[1]), 0] }
            }
            if let handles = args.handles { fields["handles"] = handles }
            let reply = try await host.query(documentID: args.path!, requestJSON: jsonString(fields), access: access)
            return completeOutput("cad.document measure: \(reply)", 8_000)

        case .check:
            if native {
                let payload: [String: Any] = ["tolerance": args.tolerance ?? 0.001]
                let request = try jsonString(["kind": "check", "payload": payload])
                let reply = try await host.threeDAction(documentID: args.path!, requestJSON: request,
                                                        access: access)
                return completeOutput("cad.document check: \(reply)", 48_000)
            }
            let request = jsonString(["operation": "check", "tolerance": args.tolerance ?? 0.001])
            let reply = try await host.query(documentID: args.path!, requestJSON: request, access: access)
            return completeOutput("cad.document check: \(reply)", 48_000)

        case .status, .cancel:
            guard native else {
                throw FloeError.validationFailed(
                    "\(args.action.rawValue) is available for native .floecad documents only")
            }
            var payload: [String: Any] = [:]
            if let task = args.taskID { payload["task_id"] = task }
            let request = try jsonString(["kind": args.action.rawValue, "payload": payload])
            let reply = try await host.threeDAction(documentID: args.path!, requestJSON: request,
                                                    access: access)
            return completeOutput("cad.document \(args.action.rawValue): \(reply)", 24_000)

        case .versions:
            guard native else {
                throw FloeError.validationFailed(
                    "versions is available for native .floecad documents only")
            }
            var payload = try Self.servicePayloadObject(args)
            // An explicit top-level revision pin is also the restore base
            // revision; the service/engine applies it as CAS and refuses a
            // stale restore before touching the document.
            if let revision = args.revision, payload["expected_revision"] == nil {
                payload["expected_revision"] = revision
            }
            let request = try jsonString(["kind": "versions", "payload": payload])
            let reply = try await host.threeDAction(documentID: args.path!,
                                                    requestJSON: request,
                                                    access: access)
            return completeOutput("cad.document versions: \(reply)", 24_000)

        case .propose:
            if native {
                let request = try Self.threeDRequestJSON(kind: "propose", args: args)
                let reply = try await host.threeDAction(documentID: args.path!, requestJSON: request,
                                                        access: access)
                // The proposal changes nothing yet; BOTH authorization paths are
                // valid for the apply that follows (UI grant or the
                // runtime-approved call), so the model is told the truth.
                let note = "Apply this prepared change with action=apply and this proposal_id. "
                    + "Omit grant_id for ordinary authorized editing; no separate user confirmation is needed. "
                    + "The runtime verifies document ownership and the base revision before committing."
                return completeOutput("cad.document propose: \(reply)\n\(note)", 16_000)
            }
            let snapshot = try await host.snapshot(documentID: args.path!, access: access)
            guard snapshot.editable else {
                throw FloeError.validationFailed("this drawing has unresolved read diagnostics; editing is disabled")
            }
            let operationsJSON = try encodeOperations(Self.normalizedOperations(args.operations!))
            let proposal = try await host.prepareProposal(
                documentID: args.path!, snapshot: snapshot,
                summary: args.summary ?? "CAD edit proposal",
                operationsJSON: operationsJSON, access: access)
            try await host.storeProposal(proposal)
            let preview = proposal.preview
            let summary = """
            cad.document proposal \(proposal.id.uuidString) on \(proposal.documentID) \
            (revision \(proposal.baseRevision), sha256 \(proposal.baseSHA256.prefix(12))…): \
            +\(preview.counts["added"] ?? 0) ~\(preview.counts["changed"] ?? 0) -\(preview.counts["deleted"] ?? 0). \
            User confirmation is required for a manual apply: a grant id from the CAD UI, or (without one) \
            this exact approved apply call's runtime authority; a pending proposal alone changes nothing. \(preview.note)
            """
            return completeOutput(summary, 8_000)

        case .preview:
            if native {
                guard let id = args.proposalID else { throw FloeError.notFound("CAD proposal") }
                let request = try jsonString(["kind": "preview", "proposal_id": id.uuidString])
                let reply = try await host.threeDAction(documentID: args.path!, requestJSON: request,
                                                        access: access)
                return completeOutput("cad.document preview: \(reply)", 32_000)
            }
            guard let id = args.proposalID,
                  let proposal = try await host.loadProposal(id: id, access: access) else {
                throw FloeError.notFound("CAD proposal")
            }
            try await host.verifyProposalBinding(proposal, documentID: args.path!, access: access)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let json = String(data: try encoder.encode(proposal.preview), encoding: .utf8) ?? "{}"
            return completeOutput("cad.document preview: \(json)", 32_000)

        case .apply:
            if native {
                return try await applyNativeProposal(args, context: context, access: access,
                                                     requestID: requestID)
            }
            guard let id = args.proposalID else {
                throw FloeError.notFound("CAD proposal")
            }
            let grantID = (args.grantID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // The proposal may still be loadable (applied tombstone retained
            // for replay) or fully applied; both paths verify ownership first.
            if let proposal = try await host.loadProposal(id: id, access: access) {
                try await host.verifyProposalBinding(proposal, documentID: args.path!, access: access)
                let receipt: CadDocumentReceipt
                if !grantID.isEmpty {
                    receipt = try await host.apply(proposal: proposal, grantID: grantID,
                                                   requestID: requestID, access: access)
                } else {
                    // Automatic path: the ONLY authority is the runtime-issued
                    // task authority for this exact approved call. A
                    // model-supplied confirmation/grant-looking value is never
                    // consulted; the proposal itself still binds the exact
                    // document revision and SHA.
                    let authorization = try await Self.consumeAutomaticAuthorization(
                        args: args, context: context)
                    receipt = try await host.applyAutomatic(proposal: proposal,
                                                            authorization: authorization,
                                                            requestID: requestID, access: access)
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                let json = String(data: try encoder.encode(receipt), encoding: .utf8) ?? "{}"
                return completeOutput("cad.document apply: \(json)", 16_000)
            }
            guard let outcome = try await host.loadProposalOutcome(id: id, access: access) else {
                throw FloeError.notFound("CAD proposal")
            }
            // Already applied: only the identical request id replays the
            // original receipt; anything else is a new operation and the
            // consumed grant refuses it.
            guard outcome.requestID == requestID else {
                throw FloeError.validationFailed(
                    "proposal \(id.uuidString) was already applied with a different request; start a new proposal to change the drawing again.")
            }
            var replay = outcome.receipt
            replay.replay = true
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let json = String(data: try encoder.encode(replay), encoding: .utf8) ?? "{}"
            return completeOutput("cad.document apply: \(json)", 16_000)

        case .save:
            if native {
                let reply = try await host.threeDAction(documentID: args.path!,
                                                        requestJSON: #"{"kind":"save"}"#, access: access)
                return completeOutput("cad.document save: \(reply)", 16_000)
            }
            let snapshot = try await host.snapshot(documentID: args.path!, access: access)
            let receipt = try await host.save(documentID: args.path!, expectedSHA256: snapshot.sha256,
                                              requestID: requestID, access: access)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let json = String(data: try encoder.encode(receipt), encoding: .utf8) ?? "{}"
            return completeOutput("cad.document save: \(json)", 16_000)

        case .export:
            if native {
                let explicitFormat = args.format?
                    .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                var output = args.output
                if let explicitFormat, !explicitFormat.isEmpty {
                    let allowed = NativeCADPolicy.exportExtensions
                    guard allowed.contains(explicitFormat) else {
                        throw FloeError.validationFailed(
                            "export format '\(explicitFormat)' is not supported "
                            + "(step, stp, iges, igs, stl, obj, obj_bundle, 3mf, glb, usdz, "
                            + "pdf, svg, dxf, csv); gltf is import-only; glTF export writes .glb.")
                    }
                    let normalized: String
                    switch explicitFormat {
                    case "stp": normalized = "step"
                    case "igs": normalized = "iges"
                    default: normalized = explicitFormat
                    }
                    if output == nil {
                        output = Self.defaultNativeExportPath(for: args.path!, format: normalized)
                    }
                    let ext = (output! as NSString).pathExtension.lowercased()
                    switch normalized {
                    case "obj_bundle":
                        guard ext == "zip" else {
                            throw FloeError.validationFailed(
                                "obj_bundle writes a .zip archive (model.obj + model.mtl + textures). "
                                + "Use a .zip output path; for a single geometry OBJ use format=obj with a .obj path.")
                        }
                    case "step":
                        guard ext == "step" || ext == "stp" else {
                            let actual = ext.isEmpty ? "(no extension)" : ".\(ext)"
                            throw FloeError.validationFailed(
                                "format=step requires a .step or .stp output path; got '\(actual)'.")
                        }
                    case "iges":
                        guard ext == "iges" || ext == "igs" else {
                            let actual = ext.isEmpty ? "(no extension)" : ".\(ext)"
                            throw FloeError.validationFailed(
                                "format=iges requires a .iges or .igs output path; got '\(actual)'.")
                        }
                    default:
                        if normalized == "obj", ext == "zip" {
                            throw FloeError.validationFailed(
                                "format=obj writes a single .obj file without materials. "
                                + "Use a .obj output path, or format=obj_bundle for a .zip with model.mtl and textures.")
                        }
                        guard ext == normalized else {
                            let actual = ext.isEmpty ? "(no extension)" : ".\(ext)"
                            throw FloeError.validationFailed(
                                "format=\(normalized) requires a .\(normalized) output path; got '\(actual)'.")
                        }
                    }
                } else {
                    let derived = args.output ?? Self.defaultNativeExportPath(for: args.path!)
                    let ext = (derived as NSString).pathExtension.lowercased()
                    if ext == "zip" {
                        throw FloeError.validationFailed(
                            "A .zip output requires format=obj_bundle. "
                            + "Plain format=obj writes a single .obj file without materials.")
                    }
                    if ext == "obj_bundle" {
                        throw FloeError.validationFailed(
                            "obj_bundle uses a .zip output path; pass format=obj_bundle with a .zip output.")
                    }
                    if ext.isEmpty {
                        throw FloeError.validationFailed(
                            "export needs an output path with a format extension, or an explicit format.")
                    }
                    guard NativeCADPolicy.exportExtensions.contains(ext) else {
                        throw FloeError.validationFailed(
                            "output extension '.\(ext)' is not a supported native export format; "
                            + "use step/stp, iges/igs, stl, obj, obj_bundle (.zip), 3mf, glb, usdz, "
                            + "pdf, svg, dxf or csv. gltf is import-only.")
                    }
                }
                let resolvedOutput = output ?? Self.defaultNativeExportPath(for: args.path!)
                let effectiveFormat: String
                if let explicitFormat, !explicitFormat.isEmpty {
                    switch explicitFormat {
                    case "stp": effectiveFormat = "step"
                    case "igs": effectiveFormat = "iges"
                    default: effectiveFormat = explicitFormat
                    }
                } else {
                    let ext = (resolvedOutput as NSString).pathExtension.lowercased()
                    effectiveFormat = ext == "igs" ? "iges" : ext
                }
                var payload: [String: Any] = ["output": resolvedOutput,
                                              "format": effectiveFormat]
                // PDF/SVG/DXF exports are DRAWING-page exports: the page id the
                // model read from `query` kind=drawings selects the page (the
                // engine refuses `page_required` without one).
                if let raw = args.pageID?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
                    payload["page_id"] = raw
                }
                if let raw = args.scope?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !raw.isEmpty {
                    payload["scope"] = raw.lowercased()
                }
                if let ids = args.bodyIDs { payload["body_ids"] = ids }
                if let ids = args.instanceIDs { payload["instance_ids"] = ids }
                if let accept = args.acceptPartial { payload["accept_partial"] = accept }
                if let dryRun = args.dryRun { payload["dry_run"] = dryRun }
                if let revision = args.revision { payload["expected_revision"] = Int(revision) }
                let request = try jsonString(["kind": "export", "payload": payload])
                let reply = try await host.threeDAction(documentID: args.path!, requestJSON: request,
                                                        access: access)
                return completeOutput("cad.document export: \(reply)", 16_000)
            }
            let output = args.output ?? Self.defaultExportPath(for: args.path!)
            let receipt = try await host.export(documentID: args.path!, relativeOutput: output, access: access)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let json = String(data: try encoder.encode(receipt), encoding: .utf8) ?? "{}"
            let summary = bounded("cad.document export: \(json)", 16_000)
            // S3-D: the host's CadExportReceipt already carries the verified
            // commit digest + size, so publication reuses it (no rehash). The
            // native threeDAction drawing-export branch below has no typed
            // commit identity and stays deliberately unpublished — a string
            // reply never becomes a fabricated receipt.
            switch RunOutputWorkbenchPublication.state(context) {
            case .legacyDirect, .temporaryExempt:
                return ToolExecutionOutput(digesting: summary)
            case .partiallyBound:
                throw RunOutputWorkbenchPublication.partialBindingFailure
            case .required:
                let fileURL = try Self.runOutputSourceURL(relativePath: receipt.relativePath, context: context)
                return try RunOutputWorkbenchPublication.publish(
                    summary: summary,
                    url: fileURL,
                    sha256: receipt.sha256,
                    byteCount: receipt.byteCount,
                    producerTool: Self.name,
                    slot: "export",
                    mimeType: Self.cadExportMIMEType(forPath: fileURL.path),
                    using: context)
            }

        case .material:
            let payload = try Self.servicePayloadObject(args)
            var envelope: [String: Any] = ["kind": "material", "payload": payload]
            if let revision = args.revision { envelope["revision"] = revision }
            let request = try jsonString(envelope)
            let reply = try await host.threeDAction(documentID: args.path!, requestJSON: request,
                                                    access: access)
            if let object = (try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any],
               object["ok"] as? Bool == false {
                let code = (object["error"] as? String) ?? "material_failed"
                let message = (object["message"] as? String) ?? "The material operation was refused."
                throw FloeError.validationFailed("\(code): \(message)")
            }
            return completeOutput("cad.document material: \(reply)", 48_000)

        case .parameters:
            let payload = try Self.servicePayloadObject(args)
            var envelope: [String: Any] = ["kind": "parameters", "payload": payload]
            if let revision = args.revision { envelope["revision"] = revision }
            let request = try jsonString(envelope)
            let reply = try await host.threeDAction(documentID: args.path!, requestJSON: request,
                                                    access: access)
            if let object = (try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any],
               object["ok"] as? Bool == false {
                let code = (object["error"] as? String) ?? "parameter_failed"
                let message = (object["message"] as? String) ?? "The parameter operation was refused."
                throw FloeError.validationFailed("\(code): \(message)")
            }
            return completeOutput("cad.document parameters: \(reply)", 48_000)

        case .scene:
            var payload = try Self.servicePayloadObject(args)
            let rawSceneAction = (payload["action"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let sceneAction = CadNativeEditActions.scene.first(where: {
                $0.lowercased() == rawSceneAction.lowercased()
            }) else {
                throw FloeError.validationFailed(
                    "scene requires a known payload.action")
            }
            payload["action"] = sceneAction
            var sceneEnvelope: [String: Any] = ["kind": "scene", "payload": payload]
            if let revision = args.revision { sceneEnvelope["revision"] = revision }
            let sceneReply = try await host.threeDAction(
                documentID: args.path!,
                requestJSON: jsonString(sceneEnvelope), access: access)
            if let object = (try? JSONSerialization.jsonObject(
                with: Data(sceneReply.utf8))) as? [String: Any],
               object["ok"] as? Bool == false {
                let code = (object["error"] as? String) ?? "scene_failed"
                let message = (object["message"] as? String)
                    ?? "The view overlay operation was refused."
                throw FloeError.validationFailed("\(code): \(message)")
            }
            return completeOutput("cad.document scene: \(sceneReply)", 32_000)

        case .animation:
            var payload = try Self.servicePayloadObject(args)
            let rawAction = (payload["action"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let action = CadNativeEditActions.animation.first(where: {
                $0.lowercased() == rawAction.lowercased()
            }) else {
                throw FloeError.validationFailed(
                    "animation requires a known payload.action")
            }
            payload["action"] = action
            if action == "capture" {
                let request = Self.animationCaptureRequest(
                    payload, expectedRevision: args.revision)
                let capture = try await host.captureAnimationFrame(
                    documentID: args.path!, request: request, access: access)
                let artifact = try Self.writeAnimationArtifact(
                    capture, context: context)
                var object: [String: Any] = [
                    "ok": true,
                    "action": "animation.capture",
                    "clip_id": capture.clipID.uuidString,
                    "time": capture.timeSeconds,
                    "frame": capture.frameIndex,
                    "fps": capture.frameRate,
                    "revision": capture.revision,
                    "change_count": capture.changeCount,
                    "content_sha256": capture.contentSHA256,
                    "image_sha256": capture.sha256,
                    "renderer": capture.renderer,
                    "width": capture.width,
                    "height": capture.height,
                    "mime_type": capture.mimeType,
                    "byte_count": capture.imageData.count,
                    "artifact": artifact.relativePath,
                    "note": capture.note,
                    "vision": "The attached image is the actual animated native render. "
                        + "Only a vision-capable model may inspect it; otherwise use evaluate values.",
                ]
                if let taskID = capture.taskID {
                    object["task_id"] = taskID.uuidString
                }
                return completeOutput(
                    "cad.document animation.capture: \(Self.jsonText(object))",
                    8_000, artifacts: [artifact])
            }
            if action == "export" {
                let options = Self.animationExportOptions(payload)
                let output = args.output
                    ?? Self.defaultAnimationExportPath(
                        for: args.path!, format: options.format)
                let receipt = try await host.exportAnimation(
                    documentID: args.path!, relativeOutput: output,
                    options: options, access: access)
                var object: [String: Any] = [
                    "ok": true,
                    "action": "animation.export",
                    "task_id": receipt.taskID.uuidString,
                    "output": receipt.relativePath,
                    "width": receipt.width,
                    "height": receipt.height,
                    "frame_rate": receipt.frameRate,
                    "duration": receipt.durationSeconds,
                    "frame_count": receipt.frameCount,
                    "codec": receipt.codec,
                    "has_audio": receipt.hasAudio,
                    "byte_count": receipt.byteCount,
                    "sha256": receipt.sha256,
                    "format": receipt.format,
                    "alpha": receipt.alpha,
                    "note": receipt.note,
                ]
                object["poster_png_bytes"] = receipt.posterPNG?.count ?? 0
                if let manifest = receipt.manifestSHA256 {
                    object["manifest_sha256"] = manifest
                }
                if let times = receipt.frameTimes, let first = times.first,
                   let last = times.last {
                    object["frame_time_range"] = [first, last]
                }
                let summary = Self.jsonText(object)
                switch RunOutputWorkbenchPublication.state(context) {
                case .legacyDirect, .temporaryExempt:
                    return ToolExecutionOutput(
                        digesting: "cad.document animation.export: \(summary)")
                case .partiallyBound:
                    throw RunOutputWorkbenchPublication.partialBindingFailure
                case .required:
                    let fileURL = try Self.runOutputSourceURL(
                        relativePath: receipt.relativePath, context: context)
                    return try RunOutputWorkbenchPublication.publish(
                        summary: "cad.document animation.export: \(summary)",
                        url: fileURL,
                        sha256: receipt.sha256,
                        byteCount: Int(receipt.byteCount),
                        producerTool: Self.name,
                        slot: "export",
                        mimeType: receipt.format == "png_zip"
                            ? "application/zip" : "video/mp4",
                        uti: receipt.format == "png_zip"
                            ? "public.zip-archive" : "public.mpeg-4",
                        using: context)
                }
            }
            var envelope: [String: Any] = ["kind": "animation", "payload": payload]
            if let revision = args.revision { envelope["revision"] = revision }
            let request = try jsonString(envelope)
            let reply = try await host.threeDAction(
                documentID: args.path!, requestJSON: request, access: access)
            if let object = (try? JSONSerialization.jsonObject(
                with: Data(reply.utf8))) as? [String: Any],
               object["ok"] as? Bool == false {
                let code = (object["error"] as? String) ?? "animation_failed"
                let message = (object["message"] as? String)
                    ?? "The animation operation was refused."
                throw FloeError.validationFailed("\(code): \(message)")
            }
            return completeOutput("cad.document animation: \(reply)", 48_000)

        case .capture:
            let payload = try Self.servicePayloadObject(args)
            let width = Self.intValue(payload["width"] ?? 1024) ?? 1024
            let height = Self.intValue(payload["height"] ?? 768) ?? 768
            let capture = try await host.captureViewport(
                documentID: args.path!, width: width, height: height,
                expectedRevision: args.revision, access: access)
            let artifact = try Self.writeViewportArtifact(capture, context: context)
            let object: [String: Any] = [
                "ok": true,
                "action": "capture",
                "revision": capture.revision,
                "change_count": capture.changeCount,
                "content_sha256": capture.contentSHA256,
                "image_sha256": capture.sha256,
                "renderer": capture.renderer,
                "width": capture.width,
                "height": capture.height,
                "byte_count": capture.pngData.count,
                "artifact": artifact.relativePath,
                "note": capture.note,
                "vision": "The attached PNG is the actual live viewport. Only a vision-capable model may inspect it; "
                    + "otherwise use measure/query values and do not claim visual inspection.",
            ]
            let summary = Self.jsonText(object)
            return completeOutput("cad.document capture: \(summary)", 8_000,
                                       artifacts: [artifact])

        case .threeDSnapshot, .threeDMeasure, .threeDPropose, .threeDApply,
             .threeDAssembly, .threeDDrawing:
            let kind: String
            switch args.action {
            case .threeDSnapshot: kind = "snapshot"
            case .threeDMeasure: kind = "measure"
            case .threeDPropose: kind = "propose"
            case .threeDApply: kind = "apply"
            case .threeDAssembly: kind = "assembly"
            default: kind = "drawing"
            }
            // The model never mints a grant; when one is supplied it is passed
            // through only so the host can validate one the UI issued. Without
            // one, the unified runtime-approved-call path applies the proposal
            // (the alias shares the exact same authority rules as `apply`).
            if kind == "apply" {
                return try await applyNativeProposal(args, context: context, access: access,
                                                     requestID: requestID)
            }
            if (kind == "propose" || kind == "measure"), args.op == nil {
                throw FloeError.validationFailed("cad.document \(kind) requires op.")
            }
            if kind == "assembly" || kind == "drawing" {
                // Resolve the one named operation through the authoritative
                // catalog and forward the CANONICAL action plus its flattened
                // arguments. A missing/unknown action throws here (and again in
                // validate) instead of reaching the bridge, which would have
                // silently defaulted to a read.
                guard native else {
                    throw FloeError.validationFailed(
                        "\(args.action.rawValue) serves native .floecad workbench services; "
                            + "a DWG/DXF drawing uses read/query/measure/propose/export.")
                }
                let payload = try Self.servicePayloadObject(args)
                let resolved = try Self.resolveService(kind: kind, payload: payload)
                var servicePayload = resolved.arguments
                servicePayload["action"] = resolved.operation.action
                let request = try Self.threeDRequestJSON(kind: kind, args: args,
                                                         servicePayload: servicePayload)
                let reply = try await host.threeDAction(documentID: args.path!,
                                                        requestJSON: request, access: access)
                return completeOutput("cad.document \(kind): \(reply)", 48_000)
            }
            let request = try Self.threeDRequestJSON(kind: kind, args: args)
            let reply = try await host.threeDAction(documentID: args.path!,
                                                    requestJSON: request, access: access)
            return completeOutput("cad.document \(kind): \(reply)", 48_000)
        }
    }

    /// The unified native apply: an explicit UI grant keeps the interactive
    /// human-reviewed path unchanged; WITHOUT one the only authority is the
    /// runtime-issued task authority for this exact approved call, re-verified
    /// by the host against the real canonical document. The returned reply is
    /// the host's receipt JSON.
    private func applyNativeProposal(_ args: CadDocumentArguments, context: ToolContext,
                                     access: CadDocumentAccess,
                                     requestID: String) async throws -> ToolExecutionOutput {
        guard let id = args.proposalID else {
            throw FloeError.notFound("CAD proposal")
        }
        let grant = (args.grantID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !grant.isEmpty {
            let request = try jsonString(["kind": "apply",
                                          "proposal_id": id.uuidString,
                                          "grant_id": grant,
                                          "request_id": requestID])
            let reply = try await host.threeDAction(documentID: args.path!, requestJSON: request,
                                                    access: access,
                                                    cancellation: context.cancellation)
            return completeOutput("cad.document apply: \(reply)", 16_000)
        }
        let authorization = try await Self.consumeAutomaticAuthorization(args: args, context: context)
        let reply = try await host.applyAutomatic(proposalID: id, authorization: authorization,
                                                  requestID: requestID, access: access)
        return completeOutput("cad.document apply: \(reply)", 16_000)
    }

    /// Consumes the runtime-issued authority for one automatic apply. The
    /// binding is derived from the DECODED approved arguments (canonical JSON,
    /// sorted keys) and the caller's real context, exactly like the runtime
    /// derived it when it minted the token; the token is single-use, so a
    /// replay (or a second consumer) sees `.alreadyConsumed`. Any mismatch —
    /// run, task, environment, target, tool, operation, call id, idempotency
    /// key, revision or payload — refuses. A model-supplied `confirmed` flag,
    /// grant-looking string or invented UUID creates nothing.
    static func consumeAutomaticAuthorization(args: CadDocumentArguments,
                                              context: ToolContext) async throws -> CadAutomaticAuthorization {
        let binding: RuntimeAuthorityBinding
        do {
            binding = try runtimeAuthorityBinding(for: args, context: context)
        } catch {
            throw FloeError.validationFailed(
                "automatic apply could not bind the approved call: \(error.localizedDescription)")
        }
        let verdict = await context.consumeRuntimeAuthority(binding: binding)
        guard verdict.isValid else {
            throw FloeError.validationFailed(
                "automatic apply needs the runtime-approved call authority for this exact operation"
                    + (verdict.failureReason.map { " (\($0))" } ?? "")
                    + "; confirm the proposal in the CAD UI (grant_id), or send the apply call "
                    + "with canonical JSON arguments (omit optional fields instead of null).")
        }
        return CadAutomaticAuthorization(
            runID: context.runID,
            taskID: context.conversationID,
            operationID: context.toolCallID ?? "",
            idempotencyKey: context.toolIdempotencyKey,
            approvalGrantID: context.approvalGrantID,
            binding: binding)
    }

    /// Bounded JSON text for tool summaries.
    static func jsonText(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    static func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
    }

    static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? Double, value == value.rounded() { return Int(value) }
        if let value = value as? String { return Int(value) }
        return nil
    }

    static func isBoundedInt(_ value: Any?, _ range: ClosedRange<Int>) -> Bool {
        guard let parsed = intValue(value) else { return false }
        return range.contains(parsed)
    }

    static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    /// Writes the real viewport PNG into Floe's app-storage artifact root
    /// (never a user workspace file) and returns the runtime-visible image
    /// artifact. The path is content-addressed by its SHA-256 so repeated
    /// captures of the same revision are idempotent.
    static func writeViewportArtifact(_ capture: CadViewportCapture,
                                      context: ToolContext) throws -> ToolArtifactReference {
        guard FloeDigest.sha256Hex(capture.pngData) == capture.sha256.lowercased(),
              ProviderImageEvidencePolicy.sniffedMIME(capture.pngData) == "image/png" else {
            throw FloeError.validationFailed("The viewport image does not match its capture receipt.")
        }
        guard capture.pngData.count <= 16 * 1024 * 1024 else {
            throw FloeError.validationFailed("The viewport PNG exceeds the 16 MiB artifact bound.")
        }
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let relativeDirectory = "CADViewportArtifacts/\(context.runID.uuidString)"
        let directory = support
            .appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent(relativeDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        let fileName = "\(capture.sha256).png"
        let url = directory.appendingPathComponent(fileName, isDirectory: false)
        let artifact = ToolArtifactReference(
            id: UUID(),
            relativePath: "\(relativeDirectory)/\(fileName)",
            mimeType: "image/png",
            byteCount: capture.pngData.count,
            sha256: capture.sha256)
        let root = support.appendingPathComponent("FloeAgent", isDirectory: true)
        if (try? VerifiedToolImageArtifact.load(artifact, root: root)) == nil {
            try capture.pngData.write(to: url, options: .atomic)
        }
        _ = try VerifiedToolImageArtifact.load(artifact, root: root)
        return artifact
    }

    /// Parse the animation capture payload into the host contract. The engine
    /// validates every value again; defaults are the same 1920x1080/30 fps
    /// contract the timeline/export use.
    static func animationCaptureRequest(
        _ payload: [String: Any], expectedRevision: Int64?
    ) -> CadAnimationCaptureRequest {
        CadAnimationCaptureRequest(
            clipID: (payload["clip_id"] as? String).flatMap(UUID.init(uuidString:)),
            timeSeconds: doubleValue(payload["time"]),
            frame: intValue(payload["frame"]),
            fps: intValue(payload["fps"] ?? 30) ?? 30,
            width: intValue(payload["width"] ?? 1920) ?? 1920,
            height: intValue(payload["height"] ?? 1080) ?? 1080,
            format: ((payload["format"] as? String) ?? "png").lowercased(),
            jpegQuality: doubleValue(payload["jpeg_quality"]) ?? 0.92,
            expectedRevision: expectedRevision)
    }

    static func animationExportOptions(_ payload: [String: Any])
    -> CadAnimationExportOptions {
        let format = ((payload["format"] as? String) ?? "mp4").lowercased()
        let isVideo = format == "mp4"
        let alpha = ((payload["alpha"] as? String) ?? "opaque").lowercased()
        return CadAnimationExportOptions(
            width: intValue(payload["width"] ?? 1920) ?? 1920,
            height: intValue(payload["height"] ?? 1080) ?? 1080,
            frameRate: intValue(payload["fps"] ?? 30) ?? 30,
            codec: isVideo
                ? ((payload["codec"] as? String) ?? "h264").lowercased()
                : "png",
            bitrate: isVideo ? intValue(payload["bitrate"]) : nil,
            overwrite: boolValue(payload["overwrite"]) ?? false,
            posterEnabled: boolValue(payload["poster"]) ?? true,
            format: format,
            alpha: alpha)
    }

    /// Writes a real animation frame into Floe's app-storage artifact root and
    /// returns the runtime-visible image artifact. Content-addressed by the
    /// image SHA so repeated captures of one frame are idempotent.
    static func writeAnimationArtifact(_ capture: CadAnimationCapture,
                                       context: ToolContext) throws -> ToolArtifactReference {
        guard FloeDigest.sha256Hex(capture.imageData) == capture.sha256.lowercased(),
              ProviderImageEvidencePolicy.sniffedMIME(capture.imageData)
                == ProviderImageEvidencePolicy.canonicalMIMEType(capture.mimeType) else {
            throw FloeError.validationFailed("The animation image does not match its capture receipt.")
        }
        guard capture.imageData.count <= 16 * 1024 * 1024 else {
            throw FloeError.validationFailed(
                "The animation frame exceeds the 16 MiB artifact bound.")
        }
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let relativeDirectory = "CADAnimationFrames/\(context.runID.uuidString)"
        let directory = support
            .appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent(relativeDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        let ext = capture.mimeType == "image/jpeg" ? "jpg" : "png"
        let fileName = "\(capture.sha256).\(ext)"
        let url = directory.appendingPathComponent(fileName, isDirectory: false)
        let artifact = ToolArtifactReference(
            id: UUID(),
            relativePath: "\(relativeDirectory)/\(fileName)",
            mimeType: capture.mimeType,
            byteCount: capture.imageData.count,
            sha256: capture.sha256)
        let root = support.appendingPathComponent("FloeAgent", isDirectory: true)
        if (try? VerifiedToolImageArtifact.load(artifact, root: root)) == nil {
            try capture.imageData.write(to: url, options: .atomic)
        }
        _ = try VerifiedToolImageArtifact.load(artifact, root: root)
        return artifact
    }

    static func defaultAnimationExportPath(
        for path: String, format: String = "mp4"
    ) -> String {
        let ns = path as NSString
        // A Canvas key addresses a package inside the Canvas package root, not
        // a literal `canvas-cad:<uuid>/` directory under that root.
        let canvasOwned = CanvasCADBindingKey.isCanvasOwned(path)
        let name = ns.lastPathComponent
        let base = (name as NSString).deletingPathExtension
        let directory = canvasOwned ? "" : ns.deletingLastPathComponent
        let extensionName = format == "png_zip" ? "zip" : "mp4"
        let file = "\(base.isEmpty ? "part" : base).animation.\(extensionName)"
        return directory.isEmpty ? file : "\(directory)/\(file)"
    }

    static func defaultExportPath(for path: String) -> String {
        let name = (path as NSString).lastPathComponent
        let base = (name as NSString).deletingPathExtension
        let directory = (path as NSString).deletingLastPathComponent
        let file = "\(base.isEmpty ? "drawing" : base).export.dxf"
        return directory.isEmpty ? file : "\(directory)/\(file)"
    }

    /// S3-D: resolves a host-committed export receipt path to the real file
    /// under the task workspace. The snapshot store independently rejects
    /// non-regular or aliased sources; this only guarantees containment.
    static func runOutputSourceURL(relativePath: String, context: ToolContext) throws -> URL {
        guard !relativePath.isEmpty, !relativePath.contains("\0"),
              !relativePath.split(separator: "/").contains("..") else {
            throw RunOutputWorkbenchPublication.sourceUnavailable("export path is not workspace-contained")
        }
        guard let root = context.workspaceRootURL else {
            throw RunOutputWorkbenchPublication.sourceUnavailable("no task workspace")
        }
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root.appendingPathComponent(relativePath)
            .standardizedFileURL.resolvingSymlinksInPath()
        let prefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
        guard candidate.path.hasPrefix(prefix) else {
            throw RunOutputWorkbenchPublication.sourceUnavailable("export path escapes the task workspace")
        }
        return candidate
    }

    static func cadExportMIMEType(forPath path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "dxf": return "image/vnd.dxf"
        case "dwg": return "image/vnd.dwg"
        case "pdf": return "application/pdf"
        case "svg": return "image/svg+xml"
        case "csv": return "text/csv"
        default: return "application/octet-stream"
        }
    }

    /// Native export defaults to an exact STEP copy beside the package; the
    /// host validates the format against the output extension and refuses a
    /// mesh-only downgrade unless the caller names a mesh format.
    static func defaultNativeExportPath(for path: String) -> String {
        defaultNativeExportPath(for: path, format: "step")
    }

    /// Default output for an explicitly named export format. `obj_bundle` is a
    /// ZIP container; every other format uses its own extension.
    static func defaultNativeExportPath(for path: String, format: String) -> String {
        let name = (path as NSString).lastPathComponent
        let base = (name as NSString).deletingPathExtension
        let directory = (path as NSString).deletingLastPathComponent
        let ext = format == "obj_bundle" ? "zip" : (format == "stp" ? "step" : format)
        let file = "\(base.isEmpty ? "part" : base).export.\(ext)"
        return directory.isEmpty ? file : "\(directory)/\(file)"
    }

    /// Native `query` request: one read scope from `nativeQueryScopes` plus
    /// bounded paging/filter fields.
    private func nativeQueryRequest(_ args: CadDocumentArguments) throws -> String {
        guard let kind = args.kind, Self.nativeQueryScopes.contains(kind) else {
            throw FloeError.validationFailed(
                "native query requires kind (\(Self.nativeQueryScopes.sorted().joined(separator: "|")))")
        }
        var payload: [String: Any] = ["scope": kind]
        if let offset = args.offset { payload["offset"] = max(0, offset) }
        if let limit = args.limit { payload["limit"] = min(500, max(1, limit)) }
        if let value = args.layer { payload["layer"] = value }
        if let value = args.text { payload["text"] = value }
        return jsonString(["kind": "query", "payload": payload])
    }

    /// Native `measure` request: deterministic kernel measurements over the
    /// document (body, distance, bounds, DOF, interference, mesh health,
    /// rebuild status). No view/render values are measured.
    ///
    /// Body-addressed kinds accept the DOCUMENTED handle vocabulary
    /// (`body:<uuid>`) and translate it to the kernel's raw-UUID arguments
    /// (`bodyID`/`bodyIDs`): the kernel's `measureJSON` resolves a body by
    /// `UUID(uuidString:)`, so a handle string or any other prefix would be an
    /// unresolvable id. A foreign handle is refused here, before the host or
    /// the kernel is called.
    private func nativeMeasureRequest(_ args: CadDocumentArguments) throws -> String {
        guard let kind = args.op ?? args.kind, Self.nativeMeasureKinds.contains(kind) else {
            throw FloeError.validationFailed(
                "native measure requires kind (\(Self.nativeMeasureKinds.sorted().joined(separator: "|")))")
        }
        var payload: [String: Any] = ["kind": kind]
        switch kind {
        case "body", "mesh":
            payload["bodyID"] = try Self.nativeBodyUUID(fromHandle: args.handles!.first!,
                                                         kind: kind)
        case "distance":
            payload["points"] = args.points!.map { Array($0.prefix(3)) }
        case "bounds":
            guard let handles = args.handles, !handles.isEmpty else {
                throw FloeError.validationFailed(
                    "native bounds measure needs at least one body:<uuid> handle")
            }
            payload["bodyIDs"] = try handles.map {
                try Self.nativeBodyUUID(fromHandle: $0, kind: kind)
            }
        case "interference":
            payload["toleranceMM"] = args.tolerance ?? 1e-6
        default:
            break
        }
        return jsonString(["kind": "measure", "payload": payload])
    }

    /// The kernel's body id for one native measure handle: `body:<uuid>` (the
    /// handle form `locate`/`query` also use) or the bare UUID a row already
    /// carries. Anything else refuses: forwarding an unresolvable handle would
    /// produce a kernel `unknown_body` instead of naming the real problem.
    static func nativeBodyUUID(fromHandle handle: String, kind: String) throws -> String {
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = trimmed.lowercased().hasPrefix("body:")
            ? String(trimmed.dropFirst("body:".count))
            : trimmed
        guard let uuid = UUID(uuidString: raw) else {
            throw FloeError.validationFailed(
                "native \(kind) measure needs a body:<uuid> handle "
                    + "(a bare body UUID is also accepted); got '\(handle)'.")
        }
        return uuid.uuidString
    }

    private func queryRequest(_ args: CadDocumentArguments) throws -> String {
        guard let kind = args.kind else {
            throw FloeError.validationFailed("query requires kind")
        }
        var fields: [String: Any] = ["operation": kind]
        switch kind {
        case "entities", "text":
            fields["offset"] = max(0, args.offset ?? 0)
            fields["limit"] = min(500, max(1, args.limit ?? 100))
            if let value = args.entityType { fields["type"] = value }
            if let value = args.layer { fields["layer"] = value }
            if let value = args.text { fields["text"] = value }
            if let handles = args.handles, !handles.isEmpty { fields["handles"] = handles }
        case "layers", "drawing":
            break
        case "snap":
            guard let point = args.points?.first, point.count >= 2,
                  point[0].isFinite, point[1].isFinite else {
                throw FloeError.validationFailed("snap requires a finite point")
            }
            fields["point"] = [point[0], point[1], 0]
            fields["tolerance"] = args.tolerance ?? 1.0
        default:
            throw FloeError.validationFailed("query kind must be entities|text|layers|drawing|snap")
        }
        return jsonString(fields)
    }

    func encodeOperations(_ operations: [CadEditOperation]) throws -> String {
        let encoder = JSONEncoder()
        let data = try encoder.encode(operations)
        guard data.count <= 32_768 else {
            throw FloeError.validationFailed("operations exceed the 32 KiB engine request limit")
        }
        guard let json = String(data: data, encoding: .utf8) else {
            throw FloeError.validationFailed("operations could not be encoded")
        }
        return json
    }

    /// Canonicalizes the coordinate shapes real model turns send into the
    /// exact wire form the engine parses: vectors as [x,y,z] with z forced to
    /// 0 on the drawing plane (a 2-number [x,y] is padded), LWPolyline
    /// vertices as 2 numbers, mirror axis as two vectors. Unknown operations
    /// and fields pass through unchanged — the engine remains the semantic
    /// validator; this only removes avoidable deserialization failures and
    /// keeps the advertised examples exactly equal to the engine contract.
    static func normalizedOperations(_ operations: [CadEditOperation]) throws -> [CadEditOperation] {
        try operations.map { try normalizedOperation($0) }
    }

    /// One operation (also used recursively for `batch.operations`).
    private static func normalizedOperation(_ operation: CadEditOperation) throws -> CadEditOperation {
        guard let name = operation.operation else {
            throw FloeError.validationFailed("every operation needs an operation name")
        }
        var fields = operation.fields
        func vector(_ key: String) throws {
            guard let value = fields[key] else { return }
            fields[key] = .array(try Self.vectorNumbers(value, field: "\(name).\(key)").map(CadValue.number))
        }
        switch name {
            case "addLine", "setLineEndpoints":
                try vector("start")
                try vector("end")
            case "addCircle", "addArc":
                try vector("center")
            case "updateDimension":
                try vector("textPosition")
                try vector("linePosition")
            case "addText":
                try vector("position")
            case "move", "copy":
                try vector("delta")
            case "rotate", "scale":
                try vector("center")
            case "mirror":
                guard let value = fields["axis"] else { break }
                guard case .array(let rows) = value, rows.count == 2 else {
                    throw FloeError.validationFailed(
                        "\(name).axis must be exactly two points [[x,y],[x,y]]")
                }
                fields["axis"] = .array(try rows.map { row in
                    .array(try Self.vectorNumbers(row, field: "\(name).axis").map(CadValue.number))
                })
            case "trim", "extend":
                try vector("pick")
            case "offset":
                try vector("side")
            case "addLeader", "addDimension", "updateLeader":
                guard let value = fields["points"] else { break }
                guard case .array(let rows) = value, !rows.isEmpty else {
                    throw FloeError.validationFailed("\(name).points must be a non-empty point list")
                }
                fields["points"] = .array(try rows.map { row in
                    .array(try Self.vectorNumbers(row, field: "\(name).points").map(CadValue.number))
                })
            case "addLwPolyline":
                guard let value = fields["points"] else { break }
                guard case .array(let rows) = value, !rows.isEmpty else {
                    throw FloeError.validationFailed("\(name).points must be a non-empty point list")
                }
                fields["points"] = .array(try rows.map { row in
                    // The engine takes 2D vertices; a supplied z is validated
                    // (must be the drawing plane) and never silently dropped.
                    let numbers = try Self.vectorNumbers(row, field: "\(name).points")
                    return .array([.number(numbers[0]), .number(numbers[1])])
                })
            case "batch":
                guard let value = fields["operations"] else { break }
                guard case .array(let rows) = value, !rows.isEmpty else {
                    throw FloeError.validationFailed("batch.operations must be a non-empty operation list")
                }
                fields["operations"] = .array(try rows.map { row in
                    guard case .object(let nested) = row else {
                        throw FloeError.validationFailed("batch.operations entries must be objects")
                    }
                    return .object(try Self.normalizedOperation(CadEditOperation(fields: nested)).fields)
                })
        default:
            break
        }
        return CadEditOperation(fields: fields)
    }

    /// A vector point or delta: canonical `[x,y]`/`[x,y,z]`, or the validated
    /// aliases `{x,y[,z]}` / `{dx,dy[,dz]}`. An omitted z is the 2D drawing
    /// plane; an explicit non-default z (beyond the engine's plane epsilon) is
    /// REFUSED — no silent 3D→2D projection.
    private static func vectorNumbers(_ value: CadValue, field: String) throws -> [Double] {
        var raw: [Double]
        switch value {
        case .array(let values):
            raw = try values.map { element in
                guard case .number(let number) = element, number.isFinite else {
                    throw FloeError.validationFailed("\(field) must contain finite numbers")
                }
                return number
            }
        case .object(let object):
            let keySets = [["x", "y", "z"], ["dx", "dy", "dz"]]
            guard let picked = keySets.first(where: { keys in
                keys.allSatisfy { object[$0] != nil }
                    || (object[keys[0]] != nil && object[keys[1]] != nil)
            }) else {
                throw FloeError.validationFailed("\(field) must be [x,y] or [x,y,z]")
            }
            raw = try picked.compactMap { key -> Double? in
                guard let entry = object[key] else { return nil }
                guard case .number(let number) = entry, number.isFinite else {
                    throw FloeError.validationFailed("\(field).\(key) must be a finite number")
                }
                return number
            }
        default:
            throw FloeError.validationFailed("\(field) must be [x,y] or [x,y,z]")
        }
        guard raw.count == 2 || raw.count == 3 else {
            throw FloeError.validationFailed("\(field) needs 2 or 3 numbers, got \(raw.count)")
        }
        if raw.count == 2 {
            raw.append(0)
        } else if abs(raw[2]) > 1e-9 {
            throw FloeError.validationFailed(
                "\(field) z must be 0: only 2D XY drawing-plane coordinates are supported, no 3D projection")
        } else {
            raw[2] = 0
        }
        return raw
    }

    private func jsonString(_ fields: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    /// The engine already bounds query pages and validates their shape.
    /// Preserve its complete reply for model budgeting/paging; truncating a
    /// JSON response here would destroy nested parameters and continuation.
    private func completeOutput(_ text: String, _ maximum: Int,
                                artifacts: [ToolArtifactReference] = []) -> ToolExecutionOutput {
        ToolExecutionOutput(
            digesting: text,
            artifacts: artifacts,
            maximumSummaryCharacters: maximum,
            capturedOutput: text
        )
    }

    private func bounded(_ text: String, _ maximum: Int) -> String {
        String(text.prefix(maximum))
    }
}
