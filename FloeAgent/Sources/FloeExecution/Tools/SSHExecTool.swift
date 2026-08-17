// FloeExecution — ssh.execute agent tool.

import Foundation
import Crypto
import FloeCore
import FloeTools
import FloeSSH

/// Runs an arbitrary shell command on a paired SSH host. Non-zero exit is a
/// normal result (the model reads stdout/stderr/exitCode); only transport and
/// timeout failures surface as errors.
public struct SSHExecTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var command: String
        public var hostID: String?
        public var timeout: Double?
        public var maxOutputBytes: Int?

        public init(
            command: String,
            hostID: String? = nil,
            timeout: Double? = nil,
            maxOutputBytes: Int? = nil
        ) {
            self.command = command
            self.hostID = hostID
            self.timeout = timeout
            self.maxOutputBytes = maxOutputBytes
        }
    }

    public static let name = "ssh.execute"
    public static let toolDescription =
        "Run a shell command on a paired SSH host (ls, grep, git, npm, etc.). Non-zero exit codes are returned as results, not errors. Requires a configured host; the call passes the catastrophic gate and approval policy because it runs commands remotely."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "command": {"type": "string", "description": "Shell command to execute remotely (max 64 KiB)"},
        "hostID": {"type": "string", "description": "UUID of the paired SSH host"},
        "timeout": {"type": "number", "description": "Timeout in seconds (default 30, max 120)"},
        "maxOutputBytes": {"type": "integer", "description": "Output cap in bytes (default 65536, max 262144)"}
      },
      "required": ["command", "hostID"],
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.executesRemoteCommand, .networkAccess]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    static let maxCommandBytes = 64 * 1024
    static let defaultTimeout: TimeInterval = 30
    static let maxTimeout: TimeInterval = 120
    static let defaultMaxOutputBytes = 64 * 1024
    static let maxOutputBytesCap = 256 * 1024

    private let service: SSHCommandService

    public init(service: SSHCommandService) {
        self.service = service
    }

    public func validate(_ args: Arguments) throws {
        if args.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw FloeError.validationFailed("command must not be empty")
        }
        if Data(args.command.utf8).count > Self.maxCommandBytes {
            throw FloeError.validationFailed("command exceeds the \(Self.maxCommandBytes)-byte limit")
        }
        guard let hostID = args.hostID, UUID(uuidString: hostID) != nil else {
            throw FloeError.validationFailed("hostID must be a UUID")
        }
        if let timeout = args.timeout, timeout <= 0 {
            throw FloeError.validationFailed("timeout must be > 0")
        }
        if let cap = args.maxOutputBytes, cap <= 0 {
            throw FloeError.validationFailed("maxOutputBytes must be > 0")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()

        let hostID = args.hostID.flatMap(UUID.init(uuidString:))
        do {
            let result = try await service.run(
                command: args.command,
                hostID: hostID,
                timeout: min(args.timeout ?? Self.defaultTimeout, Self.maxTimeout),
                maxOutputBytes: min(args.maxOutputBytes ?? Self.defaultMaxOutputBytes, Self.maxOutputBytesCap),
                cancellation: context.cancellation
            )
            var summary = "exitCode=\(result.exitCode) truncated=\(result.truncated)"
            if !result.stdout.isEmpty { summary += "\nstdout:\n\(result.stdout)" }
            if !result.stderr.isEmpty { summary += "\nstderr:\n\(result.stderr)" }
            return Self.output(summary, exitStatus: result.exitCode)
        } catch SSHExecError.cancelled {
            throw FloeError.cancelled
        } catch SSHExecError.timedOut {
            return Self.output("status=timedOut", exitStatus: 124)
        } catch let error as RemotePythonError {
            return Self.output("status=error error=\(error.errorDescription ?? "unknown")", exitStatus: 2)
        } catch {
            return Self.output("status=error error=\(error.localizedDescription)", exitStatus: 2)
        }
    }

    private static func output(_ text: String, exitStatus: Int32) -> ToolExecutionOutput {
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return ToolExecutionOutput(summary: text, fullOutputSHA256: digest, exitStatus: exitStatus)
    }
}
