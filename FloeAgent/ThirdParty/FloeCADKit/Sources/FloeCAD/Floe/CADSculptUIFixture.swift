// SPDX-License-Identifier: MPL-2.0
#if DEBUG
import Foundation
import simd

/// Seeds one REAL initial polygon grid only. No sculpt, mask, subdivision or
/// undo command is performed here; native controls must do all later work.
@MainActor public enum CADSculptUIFixture {
    public static func open(at url:URL,reset:Bool) async throws -> FloeCADDocument {
        if reset,FileManager.default.fileExists(atPath:url.path) { try FileManager.default.removeItem(at:url) }
        if FileManager.default.fileExists(atPath:url.path) { return try await FloeCADDocument.open(at:url) }
        let document=try await FloeCADDocument.create(at:url,name:"Sculpt input")
        do {
            let vertices=(0..<9).flatMap { z in (0..<9).map { x in CADPolygonCage.Vertex(point:SIMD3(Double(x-4)*2,0,Double(z-4)*2)) } }
            var faces:[CADPolygonCage.Face]=[]
            for z in 0..<8 { for x in 0..<8 {
                let i=z*9+x
                faces.append(.init(vertices:[vertices[i].id,vertices[i+9].id,vertices[i+10].id,vertices[i+1].id]))
            } }
            var cage=CADPolygonCage(vertices:vertices,edges:[],faces:faces);cage.synchronizeEdges();try cage.validate()
            let node=FeatureNode(name:"Sculpt input",kind:.polygonCage(definition:.init(cage:cage),placement:.identity),outputBodyIDs:[BodyID()])
            document.session.recordAndRebuild([node],title:"Initial sculpt grid")
            guard document.session.lastEvalErrors.isEmpty else { throw CADPolygonFailure.invalid("The real initial sculpt grid could not be built.") }
            let saved=await document.save();guard saved.succeeded else { throw CADPolygonFailure.invalid(saved.error ?? "The initial grid could not be saved.") }
            return document
        } catch { document.close();throw error }
    }
}
#endif
