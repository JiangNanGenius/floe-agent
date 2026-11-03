// SPDX-License-Identifier: MPL-2.0
// Focused App-host source. No model/provider, Bridge daemon, device selection or SDK installation.
// Geometry artifact selectors require the retained private component fixture through
// FLOE_BASIC_MACHINING_FIXTURE_ROOT. Missing evidence FAILS; it never skips to pass.
#if canImport(UIKit) && DEBUG
import Foundation
import XCTest
import FloeCAD
import FloeCore
import FloeExecution
import FloeTools
import FloeWorkbench
@testable import FloeApp

@MainActor
final class CADBasicMachiningTests:XCTestCase {
    private var nativeRoot:URL?
    override func tearDown()async throws {
        if let root=nativeRoot {await FloeCAD3DBridge.shared.releaseDocument(at:root.appendingPathComponent("Part.floecad"));try? FileManager.default.removeItem(at:root);nativeRoot=nil}
    }
    private func fixture()throws->(URL,CADBasicMachiningStudy) {
        let path=try XCTUnwrap(ProcessInfo.processInfo.environment["FLOE_BASIC_MACHINING_FIXTURE_ROOT"],"Pass the retained component fixture root; this is not real Bridge/job evidence")
        let root=URL(fileURLWithPath:path,isDirectory:true)
        let o=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("fixture-context.json"))) as? [String:Any])
        let owner=try XCTUnwrap(o["ownerBinding"] as? [String:Any]),source=try XCTUnwrap(o["source"] as? [String:Any])
        let relative=try XCTUnwrap(o["relativeDirectory"] as? String)
        let rows=try XCTUnwrap(source["files"] as? [[String:String]])
        let prefix=relative+"/input/snapshot/"
        let members=Dictionary(uniqueKeysWithValues:try rows.map{r in
            let path=try XCTUnwrap(r["path"]);XCTAssertTrue(path.hasPrefix(prefix));return (String(path.dropFirst(prefix.count)),try XCTUnwrap(r["sha256"]))})
        let params=try JSONDecoder().decode(CadBasicMachiningParameters.self,from:JSONSerialization.data(withJSONObject:try XCTUnwrap(o["parameters"])))
        let s=CADBasicMachiningStudy(id:try XCTUnwrap(UUID(uuidString:try XCTUnwrap(o["operationID"] as? String))),
            conversationID:try XCTUnwrap(UUID(uuidString:try XCTUnwrap(owner["conversationID"] as? String))),createdRunID:try XCTUnwrap(UUID(uuidString:try XCTUnwrap(owner["runID"] as? String))),
            environmentID:try XCTUnwrap(owner["environmentID"] as? String),workspaceRoot:root,
            source:CADBasicMachiningSource(documentURL:root.appendingPathComponent("component-reference-only.floecad"),bodyID:try XCTUnwrap(UUID(uuidString:try XCTUnwrap(source["bodyID"] as? String))),
                revision:try XCTUnwrap(source["documentRevision"] as? Int),contentSHA256:try XCTUnwrap(source["contentSHA256"] as? String),modelSHA256:try XCTUnwrap(source["modelSHA256"] as? String),members:members),
            parameters:params,relativeDirectory:relative,inputSHA256:try XCTUnwrap(o["requestSHA256"] as? String),preparationPayload:Data(),simulationPayload:Data(),state:.prepared,createdAt:Date(),updatedAt:Date())
        return(root,s)
    }
    private func verify(_ directory:URL,_ s:CADBasicMachiningStudy)throws->CADBasicMachiningVerified {
        try CADBasicMachiningVerification.verify(directory:directory,study:s,coreSHA:CADBasicMachiningResources.coreSHA256,wrapperSHA:CADBasicMachiningResources.wrapperSHA256)
    }
    func testActualBackendOutputHasIndependentCutVolumeNormalsAndClosedBoundary()throws {
        let(root,s)=try fixture();let v=try verify(root.appendingPathComponent(s.relativeDirectory+"/output"),s)
        XCTAssertEqual(v.removedMM3,216);XCTAssertEqual(v.remainingMM3,39_784)
        XCTAssertEqual(v.stlSHA256,"e00e72ef488853eeb8c838d88129d31bb122b1e4527cb3e7a740b87fadfa8708")
        XCTAssertEqual(v.stlData.count,1_084_084)
    }
    func testRehashedCorruptNormalAndMaterialCannotBecomeReady()throws {
        let(root,s)=try fixture(),original=root.appendingPathComponent(s.relativeDirectory+"/output")
        let copy=FileManager.default.temporaryDirectory.appendingPathComponent("basic-machining-negative-\(UUID())")
        try FileManager.default.copyItem(at:original,to:copy);defer{try? FileManager.default.removeItem(at:copy)}
        func rehash(_ name:String,_ bytes:Data)throws {
            try bytes.write(to:copy.appendingPathComponent(name),options:.atomic)
            var manifest=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:copy.appendingPathComponent("manifest.json"))) as? [String:Any])
            var artifacts=try XCTUnwrap(manifest["artifacts"] as? [[String:Any]])
            let index=try XCTUnwrap(artifacts.firstIndex(where:{$0["path"] as? String==name}));artifacts[index]["sha256"]=FloeDigest.sha256Hex(bytes);artifacts[index]["bytes"]=bytes.count
            manifest["artifacts"]=artifacts;try JSONSerialization.data(withJSONObject:manifest,options:.sortedKeys).write(to:copy.appendingPathComponent("manifest.json"),options:.atomic)
        }
        var stl=try Data(contentsOf:copy.appendingPathComponent("stock.stl"));var wrong=Float(42).bitPattern.littleEndian
        withUnsafeBytes(of:&wrong){stl.replaceSubrange(84..<88,with:$0)};try rehash("stock.stl",stl)
        XCTAssertThrowsError(try verify(copy,s),"Even a matching new digest cannot promote a wrong outward normal")
        try rehash("stock.stl",Data(contentsOf:original.appendingPathComponent("stock.stl")))
        var material=try Data(contentsOf:copy.appendingPathComponent("stock.occupancy"));material[36]=material[36]==0 ? 1:0;try rehash("stock.occupancy",material)
        XCTAssertThrowsError(try verify(copy,s),"Each material centre is checked independently, rather than trusting a volume/triangle count")
    }
    func testUnsupportedRotationAndNonFixedZAreExplicitlyRefused()throws {
        let base:[String:Any]=["resolutionMM":1,"radiusMM":2,"lengthMM":6,"startTipMM":[37,5,-10],"endTipMM":[43,5,-10]]
        var rotation=base;rotation["rotationDegrees"]=90
        let text=String(decoding:try JSONSerialization.data(withJSONObject:["action":"prepare","body_id":UUID().uuidString,"parameters":rotation]),as:UTF8.self)
        XCTAssertThrowsError(try CadBasicMachiningRequest.decode(text))
        XCTAssertThrowsError(try CadBasicMachiningParameters(startTipMM:[0,0,0],endTipMM:[1,0,1]).validate())
        let payload=try CADBasicMachiningResources.payload(phase:.environment,relativeDirectory:"BasicMachining/11111111-2222-4333-8444-555555555555",inputSHA:String(repeating:"a",count:64))
        let shell=try JSONDecoder().decode(LocalShellTool.Arguments.self,from:payload)
        XCTAssertEqual(try shell.resolvedTimeout,240);XCTAssertEqual(shell.timeoutPolicy,"hard");XCTAssertNotNil(shell.script)
        XCTAssertNil(shell.skillID,"No invented dotnet Skill dependency kind or parallel execution tool")
    }
    func testRealCADSnapshotAddsNoUndoAndRejectsChangedSourceAfterReopen()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("basic-machining-cad-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let url=root.appendingPathComponent("Part.floecad")
        nativeRoot=root
        _=try await FloeCADDocument.create(at:url,name:"Part")
        let document=try await FloeCAD3DBridge.shared.openDocument(at:url)
        let sketch=document.executeJSON(Data(#"{"op":"sketch.create","args":{"name":"Base"}}"#.utf8));XCTAssertTrue(sketch.isOK,sketch.message ?? "")
        let sketchID=try XCTUnwrap((try JSONSerialization.jsonObject(with:sketch.payload) as? [String:Any])?["sketchID"] as? String)
        XCTAssertTrue(document.executeJSON(Data("{\"op\":\"sketch.addEntities\",\"args\":{\"sketchID\":\"\(sketchID)\",\"entities\":[{\"kind\":\"rect\",\"min\":[0,0],\"max\":[8,8]}]}}".utf8)).isOK)
        XCTAssertTrue(document.executeJSON(Data("{\"op\":\"feature.extrude\",\"args\":{\"sketchID\":\"\(sketchID)\",\"seedPoint\":[4,4],\"distance\":8}}".utf8)).isOK)
        let saved=await document.save();XCTAssertTrue(saved.succeeded,saved.error ?? "")
        func body(_ document:FloeCADDocument)throws->UUID {
            let object=try XCTUnwrap(JSONSerialization.jsonObject(with:document.snapshotJSON()) as? [String:Any])
            return try XCTUnwrap(UUID(uuidString:try XCTUnwrap((object["bodies"] as? [[String:Any]])?.first?["id"] as? String)))
        }
        func volume(_ document:FloeCADDocument,_ id:UUID)throws->Double {
            let m=document.measureJSON(["kind":"body","bodyID":id.uuidString]);XCTAssertTrue(m.isOK,m.message ?? "")
            return try XCTUnwrap((try JSONSerialization.jsonObject(with:m.payload) as? [String:Any])?["volumeMM3"] as? Double)
        }
        let bodyID=try body(document);XCTAssertEqual(try volume(document,bodyID),512,accuracy:1e-7)
        let before=await FloeCADDocument.storedIdentity(at:url)
        let source=try await CADBasicMachiningSnapshot.capture(documentURL:url,bodyID:bodyID,destination:root.appendingPathComponent("snapshot"),cancellation:CancellationToken())
        XCTAssertEqual(source.revision,before?.revision);XCTAssertEqual(source.contentSHA256,before?.contentSHA256)
        for (member,sha) in source.members{XCTAssertEqual(try FloeDigest.sha256Hex(ofFileAt:url.appendingPathComponent(member)),sha,"Capture preserves actual source BRep/mesh bytes")}
        try await CADBasicMachiningSnapshot.requireCurrent(source)
        XCTAssertEqual(CADParameterService(document:document).handle(action:"undo",args:[:])["ok"] as? Bool,true)
        XCTAssertEqual(document.summary().bodyCount,0,"Capture/analysis must not add an undo entry")
        XCTAssertEqual(CADParameterService(document:document).handle(action:"redo",args:[:])["ok"] as? Bool,true)
        XCTAssertEqual(try body(document),bodyID);XCTAssertEqual(try volume(document,bodyID),512,accuracy:1e-7)
        do{try await CADBasicMachiningSnapshot.requireCurrent(source);XCTFail("Changed source must fence late artifacts")}catch{}
        let finalSave=await document.save();XCTAssertTrue(finalSave.succeeded)
        await FloeCAD3DBridge.shared.releaseDocument(at:url)
        let reopened=try await FloeCAD3DBridge.shared.openDocument(at:url)
        XCTAssertEqual(try body(reopened),bodyID);XCTAssertEqual(try volume(reopened,bodyID),512,accuracy:1e-7)
        do{try await CADBasicMachiningSnapshot.requireCurrent(source);XCTFail("New saved revision must not revive an old operation")}catch{}
        await FloeCAD3DBridge.shared.releaseDocument(at:url)
    }
}
#endif
