// SPDX-License-Identifier: MPL-2.0
#if DEBUG
import Foundation
import simd

/// Real input geometry only. No stroke, bake, undo or post-launch authoring
/// callback is executed here; the actual controls own the tested workflow.
@MainActor public enum CADTexturePaintUIFixture {
    public static func open(at url:URL,reset:Bool)async throws->FloeCADDocument {
        if reset,FileManager.default.fileExists(atPath:url.path) { try FileManager.default.removeItem(at:url) }
        let document:FloeCADDocument
        if FileManager.default.fileExists(atPath:url.path) { document=try await FloeCADDocument.open(at:url) }
        else {
            document=try await FloeCADDocument.create(at:url,name:"Texture paint and bake")
            func plane(_ lo:Float,_ hi:Float)->RenderMesh {
                RenderMesh(positions:[SIMD3(lo,lo,0),SIMD3(hi,lo,0),SIMD3(hi,hi,0),SIMD3(lo,hi,0)],
                    normals:[SIMD3<Float>](repeating:SIMD3(0,0,1),count:4),indices:[0,1,2,0,2,3],
                    texcoords:[SIMD2(0,0),SIMD2(1,0),SIMD2(1,1),SIMD2(0,1)])
            }
            var target=Body(id:BodyID(),name:"Paint plane",transform:.identity,primitive:nil,render:plane(0,10),revision:0)
            target.material=BodyMaterialSpec(baseColor:SIMD4(1,1,1,1),metallic:0,roughness:1)
            var roof=Body(id:BodyID(),name:"AO roof",transform:.identity,primitive:nil,render:plane(-100,100),revision:0)
            roof.transform.translation.z=2
            document.session.perform(AddBodyCommand(body:target));document.session.perform(AddBodyCommand(body:roof))
            let saved=await document.save()
            guard saved.succeeded else { document.close();throw CADDocumentError(code:"fixture_save_failed",message:saved.error ?? "Input geometry save failed.") }
        }
        if let target=document.session.document.bodies.first(where:{$0.name=="Paint plane"}) {
            let model=document.viewModel();model.selection=[target.id];model.mode = .selected(target.id)
        }
        return document
    }
}
#endif
