// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeSecurity
import FloeTools
import FloeLaTeXCore
import FloeLaTeXEngine
import FloeLaTeXHostAdapter

/// A native Typeset event owns a saved run and real execution leases. The
/// editor may disappear while this service finishes the same original.
@MainActor final class LaTeXNativeRuntime {
    private unowned let composition:LaTeXAppComposition
    private struct Owner {
        let runID:UUID
        let root:WorkspaceCenter.TaskRootLease?
        let layers:ToolEnvironmentLease
        let project:LaTeXHostProject
        let cancellation:CancellationToken
    }
    private var owners=[UUID:Owner]()
    private var preparing=Set<UUID>()
    private enum Outcome {case build(LaTeXBuildRecord),prepared([LaTeXEngineCapability])}
    init(composition:LaTeXAppComposition) {self.composition=composition}

    func typeset(_ store:LaTeXProjectStore,revision:Int64,configuration:LaTeXBuildConfiguration) async throws -> LaTeXBuildRecord {
        guard case .build(let record)=try await perform(store,revision:revision,configuration:configuration,action:"start",installProfile:nil) else {throw PersonalContentError.changedDocument}
        return record
    }
    func prepare(_ store:LaTeXProjectStore,revision:Int64,installProfile:String?) async throws -> [LaTeXEngineCapability] {
        guard case .prepared(let values)=try await perform(store,revision:revision,configuration:.init(),action:"prepare",installProfile:installProfile) else {throw PersonalContentError.changedDocument}
        return values
    }
    func cancel(projectID:UUID) {owners[projectID]?.cancellation.cancel()}
    private func perform(_ store:LaTeXProjectStore,revision:Int64,configuration:LaTeXBuildConfiguration,action:String,installProfile:String?) async throws -> Outcome {
        let manifest=try await store.manifest(),id=manifest.id
        guard preparing.insert(id).inserted else {throw LaTeXError.unavailable("This document is preparing typesetting.")}
        defer {preparing.remove(id)}
        guard owners[id]==nil else {throw LaTeXError.unavailable("The previous typesetting worker still needs a confirmed stop. Its source and execution owner have been retained.")}
        let app=try composition.app(),host=try await composition.host(),original=try await composition.original(id)
        guard original.root.standardizedFileURL==store.root.standardizedFileURL,manifest.revision==revision else {throw PersonalContentError.changedDocument}
        let taskID=try await composition.assistantForNativeOriginal(original)
        guard let conversation=try await app.conversationStore.conversation(id:taskID),[.ordinary,.notes].contains(conversation.purpose) else {throw PersonalContentError.changedDocument}
        let runID=UUID(),cancellation=CancellationToken()
        var root:WorkspaceCenter.TaskRootLease?
        var layers:ToolEnvironmentLease?
        var persisted=false
        do {
            let pin:TaskExecutionBinding,workspaceRoot:URL
            if conversation.purpose == .notes {
                workspaceRoot=try NotesRepository.assistantWorkspace(conversationID:taskID)
                pin=try await app.taskExecutionEnvironments.resolveNotesBinding(conversationID:taskID,runID:runID,root:workspaceRoot)
            } else {
                let workspace=try await SQLiteWorkspaceStore(database:app.database).ensureWorkspace(conversationID:taskID,title:manifest.title)
                let acquired=try await app.workspaceCenter.acquireTaskRoot(workspace,conversationID:taskID)
                root=acquired;workspaceRoot=acquired.url
                pin=try await app.taskExecutionEnvironments.resolveBinding(conversationID:taskID,runID:runID,root:workspaceRoot,workspace:workspace)
            }
            try Task.checkCancellation()
            try await app.runStore.saveRun(.init(id:runID,conversationID:taskID,state:"preparing",goal:IDELanguageRunText.t("排版论文","Typeset document"),startedAt:Date(),executionBinding:pin))
            persisted=true
            var stores=composition.typedServiceStorePaths
            stores[TypedMutationContract.nativeStudioLibraryStoreKey]=try PersonalContentLibrary.applicationRoot().path
            let base=ToolContext(runID:runID,scope:pin.target.remoteHostID.map(ToolScope.host) ?? .local,
                workspaceRootURL:workspaceRoot,serviceStorePaths:stores,cancellation:cancellation,
                environmentID:pin.target.environmentID,executionBindingGeneration:pin.generation,
                conversationID:taskID,clientSessionID:"latex.native."+runID.uuidString.lowercased())
            let acquired=try await ToolEnvironmentRouting.shared.acquire(base)
            layers=acquired
            guard acquired.context.environment?.id==pin.target.environmentID else {throw PersonalContentError.changedDocument}
            let access=try await composition.acquire(id,context:acquired.context,editing:true)
            owners[id]=Owner(runID:runID,root:root,layers:acquired,project:access,cancellation:cancellation)
            let output=try await invoke(original:original,revision:revision,configuration:configuration,action:action,installProfile:installProfile,purpose:conversation.purpose,context:acquired.context)
            if action=="prepare" {
                guard !output.outcomeUnknown else {throw LaTeXEngineFailure("Toolchain preparation has an unknown result.",workerStopped:false)}
                let values=try JSONDecoder().decode([LaTeXEngineCapability].self,from:Data(output.summary.utf8))
                try await finish(id,runID:runID,state:"completed");return .prepared(values)
            }
            guard let value=try JSONSerialization.jsonObject(with:Data(output.summary.utf8)) as? [String:Any],
                  let raw=value["id"] as? String,let buildID=UUID(uuidString:raw) else {throw LaTeXEngineFailure("Typesetting returned an unrecognized build receipt.",workerStopped:false)}
            let result=try await host.builds.wait(buildID)
            guard result.workerStopped != false else {
                try await app.runStore.updateRunState(id:runID,state:"waitingRecovery",endedAt:nil)
                return .build(result)
            }
            try await finish(id,runID:runID,state:result.succeeded ? "completed":result.state == .cancelled ? "cancelled":"failed")
            return .build(result)
        } catch {
            let cancelled=error is CancellationError || (error as? LaTeXEngineFailure)?.cancelled==true
            if let failure=error as? LaTeXEngineFailure,!failure.workerStopped {
                // Even a failed preparation command can leave a worker. A
                // missing final receipt cannot release this original/run.
                try? await app.runStore.updateRunState(id:runID,state:"waitingRecovery",endedAt:nil)
                throw error
            }
            if owners[id] != nil {
                // Commit terminal state before revoking authority/releasing
                // leases. A persistence failure leaves a recoverable owner.
                try await finish(id,runID:runID,state:cancelled ? "cancelled":"failed")
            } else {
                if persisted {
                    do {try await app.runStore.updateRunState(id:runID,state:cancelled ? "cancelled":"failed",endedAt:Date())}
                    catch {if let layers {await layers.finish()};root?.release();throw error}
                }
                if let layers {await layers.finish()};root?.release()
            }
            if cancelled {throw CancellationError()}
            throw error
        }
    }
    private func invoke(original:LaTeXOriginal,revision:Int64,configuration:LaTeXBuildConfiguration,action operation:String,installProfile:String?,purpose:ConversationPurpose,context base:ToolContext) async throws -> ToolExecutionOutput {
        let app=try composition.app(),host=try await composition.host(),name="latex.typeset",requestID=UUID().uuidString.lowercased()
        guard let runner=host.registry.runner(named:name),let taskID=base.conversationID else {throw PersonalContentError.storageUnavailable}
        let policy=try await SQLiteWorkspaceStore(database:app.database).taskPolicy(conversationID:taskID)
        var allowed=LaTeXHostTools.names.union(["exec.shell"])
        if let ceiling=policy.allowedToolNames {allowed.formIntersection(ceiling)}
        if purpose == .notes {allowed.formIntersection(NotesAssistantToolCatalog.toolNames)}
        guard allowed.contains(name),allowed.contains("exec.shell") else {throw NativeWorkbenchApprovalError.readOnly}
        struct Arguments:Encodable {let projectID:UUID;let action:String;let expectedRevision:Int64;let offline:Bool;let wait:Bool;let installProfile:String?}
        let data=try LaTeXDigest.encode(Arguments(projectID:original.id,action:operation,expectedRevision:revision,offline:configuration.offline,wait:true,installProfile:installProfile))
        try runner.validateArguments(data)
        var context=base
        context.allowedToolNames=allowed;context.frozenEffectiveCatalogNames=allowed
        context.executionToolName=name;context.toolCallID=requestID
        let call=try ToolCall(id:requestID,toolName:name,argumentsJSON:data,scope:context.scope)
        context.toolIdempotencyKey=call.idempotencyKey
        let digest=RuntimeAuthorityDigest.payloadDigest(data),validationContext=context
        let action=ProposedAction(toolCall:call,riskLabels:Set(runner.descriptor.riskLabels.map(\.rawValue)),userGoal:"Typeset the selected LaTeX original",hostAndPathScope:call.scope)
        let grant=try await app.conversationCenter.recordNativeWorkbenchApproval(action,context:context,descriptor:runner.descriptor,
            projectID:original.id,requestID:requestID,payloadDigest:digest,allowedToolNames:LaTeXHostTools.names,
            requiredPurpose:purpose,validateOriginal:{[composition] in
                let current=try await composition.authorizeOriginal(original.id,context:validationContext,editing:true)
                guard current.owner==original.owner,current.root==original.root,
                      try await LaTeXProjectStore(root:current.root).manifest().revision==revision else {throw PersonalContentError.changedDocument}
            })
        try context.cancellation.throwIfCancelled();try Task.checkCancellation()
        guard host.registry.runner(named:name)?.descriptor.authorizationIdentity==runner.descriptor.authorizationIdentity,
              grant.scope.toolAuthorizationIdentity==runner.descriptor.authorizationIdentity,
              grant.scope.singleUse,grant.scope.toolName==name,grant.expiresAt.map({$0>Date()}) != false else {throw NativeWorkbenchApprovalError.changed}
        context.approvalGrantID=grant.id;context.approvalOrigin = .policy("native-ui")
        let target=RuntimeAuthorityDigest.canonicalTarget(for:call,descriptor:runner.descriptor,workspaceRootURL:context.workspaceRootURL,serviceStorePaths:context.serviceStorePaths)
        let baseRevision=RuntimeAuthorityDigest.baseRevision(in:data)
        let binding=context.runtimeAuthorityBinding(toolName:name,operation:"apply",canonicalTarget:target,baseRevision:baseRevision,payloadDigest:digest)
        context.runtimeAuthority=await RuntimeAuthorityStore.shared.issue(.init(runID:context.runID,taskID:taskID,
            environmentBinding:binding.environmentBinding,canonicalTarget:target,toolName:name,operation:"apply",operationID:requestID,
            idempotencyKey:call.idempotencyKey,baseRevision:baseRevision,payloadDigest:digest,approvalGrantID:grant.id),ttl:installProfile==nil ? 900:3600)
        try context.cancellation.throwIfCancelled();try Task.checkCancellation()
        return try await runner.run(data,context)
    }
    private func finish(_ id:UUID,runID:UUID,state:String) async throws {
        guard let owner=owners[id],owner.runID==runID else {throw PersonalContentError.changedDocument}
        let app=try composition.app()
        try await app.runStore.updateRunState(id:runID,state:state,endedAt:Date())
        owners.removeValue(forKey:id)
        owner.cancellation.cancel();_ = await RuntimeAuthorityStore.shared.revoke(runID:runID)
        await owner.layers.finish();owner.root?.release()
    }
}
#endif
