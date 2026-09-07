// FloeExecution — Interactive SSH shell sessions (ssh.shell.*).
//
// Two interchangeable environments behind one session model: a direct SSH
// PTY (exec environment) and the Floe guardian's /v1/shell endpoints
// (execute environment). Sessions are run-scoped, expire after 30 minutes,
// and every output pass through SecretRedactor before reaching the model.

import Foundation
import FloeCore
import FloeSSH
import FloeTools

public enum InteractiveShellEnvironment: String, Sendable, Codable, CaseIterable {
    case direct
    case guardian
}

public struct InteractiveShellExchange: Sendable {
    public var output: String
    public var alive: Bool
    public var environment: InteractiveShellEnvironment

    public init(output: String, alive: Bool, environment: InteractiveShellEnvironment) {
        self.output = output
        self.alive = alive
        self.environment = environment
    }
}

/// Client seam for the guardian's /v1/shell endpoints (production wraps
/// RemoteAgentTaskService; tests inject a fake).
public struct GuardianShellClient: Sendable {
    public var open: @Sendable (_ hostID: UUID?, _ term: String, _ columns: Int, _ rows: Int) async throws -> (shellID: String, output: Data, alive: Bool)
    public var io: @Sendable (_ hostID: UUID?, _ shellID: String, _ input: Data?, _ waitMs: Int, _ maxBytes: Int, _ cancellation: CancellationToken?) async throws -> (output: Data, alive: Bool)
    public var close: @Sendable (_ hostID: UUID?, _ shellID: String) async throws -> Void

    public init(
        open: @escaping @Sendable (_ hostID: UUID?, _ term: String, _ columns: Int, _ rows: Int) async throws -> (shellID: String, output: Data, alive: Bool),
        io: @escaping @Sendable (_ hostID: UUID?, _ shellID: String, _ input: Data?, _ waitMs: Int, _ maxBytes: Int, _ cancellation: CancellationToken?) async throws -> (output: Data, alive: Bool),
        close: @escaping @Sendable (_ hostID: UUID?, _ shellID: String) async throws -> Void
    ) {
        self.open = open
        self.io = io
        self.close = close
    }
}

