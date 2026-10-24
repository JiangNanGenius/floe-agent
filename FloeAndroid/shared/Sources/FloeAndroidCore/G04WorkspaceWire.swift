// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Closed G04 command payload grammar. Declaration is not readiness: only
/// the real root-owned facade may register workspace.read/workspace.write
/// (and the additive D14 workspace.activate command below).
/// Every editor revision remains an opaque native token. No Run, absolute
/// root, environment or permission can be authored in this payload.
struct G04WorkspaceWireRequest: Sendable {
    typealias Value = SettingsDomainV1.JSONValue
    enum Failure: Error, Sendable { case invalidPayload, unknownOperation, wrongFamily, invalidField(String) }
    enum Operation: String, Sendable, CaseIterable {
        case list, search, findFileNames, metadata, tabs, open
        case beginContent, readContent, releaseContent, find, queryContent, releaseQuery
        case createFile, createDirectory, move, copy, delete, edit, selection, replace
        case beginEditUpload, appendEditUpload, commitEditUpload, cancelEditUpload
        case undo, redo, save, resolveConflictUsingDraft, close
        // D15 (Main renderer review 2026-10-24): the real KEEP_BOTH path.
        // The external original is never overwritten; the complete native
        // draft bytes are durably copied to a separate no-overwrite target
        // (verified by read-back SHA) and optionally opened as a new tab.
        // The old draft tab is discarded ONLY after that verified copy
        // acknowledgement AND only when the caller explicitly chose it.
        // `chosenText` never rides this control message: the App commits a
        // merged choice into the native draft through the existing bounded
        // upload transaction, then forks the native bytes.
        case forkDraft
        // G04 selected-workspace Git/Actions; same native owner and complete
        // query-byte carrier. No new generic evaluator or root argument.
        case gitQuery, gitMutate
        case beginProjectionRecovery, appendProjectionRecovery, commitProjectionRecovery, cancelProjectionRecovery

        var isRead: Bool {
            switch self {
            case .list, .search, .findFileNames, .metadata, .tabs, .open,
                 .beginContent, .readContent, .releaseContent, .find, .queryContent, .releaseQuery, .gitQuery: true
            default: false
            }
        }
        var command: String { isRead ? "workspace.read" : "workspace.write" }
        var fields: Set<String> {
            switch self {
            case .list: ["path", "pageToken"]
            case .search, .findFileNames: ["query", "path"]
            case .metadata, .open, .createDirectory: ["path"]
            case .tabs: []
            case .gitQuery, .gitMutate: ["action", "arguments"]
            case .beginContent: ["documentID", "revision", "part"]
            case .readContent, .queryContent: ["handle", "offset", "limit"]
            case .releaseContent, .releaseQuery, .commitEditUpload, .cancelEditUpload: ["handle"]
            case .find: ["documentID", "revision", "query", "caseSensitive", "wholeWord", "backwards"]
            case .replace: ["documentID", "revision", "query", "replacement", "caseSensitive", "wholeWord", "all"]
            case .createFile: ["path", "content"]
            case .move, .copy: ["from", "to"]
            case .delete: ["path", "recursive"]
            case .edit: ["documentID", "revision", "location", "length", "replacement", "selectionLocation", "selectionLength"]
            case .selection: ["documentID", "revision", "location", "length"]
            case .beginProjectionRecovery: ["recoveryID", "sourcePath", "byteCount", "sha256"]
            case .appendProjectionRecovery: ["handle", "offset", "bytes"]
            case .commitProjectionRecovery, .cancelProjectionRecovery: ["handle"]
            case .beginEditUpload: ["documentID", "revision", "location", "length", "byteCount", "sha256"]
            case .appendEditUpload: ["handle", "offset", "bytes"]
            case .undo, .redo, .save: ["documentID", "revision"]
        case .resolveConflictUsingDraft: ["documentID", "revision", "reviewedSHA256"]
        case .close: ["documentID", "revision", "discardDraft"]
        case .forkDraft: ["documentID", "revision", "destination", "discardAfterCopy"]
        }
        }
    }

    let operation: Operation
    let workspaceID: UUID
    let nativeEpoch: UInt64
    private let object: [String: Value]

