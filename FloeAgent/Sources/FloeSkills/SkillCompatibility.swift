import Foundation
import FloeTools

public struct SkillRuntimeEnvironment: Sendable {
    public var platform: SkillPlatform
    public var supportedCapabilities: Set<SkillCapability>
    public var registeredTools: Set<String>
    public var supportsJavaScriptCore: Bool
    public var hasRemoteExecutionHost: Bool

    public init(
        platform: SkillPlatform,
        supportedCapabilities: Set<SkillCapability>,
        registeredTools: Set<String>,
        supportsJavaScriptCore: Bool,
        hasRemoteExecutionHost: Bool
    ) {
        self.platform = platform
        self.supportedCapabilities = supportedCapabilities
        self.registeredTools = registeredTools
        self.supportsJavaScriptCore = supportsJavaScriptCore
        self.hasRemoteExecutionHost = hasRemoteExecutionHost
    }
}

public enum SkillCompatibilityProblem: Equatable, Sendable {
    case unsupportedPlatform(SkillPlatform)
    case unavailableCapability(SkillCapability)
    case unavailableTool(String)
    case javaScriptCoreUnavailable
    case remoteHostRequired
}

public struct SkillCompatibilityReport: Sendable {
    public var problems: [SkillCompatibilityProblem]
    public var isRunnable: Bool { problems.isEmpty }

    public init(problems: [SkillCompatibilityProblem]) {
        self.problems = problems
    }
}

public enum SkillCompatibility {
    public static func evaluate(
        _ package: ValidatedSkillPackage,
        in environment: SkillRuntimeEnvironment
    ) -> SkillCompatibilityReport {
        var problems: [SkillCompatibilityProblem] = []
        if !package.supportedPlatforms.contains(environment.platform) {
            problems.append(.unsupportedPlatform(environment.platform))
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
        case .remote where !environment.hasRemoteExecutionHost:
            problems.append(.remoteHostRequired)
        default:
            break
        }
        return SkillCompatibilityReport(problems: problems)
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
