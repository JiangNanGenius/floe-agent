import Foundation
import XCTest
import simd
import OCCTShim
@testable import FloeCAD

/// Source-only packet tests. These are expected assertions, not executed
/// qualification evidence. Root owns OCCT relink/App/native/UI acceptance.
@MainActor
final class CADLoftSurfaceWorkflowTests: XCTestCase {
    func testOverlappingNativeScopesRetainHandlersUntilLastOwnerExits() {
        let report = OCCTBridge.signalGuardOverlapDiagnostics()
        XCTAssertEqual(report["guardAfterFirstExit"] as? Bool, true,
                       "One finishing kernel must not remove the other thread's active crash guard")
        XCTAssertEqual(report["restoredAfterLastExit"] as? Bool, true,
                       "The last owner must restore the original process signal handlers")
    }

    private var directory: URL!
    private var documents: [FloeCADDocument] = []
    override func setUp() async throws {
        directory=FileManager.default.temporaryDirectory.appendingPathComponent("LoftSurface-\(UUID())")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    }
    override func tearDown() async throws {
        for doc in documents where !doc.isClosed { doc.close() }
        if let directory { try? FileManager.default.removeItem(at:directory) }
    }
    private func document() async throws -> FloeCADDocument {
        let doc=try await FloeCADDocument.create(at:directory.appendingPathComponent("\(UUID()).floecad"),name:"Synthetic surfaces")
        documents.append(doc); return doc
    }
    private func json<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with:JSONEncoder().encode(value))
    }
    private func shape(_ doc: FloeCADDocument, _ id: BodyID, solid: Bool) throws -> BRepHandle {
        let body=try XCTUnwrap(doc.session.document.body(with:id))
        if solid { XCTAssertNil(body.surfaceBRep); return try XCTUnwrap(body.brep) }
        XCTAssertNil(body.brep); return try XCTUnwrap(body.surfaceBRep)
    }
    private func healthy(_ handle: BRepHandle, solids: Int) {
        let health=OCCTKernel.healthReport(for:handle)
        XCTAssertNil(health.error); XCTAssertTrue(health.isValid,health.findingsSummary)
        XCTAssertEqual(health.counts["solids"],solids)
    }
    private func create(_ definition: CADSurfaceDefinition, on doc: FloeCADDocument) throws -> (FeatureID,BodyID) {
        let depth=doc.session.undoStack.undoCommands.count
        let reply=CADParameterService(document:doc).handle(action:"surface.create",args:["definition":try json(definition)])
        XCTAssertEqual(reply["ok"] as? Bool,true,"surface.\(definition.operation.rawValue): \(reply)")
        XCTAssertEqual(doc.session.undoStack.undoCommands.count,depth+1)
        let raw=try XCTUnwrap(UUID(uuidString:try XCTUnwrap(reply["feature_id"] as? String)))
        let feature=try XCTUnwrap(doc.session.document.features.node(FeatureID(raw:raw)))
        return (feature.id,try XCTUnwrap(feature.outputBodyIDs.first))
    }
    private func lineSections(_ doc: FloeCADDocument, a: SIMD2<Double> = .zero,
                              b: SIMD2<Double> = SIMD2(20,0), height: Double = 10) -> [SweepPathDefinition] {
        [0.0,height].map { z in
            let entity=UUID()
            let sketch=Sketch(plane:SketchPlane(origin:SIMD3(0,0,z),xAxis:SIMD3(1,0,0),yAxis:SIMD3(0,1,0)),
                entities:[.line(id:entity,a:a,b:b)])
            doc.session.perform(AddSketchCommand(sketch:sketch))
            return SweepPathDefinition(segments:[.init(sketchID:sketch.id,entityID:entity)])
        }
    }
    private func ringSections(_ doc: FloeCADDocument) -> [ProfileRef] {
        [0.0,5.0,10.0].map { z in
            let outer=UUID(),hole=UUID()
            let sketch=Sketch(plane:SketchPlane(origin:SIMD3(0,0,z),xAxis:SIMD3(1,0,0),yAxis:SIMD3(0,1,0)),
                entities:[.circle(id:outer,center:.zero,radius:5),.circle(id:hole,center:.zero,radius:2)])
            doc.session.perform(AddSketchCommand(sketch:sketch))
            return ProfileRef(sketchID:sketch.id,entityIDs:[outer],holeEntityIDs:[[hole]],seedPoint:SIMD2(4,0))
        }
    }
    func testPairedInnerLoopsAreExactAndSectionReorderEditsOneFeature() async throws {
        let doc=try await document(), sections=ringSections(doc), body=BodyID()
        let node=FeatureNode(name:"Ring loft",kind:.loft(sections:sections,
            boolean:BooleanIntent(op:.newBody,resolvedTargets:[]),definition:LoftDefinition(ruled:true)),outputBodyIDs:[body])
        XCTAssertTrue(doc.session.performAssociativeTransaction([AppendFeatureCommand(node:node)],title:"Loft"))
        let initial=try shape(doc,body,solid:true); healthy(initial,solids:1)
        XCTAssertEqual(OCCTKernel.volume(initial),Double.pi*21*10,accuracy:1e-3)
        XCTAssertEqual(CADDocumentFormat.requiredFormat(document:doc.session.document),7)
        let depth=doc.session.undoStack.undoCommands.count, count=doc.session.document.features.nodes.count
        let reply=CADParameterService(document:doc).handle(action:"loft.update",args:[
            "feature_id":node.id.raw.uuidString,"changes":["sections":try json(Array(sections.reversed()))]])
        XCTAssertEqual(reply["ok"] as? Bool,true,"\(reply)")
        XCTAssertEqual(doc.session.document.features.nodes.count,count)
        XCTAssertEqual(doc.session.document.features.node(node.id)?.outputBodyIDs,[body])
        XCTAssertEqual(doc.session.undoStack.undoCommands.count,depth+1)
        XCTAssertEqual(OCCTKernel.volume(try shape(doc,body,solid:true)),Double.pi*21*10,accuracy:1e-3)
        doc.session.undo()
        guard case let .loft(restored,_,_)?=doc.session.document.features.node(node.id)?.kind else { return XCTFail("Lost original loft") }
        XCTAssertEqual(restored,sections)
        doc.session.redo()
        guard case let .loft(reordered,_,_)?=doc.session.document.features.node(node.id)?.kind else { return XCTFail("Lost edited loft") }
        XCTAssertEqual(reordered,Array(sections.reversed()))
    }
    func testUnsupportedGuidesAndEndConstraintsAndMissingInnerLoopRefuseAtomically() async throws {
        let doc=try await document(), sections=ringSections(doc), body=BodyID()
        let node=FeatureNode(name:"Ring",kind:.loft(sections:sections,
            boolean:BooleanIntent(op:.newBody,resolvedTargets:[]),definition:LoftDefinition()),outputBodyIDs:[body])
        XCTAssertTrue(doc.session.performAssociativeTransaction([AppendFeatureCommand(node:node)],title:"Loft"))
        let original=try XCTUnwrap(JSONSerialization.jsonObject(with:
            JSONEncoder().encode(try XCTUnwrap(doc.session.document.features.node(node.id)).kind)) as? NSDictionary)
        let originalOutputs=try XCTUnwrap(doc.session.document.features.node(node.id)).outputBodyIDs
        let originalSketches=doc.session.document.sketches,originalBodyIDs=doc.session.document.bodies.map(\.id)
        let redoDepth=doc.session.undoStack.redoCommands.count
        let volume=OCCTKernel.volume(try shape(doc,body,solid:true)), depth=doc.session.undoStack.undoCommands.count
        let guide=SweepPathDefinition(segments:[.init(sketchID:sections[0].sketchID,entityID:UUID())])
        let definitions=[LoftDefinition(guides:[guide]),LoftDefinition(start:.init(tangent:PointWrapper(SIMD3(0,0,1)),
            curvature:PointWrapper(.zero),angularTolerance:1e-3,curvatureTolerance:1e-4))]
        for definition in definitions {
            let reply=CADParameterService(document:doc).handle(action:"loft.update",args:[
                "feature_id":node.id.raw.uuidString,"changes":["definition":try json(definition)]])
            XCTAssertEqual(reply["ok"] as? Bool,false); XCTAssertEqual(reply["mutated"] as? Bool,false)
        }
        var missing=sections; missing[1].holeEntityIDs=[[UUID()]]
        let bad=CADParameterService(document:doc).handle(action:"loft.update",args:[
            "feature_id":node.id.raw.uuidString,"changes":["sections":try json(missing)]])
        XCTAssertEqual(bad["ok"] as? Bool,false,"\(bad)")
        XCTAssertEqual(doc.session.undoStack.undoCommands.count,depth)
        let retained=try XCTUnwrap(doc.session.document.features.node(node.id))
        let retainedObject=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(retained.kind)) as? NSDictionary)
        XCTAssertEqual(retainedObject,original,"Compare the full JSON tree; synthesized enum dictionaries have no stable encoding key order.")
        XCTAssertEqual(retained.outputBodyIDs,originalOutputs)
        XCTAssertEqual(doc.session.document.bodies.map(\.id),originalBodyIDs)
        XCTAssertEqual(doc.session.document.sketches,originalSketches)
        XCTAssertEqual(doc.session.undoStack.redoCommands.count,redoDepth)
        XCTAssertEqual(OCCTKernel.volume(try shape(doc,body,solid:true)),volume,accuracy:1e-9)
    }
    private func domain(_ handle: BRepHandle) throws -> (Int,Double,Double,Double,Double) {
        let rows=try XCTUnwrap(OCCTKernel.surfaceDiagnostics(handle)["face_domains"] as? [[String:Any]])
        XCTAssertEqual(rows.count,1)
        let row=try XCTUnwrap(rows.first)
        return (try XCTUnwrap(row["face_index"] as? Int),try XCTUnwrap(row["u_min"] as? Double),
            try XCTUnwrap(row["u_max"] as? Double),try XCTUnwrap(row["v_min"] as? Double),try XCTUnwrap(row["v_max"] as? Double))
    }
    func testOpenLoftD2TrimAndThicknessAreActualNativeGeometry() async throws {
        let doc=try await document()
        let (loft,body)=try create(CADSurfaceDefinition(operation:.loft,sections:lineSections(doc),ruled:true),on:doc)
        let surface=try shape(doc,body,solid:false); healthy(surface,solids:0)
        XCTAssertGreaterThan(try XCTUnwrap(OCCTKernel.surfaceDiagnostics(surface)["free_edges"] as? Int),0)
        let (index,u0,u1,v0,v1)=try domain(surface)
        let d=try XCTUnwrap(OCCTKernel.surfaceDifferential(surface,faceIndex:index,u:(u0+u1)/2,v:(v0+v1)/2))
        XCTAssertNotNil(d.normal)
        XCTAssertEqual(try XCTUnwrap(d.normalCurvature(along:SIMD2(1,0))),0,accuracy:1e-10)
        XCTAssertEqual(try XCTUnwrap(d.normalCurvature(along:SIMD2(0,1))),0,accuracy:1e-10)
        let (trim,_)=try create(CADSurfaceDefinition(operation:.trim,sources:[.init(producer:loft,bodyID:body)],
            trim:.init(uMin:u0+(u1-u0)*0.25,uMax:u0+(u1-u0)*0.75,
                vMin:v0+(v1-v0)*0.25,vMax:v0+(v1-v0)*0.75)),on:doc)
        let trimmed=try shape(doc,body,solid:false)
        let area=OCCTKernel.faceInfo(trimmed).reduce(0.0) { $0+$1.area }
        XCTAssertEqual(area,50,accuracy:1e-6)
        let (thick,_)=try create(CADSurfaceDefinition(operation:.thicken,sources:[.init(producer:trim,bodyID:body)],thickness:2),on:doc)
        let solid=try shape(doc,body,solid:true); healthy(solid,solids:1)
        XCTAssertEqual(OCCTKernel.surfaceDiagnostics(solid)["free_edges"] as? Int,0)
        XCTAssertEqual(OCCTKernel.volume(solid),100,accuracy:1e-5)
        let originalCount=doc.session.document.features.nodes.count
        let depth=doc.session.undoStack.undoCommands.count
        let update=CADSurfaceDefinition(operation:.thicken,sources:[.init(producer:trim,bodyID:body)],thickness:3)
        let reply=CADParameterService(document:doc).handle(action:"surface.update",args:[
            "feature_id":thick.raw.uuidString,"definition":try json(update)])
        XCTAssertEqual(reply["ok"] as? Bool,true,"\(reply)")
        XCTAssertEqual(doc.session.document.features.nodes.count,originalCount)
        XCTAssertEqual(doc.session.undoStack.undoCommands.count,depth+1)
        XCTAssertEqual(OCCTKernel.volume(try shape(doc,body,solid:true)),150,accuracy:1e-5)
        doc.session.undo(); XCTAssertEqual(OCCTKernel.volume(try shape(doc,body,solid:true)),100,accuracy:1e-5)
        doc.session.redo(); XCTAssertEqual(OCCTKernel.volume(try shape(doc,body,solid:true)),150,accuracy:1e-5)
        let url=doc.url
        let saved=await doc.save(); XCTAssertTrue(saved.succeeded,saved.error ?? "")
        doc.close()
        let reopened=try await FloeCADDocument.open(at:url); documents.append(reopened)
        XCTAssertNotNil(reopened.session.document.features.node(thick))
        XCTAssertEqual(OCCTKernel.volume(try shape(reopened,body,solid:true)),150,accuracy:1e-5)
        XCTAssertTrue(reopened.session.performAssociativeTransaction([
            EditFeatureCommand(featureID:thick,before:try XCTUnwrap(reopened.session.document.features.node(thick)).kind,
                after:.surface(definition:CADSurfaceDefinition(operation:.thicken,
                    sources:[.init(producer:trim,bodyID:body)],thickness:4)))],title:"Rebuild"))
        XCTAssertEqual(OCCTKernel.volume(try shape(reopened,body,solid:true)),200,accuracy:1e-5)
    }
    func testD2MeasuresNonzeroCylinderCurvatureAndRejectsOutsideTrim() throws {
        let cylinder=try XCTUnwrap(OCCTKernel.primitiveShape(.cylinder(radius:5,height:10),placement:.identity))
        let face=try XCTUnwrap(OCCTKernel.faceInfo(cylinder).first {
            if case .cylindrical? = $0.signature?.kind { return true }; return false
        })
        let domains=try XCTUnwrap(OCCTKernel.surfaceDiagnostics(cylinder)["face_domains"] as? [[String:Any]])
        let row=try XCTUnwrap(domains.first { $0["face_index"] as? Int == face.index })
        let u0=try XCTUnwrap(row["u_min"] as? Double), u1=try XCTUnwrap(row["u_max"] as? Double)
        let v0=try XCTUnwrap(row["v_min"] as? Double), v1=try XCTUnwrap(row["v_max"] as? Double)
        let d=try XCTUnwrap(OCCTKernel.surfaceDifferential(cylinder,faceIndex:face.index,u:(u0+u1)/2,v:(v0+v1)/2))
        XCTAssertEqual(abs(try XCTUnwrap(d.normalCurvature(along:SIMD2(1,0)))),0.2,accuracy:1e-10)
        XCTAssertEqual(try XCTUnwrap(d.normalCurvature(along:SIMD2(0,1))),0,accuracy:1e-10)
        XCTAssertNil(OCCTKernel.surfaceDifferential(cylinder,faceIndex:face.index,u:(u0+u1)/2,v:v1+100))
    }
    func testSewOpenWallsPatchClosedBoundariesThenThickenAndUndoEachStep() async throws {
        let doc=try await document()
        let corners=[SIMD2<Double>(0,0),SIMD2(20,0),SIMD2(20,10),SIMD2(0,10)]
        var sources: [BodyRef] = []
        for index in corners.indices {
            let (feature,body)=try create(CADSurfaceDefinition(operation:.loft,
                sections:lineSections(doc,a:corners[index],b:corners[(index+1)%4],height:30),ruled:true),on:doc)
            sources.append(.init(producer:feature,bodyID:body))
        }
        let (sewn,body)=try create(CADSurfaceDefinition(operation:.sew,sources:sources),on:doc)
        XCTAssertEqual(doc.session.document.bodies.count,1)
        XCTAssertEqual(OCCTKernel.surfaceDiagnostics(try shape(doc,body,solid:false))["closed"] as? Bool,false)
        let (patched,_)=try create(CADSurfaceDefinition(operation:.patch,sources:[.init(producer:sewn,bodyID:body)]),on:doc)
        let closed=try shape(doc,body,solid:false)
        XCTAssertEqual(OCCTKernel.surfaceDiagnostics(closed)["closed"] as? Bool,true)
        XCTAssertEqual(OCCTKernel.surfaceDiagnostics(closed)["faces"] as? Int,6)
        XCTAssertFalse(closed.containsSolid,"A closed shell is still a surface until the explicit solid operation.")
        let (thick,_)=try create(CADSurfaceDefinition(operation:.thicken,sources:[.init(producer:patched,bodyID:body)],thickness:1),on:doc)
        let wall=try shape(doc,body,solid:true)
        healthy(wall,solids:1)
        XCTAssertGreaterThan(OCCTKernel.volume(wall),0)
        // Positive Arc offset of the SAME 20×10×30 box: six face slabs,
        // twelve quarter-cylinder edges and eight eighth-sphere corners.
        // The original 6000 mm³ solid must be the cavity, not the material.
        XCTAssertEqual(OCCTKernel.volume(wall),2200 + 60*Double.pi + 4*Double.pi/3,accuracy:1e-3)
        XCTAssertEqual(OCCTKernel.healthReport(for:wall).counts["shells"],2)
        doc.session.undo(); XCTAssertNil(doc.session.document.features.node(thick)); XCTAssertNotNil(try shape(doc,body,solid:false))
        doc.session.undo(); XCTAssertNil(doc.session.document.features.node(patched))
        XCTAssertEqual(OCCTKernel.surfaceDiagnostics(try shape(doc,body,solid:false))["closed"] as? Bool,false)
        doc.session.undo(); XCTAssertNil(doc.session.document.features.node(sewn)); XCTAssertEqual(doc.session.document.bodies.count,4)
        doc.session.redo(); doc.session.redo(); doc.session.redo(); healthy(try shape(doc,body,solid:true),solids:1)
    }
    func testFailedClosedSewAndStaleSourceKeepOriginalUndoAndShapes() async throws {
        let doc=try await document()
        let (first,a)=try create(CADSurfaceDefinition(operation:.loft,sections:lineSections(doc),ruled:true),on:doc)
        let (second,b)=try create(CADSurfaceDefinition(operation:.loft,sections:lineSections(doc,a:SIMD2(100,0),b:SIMD2(120,0)),ruled:true),on:doc)
        let depth=doc.session.undoStack.undoCommands.count, count=doc.session.document.features.nodes.count
        let definition=CADSurfaceDefinition(operation:.sew,sources:[.init(producer:first,bodyID:a),.init(producer:second,bodyID:b)],requireClosed:true)
        let reply=CADParameterService(document:doc).handle(action:"surface.create",args:["definition":try json(definition)])
        XCTAssertEqual(reply["ok"] as? Bool,false,"\(reply)")
        let stale=CADSurfaceDefinition(operation:.thicken,sources:[.init(producer:FeatureID(),bodyID:a)],thickness:2)
        let rejected=CADParameterService(document:doc).handle(action:"surface.create",args:["definition":try json(stale)])
        XCTAssertEqual(rejected["ok"] as? Bool,false,"\(rejected)")
        XCTAssertEqual(doc.session.undoStack.undoCommands.count,depth)
        XCTAssertEqual(doc.session.document.features.nodes.count,count)
        XCTAssertNotNil(try shape(doc,a,solid:false)); XCTAssertNotNil(try shape(doc,b,solid:false))
    }
    func testFutureSurfaceVersionAndUnknownOperationPreserveOriginalBytesReadOnly() async throws {
        for futureOperation in [false,true] {
            let doc=try await document()
            let (_,body)=try create(CADSurfaceDefinition(operation:.loft,sections:lineSections(doc),ruled:true),on:doc)
            let url=doc.url
            let saved=await doc.save(); XCTAssertTrue(saved.succeeded,saved.error ?? ""); doc.close()
            try CADAssociativeFormatFixture.rewrite(url,schema:7) { record in
                var row=record.features[0]
                var object=try XCTUnwrap(JSONSerialization.jsonObject(with:row.kind) as? [String:Any])
                var surface=try XCTUnwrap(object["surface"] as? [String:Any])
                var definition=try XCTUnwrap(surface["definition"] as? [String:Any])
                if futureOperation { definition["operation"]="futureCurvaturePatch" }
                else { definition["version"]=2 }
                surface["definition"]=definition; object["surface"]=surface
                row.kind=try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]); record.features[0]=row
            }
            let original=try CADAssociativeFormatFixture.bytes(url)
            let reopened=try await FloeCADDocument.open(at:url); documents.append(reopened)
            XCTAssertTrue(reopened.session.isReadOnly)
            XCTAssertNotNil(reopened.session.document.body(with:body)?.surfaceBRep)
            let attempt=CADParameterService(document:reopened).handle(action:"surface.create",args:["definition":[:]])
            XCTAssertEqual(attempt["ok"] as? Bool,false)
            let refusedSave=await reopened.save(); XCTAssertFalse(refusedSave.succeeded)
            XCTAssertEqual(try CADAssociativeFormatFixture.bytes(url),original)
        }
    }
}
