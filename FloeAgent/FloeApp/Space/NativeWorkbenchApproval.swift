// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeSecurity
import FloeTools
import FloeLaTeXCore

enum NativeWorkbenchApprovalError: Error {
    case changed, readOnly
}

@MainActor private enum NativeWorkbenchApprovalFlight {
    static var calls: Set<String> = []
}

extension ConversationCenter {
    /// Only a compiled native controller supplies the family and original
    /// validator. Model calls retain the AgentRuntime approval path.
    /// Runtime token issuance remains with the existing authority service.
    func recordNativeWorkbenchApproval(_ action: ProposedAction, context: ToolContext,
        descriptor: ToolCatalog.Descriptor, projectID: UUID, requestID: String,
        payloadDigest: String, allowedToolNames: Set<String>,
        requiredPurpose: ConversationPurpose = .ordinary,
        nativeLaTeXIntent: LaTeXNativeUIIntent? = nil,
        validateOriginal: @MainActor @Sendable () async throws -> Void) async throws -> ApprovalGrant {
        let call = action.toolCall
        // Same-task parity for canonical children (independent hunk — the
        // card-relay owner may defer it without affecting the others): this
        // validator binds the approved action to THIS executing call by id,
        // descriptor identity, payload digest, runner authorizationIdentity
        // and the run↔conversation proof below, all runtime-issued by the
        // parent for child dispatch too. A model cannot mint this context.
        try Task.checkCancellation(); try context.cancellation.throwIfCancelled()
        guard !context.temporaryReadOnly, !context.publicWebOnly,
              let taskID = context.conversationID, context.toolCallID == call.id,
              call.id == requestID, descriptor.name == call.toolName,
              allowedToolNames.contains(call.toolName),
              context.allowedToolNames?.contains(call.toolName) == true,
              RuntimeAuthorityDigest.payloadDigest(call.argumentsJSON) == payloadDigest,
              let runner = ToolRunnerRegistry.shared.runner(named: call.toolName),
              runner.descriptor.authorizationIdentity == descriptor.authorizationIdentity,
              action.riskLabels == Set(descriptor.riskLabels.map(\.rawValue)),
              let run = try await environment.runStore.run(id: context.runID),
              run.conversationID == taskID, run.endedAt == nil,
              let task = try await environment.conversationStore.conversation(id: taskID),
              task.purpose == requiredPurpose else { throw NativeWorkbenchApprovalError.changed }
        let pin=run.executionBinding
        if let intent=nativeLaTeXIntent {
            guard call.toolName=="latex.typeset",context.executionToolName=="latex.typeset",
                  intent.runID==context.runID,intent.conversationID==taskID,intent.projectID==projectID,
                  intent.requestID==requestID,["start","prepare"].contains(intent.operation),
                  run.state=="preparing",pin==nil,context.scope == .local,call.scope == .local,
                  context.environmentID==nil,context.environment==nil,context.executionBindingGeneration==nil,
                  context.clientSessionID=="latex.native."+context.runID.uuidString.lowercased(),
                  CapabilityExecutionRouter.decision(for:call.toolName).backend == .nativeApple else {
                throw NativeWorkbenchApprovalError.changed
            }
            struct Target:Decodable {let projectID:UUID;let action:String;let expectedRevision:Int64}
            let target=try JSONDecoder().decode(Target.self,from:call.argumentsJSON)
            guard target.projectID==intent.projectID,target.action==intent.operation,target.expectedRevision==intent.revision else {
                throw NativeWorkbenchApprovalError.changed
            }
        } else {
            guard let pin,pin.generation==context.executionBindingGeneration,
                  pin.target.environmentID==context.environmentID,context.environment?.id==context.environmentID,
                  call.scope==(pin.target.remoteHostID.map(ToolScope.host) ?? .local) else {
                throw NativeWorkbenchApprovalError.changed
            }
        }
        try await validateOriginal()
        try runner.validateArguments(call.argumentsJSON)
        let policy = try await SQLiteWorkspaceStore(database: environment.database).taskPolicy(conversationID: taskID)
        if let allowed = policy.allowedToolNames, !allowed.contains(call.toolName) { throw NativeWorkbenchApprovalError.readOnly }
        if pin?.target.remoteHostID != nil, policy.remoteExecutionAllowed != true { throw NativeWorkbenchApprovalError.readOnly }
        if descriptor.riskLabels.contains(.accessesCredentials), policy.credentialsAllowed != true { throw NativeWorkbenchApprovalError.readOnly }
        if descriptor.riskLabels.contains(.networkAccess), policy.networkAllowed == false { throw NativeWorkbenchApprovalError.readOnly }
        let key = context.runID.uuidString + ":" + call.id
        guard NativeWorkbenchApprovalFlight.calls.insert(key).inserted else { throw NativeWorkbenchApprovalError.changed }
        defer { NativeWorkbenchApprovalFlight.calls.remove(key) }
        let prior = try await environment.runStore.events(runID: context.runID)
        guard !prior.contains(where: { event in
            guard event.kind == .approval,
                  let value = try? JSONSerialization.jsonObject(with: Data(event.payloadJSON.utf8)) as? [String: Any] else { return false }
            return value["nativeRequestID"] as? String == call.id
        }) else { throw NativeWorkbenchApprovalError.changed }
        func validateRun() async throws {
            try context.cancellation.throwIfCancelled(); try Task.checkCancellation()
            guard let latest = try await environment.runStore.run(id: context.runID),
                  latest.conversationID == taskID, latest.endedAt == nil,
                  latest.executionBinding == pin,
                  let task = try await environment.conversationStore.conversation(id: taskID),
                  task.purpose == requiredPurpose else {throw NativeWorkbenchApprovalError.changed}
            if let intent=nativeLaTeXIntent {
                let events=try await environment.runStore.events(runID:context.runID)
                var currentPolicy=try await SQLiteWorkspaceStore(database:environment.database).taskPolicy(conversationID:taskID)
                // An unset policy is materialized with a fresh timestamp on
                // every read. Compare every effective field, not that metadata.
                currentPolicy.updatedAt=policy.updatedAt
                guard latest.state=="preparing",latest.executionBinding==nil,
                      let proof=LaTeXAppleNativeRunProof.read(events,runID:context.runID,taskID:taskID),
                      proof.projectID==intent.projectID,proof.owner==intent.owner,
                      proof.revision==intent.revision,proof.operation==intent.operation,
                      currentPolicy==policy else {
                    throw NativeWorkbenchApprovalError.changed
                }
                let original=try await environment.latexComposition.authorizeOriginal(intent.projectID,context:context,editing:true)
                guard original.owner==intent.owner,
                      try await LaTeXProjectStore(root:original.root).manifest().revision==intent.revision else {
                    throw NativeWorkbenchApprovalError.changed
                }
            } else {
                guard let pin,try await TaskExecutionBindingStore(database:environment.database).binding(conversationID:taskID)==pin else {
                    throw NativeWorkbenchApprovalError.changed
                }
            }
        }
        try await validateRun()
        try await validateOriginal()
        try await validateRun()
        let grant = ApprovalGrant(scope: .init(toolName: call.toolName, hostID: pin?.target.remoteHostID,
            singleUse: true, toolAuthorizationIdentity: descriptor.authorizationIdentity),
            expiresAt: Date().addingTimeInterval(300), policyName: "native-ui")
        struct Receipt: Encodable {
            let nativeRequestID: String
            let projectID: UUID
            let payloadDigest: String
            let grant: ApprovalGrant
        }
        let bytes = try JSONEncoder().encode(Receipt(nativeRequestID: call.id, projectID: projectID,
            payloadDigest: payloadDigest, grant: grant))
        try await environment.runStore.appendEvent(runID: context.runID, kind: .approval,
            payloadJSON: String(decoding: bytes, as: UTF8.self))
        try await validateOriginal()
        try await validateRun()
        return grant
    }
}
#endif
