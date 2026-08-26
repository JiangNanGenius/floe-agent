// FloeSecurity — Approval policy contracts and implementations.
// See docs/DEVELOPMENT_PLAN.md §3.3.

import Foundation
import FloeCore
import FloeModels

/// A fully-described action presented to a policy for decision.
public struct ProposedAction: Sendable, Codable {
    public var toolCall: ToolCall
    /// Deterministic labels from the tool catalog — never model-derived.
    public var riskLabels: Set<String>
    /// The user's original goal, truncated to 2 KiB.
    public var userGoal: String
    /// A bounded, plain-text projection of the most recent conversation.
    /// This is context for the classifier only; it never becomes authority.
    public var recentContext: String
    public var hostAndPathScope: ToolScope

    public init(
        toolCall: ToolCall,
        riskLabels: Set<String>,
        userGoal: String,
        recentContext: String = "",
        hostAndPathScope: ToolScope
    ) {
        self.toolCall = toolCall
        self.riskLabels = riskLabels
        self.userGoal = String(userGoal.prefix(2048))
        self.recentContext = String(recentContext.prefix(8192))
        self.hostAndPathScope = hostAndPathScope
    }
}

/// Decision-making strategy. All side-effecting actions pass through the
/// catastrophic gate first, then through exactly one policy.
public protocol ApprovalPolicy: Sendable {
    var policyName: String { get }
    func decide(_ action: ProposedAction) async throws -> ApprovalDecision
}

/// Lets the runtime distinguish a real model-review wait from a deterministic
/// allow. This keeps exempt local tools out of both the model call and the
/// visible approval spinner.
public protocol ApprovalReviewRouting: Sendable {
    func requiresModelReview(_ action: ProposedAction) -> Bool
}

/// Policy 1: every side-effecting action waits for the user.
public struct HumanApprovalPolicy: ApprovalPolicy {
    public let policyName = "human"

    public init() {}

    public func decide(_ action: ProposedAction) async throws -> ApprovalDecision {
        .escalateToHuman(reason: "Human approval policy requires explicit user decision")
    }
}

/// Policy 2: a configured model returns allow / deny / escalate.
/// The approval model receives the goal, structured action, scope, and
/// deterministic risk labels. It has no tool channel and cannot rewrite
/// the tool call. Any failure is fail-closed (escalate).
public struct ModelApprovalPolicy: ApprovalPolicy, ApprovalReviewRouting {
    public let policyName = "approval-model"

    /// Abstraction over the approval model call so this type stays
    /// testable without a live provider.
    public protocol DecisionBackend: Sendable {
        func decide(_ action: ProposedAction) async throws -> ApprovalDecision
    }

    private let backend: any DecisionBackend

    public init(backend: any DecisionBackend) {
        self.backend = backend
    }

    public func decide(_ action: ProposedAction) async throws -> ApprovalDecision {
        do {
            return try await backend.decide(action)
        } catch {
            return .escalateToHuman(reason: "Approval model failed: \(error.localizedDescription)")
        }
    }

    public func requiresModelReview(_ action: ProposedAction) -> Bool { true }
}

/// Automatic mode: managed packages use their source-review model; when an
/// action-review model is configured, every other side-effecting action is
/// reviewed by that model. The catastrophic gate still runs first and cannot
/// be bypassed. Without a model, safe local mutations remain deterministic
/// while sensitive actions fail closed to the user.
public struct AutomaticApprovalPolicy: ApprovalPolicy, ApprovalReviewRouting {
    private let backend: (any ModelApprovalPolicy.DecisionBackend)?
    private let packageReviewBackend: (any ModelApprovalPolicy.DecisionBackend)?

    /// The runtime uses this identity to route every tool call (including
    /// read-only calls) through the configured classifier exactly once.
    public var policyName: String { backend == nil ? "automatic" : "approval-model" }

    public init(
        backend: (any ModelApprovalPolicy.DecisionBackend)? = nil,
        packageReviewBackend: (any ModelApprovalPolicy.DecisionBackend)? = nil
    ) {
        self.backend = backend
        self.packageReviewBackend = packageReviewBackend
    }

