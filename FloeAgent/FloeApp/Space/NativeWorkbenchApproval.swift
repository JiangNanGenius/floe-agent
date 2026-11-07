// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeSecurity
import FloeTools

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
        validateOriginal: @MainActor @Sendable () async throws -> Void) async throws -> ApprovalGrant {
        let call = action.toolCall
        try Task.checkCancellation(); try context.cancellation.throwIfCancelled()
        guard !context.temporaryReadOnly, !context.publicWebOnly, context.childExecution == nil,
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
              let pin = run.executionBinding, pin.generation == context.executionBindingGeneration,
              pin.target.environmentID == context.environmentID,
              context.environment?.id == context.environmentID,
              call.scope == (pin.target.remoteHostID.map(ToolScope.host) ?? .local),
              let task = try await environment.conversationStore.conversation(id: taskID),
              task.purpose == requiredPurpose else { throw NativeWorkbenchApprovalError.changed }
        try await validateOriginal()
        try runner.validateArguments(call.argumentsJSON)
        let policy = try await SQLiteWorkspaceStore(database: environment.database).taskPolicy(conversationID: taskID)
        if let allowed = policy.allowedToolNames, !allowed.contains(call.toolName) { throw NativeWorkbenchApprovalError.readOnly }
        if pin.target.remoteHostID != nil, policy.remoteExecutionAllowed != true { throw NativeWorkbenchApprovalError.readOnly }
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
                  task.purpose == requiredPurpose,
                  try await TaskExecutionBindingStore(database: environment.database).binding(conversationID: taskID) == pin
            else { throw NativeWorkbenchApprovalError.changed }
        }
        try await validateRun()
        try await validateOriginal()
        try await validateRun()
        let grant = ApprovalGrant(scope: .init(toolName: call.toolName, hostID: pin.target.remoteHostID,
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
