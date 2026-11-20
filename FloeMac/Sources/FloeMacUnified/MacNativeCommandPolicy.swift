// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeMacBridgeProtocol
import FloeModels
import FloeSecurity

/// Risk describes the command. The requested file boundary is a separate decision.
/// Workspace execution is additionally confined by the shell runner at the OS level.
struct MacNativeCommandPolicy: ApprovalPolicy, ApprovalReviewRouting {
    enum Risk {
        case low, medium, high

        var title: String {
            switch self {
            case .low: MacPermissionsText.t("低风险", "Low risk")
            case .medium: MacPermissionsText.t("中风险", "Medium risk")
            case .high: MacPermissionsText.t("高风险", "High risk")
            }
        }
    }

    struct Review {
        let risk: Risk
        let host: Bool
        let detail: String
    }

    let mode: TaskApprovalMode
    let base: any ApprovalPolicy
    var policyName: String { base.policyName }

    static func review(_ call: ToolCall) -> Review? {
        guard call.toolName == "exec.shell" || call.toolName.hasPrefix("mac.desktop.") else { return nil }
        let object = (try? JSONSerialization.jsonObject(with: call.argumentsJSON)) as? [String: Any] ?? [:]
        if call.toolName.hasPrefix("mac.desktop.") {
            let statusOnly = call.toolName == "mac.desktop.status"
            return Review(risk: statusOnly ? .low : .high, host: !statusOnly,
                          detail: call.toolName + "\n" + (String(data: call.argumentsJSON, encoding: .utf8) ?? ""))
        }
        let access = object["access"] as? String ?? "workspace"
        let command = object["command"] as? String ?? object["script"] as? String ?? ""
        let simple = Set(object.keys).isSubset(of: ["command", "script", "access", "timeout", "timeoutSeconds", "maxOutputBytes"])
            && !(object["command"] != nil && object["script"] != nil)
            && ["workspace", "host"].contains(access)
        let risk = simple ? commandRisk(command) : .high
        // Show every field that could change what the user approved (cwd, env, stdin, etc.).
        var extras = object
        extras.removeValue(forKey: "command")
        extras.removeValue(forKey: "access")
        if object["command"] == nil { extras.removeValue(forKey: "script") }
        let options = extras.isEmpty ? nil : (try? JSONSerialization.data(withJSONObject: extras, options: [.prettyPrinted, .sortedKeys]))
        let suffix = options.flatMap { String(data: $0, encoding: .utf8) }.map { "\n" + $0 } ?? ""
        return Review(risk: risk, host: access != "workspace", detail: command + suffix)
    }

    static func commandRisk(_ source: String) -> Risk {
        let command = source.trimmingCharacters(in: .whitespaces)
        // Only classify simple known forms automatically. Substitutions, shell control
        // syntax, arbitrary programs and unreviewed argument forms stay high risk.
        guard !command.isEmpty, command.utf8.count <= 4096,
              command.range(of: #"^[A-Za-z0-9_./ +,=>-]+\z"#, options: .regularExpression) != nil else { return .high }
        let tokens = command.split(separator: " ").map(String.init)
        guard let program = tokens.first else { return .high }
        let args = tokens.dropFirst()
        if args.contains(where: { BridgeAbsoluteFileRead.isSecretPath("/" + $0) }) { return .high }
        func relative(_ value: String) -> Bool {
            !value.hasPrefix("/") && !value.hasPrefix("-") && !value.contains(">")
                && !value.split(separator: "/").contains("..")
        }
        switch program {
        case "pwd": return args.isEmpty ? .low : .high
        case "uname": return args.allSatisfy { ["-s", "-m", "-r", "-a"].contains($0) } ? .low : .high
        case "ls":
            return args.allSatisfy { relative($0) || ["-a", "-l", "-la", "-al", "-lh"].contains($0) } ? .low : .high
        case "cat", "wc":
            return !args.isEmpty && args.allSatisfy(relative) ? .low : .high
        case "touch", "mkdir":
            return !args.isEmpty && args.allSatisfy(relative) ? .medium : .high
        case "printf", "echo":
            guard let redirect = args.firstIndex(of: ">"), redirect == tokens.count - 2,
                  args[..<redirect].allSatisfy(relative), relative(tokens[redirect + 1]) else { return .high }
            return .medium
        case "make", "swift":
            return (tokens == ["make"] || tokens == ["swift", "build"] || tokens == ["swift", "test"]) ? .medium : .high
        default: return .high
        }
    }

    static func preview(_ call: ToolCall) -> String? { review(call)?.detail }

    func decide(_ action: ProposedAction) async throws -> ApprovalDecision {
        guard let review = Self.review(action.toolCall), mode != .fullAccess else {
            return try await base.decide(action)
        }
        if review.host || review.risk == .high {
            return .escalateToHuman(reason: review.host
                ? MacPermissionsText.t("此操作需要访问工作区之外的 Mac。", "This action needs access outside the workspace.")
                : MacPermissionsText.t("请检查这条高风险命令。", "Review this high-risk command."))
        }
        if review.risk == .low {
            return .allow(scope: ApprovalScope(toolName: action.toolCall.toolName, singleUse: true), expiresAt: nil)
        }
        if mode == .ask {
            return .escalateToHuman(reason: MacPermissionsText.t("此命令会更改工作区。", "This command can change the workspace."))
        }
        return try await base.decide(action)
    }

    func requiresModelReview(_ action: ProposedAction) -> Bool {
        if let review = Self.review(action.toolCall), mode != .fullAccess,
           review.host || review.risk != .medium || mode == .ask { return false }
        return (base as? any ApprovalReviewRouting)?.requiresModelReview(action) ?? false
    }
}