    public func decide(_ action: ProposedAction) async throws -> ApprovalDecision {
        if Self.isDeterministicallyExempt(action) {
            return .allow(scope: Self.scope(for: action.toolCall), expiresAt: nil)
        }
        if action.isManagedPythonPackageRequest {
            guard let packageReviewBackend else {
                return .escalateToHuman(reason: "No software package review model is configured")
            }
            do { return try await packageReviewBackend.decide(action) }
            catch {
                return .escalateToHuman(reason: "Software package review failed: \(error.localizedDescription)")
            }
        }

        if let backend {
            do { return try await backend.decide(action) }
            catch {
                // A provider outage must not make harmless reads unusable.
                // Fall back to the same deterministic local boundary used
                // when no classifier is configured; genuinely sensitive
                // actions still fail closed to the user.
                return deterministicDecision(
                    for: action,
                    unavailableReason: "Approval model unavailable: \(error.localizedDescription)"
                )
            }
        }

        return deterministicDecision(
            for: action,
            unavailableReason: "No approval model is configured for this sensitive action"
        )
    }

    public func requiresModelReview(_ action: ProposedAction) -> Bool {
        if Self.isDeterministicallyExempt(action) { return false }
        if action.isManagedPythonPackageRequest { return packageReviewBackend != nil }
        return backend != nil
    }

    /// Built-in, bounded local inspection does not need a second model to
    /// approve it. Mutating PDF calls only bypass review when they explicitly
    /// create a new output instead of overwriting their source.
    private static func isDeterministicallyExempt(_ action: ProposedAction) -> Bool {
        let alwaysExempt: Set<String> = [
            "image.inspect", "image.ocr", "image.scanBarcode", "image.generate",
            "document.pdf.inspect", "document.pdf.render",
            "workspace.listDirectory", "workspace.readFile",
            "workspace.inspectMetadata", "workspace.searchFiles", "workspace.createFile",
            "workspace.writeFile", "workspace.applyPatch", "workspace.createDirectory",
            "workspace.moveItem", "document.createDocument",
            "browser.observe", "browser.events", "browser.wait", "browser.navigate",
            "network.scanLAN",
            "apple.calendar.list", "apple.reminders.list", "apple.maps.search",
            "apple.home.list", "apple.watch.status", "apple.location.current",
            "apple.automation.list",
            "font.list", "font.install",
            "memory.recall", "exec.localNumerical", "presentation.create",
            "git.status", "git.diff", "git.log", "git.initialize", "git.stage",
            "git.commit", "git.createBranch", "git.switchBranch", "git.fetch",
            "git.pull", "github.repositories", "github.clone",
            "cloudWorkspace.gitStatus", "cloudWorkspace.gitDiff", "cloudWorkspace.gitLog",
            "cloudWorkspace.gitInitialize", "cloudWorkspace.gitStage",
            "cloudWorkspace.gitCommit", "cloudWorkspace.gitFetch",
            "cloudWorkspace.gitPull", "cloudWorkspace.gitBranch"
        ]
        if alwaysExempt.contains(action.toolCall.toolName) { return true }
        if Self.isRoutineToolDiagnosticRequest(action) { return true }
        if Self.isExplicitlyAuthorizedGitPublication(action) { return true }
        if action.toolCall.toolName == "exec.localPython", !action.isManagedPythonPackageRequest {
            return true
        }
        if Self.isReadOnlySSHBootstrap(action) { return true }
        if Self.isExplicitlyAuthorizedSSHBootstrap(action) { return true }
        if Self.isExplicitlyAuthorizedSandboxedSSH(action) { return true }
        if Self.isExplicitlyAuthorizedHostMaintenance(action) { return true }
        if action.toolCall.toolName == "image.svgDocument",
           let object = try? JSONSerialization.jsonObject(with: action.toolCall.argumentsJSON) as? [String: Any],
           object["operation"] as? String == "inspect" { return true }
        guard ["document.pdf.edit", "document.pdf.save"].contains(action.toolCall.toolName),
              let object = try? JSONSerialization.jsonObject(
                  with: action.toolCall.argumentsJSON
              ) as? [String: Any] else { return false }
        let overwritesSource = object["overwrite"] as? Bool ?? false
        return !overwritesSource
    }

    /// A user asking Floe to test/check its tools is authorizing ordinary
    /// diagnostic execution even when they did not enumerate every call.
    /// Keep the authority bounded: this never covers deletion, arbitrary
    /// remote execution, credentials, outbound disclosure, GUI control, or
    /// remote-system mutation, and never skips managed-package review.
    private static func isRoutineToolDiagnosticRequest(_ action: ProposedAction) -> Bool {
        guard !action.isManagedPythonPackageRequest else { return false }
        let goal = action.userGoal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let mentionsTools = ["工具", "能力", "tool", "capability"].contains(where: goal.contains)
        let requestsDiagnostic = [
            "测试", "测一下", "检查", "验证", "试一下", "跑一遍",
            "test", "check", "verify", "smoke test", "try"
        ].contains(where: goal.contains)
        guard mentionsTools, requestsDiagnostic else { return false }
        let excludedRisks: Set<String> = [
            "deletesFiles",
            "accessesCredentials",
            "modifiesRemoteSystem",
            "persistsPersonalData",
            "changesAgentBehavior",
            "controlsGUI",
            "sendsDataToProvider",
            "executesRemoteCommand"
        ]
        return action.riskLabels.isDisjoint(with: excludedRisks)
    }

