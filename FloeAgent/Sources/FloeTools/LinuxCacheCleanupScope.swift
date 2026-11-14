// FloeTools — the exact purpose ceiling for a one-tap Linux cache-cleanup
// task.
//
// The persisted LinuxCacheCleanupTaskProfile narrows the ordinary catalog to
// the existing guest shell/job lifecycle, optional fixed cleanup actions,
// native user questions and discovery. This policy is re-evaluated at dispatch
// boundary, not only at schema composition, so a stale/forged descriptor,
// alias, wrapper or conversation text cannot change its target. It never grants
// host/remote execution, installs, external sends, project/document
// deletion, package/toolchain/model deletion or service shutdown.

import Foundation
import FloeModels

public enum LinuxCacheCleanupScope {
    // The App creates this purpose only for EnvironmentRegistry.sharedContainerID.
    // FloeTools cannot depend on FloeEnvironments, so keep the frozen ID here
    // and require the persisted binding to agree before rewriting a call.
    private static let sharedGuestEnvironmentID = "shared"
    public static let inspectToolName = "linux.cache.inspect"
    public static let cleanToolName = "linux.cache.clean"
    public static let statusToolName = "linux.cache.status"
    public static let cancelToolName = "linux.cache.cancel"

    /// Retained purpose v1 rows used this exact projection. Expanding the
    /// means of an already-authorized cache task does not change its owner,
    /// environment or deletion scope. User-narrowed policies stay narrower.
    public static let legacyToolNames: Set<String> = [
        inspectToolName,
        cleanToolName,
        statusToolName,
        cancelToolName,
        "user.ask",
        "tools.search",
        "tools.list",
        "tools.readResult"
    ]
    public static let guestExecutionToolNames: Set<String> = [
        "exec.shell", "jobs.submit", "jobs.status", "jobs.result", "jobs.cancel"
    ]
    public static let allowedToolNames = legacyToolNames.union(guestExecutionToolNames)

    public static func projectedToolNames(_ saved: Set<String>?) -> Set<String>? {
        saved == legacyToolNames ? allowedToolNames : saved
    }

    /// Shell/submit declare a conservative union including network risk even
    /// for `df`/`du`. Keep the existing command review; do not expose any
    /// separate network capability or change the task's network flag.
    public static func usesGuestCommandReview(_ name: String) -> Bool {
        name == "exec.shell" || name == "jobs.submit"
    }

    /// Intersecting with the actually offered names keeps the ceiling truthful
    /// when a build does not provide a tool.
    public static func allowedToolNames(from offered: Set<String>) -> Set<String> {
        allowedToolNames.intersection(offered)
    }

    public static func isCleanupToolName(_ name: String) -> Bool {
        name == inspectToolName || name == cleanToolName
            || name == statusToolName || name == cancelToolName
    }

    /// Canonical dispatch decision. Nil means the descriptor + arguments are
    /// inside the reviewed cleanup action; every other case is denied with a
    /// model-comprehensible reason before any effect.
    public static func denialReason(
        profile: LinuxCacheCleanupTaskProfile,
        conversationID: UUID,
        environmentID: String?,
        descriptor: ToolCatalog.Descriptor,
        arguments: Data,
        scope: ToolScope = .local
    ) -> String? {
        guard case .local = scope else {
            return "Linux cache cleanup runs only in its saved on-device shared guest; host and remote scopes are refused."
        }
        guard profile.isValid,
              profile.profile == LinuxCacheCleanupTaskProfile.currentProfile,
              profile.backend == .linuxVM,
              profile.conversationID == conversationID,
              profile.environmentID == environmentID else {
            return "This task's stored Linux cleanup purpose does not match its live conversation/environment binding. Create a new cleanup task from Data Management; conversation text cannot widen or rebind it."
        }
        guard allowedToolNames.contains(descriptor.name) else {
            return "The '\(descriptor.name)' tool is outside this Linux cache-cleanup task. Use the saved guest's exec.shell/jobs lifecycle, optional cache actions, native questions and discovery."
        }
        if isCleanupToolName(descriptor.name) || guestExecutionToolNames.contains(descriptor.name) {
            guard let expected = expectedDescriptor(for: descriptor.name) else {
                return "The cleanup tool identity is unknown; the call was refused."
            }
            guard descriptor.effect == expected.effect,
                  descriptor.isSideEffecting == expected.isSideEffecting,
                  descriptor.requiresHostScope == false,
                  descriptor.executionBoundary == .any,
                  descriptor.riskLabels == expected.riskLabels else {
                return "The '\(descriptor.name)' descriptor no longer matches the reviewed Linux cleanup action; the call was refused."
            }
        }
        return argumentDenialReason(tool: descriptor.name, arguments: arguments)
    }

