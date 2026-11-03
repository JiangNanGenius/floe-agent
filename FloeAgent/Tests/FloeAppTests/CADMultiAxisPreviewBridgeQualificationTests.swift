// SPDX-License-Identifier: MPL-2.0
// Actual App service graph + separately signed/paired Mac companion. No stand-ins or provider calls.
// Root controls pairing, launch and execution. This selector never pairs, installs a companion or switches target.
#if canImport(UIKit) && DEBUG && !targetEnvironment(simulator)
import Foundation
import XCTest
import FloeCAD
import FloeCore
import FloeModels
import FloePersistence
import FloeEnvironments
import FloeExecution
import FloeTools
import FloeWorkbench
import FloeMacBridgeProtocol
@testable import FloeApp

@MainActor final class CADMultiAxisPreviewBridgeQualificationTests:XCTestCase {
    private static let bridgeSource="518c1123652406da4e20379a0640263804a95ea9"
    private struct OptIn:Decodable {var schema:Int;var expectedAppBundleID:String;var allowManagedRuntimePreparation:Bool;var maxSeconds:Double}
    private var app:AppEnvironment?
    private var documentURL:URL?
    private var operations:[UUID]=[]
    private var report:[String:Any]=["layer":"real-App-services-and-signed-MacBridge-not-model-not-UI-clicks","fullE38Accepted":false]
    private var evidenceRoot:URL?
    override func tearDown()async throws {
        if let app {for id in operations {if let s=try? app.basicMachiningCenter.study(id),[.prepared,.preparingEnvironment,.environmentReady,.simulating,.cancelling].contains(s.state){_ = try? await app.basicMachiningCenter.cancel(id)}}}
        if let documentURL {await FloeCAD3DBridge.shared.releaseDocument(at:documentURL)}
        try? retain("selector-finished-evidence-and-owned-workspace-retained")
        if let file=evidenceRoot?.appendingPathComponent("qualification.json"),let d=try? Data(contentsOf:file){let a=XCTAttachment(data:d,uniformTypeIdentifier:"public.json");a.name="E38-Bridge11-real-App-receipt";a.lifetime = .keepAlways;add(a)}
        // No global disconnect, environment deletion, workspace removal or credential reads.
    }
    private func retain(_ stage:String)throws {
        report["stage"]=stage;report["observedAt"]=ISO8601DateFormatter().string(from:Date())
        if let root=evidenceRoot {try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]).write(to:root.appendingPathComponent("qualification.json"),options:.atomic)}
    }
    private func fail(_ message:String)->FloeError {XCTFail(message);return .validationFailed(message)}
    private func object(_ file:URL)throws->[String:Any] {try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any])}
    private func canonical(_ data:Data)throws->Data {try JSONSerialization.data(withJSONObject:JSONSerialization.jsonObject(with:data),options:.sortedKeys)}
    private func optIn()throws->OptIn {
        let cache=try XCTUnwrap(FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask).first)
        let file=cache.appendingPathComponent("FloeE38Bridge11Qualification/opt-in.json")
        guard let d=try? Data(contentsOf:file),d.count<=4096 else{throw fail("Missing explicit current-App E38 Bridge 1.1 opt-in; do not skip or infer a paired/ready target")}
        let o=try JSONDecoder().decode(OptIn.self,from:d)
        guard o.schema==1,o.expectedAppBundleID==Bundle.main.bundleIdentifier,o.allowManagedRuntimePreparation,(60...600).contains(o.maxSeconds) else{throw fail("Opt-in must name this App and allow the task-owned pinned runtime preparation with a bounded deadline")}
        return o
    }
    private func makePart(_ url:URL)async throws->(FloeCADDocument,UUID,[Double],[Double]) {
        _ = try await FloeCADDocument.create(at:url,name:"E38 bridge-owned blank reference")
        let d=try await FloeCAD3DBridge.shared.openDocument(at:url)
        let sketch=d.executeJSON(Data(#"{"op":"sketch.create","args":{"name":"Bridge-owned base","origin":[0,0,0],"xAxis":[1,0,0],"yAxis":[0,0,-1]}}"#.utf8));guard sketch.isOK else{throw fail(sketch.message ?? "Native sketch failed")}
        let sketchID=try XCTUnwrap((try JSONSerialization.jsonObject(with:sketch.payload) as? [String:Any])?["sketchID"] as? String)
        for args in [
            "{\"op\":\"sketch.addEntities\",\"args\":{\"sketchID\":\"\(sketchID)\",\"entities\":[{\"kind\":\"rect\",\"min\":[0,0],\"max\":[80,50]}]}}",
            "{\"op\":\"feature.extrude\",\"args\":{\"sketchID\":\"\(sketchID)\",\"seedPoint\":[40,25],\"distance\":10}}"
        ] {let result=d.executeJSON(Data(args.utf8));guard result.isOK else{throw fail(result.message ?? "Native CAD command failed")}}
        let saved=await d.save();guard saved.succeeded else{throw fail(saved.error ?? "Native CAD save failed")}
        let snapshot=try XCTUnwrap(JSONSerialization.jsonObject(with:d.snapshotJSON()) as? [String:Any]),row=try XCTUnwrap((snapshot["bodies"] as? [[String:Any]])?.first),id=try XCTUnwrap(UUID(uuidString:try XCTUnwrap(row["id"] as? String)))
        let model=try object(url.appendingPathComponent("document.json")),bodies=try XCTUnwrap(model["bodies"] as? [[String:Any]]),body=try XCTUnwrap(bodies.first(where:{($0["bodyID"] as? String)?.lowercased()==id.uuidString.lowercased()})),mesh=try XCTUnwrap(body["meshBlob"] as? String)
        let bytes=try Data(contentsOf:url.appendingPathComponent(mesh));var r=CADBasicMachiningVerification.Reader(data:bytes)
        guard try r.u32()==0x4F533344 else{throw fail("Native mesh magic")};let version=try r.u32(),vertices=Int(try r.u32()),indices=Int(try r.u32())
        guard (version==1||version==2),vertices>0,vertices<1000000,bytes.count==16+(version==2 ? 32:24)*vertices+4*indices else{throw fail("Native mesh layout/budget")}
        var lo=[Double](repeating:.infinity,count:3),hi=[Double](repeating:-.infinity,count:3)
        for _ in 0..<vertices {for axis in 0..<3 {let x=Double(try r.f32());guard x.isFinite else{throw fail("Native mesh finite bounds")};lo[axis]=min(lo[axis],x);hi[axis]=max(hi[axis],x)}}
        XCTAssertEqual(zip(lo,hi).map{$0.1-$0.0},[80,10,50]);try assertVolume(d,id)
        return(d,id,lo,hi)
    }
    private func assertVolume(_ d:FloeCADDocument,_ id:UUID)throws {
        let result=d.measureJSON(["kind":"body","bodyID":id.uuidString]);guard result.isOK else{throw fail(result.message ?? "Native independent measurement failed")}
        let volume=try XCTUnwrap((try JSONSerialization.jsonObject(with:result.payload) as? [String:Any])?["volumeMM3"] as? Double);XCTAssertEqual(volume,40000,accuracy:1e-7)
    }
    private func parameters(_ lo:[Double],_ hi:[Double],cancellation:Bool=false)->CadBasicMachiningParameters {
        let a=CadMultiAxisPreviewPose(tipMM:[lo[0]+37,lo[1]+5,lo[2]+30],axisTowardSpindle:[0,0,1]),b=CadMultiAxisPreviewPose(tipMM:[lo[0]+43,lo[1]+5,lo[2]+30],axisTowardSpindle:[0,-1,0])
        var sampling=CadMultiAxisPreviewSampling();sampling.maxAngularStepDegrees=cancellation ? 0.125:0.5
        let preview=CadMultiAxisPreviewParameters(poses:cancellation ? [a,b,a,b]:[a,b],sampling:sampling,holder:.init(radiusMM:3,lengthMM:6,offsetFromTipMM:10),fixtures:[.init(id:"owned-box",minMM:[lo[0]+60,lo[1]+20,hi[2]+10],maxMM:[lo[0]+62,lo[1]+22,hi[2]+12],resolutionMM:0.5)])
        return .init(resolutionMM:1,radiusMM:2,lengthMM:10,startTipMM:a.tipMM,endTipMM:b.tipMM,preview:preview)
    }
    private func waitReady(_ id:UUID,_ app:AppEnvironment,deadline:Date)async throws->CADBasicMachiningStudy {
        while Date()<deadline {
            let s=try await app.basicMachiningCenter.refreshFromUI(id)
            if s.state == .ready {return s}
            if [.failed,.interrupted,.stale,.cancelled].contains(s.state){report["failedOperationID"]=id.uuidString;report["failure"]=s.error ?? s.state.rawValue;try retain("native-operation-failed");throw fail(s.error ?? "Native job did not become ready")}
            try await Task.sleep(for:.milliseconds(100))
        }
        throw fail("Native operation deadline exceeded; original jobs and output remain retained")
    }
    private func bridgeRow(_ job:BackgroundJob,root:URL,client:MacBridgeClient)async throws->MacBridgeClient.SavedJob? {
        let c=ToolContext(runID:job.runID,toolCallID:"jobs.\(job.id.uuidString)",workspaceRootURL:root,cancellation:CancellationToken(),environmentID:job.environmentID,conversationID:job.conversationID)
        let matches=try await client.savedJobs().filter{$0.rootPath==root.path&&$0.sessionID==c.clientScopedSessionToken}
        guard matches.count<=1 else{throw fail("More than one companion attempt for the exact native job session; no replay accepted")};return matches.first
    }
    private func bindReceipt(_ s:CADBasicMachiningStudy,app:AppEnvironment,root:URL,client:MacBridgeClient)async throws {
        let jobs=try XCTUnwrap(app.backgroundJobService),store=try CADBasicMachiningStudyStore(),archive=store.directory(s.id),receipt=try object(archive.appendingPathComponent("acceptance.json"))
        let preparation=try await jobs.ownedJob(id:try XCTUnwrap(s.preparationJobID),runID:s.createdRunID),simulation=try await jobs.ownedJob(id:try XCTUnwrap(s.simulationJobID),runID:s.createdRunID)
        var links:[[String:Any]]=[]
        for (job,payload,phase) in [(preparation,s.preparationPayload,"environment"),(simulation,s.simulationPayload,"simulation")] {
            XCTAssertEqual(job.state,.completed);XCTAssertEqual(job.environmentID,s.environmentID);XCTAssertEqual(job.conversationID,s.conversationID);XCTAssertEqual(job.workspaceRootPath,root.path);XCTAssertEqual(job.targetTool,"exec.shell")
            XCTAssertEqual(try canonical(job.payloadJSON),try canonical(payload))
            let actualRow=try await bridgeRow(job,root:root,client:client)
            let row=try XCTUnwrap(actualRow,"The completed native job must have its actual companion attempt")
            let status=try await client.call("poll",["jobID":.string(row.id),"offset":.integer(0),"limit":.integer(1)])
            XCTAssertEqual(status["alive"]?.bool,false);XCTAssertNotEqual(status["outcomeUnknown"]?.bool,true);XCTAssertEqual(status["exitCode"]?.integer,0)
            let log=root.appendingPathComponent(".floe/terminal/\(row.id).log"),bytes=try Data(contentsOf:log)
            XCTAssertFalse(bytes.isEmpty)
            links.append(["phase":phase,"nativeJobID":job.id.uuidString,"nativeRunID":job.runID.uuidString,"companionJobID":row.id,"clientSessionID":row.sessionID,"environmentID":s.environmentID,"payloadSHA256":FloeDigest.sha256Hex(job.payloadJSON),"fullTerminalBytes":bytes.count,"fullTerminalSHA256":FloeDigest.sha256Hex(bytes)])
        }
        XCTAssertEqual(receipt["schema"] as? String,"floe.basic-machining-accepted.v1");XCTAssertEqual(receipt["sourceUnchanged"] as? Bool,true)
        XCTAssertEqual(receipt["stlSHA256"] as? String,s.artifact?.sha256);XCTAssertEqual(receipt["stlBytes"] as? Int,s.artifact?.byteCount)
        XCTAssertEqual(receipt["jobID"] as? String,simulation.id.uuidString);XCTAssertEqual(receipt["runID"] as? String,simulation.runID.uuidString)
        XCTAssertEqual(receipt["operationID"] as? String,s.id.uuidString);XCTAssertEqual(receipt["conversationID"] as? String,s.conversationID.uuidString);XCTAssertEqual(receipt["environmentID"] as? String,s.environmentID)
        XCTAssertEqual(receipt["sourceRevision"] as? Int,s.source.revision);XCTAssertEqual(receipt["sourceContentSHA256"] as? String,s.source.contentSHA256);XCTAssertEqual(receipt["sourceModelSHA256"] as? String,s.source.modelSHA256)
        XCTAssertEqual(receipt["requestSHA256"] as? String,s.inputSHA256);XCTAssertEqual(s.acceptedJobRunID,simulation.runID)
        let output=root.appendingPathComponent(s.relativeDirectory+"/output"),manifest=try object(output.appendingPathComponent("manifest.json")),rows=try XCTUnwrap(manifest["artifacts"] as? [[String:Any]])
        XCTAssertEqual(rows.count,14,"The positive fixture owns 14 concrete output files, including the stock.occupancy alias")
        for row in rows {
            let path=try XCTUnwrap(row["path"] as? String);guard !path.hasPrefix("/"),!path.split(separator:"/").contains("..") else{throw fail("Unsafe returned artifact path")}
            for file in [output.appendingPathComponent(path),archive.appendingPathComponent(path)] {
                let d=try Data(contentsOf:file);XCTAssertEqual(d.count,row["bytes"] as? Int);XCTAssertEqual(FloeDigest.sha256Hex(d),row["sha256"] as? String)
            }
        }
        XCTAssertEqual(manifest["ownerBindingVerified"] as? Bool,false,"The CLI cannot mint a native job receipt")
        XCTAssertEqual(receipt["manifestSHA256"] as? String,FloeDigest.sha256Hex(try Data(contentsOf:output.appendingPathComponent("manifest.json"))))
        let events=try await app.runStore.events(runID:s.createdRunID)
        XCTAssertTrue(events.contains{CADBasicMachiningNativeRunMetadata.matches($0,runID:s.createdRunID,conversationID:s.conversationID)})
        report["realExecutionJoin"]=links;report["positiveOperationID"]=s.id.uuidString;report["all14ArtifactsRecoveredAndArchived"]=true;report["acceptanceReceiptSHA256"]=FloeDigest.sha256Hex(try Data(contentsOf:archive.appendingPathComponent("acceptance.json")))
        try retain("actual-jobs-companion-output-and-native-acceptance-joined")
    }

    func testActualBridge11NativeCADJobsCollectAllArtifactsCancelAndReopen()async throws {
        let opt=try optIn();guard LocalBridgePlatform.current.supportsMacBridge,ProcessInfo.processInfo.isiOSAppOnMac else{throw fail("This selector requires the Mac Designed-for-iPad App; no Simulator/iPad/Linux/host fallback")}
        let app=try await appQualificationEnvironment();self.app=app
        let client=MacBridgeClient.shared;try await client.bootstrap();guard await client.isConnected() else{throw fail("Root must restore the signed companion and complete real two-sided pairing; disconnected is not a skip/pass")}
        let ping=try await client.call("ping");guard ping["os"]?.string=="macos",ping["arch"]?.string=="arm64",ping["appVersion"]?.string=="1.1.0",ping["sourceCommit"]?.string==Self.bridgeSource else{throw fail("Actual companion identity differs from the public Bridge 1.1 source; never substitute the old 1.0 selector")}
        let conversationID=UUID(),workspaceID=UUID(),relative="PrivateTasks/\(conversationID.uuidString)"
        let support=try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true),root=support.appendingPathComponent("FloeAgent/"+relative,isDirectory:true).standardizedFileURL.resolvingSymlinksInPath()
        guard !FileManager.default.fileExists(atPath:root.path) else{throw fail("Owned qualification workspace already exists")};try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);evidenceRoot=root
        report.merge(["rootPath":root.path,"conversationID":conversationID.uuidString,"workspaceRecordID":workspaceID.uuidString,"companionVersion":"1.1.0","companionSource":Self.bridgeSource,"companionBuild":ping["appBuild"]?.string ?? "missing","appBundleID":opt.expectedAppBundleID]){_,new in new};try retain("actual-connected-companion-admitted")
        try await app.conversationStore.saveConversation(.init(id:conversationID,title:"E38 owned Bridge 1.1 qualification",createdAt:Date(),updatedAt:Date()))
        let workspaces=SQLiteWorkspaceStore(database:app.database)
        try await workspaces.saveWorkspace(.init(id:workspaceID,name:"E38 owned Bridge qualification",rootBookmark:Data(),kind:.privateTask,internalRelativePath:relative))
        try await workspaces.linkConversation(workspaceID:workspaceID,conversationID:conversationID)
        try await workspaces.saveTaskPolicy(.init(conversationID:conversationID,approvalMode:TaskApprovalMode.automatic.rawValue,allowedToolNames:Set(["cad.document","exec.shell","jobs.submit","jobs.status","jobs.cancel"]),filePaths:[],networkAllowed:true,browserControlAllowed:false,uploadAllowed:false,credentialsAllowed:false,remoteExecutionAllowed:false,recoveryPolicy:.safePoint,notificationPolicy:.stages))
        let target=try await app.taskExecutionEnvironments.prepareTarget(.init(id:"mac",name:"This Mac",kind:.mac),conversationID:conversationID,root:root,fresh:true)
        let binding=try await TaskExecutionBindingStore(database:app.database).bindInitial(.init(conversationID:conversationID,target:target))
        XCTAssertEqual(binding.target.backend,.macBridge);XCTAssertEqual(binding.target.operatingSystem,"macos");XCTAssertEqual(binding.target.architecture,"arm64")
        let actualRecord=await app.environmentRegistry.record(id:target.environmentID);let record=try XCTUnwrap(actualRecord);XCTAssertEqual(record.ownerID,conversationID.uuidString);XCTAssertEqual(record.state,.active);XCTAssertEqual(record.effectiveExecutionBackend,.macBridge)
        report["environmentID"]=target.environmentID;report["companionWorkspaceID"]=await client.workspaceID(for:root);try retain("actual-task-owned-Mac-environment-bound")
        let url=root.appendingPathComponent("BridgeOwnedPart.floecad");documentURL=url;let(document,bodyID,lo,hi)=try await makePart(url)
        let originalIdentity=await FloeCADDocument.storedIdentity(at:url);let before=try XCTUnwrap(originalIdentity);let id=try await app.basicMachiningCenter.startFromUI(documentURL:url,bodyID:bodyID,parameters:parameters(lo,hi),workspaceRoot:root,workspaceID:workspaceID,conversationID:conversationID);operations.append(id)
        let ready=try await waitReady(id,app,deadline:Date().addingTimeInterval(opt.maxSeconds));XCTAssertEqual(ready.formatVersion,2);XCTAssertEqual(ready.source.bodyID,bodyID);XCTAssertEqual(ready.source.revision,before.revision);XCTAssertEqual(ready.source.contentSHA256,before.contentSHA256);XCTAssertEqual(ready.source.modelSHA256,before.modelSHA256)
        XCTAssertEqual(ready.removedMM3,365);XCTAssertEqual(ready.remainingMM3,39635);XCTAssertEqual(ready.previewSummary?.continuousRemainingLowerMM3,39229);XCTAssertEqual(ready.previewSummary?.continuousRemainingUpperMM3,39850);XCTAssertEqual(ready.previewSummary?.fixtures.first?.state,"clear")
        XCTAssertTrue(ready.environmentVerified);XCTAssertFalse(ready.cancelRequested)
        let routeContext=ToolContext(runID:ready.createdRunID,workspaceRootURL:root,cancellation:CancellationToken(),environmentID:target.environmentID,conversationID:conversationID)
        let lease=try await ToolEnvironmentRouting.shared.acquire(routeContext)
        XCTAssertEqual(lease.context.environmentID,target.environmentID);XCTAssertEqual(lease.context.environment?.variables["FLOE_EXECUTION_BACKEND"],"macBridge")
        await lease.finish();report["actualEnvironmentLeaseVerified"]=true
        try await bindReceipt(ready,app:app,root:root,client:client)
        let attempts=try await client.savedJobs().filter{$0.rootPath==root.path}.map(\.id)
        await FloeCAD3DBridge.shared.releaseDocument(at:url);let reopened=try await FloeCAD3DBridge.shared.openDocument(at:url);try assertVolume(reopened,bodyID)
        let reopenedIdentityValue=await FloeCADDocument.storedIdentity(at:url);let reopenedIdentity=try XCTUnwrap(reopenedIdentityValue)
        XCTAssertEqual(reopenedIdentity.modelSHA256,before.modelSHA256);XCTAssertGreaterThanOrEqual(reopenedIdentity.revision,before.revision)
        let observer=CADBasicMachiningCenter(environment:app),restored=try await observer.refreshFromUI(id)
        XCTAssertEqual(restored.state,.ready);XCTAssertEqual(restored.id,id);XCTAssertEqual(restored.parameters,ready.parameters);XCTAssertEqual(restored.source,ready.source);let afterPositiveReopen=try await client.savedJobs().filter{$0.rootPath==root.path}.map(\.id);XCTAssertEqual(afterPositiveReopen,attempts,"Reopen must observe the original job, never resubmit")
        let cancelledID=try await app.basicMachiningCenter.startFromUI(documentURL:url,bodyID:bodyID,parameters:parameters(lo,hi,cancellation:true),workspaceRoot:root,workspaceID:workspaceID,conversationID:conversationID);operations.append(cancelledID)
        let jobs=try XCTUnwrap(app.backgroundJobService),deadline=Date().addingTimeInterval(opt.maxSeconds);var actualRunning:(BackgroundJob,MacBridgeClient.SavedJob)?
        while Date()<deadline {
            let s=try app.basicMachiningCenter.study(cancelledID)
            if let jobID=s.simulationJobID {let job=try await jobs.ownedJob(id:jobID,runID:s.createdRunID)
                if job.state == .running,let row=try await bridgeRow(job,root:root,client:client) {let status=try await client.call("poll",["jobID":.string(row.id),"offset":.integer(0),"limit":.integer(4096)]);if status["alive"]?.bool==true,let bytes=status["data"]?.string.flatMap({Data(base64Encoded:$0)}),String(decoding:bytes,as:UTF8.self).contains("Multi-axis stock preview: computing") {actualRunning=(job,row);break}}
                if job.state.isTerminal {throw fail("The real cancellation window was missed; retain this run rather than retry-to-green")}
            }
            if [.ready,.failed,.interrupted,.stale,.cancelled].contains(s.state){throw fail(s.error ?? "Cancellation fixture terminated before observing a real running simulation")}
            try await Task.sleep(for:.milliseconds(25))
        }
        let running=try XCTUnwrap(actualRunning,"No actual running companion computation was observed");_ = try await app.basicMachiningCenter.cancel(cancelledID)
        var cancelled=try app.basicMachiningCenter.study(cancelledID);let cancelDeadline=Date().addingTimeInterval(30)
        while Date()<cancelDeadline,cancelled.state != .cancelled {cancelled=try await app.basicMachiningCenter.refreshFromUI(cancelledID);try await Task.sleep(for:.milliseconds(100))}
        XCTAssertEqual(cancelled.state,.cancelled);XCTAssertTrue(cancelled.cancelRequested);XCTAssertNil(cancelled.artifact);XCTAssertNil(cancelled.acceptedJobRunID)
        let terminal=try await jobs.ownedJob(id:running.0.id,runID:running.0.runID);XCTAssertEqual(terminal.state,.cancelled)
        let stopped=try await client.call("poll",["jobID":.string(running.1.id),"offset":.integer(0),"limit":.integer(1)]);XCTAssertEqual(stopped["alive"]?.bool,false);XCTAssertNotEqual(stopped["outcomeUnknown"]?.bool,true)
        let cancelledArchive=try CADBasicMachiningStudyStore().directory(cancelledID);XCTAssertFalse(FileManager.default.fileExists(atPath:cancelledArchive.appendingPathComponent("acceptance.json").path))
        let beforeReopen=try await client.savedJobs().filter{$0.rootPath==root.path}.map(\.id),reopenedCancelled=try await CADBasicMachiningCenter(environment:app).refreshFromUI(cancelledID)
        XCTAssertEqual(reopenedCancelled.state,.cancelled);XCTAssertNil(reopenedCancelled.artifact);let afterCancelledReopen=try await client.savedJobs().filter{$0.rootPath==root.path}.map(\.id);XCTAssertEqual(afterCancelledReopen,beforeReopen)
        let finalIdentity=await FloeCADDocument.storedIdentity(at:url);let final=try XCTUnwrap(finalIdentity);XCTAssertEqual(final.revision,reopenedIdentity.revision);XCTAssertEqual(final.contentSHA256,reopenedIdentity.contentSHA256);XCTAssertEqual(final.modelSHA256,before.modelSHA256);XCTAssertFalse(reopened.hasUnsavedChanges);try assertVolume(reopened,bodyID)
        let failures=try XCTUnwrap(testRun).failureCount;report["assertionFailures"]=failures
        guard failures==0 else{try retain("failed-real-service-assertions");throw fail("Live chain assertions failed; no success receipt is emitted")}
        report["cancelledOperationID"]=cancelledID.uuidString;report["cancelledNativeJobID"]=terminal.id.uuidString;report["cancelledCompanionJobID"]=running.1.id;report["actualRunningCancellation"]=true;report["reopenDoesNotSubmit"]=true;report["sourceModelUnchanged"]=true;report["executionSourceRevision"]=before.revision;report["savedReopenRevision"]=reopenedIdentity.revision;report["result"]="actual-native-service-chain-passed";try retain("passed-root-owns-final-UI-and-cleanup")
    }
}
#endif
