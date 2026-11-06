// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import Euclid
import simd
@testable import FloeCAD

@MainActor
final class CADHybridModelingTests:XCTestCase {
    private var directory:URL!
    private var documents:[FloeCADDocument]=[]
    override func setUp() async throws {
        directory=FileManager.default.temporaryDirectory.appendingPathComponent("HybridModeling-\(UUID())")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    }
    override func tearDown() async throws {
        for document in documents {document.close()}
        if let directory {try FileManager.default.removeItem(at:directory)}
    }
    private func document() async throws -> FloeCADDocument {
        let document=try await FloeCADDocument.create(at:directory.appendingPathComponent("\(UUID()).floecad"),name:"Hybrid model")
        documents.append(document);return document
    }
    @discardableResult private func add(_ document:FloeCADDocument,size:SIMD3<Double> = SIMD3(20,10,5),precise:Bool=false)->Body {
        var body=Body(name:"Original",euclidMesh:.cube(center:.zero,size:Vector(size.x,size.y,size.z)),revision:document.session.mintBodyRevision())
        if precise,let handle=OCCTKernel.primitiveShape(.box(width:size.x,depth:size.y,height:size.z),placement:.identity) {XCTAssertTrue(body.adoptBRep(handle))}
        document.session.perform(AddBodyCommand(body:body,title:"Import source"));return body
    }
    private func bodyID(_ reply:[String:Any]) throws -> BodyID {
        BodyID(raw:try XCTUnwrap(UUID(uuidString:try XCTUnwrap(reply["bodyID"] as? String))))
    }
    private func success(_ document:FloeCADDocument,_ action:String,_ args:[String:Any]) async throws -> [String:Any] {
        let reply=await CADMeshService(document:document).handleAsync(action:action,args:args)
        XCTAssertEqual(reply["ok"] as? Bool,true,"\(reply)");return reply
    }
    private func hole(_ id:BodyID,preview:Bool=false)->[String:Any] {
        ["bodyID":id.raw.uuidString,"kind":"hole","radius":2.0,"depth":7.0,"center":[-4.0,0,0],"axis":[0,0,1],"preview":preview]
    }
    func testManifoldHoleBossCutReplayVolumeAndSourceIntegrity() throws {
        let body=Body(name:"STL",euclidMesh:.cube(center:.zero,size:Vector(20,10,5)),revision:1)
        let source=try CADHybridMeshSource(capturing:body)
        var definition=CADHybridFeatureDefinition(source:source,operations:[
            .init(kind:.hole,tool:.cylinder(radius:2,height:7,center:SIMD3(-4,0,0),axis:SIMD3(0,0,1),segments:64)),
            .init(kind:.boss,tool:.cylinder(radius:3,height:3,center:SIMD3(4,0,3.5),axis:SIMD3(0,0,1),segments:64)),
            .init(kind:.cut,tool:.box(size:SIMD3(2,20,2),center:SIMD3(9,0,2)))])
        let result=try CADHybridMeshKernel.evaluate(definition)
        XCTAssertEqual(result.sourceVolume,1000,accuracy:1e-5)
        XCTAssertEqual(result.volume,1000-Double.pi*4*5+Double.pi*9*2.5-30,accuracy:0.05)
        XCTAssertEqual(source.render,body.render)
        XCTAssertEqual(source.placement,body.transform)
        let decoded=try JSONDecoder().decode(CADHybridFeatureDefinition.self,from:JSONEncoder().encode(definition))
        XCTAssertEqual(try CADHybridMeshKernel.evaluate(decoded).render,result.render)
        definition.operations[0].tool = .cylinder(radius:1,height:7,center:SIMD3(-4,0,0),axis:SIMD3(0,0,1),segments:64)
        XCTAssertGreaterThan(try CADHybridMeshKernel.evaluate(definition).volume,result.volume+40)
        XCTAssertEqual(definition.source,source)
    }
    func testPreviewSingleUndoSaveReopenAndEditOriginalParameters() async throws {
        let document=try await document(),source=add(document),count=document.session.undoStack.undoCommands.count
        let preview=try await success(document,"hybrid.add",hole(source.id,preview:true))
        XCTAssertEqual(preview["mutated"] as? Bool,false)
        XCTAssertEqual(document.session.document.bodies.count,1)
        XCTAssertEqual(document.session.undoStack.undoCommands.count,count)
        var args=hole(source.id)
        args["expectedPreviewHash"]=preview["previewHash"];args["expectedChangeCount"]=preview["previewChangeCount"];args["expectedRevision"]=preview["previewRevision"]
        let reply=try await success(document,"hybrid.add",args),id=try bodyID(reply)
        let render=try XCTUnwrap(document.session.document.body(with:id)?.render)
        XCTAssertEqual(document.session.undoStack.undoCommands.count,count+1)
        XCTAssertNil(document.session.document.body(with:id)?.brep)
        XCTAssertEqual(document.session.document.body(with:source.id)?.render,source.render)
        XCTAssertTrue(document.session.document.body(with:source.id)?.isHidden==true)
        document.session.undo();XCTAssertNil(document.session.document.body(with:id));XCTAssertFalse(document.session.document.body(with:source.id)?.isHidden==true)
        document.session.redo();XCTAssertEqual(document.session.document.body(with:id)?.render,render)
        let saved=await document.save();XCTAssertTrue(saved.succeeded,saved.error ?? "")
        let url=document.url;document.close()
        let reopened=try await FloeCADDocument.open(at:url);documents.append(reopened)
        XCTAssertEqual(reopened.session.document.body(with:id)?.render,render)
        let inspected=try await success(reopened,"hybrid.inspect",["bodyID":id.raw.uuidString])
        let node=try XCTUnwrap(reopened.session.document.features.nodes.last)
        guard case let .hybrid(definition,_)=node.kind else {return XCTFail("Missing persisted hybrid history")}
        XCTAssertEqual(definition.source.render,source.render)
        var update=hole(id);update["radius"]=1.0;update["operationID"]=definition.operations[0].id.uuidString;update["definitionDigest"]=inspected["definitionDigest"]
        let updated=try await success(reopened,"hybrid.update",update)
        XCTAssertGreaterThan(try XCTUnwrap(updated["volumeMM3"] as? Double),try XCTUnwrap(reply["volumeMM3"] as? Double))
        reopened.session.undo();XCTAssertEqual(reopened.session.document.body(with:id)?.render,render)
    }
    func testMixedPreciseToolRequiresAcknowledgementAndKeepsItsBRep() async throws {
        let document=try await document(),source=add(document),tool=add(document,size:SIMD3(4,20,20),precise:true)
        XCTAssertNotNil(tool.brep)
        var args:[String:Any]=["bodyID":source.id.raw.uuidString,"kind":"subtract","toolBodyID":tool.id.raw.uuidString]
        let count=document.session.undoStack.undoCommands.count
        let refused=await CADMeshService(document:document).handleAsync(action:"hybrid.add",args:args)
        XCTAssertEqual(refused["ok"] as? Bool,false);XCTAssertEqual(document.session.undoStack.undoCommands.count,count)
        args["allowMeshResult"]=true
        let result=try await success(document,"hybrid.add",args),id=try bodyID(result)
        XCTAssertNil(document.session.document.body(with:id)?.brep)
        XCTAssertNotNil(document.session.document.body(with:tool.id)?.brep)
        XCTAssertEqual(document.session.document.body(with:tool.id)?.render,tool.render)
        XCTAssertEqual(document.session.document.body(with:source.id)?.render,source.render)
    }
    func testFacetedConversionCreatesValidatedSolidAndRetainsScanOnColdReopen() async throws {
        let document=try await document(),source=add(document),before=document.session.undoStack.undoCommands.count
        let result=try await success(document,"faceted.convert",["bodyID":source.id.raw.uuidString]),id=try bodyID(result)
        XCTAssertEqual(result["representation"] as? String,"faceted")
        XCTAssertEqual(result["curvedSurfacesRecovered"] as? Bool,false)
        XCTAssertEqual(document.session.undoStack.undoCommands.count,before+1)
        let handle=try XCTUnwrap(document.session.document.body(with:id)?.brep)
        XCTAssertTrue(handle.containsSolid)
        XCTAssertEqual(OCCTKernel.faceInfo(handle).count,6,"Same-domain unification must remove the planar triangle diagonals")
        guard case let .baseSolid(stored)=document.session.document.features.nodes.last?.kind else {return XCTFail("Missing exact source")}
        XCTAssertEqual(stored.conversionProvenance?.meshSource?.render,source.render)
        let saved=await document.save();XCTAssertTrue(saved.succeeded,saved.error ?? "")
        let url=document.url;document.close()
        let reopened=try await FloeCADDocument.open(at:url);documents.append(reopened)
        XCTAssertTrue(reopened.session.document.body(with:id)?.brep?.containsSolid==true)
        XCTAssertEqual(reopened.session.document.body(with:source.id)?.render,source.render)
        let recognition=try await success(reopened,"recognition.inspect",["bodyID":source.id.raw.uuidString])
        XCTAssertEqual((recognition["candidates"] as? [[String:Any]])?.first?["kind"] as? String,"axis-aligned-box")
    }
    func testOpenMeshCancellationAndUnknownNestedDataAreRefused() async throws {
        let document=try await document(),original=add(document)
        var open=original.render;open.indices.removeLast(3)
        let body=Body(id:BodyID(),name:"Open STL",transform:.identity,primitive:nil,render:open,revision:document.session.mintBodyRevision())
        document.session.perform(AddBodyCommand(body:body,title:"Import open STL"))
        let count=document.session.undoStack.undoCommands.count,epoch=document.session.changeCount
        let refused=await CADMeshService(document:document).handleAsync(action:"hybrid.add",args:hole(body.id))
        XCTAssertEqual(refused["ok"] as? Bool,false);XCTAssertEqual(document.session.changeCount,epoch)
        XCTAssertEqual(document.session.undoStack.undoCommands.count,count)
        let token=CADMeshCancellation();token.cancel()
        XCTAssertThrowsError(try CADHybridMeshKernel.validatedSource(CADHybridMeshSource(capturing:original),cancellation:token))
        let definition=CADHybridFeatureDefinition(source:try CADHybridMeshSource(capturing:original),operations:[.init(kind:.hole,tool:.cylinder(radius:2,height:7,center:.zero,axis:SIMD3(0,0,1),segments:64))])
        let data=try JSONEncoder().encode(definition)
        var raw=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        XCTAssertNoThrow(try CADHybridFeatureDefinition.validateStoredJSONObject(raw))
        var source=try XCTUnwrap(raw["source"] as? [String:Any]);source["futureSurfaceFit"]=["version":2];raw["source"]=source
        XCTAssertThrowsError(try CADHybridFeatureDefinition.validateStoredJSONObject(raw))
    }

