// FloeWorkbench — cad.document tool.
//
// One tool, thirteen actions at explicit effect levels:
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
import FloeCore
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
}

public extension CadDocumentHost {
    /// Environments without the native CAD kernel must answer honestly rather
    /// than pretending the action is unsupported per-file.
    func threeDAction(documentID: String, requestJSON: String,
                      access: CadDocumentAccess) async throws -> String {
        throw FloeError.notFound("native_cad_kernel")
    }
    func createNativePackage(relativePath: String, name: String,
                             access: CadDocumentAccess) async throws -> CadNativePackageReceipt {
        throw FloeError.notFound("native_cad_kernel")
    }
    func nativeCapabilities(access: CadDocumentAccess) async throws -> String {
        throw FloeError.notFound("native_cad_kernel")
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
    /// Durable native-task status and cancellation (long rebuild/export/mesh
    /// jobs). `status` lists or reports one task; `cancel` requires task_id.
    case status, cancel
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
    /// `import`: workspace-relative path of the source STEP/STP/IGES/IGS/
    /// STL/OBJ/GLB/glTF file added to the existing native package.
    public var sourcePath: String?
    /// `import`: explicit source format; defaults to the source path
    /// extension. One of step/stp/iges/igs/stl/obj/glb/gltf.
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

    enum CodingKeys: String, CodingKey {
        case action, path, summary, operations, kind, points, handles, tolerance, scope, layer, text, offset, limit, output, op, args, payload, revision
        case proposalID = "proposal_id"
        case grantID = "grant_id"
        case requestID = "request_id"
        case taskID = "task_id"
        case entityType = "entity_type"
        case sourcePath = "source_path"
        case format = "format"
        case unitScale = "unit_scale"
        case name = "name"
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
        format = try container.decodeIfPresent(String.self, forKey: .format)
        unitScale = try container.decodeIfPresent(Double.self, forKey: .unitScale)
        name = try container.decodeIfPresent(String.self, forKey: .name)
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

// MARK: - Tool

public struct CadDocumentTool: AgentTool {
    public typealias Arguments = CadDocumentArguments

    public static let name = "cad.document"
    public static let toolDescription = """
    Create, import into, read, query, measure, propose changes to, apply \
    confirmed proposals to, save and export a CAD document. The document \
    representation decides the engine: a DWG/DXF drawing runs in the local 2D \
    engine, a native `.floecad` package runs in the parametric 3D kernel. \
    Use action "create" (path/name) to make a new EMPTY native `.floecad` \
    package through the built-in factory — never create the folder, manifest \
    or zip by hand and never guess the internal package layout. Use action \
    "import" on an EXISTING `.floecad` to add the geometry of a workspace \
    STEP/STP, IGES/IGS, STL, OBJ, GLB or glTF file: it drafts a proposal on a \
    throwaway copy and returns a preview. STEP gives exact editable solids; \
    IGES solids are exact while shells/faces stay render-only; STL/OBJ/GLB \
    are render meshes with no parametric history. Propose binds an exact \
    document revision and SHA-256 and returns a preview without writing. \
    Apply commits ONE atomic undoable transaction for the exact proposal the \
    approved call names: a `grant_id` selects the human-reviewed CAD UI path, \
    and WITHOUT one the runtime-approved call authority for that exact apply \
    authorizes it automatically (the model cannot mint or replay either; the \
    proposal's revision/SHA is re-verified against the live document at \
    commit). 2D edits are lines, circles, arcs, LWPolylines, text, dimensions \
    and leaders plus move/copy/rotate/scale/mirror/trim/extend/offset and \
    layer management. 3D, blocks, xrefs, splines and proxy graphics are \
    retained read-only in the 2D engine; they are never flattened. Units stay \
    drawing units when undefined. Native documents add parametric features, \
    assembly constraints, drawings, ShapeScript and mesh operations through \
    the typed operation vocabulary (`op` + `args`; feature.extrude, \
    feature.boolean, ...) and the three_d_* aliases; status/cancel report \
    durable native jobs. Workflow: create → propose {"op":"sketch.create"} → \
    apply → propose {"op":"sketch.addEntities"} → apply → propose \
    {"op":"feature.extrude","args":{"sketchID":...,"seedPoint":[x,y],\
    "distance":mm}} → apply → measure {"op":"body","handles":["body:<uuid>"]} → \
    export. Nothing is written by \
    propose/preview/import.
    """
    public static let riskLabels: Set<RiskLabel> = [.readsFiles, .writesFiles]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating
    public static let requiresHostScope = false

    /// Exact operation names the engine accepts; anything else is refused
    /// before it reaches the host.
    public static let supportedOperations: Set<String> = [
        "addLine", "addCircle", "addArc", "addLwPolyline", "addText", "addLeader",
        "addDimension", "move", "copy", "rotate", "scale", "mirror", "setText",
        "setRadius", "setLayer", "setColor", "setLineWeight", "delete", "trim",
        "extend", "offset", "addLayer", "updateLayer", "renameLayer", "deleteLayer",
        "batch",
    ]

    public static let parametersJSON = #"""
    {
      "type": "object",
      "additionalProperties": false,
      "required": ["action"],
      "properties": {
        "action": { "type": "string", "enum": ["capabilities", "create", "read", "query", "locate", "measure", "check", "propose", "import", "preview", "apply", "save", "export", "status", "cancel", "three_d_snapshot", "three_d_measure", "three_d_propose", "three_d_apply", "three_d_assembly", "three_d_drawing"] },
        "path": { "type": "string", "description": "Document path relative to the task workspace (an allowed absolute workspace path is accepted too). Required for every action except capabilities without a path. A .floecad extension routes to the native 3D kernel; .dwg/.dxf route to the 2D engine. For 'create' it is the new package location (its parent directory must exist or be omitted); for 'import' it is the EXISTING .floecad package that receives the geometry. Never write a .floecad directory, manifest.json or zip yourself: use create." },
        "name": { "type": "string", "maxLength": 120, "description": "create: human-readable display name stored in the new native document. Letters and digits of ANY language (Chinese, Japanese, Cyrillic, ...), spaces and -_(). are accepted; it must not contain '/', '\\\\', control/invisible characters or a '..' path segment and must be at most 120 characters, otherwise the call is refused with a bilingual explanation. When omitted the display name defaults to the file stem. The FILE keeps the stem of 'path' and is uniquified, so the display name and the file name stay separate. import: optional name for the imported body(ies)." },
        "source_path": { "type": "string", "description": "import only: workspace-relative path of the source file to add to the existing .floecad package. Supported extensions: .step/.stp (exact solids), .iges/.igs (solids + render-only surfaces), .stl/.obj/.glb/.gltf (meshes). The file is read through the workspace guard (symlink-safe, size-bounded) and is never modified. DWG/DXF go through the 2D engine instead." },
        "format": { "type": "string", "enum": ["step", "stp", "iges", "igs", "stl", "obj", "glb", "gltf"], "description": "import only: explicit source format; defaults to the source_path extension. A JSON .gltf imports only when its buffers/images are embedded data URIs; external .bin/texture references are reported unsupported by the tool. A self-contained .glb always works." },
        "unit_scale": { "type": "number", "exclusiveMinimum": 0, "description": "import only: optional millimetres-per-file-unit scale for unitless meshes (STL/OBJ). Ignored for STEP/IGES and declared-unit glTF." },
        "summary": { "type": "string", "maxLength": 2000, "description": "Human-readable proposal summary shown before confirmation (propose/import)." },
        "operations": {
          "type": "array", "maxItems": 64,
          "description": "Typed 2D engine edits (propose on a DWG/DXF drawing). Each object needs operation. Exact shapes: addLine{start:[x,y,z],end:[x,y,z],layer}; addCircle{center:[x,y,z],radius,layer}; addArc{center:[x,y,z],radius,startAngle,endAngle,layer}; addLwPolyline{points:[[x,y],...],closed?,layer} (2 numbers per point; rectangle = closed 4-point); addText{position:[x,y,z],text,height,layer}; addLeader{points:[[x,y,z],...],layer}; addDimension{kind:linear|aligned|angular|radius|diameter,points:[[x,y,z],...],layer,offset?,rotation?}; move|copy{handle,delta:[dx,dy,dz]}; rotate{handle,center:[x,y,z],angle}; scale{handle,center:[x,y,z],factor}; mirror{handle,axis:[[x,y,z],[x,y,z]]}; setText{handle,text}; setRadius{handle,radius}; setLayer{handle,layer}; setColor{handle,color}; setLineWeight{handle,lineWeight}; delete{handle}; trim|extend{handle,boundary,pick:[x,y,z]}; offset{handle,distance,side:[x,y,z]}; addLayer{name,color?,lineType?,lineWeight?}; updateLayer{name,locked?,visible?,color?,lineType?,lineWeight?}; renameLayer{from,to}; deleteLayer{name}; batch{operations:[...]} nests the same canonical shapes. Canonical vectors are arrays [x,y] (omitted z = the 2D drawing plane) or [x,y,0]; a nonzero z is rejected, never projected. The validated aliases {x,y[,z]} and {dx,dy[,dz]} are accepted and normalized to those arrays; addLwPolyline vertices are [x,y] or [x,y,0].",
          "items": { "type": "object", "required": ["operation"], "properties": { "operation": { "type": "string" } } }
        },
        "proposal_id": { "type": "string", "format": "uuid", "description": "Proposal id from propose (preview/apply). Send it exactly as the propose reply printed it." },
        "grant_id": { "type": "string", "description": "apply: OPTIONAL. When present, selects the human-reviewed CAD UI confirmation path (opaque single-use token the user's acceptance issued; the model cannot mint it). Omit it to let the runtime-approved call authority for this exact apply authorize the change automatically; a made-up or model-supplied value never authorizes anything." },
        "revision": { "type": "integer", "minimum": 0, "description": "apply: optional base revision pin. When present it is bound into the approved call and the host refuses a proposal drafted against a different revision." },
        "request_id": { "type": "string", "description": "Optional caller idempotency key; defaults to the tool call id." },
        "task_id": { "type": "string", "description": "Durable native task id (status reports one task; cancel requires it)." },
        "kind": { "type": "string", "description": "query/measure scope. 2D query: entities|text|layers|drawing|snap; 2D measure: distance|angle|radius|perimeter|area. Native .floecad query: bodies|sketches|constraints|features|edges|faces|variables|assembly|drawings|detail|snapshot. Native measure: body|distance|bounds|dof|interference|mesh|rebuild (op may name the same kind)." },
        "points": { "type": "array", "items": { "type": "array", "items": { "type": "number" } }, "description": "measure points: 2D distance exactly 2, angle exactly 3, area 3+; snap point (first row). Native distance exactly 2 [x,y,z] rows." },
        "handles": { "type": "array", "items": { "type": "string" }, "description": "2D entity handles: distance exactly 2, angle 2 lines, radius 1 circle/arc, perimeter 1+. Native: one handle per action, body:<uuid> / face:<uuid>:<index> / edge:<uuid>:<index>; body, mesh and bounds accept body:<uuid> (a bare body UUID is also accepted); bounds takes one or more body handles." },
        "tolerance": { "type": "number", "description": "snap/check tolerance in drawing units; native interference tolerance in mm." },
        "layer": { "type": "string", "description": "2D query filter." },
        "entity_type": { "type": "string", "description": "2D query filter: Line|Circle|Arc|LwPolyline|Text." },
        "text": { "type": "string", "description": "2D query filter: text content contains." },
        "offset": { "type": "integer", "minimum": 0, "description": "query pagination offset." },
        "limit": { "type": "integer", "minimum": 1, "maximum": 500, "description": "query pagination size." },
        "output": { "type": "string", "description": "export relative path. 2D defaults to <name>.export.dxf. Native defaults to <name>.export.step; accepted native formats: step, stl, obj, 3mf, glb, usdz, pdf, svg, dxf; the path must stay inside the workspace." },
        "op": { "type": "string", "description": "Native typed operation name. Native propose requires it; native measure may use it to name the measurement kind. Exact vocabulary (also reported by capabilities as operation_names): sketch.create, sketch.addEntities, feature.extrude, feature.revolve, feature.pattern, feature.mirror, feature.transform, feature.boolean, feature.fillet, feature.chamfer, feature.shell, feature.sweep, feature.loft, feature.pushPull, feature.moveFace, feature.scaleFace, feature.rotateFace, feature.deleteFace, feature.replaceFace, feature.draftFace, body.setMaterial, item.setHidden." },
        "args": { "type": "string", "description": "JSON object string with the typed operation's arguments. Required for native propose (and the three_d_measure/three_d_propose aliases). Units are mm and degrees. RUNNABLE CONTRACT (exact argument names): sketch.create {name?, origin?[x,y,z], xAxis?[x,y,z], yAxis?[x,y,z]} defaults to the ground plane and returns sketchID; sketch.addEntities {sketchID, entities:[{kind:\"line\",a:[x,y],b:[x,y]} | {kind:\"circle\",center:[x,y],radius} | {kind:\"arc\",center:[x,y],radius,startAngle,endAngle} | {kind:\"spline\",points:[[x,y],...],closed?} | {kind:\"rect\",min:[x,y],max:[x,y]} | {kind:\"polygon\",center:[x,y],radius,sides,rotation?} | {kind:\"ellipse\",center:[x,y],radiusX,radiusY,rotation?}], construction?:[indexes]}; feature.extrude {sketchID, seedPoint:[x,y] (a point INSIDE the closed profile), distance (mm, non-zero; optional only with end), symmetric?, taperDegrees? (|t|<89, 0 = straight), end?:\"throughAll\"|\"upToNext\"|\"blind\", boolean?:\"newBody\"|\"union\"|\"subtract\"|\"intersect\", booleanTargets?:[bodyID]}. Example: {\"sketchID\":\"<uuid from sketch.create>\",\"seedPoint\":[40,20],\"distance\":10}. Ops that act on an existing body take {bodyID} plus their own fields (feature.boolean {kind,targetBodyID,toolBodyIDs}, feature.fillet/chamfer {bodyID,isFillet,amount,edges}, feature.shell {bodyID,thickness,openFaces}, feature.pattern {bodyID,kind,count,...}); measure accepts op to name the kind (body|distance|bounds|dof|interference|mesh|rebuild)." },
        "payload": { "type": "string", "description": "JSON object string for native assembly/drawing/script/mesh actions (three_d_assembly, three_d_drawing) and for native query/export requests. Never contains file paths other than the guarded output/import fields above." }
      }
    }
    """#

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
        if args.action == .capabilities, args.path == nil {
            // Engine capability discovery without a document stays on the 2D
            // engine; a `.floecad` path routes to the native kernel instead
            // (never through the 2D DWG/DXF loader).
            return
        }
        guard let path = args.path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty,
              path.count <= 1024, !path.contains("\0") else {
            throw FloeError.validationFailed("path is required for \(args.action.rawValue)")
        }
        let native = Self.isNativeRepresentation(path)
        switch args.action {
        case .capabilities:
            break
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
                    "import supports STEP/STP, IGES/IGS, STL, OBJ, GLB/glTF files (got \(inferred.isEmpty ? "unknown" : inferred))")
            }
            if let inferredFormat = NativeCADPolicy.normalizedImportFormat(inferred),
               let explicitFormat, explicitFormat != inferredFormat {
                throw FloeError.validationFailed(
                    "import format '\(args.format ?? "")' does not match the source extension '\(inferred)'")
            }
            if let scale = args.unitScale, !(scale.isFinite && scale > 0) {
                throw FloeError.validationFailed("unit_scale must be a positive finite number")
            }
        case .read, .save, .export:
            break
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
        case .threeDSnapshot, .threeDAssembly, .threeDDrawing:
            break
        case .threeDMeasure, .threeDPropose:
            guard let op = args.op, !op.isEmpty else {
                throw FloeError.validationFailed("\(args.action.rawValue) requires op")
            }
            if let raw = args.args,
               (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] == nil {
                throw FloeError.validationFailed("args must be a JSON object string")
            }
        case .propose:
            if native {
                // Native proposals use the typed operation vocabulary; the
                // representation decides, not the caller's wording.
                guard let op = args.op, !op.isEmpty else {
                    throw FloeError.validationFailed("native propose requires op (for example feature.extrude)")
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

    /// Native read scopes served by `query` on a `.floecad` document.
    public static let nativeQueryScopes: Set<String> = [
        "bodies", "sketches", "constraints", "features", "edges", "faces",
        "variables", "assembly", "drawings", "detail", "snapshot",
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
    static func threeDRequestJSON(kind: String, args: CadDocumentArguments) throws -> String {
        var object: [String: Any] = ["kind": kind]
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
        if let format = args.format { object["format"] = format }
        if let unitScale = args.unitScale { object["unit_scale"] = unitScale }
        if let name = args.name { object["name"] = name }
        if let revision = args.revision { object["revision"] = revision }
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
        // Unified representation routing: a `.floecad` package is answered by
        // the native kernel and never by the 2D DWG/DXF loader.
        let native = Self.isNativeRepresentation(args.path)

        switch args.action {
        case .capabilities:
            if native {
                let reply = try await host.threeDAction(
                    documentID: args.path!, requestJSON: #"{"kind":"capabilities"}"#, access: access)
                return ToolExecutionOutput(digesting: bounded("cad.document capabilities: \(reply)", 24_000))
            }
            if args.path == nil {
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
                let nativeCaps: Any
                do {
                    let json = try await host.nativeCapabilities(access: access)
                    nativeCaps = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) ?? ["raw": json]
                } catch let error as FloeError {
                    if case .notFound(let what) = error, what == "native_cad_kernel" {
                        nativeCaps = ["available": false]
                    } else {
                        throw error
                    }
                }
                let merged: [String: Any] = [
                    "two_dimensional": twoD,
                    "native_three_dimensional": nativeCaps,
                ]
                let data = try JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys, .withoutEscapingSlashes])
                let text = String(data: data, encoding: .utf8) ?? "{}"
                return ToolExecutionOutput(digesting: bounded("cad.document capabilities: \(text)", 32_000))
            }
            let caps = try await host.capabilities(access: access)
            return ToolExecutionOutput(digesting: bounded("cad.document capabilities: \(caps)", 24_000))

        case .create:
            let path = args.path!
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
            return ToolExecutionOutput(digesting: bounded("cad.document created: \(json)", 16_000))

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
                    "import supports STEP/STP, IGES/IGS, STL, OBJ, GLB/glTF files")
            }
            var payload: [String: Any] = [
                "path": source,
                "format": format,
            ]
            if let name = args.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                payload["name"] = name
            }
            if let scale = args.unitScale { payload["unitScale"] = scale }
            var envelope: [String: Any] = ["kind": "import", "payload": payload]
            if let summary = args.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
               !summary.isEmpty {
                envelope["summary"] = summary
            }
            let request = try jsonString(envelope)
            let reply = try await host.threeDAction(documentID: args.path!, requestJSON: request,
                                                    access: access)
            return ToolExecutionOutput(digesting: bounded("cad.document import proposal: \(reply)", 24_000))

        case .read:
            if native {
                let reply = try await host.threeDAction(
                    documentID: args.path!, requestJSON: #"{"kind":"snapshot"}"#, access: access)
                return ToolExecutionOutput(digesting: bounded("cad.document read: \(reply)", 48_000))
            }
            let snapshot = try await host.snapshot(documentID: args.path!, access: access)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let json = String(data: try encoder.encode(snapshot), encoding: .utf8) ?? "{}"
            return ToolExecutionOutput(digesting: bounded("cad.document read: \(json)", 24_000))

        case .query:
            if native {
                let request = try nativeQueryRequest(args)
                let reply = try await host.threeDAction(documentID: args.path!, requestJSON: request,
                                                        access: access)
                return ToolExecutionOutput(digesting: bounded("cad.document query: \(reply)", 48_000))
            }
            let request = try queryRequest(args)
            let reply = try await host.query(documentID: args.path!, requestJSON: request, access: access)
            return ToolExecutionOutput(digesting: bounded("cad.document query: \(reply)", 48_000))

        case .locate:
            if native {
                let request = try jsonString(["kind": "locate",
                                              "payload": ["handle": args.handles![0]]])
                let reply = try await host.threeDAction(documentID: args.path!, requestJSON: request,
                                                        access: access)
                return ToolExecutionOutput(digesting: bounded("cad.document locate: \(reply)", 8_000))
            }
            let request = jsonString(["operation": "locate", "handle": args.handles![0]])
            let reply = try await host.query(documentID: args.path!, requestJSON: request, access: access)
            return ToolExecutionOutput(digesting: bounded("cad.document locate: \(reply)", 8_000))

        case .measure:
            if native {
                let request = try nativeMeasureRequest(args)
                let reply = try await host.threeDAction(documentID: args.path!, requestJSON: request,
                                                        access: access)
                return ToolExecutionOutput(digesting: bounded("cad.document measure: \(reply)", 8_000))
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
            return ToolExecutionOutput(digesting: bounded("cad.document measure: \(reply)", 8_000))

        case .check:
            if native {
                let payload: [String: Any] = ["tolerance": args.tolerance ?? 0.001]
                let request = try jsonString(["kind": "check", "payload": payload])
                let reply = try await host.threeDAction(documentID: args.path!, requestJSON: request,
                                                        access: access)
                return ToolExecutionOutput(digesting: bounded("cad.document check: \(reply)", 48_000))
            }
            let request = jsonString(["operation": "check", "tolerance": args.tolerance ?? 0.001])
            let reply = try await host.query(documentID: args.path!, requestJSON: request, access: access)
            return ToolExecutionOutput(digesting: bounded("cad.document check: \(reply)", 48_000))

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
            return ToolExecutionOutput(digesting: bounded("cad.document \(args.action.rawValue): \(reply)", 24_000))

        case .propose:
            if native {
                let request = try Self.threeDRequestJSON(kind: "propose", args: args)
                let reply = try await host.threeDAction(documentID: args.path!, requestJSON: request,
                                                        access: access)
                // The proposal changes nothing yet; BOTH authorization paths are
                // valid for the apply that follows (UI grant or the
                // runtime-approved call), so the model is told the truth.
                let note = "Nothing was written. Call apply with this proposal id — a grant_id the user issued "
                    + "in the CAD UI, or (without one) this exact approved call's runtime authority, authorizes it. "
                    + "A pending proposal alone grants nothing and stays confirmable in the CAD UI."
                return ToolExecutionOutput(digesting: bounded("cad.document propose: \(reply)\n\(note)", 16_000))
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
            return ToolExecutionOutput(digesting: bounded(summary, 8_000))

        case .preview:
            if native {
                guard let id = args.proposalID else { throw FloeError.notFound("CAD proposal") }
                let request = try jsonString(["kind": "preview", "proposal_id": id.uuidString])
                let reply = try await host.threeDAction(documentID: args.path!, requestJSON: request,
                                                        access: access)
                return ToolExecutionOutput(digesting: bounded("cad.document preview: \(reply)", 32_000))
            }
            guard let id = args.proposalID,
                  let proposal = try await host.loadProposal(id: id, access: access) else {
                throw FloeError.notFound("CAD proposal")
            }
            try await host.verifyProposalBinding(proposal, documentID: args.path!, access: access)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let json = String(data: try encoder.encode(proposal.preview), encoding: .utf8) ?? "{}"
            return ToolExecutionOutput(digesting: bounded("cad.document preview: \(json)", 32_000))

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
                return ToolExecutionOutput(digesting: bounded("cad.document apply: \(json)", 16_000))
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
            return ToolExecutionOutput(digesting: bounded("cad.document apply: \(json)", 16_000))

        case .save:
            if native {
                let reply = try await host.threeDAction(documentID: args.path!,
                                                        requestJSON: #"{"kind":"save"}"#, access: access)
                return ToolExecutionOutput(digesting: bounded("cad.document save: \(reply)", 16_000))
            }
            let snapshot = try await host.snapshot(documentID: args.path!, access: access)
            let receipt = try await host.save(documentID: args.path!, expectedSHA256: snapshot.sha256,
                                              requestID: requestID, access: access)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let json = String(data: try encoder.encode(receipt), encoding: .utf8) ?? "{}"
            return ToolExecutionOutput(digesting: bounded("cad.document save: \(json)", 16_000))

        case .export:
            if native {
                let output = args.output ?? Self.defaultNativeExportPath(for: args.path!)
                let payload: [String: Any] = ["output": output,
                                              "format": (output as NSString).pathExtension.lowercased()]
                let request = try jsonString(["kind": "export", "payload": payload])
                let reply = try await host.threeDAction(documentID: args.path!, requestJSON: request,
                                                        access: access)
                return ToolExecutionOutput(digesting: bounded("cad.document export: \(reply)", 16_000))
            }
            let output = args.output ?? Self.defaultExportPath(for: args.path!)
            let receipt = try await host.export(documentID: args.path!, relativeOutput: output, access: access)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let json = String(data: try encoder.encode(receipt), encoding: .utf8) ?? "{}"
            return ToolExecutionOutput(digesting: bounded("cad.document export: \(json)", 16_000))

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
            let request = try Self.threeDRequestJSON(kind: kind, args: args)
            let reply = try await host.threeDAction(documentID: args.path!,
                                                    requestJSON: request, access: access)
            return ToolExecutionOutput(digesting: bounded("cad.document \(kind): \(reply)", 48_000))
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
                                                    access: access)
            return ToolExecutionOutput(digesting: bounded("cad.document apply: \(reply)", 16_000))
        }
        let authorization = try await Self.consumeAutomaticAuthorization(args: args, context: context)
        let reply = try await host.applyAutomatic(proposalID: id, authorization: authorization,
                                                  requestID: requestID, access: access)
        return ToolExecutionOutput(digesting: bounded("cad.document apply: \(reply)", 16_000))
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

    static func defaultExportPath(for path: String) -> String {
        let name = (path as NSString).lastPathComponent
        let base = (name as NSString).deletingPathExtension
        let directory = (path as NSString).deletingLastPathComponent
        let file = "\(base.isEmpty ? "drawing" : base).export.dxf"
        return directory.isEmpty ? file : "\(directory)/\(file)"
    }

    /// Native export defaults to an exact STEP copy beside the package; the
    /// host validates the format against the output extension and refuses a
    /// mesh-only downgrade unless the caller names a mesh format.
    static func defaultNativeExportPath(for path: String) -> String {
        let name = (path as NSString).lastPathComponent
        let base = (name as NSString).deletingPathExtension
        let directory = (path as NSString).deletingLastPathComponent
        let file = "\(base.isEmpty ? "part" : base).export.step"
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
            case "addLine":
                try vector("start")
                try vector("end")
            case "addCircle", "addArc":
                try vector("center")
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
            case "addLeader", "addDimension":
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

    private func bounded(_ text: String, _ maximum: Int) -> String {
        String(text.prefix(maximum))
    }
}
