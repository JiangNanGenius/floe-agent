// FloeWorkbench — cad.document tool.
//
// One tool, eleven actions at explicit effect levels:
//   capabilities — engine-declared capacities and limits (read-only)
//   read         — document summary: format, revision, SHA-256, units, layers
//   query        — paginated entities/text/layers scoped to the document
//   locate       — representative point and bounds of one entity handle
//   measure      — deterministic geometric measurement (points or handles)
//   check        — zero-length/duplicate/layer/open-contour consistency
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
    /// Commits the current verified engine output (CAS on SHA).
    func save(documentID: String, expectedSHA256: String, requestID: String,
              access: CadDocumentAccess) async throws -> CadDocumentReceipt
    /// Writes a separate verified presentation copy; never overwrites the
    /// source document.
    func export(documentID: String, relativeOutput: String,
                access: CadDocumentAccess) async throws -> CadExportReceipt
    /// Native FloeCAD request. `requestJSON` carries a `kind` plus the typed
    /// operation/payload. Read-only kinds (`snapshot`, `measure`, `assembly`,
    /// `drawing` reads) return JSON; `propose` validates on a throwaway copy
    /// and never writes; `apply` requires a UI-issued single-use `grant_id`
    /// bound to the proposal and base revision/SHA.
    func threeDAction(documentID: String, requestJSON: String,
                      access: CadDocumentAccess) async throws -> String
}

public extension CadDocumentHost {
    /// Environments without the native CAD kernel must answer honestly rather
    /// than pretending the action is unsupported per-file.
    func threeDAction(documentID: String, requestJSON: String,
                      access: CadDocumentAccess) async throws -> String {
        throw FloeError.notFound("native_cad_kernel")
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
    case capabilities, read, query, locate, measure, check, propose, preview, apply, save, export
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

    enum CodingKeys: String, CodingKey {
        case action, path, summary, operations, kind, points, handles, tolerance, scope, layer, text, offset, limit, output, op, args, payload
        case proposalID = "proposal_id"
        case grantID = "grant_id"
        case requestID = "request_id"
        case taskID = "task_id"
        case entityType = "entity_type"
    }
}

// MARK: - Tool

public struct CadDocumentTool: AgentTool {
    public typealias Arguments = CadDocumentArguments

