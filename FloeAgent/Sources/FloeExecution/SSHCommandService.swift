// FloeExecution — Generic remote shell command execution over SSH.
//
// Unlike RemotePythonService (which wraps scripts in `python3 -c`), this
// runs an arbitrary command line and returns the raw bounded result so the
// agent can drive the remote host directly (ls, grep, git, npm, …).

import Foundation
import FloeCore
import FloeTools
import FloeSSH

/// Executes arbitrary commands on a paired SSH host. Reuses the same
/// session/host closures as RemotePythonService so production wires them
/// from the shared host store; tests inject fakes.
public struct SSHCommandService: Sendable {
    public typealias SessionFactory = RemotePythonService.SessionFactory
    public typealias HostResolver = RemotePythonService.HostResolver
    public typealias DefaultHostProvider = RemotePythonService.DefaultHostProvider

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

    /// Runs `command` on the resolved host and returns the bounded result
    /// (non-zero exit is a value, not a throw — the agent reads exitCode).
    public func run(
        command: String,
        hostID: UUID?,
        timeout: TimeInterval = 30,
        maxOutputBytes: Int = 64 * 1024,
        cancellation: CancellationToken? = nil
    ) async throws -> SSHExecResult {
        if cancellation?.isCancelled == true { throw SSHExecError.cancelled }

        let resolvedID: UUID
        if let hostID {
            resolvedID = hostID
        } else if let fallback = try await defaultHostProvider() {
            resolvedID = fallback
        } else {
            throw RemotePythonError.noHostConfigured
        }
        guard try await hostResolver(resolvedID) != nil else {
            throw RemotePythonError.hostNotFound(resolvedID)
        }

        let session: any RemotePythonSession
        do {
            session = try await sessionFactory(resolvedID)
        } catch let error as RemotePythonError {
            throw error
        } catch {
            throw RemotePythonError.connectionFailed(
                SecretRedactor.redact(error.localizedDescription)
            )
        }
        return try await session.execute(
            command,
            timeout: timeout,
            maxOutputBytes: maxOutputBytes,
            cancellation: cancellation
        )
    }
}
