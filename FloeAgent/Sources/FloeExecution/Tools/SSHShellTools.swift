// FloeExecution — ssh.shell.* interactive remote shell tools.
//
// A persistent PTY shell session on a paired host: open → exchange → close.
// executionMode=direct rides a plain SSH PTY; executionMode=host rides the
// Floe guardian's /v1/shell endpoints. One-shot commands belong to
// ssh.execute (durable taskID); these tools are for interactive sessions.

import Foundation
import Crypto
import FloeCore
import FloeTools

private enum SSHShellSupport {
    static func validateHostID(_ value: String?) throws {
        if let value, UUID(uuidString: value) == nil {
            throw FloeError.validationFailed("hostID must be a UUID when provided")
        }
    }

    static func validateSessionID(_ value: String) throws -> UUID {
        guard let id = UUID(uuidString: value) else {
            throw FloeError.validationFailed("sessionID must be a UUID returned by ssh.shellOpen")
        }
        return id
    }

    static func output(_ text: String, exitStatus: Int32 = 0) -> ToolExecutionOutput {
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return ToolExecutionOutput(summary: text, fullOutputSHA256: digest, exitStatus: exitStatus)
    }
}

public struct SSHShellOpenTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var hostID: String?
        /// direct (default, plain SSH PTY) or host (guardian /v1/shell).
        public var executionMode: String?
        public var term: String?
        public var cols: Int?
        public var rows: Int?

        public init(hostID: String? = nil, executionMode: String? = nil, term: String? = nil, cols: Int? = nil, rows: Int? = nil) {
            self.hostID = hostID
            self.executionMode = executionMode
            self.term = term
            self.cols = cols
            self.rows = rows
        }
    }

    public static let name = "ssh.shellOpen"
    public static let toolDescription =
        "Open an interactive remote shell session on a paired host and return its sessionID plus initial output. executionMode=direct (default) opens a plain SSH PTY; executionMode=host rides the Floe guardian's /v1/shell channel (guardian 1.4.4+, older guardians return a redeploy hint). Drive the session with ssh.shellExchange using the exact sessionID, finish with ssh.shellClose. For one-shot commands use ssh.execute instead (durable taskID model)."
    public static let parametersJSON = #"""
    {"type":"object","properties":{"hostID":{"type":"string","description":"Paired host UUID; omit to use the default host"},"executionMode":{"type":"string","enum":["direct","host"]},"term":{"type":"string","description":"Terminal type, default xterm-256color"},"cols":{"type":"integer","minimum":20,"maximum":500},"rows":{"type":"integer","minimum":5,"maximum":200}},"required":[],"additionalProperties":false}
    """#
    public static let riskLabels: Set<RiskLabel> = [.executesRemoteCommand, .networkAccess]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    private let service: InteractiveShellSessionService

    public init(service: InteractiveShellSessionService) {
        self.service = service
    }

    public func validate(_ args: Arguments) throws {
        try SSHShellSupport.validateHostID(args.hostID)
        if let mode = args.executionMode, mode != "direct", mode != "host" {
            throw FloeError.validationFailed("executionMode must be direct or host")
        }
        if let term = args.term, term.utf8.count > 32 {
            throw FloeError.validationFailed("term must be at most 32 characters")
        }
        if let cols = args.cols, !(20...500).contains(cols) {
            throw FloeError.validationFailed("cols must be 20-500")
        }
        if let rows = args.rows, !(5...200).contains(rows) {
            throw FloeError.validationFailed("rows must be 5-200")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let environment: InteractiveShellEnvironment = args.executionMode == "host" ? .guardian : .direct
        do {
            let opened = try await service.open(
                runID: context.runID,
                hostID: args.hostID.flatMap(UUID.init(uuidString:)),
                environment: environment,
                term: args.term ?? "xterm-256color",
                columns: args.cols ?? 80,
                rows: args.rows ?? 24
            )
            var summary = "status=ok sessionID=\(opened.sessionID.uuidString) environment=\(environment.rawValue)"
            if !opened.output.isEmpty { summary += "\noutput:\n\(opened.output)" }
            return SSHShellSupport.output(summary)
        } catch let error as FloeError {
            return SSHShellSupport.output("status=error error=\(error.localizedDescription)", exitStatus: 2)
        }
    }
}

public struct SSHShellExchangeTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var sessionID: String
        /// UTF-8 input written to the shell (include \n to submit a line).
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

    public static let name = "ssh.shellExchange"
    public static let toolDescription =
        "Exchange with an interactive shell session: write optional input (include a newline to submit a command line) and return the new output produced since the previous exchange, redacted and bounded, plus whether the shell is still alive. An empty input performs a pure read with waitMs up to 30000. alive=false means the shell exited; close the session with ssh.shellClose."
    public static let parametersJSON = #"""
    {"type":"object","properties":{"sessionID":{"type":"string"},"input":{"type":"string","description":"UTF-8 bytes for the shell (max 65536)"},"waitMs":{"type":"integer","minimum":50,"maximum":30000},"maxBytes":{"type":"integer","minimum":1,"maximum":262144}},"required":["sessionID"],"additionalProperties":false}
    """#
    public static let riskLabels: Set<RiskLabel> = [.executesRemoteCommand, .networkAccess]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    private let service: InteractiveShellSessionService

    public init(service: InteractiveShellSessionService) {
        self.service = service
    }

    public func validate(_ args: Arguments) throws {
        _ = try SSHShellSupport.validateSessionID(args.sessionID)
        if let input = args.input, input.utf8.count > 65_536 {
            throw FloeError.validationFailed("input exceeds the 65536-byte limit")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let sessionID = try SSHShellSupport.validateSessionID(args.sessionID)
        do {
            let result = try await service.exchange(
                runID: context.runID,
                sessionID: sessionID,
                input: args.input.map { Data($0.utf8) },
                waitMs: args.waitMs ?? 2_000,
                maxBytes: args.maxBytes ?? 65_536,
                cancellation: context.cancellation
            )
            var summary = "status=ok alive=\(result.alive) environment=\(result.environment.rawValue)"
            if !result.output.isEmpty { summary += "\noutput:\n\(result.output)" }
            return SSHShellSupport.output(summary)
        } catch let error as FloeError {
            return SSHShellSupport.output("status=error error=\(error.localizedDescription)", exitStatus: 2)
        }
    }
}

public struct SSHShellCloseTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var sessionID: String

        public init(sessionID: String) {
            self.sessionID = sessionID
        }
    }

    public static let name = "ssh.shellClose"
    public static let toolDescription =
        "Close an interactive shell session opened with ssh.shellOpen, terminating the remote shell and releasing the sessionID. Always close sessions when the interactive work is done."
    public static let parametersJSON = #"""
    {"type":"object","properties":{"sessionID":{"type":"string"}},"required":["sessionID"],"additionalProperties":false}
    """#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    private let service: InteractiveShellSessionService

    public init(service: InteractiveShellSessionService) {
        self.service = service
    }

    public func validate(_ args: Arguments) throws {
        _ = try SSHShellSupport.validateSessionID(args.sessionID)
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let sessionID = try SSHShellSupport.validateSessionID(args.sessionID)
        await service.close(runID: context.runID, sessionID: sessionID)
        return SSHShellSupport.output("status=ok sessionID=\(sessionID.uuidString) closed=true")
    }
}
