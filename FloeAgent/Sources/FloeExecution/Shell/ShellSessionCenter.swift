// FloeExecution — Interactive local shell sessions.
// Mirrors InteractiveShellSessionService: run-scoped ownership, bounded
// output, sliding expiry and a session cap. The backend owns the process
// (an interactive sh, a REPL-like program, or a long-running script).

import Foundation
import FloeCore
import FloeTools

public actor ShellSessionCenter {
    public struct Configuration: Sendable {
        public var maximumSessions: Int
        public var sessionLifetime: TimeInterval
        public var maximumBufferBytes: Int

        public init(
            maximumSessions: Int = 4,
            sessionLifetime: TimeInterval = 30 * 60,
            maximumBufferBytes: Int = 256 * 1024
        ) {
            self.maximumSessions = maximumSessions
            self.sessionLifetime = sessionLifetime
            self.maximumBufferBytes = maximumBufferBytes
        }
    }

    private struct Entry {
        var sessionID: String
        var schedulerID: UUID
        var runID: UUID
        var expiresAt: Date
        var buffer: String
        var alive: Bool
    }

    private let backend: any LocalShellBackend
    private let policy: ShellCommandPolicy
    private let configuration: Configuration
    private var sessions: [String: Entry] = [:]
    private var pendingOpens = 0

    public init(
        backend: any LocalShellBackend,
        policy: ShellCommandPolicy = ShellCommandPolicy(),
        configuration: Configuration = Configuration()
    ) {
        self.backend = backend
        self.policy = policy
        self.configuration = configuration
    }

    public func activeSessionIDs(runID: UUID) -> [String] {
        sessions.values.filter { $0.runID == runID && $0.alive }.map(\.sessionID).sorted()
    }

    public func open(
        command: String,
        cwd: String,
        environment: [String: String],
        columns: Int,
        rows: Int,
        runID: UUID,
        rootURL: URL,
        cancellation: CancellationToken?,
        forTerminal: Bool = false
    ) async throws -> ShellOpenResult {
        try cancellation?.throwIfCancelled()
        try ShellInputValidation.validate(command: command, cwd: cwd, environment: environment)
        _ = try ShellInputValidation.directory(cwd: cwd, root: rootURL)
        if !command.isEmpty {
            let verdict = policy.evaluate(command)
            if verdict.stopped {
                throw FloeError.validationFailed(verdict.reason ?? "Command blocked by policy")
            }
        }
        guard sessions.count + pendingOpens < configuration.maximumSessions else {
            throw FloeError.validationFailed("Close an existing shell session before opening another")
        }
        pendingOpens += 1
        defer { pendingOpens -= 1 }
        let sessionID = UUID().uuidString.lowercased()
        let request = ShellOpenRequest(
            command: command,
            cwd: cwd,
            rootURL: rootURL,
            environment: environment,
            columns: max(20, min(columns, 500)),
            rows: max(5, min(rows, 200)),
            sessionID: sessionID,
            runID: runID
        )
        let result = try await backend.openSession(request, cancellation: cancellation)
        let entry = Entry(
            sessionID: sessionID,
            schedulerID: UUID(),
            runID: runID,
            expiresAt: Date().addingTimeInterval(configuration.sessionLifetime),
            buffer: "",
            alive: result.alive
        )
        if result.alive {
            sessions[sessionID] = entry
            await scheduleExpiry(for: sessionID, schedulerID: entry.schedulerID)
        } else {
            await backend.closeSession(sessionID: sessionID)
        }
        return ShellOpenResult(
            sessionID: sessionID,
            initialOutput: SecretRedactor.redact(ShellOutputSanitizer.sanitize(ShellInputValidation.prefix(result.initialOutput, maxBytes: configuration.maximumBufferBytes))),
            alive: result.alive,
            terminalOutput: forTerminal ? (result.terminalOutput ?? Data(result.initialOutput.utf8)) : nil
        )
    }

    public func exchange(
        sessionID: String,
        input: String?,
        waitMs: Int,
        maxBytes: Int,
        runID: UUID,
        cancellation: CancellationToken?,
        forTerminal: Bool = false
    ) async throws -> ShellExchangeResult {
        guard var entry = sessions[sessionID], entry.runID == runID else {
            throw FloeError.notFound("Unknown or expired shell session \(sessionID)")
        }
        try cancellation?.throwIfCancelled()
        if let input {
            try ShellInputValidation.validate(command: "", cwd: ".", environment: [:], stdin: input)
            let verdict = policy.evaluate(input)
            guard !verdict.stopped else { throw FloeError.validationFailed(verdict.reason ?? "Input blocked") }
        }
        let request = ShellExchangeRequest(
            sessionID: sessionID,
            input: input,
            waitMs: max(50, min(waitMs, 30_000)),
            maxBytes: max(1, min(maxBytes, configuration.maximumBufferBytes))
        )
        var result: ShellExchangeResult
        do {
            result = try await backend.exchangeSession(request, cancellation: cancellation)
        } catch {
            await close(sessionID: sessionID, runID: runID)
            throw error
        }
        guard sessions[sessionID]?.schedulerID == entry.schedulerID else {
            return ShellExchangeResult(output: "", alive: false, exitCode: result.exitCode)
        }
        entry.alive = result.alive
        entry.expiresAt = Date().addingTimeInterval(configuration.sessionLifetime)
        var drained = result.output
        if drained.utf8.count > configuration.maximumBufferBytes {
            drained = ShellInputValidation.prefix(drained, maxBytes: configuration.maximumBufferBytes)
        }
        let cleanOutput = SecretRedactor.redact(ShellOutputSanitizer.sanitize(drained))
        sessions[sessionID] = entry
        if entry.alive {
            await scheduleExpiry(for: sessionID, schedulerID: entry.schedulerID)
        } else {
            await close(sessionID: sessionID, runID: runID)
        }
        return ShellExchangeResult(output: cleanOutput, alive: result.alive, exitCode: result.exitCode, terminalOutput: forTerminal ? (result.terminalOutput ?? Data(result.output.utf8)) : nil)
    }

    public func close(sessionID: String, runID: UUID) async {
        guard let entry = sessions[sessionID], entry.runID == runID else { return }
        sessions.removeValue(forKey: sessionID)
        await SessionExpiryScheduler.shared.cancel(id: entry.schedulerID)
        await backend.closeSession(sessionID: sessionID)
    }

    public func signal(sessionID: String, signal: ShellSignal, runID: UUID) async {
        guard let entry = sessions[sessionID], entry.runID == runID else { return }
        await backend.signalSession(sessionID: sessionID, signal: signal)
    }

    public func resize(sessionID: String, columns: Int, rows: Int, runID: UUID) async {
        guard sessions[sessionID]?.runID == runID else { return }
        await backend.resizeSession(sessionID: sessionID, columns: max(20, min(columns, 500)), rows: max(5, min(rows, 200)))
    }

    public func closeAll(runID: UUID) async {
        let owned = sessions.values.filter { $0.runID == runID }
        for entry in owned {
            sessions.removeValue(forKey: entry.sessionID)
            await SessionExpiryScheduler.shared.cancel(id: entry.schedulerID)
            await backend.closeSession(sessionID: entry.sessionID)
        }
    }

    /// Closes every live session. Container teardown uses this hook; session
    /// tagging by container is applied when the run context carries an
    /// environment identifier.
    public func closeAllSessions() async {
        let all = Array(sessions.values)
        for entry in all {
            sessions.removeValue(forKey: entry.sessionID)
            await SessionExpiryScheduler.shared.cancel(id: entry.schedulerID)
            await backend.closeSession(sessionID: entry.sessionID)
        }
    }

    private func scheduleExpiry(for sessionID: String, schedulerID: UUID) async {
        await SessionExpiryScheduler.shared.schedule(id: schedulerID, after: configuration.sessionLifetime) { [weak self] in
            await self?.expire(sessionID: sessionID, schedulerID: schedulerID)
        }
    }

    private func expire(sessionID: String, schedulerID: UUID) async {
        guard let entry = sessions[sessionID], entry.schedulerID == schedulerID else { return }
        let remaining = entry.expiresAt.timeIntervalSinceNow
        if remaining > 0 {
            await SessionExpiryScheduler.shared.schedule(id: schedulerID, after: remaining) { [weak self] in
                await self?.expire(sessionID: sessionID, schedulerID: schedulerID)
            }
            return
        }
        sessions.removeValue(forKey: sessionID)
        await backend.closeSession(sessionID: sessionID)
    }
}