    func testSignedZeroSourceAndDefinitionDigestsSurviveFoundationRoundTrip() throws {
        let negativeZero=Float(-0.0)
        let render=RenderMesh(positions:[SIMD3(negativeZero,0,0),SIMD3(1.25,0,0),SIMD3(0,2.5,0)],
            normals:Array(repeating:SIMD3(negativeZero,0,1),count:3),indices:[0,1,2],
            texcoords:[SIMD2(negativeZero,0),SIMD2(0.25,0.5),SIMD2(1,1)])
        var placement=Transform3D.identity
        placement.translation=SIMD3(-0.0,1e-10,Double.pi)
        placement.rotation=simd_quatd(ix:-0.0,iy:0,iz:0,r:1)
        placement.scale=1.0000000000000002
        let body=Body(id:BodyID(),name:"Signed zero source",transform:placement,primitive:nil,render:render,revision:1)
        let source=try CADHybridMeshSource(capturing:body)
        // Hashing must not normalize the original source buffers in place.
        XCTAssertEqual(source.positions[0].x.bitPattern,negativeZero.bitPattern)
        XCTAssertEqual(source.normals[0].x.bitPattern,negativeZero.bitPattern)
        XCTAssertEqual(source.texcoords?[0].x.bitPattern,negativeZero.bitPattern)
        XCTAssertEqual(source.placement.translation.x.sign,.minus)

        var positive=body
        positive.render.positions[0].x=0;positive.render.normals=Array(repeating:SIMD3(0,0,1),count:3)
        positive.render.texcoords?[0].x=0
        positive.transform.translation.x=0;positive.transform.rotation=simd_quatd(ix:0,iy:0,iz:0,r:1)
        let positiveSource=try CADHybridMeshSource(capturing:positive)
        XCTAssertEqual(source.sha256,positiveSource.sha256,"Only the sign of numeric zero may be ignored")

        let definition=CADHybridFeatureDefinition(source:source,operations:[
            .init(kind:.hole,tool:.cylinder(radius:1.1,height:2.1,center:SIMD3(-0.0,0,1.25),axis:SIMD3(-0.0,0,1),segments:64)),
            .init(kind:.union,tool:.body(source))],discardOutputUV:true)
        let encoded=try JSONEncoder().encode(definition)
        let raw=try JSONSerialization.jsonObject(with:encoded)
        let foundationBytes=try JSONSerialization.data(withJSONObject:raw,options:.sortedKeys)
        let restored=try JSONDecoder().decode(CADHybridFeatureDefinition.self,from:foundationBytes)
        XCTAssertNoThrow(try CADHybridFeatureDefinition.validateStoredJSONObject(raw))
        XCTAssertNoThrow(try restored.validate())
        XCTAssertEqual(restored.source.sha256,source.sha256)
        XCTAssertEqual(restored.digest,definition.digest,"Cold-open CAS identity must not depend on JSON's spelling of zero")
        XCTAssertEqual(restored.source.render,source.render)
        XCTAssertEqual(CADTransientMeshPreview.hash(of:restored.source.render),CADTransientMeshPreview.hash(of:source.render))

        let provenance=CADSolidConversionProvenance(representation:"faceted",toleranceMM:0.00001,
            sourceBodyIDs:[body.id],meshSource:source)
        let provenanceRaw=try JSONSerialization.jsonObject(with:JSONEncoder().encode(provenance))
        XCTAssertNoThrow(try CADSolidConversionProvenance.validateStoredJSONObject(provenanceRaw))
        let provenanceBytes=try JSONSerialization.data(withJSONObject:provenanceRaw,options:.sortedKeys)
        let restoredProvenance=try JSONDecoder().decode(CADSolidConversionProvenance.self,from:provenanceBytes)
        XCTAssertNoThrow(try restoredProvenance.validate())
        XCTAssertEqual(restoredProvenance.meshSource?.sha256,source.sha256)
    }

