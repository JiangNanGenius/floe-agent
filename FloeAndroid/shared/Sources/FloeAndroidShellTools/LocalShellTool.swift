// FloeAndroidShellTools — Android platform mirror of the ORIGINAL
// FloeAgent/Sources/FloeExecution/Tools/LocalShellTool.swift.
// Every statement is byte-equal to the original except the deltas below
// (full list also delivered to Main in the private SOURCE_READY.json):
//   T1 (Android description): the tool description reflects PRoot engine
//      reality and the single-workload serialization, and REMOVES the
//      unsupported iOS claims (Virtualization guest CPU/RAM shape resume,
//      lifecycle core-selection tools, environment.linuxStatus roundtrip).
//      The honest-failure sentence stays: a missing or unqualified engine
//      fails with preparation/selection guidance and NEVER falls back to a
//      host interpreter. `jobs.submit` remains the documented long-command
//      path (the ORIGINAL BackgroundJobStore/BackgroundJobService stay the
//      durable authority; their port is a separate follow-up integration).
//   T2 (legacy packages refusal): a non-empty `packages` input is refused
//      in `validate` with `python3 -m pip` guidance. The ORIGINAL's
//      ManagedPythonInstallService parameter and install branch are
//      REMOVED: the managed host Python installer does not exist on
//      Android and is never instantiated. Decoding of the legacy fields is
//      preserved so old provider calls reach the honest refusal instead of
//      a schema error.
//   T3 (no installer injection): `init` keeps only `shell:`. The original
//      "--- managed packages ---" install header is unreachable here and
//      removed with the install branch.
//   T4 (honest output labels): the engine returns MERGED PTY bytes and the
//      backend never splits them, so the render section headers rename
//      "--- stdout ---" to "--- output (merged PTY) ---" and "--- stderr ---"
//      to "--- stderr (backend metadata) ---" (the latter only ever carries
//      backend-generated metadata such as a stdin-write note). Exit codes,
//      truncation flags and all other render semantics are byte-equal.
// The validation limits, policy pre-check, background detection
// (`jobs.` call ids), rendering contract (exit=126/124/130/75/125) and the
// service authority are byte-equal.

import Foundation
import FloeCore
import FloeTools

