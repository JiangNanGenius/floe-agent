// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeSecurity
import FloeTools

@MainActor private enum BiologyNativeApprovalFlight {
    static var calls: Set<String> = []
}

extension ConversationCenter {
    /// The native Execute/Run button is the user's approval of this exact
    /// invocation. Model calls never enter this method: their existing
    /// AgentRuntime approval path remains authoritative. Record the same
    /// single-use grant type before the native runtime issues its token.
    func recordNativeWorkbenchApproval(_ action: ProposedAction, context: ToolContext,
        descriptor: ToolCatalog.Descriptor, intent: BiologyNativeUIIntent) async throws -> ApprovalGrant {
        let call = action.toolCall
        try Task.checkCancellation(); try context.cancellation.throwIfCancelled()
        guard !context.temporaryReadOnly, !context.publicWebOnly, context.childExecution == nil,
              let taskID = context.conversationID, context.toolCallID == call.id,
              call.id == intent.requestID, descriptor.name == call.toolName,
              BiologyHostServices.names.contains(call.toolName),
              context.allowedToolNames?.contains(call.toolName) == true,
              RuntimeAuthorityDigest.payloadDigest(call.argumentsJSON) == intent.payloadDigest,
              let runner = ToolRunnerRegistry.shared.runner(named: call.toolName),
              runner.descriptor.authorizationIdentity == descriptor.authorizationIdentity,
              action.riskLabels == Set(descriptor.riskLabels.map(\.rawValue)),
              let run = try await environment.runStore.run(id: context.runID),
              run.conversationID == taskID, run.endedAt == nil,
              let pin = run.executionBinding, pin.generation == context.executionBindingGeneration,
              pin.target.environmentID == context.environmentID,
              context.environment?.id == context.environmentID,
              call.scope == (pin.target.remoteHostID.map(ToolScope.host) ?? .local),
              let task = try await environment.conversationStore.conversation(id: taskID), task.purpose == .ordinary,
              try await environment.studioCoordinator.access.get().canAccess(conversationID: taskID,
                projectID: intent.projectID, editing: descriptor.isSideEffecting) else { throw BiologyHostError.changed }
        switch intent.source {
        case .console: break
        case .analysis, .imageRegion:
            guard call.toolName == "biology.analyze" else { throw BiologyHostError.changed }
        }
        try runner.validateArguments(call.argumentsJSON)
        let policy = try await SQLiteWorkspaceStore(database: environment.database).taskPolicy(conversationID: taskID)
        if let allowed = policy.allowedToolNames, !allowed.contains(call.toolName) { throw BiologyHostError.readOnly }
        if pin.target.remoteHostID != nil, policy.remoteExecutionAllowed != true { throw BiologyHostError.readOnly }
        if descriptor.riskLabels.contains(.accessesCredentials), policy.credentialsAllowed != true { throw BiologyHostError.readOnly }
        if descriptor.riskLabels.contains(.networkAccess), policy.networkAllowed == false { throw BiologyHostError.readOnly }
        // A callback racing a second button cannot approve the same request
        // twice. The durable event also fences reconstruction after a retry.
        let key = context.runID.uuidString + ":" + call.id
        guard BiologyNativeApprovalFlight.calls.insert(key).inserted else { throw BiologyHostError.changed }
        defer { BiologyNativeApprovalFlight.calls.remove(key) }
        let prior = try await environment.runStore.events(runID: context.runID)
        guard !prior.contains(where: { event in
            guard event.kind == .approval,
                  let value = try? JSONSerialization.jsonObject(with: Data(event.payloadJSON.utf8)) as? [String: Any] else { return false }
            return value["nativeRequestID"] as? String == call.id
        }) else { throw BiologyHostError.changed }
        try context.cancellation.throwIfCancelled(); try Task.checkCancellation()
        let grant = ApprovalGrant(scope: .init(toolName: call.toolName, hostID: pin.target.remoteHostID,
            singleUse: true, toolAuthorizationIdentity: descriptor.authorizationIdentity),
            expiresAt: Date().addingTimeInterval(300), policyName: "native-ui")
        struct Receipt: Encodable {
            let nativeRequestID: String
            let projectID: UUID
            let payloadDigest: String
            let grant: ApprovalGrant
        }
        let bytes = try JSONEncoder().encode(Receipt(nativeRequestID: call.id, projectID: intent.projectID,
            payloadDigest: intent.payloadDigest, grant: grant))
        try await environment.runStore.appendEvent(runID: context.runID, kind: .approval,
            payloadJSON: String(decoding: bytes, as: UTF8.self))
        try context.cancellation.throwIfCancelled(); try Task.checkCancellation()
        return grant
    }
}
#endif
