// FloeExecution — exec.shell agent tool.
// Executes one bounded shell command through the injected local backend
// (ios_system + sh/dash in production). Risks are broad by construction:
// the approval card shows the exact command and the user decides.

import Foundation
import FloeCore
import FloeTools

public struct LocalShellTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        /// Command string (≤16 KiB). Pipelines, redirections and globs are
        /// supported by the backend shell.
        public var command: String?
        /// Alias for `command` when the payload is a multi-line script body.
        public var script: String?
        public var cwd: String?
        public var env: [String: String]?
        public var stdin: String?
        public var timeout: Double?
        public var maxOutputBytes: Int?
        /// Optional managed pure-Python packages installed (reviewed) before
        /// the command runs, exactly like exec.localPython.
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
    public static let toolDescription =
        "Run a bounded local Unix shell command through Floe's on-device shell (POSIX sh: pipelines, redirections, globs, variables, &&/||). File tools, text tools, archives, hashing, python3, git, network diagnostics and the apt/pkg package commands are available; the working root is the current task workspace. Use jobs.submit with this tool for long-running commands, and shell.open/shell.exchange for interactive sessions. Output is capped; exit codes follow shell conventions (124 timeout, 126 blocked, 127 command not found). sudo is unavailable, and native ELF binaries cannot run on iOS."
    public static let parametersJSON = #"""
    {"type":"object","properties":{
      "command":{"type":"string","description":"Shell command line (max 16 KiB). Pipelines and redirections supported."},
      "script":{"type":"string","description":"Alias for command when passing a multi-line script body"},
      "cwd":{"type":"string","description":"Workspace-relative working directory (default: session cwd or workspace root)"},
      "env":{"type":"object","additionalProperties":{"type":"string"},"description":"Extra environment variables for this run only"},
      "stdin":{"type":"string","description":"Optional stdin content (max 256 KiB)"},
      "timeout":{"type":"number","description":"Wall-clock timeout seconds (default 10, max 120; 600 for jobs.submit background jobs)"},
      "maxOutputBytes":{"type":"integer","description":"Combined output cap (default 65536, max 262144)"},
      "packages":{"type":"array","maxItems":16,"items":{"type":"string"},"description":"Managed pure-Python packages installed before the command; each entry is reviewed"},
      "packagePurpose":{"type":"string","description":"Why the packages are required (reviewed evidence)"},
      "packageCapabilities":{"type":"array","maxItems":16,"items":{"type":"string"},"description":"Narrow capabilities such as spreadsheet or network.http"}},
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
    private let pythonInstaller: ManagedPythonInstallService?

    public init(shell: LocalShellService, pythonInstaller: ManagedPythonInstallService? = nil) {
        self.shell = shell
        self.pythonInstaller = pythonInstaller
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
        var installOutput = ""
        if let packages = args.packages, !packages.isEmpty {
            guard let pythonInstaller else {
                return Self.output("status=packageInstallUnavailable\nexit=65", exitStatus: 65)
            }
            let outcome = await pythonInstaller.install(
                specs: packages,
                timeout: 30,
                maxOutputBytes: 64 * 1024,
                cancellation: context.cancellation
            )
            switch outcome {
            case .ok(let output):
                installOutput = output
            case .failed(let message):
                return Self.output("status=packageInstallFailed\nerror=\(message)\nexit=65", exitStatus: 65)
            case .timedOut(let partial):
                return Self.output("status=packageInstallTimedOut\n\(partial)\nexit=124", exitStatus: 124)
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
            return render(outcome: outcome, command: command, cwd: cwd, installOutput: installOutput)
        }
    }

    private func render(
        outcome: ShellRunOutcome,
        command: String,
        cwd: String,
        installOutput: String
    ) -> ToolExecutionOutput {
        func prefix() -> String {
            var header = ""
            if !installOutput.isEmpty { header += "--- managed packages ---\n\(installOutput)\n" }
            return header
        }
        switch outcome {
        case .exited(let code, let stdout, let stderr, let truncated, let stderrTruncated, let durationMs):
            let cleanOut = SecretRedactor.redact(ShellOutputSanitizer.sanitize(stdout))
            let cleanErr = SecretRedactor.redact(ShellOutputSanitizer.sanitize(stderr))
            var text = prefix()
            text += "exit=\(code) durationMs=\(durationMs) cwd=\(cwd)"
            if truncated { text += " stdoutTruncated" }
            if stderrTruncated { text += " stderrTruncated" }
            text += "\n--- stdout ---\n\(cleanOut)"
            if !cleanErr.isEmpty { text += "\n--- stderr ---\n\(cleanErr)" }
            return Self.output(text, exitStatus: code)
        case .timedOut(let partialStdout, let partialStderr, let durationMs):
            var text = prefix()
            text += "exit=124 durationMs=\(durationMs) cwd=\(cwd) status=timedOut"
            let cleanOut = SecretRedactor.redact(ShellOutputSanitizer.sanitize(partialStdout))
            if !cleanOut.isEmpty { text += "\n--- stdout ---\n\(cleanOut)" }
            let cleanErr = SecretRedactor.redact(ShellOutputSanitizer.sanitize(partialStderr))
            if !cleanErr.isEmpty { text += "\n--- stderr ---\n\(cleanErr)" }
            return Self.output(text, exitStatus: 124)
        case .cancelled:
            return Self.output("exit=130 status=cancelled cwd=\(cwd)", exitStatus: 130)
        case .failed(let message):
            return Self.output(prefix() + "exit=125 status=engineUnavailable\n\(message)", exitStatus: 125)
        }
    }

    private static func output(_ text: String, exitStatus: Int32) -> ToolExecutionOutput {
        ToolExecutionOutput(digesting: text, exitStatus: exitStatus)
    }
}
