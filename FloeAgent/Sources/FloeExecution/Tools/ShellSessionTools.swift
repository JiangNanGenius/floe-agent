// FloeExecution — Interactive local shell tools (shell.*).
// Session semantics intentionally mirror ssh.shellOpen/shellExchange/
// shellClose: a run-scoped sessionID, bounded exchanges, sliding expiry.
// shell.signal adds Ctrl-C/TERM/KILL control for interactive programs.

import Foundation
import FloeCore
import FloeTools

public struct ShellOpenTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var command: String?
        public var cwd: String?
        public var env: [String: String]?
        public var columns: Int?
        public var rows: Int?

        public init(command: String? = nil, cwd: String? = nil, env: [String: String]? = nil, columns: Int? = nil, rows: Int? = nil) {
            self.command = command
            self.cwd = cwd
            self.env = env
            self.columns = columns
            self.rows = rows
        }
    }

    public static let name = "shell.open"
    public static let toolDescription =
        "Open an interactive local shell session for programs that read input over time (an interactive sh prompt, a script that asks questions, a REPL-like tool). Defaults to the interactive sh. Continue with shell.exchange (feed input, read output), then shell.close. At most 4 sessions; sessions expire after 30 idle minutes. Use exec.shell for one-shot commands and jobs.submit for background work."
    public static let parametersJSON = #"""
    {"type":"object","properties":{
      "command":{"type":"string","description":"Program to run interactively (default: interactive sh)"},
      "cwd":{"type":"string","description":"Workspace-relative working directory"},
      "env":{"type":"object","additionalProperties":{"type":"string"}},
      "columns":{"type":"integer","minimum":20,"maximum":500},
      "rows":{"type":"integer","minimum":5,"maximum":200}},
     "additionalProperties":false}
    """#
    public static let riskLabels: Set<RiskLabel> = [
        .executesLocalCode, .readsFiles, .writesFiles, .deletesFiles, .networkAccess
    ]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    private let center: ShellSessionCenter

    public init(center: ShellSessionCenter) {
        self.center = center
    }

    public func validate(_ args: Arguments) throws {
        try ShellInputValidation.validate(command: args.command ?? "", cwd: args.cwd ?? ".", environment: args.env ?? [:])
        if let cwd = args.cwd {
            guard !cwd.hasPrefix("/"), !cwd.hasPrefix("~"), !cwd.split(separator: "/").contains("..") else {
                throw FloeError.validationFailed("cwd must be a workspace-relative path without '..'")
            }
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        guard let root = context.workspaceRootURL else {
            throw FloeError.validationFailed("A workspace root is required for shell sessions")
        }
        let result = try await center.open(
            command: args.command ?? "",
            cwd: args.cwd ?? ".",
            environment: args.env ?? [:],
            columns: args.columns ?? 80,
            rows: args.rows ?? 24,
            runID: context.runID,
            rootURL: root,
            cancellation: context.cancellation,
            toolEnvironment: context.environment
        )
        var text = "status=ok sessionID=\(result.sessionID) alive=\(result.alive)"
        if !result.initialOutput.isEmpty { text += "\noutput:\n\(result.initialOutput)" }
        return ToolExecutionOutput(digesting: text, exitStatus: 0)
    }
}

public struct ShellExchangeTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var sessionID: String
        public var input: String?
        public var waitMs: Int?
        public var maxBytes: Int?

        public init(sessionID: String, input: String? = nil, waitMs: Int? = nil, maxBytes: Int? = nil) {
            self.sessionID = sessionID
            self.input = input
            self.waitMs = waitMs
            self.maxBytes = maxBytes
        }
    }

    public static let name = "shell.exchange"
    public static let toolDescription =
        "Send input to an open shell session and read new output. `input` is UTF-8 text; send \"\\u0003\" for Ctrl-C. waitMs bounds how long to collect output (default 2000, max 30000). The response reports whether the program is still alive and its exit code once it exits."
    public static let parametersJSON = #"""
    {"type":"object","properties":{
      "sessionID":{"type":"string"},
      "input":{"type":"string","description":"Input bytes; \\u0003 sends Ctrl-C"},
      "waitMs":{"type":"integer","minimum":50,"maximum":30000},
      "maxBytes":{"type":"integer","minimum":1,"maximum":262144}},
     "required":["sessionID"],"additionalProperties":false}
    """#
    public static let riskLabels: Set<RiskLabel> = [.executesLocalCode, .networkAccess]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    private let center: ShellSessionCenter

    public init(center: ShellSessionCenter) {
        self.center = center
    }

    public func validate(_ args: Arguments) throws {
        guard !args.sessionID.isEmpty else { throw FloeError.validationFailed("sessionID is required") }
        if let input = args.input, input.utf8.count > 64 * 1024 {
            throw FloeError.validationFailed("input exceeds 64 KiB")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let result = try await center.exchange(
            sessionID: args.sessionID,
            input: args.input,
            waitMs: args.waitMs ?? 2_000,
            maxBytes: args.maxBytes ?? 64 * 1024,
            runID: context.runID,
            cancellation: context.cancellation
        )
        var text = "status=ok sessionID=\(args.sessionID) alive=\(result.alive)"
        if let exitCode = result.exitCode { text += " exitCode=\(exitCode)" }
        if !result.output.isEmpty { text += "\noutput:\n\(result.output)" }
        return ToolExecutionOutput(digesting: text, exitStatus: result.alive ? 0 : (result.exitCode ?? 0))
    }
}

public struct ShellCloseTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var sessionID: String
        public init(sessionID: String) { self.sessionID = sessionID }
    }

    public static let name = "shell.close"
    public static let toolDescription = "Close an interactive local shell session opened with shell.open. Safe to call more than once."
    public static let parametersJSON = #"{"type":"object","properties":{"sessionID":{"type":"string"}},"required":["sessionID"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.executesLocalCode]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    private let center: ShellSessionCenter

    public init(center: ShellSessionCenter) {
        self.center = center
    }

    public func validate(_ args: Arguments) throws {
        guard !args.sessionID.isEmpty else { throw FloeError.validationFailed("sessionID is required") }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        await center.close(sessionID: args.sessionID, runID: context.runID)
        return ToolExecutionOutput(digesting: "status=ok sessionID=\(args.sessionID) closed=true", exitStatus: 0)
    }
}

public struct ShellSignalTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var sessionID: String
        public var signal: String
        public init(sessionID: String, signal: String) {
            self.sessionID = sessionID
            self.signal = signal
        }
    }

    public static let name = "shell.signal"
    public static let toolDescription = "Send INT, TERM or KILL to a running interactive shell session without closing it."
    public static let parametersJSON = #"{"type":"object","properties":{"sessionID":{"type":"string"},"signal":{"type":"string","enum":["INT","TERM","KILL"]}},"required":["sessionID","signal"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.executesLocalCode]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    private let center: ShellSessionCenter

    public init(center: ShellSessionCenter) {
        self.center = center
    }

    public func validate(_ args: Arguments) throws {
        guard !args.sessionID.isEmpty else { throw FloeError.validationFailed("sessionID is required") }
        guard ShellSignal(rawValue: args.signal.uppercased()) != nil else {
            throw FloeError.validationFailed("signal must be INT, TERM or KILL")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let signal = ShellSignal(rawValue: args.signal.uppercased()) ?? .interrupt
        await center.signal(sessionID: args.sessionID, signal: signal, runID: context.runID)
        return ToolExecutionOutput(digesting: "status=ok sessionID=\(args.sessionID) signal=\(signal.rawValue)", exitStatus: 0)
    }
}
