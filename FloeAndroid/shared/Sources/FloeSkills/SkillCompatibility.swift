import Foundation
import FloeTools

public struct SkillRuntimeEnvironment: Sendable {
    public var platform: SkillPlatform
    public var supportedCapabilities: Set<SkillCapability>
    public var registeredTools: Set<String>
    public var supportsJavaScriptCore: Bool
    public var hasRemoteExecutionHost: Bool
    /// True only when a task Linux runtime is ACTUALLY selected and
    /// qualified for this client generation. It is never inferred from the
    /// Android host itself and never grants execution. Script-carrying
    /// packages that rely on the Linux runtime stay incompatible while this
    /// is false; guide-only packages remain readable.
    public var hasQualifiedTaskLinuxRuntime: Bool

    public init(
        platform: SkillPlatform,
        supportedCapabilities: Set<SkillCapability>,
        registeredTools: Set<String>,
        supportsJavaScriptCore: Bool,
        hasRemoteExecutionHost: Bool,
        hasQualifiedTaskLinuxRuntime: Bool = false
    ) {
        self.platform = platform
        self.supportedCapabilities = supportedCapabilities
        self.registeredTools = registeredTools
        self.supportsJavaScriptCore = supportsJavaScriptCore
        self.hasRemoteExecutionHost = hasRemoteExecutionHost
        self.hasQualifiedTaskLinuxRuntime = hasQualifiedTaskLinuxRuntime
    }
}

public enum SkillCompatibilityProblem: Equatable, Sendable {
    case unsupportedPlatform(SkillPlatform)
    case unavailableCapability(SkillCapability)
    case unavailableTool(String)
    case javaScriptCoreUnavailable
    case localPythonUnavailable
    case remoteHostRequired
    /// The package needs the Linux runtime and no selected/qualified task
    /// Linux environment exists in this generation.
    case linuxRuntimeUnavailable
}

public struct SkillCompatibilityReport: Sendable {
    public var problems: [SkillCompatibilityProblem]
    /// Problems that gate EXECUTION in a task, but not installation. The
    /// package can be installed and inspected; a run refuses until the
    /// selected task runtime is actually ready.
    public var runtimeProblems: [SkillCompatibilityProblem]
    public var isRunnable: Bool { problems.isEmpty }
    public var isRuntimeReady: Bool { runtimeProblems.isEmpty }

    public init(problems: [SkillCompatibilityProblem],
                runtimeProblems: [SkillCompatibilityProblem] = []) {
        self.problems = problems
        self.runtimeProblems = runtimeProblems
    }
}

public enum SkillCompatibility {
    public static func evaluate(
        _ package: ValidatedSkillPackage,
        in environment: SkillRuntimeEnvironment
    ) -> SkillCompatibilityReport {
        var problems: [SkillCompatibilityProblem] = []
        // Platform identity is the HOST/store OS. The Android host provides
        // the task Linux runtime, so a package that explicitly declares
        // `linux` is not misrepresented as iOS: it is compatible with this
        // host only through that Linux runtime. Packages declaring only
        // `ios` are never widened.
        let platformSatisfied: Bool
        switch environment.platform {
        case .android:
            platformSatisfied = package.supportedPlatforms.contains(.android)
                || package.supportedPlatforms.contains(.linux)
        default:
            platformSatisfied = package.supportedPlatforms.contains(environment.platform)
        }
        if !platformSatisfied {
            problems.append(.unsupportedPlatform(environment.platform))
        }
        // A declared Linux execution path requires the ACTUAL selected and
        // qualified task runtime before a task may execute the package.
        // Guide-only packages carry no runtime claim, so their instructions
        // stay readable without one. Installation is not blocked here: the
        // owned package can exist while the user has not selected a task
        // environment yet; the execution boundary checks `runtimeProblems`.
        var runtimeProblems: [SkillCompatibilityProblem] = []
        if environment.platform == .android,
           package.manifest.scriptRuntime != .none,
           !environment.hasQualifiedTaskLinuxRuntime {
            runtimeProblems.append(.linuxRuntimeUnavailable)
        }
        for capability in package.declaredCapabilities.sorted(by: { $0.rawValue < $1.rawValue })
        where !environment.supportedCapabilities.contains(capability) {
            problems.append(.unavailableCapability(capability))
        }
        for tool in package.manifest.tools.sorted() where !environment.registeredTools.contains(tool) {
            problems.append(.unavailableTool(tool))
        }
        switch package.manifest.scriptRuntime {
        case .none:
            break
        case .javaScriptCore where !environment.supportsJavaScriptCore:
            problems.append(.javaScriptCoreUnavailable)
        case .localPython where !environment.supportedCapabilities.contains(.localPython) || !environment.registeredTools.contains("exec.localPython"):
            problems.append(.localPythonUnavailable)
        case .remote where !environment.registeredTools.contains("exec.shell") && !environment.hasRemoteExecutionHost:
            problems.append(.remoteHostRequired)
        default:
            break
        }
        return SkillCompatibilityReport(problems: problems, runtimeProblems: runtimeProblems)
    }
}