/// Run-scoped interactive shell sessions. Nothing is persisted or synced.
public actor InteractiveShellSessionService {
    public typealias DirectPTYFactory = @Sendable (_ hostID: UUID, _ term: String, _ columns: Int, _ rows: Int) async throws -> PTYSessionHandle
    public typealias DefaultHostProvider = RemotePythonService.DefaultHostProvider

    private struct Entry {
        var runID: UUID
        var environment: InteractiveShellEnvironment
        var pty: PTYSessionHandle?
        var guardianHostID: UUID?
        var guardianShellID: String?
        var buffer: Data
        var alive: Bool
        var expiresAt: Date
        var reader: Task<Void, Never>?
    }

    private static let maxBufferBytes = 256 * 1024
    private static let sessionLifetime: TimeInterval = 30 * 60

    private var sessions: [UUID: Entry] = [:]
    private var pendingOpens = 0
    private let directFactory: DirectPTYFactory
    private let defaultHostProvider: DefaultHostProvider
    private var guardian: GuardianShellClient?

    public init(
        directFactory: @escaping DirectPTYFactory,
        defaultHostProvider: @escaping DefaultHostProvider,
        guardian: GuardianShellClient? = nil
    ) {
        self.directFactory = directFactory
        self.defaultHostProvider = defaultHostProvider
        self.guardian = guardian
    }

    /// Attaches the guardian backend after construction (the client depends
    /// on CloudWorkspaceService, which is built later in app assembly).
    public func attachGuardian(_ client: GuardianShellClient) {
        self.guardian = client
    }

    public func open(
        runID: UUID,
        hostID: UUID?,
        environment: InteractiveShellEnvironment,
        term: String,
        columns: Int,
        rows: Int,
        cancellation: CancellationToken? = nil
    ) async throws -> (sessionID: UUID, output: String) {
        try cancellation?.throwIfCancelled()
        try Task.checkCancellation()
        guard sessions.count + pendingOpens < 16 else { throw FloeError.validationFailed("Close an existing Terminal session before opening another") }
        pendingOpens += 1
        defer { pendingOpens -= 1 }
        let id = UUID()
        switch environment {
        case .direct:
            let resolvedID: UUID
            if let hostID {
                resolvedID = hostID
            } else if let fallback = try await defaultHostProvider() {
                resolvedID = fallback
            } else {
                throw RemotePythonError.noHostConfigured
            }
            let pty = try await directFactory(resolvedID, term, columns, rows)
            do { try cancellation?.throwIfCancelled(); try Task.checkCancellation() }
            catch { await pty.close(); throw error }
            var entry = Entry(
                runID: runID, environment: .direct, pty: pty,
                guardianHostID: nil, guardianShellID: nil,
                buffer: Data(), alive: true,
                expiresAt: Date().addingTimeInterval(Self.sessionLifetime),
                reader: nil
            )
            let reader = Task { [weak self] in
                do {
                    for try await chunk in pty.output {
                        await self?.appendOutput(id, chunk)
                    }
                } catch {
                    // A closed/failed PTY marks the session dead; the next
                    // exchange reports alive=false instead of hanging.
                }
                await self?.markDead(id)
            }
            entry.reader = reader
            sessions[id] = entry
            scheduleExpiry(id)
            let banner = await drainAfter(id, wait: 0.5, maxBytes: 65_536)
            do { try cancellation?.throwIfCancelled(); try Task.checkCancellation() }
            catch { await close(runID: runID, sessionID: id); throw error }
            return (id, banner)

        case .guardian:
            guard let guardian else {
                throw FloeError.invalidConfiguration(
                    "The Floe guardian shell channel is unavailable on this device; use executionMode=direct or redeploy with ssh.bootstrapFloeRemoteAgent"
                )
            }
            let resolvedID: UUID
            if let hostID { resolvedID = hostID }
            else if let fallback = try await defaultHostProvider() { resolvedID = fallback }
            else { throw RemotePythonError.noHostConfigured }
            do {
                let opened = try await guardian.open(resolvedID, term, columns, rows)
                do { try cancellation?.throwIfCancelled(); try Task.checkCancellation() }
                catch { try? await guardian.close(resolvedID, opened.shellID); throw error }
                sessions[id] = Entry(
                    runID: runID, environment: .guardian, pty: nil,
                    guardianHostID: resolvedID, guardianShellID: opened.shellID,
                    buffer: Data(), alive: opened.alive,
                    expiresAt: Date().addingTimeInterval(Self.sessionLifetime),
                    reader: nil
                )
                scheduleExpiry(id)
                return (id, SecretRedactor.redact(String(decoding: opened.output, as: UTF8.self)))
            } catch {
                throw Self.guardianCapabilityError(error)
            }
        }
    }

    public func exchange(
        runID: UUID,
        sessionID: UUID,
        input: Data?,
        waitMs: Int,
        maxBytes: Int,
        cancellation: CancellationToken?
    ) async throws -> InteractiveShellExchange {
        try cancellation?.throwIfCancelled()
        guard let entry = sessions[sessionID], entry.runID == runID else {
            throw FloeError.notFound("Interactive shell session")
        }
        let boundedWait = min(max(waitMs, 50), 30_000)
        let boundedBytes = min(max(maxBytes, 1), 262_144)
        switch entry.environment {
        case .direct:
            if let input, !input.isEmpty, let pty = entry.pty {
                guard entry.alive else {
                    return InteractiveShellExchange(output: "", alive: false, environment: .direct)
                }
                try await pty.write(input)
            }
            let deadline = Date().addingTimeInterval(Double(boundedWait) / 1000)
            while Date() < deadline {
                if cancellation?.isCancelled == true { throw FloeError.cancelled }
                if let pending = takeBuffer(sessionID, maxBytes: boundedBytes), !pending.isEmpty {
                    return InteractiveShellExchange(
                        output: SecretRedactor.redact(String(decoding: pending, as: UTF8.self)),
                        alive: sessions[sessionID]?.alive ?? false,
                        environment: .direct
                    )
                }
                if sessions[sessionID]?.alive == false, bufferIsEmpty(sessionID) {
                    return InteractiveShellExchange(output: "", alive: false, environment: .direct)
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            let remaining = takeBuffer(sessionID, maxBytes: boundedBytes) ?? Data()
            return InteractiveShellExchange(
                output: SecretRedactor.redact(String(decoding: remaining, as: UTF8.self)),
                alive: sessions[sessionID]?.alive ?? false,
                environment: .direct
            )

        case .guardian:
            guard let guardian, let shellID = entry.guardianShellID else {
                throw FloeError.notFound("Interactive shell session")
            }
            do {
                let result = try await guardian.io(entry.guardianHostID, shellID, input, boundedWait, boundedBytes, cancellation)
                try cancellation?.throwIfCancelled()
                sessions[sessionID]?.alive = result.alive
                sessions[sessionID]?.expiresAt = Date().addingTimeInterval(Self.sessionLifetime)
                return InteractiveShellExchange(
                    output: SecretRedactor.redact(String(decoding: result.output, as: UTF8.self)),
                    alive: result.alive,
                    environment: .guardian
                )
            } catch {
                throw Self.guardianCapabilityError(error)
            }
        }
    }

    public func close(runID: UUID, sessionID: UUID) async {
        guard let entry = sessions[sessionID], entry.runID == runID else { return }
        sessions.removeValue(forKey: sessionID)
        entry.reader?.cancel()
        if let pty = entry.pty { await pty.close() }
        if let guardian, let shellID = entry.guardianShellID {
            try? await guardian.close(entry.guardianHostID, shellID)
        }
    }

    // MARK: - Buffer helpers (actor-isolated)

    private func appendOutput(_ sessionID: UUID, _ chunk: Data) {
        guard var entry = sessions[sessionID] else { return }
        entry.buffer.append(chunk)
        if entry.buffer.count > Self.maxBufferBytes {
            entry.buffer = entry.buffer.suffix(Self.maxBufferBytes)
        }
        entry.expiresAt = Date().addingTimeInterval(Self.sessionLifetime)
        sessions[sessionID] = entry
    }

    private func markDead(_ sessionID: UUID) {
        sessions[sessionID]?.alive = false
    }

    private func takeBuffer(_ sessionID: UUID, maxBytes: Int) -> Data? {
        guard var entry = sessions[sessionID], !entry.buffer.isEmpty else { return nil }
        let chunk = entry.buffer.prefix(maxBytes)
        entry.buffer.removeFirst(min(chunk.count, entry.buffer.count))
        sessions[sessionID] = entry
        return Data(chunk)
    }

    private func bufferIsEmpty(_ sessionID: UUID) -> Bool {
        sessions[sessionID]?.buffer.isEmpty ?? true
    }

    private func drainAfter(_ sessionID: UUID, wait: TimeInterval, maxBytes: Int) async -> String {
        let deadline = Date().addingTimeInterval(wait)
        while Date() < deadline {
            if let pending = takeBuffer(sessionID, maxBytes: maxBytes), !pending.isEmpty {
                return SecretRedactor.redact(String(decoding: pending, as: UTF8.self))
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return ""
    }

    private func scheduleExpiry(_ sessionID: UUID) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.sessionLifetime))
            guard let self else { return }
            await self.expire(sessionID)
        }
    }

    private func expire(_ sessionID: UUID) {
        guard let entry = sessions.removeValue(forKey: sessionID) else { return }
        entry.reader?.cancel()
        if let pty = entry.pty {
            Task { await pty.close() }
        }
        if let guardian, let shellID = entry.guardianShellID {
            Task { try? await guardian.close(entry.guardianHostID, shellID) }
        }
    }

    /// Old guardians lack /v1/shell; turn their 404 into an actionable error.
    private static func guardianCapabilityError(_ error: Error) -> Error {
        let message = String(describing: error).lowercased()
        if message.contains("not_found") || message.contains("404") {
            return FloeError.validationFailed(
                "The paired host's Floe guardian is too old for interactive shells (needs /v1/shell, guardian 1.4.4+). Redeploy it with ssh.bootstrapFloeRemoteAgent, then retry."
            )
        }
        return error
    }
}
