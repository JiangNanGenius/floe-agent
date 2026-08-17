// FloeExecution — exec.remotePython agent tool.
// See docs/ARCHITECTURE_EXECUTION.md §3.4/§4: a side-effecting remote
// execution tool. The `python3` command string is visible to the
// catastrophic gate, and the full gate → policy → approval chain runs
// before execution. Host scope is required.

import Foundation
import Crypto
import FloeCore
import FloeTools

/// Runs a Python script on a paired SSH host (`python3 -`, script over
/// stdin). Requires an explicit host; without one the call fails with a
/// structured "no host configured" message.
public struct RemotePythonTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        /// Python source (≤64 KiB).
        public var script: String
        /// Target host identifier. Agent calls require an explicit host so
        /// approval scope and execution scope are identical.
        public var hostID: String?
        /// Timeout in seconds; clamped to (0, 120].
        public var timeout: Double?
        /// Output cap in bytes; clamped to (0, 256 KiB].
        public var maxOutputBytes: Int?

        public init(
            script: String,
            hostID: String? = nil,
            timeout: Double? = nil,
            maxOutputBytes: Int? = nil
        ) {
            self.script = script
            self.hostID = hostID
            self.timeout = timeout
            self.maxOutputBytes = maxOutputBytes
        }
    }

    public static let name = "exec.remotePython"
    public static let toolDescription =
        "Execute a Python 3 script on a paired SSH host (script is sent over stdin to python3 -). Requires a configured host with python3; the call passes the catastrophic gate and approval policy because it runs code remotely."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "script": {"type": "string", "description": "Python 3 source to execute remotely (max 64 KiB)"},
        "hostID": {"type": "string", "description": "UUID of the paired SSH host"},
        "timeout": {"type": "number", "description": "Timeout in seconds (default 30, max 120)"},
        "maxOutputBytes": {"type": "integer", "description": "Output cap in bytes (default 65536, max 262144)"}
      },
      "required": ["script", "hostID"],
      "additionalProperties": false
    }
    """#
    /// Remote code execution: side-effecting and visible to the gate.
    public static let riskLabels: Set<RiskLabel> = [.executesRemoteCommand, .networkAccess]
    public static let isSideEffecting = true

    static let maxScriptBytes = 64 * 1024
    static let defaultTimeout: TimeInterval = 30
    static let maxTimeout: TimeInterval = 120
    static let defaultMaxOutputBytes = 64 * 1024
    static let maxOutputBytesCap = 256 * 1024

    private let service: RemotePythonService

    public init(service: RemotePythonService) {
        self.service = service
    }

    public func validate(_ args: Arguments) throws {
        if args.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw FloeError.validationFailed("script must not be empty")
        }
        if Data(args.script.utf8).count > Self.maxScriptBytes {
            throw FloeError.validationFailed(
                "script exceeds the \(Self.maxScriptBytes)-byte limit"
            )
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
            let outcome = try await service.run(
                script: args.script,
                hostID: hostID,
                timeout: min(args.timeout ?? Self.defaultTimeout, Self.maxTimeout),
                maxOutputBytes: min(args.maxOutputBytes ?? Self.defaultMaxOutputBytes, Self.maxOutputBytesCap),
                cancellation: context.cancellation
            )
            switch outcome {
            case .ok(_, let stdout, let stderr, let truncated, let stderrTruncated, let durationMs):
                var summary = "status=ok durationMs=\(durationMs) stdoutTruncated=\(truncated) stderrTruncated=\(stderrTruncated)\n"
                if !stdout.isEmpty { summary += "stdout:\n\(stdout)" }
                if !stderr.isEmpty {
                    if !stdout.isEmpty { summary += "\n" }
                    summary += "stderr:\n\(stderr)"
                }
                return ToolExecutionOutput(summary: summary, fullOutputSHA256: Self.sha256Hex(of: summary))
            case .jsException(let message, let stdout):
                // Python syntax/runtime errors come back as non-zero exit,
                // handled below; this case is unreachable for python3 but
                // kept total for the shared outcome type.
                let full = "status=exception\nerror=\(message)\n" + stdout
                return ToolExecutionOutput(summary: full, fullOutputSHA256: Self.sha256Hex(of: full), exitStatus: 1)
            case .timedOut(let afterMs, let partial):
                let full = "status=timedOut afterMs=\(afterMs)\n" + partial
                return ToolExecutionOutput(summary: full, fullOutputSHA256: Self.sha256Hex(of: full), exitStatus: 124)
            case .cancelled:
                throw FloeError.cancelled
            }
        } catch let error as RemotePythonError {
            // Structured host/capability failures surface to the model as
            // an ok-with-error-status result so it can react (pick another
            // host, report honestly), not as a tool-level crash.
            let full = "status=error\nerror=\(error.errorDescription ?? "unknown")"
            return ToolExecutionOutput(summary: full, fullOutputSHA256: Self.sha256Hex(of: full), exitStatus: 2)
        }
    }

    private static func sha256Hex(of text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
