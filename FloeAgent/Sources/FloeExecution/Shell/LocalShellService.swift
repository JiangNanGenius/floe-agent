// FloeExecution — Local shell service.
// Wraps the injected backend with Floe's deterministic policy, output
// sanitation, journaling and explicit limits. The service never invokes a
// backend for a blocked command and never fabricates an outcome.

import Foundation
import FloeCore
import FloeTools

public actor LocalShellService {
    public struct Configuration: Sendable {
        /// The deadline used when the caller states none. New explicit human
        /// policy (2026-10-26): default execution is UNLIMITED — the old
        /// default-10/foreground-120/background-600 application deadlines
        /// are removed, and a bare model number is advisory (never a kill).
        public var defaultDeadline: ShellExecutionDeadline
        /// How long a caller queues behind another engine worker before the
        /// command is reported as not-started. Kept separate from the
        /// execution deadline so gate starvation never fakes a run timeout.
        /// This is a queue/handshake safety budget, not an execution cap.
        public var gateWaitTimeout: TimeInterval
        public var defaultMaxOutputBytes: Int
        public var maxOutputBytes: Int
        public var maximumStdinBytes: Int

        public init(
            defaultDeadline: ShellExecutionDeadline = .unlimited,
            gateWaitTimeout: TimeInterval = 5,
            defaultMaxOutputBytes: Int = 64 * 1024,
            maxOutputBytes: Int = 256 * 1024,
            maximumStdinBytes: Int = 256 * 1024
        ) {
            self.defaultDeadline = defaultDeadline
            self.gateWaitTimeout = gateWaitTimeout
            self.defaultMaxOutputBytes = defaultMaxOutputBytes
            self.maxOutputBytes = maxOutputBytes
            self.maximumStdinBytes = maximumStdinBytes
        }
    }

    /// The tool-facing resolution of a requested number + policy: the
    /// deadline the command actually receives, the number the caller asked
    /// for (receipt only) and the honest reason the two differ.
    public struct ResolvedDeadline: Sendable, Equatable {
        public var deadline: ShellExecutionDeadline
        public var requestedSeconds: TimeInterval?
        /// `default` (nothing requested), `advisoryDefault` (a bare number is
        /// an advisory hint under the new policy — execution stays
        /// unlimited), `advisoryPolicy` (explicit `timeoutPolicy:"advisory"`),
        /// `none` (a hard deadline honored as requested), `minimumFloor` (the
        /// backend's documented floor raised it) or `invalidHard` (a hard
        /// value that failed checked representability; the service fails safe
        /// to the default policy instead of inventing a kill or a fake cap).
        public var clampReason: String

        public init(deadline: ShellExecutionDeadline, requestedSeconds: TimeInterval?, clampReason: String) {
            self.deadline = deadline
            self.requestedSeconds = requestedSeconds
            self.clampReason = clampReason
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
    /// One-time 600 s host-monotonic duration advisory for unlimited
    /// foreground runs (nil keeps this module platform-independent; the app
    /// injects the monitor whose sink delivers through the existing durable
    /// outbox). Job-wrapped runs are owned by the job monitor instead, so one
    /// unit of work never advises twice.
    private let durationReminder: LongRunDurationReminder?
    private let environmentDefaults: [String: String]
    private let rootProvider: @Sendable () async -> URL?

    public init(
        backend: any LocalShellBackend,
        policy: ShellCommandPolicy = ShellCommandPolicy(),
        journal: ShellOperationJournal = ShellOperationJournal(),
        configuration: Configuration = Configuration(),
        durationReminder: LongRunDurationReminder? = nil,
        environmentDefaults: [String: String] = [:],
        rootProvider: @escaping @Sendable () async -> URL?
    ) {
        self.backend = backend
        self.policy = policy
        self.journal = journal
        self.configuration = configuration
        self.durationReminder = durationReminder
        self.environmentDefaults = environmentDefaults
        self.rootProvider = rootProvider
    }

    /// Resolves the requested number + policy into the deadline the command
    /// actually receives, then lets the backend apply its own documented
    /// floor (the Linux guest runner enforces a 1-second minimum on real
    /// deadlines; generic backends keep the service value unchanged). New
    /// time policy: an omitted number keeps the configured default
    /// (unlimited); a bare number is an ADVISORY hint and never kills; only
    /// `timeoutPolicy:"hard"` produces a real deadline, honored at its exact
    /// finite value within checked host-monotonic representability (never a
    /// silent clamp to a product cap, never infinity, never a fake huge
    /// number). The result is what the backend receives, so the tool receipt
    /// and this service never disagree. Exposed for tests.
    public nonisolated func resolvedDeadline(
        _ requested: TimeInterval?,
        policy: ShellTimeoutPolicy
    ) -> ResolvedDeadline {
        guard let requested, requested.isFinite, requested > 0 else {
            // Omitted (or an invalid value that tool validation already
            // refused upstream): the configured default policy applies.
            return ResolvedDeadline(
                deadline: configuration.defaultDeadline,
                requestedSeconds: (requested?.isFinite == true) ? requested : nil,
                clampReason: "default")
        }
        switch policy {
        case .advisory:
            return ResolvedDeadline(deadline: .unlimited, requestedSeconds: requested, clampReason: "advisoryDefault")
        case .hard:
            guard let checked = ShellExecutionDeadline.validated(seconds: requested) else {
                // Unrepresentable on the host monotonic clock: fail safe to
                // the default policy instead of inventing a kill or a cap.
                return ResolvedDeadline(
                    deadline: configuration.defaultDeadline,
                    requestedSeconds: requested,
                    clampReason: "invalidHard")
            }
            let enforced = backend.normalizedRunDeadline(checked)
            return ResolvedDeadline(
                deadline: enforced,
                requestedSeconds: requested,
                clampReason: enforced == checked ? "none" : "minimumFloor")
        }
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
        requestedTimeout: TimeInterval?,
        timeoutPolicy: ShellTimeoutPolicy = .advisory,
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
        let resolved = resolvedDeadline(requestedTimeout, policy: timeoutPolicy)
        let request = ShellRunRequest(
            command: command,
            cwd: cwd,
            rootURL: root,
            environment: mergedEnvironment,
            stdin: stdin,
            deadline: resolved.deadline,
            gateTimeout: normalizedGateWait(nil),
            maxOutputBytes: normalizedOutputCap(maxOutputBytes),
            sessionID: context.clientScopedSessionToken,
            runID: context.runID,
            toolEnvironment: context.environment
        )
        // One-time 600 s duration advisory for an unlimited FOREGROUND run.
        // A job-wrapped run (isBackground) is owned by the job-side monitor,
        // so one unit of work can never advise twice; the identity is the
        // runtime-issued run id + client-scoped session token, never a
        // model-supplied alias, so unrelated commands/sessions cannot
        // collide. Arming is observe-only: it cannot affect the run.
        let reminderKey: String? = (!isBackground && resolved.deadline == .unlimited && durationReminder != nil)
            ? "shell.\(context.runID.uuidString).\(context.clientScopedSessionToken)"
            : nil
        if let reminderKey {
            await durationReminder?.begin(
                key: reminderKey,
                conversationID: context.conversationID,
                runID: context.runID,
                jobID: nil,
                label: "exec.shell"
            )
        }
        let started = Date()
        let outcome = await backend.run(request, cancellation: context.cancellation)
        if let reminderKey { await durationReminder?.end(key: reminderKey) }
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