public struct LocalShellTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        /// Command string (≤16 KiB). Pipelines, redirections and globs are
        /// supported by the backend shell engine.
        public var command: String?
        /// Alias for `command` when the payload is a multi-line script body.
        public var script: String?
        public var cwd: String?
        public var env: [String: String]?
        public var stdin: String?
        public var timeout: Double?
        public var maxOutputBytes: Int?
        /// Legacy managed dependency input; prefer python3 -m pip in the command.
        public var packages: [String]?
        public var packagePurpose: String?
        public var packageCapabilities: [String]?

        public init(
            command: String? = nil,
            script: String? = nil,
            cwd: String? = nil,
            env: [String: String]? = nil,
            stdin: String? = nil,
            timeout: Double? = nil,
            maxOutputBytes: Int? = nil,
            packages: [String]? = nil,
            packagePurpose: String? = nil,
            packageCapabilities: [String]? = nil
        ) {
            self.command = command
            self.script = script
            self.cwd = cwd
            self.env = env
            self.stdin = stdin
            self.timeout = timeout
            self.maxOutputBytes = maxOutputBytes
            self.packages = packages
            self.packagePurpose = packagePurpose
            self.packageCapabilities = packageCapabilities
        }

        public var resolvedCommand: String? {
            if let command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return command }
            if let script, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return script }
            return nil
        }
    }

    public static let name = "exec.shell"
    // T1: Android engine reality (PRoot userland in the dedicated runtime
    // UID, one serialized workload, merged PTY output). No VM-shape or
    // lifecycle-core-selection claims exist on this platform.
    public static let toolDescription =
        "Execute commands or a POSIX shell script in the task's resolved Linux engine (a PRoot Debian userland running in the dedicated runtime UID), never the Android host. Supports python3, node, pipelines, redirections, loops and the actual installed Linux utilities. Inspect command -v and versions before relying on tools; use python3 -m pip, npm/pnpm or the engine's apt for dependencies when available. Git may be used if actually installed; git.* tools provide structured repository operations. cwd is workspace-relative and workspace file visibility requires the runtime setup and file mapping to be qualified. Use jobs.submit targeting exec.shell for long commands or shell.open/shell.exchange for persistent input. Effective timeout is reported (foreground max 120 seconds; jobs max 600); output is bounded and PTY output is merged (stdout/stderr are not split). Inspect exit status and saved outputs before continuing a timed-out/interrupted operation, rather than repeating side effects. A busy engine reports status=notStarted (nothing ran) instead of a fake timeout. A missing or unqualified Linux engine fails with preparation/selection guidance and never falls back to a host interpreter. Package installs happen through the Linux userland itself (python3 -m pip / npm / apt inside the command); the legacy packages input is refused."
    public static let parametersJSON = #"""
    {"type":"object","properties":{
      "command":{"type":"string","description":"Shell command line (max 16 KiB). Pipelines and redirections supported."},
      "script":{"type":"string","description":"Alias for command when passing a multi-line script body"},
      "cwd":{"type":"string","description":"Workspace-relative working directory (default: session cwd or workspace root)"},
      "env":{"type":"object","additionalProperties":{"type":"string"},"description":"Extra environment variables for this run only"},
      "stdin":{"type":"string","description":"Optional stdin content (max 256 KiB)"},
      "timeout":{"type":"number","description":"Wall-clock timeout seconds (default 10, max 120; 600 for jobs.submit background jobs)"},
      "maxOutputBytes":{"type":"integer","description":"Combined output cap (default 65536, max 262144)"}},
     "additionalProperties":false}
    """#
    public static let riskLabels: Set<RiskLabel> = [
        .executesLocalCode, .readsFiles, .writesFiles, .deletesFiles, .networkAccess
    ]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    static let maximumCommandBytes = 16 * 1024
    static let maximumStdinBytes = 256 * 1024
    static let maximumEnvEntries = 32

    private let shell: LocalShellService

    public init(shell: LocalShellService) {
        self.shell = shell
    }

    public func validate(_ args: Arguments) throws {
        guard let command = args.resolvedCommand else {
            throw FloeError.validationFailed("command (or script) must not be empty")
        }
        try ShellInputValidation.validate(command: command, cwd: args.cwd ?? ".", environment: args.env ?? [:], stdin: args.stdin)
        if Data(command.utf8).count > Self.maximumCommandBytes {
            throw FloeError.validationFailed("command exceeds the \(Self.maximumCommandBytes)-byte limit")
        }
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
        if let timeout = args.timeout, (!timeout.isFinite || timeout <= 0) {
            throw FloeError.validationFailed("timeout must be > 0")
        }
        if let maxOutputBytes = args.maxOutputBytes, maxOutputBytes <= 0 {
            throw FloeError.validationFailed("maxOutputBytes must be > 0")
        }
        let packages = args.packages ?? []
        // T2: legacy managed dependency input is refused on Android. The
        // ORIGINAL validated specs via ManagedPythonPackageSpecParser and
        // routed through ManagedPythonInstallService; that managed host
        // Python installer was REMOVED and must never be instantiated here
        // — installs ride the Linux userland itself.
        guard packages.isEmpty else {
            throw FloeError.validationFailed("packages is not supported on Android: install dependencies inside the command with python3 -m pip (or npm/pnpm/apt where actually installed); the legacy managed installer is removed")
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
        let isBackground = context.toolCallID?.hasPrefix("jobs.") == true
        let cwd = args.cwd ?? "."
        let result = await shell.run(
            command: command,
            cwd: cwd,
            environment: args.env ?? [:],
            stdin: args.stdin,
            timeout: args.timeout,
            maxOutputBytes: args.maxOutputBytes,
            isBackground: isBackground,
            context: context
        )
        switch result {
        case .blocked(let verdict):
            let text = "status=blocked pattern=\(verdict.matchedPatternID ?? "policy")\n\(verdict.reason ?? "Command blocked")\nexit=126"
            return Self.output(text, exitStatus: 126)
        case .outcome(let outcome):
            return render(outcome: outcome, command: command, cwd: cwd, effectiveTimeout: shell.normalizedTimeout(args.timeout, isBackground: isBackground), isBackground: isBackground)
        }
    }

    private func render(
        outcome: ShellRunOutcome,
        command: String,
        cwd: String,
        effectiveTimeout: TimeInterval,
        isBackground: Bool
    ) -> ToolExecutionOutput {
        switch outcome {
        case .exited(let code, let stdout, let stderr, let truncated, let stderrTruncated, let durationMs):
            let cleanOut = SecretRedactor.redact(ShellOutputSanitizer.sanitize(stdout))
            let cleanErr = SecretRedactor.redact(ShellOutputSanitizer.sanitize(stderr))
            var text = "exit=\(code) durationMs=\(durationMs) cwd=\(cwd) effectiveTimeoutSeconds=\(effectiveTimeout)"
            if truncated { text += " stdoutTruncated" }
            if stderrTruncated { text += " stderrTruncated" }
            text += "\n--- output (merged PTY) ---\n\(cleanOut)"
            if !cleanErr.isEmpty { text += "\n--- stderr (backend metadata) ---\n\(cleanErr)" }
            return Self.output(text, exitStatus: code)
        case .timedOut(let partialStdout, let partialStderr, let durationMs):
            var text = "exit=124 durationMs=\(durationMs) cwd=\(cwd) status=timedOut effectiveTimeoutSeconds=\(effectiveTimeout)"
            text += isBackground
                ? "\nThe background command reached its effective deadline. Inspect existing outputs before explicitly continuing; do not blindly repeat side effects."
                : "\nThe foreground command reached its effective deadline. Inspect existing outputs before explicitly continuing long work through jobs.submit; do not blindly repeat side effects."
            let cleanOut = SecretRedactor.redact(ShellOutputSanitizer.sanitize(partialStdout))
            if !cleanOut.isEmpty { text += "\n--- output (merged PTY) ---\n\(cleanOut)" }
            let cleanErr = SecretRedactor.redact(ShellOutputSanitizer.sanitize(partialStderr))
            if !cleanErr.isEmpty { text += "\n--- stderr (backend metadata) ---\n\(cleanErr)" }
            return Self.output(text, exitStatus: 124)
        case .cancelled:
            return Self.output("exit=130 status=cancelled cwd=\(cwd)", exitStatus: 130)
        case .notStarted(let reason):
            // The engine slot was still owned by another workload. Nothing of
            // this command ran, so there is no exit code and no output to
            // report: say so instead of returning a timeout with empty stdout.
            return Self.output("exit=75 status=notStarted cwd=\(cwd)\n\(reason)", exitStatus: 75)
        case .failed(let message):
            return Self.output("exit=125 status=engineUnavailable\n\(message)", exitStatus: 125)
        }
    }

    private static func output(_ text: String, exitStatus: Int32) -> ToolExecutionOutput {
        ToolExecutionOutput(digesting: text, exitStatus: exitStatus)
    }
}
