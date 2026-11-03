// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import simd
@testable import FloeCAD
#if canImport(UIKit) && canImport(RealityKit)
import UIKit
import RealityKit
#endif

@MainActor final class CADMaterialNodeTests:XCTestCase {
    private var directory:URL!
    private var opened:[FloeCADDocument]=[]
    override func setUp() async throws { directory=FileManager.default.temporaryDirectory.appendingPathComponent("MaterialNodes-\(UUID())");try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true) }
    override func tearDown() async throws {
        CADMaterialGraphService.testBeforeCompute=nil;CADMaterialGraphService.testBeforeCommit=nil
        opened.forEach{$0.close()};opened=[];if let directory { try? FileManager.default.removeItem(at:directory) }
    }
    private func advanced() -> CADAdvancedMaterial { var v=CADAdvancedMaterial();v.clearcoat=0.8;v.coatRoughness=0.23;v.anisotropyLevel=0.65;v.anisotropyAngle=0.31;v.specular=0.4;v.sheen=SIMD3(0.1,0.2,0.3);return v }
    private func pixels(_ data:Data) throws -> CADExportImage.Pixels {
        guard case let .success(decoded)=CADExportImage.decode(data),let pixels=CADExportImage.pixels(decoded) else { throw CADMaterialGraphError.invalid };return pixels
    }
    private func fixture() async throws -> (FloeCADDocument,BodyID) {
        let doc=try await FloeCADDocument.create(at:directory.appendingPathComponent("\(UUID()).floecad"),name:"Owned node surface");opened.append(doc)
        let id=BodyID();doc.session.recordAndRebuild([FeatureNode(name:"Surface sphere",kind:.primitive(spec:.sphere(radius:20),placement:.identity),outputBodyIDs:[id])],title:"Fixture")
        var material=BodyMaterialSpec(baseColor:SIMD4(0.35,0.18,0.08,1),metallic:0.2,roughness:0.2)
        material.advanced=advanced();material.uvMapping=CADMaterialUVMapping(source:.boxProjection,axis:.y,scaleMM:SIMD2(40,40))
        doc.session.perform(SetMaterialCommand(bodyIDs:[id],material:material,document:doc.session.document));return (doc,id)
    }
    private func recipe(_ graph:CADMaterialNodeGraph) throws -> [String:Any] {
        var raw=try XCTUnwrap(try JSONSerialization.jsonObject(with:JSONEncoder().encode(graph)) as? [String:Any]);for key in ["images","recipeSHA256","bakedSHA256"] { raw[key]=nil };return raw
    }
    private func bake(_ doc:FloeCADDocument,_ id:BodyID,_ graph:CADMaterialNodeGraph) async throws -> [String:Any] {
        await CADMaterialService(document:doc).handleAsync(action:"graph.bake",args:["body_id":id.raw.uuidString,"expected_change_count":doc.liveChangeCount,"graph":try recipe(graph)])
    }
    func testActualDAGImageMultiplyMixCheckerAndScalarPixels() throws {
        let png=try XCTUnwrap(CADExportImage.encodePNG(.init(width:2,height:2,rgba:[UInt8](repeating:128,count:16).enumerated().map{$0.offset%4==3 ? 255:$0.element})))
        let image=CADMaterialTexture(slot:.baseColor,colorSpace:.linear,bytes:png)
        let a=CADMaterialNode(operation:.image,imageID:image.id.raw,imageSHA256:image.sha256),b=CADMaterialNode(operation:.value,value:0.5)
        let mul=CADMaterialNode(operation:.multiply,inputs:[a.id,b.id]),red=CADMaterialNode(operation:.color,color:SIMD4(1,0,0,1))
        let mixed=CADMaterialNode(operation:.mix,inputs:[mul.id,red.id],factor:0.25),checker=CADMaterialNode(operation:.checker,inputs:[mul.id,mixed.id],frequency:2)
        var graph=CADMaterialNodeGraph(nodes:[a,b,mul,red,mixed,checker],outputs:["baseColor":checker.id,"roughness":b.id,"metallic":b.id],images:[image],resolution:64)
        let result=try CADMaterialGraphKernel.compute(graph,cancellation:CADMeshCancellation()),base=try pixels(XCTUnwrap(result.textures.first{$0.slot == .baseColor}).bytes)
        // Independent reference bytes: linear (128/255)*.5 -> sRGB 137;
        // .75*((128/255)*.5)+.25*red -> (177,120,120).
        func pixel(_ x:Int,_ y:Int) -> [UInt8] { Array(base.rgba[((y*64+x)*4)..<((y*64+x)*4+4)]) }
        XCTAssertEqual(pixel(1,1),[137,137,137,255]);XCTAssertEqual(pixel(40,1),[177,120,120,255])
        let scalar=try pixels(XCTUnwrap(result.textures.first{$0.slot == .roughness}).bytes);XCTAssertEqual(Array(scalar.rgba.prefix(4)),[128,128,128,255])
        XCTAssertEqual(try CADMaterialGraphKernel.compute(graph,cancellation:CADMeshCancellation()).textures.map(\.bytes),result.textures.map(\.bytes))
        try result.graph.validate(requireBake:true)
        graph.nodes[0].operation = .mix;graph.nodes[0].inputs=[checker.id,b.id];graph.nodes[0].factor=0.5
        XCTAssertThrowsError(try graph.validate(),"Cycles must fail, including disconnected cycles")
        let cancelled=CADMeshCancellation();cancelled.cancel();XCTAssertThrowsError(try CADMaterialGraphKernel.compute(.checker(),cancellation:cancelled))
        var oversized=CADMaterialNodeGraph.checker();oversized.resolution=1024;XCTAssertThrowsError(try oversized.validate())
    }
    func testSnapshotsUndoSaveReopenLibraryCopyAndPackageFloor() async throws {
        let (doc,id)=try await fixture()
        let seedPNG=try XCTUnwrap(CADExportImage.encodePNG(.init(width:2,height:2,rgba:[255,30,10,255,20,220,30,255,20,40,240,255,180,180,180,255])))
        let seed=CADMaterialTexture(slot:.baseColor,colorSpace:.srgb,bytes:seedPNG)
        var source=try XCTUnwrap(doc.session.document.body(with:id)?.material);source.baseColorTexture=seedPNG;source.textureMetadata=[seed.metadata]
        doc.session.perform(SetMaterialCommand(bodyIDs:[id],material:source,document:doc.session.document))
        var recipe=CADMaterialNodeGraph.checker();let image=CADMaterialNode(operation:.image,imageID:seed.id.raw,imageSHA256:seed.sha256)
        let mix=CADMaterialNode(operation:.mix,inputs:[recipe.outputs["baseColor"]!,image.id],factor:0.5);recipe.nodes += [image,mix];recipe.outputs["baseColor"]=mix.id
        let original=doc.session.document.body(with:id)?.material,mesh=doc.session.document.body(with:id)?.render,count=doc.session.undoStack.undoCommands.count
        let reply=try await bake(doc,id,recipe);XCTAssertEqual(reply["ok"] as? Bool,true,"\(reply)")
        XCTAssertEqual(doc.session.undoStack.undoCommands.count,count+1)
        let material=try XCTUnwrap(doc.session.document.body(with:id)?.material);XCTAssertEqual(material.advanced,advanced());XCTAssertNotNil(material.nodeGraph);XCTAssertNil(material.materialID)
        XCTAssertEqual(doc.session.document.body(with:id)?.render,mesh)
        doc.session.undo();XCTAssertEqual(doc.session.document.body(with:id)?.material,original);doc.session.redo()
        var definition=CADMaterialDefinition(spec:material,name:"Snapshot"),library=CADMaterialLibrary(entries:[definition])
        let data=try XCTUnwrap(CADMaterialLibraryCodec.encode(library));XCTAssertEqual(CADMaterialLibraryCodec.decode(data).schemaVersion,2)
        doc.session.perform(SetMaterialLibraryDataCommand(before:nil,after:data))
        definition.advanced?.clearcoat=0;library.upsert(definition)
        doc.session.perform(SetMaterialLibraryDataCommand(before:data,after:CADMaterialLibraryCodec.encode(library)))
        XCTAssertEqual(doc.session.document.body(with:id)?.material,material,"Library edits do not mutate a snapshot")
        let saved=await doc.save();XCTAssertTrue(saved.succeeded,saved.error ?? "");XCTAssertEqual(doc.session.project.formatVersion,8)
        let url=doc.url;doc.close();let reopened=try await FloeCADDocument.open(at:url);opened.append(reopened)
        XCTAssertEqual(reopened.session.document.body(with:id)?.material,material)
        XCTAssertEqual(reopened.session.document.body(with:id)?.material?.nodeGraph?.images.first?.sha256,seed.sha256)
        let rerun=try await bake(reopened,id,XCTUnwrap(reopened.session.document.body(with:id)?.material?.nodeGraph))
        XCTAssertEqual(rerun["ok"] as? Bool,true)
        XCTAssertEqual(reopened.session.document.body(with:id)?.material?.nodeGraph?.bakedSHA256,material.nodeGraph?.bakedSHA256,"Rebaking resolves the original immutable image, not its previous baked output")
        let legacy=Data(#"{"baseColor":[0.2,0.3,0.4,1],"metallic":0,"roughness":0.5}"#.utf8)
        let old=try JSONDecoder().decode(BodyMaterialSpec.self,from:legacy);XCTAssertNil(old.advanced);XCTAssertNil(old.nodeGraph);XCTAssertFalse(CADMaterialAppearanceIntent.inspect(legacy).present)
        XCTAssertEqual(CADMaterialLibraryCodec.decode(try XCTUnwrap(CADMaterialLibraryCodec.encode(.empty))).schemaVersion,1)
    }
    func testFutureMaterialLibraryAndNestedGraphPreserveReadOnlyBytes() async throws {
        let (doc,id)=try await fixture();let material=try XCTUnwrap(doc.session.document.body(with:id)?.material),data=try JSONEncoder().encode(material)
        var raw=try XCTUnwrap(try JSONSerialization.jsonObject(with:data) as? [String:Any]),advanced=try XCTUnwrap(raw["advanced"] as? [String:Any]);advanced["futureTransmission"]=0.6;raw["advanced"]=advanced
        let unknown=try JSONSerialization.data(withJSONObject:raw);XCTAssertTrue(CADMaterialAppearanceIntent.inspect(unknown).opaque)
        let graph=try CADMaterialGraphKernel.compute(.checker(),cancellation:CADMeshCancellation()).graph
        var graphRaw=try recipe(graph);graphRaw["futureShader"]=true
        XCTAssertThrowsError(try JSONDecoder().decode(CADMaterialNodeGraph.self,from:JSONSerialization.data(withJSONObject:graphRaw)))
        var library=try XCTUnwrap(try JSONSerialization.jsonObject(with:JSONEncoder().encode(CADMaterialLibrary(entries:[CADMaterialDefinition(name:"Old")])) ) as? [String:Any]);library["schemaVersion"]=99
        let future=try JSONSerialization.data(withJSONObject:library);XCTAssertFalse(CADMaterialAppearanceIntent.readableLibrary(future))
        let file=directory.appendingPathComponent("owned-future-library.json");try future.write(to:file)
        XCTAssertThrowsError(try CADMaterialLibraryFileStore.write(.empty,to:file));XCTAssertEqual(try Data(contentsOf:file),future)
        let supplied=Data(#"{"version":1,"clearcoat":0.7,"coatRoughness":0.2,"anisotropyLevel":0.6,"anisotropyAngle":0.3,"specular":0.4,"sheen":[0.1,0.2,0.3]}"#.utf8)
        let reply=CADMaterialService(document:doc).handle(action:"apply",args:["bodyID":id.raw.uuidString,"advanced":try JSONSerialization.jsonObject(with:supplied)])
        XCTAssertEqual(reply["ok"] as? Bool,true,"\(reply)");XCTAssertEqual(doc.session.document.body(with:id)?.material?.advanced?.clearcoat,0.7)
    }
    func testJoinedWorkerStaleCancellationCloseAndSaveFailure() async throws {
        let (doc,id)=try await fixture();let before=doc.session.document.body(with:id)?.material,graph=try recipe(.checker()),latch=MaterialNodeTestLatch()
        CADMaterialGraphService.testBeforeCompute={latch.pause()};defer { latch.release.signal();CADMaterialGraphService.testBeforeCompute=nil }
        func start(_ external:(any MeshImportCancellationChecking)?=nil) -> Task<Data,Never> {
            Task { @MainActor in let reply=await CADMaterialService(document:doc).handleAsync(action:"graph.bake",args:["body_id":id.raw.uuidString,"graph":graph],cancellation:external);return (try? JSONSerialization.data(withJSONObject:reply)) ?? Data() }
        }
        let first=start();let entered=await Task.detached {latch.wait()}.value;XCTAssertTrue(entered);XCTAssertFalse(latch.onMain)
        var changed=try XCTUnwrap(before);changed.roughness=0.9;doc.session.perform(SetMaterialCommand(bodyIDs:[id],material:changed,document:doc.session.document));latch.release.signal()
        let firstData=await first.value,firstRow=try XCTUnwrap(try JSONSerialization.jsonObject(with:firstData) as? [String:Any]);XCTAssertEqual(firstRow["error"] as? String,"material_graph_stale");XCTAssertEqual(doc.session.document.body(with:id)?.material,changed)
        let external=MeshImportCancellation(),second=start(external);let secondEntered=await Task.detached {latch.wait()}.value;XCTAssertTrue(secondEntered)
        external.cancel();latch.release.signal();let secondData=await second.value,secondRow=try XCTUnwrap(try JSONSerialization.jsonObject(with:secondData) as? [String:Any]);XCTAssertEqual(secondRow["error"] as? String,"material_graph_cancelled")
        CADMaterialGraphService.testBeforeCompute=nil
        let checkpoint=doc.captureEditCheckpoint(),reply=try await bake(doc,id,.checker());XCTAssertEqual(reply["ok"] as? Bool,true)
        let after=doc.liveChangeCount;doc.store.revoke()
        let failed=await CADNativeEditCommit.save(document:doc,changeAfterMutation:after,rollback:.undo,checkpoint:checkpoint)
        XCTAssertFalse(failed.saved);XCTAssertTrue(failed.rolledBack);XCTAssertEqual(doc.session.document.body(with:id)?.material,changed)
        let (closing,cid)=try await fixture()
        CADMaterialGraphService.testBeforeCompute={latch.pause()}
        let closeTask=Task { @MainActor () -> Data in
            let value=await CADMaterialService(document:closing).handleAsync(action:"graph.bake",args:["body_id":cid.raw.uuidString,"graph":graph])
            return (try? JSONSerialization.data(withJSONObject:value)) ?? Data()
        }
        let closeEntered=await Task.detached {latch.wait()}.value;XCTAssertTrue(closeEntered);closing.close()
        let (replacement,rid)=try await fixture();let replacementCount=replacement.liveChangeCount,beforeReplacement=replacement.session.document.body(with:rid)?.material
        latch.release.signal();let closedData=await closeTask.value,closed=try XCTUnwrap(try JSONSerialization.jsonObject(with:closedData) as? [String:Any])
        XCTAssertEqual(closed["ok"] as? Bool,false);XCTAssertEqual(replacement.liveChangeCount,replacementCount);XCTAssertEqual(replacement.session.document.body(with:rid)?.material,beforeReplacement)
    }
    #if canImport(UIKit) && canImport(RealityKit)
    func testConcretePBRFieldsAndIndependentGLBArtifacts() async throws {
        let v=advanced();var pbr=PhysicallyBasedMaterial();CADAdvancedMaterialAdapter.apply(v,to:&pbr,hasUVs:true)
        XCTAssertEqual(pbr.clearcoat.scale,0.8,accuracy:1e-6);XCTAssertEqual(pbr.clearcoatRoughness.scale,0.23,accuracy:1e-6);XCTAssertEqual(pbr.anisotropyLevel.scale,0.65,accuracy:1e-6);XCTAssertEqual(pbr.anisotropyAngle.scale,0.31,accuracy:1e-6);XCTAssertEqual(pbr.specular.scale,0.4,accuracy:1e-6);XCTAssertNotNil(pbr.sheen)
        CADAdvancedMaterialAdapter.apply(v,to:&pbr,hasUVs:false);XCTAssertEqual(pbr.anisotropyLevel.scale,0)
        let (doc,id)=try await fixture();var body=try XCTUnwrap(doc.session.document.body(with:id));body.material?.emissive=SIMD3(0.01,0.02,0.03);body.material?.emissiveStrength=2
        let fields=GLBExporter.glb(bodies:[body]),output=try await bake(doc,id,.checker());XCTAssertEqual(output["ok"] as? Bool,true)
        let baked=try XCTUnwrap(doc.session.document.body(with:id)),bakedGLB=GLBExporter.glb(bodies:[baked]),pngSHA=try XCTUnwrap(baked.material?.nodeGraph?.bakedSHA256?["baseColor"])
        let expected=try JSONSerialization.data(withJSONObject:["clearcoat":0.8,"coatRoughness":0.23,"anisotropy":0.65,"nativeAngle":0.31,"exportRotation":0.0,"specular":0.4,"sheen":[0.1,0.2,0.3],"sheenRoughness":1.0,"bakedBaseColorSHA256":pngSHA])
        for (name,data,type) in [("advanced-fields.glb",fields,"org.khronos.glb"),("baked-graph.glb",bakedGLB,"org.khronos.glb"),("material-expected.json",expected,"public.json")] { let a=XCTAttachment(data:data,uniformTypeIdentifier:type);a.name=name;a.lifetime = .keepAlways;add(a) }
        let originalKey=CADPresentationMaterialResolver.resolve(spec:body.material,bodyID:id.raw,bodyName:"Sphere",hasMeshUVs:false,hasProjectedUVs:true).material.stableKey
        body.material?.advanced?.clearcoat=0
        XCTAssertNotEqual(CADPresentationMaterialResolver.resolve(spec:body.material,bodyID:id.raw,bodyName:"Sphere",hasMeshUVs:false,hasProjectedUVs:true).material.stableKey,originalKey)
    }
    func testRealPresentNonemptyPixelsForEachAdvancedSurfaceClass() async throws {
        let (doc,id)=try await fixture();let clip=try doc.createAnimationClip(name:"Material still",duration:0.1,isLooping:false)
        let body=try XCTUnwrap(doc.session.document.body(with:id)),positions=body.render.positions
        let lo=positions.reduce(SIMD3<Float>(repeating:.greatestFiniteMagnitude),simd_min),hi=positions.reduce(SIMD3<Float>(repeating:-.greatestFiniteMagnitude),simd_max)
        let camera=try doc.saveCamera(CADSavedCamera(name:"Surface witness",projection:.perspective,targetMM:SIMD3<Double>((lo+hi)/2),distanceMM:Double(max(hi.x-lo.x,max(hi.y-lo.y,hi.z-lo.z)))*3,azimuthRadians:0.4,elevationRadians:0.2,frameAspect:1));try doc.selectCamera(id:camera.id)
        var material=try XCTUnwrap(doc.session.document.body(with:id)?.material);material.advanced=nil
        doc.session.perform(SetMaterialCommand(bodyIDs:[id],material:material,document:doc.session.document));let saved=await doc.save();XCTAssertTrue(saved.succeeded)
        doc.session.perform(SetItemVisibilityCommand(item:.body(id),isHidden:true))
        let emptyFrame=try await doc.captureAnimationFramePNG(clipID:clip.id,time:0,width:128,height:128),empty=try pixels(emptyFrame.imageData)
        doc.session.perform(SetItemVisibilityCommand(item:.body(id),isHidden:false))
        let baseline=try await doc.captureAnimationFramePNG(clipID:clip.id,time:0,width:128,height:128),base=try pixels(baseline.imageData)
        // A dark metal reflects its neutral environment. Compare against an
        // actual same-camera empty render instead of assuming red pixels.
        func foreground(_ image:CADExportImage.Pixels) -> Int { stride(from:0,to:image.rgba.count,by:4).filter { offset in (0..<3).contains { abs(Int(image.rgba[offset+$0])-Int(empty.rgba[offset+$0]))>6 } }.count }
        XCTAssertGreaterThan(foreground(base),20)
        let baselineAttachment=XCTAttachment(data:baseline.imageData,uniformTypeIdentifier:"public.png");baselineAttachment.name="advanced-baseline";baselineAttachment.lifetime = .keepAlways;add(baselineAttachment)
        var variants:[(String,CADAdvancedMaterial)]=[]
        var coat=CADAdvancedMaterial();coat.clearcoat=1;coat.coatRoughness=0.05;variants.append(("coat",coat))
        var anis=CADAdvancedMaterial();anis.anisotropyLevel=1;anis.anisotropyAngle=0.7;variants.append(("anisotropy",anis))
        var spec=CADAdvancedMaterial();spec.specular=0;variants.append(("specular",spec))
        var sheen=CADAdvancedMaterial();sheen.sheen=SIMD3(0.8,0.1,0.6);variants.append(("sheen",sheen))
        for (name,value) in variants {
            material.advanced=value;doc.session.perform(SetMaterialCommand(bodyIDs:[id],material:material,document:doc.session.document));let save=await doc.save();XCTAssertTrue(save.succeeded)
            let frame=try await doc.captureAnimationFramePNG(clipID:clip.id,time:0,width:128,height:128),image=try pixels(frame.imageData);XCTAssertGreaterThan(foreground(image),20)
            XCTAssertNotEqual(image.rgba,base.rgba,"Actual advanced shading class must change rendered pixels: \(name)")
            let a=XCTAttachment(data:frame.imageData,uniformTypeIdentifier:"public.png");a.name="advanced-\(name)";a.lifetime = .keepAlways;add(a)
        }
    }
    #endif
}
private nonisolated final class MaterialNodeTestLatch:@unchecked Sendable {
    let entered=DispatchSemaphore(value:0)
    let release=DispatchSemaphore(value:0)
    private let lock=NSLock()
    private var main=true
    func pause() { lock.lock();main=Thread.isMainThread;lock.unlock();entered.signal();_ = release.wait(timeout:.now()+10) }
    func wait() -> Bool { entered.wait(timeout:.now()+10) == .success }
    var onMain:Bool { lock.lock();defer { lock.unlock() };return main }
}
