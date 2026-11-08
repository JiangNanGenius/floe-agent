// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeTools
import FloeExecution
import FloePersistence
import FloeEnvironments
import FloeLaTeXCore
import FloeLaTeXEngine

/// Concrete transport through Floe's existing exec.shell and durable jobs.
/// The compiled document service retains the original approved call provenance;
/// a model cannot manufacture a ToolContext or native-service submission flag.
public actor LaTeXShellTransport:LaTeXEnvironmentTransport {
    public nonisolated let owner:LaTeXExecutionOwner
    public nonisolated let isLocal:Bool
    private let context:ToolContext
    private let binding:RuntimeAuthorityBinding?
    private let jobs:BackgroundJobService
    private let environments:EnvironmentRegistry
    private let registry:ToolRunnerRegistry
    private let validateOwner:(@Sendable (ToolContext) async throws -> Void)?
    private var sequence=0
    private var active=Set<UUID>()
    private var unconfirmed=Set<UUID>()
    private init(context:ToolContext,binding:RuntimeAuthorityBinding?,jobs:BackgroundJobService,environments:EnvironmentRegistry,registry:ToolRunnerRegistry,isLocal:Bool,validateOwner:(@Sendable (ToolContext) async throws -> Void)?) {
        self.context=context;self.binding=binding;self.jobs=jobs;self.environments=environments;self.registry=registry;self.isLocal=isLocal
        self.validateOwner=validateOwner
        owner = .init(taskID:context.conversationID!,runID:context.runID,environmentID:context.environmentID)
    }
    public static func create(context:ToolContext,binding:RuntimeAuthorityBinding?,jobs:BackgroundJobService,environments:EnvironmentRegistry,lifetime:LaTeXHostProject,registry:ToolRunnerRegistry = .shared,validateOwner:(@Sendable (ToolContext) async throws -> Void)?=nil) async throws -> LaTeXShellTransport {
        guard !context.temporaryReadOnly,!context.publicWebOnly,context.conversationID != nil,context.workspaceRootURL != nil,
              context.allowedToolNames?.contains("exec.shell") != false,context.frozenEffectiveCatalogNames?.contains("exec.shell") != false,
              registry.runner(named:"exec.shell") != nil,context.approvalGrantID != nil,
              context.runtimeAuthority==nil || binding != nil,let id=context.environmentID,context.environment?.id==id,
              let record=await environments.record(id:id),record.state != .deleting,!record.requiresRebuild,record.pendingRuntimeResetID==nil,
              record.effectiveExecutionBackend == .linuxVM || (record.effectiveExecutionBackend == .remoteSSH && record.operatingSystem?.lowercased()=="linux") else {throw LaTeXError.unavailable("An authorized, resolved Linux exec.shell environment is required for the LaTeX toolchain.")}
        if record.kind == .session,record.ownerID?.lowercased() != context.conversationID?.uuidString.lowercased() {throw LaTeXError.unavailable("The selected environment belongs to another task.")}
        let lease=try await ToolEnvironmentRouting.shared.acquire(context)
        do {
            guard lease.context.environmentID==context.environmentID,lease.context.environment?.id==context.environmentID,
                  lease.context.runID==context.runID,lease.context.conversationID==context.conversationID else {throw LaTeXError.unavailable("The typesetting environment lease changed its owner.")}
            let value=LaTeXShellTransport(context:lease.context,binding:binding,jobs:jobs,environments:environments,registry:registry,isLocal:record.effectiveExecutionBackend == .linuxVM,validateOwner:validateOwner)
            try await value.validate();lifetime.retain(EnvironmentLifetime(lease:lease));return value
        }catch {await lease.finish();throw error}
    }
    private func validate() async throws {
        try context.cancellation.throwIfCancelled();try Task.checkCancellation()
        try await validateOwner?(context)
        guard let id=owner.environmentID,context.environmentID==id,context.environment?.id==id,
              let record=await environments.record(id:id),record.state != .deleting,!record.requiresRebuild,record.pendingRuntimeResetID==nil else {throw LaTeXError.unavailable("The LaTeX execution environment changed or is being retired.")}
        if let authority=context.runtimeAuthority {
            guard let binding else {throw LaTeXError.unavailable("The execution approval binding is missing.")}
            let result=await RuntimeAuthorityStore.shared.validate(authority,binding:binding)
            guard result.isValid else {throw LaTeXError.unavailable("This typesetting call no longer matches its runtime approval.")}
        }
    }
    public func authorize(relativePath:String) async throws {
        try await validate();try context.authorizeWorkspacePath(relativePath)
    }
    public func execute(script:String,maximumOutputBytes:Int) async throws -> LaTeXEnvironmentCommandResult {
        try await validate()
        guard let runner=registry.runner(named:"exec.shell") else {throw LaTeXError.unavailable("exec.shell is unavailable in this environment.")}
        let data=try JSONEncoder().encode(LocalShellTool.Arguments(script:script,cwd:".",maxOutputBytes:min(262144,max(1024,maximumOutputBytes))))
        let output:ToolExecutionOutput
        do {output=try await runner.execute(argumentsJSON:data,context:context)}
        catch {throw LaTeXEngineFailure("The environment command did not confirm its outcome.",messages:[error.localizedDescription],workerStopped:false)}
        guard !output.capturedOutputTruncated else {throw LaTeXEngineFailure("The environment truncated its typesetting transfer receipt.",workerStopped:!output.outcomeUnknown && output.exitStatus != nil)}
        return .init(stdout:output.capturedOutput ?? output.summary,exitStatus:output.exitStatus.map(Int.init) ?? -1,workerStopped:!output.outcomeUnknown && output.exitStatus != nil)
    }
    public func run(script:String,progress:@escaping @Sendable (String)->Void) async throws -> LaTeXEnvironmentCommandResult {
        // An unstructured service task outlives a cancelled waiter. In
        // particular, GRDB must still persist the cancellation request and
        // read the processor's canonical exit before this call can settle.
        let cancellation=context.cancellation
        let task=Task {try await self.runOwned(script:script,progress:progress)}
        return try await withTaskCancellationHandler(operation:{try await task.value},onCancel:{cancellation.cancel()})
    }
    private func runOwned(script:String,progress:@escaping @Sendable (String)->Void) async throws -> LaTeXEnvironmentCommandResult {
        try await validate();sequence+=1
        let call="latex."+context.runID.uuidString.lowercased()+"."+UUID().uuidString.lowercased()+"."+String(sequence)
        let data=try JSONEncoder().encode(LocalShellTool.Arguments(script:script,cwd:".",maxOutputBytes:262144))
        let submitted:BackgroundJob
        do {submitted=try await jobs.submit(runID:context.runID,toolCallID:call,targetTool:"exec.shell",payloadJSON:data,
            scope:context.scope,workspaceRootURL:context.workspaceRootURL,allowedWorkspacePaths:context.allowedWorkspacePaths,
            environmentID:context.environmentID,allowedToolNames:context.allowedToolNames,callOrigin:context.callOrigin,childExecution:context.childExecution,
            toolIdempotencyKey:context.toolIdempotencyKey,approvalGrantID:context.approvalGrantID,runtimeAuthority:context.runtimeAuthority,
            runtimeAuthorityBinding:binding,submissionSource:.nativeService,waitForCompletion:true)}
        catch {throw LaTeXEngineFailure("The environment job submission did not confirm its outcome.",messages:[error.localizedDescription],workerStopped:false)}
        guard submitted.runID==context.runID,submitted.conversationID==context.conversationID,submitted.environmentID==context.environmentID,
              submitted.toolCallID==call,submitted.targetTool=="exec.shell",submitted.payloadJSON==data else {throw LaTeXEngineFailure("The saved job does not match the exact typesetting operation.",workerStopped:false)}
        active.insert(submitted.id);unconfirmed.insert(submitted.id);defer {active.remove(submitted.id)}
        progress("Typesetting job "+submitted.id.uuidString.lowercased())
        var cancellationRequested=false
        do {while true {
            if context.cancellation.isCancelled && !cancellationRequested {
                _=try await jobs.cancel(id:submitted.id);cancellationRequested=true
            }
            guard let current=try await jobs.job(id:submitted.id) else {throw LaTeXEngineFailure("The typesetting job record disappeared.",workerStopped:false)}
            if current.state.isTerminal {
                let text=current.resultSummary ?? current.lastError ?? ""
                // Processor exit precedes untrusted stdout in LocalShellTool's
                // canonical receipt. A terminal DB state alone is insufficient.
                let code=Self.confirmedExit(text)
                let stopped=code != nil || (current.state == .cancelled && current.lastError=="Cancelled before execution started; no effects were produced.")
                if stopped {unconfirmed.remove(submitted.id)}
                if current.state == .cancelled {throw LaTeXEngineFailure("Typesetting cancelled",cancelled:true,workerStopped:stopped)}
                return .init(stdout:text,exitStatus:code ?? -1,workerStopped:code != nil)
            }
            await Task.detached {try? await Task.sleep(for:.milliseconds(150))}.value
        }} catch let failure as LaTeXEngineFailure {throw failure}
        catch {throw LaTeXEngineFailure("The existing typesetting job could not be reconciled.",messages:[error.localizedDescription],workerStopped:false)}
    }
    public func stop() async throws {
        // Stop is reconciliation, including when invoked by an already
        // cancelled caller. Never propagate waiter cancellation into GRDB.
        let task=Task {try await self.stopOwned()}
        try await task.value
    }
    private func stopOwned() async throws {
        let owned=active.union(unconfirmed)
        for id in owned {_=try await jobs.cancel(id:id)}
        for id in owned {
            while let job=try await jobs.job(id:id),!job.state.isTerminal {await Task.detached {try? await Task.sleep(for:.milliseconds(100))}.value}
            guard let job=try await jobs.job(id:id),Self.confirmedExit(job.resultSummary ?? "") != nil else {throw LaTeXEngineFailure("The existing environment job has not confirmed processor exit.",workerStopped:false)}
            unconfirmed.remove(id)
        }
    }
    static func confirmedExit(_ text:String)->Int? {
        guard let line=text.split(separator:"\n").first,line.hasPrefix("exit="),let field=line.split(separator:" ").first else {return nil}
        return Int(field.dropFirst(5))
    }
}

private final class EnvironmentLifetime:LaTeXBuildLifetime,Sendable {
    let lease:ToolEnvironmentLease
    init(lease:ToolEnvironmentLease) {self.lease=lease}
    deinit {let finish=lease.finish;Task {await finish()}}
}
