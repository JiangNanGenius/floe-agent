// FloeSkills — skill.install agent tool.
//
// Installs a COMPLETE package directory the task already produced in its own
// workspace. The tool owns only the deterministic boundary: argument/digest
// contract, task-workspace ownership, planner validation and the bounded
// receipt. The injected `SkillWorkspaceInstalling` bridge performs the real
// commit through the App's existing reviewed install transaction; this tool
// never copies bytes itself, executes a script, starts an interpreter or
// grants a capability.
//
// The SAME tool also accepts `source="hub"` for the signed curated catalog:
// an injected `SkillHubInstalling` bridge performs the verified download and
// the existing grant-delta install transaction and returns a TYPED receipt.
// The two branches are strictly discriminated (workspace directory
// vocabulary cannot mix with Hub id vocabulary), the temporary-chat /
// approval / cancellation gates are identical, and an absent Hub bridge fails
// honestly as not-configured: there is never a fallback to the workspace
// branch or a host interpreter. No new permission grant lives here.

import Foundation
import FloeCore
import FloeTools

/// App-side commit boundary. The implementation must stage a private,
/// independent copy of the plan's bytes, re-validate it, and only then apply
/// the existing install transaction. It returns what persistence actually
/// committed so the tool can verify it against the reviewed plan.
public protocol SkillWorkspaceInstalling: Sendable {
    func install(_ plan: SkillWorkspaceInstallPlan) async throws -> SkillWorkspaceInstallCommit
}

public struct SkillWorkspaceInstallTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        /// Explicit source. Omitted means the legacy `.workspace` directory
        /// branch, so every existing call keeps working byte-for-byte.
        public var source: SkillInstallSource?
        public var directory: String?
        public var mode: SkillWorkspaceInstallMode?
        public var expectedDigest: String?
        /// Hub branch: exact catalog id (validated with the existing
        /// `SkillIdentifier` grammar). Never accepted by the workspace branch.
        public var id: String?
        /// Hub branch: optional frozen 40-hex publication pin Y. When the
        /// injected adapter requires an explicit pin it refuses without one;
        /// otherwise it resolves the pinned ref itself and the receipt carries
        /// the pin that was ACTUALLY used.
        public var publicationCommit: String?

        public init(
            source: SkillInstallSource? = nil,
            directory: String? = nil,
            mode: SkillWorkspaceInstallMode? = nil,
            expectedDigest: String? = nil,
            id: String? = nil,
            publicationCommit: String? = nil
        ) {
            self.source = source
            self.directory = directory
            self.mode = mode
            self.expectedDigest = expectedDigest
            self.id = id
            self.publicationCommit = publicationCommit
        }

        /// Legacy memberwise form kept so every existing constructor call and
        /// test compiles unchanged: a bare `directory` is the workspace branch.
        public init(
            directory: String,
            mode: SkillWorkspaceInstallMode? = nil,
            expectedDigest: String? = nil
        ) {
            self.init(source: nil, directory: directory, mode: mode, expectedDigest: expectedDigest)
        }
    }

    public static let name = "skill.install"
    public static let toolDescription =
        "Install a complete skill package from a directory in this task's workspace (the folder exported to the Linux task environment as /workspace). The directory must contain SKILL.md; floe.json is optional. Every byte of scripts/, references/, assets/, agents/ and license files is installed as-is: nothing is executed and no permission is granted beyond the package's declared capabilities, which follow the normal install review. mode=install refuses an existing skill. To replace a workspace-imported skill, use mode=replace with expectedDigest (currentDigest from skill.read or digest from skill.list); built-in, official and locally created skills cannot be replaced here. With source=\"hub\" plus the exact catalog id (optionally publicationCommit, the 40-hex pinned publication Y to fetch at), install one verified curated-catalog entry instead: the App fetches every artifact at Y, verifies the signed catalog, review record and package digests, applies the existing grant-delta approval, and returns a typed receipt with the actual installed version and the separate catalog/source digests. The two sources are exclusive: directory/mode/expectedDigest belong only to the workspace branch, id/publicationCommit only to the hub branch; a hub install still requires approval, is unavailable in a temporary chat, never overrides a user's disabled/uninstalled/locally-edited skill, and never runs a package script."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "source": {"type": "string", "enum": ["workspace", "hub"], "description": "workspace (default): install from this task's workspace directory; hub: install one verified curated catalog entry"},
        "directory": {"type": "string", "description": "workspace branch (required there): workspace-relative directory of the complete package, e.g. skills/my-skill"},
        "mode": {"type": "string", "enum": ["install", "replace"], "description": "workspace branch only: install (default) or replace an existing workspace-imported skill"},
        "expectedDigest": {"type": "string", "description": "workspace branch, mode=replace only: canonical SHA-256 of the currently installed revision"},
        "id": {"type": "string", "description": "hub branch (required there): exact curated catalog skill id"},
        "publicationCommit": {"type": "string", "minLength": 40, "maxLength": 40, "description": "hub branch (optional): frozen 40-hex publication commit Y to fetch and verify at"}
      },
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.writesFiles, .changesAgentBehavior]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    private let installer: any SkillWorkspaceInstalling
    private let hub: (any SkillHubInstalling)?

    public init(installer: any SkillWorkspaceInstalling, hub: (any SkillHubInstalling)? = nil) {
        self.installer = installer
        self.hub = hub
    }

    public func validate(_ args: Arguments) throws {
        switch args.source ?? .workspace {
        case .workspace:
            guard args.id == nil, args.publicationCommit == nil else {
                throw SkillHubValidationError.unexpectedHubParameter("id/publicationCommit")
            }
            _ = try Self.request(args)
        case .hub:
            guard args.directory == nil, args.mode == nil, args.expectedDigest == nil else {
                throw SkillHubValidationError.unexpectedWorkspaceParameter("directory/mode/expectedDigest")
            }
            _ = try Self.hubRequest(args)
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args)
        try context.cancellation.throwIfCancelled()
        guard !context.temporaryReadOnly else {
            throw FloeError.validationFailed("Skill installation is unavailable in a temporary chat")
        }
        guard context.approvalGrantID != nil else {
            throw FloeError.validationFailed("Skill installation requires approval")
        }
        if args.source ?? .workspace == .hub {
            return try await executeHub(args, context: context)
        }
        guard let workspaceRoot = context.workspaceRootURL else {
            throw SkillWorkspaceInstallError.workspaceUnavailable
        }
        let request = try Self.request(args)
        // The persisted task file scope is checked before any package read, so
        // a narrowed task can never install from a directory it cannot see.
        try context.authorizeWorkspacePath(request.directory)

        let plan: SkillWorkspaceInstallPlan
        let commit: SkillWorkspaceInstallCommit
        do {
            plan = try SkillWorkspaceInstallPlanner.plan(request, in: workspaceRoot)
            try context.cancellation.throwIfCancelled()
            commit = try await installer.install(plan)
        } catch {
            if Self.isCancellation(error, context: context) { throw FloeError.cancelled }
            let text = "status=failed error=\(Self.failureText(error))"
            return ToolExecutionOutput(digesting: text, exitStatus: 1)
        }
        // Once the transaction committed, a later cancellation must not be
        // reported as "nothing installed": the receipt states what really
        // landed, so a retry cannot silently duplicate the install.
        // A bridge that returns a different identity/version/digest (or an
        // unproven previous revision) is an integrity failure, not a result
        // the model may treat as installed.
        let receipt = try SkillWorkspaceInstallReceipt(plan: plan, commit: commit)
        return ToolExecutionOutput(digesting: Self.summary(for: receipt), exitStatus: 0)
    }

    /// Hub branch. No workspace root is required: the catalog install is
    /// global and the current App service owns the bytes. The injected bridge
    /// performs the real verified download and the existing install
    /// transaction; this tool verifies the TYPED receipt against the exact
    /// requested id and (when pinned) the exact requested publication commit.
    /// The bridge receives THIS call's actual runtime-issued context (real
    /// run/conversation/approval identity and the live cancellation token),
    /// so durable staging and same-run refusal dedupe bind to trusted
    /// identity, never to model-supplied values. A malformed or
    /// identity-mismatched receipt is an integrity failure and is thrown,
    /// never surfaced as a retryable "failed" result.
    private func executeHub(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        guard let hub else {
            throw SkillHubInstallError.notConfigured
        }
        let request = try Self.hubRequest(args)
        let receipt: SkillHubInstallReceipt
        do {
            receipt = try await hub.install(request, context: context)
        } catch {
            // Fixed-vocabulary Hub install outcomes are classified BEFORE the
            // generic mapping, because they are not ordinary retryable
            // failures:
            // - reviewRequired: the existing combined approval flow still owes
            //   a delta. Answer honestly with a pending-review action state
            //   (Main's existing PendingInstallation UI consumes it). NOTHING
            //   was committed, so no receipt fields and no success exit status
            //   may appear.
            // - reviewDeclined / userChoiceBlocked: terminal user decisions.
            //   Non-retryable messages; never a directory fallback.
            // - notConfigured: wiring absent; thrown, never disguised as a
            //   retryable package failure.
            if let hubError = error as? SkillHubInstallError {
                switch hubError {
                case .notConfigured:
                    throw hubError
                case .reviewRequired:
                    let text = """
                    status=pending-review id=\(request.id)
                    note=Installation is waiting on the existing combined approval flow for a real permission/review delta. Nothing was installed yet; the review card is being shown to the user. Do not retry this call from the tool and do not fall back to a workspace install.
                    """
                    return ToolExecutionOutput(digesting: text, exitStatus: nil, requiresUserAction: true)
                case .reviewDeclined:
                    let text = """
                    status=review-declined id=\(request.id)
                    note=The user declined the required review for this skill. This decision is final for the current run and is not retryable from the tool; a later install requires a new explicit user request. Do not attempt a workspace-directory install as a substitute.
                    """
                    return ToolExecutionOutput(digesting: text, exitStatus: 1)
                case .userChoiceBlocked:
                    let text = """
                    status=user-choice-blocked id=\(request.id)
                    note=An explicit user choice (disabled, uninstalled or locally edited skill) prevents this install; the user's choice wins. This is not retryable from the tool. Do not attempt a workspace-directory install as a substitute.
                    """
                    return ToolExecutionOutput(digesting: text, exitStatus: 1)
                }
            }
            if Self.isCancellation(error, context: context) { throw FloeError.cancelled }
            let text = "status=failed error=\(Self.failureText(error))"
            return ToolExecutionOutput(digesting: text, exitStatus: 1)
        }
        // Receipt verification happens AFTER the await: a cancellation that
        // arrives once the transaction already committed must still report
        // the committed receipt, never "nothing installed".
        let verified = try receipt.verified(against: request)
        return ToolExecutionOutput(digesting: Self.hubSummary(for: verified), exitStatus: 0)
    }

    private static func request(_ args: Arguments) throws -> SkillWorkspaceInstallRequest {
        guard let directory = args.directory else {
            throw SkillWorkspaceInstallError.invalidDirectory("directory is required for a workspace install; source=hub installs use id instead")
        }
        return try SkillWorkspaceInstallRequest(
            directory: directory,
            mode: args.mode ?? .install,
            expectedDigest: args.expectedDigest
        )
    }

    private static func hubRequest(_ args: Arguments) throws -> SkillHubInstallRequest {
        guard let id = args.id else { throw SkillHubValidationError.hubIdRequired }
        return try SkillHubInstallRequest(id: id, publicationCommit: args.publicationCommit)
    }

    private static func isCancellation(_ error: any Error, context: ToolContext) -> Bool {
        if context.cancellation.isCancelled || Task.isCancelled { return true }
        if error is CancellationError { return true }
        if let floe = error as? FloeError, case .cancelled = floe { return true }
        return false
    }

    /// Package/install failures stay a normal failed tool result so the model
    /// can correct the directory or digest. Only vocabulary with a
    /// path-safety contract is echoed; an unexpected Cocoa/IO error is
    /// reported generically instead of leaking a host temporary path.
    static func failureText(_ error: any Error) -> String {
        if let error = error as? SkillValidationError {
            if case .unsafePath = error { return "The package contains an unsafe path" }
            return bounded(error.localizedDescription)
        }
        if let error = error as? SkillHubCatalogError {
            return bounded(error.localizedDescription)
        }
        if let error = error as? SkillHubValidationError {
            return bounded(error.localizedDescription)
        }
        if let error = error as? SkillHubInstallError {
            return bounded(error.localizedDescription)
        }
        if let error = error as? SkillWorkspaceInstallError {
            return bounded(error.localizedDescription)
        }
        if let error = error as? SkillInstallError {
            return bounded(error.localizedDescription)
        }
        if let error = error as? FloeError {
            return bounded(error.localizedDescription)
        }
        return "The skill package could not be installed; check the directory contents and retry"
    }

    private static func bounded(_ text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(collapsed.prefix(600))
    }

    /// Bounded receipt text: identity, honest source/directory, declarations,
    /// the actual inventory as far as it fits, and any omitted entry count.
    /// No host path and no per-file digest.
    static func summary(for receipt: SkillWorkspaceInstallReceipt) -> String {
        var lines: [String] = [
            "status=\(receipt.status) id=\(receipt.skillID) version=\(receipt.version) "
                + "digest=\(receipt.canonicalSHA256) files=\(receipt.fileCount) "
                + "bytes=\(receipt.totalBytes) mode=\(receipt.mode.rawValue)",
            "directory=\(receipt.directory)",
            "source=\(receipt.source)",
            "declarations capabilities=\(list(receipt.declaredCapabilities)) "
                + "tools=\(list(receipt.toolNames)) runtime=\(receipt.scriptRuntime) "
                + "pythonPackages=\(receipt.pythonPackageSpecs.count) "
                + "packagedManifest=\(receipt.hasPackagedManifest)"
        ]
        if let previousDigest = receipt.previousDigest {
            lines.append("previousDigest=\(previousDigest)")
        }
        if !receipt.pythonPackageSpecs.isEmpty {
            // Exact name==version requirements are part of the declaration
            // state; the list is bounded so the inventory note always fits.
            let shown = receipt.pythonPackageSpecs.prefix(8).map { String($0.prefix(80)) }
            let omitted = receipt.pythonPackageSpecs.count - shown.count
            lines.append(
                "pythonPackageSpecs=" + shown.joined(separator: ",")
                    + (omitted > 0 ? ",+\(omitted) more" : "")
            )
        }
        let base = lines.joined(separator: "\n")
        var shown: [String] = []
        for path in receipt.inventory {
            let candidate = shown + [path]
            let inventoryLine = "inventory=" + candidate.joined(separator: ",")
            if base.count + 1 + inventoryLine.count > 3_600 { break }
            shown = candidate
        }
        var inventoryLine = "inventory=" + (shown.isEmpty ? "(none)" : shown.joined(separator: ","))
        let omitted = receipt.omittedFileCount + (receipt.inventory.count - shown.count)
        if omitted > 0 { inventoryLine += "\ninventoryOmitted=\(omitted)" }
        lines.append(inventoryLine)
        lines.append(
            "note=No package script was executed. Installed under the existing skill permission review; "
                + "the installed copy is independent of the task workspace."
        )
        return lines.joined(separator: "\n")
    }

    private static func list(_ values: [String]) -> String {
        values.isEmpty ? "(none)" : values.joined(separator: ",")
    }

    /// Bounded Hub install receipt: the ACTUAL committed identity plus the
    /// separate catalog provenance — retrieval pin Y, audited source X,
    /// catalog/content/review digests. No host path, no per-file digest, no
    /// instruction-activation claim.
    static func hubSummary(for receipt: SkillHubInstallReceipt) -> String {
        var lines: [String] = [
            "status=\(receipt.status.rawValue) id=\(receipt.skillID) version=\(receipt.version) "
                + "contentDigest=\(receipt.contentDigest) packageSHA256=\(receipt.packageSHA256) "
                + "files=\(receipt.fileCount) bytes=\(receipt.totalBytes) scripts=\(receipt.containsScripts)",
            "catalogDigest=\(receipt.catalogDigest) reviewDigest=\(receipt.reviewDigest)",
            "publicationCommit=\(receipt.publicationCommit) sourceCommit=\(receipt.sourceCommit ?? "(none)")",
            "reviewed capabilities=\(list(receipt.reviewedCapabilities)) tools=\(list(receipt.reviewedTools))"
        ]
        lines.append(
            "note=Installed through the curated Hub verified catalog/review/digest chain under the existing "
                + "approval and grant-delta flow. No package script was executed; the installed copy is "
                + "independent of this task workspace and a user-disabled or locally edited skill was not overridden."
        )
        let text = lines.joined(separator: "\n")
        return String(text.prefix(4_096))
    }
}
