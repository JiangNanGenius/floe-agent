// FloeExecution — Remote Python execution over SSH.
// See docs/ARCHITECTURE_EXECUTION.md §3.2/§5.1: scripts run on a paired
// host via an exec channel (`python3 -`, script over stdin — the stdin
// path, no shell quoting). Host resolution, capability probing and the
// error mapping live here; the AgentTool wrapper is in
// Tools/RemotePythonTool.swift.

import Foundation
import FloeCore
import FloeTools
import FloeSSH
import FloePersistence

/// Structured failures for remote Python. Surfaced verbatim to the model
/// and UI (honest-unavailable rule — never a simulated success).
public enum RemotePythonError: Error, Sendable, Equatable, LocalizedError {
    /// No SSH host is configured at all.
    case noHostConfigured
    /// The requested host ID is not in the store.
    case hostNotFound(UUID)
    /// The host is reachable but has no python3 on PATH.
    case pythonNotFound(hostID: UUID)
    /// python3 exited non-zero; stderr is included for the model.
    case executionFailed(exitCode: Int32, stderr: String)
    /// A connection/auth/transport failure (SSH-level).
    case connectionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noHostConfigured:
            "No SSH host is configured for remote Python"
        case .hostNotFound(let id):
            "Host not found: \(id.uuidString)"
        case .pythonNotFound(let id):
            "python3 is not installed on host \(id.uuidString)"
        case .executionFailed(let code, let stderr):
            "python3 exited with status \(code): \(stderr)"
        case .connectionFailed(let detail):
            "SSH connection failed: \(detail)"
        }
    }
}

/// Executes Python on a paired host. Concrete connections are injected so
/// tests can run the full logic against an in-memory fake.
public struct RemotePythonService: Sendable {

    /// Opens an SSH session to a stored host. Production wires
    /// SSHConnectionService; tests return a fake session.
    public typealias SessionFactory = @Sendable (UUID) async throws -> any RemotePythonSession

    /// Resolves a stored host's display metadata (for probe messages).
    public typealias HostResolver = @Sendable (UUID) async throws -> RemotePythonHost?

    /// A stored host, projected to what the service needs.
    public struct RemotePythonHost: Sendable, Equatable {
        public var id: UUID
        public var displayName: String

        public init(id: UUID, displayName: String) {
            self.id = id
            self.displayName = displayName
        }
    }

    /// The first configured host, when the caller did not name one.
    public typealias DefaultHostProvider = @Sendable () async throws -> UUID?

    private let sessionFactory: SessionFactory
    private let hostResolver: HostResolver
    private let defaultHostProvider: DefaultHostProvider

    public init(
        sessionFactory: @escaping SessionFactory,
        hostResolver: @escaping HostResolver,
        defaultHostProvider: @escaping DefaultHostProvider
    ) {
        self.sessionFactory = sessionFactory
        self.hostResolver = hostResolver
        self.defaultHostProvider = defaultHostProvider
    }

    /// Resolves the target host ID: an explicit ID wins; otherwise the
    /// first configured host. No host at all → `.noHostConfigured`.
    public func resolveHostID(_ requested: UUID?) async throws -> UUID {
        if let requested { return requested }
        if let fallback = try await defaultHostProvider() { return fallback }
        throw RemotePythonError.noHostConfigured
    }

    /// Probes python3 on the host: `command -v python3 && python3
    /// --version`. Returns the version string, or nil when absent.
    public func detectPython3(hostID: UUID) async throws -> String? {
        guard try await hostResolver(hostID) != nil else {
            throw RemotePythonError.hostNotFound(hostID)
        }
        let session = try await sessionFactory(hostID)
        let result: SSHExecResult
        do {
            result = try await session.execute(
                "command -v python3 && python3 --version",
                timeout: 15,
                maxOutputBytes: 4096,
                cancellation: nil
            )
        } catch SSHExecError.cancelled {
            throw FloeError.cancelled
        } catch SSHExecError.timedOut {
            // A probe that times out is reported as "no python3" — the
            // capability is not verifiably present.
            return nil
        }
        guard result.exitCode == 0 else { return nil }
        let version = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? "python3" : version
    }

    /// Runs a Python script on the host. The script is base64-wrapped into
    /// a `python3 -c` one-liner (see SSHExecService header for why stdin is
    /// unavailable on iOS): no quoting issues, bytes travel verbatim.
    public func run(
        script: String,
        hostID: UUID?,
        timeout: TimeInterval = 30,
        maxOutputBytes: Int = 64 * 1024,
        cancellation: CancellationToken? = nil
    ) async throws -> ScriptExecutionOutcome {
        if cancellation?.isCancelled == true { return .cancelled }
        let resolvedID = try await resolveHostID(hostID)
        guard try await hostResolver(resolvedID) != nil else {
            throw RemotePythonError.hostNotFound(resolvedID)
        }
        guard let version = try await detectPython3(hostID: resolvedID) else {
            throw RemotePythonError.pythonNotFound(hostID: resolvedID)
        }
        _ = version

        let session = try await sessionFactory(resolvedID)
        let started = Date()
        let encoded = Data(script.utf8).base64EncodedString()
        // The gate sees a command containing "python3"; the payload is
        // opaque base64 so no injected quoting can break out.
        let command = "python3 -c \"import base64;exec(base64.b64decode('\(encoded)').decode())\""
        let result: SSHExecResult
        do {
            result = try await session.execute(
                command,
                timeout: timeout,
                maxOutputBytes: maxOutputBytes,
                cancellation: cancellation
            )
        } catch SSHExecError.cancelled {
            return .cancelled
        } catch SSHExecError.timedOut {
            return .timedOut(afterMs: Int(timeout * 1000), partialStdout: "")
        }

        let durationMs = Int(Date().timeIntervalSince(started) * 1000)
        guard result.exitCode == 0 else {
            throw RemotePythonError.executionFailed(
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
        return .ok(
            resultJSON: nil,
            stdout: result.stdout,
            truncated: result.truncated,
            durationMs: durationMs
        )
    }
}

/// The exec surface the service needs from an SSH session. The production
/// conformance forwards to `SSHSessionHandle.executeBounded`; tests
/// substitute an in-memory fake. There is no stdin parameter: iOS cannot
/// feed stdin over Citadel's public API (see SSHExecService header), so
/// scripts are delivered base64-wrapped via `python3 -c`.
public protocol RemotePythonSession: Sendable {
    func execute(
        _ command: String,
        timeout: TimeInterval,
        maxOutputBytes: Int,
        cancellation: CancellationToken?
    ) async throws -> SSHExecResult
}

/// Production conformance: delegates to the bounded exec helper.
extension SSHSessionHandle: RemotePythonSession {
    public func execute(
        _ command: String,
        timeout: TimeInterval,
        maxOutputBytes: Int,
        cancellation: CancellationToken?
    ) async throws -> SSHExecResult {
        try await executeBounded(
            command,
            timeout: timeout,
            maxOutputBytes: maxOutputBytes,
            cancellation: cancellation
        )
    }
}
