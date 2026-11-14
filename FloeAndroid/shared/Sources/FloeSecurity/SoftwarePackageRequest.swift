// FloeSecurity — bounded software-package request inspection.
//
// The package-review role must see the SAME declared dependency work that the
// tools will execute, including a dependency preparation submitted through
// `jobs.submit` around exactly `exec.shell`. This file owns the two bounded
// inspections that decision needs:
//
// * `shellDeclaresPackageOperation` — the ORIGINAL install-verb/`packages`
//   predicate for a concrete exec.shell argument object. It is shared by the
//   direct call and by the nested background-job declaration so both cannot
//   drift apart.
// * `backgroundExecShellDeclaration` — a bounded, exact, fail-closed reader
//   for the ONE supported wrapper shape (`jobs.submit`, target exactly
//   `exec.shell`, `arguments` a JSON-encoded string as the published schema
//   requires). Unknown keys, a managed-service declaration, a non-string
//   `arguments` value, malformed JSON or a payload without a real command
//   return nil: the wrapper is then never treated as a package request or as
//   a resolved PRoot shell route, and the ordinary policy remains in force.
//   There is NO recursive unwrapping and no second tool-name spelling: a
//   level-2 wrapper is simply an unknown inner payload.
// * `trustedEnvironmentClass` — the runtime-owned route fact. It only reports
//   `localLinuxPRoot` when the app resolved THIS run to the local Linux PRoot
//   target AND the exact call is a shell call that consumes that route.
//   Native/remote/unknown calls stay exactly where they were. The separate
//   `localLinuxGuestEnvironment` record class (a real `.linuxVM` guest) keeps
//   its existing deterministic carve-outs; the PRoot route class is NOT a
//   guest/disposability claim and deliberately does not satisfy them.
// * `normalizedJobSubmitCall` — closes the only later-runtime incompatibility
//   found by the actual Full12 trace. The durable `toolRequest` projection
//   stored by `ConversationRunService` keeps `input` as a JSON STRING, and
//   `AgentRuntime` emits the raw request before its canonical normalization;
//   the task-transcript exporter (`C08TaskTranscript.scrub`) additionally
//   re-parses any string that begins with `{`/`[` into nested JSON. An
//   exported `arguments` object is therefore NOT proof of runtime
//   normalization, while the runtime schema and the strict
//   `JobsSubmitTool.Arguments` decoder did require a string. When a provider/model really
//   emits the supported nested-object shape, this helper converts exactly
//   `jobs.submit` → `exec.shell` `arguments` object to its canonical JSON
//   string at the canonical ingress, BEFORE approval/checkpoint/persistence,
//   so the approved bytes and the dispatched bytes are the same canonical
//   bytes. The schema string shape is returned BYTE-IDENTICAL. Arrays,
//   scalars, other targets and managed-service declarations are left
//   untouched so the tool's own strict validation still refuses them.

import Foundation
import FloeCore
import FloeModels

/// Bounded projection of one exact `jobs.submit` wrapper around
/// `exec.shell`. Values are the DECLARED payload, never verified effect.
public struct BackgroundExecShellDeclaration: Sendable, Equatable {
    /// The exact inner `arguments` string bytes the tool will decode and the
    /// job will execute. For the schema string shape this is byte-identical
    /// to the approved field; it is never re-serialized.
    public let innerArgumentsJSON: Data
    /// The command/script the shell will run. Non-empty by construction.
    public let command: String
    /// Declared `packages` entries, bounded to the first 24 and each entry
    /// size-capped. Empty for a command-only request.
    public let packageNames: [String]
    /// Total declared package count before the 24-entry projection cap.
    public let declaredPackageCount: Int
    /// The optional outer job purpose, bounded by the jobs schema.
    public let purpose: String?
    /// True only when the declared command carries an installer verb or the
    /// legacy `packages` list is non-empty (the ORIGINAL predicate).
    public let declaresSoftwareInstall: Bool

