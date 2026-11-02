// SPDX-License-Identifier: MPL-2.0
// Product-path tests. These are new, unexecuted source until the integration
// owner compiles and runs the actual App-hosted test target.
import Foundation
import XCTest
import simd
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
