// FloeApp — nodejs-mobile runtime implementation of the NodeRuntime contract.

import Foundation
import FloeCore
import FloeExecution
import FloeTools

final class IOSSystemNodeRuntime: NodeRuntime, @unchecked Sendable {
    static let shared = IOSSystemNodeRuntime()

    var isAvailable: Bool { FloeNodeRuntimeAvailable() }

    func run(_ request: NodeRunRequest, cancellation: CancellationToken?) async -> NodeRunOutcome {
        guard isAvailable else {
            return .failed(message: "The bundled Node.js runtime is not linked in this build")
        }
        if cancellation?.isCancelled == true { return .cancelled }
        let started = Date()
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var stdout: NSString?
                var stderr: NSString?
                var exitCode: Int32 = 0
                var truncated: ObjCBool = false
                let status = FloeNodeRun(
                    request.entryScript,
                    request.arguments,
                    request.workingDirectory.path,
                    request.environment,
                    request.stdin.map { Data($0.utf8) },
                    request.timeout,
                    request.maxOutputBytes,
                    { cancellation?.isCancelled == true },
                    &stdout,
                    &stderr,
                    &exitCode,
                    &truncated
                )
                if cancellation?.isCancelled == true {
                    continuation.resume(returning: .cancelled)
                    return
                }
                let durationMs = Int(Date().timeIntervalSince(started) * 1000)
                let out = (stdout as String?) ?? ""
                let err = (stderr as String?) ?? ""
                switch status {
                case .ok:
                    continuation.resume(returning: .exited(code: exitCode, stdout: out, stderr: err, durationMs: durationMs, truncated: truncated.boolValue))
                case .timedOut:
                    continuation.resume(returning: .timedOut(partialStdout: out, partialStderr: err, durationMs: durationMs))
                case .cancelled:
                    continuation.resume(returning: .cancelled)
                default:
                    continuation.resume(returning: .failed(message: err.isEmpty ? "The Node runtime is unavailable or still stopping" : err))
                }
            }
        }
    }

    /// Environment variables every Node invocation receives. Paths point at
    /// the active container; the caller may override them explicitly.
    static func defaultEnvironment(containerRoot: URL, workspaceRoot: URL) -> [String: String] {
        let nodeModules = containerRoot.appendingPathComponent("usr/lib/node_modules").path
        let bin = containerRoot.appendingPathComponent("usr/bin").path
        return [
            "HOME": containerRoot.appendingPathComponent("home").path,
            "TMPDIR": containerRoot.appendingPathComponent("tmp").path,
            "NODE_PATH": nodeModules,
            "PATH": "\(bin):/usr/local/bin:/usr/bin:/bin",
            "npm_config_cache": containerRoot.appendingPathComponent("var/npm").path,
            "PNPM_HOME": containerRoot.appendingPathComponent("usr").path,
            "npm_config_store_dir": containerRoot.appendingPathComponent("opt/pnpm-store").path,
            "PWD": workspaceRoot.path
        ]
    }
}
