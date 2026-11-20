// SPDX-License-Identifier: MPL-2.0
import FloeAgentRuntime
import FloeModels
import FloeTools
import Foundation

/// Approval details are decoded only for actions registered with the task runtime.
struct MacTaskActionPreview {
    let title: String
    let detail: String
    let changesState: Bool
    private(set) var riskLabels: Set<String> = ["persistsPersonalData"]

    init?(_ call: ToolCall) {
        let decoder = JSONDecoder()
        switch call.toolName {
        case "image.generate", "video.generate", "video.status", "video.cancel":
            guard let fields = try? JSONSerialization.jsonObject(with: call.argumentsJSON) as? [String: Any],
                  let json = try? JSONSerialization.data(withJSONObject: fields, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return nil }
            let isImage = call.toolName == "image.generate"
            if isImage || call.toolName == "video.generate" {
                guard let prompt = fields["prompt"] as? String, !prompt.isEmpty else { return nil }
                title = isImage ? String(localized: "mac.media.reviewImage") : String(localized: "mac.media.reviewVideo")
                detail = String(localized: "mac.media.providerCharge") + "\n\n" + String(decoding: json, as: UTF8.self)
                riskLabels = isImage ? Set(MacTaskImageGenerateTool.riskLabels.map(\.rawValue))
                    : ["sendsDataToProvider", "networkAccess", "writesFiles"]
                changesState = true
            } else {
                guard let job = fields["jobID"] as? String, UUID(uuidString: job) != nil else { return nil }
                changesState = call.toolName == "video.cancel"
                title = changesState ? String(localized: "mac.media.reviewCancel") : String(localized: "mac.media.reviewStatus")
                detail = job
                riskLabels = ["networkAccess"]
            }
        case MacPublicWebFetch.name:
            guard let args = try? decoder.decode(MacPublicWebFetch.Arguments.self, from: call.argumentsJSON) else { return nil }
            title = String(localized: "mac.web.reviewRead")
            detail = args.url
            changesState = false
            riskLabels = Set(MacPublicWebFetch.riskLabels.map(\.rawValue))
        case MacSearchTool.name:
            guard let args = try? decoder.decode(MacSearchTool.Arguments.self, from: call.argumentsJSON) else { return nil }
            title = String(localized: "mac.settings.webSearch")
            detail = [args.query, args.provider, args.domains?.joined(separator: ", ")].compactMap { $0 }.joined(separator: "\n")
            changesState = false
            riskLabels = Set(MacSearchTool.riskLabels.map(\.rawValue))
        case DelegateMessageTool.name:
            guard let args = try? decoder.decode(DelegateMessageTool.Arguments.self, from: call.argumentsJSON) else { return nil }
            title = String(localized: "mac.conversation.reviewMessage")
            detail = [args.to, args.message].joined(separator: "\n\n")
            changesState = false
            riskLabels = []
        case DelegatePeersTool.name:
            title = String(localized: "mac.child.approvePeers")
            detail = title
            changesState = false
            riskLabels = []
        case ConversationSpawnTool.name:
            guard let args = try? decoder.decode(ConversationSpawnTool.Arguments.self, from: call.argumentsJSON) else { return nil }
            title = String(localized: "mac.conversation.reviewSpawn")
            let folder = args.workspaceID?.uuidString ?? String(localized: "mac.conversation.newFolder")
            detail = [args.title, args.objective, folder].joined(separator: "\n\n")
            changesState = true
        case ConversationMessageTool.name:
            guard let args = try? decoder.decode(ConversationMessageTool.Arguments.self, from: call.argumentsJSON) else { return nil }
            title = String(localized: "mac.conversation.reviewMessage")
            detail = [args.runID.uuidString, args.message].joined(separator: "\n\n")
            changesState = true
        case ConversationListTool.name, ConversationReadTool.name, ConversationSearchTool.name:
            title = String(localized: "mac.conversation.reviewHistory")
            guard let parameters = try? JSONSerialization.jsonObject(with: call.argumentsJSON) as? [String: Any],
                  let formatted = try? JSONSerialization.data(withJSONObject: parameters, options: [.prettyPrinted, .sortedKeys]) else { return nil }
            detail = parameters.isEmpty ? title : String(decoding: formatted, as: UTF8.self)
            changesState = false
        default:
            return nil
        }
    }
}
