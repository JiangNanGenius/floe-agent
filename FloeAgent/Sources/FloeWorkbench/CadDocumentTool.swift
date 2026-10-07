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

    public init(handle: String, type: String, layer: String, bounds: CadBounds?) {
        self.handle = handle
        self.type = type
        self.layer = layer
        self.bounds = bounds
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

public struct CadDocumentReceipt: Codable, Sendable, Equatable {
    public var documentID: String
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
    func loadProposal(id: UUID) async throws -> CadProposal?
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

public enum CadDocumentAction: String, Decodable, Sendable {
    case capabilities, read, query, locate, measure, check, propose, preview, apply, save, export
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

    enum CodingKeys: String, CodingKey {
        case action, path, summary, operations, kind, points, handles, tolerance, scope, layer, text, offset, limit, output
        case proposalID = "proposal_id"
        case grantID = "grant_id"
        case requestID = "request_id"
        case entityType = "entity_type"
    }
}

// MARK: - Tool

public struct CadDocumentTool: AgentTool {
    public typealias Arguments = CadDocumentArguments

    public static let name = "cad.document"
    public static let toolDescription = """
    Read, query, measure, propose changes to, apply confirmed proposals to, \
    save and export a 2D DWG/DXF drawing through the local CAD engine. Propose \
    binds an exact document revision and SHA-256 and returns a new/changed/\
    deleted preview without writing; apply needs a single-use grant the user \
    issued in the CAD UI. Supported edits are lines, circles, arcs, LWPolylines \
    (including rectangles), single-line text, dimensions and leaders plus \
    move/copy/rotate/scale/mirror/trim/extend/offset and layer management. \
    3D, blocks, xrefs, splines and proxy graphics are retained read-only; they \
    are never flattened. Units stay drawing units when the file leaves them \
    undefined.
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
        "action": { "type": "string", "enum": ["capabilities", "read", "query", "locate", "measure", "check", "propose", "preview", "apply", "save", "export"] },
        "path": { "type": "string", "description": "Drawing path (relative to the task workspace or an allowed absolute path). Required for every action except capabilities." },
        "summary": { "type": "string", "maxLength": 2000, "description": "Human-readable proposal summary shown before confirmation (propose)." },
        "operations": {
          "type": "array", "maxItems": 64,
          "description": "Typed engine edits (propose). Each object needs operation. Supported: addLine{start,end,layer}; addCircle{center,radius,layer}; addArc{center,radius,startAngle,endAngle,layer}; addLwPolyline{points:[[x,y]],closed,layer} (rectangle = closed 4-point); addText{position,text,height,layer}; addLeader{points,layer}; addDimension{kind:linear|aligned|angular|radius|diameter,points,layer,offset?,rotation?}; move|copy{handle,delta}; rotate{handle,center,angle}; scale{handle,center,factor}; mirror{handle,axis:[p1,p2]}; setText{handle,text}; setRadius{handle,radius}; setLayer{handle,layer}; setColor{handle,color}; setLineWeight{handle,lineWeight}; delete{handle}; trim|extend{handle,boundary,pick}; offset{handle,distance,side}; addLayer{name,color?,lineType?,lineWeight?}; updateLayer{name,locked?,visible?,color?,lineType?,lineWeight?}; renameLayer{from,to}; deleteLayer{name}; batch{operations}. Coordinates are Z=0 drawing units.",
          "items": { "type": "object", "required": ["operation"], "properties": { "operation": { "type": "string" } } }
        },
        "proposal_id": { "type": "string", "format": "uuid", "description": "Proposal id from propose (preview/apply)." },
        "grant_id": { "type": "string", "description": "Opaque single-use confirmation token issued by the CAD UI after the user accepts. The model cannot mint this." },
        "request_id": { "type": "string", "description": "Optional caller idempotency key; defaults to the tool call id." },
        "kind": { "type": "string", "description": "query scope: entities|text|layers|drawing|snap. measure kind: distance|angle|radius|perimeter|area. check tolerance is separate." },
        "points": { "type": "array", "items": { "type": "array", "items": { "type": "number" } }, "description": "measure points; snap point (first row)." },
        "handles": { "type": "array", "items": { "type": "string" }, "description": "measure entity handles." },
        "tolerance": { "type": "number", "description": "snap/check tolerance in drawing units." },
        "layer": { "type": "string", "description": "query filter." },
        "entity_type": { "type": "string", "description": "query filter: Line|Circle|Arc|LwPolyline|Text." },
        "text": { "type": "string", "description": "query filter: text content contains." },
        "offset": { "type": "integer", "minimum": 0, "description": "query pagination offset." },
        "limit": { "type": "integer", "minimum": 1, "maximum": 500, "description": "query pagination size." },
        "output": { "type": "string", "description": "export relative path; defaults to <name>.export.dxf." }
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
        if args.action == .capabilities { return }
        guard let path = args.path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty,
              path.count <= 1024, !path.contains("\0") else {
            throw FloeError.validationFailed("path is required for \(args.action.rawValue)")
        }
        switch args.action {
        case .capabilities:
            break
        case .read, .save, .export, .preview, .apply:
            break
        case .query:
            throw FloeError.validationFailed("query requires kind (entities|text|layers|drawing|snap)")
        case .locate:
            guard let handles = args.handles, handles.count == 1 else {
                throw FloeError.validationFailed("locate requires exactly one handle")
            }
        case .measure:
            guard let kind = args.kind, ["distance", "angle", "radius", "perimeter", "area"].contains(kind) else {
                throw FloeError.validationFailed("measure requires kind distance|angle|radius|perimeter|area")
            }
        case .check:
            if let tolerance = args.tolerance, !(tolerance.isFinite && tolerance > 0) {
                throw FloeError.validationFailed("tolerance must be positive")
            }
        case .propose:
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

    public func execute(_ args: CadDocumentArguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let access = CadDocumentAccess(
            environmentID: context.environmentID,
            workspacePath: context.workspaceRootURL?.path,
            ownerKind: context.conversationID == nil ? "workspace" : "chat",
            ownerID: context.conversationID
        )
        try await host.authorizeAccess(access: access)
        let requestID = args.requestID ?? context.toolCallID ?? context.runID.uuidString

        switch args.action {
        case .capabilities:
            let caps = try await host.capabilities(access: access)
            return ToolExecutionOutput(digesting: bounded("cad.document capabilities: \(caps)", 24_000))

        case .read:
            let snapshot = try await host.snapshot(documentID: args.path!, access: access)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let json = String(data: try encoder.encode(snapshot), encoding: .utf8) ?? "{}"
            return ToolExecutionOutput(digesting: bounded("cad.document read: \(json)", 24_000))

        case .query:
            let request = try queryRequest(args)
            let reply = try await host.query(documentID: args.path!, requestJSON: request, access: access)
            return ToolExecutionOutput(digesting: bounded("cad.document query: \(reply)", 48_000))

        case .locate:
            let request = jsonString(["operation": "locate", "handle": args.handles![0]])
            let reply = try await host.query(documentID: args.path!, requestJSON: request, access: access)
            return ToolExecutionOutput(digesting: bounded("cad.document locate: \(reply)", 8_000))

        case .measure:
            var fields: [String: Any] = ["operation": "measure", "kind": args.kind!]
            if let points = args.points, !points.isEmpty {
                guard points.count >= 2, points.allSatisfy({ $0.count >= 2 && $0.allSatisfy { $0.isFinite } }) else {
                    throw FloeError.validationFailed("measure points must have at least two rows of finite x/y")
                }
                fields["points"] = points.map { [Double($0[0]), Double($0[1]), 0] }
            }
            if let handles = args.handles { fields["handles"] = handles }
            let reply = try await host.query(documentID: args.path!, requestJSON: jsonString(fields), access: access)
            return ToolExecutionOutput(digesting: bounded("cad.document measure: \(reply)", 8_000))

        case .check:
            let request = jsonString(["operation": "check", "tolerance": args.tolerance ?? 0.001])
            let reply = try await host.query(documentID: args.path!, requestJSON: request, access: access)
            return ToolExecutionOutput(digesting: bounded("cad.document check: \(reply)", 48_000))

        case .propose:
            let snapshot = try await host.snapshot(documentID: args.path!, access: access)
            guard snapshot.editable else {
                throw FloeError.validationFailed("this drawing has unresolved read diagnostics; editing is disabled")
            }
            let operationsJSON = try encodeOperations(args.operations!)
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
            guard let id = args.proposalID, let proposal = try await host.loadProposal(id: id) else {
                throw FloeError.notFound("CAD proposal")
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let json = String(data: try encoder.encode(proposal.preview), encoding: .utf8) ?? "{}"
            return ToolExecutionOutput(digesting: bounded("cad.document preview: \(json)", 32_000))

        case .apply:
            guard let id = args.proposalID, let proposal = try await host.loadProposal(id: id) else {
                throw FloeError.notFound("CAD proposal")
            }
            guard let grantID = args.grantID, !grantID.isEmpty else {
                throw FloeError.unauthorized
            }
            let receipt = try await host.apply(proposal: proposal, grantID: grantID, requestID: requestID, access: access)
            try await host.removeProposal(id: proposal.id)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let json = String(data: try encoder.encode(receipt), encoding: .utf8) ?? "{}"
            return ToolExecutionOutput(digesting: bounded("cad.document apply: \(json)", 16_000))

        case .save:
            let snapshot = try await host.snapshot(documentID: args.path!, access: access)
            let receipt = try await host.save(documentID: args.path!, expectedSHA256: snapshot.sha256,
                                              requestID: requestID, access: access)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let json = String(data: try encoder.encode(receipt), encoding: .utf8) ?? "{}"
            return ToolExecutionOutput(digesting: bounded("cad.document save: \(json)", 16_000))

        case .export:
            let output = args.output ?? Self.defaultExportPath(for: args.path!)
            let receipt = try await host.export(documentID: args.path!, relativeOutput: output, access: access)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let json = String(data: try encoder.encode(receipt), encoding: .utf8) ?? "{}"
            return ToolExecutionOutput(digesting: bounded("cad.document export: \(json)", 16_000))
        }
    }

    static func defaultExportPath(for path: String) -> String {
        let name = (path as NSString).lastPathComponent
        let base = (name as NSString).deletingPathExtension
        let directory = (path as NSString).deletingLastPathComponent
        let file = "\(base.isEmpty ? "drawing" : base).export.dxf"
        return directory.isEmpty ? file : "\(directory)/\(file)"
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

    private func jsonString(_ fields: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    private func bounded(_ text: String, _ maximum: Int) -> String {
        String(text.prefix(maximum))
    }
}
