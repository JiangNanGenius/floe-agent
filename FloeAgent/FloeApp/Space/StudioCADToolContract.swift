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
    static let geometryOperations: Set<String> = ["sketch.create", "sketch.addEntities", "sketch.addText", "feature.extrude", "feature.revolve", "feature.hole", "feature.pattern", "feature.mirror", "feature.transform"]
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
            "savedRevision": document.revision, "changeCount": document.exchangeChangeCount,
            "contentSHA256": document.contentSHA256, "hasUnsavedChanges": document.hasUnsavedChanges,
            "sketches": sketches, "sketchesComplete": true]
    }
    static func applyAndSave(_ data: Data, to document: FloeCADDocument, expected: Identity, context: ToolContext,
                             validateSource: @MainActor () async throws -> Void) async throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["op", "args"]), let op = object["op"] as? String else {
            throw FloeError.validationFailed("Use one native CAD {op,args} object from studio.read; no filename or workspace path is needed.")
        }
        guard expected.matches(document) else { throw PersonalContentError.changedDocument }
        try await validateSource()
        guard expected.matches(document) else { throw PersonalContentError.changedDocument }
        try context.cancellation.throwIfCancelled(); try Task.checkCancellation()
        var owned: CADOwnedCommandRef?
        do {
            if StudioCADRenameCommand.Operation(rawValue: op) != nil {
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
                guard geometryOperations.contains(op) else { throw FloeError.validationFailed("Use supported native geometry, scene.object.rename, sketch.rename or document.save from studio.read.") }
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
        } catch {
            // Only this newest uncommitted rename can be reverted. A later
            // UI edit or a successful competing save remains authoritative.
            if let owned { _ = document.rollbackOwnedCommand(owned) }
            throw error
        }
    }
}
#endif