    /// Safe Git plumbing is deterministic above. Publication remains tied to
    /// the user's stated goal, but one direct request authorizes the bounded
    /// non-force push or repository creation without repeated model reviews.
    private static func isExplicitlyAuthorizedGitPublication(_ action: ProposedAction) -> Bool {
        let goal = action.userGoal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !goal.isEmpty else { return false }
        let denials = [
            "不要推送", "别推送", "不要发布", "不要上传", "不要创建仓库",
            "do not push", "don't push", "do not publish", "do not create"
        ]
        guard !denials.contains(where: goal.contains) else { return false }
        switch action.toolCall.toolName {
        case "git.push", "cloudWorkspace.gitPush":
            return ["推送", "发布", "上传", "push", "publish"].contains(where: goal.contains)
        case "github.createRepository":
            return ["创建仓库", "新建仓库", "create repository", "create repo"].contains(where: goal.contains)
        default:
            return false
        }
    }

    /// SSH discovery and bootstrap planning are read-only even though the
    /// compiled descriptors conservatively carry the mutating labels needed
    /// by their apply variants. They should never consume an approval-model
    /// call or interrupt a setup workflow.
    private static func isReadOnlySSHBootstrap(_ action: ProposedAction) -> Bool {
        switch action.toolCall.toolName {
        case "ssh.listHosts", "ssh.inspectTarget":
            return true
        case "ssh.bootstrapExecutionHost":
            guard let object = action.argumentObject else { return false }
            return object["apply"] as? Bool != true
        case "ssh.bootstrapFloeRemoteAgent":
            guard let object = action.argumentObject else { return false }
            let operation = object["operation"] as? String
            return operation == nil || operation == "plan" || operation == "check"
        default:
            return false
        }
    }

    /// The two bootstrap tools execute fixed, bounded installers. A direct
    /// user request to install/deploy/update that environment is authority for
    /// the requested apply call; asking again after messages such as “授权” or
    /// “我同意安装” is both redundant and the source of the observed loop.
    /// Arbitrary ssh.execute commands remain reviewable.
    private static func isExplicitlyAuthorizedSSHBootstrap(_ action: ProposedAction) -> Bool {
        guard let object = action.argumentObject else { return false }
        let isApplying: Bool
        switch action.toolCall.toolName {
        case "ssh.bootstrapExecutionHost":
            isApplying = object["apply"] as? Bool == true
        case "ssh.bootstrapFloeRemoteAgent":
            isApplying = object["operation"] as? String == "installOrUpdate"
                || object["apply"] as? Bool == true
        default:
            return false
        }
        guard isApplying else { return false }
        let goal = action.userGoal
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !goal.isEmpty else { return false }
        let denials = [
            "不要安装", "别安装", "不要部署", "别部署", "不同意", "不授权",
            "do not install", "don't install", "do not deploy", "not authorized"
        ]
        guard !denials.contains(where: goal.contains) else { return false }
        let explicitConsent = [
            "授权", "同意", "批准", "允许", "可以安装", "确认安装",
            "authorized", "i approve", "i agree", "permission granted"
        ].contains(where: goal.contains)
        let directInstallRequest = [
            "安装", "部署", "配置环境", "准备环境", "搭建环境", "更新远程",
            "install", "deploy", "set up", "setup", "configure the environment",
            "prepare the environment", "update the remote"
        ].contains(where: goal.contains)
        return explicitConsent || directInstallRequest
    }

