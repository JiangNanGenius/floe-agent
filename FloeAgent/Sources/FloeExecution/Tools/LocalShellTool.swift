// FloeExecution — exec.shell agent tool.
// Executes one bounded shell command through the injected local backend
// (the selected Linux guest in production). Risks are broad by construction:
// the approval card shows the exact command and the user decides.

import Foundation
import FloeCore
import FloeTools

public struct LocalShellTool: AgentTool {
    public struct Arguments: Codable, Sendable {
        /// Command string. Pipelines, redirections and globs are supported
        /// by the backend shell. Command length has no application-level cap:
        /// large bodies are staged as a script file inside the guest.
        public var command: String?
        /// Alias for `command` when the payload is a multi-line script body.
        public var script: String?
        public var cwd: String?
        public var env: [String: String]?
        public var stdin: String?
        public var timeout: Double?
        /// Alias for `timeout`. Rejected when both are present with
        /// different values; equal duplicates are accepted.
        public var timeoutSeconds: Double?
        /// Provenance of the requested number: `"hard"` is a real
        /// user-requested stop time; `"advisory"` (the default when a number
        /// is present without this field) records an intended duration and
        /// never kills. A bare number alone never establishes human intent —
        /// old schemas taught models 10/120/600/1800 defaults and those must
        /// not restore the old application deadline.
        public var timeoutPolicy: String?
        public var maxOutputBytes: Int?
        /// Legacy managed dependency input; prefer python3 -m pip in the command.
        public var packages: [String]?
        public var packagePurpose: String?
        public var packageCapabilities: [String]?
        /// Optional exact installed Skill id when this command belongs to that
        /// skill's reviewed workflow. With it the app verifies the installed
        /// record, the current run binding and the approval grant, then
        /// automatically prepares and reads back the skill's declared
        /// dependencies in the task's already-resolved Linux environment; a
        /// required dependency that is not ready refuses THIS skill's
        /// invocation with the honest reason. Omitting it keeps ordinary
        /// behavior byte-for-byte unchanged (that path is how a run repairs
        /// itself). Never model-mintable authority: the verification re-reads
        /// live installed facts every time.
        public var skillID: String?

        public init(
            command: String? = nil,
            script: String? = nil,
            cwd: String? = nil,
            env: [String: String]? = nil,
            stdin: String? = nil,
            timeout: Double? = nil,
            timeoutSeconds: Double? = nil,
            timeoutPolicy: String? = nil,
            maxOutputBytes: Int? = nil,
            packages: [String]? = nil,
            packagePurpose: String? = nil,
            packageCapabilities: [String]? = nil,
            skillID: String? = nil
        ) {
            self.command = command
            self.script = script
            self.cwd = cwd
            self.env = env
            self.stdin = stdin
            self.timeout = timeout
            self.timeoutSeconds = timeoutSeconds
            self.timeoutPolicy = timeoutPolicy
            self.maxOutputBytes = maxOutputBytes
            self.packages = packages
            self.packagePurpose = packagePurpose
            self.packageCapabilities = packageCapabilities
            self.skillID = skillID
        }

