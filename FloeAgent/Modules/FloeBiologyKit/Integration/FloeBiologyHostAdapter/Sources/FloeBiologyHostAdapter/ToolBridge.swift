// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeModels
import FloeTools
import FloeBiologyCore
import FloeBiologyEngine

public struct BiologyTaskGrant:Sendable {
    public let projects:Set<UUID>
    public let canCreate:Bool
    public let readOnly:Bool
    public init(projects:Set<UUID>,canCreate:Bool=false,readOnly:Bool=false) {self.projects=projects;self.canCreate=canCreate;self.readOnly=readOnly}
}
public actor BiologyExecutionContexts {
    struct Entry:Sendable {let context:ToolContext;let binding:RuntimeAuthorityBinding?}
    private var calls:[String:Entry]=[:]
    private var runs:[UUID:Entry]=[:]
    private var native:[BiologyExecutionOwner:Entry]=[:]
    private func key(_ owner:BiologyExecutionOwner,_ call:String)->String {owner.taskID.uuidString+":"+owner.hostRunID.uuidString+":"+call}
    func remember(_ context:ToolContext,binding:RuntimeAuthorityBinding?) throws {
        guard let task=context.conversationID,let call=context.toolCallID,!call.isEmpty else {throw BiologyError.unavailable("Biology execution requires the real task, run and provider call identity.")}
        guard calls.count<256 else {throw BiologyError.unavailable("Too many pending biology calls.")}
        calls[key(.init(taskID:task,hostRunID:context.runID),call)]=Entry(context:context,binding:binding)
    }
    public func bind(runID:UUID,owner:BiologyExecutionOwner?,requestID:String?) throws {
        guard let owner else {throw BiologyError.unavailable("This calculation has no task owner.")}
        let resolved:Entry?
        if let requestID {resolved=calls[key(owner,requestID)]}else{resolved=native.removeValue(forKey:owner)}
        guard let entry=resolved,!entry.context.cancellation.isCancelled else {throw BiologyError.unavailable("This calculation has no live host execution context.")}
        guard runs.count<128 else {throw BiologyError.unavailable("Too many scientific workers.")};runs[runID]=entry
    }
    /// Used by the native workbench's executionOwner callback after the App
    /// creates/resolves its ordinary durable task. This consumes one native
    /// launch binding; a model cannot construct a ToolContext through JSON.
    public func authorizeNative(_ context:ToolContext,binding:RuntimeAuthorityBinding?=nil) throws -> BiologyExecutionOwner {
        guard let task=context.conversationID,!context.temporaryReadOnly,!context.publicWebOnly,!context.cancellation.isCancelled,context.environmentID==context.environment?.id else {throw BiologyError.unavailable("A live resolved task is required for this workbench operation.")}
        guard native.count<128 else {throw BiologyError.unavailable("Too many pending native calculations.")}
        let owner=BiologyExecutionOwner(taskID:task,hostRunID:context.runID);native[owner]=Entry(context:context,binding:binding);return owner
    }
    func entry(_ runID:UUID) throws -> Entry {guard let value=runs[runID] else {throw BiologyError.unavailable("Scientific execution context expired.")};return value}
    func forget(_ runID:UUID) {runs.removeValue(forKey:runID)}
    func forgetCall(_ context:ToolContext) {if let task=context.conversationID,let call=context.toolCallID{calls.removeValue(forKey:key(.init(taskID:task,hostRunID:context.runID),call))}}
}

