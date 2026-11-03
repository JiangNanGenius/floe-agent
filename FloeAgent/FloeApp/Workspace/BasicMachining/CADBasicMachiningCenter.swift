// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCAD
import FloeCore
import FloeEnvironments
import FloeExecution
import FloeModels
import FloePersistence
import FloeTools
import FloeWorkbench

@MainActor
final class CADBasicMachiningCenter {
    weak var environment: AppEnvironment?
    private var workers:[UUID:Task<Void,Never>]=[:]
    private var validationTasks:[UUID:Task<CADBasicMachiningVerified,Error>]=[:]
    private var validationTokens:[UUID:CancellationToken]=[:]
    init(environment:AppEnvironment){self.environment=environment}
    private func env()throws->AppEnvironment {guard let environment else{throw FloeError.validationFailed("The application owner is unavailable")};return environment}
    private func store()throws->CADBasicMachiningStudyStore {try CADBasicMachiningStudyStore()}
    private func json(_ object:[String:Any])throws->String {String(decoding:try JSONSerialization.data(withJSONObject:object,options:.sortedKeys),as:UTF8.self)}
    private func owned(_ id:UUID,url:URL,context:ToolContext)throws->CADBasicMachiningStudy {
        let s=try store().load(id)
        guard context.conversationID==s.conversationID,context.environmentID==s.environmentID,
              context.workspaceRootURL?.standardizedFileURL.resolvingSymlinksInPath()==s.workspaceRoot,
              url.standardizedFileURL.resolvingSymlinksInPath()==s.source.documentURL else{throw FloeError.unauthorized}
        try context.authorizeWorkspacePath(s.relativeDirectory)
        return s
    }
    private func save(_ s:CADBasicMachiningStudy)throws {var copy=s;copy.updatedAt=Date();try store().save(copy)}
    private func requireTarget(_ context:ToolContext) async throws {
        guard LocalBridgePlatform.current.supportsMacBridge,context.canvasStagedDocument==nil,
              context.conversationID != nil,let id=context.environmentID,
              let record=await (try env()).environmentRegistry.record(id:id),record.state == .active,
              record.effectiveExecutionBackend == .macBridge,
              await MacBridgeClient.shared.isConnected() else {
            throw FloeError.validationFailed("Basic machining needs this task's connected Mac execution environment. No other target was selected.")
        }
        let lease=try await ToolEnvironmentRouting.shared.acquire(context)
        defer {Task{await lease.finish()}}
        guard lease.context.environmentID==id,lease.context.environment?.variables["FLOE_EXECUTION_BACKEND"]=="macBridge" else{throw FloeError.unauthorized}
    }
    func uiAvailable(conversationID:UUID?,root:URL?) async->Bool {
        guard let conversationID,root != nil,LocalBridgePlatform.current.supportsMacBridge,
              let environment,let binding=try? await TaskExecutionBindingStore(database:environment.database).binding(conversationID:conversationID),
              binding.target.backend == .macBridge,
              let record=await environment.environmentRegistry.record(id:binding.target.environmentID),record.state == .active,
              await MacBridgeClient.shared.isConnected() else{return false}
        return (try? CADBasicMachiningResources.validateBundle()) != nil
    }
    func latest(documentURL:URL,conversationID:UUID,root:URL,preview:Bool=false)->CADBasicMachiningStudy? {
        try? store().latest(documentURL:documentURL.standardizedFileURL.resolvingSymlinksInPath(),conversationID:conversationID,root:root.standardizedFileURL.resolvingSymlinksInPath(),preview:preview)
    }
    func multiAxisUIAvailable(conversationID:UUID?,root:URL?) async->Bool {
        guard await uiAvailable(conversationID:conversationID,root:root) else{return false}
        return (try? CADMultiAxisPreviewResources.validateBundle()) != nil
    }
    func isRunning(_ id:UUID)->Bool {workers[id] != nil}
    func study(_ id:UUID)throws->CADBasicMachiningStudy {try store().load(id)}