    /// `ssh.execute` in automatic/container mode cannot mutate the paired
    /// host: the SSH router either runs inside a disposable unprivileged task
    /// container or returns a bootstrap-required result. A direct request to
    /// test tools or prepare that execution environment therefore authorizes
    /// the bounded command without asking once per probe. Explicit host and
    /// network-device modes remain reviewable.
    private static func isExplicitlyAuthorizedSandboxedSSH(_ action: ProposedAction) -> Bool {
        guard action.toolCall.toolName == "ssh.execute",
              let object = action.argumentObject,
              let command = object["command"] as? String,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        let mode = (object["executionMode"] as? String)?.lowercased() ?? "automatic"
        guard mode == "container"
                || (mode == "automatic" && isClearlyReadOnlySSHDiagnostic(command))
        else { return false }

        let goal = action.userGoal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !goal.isEmpty else { return false }
        let denials = [
            "不要执行", "别执行", "不要测试", "别测试", "不要安装", "别安装",
            "do not execute", "don't execute", "do not test", "do not install"
        ]
        guard !denials.contains(where: goal.contains) else { return false }
        let asksForToolDiagnostics =
            ["工具", "能力", "tool", "capability"].contains(where: goal.contains)
            && ["测试", "检查", "验证", "试一下", "跑一遍", "走一遍",
                "test", "check", "verify", "smoke test", "try"].contains(where: goal.contains)
        let asksForEnvironmentWork = [
            "准备环境", "准备远程执行环境", "配置环境", "搭建环境", "安装环境", "远程环境", "容器测试",
            "prepare the environment", "configure the environment", "set up", "setup",
            "remote environment", "container test"
        ].contains(where: goal.contains)
        return asksForToolDiagnostics || asksForEnvironmentWork
    }

    /// A direct request to install, repair, update or prepare a named remote
    /// environment authorizes the ordinary host commands needed to finish
    /// that task as one workflow. The catastrophic gate still runs first, so
    /// this cannot authorize root/home erasure, disks, reboot, or firewall
    /// flushes. Explicit denials always win.
    private static func isExplicitlyAuthorizedHostMaintenance(_ action: ProposedAction) -> Bool {
        guard action.toolCall.toolName == "ssh.execute",
              let object = action.argumentObject,
              (object["executionMode"] as? String)?.lowercased() == "host",
              let command = object["command"] as? String,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        let goal = action.userGoal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !goal.isEmpty else { return false }
        let denials = [
            "不要执行", "别执行", "不要安装", "别安装", "不要修改", "别修改",
            "do not execute", "don't execute", "do not install", "do not modify"
        ]
        guard !denials.contains(where: goal.contains) else { return false }
        return [
            "安装", "部署", "配置", "准备环境", "搭建环境", "修复环境", "更新环境",
            "换源", "软件源", "依赖", "清理锁", "清理目录", "vnc", "docker",
            "install", "deploy", "configure", "prepare", "set up", "setup",
            "repair", "upgrade", "update", "package source", "dependency"
        ].contains(where: goal.contains)
    }

    /// Automatic routing can resolve to a real macOS or Windows host, so it
    /// is exempt only for a small shell-free diagnostic vocabulary. Mutating
    /// setup work must explicitly select the disposable container mode.
    private static func isClearlyReadOnlySSHDiagnostic(_ command: String) -> Bool {
        let normalized = command
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return false }
        let forbidden = [";", "|", ">", "<", "`", "$(", "${", "\n", "\r"]
        guard !forbidden.contains(where: normalized.contains) else { return false }
        guard !normalized.replacingOccurrences(of: "&&", with: "").contains("&") else {
            return false
        }
        let clauses = normalized.components(separatedBy: "&&")
        let allowedPrefixes = [
            "pwd", "id", "whoami", "uname", "uptime", "date", "arch",
            "printf ", "echo ", "command -v ", "which ", "type ",
            "ls", "stat ", "df", "du ", "free", "vm_stat",
            "sw_vers", "systeminfo", "ver", "docker --version",
            "podman --version", "python --version", "python3 --version",
            "node --version", "git --version"
        ]
        return clauses.allSatisfy { clause in
            let value = clause.trimmingCharacters(in: .whitespacesAndNewlines)
            return allowedPrefixes.contains(where: { value == $0 || value.hasPrefix($0) })
        }
    }

    private func deterministicDecision(
        for action: ProposedAction,
        unavailableReason: String
    ) -> ApprovalDecision {
        let risks = action.riskLabels
        let requiresReview: Set<String> = [
            "deletesFiles",
            "accessesCredentials",
            "modifiesRemoteSystem",
            "executesLocalCode",
            "persistsPersonalData",
            "changesAgentBehavior",
            "controlsGUI",
            "sendsDataToProvider",
            "executesRemoteCommand"
        ]
        if !risks.isDisjoint(with: requiresReview), action.toolCall.toolName != "exec.localPython" {
            return .escalateToHuman(reason: unavailableReason)
        }
        return .allow(
            scope: Self.scope(for: action.toolCall),
            expiresAt: nil
        )
    }

    private static func scope(for call: ToolCall) -> ApprovalScope {
        switch call.scope {
        case .local:
            ApprovalScope(toolName: call.toolName, singleUse: true)
        case .host(let hostID):
            ApprovalScope(toolName: call.toolName, hostID: hostID, singleUse: true)
        case .hostPath(let hostID, let path):
            ApprovalScope(
                toolName: call.toolName,
                hostID: hostID,
                paths: [path],
                singleUse: true
            )
        }
    }
}

