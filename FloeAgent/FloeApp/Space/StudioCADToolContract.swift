// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import CoreFoundation
import CryptoKit
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
    typealias ReadQuery = StudioCADNativeOperations.ReadQuery
    /// A read projection (sketch/entity page, measurement or viewport) is not
    /// a document edit. Bind the token only to the same real original identity
    /// that guards native saves, independently of the requested projection.
    static func revisionToken(revision: Int, changeCount: Int, sha256: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [
            "savedRevision": revision, "changeCount": changeCount, "contentSHA256": sha256
        ], options: [.sortedKeys])
        return StudioToolOutput.hash(data)
    }
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
    static func geometryOperations(for kind: PersonalContentKind) -> [String] {
        StudioCADNativeOperations.geometryOperations(for: kind)
    }
    static let hostOperations = ["scene.object.rename", "sketch.rename", "document.save"]
    static func nativeState(_ document: FloeCADDocument, kind: PersonalContentKind,
                            query: ReadQuery = .init(), context: ToolContext) throws -> [String: Any] {
        var native = try StudioCADNativeOperations.state(document, kind: kind, query: query, context: context)
        let sketches = (native["sketchQuery"] as? [String: Any])?["sketches"] as? [[String: Any]] ?? []
        let complete = (native["sketchQuery"] as? [String: Any])?["sketchesComplete"] as? Bool ?? false
        native["route"] = "studio.read / studio.edit with this SAME projectID; use cad paging fields from sketchQuery/entities/constraints"
        native["hostOperations"] = hostOperations
        native["geometryOperations"] = geometryOperations(for: kind)
        native["nativeOperations"] = StudioCADNativeOperations.operationNames(for: kind)
        native["threeDOnlyGeometryOperations"] = StudioCADNativeOperations.threeDOnlyOperations(for: kind)
        native["unavailableOperations"] = kind == .cad2D ? [] : FloeCADDocument.unavailableNativeOperations
        native["savedRevision"] = document.revision
        native["sketches"] = sketches
        native["sketchesComplete"] = complete
        native["sketchQueryComplete"] = complete
        native["note"] = kind == .cad2D
            ? "This is a standalone 2D original. 3D feature/mesh operations are listed only in threeDOnlyGeometryOperations and are refused."
            : "This is a 3D original. Sketch edits still operate on explicit sketch ids; entering a sketch is not a separate 2D original."
        let encoded = try JSONSerialization.data(withJSONObject: native)
        guard encoded.count <= 224 * 1_024 else {
            throw FloeError.validationFailed("This bounded CAD read exceeds 224KiB. Request a smaller cad sketch/entity/constraint page or measure; nothing was changed.")
        }
        return native
    }

    @discardableResult static func applyAndSave(_ data: Data, to document: FloeCADDocument,
                             expected: Identity, kind: PersonalContentKind, context: ToolContext,
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
            if op == "document.importDrawing" {
                guard kind == .cad2D else {
                    throw FloeError.validationFailed("document.importDrawing imports a DXF/DWG drawing into a standalone 2D sketch. "
                        + "This is a 3D original; import model geometry through the existing 3D editor or PersonalCADImport, not into a 2D sketch.")
                }
                guard let args = object["args"] as? [String: Any] else {
                    throw FloeError.validationFailed("document.importDrawing requires args {sketchID, source:{workspacePath,expectedSHA256?}, placement?}.")
                }
                let checkpoint = document.captureEditCheckpoint()
                let receipt = try await importDrawing(args, into: document, context: context)
                guard document.revision == expected.revision, document.contentSHA256 == expected.sha256 else {
                    throw PersonalContentError.changedDocument
                }
                guard document.exchangeChangeCount != expected.changeCount else {
                    throw FloeError.validationFailed("The drawing import reported no undoable document change; it was not reported as saved.")
                }
                nativeCheckpoint = checkpoint; nativeChangeCount = document.exchangeChangeCount
                var reply = receipt
                reply["ok"] = true; reply["mutated"] = true; reply["operation"] = op
                nativeReply = reply
            } else if StudioCADNativeOperations.contains(op, kind: kind) {
                guard let args = object["args"] as? [String: Any] else {
                    throw FloeError.validationFailed("A native service operation requires one typed args object from studio.read.")
                }
                let request = try StudioCADNativeOperations.resolve(op: op, args: args, kind: kind)
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
                let offered = geometryOperations(for: kind)
                guard offered.contains(op) else {
                    if kind == .cad2D, StudioCADNativeOperations.threeDOnlyOperations(for: kind).contains(op)
                        || StudioCADNativeOperations.operationNames(for: .cad3D).contains(op) {
                        throw FloeError.validationFailed("'\(op)' is a 3D operation. This standalone 2D original offers only "
                            + offered.joined(separator: ", ") + " plus its nativeOperations; no 3D geometry was changed.")
                    }
                    throw FloeError.validationFailed("Use nativeCAD.geometryOperations or nativeCAD.nativeOperations from studio.read, "
                        + "scene.object.rename, sketch.rename or document.save; unknown operations are not forwarded.")
                }
                let checkpoint = document.captureEditCheckpoint()
                let outcome = await document.executeJSONAsync(data)
                guard outcome.isOK else { throw FloeError.validationFailed(outcome.message ?? "CAD edit failed") }
                nativeCheckpoint = checkpoint
                nativeChangeCount = document.exchangeChangeCount
                // Preserve the actual native IDs/result. The receipt is
                // marked saved only below, after the real save and fences.
                guard outcome.payload.count <= 64 * 1_024 else {
                    throw FloeError.validationFailed("The actual native operation receipt exceeds the 64KiB result budget; this edit was not saved.")
                }
                guard !outcome.payload.isEmpty,
                      let reply = try JSONSerialization.jsonObject(with: outcome.payload) as? [String: Any] else {
                    throw FloeError.validationFailed("The native CAD operation did not return a structured receipt; this edit was not saved.")
                }
                nativeReply = reply
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

    private static func importDrawing(_ args: [String: Any], into document: FloeCADDocument,
                                      context: ToolContext) async throws -> [String: Any] {
        guard Set(args.keys).isSubset(of: ["sketchID", "sketch_id", "source", "placement", "format"]) else {
            throw FloeError.validationFailed("document.importDrawing accepts exactly sketchID, source, placement and optional format.")
        }
        guard let rawSketch = args["sketchID"] as? String ?? args["sketch_id"] as? String,
              let sketchID = UUID(uuidString: rawSketch) else {
            throw FloeError.validationFailed("document.importDrawing needs sketchID (the actual sketch id from studio.read).")
        }
        guard let source = args["source"] as? [String: Any],
              Set(source.keys).isSubset(of: ["workspacePath", "expectedSHA256"]),
              let path = source["workspacePath"] as? String else {
            throw FloeError.validationFailed("source requires workspacePath and optional expectedSHA256 from this saved task; host paths are not accepted.")
        }
        let url = try StudioMediaSourceContracts.workspaceURL(path, context: context)
        let format = url.pathExtension.lowercased()
        guard ["dxf", "dwg"].contains(format) else {
            throw FloeError.validationFailed("A standalone 2D sketch imports DXF or DWG drawings. "
                + "STEP/STL/OBJ/IGES/PNG/PDF are not imported into a 2D sketch; use the existing 3D or drawing editor route.")
        }
        if let rawFormat = args["format"] as? String, rawFormat.lowercased() != format {
            throw FloeError.validationFailed("The declared format '\(rawFormat)' does not match the source extension '.\(format)'.")
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= 10 * 1_024 * 1_024 else {
            throw FloeError.validationFailed("The drawing source must be an original regular task file no larger than 10 MB.")
        }
        let cancellation = context.cancellation
        let bytes = try await Task.detached(priority: .userInitiated) {
            try cancellation.throwIfCancelled()
            let data = try Data(contentsOf: url)
            try Task.checkCancellation()
            return data
        }.value
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        if let expected = source["expectedSHA256"] as? String, expected != digest {
            throw FloeError.validationFailed("The drawing source changed before import; nothing was imported.")
        }
        guard let decoder = document.drawingSketchDecoder else {
            throw FloeError.validationFailed("The DXF/DWG drawing decoder is unavailable in this host; nothing was imported.")
        }
        let envelope = try await decoder(bytes, url.lastPathComponent)
        guard envelope.sourceSHA256 == digest else {
            throw FloeError.validationFailed("The decoded drawing source identity does not match its bytes; nothing was imported.")
        }
        let placement = try placement(from: args["placement"], snapshot: envelope.snapshot)
        let receipt = try CADSketchEditService(document: document).importDrawingSketch(
            envelope, into: sketchID, placement: placement)
        var reply: [String: Any] = [
            "action": "document.importDrawing",
            "sketchID": receipt.sketchID.uuidString,
            "entityIDs": receipt.entityIDs.map(\.uuidString),
            "sourceSHA256": digest,
            "format": format,
            "sourceBytes": bytes.count,
            "sourceWorkspacePath": path,
            "change_count": receipt.editRevision,
        ]
        if !envelope.snapshot.omissions.isEmpty {
            reply["acceptedOmissions"] = envelope.snapshot.omissions.count
        }
        return reply
    }

    private static func placement(from raw: Any?, snapshot: CADSketchTransferSnapshot) throws -> CADSketchTransferPlacement {
        guard let raw else {
            if snapshot.unitScaleMM == nil {
                throw FloeError.validationFailed("This drawing has no declared units. Supply placement.unitScaleMM "
                    + "(millimetres per source unit) and review any omissions first.")
            }
            guard snapshot.omissions.isEmpty else {
                throw FloeError.validationFailed("This drawing has \(snapshot.omissions.count) omitted source entities. "
                    + "Supply placement.acceptOmissions:true only after reviewing them.")
            }
            return CADSketchTransferPlacement(target: .selected)
        }
        guard let object = raw as? [String: Any],
              Set(object.keys).isSubset(of: ["sourceAnchor", "offsetMM", "rotationDegrees", "unitScaleMM", "acceptOmissions"]) else {
            throw FloeError.validationFailed("placement accepts sourceAnchor, offsetMM, rotationDegrees, unitScaleMM and acceptOmissions only.")
        }
        func pair(_ key: String) throws -> [Double] {
            guard let value = object[key] else { return [0, 0] }
            guard let rows = value as? [NSNumber], rows.count == 2,
                  rows.allSatisfy({ $0.doubleValue.isFinite && abs($0.doubleValue) <= 1e12 }) else {
                throw FloeError.validationFailed("placement.\(key) must be two finite [x,y] numbers in millimetres.")
            }
            return rows.map(\.doubleValue)
        }
        let rotation: Double
        if let value = object["rotationDegrees"] {
            guard let number = value as? NSNumber, number.doubleValue.isFinite,
                  abs(number.doubleValue) <= 1e12 else {
                throw FloeError.validationFailed("placement.rotationDegrees must be a finite number.")
            }
            rotation = number.doubleValue
        } else { rotation = 0 }
        let unitScale: Double?
        if let value = object["unitScaleMM"] {
            guard let number = value as? NSNumber, number.doubleValue.isFinite,
                  number.doubleValue > 0, number.doubleValue <= 1e12 else {
                throw FloeError.validationFailed("placement.unitScaleMM must be a finite positive millimetre-per-unit number.")
            }
            unitScale = number.doubleValue
        } else { unitScale = nil }
        let accept: Bool
        if let value = object["acceptOmissions"] {
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                throw FloeError.validationFailed("placement.acceptOmissions must be true or false.")
            }
            accept = number.boolValue
        } else { accept = false }
        if !snapshot.omissions.isEmpty, !accept {
            throw FloeError.validationFailed("This drawing has \(snapshot.omissions.count) omitted source entities. "
                + "Supply placement.acceptOmissions:true only after reviewing them.")
        }
        if snapshot.unitScaleMM == nil, unitScale == nil {
            throw FloeError.validationFailed("This drawing has no declared units. Supply placement.unitScaleMM.")
        }
        return CADSketchTransferPlacement(target: .selected,
            sourceAnchor: try pair("sourceAnchor"), offsetMM: try pair("offsetMM"),
            rotationDegrees: rotation, unitScaleMM: unitScale, acceptOmissions: accept)
    }
}
#endif