    /// Model calls prepare/collect only. This method NEVER submits an execution job.
    func handleAI(documentURL:URL,request:CadBasicMachiningRequest,context:ToolContext) async throws->CadBasicMachiningReply {
        guard !context.temporaryReadOnly,context.canvasStagedDocument==nil else{throw FloeError.unauthorized}
        switch request.action {
        case .availability:
            do {try await requireTarget(context);try CADBasicMachiningResources.validateBundle()
                return try reply(["ok":true,"available":false,"can_prepare":true,"state":"requires_environment_preparation","requires_environment_preparation":true,"scope":"fixed-Z straight flat-end-mill stock visualization","execution":"jobs.submit -> exec.shell","preview_can_prepare":(try? CADMultiAxisPreviewResources.validateBundle()) != nil,"preview_scope":"bounded XYZ/IJK voxel stock preview, optional cylindrical holder/box-fixture three-state checks; no CAM planning or turn-mill","full_engineering_analysis":false])
            } catch {return try reply(["ok":true,"available":false,"reason":error.localizedDescription,"full_engineering_analysis":false])}
        case .prepare:
            if let ceiling=context.allowedToolNames,(!ceiling.contains("exec.shell") || !ceiling.contains("jobs.submit")){throw FloeError.unauthorized}
            let s=try await prepare(documentURL:documentURL,bodyID:request.bodyID!,parameters:request.parameters!,context:context)
            return s.state == .prepared ? try plan(s,phase:.environment) : try statusReply(s)
        case .collect:
            _=try owned(request.operationID!,url:documentURL,context:context)
            let s=try await collect(request.operationID!,phase:request.phase!,jobID:request.jobID!,context:context)
            if request.phase == .environment,s.state == .environmentReady {return try plan(s,phase:.simulation)}
            return try statusReply(s)
        case .status:
            var s=try owned(request.operationID!,url:documentURL,context:context)
            if s.state == .ready {do{try await CADBasicMachiningSnapshot.requireCurrent(s.source)}catch{s.state = .stale;s.error=error.localizedDescription;try save(s)}}
            return try statusReply(s)
        case .cancel:
            let s=try owned(request.operationID!,url:documentURL,context:context)
            return try statusReply(try await cancel(s.id))
        }
    }
    private func reply(_ object:[String:Any],artifact:CadBasicMachiningArtifact?=nil)throws->CadBasicMachiningReply {
        CadBasicMachiningReply(json:try json(object),artifact:artifact)
    }
    private func statusReply(_ s:CADBasicMachiningStudy)throws->CadBasicMachiningReply {
        var object:[String:Any]=["ok":s.state != .failed && s.state != .stale && s.state != .interrupted,"operation_id":s.id.uuidString,"state":s.state.rawValue,"source_revision":s.source.revision,"source_model_sha256":s.source.modelSHA256,"environment_id":s.environmentID,"mode":s.parameters.preview == nil ? "basic-fixed-z":"multi-axis-preview","precision":"approximate voxel mesh; not BRep or machine-safety verification"]
        if let summary=s.previewSummary {
            object["mode"]="multi-axis-preview";object["precision"]="sampled voxel nominal mesh with a certified continuous remaining-volume bracket; no CAM planning, turn-mill or complete machine safety"
            object["continuous_remaining_lower_mm3"]=summary.continuousRemainingLowerMM3;object["continuous_remaining_upper_mm3"]=summary.continuousRemainingUpperMM3
            object["fixture_checks"]=summary.fixtures.map{["id":$0.id,"state":$0.state]}
            if s.state == .ready {object["remaining_lower_path"]=s.relativeDirectory+"/output/motion/remaining-lower.stl";object["remaining_upper_path"]=s.relativeDirectory+"/output/motion/remaining-upper.stl"}
        }
        if let value=s.removedMM3{object["removed_mm3"]=value};if let value=s.remainingMM3{object["remaining_mm3"]=value}
        if let run=s.acceptedJobRunID{object["accepted_run_id"]=run.uuidString}
        if let error=s.error{object["message"]=error};if let j=s.preparationJobID{object["environment_job_id"]=j.uuidString};if let j=s.simulationJobID{object["simulation_job_id"]=j.uuidString}
        if s.state == .ready,let artifact=s.artifact {object["artifact_path"]=artifact.artifactPath;object["workspace_path"]=artifact.workspacePath;object["sha256"]=artifact.sha256;return try reply(object,artifact:artifact)}
        return try reply(object)
    }
    private func plan(_ s:CADBasicMachiningStudy,phase:CadBasicMachiningRequest.Phase)throws->CadBasicMachiningReply {
        let payload=phase == .environment ? s.preparationPayload:s.simulationPayload
        return try reply(["ok":true,"operation_id":s.id.uuidString,"phase":phase.rawValue,"state":s.state.rawValue,
            "next_tool":"jobs.submit","next_arguments":["tool":"exec.shell","arguments":String(decoding:payload,as:UTF8.self),"purpose":phase == .environment ? "Prepare the selected Mac environment for basic machining":(s.parameters.preview == nil ? "Compute the saved part's bounded stock mesh":"Preview bounded XYZ/IJK stock removal and continuous-volume brackets"),"wait":true],
            "after_submission":"Call cad.document machining collect with this operation_id, phase and the real returned job_id. A running/cancelling/failed/foreign job never becomes a ready result.","environment_id":s.environmentID])
    }
    private func prepare(documentURL:URL,bodyID:UUID,parameters:CadBasicMachiningParameters,context:ToolContext) async throws->CADBasicMachiningStudy {
        try parameters.validate();if parameters.preview != nil {try CADMultiAxisPreviewResources.validateBundle()};try context.cancellation.throwIfCancelled();try await requireTarget(context)
        guard let root=context.workspaceRootURL?.standardizedFileURL.resolvingSymlinksInPath(),let owner=context.conversationID,let environmentID=context.environmentID else{throw FloeError.unauthorized}
        let url=documentURL.standardizedFileURL.resolvingSymlinksInPath();guard url.path.hasPrefix(root.path+"/") else{throw FloeError.unauthorized}
        let id:UUID
        if let call=context.toolCallID {
            let hex=FloeDigest.sha256Hex(Data((context.runID.uuidString+":"+call).utf8));let prefix=Array(hex.prefix(32))
            let raw=String(prefix[0..<8])+"-"+String(prefix[8..<12])+"-"+String(prefix[12..<16])+"-"+String(prefix[16..<20])+"-"+String(prefix[20..<32]);id=UUID(uuidString:raw)!
            if let existing=try? store().load(id) {
                guard existing.conversationID==owner,existing.environmentID==environmentID,existing.workspaceRoot==root,existing.source.documentURL==url,existing.source.bodyID==bodyID,existing.parameters==parameters else{throw FloeError.unauthorized}
                try context.authorizeWorkspacePath(existing.relativeDirectory)
                try await CADBasicMachiningSnapshot.requireCurrent(existing.source);return existing
            }
        }else{id=UUID()}
        let relative="BasicMachining/\(id.uuidString)";try context.authorizeWorkspacePath(relative)
        let directory=root.appendingPathComponent(relative,isDirectory:true);guard !FileManager.default.fileExists(atPath:directory.path) else{throw FloeError.validationFailed("Operation directory already exists")}
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        do {
            let source=try await CADBasicMachiningSnapshot.capture(documentURL:url,bodyID:bodyID,destination:directory.appendingPathComponent("input/snapshot"),cancellation:context.cancellation)
            try CADBasicMachiningResources.stage(into:directory.appendingPathComponent("support"))
            if parameters.preview != nil {try CADMultiAxisPreviewResources.stage(into:directory.appendingPathComponent("support"))}
            let input=try json(["schema":"floe.cad-stock-task.v1","units":"mm",
                "ownerBinding":["operationID":id.uuidString,"environmentID":environmentID,"conversationID":owner.uuidString,"runID":context.runID.uuidString,"jobID":NSNull(),"studyRevision":1],
                "source":["snapshotRoot":relative+"/input/snapshot","bodyID":bodyID.uuidString,"documentRevision":source.revision,"modelSHA256":source.modelSHA256,"contentSHA256":source.contentSHA256,
                    "files":source.members.sorted{$0.key<$1.key}.map{["path":relative+"/input/snapshot/"+$0.key,"sha256":$0.value]}],
                "stock":["mode":"part-bounding-box-blank","resolutionMM":parameters.resolutionMM],
                "tool":["kind":"flat-end-mill","radiusMM":parameters.radiusMM,"lengthMM":parameters.lengthMM],
                "path":["kind":"linear-fixed-z","startTipMM":parameters.startTipMM,"endTipMM":parameters.endTipMM]])
            let finalInput=parameters.preview != nil ? try CADMultiAxisPreviewResources.taskRequest(fromBasicJSON:input,parameters:parameters):input
            let data=Data(finalInput.utf8),hash=FloeDigest.sha256Hex(data);try data.write(to:directory.appendingPathComponent("input/request.json"),options:.atomic)
            let prep=try CADBasicMachiningResources.payload(phase:.environment,relativeDirectory:relative,inputSHA:hash,preview:parameters.preview != nil)
            let simulation=try CADBasicMachiningResources.payload(phase:.simulation,relativeDirectory:relative,inputSHA:hash,preview:parameters.preview != nil)
            var s=CADBasicMachiningStudy(id:id,conversationID:owner,createdRunID:context.runID,environmentID:environmentID,workspaceRoot:root,source:source,parameters:parameters,relativeDirectory:relative,inputSHA256:hash,preparationPayload:prep,simulationPayload:simulation,state:.prepared,createdAt:Date(),updatedAt:Date())
            if parameters.preview != nil {s.formatVersion=2}
            try save(s);return s
        }catch{try? Data(error.localizedDescription.utf8).write(to:directory.appendingPathComponent("prepare-failure.txt"),options:.atomic);throw error}
    }
    private func normalized(_ data:Data)throws->Data {try JSONSerialization.data(withJSONObject:JSONSerialization.jsonObject(with:data),options:.sortedKeys)}
    private func collect(_ id:UUID,phase:CadBasicMachiningRequest.Phase,jobID:UUID,context:ToolContext) async throws->CADBasicMachiningStudy {
        var s=try study(id);guard let jobs=try env().backgroundJobService else{throw FloeError.validationFailed("Background jobs are unavailable")}
        let job=try await jobs.ownedJob(id:jobID,runID:context.runID)
        s=try study(id) // Re-read after suspension: cancellation may have fenced the operation.
        let expected=phase == .environment ? s.preparationPayload:s.simulationPayload
        guard job.conversationID==s.conversationID,job.environmentID==s.environmentID,job.targetTool=="exec.shell",
              job.workspaceRootPath.map({URL(fileURLWithPath:$0).standardizedFileURL.resolvingSymlinksInPath()})==s.workspaceRoot,
              try normalized(job.payloadJSON)==normalized(expected) else{throw FloeError.unauthorized}
        if phase == .environment {
            guard s.preparationJobID==nil || s.preparationJobID==jobID else{throw FloeError.unauthorized};s.preparationJobID=jobID
        }else{guard s.simulationJobID==nil || s.simulationJobID==jobID else{throw FloeError.unauthorized};s.simulationJobID=jobID}
        if s.cancelRequested {s.state = job.state.isTerminal ? .cancelled:.cancelling;try save(s);return s}
        if [.failed,.interrupted,.stale].contains(s.state){return s}
        if job.state == .cancelled {s.state = .cancelled;try save(s);return s}
        if job.state == .failed || job.state == .interrupted {s.state = job.state == .failed ? .failed:.interrupted;s.error=job.lastError ?? "The job did not complete. Inspect its saved output before retrying.";try save(s);return s}
        if s.state == .cancelled {try save(s);return s}
        if !job.state.isTerminal {s.state = s.state == .cancelling ? .cancelling : phase == .environment ? .preparingEnvironment:.simulating;try save(s);return s}
        guard job.state == .completed else{throw FloeError.validationFailed("The job is not complete")}
        do {
            try await requireTarget(context);try await CADBasicMachiningSnapshot.requireCurrent(s.source)
            s=try study(id);if s.cancelRequested{return s}
            let directory=s.workspaceRoot.appendingPathComponent(s.relativeDirectory)
            if phase == .environment {
                if s.environmentVerified,(s.simulationJobID != nil || s.state == .ready){return s}
                try CADBasicMachiningResources.verifyPreparation(directory:directory,inputSHA:s.inputSHA256,preview:s.parameters.preview != nil)
                s.environmentVerified=true;s.state = .environmentReady
            } else {
                guard s.environmentVerified,s.preparationJobID != nil else{throw FloeError.validationFailed("Environment preparation was not verified")}
                if s.state == .ready, s.artifact != nil {return s}
                let verified=try await verifyResult(s,directory:directory.appendingPathComponent("output"))
                let current=try await CADBasicMachiningSnapshot.requireCurrent(s.source)
                s=try study(id);if s.cancelRequested{return s}
                try CADBasicMachiningSnapshot.requireLiveCurrent(current,source:s.source)
                let archive=try store().directory(id),stl=archive.appendingPathComponent("stock.stl"),manifest=archive.appendingPathComponent("manifest.json")
                if FileManager.default.fileExists(atPath:stl.path){guard try FloeDigest.sha256Hex(ofFileAt:stl)==verified.stlSHA256 else{throw FloeError.validationFailed("Stored result changed")}}
                else{try verified.stlData.write(to:stl,options:.atomic)}
                for (relative,data) in verified.supplementalFiles {
                    let target=archive.appendingPathComponent(relative).standardizedFileURL
                    guard !relative.hasPrefix("/"),!relative.split(separator:"/").contains(".."),target.path.hasPrefix(archive.standardizedFileURL.path+"/") else{throw FloeError.unauthorized}
                    try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
                    guard target.standardizedFileURL==target.resolvingSymlinksInPath().standardizedFileURL else{throw FloeError.unauthorized}
                    try data.write(to:target,options:.atomic)
                }
                try verified.manifestData.write(to:manifest,options:.atomic)
                s.previewSummary=verified.previewSummary
                s.artifact=CadBasicMachiningArtifact(workspacePath:s.relativeDirectory+"/output/stock.stl",artifactPath:"JobDownloads/BasicMachining/\(id.uuidString)/stock.stl",sha256:verified.stlSHA256,byteCount:verified.stlData.count,manifestSHA256:verified.manifestSHA256)
                let acceptance:[String:Any]=["schema":"floe.basic-machining-accepted.v1","operationID":id.uuidString,"environmentID":s.environmentID,
                    "conversationID":s.conversationID.uuidString,"jobID":job.id.uuidString,"runID":job.runID.uuidString,"sourceRevision":s.source.revision,
                    "sourceContentSHA256":s.source.contentSHA256,"sourceModelSHA256":s.source.modelSHA256,"requestSHA256":s.inputSHA256,
                    "manifestSHA256":verified.manifestSHA256,"stlSHA256":verified.stlSHA256,"stlBytes":verified.stlData.count,
                    "removedMM3":verified.removedMM3,"remainingMM3":verified.remainingMM3,"sourceUnchanged":true]
                try JSONSerialization.data(withJSONObject:acceptance,options:.sortedKeys).write(to:archive.appendingPathComponent("acceptance.json"),options:.atomic)
                s.removedMM3=verified.removedMM3;s.remainingMM3=verified.remainingMM3
                s.acceptedJobRunID=job.runID;s.state = .ready
            }
            s.error=nil;try save(s);return s
        }catch{s=try study(id);if !s.cancelRequested{s.state = .failed};s.error=error.localizedDescription;try save(s);throw error}
    }
    private func verifyResult(_ study:CADBasicMachiningStudy,directory:URL) async throws->CADBasicMachiningVerified {
        if let existing=validationTasks[study.id]{return try await existing.value}
        let token=CancellationToken();validationTokens[study.id]=token
        let task=Task.detached(priority:.userInitiated){
            if study.parameters.preview != nil {return try CADMultiAxisPreviewVerification.verify(directory:directory,study:study,cancellation:token)}
            return try CADBasicMachiningVerification.verify(directory:directory,study:study,coreSHA:CADBasicMachiningResources.coreSHA256,wrapperSHA:CADBasicMachiningResources.wrapperSHA256,cancellation:token)}
        validationTasks[study.id]=task
        defer{validationTasks[study.id]=nil;validationTokens[study.id]=nil}
        return try await task.value
    }
    func cancel(_ id:UUID) async throws->CADBasicMachiningStudy {
        var s=try study(id);guard s.state != .ready else{return s}
        s.cancelRequested=true;s.state = .cancelling;try save(s) // Fence before any suspension.
        validationTokens[id]?.cancel();validationTasks[id]?.cancel()
        let active=s.simulationJobID ?? s.preparationJobID
        if let active,let jobs=try env().backgroundJobService {
            let job=try await jobs.ownedJob(id:active,runID:s.createdRunID)
            guard job.conversationID==s.conversationID,job.environmentID==s.environmentID else{throw FloeError.unauthorized}
            let result=try await jobs.cancel(id:active)
            s=try study(id);s.state = result.state.isTerminal ? .cancelled:.cancelling
        }else{s.state = .cancelled}
        try save(s);return s
    }