    init(payload: Value?, command: String) throws {
        guard case .object(let object) = payload,
              case .string(let name)? = object["op"], let operation = Operation(rawValue: name)
        else { throw Failure.invalidPayload }
        guard command == operation.command else { throw Failure.wrongFamily }
        guard Set(object.keys).isSubset(of: operation.fields.union(["op", "workspaceID", "nativeEpoch"])) else {
            throw Failure.invalidPayload
        }
        guard case .string(let rawWorkspace)? = object["workspaceID"],
              let workspaceID = UUID(uuidString: rawWorkspace),
              rawWorkspace.lowercased() == workspaceID.uuidString.lowercased(),
              case .string(let rawEpoch)? = object["nativeEpoch"],
              let epoch = UInt64(rawEpoch), epoch > 0, String(epoch) == rawEpoch else { throw Failure.invalidPayload }
        self.operation = operation; self.workspaceID = workspaceID; self.nativeEpoch = epoch; self.object = object
        try validateFields()
    }

    func hasField(_ key: String) -> Bool { object[key] != nil }
    func fieldsObject(_ key: String) throws -> [String: Value] {
        guard let value = object[key] else { return [:] }
        guard case .object(let fields) = value else { throw Failure.invalidField(key) }
        return fields
    }
    func text(_ key: String, default fallback: String? = nil, maxBytes: Int = 4096) throws -> String {
        guard let value = object[key] else {
            if let fallback { return fallback }; throw Failure.invalidField(key)
        }
        guard case .string(let string) = value, string.utf8.count <= maxBytes,
              !string.contains("\0") else { throw Failure.invalidField(key) }
        return string
    }
    func optionalText(_ key: String, maxBytes: Int = 4096) throws -> String? {
        guard let value = object[key] else { return nil }
        if value == .null { return nil }
        return try text(key, maxBytes: maxBytes)
    }
    func integer(_ key: String, maximum: Int, default fallback: Int? = nil) throws -> Int {
        guard let value = object[key] else {
            if let fallback { return fallback }; throw Failure.invalidField(key)
        }
        guard case .integer(let raw) = value, raw >= 0, raw <= Int64(maximum) else { throw Failure.invalidField(key) }
        return Int(raw)
    }
    func flag(_ key: String, default fallback: Bool = false) throws -> Bool {
        guard let value = object[key] else { return fallback }
        guard case .boolean(let flag) = value else { throw Failure.invalidField(key) }
        return flag
    }
    func identifier(_ key: String) throws -> UUID {
        let raw = try text(key, maxBytes: 36)
        guard let uuid = UUID(uuidString: raw), raw.lowercased() == uuid.uuidString.lowercased() else { throw Failure.invalidField(key) }
        return uuid
    }
    func revision() throws -> String {
        let revision = try text("revision", maxBytes: 128)
        guard !revision.isEmpty else { throw Failure.invalidField("revision") }
        return revision
    }
    func range() throws -> NSRange {
        let location = try integer("location", maximum: G04WorkspaceDocumentSession.maximumDocumentBytes)
        let length = try integer("length", maximum: G04WorkspaceDocumentSession.maximumDocumentBytes)
        guard length <= G04WorkspaceDocumentSession.maximumDocumentBytes - location else { throw Failure.invalidField("length") }
        return NSRange(location: location, length: length)
    }
    func digest(_ key: String) throws -> String {
        let value = try text(key, maxBytes: 64)
        guard value.utf8.count == 64,
              value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw Failure.invalidField(key) }
        return value
    }

    private func validateFields() throws {
        if operation == .gitQuery || operation == .gitMutate {
            _ = try G04WorkspaceGit.Arguments(action: text("action", maxBytes: 64),
                values: fieldsObject("arguments"), write: operation == .gitMutate)
        }
        switch operation {
        case .metadata, .open, .createDirectory, .delete, .createFile: _ = try text("path")
        case .move, .copy: _ = try text("from"); _ = try text("to")
        case .search, .findFileNames:
            guard try !text("query", maxBytes: 8192).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Failure.invalidField("query")
            }
        case .find, .replace: _ = try text("query", maxBytes: 8192)
        default: break
        }

        for name in ["path", "from", "to", "destination"] where object[name] != nil {
            let path = try text(name)
            guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~") else { throw Failure.invalidField(name) }
            // Actual traversal/symlink/secret checks remain original native
            // WorkspacePathGuard after the workspace is resolved by stores.
        }
        if operation.fields.contains("documentID") { _ = try identifier("documentID"); _ = try revision() }
        if operation == .forkDraft { _ = try optionalText("destination", maxBytes: 4096) }
        if operation.fields.contains("handle") {
            let handle = try text("handle", maxBytes: 256)
            guard !handle.isEmpty else { throw Failure.invalidField("handle") }
        }
        if operation.fields.contains("location") { _ = try range() }
        for key in ["recursive", "caseSensitive", "wholeWord", "backwards", "discardDraft", "all",
                    "discardAfterCopy"] where object[key] != nil {
            _ = try flag(key)
        }
        if operation == .beginContent {
            guard G04DocumentContentPart(rawValue: try text("part", default: "document", maxBytes: 32)) != nil else {
                throw Failure.invalidField("part")
            }
        }
        if operation == .replace { _ = try text("replacement", maxBytes: 24 * 1024) }
        if operation == .edit {
            _ = try text("replacement", maxBytes: 24 * 1024)
            if object["selectionLocation"] != nil || object["selectionLength"] != nil {
                let location = try integer("selectionLocation", maximum: G04WorkspaceDocumentSession.maximumDocumentBytes)
                let length = try integer("selectionLength", maximum: G04WorkspaceDocumentSession.maximumDocumentBytes)
                guard length <= G04WorkspaceDocumentSession.maximumDocumentBytes - location else { throw Failure.invalidField("selectionLength") }
            }
        }
        if operation == .beginProjectionRecovery {
            _ = try identifier("recoveryID")
            _ = try text("sourcePath")
        }
        if operation == .beginEditUpload || operation == .beginProjectionRecovery {
            _ = try integer("byteCount", maximum: G04WorkspaceDocumentSession.maximumDocumentBytes)
            _ = try digest("sha256")
        }
        if operation == .appendEditUpload || operation == .appendProjectionRecovery {
            _ = try integer("offset", maximum: G04WorkspaceDocumentSession.maximumDocumentBytes)
            let base64 = try text("bytes", maxBytes: 32 * 1024)
            guard let data = Data(base64Encoded: base64), data.count <= G04WorkspaceDocumentSession.maximumChunkBytes else {
                throw Failure.invalidField("bytes")
            }
        }
        if operation == .readContent || operation == .queryContent {
            _ = try integer("offset", maximum: 17 * 1024 * 1024)
            guard try integer("limit", maximum: G04WorkspaceDocumentSession.maximumChunkBytes) > 0 else {
                throw Failure.invalidField("limit")
            }
        }
        if operation == .resolveConflictUsingDraft { _ = try digest("reviewedSHA256") }
        if object["content"] != nil { _ = try text("content", maxBytes: 24 * 1024) }
        if object["query"] != nil { _ = try text("query", maxBytes: 8192) }
        if object["pageToken"] != nil { _ = try optionalText("pageToken", maxBytes: 8192) }
    }
}

