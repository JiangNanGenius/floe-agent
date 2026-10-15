// FloeDocuments — document.office.edit: the shared propose → confirm → apply
// contract for engine-level Word/Excel/Presentation edits.
//
// The tool never dispatches UNO itself; the app host (the live editor session)
// does, through the same `OfficeEngineCommand` catalog the UI uses. Ownership,
// exact-revision binding, single-use UI grants, idempotent replay and the
// post-save OOXML verification all live behind this boundary:
//
//   capabilities — truthful per-format matrix (verified / engine / unavailable)
//   read         — live session status: format, sha256, editable, unsaved edits
//   query        — supported command ids + argument shapes for one format
//   propose      — validates a command batch against an exact sha256, computes
//                  the OOXML expectation set and stores a pending proposal;
//                  changes nothing
//   preview      — returns the stored proposal (command list + expectations)
//   apply        — needs a single-use grant the UI minted for this proposal and
//                  sha; dispatches through the live engine, flushes the working
//                  copy, then verifies the saved package and commits CAS
//   export       — writes a separate verified copy; never overwrites the source
//   errors       — read-only formula-error cell locations from the saved package
//   replaceImage — replaces an existing picture's bytes in place (package-level;
//                  the pinned bundle has no .uno:ChangePicture)
//
// A model cannot mint `grant_id` or `expectedSHA256`; both are checked by the
// host. A request id is bound to its payload, so a retry replays the original
// receipt and a reused id with different content is a conflict.

import Foundation
import Crypto
import FloeCore
import FloeTools
import FloeWorkspace

public struct OfficeCommandAccess: Sendable, Hashable, Codable {
    public var environmentID: String?
    public var workspacePath: String?
    public var ownerKind: String?
    public var ownerID: UUID?
    /// The task conversation presenting the call, when the caller is a chat
    /// run. The host refuses a call from a different task than the session's
    /// recorded owner.
    public var conversationID: UUID?

    public init(environmentID: String? = nil, workspacePath: String? = nil,
                ownerKind: String? = nil, ownerID: UUID? = nil,
                conversationID: UUID? = nil) {
        self.environmentID = environmentID
        self.workspacePath = workspacePath
        self.ownerKind = ownerKind
        self.ownerID = ownerID
        self.conversationID = conversationID
    }
}

public struct OfficeLiveStatus: Codable, Sendable, Equatable {
    public var documentID: String
    public var format: String
    /// SHA-256 of the last committed bytes on disk (the CAS baseline).
    public var revisionSHA256: String
    /// True when a live engine session is open for this document.
    public var liveSession: Bool
    /// True when the open engine session is editable (not a preview).
    public var editable: Bool
    /// Engine-reported reason editing is unavailable, when known.
    public var readOnlyReason: String?
    /// True when the live session holds edits not yet written to disk.
    public var hasUnsavedChanges: Bool?

    public init(documentID: String, format: String, revisionSHA256: String,
                liveSession: Bool, editable: Bool, readOnlyReason: String? = nil,
                hasUnsavedChanges: Bool? = nil) {
        self.documentID = documentID
        self.format = format
        self.revisionSHA256 = revisionSHA256
        self.liveSession = liveSession
        self.editable = editable
        self.readOnlyReason = readOnlyReason
        self.hasUnsavedChanges = hasUnsavedChanges
    }
}

public struct OfficeCommandProposal: Codable, Sendable, Equatable {
    public var id: UUID
    public var documentID: String
    public var format: String
    public var baseSHA256: String
    public var summary: String
    /// Encoded `[OfficeCommandCodec.Entry]` array; the only payload the host
    /// dispatches.
    public var commandsJSON: String
    /// Human-readable verification the saved package must satisfy.
    public var expectations: [String]
    /// Opaque live selection identity captured when the proposal was created,
    /// required for commands that act on the current cursor/selection. Apply
    /// re-reads it and refuses a changed selection instead of redirecting the
    /// edit to a different paragraph/cell/object.
    public var selectionFingerprint: String?
    /// Human description of what the commands act on (selection/cell/slide).
    public var targetSummary: String
    public var createdAt: Date

    public init(id: UUID = UUID(), documentID: String, format: String, baseSHA256: String,
                summary: String, commandsJSON: String, expectations: [String],
                selectionFingerprint: String? = nil, targetSummary: String = "document",
                createdAt: Date = Date()) {
        self.id = id
        self.documentID = documentID
        self.format = format
        self.baseSHA256 = baseSHA256
        self.summary = summary
        self.commandsJSON = commandsJSON
        self.expectations = expectations
        self.selectionFingerprint = selectionFingerprint
        self.targetSummary = targetSummary
        self.createdAt = createdAt
    }
}

public struct OfficeCommandReceipt: Codable, Sendable, Equatable {
    public var documentID: String
    public var sha256: String
    public var commands: [String]
    public var verified: [String]
    public var saved: Bool
    public var replay: Bool
    public var note: String?

    public init(documentID: String, sha256: String, commands: [String], verified: [String],
                saved: Bool, replay: Bool = false, note: String? = nil) {
        self.documentID = documentID
        self.sha256 = sha256
        self.commands = commands
        self.verified = verified
        self.saved = saved
        self.replay = replay
        self.note = note
    }
}

public struct OfficeExportReceipt: Codable, Sendable, Equatable {
    public var documentID: String
    public var relativePath: String
    public var sha256: String
    public var byteCount: Int
    public var note: String?

    public init(documentID: String, relativePath: String, sha256: String,
                byteCount: Int, note: String? = nil) {
        self.documentID = documentID
        self.relativePath = relativePath
        self.sha256 = sha256
        self.byteCount = byteCount
        self.note = note
    }
}

public enum OfficeGrantDecision: Sendable, Equatable {
    case authorized
    case unknownGrant
    case expired
    case documentMismatch
    case alreadyConsumed
    case shaMismatch(expected: String, actual: String)
}

public enum OfficeGrantReservation: Sendable, Equatable {
    case reserved
    case unknownGrant
    case expired
    case documentMismatch
    case alreadyConsumed
    case alreadyReserved
    case shaMismatch(expected: String, actual: String)
}