    public static let name = "cad.document"
    public static let toolDescription = """
    Read, query, measure, propose changes to, apply confirmed proposals to, \
    save and export a CAD document. The document representation decides the \
    engine: a DWG/DXF drawing runs in the local 2D engine, a native `.floecad` \
    package runs in the parametric 3D kernel. Propose binds an exact document \
    revision and SHA-256 and returns a preview without writing; apply needs a \
    single-use grant the user issued in the CAD UI. 2D edits are lines, \
    circles, arcs, LWPolylines, text, dimensions and leaders plus move/copy/\
    rotate/scale/mirror/trim/extend/offset and layer management. 3D, blocks, \
    xrefs, splines and proxy graphics are retained read-only in the 2D engine; \
    they are never flattened. Units stay drawing units when undefined. Native \
    documents add parametric features, assembly constraints, drawings, \
    ShapeScript and mesh operations through the typed operation vocabulary \
    (feature.extrude, feature.boolean, ...) and the three_d_* aliases; \
    status/cancel report durable native jobs. Nothing is written before apply.
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
        "action": { "type": "string", "enum": ["capabilities", "read", "query", "locate", "measure", "check", "propose", "preview", "apply", "save", "export", "status", "cancel", "three_d_snapshot", "three_d_measure", "three_d_propose", "three_d_apply", "three_d_assembly", "three_d_drawing"] },
        "path": { "type": "string", "description": "Document path (relative to the task workspace or an allowed absolute path). Required for every action except capabilities without a path. A .floecad extension routes to the native 3D kernel; .dwg/.dxf route to the 2D engine." },
        "summary": { "type": "string", "maxLength": 2000, "description": "Human-readable proposal summary shown before confirmation (propose)." },
        "operations": {
          "type": "array", "maxItems": 64,
          "description": "Typed 2D engine edits (propose on a DWG/DXF drawing). Each object needs operation. Exact shapes: addLine{start:[x,y,z],end:[x,y,z],layer}; addCircle{center:[x,y,z],radius,layer}; addArc{center:[x,y,z],radius,startAngle,endAngle,layer}; addLwPolyline{points:[[x,y],...],closed?,layer} (2 numbers per point; rectangle = closed 4-point); addText{position:[x,y,z],text,height,layer}; addLeader{points:[[x,y,z],...],layer}; addDimension{kind:linear|aligned|angular|radius|diameter,points:[[x,y,z],...],layer,offset?,rotation?}; move|copy{handle,delta:[dx,dy,dz]}; rotate{handle,center:[x,y,z],angle}; scale{handle,center:[x,y,z],factor}; mirror{handle,axis:[[x,y,z],[x,y,z]]}; setText{handle,text}; setRadius{handle,radius}; setLayer{handle,layer}; setColor{handle,color}; setLineWeight{handle,lineWeight}; delete{handle}; trim|extend{handle,boundary,pick:[x,y,z]}; offset{handle,distance,side:[x,y,z]}; addLayer{name,color?,lineType?,lineWeight?}; updateLayer{name,locked?,visible?,color?,lineType?,lineWeight?}; renameLayer{from,to}; deleteLayer{name}; batch{operations:[...]} nests the same canonical shapes. Canonical vectors are arrays [x,y] (omitted z = the 2D drawing plane) or [x,y,0]; a nonzero z is rejected, never projected. The validated aliases {x,y[,z]} and {dx,dy[,dz]} are accepted and normalized to those arrays; addLwPolyline vertices are [x,y] or [x,y,0].",
          "items": { "type": "object", "required": ["operation"], "properties": { "operation": { "type": "string" } } }
        },
        "proposal_id": { "type": "string", "format": "uuid", "description": "Proposal id from propose (preview/apply)." },
        "grant_id": { "type": "string", "description": "Opaque single-use confirmation token issued by the CAD UI after the user accepts. The model cannot mint this." },
        "request_id": { "type": "string", "description": "Optional caller idempotency key; defaults to the tool call id." },
        "task_id": { "type": "string", "description": "Durable native task id (status reports one task; cancel requires it)." },
        "kind": { "type": "string", "description": "query/measure scope. 2D query: entities|text|layers|drawing|snap; 2D measure: distance|angle|radius|perimeter|area. Native .floecad query: bodies|sketches|constraints|features|edges|faces|variables|assembly|drawings|detail|snapshot. Native measure: body|distance|bounds|dof|interference|mesh|rebuild (op may name the same kind)." },
        "points": { "type": "array", "items": { "type": "array", "items": { "type": "number" } }, "description": "measure points: 2D distance exactly 2, angle exactly 3, area 3+; snap point (first row). Native distance exactly 2 [x,y,z] rows." },
        "handles": { "type": "array", "items": { "type": "string" }, "description": "2D entity handles: distance exactly 2, angle 2 lines, radius 1 circle/arc, perimeter 1+. Native: one handle per action, body:<uuid> / face:<uuid>:<index> / edge:<uuid>:<index>; bounds takes body handles." },
        "tolerance": { "type": "number", "description": "snap/check tolerance in drawing units; native interference tolerance in mm." },
        "layer": { "type": "string", "description": "2D query filter." },
        "entity_type": { "type": "string", "description": "2D query filter: Line|Circle|Arc|LwPolyline|Text." },
        "text": { "type": "string", "description": "2D query filter: text content contains." },
        "offset": { "type": "integer", "minimum": 0, "description": "query pagination offset." },
        "limit": { "type": "integer", "minimum": 1, "maximum": 500, "description": "query pagination size." },
        "output": { "type": "string", "description": "export relative path. 2D defaults to <name>.export.dxf. Native defaults to <name>.export.step; accepted native formats: step, stl, obj, 3mf, glb, usdz, pdf, svg, dxf; the path must stay inside the workspace." },
        "op": { "type": "string", "description": "Native typed operation name (feature.extrude, feature.boolean, feature.fillet, feature.shell, feature.pattern, ...). Native propose requires it; native measure may use it to name the measurement kind." },
        "args": { "type": "string", "description": "JSON object string with the typed operation's arguments. Required for native propose (and the three_d_measure/three_d_propose aliases)." },
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
            guard let grant = args.grantID, !grant.isEmpty else {
                throw FloeError.validationFailed("\(args.action.rawValue) requires a user-issued grant_id")
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

    public func execute(_ args: CadDocumentArguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let access = Self.access(for: context)
        try Self.authorizeDocumentPath(args.path, context: context)
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
            let caps = try await host.capabilities(access: access)
            return ToolExecutionOutput(digesting: bounded("cad.document capabilities: \(caps)", 24_000))

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
                return ToolExecutionOutput(digesting: bounded("cad.document propose: \(reply)", 16_000),
                                           requiresUserAction: true)
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
            User confirmation is required before apply; grant id must come from the CAD UI. \(preview.note)
            """
            return ToolExecutionOutput(digesting: bounded(summary, 8_000), requiresUserAction: true)

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
                guard let id = args.proposalID, let grant = args.grantID, !grant.isEmpty else {
                    throw FloeError.unauthorized
                }
                let request = try jsonString(["kind": "apply",
                                              "proposal_id": id.uuidString,
                                              "grant_id": grant,
                                              "request_id": requestID])
                let reply = try await host.threeDAction(documentID: args.path!, requestJSON: request,
                                                        access: access)
                return ToolExecutionOutput(digesting: bounded("cad.document apply: \(reply)", 16_000))
            }
            guard let id = args.proposalID else {
                throw FloeError.notFound("CAD proposal")
            }
            guard let grantID = args.grantID, !grantID.isEmpty else {
                throw FloeError.unauthorized
            }
            // The proposal may still be loadable (applied tombstone retained
            // for replay) or fully applied; both paths verify ownership first.
            if let proposal = try await host.loadProposal(id: id, access: access) {
                try await host.verifyProposalBinding(proposal, documentID: args.path!, access: access)
                let receipt = try await host.apply(proposal: proposal, grantID: grantID,
                                                   requestID: requestID, access: access)
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
            // The model never mints a grant; the field is passed through only
            // so the host can validate one the UI issued. Missing/forged values
            // are refused by the host.
            if kind == "apply" {
                guard args.proposalID != nil, let grant = args.grantID, !grant.isEmpty else {
                    throw FloeError.validationFailed(
                        "cad.document three_d_apply requires proposal_id and a UI-issued grant_id.")
                }
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
    private func nativeMeasureRequest(_ args: CadDocumentArguments) throws -> String {
        guard let kind = args.op ?? args.kind, Self.nativeMeasureKinds.contains(kind) else {
            throw FloeError.validationFailed(
                "native measure requires kind (\(Self.nativeMeasureKinds.sorted().joined(separator: "|")))")
        }
        var payload: [String: Any] = ["kind": kind]
        switch kind {
        case "body", "mesh":
            payload["bodyID"] = args.handles!.first!
        case "distance":
            payload["points"] = args.points!.map { Array($0.prefix(3)) }
        case "bounds":
            payload["bodyIDs"] = args.handles ?? []
        case "interference":
            payload["toleranceMM"] = args.tolerance ?? 1e-6
        default:
            break
        }
        return jsonString(["kind": "measure", "payload": payload])
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