    func testSourceIntegrityStillRejectsNonzeroValueAndTopologyChanges() throws {
        var placement=Transform3D.identity;placement.translation.y=1e-10
        let body=Body(id:BodyID(),name:"Integrity source",transform:placement,primitive:nil,
            render:RenderMesh(positions:[SIMD3(0,0,0),SIMD3(1.25,0,0),SIMD3(0,2.5,0)],
                normals:Array(repeating:SIMD3(0,0,1),count:3),indices:[0,1,2],
                texcoords:[SIMD2(0,0),SIMD2(0.25,0.5),SIMD2(1,1)]),revision:1)
        let source=try CADHybridMeshSource(capturing:body)
        let raw=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(source)) as? [String:Any])
        var changed:[[String:Any]]=[]
        var position=raw,positions=try XCTUnwrap(raw["positions"] as? [[Double]])
        positions[1][0]=Double(Float(1.25).nextUp);position["positions"]=positions;changed.append(position)
        var normal=raw,normals=try XCTUnwrap(raw["normals"] as? [[Double]])
        normals[0][2]=Double(Float(1).nextDown);normal["normals"]=normals;changed.append(normal)
        var uv=raw,texcoords=try XCTUnwrap(raw["texcoords"] as? [[Double]])
        texcoords[1][0]=Double(Float(0.25).nextUp);uv["texcoords"]=texcoords;changed.append(uv)
        var topology=raw;topology["indices"]=[0,2,1];changed.append(topology)
        var transformed=raw,frame=try XCTUnwrap(raw["placement"] as? [String:Any])
        var translation=try XCTUnwrap(frame["translation"] as? [Double])
        translation[1]=Double(1e-10).nextUp;frame["translation"]=translation;transformed["placement"]=frame;changed.append(transformed)
        var precision=raw;precision["inputExactness"]="solid";changed.append(precision)
        var absentUV=raw;absentUV["texcoords"]=NSNull();changed.append(absentUV)
        for value in changed {
            let decoded=try JSONDecoder().decode(CADHybridMeshSource.self,from:JSONSerialization.data(withJSONObject:value))
            XCTAssertThrowsError(try decoded.validate()) { error in
                XCTAssertTrue(error.localizedDescription.contains("integrity check"),"\(error)")
            }
        }
        var definition=CADHybridFeatureDefinition(source:source,operations:[
            .init(kind:.hole,tool:.cylinder(radius:1.1,height:2.1,center:.zero,axis:SIMD3(0,0,1),segments:64))],discardOutputUV:true)
        let before=definition.digest
        definition.operations[0].tool = .cylinder(radius:Double(1.1).nextUp,height:2.1,center:.zero,axis:SIMD3(0,0,1),segments:64)
        XCTAssertNotEqual(definition.digest,before,"Nonzero tool parameters must remain bit-exact CAS inputs")
    }
}
