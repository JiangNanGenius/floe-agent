// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeModels
import FloeTools
import FloeExecution
import FloePersistence
import FloeEnvironments
import FloeBiologyCore
import FloeBiologyEngine
import FloeBiologyWorkerResources

public struct BiologyScientificQualification:Sendable {
    public let environmentID:String
    public let methods:Set<String>
    public let engines:JSONValue
    public let unavailable:JSONValue
    public let resourceDigest:String
}

/// Compiled scientific operations use the existing resolved exec.shell runner
/// and durable jobs. No Process, host interpreter, invented environment or
/// installer alias is exposed by this adapter.
public actor BiologyScientificJobs {
    private let jobs:BackgroundJobService
    private let registry:ToolRunnerRegistry
    private let contexts:BiologyExecutionContexts
    private let environments:EnvironmentRegistry
    private let files:(any BiologyFileAccessing)?
    private var active:[UUID:Set<UUID>]=[:]
    private var stopped:Set<UUID>=[]
    private var unconfirmed:Set<UUID>=[]
    public init(jobs:BackgroundJobService,registry:ToolRunnerRegistry = .shared,environments:EnvironmentRegistry,contexts:BiologyExecutionContexts,files:(any BiologyFileAccessing)?=nil) {self.jobs=jobs;self.registry=registry;self.environments=environments;self.contexts=contexts;self.files=files}
    private func validateEnvironment(_ context:ToolContext) async throws {
        guard let id=context.environmentID,context.environment?.id==id,let record=await environments.record(id:id),record.state != .deleting,!record.requiresRebuild,record.pendingRuntimeResetID==nil else {throw BiologyError.unavailable("The selected execution environment is missing, rebuilding or being deleted.")}
        guard record.effectiveExecutionBackend == .linuxVM || (record.effectiveExecutionBackend == .remoteSSH && record.operatingSystem?.lowercased()=="linux") else {throw BiologyError.unavailable("Select a Linux execution environment for these scientific packages.")}
        if record.kind == .session,record.ownerID?.lowercased() != context.conversationID?.uuidString.lowercased() {throw BiologyError.unavailable("This execution environment belongs to another task.")}
    }
    public func backend(qualified value:BiologyScientificQualification) throws -> ConfiguredBiologyBackend {
        try ConfiguredBiologyBackend(environmentID:value.environmentID,engineVersion:String(decoding:BiologyCoding.encode(value.engines),as:UTF8.self),methods:value.methods,prepare:{[contexts] run,owner,request in try await contexts.bind(runID:run,owner:owner,requestID:request)},execute:{[self] request in
            do{return try await execute(request)}catch let error as BiologyWorkerStopUnconfirmed{if let id=UUID(uuidString:request.identity.runID){await markUnconfirmed(id)};throw error}
        },stop:{[self] run in try await stop(run)})
    }
    private func markUnconfirmed(_ id:UUID){unconfirmed.insert(id)}
    public func probe(context:ToolContext) async throws -> BiologyScientificQualification {
        try await validateEnvironment(context)
        guard let environment=context.environmentID,context.environment?.id==environment,context.conversationID != nil,context.workspaceRootURL != nil,!context.temporaryReadOnly,!context.publicWebOnly,context.allowedToolNames?.contains("exec.shell") != false,let runner=registry.runner(named:"exec.shell") else {throw BiologyError.unavailable("Resolve a task-owned execution environment before probing biology engines.")}
        try context.cancellation.throwIfCancelled()
        let directory=".floe-biology/probe-"+UUID().uuidString.lowercased();try context.authorizeWorkspacePath(directory)
        let files=try BiologyWorkerResources.verifiedFiles(),data=try JSONEncoder().encode(files.mapValues{$0.base64EncodedString()})
        let script="""
        import pathlib,os,json,base64,sys
        root=pathlib.Path('\(directory)');root.mkdir(parents=True)
        assert root.resolve()==pathlib.Path.cwd()/root
        for name,data in json.loads(base64.b64decode('\(data.base64EncodedString())')).items():
            assert '/' not in name and '..' not in name
            fd=os.open(root/name,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
            with os.fdopen(fd,'wb') as f:f.write(base64.b64decode(data,validate=True))
        sys.path.insert(0,str(root))
        from biology_worker import capabilities
        result=capabilities()
        print('BIOLOGY_RECEIPT '+base64.b64encode(json.dumps(result).encode()).decode())
        """
        let output=try await runner.execute(argumentsJSON:JSONEncoder().encode(LocalShellTool.Arguments(script:Self.python(script),cwd:".",maxOutputBytes:32768)),context:context)
        guard output.exitStatus==0,!output.capturedOutputTruncated else {throw BiologyError.unavailable("The selected environment could not complete the scientific engine probe.")}
        let result=try Self.receipt(output.capturedOutput ?? output.summary)
        guard result["protocol"]?.string=="floe.biology.worker",result["version"]?.number==1,let methods=result["methods"]?.array else {throw BiologyError.corrupt("Scientific capability probe returned an invalid contract.")}
        return .init(environmentID:environment,methods:Set(methods.compactMap(\.string)),engines:result["engines"] ?? .object([:]),unavailable:result["unavailable"] ?? .object([:]),resourceDigest:BiologyProjectStore.digest(try BiologyCoding.encode(files.mapValues{BiologyProjectStore.digest($0)})))
    }
    public func stop(_ runID:UUID) async throws -> Bool {
        guard !unconfirmed.contains(runID) else{return false}
        stopped.insert(runID)
        let ids=active[runID] ?? []
        for id in ids { _=try await jobs.cancel(id:id) }
        for id in ids {
            while let job=try await jobs.job(id:id),!job.state.isTerminal {try await Task.sleep(for:.milliseconds(100))}
            guard let job=try await jobs.job(id:id),Self.stopped(job) else {return false}
        }
        // The service cancels and joins its orchestration task immediately
        // after this acknowledgement. The stopped flag fences later submits.
        return true
    }
    private func execute(_ request:BiologyTransportRequest) async throws -> BiologyTransportReceipt {
        guard let runID=UUID(uuidString:request.identity.runID),let projectID=UUID(uuidString:request.identity.projectID) else {throw BiologyError.invalid("Invalid scientific execution identity.")}
        let entry=try await contexts.entry(runID),context=entry.context
        try await validateEnvironment(context)
        guard context.runID.uuidString.lowercased()==request.identity.hostRunID,context.conversationID?.uuidString.lowercased()==request.identity.taskID,context.environmentID==request.identity.environmentID,context.environment?.id==request.identity.environmentID,context.workspaceRootURL != nil,context.allowedToolNames?.contains("exec.shell") != false else {throw BiologyError.unavailable("Scientific execution must use this task's resolved Linux environment and workspace.")}
        let relative=".floe-biology/"+request.identity.projectID+"/"+request.identity.runID+"/"+request.identity.attemptID
        try context.authorizeWorkspacePath(relative)
        active[runID]=[]
        defer {active.removeValue(forKey:runID);stopped.remove(runID);Task{await contexts.forget(runID)}}
        let resources=try BiologyWorkerResources.verifiedFiles()
        var staged=resources;staged["request.json"]=request.envelope
        let json=try JSONEncoder().encode(staged.mapValues{$0.base64EncodedString()})
        let setup="""
        import os,pathlib,base64,json
        root=pathlib.Path('\(relative)')
        root.mkdir(parents=True,exist_ok=True)
        assert root.resolve()==pathlib.Path.cwd()/root and not any(p.is_symlink() for p in [root,*root.parents]), 'Unsafe scientific workspace'
        for name,data in json.loads(base64.b64decode('\(json.base64EncodedString())')).items():
            assert '/' not in name and '..' not in name
            raw=base64.b64decode(data,validate=True)
            fd=os.open(root/name,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
            with os.fdopen(fd,'wb') as f: f.write(raw);f.flush();os.fsync(f.fileno())
        (root/'inputs').mkdir()
        print('BIOLOGY_RECEIPT '+base64.b64encode(b'{"staged":true}').decode())
        """
        let stagedJob=try await submit(script:setup,phase:"stage",runID:runID,entry:entry);_=try Self.receipt(stagedJob.resultSummary ?? "")
        if let snapshot=try JSONSerialization.jsonObject(with:request.envelope) as? [String:Any],let inner=snapshot["requestJSON"] as? String,
           let payload=try JSONSerialization.jsonObject(with:Data(inner.utf8)) as? [String:Any],let encoded=payload["snapshotJSON"] as? String,
           let asset=try? JSONDecoder().decode(BiologyAsset.self,from:Data(encoded.utf8)),let reference=asset.fileReference {
            guard let files,reference.projectID==projectID,reference.environmentID==request.identity.environmentID else {throw BiologyError.unavailable("The referenced input has no matching authorized file service.")}
            let fileContext=BiologyFileContext(projectID:projectID,owner:.init(taskID:context.conversationID!,hostRunID:context.runID))
            guard try await files.resolve(reference.id,context:fileContext)==reference else {throw BiologyError.corrupt("Referenced input identity changed.")}
            var offset:UInt64=0
            while offset<reference.byteCount {
                try check(runID,context:context)
                let length=Int(min(1_048_576,reference.byteCount-offset)),data=try await files.read(reference,offset:offset,length:length,context:fileContext)
                guard data.count==length else {throw BiologyError.corrupt("Referenced input was truncated.")}
                let script="""
                import pathlib,os,base64
                p=pathlib.Path('\(relative)/inputs/\(reference.sha256).bin')
                fd=os.open(p,os.O_WRONLY|os.O_CREAT|os.O_NOFOLLOW,0o600)
                with os.fdopen(fd,'r+b') as f:
                    assert os.fstat(f.fileno()).st_size==\(offset), 'Input stage offset changed'
                    f.seek(\(offset));f.write(base64.b64decode('\(data.base64EncodedString())',validate=True));f.flush();os.fsync(f.fileno())
                print('BIOLOGY_RECEIPT e30=')
                """
                let stagedInput=try await submit(script:script,phase:"input-"+String(offset),runID:runID,entry:entry);_=try Self.receipt(stagedInput.resultSummary ?? "");offset+=UInt64(length)
            }
        }
        try check(runID,context:context)
        // Shell metacharacters cannot originate from model arguments: paths
        // contain only host-generated UUIDs, and bytes are base64 data.
        let runScript="""
        set -eu
        python3 '\(relative)/biology_worker.py' --workspace '\(relative)' < '\(relative)/request.json' > '\(relative)/response.json' 2> '\(relative)/worker.log'
        python3 - <<'FLOE_BIOLOGY_RECEIPT'
        import pathlib,hashlib,base64,json
        p=pathlib.Path('\(relative)/response.json');n=p.stat().st_size
        assert 0<n<=33554432, 'Scientific output size exceeds budget'
        with p.open('rb') as f: digest=hashlib.file_digest(f,'sha256').hexdigest()
        print('BIOLOGY_RECEIPT '+base64.b64encode(json.dumps(dict(bytes=n,sha256=digest)).encode()).decode())
        FLOE_BIOLOGY_RECEIPT
        """
        let completed=try await submit(command:runScript,phase:"calculate",runID:runID,entry:entry)
        let receipt=try Self.receipt(completed.resultSummary ?? "")
        guard let size=receipt["bytes"]?.number,let digest=receipt["sha256"]?.string,size>0,size<=32*1024*1024 else {throw BiologyError.corrupt("Scientific job did not retain a complete output receipt.")}
        guard let runner=registry.runner(named:"exec.shell") else {throw BiologyError.unavailable("The selected environment has no exec.shell runner.")}
        var response=Data(),offset=0
        while offset<Int(size) {
            try check(runID,context:context)
            let length=min(8192,Int(size)-offset)
            let script="""
            import pathlib,os,base64
            p=pathlib.Path('\(relative)/response.json');fd=os.open(p,os.O_RDONLY|os.O_NOFOLLOW)
            with os.fdopen(fd,'rb') as f:
                assert os.fstat(f.fileno()).st_size==\(Int(size))
                f.seek(\(offset));data=f.read(\(length));assert len(data)==\(length)
            print('BIOLOGY_BYTES '+base64.b64encode(data).decode())
            """
            let arguments=try JSONEncoder().encode(LocalShellTool.Arguments(script:Self.python(script),cwd:".",maxOutputBytes:32768))
            let output=try await runner.execute(argumentsJSON:arguments,context:context)
            if output.outcomeUnknown {throw BiologyWorkerStopUnconfirmed("Scientific read-back lost its processor connection. The host must reconcile the owned worker before deleting its data.")}
            guard output.exitStatus==0,!output.capturedOutputTruncated,let line=(output.capturedOutput ?? output.summary).split(separator:"\n").first(where:{$0.hasPrefix("BIOLOGY_BYTES ")}),let data=Data(base64Encoded:String(line.dropFirst(14))),data.count==length else {throw BiologyError.corrupt("Scientific output range was incomplete or redacted.")}
            response+=data;offset+=length
        }
        guard BiologyProjectStore.digest(response)==digest else {throw BiologyError.corrupt("Scientific output digest changed during read-back.")}
        return BiologyTransportReceipt(jobID:completed.id,projectID:projectID,runID:runID,owner:.init(taskID:context.conversationID!,hostRunID:context.runID),environmentID:request.identity.environmentID,requestDigest:request.requestDigest,workerStopped:true,exitCode:0,response:response)
    }
    private static func python(_ source:String)->String {"python3 - <<'FLOE_BIOLOGY_COMPILED'\n"+source+"\nFLOE_BIOLOGY_COMPILED"}
    private func check(_ runID:UUID,context:ToolContext) throws {
        guard !stopped.contains(runID),!context.cancellation.isCancelled,!Task.isCancelled else {throw CancellationError()}
    }
    private func submit(script:String,phase:String,runID:UUID,entry:BiologyExecutionContexts.Entry) async throws -> BackgroundJob {try await submit(command:Self.python(script),phase:phase,runID:runID,entry:entry)}
    private func submit(command:String,phase:String,runID:UUID,entry:BiologyExecutionContexts.Entry) async throws -> BackgroundJob {
        let context=entry.context;try check(runID,context:context)
        try await validateEnvironment(context)
        let payload=try JSONEncoder().encode(LocalShellTool.Arguments(script:command,cwd:".",maxOutputBytes:16384))
        let callID="biology."+runID.uuidString.lowercased()+"."+phase
        let job=try await jobs.submit(runID:context.runID,toolCallID:callID,targetTool:"exec.shell",payloadJSON:payload,scope:context.scope,workspaceRootURL:context.workspaceRootURL,allowedWorkspacePaths:context.allowedWorkspacePaths,environmentID:context.environmentID,allowedToolNames:context.allowedToolNames,callOrigin:context.callOrigin,childExecution:context.childExecution,toolIdempotencyKey:context.toolIdempotencyKey,approvalGrantID:context.approvalGrantID,runtimeAuthority:context.runtimeAuthority,runtimeAuthorityBinding:entry.binding,submissionSource:.nativeService,waitForCompletion:true)
        guard job.runID==context.runID,job.conversationID==context.conversationID,job.environmentID==context.environmentID,job.targetTool=="exec.shell",job.payloadJSON==payload,job.toolCallID==callID else {throw BiologyError.corrupt("The background job does not match this exact scientific operation.")}
        active[runID,default:[]].insert(job.id)
        defer{active[runID]?.remove(job.id)}
        // A stop may have arrived while submission awaited durable storage.
        if stopped.contains(runID) || context.cancellation.isCancelled || Task.isCancelled {_=try await jobs.cancel(id:job.id)}
        while true {
            guard let current=try await jobs.job(id:job.id) else {throw BiologyError.corrupt("Scientific job record disappeared.")}
            if current.state.isTerminal {
                if current.state == .cancelled {throw CancellationError()}
                guard current.state == .completed else {
                    if !Self.stopped(current) {throw BiologyWorkerStopUnconfirmed(current.lastError ?? "The host has not confirmed that the scientific worker stopped.")}
                    throw BiologyError.unavailable(current.lastError ?? "Scientific processor did not complete.")
                }
                return current
            }
            if stopped.contains(runID) || context.cancellation.isCancelled || Task.isCancelled {_=try await jobs.cancel(id:job.id)}
            // Do not unwind a cancelled orchestration before the real job
            // has reached a durable terminal state.
            if Task.isCancelled {await Task.detached{try? await Task.sleep(for:.milliseconds(150))}.value}
            else {try? await Task.sleep(for:.milliseconds(150))}
        }
    }
    private static func receipt(_ text:String) throws -> JSONValue {
        let matches=text.split(separator:"\n").filter{$0.hasPrefix("BIOLOGY_RECEIPT ")}
        guard matches.count==1,let bytes=Data(base64Encoded:String(matches[0].dropFirst(16))) else {throw BiologyError.corrupt("Scientific stage has no valid completion receipt.")}
        return try JSONDecoder().decode(JSONValue.self,from:bytes)
    }
    private static func stopped(_ job:BackgroundJob)->Bool {
        if job.state == .completed || job.state == .cancelled {return true}
        // LocalShellTool puts the actual processor exit receipt BEFORE its
        // untrusted stdout. An unsafe/interrupted record has no such receipt.
        guard job.state == .failed,let first=job.resultSummary?.split(separator:"\n").first,first.hasPrefix("exit="),let code=first.split(separator:" ").first.flatMap({Int($0.dropFirst(5))}) else{return false}
        return code != 0
    }
}
