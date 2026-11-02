// SPDX-License-Identifier: MPL-2.0
// Product-path tests. These are new, unexecuted source until the integration
// owner compiles and runs the actual App-hosted test target.
import Foundation
import XCTest
import simd
#if canImport(UIKit)
import UIKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Observation
#endif
@testable import FloeCAD

@MainActor
final class CADUVAuthoringTests: XCTestCase {
    private var work: URL!
    override func setUp() async throws {
        work=FileManager.default.temporaryDirectory.appendingPathComponent("CADUV-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:work,withIntermediateDirectories:true)
    }
    override func tearDown() async throws {
        CADUVService.testBeforeCommitProbe=nil
        if let work { try? FileManager.default.removeItem(at:work) }
    }
    private func document(mesh: RenderMesh? = nil, exact: Bool = false) async throws -> (FloeCADDocument,BodyID) {
        let doc=try await FloeCADDocument.create(at:work.appendingPathComponent("model-\(UUID().uuidString).floecad"),name:"UV fixture")
        var body: Body
        if let mesh {
            body=Body(id:BodyID(),name:"Torus",transform:.identity,primitive:nil,render:mesh,revision:0)
        } else {
            let spec=PrimitiveSpec.box(width:20,depth:12,height:8)
            body=Body(name:"Exact block",primitive:spec,euclidMesh:.primitive(spec),revision:0)
            if exact {
                body.brep=try XCTUnwrap(OCCTKernel.primitiveShape(spec,placement:.identity))
                let face=try XCTUnwrap(OCCTKernel.faceInfo(body.brep!).first)
                let key=try XCTUnwrap(CADFaceKey(face:face))
                body.materialFaceBindings=[CADFaceMaterialBinding(key:key,
                    material:BodyMaterialSpec(baseColor:SIMD4(1,0,0,1),metallic:0,roughness:0.6),
                    assignedAt:Date(timeIntervalSince1970:1))]
            }
        }
        doc.session.perform(AddBodyCommand(body:body))
        return (doc,body.id)
    }
    private func body(_ doc:FloeCADDocument,_ id:BodyID) throws -> Body { try XCTUnwrap(doc.session.document.body(with:id)) }
    private func read(_ doc:FloeCADDocument,_ id:BodyID) async throws -> [String:Any] {
        let r=await CADMaterialService(document:doc).handleAsync(action:"uv.read",args:["body_id":id.raw.uuidString])
        XCTAssertEqual(r["ok"] as? Bool,true,"\(r)"); return r
    }
    private func edit(_ action:String,_ doc:FloeCADDocument,_ id:BodyID,_ extra:[String:Any]=[:]) async throws -> [String:Any] {
        let state=try await read(doc,id)
        var args:[String:Any]=["body_id":id.raw.uuidString,"source_sha256":state["source_sha256"]!,
                              "expected_change_count":doc.liveChangeCount]
        for (k,v) in extra { args[k]=v }
        let reply=await CADMaterialService(document:doc).handleAsync(action:action,args:args)
        XCTAssertEqual(reply["ok"] as? Bool,true,"\(reply)"); return reply
    }

    func testMarkedSeamSeparatesActualXatlasChartsAndPreservesExactBodyAndFaceMaterials() async throws {
        let (doc,id)=try await document(exact:true); defer { doc.close() }
        let before=try body(doc,id), tableBefore=doc.session.faceRangeTable(for:before)
        let rangesBefore=CADFaceMaterialResolver.assessGroups(in:before,table:tableBefore,tableRevision:before.meshRevision)
        XCTAssertTrue(rangesBefore.isLossless); XCTAssertFalse(rangesBefore.claimedTriangles.isEmpty)
        let edges=try CADUVRecord.edgeFaces(before.render)
        let seam=try XCTUnwrap(edges.sorted { $0.key < $1.key }.first { $0.value.count == 2 }?.key)
        _=try await edit("uv.seams",doc,id,["seams":[[seam.a,seam.b]]])
        _=try await edit("uv.unwrap",doc,id,["resolution":256])
        let after=try body(doc,id), record=try CADUVRecord.decode(XCTUnwrap(after.uvData))
        let set=try XCTUnwrap(record.activeSet), faces=try XCTUnwrap(edges[seam])
        XCTAssertNotEqual(set.faceCharts[faces[0]],set.faceCharts[faces[1]])
        XCTAssertEqual(try CADUVRecord.geometryDigest(before.render),try CADUVRecord.geometryDigest(after.render))
        XCTAssertTrue(after.brep === before.brep)
        XCTAssertEqual(after.materialFaceBindings,before.materialFaceBindings)
        XCTAssertEqual(after.primitive,before.primitive)
        let rangesAfter=CADFaceMaterialResolver.assessGroups(in:after,table:doc.session.faceRangeTable(for:after),tableRevision:after.meshRevision)
        XCTAssertEqual(rangesAfter.claimedTriangles,rangesBefore.claimedTriangles)
        XCTAssertEqual(rangesAfter.issues,[])
        XCTAssertEqual(after.render.indices.count,before.render.indices.count)
        XCTAssertEqual(after.render.texcoords?.count,after.render.positions.count)
    }

    func testKnownIslandTransformHasAnalyticMoveRotationScaleAndLeavesOtherIslandUntouched() throws {
        let uv:[SIMD2<Float>]=[SIMD2(0,0),SIMD2(2,0),SIMD2(0,2),SIMD2(3,3),SIMD2(4,3),SIMD2(3,4)]
        let set=CADUVSet(name:"Known",cornerUVData:CADUVRecord.pack(uv),faceCharts:[0,1],seamSHA256:"",atlasWidth:0,atlasHeight:0,algorithm:"fixture")
        let changed=try CADUVRecord.transformed(set,islands:[0],translate:SIMD2(0.25,-0.5),rotationDegrees:90,scale:SIMD2(2,0.5))
        let values=try CADUVRecord.unpack(changed.cornerUVData)
        // AABB centre (1,1); scale, then +90deg, then translate.
        let expected:[SIMD2<Float>]=[SIMD2(1.75,-1.5),SIMD2(1.75,2.5),SIMD2(0.75,-1.5)]
        for i in 0..<3 { XCTAssertEqual(values[i].x,expected[i].x,accuracy:1e-6); XCTAssertEqual(values[i].y,expected[i].y,accuracy:1e-6) }
        XCTAssertEqual(Array(values[3...]),Array(uv[3...]))
        XCTAssertEqual(changed.id,set.id)
        XCTAssertThrowsError(try CADUVRecord.transformed(set,islands:[99],translate:.zero,rotationDegrees:0,scale:SIMD2(repeating:1)))
        XCTAssertThrowsError(try CADUVRecord.transformed(set,islands:[0],translate:.zero,rotationDegrees:0,scale:SIMD2(0,1)))
    }

    func testCurvedTorusSeamUnwrapEditPackPreservesEverySourceTriangleAndSetIdentity() async throws {
        let mesh=Self.torus(), (doc,id)=try await document(mesh:mesh); defer { doc.close() }
        let seams=(0..<12).map { CADUVEdge(UInt32($0),UInt32(($0+1)%12)) }
        _=try await edit("uv.seams",doc,id,["seams":seams.map { [$0.a,$0.b] }])
        _=try await edit("uv.unwrap",doc,id,["resolution":256])
        let original=try CADUVRecord.decode(XCTUnwrap(try body(doc,id).uvData)), set=try XCTUnwrap(original.activeSet)
        let edges=try CADUVRecord.edgeFaces(mesh)
        for seam in seams { let f=try XCTUnwrap(edges[seam]); XCTAssertEqual(f.count,2); XCTAssertNotEqual(set.faceCharts[f[0]],set.faceCharts[f[1]]) }
        _=try await edit("uv.transform",doc,id,["island_ids":[set.faceCharts[0]],"translate":[1.25,0.5],"rotation_degrees":17,"scale":[0.8,0.9]])
        _=try await edit("uv.pack",doc,id,["resolution":512])
        let final=try body(doc,id), record=try CADUVRecord.decode(XCTUnwrap(final.uvData)), packed=try XCTUnwrap(record.activeSet)
        XCTAssertEqual(packed.id,set.id)
        XCTAssertEqual(final.render.indices.count,mesh.indices.count)
        XCTAssertEqual(try CADUVRecord.geometryDigest(final.render),try CADUVRecord.geometryDigest(mesh))
        XCTAssertEqual(packed.faceCharts.count,mesh.triangleCount)
        for value in try CADUVRecord.unpack(packed.cornerUVData) {
            XCTAssertGreaterThanOrEqual(value.x,0); XCTAssertLessThanOrEqual(value.x,1)
            XCTAssertGreaterThanOrEqual(value.y,0); XCTAssertLessThanOrEqual(value.y,1)
        }
    }

    func testSetsUndoRedoSaveReopenAndIndependentGLBAccessorReadPreserveActiveUVs() async throws {
        let (doc,id)=try await document(mesh:Self.torus()); var closed=false; defer { if !closed { doc.close() } }
        _=try await edit("uv.unwrap",doc,id,["resolution":256])
        _=try await edit("uv.createSet",doc,id,["name":"Paint UV"])
        let copied=try XCTUnwrap(try CADUVRecord.decode(XCTUnwrap(try body(doc,id).uvData)).sets.last)
        _=try await edit("uv.activateSet",doc,id,["set_id":copied.id.uuidString])
        let beforeData=try XCTUnwrap(try body(doc,id).uvData),beforeUV=try XCTUnwrap(try body(doc,id).render.texcoords)
        let island=try XCTUnwrap(copied.faceCharts.first)
        _=try await edit("uv.transform",doc,id,["island_ids":[island],"translate":[0.125,0.25]])
        let afterData=try XCTUnwrap(try body(doc,id).uvData),afterUV=try XCTUnwrap(try body(doc,id).render.texcoords)
        XCTAssertNotEqual(afterData,beforeData); XCTAssertNotEqual(afterUV,beforeUV)
        doc.session.undo(); XCTAssertEqual(try body(doc,id).uvData,beforeData); XCTAssertEqual(try body(doc,id).render.texcoords,beforeUV)
        doc.session.redo(); XCTAssertEqual(try body(doc,id).uvData,afterData); XCTAssertEqual(try body(doc,id).render.texcoords,afterUV)
        let saved=await doc.save(); XCTAssertTrue(saved.succeeded,"\(String(describing:saved.error))")
        let url=doc.url; doc.close(); closed=true
        let reopened=try await FloeCADDocument.open(at:url); defer { reopened.close() }
        let restored=try body(reopened,id)
        XCTAssertEqual(restored.uvData,afterData); XCTAssertEqual(restored.render.texcoords,afterUV)
        let record=try CADUVRecord.decode(XCTUnwrap(restored.uvData))
        XCTAssertEqual(record.sets.count,2); XCTAssertEqual(record.activeSetID,copied.id)
        XCTAssertEqual(reopened.session.project.formatVersion,CADDocumentFormat.uvAuthoringVersion)
        let glb=GLBExporter.glb(bodies:[restored])
        let wire=try Self.readGLBUVs(glb)
        XCTAssertEqual(wire.count,afterUV.count)
        for (a,b) in zip(wire,afterUV) { XCTAssertEqual(a.x,b.x,accuracy:1e-7); XCTAssertEqual(a.y,b.y,accuracy:1e-7) }
    }

    func testGeometryReplacementRetainsStaleRecordAndRefusesOldIndicesUntilExplicitRebase() async throws {
        let (doc,id)=try await document(); defer { doc.close() }
        _=try await edit("uv.unwrap",doc,id)
        let before=try body(doc,id), data=try XCTUnwrap(before.uvData)
        var replacement=Body(id:id,name:before.name,transform:before.transform,primitive:nil,
            render:before.render,revision:before.meshRevision+1)
        replacement.render.positions=replacement.render.positions.map { SIMD3($0.x*1.5,$0.y,$0.z) }
        replacement.render.texcoords=nil
        doc.session.perform(ReplaceBodyCommand(title:"Change Geometry",before:before,after:replacement))
        let changed=try body(doc,id)
        XCTAssertEqual(changed.uvData,data); XCTAssertNil(changed.render.texcoords)
        let read=try await read(doc,id); XCTAssertEqual(read["source_changed"] as? Bool,true)
        let count=doc.liveChangeCount
        let refused=await CADMaterialService(document:doc).handleAsync(action:"uv.transform",args:[
            "body_id":id.raw.uuidString,"source_sha256":read["source_sha256"]!,
            "expected_change_count":count,"island_ids":[0],"translate":[0.1,0]])
        XCTAssertEqual(refused["error"] as? String,"uv_source_changed")
        XCTAssertEqual(doc.liveChangeCount,count); XCTAssertEqual(try body(doc,id).uvData,data)
        let accepted=await CADMaterialService(document:doc).handleAsync(action:"uv.unwrap",args:[
            "body_id":id.raw.uuidString,"source_sha256":read["live_mesh_sha256"]!,
            "expected_change_count":count,"rebase":true])
        XCTAssertEqual(accepted["ok"] as? Bool,true,"\(accepted)")
        let rebased=try CADUVRecord.decode(XCTUnwrap(try body(doc,id).uvData))
        XCTAssertNotEqual(rebased.sourceMeshSHA256,try CADUVRecord.decode(data).sourceMeshSHA256)
        doc.session.undo(); XCTAssertEqual(try body(doc,id).uvData,data); XCTAssertNil(try body(doc,id).render.texcoords)
    }

    func testActualExtrusionParameterRebuildRetainsStaleUVWithoutReusingOldCornerIndices() async throws {
        let doc=try await FloeCADDocument.create(at:work.appendingPathComponent("feature-stale.floecad"),name:"Feature UV")
        var closed=false; defer { if !closed { doc.close() } }
        func command(_ op:String,_ args:[String:Any]) throws -> [String:Any] {
            let json=try JSONSerialization.data(withJSONObject:["op":op,"args":args])
            let result=doc.executeJSON(json)
            XCTAssertTrue(result.isOK,"\(result.errorCode ?? ""): \(result.message ?? "")")
            return try XCTUnwrap(JSONSerialization.jsonObject(with:result.payload) as? [String:Any])
        }
        let sketch=try command("sketch.create",["name":"UV source"])
        let sketchID=try XCTUnwrap(sketch["sketchID"] as? String)
        _=try command("sketch.addEntities",["sketchID":sketchID,"entities":[["kind":"rect","min":[0,0],"max":[20,12]]]])
        _=try command("feature.extrude",["sketchID":sketchID,"seedPoint":[10,6],"distance":8])
        let original=try XCTUnwrap(doc.session.document.bodies.first),id=original.id
        let featureID=try XCTUnwrap(doc.session.document.features.nodes.last?.id.raw.uuidString)
        _=try await edit("uv.unwrap",doc,id)
        let mapped=try body(doc,id),savedUV=try XCTUnwrap(mapped.uvData),oldCoordinates=try XCTUnwrap(mapped.render.texcoords)
        let update=CADParameterService(document:doc).handle(action:"update",args:["feature_id":featureID,"changes":["distance":16.0]])
        XCTAssertEqual(update["ok"] as? Bool,true,"\(update)")
        let rebuilt=try body(doc,id)
        XCTAssertEqual(rebuilt.id,mapped.id)
        XCTAssertEqual(rebuilt.uvData,savedUV,"The actual feature replay must retain the source UV bytes")
        XCTAssertNotEqual(try CADUVRecord.geometryDigest(rebuilt.render),try CADUVRecord.geometryDigest(mapped.render))
        XCTAssertNil(rebuilt.render.texcoords,"Old corner indices cannot be applied to the changed exact solid")
        XCTAssertNotNil(rebuilt.brep)
        let stale=try await read(doc,id)
        XCTAssertEqual(stale["source_changed"] as? Bool,true)
        doc.session.undo()
        XCTAssertEqual(try body(doc,id).uvData,savedUV)
        XCTAssertEqual(try body(doc,id).render.texcoords,oldCoordinates)
        doc.session.redo()
        XCTAssertEqual(try body(doc,id).uvData,savedUV); XCTAssertNil(try body(doc,id).render.texcoords)
        let outcome=await doc.save(); XCTAssertTrue(outcome.succeeded)
        let url=doc.url; doc.close(); closed=true
        let reopened=try await FloeCADDocument.open(at:url); defer { reopened.close() }
        XCTAssertEqual(try body(reopened,id).uvData,savedUV); XCTAssertNil(try body(reopened,id).render.texcoords)
        let staleReopen=try await read(reopened,id)
        XCTAssertEqual(staleReopen["source_changed"] as? Bool,true)
    }

    func testNoopAndInvalidPinsDoNotConsumeUndoOrChangeModel() async throws {
        let (doc,id)=try await document(); defer { doc.close() }
        _=try await edit("uv.unwrap",doc,id)
        let state=try await read(doc,id), count=doc.liveChangeCount, undo=doc.session.undoStack.undoCommands.count
        let data=try body(doc,id).uvData
        let noop=try await edit("uv.transform",doc,id,["island_ids":[0]])
        XCTAssertEqual(noop["mutated"] as? Bool,false)
        XCTAssertEqual(doc.liveChangeCount,count); XCTAssertEqual(doc.session.undoStack.undoCommands.count,undo)
        let refusal=await CADMaterialService(document:doc).handleAsync(action:"uv.seams",args:[
            "body_id":id.raw.uuidString,"source_sha256":"foreign",
            "expected_change_count":count,"seams":[]])
        XCTAssertEqual(refusal["error"] as? String,"uv_source_mismatch")
        let stale=await CADMaterialService(document:doc).handleAsync(action:"uv.seams",args:[
            "body_id":id.raw.uuidString,"source_sha256":state["source_sha256"]!,
            "expected_change_count":count-1,"seams":[]])
        XCTAssertEqual(stale["error"] as? String,"revision_mismatch")
        XCTAssertEqual(try body(doc,id).uvData,data); XCTAssertEqual(doc.liveChangeCount,count)
    }

    func testUnknownUVVersionRetainsRawBytesAndOpensReadOnlyWithoutRaisingOrdinaryDocuments() throws {
        let source=Self.torus(), known=try CADUVRecord.make(source:source).encoded()
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:known) as? [String:Any]); object["version"]=999
        let future=try JSONSerialization.data(withJSONObject:object,options:.sortedKeys)
        let project=Project(name:"Future UV"), id=UUID()
        project.formatVersion=7
        let row=PersistedBody(bodyID:id,name:"Future",transformData:try JSONEncoder().encode(Transform3D.identity),primitiveData:nil,meshData:MeshBlob.encode(source))
        row.uvData=future; row.project=project; project.bodies=[row]
        let session=DocumentSession(project:project,modelContext:CADModelContext(project:project))
        XCTAssertTrue(session.isReadOnly)
        XCTAssertEqual(session.document.bodies.first?.uvData,future)
        XCTAssertEqual(row.uvData,future)
        var ordinary=DesignDocument(); XCTAssertEqual(CADDocumentFormat.requiredFormat(document:ordinary),1)
        var body=Body(id:BodyID(raw:id),name:"Known",transform:.identity,primitive:nil,render:source,revision:1)
        body.uvData=known; ordinary.bodies=[body]
        XCTAssertEqual(CADDocumentFormat.requiredFormat(document:ordinary),7)
    }

    func testNativeCancellationBeforeEntryProducesNoOutput() throws {
        let source=Self.torus(), record=try CADUVRecord.make(source:source), cancellation=try CADUVCancellation()
        cancellation.cancel()
        XCTAssertThrowsError(try CADUVNative.generate(record:record,repacking:false,resolution:256,padding:2,cancellation:cancellation)) { error in
            XCTAssertEqual((error as? CADUVFailure)?.code,"cancelled")
        }
    }

    func testLateNativeResultIsRejectedAfterARealSourceEdit() async throws {
        let (doc,id)=try await document(); defer { doc.close() }
        let pin=try await read(doc,id), count=doc.liveChangeCount
        let entered=expectation(description:"Real native computation finished"), gate=DispatchSemaphore(value:0)
        CADUVService.testBeforeCommitProbe={ entered.fulfill(); _=gate.wait(timeout:.now()+20) }
        let task=Task { await CADMaterialService(document:doc).handleAsync(action:"uv.unwrap",args:[
            "body_id":id.raw.uuidString,"source_sha256":pin["source_sha256"]!,"expected_change_count":count]) }
        await fulfillment(of:[entered],timeout:20)
        let before=try body(doc,id); var changed=before; changed.name="Edited while unwrapping"
        doc.session.perform(ReplaceBodyCommand(title:"Concurrent edit",before:before,after:changed))
        gate.signal(); let reply=await task.value; CADUVService.testBeforeCommitProbe=nil
        XCTAssertEqual(reply["error"] as? String,"document_changed")
        XCTAssertEqual(try body(doc,id).name,"Edited while unwrapping"); XCTAssertNil(try body(doc,id).uvData)
    }

    func testCallerCancellationAndDocumentCloseFenceCompletedNativeOutput() async throws {
        for closing in [false,true] {
            let (doc,id)=try await document(); var didClose=false; defer { if !didClose { doc.close() } }
            let pin=try await read(doc,id), count=doc.liveChangeCount
            let entered=expectation(description:"Real native result waits before commit"), gate=DispatchSemaphore(value:0)
            CADUVService.testBeforeCommitProbe={ entered.fulfill(); _=gate.wait(timeout:.now()+20) }
            let task=Task { await CADMaterialService(document:doc).handleAsync(action:"uv.unwrap",args:[
                "body_id":id.raw.uuidString,"source_sha256":pin["source_sha256"]!,"expected_change_count":count]) }
            await fulfillment(of:[entered],timeout:20)
            XCTAssertEqual(CADUVService(document:doc).control(action:"uv.status")["active"] as? Bool,true)
            if closing { doc.close(); didClose=true } else { task.cancel() }
            gate.signal(); let reply=await task.value; CADUVService.testBeforeCommitProbe=nil
            XCTAssertEqual(reply["ok"] as? Bool,false)
            XCTAssertTrue(["cancelled","document_closed"].contains(reply["error"] as? String ?? ""))
            XCTAssertNil(try body(doc,id).uvData); XCTAssertEqual(doc.liveChangeCount,count)
        }
    }

    #if canImport(UIKit)
    /// One complex-surface product chain, using the SAME model methods bound
    /// to the native sheet's seam/unwrap/transform/preview controls. Pixel
    /// expectations come from source UVs and projected visible triangles;
    /// decoding a UIImage alone is never acceptance evidence.
    func testUVEditorTorusFourColorTextureRealViewportGLBAndNativeReopen() async throws {
        let (doc,id)=try await document(mesh:Self.torus())
        var closed=false; defer { if !closed { doc.close() } }
        let material=CADMaterialService(document:doc)
        let textureA=try uvProductTexture(cycle:0), textureB=try uvProductTexture(cycle:1)
        uvProductAttach(textureA,name:"X09 authored four-color grid A.png",type:UTType.png.identifier)
        uvProductAttach(textureB,name:"X09 authored four-color grid B negative control.png",type:UTType.png.identifier)
        let created=material.handle(action:"create",args:["name":"X09 four-color grid",
            "color":[1,1,1,1],"metallic":0,"roughness":1,"uv_mapping":["source":"mesh"],
            "textures":[["slot":"baseColor","base64":textureA.base64EncodedString(),
                         "mime_type":"image/png","color_space":"srgb","orientation":"topLeft"]]])
        XCTAssertEqual(created["ok"] as? Bool,true,"\(created)")
        let materialID=try XCTUnwrap(created["id"] as? String)
        let applied=material.handle(action:"apply",args:["bodyID":id.raw.uuidString,"material_id":materialID])
        XCTAssertEqual(applied["ok"] as? Bool,true,"\(applied)")
        let model=CADUVEditorModel(document:doc,bodyID:id); defer { model.stop() }
        await model.refresh()
        XCTAssertNil(model.errorMessage,model.diagnostic ?? "")
        let seams=(0..<12).map { CADUVEdge(UInt32($0),UInt32(($0+1)%12)) }
        for seam in seams {
            model.selectedEdge=seam
            model.toggleSeam() // Actual Mark Seam model/command path.
            await uvProductAwaitEditor(model)
        }
        XCTAssertEqual(Set(try XCTUnwrap(model.snapshot).record.seams),Set(seams))
        model.resolution=512
        model.run("uv.unwrap",extra:["resolution":model.resolution])
        await uvProductAwaitEditor(model)
        let unwrapped=try body(doc,id), initialRecord=try CADUVRecord.decode(XCTUnwrap(unwrapped.uvData))
        let initialSet=try XCTUnwrap(initialRecord.activeSet)
        let edgeFaces=try CADUVRecord.edgeFaces(Self.torus())
        for seam in seams {
            let faces=try XCTUnwrap(edgeFaces[seam]); XCTAssertEqual(faces.count,2)
            XCTAssertNotEqual(initialSet.faceCharts[faces[0]],initialSet.faceCharts[faces[1]])
        }
        let before=try uvProductCapture(model,document:doc,name:"X09 torus A unwrapped textured viewport.png")
        model.selectedIslands=Set(initialSet.faceCharts)
        model.moveU=0.083333333; model.moveV=0.046875
        model.rotation=17; model.scaleU=0.93; model.scaleV=0.88
        model.transform() // Actual Apply Transform model/command path.
        await uvProductAwaitEditor(model)
        let edited=try body(doc,id), uvBytes=try XCTUnwrap(edited.uvData)
        let record=try CADUVRecord.decode(uvBytes), set=try XCTUnwrap(record.activeSet)
        XCTAssertEqual(record.sourceMeshSHA256,initialRecord.sourceMeshSHA256)
        XCTAssertEqual(record.seams,initialRecord.seams)
        XCTAssertEqual(set.id,initialSet.id)
        XCTAssertEqual(edited.render.positions,unwrapped.render.positions)
        XCTAssertEqual(edited.render.normals,unwrapped.render.normals)
        XCTAssertEqual(edited.render.indices,unwrapped.render.indices)
        XCTAssertNotEqual(edited.render.texcoords,unwrapped.render.texcoords)
        XCTAssertEqual(edited.material?.baseColorTexture,textureA)
        XCTAssertEqual(edited.material?.verifiedTextureMetadata(for:.baseColor)?.verifiedDigest(for:textureA),CADUVRecord.sha(textureA))
        let after=try uvProductCapture(model,document:doc,name:"X09 torus B edited islands textured viewport.png")
        let landmarks=try uvProductLandmarks(document:doc,bodyID:id,before:unwrapped.render,after:edited.render)
        XCTAssertGreaterThanOrEqual(landmarks.count,12,"Need visible, texture-interior witnesses from the actual curved surface")
        for color in 0..<4 { XCTAssertGreaterThanOrEqual(landmarks.filter { $0.afterColor == color }.count,2,"Every authored color needs visible UV-bound landmarks") }
        for point in landmarks {
            uvProductAssertHue(before.pixels,point:point.pixel,color:point.beforeColor,label:"Before island transform")
            uvProductAssertHue(after.pixels,point:point.pixel,color:point.afterColor,label:"After island transform")
        }
        XCTAssertGreaterThan(uvProductMeanDifference(before.pixels,after.pixels),2,
                             "A real UV edit must change the actual textured viewport, not metadata alone")

        // Negative control: same geometry/UV/camera, deliberately cycle the
        // actual material bytes. A grey fallback or stale texture cannot pass.
        let changed=material.handle(action:"textures",args:["material_id":materialID,"slot":"baseColor",
            "base64":textureB.base64EncodedString(),"mime_type":"image/png","orientation":"topLeft",
            "color_space":"srgb","apply_to_applied":true])
        XCTAssertEqual(changed["ok"] as? Bool,true,"\(changed)")
        await model.refresh()
        let negative=try uvProductCapture(model,document:doc,name:"X09 torus C cycled texture negative control.png")
        for point in landmarks { uvProductAssertHue(negative.pixels,point:point.pixel,color:(point.afterColor+1)%4,label:"Cycled texture control") }
        XCTAssertGreaterThan(uvProductMeanDifference(after.pixels,negative.pixels),2)
        let restore=material.handle(action:"textures",args:["material_id":materialID,"slot":"baseColor",
            "base64":textureA.base64EncodedString(),"mime_type":"image/png","orientation":"topLeft",
            "color_space":"srgb","apply_to_applied":true])
        XCTAssertEqual(restore["ok"] as? Bool,true,"\(restore)")
        await model.refresh()
        let restored=try uvProductCapture(model,document:doc,name:"X09 torus D original texture restored.png")
        XCTAssertLessThanOrEqual(uvProductMeanDifference(after.pixels,restored.pixels),1)
        XCTAssertEqual(try body(doc,id).uvData,uvBytes)

        let glb=GLBExporter.glb(bodies:[try body(doc,id)])
        let glbUV=try Self.readGLBUVs(glb), authoredUV=try XCTUnwrap(edited.render.texcoords)
        XCTAssertEqual(glbUV,authoredUV,"Independent accessor floats must equal every active UV corner")
        XCTAssertEqual(try uvProductGLBBaseColorImage(glb),textureA,
                       "The material actually used by the GLB primitive must reference the exact authored image")
        uvProductAttach(glb,name:"X09 edited torus active UV and texture.glb",type:UTType.data.identifier)
        let outcome=await doc.save(); XCTAssertTrue(outcome.succeeded)
        let url=doc.url; model.stop(); doc.close(); closed=true
        let reopened=try await FloeCADDocument.open(at:url); defer { reopened.close() }
        let reopenedBody=try body(reopened,id)
        XCTAssertEqual(reopenedBody.uvData,uvBytes)
        XCTAssertEqual(reopenedBody.render.texcoords,authoredUV)
        XCTAssertEqual(reopenedBody.material?.baseColorTexture,textureA)
        XCTAssertTrue(try CADUVRecord.decode(XCTUnwrap(reopenedBody.uvData)).matches(reopenedBody.render))
        let reopenModel=CADUVEditorModel(document:reopened,bodyID:id); defer { reopenModel.stop() }
        await reopenModel.refresh()
        let reopenedCapture=try uvProductCapture(reopenModel,document:reopened,name:"X09 torus E native save reopen textured viewport.png")
        XCTAssertLessThanOrEqual(uvProductMeanDifference(restored.pixels,reopenedCapture.pixels),1)
        for point in landmarks { uvProductAssertHue(reopenedCapture.pixels,point:point.pixel,color:point.afterColor,label:"Native reopen") }
        let reopenedGLB=GLBExporter.glb(bodies:[reopenedBody])
        XCTAssertEqual(try Self.readGLBUVs(reopenedGLB),authoredUV)
        XCTAssertEqual(try uvProductGLBBaseColorImage(reopenedGLB),textureA)
        let manifest:[String:Any]=[
            "item":"X09","bodyID":id.raw.uuidString,"sourceMeshSHA256":record.sourceMeshSHA256,
            "uvRecordSHA256":CADUVRecord.sha(uvBytes),"activeSetID":set.id.uuidString,
            "sourceTextureSHA256":CADUVRecord.sha(textureA),"negativeTextureSHA256":CADUVRecord.sha(textureB),
            "glbSHA256":CADUVRecord.sha(glb),"seams":record.seams.map { [$0.a,$0.b] },
            "captures":[before,after,negative,restored,reopenedCapture].map { $0.identity },
            "landmarks":landmarks.map { $0.json },
            "assertions":"Unoccluded source-UV hue landmarks before/after transform and color-cycle control; restored/reopened viewport mean channel difference <=1; exact active GLB UV floats and primitive-linked PNG bytes.",
            "limits":"Production UI model/service and real Metal capture; actual on-screen touch controls remain a separate owner UI gate."
        ]
        uvProductAttach(try JSONSerialization.data(withJSONObject:manifest,options:[.sortedKeys,.prettyPrinted]),
                        name:"X09 torus UV texture capture identities and landmarks.json",type:UTType.json.identifier)
    }

    /// Observation ends on the model's real completion transition; no sleep,
    /// fabricated result or new production test API is needed.
    private func uvProductAwaitEditor(_ model:CADUVEditorModel) async {
        if model.isBusy {
            await withCheckedContinuation { (continuation:CheckedContinuation<Void,Never>) in
                withObservationTracking { _=model.isBusy } onChange: {
                    Task { @MainActor in continuation.resume() }
                }
            }
        }
        XCTAssertFalse(model.isBusy)
        XCTAssertNil(model.errorMessage,model.diagnostic ?? "")
    }

    private struct UVProductPixels {
        let width:Int, height:Int
        let rgba:[UInt8]
        static func decode(_ png:Data) throws -> Self {
            let source=try XCTUnwrap(CGImageSourceCreateWithData(png as CFData,nil))
            let image=try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil))
            let w=image.width,h=image.height
            guard w == 768,h == 512 else { throw CocoaError(.fileReadCorruptFile) }
            var bytes=[UInt8](repeating:0,count:w*h*4)
            try bytes.withUnsafeMutableBytes { raw in
                let context=try XCTUnwrap(CGContext(data:raw.baseAddress,width:w,height:h,bitsPerComponent:8,
                    bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(image,in:CGRect(x:0,y:0,width:w,height:h))
            }
            return Self(width:w,height:h,rgba:bytes)
        }
        func mean(at point:CGPoint) -> SIMD3<Double> {
            let x=Int(point.x.rounded()),y=Int(point.y.rounded())
            var sum=SIMD3<Double>(repeating:0)
            for row in y-1...y+1 { for column in x-1...x+1 {
                let i=(row*width+column)*4
                sum += SIMD3(Double(rgba[i]),Double(rgba[i+1]),Double(rgba[i+2]))
            } }
            return sum/9
        }
    }
    private struct UVProductCapture {
        let result:CADViewportCaptureResult
        let pixels:UVProductPixels
        let name:String
        var identity:[String:Any] { ["name":name,"renderer":result.renderer,"imageSHA256":result.sha256,
            "revision":result.revision,"changeCount":result.changeCount,"contentSHA256":result.contentSHA256,
            "width":result.width,"height":result.height] }
    }
    private func uvProductCapture(_ model:CADUVEditorModel,document:FloeCADDocument,name:String) throws -> UVProductCapture {
        let count=document.liveChangeCount
        model.capture() // The same Refresh 3D Preview action used by the sheet.
        XCTAssertNil(model.errorMessage,model.diagnostic ?? "")
        let modelPNG=try XCTUnwrap(try XCTUnwrap(model.preview).pngData())
        let captured=try document.captureViewportPNG(width:768,height:512)
        uvProductAttach(captured.pngData,name:name,type:UTType.png.identifier)
        XCTAssertEqual(captured.renderer,"engineering")
        XCTAssertEqual(captured.changeCount,count); XCTAssertEqual(document.liveChangeCount,count)
        let pixels=try UVProductPixels.decode(captured.pngData)
        XCTAssertLessThanOrEqual(uvProductMeanDifference(pixels,try UVProductPixels.decode(modelPNG)),1,
                                 "The editor preview must contain the same actual production-rendered pixels")
        return UVProductCapture(result:captured,pixels:pixels,name:name)
    }
    private func uvProductAttach(_ bytes:Data,name:String,type:String) {
        let attachment=XCTAttachment(data:bytes,uniformTypeIdentifier:type)
        attachment.name=name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func uvProductMeanDifference(_ a:UVProductPixels,_ b:UVProductPixels) -> Double {
        XCTAssertEqual(a.width,b.width); XCTAssertEqual(a.height,b.height)
        guard a.rgba.count == b.rgba.count else { return .infinity }
        var total:Double=0
        for i in stride(from:0,to:a.rgba.count,by:4) {
            for c in 0..<3 { total += Double(abs(Int(a.rgba[i+c])-Int(b.rgba[i+c]))) }
        }
        return total/Double(a.width*a.height*3)
    }
    private func uvProductAssertHue(_ pixels:UVProductPixels,point:CGPoint,color:Int,label:String) {
        let rgb=pixels.mean(at:point),r=rgb.x,g=rgb.y,b=rgb.z
        let matches:Bool
        switch color {
        case 0: matches = r >= 40 && r > 1.4*g && r > 1.4*b
        case 1: matches = g >= 40 && g > 1.4*r && g > 1.4*b
        case 2: matches = b >= 30 && b > 1.35*r && b > 1.35*g
        default: matches = r >= 35 && g >= 35 && min(r,g) > 1.5*b
        }
        XCTAssertTrue(matches,"\(label): authored color \(color) at \(point) rendered RGB \(rgb)")
    }

    private struct UVProductLandmark {
        let triangle:Int
        let barycentric:SIMD3<Float>
        let world:SIMD3<Float>
        let pixel:CGPoint
        let beforeUV:SIMD2<Float>,afterUV:SIMD2<Float>
        let beforeColor:Int,afterColor:Int
        var json:[String:Any] { ["triangle":triangle,"barycentric":[barycentric.x,barycentric.y,barycentric.z],
            "worldMM":[world.x,world.y,world.z],"pixel":[pixel.x,pixel.y],
            "beforeUV":[beforeUV.x,beforeUV.y],"afterUV":[afterUV.x,afterUV.y],
            "beforeColor":beforeColor,"afterColor":afterColor] }
    }
    private func uvProductLandmarks(document:FloeCADDocument,bodyID:BodyID,before:RenderMesh,after:RenderMesh) throws -> [UVProductLandmark] {
        let scene=document.viewModel().captureScene()
        let drawable=try XCTUnwrap(scene.bodies.first { $0.id == bodyID })
        let bounds=try XCTUnwrap(scene.worldBounds)
        var camera=TurntableCamera()
        if let saved=scene.appearance?.camera { camera=Renderer.turntableCamera(from:saved) }
        else { camera.fit(boundsMin:bounds.min,boundsMax:bounds.max,aspect:1.5) }
        let matrix=camera.viewProjection(aspect:1.5),size=CGSize(width:768,height:512)
        let beforeUV=try XCTUnwrap(before.texcoords),afterUV=try XCTUnwrap(after.texcoords)
        func world(_ p:SIMD3<Float>) -> SIMD3<Float> { let v=drawable.modelMatrix*SIMD4(p,1); return SIMD3(v.x,v.y,v.z)/v.w }
        func project(_ p:SIMD3<Float>) -> CGPoint? {
            let clip=matrix*SIMD4(p,1); guard clip.w > 0 else { return nil }
            let x=Double(clip.x/clip.w),y=Double(clip.y/clip.w)
            guard x.isFinite,y.isFinite else { return nil }
            return CGPoint(x:(x+1)*384,y:(1-y)*256)
        }
        func distance(_ p:CGPoint,_ a:CGPoint,_ b:CGPoint) -> CGFloat {
            abs((b.x-a.x)*(p.y-a.y)-(b.y-a.y)*(p.x-a.x))/max(hypot(b.x-a.x,b.y-a.y),1e-6)
        }
        var result:[UVProductLandmark]=[],perColor=[Int](repeating:0,count:4)
        let barycentrics:[SIMD3<Float>]=[SIMD3(repeating:1.0/3),SIMD3(0.2,0.3,0.5),SIMD3(0.5,0.2,0.3),SIMD3(0.3,0.5,0.2)]
        for f in 0..<after.triangleCount {
            let ids=(0..<3).map { Int(after.indices[f*3+$0]) }
            let oldIDs=(0..<3).map { Int(before.indices[f*3+$0]) }
            let corners=ids.map { world(after.positions[$0]) }
            guard let a=project(corners[0]),let b=project(corners[1]),let c=project(corners[2]) else { continue }
            for weights in barycentrics {
                let oldUV=beforeUV[oldIDs[0]]*weights.x+beforeUV[oldIDs[1]]*weights.y+beforeUV[oldIDs[2]]*weights.z
                let uv=afterUV[ids[0]]*weights.x+afterUV[ids[1]]*weights.y+afterUV[ids[2]]*weights.z
                guard let oldColor=uvProductColor(at:oldUV),let color=uvProductColor(at:uv),oldColor != color,perColor[color] < 8 else { continue }
                let p=corners[0]*weights.x+corners[1]*weights.y+corners[2]*weights.z
                guard let pixel=project(p),pixel.x >= 4,pixel.x < 764,pixel.y >= 4,pixel.y < 508,
                      min(distance(pixel,a,b),min(distance(pixel,b,c),distance(pixel,c,a))) >= 2 else { continue }
                let ray=camera.ray(through:pixel,viewportSize:size)
                guard let hit=HitTester.pickBody(ray:ray,in:scene),hit.bodyID == bodyID,hit.triangleIndex == f else { continue }
                result.append(UVProductLandmark(triangle:f,barycentric:weights,world:p,pixel:pixel,
                    beforeUV:oldUV,afterUV:uv,beforeColor:oldColor,afterColor:color))
                perColor[color] += 1
            }
        }
        return result
    }
    private func uvProductColor(at uv:SIMD2<Float>) -> Int? {
        guard uv.x >= 0,uv.x < 1,uv.y >= 0,uv.y < 1 else { return nil }
        let x=Int(uv.x*256),y=Int(uv.y*256)
        guard (6..<26).contains(x%32),(6..<26).contains(y%32) else { return nil }
        return (x/32+2*(y/32))%4
    }
    private func uvProductTexture(cycle:Int) throws -> Data {
        let colors:[[UInt8]]=[[240,24,24,255],[24,220,40,255],[28,60,240,255],[230,215,20,255]]
        var bytes=[UInt8](); bytes.reserveCapacity(256*256*4)
        for y in 0..<256 { for x in 0..<256 {
            let color=(x/32+2*(y/32)+cycle)%4
            bytes += x%32 < 2 || y%32 < 2 ? [8,8,8,255] : colors[color]
        } }
        let provider=try XCTUnwrap(CGDataProvider(data:Data(bytes) as CFData))
        let image=try XCTUnwrap(CGImage(width:256,height:256,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:256*4,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),
            provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
        let output=NSMutableData(),destination=try XCTUnwrap(CGImageDestinationCreateWithData(output,UTType.png.identifier as CFString,1,nil))
        CGImageDestinationAddImage(destination,image,nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
    private func uvProductGLBBaseColorImage(_ data:Data) throws -> Data {
        func u32(_ offset:Int) -> UInt32 { data.withUnsafeBytes { UInt32(littleEndian:$0.loadUnaligned(fromByteOffset:offset,as:UInt32.self)) } }
        let jsonLength=Int(u32(12)),binaryStart=20+jsonLength+8
        let object=try XCTUnwrap(JSONSerialization.jsonObject(with:data.subdata(in:20..<20+jsonLength)) as? [String:Any])
        let meshes=try XCTUnwrap(object["meshes"] as? [[String:Any]])
        let primitives=try XCTUnwrap(meshes.first?["primitives"] as? [[String:Any]])
        let materialIndex=try XCTUnwrap(primitives.first?["material"] as? Int)
        let materials=try XCTUnwrap(object["materials"] as? [[String:Any]])
        guard materials.indices.contains(materialIndex) else { throw CocoaError(.fileReadCorruptFile) }
        let pbr=try XCTUnwrap(materials[materialIndex]["pbrMetallicRoughness"] as? [String:Any])
        let map=try XCTUnwrap(pbr["baseColorTexture"] as? [String:Any]),textureIndex=try XCTUnwrap(map["index"] as? Int)
        XCTAssertEqual(map["texCoord"] as? Int ?? 0,0,"The primitive-linked image must use active TEXCOORD_0")
        let textures=try XCTUnwrap(object["textures"] as? [[String:Any]])
        guard textures.indices.contains(textureIndex) else { throw CocoaError(.fileReadCorruptFile) }
        let imageIndex=try XCTUnwrap(textures[textureIndex]["source"] as? Int),images=try XCTUnwrap(object["images"] as? [[String:Any]])
        guard images.indices.contains(imageIndex) else { throw CocoaError(.fileReadCorruptFile) }
        let viewIndex=try XCTUnwrap(images[imageIndex]["bufferView"] as? Int),views=try XCTUnwrap(object["bufferViews"] as? [[String:Any]])
        guard views.indices.contains(viewIndex) else { throw CocoaError(.fileReadCorruptFile) }
        let start=binaryStart+(views[viewIndex]["byteOffset"] as? Int ?? 0),length=try XCTUnwrap(views[viewIndex]["byteLength"] as? Int)
        guard start >= 0,length >= 0,start+length <= data.count else { throw CocoaError(.fileReadCorruptFile) }
        return data.subdata(in:start..<start+length)
    }
    #endif

    private nonisolated static func torus() -> RenderMesh {
        let uCount=24,vCount=12
        var positions:[SIMD3<Float>]=[],normals:[SIMD3<Float>]=[],indices:[UInt32]=[]
        for u in 0..<uCount { for v in 0..<vCount {
            let a=Float(u)*2 * .pi/Float(uCount),b=Float(v)*2 * .pi/Float(vCount)
            positions.append(SIMD3((12+3*cos(b))*cos(a),3*sin(b),(12+3*cos(b))*sin(a)))
            normals.append(SIMD3(cos(b)*cos(a),sin(b),cos(b)*sin(a)))
        } }
        for u in 0..<uCount { for v in 0..<vCount {
            let a=UInt32(u*vCount+v),b=UInt32(((u+1)%uCount)*vCount+v)
            let c=UInt32(((u+1)%uCount)*vCount+(v+1)%vCount),d=UInt32(u*vCount+(v+1)%vCount)
            indices += [a,d,b,b,d,c]
        } }
        return RenderMesh(positions:positions,normals:normals,indices:indices)
    }

    /// Independent glTF accessor read: asserts actual exported float bytes,
    /// not a call back into the production UV helper.
    private nonisolated static func readGLBUVs(_ data:Data) throws -> [SIMD2<Float>] {
        func u32(_ offset:Int) -> UInt32 { data.withUnsafeBytes { UInt32(littleEndian:$0.loadUnaligned(fromByteOffset:offset,as:UInt32.self)) } }
        XCTAssertEqual(u32(0),0x46546c67)
        let jsonLength=Int(u32(12)), binaryStart=20+jsonLength+8
        let json=try XCTUnwrap(JSONSerialization.jsonObject(with:data.subdata(in:20..<20+jsonLength)) as? [String:Any])
        let meshes=try XCTUnwrap(json["meshes"] as? [[String:Any]])
        let primitives=try XCTUnwrap(meshes.first?["primitives"] as? [[String:Any]])
        let attributes=try XCTUnwrap(primitives.first?["attributes"] as? [String:Any])
        let uvIndex=try XCTUnwrap(attributes["TEXCOORD_0"] as? Int)
        let accessors=try XCTUnwrap(json["accessors"] as? [[String:Any]]), accessor=accessors[uvIndex]
        XCTAssertEqual(accessor["componentType"] as? Int,5126); XCTAssertEqual(accessor["type"] as? String,"VEC2")
        let views=try XCTUnwrap(json["bufferViews"] as? [[String:Any]])
        let view=views[try XCTUnwrap(accessor["bufferView"] as? Int)]
        let count=try XCTUnwrap(accessor["count"] as? Int)
        let offset=binaryStart+(view["byteOffset"] as? Int ?? 0)+(accessor["byteOffset"] as? Int ?? 0)
        let stride=view["byteStride"] as? Int ?? 8
        guard offset >= 0, offset+max(count-1,0)*stride+8 <= data.count else { throw CocoaError(.fileReadCorruptFile) }
        return (0..<count).map { SIMD2(Float(bitPattern:u32(offset+$0*stride)),Float(bitPattern:u32(offset+$0*stride+4))) }
    }
}
