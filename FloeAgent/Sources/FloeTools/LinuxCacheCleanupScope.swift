// FloeTools — the exact purpose ceiling for a one-tap Linux cache-cleanup
// task.
//
// The persisted LinuxCacheCleanupTaskProfile narrows the ordinary catalog to
// the four native cleanup actions plus the native user-question interaction
// and tool discovery. This policy is re-evaluated at the canonical dispatch
// boundary, not only at schema composition, so a stale/forged descriptor,
// alias, batch wrapper or conversation text cannot widen it. It never grants
// host files, arbitrary shell, installs, network, sends, project/document
// deletion, package/toolchain/model deletion or service shutdown.

import Foundation
import FloeModels

public enum LinuxCacheCleanupScope {
    public static let inspectToolName = "linux.cache.inspect"
    public static let cleanToolName = "linux.cache.clean"
    public static let statusToolName = "linux.cache.status"
    public static let cancelToolName = "linux.cache.cancel"

    /// The entire model-facing ceiling. `tools.*` are discovery plumbing, and
    /// `user.ask` is the native ambiguity question. No exec.shell/jobs/apt/
    /// workspace/delegate/network/host tool can enter this set.
    public static let allowedToolNames: Set<String> = [
        inspectToolName,
        cleanToolName,
        statusToolName,
        cancelToolName,
        "user.ask",
        "tools.search",
        "tools.list",
        "tools.readResult"
    ]

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
        arguments: Data
    ) -> String? {
        guard profile.isValid,
              profile.profile == LinuxCacheCleanupTaskProfile.currentProfile,
              profile.backend == .linuxVM,
              profile.conversationID == conversationID,
              profile.environmentID == environmentID else {
            return "This task's stored Linux cleanup purpose does not match its live conversation/environment binding. Create a new cleanup task from Data Management; conversation text cannot widen or rebind it."
        }
        guard allowedToolNames.contains(descriptor.name) else {
            return "The '\(descriptor.name)' tool is outside this Linux cache-cleanup task. Only the dedicated cleanup actions, the native user question and tool discovery are available."
        }
        if isCleanupToolName(descriptor.name) {
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
        default:
            return nil
        }
    }

    /// Argument surface. The cleanup tools take NO path, command or free-form
    /// text: only category ids and, for status/cancel, a job UUID. Extra keys
    /// are refused so a model cannot smuggle a future parameter.
    private static func argumentDenialReason(tool: String, arguments: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: arguments) as? [String: Any] else {
            return "The '\(tool)' call requires a JSON object with only its documented fields."
        }
        switch tool {
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
        case statusToolName, cancelToolName:
            guard Set(object.keys) == Set(["jobID"]),
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