    /// The shell's ordinary cwd validator deliberately accepts only paths
    /// relative to its workspace. A cleanup task may inspect caches anywhere
    /// inside its pinned Linux guest, so translate an absolute guest cwd into
    /// a quoted `cd` in that same guest process. This is a data-only rewrite:
    /// it never selects a host, changes the frozen environment, or bypasses
    /// the shell validator and command approval. Nil leaves the call intact.
    public static func normalizedGuestAbsoluteCWD(
        profile: LinuxCacheCleanupTaskProfile?,
        conversationID: UUID,
        environmentID: String?,
        executionBinding: TaskExecutionBinding?,
        localLinuxGuestEnvironment: Bool,
        remoteExecutionEnvironment: Bool,
        descriptor: ToolCatalog.Descriptor?,
        toolName: String,
        scope: ToolScope,
        arguments: Data
    ) -> Data? {
        guard let profile, let executionBinding, let descriptor,
              profile.environmentID == sharedGuestEnvironmentID,
              executionBinding.conversationID == conversationID,
              executionBinding.target.environmentID == profile.environmentID,
              executionBinding.target.backend == .linuxVM,
              executionBinding.target.remoteHostID == nil,
              executionBinding.target.remoteRootPath == nil,
              localLinuxGuestEnvironment, !remoteExecutionEnvironment,
              descriptor.name == toolName,
              (toolName == "exec.shell" || toolName == "jobs.submit"),
              denialReason(profile: profile, conversationID: conversationID,
                           environmentID: environmentID, descriptor: descriptor,
                           arguments: arguments, scope: scope) == nil,
              var object = try? JSONSerialization.jsonObject(with: arguments) as? [String: Any]
        else { return nil }

        if toolName == "jobs.submit" {
            guard let nested = object["arguments"] as? String,
                  let rewritten = normalizeShellAbsoluteCWD(Data(nested.utf8)) else { return nil }
            object["arguments"] = String(decoding: rewritten, as: UTF8.self)
        } else {
            guard let rewritten = normalizeShellAbsoluteCWD(arguments),
                  let shell = try? JSONSerialization.jsonObject(with: rewritten) as? [String: Any] else { return nil }
            object = shell
        }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func normalizeShellAbsoluteCWD(_ arguments: Data) -> Data? {
        guard var object = try? JSONSerialization.jsonObject(with: arguments) as? [String: Any],
              let cwd = object["cwd"] as? String, cwd.hasPrefix("/"),
              !cwd.hasPrefix("//"), cwd.utf8.count <= 4096,
              cwd.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        let commandKey: String
        if let command = object["command"] as? String,
           !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            commandKey = "command"
        } else if let script = object["script"] as? String,
                  !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            commandKey = "script"
        } else { return nil }
        let literal = "'" + cwd.replacingOccurrences(of: "'", with: "'\\''") + "'"
        guard let body = object[commandKey] as? String else { return nil }
        object[commandKey] = "cd \(literal) || exit $?\n\(body)"
        object.removeValue(forKey: "cwd")
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func expectedDescriptor(
        for name: String
    ) -> (effect: ToolEffect, isSideEffecting: Bool, riskLabels: Set<RiskLabel>)? {
        switch name {
        case inspectToolName:
            return (.readOnly, false, [.readsFiles, .executesLocalCode])
        case cleanToolName:
            return (.mutating, true, [.executesLocalCode, .readsFiles, .writesFiles, .deletesFiles])
        case statusToolName:
            return (.readOnly, false, [])
        case cancelToolName:
            return (.mutating, true, [])
        case "exec.shell", "jobs.submit":
            return (.mutating, true, [.executesLocalCode, .readsFiles, .writesFiles, .deletesFiles, .networkAccess])
        case "jobs.status", "jobs.result":
            return (.readOnly, false, [])
        case "jobs.cancel":
            return (.internalState, true, [])
        default:
            return nil
        }
    }

    /// Convenience tools take category ids/job IDs only. The ordinary shell
    /// keeps its existing command validator and approval; no caller target or
    /// installation/receipt fields can be smuggled through a wrapper.
    private static func argumentDenialReason(tool: String, arguments: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: arguments) as? [String: Any] else {
            return "The '\(tool)' call requires a JSON object with only its documented fields."
        }
        switch tool {
        case "exec.shell":
            let keys: Set<String> = ["command", "script", "cwd", "env", "stdin", "timeout", "timeoutSeconds", "timeoutPolicy", "maxOutputBytes"]
            guard Set(object.keys).isSubset(of: keys),
                  ["command", "script"].contains(where: { (object[$0] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }) else {
                return "Use exec.shell command/script in this task's saved guest. Target overrides, package/skill installers and extra fields are not part of cache cleanup."
            }
            if let env = object["env"] {
                guard let values = env as? [String: String],
                      !values.keys.contains(where: { $0.hasPrefix("FLOE_CLEANUP_") }) else {
                    return "Cleanup receipt markers are app-owned; model commands cannot mint native-script receipts."
                }
            }
            return nil // The registered shell validator and ordinary approval still run.
        case "jobs.submit":
            guard Set(object.keys).isSubset(of: ["tool", "arguments", "purpose", "wait"]),
                  object["tool"] as? String == "exec.shell",
                  let nested = object["arguments"] as? String else {
                return "This cleanup task may submit only exec.shell to the existing job lifecycle in the same saved guest."
            }
            return argumentDenialReason(tool: "exec.shell", arguments: Data(nested.utf8))
        case inspectToolName, cleanToolName:
            let allowedKeys: Set<String> = ["categories"]
            guard Set(object.keys).isSubset(of: allowedKeys) else {
                return "The '\(tool)' call accepts only apt, pip and npm categories; scratch, paths, commands and other fields are refused."
            }
            if let raw = object["categories"] {
                guard let values = raw as? [String], !values.isEmpty else {
                    return "categories must be a non-empty array of known cleanup category ids."
                }
                guard LinuxCacheCleanupCategory.validated(rawValues: values) != nil else {
                    return "categories contains an unsupported or duplicate category. Allowed ids: apt, pip, npm. Scratch is retained because ownership is unverified."
                }
            }
            return nil
        case statusToolName, cancelToolName, "jobs.status", "jobs.result", "jobs.cancel":
            let keys: Set<String> = tool == "jobs.result" ? ["jobID", "offset", "maxBytes"] : ["jobID"]
            guard Set(object.keys).isSubset(of: keys),
                  let raw = object["jobID"] as? String,
                  UUID(uuidString: raw) != nil else {
                return "The '\(tool)' call requires exactly one jobID UUID."
            }
            return nil
        default:
            // Discovery and the native user question keep their own validated
            // argument contracts. Membership in the ceiling is already proven.
            return nil
        }
    }
}
