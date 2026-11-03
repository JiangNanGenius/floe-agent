// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import simd
@testable import FloeCAD

/// Supplied source; not executed by the private implementation lane. Assertions
/// inspect real decoded pixels, triangle occlusion, native storage and GLB bytes.
@MainActor final class CADTexturePaintBakeTests:XCTestCase {
    private var work:URL!
    private var opened:[FloeCADDocument]=[]
    override func setUp() async throws {
        work=FileManager.default.temporaryDirectory.appendingPathComponent("PaintBake-\(UUID())")
        try FileManager.default.createDirectory(at:work,withIntermediateDirectories:true)
    }
    override func tearDown() async throws {
        #if DEBUG
        CADTexturePaintService.testBeforeCompute=nil;CADTexturePaintService.testBeforeCommit=nil
        #endif
        for doc in opened where !doc.isClosed { doc.close() }
        if let work { try? FileManager.default.removeItem(at:work) }
    }
    private func plane(_ span:Float=10,overlap:Bool=false)->RenderMesh {
        let p:[SIMD3<Float>]=[SIMD3(0,0,0),SIMD3(span,0,0),SIMD3(span,span,0),SIMD3(0,span,0)]
        let uv:[SIMD2<Float>]=overlap ? [SIMD2(0,0),SIMD2(1,0),SIMD2(0,1),SIMD2(1,0)] : [SIMD2(0,0),SIMD2(1,0),SIMD2(1,1),SIMD2(0,1)]
        return RenderMesh(positions:p,normals:[SIMD3<Float>](repeating:SIMD3(0,0,1),count:4),indices:[0,1,2,0,2,3],texcoords:uv)
    }
    private func fixture(overlap:Bool=false)async throws->(FloeCADDocument,BodyID) {
        let doc=try await FloeCADDocument.create(at:work.appendingPathComponent("\(UUID()).floecad"),name:"Paint pixels")
        opened.append(doc)
        var body=Body(id:BodyID(),name:"Paint plane",transform:.identity,primitive:nil,render:plane(overlap:overlap),revision:0)
        body.material=BodyMaterialSpec(baseColor:SIMD4(1,1,1,0.8),metallic:0.2,roughness:0.7)
        doc.session.perform(AddBodyCommand(body:body));return (doc,body.id)
    }
    private func pixels(_ data:Data)throws->CADExportImage.Pixels {
        guard case let .success(image)=CADExportImage.decode(data),let pixels=CADExportImage.pixels(image) else { throw CADTexturePaintFailure(code:"test_image",message:"PNG pixels unavailable") };return pixels
    }
    private func read(_ doc:FloeCADDocument,_ id:BodyID)async throws->[String:Any] {
        let reply=await CADMaterialService(document:doc).handleAsync(action:"paint.read",args:["body_id":id.raw.uuidString,"resolution":64])
        XCTAssertEqual(reply["ok"] as? Bool,true,"\(reply)");return reply
    }
    private func strokeArgs(_ id:BodyID,_ read:[String:Any])->[String:Any] {
        ["body_id":id.raw.uuidString,"source_sha256":read["source_sha256"] as? String ?? "","expected_change_count":read["change_count"] as? Int ?? -1,
         "resolution":64,"hits":[["triangle":0,"barycentric":[0.25,0.5,0.25]]],"color_srgb":[1,0,0,1],"radius_pixels":4,"opacity":1]
    }
    func testLocalPixelsSingleUndoPreserveGeometryOtherMapsAndRestoreExactTextureBytes()async throws {
        let (doc,id)=try await fixture(),body=try XCTUnwrap(doc.session.document.body(with:id)),beforeMesh=body.render,beforeUV=body.uvData
        let report=try await read(doc,id),depth=doc.session.undoStack.undoCommands.count
        let reply=await CADMaterialService(document:doc).handleAsync(action:"paint.stroke",args:strokeArgs(id,report))
        XCTAssertEqual(reply["ok"] as? Bool,true,"\(reply)");XCTAssertEqual(reply["mutated"] as? Bool,true)
        XCTAssertEqual(doc.session.undoStack.undoCommands.count,depth+1)
        let painted=try XCTUnwrap(doc.session.document.body(with:id)),bytes=try XCTUnwrap(painted.material?.baseColorTexture),image=try pixels(bytes)
        let center=(15*64+47)*4
        XCTAssertEqual(Array(image.rgba[center..<center+4]),[255,0,0,255])
        XCTAssertEqual(Array(image.rgba[0..<4]),[255,255,255,255],"Far pixels outside the brush must remain white.")
        XCTAssertGreaterThan(try XCTUnwrap(reply["changed_pixels"] as? Int),0)
        XCTAssertLessThan(try XCTUnwrap(reply["changed_pixels"] as? Int),100)
        XCTAssertEqual(painted.render,beforeMesh);XCTAssertEqual(painted.uvData,beforeUV)
        XCTAssertEqual(painted.material?.baseColor.w,0.8);XCTAssertEqual(painted.material?.roughness,0.7)
        XCTAssertEqual(painted.material?.textureOrientation(for:.baseColor),.topLeft)
        XCTAssertEqual(painted.material?.verifiedTextureMetadata(for:.baseColor)?.sha256,CADMaterialTexture.digest(bytes))
        doc.session.undo();XCTAssertEqual(doc.session.document.body(with:id)?.material,body.material)
        doc.session.redo();XCTAssertEqual(doc.session.document.body(with:id)?.material?.baseColorTexture,bytes)
    }
    func testRealGeometryOccluderAndWorldDistanceControlAOInsteadOfFlatColorFill()throws {
        let mesh=plane(),material=BodyMaterialSpec(baseColor:SIMD4(1,1,1,1),metallic:0,roughness:1)
        let request=CADTexturePaintRequest(kind:.ao,resolution:64,samples:16,maxDistance:50)
        let bare=CADTexturePaintSource(mesh:mesh,transform:.identity,material:material,uvData:nil,occluders:[])
        let unoccluded=try CADTexturePaintKernel.compute(bare,request:request,budget:.init(cancellation:CADMeshCancellation()))
        XCTAssertEqual(unoccluded.occludedRays,0);XCTAssertGreaterThan(unoccluded.rays,0)
        let roofMesh=plane(200)
        var near=Transform3D.identity;near.translation=SIMD3(-100,-100,2)
        let sheltered=CADTexturePaintSource(mesh:mesh,transform:.identity,material:material,uvData:nil,occluders:[.init(mesh:roofMesh,transform:near)])
        let baked=try CADTexturePaintKernel.compute(sheltered,request:request,budget:.init(cancellation:CADMeshCancellation()))
        XCTAssertGreaterThan(baked.occludedRays,0)
        let center=(32*64+32)*4,clearPixels=try pixels(unoccluded.png),darkPixels=try pixels(baked.png)
        XCTAssertEqual(clearPixels.rgba[center],255);XCTAssertLessThan(darkPixels.rgba[center],100)
        XCTAssertEqual(darkPixels.rgba[center+3],255)
        var far=near;far.translation.z=100
        let distant=CADTexturePaintSource(mesh:mesh,transform:.identity,material:material,uvData:nil,occluders:[.init(mesh:roofMesh,transform:far)])
        let outsideDistance=try CADTexturePaintKernel.compute(distant,request:request,budget:.init(cancellation:CADMeshCancellation()))
        XCTAssertEqual(outsideDistance.occludedRays,0);XCTAssertEqual(try pixels(outsideDistance.png),clearPixels)
        XCTAssertEqual(try CADTexturePaintKernel.compute(sheltered,request:request,budget:.init(cancellation:CADMeshCancellation())).png,baked.png,"Deterministic samples must reproduce the same image.")
    }
    func testOverlapAndStalePinsRefuseWithoutChangingMaterialOrHistory()async throws {
        let (doc,id)=try await fixture(overlap:true),before=doc.session.document.body(with:id)?.material,depth=doc.session.undoStack.undoCommands.count
        let refusal=await CADMaterialService(document:doc).handleAsync(action:"paint.read",args:["body_id":id.raw.uuidString,"resolution":64])
        XCTAssertEqual(refusal["error"] as? String,"paint_overlapping_uv")
        let invalid=await CADMaterialService(document:doc).handleAsync(action:"paint.stroke",args:["body_id":id.raw.uuidString,"source_sha256":"stale","expected_change_count":0,
            "hits":[["triangle":0,"barycentric":[1,0,0]]],"color_srgb":[1,0,0,1]])
        XCTAssertEqual(invalid["ok"] as? Bool,false);XCTAssertEqual(doc.session.undoStack.undoCommands.count,depth)
        XCTAssertEqual(doc.session.document.body(with:id)?.material,before)
    }
    func testBottomLeftLinearPixelsAreNormalizedAndOtherTextureMetadataSurvives()throws {
        let mesh=plane()
        let raw=CADExportImage.Pixels(width:64,height:64,rgba:(0..<64*64).flatMap { i->[UInt8] in i<64*32 ? [128,0,0,100] : [0,128,0,200] })
        let data=try XCTUnwrap(CADExportImage.encodePNG(raw)),texture=CADMaterialTexture(slot:.baseColor,colorSpace:.linear,orientation:.bottomLeft,bytes:data)
        var material=BodyMaterialSpec(baseColor:SIMD4(1,1,1,0.6),metallic:0.1,roughness:0.4)
        material.baseColorTexture=data;material.textureMetadata=[texture.metadata]
        let other=CADMaterialTexture(slot:.normal,colorSpace:.linear,orientation:.bottomLeft,bytes:data)
        material.normalTexture=data;material.textureMetadata?.append(other.metadata)
        let source=CADTexturePaintSource(mesh:mesh,transform:.identity,material:material,uvData:nil,occluders:[])
        let result=try CADTexturePaintKernel.compute(source,request:.init(kind:.stroke,resolution:64,hits:[.init(triangle:0,barycentric:SIMD3(0.25,0.5,0.25))],radius:2,color:SIMD4(0,0,1,1)),budget:.init(cancellation:CADMeshCancellation()))
        let out=try pixels(result.png)
        XCTAssertEqual(out.rgba[3],200,"The untouched top image row is the original bottom row, retaining alpha.")
        XCTAssertLessThanOrEqual(abs(Int(out.rgba[1])-Int((CADExportImage.linearToSRGB(128.0/255)*255).rounded())),1)
        XCTAssertEqual(result.material.normalTexture,data);XCTAssertEqual(result.material.verifiedTextureMetadata(for:.normal),other.metadata)
        XCTAssertEqual(result.material.baseColor.w,0.6)
    }
    #if DEBUG
    func testCancelledWorkerJoinsAndCannotConsumeUndoOrChangePixels()async throws {
        let (doc,id)=try await fixture(),report=try await read(doc,id),before=doc.session.document.body(with:id)?.material,depth=doc.session.undoStack.undoCommands.count
        let entered=XCTestExpectation(description:"Value worker entered"),release=DispatchSemaphore(value:0)
        CADTexturePaintService.testBeforeCompute={entered.fulfill();_ = release.wait(timeout:.now()+30)}
        let args=strokeArgs(id,report),task=Task<String?,Never> { @MainActor in
            let reply=await CADMaterialService(document:doc).handleAsync(action:"paint.stroke",args:args)
            return reply["error"] as? String
        }
        await fulfillment(of:[entered],timeout:10)
        task.cancel();release.signal();let reply=await task.value
        CADTexturePaintService.testBeforeCompute=nil
        XCTAssertEqual(reply,"cancelled");XCTAssertEqual(doc.session.undoStack.undoCommands.count,depth)
        XCTAssertEqual(doc.session.document.body(with:id)?.material,before)
    }
    func testLateResultAfterRealDocumentChangeKeepsUserEdit()async throws {
        let (doc,id)=try await fixture(),report=try await read(doc,id),before=doc.session.document.body(with:id)?.material,depth=doc.session.undoStack.undoCommands.count
        let entered=XCTestExpectation(description:"Pixels computed"),release=DispatchSemaphore(value:0)
        CADTexturePaintService.testBeforeCommit={entered.fulfill();_ = release.wait(timeout:.now()+30)}
        let args=strokeArgs(id,report),task=Task<String?,Never> { @MainActor in
            let reply=await CADMaterialService(document:doc).handleAsync(action:"paint.stroke",args:args)
            return reply["error"] as? String
        }
        await fulfillment(of:[entered],timeout:10)
        doc.session.perform(AddSketchCommand(sketch:Sketch(name:"Concurrent user edit",plane:.ground,entities:[])))
        release.signal();let reply=await task.value;CADTexturePaintService.testBeforeCommit=nil
        XCTAssertEqual(reply,"document_changed")
        XCTAssertEqual(doc.session.undoStack.undoCommands.count,depth+1)
        XCTAssertTrue(doc.session.document.sketches.contains{$0.name=="Concurrent user edit"})
        XCTAssertEqual(doc.session.document.body(with:id)?.material,before)
    }
    #endif
    func testStrokeUndoAOBakeSaveReopenAndActualGLBImageUVsAgree()async throws {
        let (doc,id)=try await fixture(),read=try await read(doc,id),initial=try XCTUnwrap(doc.session.document.body(with:id))
        let stroke=await CADMaterialService(document:doc).handleAsync(action:"paint.stroke",args:strokeArgs(id,read))
        XCTAssertEqual(stroke["ok"] as? Bool,true,"\(stroke)")
        doc.session.undo();XCTAssertEqual(doc.session.document.body(with:id)?.material,initial.material)
        doc.session.redo()
        var roof=Body(id:BodyID(),name:"Real AO roof",transform:.identity,primitive:nil,render:plane(200),revision:0)
        roof.transform.translation=SIMD3(-100,-100,2);doc.session.perform(AddBodyCommand(body:roof))
        let fresh=try await self.read(doc,id),before=try XCTUnwrap(doc.session.document.body(with:id)?.material?.baseColorTexture)
        let baked=await CADMaterialService(document:doc).handleAsync(action:"paint.bakeAO",args:["body_id":id.raw.uuidString,"source_sha256":fresh["source_sha256"] as? String ?? "",
            "expected_change_count":fresh["change_count"] as? Int ?? -1,"samples":16,"max_distance_mm":50,"occluder_body_ids":[roof.id.raw.uuidString]])
        XCTAssertEqual(baked["ok"] as? Bool,true,"\(baked)");XCTAssertGreaterThan(try XCTUnwrap(baked["occluded_rays"] as? Int),0)
        let final=try XCTUnwrap(doc.session.document.body(with:id)),bytes=try XCTUnwrap(final.material?.baseColorTexture)
        XCTAssertNotEqual(try pixels(bytes),try pixels(before));XCTAssertEqual(final.render,initial.render);XCTAssertEqual(final.uvData,initial.uvData)
        let exported=try glbImageAndUVs(GLBExporter.glb(bodies:[final]))
        XCTAssertEqual(exported.image,bytes);XCTAssertEqual(exported.uv,try XCTUnwrap(final.render.texcoords))
        let url=doc.url,saved=await doc.save();XCTAssertTrue(saved.succeeded,saved.error ?? "");doc.close()
        let reopened=try await FloeCADDocument.open(at:url);opened.append(reopened)
        let retained=try XCTUnwrap(reopened.session.document.body(with:id))
        XCTAssertEqual(retained.material,final.material);XCTAssertEqual(retained.render.texcoords,initial.render.texcoords)
        let reexported=try glbImageAndUVs(GLBExporter.glb(bodies:[retained]))
        XCTAssertEqual(reexported.image,bytes);XCTAssertEqual(reexported.uv,exported.uv)
    }
    func testOpaqueDocumentRefusesPaintWritesBeforeArgumentValidation()async throws {
        let url=work.appendingPathComponent("opaque.floecad")
        try await CADAssociativeFormatFixture.basicPackage(at:url)
        try CADAssociativeFormatFixture.makeOpaque(url,kind:.definitionKind)
        let doc=try await FloeCADDocument.open(at:url);opened.append(doc)
        let before=try CADAssociativeFormatFixture.bytes(url),depth=doc.session.undoStack.undoCommands.count
        for action in CADTexturePaintService.mutations {
            let reply=await CADMaterialService(document:doc).handleAsync(action:action,args:[:])
            XCTAssertEqual(reply["error"] as? String,"read_only");XCTAssertEqual(reply["mutated"] as? Bool,false)
        }
        XCTAssertEqual(doc.session.undoStack.undoCommands.count,depth);XCTAssertEqual(try CADAssociativeFormatFixture.bytes(url),before)
    }
    private func glbImageAndUVs(_ data:Data)throws->(image:Data,uv:[SIMD2<Float>]) {
        func u32(_ offset:Int)->Int { data.withUnsafeBytes{Int(UInt32(littleEndian:$0.loadUnaligned(fromByteOffset:offset,as:UInt32.self)))} }
        XCTAssertEqual(u32(0),0x46546c67)
        let jsonLength=u32(12),object=try XCTUnwrap(JSONSerialization.jsonObject(with:data.subdata(in:20..<20+jsonLength)) as? [String:Any])
        let binaryStart=20+jsonLength+8
        let meshes=try XCTUnwrap(object["meshes"] as? [[String:Any]]),primitive=try XCTUnwrap((meshes[0]["primitives"] as? [[String:Any]])?.first)
        let materialIndex=try XCTUnwrap(primitive["material"] as? Int),materials=try XCTUnwrap(object["materials"] as? [[String:Any]])
        let pbr=try XCTUnwrap(materials[materialIndex]["pbrMetallicRoughness"] as? [String:Any]),textureIndex=try XCTUnwrap((pbr["baseColorTexture"] as? [String:Any])?["index"] as? Int)
        let textures=try XCTUnwrap(object["textures"] as? [[String:Any]]),imageIndex=try XCTUnwrap(textures[textureIndex]["source"] as? Int)
        let images=try XCTUnwrap(object["images"] as? [[String:Any]]),viewIndex=try XCTUnwrap(images[imageIndex]["bufferView"] as? Int),views=try XCTUnwrap(object["bufferViews"] as? [[String:Any]])
        let imageView=views[viewIndex],offset=(imageView["byteOffset"] as? Int) ?? 0,length=try XCTUnwrap(imageView["byteLength"] as? Int)
        let attributes=try XCTUnwrap(primitive["attributes"] as? [String:Any]),accessorIndex=try XCTUnwrap(attributes["TEXCOORD_0"] as? Int),accessors=try XCTUnwrap(object["accessors"] as? [[String:Any]])
        let accessor=accessors[accessorIndex],uvView=views[try XCTUnwrap(accessor["bufferView"] as? Int)],count=try XCTUnwrap(accessor["count"] as? Int)
        let uvOffset=binaryStart+((uvView["byteOffset"] as? Int) ?? 0)+((accessor["byteOffset"] as? Int) ?? 0),stride=(uvView["byteStride"] as? Int) ?? 8
        XCTAssertEqual(accessor["componentType"] as? Int,5126)
        let uv=data.withUnsafeBytes { raw in (0..<count).map { i in SIMD2(Float(bitPattern:UInt32(littleEndian:raw.loadUnaligned(fromByteOffset:uvOffset+i*stride,as:UInt32.self))),Float(bitPattern:UInt32(littleEndian:raw.loadUnaligned(fromByteOffset:uvOffset+i*stride+4,as:UInt32.self)))) } }
        return (data.subdata(in:binaryStart+offset..<binaryStart+offset+length),uv)
    }
}
