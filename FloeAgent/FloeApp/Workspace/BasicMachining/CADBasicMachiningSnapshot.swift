// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCAD
import FloeCore
import FloeTools
import FloeWorkbench

@MainActor
enum CADBasicMachiningSnapshot {
    static func capture(documentURL:URL,bodyID:UUID,destination:URL,cancellation:CancellationToken) async throws -> CADBasicMachiningSource {
        let document=try await FloeCAD3DBridge.shared.openDocument(at:documentURL)
        guard !document.isReadOnly,!document.isClosed else { throw FloeError.validationFailed("Save an editable CAD part before starting machining.") }
        try cancellation.throwIfCancelled()
        // Explicit Save commits project metadata even for a clean document.
        // Snapshotting must reuse that saved identity; only pending edits need
        // the existing revision-guarded save path (the same flush-if-dirty rule
        // used by native proposal preparation).
        if document.hasUnsavedChanges {
            let save=await document.save()
            guard save.error==nil else { throw FloeError.validationFailed(save.error ?? "The CAD document changed during save.") }
        }
        try cancellation.throwIfCancelled()
        guard !document.isClosed,!document.hasUnsavedChanges else { throw FloeError.validationFailed("The CAD document changed during save.") }
        let expected=CADBasicMachiningSource(documentURL:documentURL,bodyID:bodyID,revision:document.revision,
            contentSHA256:document.contentSHA256,modelSHA256:document.modelSHA256,members:[:])
        guard !expected.modelSHA256.isEmpty else { throw FloeError.validationFailed("The native part has no complete saved model identity.") }
        guard let stored=await FloeCADDocument.storedIdentity(at:documentURL),stored.revision==expected.revision,
              stored.contentSHA256==expected.contentSHA256,stored.modelSHA256==expected.modelSHA256 else {
            throw FloeError.validationFailed("The saved native part identity could not be verified.")
        }
        // storedIdentity awaited off-main I/O; reject an intervening live edit
        // or owner release before beginning the member copy.
        try requireLiveCurrent(document,source:expected)
        let result=try await Task.detached(priority:.userInitiated) { () throws -> CADBasicMachiningSource in
            let fm=FileManager.default
            func member(_ relative:String)throws->URL {
                guard !relative.hasPrefix("/"),!relative.split(separator:"/").contains("..") else { throw FloeError.validationFailed("Invalid native part member") }
                let file=documentURL.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
                guard file.path.hasPrefix(documentURL.standardizedFileURL.resolvingSymlinksInPath().path+"/") else {throw FloeError.validationFailed("Native part member escaped its package")}
                return file
            }
            let modelData=try Data(contentsOf:member("document.json"))
            guard let model=try JSONSerialization.jsonObject(with:modelData) as? [String:Any],
                  let bodies=model["bodies"] as? [[String:Any]],let body=bodies.first(where:{($0["bodyID"] as? String)?.lowercased()==bodyID.uuidString.lowercased()}),
                  let mesh=body["meshBlob"] as? String,let brep=body["brepBlob"] as? String,
                  let meshHash=body["meshSHA256"] as? String,let brepHash=body["brepSHA256"] as? String,
                  let rawTransform=body["transform"] as? String,let transformData=Data(base64Encoded:rawTransform),
                  let transform=try JSONSerialization.jsonObject(with:transformData) as? [String:Any],
                  transform["translation"] as? [Double]==[0,0,0],transform["rotation"] as? [Double]==[0,0,0,1],
                  (transform["scale"] as? Double)==1 else {
                throw FloeError.validationFailed("Basic machining requires one saved BRep part with identity placement and a mesh cache.")
            }
            let originals=["document.json","manifest.json",mesh,brep]
            try fm.createDirectory(at:destination,withIntermediateDirectories:true)
            var result=expected
            for name in originals {
                let source=try member(name);let attrs=try fm.attributesOfItem(atPath:source.path)
                guard ((attrs[.size] as? NSNumber)?.intValue ?? Int.max) <= 16_000_000 else {throw FloeError.validationFailed("Native snapshot member is too large")}
                let data=try Data(contentsOf:source),hash=FloeDigest.sha256Hex(data)
                if name==mesh && hash != meshHash {throw FloeError.validationFailed("Mesh cache digest mismatch")}
                if name==brep && hash != brepHash {throw FloeError.validationFailed("BRep cache digest mismatch")}
                let target=destination.appendingPathComponent(name);try fm.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
                try data.write(to:target,options:.atomic);result.members[name]=hash
            }
            return result
        }.value
        try cancellation.throwIfCancelled()
        let after=await FloeCADDocument.storedIdentity(at:documentURL)
        try requireLiveCurrent(document,source:expected)
        guard after?.revision==expected.revision,after?.contentSHA256==expected.contentSHA256,
              after?.modelSHA256==expected.modelSHA256 else {
            throw FloeError.validationFailed("The native part changed while its snapshot was being captured.")
        }
        return result
    }
    @discardableResult
    static func requireCurrent(_ source:CADBasicMachiningSource,
                               allowMetadataOnlyReopen:Bool=false) async throws -> FloeCADDocument {
        let document=try await FloeCAD3DBridge.shared.openDocument(at:source.documentURL)
        let disk=await FloeCADDocument.storedIdentity(at:source.documentURL)
        if allowMetadataOnlyReopen {
            // A completed result may be read after the owner closes/saves the
            // unchanged model. Keep its original source receipt; this never
            // authorizes collecting, resuming or committing an in-flight job.
            guard !document.isClosed,!document.hasUnsavedChanges,
                  document.revision>=source.revision,document.modelSHA256==source.modelSHA256,
                  disk?.revision==document.revision,disk?.contentSHA256==document.contentSHA256,
                  disk?.modelSHA256==source.modelSHA256 else {
                throw FloeError.validationFailed("The source part has changed. Keep this result as history and run a new simulation.")
            }
            return document
        }
        try requireLiveCurrent(document,source:source)
        guard disk?.revision==source.revision,disk?.contentSHA256==source.contentSHA256,disk?.modelSHA256==source.modelSHA256 else {
            throw FloeError.validationFailed("The source part has changed. Keep this result as history and run a new simulation.")
        }
        return document
    }
    /// Synchronous final MainActor fence immediately before archive/state commit.
    static func requireLiveCurrent(_ document:FloeCADDocument,source:CADBasicMachiningSource)throws {
        guard !document.isClosed,!document.hasUnsavedChanges,document.revision==source.revision,
              document.modelSHA256==source.modelSHA256,document.contentSHA256==source.contentSHA256 else {
            throw FloeError.validationFailed("The source part has changed. Keep this result as history and run a new simulation.")
        }
    }
}
