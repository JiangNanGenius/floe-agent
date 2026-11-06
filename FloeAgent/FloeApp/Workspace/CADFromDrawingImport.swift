// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCAD
import FloeWorkspace

@MainActor
enum CADFromDrawingImport {
    /// A separately named native working copy. Original drawing/draft bytes
    /// remain source evidence inside the sketch/building after user applies.
    static func open(_ transfer:CADSketchTransferEnvelope,sourcePath:String,
                     service:WorkspaceFileService) async throws -> (document:FloeCADDocument,path:String) {
        try transfer.validate();try Task.checkCancellation()
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let identity=CADSketchTransferEnvelope.digest(try encoder.encode(transfer))
        let raw=((sourcePath as NSString).lastPathComponent as NSString).deletingPathExtension
        let stem=String(raw.prefix(32)).replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"\\",with:"_")
        let parent=(sourcePath as NSString).deletingLastPathComponent
        let filename="\(stem)-\(transfer.purpose.rawValue)-\(identity).floecad"
        let path=parent.isEmpty ? filename:(parent as NSString).appendingPathComponent(filename)
        let destination=try service.guardResolver.resolve(path)
        if !FileManager.default.fileExists(atPath:destination.path) {
            let stageName=".floe-drawing-import-\(UUID().uuidString).floecad"
            let stagePath=parent.isEmpty ? stageName:(parent as NSString).appendingPathComponent(stageName)
            let stage=try service.guardResolver.resolve(stagePath,for:.createNew)
            let temporary=try await FloeCADDocument.create(at:stage,name:stem)
            defer { temporary.close();try? FileManager.default.removeItem(at:stage) }
            let saved=await temporary.save()
            guard saved.succeeded else { throw CADDocumentError(code:"save_failed",message:saved.error ?? "The model could not be saved.") }
            try Task.checkCancellation();temporary.close()
            let publication=try service.guardResolver.resolve(path,for:.createNew)
            try FileManager.default.moveItem(at:service.guardResolver.resolve(stagePath),to:publication)
        }
        try Task.checkCancellation()
        let document=try await FloeCAD3DBridge.shared.openDocument(at:destination)
        do {
            try Task.checkCancellation()
            CADDrawingModelBridge.configure(document)
            return (document,path)
        } catch {
            await FloeCAD3DBridge.shared.releaseDocument(at: destination, expected: document)
            throw error
        }
    }
}
