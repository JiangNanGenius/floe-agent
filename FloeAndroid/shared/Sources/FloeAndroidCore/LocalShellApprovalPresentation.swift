// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeAgentRuntime
import FloeAndroidShellTools

/// Display-only local Linux command projection. It never widens a grant,
/// executes shell, sends data to the model or persists the returned fields.
enum LocalShellApprovalPresentation {
    typealias Value = SettingsDomainV1.JSONValue

    static func samePinnedTarget(_ frozen: C02ResolvedExecutionTarget, _ current: C02ResolvedExecutionTarget) -> Bool {
        let a = frozen.target, b = current.target, p = frozen.pin, q = current.pin
        return a.kind == .localLinux && b.kind == .localLinux && a.remote == nil && b.remote == nil &&
            a.taskID == b.taskID && a.revision == b.revision && a.environmentID == b.environmentID &&
            a.workspaceID == b.workspaceID && a.projectID == b.projectID &&
            a.shellRootHash == b.shellRootHash && a.engineOwnerHash == b.engineOwnerHash &&
            a.rootEpoch == b.rootEpoch && p.runID == q.runID && p.taskID == q.taskID &&
            p.targetRevision == q.targetRevision && p.environmentID == q.environmentID &&
            p.shellRootHash == q.shellRootHash && p.engineOwnerHash == q.engineOwnerHash &&
            p.rootEpoch == q.rootEpoch && p.matches(a) && q.matches(b)
    }

    static func details(waiting: AgentState.WaitingApproval, target: C02ResolvedExecutionTarget,
                        workspace: WorkspaceApprovalLaunchProof,
                        shell: LocalShellService) -> [String: Value]? {
        guard waiting.toolCall.toolName == "exec.shell", case .local = waiting.toolCall.scope,
              !waiting.toolCall.id.hasPrefix("jobs."), target.target.kind == .localLinux,
              target.target.workspaceID == workspace.workspaceID,
              target.pin.matches(target.target), target.target.revision > 0,
              let object = try? JSONSerialization.jsonObject(with: waiting.toolCall.argumentsJSON) as? [String: Any],
              Set(object.keys).isSubset(of: ["command", "script", "cwd", "env", "stdin", "timeout", "maxOutputBytes", "environmentTransaction", "packages", "packagePurpose", "packageCapabilities"]),
              !object.keys.contains("stdin"),
              let args = try? JSONDecoder().decode(LocalShellTool.Arguments.self, from: waiting.toolCall.argumentsJSON),
              (args.command == nil) != (args.script == nil),
              args.env?.isEmpty != false, args.packagePurpose == nil, args.packageCapabilities == nil,
              args.packages?.isEmpty != false,
              let command = args.resolvedCommand, !command.isEmpty, command.utf8.count <= 16_384,
              safeText(command, allowNewlines: true),
              safeText(target.target.environmentID, allowNewlines: false),
              !target.target.environmentID.isEmpty, target.target.environmentID.utf8.count <= 128,
              (try? LocalShellTool(shell: shell).validate(args)) != nil else { return nil }
        let cwd = args.cwd ?? "."
        let canonicalRoot = workspace.rootURL.resolvingSymlinksInPath().standardizedFileURL
        guard !cwd.isEmpty, cwd.utf8.count <= 1_024, safeText(cwd, allowNewlines: false),
              !cwd.hasPrefix("/"), !cwd.hasPrefix("~"), !cwd.contains("\\"),
              cwd == "." || cwd.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              let resolved = try? ShellInputValidation.directory(cwd: cwd, root: workspace.rootURL),
              resolved.standardizedFileURL == (cwd == "." ? canonicalRoot : canonicalRoot.appendingPathComponent(cwd).standardizedFileURL),
              workspace.rootHandle.matches(root: workspace.rootURL) else { return nil }
        return [
            "kind": .string("localShell"), "target": .string("localLinux"),
            "environmentID": .string(target.target.environmentID),
            "workspaceID": .string(workspace.workspaceID.uuidString.lowercased()),
            "targetRevision": .integer(target.target.revision),
            "command": .string(command), "cwd": .string(cwd),
            "timeoutSeconds": .fractional(shell.normalizedTimeout(args.timeout, isBackground: false)),
            "maxOutputBytes": .integer(Int64(shell.normalizedOutputCap(args.maxOutputBytes))),
            "environmentTransaction": .boolean(args.environmentTransaction ?? false),
        ]
    }

    private static func safeText(_ text: String, allowNewlines: Bool) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            if allowNewlines && scalar.value == 10 { return true }
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .unassigned:
                return false
            default: return true
            }
        }
    }
}
