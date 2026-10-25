// FloeAndroidShellTools — Android platform mirror of the ORIGINAL
// FloeAgent/Sources/FloeExecution/Shell/ShellSessionCenter.swift.
// Every statement is byte-equal to the original except the deltas below:
//   A1 (owner threading, job-1bd4fcce5eca4856): `open(...)` gains ONE
//      trailing defaulted parameter `conversationID: UUID? = nil`, taken
//      from the caller's trusted `ToolContext.conversationID` by the
//      session tool (ShellSessionTools.swift mirror) and threaded
//      unchanged into `ShellOpenRequest`. The ORIGINAL DTO lacks the
//      owner field the engine `shell.start` payload requires; it is
//      NEVER inferred from session text. Every other ownership, expiry,
//      buffer, policy, redaction and lease rule is byte-equal.
// Dependencies `SessionExpiryScheduler` and `DesignGuestWriteGate` are the
// per-file ORIGINAL links in this module; the excluded iOS guest-shape
// helpers are documented in LocalShellBackend.swift (D1).
//
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
        /// Bounded wait for the engine's process-wide run gate when opening a
        /// session. Sessions and one-shot commands share one serial engine;
        /// an open that cannot acquire the gate in this window fails instead
        /// of running concurrently with another engine user.
        public var gateWaitTimeout: TimeInterval

        public init(
            maximumSessions: Int = 4,
            sessionLifetime: TimeInterval = 30 * 60,
            maximumBufferBytes: Int = 256 * 1024,
            gateWaitTimeout: TimeInterval = 5
        ) {
            self.maximumSessions = maximumSessions
            self.sessionLifetime = sessionLifetime
            self.maximumBufferBytes = maximumBufferBytes
            self.gateWaitTimeout = max(0.25, min(gateWaitTimeout, 30))
        }
    }

    private struct Entry {
        var sessionID: String
        var schedulerID: UUID
        var runID: UUID
        /// Runtime-issued identity of the client that OPENED this session
        /// (`run:<uuid>` for the main run, `child:<uuid>` for a delegated
        /// child; nil for legacy/UI callers that predate client identity).
        /// The parent and every delegated child of one task share the run id,
        /// so session access additionally requires an exact match on this
        /// identity: a sibling can learn a sessionID without ever being able
        /// to exchange, close, signal or resize that session. Nil is an
        /// identity like any other — a nil-owned session stays available to
        /// nil callers (the existing UI terminals) and is never reachable
        /// through a child's client id, and vice versa.
        var clientSessionID: String?
        var environmentLease: ToolEnvironmentLease
        var expiresAt: Date
        var buffer: String
        var alive: Bool
    }

    /// Outcome of a session-scoped operation (close/signal/resize). `applied`
    /// only ever means the caller's OWN session was reached; a live session
    /// owned by another client of the same run is `ownerMismatch` and is never
    /// dispatched to (so the other client's PTY is untouched).
    public enum AccessOutcome: Sendable, Equatable {
        case applied
        case notFound
        case ownerMismatch
    }

    /// Typed refusal thrown by `exchange` when the addressed session belongs
    /// to a different client of the same run: an explicit denial (surfaced to
    /// the model as `reason=session-owner-mismatch`), never a silent no-op and
    /// never another client's output.
    public struct OwnerMismatch: Error, LocalizedError, Equatable, Sendable {
        public let sessionID: String

        public init(sessionID: String) {
            self.sessionID = sessionID
        }

        public var errorDescription: String? {
            "session-owner-mismatch: session \(sessionID) is owned by another client of this run"
        }
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

    /// Opens a session owned by `clientSessionID` (the runtime-issued identity
    /// of the calling client; never a model-supplied value). Every later
    /// exchange/close/signal/resize must present the same identity, so a
    /// sibling client of the same run cannot reach this session even if it
    /// learns the id.
    public func open(
        command: String,
        cwd: String,
        environment: [String: String],
        columns: Int,
        rows: Int,
        runID: UUID,
        rootURL: URL,
        cancellation: CancellationToken?,
        forTerminal: Bool = false,
        toolEnvironment: ToolEnvironment? = nil,
        clientSessionID: String? = nil,
        conversationID: UUID? = nil,
        workspaceOperationID: UUID? = nil
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
        let lease = try await ToolEnvironmentRouting.shared.acquire(ToolContext(runID: runID, workspaceRootURL: rootURL, cancellation: cancellation ?? CancellationToken(), environmentID: toolEnvironment?.id, environment: toolEnvironment))
        let request = ShellOpenRequest(
            command: command,
            cwd: cwd,
            rootURL: rootURL,
            environment: environment,
            columns: max(20, min(columns, 500)),
            rows: max(5, min(rows, 200)),
            gateTimeout: configuration.gateWaitTimeout,
            sessionID: sessionID,
            runID: runID,
            toolEnvironment: lease.context.environment,
            conversationID: conversationID,   // A1 (see file header)
            workspaceOperationID: workspaceOperationID, // G04-R2 trusted UI operation lease (nil = unchanged path)
            prepareLinuxIfMissing: !forTerminal
        )
        let result: ShellOpenResult
        do { result = try await backend.openSession(request, cancellation: cancellation) }
        catch { await lease.finish(); throw error }
        let entry = Entry(
            sessionID: sessionID,
            schedulerID: UUID(),
            runID: runID,
            clientSessionID: clientSessionID,
            environmentLease: lease,
            expiresAt: Date().addingTimeInterval(configuration.sessionLifetime),
            buffer: "",
            alive: result.alive
        )
        if result.alive {
            sessions[sessionID] = entry
            await scheduleExpiry(for: sessionID, schedulerID: entry.schedulerID)
        } else {
            await backend.closeSession(sessionID: sessionID)
            await lease.finish()
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
        forTerminal: Bool = false,
        clientSessionID: String? = nil
    ) async throws -> ShellExchangeResult {
        guard var entry = sessions[sessionID], entry.runID == runID else {
            throw FloeError.notFound("Unknown or expired shell session \(sessionID)")
        }
        guard entry.clientSessionID == clientSessionID else {
            throw OwnerMismatch(sessionID: sessionID)
        }
        try cancellation?.throwIfCancelled()
        // Interactive input is user keystrokes on an already-approved session,
        // not a fresh command: it is never re-run through the command policy
        // (that would block ordinary typing such as fragments of a longer
        // line). The policy boundary stays where it belongs — the session's
        // opening command and one-shot exec.shell are still screened.
        var routedInput = input
        if routedInput == "\u{3}" {
            // Ctrl-C over a pipe is a byte, not a signal: route it to the
            // backend's cooperative interruption instead of writing it, so
            // the documented shell.exchange contract works without a PTY.
            await backend.signalSession(sessionID: sessionID, signal: .interrupt)
            routedInput = nil
        }
        if let input = routedInput {
            try ShellInputValidation.validate(command: "", cwd: ".", environment: [:], stdin: input)
        }
        let request = ShellExchangeRequest(
            sessionID: sessionID,
            input: routedInput,
            waitMs: max(50, min(waitMs, 30_000)),
            maxBytes: max(1, min(maxBytes, configuration.maximumBufferBytes))
        )
        var result: ShellExchangeResult
        do {
            result = try await backend.exchangeSession(request, cancellation: cancellation)
        } catch is CancellationError {
            // Cooperative cancellation of the VIEW's poll loop is not a
            // disconnect: keep the live session. The owner's explicit close()
            // closes it itself, and genuine backend errors still take the
            // branch below and tear the session down.
            throw CancellationError()
        } catch {
            await closeUnchecked(sessionID: sessionID)
            throw error
        }
        guard sessions[sessionID]?.schedulerID == entry.schedulerID else {
            return ShellExchangeResult(output: "", alive: false, exitCode: result.exitCode, failure: result.failure, bytesRead: result.bytesRead, bytesWritten: result.bytesWritten)
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
            await closeUnchecked(sessionID: sessionID)
        }
        return ShellExchangeResult(output: cleanOutput, alive: result.alive, exitCode: result.exitCode, terminalOutput: forTerminal ? (result.terminalOutput ?? Data(result.output.utf8)) : nil, failure: result.failure, bytesRead: result.bytesRead, bytesWritten: result.bytesWritten)
    }

    /// Closes the caller's own session. `ownerMismatch` means a live session
    /// with that id belongs to another client of the same run: nothing was
    /// closed and nothing was sent. `notFound` keeps the documented idempotent
    /// "safe to call more than once" contract for an unknown/expired session.
    @discardableResult
    public func close(
        sessionID: String,
        runID: UUID,
        clientSessionID: String? = nil
    ) async -> AccessOutcome {
        guard let entry = sessions[sessionID], entry.runID == runID else { return .notFound }
        guard entry.clientSessionID == clientSessionID else { return .ownerMismatch }
        sessions.removeValue(forKey: sessionID)
        await tearDown(entry)
        return .applied
    }

    /// Signals the caller's own session. A sibling client's live session is
    /// refused (`ownerMismatch`) before any signal reaches the backend, so one
    /// client's cross-cancel can never hit another client's process group.
    @discardableResult
    public func signal(
        sessionID: String,
        signal: ShellSignal,
        runID: UUID,
        clientSessionID: String? = nil
    ) async -> AccessOutcome {
        guard let entry = sessions[sessionID], entry.runID == runID else { return .notFound }
        guard entry.clientSessionID == clientSessionID else { return .ownerMismatch }
        await backend.signalSession(sessionID: sessionID, signal: signal)
        return .applied
    }

    @discardableResult
    public func resize(
        sessionID: String,
        columns: Int,
        rows: Int,
        runID: UUID,
        clientSessionID: String? = nil
    ) async -> AccessOutcome {
        guard let entry = sessions[sessionID], entry.runID == runID else { return .notFound }
        guard entry.clientSessionID == clientSessionID else { return .ownerMismatch }
        await backend.resizeSession(sessionID: sessionID, columns: max(20, min(columns, 500)), rows: max(5, min(rows, 200)))
        return .applied
    }

    /// Root-owned lifecycle cleanup: closes every session of the run,
    /// regardless of which client opened it. This is the trusted teardown
    /// entry (run/user stop, environment teardown), not a model call path, so
    /// it deliberately ignores client identity — it can always orderly close
    /// owned resources.
    public func closeAll(runID: UUID) async {
        let owned = sessions.values.filter { $0.runID == runID }
        for entry in owned {
            sessions.removeValue(forKey: entry.sessionID)
            await tearDown(entry)
        }
    }

    /// Closes every live session. Container teardown uses this hook; session
    /// tagging by container is applied when the run context carries an
    /// environment identifier.
    public func activeSessionIDs(environmentID: String) -> [String] {
        sessions.values.filter { $0.environmentLease.context.environmentID == environmentID && $0.alive }
            .map(\.sessionID).sorted()
    }

    public func activeSessionCount(environmentID: String) -> Int {
        sessions.values.filter { $0.environmentLease.context.environmentID == environmentID }.count
    }

    /// Environment teardown is a trusted root-owned lifecycle entry: it closes
    /// every session tagged with the environment, whichever client opened it.
    public func closeAll(environmentID: String) async {
        let owned = sessions.values.filter { $0.environmentLease.context.environmentID == environmentID }
        for entry in owned {
            sessions.removeValue(forKey: entry.sessionID)
            await tearDown(entry)
        }
    }

    /// Closes every live session regardless of run or client (trusted
    /// container teardown hook).
    public func closeAllSessions() async {
        let all = Array(sessions.values)
        for entry in all {
            sessions.removeValue(forKey: entry.sessionID)
            await tearDown(entry)
        }
    }

    /// Removes and tears down one session WITHOUT an ownership check. Only
    /// trusted callers may use it: a caller that already passed the ownership
    /// check (exchange's own cleanup when the session ended or errored), the
    /// session's expiry, and root-owned lifecycle cleanup (`closeAll*`), which
    /// must be able to orderly close owned resources regardless of client.
    private func closeUnchecked(sessionID: String) async {
        guard let entry = sessions.removeValue(forKey: sessionID) else { return }
        await tearDown(entry)
    }

    private func tearDown(_ entry: Entry) async {
        await SessionExpiryScheduler.shared.cancel(id: entry.schedulerID)
        await backend.closeSession(sessionID: entry.sessionID)
        await entry.environmentLease.finish()
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
        await tearDown(entry)
    }
}