public struct SkillToolRequirement: Sendable {
    public var capabilities: Set<SkillCapability>

    public init(capabilities: Set<SkillCapability>) {
        self.capabilities = capabilities
    }
}

public struct SkillToolAuthorization: Sendable {
    public let skillID: String
    public let effectiveCapabilities: Set<SkillCapability>
    public let allowedToolNames: Set<String>

    public init(
        package: ValidatedSkillPackage,
        deviceCapabilities: Set<SkillCapability>,
        grantedCapabilities: Set<SkillCapability>,
        descriptors: [ToolCatalog.Descriptor],
        requirements: [String: SkillToolRequirement]
    ) {
        skillID = package.manifest.id
        let effective = package.declaredCapabilities
            .intersection(deviceCapabilities)
            .intersection(grantedCapabilities)
        effectiveCapabilities = effective
        let registered = Dictionary(
            descriptors.map { ($0.name, $0) },
            uniquingKeysWith: { _, newest in newest }
        )
        allowedToolNames = Set(package.manifest.tools.filter { name in
            guard let descriptor = registered[name], let requirement = requirements[name] else { return false }
            guard requirement.capabilities.isSubset(of: effective) else { return false }
            // A side-effecting tool must never be authorized by an empty capability declaration.
            return !descriptor.isSideEffecting || !requirement.capabilities.isEmpty
        })
    }

    /// Execution-side check. Call immediately before runner lookup; provider
    /// schema filtering alone is not an authorization boundary.
    public func authorize(toolName: String) throws {
        guard allowedToolNames.contains(toolName) else {
            throw SkillToolAuthorizationError.denied(skillID: skillID, toolName: toolName)
        }
    }
}

public enum SkillToolAuthorizationError: Error, Equatable, Sendable, LocalizedError {
    case denied(skillID: String, toolName: String)

    public var errorDescription: String? {
        switch self {
        case .denied(let skillID, let toolName):
            "Skill '\(skillID)' is not authorized to use tool '\(toolName)'"
        }
    }
}

public enum SkillAutomaticInstallPolicy {
    /// Only instruction-only or workspace-read-only packages without scripts
    /// can bypass the explicit installation confirmation sheet.
    public static func mayInstallWithoutConfirmation(
        _ package: ValidatedSkillPackage,
        descriptors: [ToolCatalog.Descriptor]
    ) -> Bool {
        guard !package.containsScripts,
              package.declaredCapabilities.isSubset(of: [.workspaceRead])
        else { return false }
        let lookup = Dictionary(
            descriptors.map { ($0.name, $0) },
            uniquingKeysWith: { _, newest in newest }
        )
        return package.manifest.tools.allSatisfy { name in
            guard let descriptor = lookup[name] else { return false }
            return !descriptor.isSideEffecting && descriptor.riskLabels.isSubset(of: [.readsFiles])
        }
    }
}
