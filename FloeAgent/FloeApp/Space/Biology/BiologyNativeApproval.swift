// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeSecurity
import FloeTools

extension ConversationCenter {
    /// Preserve Biology's source and original-authority checks while sharing
    /// the existing single-use native approval receipt with workbenches.
    func recordNativeWorkbenchApproval(_ action: ProposedAction, context: ToolContext,
        descriptor: ToolCatalog.Descriptor, intent: BiologyNativeUIIntent) async throws -> ApprovalGrant {
        switch intent.source {
        case .console: break
        case .analysis, .imageRegion:
            guard action.toolCall.toolName == "biology.analyze" else { throw BiologyHostError.changed }
        }
        do {
            return try await recordNativeWorkbenchApproval(action, context: context, descriptor: descriptor,
                projectID: intent.projectID, requestID: intent.requestID, payloadDigest: intent.payloadDigest,
                allowedToolNames: BiologyHostServices.names) {
                    guard let taskID = context.conversationID,
                          try await self.environment.studioCoordinator.access.get().canAccess(
                            conversationID: taskID, projectID: intent.projectID,
                            editing: descriptor.isSideEffecting) else { throw BiologyHostError.changed }
                }
        } catch NativeWorkbenchApprovalError.changed {
            throw BiologyHostError.changed
        } catch NativeWorkbenchApprovalError.readOnly {
            throw BiologyHostError.readOnly
        }
    }
}
#endif
