// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Observation
import FloeCore
import FloeModels
import FloePersistence
import FloeSecurity
import FloeTools
import FloeExecution
import FloeLaTeXCore
import FloeLaTeXEngine
import FloeLaTeXHostAdapter

/// Constructed only by the compiled native LaTeX controller, never decoded
/// from a tool argument or an imported document.
struct LaTeXNativeUIIntent:Sendable {
    let runID:UUID;let conversationID:UUID;let projectID:UUID;let owner:LaTeXOwner
    let revision:Int64;let requestID:String;let operation:String
}

/// Persisted provenance for an App-owned native operation with no command
/// environment. It supplements, rather than replaces, the real original/CAS
/// and single-use runtime-authority checks.
struct LaTeXAppleNativeRunProof:Codable,Sendable {
    let activity:String;let version:Int;let backend:String;let targetTool:String
    let runID:UUID;let conversationID:UUID;let projectID:UUID;let owner:LaTeXOwner
    let revision:Int64;let operation:String
    init(runID:UUID,conversationID:UUID,projectID:UUID,owner:LaTeXOwner,revision:Int64,operation:String) {
        activity="latexNativeService";version=2;backend="nativeApple";targetTool="latex.typeset"
        self.runID=runID;self.conversationID=conversationID;self.projectID=projectID;self.owner=owner
        self.revision=revision;self.operation=operation
    }
    static func read(_ events:[RunEventRecord],runID:UUID,taskID:UUID)->Self? {
        let values=events.filter{$0.kind == .status && $0.runID==runID}.compactMap {
            try? JSONDecoder().decode(Self.self,from:Data($0.payloadJSON.utf8))
        }.filter{$0.activity=="latexNativeService" && $0.version==2 && $0.backend=="nativeApple"
            && $0.targetTool=="latex.typeset" && $0.runID==runID && $0.conversationID==taskID
            && ["start","prepare"].contains($0.operation)}
        return values.count==1 ? values[0]:nil
    }
}

/// A native Typeset event owns a saved run and real execution leases. The
/// editor may disappear while this service finishes the same original.
@MainActor @Observable final class LaTeXNativeRuntime {
    struct Operation:Equatable {
        enum Kind:Equatable {case preparation,typesetting}
        let kind:Kind
        var cancelling=false
        var waitingRecovery=false
        var preparationProgress:LaTeXPreparationProgress?
    }
    struct Failure:Equatable {let id:UUID;let message:String;let occurredAt=Date()}
    private(set) var operations=[UUID:Operation]()
    private(set) var failures=[UUID:Failure]()
    private unowned let composition:LaTeXAppComposition
    private struct Owner {
        let runID:UUID
        let root:WorkspaceCenter.TaskRootLease?
        let project:LaTeXHostProject
        let cancellation:CancellationToken
    }
    @ObservationIgnored private var owners=[UUID:Owner]()
    @ObservationIgnored private var preparing=[UUID:CancellationToken]()
    private enum Outcome:Sendable {case build(LaTeXBuildRecord),prepared([LaTeXEngineCapability])}
    @ObservationIgnored private var operationTasks=[UUID:Task<Outcome,Error>]()
    init(composition:LaTeXAppComposition) {self.composition=composition}

