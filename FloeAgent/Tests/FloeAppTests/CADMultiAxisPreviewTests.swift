// SPDX-License-Identifier: MPL-2.0
// App-host selectors. Retained component files never substitute for real jobs/Bridge/UI acceptance.
#if canImport(UIKit) && DEBUG
import Foundation
import XCTest
import FloeCore
import FloeTools
import FloeWorkbench
@testable import FloeApp

@MainActor final class CADMultiAxisPreviewTests:XCTestCase {
    private func fixture()throws->(URL,CADBasicMachiningStudy) {
        let path=try XCTUnwrap(ProcessInfo.processInfo.environment["FLOE_MULTI_AXIS_PREVIEW_FIXTURE_ROOT"],"Provide retained managed-workspace fixture; missing evidence must fail")
        let root:URL
        if path.hasPrefix("app-cache:") {let name=String(path.dropFirst(10));guard !name.isEmpty,!name.contains("/"),!name.contains("\\"),name != ".",name != ".." else{throw CocoaError(.fileReadInvalidFileName)};root=try XCTUnwrap(FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask).first).appendingPathComponent(name)}
        else {root=URL(fileURLWithPath:path,isDirectory:true)}
        let context=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("fixture-context.json"))) as? [String:Any]),relative=try XCTUnwrap(context["relativeDirectory"] as? String)
        let input=try Data(contentsOf:root.appendingPathComponent(relative+"/input/request.json")),q=try XCTUnwrap(JSONSerialization.jsonObject(with:input) as? [String:Any]),owner=try XCTUnwrap(q["ownerBinding"] as? [String:Any]),source=try XCTUnwrap(q["source"] as? [String:Any])
        let payload=String(decoding:try JSONSerialization.data(withJSONObject:["action":"prepare","body_id":source["bodyID"]!,"parameters":q["parameters"]!]),as:UTF8.self)
        let parameters=try XCTUnwrap(CadBasicMachiningRequest.decode(payload).parameters),rows=try XCTUnwrap(source["files"] as? [[String:String]]),prefix=relative+"/input/snapshot/"
        let members=Dictionary(uniqueKeysWithValues:try rows.map{r in let name=try XCTUnwrap(r["path"]);guard name.hasPrefix(prefix) else{throw FloeError.unauthorized};return(String(name.dropFirst(prefix.count)),try XCTUnwrap(r["sha256"]))})
        var s=CADBasicMachiningStudy(id:try XCTUnwrap(UUID(uuidString:try XCTUnwrap(owner["operationID"] as? String))),conversationID:try XCTUnwrap(UUID(uuidString:try XCTUnwrap(owner["conversationID"] as? String))),createdRunID:try XCTUnwrap(UUID(uuidString:try XCTUnwrap(owner["runID"] as? String))),environmentID:try XCTUnwrap(owner["environmentID"] as? String),workspaceRoot:root,source:CADBasicMachiningSource(documentURL:root.appendingPathComponent("component-reference.floecad"),bodyID:try XCTUnwrap(UUID(uuidString:try XCTUnwrap(source["bodyID"] as? String))),revision:try XCTUnwrap(source["documentRevision"] as? Int),contentSHA256:try XCTUnwrap(source["contentSHA256"] as? String),modelSHA256:try XCTUnwrap(source["modelSHA256"] as? String),members:members),parameters:parameters,relativeDirectory:relative,inputSHA256:FloeDigest.sha256Hex(input),preparationPayload:Data(),simulationPayload:Data(),state:.prepared,createdAt:Date(),updatedAt:Date());s.formatVersion=2
        return(root,s)
    }
    private func verify(_ root:URL,_ s:CADBasicMachiningStudy)throws->CADBasicMachiningVerified {try CADMultiAxisPreviewVerification.verify(directory:root,study:s,cancellation:CancellationToken())}
    func testActualManagedOutputHasIndependentContinuousBracketAndClosedMeshes()throws {
        let(root,s)=try fixture();let v=try verify(root.appendingPathComponent(s.relativeDirectory+"/output"),s)
        XCTAssertEqual(v.removedMM3,365);XCTAssertEqual(v.remainingMM3,39635)
        XCTAssertEqual(v.previewSummary?.continuousRemainingLowerMM3,39229);XCTAssertEqual(v.previewSummary?.continuousRemainingUpperMM3,39850)
        XCTAssertEqual(v.previewSummary?.fixtures.first?.state,"clear")
        XCTAssertNotNil(v.supplementalFiles["motion/remaining-lower.stl"]);XCTAssertNotNil(v.supplementalFiles["motion/remaining-upper.stl"])
    }
    func testRehashedNormalAndChangedNominalCannotBeAccepted()throws {
        let(root,s)=try fixture(),original=root.appendingPathComponent(s.relativeDirectory+"/output"),copy=FileManager.default.temporaryDirectory.appendingPathComponent("multi-axis-negative-\(UUID())")
        try FileManager.default.copyItem(at:original,to:copy);defer{try? FileManager.default.removeItem(at:copy)}
        func rehash(_ names:[String],_ d:Data)throws {
            var m=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:copy.appendingPathComponent("manifest.json"))) as? [String:Any]),rows=try XCTUnwrap(m["artifacts"] as? [[String:Any]])
            for name in names {try d.write(to:copy.appendingPathComponent(name),options:.atomic);let i=try XCTUnwrap(rows.firstIndex(where:{$0["path"] as? String==name}));rows[i]["sha256"]=FloeDigest.sha256Hex(d);rows[i]["bytes"]=d.count}
            m["artifacts"]=rows;try JSONSerialization.data(withJSONObject:m,options:.sortedKeys).write(to:copy.appendingPathComponent("manifest.json"),options:.atomic)
        }
        var stl=try Data(contentsOf:copy.appendingPathComponent("stock.stl")),wrong=Float(42).bitPattern.littleEndian;withUnsafeBytes(of:&wrong){stl.replaceSubrange(84..<88,with:$0)}
        try rehash(["stock.stl","motion/nominal.stl"],stl);XCTAssertThrowsError(try verify(copy,s))
        try rehash(["stock.stl","motion/nominal.stl"],Data(contentsOf:original.appendingPathComponent("stock.stl")))
        var raw=try Data(contentsOf:copy.appendingPathComponent("stock.occupancy"));XCTAssertEqual(raw[36],1);raw[36]=0
        try rehash(["stock.occupancy","motion/nominal.occupancy"],raw);XCTAssertThrowsError(try verify(copy,s))
    }
    func testForeignOwnerCancellationAndFutureStudyPreserveEvidence()throws {
        let(root,s)=try fixture(),directory=root.appendingPathComponent(s.relativeDirectory+"/output");var foreign=s;foreign.environmentID="another-environment"
        XCTAssertThrowsError(try verify(directory,foreign));let token=CancellationToken();token.cancel();XCTAssertThrowsError(try CADMultiAxisPreviewVerification.verify(directory:directory,study:s,cancellation:token))
        let temp=FileManager.default.temporaryDirectory.appendingPathComponent("multi-axis-store-\(UUID())");defer{try? FileManager.default.removeItem(at:temp)};let store=try CADBasicMachiningStudyStore(root:temp);try store.save(s);let reopened=try store.load(s.id)
        XCTAssertEqual(reopened.id,s.id);XCTAssertEqual(reopened.parameters,s.parameters);XCTAssertEqual(reopened.source,s.source);XCTAssertEqual(reopened.environmentID,s.environmentID)
        var future=s;future.formatVersion=3;try store.save(future);let file=store.directory(s.id).appendingPathComponent("study.json"),bytes=try Data(contentsOf:file);XCTAssertThrowsError(try store.load(s.id));XCTAssertEqual(try Data(contentsOf:file),bytes)
    }
    func testPreviewContractDoesNotAcceptMachineAxesOrUnmodelledTurnMill()throws {
        let(_,s)=try fixture();let p=try XCTUnwrap(s.parameters.preview);var fields=try p.taskParameters(radius:s.parameters.radiusMM,length:s.parameters.lengthMM,resolution:s.parameters.resolutionMM)
        fields["machineRotaryAxes"]=[0,90]
        let text=String(decoding:try JSONSerialization.data(withJSONObject:["action":"prepare","body_id":s.source.bodyID.uuidString,"parameters":fields]),as:UTF8.self)
        XCTAssertThrowsError(try CadBasicMachiningRequest.decode(text))
        var zero=p;zero.poses[0].axisTowardSpindle=[0,0,0];XCTAssertThrowsError(try zero.validate(radius:2,length:10,resolution:1))
    }
}
#endif
