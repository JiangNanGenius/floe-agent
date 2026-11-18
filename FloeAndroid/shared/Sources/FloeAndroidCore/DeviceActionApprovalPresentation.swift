// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeAgentRuntime

/// Untrusted request metadata only. A host-side live observation proof is
/// required before this projection may be presented as an approvable action.
/// In particular, a node reference is never itself a human-readable target.
enum DeviceActionApprovalPresentation {
    typealias Value = SettingsDomainV1.JSONValue

    static func details(waiting: AgentState.WaitingApproval) -> [String: Value]? {
        let call = waiting.toolCall
        guard call.toolName == "device.act", case .local = call.scope,
              let values = try? JSONSerialization.jsonObject(with: call.argumentsJSON) as? [String: Any],
              let action = values["action"] as? String,
              let observation = values["observationId"] as? String,
              let node = values["nodeRef"] as? String,
              validObservation(observation), !node.isEmpty, node.utf8.count <= 16,
              node.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) })
        else { return nil }

        var allowed: Set<String> = ["action", "observationId", "nodeRef"]
        var direction: Value = .null
        var inputKind: Value = .null
        switch action {
        case "click", "focus", "commit": break
        case "scroll", "swipe":
            allowed.insert("direction")
            guard let value = values["direction"] as? String,
                  (action == "scroll" ? ["forward", "backward"] : ["up", "down", "left", "right"]).contains(value)
            else { return nil }
            direction = .string(value)
        case "setText":
            let keys = ["text", "sensitiveText"].filter { values.keys.contains($0) }
            guard keys.count == 1, let key = keys.first,
                  let text = values[key] as? String, text.utf16.count <= 2_000 else { return nil }
            allowed.insert(key)
            inputKind = .string(key)
        default: return nil
        }
        guard Set(values.keys).isSubset(of: allowed) else { return nil }
        return ["kind": .string("deviceAction"), "action": .string(action),
                "observationId": .string(observation), "nodeRef": .string(node),
                "direction": direction, "inputKind": inputKind]
    }

    private static func validObservation(_ value: String) -> Bool {
        let id = value.hasPrefix("adbui-") ? String(value.dropFirst(6)) : value
        guard let uuid = UUID(uuidString: id) else { return false }
        return uuid.uuidString.lowercased() == id
    }
}
