import Foundation
import FloeCore
import FloeExecution
import FloeTools

private struct CPythonBridgeResponse: Sendable {
    var resultJSON: String?
    var status: String
    var stdout: String
    var stderr: String
    var error: String
    var truncated: Bool
    var stderrTruncated: Bool
    var durationMs: Int

    init(_ response: [String: Any]) {
        resultJSON = response["resultJSON"] as? String
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
    case cancelled
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
    private static let activeLock = NSLock()
    nonisolated(unsafe) private static var activeByEnvironment: [String: Int] = [:]
    nonisolated static func hasActiveWork(environmentID: String) -> Bool {
        activeLock.withLock { activeByEnvironment[environmentID, default: 0] > 0 }
            || FloeCPythonBridge.hasActiveServices(environmentID)
    }
    nonisolated private static func track(_ id: String?, delta: Int) {
        guard let id else { return }
        activeLock.withLock {
            let count = activeByEnvironment[id, default: 0] + delta
            if count > 0 { activeByEnvironment[id] = count } else { activeByEnvironment.removeValue(forKey: id) }
        }
    }
    private static let interpreterQueue = DispatchQueue(label: "org.floeagent.cpython", qos: .userInitiated)

    struct ServiceResult: Sendable {
        let serviceID: String?
        let state: String
        let stdout: String
        let stderr: String
        let error: String?
        let truncated: Bool
        init(_ response: [String: Any]) {
            serviceID = response["serviceID"] as? String
            state = response["status"] as? String ?? "unknown"
            func text(_ key: String) -> String {
                let value = response[key] as? String ?? ""
                guard response["encoding"] as? String == "base64" else { return value }
                return Data(base64Encoded: value).map { String(decoding: $0, as: UTF8.self) } ?? ""
            }
            stdout = text("stdout"); stderr = text("stderr")
            error = response["error"] as? String
            truncated = response["truncated"] as? Bool ?? false
        }
    }

    func startService(_ request: ScriptExecutionRequest, environmentID: String) async -> ServiceResult {
        guard !environmentID.isEmpty, request.pythonContext?.environmentID == environmentID,
              let context = request.pythonContext,
              let data = try? JSONEncoder().encode(context) else {
            return ServiceResult(["status": "invalid", "error": "A Python service needs an explicit owning environment"])
        }
        let json = String(decoding: data, as: UTF8.self)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: ServiceResult(FloeCPythonBridge.startService(
                    request.script, contextJSON: json, environmentID: environmentID,
                    maxOutputBytes: min(1_048_576, max(1, request.maxOutputBytes)))))
            }
        }
    }

    func serviceStatus(id: String, environmentID: String) -> ServiceResult {
        ServiceResult(FloeCPythonBridge.serviceStatus(id, environmentID: environmentID))
    }

    func stopService(id: String, environmentID: String) async -> ServiceResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: ServiceResult(FloeCPythonBridge.stopService(id, environmentID: environmentID)))
            }
        }
    }

    func stopServices(environmentID: String) async throws {
        let stopped = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: FloeCPythonBridge.stopServices(environmentID))
            }
        }
        guard stopped else { throw FloeError.validationFailed("Python services have not stopped; environment data was retained") }
    }

    func version() -> String? {
        try? FloeCPythonBridge.runtimeVersion()
    }

    func run(
        _ request: ScriptExecutionRequest,
        cancellation: CancellationToken?
    ) async -> ScriptExecutionOutcome {
        if cancellation?.isCancelled == true { return .cancelled }
        let gate = CPythonRaceGate()
        // The interactive tool clamps to 30s; jobs.submit background work may
        // legitimately run longer, so the runtime ceiling sits above both.
        let timeout = max(0.05, min(request.timeout, 600))
        let contextJSON = request.pythonContext.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }
        let deadline = Date().addingTimeInterval(timeout)
        Self.track(request.pythonContext?.environmentID, delta: 1)
        Self.interpreterQueue.async {
            defer { Self.track(request.pythonContext?.environmentID, delta: -1) }
            guard Date() < deadline else {
                Task { await gate.resolve(.timedOut(Int(timeout * 1_000))) }; return
            }
            if cancellation?.isCancelled == true {
                Task { await gate.resolve(.response(CPythonBridgeResponse(["status": "cancelled"]))) }
                return
            }
            let raw = FloeCPythonBridge.runScript(
                request.script,
                inputJSON: request.inputJSON,
                contextJSON: contextJSON,
                timeout: max(0.05, deadline.timeIntervalSinceNow),
                maxOutputBytes: request.maxOutputBytes,
                allowPackageInstaller: request.allowsManagedPackageInstaller,
                shouldCancel: { cancellation?.isCancelled == true }
            )
            let response = CPythonBridgeResponse(raw)
            Task { await gate.resolve(.response(response)) }
        }
        let watcher = Task.detached {
            while !Task.isCancelled && Date() < deadline {
                if cancellation?.isCancelled == true { await gate.resolve(.cancelled); return }
                do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
            }
            if !Task.isCancelled { await gate.resolve(.timedOut(Int(timeout * 1_000))) }
        }
        defer { watcher.cancel() }
        let raced = await gate.wait()
        if cancellation?.isCancelled == true { return .cancelled }
        if case .cancelled = raced { return .cancelled }
        guard case .response(let response) = raced else {
            if case .timedOut(let afterMs) = raced {
                return .timedOut(afterMs: afterMs, partialStdout: "")
            }
            return .timedOut(afterMs: Int(timeout * 1_000), partialStdout: "")
        }
        switch response.status {
        case "ok":
            return .ok(
                resultJSON: response.resultJSON,
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
