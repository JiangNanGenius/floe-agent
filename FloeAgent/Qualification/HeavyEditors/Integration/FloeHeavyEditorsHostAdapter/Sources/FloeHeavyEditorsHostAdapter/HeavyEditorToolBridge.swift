// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeModels
import FloeTools
import FloeHeavyEditorSupport

public struct HeavyEditorTaskGrant: Sendable {
    public let enabledKinds: Set<HeavyEditorKind>
    public let projects: Set<UUID>
    public let canCreate: Bool
    public let readOnly: Bool
    public init(enabledKinds: Set<HeavyEditorKind>, projects: Set<UUID>, canCreate: Bool, readOnly: Bool = false) {
        self.enabledKinds=enabledKinds;self.projects=projects;self.canCreate=canCreate;self.readOnly=readOnly
    }
}
public struct HeavyEditorCreationRequest: Sendable {
    public let kind: HeavyEditorKind
    public let title: String
    public let requestID: String
}
/// Callbacks resolve existing host file/project services under the exact live
/// ToolContext. They never trust a model's owner, environment, URL or directory.
public final class HeavyEditorToolBridge: Sendable {
    private let grant: @Sendable (ToolContext) async throws -> HeavyEditorTaskGrant
    private let open: @Sendable (UUID, ToolContext) async throws -> HeavyEditorModelLease
    private let create: @Sendable (HeavyEditorCreationRequest, ToolContext) async throws -> UUID
    private let source: @Sendable (String, ToolContext) async throws -> HeavyEditorArtifact
    public init(grant: @escaping @Sendable (ToolContext) async throws -> HeavyEditorTaskGrant,
                open: @escaping @Sendable (UUID, ToolContext) async throws -> HeavyEditorModelLease,
                create: @escaping @Sendable (HeavyEditorCreationRequest, ToolContext) async throws -> UUID,
                resolveFile: @escaping @Sendable (String, ToolContext) async throws -> HeavyEditorArtifact) {
        self.grant=grant;self.open=open;self.create=create;self.source=resolveFile
    }
    private static let operations=["create","describe","query","invoke","import","export"]
    public func descriptors(for context: ToolContext) async throws -> [ToolCatalog.Descriptor] {
        guard !context.temporaryReadOnly,!context.publicWebOnly,context.conversationID != nil else{return []}
        let grant=try await grant(context)
        return try grant.enabledKinds.sorted{$0.rawValue<$1.rawValue}.flatMap {kind in
            try Self.operations.filter{operation in (!grant.readOnly || ["describe","query"].contains(operation)) && (operation != "create" || grant.canCreate)}.map {try Self.descriptor(kind,operation:$0)}
        }.filter{context.allowedToolNames?.contains($0.name) != false}
    }
    public func register(in registry: ToolRunnerRegistry = .shared) throws {
        for kind in HeavyEditorKind.allCases {for operation in Self.operations {
            let descriptor=try Self.descriptor(kind,operation:operation)
            registry.register(AnyAgentTool(descriptor:descriptor,run:{[self] data,context in
                try await execute(kind,operation:operation,data:data,context:context)
            },validateArguments:{data in _=try Self.arguments(data,operation:operation)}))
        }}
    }
    private struct Arguments: Decodable {
        var projectID: UUID?
        var baseRevision: UInt64?
        var title: String?
        var command: String?
        var arguments: EditorJSON?
        var fileID: String?
    }
    private static func arguments(_ data: Data, operation: String) throws -> Arguments {
        guard data.count<=1_048_576,case .object(let object)=try EditorJSON.decode(data) else{throw HeavyEditorError.invalidDocument}
        let keys: Set<String>=operation=="create" ? ["title"] : operation=="describe" ? ["projectID"] : operation=="import" ? ["projectID","baseRevision","fileID"] : ["projectID","baseRevision","command","arguments"]
        guard Set(object.keys).isSubset(of:keys) else{throw HeavyEditorError.invalidCommand}
        let args=try JSONDecoder().decode(Arguments.self,from:data)
        if operation=="create" {guard let title=args.title,!title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,title.count<=200 else{throw HeavyEditorError.invalidDocument}}
        else {guard args.projectID != nil else{throw HeavyEditorError.invalidDocument}}
        if ["query","invoke","import","export"].contains(operation){guard args.baseRevision != nil else{throw HeavyEditorError.revisionConflict}}
        if ["query","invoke","export"].contains(operation){guard let command=args.command,!command.isEmpty else{throw HeavyEditorError.invalidCommand}}
        if operation=="import"{guard let file=args.fileID,!file.isEmpty else{throw HeavyEditorError.invalidDocument}}
        return args
    }
    private static func descriptor(_ kind: HeavyEditorKind, operation: String) throws -> ToolCatalog.Descriptor {
        let string: EditorJSON = .object(["type":.string("string")])
        let project: EditorJSON = .object(["type":.string("string"),"format":.string("uuid")])
        let revision: EditorJSON = .object(["type":.string("integer"),"minimum":.number(0)])
        var properties: [String:EditorJSON]=[:],required:[String]=[]
        if operation=="create"{properties=["title":string];required=["title"]}
        else{properties=["projectID":project];required=["projectID"]}
        if ["query","invoke","import","export"].contains(operation){properties["baseRevision"]=revision;required.append("baseRevision")}
        if ["query","invoke","export"].contains(operation){properties["command"]=string;properties["arguments"] = .object(["type":.string("object")]);required.append("command")}
        if operation=="import"{properties["fileID"]=string;required.append("fileID")}
        let schema: EditorJSON = .object(["type":.string("object"),"properties":.object(properties),"required":.array(required.map(EditorJSON.string)),"additionalProperties":.bool(false)])
        let descriptions=["create":"Create a durable \(kind.rawValue) project under this task using existing workspace ownership.","describe":"Inspect this authorized \(kind.rawValue) project, revision, selection and executable command schemas.","invoke":"Run an editing, query or analysis command returned by \(kind.rawValue).describe against the same original and expected revision.","import":"Import an authorized fileID into this \(kind.rawValue) project. No host path or model-supplied ownership is accepted.","export":"Run an export command returned by \(kind.rawValue).describe; return managed output file IDs and hashes."]
        let readOnly=["describe","query"].contains(operation)
        let toolDescription=operation=="query" ? "Run a read-only query returned by \(kind.rawValue).describe against the exact authorized original and revision.":descriptions[operation]!
        return .init(name:kind.rawValue+"."+operation,toolDescription:toolDescription,parametersJSON:try schema.text(),riskLabels:readOnly ? [.readsFiles]:[.readsFiles,.writesFiles],isSideEffecting:!readOnly,effect:readOnly ? .readOnly:.mutating,executionBoundary:.mainRunOnly)
    }
    private func execute(_ kind: HeavyEditorKind, operation: String, data: Data, context: ToolContext) async throws -> ToolExecutionOutput {
        let name=kind.rawValue+"."+operation
        guard !context.temporaryReadOnly,!context.publicWebOnly,context.conversationID != nil,let callID=context.toolCallID,
              context.allowedToolNames?.contains(name) != false,context.frozenEffectiveCatalogNames?.contains(name) != false else{throw HeavyEditorError.invalidCommand}
        try context.cancellation.throwIfCancelled();try Task.checkCancellation()
        let args=try Self.arguments(data,operation:operation),grant=try await grant(context)
        guard grant.enabledKinds.contains(kind),!grant.readOnly || ["describe","query"].contains(operation) else{throw HeavyEditorError.invalidCommand}
        if let authority=context.runtimeAuthority {
            var call=try ToolCall(id:callID,toolName:name,argumentsJSON:data,scope:context.scope);call.idempotencyKey=context.toolIdempotencyKey
            let descriptor=try Self.descriptor(kind,operation:operation)
            let binding=context.runtimeAuthorityBinding(toolName:name,operation:"apply",canonicalTarget:RuntimeAuthorityDigest.canonicalTarget(for:call,descriptor:descriptor,workspaceRootURL:context.workspaceRootURL,stagedDocument:context.canvasStagedDocument,serviceStorePaths:context.serviceStorePaths),baseRevision:RuntimeAuthorityDigest.baseRevision(in:data),payloadDigest:RuntimeAuthorityDigest.payloadDigest(data))
            guard await RuntimeAuthorityStore.shared.validate(authority,binding:binding).isValid else{throw HeavyEditorError.invalidCommand}
        }
        let result: EditorJSON
        if operation=="create"{
            guard grant.canCreate else{throw HeavyEditorError.invalidCommand}
            let request=HeavyEditorCreationRequest(kind:kind,title:args.title!,requestID:(context.toolIdempotencyKey ?? callID))
            let id=try await create(request,context)
            let refreshed=try await self.grant(context)
            guard refreshed.projects.contains(id) else{throw HeavyEditorError.wrongDocument}
            let lease=try await open(id,context)
            result=try await HeavyEditorModelCalls.execute(.describe,kind:kind,request:.init(projectID:id),lease:lease)
        }else{
            guard let id=args.projectID,grant.projects.contains(id) else{throw HeavyEditorError.wrongDocument}
            if operation=="import"{
                let artifact=try await source(args.fileID!,context),lease=try await open(id,context)
                do{result=try await Self.importFile(kind:kind,id:id,revision:args.baseRevision!,artifact:artifact,lease:lease);await lease.release()}
                catch{await lease.release();throw error}
            }else{
                let lease=try await open(id,context)
                result=try await HeavyEditorModelCalls.execute(operation=="describe" ? .describe:operation=="query" ? .query:operation=="export" ? .export:.invoke,kind:kind,request:.init(projectID:id,baseRevision:args.baseRevision,command:args.command,arguments:args.arguments),lease:lease)
            }
        }
        let text=try result.text();return ToolExecutionOutput(digesting:text,exitStatus:0,capturedOutput:text)
    }
    @MainActor private static func importFile(kind: HeavyEditorKind,id: UUID,revision: UInt64,artifact: HeavyEditorArtifact,lease: HeavyEditorModelLease) async throws -> EditorJSON {
        guard lease.controller.document.id==id,lease.controller.descriptor.kind==kind else{throw HeavyEditorError.wrongDocument}
        try await lease.controller.waitUntilReady()
        try await lease.controller.importFile(name:artifact.name,data:artifact.data,expectedRevision:revision)
        return try await lease.controller.describe()
    }
}
