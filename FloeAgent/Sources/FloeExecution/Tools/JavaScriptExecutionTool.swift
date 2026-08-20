// FloeExecution — exec.javascript agent tool.
// See docs/ARCHITECTURE_EXECUTION.md §3.4/§4: a non-side-effecting pure
// computation tool. The JSCore sandbox has no file or network APIs and no
// Swift objects are injected, so it carries no risk labels and is
// auto-allowed by every approval policy (no approval card).

import Foundation
import Crypto
import FloeCore
import FloeTools

/// Runs a JavaScript snippet in a sandboxed JSContext and returns the
/// captured console output plus the optional `printJSON` result.
public struct JavaScriptExecutionTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        /// Script source (≤64 KiB).
        public var script: String
        /// Optional JSON injected as the JS `input` value.
        public var inputJSON: String?
        /// Wall-clock timeout in seconds; clamped to (0, 120].
        public var timeout: Double?
        /// Console output cap in bytes; clamped to (0, 256 KiB].
        public var maxOutputBytes: Int?

        public init(
            script: String,
            inputJSON: String? = nil,
            timeout: Double? = nil,
            maxOutputBytes: Int? = nil
        ) {
            self.script = script
            self.inputJSON = inputJSON
            self.timeout = timeout
            self.maxOutputBytes = maxOutputBytes
        }
    }

    public static let name = "exec.javascript"
    public static let toolDescription =
        "Execute a JavaScript snippet in a sandboxed JavaScriptCore context (no file or network access). console.log output is captured; call printJSON(value) to return a structured result."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "script": {"type": "string", "description": "JavaScript source to execute (max 64 KiB)"},
        "inputJSON": {"type": "string", "description": "Optional JSON value available to the script as `input`"},
        "timeout": {"type": "number", "description": "Timeout in seconds (default 10, max 120)"},
        "maxOutputBytes": {"type": "integer", "description": "Console output cap in bytes (default 65536, max 262144)"}
      },
      "required": ["script"],
      "additionalProperties": false
    }
    """#
    /// Pure computation inside the JSCore sandbox: no files, no network,
    /// no remote system — no risk labels, never side-effecting.
    public static let riskLabels: Set<RiskLabel> = []
    public static let isSideEffecting = false

    /// Hard bounds regardless of caller input.
    static let maxScriptBytes = 64 * 1024
    static let defaultTimeout: TimeInterval = 10
    static let maxTimeout: TimeInterval = 120
    static let defaultMaxOutputBytes = 64 * 1024
    static let maxOutputBytesCap = 256 * 1024

    private let service: any ScriptExecutionService

    public init(service: any ScriptExecutionService = JavaScriptExecutionService()) {
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
        if let timeout = args.timeout, timeout <= 0 {
            throw FloeError.validationFailed("timeout must be > 0")
        }
        if let cap = args.maxOutputBytes, cap <= 0 {
            throw FloeError.validationFailed("maxOutputBytes must be > 0")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()

        let request = ScriptExecutionRequest(
            script: args.script,
            inputJSON: args.inputJSON,
            timeout: min(args.timeout ?? Self.defaultTimeout, Self.maxTimeout),
            maxOutputBytes: min(args.maxOutputBytes ?? Self.defaultMaxOutputBytes, Self.maxOutputBytesCap)
        )
        let outcome = await service.run(request, cancellation: context.cancellation)

        switch outcome {
        case .ok(let resultJSON, let stdout, let stderr, let truncated, let stderrTruncated, let durationMs):
            var summary = "status=ok durationMs=\(durationMs) truncated=\(truncated) stderrTruncated=\(stderrTruncated)"
            if let resultJSON {
                summary += "\nresult=\(resultJSON)"
            }
            // Present stdout and stderr as distinct sections so the model
            // can tell normal output from warnings/errors (PRD JS-01).
            summary += "\n--- stdout ---\n" + stdout
            if !stderr.isEmpty {
                summary += "\n--- stderr ---\n" + stderr
            }
            return ToolExecutionOutput(summary: summary, fullOutputSHA256: Self.sha256Hex(of: summary))

        case .jsException(let message, let stdout):
            let full = "status=exception\nerror=\(message)\n" + stdout
            // A script error is a tool result the model can recover from,
            // not a tool-level failure: surface it as ok-with-error-status
            // so the model reads the message instead of a generic failure.
            return ToolExecutionOutput(summary: full, fullOutputSHA256: Self.sha256Hex(of: full), exitStatus: 1)

        case .timedOut(let afterMs, let partialStdout):
            let full = "status=timedOut afterMs=\(afterMs)\n" + partialStdout
            return ToolExecutionOutput(summary: full, fullOutputSHA256: Self.sha256Hex(of: full), exitStatus: 124)

        case .cancelled:
            throw FloeError.cancelled
        }
    }

    private static func sha256Hex(of text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
