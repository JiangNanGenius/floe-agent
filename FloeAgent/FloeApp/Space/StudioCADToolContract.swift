// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeTools
import FloeCAD

struct StudioCADRenameCommand: Codable {
    struct Args: Codable { let id: UUID; let name: String }
    enum Operation: String, Codable { case body = "scene.object.rename", sketch = "sketch.rename" }
    let op: Operation
    let args: Args
}
struct StudioCADSaveCommand: Encodable {
    struct Args: Codable {}
    let op = "document.save"
    let args = Args()
}
@MainActor enum StudioCADToolContract {
    struct Identity {
        let revision: Int, changeCount: Int, sha256: String
        init(snapshot: Data) throws {
            guard let value = try JSONSerialization.jsonObject(with: snapshot) as? [String: Any],
                  let native = value["nativeCAD"] as? [String: Any], let revision = native["savedRevision"] as? Int,
                  let changeCount = native["changeCount"] as? Int, let hash = native["contentSHA256"] as? String else { throw PersonalContentError.changedDocument }
            self.revision = revision; self.changeCount = changeCount; sha256 = hash
        }
        @MainActor func matches(_ document: FloeCADDocument) -> Bool {
            revision == document.revision && changeCount == document.exchangeChangeCount && sha256 == document.contentSHA256
        }
    }
    // The native parser owns availability. Keep the managed project route in
    // step with its actual executable operations rather than a second list.
    static var geometryOperations: Set<String> { Set(FloeCADDocument.nativeOperationNames) }
    static let hostOperations = ["scene.object.rename", "sketch.rename", "document.save"]
    static func nativeState(_ document: FloeCADDocument, context: ToolContext) throws -> [String: Any] {
        var sketches: [[String: Any]] = [], bytes = 0, offset = 0
        while true {
            try context.cancellation.throwIfCancelled(); try Task.checkCancellation()
            let reply = document.nativeQueryJSON(["scope": "sketches", "offset": offset, "limit": 200])
            guard reply.isOK, let page = try JSONSerialization.jsonObject(with: reply.payload) as? [String: Any],
                  let rows = page["rows"] as? [[String: Any]], let total = page["total"] as? Int else {
                throw FloeError.validationFailed("The current native sketch query could not be read.")
            }
            bytes += reply.payload.count
            guard total <= 4_096, bytes <= 24 * 1_024 * 1_024 else { throw FloeError.validationFailed("This CAD work exceeds the bounded sketch inspection budget.") }
            sketches += rows; offset += rows.count
            if offset >= total { break }
            guard !rows.isEmpty else { throw PersonalContentError.changedDocument }
        }
        return ["route": "studio.read / studio.edit with this projectID", "hostOperations": hostOperations,
            "geometryOperations": geometryOperations.sorted(),
            "nativeOperations": StudioCADNativeOperations.operationNames,
            "nativeServices": try StudioCADNativeOperations.state(document, context: context),
            "unavailableOperations": FloeCADDocument.unavailableNativeOperations,
            "savedRevision": document.revision, "changeCount": document.exchangeChangeCount,
            "contentSHA256": document.contentSHA256, "hasUnsavedChanges": document.hasUnsavedChanges,
            "sketches": sketches, "sketchesComplete": true]
    }
    @discardableResult static func applyAndSave(_ data: Data, to document: FloeCADDocument, expected: Identity, context: ToolContext,
                             validateSource: @MainActor () async throws -> Void) async throws -> Data? {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["op", "args"]), let op = object["op"] as? String else {
            throw FloeError.validationFailed("Use one native CAD {op,args} object from studio.read; no filename or workspace path is needed.")
        }
        guard expected.matches(document) else { throw PersonalContentError.changedDocument }
        try await validateSource()
        guard expected.matches(document) else { throw PersonalContentError.changedDocument }
        try context.cancellation.throwIfCancelled(); try Task.checkCancellation()
        var owned: CADOwnedCommandRef?
        var nativeCheckpoint: CADEditCheckpoint?
        var nativeChangeCount: Int?
        var nativeReply: [String: Any]?
        do {
            if StudioCADNativeOperations.contains(op) {
                guard let args = object["args"] as? [String: Any] else {
                    throw FloeError.validationFailed("A native service operation requires one typed args object from studio.read.")
                }
                let request = try StudioCADNativeOperations.resolve(op: op, args: args)
                let checkpoint = document.captureEditCheckpoint()
                let reply = try await StudioCADNativeOperations.execute(request, document: document)
                guard document.revision == expected.revision, document.contentSHA256 == expected.sha256 else {
                    throw PersonalContentError.changedDocument
                }
                if reply["mutated"] as? Bool == true {
                    guard document.exchangeChangeCount != expected.changeCount else {
                        throw FloeError.validationFailed("The native service reported an edit without an undoable document change; it was not reported as saved.")
                    }
                    nativeCheckpoint = checkpoint; nativeChangeCount = document.exchangeChangeCount
                } else {
                    guard document.exchangeChangeCount == expected.changeCount else { throw PersonalContentError.changedDocument }
                    try context.cancellation.throwIfCancelled(); try Task.checkCancellation()
                    try await validateSource()
                    guard expected.matches(document) else { throw PersonalContentError.changedDocument }
                    // A truthful no-change result is never silently saved.
                    var result = reply; result["saved"] = false
                    result["revision"] = document.revision; result["content_sha256"] = document.contentSHA256
                    let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
                    guard data.count <= 64 * 1_024 else { throw FloeError.validationFailed("The native no-change result exceeds the 64KiB result budget.") }
                    return data
                }
                guard try JSONSerialization.data(withJSONObject: reply).count <= 64 * 1_024 else {
                    throw FloeError.validationFailed("The actual native operation receipt exceeds the 64KiB result budget. Use a smaller operation; this edit was not saved.")
                }
                nativeReply = reply
            } else if StudioCADRenameCommand.Operation(rawValue: op) != nil {
                guard let args = object["args"] as? [String: Any], Set(args.keys) == ["id", "name"] else {
                    throw FloeError.validationFailed("Rename requires exactly args {id:existingNativeUUID,name:string}.")
                }
                let command = try JSONDecoder().decode(StudioCADRenameCommand.self, from: data)
                let prior = document.pendingOwnedCommand
                let result = document.renameExistingItem(kind: command.op == .body ? .body : .sketch,
                    id: command.args.id, name: command.args.name, expectedChangeCount: document.exchangeChangeCount)
                guard result.isOK else { throw FloeError.validationFailed(result.message ?? "Native item rename failed") }
                if let reference = document.pendingOwnedCommand, reference != prior, reference.tag == "native-item-rename" { owned = reference }
            } else if op == "document.save" {
                guard let args = object["args"] as? [String: Any], args.isEmpty else {
                    throw FloeError.validationFailed("document.save uses empty args {}; it saves this current native work.")
                }
            } else {
                guard geometryOperations.contains(op) else { throw FloeError.validationFailed("Use nativeCAD.geometryOperations or nativeCAD.nativeOperations from studio.read, scene.object.rename, sketch.rename or document.save; unknown operations are not forwarded.") }
                let outcome = await document.executeJSONAsync(data)
                guard outcome.isOK else { throw FloeError.validationFailed(outcome.message ?? "CAD edit failed") }
            }
            let editedChangeCount = document.exchangeChangeCount
            try await validateSource()
            guard document.exchangeChangeCount == editedChangeCount else { throw PersonalContentError.changedDocument }
            try context.cancellation.throwIfCancelled(); try Task.checkCancellation()
            let saved = await document.save()
            guard saved.succeeded else { throw FloeError.validationFailed(saved.error ?? "The native CAD save did not complete.") }
            try await validateSource()
            guard document.exchangeChangeCount == editedChangeCount else { throw PersonalContentError.changedDocument }
            if var reply = nativeReply {
                reply["saved"] = true; reply["revision"] = saved.revision
                reply["content_sha256"] = saved.contentSHA256; reply["change_count"] = editedChangeCount
                return try JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])
            }
            return nil
        } catch {
            // Only this newest uncommitted rename can be reverted. A later
            // UI edit or a successful competing save remains authoritative.
            if let owned { _ = document.rollbackOwnedCommand(owned) }
            if let nativeCheckpoint, let nativeChangeCount, !document.isClosed,
               document.exchangeChangeCount == nativeChangeCount,
               document.revision == expected.revision, document.contentSHA256 == expected.sha256 {
                document.restoreEditCheckpoint(nativeCheckpoint)
            }
            throw error
        }
    }
}
#endif