/// D14 (Main decision 2026-10-24): the THIRD closed conversationLifecycle
/// command payload. `workspace.activate` carries ONLY the actual native
/// epoch decimal string — it never claims a workspace, root, run or
/// environment. The real root-owned facade validates the durable ordinary
/// conversation under the ORIGINAL owned-operation lease/fences and uses
/// the ORIGINAL `SQLiteWorkspaceStore.ensureWorkspace` only when the task
/// is TRULY unbound; an existing association (including a later managed/
/// source layer) is returned untouched, never re-pointed, never guessed.
/// `conversation.get` stays a pure read and never writes here.
struct G04WorkspaceActivationRequest: Sendable {
    typealias Value = SettingsDomainV1.JSONValue
    enum Failure: Error, Sendable { case invalidPayload, invalidField(String) }

    let nativeEpoch: UInt64

    init(payload: Value?) throws {
        guard case .object(let object) = payload,
              Set(object.keys) == ["nativeEpoch"] else { throw Failure.invalidPayload }
        guard case .string(let rawEpoch)? = object["nativeEpoch"],
              let epoch = UInt64(rawEpoch), epoch > 0, String(epoch) == rawEpoch
        else { throw Failure.invalidField("nativeEpoch") }
        self.nativeEpoch = epoch
    }
}