    public init(
        innerArgumentsJSON: Data,
        command: String,
        packageNames: [String],
        declaredPackageCount: Int,
        purpose: String?,
        declaresSoftwareInstall: Bool
    ) {
        self.innerArgumentsJSON = innerArgumentsJSON
        self.command = command
        self.packageNames = packageNames
        self.declaredPackageCount = declaredPackageCount
        self.purpose = purpose
        self.declaresSoftwareInstall = declaresSoftwareInstall
    }
}

public enum SoftwarePackageRequest {
    public static let shellToolName = "exec.shell"
    public static let backgroundJobToolName = "jobs.submit"

    /// Closed outer wrapper keys. An unknown key is not the reviewed shape:
    /// the runtime authority's canonical payload also drops it later, so the
    /// submission would fail closed at the job boundary. Refusing to classify
    /// it as a package request here keeps the review and execution verdicts
    /// consistent.
    private static let backgroundWrapperKeys: Set<String> = [
        "tool", "arguments", "purpose", "wait", "service",
    ]

    /// The exact resolved shell command: `command` first, then the documented
    /// `script` alias. Empty/whitespace-only values are not a command.
    public static func shellCommand(in object: [String: Any]) -> String? {
        for key in ["command", "script"] {
            if let value = object[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    /// The ORIGINAL software-install predicate for a concrete exec.shell
    /// argument object: a non-empty declared `packages` list, or an installer
    /// verb in the resolved command. It reuses the same regex the direct call
    /// used and resolves the documented `script` alias exactly as the shell
    /// tool does; the nested wrapper shares this single predicate rather than
    /// carrying a second package-name whitelist.
    public static func shellDeclaresPackageOperation(in object: [String: Any]) -> Bool {
        if let packages = object["packages"] as? [Any], !packages.isEmpty { return true }
        guard let command = shellCommand(in: object) else { return false }
        return command.range(
            of: #"(?i)(^|[\s;&|])(apt|apt-get|pkg|pip3?|python3?\s+-m\s+pip)\s+(install|remove|uninstall|upgrade)"#,
            options: .regularExpression) != nil
    }

    /// Bounded exact reader for the ONE supported background wrapper. Returns
    /// nil for every malformed, unknown, service-mode, non-string-arguments
    /// or multilevel shape; the caller must then keep the ordinary policy.
    public static func backgroundExecShellDeclaration(
        argumentsJSON: Data
    ) -> BackgroundExecShellDeclaration? {
        guard let outer = jsonObject(argumentsJSON) else { return nil }
        guard Set(outer.keys).isSubset(of: backgroundWrapperKeys) else { return nil }
        guard let target = outer["tool"] as? String, target == shellToolName else { return nil }
        // A managed service is not one-shot dependency preparation: its
        // payload has a different lifetime/ownership contract.
        if let service = outer["service"], !(service is NSNull) { return nil }
        let purpose: String?
        if let rawPurpose = outer["purpose"], !(rawPurpose is NSNull) {
            guard let value = rawPurpose as? String, value.utf8.count <= 240 else {
                return nil
            }
            purpose = value
        } else {
            purpose = nil
        }
        if let rawWait = outer["wait"], !(rawWait is NSNull), !(rawWait is Bool) {
            return nil
        }
        // The published schema and the strict JobsSubmitTool decoder require
        // a JSON-encoded STRING. A nested object is a different (export-only)
        // shape and is refused here unless the canonical ingress normalized
        // it first.
        guard let rawArguments = outer["arguments"] as? String else { return nil }
        let innerData = Data(rawArguments.utf8)
        guard let inner = jsonObject(innerData) else { return nil }
        guard let command = shellCommand(in: inner) else { return nil }
        let rawPackages = inner["packages"] as? [Any] ?? []
        let packageNames = rawPackages.prefix(24).map {
            String(String(describing: $0).prefix(80))
        }
        return BackgroundExecShellDeclaration(
            innerArgumentsJSON: innerData,
            command: command,
            packageNames: Array(packageNames),
            declaredPackageCount: rawPackages.count,
            purpose: purpose,
            declaresSoftwareInstall: shellDeclaresPackageOperation(in: inner))
    }

    /// Runtime-owned trusted environment class for one call. Only a LOCAL
    /// call can receive a local class; a host/host-path scope is remote.
    ///
    /// `localLinuxGuestEnvironment` keeps the ORIGINAL `.linuxVM` semantics
    /// and is checked first. `localLinuxShellTarget` is the app-resolved
    /// local Linux PRoot route fact; the additional environment id and exact
    /// shell-call predicate keep it from ever describing the Android host, an
    /// SSH target, a temporary/Notes run or a non-shell tool.
    public static func trustedEnvironmentClass(
        for call: ToolCall,
        localLinuxGuestEnvironment: Bool,
        localLinuxShellTarget: Bool,
        environmentID: String?
    ) -> ApprovalEnvironmentClass {
        guard case .local = call.scope else { return .remote }
        if localLinuxGuestEnvironment { return .localLinuxVM }
        guard localLinuxShellTarget,
              let environmentID,
              !environmentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              callUsesTaskLocalLinuxShell(call) else {
            return .localNative
        }
        return .localLinuxPRoot
    }

    /// True only for a shell call that really consumes the task PRoot route:
    /// a direct `exec.shell` with a resolved command/script, or a `jobs.submit`
    /// wrapper whose exact target is `exec.shell` and whose bounded inner
    /// declaration carries a resolved command/script.
    public static func callUsesTaskLocalLinuxShell(_ call: ToolCall) -> Bool {
        switch call.toolName {
        case shellToolName:
            guard let object = jsonObject(call.argumentsJSON) else { return false }
            return shellCommand(in: object) != nil
        case backgroundJobToolName:
            return backgroundExecShellDeclaration(argumentsJSON: call.argumentsJSON) != nil
        default:
            return false
        }
    }

    /// Canonicalizes ONLY the supported `jobs.submit` → `exec.shell` nested
    /// object `arguments` shape into the schema's JSON string form. The
    /// string form and every unsupported shape are returned BYTE-IDENTICAL.
    /// Called at the canonical ingress BEFORE approval, checkpointing,
    /// persistence and provider replay, so the approved and dispatched
    /// payloads are the same bytes. Throws only when the canonicalized call
    /// would exceed the tool's own argument ceiling — an honest malformed-call
    /// refusal, never a truncation.
    public static func normalizedJobSubmitCall(_ call: ToolCall) throws -> ToolCall {
        guard call.toolName == backgroundJobToolName else { return call }
        guard let outer = jsonObject(call.argumentsJSON) else { return call }
        guard Set(outer.keys).isSubset(of: backgroundWrapperKeys) else { return call }
        guard let target = outer["tool"] as? String, target == shellToolName else { return call }
        if let service = outer["service"], !(service is NSNull) { return call }
        guard let rawArguments = outer["arguments"], !(rawArguments is NSNull) else { return call }
        // Schema shape: preserve exactly. Scalars/arrays are malformed and
        // must keep failing the tool's strict decoder.
        if rawArguments is String { return call }
        guard let inner = rawArguments as? [String: Any],
              JSONSerialization.isValidJSONObject(inner),
              let innerData = try? JSONSerialization.data(
                  withJSONObject: inner, options: [.sortedKeys]),
              let innerString = String(data: innerData, encoding: .utf8),
              jsonObject(innerData) != nil else {
            return call
        }
        var normalizedOuter = outer
        normalizedOuter["arguments"] = innerString
        guard JSONSerialization.isValidJSONObject(normalizedOuter),
              let normalizedData = try? JSONSerialization.data(
                  withJSONObject: normalizedOuter, options: [.sortedKeys]) else {
            return call
        }
        let limit = toolArgumentsByteLimit(for: call.toolName)
        guard normalizedData.count <= limit else {
            throw FloeError.validationFailed(
                "jobs.submit arguments exceed \(limit) bytes after normalizing the supported nested object shape")
        }
        var normalized = call
        normalized.argumentsJSON = normalizedData
        return normalized
    }

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
