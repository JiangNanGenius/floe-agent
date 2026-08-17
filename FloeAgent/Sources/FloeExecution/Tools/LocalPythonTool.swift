// FloeExecution — exec.localPython agent tool.

import Foundation
import Crypto
import FloeCore
import FloeTools

/// Runs bounded Python inside the app sandbox. This is intentionally marked
/// side-effecting: CPython shares the app process and container, so every
/// invocation requires a fresh human approval even in Full Access mode.
public struct LocalPythonTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var script: String
        public var inputJSON: String?
        public var timeout: Double?
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

    public static let name = "exec.localPython"
    public static let toolDescription =
        "Execute Python 3 in Floe's on-device app sandbox. No pip or runtime package downloads are available. stdout/stderr share a strict size cap; the cooperative bytecode deadline is at most 30 seconds."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "script": {"type": "string", "description": "Python source (max 64 KiB)"},
        "inputJSON": {"type": "string", "description": "Optional JSON value exposed as `input`"},
        "timeout": {"type": "number", "description": "Cooperative Python bytecode deadline in seconds (default 10, max 30)"},
        "maxOutputBytes": {"type": "integer", "description": "Combined output cap (default 65536, max 262144)"}
      },
      "required": ["script"],
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.executesLocalCode]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    static let maxScriptBytes = 64 * 1024
    static let defaultTimeout: TimeInterval = 10
    static let maxTimeout: TimeInterval = 30
    static let defaultMaxOutputBytes = 64 * 1024
    static let maxOutputBytesCap = 256 * 1024

    private let service: LocalPythonService

    public init(service: LocalPythonService) {
        self.service = service
    }

    public func validate(_ args: Arguments) throws {
        if args.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw FloeError.validationFailed("script must not be empty")
        }
        if Data(args.script.utf8).count > Self.maxScriptBytes {
            throw FloeError.validationFailed("script exceeds the \(Self.maxScriptBytes)-byte limit")
        }
        if let timeout = args.timeout, timeout <= 0 {
            throw FloeError.validationFailed("timeout must be > 0")
        }
        if let maxOutputBytes = args.maxOutputBytes, maxOutputBytes <= 0 {
            throw FloeError.validationFailed("maxOutputBytes must be > 0")
        }
        if let inputJSON = args.inputJSON,
           (try? JSONSerialization.jsonObject(with: Data(inputJSON.utf8))) == nil {
            throw FloeError.validationFailed("inputJSON must contain valid JSON")
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
            var full = "status=ok durationMs=\(durationMs) truncated=\(truncated) stderrTruncated=\(stderrTruncated)"
            if let resultJSON { full += "\nresult=\(resultJSON)" }
            full += "\n--- stdout ---\n\(stdout)"
            if !stderr.isEmpty { full += "\n--- stderr ---\n\(stderr)" }
            return Self.output(full, exitStatus: 0)
        case .jsException(let message, let stdout):
            return Self.output("status=exception\nerror=\(message)\n\(stdout)", exitStatus: 1)
        case .timedOut(let afterMs, let partialStdout):
            return Self.output("status=timedOut afterMs=\(afterMs)\n\(partialStdout)", exitStatus: 124)
        case .cancelled:
            throw FloeError.cancelled
        }
    }

    private static func output(_ text: String, exitStatus: Int32) -> ToolExecutionOutput {
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return ToolExecutionOutput(summary: text, fullOutputSHA256: digest, exitStatus: exitStatus)
    }
}