        public var resolvedCommand: String? {
            if let command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return command }
            if let script, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return script }
            return nil
        }

        /// Canonical timeout argument. `timeout` stays the canonical name;
        /// `timeoutSeconds` is an accepted alias because models spell it that
        /// way. A silent ignore previously turned such a request into the
        /// 10-second default, so the alias now works and a real disagreement
        /// fails loudly instead of picking one.
        public var resolvedTimeout: Double? {
            get throws {
                switch (timeout, timeoutSeconds) {
                case let (value?, alias?):
                    guard value == alias else {
                        throw FloeError.validationFailed(
                            "timeout and timeoutSeconds disagree (\(value) vs \(alias)); pass one value or make both equal"
                        )
                    }
                    return value
                case let (value?, nil):
                    return value
                case let (nil, alias?):
                    return alias
                case (nil, nil):
                    return nil
                }
            }
        }

        /// Canonical policy for the requested number. Absent/empty means
        /// `.advisory`: under the new time policy a bare number never
        /// establishes a human deadline, so legacy taught values (including
        /// exactly 600) stay advisory and execution remains unlimited.
        /// `"hard"` requires a number and produces the only real deadline.
        public var resolvedTimeoutPolicy: ShellTimeoutPolicy {
            get throws {
                guard let raw = timeoutPolicy?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                      !raw.isEmpty else { return .advisory }
                guard let policy = ShellTimeoutPolicy(rawValue: raw) else {
                    throw FloeError.validationFailed(
                        "timeoutPolicy must be \"hard\" (a real user-requested deadline) or \"advisory\" (an intended duration that never kills)"
                    )
                }
                if policy == .hard, try resolvedTimeout == nil {
                    throw FloeError.validationFailed(
                        "timeoutPolicy \"hard\" requires a timeout (or timeoutSeconds) number; omit both for the default unlimited execution"
                    )
                }
                return policy
            }
        }
    }

    public static let name = "exec.shell"
    public static let toolDescription =
        "Execute commands or a POSIX shell script in the task's pinned execution environment: on-device Linux, a paired Mac bridge, or the explicitly selected SSH host. Native App tools retain App ownership. Supports available interpreters, pipelines, redirections and loops; inspect the actual OS, architecture and installed tools. Inspect command -v and versions before relying on tools; use python3 -m pip, npm/pnpm or the selected system's package manager for dependencies when available. Git may be used if actually installed; git.* tools provide structured repository operations. cwd is workspace-relative. Use jobs.submit targeting exec.shell for long commands or shell.open/shell.exchange for persistent input. There is no application-level command-length limit: an oversized script body is staged as a file inside the task's execution workspace and executed by its /bin/sh, while stdin stays a separate bounded channel. Commands run with NO application execution deadline by default: omit timeout and the command runs until it finishes, is cancelled, or fails, and the user receives one progress reminder after 10 minutes of runtime. The requested number, its policy and the effective deadline are reported with the reason (effectiveTimeoutSeconds=unlimited for the default and advisory cases); output is bounded. Inspect exit status and saved outputs before continuing a timed-out/interrupted operation, rather than repeating side effects. When an official skill declares dependencies (see its skill.read Dependency invocation section), pass its exact id as skillID on this run's commands: verification plus automatic install/readback happen in the task's resolved environment and a not-ready required dependency refuses only that skill's invocation; commands without skillID keep the ordinary behavior. A missing, disconnected or legacy environment fails with preparation/selection guidance; it never silently changes machines or replays an interrupted command. A stopped guest resumes its last successful CPU/RAM shape. Use environment.linuxStatus to inspect it, and lifecycle tools to select 1–3 cores within the shared budget when needed; do not restart another task's environment to cancel your command."
    public static let parametersJSON = #"""
    {"type":"object","properties":{
      "command":{"type":"string","description":"Shell command line or whole script body. No application-level length cap: large scripts are staged as a file inside the task's guest workspace, so pipelines, redirections and loops all run as guest /bin/sh code."},
      "script":{"type":"string","description":"Alias for command when passing a multi-line script body"},
      "cwd":{"type":"string","description":"Workspace-relative working directory (default: session cwd or workspace root)"},
      "env":{"type":"object","additionalProperties":{"type":"string"},"description":"Extra environment variables for this run only"},
      "stdin":{"type":"string","description":"Optional stdin content (max 256 KiB)"},
      "timeout":{"type":"number","description":"Duration seconds. ADVISORY by default: it is recorded in the receipt but the command is NOT killed, because default execution is unlimited. Pair with timeoutPolicy=hard for a real user-requested stop time. Canonical name; timeoutSeconds is an accepted alias."},
      "timeoutSeconds":{"type":"number","description":"Alias for timeout. If both are present they must be equal."},
      "timeoutPolicy":{"type":"string","enum":["hard","advisory"],"description":"hard = a real deadline the USER asked for: the command stops at that time (exit 124). advisory (default) = intended duration only; execution stays unlimited. Use hard ONLY for an actual user-requested deadline; a bare timeout number (including the old taught default 600) never kills."},
      "maxOutputBytes":{"type":"integer","description":"Combined output cap (default 65536, max 262144)"},
      "skillID":{"type":"string","description":"Optional exact installed Skill id when this command belongs to that skill's reviewed workflow. Floe verifies the installed record, this run's binding and the approval grant, then automatically installs and reads back the skill's declared dependencies in the task's resolved execution environment; a required dependency that is not ready refuses only this skill's invocation with the honest reason. Omit for ordinary commands, which run exactly as before (including repair commands)."}},
     "additionalProperties":false}
    """#
    public static let riskLabels: Set<RiskLabel> = [
        .executesLocalCode, .readsFiles, .writesFiles, .deletesFiles, .networkAccess
    ]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    static let maximumStdinBytes = 256 * 1024
    static let maximumEnvEntries = 32

    private let shell: LocalShellService
    private let pythonInstaller: ManagedPythonInstallService?
    private let dependencyGate: (any SkillDependencyInvocationGating)?

    public init(
        shell: LocalShellService,
        pythonInstaller: ManagedPythonInstallService? = nil,
        dependencyGate: (any SkillDependencyInvocationGating)? = nil
    ) {
        self.shell = shell
        self.pythonInstaller = pythonInstaller
        self.dependencyGate = dependencyGate
    }

    public func validate(_ args: Arguments) throws {
        guard let command = args.resolvedCommand else {
            throw FloeError.validationFailed("command (or script) must not be empty")
        }
        try ShellInputValidation.validate(command: command, cwd: args.cwd ?? ".", environment: args.env ?? [:], stdin: args.stdin)
        if let cwd = args.cwd {
            guard !cwd.hasPrefix("/"), !cwd.hasPrefix("~"), !cwd.split(separator: "/").contains("..") else {
                throw FloeError.validationFailed("cwd must be a workspace-relative path without '..'")
            }
        }
        if let stdin = args.stdin, stdin.utf8.count > Self.maximumStdinBytes {
            throw FloeError.validationFailed("stdin exceeds the \(Self.maximumStdinBytes)-byte limit")
        }
        if let env = args.env, env.count > Self.maximumEnvEntries {
            throw FloeError.validationFailed("env accepts at most \(Self.maximumEnvEntries) variables")
        }
        if let timeout = try args.resolvedTimeout, !timeout.isFinite || timeout <= 0 {
            throw FloeError.validationFailed("timeout must be > 0")
        }
        let policy = try args.resolvedTimeoutPolicy
        if policy == .hard, let timeout = try args.resolvedTimeout,
           timeout > ShellExecutionDeadline.maximumRepresentableSeconds {
            throw FloeError.validationFailed(
                "timeout exceeds the representable host monotonic clock horizon (\(ShellExecutionDeadline.maximumRepresentableSeconds) seconds); omit timeout for unlimited execution"
            )
        }
        if let maxOutputBytes = args.maxOutputBytes, maxOutputBytes <= 0 {
            throw FloeError.validationFailed("maxOutputBytes must be > 0")
        }
        if let skillID = args.skillID {
            let trimmed = skillID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty || (trimmed.count <= 64 && trimmed.first?.isLowercase == true
                && trimmed.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" }) else {
                throw FloeError.validationFailed("skillID must be a lowercase skill identifier when provided")
            }
        }
        let packages = args.packages ?? []
        guard packages.count <= 16 else {
            throw FloeError.validationFailed("packages accepts at most 16 entries")
        }
        for package in packages {
            try ManagedPythonPackageSpecParser.validate(package)
        }
        if !packages.isEmpty {
            guard let purpose = args.packagePurpose?.trimmingCharacters(in: .whitespacesAndNewlines), !purpose.isEmpty else {
                throw FloeError.validationFailed("packagePurpose is required when packages are requested")
            }
        }
        let verdict = shell.policy.evaluate(command)
        if verdict.stopped {
            throw FloeError.validationFailed(verdict.reason ?? "Command blocked by policy")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        guard let command = args.resolvedCommand else {
            throw FloeError.validationFailed("command must not be empty")
        }
        // Skill-scoped dependency gate. Default (no `skillID`) never reaches
        // any verification and behaves exactly as before; ordinary repair
        // commands stay available. Only THIS skill's invocation can be
        // refused, never the shell itself, and the impeccable runtime
        // component's nonblocking hook is unchanged.
        var dependencyAnnotation = ""
        if let rawSkillID = args.skillID?.trimmingCharacters(in: .whitespacesAndNewlines), !rawSkillID.isEmpty {
            guard dependencyGate != nil else {
                return Self.output(
                    "status=skillDependencyUnavailable\nskillID=\(rawSkillID)\nreason=official Skill dependency provisioning is not configured in this build; run the command without skillID (ordinary shell behavior is unchanged) or update Floe\nexit=75",
                    exitStatus: 75
                )
            }
            guard context.approvalGrantID != nil else {
                return Self.output(
                    "status=skillDependencyUnavailable\nskillID=\(rawSkillID)\nreason=dependency-aware invocation requires the run's approval grant\nexit=75",
                    exitStatus: 75
                )
            }
            switch await dependencyGate!.dependencyInvocationDecision(
                skillID: rawSkillID,
                environmentID: context.environmentID ?? context.environment?.id,
                runID: context.runID,
                approvalGrantID: context.approvalGrantID,
                cancellation: context.cancellation
            ) {
            case .proceed(let annotation):
                dependencyAnnotation = annotation
            case .refused(let reason):
                return Self.output(
                    "status=skillDependencyNotReady\nskillID=\(rawSkillID)\nreason=\(reason)\nexit=75",
                    exitStatus: 75
                )
            case .unavailable(let reason):
                return Self.output(
                    "status=skillDependencyUnavailable\nskillID=\(rawSkillID)\nreason=\(reason)\nexit=75",
                    exitStatus: 75
                )
            }
        }
        // Resolve the deadline BEFORE any side effect: the legacy managed
        // packages pre-install inherits this call's resolved deadline, so a
        // default-unlimited call never hits a hidden install budget and an
        // explicit hard deadline is the only real bound.
        let requestedTimeout = try args.resolvedTimeout
        let timeoutPolicy = try args.resolvedTimeoutPolicy
        let resolved = shell.resolvedDeadline(requestedTimeout, policy: timeoutPolicy, environment: context.environment)
        var installOutput = ""
        if let packages = args.packages, !packages.isEmpty {
            guard let pythonInstaller else {
                return Self.output("status=packageInstallUnavailable\nexit=65", exitStatus: 65)
            }
            let outcome = await pythonInstaller.install(
                specs: packages,
                deadline: resolved.deadline,
                maxOutputBytes: 64 * 1024,
                cancellation: context.cancellation,
                environment: context.environment
            )
            switch outcome {
            case .ok(let output):
                installOutput = output
            case .failed(let message):
                return Self.output("status=packageInstallFailed\nerror=\(message)\nexit=65", exitStatus: 65)
            case .timedOut(let partial):
                // The install was killed mid-flight: the retained text is a
                // partial receipt, not a complete captured output.
                return Self.output(
                    "status=packageInstallTimedOut\n\(partial)\nexit=124",
                    exitStatus: 124, captureTruncated: true)
            case .cancelled:
                throw FloeError.cancelled
            }
        }
        let isBackground = context.toolCallID?.hasPrefix("jobs.") == true
        let cwd = args.cwd ?? "."
        let result = await shell.run(
            command: command,
            cwd: cwd,
            environment: args.env ?? [:],
            stdin: args.stdin,
            requestedTimeout: requestedTimeout,
            timeoutPolicy: timeoutPolicy,
            maxOutputBytes: args.maxOutputBytes,
            isBackground: isBackground,
            context: context
        )
        switch result {
        case .blocked(let verdict):
            let text = "status=blocked pattern=\(verdict.matchedPatternID ?? "policy")\n\(verdict.reason ?? "Command blocked")\nexit=126"
            return Self.output(text, exitStatus: 126)
        case .outcome(let outcome):
            return render(
                outcome: outcome,
                command: command,
                cwd: cwd,
                installOutput: installOutput,
                dependencyAnnotation: dependencyAnnotation,
                resolved: resolved,
                requestedPolicy: timeoutPolicy,
                isBackground: isBackground
            )
        }
    }

    private func render(
        outcome: ShellRunOutcome,
        command: String,
        cwd: String,
        installOutput: String,
        dependencyAnnotation: String = "",
        resolved: LocalShellService.ResolvedDeadline,
        requestedPolicy: ShellTimeoutPolicy,
        isBackground: Bool
    ) -> ToolExecutionOutput {
        func prefix() -> String {
            var header = ""
            if !dependencyAnnotation.isEmpty { header += "--- skill dependencies ---\n\(dependencyAnnotation)\n" }
            if !installOutput.isEmpty { header += "--- managed packages ---\n\(installOutput)\n" }
            return header
        }
        /// Requested/policy/effective/clamp receipt. The effective value is
        /// the deadline the guest command actually received (`unlimited` =
        /// no application execution deadline); the reason names why it
        /// differs from the request, so an advisory legacy number is never
        /// mistaken for a real deadline and the default-unlimited policy is
        /// visible in every result.
        func timeoutReceipt() -> String {
            let requested = resolved.requestedSeconds.map { String($0) } ?? "none"
            let policyText = resolved.requestedSeconds == nil ? "default" : requestedPolicy.rawValue
            return "timeoutRequestedSeconds=\(requested) timeoutPolicy=\(policyText) effectiveTimeoutSeconds=\(resolved.deadline.receiptText) timeoutClamp=\(resolved.clampReason)"
        }
        switch outcome {
        case .exited(let code, let stdout, let stderr, let truncated, let stderrTruncated, let durationMs):
            // Sanitization itself bounds each line (32 KiB) and the whole
            // output (512 KiB); those cuts are real losses of command output,
            // so their flags travel with the capture exactly like the
            // backend's transport-cap markers.
            let sanitizedOut = ShellOutputSanitizer.sanitizeReportingTruncation(stdout)
            let sanitizedErr = ShellOutputSanitizer.sanitizeReportingTruncation(stderr)
            let cleanOut = SecretRedactor.redact(sanitizedOut.text)
            let cleanErr = SecretRedactor.redact(sanitizedErr.text)
            var text = prefix()
            text += "exit=\(code) durationMs=\(durationMs) cwd=\(cwd) \(timeoutReceipt())"
            if truncated { text += " stdoutTruncated" }
            if stderrTruncated { text += " stderrTruncated" }
            text += "\n--- stdout ---\n\(cleanOut)"
            if !cleanErr.isEmpty { text += "\n--- stderr ---\n\(cleanErr)" }
            // This capture is the complete RETAINED text for this run, but when
            // the transport cap or the sanitizer already cut stdout/stderr it
            // is NOT the command's whole raw output, and neither the job
            // artifact nor a result reader may claim otherwise.
            return Self.output(
                text, exitStatus: code,
                captureTruncated: truncated || stderrTruncated
                    || sanitizedOut.truncated || sanitizedErr.truncated)
        case .timedOut(let partialStdout, let partialStderr, let durationMs):
            var text = prefix()
            text += "exit=124 durationMs=\(durationMs) cwd=\(cwd) status=timedOut \(timeoutReceipt())"
            text += isBackground
                ? "\nThe background command reached its effective deadline. Inspect existing outputs before explicitly continuing; do not blindly repeat side effects."
                : "\nThe foreground command reached its effective deadline. Inspect existing outputs before explicitly continuing long work through jobs.submit; do not blindly repeat side effects."
            let cleanOut = SecretRedactor.redact(ShellOutputSanitizer.sanitize(partialStdout))
            if !cleanOut.isEmpty { text += "\n--- stdout ---\n\(cleanOut)" }
            let cleanErr = SecretRedactor.redact(ShellOutputSanitizer.sanitize(partialStderr))
            if !cleanErr.isEmpty { text += "\n--- stderr ---\n\(cleanErr)" }
            // A deadline stop leaves only partial output: declare the capture
            // incomplete instead of inventing a size for what was never read.
            return Self.output(text, exitStatus: 124, captureTruncated: true)
        case .cancelled:
            // Cancellation returns a receipt with no collected stdout: the
            // command's output is unknown, so the capture is partial too.
            return Self.output("exit=130 status=cancelled cwd=\(cwd)", exitStatus: 130, captureTruncated: true)
        case .notStarted(let reason):
            // The engine gate was still owned by another worker. Nothing of
            // this command ran, so there is no exit code and no output to
            // report: say so instead of returning a timeout with empty stdout.
            return Self.output(prefix() + "exit=75 status=notStarted cwd=\(cwd)\n\(reason)", exitStatus: 75)
        case .failed(let message):
            return Self.output(prefix() + "exit=125 status=engineUnavailable\n\(message)", exitStatus: 125)
        case .outcomeUnknown(let jobID, let message):
            return ToolExecutionOutput(
                digesting: prefix() + "status=outcomeUnknown jobID=\(jobID)\n\(SecretRedactor.redact(message))\nReconnect and inspect this existing job. Do not submit the command again.",
                requiresUserAction: true,
                capturedOutputTruncated: true,
                outcomeUnknown: true
            )
        }
    }

    /// - Parameter captureTruncated: true when this receipt is not the
    ///   command's whole output (transport cut, deadline stop, cancellation).
    ///   The captured text is still everything this run retained, and the
    ///   digest always covers that retained text.
    private static func output(
        _ text: String,
        exitStatus: Int32,
        captureTruncated: Bool = false
    ) -> ToolExecutionOutput {
        ToolExecutionOutput(
            digesting: text,
            exitStatus: exitStatus,
            capturedOutput: text,
            capturedOutputTruncated: captureTruncated)
    }
}