/// Per-task full access removes ordinary prompts for this task. The
/// catastrophic command gate still runs before this policy, and managed
/// Python package requests still receive their dedicated source review.
public struct TaskFullAccessPolicy: ApprovalPolicy {
    public let policyName = "full-access"

    private let packageReviewBackend: (any ModelApprovalPolicy.DecisionBackend)?

    public init(packageReviewBackend: (any ModelApprovalPolicy.DecisionBackend)? = nil) {
        self.packageReviewBackend = packageReviewBackend
    }

    public func decide(_ action: ProposedAction) async throws -> ApprovalDecision {
        if action.isManagedPythonPackageRequest {
            guard let packageReviewBackend else {
                return .escalateToHuman(reason: "No software package review model is configured")
            }
            do { return try await packageReviewBackend.decide(action) }
            catch {
                return .escalateToHuman(reason: "Software package review failed: \(error.localizedDescription)")
            }
        }

        return .allow(
            scope: AutomaticApprovalPolicyScope.scope(for: action.toolCall),
            expiresAt: nil
        )
    }
}

private extension ProposedAction {
    var argumentObject: [String: Any]? {
        try? JSONSerialization.jsonObject(with: toolCall.argumentsJSON) as? [String: Any]
    }

    var isManagedPythonPackageRequest: Bool {
        guard toolCall.toolName == "exec.localPython",
              let object = try? JSONSerialization.jsonObject(with: toolCall.argumentsJSON) as? [String: Any]
        else { return false }
        if let packages = object["packages"] as? [Any], !packages.isEmpty { return true }
        return !((try? ManagedPythonPackageSpecParser.parse(
            command: object["pipCommand"] as? String
        )) ?? []).isEmpty
    }
}

private enum AutomaticApprovalPolicyScope {
    static func scope(for call: ToolCall) -> ApprovalScope {
        switch call.scope {
        case .local:
            ApprovalScope(toolName: call.toolName, singleUse: true)
        case .host(let hostID):
            ApprovalScope(toolName: call.toolName, hostID: hostID, singleUse: true)
        case .hostPath(let hostID, let path):
            ApprovalScope(toolName: call.toolName, hostID: hostID, paths: [path], singleUse: true)
        }
    }
}

/// Policy 3: full control for one host within a time window.
/// Enabling requires Face ID or passcode plus a risk acknowledgement
/// (handled by the UI layer before constructing the grant).
public struct FullControlPolicy: ApprovalPolicy {
    public let policyName = "full-control"

    public struct Grant: Sendable, Codable, Hashable {
        public var hostID: UUID
        public var expiresAt: Date?

        public init(hostID: UUID, expiresAt: Date?) {
            self.hostID = hostID
            self.expiresAt = expiresAt
        }

        public func isActive(at now: Date = Date()) -> Bool {
            guard let expiresAt else { return true } // until connection closes
            return now < expiresAt
        }
    }

    private let grant: Grant

    public init(grant: Grant) {
        self.grant = grant
    }

    public func decide(_ action: ProposedAction) async throws -> ApprovalDecision {
        guard grant.isActive() else {
            return .escalateToHuman(reason: "Full-control window expired")
        }
        switch action.hostAndPathScope {
        case .host(let id) where id == grant.hostID,
             .hostPath(let id, _) where id == grant.hostID:
            return .allow(
                scope: ApprovalScope(
                    toolName: action.toolCall.toolName,
                    hostID: grant.hostID,
                    singleUse: true
                ),
                expiresAt: grant.expiresAt
            )
        case .host, .hostPath:
            return .escalateToHuman(reason: "Action targets a host outside the full-control grant")
        case .local:
            // Local non-destructive actions still flow; the gate already ran.
            return .allow(
                scope: ApprovalScope(toolName: action.toolCall.toolName, singleUse: true),
                expiresAt: grant.expiresAt
            )
        }
    }
}