/// Real Floe registry integration. The two host callbacks only resolve existing
/// task/project authority and record newly created project ownership; they do
/// not execute tools, choose environments or supply scientific results.
public final class BiologyToolBridge:Sendable {
    public let service:BiologyService
    public let contexts:BiologyExecutionContexts
    private let grant:@Sendable (ToolContext) async throws -> BiologyTaskGrant
    private let created:@Sendable (UUID,ToolContext) async throws -> Void
    private let scientificJobs:BiologyScientificJobs?
    public init(service:BiologyService,contexts:BiologyExecutionContexts,scientificJobs:BiologyScientificJobs?=nil,grant:@escaping @Sendable (ToolContext) async throws -> BiologyTaskGrant,registerCreatedProject:@escaping @Sendable (UUID,ToolContext) async throws -> Void) {self.service=service;self.contexts=contexts;self.scientificJobs=scientificJobs;self.grant=grant;self.created=registerCreatedProject}
    public func descriptors(for context:ToolContext) async throws -> [ToolCatalog.Descriptor] {
        guard !context.temporaryReadOnly,!context.publicWebOnly,let taskID=context.conversationID else {return []}
        let g=try await grant(context),session=BiologyToolSession(service:service,authorizedProjectIDs:g.projects,owner:.init(taskID:taskID,hostRunID:context.runID),canCreate:g.canCreate,readOnly:g.readOnly)
        return try await session.descriptors().filter{context.allowedToolNames?.contains($0.name) != false}.map(Self.descriptor)
    }
    public func register(in registry:ToolRunnerRegistry = .shared) async throws {
        // Register the complete executable family once. Each actual dispatch
        // refreshes host scope; composition uses descriptors(for:) above.
        let template=BiologyToolSession(service:service,authorizedProjectIDs:[],owner:.init(taskID:UUID(),hostRunID:UUID()),canCreate:true)
        for item in await template.descriptors() {
            let descriptor=try Self.descriptor(item)
            registry.register(AnyAgentTool(descriptor:descriptor,run:{[self] data,context in try await execute(item,data:data,context:context)},validateArguments:{data in
                guard data.count<=65536 else {throw BiologyError.invalid("Use an opaque authorized fileID for a large import.")}
                try BiologyToolSchemas.validate(JSONDecoder().decode(JSONValue.self,from:data),against:item.parameters)
            }))
        }
    }
    private static func descriptor(_ item:BiologyToolDescriptor) throws -> ToolCatalog.Descriptor {
        var risks:Set<RiskLabel>=[.readsFiles]
        if !item.isReadOnly {risks.insert(.writesFiles)}
        if ["biology.deleteProject","biology.update"].contains(item.name){risks.insert(.deletesFiles)}
        if item.name=="biology.analyze" {risks.insert(.executesLocalCode)}
        return .init(name:item.name,toolDescription:item.description,parametersJSON:String(decoding:try BiologyCoding.encode(item.parameters),as:UTF8.self),riskLabels:risks,isSideEffecting:!item.isReadOnly,effect:item.isReadOnly ? .readOnly:.mutating)
    }
    private func execute(_ item:BiologyToolDescriptor,data:Data,context:ToolContext) async throws -> ToolExecutionOutput {
        guard !context.temporaryReadOnly,!context.publicWebOnly,context.allowedToolNames?.contains(item.name) != false,context.frozenEffectiveCatalogNames?.contains(item.name) != false,let taskID=context.conversationID,let callID=context.toolCallID else {throw BiologyError.unavailable("Biology tools are outside this task's capability ceiling.")}
        try context.cancellation.throwIfCancelled();try Task.checkCancellation()
        let g=try await grant(context)
        guard !g.readOnly || item.isReadOnly else {throw BiologyError.unavailable("This task currently permits reads only.")}
        let value=try JSONDecoder().decode(JSONValue.self,from:data)
        try BiologyToolSchemas.validate(value,against:item.parameters)
        let session=BiologyToolSession(service:service,authorizedProjectIDs:g.projects,owner:.init(taskID:taskID,hostRunID:context.runID),canCreate:g.canCreate,readOnly:g.readOnly,isCancelled:{context.cancellation.isCancelled})
        var binding:RuntimeAuthorityBinding?
        if context.runtimeAuthority != nil {
            var call=try ToolCall(id:callID,toolName:item.name,argumentsJSON:data,scope:context.scope);call.idempotencyKey=context.toolIdempotencyKey
            binding=context.runtimeAuthorityBinding(toolName:item.name,operation:"apply",canonicalTarget:RuntimeAuthorityDigest.canonicalTarget(for:call,descriptor:try Self.descriptor(item),workspaceRootURL:context.workspaceRootURL,stagedDocument:context.canvasStagedDocument,serviceStorePaths:context.serviceStorePaths),baseRevision:RuntimeAuthorityDigest.baseRevision(in:data),payloadDigest:RuntimeAuthorityDigest.payloadDigest(data))
            let verdict=await RuntimeAuthorityStore.shared.validate(context.runtimeAuthority!,binding:binding!)
            guard verdict.isValid else {throw BiologyError.unavailable("This operation no longer matches the runtime approval.")}
        }
        try await contexts.remember(context,binding:binding)
        do {
            if item.name=="biology.analyze",let environment=value["environmentID"]?.string,environment != "native.local",let scientificJobs {
                guard environment==context.environmentID,let project=value["projectID"]?.string.flatMap(UUID.init(uuidString:)),g.projects.contains(project) else {throw BiologyError.unavailable("Scientific analysis must use this task's project and resolved environment.")}
                let identity=BiologyMutationIdentity(owner:.init(taskID:taskID,hostRunID:context.runID),requestID:callID,argumentDigest:BiologyProjectStore.digest(try BiologyCoding.encode(JSONValue.object(["tool":.string(item.name),"arguments":value]))))
                if try await service.store.receipt(project,identity:identity)==nil {
                    let qualified=try await scientificJobs.probe(context:context)
                    guard let method=value["method"]?.string,qualified.methods.contains(method) else {throw BiologyError.unavailable("This environment cannot run the requested scientific method. Inspect biology.describe for the pinned dependencies and install them through the existing exec.shell workflow. Engine diagnostics: "+String(decoding:try BiologyCoding.encode(qualified.unavailable),as:UTF8.self))}
                    let backend=try await scientificJobs.backend(qualified:qualified)
                    try await service.configureBackend(backend)
                }
            }
            var result=try await session.invoke(name:item.name,arguments:value,requestID:callID)
            if item.name=="biology.methods",scientificJobs != nil,let environment=context.environmentID,var object=result.object {
                object["selectedScientificEnvironmentID"] = .string(environment)
                object["setup"] = .string("biology.describe provides the optional scientific method schemas and pinned dependency requirements. Scientific analysis probes actual installed engines in this environment.");result = .object(object)
            }
            if ["biology.create","biology.importProject"].contains(item.name),let id=result["id"]?.string.flatMap(UUID.init(uuidString:)) {try await created(id,context)}
            await contexts.forgetCall(context)
            let text=String(decoding:try BiologyCoding.encode(result),as:UTF8.self)
            return ToolExecutionOutput(digesting:text,exitStatus:0,capturedOutput:text)
        } catch {await contexts.forgetCall(context);throw error}
    }
}
