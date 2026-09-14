// FloeApp — nodejs-mobile runtime implementation of the NodeRuntime contract.

import Foundation
import FloeCore
import FloeExecution
import FloeTools

final class IOSSystemNodeRuntime: NodeRuntime, @unchecked Sendable {
    static let shared = IOSSystemNodeRuntime()

    var isAvailable: Bool { FloeNodeRuntimeAvailable() }

    func probe() async -> CapabilityState {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                if let version = FloeNodeRuntimeVersion() {
                    continuation.resume(returning: .available(version: "Node.js \(version)"))
                } else {
                    continuation.resume(returning: .unavailable(reason: String(localized: "settings.exec.node.unavailable")))
                }
            }
        }
    }

    struct ServiceResult: Sendable {
        let serviceID: String?
        let state: String
        let stdout: String
        let stderr: String
        let truncated: Bool

        init(_ response: [String: Any]) {
            serviceID = response["serviceID"] as? String
            state = response["status"] as? String ?? "unknown"
            let encoded = response["encoding"] as? String == "base64"
            func decode(_ key: String) -> String {
                let value = response[key] as? String ?? ""
                guard encoded else { return value }
                return Data(base64Encoded: value).map { String(decoding: $0, as: UTF8.self) } ?? ""
            }
            stdout = decode("stdout")
            stderr = decode("stderr")
            truncated = response["truncated"] as? Bool ?? false
        }
    }

    /// The returned worker ID is ownership, not proof of an HTTP endpoint.
    /// The service manager must probe readiness before exposing a preview URL.
    func startService(_ request: NodeRunRequest, environmentID: String) async -> ServiceResult {
        guard !environmentID.isEmpty,
              request.environment["FLOE_ENVIRONMENT_ID"] == environmentID,
              request.maxOutputBytes > 0,
              request.stdinFileDescriptor == nil else {
            return ServiceResult(["status": "invalid", "stderr": "A service needs an owning environment and cannot borrow foreground stdin"])
        }
        var message: [String: Any] = [
            "service": "start", "args": request.arguments,
            "cwd": request.workingDirectory.path, "env": request.environment,
            "stdin": Data((request.stdin ?? "").utf8).base64EncodedString(),
            // Required by the host request validator; services have no ordinary
            // command timer and are stopped by their manager instead.
            "timeoutMs": 10_000,
            "maxOutputBytes": min(request.maxOutputBytes, 1_048_576)
        ]
        if let entry = request.entryScript { message["entry"] = entry }
        return await serviceCommand(message, environmentID: environmentID)
    }

    func serviceStatus(id: String, environmentID: String) async -> ServiceResult {
        await serviceCommand(["service": "status", "serviceID": id], environmentID: environmentID)
    }

    func stopService(id: String, environmentID: String) async -> ServiceResult {
        await serviceCommand(["service": "stop", "serviceID": id], environmentID: environmentID)
    }

    func stopServices(environmentID: String) async throws {
        for id in FloeNodeServiceIDs(environmentID) {
            let result = await stopService(id: id, environmentID: environmentID)
            guard result.state == "stopped" || result.state == "notFound" else {
                throw FloeError.validationFailed("Node service has not stopped; environment data was retained")
            }
        }
    }

    private func serviceCommand(_ message: [String: Any], environmentID: String) async -> ServiceResult {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else {
            return ServiceResult(["status": "invalid", "stderr": "Invalid Node service request"])
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                guard let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continuation.resume(returning: ServiceResult(["status": "invalid"]))
                    return
                }
                continuation.resume(returning: ServiceResult(FloeNodeServiceCommand(request, environmentID) as? [String: Any] ?? [:]))
            }
        }
    }

    func run(_ request: NodeRunRequest, cancellation: CancellationToken?) async -> NodeRunOutcome {
        guard isAvailable else {
            return .failed(message: "The bundled Node.js runtime is not linked in this build")
        }
        guard request.maxOutputBytes > 0, request.timeout.isFinite, request.timeout > 0 else {
            return .failed(message: "Node output limit and timeout must be positive")
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
                    request.stdinFileDescriptor ?? -1,
                    request.timeout,
                    UInt(request.maxOutputBytes),
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
                case .OK:
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
            "npm_config_prefix": containerRoot.appendingPathComponent("usr").path,
            "npm_config_cache": containerRoot.appendingPathComponent("var/npm").path,
            "PNPM_HOME": containerRoot.appendingPathComponent("usr").path,
            "npm_config_store_dir": containerRoot.appendingPathComponent("opt/pnpm-store").path,
            "PWD": workspaceRoot.path
        ].merging(FloeTLSEnvironment()) { _, trust in trust }
    }
}
