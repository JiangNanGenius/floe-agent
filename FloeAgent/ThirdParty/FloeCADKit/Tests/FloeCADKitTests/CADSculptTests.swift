// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import simd
@testable import FloeCAD

/// Real CPU mesh geometry/weights, real feature commands and native storage.
/// Source only: this implementation lane did not compile/run these tests.
@MainActor final class CADSculptTests:XCTestCase {
    private var directory:URL!
    private var documents:[FloeCADDocument]=[]
    override func setUp() async throws {
        directory=FileManager.default.temporaryDirectory.appendingPathComponent("Sculpt-\(UUID())")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    }
    override func tearDown() async throws {
        #if DEBUG
        CADPolygonMeshService.testBeforeSculptCompute=nil;CADPolygonMeshService.testAfterSculptCompute=nil
        #endif
        for document in documents where !document.isClosed { document.close() }
        if let directory { try? FileManager.default.removeItem(at:directory) }
    }
    private func grid(z:Double=0) throws -> CADPolygonCage {
        let vertices=(0..<9).flatMap { y in (0..<9).map { x in CADPolygonCage.Vertex(point:SIMD3(Double(x-4),Double(y-4),z)) } }
        var faces:[CADPolygonCage.Face]=[]
        for y in 0..<8 { for x in 0..<8 { let i=y*9+x;faces.append(.init(vertices:[vertices[i].id,vertices[i+1].id,vertices[i+10].id,vertices[i+9].id])) } }
        var cage=CADPolygonCage(vertices:vertices,edges:[],faces:faces);cage.synchronizeEdges();try cage.validate();return cage
    }
    private func begun(_ cage:CADPolygonCage?=nil) throws -> CADPolygonMeshDefinition {
        try CADSculptKernel.apply(.begin,to:.init(cage:cage ?? grid()),cancelled:{ false })
    }
    private func sample(_ definition:CADPolygonMeshDefinition,z:Double=0,pressure:Double=1) throws -> CADSculptSample {
        let render=try CADPolygonMeshKernel.evaluate(definition).render
        for triangle in 0..<render.triangleCount { for corner in 0..<3 {
            let point=render.positions[Int(render.indices[triangle*3+corner])]
            if abs(point.x)<1e-6 && abs(point.y)<1e-6 && abs(Double(point.z)-z)<1e-6 {
                var weights=SIMD3<Double>.zero;weights[corner]=1
                return .init(triangle:triangle,barycentric:weights,pressure:pressure)
            }
        } }
        throw CADPolygonFailure.invalid("The real center vertex was not found in the delivered render.")
    }
    private func stroke(_ source:CADPolygonMeshDefinition,mode:CADSculptBrush.Mode = .inflate,radius:Double=2,strength:Double=1,pressure:Double=1,z:Double=0) throws -> CADPolygonMeshDefinition {
        let value=CADSculptStroke(brush:.init(mode:mode,radius:radius,strength:strength,inverted:false),samples:[try sample(source,z:z,pressure:pressure)])
        return try CADSculptKernel.apply(.stroke(value),to:source,cancelled:{ false })
    }
    private func center(_ definition:CADPolygonMeshDefinition,level:Int?=nil) throws -> CADPolygonCage.Vertex {
        let state=try XCTUnwrap(definition.sculpt),resolved=try CADSculptKernel.resolve(state,level:level)
        return try XCTUnwrap(resolved.cage.vertices.min { simd_length(SIMD2($0.point.x,$0.point.y))<simd_length(SIMD2($1.point.x,$1.point.y)) })
    }
    func testActualPressureScalesVertexDisplacementAndZeroPressureDoesNothing() throws {
        let original=try begun(),low=try stroke(original,pressure:0.2),high=try stroke(original,pressure:0.8),zero=try stroke(original,pressure:0)
        XCTAssertEqual(try center(low).point.z,0.04,accuracy:1e-9)
        XCTAssertEqual(try center(high).point.z,0.16,accuracy:1e-9)
        XCTAssertEqual(try center(high).point.z/center(low).point.z,4,accuracy:1e-9)
        XCTAssertEqual(zero,original)
        let render=try CADPolygonMeshKernel.evaluate(high).render
        XCTAssertTrue(render.positions.contains { $0.z>0.15 })
    }
    func testJacobiSmoothingMovesRealRaisedNeighborhoodAndMaskBlocksIt() throws {
        let original=try begun(),raised=try stroke(original),tip=try center(raised)
        let relaxed=try stroke(raised,mode:.smooth,z:tip.point.z)
        XCTAssertLessThan(try center(relaxed).point.z,tip.point.z)
        XCTAssertGreaterThan(try center(relaxed).point.z,0)
        var protected=raised
        protected.sculpt?.levels[0].mask=[.init(vertex:tip.id,value:1)]
        let smoothed=try stroke(protected,mode:.smooth,z:tip.point.z)
        XCTAssertEqual(try center(smoothed).point,tip.point)
    }
    func testMaskPressureWeightsPersistAndProtectVertexWithoutPaintingColor() throws {
        let original=try begun(),quarter=try stroke(original,mode:.mask,radius:0.4,pressure:0.25),full=try stroke(original,mode:.mask,radius:0.4)
        let vertex=try center(original).id
        XCTAssertEqual(try CADSculptKernel.resolve(XCTUnwrap(quarter.sculpt)).mask[vertex],0.25)
        XCTAssertEqual(try CADSculptKernel.resolve(XCTUnwrap(full.sculpt)).mask[vertex],1)
        XCTAssertEqual(try CADPolygonMeshKernel.evaluate(full).render,try CADPolygonMeshKernel.evaluate(original).render)
        let moved=try stroke(full)
        XCTAssertEqual(try center(moved).point,try center(original).point)
        XCTAssertTrue(try CADSculptKernel.resolve(XCTUnwrap(moved.sculpt)).cage.vertices.contains { $0.point.z>0 })
        let unmasked=try stroke(full,mode:.unmask,radius:0.4)
        XCTAssertEqual(try CADSculptKernel.resolve(XCTUnwrap(unmasked.sculpt)).mask[vertex],0)
    }
    func testBrushCannotTunnelToDisconnectedNearbyBackSheet() throws {
        var front=try grid(z:0.01);let back=try grid(z:0)
        front.vertices+=back.vertices;front.faces+=back.faces;front.synchronizeEdges();try front.validate()
        let original=try begun(front),changed=try stroke(original,z:0.01)
        let old=try CADSculptKernel.resolve(XCTUnwrap(original.sculpt)).cage
        let next=try CADSculptKernel.resolve(XCTUnwrap(changed.sculpt)).cage.points
        for vertex in old.vertices where vertex.point.z==0 { XCTAssertEqual(next[vertex.id],vertex.point) }
        XCTAssertTrue(next.values.contains { $0.z>0.1 })
    }
    func testMultiresLevelsPreserveDetailAfterLowerLevelEditingAndMaskInheritance() throws {
        let original=try stroke(begun(),mode:.mask,radius:0.4)
        var higher=try CADSculptKernel.apply(.subdivide,to:original,cancelled:{false})
        let parent=try center(original).id
        XCTAssertEqual(try CADSculptKernel.resolve(XCTUnwrap(higher.sculpt)).mask[parent],1)
        higher=try CADSculptKernel.apply(.clearMask,to:higher,cancelled:{false})
        XCTAssertTrue(try CADSculptKernel.resolve(XCTUnwrap(higher.sculpt)).mask.values.allSatisfy { $0==0 })
        higher=try stroke(higher)
        let detail=try XCTUnwrap(higher.sculpt?.levels[1].offsets),centerID=try center(higher).id
        var low=try CADSculptKernel.apply(.level(0),to:higher,cancelled:{false})
        low=try CADSculptKernel.apply(.clearMask,to:low,cancelled:{false});low=try stroke(low,strength:0.2)
        XCTAssertEqual(low.sculpt?.levels[1].offsets,detail)
        let state=try XCTUnwrap(low.sculpt),coarse=try CADSculptKernel.resolve(state,level:0)
        let refined=try CADPolygonMeshKernel.subdivide(coarse.cage,namespace:state.levels[1].id,cancelled:{false})
        let expected=try XCTUnwrap(refined.points[centerID])+XCTUnwrap(detail.first { $0.vertex==centerID }?.vector)
        XCTAssertEqual(try center(low,level:1).point,expected)
        let back=try CADSculptKernel.apply(.level(1),to:low,cancelled:{false}),more=try CADSculptKernel.apply(.subdivide,to:back,cancelled:{false})
        XCTAssertEqual(more.sculpt?.levels.count,3)
        XCTAssertGreaterThan(try CADSculptKernel.resolve(XCTUnwrap(more.sculpt)).cage.faces.count,refined.faces.count)
        XCTAssertEqual(try JSONDecoder().decode(CADPolygonMeshDefinition.self,from:JSONEncoder().encode(more)),more)
    }
    private func fixture() async throws -> (FloeCADDocument,FeatureNode,BodyID) {
        let doc=try await FloeCADDocument.create(at:directory.appendingPathComponent("\(UUID()).floecad"),name:"Offline sculpt")
        documents.append(doc)
        let body=BodyID(),node=FeatureNode(name:"Sculpt grid",kind:.polygonCage(definition:.init(cage:try grid()),placement:.identity),outputBodyIDs:[body])
        doc.session.recordAndRebuild([node],title:"Initial grid");XCTAssertTrue(doc.session.lastEvalErrors.isEmpty)
        return (doc,node,body)
    }
    private func definition(_ doc:FloeCADDocument,_ id:FeatureID) throws -> CADPolygonMeshDefinition {
        guard let node=doc.session.document.features.node(id),case let .polygonCage(definition,_)=node.kind else { throw CADPolygonFailure.invalid("Missing same sculpt feature") };return definition
    }
    private func run(_ doc:FloeCADDocument,_ node:FeatureNode,_ id:BodyID,_ action:String,_ extra:[String:Any]=[:]) async throws -> [String:Any] {
        var args=extra;args["bodyID"]=id.raw.uuidString;args["cageDigest"]=try definition(doc,node.id).digest;args["expectedChangeCount"]=doc.session.changeCount
        let result=await CADMeshService(document:doc).handleAsync(action:action,args:args)
        XCTAssertEqual(result["ok"] as? Bool,true,"\(result)");return result
    }
    private func json<T:Encodable>(_ value:T) throws -> Any { try JSONSerialization.jsonObject(with:JSONEncoder().encode(value)) }
    func testNativeServiceOneStrokeOneUndoSameFeatureThenColdOfflineSaveReopen() async throws {
        let (doc,node,id)=try await fixture();_ = try await run(doc,node,id,"sculpt.begin")
        let original=try definition(doc,node.id),value=CADSculptStroke(brush:.init(),samples:[try sample(original,pressure:0.7)])
        let depth=doc.session.undoStack.undoCommands.count
        _ = try await run(doc,node,id,"sculpt.stroke",["stroke":try json(value)])
        let changed=try definition(doc,node.id),render=try XCTUnwrap(doc.session.document.body(with:id)?.render)
        XCTAssertNotEqual(changed,original);XCTAssertEqual(doc.session.undoStack.undoCommands.count,depth+1)
        XCTAssertEqual(doc.session.document.features.nodes.count,1);XCTAssertEqual(doc.session.document.features.nodes[0].id,node.id)
        XCTAssertEqual(doc.session.document.features.nodes[0].outputBodyIDs,[id]);XCTAssertNil(doc.session.document.body(with:id)?.brep)
        doc.session.undo();XCTAssertEqual(try definition(doc,node.id),original)
        doc.session.redo();XCTAssertEqual(try definition(doc,node.id),changed)
        let raisedTip=try center(changed)
        let smooth=CADSculptStroke(brush:.init(mode:.smooth,radius:2,strength:1,inverted:false),samples:[try sample(changed,z:raisedTip.point.z)])
        _ = try await run(doc,node,id,"sculpt.stroke",["stroke":try json(smooth)])
        let smoothed=try definition(doc,node.id),smoothedRender=try XCTUnwrap(doc.session.document.body(with:id)?.render)
        XCTAssertLessThan(try center(smoothed).point.z,raisedTip.point.z)
        let tip=try center(smoothed)
        let mask=CADSculptStroke(brush:.init(mode:.mask,radius:1,strength:1,inverted:false),samples:[try sample(smoothed,z:tip.point.z)])
        _ = try await run(doc,node,id,"sculpt.stroke",["stroke":try json(mask)])
        _ = try await run(doc,node,id,"sculpt.subdivide");_ = try await run(doc,node,id,"sculpt.subdivide")
        let fine=try definition(doc,node.id),saved=await doc.save();XCTAssertTrue(saved.succeeded,saved.error ?? "")
        let final=try XCTUnwrap(doc.session.document.body(with:id)?.render),url=doc.url
        doc.close();CADPolygonMeshKernel.clearCachedEvaluationsForTesting()
        let reopened=try await FloeCADDocument.open(at:url);documents.append(reopened)
        XCTAssertEqual(try definition(reopened,node.id),fine);XCTAssertEqual(reopened.session.document.body(with:id)?.render,final)
        XCTAssertGreaterThan(try CADSculptKernel.resolve(XCTUnwrap(fine.sculpt)).mask.values.max() ?? 0,0)
        XCTAssertEqual(try CADPolygonMeshKernel.evaluate(definition(reopened,node.id)).render,final)
        XCTAssertNotEqual(final,render);XCTAssertEqual(CADDocumentFormat.requiredFormat(document:reopened.session.document),7)
        _ = try await run(reopened,node,id,"sculpt.level",["level":0])
        XCTAssertEqual(try definition(reopened,node.id).sculpt?.levels.count,3)
        XCTAssertEqual(reopened.session.document.body(with:id)?.render,smoothedRender)
    }
    func testFullyMaskedOrZeroPressureServiceStrokeIsHonestNoOpWithoutUndo() async throws {
        let (doc,node,id)=try await fixture();_ = try await run(doc,node,id,"sculpt.begin")
        let source=try definition(doc,node.id)
        let mask=CADSculptStroke(brush:.init(mode:.mask,radius:0.4,strength:1,inverted:false),samples:[try sample(source)])
        _ = try await run(doc,node,id,"sculpt.stroke",["stroke":try json(mask)])
        let before=try definition(doc,node.id),depth=doc.session.undoStack.undoCommands.count,generation=doc.session.changeCount
        for pressure in [1.0,0.0] {
            let brush=CADSculptStroke(brush:.init(mode:.inflate,radius:0.4,strength:1,inverted:false),samples:[try sample(before,pressure:pressure)])
            let reply=try await run(doc,node,id,"sculpt.stroke",["stroke":try json(brush)])
            XCTAssertEqual(reply["mutated"] as? Bool,false);XCTAssertEqual(reply["unchanged"] as? Bool,true);XCTAssertEqual(reply["undoSteps"] as? Int,0)
        }
        XCTAssertEqual(doc.session.undoStack.undoCommands.count,depth);XCTAssertEqual(doc.session.changeCount,generation)
        XCTAssertEqual(try definition(doc,node.id),before)
    }
    func testFutureNestedSculptSemanticsOpenOpaqueAndKeepOriginalPackageBytes() async throws {
        let (doc,node,id)=try await fixture();_ = try await run(doc,node,id,"sculpt.begin")
        let saved=await doc.save();XCTAssertTrue(saved.succeeded);let url=doc.url;doc.close()
        var future=Data()
        try CADAssociativeFormatFixture.rewrite(url,schema:7) { record in
            let index=try XCTUnwrap(record.features.firstIndex { $0.featureID==node.id.raw })
            var raw=try XCTUnwrap(JSONSerialization.jsonObject(with:record.features[index].kind) as? [String:Any])
            var poly=try XCTUnwrap(raw["polygonCage"] as? [String:Any]),definition=try XCTUnwrap(poly["definition"] as? [String:Any]),sculpt=try XCTUnwrap(definition["sculpt"] as? [String:Any])
            var levels=try XCTUnwrap(sculpt["levels"] as? [[String:Any]])
            levels[0]["futureInterpolation"]=["original":"preserve exact bytes"]
            sculpt["levels"]=levels;definition["sculpt"]=sculpt;poly["definition"]=definition;raw["polygonCage"]=poly
            future=try JSONSerialization.data(withJSONObject:raw);record.features[index].kind=future
        }
        let bytes=try CADAssociativeFormatFixture.bytes(url),reopened=try await FloeCADDocument.open(at:url);documents.append(reopened)
        XCTAssertTrue(reopened.isReadOnly)
        XCTAssertEqual(reopened.project.features.first(where:{ $0.featureID==node.id.raw })?.kindData,future)
        let refused=await CADMeshService(document:reopened).handleAsync(action:"sculpt.subdivide",args:["bodyID":id.raw.uuidString,"cageDigest":"old"])
        XCTAssertEqual(refused["mutated"] as? Bool,false)
        let save=await reopened.save();XCTAssertFalse(save.succeeded);reopened.close()
        XCTAssertEqual(try CADAssociativeFormatFixture.bytes(url),bytes)
    }
    func testInvalidSampleAndOldDigestPreserveUndoRedoAndMesh() async throws {
        let (doc,node,id)=try await fixture();_ = try await run(doc,node,id,"sculpt.begin")
        let before=try definition(doc,node.id),depth=doc.session.undoStack.undoCommands.count,render=doc.session.document.body(with:id)?.render
        for fields in [["cageDigest":"stale"],["cageDigest":before.digest,"stroke":["brush":["mode":"inflate","radius":2,"strength":1,"inverted":false],"samples":[["triangle":999999,"barycentric":[1,0,0],"pressure":1]]]]] as [[String:Any]] {
            var args=fields;args["bodyID"]=id.raw.uuidString
            let reply=await CADMeshService(document:doc).handleAsync(action:"sculpt.stroke",args:args);XCTAssertEqual(reply["ok"] as? Bool,false)
        }
        let blocked=await CADMeshService(document:doc).handleAsync(action:"modifier.add",args:["bodyID":id.raw.uuidString,"cageDigest":before.digest,"kind":"subdivision","levels":1])
        XCTAssertEqual(blocked["ok"] as? Bool,false);XCTAssertEqual(try definition(doc,node.id),before)
        XCTAssertEqual(doc.session.undoStack.undoCommands.count,depth);XCTAssertEqual(doc.session.document.body(with:id)?.render,render)
    }
    func testExistingTextureCoordinatesRefuseSculptWithoutLosingDataOrHistory() async throws {
        let (doc,node,id)=try await fixture();_ = try await run(doc,node,id,"sculpt.begin")
        let original=try definition(doc,node.id),body=try XCTUnwrap(doc.session.document.body(with:id))
        var textured=body.render;textured.texcoords=Array(repeating:SIMD2<Float>(0.25,0.75),count:textured.positions.count)
        doc.session.perform(SetBodyUVCommand(title:"Existing UV",bodyID:id,beforeRender:body.render,afterRender:textured,beforeData:body.uvData,afterData:nil))
        let depth=doc.session.undoStack.undoCommands.count
        let reply=await CADMeshService(document:doc).handleAsync(action:"sculpt.subdivide",args:["bodyID":id.raw.uuidString,"cageDigest":original.digest])
        XCTAssertEqual(reply["ok"] as? Bool,false);XCTAssertEqual(doc.session.document.body(with:id)?.render,textured)
        XCTAssertEqual(doc.session.undoStack.undoCommands.count,depth);XCTAssertEqual(try definition(doc,node.id),original)
    }
    #if DEBUG
    func testCancelledWorkerJoinsWithoutConsumingHistoryOrReplacingNewerResult() async throws {
        let (doc,node,id)=try await fixture();_ = try await run(doc,node,id,"sculpt.begin")
        let original=try definition(doc,node.id),depth=doc.session.undoStack.undoCommands.count
        let entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0)
        CADPolygonMeshService.testBeforeSculptCompute={ entered.signal();_ = release.wait(timeout:.now()+30) }
        let args:[String:Any]=["bodyID":id.raw.uuidString,"cageDigest":original.digest,"stroke":try json(CADSculptStroke(brush:.init(),samples:[try sample(original)]))]
        // Dictionary receipt stays on MainActor; only a Sendable scalar leaves.
        let task=Task { @MainActor in let reply=await CADMeshService(document:doc).handleAsync(action:"sculpt.stroke",args:args);return reply["error"] as? String }
        let waitForEntry: @Sendable () -> Bool = { entered.wait(timeout:.now()+10) == .success }
        let reached=await Task.detached { waitForEntry() }.value;XCTAssertTrue(reached)
        task.cancel();CADPolygonMeshService.testBeforeSculptCompute=nil
        _ = try await run(doc,node,id,"sculpt.subdivide");let current=try definition(doc,node.id)
        release.signal();let error=await task.value;XCTAssertNotNil(error)
        XCTAssertEqual(try definition(doc,node.id),current);XCTAssertEqual(doc.session.undoStack.undoCommands.count,depth+1)
    }
    func testRealInterveningUserEditSurvivesStaleSculptResult() async throws {
        let (doc,node,id)=try await fixture();_ = try await run(doc,node,id,"sculpt.begin")
        let original=try definition(doc,node.id),depth=doc.session.undoStack.undoCommands.count
        CADPolygonMeshService.testAfterSculptCompute={ doc.session.perform(AddSketchCommand(sketch:Sketch(name:"Real intervening edit",plane:.ground,entities:[]))) }
        let reply=await CADMeshService(document:doc).handleAsync(action:"sculpt.stroke",args:["bodyID":id.raw.uuidString,"cageDigest":original.digest,
            "stroke":try json(CADSculptStroke(brush:.init(),samples:[try sample(original)]))])
        CADPolygonMeshService.testAfterSculptCompute=nil
        XCTAssertEqual(reply["ok"] as? Bool,false);XCTAssertEqual(try definition(doc,node.id),original)
        XCTAssertTrue(doc.session.document.sketches.contains { $0.name=="Real intervening edit" });XCTAssertEqual(doc.session.undoStack.undoCommands.count,depth+1)
    }
    #endif
}