    /// Reopening observes the durable existing job; never replays or submits an old command.
    func refreshFromUI(_ id:UUID) async throws->CADBasicMachiningStudy {
        var s=try study(id)
        if s.state == .ready {
            do{try await CADBasicMachiningSnapshot.requireCurrent(s.source,allowMetadataOnlyReopen:true)}catch{s.state = .stale;s.error=error.localizedDescription;try save(s)}
            return s
        }
        let context=ToolContext(runID:s.createdRunID,workspaceRootURL:s.workspaceRoot,cancellation:CancellationToken(),environmentID:s.environmentID,conversationID:s.conversationID)
        if let job=s.simulationJobID {return try await collect(id,phase:.simulation,jobID:job,context:context)}
        if let job=s.preparationJobID {return try await collect(id,phase:.environment,jobID:job,context:context)}
        return s
    }

    /// Explicit native UI intent only. AI requests cannot reach this entry.
    func startFromUI(documentURL:URL,bodyID:UUID,parameters:CadBasicMachiningParameters,workspaceRoot:URL,workspaceID:UUID,conversationID:UUID) async throws->UUID {
        let environment=try env();let owners=try await SQLiteWorkspaceStore(database:environment.database).conversations(workspaceID:workspaceID)
        guard owners.contains(conversationID),let binding=try await TaskExecutionBindingStore(database:environment.database).binding(conversationID:conversationID),binding.target.backend == .macBridge else{throw FloeError.unauthorized}
        let runID=UUID();try await environment.runStore.saveRun(RunRecord(id:runID,conversationID:conversationID,state:"completed",goal:"Basic machining simulation",startedAt:Date(),endedAt:Date(),executionBinding:binding))
        let context=ToolContext(runID:runID,workspaceRootURL:workspaceRoot,cancellation:CancellationToken(),environmentID:binding.target.environmentID,conversationID:conversationID)
        let s=try await prepare(documentURL:documentURL,bodyID:bodyID,parameters:parameters,context:context)
        try await environment.runStore.appendEvent(runID:runID,kind:.status,payloadJSON:CADBasicMachiningNativeRunMetadata(runID:runID,conversationID:conversationID,operationID:s.id,environmentID:s.environmentID).payloadJSON())
        workers[s.id]=Task{[weak self] in guard let self else{return};defer{self.workers[s.id]=nil;Task{await environment.backgroundJobService?.releaseAdvisoryGroupLease(groupID:s.id)}}
            do {for phase in [CadBasicMachiningRequest.Phase.environment,.simulation] {
                var latest=try self.study(s.id);if latest.state == .cancelled || latest.state == .cancelling{return}
                try await self.requireTarget(context);try await CADBasicMachiningSnapshot.requireCurrent(latest.source)
                latest=try self.study(s.id);if latest.cancelRequested{return}
                guard let jobs=environment.backgroundJobService else{throw FloeError.validationFailed("Background jobs unavailable")}
                let job=try await jobs.submit(runID:runID,toolCallID:nil,targetTool:"exec.shell",payloadJSON:phase == .environment ? latest.preparationPayload:latest.simulationPayload,scope:.local,workspaceRootURL:latest.workspaceRoot,allowedWorkspacePaths:[],environmentID:latest.environmentID,allowedToolNames:["exec.shell"],submissionSource:.nativeService,advisoryGroupID:s.id)
                latest=try self.study(s.id)
                if phase == .environment{latest.preparationJobID=job.id}else{latest.simulationJobID=job.id}
                if latest.state == .cancelled || latest.state == .cancelling{_ = try await jobs.cancel(id:job.id);latest.state = .cancelling;try self.save(latest)}else{try self.save(latest)}
                repeat {
                    let state=try await self.collect(s.id,phase:phase,jobID:job.id,context:context)
                    if [.cancelled,.failed,.interrupted,.stale].contains(state.state){return}
                    if phase == .environment && state.state == .environmentReady{break}
                    if phase == .simulation && state.state == .ready{return}
                    try await Task.sleep(for:.milliseconds(350))
                }while true
            }}catch{if var failed=try? self.study(s.id){if !failed.cancelRequested{failed.state = .failed};failed.error=error.localizedDescription;try? self.save(failed)}}
        }
        return s.id
    }
}

@MainActor
private enum CADBasicMachiningCenters {
    static var values:[ObjectIdentifier:CADBasicMachiningCenter]=[:]
    static func get(_ environment:AppEnvironment)->CADBasicMachiningCenter {
        values=values.filter{$0.value.environment != nil};let id=ObjectIdentifier(environment)
        if let value=values[id]{return value};let value=CADBasicMachiningCenter(environment:environment);values[id]=value;return value
    }
}
extension AppEnvironment {
    var basicMachiningCenter:CADBasicMachiningCenter {CADBasicMachiningCenters.get(self)}
}