public protocol OfficeCommandHost: Sendable {
    func authorizeAccess(_ access: OfficeCommandAccess) async throws
    func status(documentID: String, access: OfficeCommandAccess) async throws -> OfficeLiveStatus
    func prepareProposal(documentID: String, baseSHA256: String, summary: String,
                         commandsJSON: String, access: OfficeCommandAccess) async throws -> OfficeCommandProposal
    func storeProposal(_ proposal: OfficeCommandProposal) async throws
    func loadProposal(id: UUID, access: OfficeCommandAccess) async throws -> OfficeCommandProposal?
    func verifyProposalBinding(_ proposal: OfficeCommandProposal, documentID: String,
                               access: OfficeCommandAccess) async throws
    func removeProposal(id: UUID) async throws
    func consumeGrant(grantID: String, proposalID: UUID, documentID: String,
                      sha256: String) async -> OfficeGrantDecision
    func apply(proposal: OfficeCommandProposal, grantID: String, requestID: String,
               access: OfficeCommandAccess) async throws -> OfficeCommandReceipt
    func export(documentID: String, relativeOutput: String,
                access: OfficeCommandAccess) async throws -> OfficeExportReceipt
    /// Authorized automatic copy execution through a service-owned engine
    /// session. Called ONLY after the tool consumed the runtime-issued task
    /// authority for the exact apply call; the host runs the isolated working
    /// copy and never touches the original document. A host without a
    /// service-owned engine session keeps the default refusal below.
    func applyAutomatic(proposal: OfficeCommandProposal,
                        authorization: OfficeAutomaticAuthorization,
                        relativeOutput: String?,
                        requestID: String,
                        access: OfficeCommandAccess) async throws -> OfficeAutomaticReceipt

    /// Token-aware variant of the same call: production callers forward the
    /// tool context's cancellation so an automatic operation can leave at its
    /// safe pre-effect boundary (before any engine session or edit).
    func applyAutomatic(proposal: OfficeCommandProposal,
                        authorization: OfficeAutomaticAuthorization,
                        relativeOutput: String?,
                        requestID: String,
                        access: OfficeCommandAccess,
                        cancellation: CancellationToken?) async throws -> OfficeAutomaticReceipt
}

public extension OfficeCommandHost {
    /// Default token-aware forwarding for hosts that only implement the legacy
    /// requirement: this host cannot interrupt a running operation, but a
    /// context that is ALREADY cancelled must still leave at its safe
    /// pre-effect boundary instead of starting engine work. The token is never
    /// widened into authority; a live cancellation during the operation stays
    /// the legacy host's responsibility.
    func applyAutomatic(proposal: OfficeCommandProposal,
                        authorization: OfficeAutomaticAuthorization,
                        relativeOutput: String?,
                        requestID: String,
                        access: OfficeCommandAccess,
                        cancellation: CancellationToken?) async throws -> OfficeAutomaticReceipt {
        try cancellation?.throwIfCancelled()
        return try await applyAutomatic(proposal: proposal, authorization: authorization,
                                        relativeOutput: relativeOutput, requestID: requestID,
                                        access: access)
    }

    /// No service-owned engine session is installed: automatic execution is
    /// refused with the interactive alternative instead of a silent fallback.
    func applyAutomatic(proposal: OfficeCommandProposal,
                        authorization: OfficeAutomaticAuthorization,
                        relativeOutput: String?,
                        requestID: String,
                        access: OfficeCommandAccess) async throws -> OfficeAutomaticReceipt {
        throw FloeError.validationFailed(
            "This build has no service-owned Office engine session for automatic execution; "
                + "confirm the proposal in the editor UI (grant_id) or use a package-level tool.")
    }
}

