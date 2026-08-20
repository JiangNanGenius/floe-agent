import Foundation
import FloeCore
import FloeExecution
import FloeTools

private struct CPythonBridgeResponse: Sendable {
    var status: String
    var stdout: String
    var stderr: String
    var error: String
    var truncated: Bool
    var stderrTruncated: Bool
    var durationMs: Int

    init(_ response: [String: Any]) {
        status = response["status"] as? String ?? "exception"
        stdout = response["stdout"] as? String ?? ""
        stderr = response["stderr"] as? String ?? ""
        error = response["error"] as? String ?? "Unknown Python exception"
        truncated = response["truncated"] as? Bool ?? false
        stderrTruncated = response["stderrTruncated"] as? Bool ?? false
        durationMs = response["durationMs"] as? Int ?? 0
    }
}

private enum CPythonRaceResult: Sendable {
    case response(CPythonBridgeResponse)
    case timedOut(Int)
}

/// First-writer-wins handoff between the interpreter worker and the wall-clock
/// deadline. It deliberately does not wait for a C extension that ignores
/// Python tracing; that worker retains the GIL-bound cleanup responsibility.
private actor CPythonRaceGate {
    private var result: CPythonRaceResult?
    private var continuation: CheckedContinuation<CPythonRaceResult, Never>?

    func wait() async -> CPythonRaceResult {
        if let result { return result }
        return await withCheckedContinuation { continuation = $0 }
    }

    func resolve(_ candidate: CPythonRaceResult) {
        guard result == nil else { return }
        result = candidate
        continuation?.resume(returning: candidate)
        continuation = nil
    }
}

/// Serializes access to the single embedded CPython interpreter and maps the
/// Objective-C bridge's property-list response to Floe's execution contract.
actor CPythonLocalRuntime {
    static let shared = CPythonLocalRuntime()

    func version() -> String? {
        try? FloeCPythonBridge.runtimeVersion()
    }

    func run(
        _ request: ScriptExecutionRequest,
        cancellation: CancellationToken?
    ) async -> ScriptExecutionOutcome {
        if cancellation?.isCancelled == true { return .cancelled }
        let gate = CPythonRaceGate()
        let timeout = max(0.05, min(request.timeout, 30))
        Task.detached(priority: .userInitiated) {
            let raw = FloeCPythonBridge.runScript(
                request.script,
                inputJSON: request.inputJSON,
                timeout: timeout,
                maxOutputBytes: request.maxOutputBytes,
                allowPackageInstaller: request.allowsManagedPackageInstaller
            )
            await gate.resolve(.response(CPythonBridgeResponse(raw)))
        }
        Task.detached {
            try? await Task.sleep(for: .seconds(timeout))
            await gate.resolve(.timedOut(Int(timeout * 1_000)))
        }
        let raced = await gate.wait()
        if cancellation?.isCancelled == true { return .cancelled }
        guard case .response(let response) = raced else {
            if case .timedOut(let afterMs) = raced {
                return .timedOut(afterMs: afterMs, partialStdout: "")
            }
            return .timedOut(afterMs: Int(timeout * 1_000), partialStdout: "")
        }
        switch response.status {
        case "ok":
            return .ok(
                resultJSON: nil,
                stdout: response.stdout,
                stderr: response.stderr,
                truncated: response.truncated,
                stderrTruncated: response.stderrTruncated,
                durationMs: response.durationMs
            )
        case "timedOut":
            return .timedOut(afterMs: response.durationMs, partialStdout: response.stdout)
        default:
            return .jsException(
                message: response.error,
                stdout: response.stdout + (response.stderr.isEmpty ? "" : "\n--- stderr ---\n" + response.stderr)
            )
        }
    }
}

enum CPythonServiceFactory {
    static func make() -> LocalPythonService? {
        guard let version = try? FloeCPythonBridge.runtimeVersion() else { return nil }
        return LocalPythonService(version: "CPython \(version.split(separator: " ").first ?? "3.13")") {
            request, cancellation in
            await CPythonLocalRuntime.shared.run(request, cancellation: cancellation)
        }
    }
}
