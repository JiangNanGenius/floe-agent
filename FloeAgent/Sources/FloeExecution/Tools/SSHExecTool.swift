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
        public var executionMode: RemoteExecutionMode?
        public var containerNetwork: Bool?
        public var networkChangePlan: String?
        public var networkRollbackCommand: String?

        public init(
            command: String,
            hostID: String? = nil,
            timeout: Double? = nil,
            maxOutputBytes: Int? = nil,
            executionMode: RemoteExecutionMode? = nil,
            containerNetwork: Bool? = nil,
            networkChangePlan: String? = nil,
            networkRollbackCommand: String? = nil
        ) {
            self.command = command
            self.hostID = hostID
            self.timeout = timeout
            self.maxOutputBytes = maxOutputBytes
            self.executionMode = executionMode
            self.containerNetwork = containerNetwork
            self.networkChangePlan = networkChangePlan
            self.networkRollbackCommand = networkRollbackCommand
        }
    }

    public static let name = "ssh.execute"
    public static let toolDescription =
        "Run a command on a paired SSH target. Floe first performs read-only target classification so Linux, macOS, Windows, NAS/OpenWrt and switch/router/firewall CLIs use different strategies. Automatic mode uses a disposable, non-privileged Ubuntu task container on Linux when Docker/Podman is available; select host only for an explicitly authorized host-administration task such as runtime setup, firewall, services or OS configuration. Network devices receive native CLI commands and never Linux shell commands. Use ssh.inspectTarget before planning vendor-specific changes."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "command": {"type": "string", "description": "Shell command to execute remotely (max 64 KiB)"},
        "hostID": {"type": "string", "description": "Optional UUID of a specific paired SSH host; omitted uses the default host"},
        "timeout": {"type": "number", "description": "Timeout in seconds (default 30, max 120)"},
        "maxOutputBytes": {"type": "integer", "description": "Output cap in bytes (default 65536, max 262144)"},
        "executionMode": {"type": "string", "enum": ["automatic", "container", "host", "networkDevice"], "description": "Default automatic. Host must be explicit for host administration."},
        "containerNetwork": {"type": "boolean", "description": "Allow network inside the disposable task container; default false"},
        "networkChangePlan": {"type": "string", "description": "Required bounded diff/plan for a mutating network-device CLI command"},
        "networkRollbackCommand": {"type": "string", "description": "Required rollback or commit-confirm recovery command for a mutating network-device change"}
      },
      "required": ["command"],
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
    private let remoteAgent: RemoteAgentTaskService?

    public init(service: SSHCommandService, remoteAgent: RemoteAgentTaskService? = nil) {
        self.service = service
        self.remoteAgent = remoteAgent
    }

    public func validate(_ args: Arguments) throws {
        if args.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw FloeError.validationFailed("command must not be empty")
        }
        if Data(args.command.utf8).count > Self.maxCommandBytes {
            throw FloeError.validationFailed("command exceeds the \(Self.maxCommandBytes)-byte limit")
        }
        if let hostID = args.hostID, UUID(uuidString: hostID) == nil {
            throw FloeError.validationFailed("hostID must be a UUID when provided")
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
            if args.executionMode == .host,
               let remoteAgent,
               let toolCallID = context.toolCallID {
                let durable = try await remoteAgent.runHost(
                    command: args.command,
                    hostID: hostID,
                    runID: context.runID,
                    toolCallID: toolCallID,
                    timeout: min(args.timeout ?? Self.defaultTimeout, Self.maxTimeout),
                    maxOutputBytes: min(args.maxOutputBytes ?? Self.defaultMaxOutputBytes, Self.maxOutputBytesCap),
                    cancellation: context.cancellation
                )
                var summary = "transport=remoteGuardian taskID=\(durable.taskID) state=\(durable.state) exitCode=\(durable.exitCode)"
                if let duration = durable.duration {
                    let formattedDuration = String(format: "%.2f", duration)
                    summary += " duration=\(formattedDuration)s"
                }
                if !durable.output.isEmpty { summary += "\noutput:\n\(durable.output)" }
                return Self.output(summary, exitStatus: durable.exitCode)
            }
            let routed = try await service.runRouted(
                command: args.command,
                hostID: hostID,
                mode: args.executionMode ?? .automatic,
                containerNetwork: args.containerNetwork ?? false,
                taskID: context.runID,
                networkChangePlan: args.networkChangePlan,
                networkRollbackCommand: args.networkRollbackCommand,
                timeout: min(args.timeout ?? Self.defaultTimeout, Self.maxTimeout),
                maxOutputBytes: min(args.maxOutputBytes ?? Self.defaultMaxOutputBytes, Self.maxOutputBytesCap),
                cancellation: context.cancellation
            )
            let result = routed.result
            var summary = "targetKind=\(routed.inspection.kind.rawValue) confidence=\(String(format: "%.2f", routed.inspection.confidence)) executionMode=\(routed.mode.rawValue) exitCode=\(result.exitCode) truncated=\(result.truncated)"
            if !result.stdout.isEmpty { summary += "\nstdout:\n\(result.stdout)" }
            if !result.stderr.isEmpty { summary += "\nstderr:\n\(result.stderr)" }
            return Self.output(summary, exitStatus: result.exitCode)
        } catch SSHExecError.cancelled {
            throw FloeError.cancelled
        } catch let error as FloeError where error == .cancelled {
            throw error
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
