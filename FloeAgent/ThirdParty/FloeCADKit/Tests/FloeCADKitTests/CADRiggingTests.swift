// SPDX-License-Identifier: MPL-2.0
import XCTest
import Foundation
import simd
@testable import FloeCAD
#if canImport(UIKit) && canImport(RealityKit)
import UIKit
import ImageIO
import AVFoundation
#endif

@MainActor final class CADRiggingTests:XCTestCase {
    private var directory:URL!
    private var documents:[FloeCADDocument]=[]
    override func setUp() async throws { directory=FileManager.default.temporaryDirectory.appendingPathComponent("Rig-\(UUID())");try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true) }
    override func tearDown() async throws { documents.forEach { $0.close() };documents=[];if let directory { try? FileManager.default.removeItem(at:directory) } }
    @discardableResult private func command(_ document:FloeCADDocument,_ action:String,_ args:[String:Any]=[:]) throws -> [String:Any] {
        let value=CADViewOverlayService(document:document).handle(action:action,args:args)
        XCTAssertEqual(value["ok"] as? Bool,true,"\(value)");guard value["ok"] as? Bool==true else { throw CADRigError.invalid };return value
    }
    private func fixture() async throws -> (FloeCADDocument,BodyID,CADPolygonMeshDefinition) {
        let document=try await FloeCADDocument.create(at:directory.appendingPathComponent("owned.floecad"),name:"Owned rig");documents.append(document)
        let id=BodyID(),definition=CADPolygonMeshDefinition(cage:try .box(width:4,height:20,depth:2))
        let node=FeatureNode(name:"Owned polygon bar",kind:.polygonCage(definition:definition,placement:Transform3D(translation:SIMD3(2,3,4))),outputBodyIDs:[id])
        document.session.recordAndRebuild([node],title:"Fixture")
        try command(document,"rig.bind",["body_id":id.raw.uuidString,"duration":2.0]);return (document,id,definition)
    }
    private func record(_ document:FloeCADDocument) throws -> CADRigRecord { try XCTUnwrap(try CADRigCodec.read(document.session.document.sceneSettingsData)) }
    private func authored(_ document:FloeCADDocument,_ definition:CADPolygonMeshDefinition) throws -> (CADRigRecord,UUID) {
        let root=try record(document).joints[0].id
        try command(document,"rig.joint.add",["name":"Tip","parent_id":root.uuidString,"translation":[0.0,10.0,0.0]])
        let child=try record(document).joints[1].id
        for (i,vertex) in definition.cage.vertices.enumerated() where vertex.point.y>10 {
            let influences:[[String:Any]]=i==2 ? [["joint_id":root.uuidString,"weight":2.0],["joint_id":child.uuidString,"weight":2.0]] : [["joint_id":child.uuidString,"weight":1.0]]
            try command(document,"rig.weight",["vertex_id":vertex.id.uuidString,"influences":influences])
        }
        try command(document,"rig.morph",["name":"Depth","deltas":[["vertex_id":definition.cage.vertices[6].id.uuidString,"delta":[0.0,0.0,3.0]]],"weight":0.0])
        try command(document,"rig.key",["time":0.0])
        let q=simd_quatd(angle:.pi/2,axis:SIMD3(0,0,1)).vector
        try command(document,"rig.pose",["joint_id":child.uuidString,"translation":[0.0,10.0,0.0],"rotation":[q.x,q.y,q.z,q.w]])
        try command(document,"rig.morph.weight",["morph_id":try record(document).morphs[0].id.uuidString,"weight":1.0])
        try command(document,"rig.key",["time":2.0]);try command(document,"rig.clip",["name":"Authored bend"])
        return (try record(document),child)
    }
    private func expected(_ point:SIMD3<Float>,time:Double,definition:CADPolygonMeshDefinition) -> SIMD3<Double> {
        let p=SIMD3<Double>(point),theta=(.pi/2)*time/2
        guard p.y>10 else { return p }
        let delta=(SIMD3<Float>(definition.cage.vertices[6].point)==point) ? 3*time/2:0
        let shifted=SIMD3(p.x,p.y-10,p.z+delta)
        let rotated=SIMD3(cos(theta)*shifted.x-sin(theta)*shifted.y,sin(theta)*shifted.x+cos(theta)*shifted.y+10,shifted.z)
        return SIMD3<Float>(definition.cage.vertices[2].point)==point ? (p+rotated)/2:rotated
    }
    func testInverseBindMorphBeforeSkinNormalizedWeightsAndAnalyticalVertices() async throws {
        let (document,id,definition)=try await fixture();let source=try XCTUnwrap(document.session.document.body(with:id)).render
        let (record,_)=try authored(document,definition),mixed=try XCTUnwrap(record.weights.first(where:{$0.vertexID==definition.cage.vertices[2].id}))
        XCTAssertEqual(mixed.influences.map(\.weight),[0.5,0.5])
        let playback=try XCTUnwrap(document.rigPlayback())
        for time in [0.0,1.0,2.0] {
            let output=try playback.evaluate(at:time)
            for index in source.positions.indices { XCTAssertLessThan(simd_distance(SIMD3<Double>(output.positions[index]),expected(source.positions[index],time:time,definition:definition)),2e-6) }
            XCTAssertTrue(output.normals.allSatisfy { abs(simd_length($0)-1)<1e-6 })
        }
        XCTAssertEqual(document.session.document.body(with:id)?.render,source,"Skinning must never rewrite the source body/cage");XCTAssertNil(document.session.document.body(with:id)?.brep)
    }
    func testAuthoredTimelineOneUndoSaveReopenAndTopologyInvalidation() async throws {
        let (document,id,definition)=try await fixture();_ = try authored(document,definition)
        let clip=try XCTUnwrap(document.animationDocument.activeClip),count=document.session.undoStack.undoCommands.count
        XCTAssertEqual(clip.rigID,try record(document).id);XCTAssertTrue(clip.tracks.isEmpty)
        XCTAssertEqual(CADAnimationDocument.rigSchemaVersion,4);XCTAssertGreaterThanOrEqual(document.animationDocument.schemaVersion,4)
        let before=try document.evaluateAnimation(clipID:clip.id,time:1).rigDeformation
        try command(document,"rig.pose",["joint_id":try record(document).joints[0].id.uuidString,"translation":[1.0,0.0,0.0]])
        XCTAssertEqual(document.session.undoStack.undoCommands.count,count+1)
        XCTAssertEqual(try record(document).poses[0].translation.x,1)
        document.session.undo();XCTAssertEqual(try record(document).poses[0].translation.x,0)
        XCTAssertEqual(try document.evaluateAnimation(clipID:clip.id,time:1).rigDeformation,before)
        document.session.redo();XCTAssertEqual(try record(document).poses[0].translation.x,1);document.session.undo()
        let saved=await document.save();XCTAssertTrue(saved.succeeded,saved.error ?? "")
        let url=document.url;document.close();let reopened=try await FloeCADDocument.open(at:url);documents.append(reopened)
        XCTAssertEqual(try reopened.evaluateAnimation(clipID:clip.id,time:1).rigDeformation,before)
        let source=try XCTUnwrap(CADPolygonMeshService.currentCage(in:reopened.session,bodyID:id))
        var changed=source.definition;for index in changed.cage.vertices.indices { changed.cage.vertices[index].point.x += 1 }
        reopened.session.editFeature(source.node.id,to:.polygonCage(definition:changed,placement:source.body.transform),title:"Changed cage")
        XCTAssertNil(reopened.rigPlayback());XCTAssertThrowsError(try reopened.riggedGLB())
    }
    func testInvalidReferencesFutureFieldsAndCancelledCallerPreserveBytes() async throws {
        let (document,_,definition)=try await fixture();let before=document.session.document.sceneSettingsData,count=document.liveChangeCount
        let reply=CADViewOverlayService(document:document).handle(action:"rig.weight",args:["vertex_id":definition.cage.vertices[0].id.uuidString,"influences":[["joint_id":UUID().uuidString,"weight":1.0]]])
        XCTAssertEqual(reply["ok"] as? Bool,false);XCTAssertEqual(document.liveChangeCount,count);XCTAssertEqual(document.session.document.sceneSettingsData,before)
        var root=try XCTUnwrap(try JSONSerialization.jsonObject(with:XCTUnwrap(before)) as? [String:Any]);var raw=try XCTUnwrap(root["rigging"] as? [String:Any]);var joints=try XCTUnwrap(raw["joints"] as? [[String:Any]])
        joints[0]["ikFuture"]=true;raw["joints"]=joints;root["rigging"]=raw
        let future=try JSONSerialization.data(withJSONObject:root)
        XCTAssertThrowsError(try CADRigCodec.read(future));XCTAssertTrue(CADDocumentFormat.riggingIntent(future).opaque)
        let task=Task { @MainActor () -> Bool in
            try? await Task.sleep(for:.milliseconds(5))
            let result=CADRiggingService(document:document).handle(action:"rig.remove",args:[:]);return result["ok"] as? Bool ?? false
        };task.cancel();let ok=await task.value;XCTAssertFalse(ok);XCTAssertEqual(document.session.document.sceneSettingsData,before)
        var cycle=try record(document);cycle.joints[0].parent=cycle.joints[0].id;XCTAssertThrowsError(try cycle.validate())
    }
    func testRealGLBAndIndependentParserInputArtifacts() async throws {
        let (document,id,definition)=try await fixture();_ = try authored(document,definition)
        let source=try XCTUnwrap(document.session.document.body(with:id)),data=try document.riggedGLB()
        let length=data.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset:12,as:UInt32.self).littleEndian) }
        let json=try XCTUnwrap(try JSONSerialization.jsonObject(with:data.subdata(in:20..<(20+length))) as? [String:Any])
        XCTAssertEqual((json["skins"] as? [Any])?.count,1);XCTAssertEqual((json["animations"] as? [Any])?.count,1)
        var samples:[[String:Any]]=[]
        for time in [0.0,1.0,2.0] {
            let points=source.render.positions.map { p -> [Double] in let local=expected(p,time:time,definition:definition);let world=source.transform.applying(to:local)/1000;return [world.x,world.y,world.z] }
            samples.append(["time":time,"worldPositionsM":points])
        }
        let oracle=try JSONSerialization.data(withJSONObject:["units":"metres","tolerance":2e-7,"samples":samples],options:[.sortedKeys])
        for (name,bytes,type) in [("owned-rig.glb",data,"org.khronos.glb"),("owned-rig-expected.json",oracle,"public.json")] {
            let attachment=XCTAttachment(data:bytes,uniformTypeIdentifier:type);attachment.name=name;attachment.lifetime = .keepAlways;add(attachment)
        }
        let selection=CADExchangeSelection(scope:.part,bodyIDs:[id.raw])
        if case let .success(output,_,_) = document.nativeExchangeExport(format:"glb",pageID:nil,selection:selection,dryRun:false) { XCTAssertEqual(output,data) }
        else { XCTFail("The existing glb exchange route did not export the rigged part") }
    }
    #if canImport(UIKit) && canImport(RealityKit)
    func testActualPresentPixelsAndMP4UseDeformedVertices() async throws {
        let (document,id,definition)=try await fixture();_ = try authored(document,definition)
        var material=BodyMaterialSpec.default;material.baseColor=SIMD4(0.9,0.025,0.025,1)
        document.session.perform(SetMaterialCommand(bodyIDs:[id],material:material,document:document.session.document))
        let camera=try document.saveCamera(CADSavedCamera(name:"Rig witness",projection:.orthographic,targetMM:SIMD3(0,12,0),distanceMM:100,azimuthRadians:0,elevationRadians:0,frameAspect:1));try document.selectCamera(id:camera.id)
        let saved=await document.save();XCTAssertTrue(saved.succeeded)
        let clip=try XCTUnwrap(document.animationDocument.activeClip)
        let a=try await document.captureAnimationFramePNG(clipID:clip.id,time:0,width:128,height:128)
        let b=try await document.captureAnimationFramePNG(clipID:clip.id,time:2,width:128,height:128)
        func witness(_ data:Data) throws -> (count:Int,x:Double) {
            let source=try XCTUnwrap(CGImageSourceCreateWithData(data as CFData,nil)),image=try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil));var rgba=[UInt8](repeating:0,count:image.width*image.height*4)
            try rgba.withUnsafeMutableBytes { bytes in let context=try XCTUnwrap(CGContext(data:bytes.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue));context.draw(image,in:CGRect(x:0,y:0,width:CGFloat(image.width),height:CGFloat(image.height))) }
            var count=0,sum=0.0
            for y in 0..<image.height { for x in 0..<image.width { let i=(y*image.width+x)*4;if rgba[i]>40 && Double(rgba[i])>Double(rgba[i+1])*1.5 && Double(rgba[i])>Double(rgba[i+2])*1.5 { count+=1;sum+=Double(x) } } }
            return (count,sum/Double(max(count,1)))
        }
        let pa=try witness(a.imageData),pb=try witness(b.imageData);XCTAssertGreaterThan(pa.count,8);XCTAssertGreaterThan(pb.count,8);XCTAssertGreaterThan(abs(pa.x-pb.x),2)
        for (name,frame) in [("rig-pose-zero",a),("rig-pose-bend",b)] { let attachment=XCTAttachment(data:frame.imageData,uniformTypeIdentifier:"public.png");attachment.name=name;attachment.lifetime = .keepAlways;add(attachment) }
        let movie=try await document.exportAnimationMP4(clipID:clip.id,to:directory.appendingPathComponent("rig.mp4"),settings:CADAnimationExportSettings(width:128,height:128,frameRate:12,posterEnabled:false))
        XCTAssertEqual(movie.frameCount,24);let asset=AVURLAsset(url:movie.url),tracks=try await asset.loadTracks(withMediaType:.video),track=try XCTUnwrap(tracks.first),reader=try AVAssetReader(asset:asset),output=AVAssetReaderTrackOutput(track:track,outputSettings:nil);reader.add(output);XCTAssertTrue(reader.startReading());var count=0;while let buffer=output.copyNextSampleBuffer() { count+=CMSampleBufferGetNumSamples(buffer) };XCTAssertEqual(reader.status,.completed);XCTAssertEqual(count,24)
    }
    #endif
}
