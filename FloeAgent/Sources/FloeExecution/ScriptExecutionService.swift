// FloeExecution — Script execution contract.
// See docs/ARCHITECTURE_EXECUTION.md §3.1: a bounded, cancellable script
// run. The JavaScript implementation lives in JavaScriptEngine.swift;
// remote Python reuses the same outcome type.

import Foundation
import FloeTools

/// One bounded script execution.
public struct ScriptExecutionRequest: Sendable {
    /// Script source (≤64 KiB, same scale as toolArgumentsMaxBytes).
    public var script: String
    /// Optional JSON input, injected into the script as `input`.
    public var inputJSON: String?
    /// Wall-clock timeout. Expiry abandons the execution; the caller
    /// always returns on time.
    public var timeout: TimeInterval
    /// Maximum captured console output in bytes; excess is truncated.
    public var maxOutputBytes: Int

    public init(
        script: String,
        inputJSON: String? = nil,
        timeout: TimeInterval = 10,
        maxOutputBytes: Int = 64 * 1024
    ) {
        self.script = script
        self.inputJSON = inputJSON
        self.timeout = timeout
        self.maxOutputBytes = maxOutputBytes
    }
}

/// Terminal outcome of a script run. Never throws — every failure mode is
/// a value so tool wrappers can map it into ToolExecutionOutput directly.
public enum ScriptExecutionOutcome: Sendable, Equatable {
    /// Script finished. `resultJSON` is set when the script called
    /// `printJSON(value)`; `truncated` marks capped console output.
    /// `stderr` carries warn/error output, captured separately from
    /// `stdout` (PRD JS-01); `stderrTruncated` marks its own cap.
    case ok(
        resultJSON: String?,
        stdout: String,
        stderr: String,
        truncated: Bool,
        stderrTruncated: Bool,
        durationMs: Int
    )
    /// The script raised; `stdout` carries output captured before the throw.
    case jsException(message: String, stdout: String)
    /// Timeout expired; `partialStdout` is what the console captured.
    case timedOut(afterMs: Int, partialStdout: String)
    /// Cooperative cancellation won the race before completion.
    case cancelled
}

/// A script execution backend (JavaScriptCore, remote Python, …).
public protocol ScriptExecutionService: Sendable {
    /// Runs one script to a terminal outcome. Implementations must honor
    /// `request.timeout` and return within it plus a small margin, even
    /// when the script never yields.
    func run(
        _ request: ScriptExecutionRequest,
        cancellation: CancellationToken?
    ) async -> ScriptExecutionOutcome
}
