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
        /// How long a caller queues behind another engine worker before the
        /// command is reported as not-started. Kept separate from the
        /// execution timeout so gate starvation never fakes a run timeout.
        public var gateWaitTimeout: TimeInterval
        public var defaultMaxOutputBytes: Int
        public var maxOutputBytes: Int
        public var maximumStdinBytes: Int
        public var maximumCommandBytes: Int

        public init(
            defaultTimeout: TimeInterval = 10,
            maxTimeout: TimeInterval = 120,
            backgroundTimeout: TimeInterval = 600,
            gateWaitTimeout: TimeInterval = 5,
            defaultMaxOutputBytes: Int = 64 * 1024,
            maxOutputBytes: Int = 256 * 1024,
            maximumStdinBytes: Int = 256 * 1024,
            maximumCommandBytes: Int = 16 * 1024
        ) {
            self.defaultTimeout = defaultTimeout
            self.maxTimeout = maxTimeout
            self.backgroundTimeout = backgroundTimeout
            self.gateWaitTimeout = gateWaitTimeout
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

    /// Clamps the caller's gate queue window. It is intentionally independent
    /// from the execution timeout: a busy engine must report "nothing was
    /// started" promptly instead of pretending the command ran and timed out.
    public nonisolated func normalizedGateWait(_ requested: TimeInterval?) -> TimeInterval {
        let ceiling = max(0.25, min(configuration.gateWaitTimeout, 30))
        let value = requested.flatMap { $0.isFinite ? $0 : nil } ?? ceiling
        return max(0.25, min(value, ceiling))
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
                sessionID: context.clientScopedSessionToken,
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
        // Design original-write barrier (BEFORE any backend dispatch): when
        // this run owns frozen design originals, arbitrary guest/native shell
        // commands that could overwrite a frozen original are refused here —
        // the guest addresses the same workspace through its share, so this
        // is the single pre-dispatch choke point for exec.shell (and for
        // jobs.submit, which funnels through this same service). Only
        // strictly read-only inspection reaches the backend; the denial is
        // structured with the recovery actions. Runs without a freeze are
        // untouched.
        if let denial = DesignGuestWriteGate.evaluate(command: command, context: context) {
            await journal.record(ShellOperationJournal.Entry(
                runID: context.runID.uuidString,
                toolCallID: context.toolCallID,
                sessionID: context.clientScopedSessionToken,
                commandSHA256: FloeDigest.sha256Hex(Data(command.utf8)),
                cwd: cwd,
                exitCode: 126,
                stdoutBytes: 0,
                stderrBytes: denial.message.utf8.count,
                truncated: false,
                durationMs: 0,
                outcome: "denied:designFreezePreDispatch",
                approvalGrantID: context.approvalGrantID?.uuidString
            ))
            return .outcome(.exited(
                code: 126, stdout: "", stderr: denial.message,
                truncated: false, stderrTruncated: false, durationMs: 0
            ))
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
        // The backend session key is the runtime-issued per-CLIENT scope, not
        // the bare provider tool-call id: a parent run and two delegated
        // children of the same task may legitimately all be handed provider
        // call id `call_1`, and a shared executor keeps per-session state
        // (guest console sessions, PTYs) keyed by this string. Distinct
        // clients therefore stay distinct here, and every journal entry below
        // uses the same token so a reviewer can correlate the run's request
        // with its recorded outcome. The provider-visible call id is
        // unchanged (it is still journaled in `toolCallID`).
        let request = ShellRunRequest(
            command: command,
            cwd: cwd,
            rootURL: root,
            environment: mergedEnvironment,
            stdin: stdin,
            timeout: normalizedTimeout(timeout, isBackground: isBackground),
            gateTimeout: normalizedGateWait(nil),
            maxOutputBytes: normalizedOutputCap(maxOutputBytes),
            sessionID: context.clientScopedSessionToken,
            runID: context.runID,
            toolEnvironment: context.environment
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
                sessionID: context.clientScopedSessionToken,
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
                sessionID: context.clientScopedSessionToken,
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
                sessionID: context.clientScopedSessionToken,
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
        case .notStarted(let reason):
            entry = ShellOperationJournal.Entry(
                runID: context.runID.uuidString,
                toolCallID: context.toolCallID,
                sessionID: context.clientScopedSessionToken,
                commandSHA256: FloeDigest.sha256Hex(Data(command.utf8)),
                cwd: cwd,
                exitCode: nil,
                stdoutBytes: 0,
                stderrBytes: 0,
                truncated: false,
                durationMs: durationMs,
                outcome: "notStarted:\(reason.prefix(120))",
                approvalGrantID: context.approvalGrantID?.uuidString
            )
        case .failed(let message):
            entry = ShellOperationJournal.Entry(
                runID: context.runID.uuidString,
                toolCallID: context.toolCallID,
                sessionID: context.clientScopedSessionToken,
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
