// FloeExecution — Local shell service.
// Wraps the injected backend with Floe's deterministic policy, output
// sanitation, journaling and explicit limits. The service never invokes a
// backend for a blocked command and never fabricates an outcome.

import Foundation
import FloeCore
import FloeTools

public actor LocalShellService {
    public struct Configuration: Sendable {
        public var defaultTimeout: TimeInterval
        public var maxTimeout: TimeInterval
        public var backgroundTimeout: TimeInterval
        public var defaultMaxOutputBytes: Int
        public var maxOutputBytes: Int
        public var maximumStdinBytes: Int
        public var maximumCommandBytes: Int

        public init(
            defaultTimeout: TimeInterval = 10,
            maxTimeout: TimeInterval = 120,
            backgroundTimeout: TimeInterval = 600,
            defaultMaxOutputBytes: Int = 64 * 1024,
            maxOutputBytes: Int = 256 * 1024,
            maximumStdinBytes: Int = 256 * 1024,
            maximumCommandBytes: Int = 16 * 1024
        ) {
            self.defaultTimeout = defaultTimeout
            self.maxTimeout = maxTimeout
            self.backgroundTimeout = backgroundTimeout
            self.defaultMaxOutputBytes = defaultMaxOutputBytes
            self.maxOutputBytes = maxOutputBytes
            self.maximumStdinBytes = maximumStdinBytes
            self.maximumCommandBytes = maximumCommandBytes
        }
    }

    public enum RunResult: Sendable {
        case blocked(ShellCommandPolicy.Verdict)
        case outcome(ShellRunOutcome)
    }

    public nonisolated let policy: ShellCommandPolicy
    public nonisolated var backendDescription: String { String(describing: type(of: backend)) }

    private let backend: any LocalShellBackend
    private let journal: ShellOperationJournal
    private let configuration: Configuration
    private let environmentDefaults: [String: String]
    private let rootProvider: @Sendable () async -> URL?

    public init(
        backend: any LocalShellBackend,
        policy: ShellCommandPolicy = ShellCommandPolicy(),
        journal: ShellOperationJournal = ShellOperationJournal(),
        configuration: Configuration = Configuration(),
        environmentDefaults: [String: String] = [:],
        rootProvider: @escaping @Sendable () async -> URL?
    ) {
        self.backend = backend
        self.policy = policy
        self.journal = journal
        self.configuration = configuration
        self.environmentDefaults = environmentDefaults
        self.rootProvider = rootProvider
    }

    /// Clamps requested limits to the compiled ceilings. Exposed for tests.
    public nonisolated func normalizedTimeout(_ requested: TimeInterval?, isBackground: Bool) -> TimeInterval {
        let ceiling = isBackground ? configuration.backgroundTimeout : configuration.maxTimeout
        let value = requested.flatMap { $0.isFinite ? $0 : nil } ?? configuration.defaultTimeout
        return max(0.05, min(value, ceiling))
    }

    public nonisolated func normalizedOutputCap(_ requested: Int?) -> Int {
        let value = requested ?? configuration.defaultMaxOutputBytes
        return max(1, min(value, configuration.maxOutputBytes))
    }

    public func run(
        command: String,
        cwd: String,
        environment: [String: String],
        stdin: String?,
        timeout: TimeInterval?,
        maxOutputBytes: Int?,
        isBackground: Bool,
        context: ToolContext
    ) async -> RunResult {
        do {
            try ShellInputValidation.validate(command: command, cwd: cwd, environment: environment, stdin: stdin)
            try context.cancellation.throwIfCancelled()
        } catch { return .outcome(.failed(message: String(describing: error))) }
        let verdict = policy.evaluate(command)
        guard !verdict.stopped else {
            await journal.record(ShellOperationJournal.Entry(
                runID: context.runID.uuidString,
                toolCallID: context.toolCallID,
                sessionID: context.toolCallID ?? context.runID.uuidString,
                commandSHA256: FloeDigest.sha256Hex(Data(command.utf8)),
                cwd: cwd,
                exitCode: 126,
                stdoutBytes: 0,
                stderrBytes: 0,
                truncated: false,
                durationMs: 0,
                outcome: "blocked:\(verdict.matchedPatternID ?? "policy")",
                approvalGrantID: context.approvalGrantID?.uuidString
            ))
            return .blocked(verdict)
        }
        let resolvedRoot: URL?
        if let provided = context.workspaceRootURL {
            resolvedRoot = provided
        } else {
            resolvedRoot = await rootProvider()
        }
        guard let root = resolvedRoot else {
            return .outcome(.failed(message: "No workspace root is available for the shell"))
        }
        do { _ = try ShellInputValidation.directory(cwd: cwd, root: root) }
        catch { return .outcome(.failed(message: String(describing: error))) }
        var mergedEnvironment = environmentDefaults
        for (key, value) in environment { mergedEnvironment[key] = value }
        let request = ShellRunRequest(
            command: command,
            cwd: cwd,
            rootURL: root,
            environment: mergedEnvironment,
            stdin: stdin,
            timeout: normalizedTimeout(timeout, isBackground: isBackground),
            maxOutputBytes: normalizedOutputCap(maxOutputBytes),
            sessionID: context.toolCallID ?? context.runID.uuidString,
            runID: context.runID
        )
        let started = Date()
        let outcome = await backend.run(request, cancellation: context.cancellation)
        let durationMs = Int(Date().timeIntervalSince(started) * 1000)
        await record(outcome: outcome, command: command, cwd: cwd, context: context, durationMs: durationMs)
        return .outcome(outcome)
    }

    private func record(
        outcome: ShellRunOutcome,
        command: String,
        cwd: String,
        context: ToolContext,
        durationMs: Int
    ) async {
        let entry: ShellOperationJournal.Entry
        switch outcome {
        case .exited(let code, let stdout, let stderr, let truncated, let stderrTruncated, _):
            entry = ShellOperationJournal.Entry(
                runID: context.runID.uuidString,
                toolCallID: context.toolCallID,
                sessionID: context.toolCallID ?? context.runID.uuidString,
                commandSHA256: FloeDigest.sha256Hex(Data(command.utf8)),
                cwd: cwd,
                exitCode: code,
                stdoutBytes: stdout.utf8.count,
                stderrBytes: stderr.utf8.count,
                truncated: truncated || stderrTruncated,
                durationMs: durationMs,
                outcome: "exited:\(code)",
                approvalGrantID: context.approvalGrantID?.uuidString
            )
        case .timedOut(let stdout, let stderr, _):
            entry = ShellOperationJournal.Entry(
                runID: context.runID.uuidString,
                toolCallID: context.toolCallID,
                sessionID: context.toolCallID ?? context.runID.uuidString,
                commandSHA256: FloeDigest.sha256Hex(Data(command.utf8)),
                cwd: cwd,
                exitCode: 124,
                stdoutBytes: stdout.utf8.count,
                stderrBytes: stderr.utf8.count,
                truncated: false,
                durationMs: durationMs,
                outcome: "timedOut",
                approvalGrantID: context.approvalGrantID?.uuidString
            )
        case .cancelled:
            entry = ShellOperationJournal.Entry(
                runID: context.runID.uuidString,
                toolCallID: context.toolCallID,
                sessionID: context.toolCallID ?? context.runID.uuidString,
                commandSHA256: FloeDigest.sha256Hex(Data(command.utf8)),
                cwd: cwd,
                exitCode: nil,
                stdoutBytes: 0,
                stderrBytes: 0,
                truncated: false,
                durationMs: durationMs,
                outcome: "cancelled",
                approvalGrantID: context.approvalGrantID?.uuidString
            )
        case .failed(let message):
            entry = ShellOperationJournal.Entry(
                runID: context.runID.uuidString,
                toolCallID: context.toolCallID,
                sessionID: context.toolCallID ?? context.runID.uuidString,
                commandSHA256: FloeDigest.sha256Hex(Data(command.utf8)),
                cwd: cwd,
                exitCode: nil,
                stdoutBytes: 0,
                stderrBytes: 0,
                truncated: false,
                durationMs: durationMs,
                outcome: "failed:\(message.prefix(120))",
                approvalGrantID: context.approvalGrantID?.uuidString
            )
        }
        await journal.record(entry)
    }
}