/// Single-use, expiring, opaque grant store. Only the interactive editor calls
/// `issueGrant`; a grant arriving in a tool request is not authority.
public actor OfficeProposalGrantStore {
    private struct Entry {
        let proposalID: UUID
        let documentID: String
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
    public func issueGrant(proposal: OfficeCommandProposal, now: Date = Date()) -> String {
        sweep(now: now)
        let id = idProvider()
        entries[id] = Entry(proposalID: proposal.id, documentID: proposal.documentID,
                            sha256: proposal.baseSHA256, expiresAt: now.addingTimeInterval(timeToLive),
                            consumed: false, reserved: false)
        return id
    }

    public func consume(grantID: String, proposalID: UUID, documentID: String,
                        sha256: String, now: Date = Date()) -> OfficeGrantDecision {
        sweep(now: now)
        guard var entry = entries[grantID] else { return .unknownGrant }
        guard entry.proposalID == proposalID, entry.documentID == documentID else { return .documentMismatch }
        if entry.consumed || entry.reserved { return .alreadyConsumed }
        if entry.expiresAt <= now { return .expired }
        if entry.sha256.lowercased() != sha256.lowercased() {
            return .shaMismatch(expected: entry.sha256, actual: sha256)
        }
        entry.consumed = true
        entries[grantID] = entry
        return .authorized
    }

    public func reserve(grantID: String, proposalID: UUID, documentID: String,
                        sha256: String, now: Date = Date()) -> OfficeGrantReservation {
        sweep(now: now)
        guard var entry = entries[grantID] else { return .unknownGrant }
        guard entry.proposalID == proposalID, entry.documentID == documentID else { return .documentMismatch }
        if entry.consumed { return .alreadyConsumed }
        if entry.reserved { return .alreadyReserved }
        if entry.expiresAt <= now { return .expired }
        if entry.sha256.lowercased() != sha256.lowercased() {
            return .shaMismatch(expected: entry.sha256, actual: sha256)
        }
        entry.reserved = true
        entries[grantID] = entry
        return .reserved
    }

    @discardableResult
    public func commitReservation(grantID: String) -> Bool {
        guard var entry = entries[grantID], entry.reserved, !entry.consumed else { return false }
        entry.reserved = false
        entry.consumed = true
        entries[grantID] = entry
        return true
    }

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

// MARK: - Command JSON codec

public enum OfficeCommandCodec {
    public struct Entry: Codable, Sendable, Equatable {
        public var id: String
        public var arguments: [String: String]

        public init(id: String, arguments: [String: String]) {
            self.id = id
            self.arguments = arguments
        }
    }

    public static func encode(_ commands: [OfficeEngineCommand]) throws -> String {
        let entries = commands.map { command -> Entry in
            switch command {
            case .wordStyle(let name): return Entry(id: command.id, arguments: ["style": name])
            case .wordAlignment(let alignment): return Entry(id: command.id, arguments: ["alignment": alignment.rawValue])
            case .wordInsertTable(let rows, let columns):
                return Entry(id: command.id, arguments: ["rows": "\(rows)", "columns": "\(columns)"])
            case .excelNumberFormat(let format, let cell):
                return Entry(id: command.id, arguments: ["format": format.rawValue, "cell": cell])
            case .excelInsertRows(let count, let cell), .excelDeleteRows(let count, let cell),
                 .excelInsertColumns(let count, let cell), .excelDeleteColumns(let count, let cell):
                return Entry(id: command.id, arguments: ["count": "\(count)", "cell": cell])
            case .excelFreezePanes(let cell): return Entry(id: command.id, arguments: cell.map { ["cell": $0] } ?? [:])
            case .excelSort(let ascending, let range):
                var arguments = ["ascending": "\(ascending)"]
                if let range { arguments["range"] = range }
                return Entry(id: command.id, arguments: arguments)
            case .excelGoToCell(let cell): return Entry(id: command.id, arguments: ["cell": cell])
            case .pptDuplicateSlide(let at): return Entry(id: command.id, arguments: ["at": "\(at)"])
            case .pptMoveSlide(let from, let to):
                return Entry(id: command.id, arguments: ["from": "\(from)", "to": "\(to)"])
            case .pptAlignObjects(let alignment):
                return Entry(id: command.id, arguments: ["alignment": alignment.rawValue])
            case .wordBulletList, .wordNumberedList, .excelAutoFilter, .excelRecalculate:
                return Entry(id: command.id, arguments: [:])
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(entries), as: UTF8.self)
    }

    public static func decode(_ json: String) throws -> [OfficeEngineCommand] {
        guard let data = json.data(using: .utf8) else {
            throw FloeError.validationFailed("commands must be UTF-8 JSON")
        }
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        return try entries.map { try decode(entry: $0) }
    }

    static func decode(entry: Entry) throws -> OfficeEngineCommand {
        func int(_ key: String) throws -> Int {
            guard let raw = entry.arguments[key], let value = Int(raw) else {
                throw FloeError.validationFailed("\(entry.id) needs an integer '\(key)'")
            }
            return value
        }
        func string(_ key: String) throws -> String {
            guard let value = entry.arguments[key], !value.isEmpty else {
                throw FloeError.validationFailed("\(entry.id) needs a non-empty '\(key)'")
            }
            return value
        }
        let command: OfficeEngineCommand
        switch entry.id {
        case "word.style":
            command = .wordStyle(name: try string("style"))
        case "word.bulletList":
            command = .wordBulletList
        case "word.numberedList":
            command = .wordNumberedList
        case "word.alignment":
            guard let alignment = OfficeParagraphAlignment(rawValue: try string("alignment")) else {
                throw FloeError.validationFailed("word.alignment must be left|center|right|justified")
            }
            command = .wordAlignment(alignment)
        case "word.insertTable":
            command = .wordInsertTable(rows: try int("rows"), columns: try int("columns"))
        case "excel.numberFormat":
            guard let format = OfficeNumberFormat(rawValue: try string("format")) else {
                throw FloeError.validationFailed("unknown excel.numberFormat value")
            }
            command = .excelNumberFormat(format, cell: try string("cell"))
        case "excel.insertRows": command = .excelInsertRows(count: try int("count"), at: try string("cell"))
        case "excel.deleteRows": command = .excelDeleteRows(count: try int("count"), at: try string("cell"))
        case "excel.insertColumns": command = .excelInsertColumns(count: try int("count"), at: try string("cell"))
        case "excel.deleteColumns": command = .excelDeleteColumns(count: try int("count"), at: try string("cell"))
        case "excel.freezePanes": command = .excelFreezePanes(at: entry.arguments["cell"])
        case "excel.sort":
            guard let ascending = entry.arguments["ascending"].flatMap(Bool.init) else {
                throw FloeError.validationFailed("excel.sort needs ascending=true|false")
            }
            command = .excelSort(ascending: ascending, range: entry.arguments["range"])
        case "excel.autoFilter": command = .excelAutoFilter
        case "excel.goToCell": command = .excelGoToCell(try string("cell"))
        case "excel.recalculate": command = .excelRecalculate
        case "pptx.duplicateSlide": command = .pptDuplicateSlide(at: try int("at"))
        case "pptx.moveSlide": command = .pptMoveSlide(from: try int("from"), to: try int("to"))
        case "pptx.alignObjects":
            guard let alignment = OfficeObjectAlignment(rawValue: try string("alignment")) else {
                throw FloeError.validationFailed("pptx.alignObjects must be left|center|right|top|middle|bottom")
            }
            command = .pptAlignObjects(alignment)
        default:
            throw FloeError.validationFailed("unsupported office command '\(entry.id)'")
        }
        try command.validate()
        return command
    }

    /// The OOXML expectation list shown in the proposal preview and checked
    /// after the saved package is reopened.
    public static func expectations(_ commands: [OfficeEngineCommand]) -> [String] {
        commands.flatMap { command -> [String] in
            switch command {
            case .wordStyle(let name): return ["paragraph style \(name) referenced"]
            case .wordBulletList: return ["bulleted numbering present"]
            case .wordNumberedList: return ["decimal numbering present"]
            case .wordAlignment(let alignment): return ["paragraph alignment \(alignment.rawValue)"]
            case .wordInsertTable(let rows, let columns): return ["table \(rows)×\(columns) present"]
            case .excelNumberFormat(let format, let cell): return ["cell \(cell) format \(format.rawValue) changed"]
            case .excelInsertRows(let count, let cell): return ["row count +\(count) at \(cell)"]
            case .excelDeleteRows(let count, let cell): return ["row count -\(count) at \(cell)"]
            case .excelInsertColumns(let count, let cell): return ["column count +\(count) at \(cell)"]
            case .excelDeleteColumns(let count, let cell): return ["column count -\(count) at \(cell)"]
            case .excelFreezePanes(let cell): return [cell.map { "frozen pane at \($0)" } ?? "frozen pane present"]
            case .excelSort(let ascending, _): return ["selection sorted \(ascending ? "ascending" : "descending")"]
            case .excelAutoFilter: return ["autoFilter toggled"]
            case .excelGoToCell: return []
            case .excelRecalculate: return ["recalculation requested"]
            case .pptDuplicateSlide: return ["slide count +1"]
            case .pptMoveSlide: return ["slide order changed to the requested position"]
            case .pptAlignObjects(let alignment): return ["objects aligned \(alignment.rawValue) (dispatch only)"]
            }
        }
    }
}

// MARK: - Tool

public enum OfficeEditAction: String, Decodable, Sendable {
    case capabilities, read, query, propose, preview, apply, export, errors, replaceImage
}

public struct OfficeEditArguments: Decodable, Sendable {
    public var action: OfficeEditAction
    public var path: String?
    public var summary: String?
    public var commands: [OfficeCommandCodec.Entry]?
    public var proposalID: UUID?
    /// Raw `proposal_id` spelling exactly as the approved call carried it. The
    /// runtime digests the RAW approved arguments; the automatic-apply
    /// binding must derive from the same bytes, so the canonical payload
    /// keeps the exact spelling the tool printed (and the model echoes). Nil
    /// when the arguments were constructed programmatically. Setter-private:
    /// only the decoder/memberwise init inside this file may fill it, so a
    /// caller that mutates `proposalID` can never carry a stale spelling.
    public private(set) var proposalIDRaw: String?
    public var grantID: String?
    public var requestID: String?
    public var expectedSHA256: String?
    public var output: String?
    public var image: String?
    public var imagePath: String?

    enum CodingKeys: String, CodingKey {
        case action, path, summary, commands, output, image, imagePath
        case proposalID = "proposal_id"
        case grantID = "grant_id"
        case requestID = "request_id"
        case expectedSHA256 = "expected_sha256"
    }

    public init(action: OfficeEditAction,
                path: String? = nil,
                summary: String? = nil,
                commands: [OfficeCommandCodec.Entry]? = nil,
                proposalID: UUID? = nil,
                grantID: String? = nil,
                requestID: String? = nil,
                expectedSHA256: String? = nil,
                output: String? = nil,
                image: String? = nil,
                imagePath: String? = nil) {
        self.action = action
        self.path = path
        self.summary = summary
        self.commands = commands
        self.proposalID = proposalID
        self.proposalIDRaw = nil
        self.grantID = grantID
        self.requestID = requestID
        self.expectedSHA256 = expectedSHA256
        self.output = output
        self.image = image
        self.imagePath = imagePath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = try container.decode(OfficeEditAction.self, forKey: .action)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        commands = try container.decodeIfPresent([OfficeCommandCodec.Entry].self, forKey: .commands)
        if let rawProposalID = try container.decodeIfPresent(String.self, forKey: .proposalID) {
            guard let parsed = UUID(uuidString: rawProposalID) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .proposalID, in: container,
                    debugDescription: "proposal_id must be a UUID string")
            }
            proposalID = parsed
            proposalIDRaw = rawProposalID
        } else {
            proposalID = nil
            proposalIDRaw = nil
        }
        grantID = try container.decodeIfPresent(String.self, forKey: .grantID)
        requestID = try container.decodeIfPresent(String.self, forKey: .requestID)
        expectedSHA256 = try container.decodeIfPresent(String.self, forKey: .expectedSHA256)
        output = try container.decodeIfPresent(String.self, forKey: .output)
        image = try container.decodeIfPresent(String.self, forKey: .image)
        imagePath = try container.decodeIfPresent(String.self, forKey: .imagePath)
    }
}

public struct OfficeEditTool: AgentTool {
    public typealias Arguments = OfficeEditArguments

    public static let name = "document.office.edit"
    public static let toolDescription = """
    Inspect, propose and apply engine-level Word/Excel/Presentation edits through \
    the pinned native Office editor. Read the document first (document.office.inspect) \
    and call action=read for the live session's exact sha256. Supported through the \
    engine: Word paragraph styles/lists/alignment/table insert; Excel number formats, \
    row/column insert-delete, freeze panes, sort, AutoFilter, go-to-cell, recalculation; \
    Presentation slide duplicate, slide reorder, object alignment. Package-level \
    (verified, atomic): formula cell updates via document.office.updateText, image \
    replacement (action=replaceImage, same image format), formula-error cell locations \
    (action=errors). propose binds the exact sha256 and changes nothing; it returns \
    status=proposed with the proposal_id. For an already-authorized task, call apply \
    with that proposal_id and the SAME path and NO grant_id: the runtime authorizes \
    this exact call and the apply runs a service-owned engine session on an isolated \
    copy and publishes a verified <name>.edited.<ext> COPY — the original document is \
    never overwritten, the output is reopened and checked (including persisted formula \
    cached value/type/error for workbooks), and selection-relative commands are refused \
    automatically. grant_id is only for a review the user explicitly requested in the \
    editor UI: with it, apply commits the document through the live session. A model \
    cannot mint a grant or an authorization; never claim an engine change was accepted \
    without the returned verified facts. Unsupported engine operations are reported \
    unavailable, never faked with screenshots or PDF edits.
    """
    public static let parametersJSON = #"""
    {
      "type": "object",
      "additionalProperties": false,
      "required": ["action"],
      "properties": {
        "action": { "type": "string", "enum": ["capabilities", "read", "query", "propose", "preview", "apply", "export", "errors", "replaceImage"] },
        "path": { "type": "string", "description": "Workspace-relative .docx/.xlsx/.pptx path. For apply it must resolve to the stored proposal's own document: a different path is refused before any edit." },
        "summary": { "type": "string", "maxLength": 2000, "description": "Human-readable proposal summary shown before confirmation (propose)." },
        "commands": {
          "type": "array", "maxItems": 64,
          "description": "Validated engine commands (propose). Supported ids: word.style{style}; word.bulletList; word.numberedList; word.alignment{alignment}; word.insertTable{rows,columns}; excel.numberFormat{format,cell}; excel.insertRows{count,cell}; excel.deleteRows{count,cell}; excel.insertColumns{count,cell}; excel.deleteColumns{count,cell}; excel.freezePanes{cell?}; excel.sort{ascending,range?}; excel.autoFilter; excel.goToCell{cell}; excel.recalculate; pptx.duplicateSlide{at}; pptx.moveSlide{from,to}; pptx.alignObjects{alignment}. Word style/list/alignment, excel sort/autoFilter and pptx.alignObjects act on the live selection: propose captures the engine selection identity and apply refuses if it changed. They are unavailable in automatic copy execution (no user selection exists); use explicit cell-addressed commands.",
          "items": { "type": "object", "required": ["id"], "properties": { "id": { "type": "string" }, "arguments": { "type": "object", "additionalProperties": { "type": "string" } } } }
        },
        "proposal_id": { "type": "string", "format": "uuid", "description": "Proposal id from propose (preview/apply). For apply, pass this id with the same path and no grant_id unless the user explicitly asked to confirm in the editor UI." },
        "grant_id": { "type": "string", "description": "Opaque single-use confirmation token issued by the editor UI after the user accepts — only for a review the user explicitly requested. The model cannot mint this. OMIT for the ordinary already-authorized apply: the runtime approval of this exact call authorizes an isolated verified copy and the original is never modified." },
        "request_id": { "type": "string", "description": "Optional caller idempotency key; defaults to the tool call id." },
        "expected_sha256": { "type": "string", "pattern": "^[a-fA-F0-9]{64}$", "description": "Exact revision for propose/replaceImage (from action=read or inspect)." },
        "output": { "type": "string", "description": "export relative path (default <name>.export.<ext>); for an apply without grant_id it is the verified edited-copy destination (default <name>.edited.<ext>). An apply that passes both grant_id and output is refused; an existing different file is never overwritten." },
        "image": { "type": "string", "description": "replaceImage target: package member such as ppt/media/image2.png or #N for the N-th image." },
        "imagePath": { "type": "string", "description": "replaceImage source: workspace-relative PNG/JPEG/GIF path, same format as the target member." }
      }
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles, .writesFiles]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating
    public static let requiresHostScope = false

    private let host: OfficeCommandHost
    private let grants: OfficeProposalGrantStore
    private let workspaceRoot: @Sendable () -> URL?

    public init(host: OfficeCommandHost,
                grants: OfficeProposalGrantStore = OfficeProposalGrantStore(),
                workspaceRoot: @escaping @Sendable () -> URL?) {
        self.host = host
        self.grants = grants
        self.workspaceRoot = workspaceRoot
    }

    /// Trusted UI path: issue a single-use grant after the user accepts.
    @discardableResult
    public func issueUserGrant(for proposal: OfficeCommandProposal) async -> String {
        await grants.issueGrant(proposal: proposal)
    }

    public func consumeUserGrant(grantID: String, proposal: OfficeCommandProposal) async -> OfficeGrantDecision {
        await grants.consume(grantID: grantID, proposalID: proposal.id,
                             documentID: proposal.documentID, sha256: proposal.baseSHA256)
    }

    public static func access(from context: ToolContext) -> OfficeCommandAccess {
        OfficeCommandAccess(environmentID: context.environmentID,
                            workspacePath: context.workspaceRootURL?.path,
                            ownerKind: context.conversationID == nil ? "workspace" : "chat",
                            ownerID: context.conversationID,
                            conversationID: context.conversationID)
    }

    public func validate(_ args: Arguments) throws {
        switch args.action {
        case .capabilities:
            return
        case .query:
            guard let path = args.path, !path.isEmpty else {
                throw FloeError.validationFailed("path is required")
            }
        case .read, .errors:
            guard let path = args.path, !path.isEmpty else {
                throw FloeError.validationFailed("path is required")
            }
        case .propose:
            guard let path = args.path, !path.isEmpty else {
                throw FloeError.validationFailed("path is required")
            }
            guard let digest = args.expectedSHA256, digest.count == 64 else {
                throw FloeError.validationFailed("propose requires expected_sha256 from action=read")
            }
            guard let commands = args.commands, !commands.isEmpty, commands.count <= 64 else {
                throw FloeError.validationFailed("commands must contain 1...64 entries")
            }
            for entry in commands { _ = try OfficeCommandCodec.decode(entry: entry) }
        case .preview, .apply:
            guard args.proposalID != nil else {
                throw FloeError.validationFailed("proposal_id is required")
            }
            if args.action == .apply, let grant = args.grantID, !grant.isEmpty,
               let output = args.output?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
                throw FloeError.validationFailed(
                    "apply accepts output only for an authorized automatic copy execution; "
                        + "remove output to commit the document in the editor, or omit grant_id to write a verified copy")
            }
            if args.action == .apply, let output = args.output, output.utf8.count > 1_024 {
                throw FloeError.validationFailed("output path is too long")
            }
        case .export:
            guard let path = args.path, !path.isEmpty else {
                throw FloeError.validationFailed("path is required")
            }
        case .replaceImage:
            guard let path = args.path, !path.isEmpty, let image = args.image, !image.isEmpty,
                  let imagePath = args.imagePath, !imagePath.isEmpty else {
                throw FloeError.validationFailed("replaceImage requires path, image and imagePath")
            }
            guard let digest = args.expectedSHA256, digest.count == 64 else {
                throw FloeError.validationFailed("replaceImage requires expected_sha256 from action=read")
            }
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        do {
            try validate(args)
            try await host.authorizeAccess(Self.access(from: context))
            switch args.action {
            case .capabilities:
                return output(OfficeCapabilityTool.capabilitiesJSON(enginePresent: true))
            case .query:
                return try query(args)
            case .read:
                return try await read(args, context: context)
            case .errors:
                return try errors(args, context: context)
            case .propose:
                return try await propose(args, context: context)
            case .preview:
                return try await preview(args, context: context)
            case .apply:
                return try await apply(args, context: context)
            case .export:
                return try await export(args, context: context)
            case .replaceImage:
                return try await replaceImage(args, context: context)
            }
        } catch {
            return output("status=error error=\(error.localizedDescription)", exitStatus: 2)
        }
    }

    // MARK: Actions

    private func query(_ args: Arguments) throws -> ToolExecutionOutput {
        guard let path = args.path,
              let format = OfficeDocumentFormat(fileExtension: (path as NSString).pathExtension) else {
            throw FloeError.validationFailed("path must end in .docx, .xlsx or .pptx")
        }
        struct CommandEntry: Codable {
            var id: String
            var format: String
            var arguments: [String: String]
            var mutating: Bool
            var target: String
            var requiresSelectionFingerprint: Bool
            var expectations: [String]
        }
        let entries: [CommandEntry] = OfficeEngineCommandCatalog.engineCommands(format).map { command in
            CommandEntry(id: command.id, format: format.rawValue,
                         arguments: Self.arguments(of: command),
                         mutating: command.isMutating,
                         target: command.targetSummary,
                         requiresSelectionFingerprint: command.requiresSelectionFingerprint,
                         expectations: OfficeCommandCodec.expectations([command]))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: (try? encoder.encode(entries)) ?? Data("[]".utf8), as: UTF8.self)
        return output("format=\(format.rawValue) commands=\(entries.count)\n\(json)")
    }

    private func read(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let path = try requirePath(args)
        _ = try resolveWorkspaceFile(path, context: context, mustExist: true)
        let access = Self.access(from: context)
        let status = try await host.status(documentID: path, access: access)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: (try? encoder.encode(status)) ?? Data("{}".utf8), as: UTF8.self)
        return output(json)
    }

    private func errors(_ args: Arguments, context: ToolContext) throws -> ToolExecutionOutput {
        let path = try requirePath(args)
        let url = try resolveWorkspaceFile(path, context: context, mustExist: true)
        let snapshot = try OfficeOutputSnapshot.capture(url: url)
        guard snapshot.kind == .workbook else {
            throw FloeError.validationFailed("error cells are only defined for .xlsx workbooks")
        }
        let lines = snapshot.errorCells.prefix(500).map { "cell=\($0.cell) error=\($0.error)" }
        return output("sha256=\(snapshot.sha256) errorCells=\(snapshot.errorCells.count)\n" + lines.joined(separator: "\n"))
    }

    private func propose(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let path = try requirePath(args)
        let url = try resolveWorkspaceFile(path, context: context, mustExist: true)
        let format = try requireFormat(path)
        let commands = try decodeCommands(args)
        for command in commands where command.format != format {
            throw OfficeEngineCommandError.unsupportedFormat(command.id, format.rawValue)
        }
        let access = Self.access(from: context)
        let status = try await host.status(documentID: path, access: access)
        guard let expected = args.expectedSHA256?.lowercased(), status.revisionSHA256.lowercased() == expected else {
            throw FloeError.validationFailed(
                "the document changed after it was read (expected \(args.expectedSHA256?.prefix(12) ?? "?")…, current \(status.revisionSHA256.prefix(12))…); read it again")
        }
        // Also prove the bytes on disk are still the exact revision the caller saw.
        let snapshot = try OfficeOutputSnapshot.capture(url: url)
        guard snapshot.sha256 == expected else {
            throw FloeError.validationFailed("the file on disk changed; read it again before proposing")
        }
        let commandsJSON = try OfficeCommandCodec.encode(commands)
        let proposal = try await host.prepareProposal(
            documentID: path, baseSHA256: expected,
            summary: args.summary ?? commands.map(\.summary).joined(separator: "; "),
            commandsJSON: commandsJSON, access: access)
        try await host.storeProposal(proposal)
        return output("proposal_id=\(proposal.id.uuidString) sha256=\(proposal.baseSHA256) commands=\(commands.count) "
            + "expectations=\(proposal.expectations.count) status=proposed "
            + "next=apply with this proposal_id and the same path; omit grant_id for an already-authorized task "
            + "(the runtime authorizes this exact call), or confirm in the editor UI when review was requested")
    }

    private func preview(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        guard let id = args.proposalID else { throw FloeError.validationFailed("proposal_id is required") }
        let access = Self.access(from: context)
        guard let proposal = try await host.loadProposal(id: id, access: access) else {
            throw FloeError.notFound("proposal \(id.uuidString)")
        }
        return output("proposal_id=\(proposal.id.uuidString) document=\(proposal.documentID) sha256=\(proposal.baseSHA256) "
            + "summary=\(proposal.summary)\nexpectations:\n" + proposal.expectations.map { "- \($0)" }.joined(separator: "\n"))
    }

    private func apply(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        guard let id = args.proposalID else {
            throw FloeError.validationFailed("proposal_id is required")
        }
        let access = Self.access(from: context)
        guard let proposal = try await host.loadProposal(id: id, access: access) else {
            throw FloeError.notFound("proposal \(id.uuidString)")
        }
        try await host.verifyProposalBinding(proposal, documentID: proposal.documentID, access: access)
        let requestID = args.requestID ?? context.toolCallID ?? UUID().uuidString
        let interactiveGrant = (args.grantID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !interactiveGrant.isEmpty {
            let receipt = try await host.apply(proposal: proposal, grantID: interactiveGrant,
                                               requestID: requestID, access: access)
            try? await host.removeProposal(id: id)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let json = String(decoding: (try? encoder.encode(receipt)) ?? Data("{}".utf8), as: UTF8.self)
            return output("status=\(receipt.saved ? "saved" : "partial") replay=\(receipt.replay)\n\(json)")
        }
        // No UI grant: the ONLY authority for an automatic copy execution is
        // the runtime-issued task authority for this exact approved call. A
        // model-supplied `confirmed`/grant-looking value is never consulted.
        //
        // The STORED proposal's document is the mutation identity: a declared
        // `path` that names a different document than the proposal is refused
        // here, before the authority is consumed or any engine work starts.
        // The runtime approved the DECLARED call, so the consumer must prove
        // the declared identity and the stored proposal identity are the same
        // document — the model cannot pick the write boundary with `path`.
        if let declared = args.path?.trimmingCharacters(in: .whitespacesAndNewlines),
           !declared.isEmpty {
            let root = context.workspaceRootURL ?? workspaceRoot()
            let declaredTarget = Self.canonicalDocumentTarget(declared, workspaceRoot: root)
            let proposalTarget = Self.canonicalDocumentTarget(proposal.documentID, workspaceRoot: root)
            guard let declaredTarget, let proposalTarget, declaredTarget == proposalTarget else {
                throw FloeError.validationFailed(
                    "the declared path does not match the stored proposal's document "
                        + "\(proposal.documentID); an automatic apply is bound to the proposal's own document")
            }
        }
        let binding: RuntimeAuthorityBinding
        do {
            binding = try Self.runtimeAuthorityBinding(for: args, context: context, workspaceRoot: workspaceRoot)
        } catch {
            throw FloeError.validationFailed(
                "automatic apply could not bind the approved call: \(error.localizedDescription)")
        }
        let verdict = await context.consumeRuntimeAuthority(binding: binding)
        guard verdict.isValid else {
            throw FloeError.validationFailed(
                "automatic apply needs the runtime-approved call authority for this exact operation"
                    + (verdict.failureReason.map { " (\($0))" } ?? "")
                    + "; a model-provided confirmation is not authority. Confirm the proposal in the editor UI (grant_id), "
                    + "or send the apply call with canonical JSON arguments (omit optional fields instead of null).")
        }
        // A selection-relative command cannot be redirected without the live
        // editor selection; refuse before opening any session.
        for command in (try? OfficeCommandCodec.decode(proposal.commandsJSON)) ?? []
        where command.requiresSelectionFingerprint {
            throw FloeError.validationFailed(
                "\(command.id) acts on the live editor selection and is unavailable for automatic copy execution; "
                    + "use explicit cell-addressed commands or confirm it in the editor UI")
        }
        let authorization = OfficeAutomaticAuthorization(
            runID: context.runID,
            taskID: context.conversationID,
            operationID: context.toolCallID ?? "",
            idempotencyKey: context.toolIdempotencyKey,
            approvalGrantID: context.approvalGrantID,
            binding: binding)
        let receipt = try await host.applyAutomatic(proposal: proposal,
                                                    authorization: authorization,
                                                    relativeOutput: args.output,
                                                    requestID: requestID,
                                                    access: access,
                                                    cancellation: context.cancellation)
        try? await host.removeProposal(id: id)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: (try? encoder.encode(receipt)) ?? Data("{}".utf8), as: UTF8.self)
        return output("status=\(receipt.saved ? "saved" : "partial") replay=\(receipt.replay) "
            + "mode=automatic-copy sourceUnchanged=\(receipt.sourceUnchanged)\n\(json)")
    }

    private func export(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let path = try requirePath(args)
        let url = try resolveWorkspaceFile(path, context: context, mustExist: true)
        let format = try requireFormat(path)
        var relativeOutput = args.output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if relativeOutput.isEmpty {
            relativeOutput = "\(path).export.\(format.rawValue)"
        }
        let access = Self.access(from: context)
        let sourceBefore = (try? FileDigest.sha256Hex(url)) ?? ""
        let receipt = try await host.export(documentID: path, relativeOutput: relativeOutput, access: access)
        // The source is never modified by export.
        let sourceAfter = try OfficeOutputSnapshot.capture(url: url)
        return output("exported=\(receipt.relativePath) sha256=\(receipt.sha256) bytes=\(receipt.byteCount) "
            + "sourceUnchanged=\(!sourceBefore.isEmpty && sourceBefore == sourceAfter.sha256)")
    }

    private func replaceImage(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        guard let path = args.path, let imageTarget = args.image, let imagePath = args.imagePath else {
            throw FloeError.validationFailed("path, image and imagePath are required")
        }
        let documentURL = try resolveWorkspaceFile(path, context: context, mustExist: true)
        let imageURL = try resolveWorkspaceFile(imagePath, context: context, mustExist: true)
        let values = try imageURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 64 * 1_024 * 1_024 else {
            throw FloeError.validationFailed("image must be a regular file of at most 64 MiB")
        }
        let data = try Data(contentsOf: imageURL, options: [.mappedIfSafe])
        // Refuse while a live editor holds unsaved edits, whose later save
        // would overwrite this package-level change.
        let access = Self.access(from: context)
        if let status = try? await host.status(documentID: path, access: access),
           status.liveSession, status.hasUnsavedChanges == true {
            throw FloeError.validationFailed(
                "the open editor has unsaved changes; save or discard them before replacing an image")
        }
        let snapshot = try OfficePackageEdits.replaceImage(
            url: documentURL,
            OfficeImageReplacement(target: imageTarget, imageData: data),
            expectedSHA256: args.expectedSHA256)
        return output("replaced=\(imageTarget) documentSha256=\(snapshot.sha256) bytes=\(data.count) verified=true "
            + "note=Picture relationship and layout unchanged; reopen the editor to see the new image.")
    }

    // MARK: Helpers

    private func decodeCommands(_ args: Arguments) throws -> [OfficeEngineCommand] {
        guard let entries = args.commands else { return [] }
        return try entries.map { try OfficeCommandCodec.decode(entry: $0) }
    }

    /// Canonical JSON of the DECODED approved arguments, in exactly the shape
    /// the runtime hashed when it minted this call's authority. Optional fields
    /// that were absent stay absent, and `proposal_id` keeps the RAW approved
    /// spelling: the runtime digests the raw argument bytes, so the consumer
    /// must bind the exact id string the tool printed and the model echoed —
    /// a re-spelled id is a different payload (mirrors the CAD contract).
    public static func canonicalApprovedPayload(_ args: OfficeEditArguments) throws -> Data {
        var object: [String: Any] = ["action": args.action.rawValue]
        if let path = args.path { object["path"] = path }
        if let summary = args.summary { object["summary"] = summary }
        if let commands = args.commands {
            object["commands"] = commands.map { entry -> [String: Any] in
                ["id": entry.id, "arguments": entry.arguments]
            }
        }
        if let proposalID = args.proposalID {
            object["proposal_id"] = approvedProposalIDSpelling(proposalID, raw: args.proposalIDRaw)
        }
        if let grantID = args.grantID { object["grant_id"] = grantID }
        if let requestID = args.requestID { object["request_id"] = requestID }
        if let expectedSHA256 = args.expectedSHA256 { object["expected_sha256"] = expectedSHA256 }
        if let output = args.output { object["output"] = output }
        if let image = args.image { object["image"] = image }
        if let imagePath = args.imagePath { object["imagePath"] = imagePath }
        return try JSONSerialization.data(withJSONObject: object, options: [])
    }

    /// The approved `proposal_id` spelling for the canonical payload: the RAW
    /// approved string only while it still parses to the argument's CURRENT
    /// id. A decoded-then-mutated argument (or any stale helper field) falls
    /// back to the current id's own spelling, so the digest can never bind an
    /// id the call no longer carries. When they agree, the RAW approved bytes
    /// are preserved verbatim (uppercase/lowercase wire spelling included).
    public static func approvedProposalIDSpelling(_ proposalID: UUID, raw: String?) -> String {
        if let raw, UUID(uuidString: raw) == proposalID { return raw }
        return proposalID.uuidString
    }

    /// Canonical `file:` identity for one office document path, resolved with
    /// the same rules the runtime mints its canonical target with: absolute,
    /// or workspace-root-relative, standardized with symlinks resolved. Nil
    /// when the value cannot name a document.
    public static func canonicalDocumentTarget(_ raw: String, workspaceRoot: URL?) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 4_096 else { return nil }
        let url: URL
        if trimmed.hasPrefix("/") {
            url = URL(fileURLWithPath: trimmed)
        } else if let workspaceRoot {
            url = workspaceRoot.appendingPathComponent(trimmed)
        } else {
            return nil
        }
        return "file:" + url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Mirrors `RuntimeAuthorityDigest.canonicalTarget` for this tool's exact
    /// resolution rules (`document.` prefix → path argument, else the workspace
    /// wildcard). Both sides must derive the same string or the token refuses.
    public static func canonicalTarget(for args: OfficeEditArguments, workspaceRoot: URL?) -> String {
        if let raw = args.path, let target = canonicalDocumentTarget(raw, workspaceRoot: workspaceRoot) {
            return target
        }
        guard let workspaceRoot else { return "workspace:*" }
        return "workspace:" + workspaceRoot.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Builds the binding this apply call implies, exactly like the runtime
    /// minted it. Throws only when the approved arguments cannot be
    /// canonicalized (which itself is a refusal, never a bypass).
    public static func runtimeAuthorityBinding(for args: OfficeEditArguments,
                                               context: ToolContext,
                                               workspaceRoot: @escaping @Sendable () -> URL?) throws -> RuntimeAuthorityBinding {
        let root = context.workspaceRootURL ?? workspaceRoot()
        let payload = try canonicalApprovedPayload(args)
        return context.runtimeAuthorityBinding(
            toolName: name,
            operation: "apply",
            canonicalTarget: canonicalTarget(for: args, workspaceRoot: root),
            baseRevision: RuntimeAuthorityDigest.baseRevision(in: payload),
            payloadDigest: RuntimeAuthorityDigest.payloadDigest(payload))
    }

    /// Argument shape shown by action=query for one command.
    static func arguments(of command: OfficeEngineCommand) -> [String: String] {        switch command {
        case .wordStyle(let name): return ["style": name]
        case .wordAlignment(let alignment): return ["alignment": alignment.rawValue]
        case .wordInsertTable(let rows, let columns): return ["rows": "\(rows)", "columns": "\(columns)"]
        case .excelNumberFormat(let format, let cell): return ["format": format.rawValue, "cell": cell]
        case .excelInsertRows(let count, let cell), .excelDeleteRows(let count, let cell),
             .excelInsertColumns(let count, let cell), .excelDeleteColumns(let count, let cell):
            return ["count": "\(count)", "cell": cell]
        case .excelFreezePanes(let cell): return cell.map { ["cell": $0] } ?? [:]
        case .excelSort(let ascending, let range):
            var arguments = ["ascending": "\(ascending)"]
            if let range { arguments["range"] = range }
            return arguments
        case .excelGoToCell(let cell): return ["cell": cell]
        case .pptDuplicateSlide(let at): return ["at": "\(at)"]
        case .pptMoveSlide(let from, let to): return ["from": "\(from)", "to": "\(to)"]
        case .pptAlignObjects(let alignment): return ["alignment": alignment.rawValue]
        case .wordBulletList, .wordNumberedList, .excelAutoFilter, .excelRecalculate:
            return [:]
        }
    }

    private func requirePath(_ args: Arguments) throws -> String {
        guard let path = args.path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty,
              path.utf8.count <= 1_024 else {
            throw FloeError.validationFailed("path is required")
        }
        return path
    }

    private func requireFormat(_ path: String) throws -> OfficeDocumentFormat {
        guard let format = OfficeDocumentFormat(fileExtension: (path as NSString).pathExtension) else {
            throw FloeError.validationFailed("path must end in .docx, .xlsx or .pptx")
        }
        return format
    }

    private func resolveWorkspaceFile(_ path: String, context: ToolContext, mustExist: Bool) throws -> URL {
        try context.authorizeWorkspacePath(path)
        guard let root = context.workspaceRootURL ?? workspaceRoot() else {
            throw FloeError.validationFailed("No workspace is open")
        }
        let guarder = WorkspacePathGuard(rootURL: root, maxReadBytes: 128 * 1_024 * 1_024,
                                         maxWriteBytes: 128 * 1_024 * 1_024)
        let url = try guarder.resolve(path)
        try guarder.assertWritable(url)
        if mustExist {
            try guarder.assertReadableSize(url)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw FloeError.validationFailed("Office document does not exist: \(path)")
            }
        }
        return url
    }

    private func output(_ text: String, exitStatus: Int32 = 0) -> ToolExecutionOutput {
        ToolExecutionOutput(digesting: text, exitStatus: exitStatus)
    }
}

private enum FileDigest {
    static func sha256Hex(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
