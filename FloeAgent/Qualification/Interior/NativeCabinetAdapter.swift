// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCAD
import FloeInteriorCore

enum NativeInteriorProbeError: Error {
    case existingOutput, command(String), missingBody, save(String)
}

/// Research adapter uses only the public CAD facade. It creates a new draft;
/// it never mutates a user's existing project or reaches into the kernel.
@MainActor final class NativeCabinetDraft {
    let document:FloeCADDocument
    let assembly:CabinetAssembly
    let directory:URL
    let bodyIDs:[String:String]

    private init(document:FloeCADDocument,assembly:CabinetAssembly,directory:URL,bodyIDs:[String:String]) {
        self.document=document; self.assembly=assembly; self.directory=directory; self.bodyIDs=bodyIDs
    }

    static func create(assembly:CabinetAssembly,directory:URL) async throws -> NativeCabinetDraft {
        let plans=try CabinetDerivations.nativeDrafts(assembly)
        guard !FileManager.default.fileExists(atPath:directory.path) else { throw NativeInteriorProbeError.existingOutput }
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let document=try await FloeCADDocument.create(at:directory.appendingPathComponent("Document.floecad"),name:assembly.recipe.name)
        var mapping:[String:String]=[:]
        do {
            for plan in plans {
                let sketch=try await execute(document,"sketch.create",["name":plan.panelID])
                guard let sketchID=sketch["sketchID"] as? String else { throw NativeInteriorProbeError.missingBody }
                _=try await execute(document,"sketch.addEntities",[
                    "sketchID":sketchID,"entities":[["kind":"rect","min":plan.rectangleMin,"max":plan.rectangleMax]]
                ])
                let center=zip(plan.rectangleMin,plan.rectangleMax).map{($0+$1)/2}
                let result=try await execute(document,"feature.extrude",[
                    "sketchID":sketchID,"seedPoint":center,"distance":plan.extrusionMM
                ])
                guard var bodyID=(result["producedBodyIDs"] as? [String])?.first ?? (result["changedBodyIDs"] as? [String])?.first else {
                    throw NativeInteriorProbeError.missingBody
                }
                if plan.translationXYZ.contains(where:{$0 != 0}) {
                    let moved=try await execute(document,"feature.transform",["bodyID":bodyID,"translation":plan.translationXYZ])
                    bodyID=(moved["producedBodyIDs"] as? [String])?.first ?? (moved["changedBodyIDs"] as? [String])?.first ?? bodyID
                }
                mapping[plan.panelID]=bodyID
            }
            let value=NativeCabinetDraft(document:document,assembly:assembly,directory:directory,bodyIDs:mapping)
            try await value.save()
            return value
        } catch {
            document.close()
            throw error // The new task-owned partial draft is retained as failure evidence.
        }
    }

    private static func execute(_ document:FloeCADDocument,_ op:String,_ args:[String:Any]) async throws -> [String:Any] {
        let result=await document.executeAsync(["op":op,"args":args])
        guard result.isOK else { throw NativeInteriorProbeError.command("\(op): \(result.errorCode ?? "") \(result.message ?? "")") }
        return try JSONSerialization.jsonObject(with:result.payload) as? [String:Any] ?? [:]
    }

    static func drawingArguments(frame:InteriorDrawingFrame) -> [String:Any] {
        var args:[String:Any] = [
            "viewNormal":frame.nativeNormal.values,
            "viewUp":frame.nativeHorizontalAxis.values
        ]
        if frame.view == .sideSection {
            args["sectionOrigin"] = frame.nativeOriginMM.values
            args["sectionNormal"] = frame.nativeNormal.values
        }
        return args
    }

    func save() async throws {
        let saved=await document.save()
        guard saved.succeeded else { throw NativeInteriorProbeError.save(saved.error ?? "unknown") }
        try InteriorFingerprint.data(assembly).write(to:directory.appendingPathComponent("cabinet-source.json"),options:.atomic)
        let receipt:[String:Any]=[
            "scope":"component research, not a Floe Space project",
            "geometryFingerprint":assembly.geometryFingerprint,
            "scheduleFingerprint":assembly.scheduleFingerprint,
            "nativeRevision":saved.revision,"nativeContentSHA256":saved.contentSHA256,
            "nativeModelSHA256":saved.modelSHA256,"bodyIDs":bodyIDs,
            "manufacturingVerified":false
        ]
        try JSONSerialization.data(withJSONObject:receipt,options:[.sortedKeys,.prettyPrinted])
            .write(to:directory.appendingPathComponent("native-bindings.json"),options:.atomic)
    }
}
