import Foundation
import FloeCore
import FloeTools

/// Native configuration for one explicit Skill invocation. It is never
/// decoded from tool arguments or copied into ToolEnvironment/global env.
public struct SkillProcessConfiguration: Sendable, CustomStringConvertible,
                                         CustomDebugStringConvertible {
    public let environment: [String: String]
    public let sensitiveEnvironment: SensitiveProcessEnvironment?
    public let configuredEnvironmentNames: Set<String>
    private let authorization: @Sendable () async throws -> Void
    private let outputProjection: @Sendable (String) -> String

    public init(
        environment: [String: String],
        sensitiveEnvironment: SensitiveProcessEnvironment?,
        configuredEnvironmentNames: Set<String>,
        revalidate: @escaping @Sendable () async throws -> Void,
        sanitizeOutput: @escaping @Sendable (String) -> String
    ) {
        self.environment = environment
        self.sensitiveEnvironment = sensitiveEnvironment
        self.configuredEnvironmentNames = configuredEnvironmentNames
        self.authorization = revalidate
        self.outputProjection = sanitizeOutput
    }

    public var description: String { "SkillProcessConfiguration(redacted)" }
    public var debugDescription: String { description }

    public func validateOverrides(_ overrides: [String: String]) throws {
        guard configuredEnvironmentNames.isDisjoint(with: Set(overrides.keys)) else {
            throw FloeError.validationFailed(
                "A configured Skill variable cannot be overridden through env. Update it with skill.config first."
            )
        }
    }

    public func revalidate() async throws { try await authorization() }

    public func sanitizeOutput(_ text: String) -> String { outputProjection(text) }

    /// Applied before a result reaches tool history, jobs or receipts.
    public func sanitize(_ outcome: ShellRunOutcome) -> ShellRunOutcome {
        switch outcome {
        case .exited(let code, let stdout, let stderr, let truncated, let stderrTruncated, let duration):
            return .exited(code: code, stdout: outputProjection(stdout), stderr: outputProjection(stderr),
                           truncated: truncated, stderrTruncated: stderrTruncated, durationMs: duration)
        case .timedOut(let stdout, let stderr, let duration):
            return .timedOut(partialStdout: outputProjection(stdout), partialStderr: outputProjection(stderr), durationMs: duration)
        case .notStarted(let reason): return .notStarted(reason: outputProjection(reason))
        case .outcomeUnknown(let id, let message): return .outcomeUnknown(jobID: id, message: outputProjection(message))
        case .failed(let message): return .failed(message: outputProjection(message))
        case .cancelled: return .cancelled
        }
    }
}

/// Implemented by the App using the exact installed revision, task grant,
/// current execution lease and scoped credential service. skillID selects a
/// candidate; it is not authority. Unscoped ordinary commands call no resolver.
public protocol SkillProcessConfigurationProviding: Sendable {
    func processConfiguration(skillID: String, context: ToolContext) async throws -> SkillProcessConfiguration
}