    func typeset(_ store:LaTeXProjectStore,revision:Int64,configuration:LaTeXBuildConfiguration) async throws -> LaTeXBuildRecord {
        guard case .build(let record)=try await perform(store,revision:revision,configuration:configuration,action:"start",installProfile:nil) else {throw PersonalContentError.changedDocument}
        return record
    }
    func prepare(_ store:LaTeXProjectStore,revision:Int64,installProfile:String?=nil) async throws -> [LaTeXEngineCapability] {
        guard installProfile==nil else {throw LaTeXError.invalidOperation("Prepare this project's dependencies without an installation profile.")}
        guard case .prepared(let values)=try await perform(store,revision:revision,configuration:.init(),action:"prepare",installProfile:nil) else {throw PersonalContentError.changedDocument}
        return values
    }
    func updatePreparationProgress(projectID:UUID,context:ToolContext,progress:LaTeXPreparationProgress) {
        guard let owner=owners[projectID],owner.runID==context.runID,!owner.cancellation.isCancelled,
              var operation=operations[projectID],!operation.cancelling,!operation.waitingRecovery,
              progress.sequence>(operation.preparationProgress?.sequence ?? 0) else {return}
        operation.preparationProgress=progress;operations[projectID]=operation
    }
    func cancel(projectID:UUID) {
        preparing[projectID]?.cancel();owners[projectID]?.cancellation.cancel()
        if var operation=operations[projectID] {operation.cancelling=true;operations[projectID]=operation}
    }
    private func perform(_ store:LaTeXProjectStore,revision:Int64,configuration:LaTeXBuildConfiguration,action:String,installProfile:String?) async throws -> Outcome {
        // The native service owns cancellation, processor drain and SQLite
        // settlement. Cancelling an editor waiter requests that work through
        // the token; it must not cancel the service's GRDB reads/writes.
        let requestID=UUID(),cancellation=CancellationToken()
        let task=Task { @MainActor in
            try await self.performOwned(store,revision:revision,configuration:configuration,action:action,installProfile:installProfile,cancellation:cancellation)
        }
        operationTasks[requestID]=task
        defer {operationTasks.removeValue(forKey:requestID)}
        return try await withTaskCancellationHandler(operation:{try await task.value},onCancel:{cancellation.cancel()})
    }
    private func performOwned(_ store:LaTeXProjectStore,revision:Int64,configuration:LaTeXBuildConfiguration,action:String,installProfile:String?,cancellation:CancellationToken) async throws -> Outcome {
        let manifest=try await store.manifest(),id=manifest.id
        try cancellation.throwIfCancelled()
        guard preparing[id]==nil else {throw LaTeXError.unavailable("This document is preparing typesetting.")}
        guard owners[id]==nil else {throw LaTeXError.unavailable("The previous typesetting worker still needs a confirmed stop. Its source and execution owner have been retained.")}
        failures.removeValue(forKey:id)
        preparing[id]=cancellation
        operations[id]=Operation(kind:action=="prepare" ? .preparation:.typesetting)
        defer {
            preparing.removeValue(forKey:id)
            if owners[id]==nil {operations.removeValue(forKey:id)}
            else {operations[id]?.waitingRecovery=true}
            let finished=failures.filter {owners[$0.key]==nil && $0.key != id}
            if finished.count>128 {
                for item in finished.sorted(by:{$0.value.occurredAt<$1.value.occurredAt}).prefix(finished.count-128) {failures.removeValue(forKey:item.key)}
            }
        }
        let app=try composition.app(),host=try await composition.host(),original=try await composition.original(id)
        guard original.root.standardizedFileURL==store.root.standardizedFileURL,manifest.revision==revision else {throw PersonalContentError.changedDocument}
        let taskID=try await composition.assistantForNativeOriginal(original)
        guard let conversation=try await app.conversationStore.conversation(id:taskID),[.ordinary,.notes].contains(conversation.purpose) else {throw PersonalContentError.changedDocument}
        let runID=UUID()
        var root:WorkspaceCenter.TaskRootLease?
        var persisted=false
        do {
            let workspaceRoot:URL
            if conversation.purpose == .notes {
                workspaceRoot=try NotesRepository.assistantWorkspace(conversationID:taskID)
            } else {
                let workspace=try await SQLiteWorkspaceStore(database:app.database).ensureWorkspace(conversationID:taskID,title:manifest.title)
                let acquired=try await app.workspaceCenter.acquireTaskRoot(workspace,conversationID:taskID)
                root=acquired;workspaceRoot=acquired.url
            }
            try cancellation.throwIfCancelled();try Task.checkCancellation()
            try await app.runStore.saveRun(.init(id:runID,conversationID:taskID,state:"preparing",goal:IDELanguageRunText.t("排版论文","Typeset document"),startedAt:Date(),executionBinding:nil))
            persisted=true
            _ = try await app.runStore.appendEvent(runID:runID,kind:.status,
                payloadJSON:String(decoding:try JSONEncoder().encode(LaTeXAppleNativeRunProof(runID:runID,
                    conversationID:taskID,projectID:id,owner:original.owner,revision:revision,operation:action)),as:UTF8.self))
            var stores=composition.typedServiceStorePaths
            stores[TypedMutationContract.nativeStudioLibraryStoreKey]=try PersonalContentLibrary.applicationRoot().path
            var base=ToolContext(runID:runID,scope:.local,
                workspaceRootURL:workspaceRoot,serviceStorePaths:stores,cancellation:cancellation,
                conversationID:taskID,clientSessionID:"latex.native."+runID.uuidString.lowercased())
            base.executionToolName="latex.typeset"
            // Native document work acquires only the original's usage lease.
            // It never resolves/boots a Linux target or acquires shell layers.
            let access=try await composition.acquire(id,context:base,editing:true)
            owners[id]=Owner(runID:runID,root:root,project:access,cancellation:cancellation)
            let output=try await invoke(original:original,revision:revision,configuration:configuration,action:action,installProfile:installProfile,purpose:conversation.purpose,context:base)
            if action=="prepare" {
                if output.outcomeUnknown {
                    struct Unknown:Decodable {let message:String;let messages:[String]}
                    let unknown=try? JSONDecoder().decode(Unknown.self,from:Data(output.summary.utf8))
                    throw LaTeXEngineFailure(unknown?.message ?? "Toolchain preparation has an unknown result.",messages:unknown?.messages ?? [],workerStopped:false)
                }
                let values=try JSONDecoder().decode([LaTeXEngineCapability].self,from:Data(output.summary.utf8))
                try await finish(id,runID:runID,state:"completed");return .prepared(values)
            }
            guard let value=try JSONSerialization.jsonObject(with:Data(output.summary.utf8)) as? [String:Any],
                  let raw=value["id"] as? String,let buildID=UUID(uuidString:raw) else {throw LaTeXEngineFailure("Typesetting returned an unrecognized build receipt.",workerStopped:false)}
            let result=try await host.builds.wait(buildID)
            guard result.workerStopped != false else {
                operations[id]?.waitingRecovery=true
                try await app.runStore.updateRunState(id:runID,state:"waitingRecovery",endedAt:nil)
                return .build(result)
            }
            try await finish(id,runID:runID,state:result.succeeded ? "completed":result.state == .cancelled ? "cancelled":"failed")
            return .build(result)
        } catch {
            let cancelled=cancellation.isCancelled || Task.isCancelled || error is CancellationError || (error as? LaTeXEngineFailure)?.cancelled==true
            if !cancelled {
                let message=String(error.localizedDescription.prefix(2000))
                failures[id]=Failure(id:runID,message:message)
                if persisted {
                    do {
                        let payload=try JSONSerialization.data(withJSONObject:["source":"latex.native","projectID":id.uuidString,"operation":action,"message":message])
                        _ = try await app.runStore.appendEvent(runID:runID,kind:.error,payloadJSON:String(decoding:payload,as:UTF8.self))
                    } catch {FloeLogger(category:.persistence).warning("latexNativeFailureEvidenceFailed")}
                }
            }
            if let failure=error as? LaTeXEngineFailure,!failure.workerStopped {
                // Even a failed preparation command can leave a worker. A
                // missing final receipt cannot release this original/run.
                operations[id]?.waitingRecovery=true
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
                    catch {root?.release();throw error}
                }
                root?.release()
            }
            if cancelled {throw CancellationError()}
            throw error
        }
    }
    private func invoke(original:LaTeXOriginal,revision:Int64,configuration:LaTeXBuildConfiguration,action operation:String,installProfile:String?,purpose:ConversationPurpose,context base:ToolContext) async throws -> ToolExecutionOutput {
        let app=try composition.app(),host=try await composition.host(),name="latex.typeset",requestID=UUID().uuidString.lowercased()
        guard let runner=host.registry.runner(named:name),let taskID=base.conversationID else {throw PersonalContentError.storageUnavailable}
        let policy=try await SQLiteWorkspaceStore(database:app.database).taskPolicy(conversationID:taskID)
        var allowed=LaTeXHostTools.names
        if let ceiling=policy.allowedToolNames {allowed.formIntersection(ceiling)}
        if purpose == .notes {allowed.formIntersection(NotesAssistantToolCatalog.toolNames)}
        guard allowed.contains(name) else {throw NativeWorkbenchApprovalError.readOnly}
        struct Arguments:Encodable {let projectID:UUID;let action:String;let expectedRevision:Int64;let offline:Bool;let wait:Bool;let timeoutSeconds:Int}
        guard installProfile==nil else {throw LaTeXError.invalidOperation("Prepare this project's dependencies without an installation profile.")}
        let data=try LaTeXDigest.encode(Arguments(projectID:original.id,action:operation,expectedRevision:revision,offline:configuration.offline,wait:true,timeoutSeconds:configuration.timeoutSeconds))
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
            requiredPurpose:purpose,
            nativeLaTeXIntent:.init(runID:context.runID,conversationID:taskID,projectID:original.id,
                owner:original.owner,revision:revision,requestID:requestID,operation:operation),validateOriginal:{[composition] in
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
            idempotencyKey:call.idempotencyKey,baseRevision:baseRevision,payloadDigest:digest,approvalGrantID:grant.id),ttl:3600)
        try context.cancellation.throwIfCancelled();try Task.checkCancellation()
        return try await runner.run(data,context)
    }
    private func finish(_ id:UUID,runID:UUID,state:String) async throws {
        guard let owner=owners[id],owner.runID==runID else {throw PersonalContentError.changedDocument}
        let app=try composition.app()
        try await app.runStore.updateRunState(id:runID,state:state,endedAt:Date())
        owners.removeValue(forKey:id)
        owner.cancellation.cancel();_ = await RuntimeAuthorityStore.shared.revoke(runID:runID)
        owner.root?.release()
    }
}
#endif
