// FloeExecution — Pinned remote-SSH shell backend and router.
//
// A selected SSH environment must execute on its own pinned host, using the
// existing verified SSH lifecycle (SSHConnectionService / SSHSessionHandle and
// the Citadel raw command stream). It must never silently fall back to the
// iOS-native or Linux-guest backend, and the model-supplied request
// environment is not an authority for routing.
//
// Ownership boundaries:
//   * Environment records, pins, migrations and App composition live in the
//     primary/App lanes; this file consumes only the small target DTO below.
//   * `RemoteEnvironmentShellRouter` is the only routing point. It asks the
//     trusted resolver for the selected environment id and never reads
//     `request.environment` to choose a backend.
//   * The SSH connection is created by an injected factory built on the
//     existing `SSHCommandService` path; no new SSH client exists here.
//
// Source/static only in this lane: no build, resolve, test run, Simulator,
// device, commit, version or release.

import Foundation
import FloeCore
import FloeTools
import FloeSSH

// MARK: - Trusted target DTO

/// One immutable remote-SSH execution target, mapped by the primary/App lane
/// from its trusted environment registry/pin record. The root is a remote
/// POSIX path; it is never a local source path.
public struct SSHShellTarget: Sendable, Equatable, Hashable {
    public let hostID: UUID
    /// Absolute, normalized remote task root (for example
    /// `/home/alice/.floe/tasks/<task>`).
    public let remoteTaskRoot: String
    public let environmentID: String
    /// Primary's runtime/launch generation for the pin, used verbatim as an
    /// opaque canonical string. A later generation is a different target even
    /// when host and path are unchanged.
    public let generation: String

    public init?(
        hostID: UUID,
        remoteTaskRoot: String,
        environmentID: String,
        generation: String
    ) {
        guard let root = Self.normalizedRemoteRoot(remoteTaskRoot),
              !generation.isEmpty,
              !generation.contains("\0"),
              !generation.contains("\n"),
              !generation.contains("\r") else { return nil }
        let trimmedEnvironment = environmentID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEnvironment.isEmpty,
              trimmedEnvironment == environmentID,
              !environmentID.contains("\0"),
              !environmentID.contains("\n"),
              !environmentID.contains("\r") else { return nil }
        self.hostID = hostID
        self.remoteTaskRoot = root
        self.environmentID = environmentID
        self.generation = generation
    }

    /// Absolute, normalized POSIX path. Rejects a bare `/`, empty roots,
    /// `.`/`..` components, NUL and newlines. `//` and a trailing `/` are
    /// normalized away so the same target compares equal after registry
    /// round-trips.
    public static func normalizedRemoteRoot(_ raw: String) -> String? {
        guard raw.hasPrefix("/"),
              !raw.contains("\0"),
              !raw.contains("\n"),
              !raw.contains("\r") else { return nil }
        let parts = raw.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty,
              !parts.contains(where: { String($0) == "." || String($0) == ".." }) else { return nil }
        return "/" + parts.joined(separator: "/")
    }

    public var facts: SSHShellTargetFacts {
        SSHShellTargetFacts(
            environmentID: environmentID,
            hostID: hostID,
            remoteTaskRoot: remoteTaskRoot,
            generation: generation
        )
    }

    /// Stable identity used to detect a late session from an older generation.
    public var identityToken: String {
        "ssh:\(environmentID):\(generation):\(hostID.uuidString):\(remoteTaskRoot)"
    }
}

/// Facts the App can use to mark a tool/run as remote. App-native tools keep
/// their native policy; these facts grant no permission by themselves.
public struct SSHShellTargetFacts: Sendable, Equatable, Hashable {
    public let isRemote: Bool
    public let backendIdentifier: String
    public let environmentID: String
    public let hostID: UUID
    public let remoteTaskRoot: String
    public let generation: String

    public init(
        environmentID: String,
        hostID: UUID,
        remoteTaskRoot: String,
        generation: String
    ) {
        self.isRemote = true
        self.backendIdentifier = "remoteSSH"
        self.environmentID = environmentID
        self.hostID = hostID
        self.remoteTaskRoot = remoteTaskRoot
        self.generation = generation
    }
}

/// Trusted resolution of one environment id. `.notSSH` is the ONLY value
/// that may delegate to the existing default backend. `.unavailable` is an
/// explicit selected-SSH failure and must never fall through.
public enum SSHShellTargetResolution: Sendable, Equatable {
    case notSSH
    case ssh(SSHShellTarget)
    case unavailable(environmentID: String, reason: String)
}

public typealias SSHShellTargetResolver =
    @Sendable (_ environmentID: String) async -> SSHShellTargetResolution

// MARK: - Workspace synchronization seam

public enum RemoteWorkspaceSyncPhase: String, Sendable, Equatable {
    case beforeRun
    case afterRun
    case beforeOpen
    case afterClose
}

/// The existing App file bridge is the only place local source paths map to
/// remote task paths. A `beforeRun`/`beforeOpen` failure means nothing was
/// dispatched; an `afterRun` failure after a real command exit is reported as
/// unknown and must never rerun the command.
public struct RemoteWorkspaceSyncCallbacks: Sendable {
    public typealias Handler = @Sendable (
        _ target: SSHShellTarget,
        _ phase: RemoteWorkspaceSyncPhase,
        _ cancellation: CancellationToken?
    ) async throws -> Void

    public var handler: Handler?

    public init(handler: Handler? = nil) {
        self.handler = handler
    }

    public static let none = RemoteWorkspaceSyncCallbacks()
}

// MARK: - Limits

public struct RemoteEnvironmentShellLimits: Sendable, Equatable {
    /// Inline wrapper-script budget. A larger assembled script (command plus
    /// exports plus cleanup) is staged inside the remote task root.
    public var inlineCommandBytes: Int
    /// Base64 staging chunk sent as one remote command argument. Kept well
    /// below portable ARG_MAX with the rest of the command envelope.
    public var stagingChunkBytes: Int
    /// Hard ceiling for in-memory previews; the full output still goes to disk.
    public var previewBytesCeiling: Int
    /// Bounded PTY exchange buffer. Oldest bytes are dropped when exceeded.
    public var ptyBufferBytes: Int
    public var maximumSessions: Int
    public var stagingDirectoryName: String

    public init(
        inlineCommandBytes: Int = 48 * 1024,
        stagingChunkBytes: Int = 24 * 1024,
        previewBytesCeiling: Int = 1024 * 1024,
        ptyBufferBytes: Int = 256 * 1024,
        maximumSessions: Int = 8,
        stagingDirectoryName: String = ".floe-shell"
    ) {
        self.inlineCommandBytes = max(4096, min(inlineCommandBytes, 256 * 1024))
        self.stagingChunkBytes = max(4096, min(stagingChunkBytes, 48 * 1024))
        self.previewBytesCeiling = max(4096, min(previewBytesCeiling, 4 * 1024 * 1024))
        self.ptyBufferBytes = max(16 * 1024, min(ptyBufferBytes, 1024 * 1024))
        self.maximumSessions = max(1, min(maximumSessions, 16))
        let validStagingName =
            stagingDirectoryName.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
            && stagingDirectoryName != "."
            && stagingDirectoryName != ".."
            && !stagingDirectoryName.hasPrefix("-")
        self.stagingDirectoryName = validStagingName ? stagingDirectoryName : ".floe-shell"
    }
}

// MARK: - Testable SSH connection seam

/// The subset of a real SSH connection this backend needs. Production
/// conformance is `SSHSessionHandle`; tests substitute an in-memory fake.
public protocol SSHRemoteShellConnection: Sendable {
    var isConnected: Bool { get }
    func executeStreaming(
        _ command: String,
        deadline: SSHStreamExecDeadline,
        cancellation: CancellationToken?,
        maxPreviewBytes: Int,
        onOutput: @escaping @Sendable (SSHStreamChannel, Data) async throws -> Void
    ) async throws -> SSHStreamExecResult
    func openRemotePTY(term: String, columns: Int, rows: Int) async throws -> any SSHRemoteShellPTY
    func close() async
}

public protocol SSHRemoteShellPTY: Sendable {
    var output: AsyncThrowingStream<Data, Error> { get }
    func write(_ data: Data) async throws
    func resize(columns: Int, rows: Int) async throws
    func close() async
}

public typealias SSHShellSessionFactory =
    @Sendable (_ target: SSHShellTarget) async throws -> any SSHRemoteShellConnection

extension SSHSessionHandle: SSHRemoteShellConnection {
    public func openRemotePTY(
        term: String,
        columns: Int,
        rows: Int
    ) async throws -> any SSHRemoteShellPTY {
        try await openPTY(term: term, columns: columns, rows: rows)
    }
}

extension PTYSessionHandle: SSHRemoteShellPTY {}

// MARK: - Backend

/// Executes one pinned SSH target. The resolver is still stored so the type
/// conforms to `LocalShellBackend` for direct use; the router calls the
/// target-bound overloads after a single trusted resolution.
public actor RemoteEnvironmentShellBackend: LocalShellBackend {
    private struct Session {
        let target: SSHShellTarget
        let connection: any SSHRemoteShellConnection
        let pty: any SSHRemoteShellPTY
        var buffer: Data
        var alive: Bool
        var failure: String?
        var bytesRead: Int
        var bytesWritten: Int
        var reader: Task<Void, Never>?
    }

    private let resolver: SSHShellTargetResolver
    private let sessionFactory: SSHShellSessionFactory
    private let sync: RemoteWorkspaceSyncCallbacks
    private let limits: RemoteEnvironmentShellLimits
    private let outputRoot: URL?
    private var sessions: [String: Session] = [:]

    public init(
        resolver: @escaping SSHShellTargetResolver,
        sessionFactory: @escaping SSHShellSessionFactory,
        sync: RemoteWorkspaceSyncCallbacks = .none,
        limits: RemoteEnvironmentShellLimits = RemoteEnvironmentShellLimits(),
        outputRoot: URL? = nil
    ) {
        self.resolver = resolver
        self.sessionFactory = sessionFactory
        self.sync = sync
        self.limits = limits
        self.outputRoot = outputRoot
    }

    public func targetFacts(environmentID: String) async -> SSHShellTargetFacts? {
        let resolved = await resolver(environmentID)
        guard case .ssh(let target) = resolved,
              target.environmentID == environmentID else { return nil }
        return target.facts
    }

    // MARK: LocalShellBackend (direct use)

    public func run(
        _ request: ShellRunRequest,
        cancellation: CancellationToken?
    ) async -> ShellRunOutcome {
        guard let environmentID = request.toolEnvironment?.id else {
            return .failed(message: "SSH shell execution requires the selected environment id")
        }
        switch await resolver(environmentID) {
        case .notSSH:
            return .failed(message: "This environment is not a pinned SSH environment")
        case .unavailable(_, let reason):
            return .failed(message: reason)
        case .ssh(let target):
            guard target.environmentID == environmentID else {
                return .failed(message: "The trusted SSH target does not match the selected environment")
            }
            return await run(request, target: target, cancellation: cancellation)
        }
    }

    public func openSession(
        _ request: ShellOpenRequest,
        cancellation: CancellationToken?
    ) async throws -> ShellOpenResult {
        guard let environmentID = request.toolEnvironment?.id else {
            throw FloeError.validationFailed("SSH terminal execution requires the selected environment id")
        }
        switch await resolver(environmentID) {
        case .notSSH:
            throw FloeError.validationFailed("This environment is not a pinned SSH environment")
        case .unavailable(_, let reason):
            throw FloeError.validationFailed(reason)
        case .ssh(let target):
            guard target.environmentID == environmentID else {
                throw FloeError.validationFailed("The trusted SSH target does not match the selected environment")
            }
            return try await openSession(request, target: target, cancellation: cancellation)
        }
    }

    public func exchangeSession(
        _ request: ShellExchangeRequest,
        cancellation: CancellationToken?
    ) async throws -> ShellExchangeResult {
        guard let session = sessions[request.sessionID] else {
            throw FloeError.notFound("SSH terminal session")
        }
        switch await resolver(session.target.environmentID) {
        case .ssh(let current) where current == session.target:
            return try await exchangeSession(request, target: session.target, cancellation: cancellation)
        default:
            await closeSession(sessionID: request.sessionID)
            throw FloeError.validationFailed(
                "This SSH terminal belongs to an earlier environment generation or an unavailable target. It was closed; reopen the terminal. Its output was not routed to a different backend.")
        }
    }

    public func closeSession(sessionID: String) async {
        guard let session = sessions.removeValue(forKey: sessionID) else { return }
        session.reader?.cancel()
        await session.pty.close()
        await session.connection.close()
        if let handler = sync.handler {
            try? await handler(session.target, .afterClose, nil)
        }
    }

    public func signalSession(sessionID: String, signal: ShellSignal) async {
        guard let session = sessions[sessionID] else { return }
        guard await sessionIsCurrent(session.target) else {
            await closeSession(sessionID: sessionID)
            return
        }
        switch signal {
        case .interrupt:
            do { try await session.pty.write(Data([0x03])) }
            catch { markSessionDead(sessionID: sessionID, failure: SecretRedactor.redact(error.localizedDescription)) }
        case .terminate, .kill:
            // Citadel's public PTY surface exposes write/resize/close only;
            // there is no POSIX signal or session-id call. Ctrl-C interrupts
            // the foreground job, then closing the owned channel terminates
            // the session and its process group (SIGHUP). The session reports
            // alive=false and keeps its buffered output for a final exchange.
            try? await session.pty.write(Data([0x03]))
            markSessionDead(sessionID: sessionID, failure: nil)
            await session.pty.close()
            await session.connection.close()
        }
    }

    public func resizeSession(sessionID: String, columns: Int, rows: Int) async {
        guard let session = sessions[sessionID] else { return }
        guard await sessionIsCurrent(session.target) else {
            await closeSession(sessionID: sessionID)
            return
        }
        try? await session.pty.resize(columns: columns, rows: rows)
    }

    private func sessionIsCurrent(_ target: SSHShellTarget) async -> Bool {
        let resolved = await resolver(target.environmentID)
        if case .ssh(let current) = resolved { return current == target }
        return false
    }

    // MARK: Target-bound run

    public func run(
        _ request: ShellRunRequest,
        target: SSHShellTarget,
        cancellation: CancellationToken?
    ) async -> ShellRunOutcome {
        let started = ContinuousClock.now
        guard let environmentID = request.toolEnvironment?.id,
              environmentID == target.environmentID else {
            return .failed(message: "The trusted SSH target does not match the selected environment; nothing was executed")
        }
        if cancellation?.isCancelled == true || Task.isCancelled { return .cancelled }
        guard !request.command.contains("\0") else {
            return .failed(message: "The remote command contains NUL; nothing was executed")
        }
        if let reason = Self.environmentValidationFailure(request.environment) {
            return .failed(message: reason)
        }
        let directory: String
        do {
            directory = try Self.remoteDirectory(root: target.remoteTaskRoot, cwd: request.cwd)
        } catch {
            return .failed(message: "The remote working directory is invalid: \(Self.safe(error))")
        }
        if let handler = sync.handler {
            do {
                try await handler(target, .beforeRun, cancellation)
            } catch {
                if cancellation?.isCancelled == true || Task.isCancelled { return .cancelled }
                return .notStarted(
                    reason: "Workspace synchronization before the remote command failed: \(Self.safe(error)). Nothing ran on the selected SSH host or any fallback backend.")
            }
        }
        let jobID = request.runID.map { "\($0.uuidString.lowercased())-\(UUID().uuidString.lowercased())" }
            ?? UUID().uuidString.lowercased()
        let log: RemoteShellOutputLog
        do {
            log = try RemoteShellOutputLog.create(root: outputRoot ?? request.rootURL, jobID: jobID)
        } catch {
            return .failed(
                message: "The full remote output could not be saved, so the command was not executed: \(Self.safe(error))")
        }
        defer { log.close() }

        let connection: any SSHRemoteShellConnection
        do {
            connection = try await sessionFactory(target)
        } catch {
            if cancellation?.isCancelled == true || Task.isCancelled { return .cancelled }
            return .notStarted(
                reason: "The selected SSH host \(target.hostID.uuidString) could not be connected: \(Self.safe(error)). Nothing ran on a different backend.")
        }
        guard connection.isConnected else {
            await connection.close()
            return .notStarted(
                reason: "The selected SSH host \(target.hostID.uuidString) is not connected; nothing was executed and no fallback backend was used.")
        }

        let previewLimit = min(max(1, request.maxOutputBytes), limits.previewBytesCeiling)
        let collector = RemoteShellPreviewCollector(limit: previewLimit)
        let outcome = await performRun(
            request,
            target: target,
            directory: directory,
            connection: connection,
            log: log,
            collector: collector,
            previewLimit: previewLimit,
            jobID: jobID,
            started: started,
            cancellation: cancellation
        )
        await connection.close()
        return outcome
    }

    private func performRun(
        _ request: ShellRunRequest,
        target: SSHShellTarget,
        directory: String,
        connection: any SSHRemoteShellConnection,
        log: RemoteShellOutputLog,
        collector: RemoteShellPreviewCollector,
        previewLimit: Int,
        jobID: String,
        started: ContinuousClock.Instant,
        cancellation: CancellationToken?
    ) async -> ShellRunOutcome {
        var stagedPaths: [String] = []
        do {
            let stdinPath: String?
            if let stdin = request.stdin, !stdin.isEmpty {
                let path = Self.stagingPath(target: target, suffix: ".stdin", limits: limits)
                stagedPaths.append(path)
                stagedPaths.append(path + ".b64")
                guard let budget = Self.remainingBudget(request.deadline, since: started) else {
                    throw RemoteShellPreparationFailure.deadlineExhausted
                }
                try await Self.stageRemoteFile(
                    Data(stdin.utf8),
                    remotePath: path,
                    target: target,
                    limits: limits,
                    connection: connection,
                    budget: budget,
                    cancellation: cancellation
                )
                stdinPath = path
            } else {
                stdinPath = nil
            }

            let requestEnvironment = Self.sanitizedRequestEnvironment(request.environment)
            let trustedEnvironment = Self.trustedEnvironment(target)
            var body = Self.wrapperScript(
                directory: directory,
                command: request.command,
                requestEnvironment: requestEnvironment,
                trustedEnvironment: trustedEnvironment,
                stdinPath: stdinPath,
                scriptPath: nil
            )
            let commandLine: String
            if body.utf8.count > limits.inlineCommandBytes {
                let path = Self.stagingPath(target: target, suffix: ".sh", limits: limits)
                stagedPaths.append(path)
                stagedPaths.append(path + ".b64")
                body = Self.wrapperScript(
                    directory: directory,
                    command: request.command,
                    requestEnvironment: requestEnvironment,
                    trustedEnvironment: trustedEnvironment,
                    stdinPath: stdinPath,
                    scriptPath: path
                )
                guard let budget = Self.remainingBudget(request.deadline, since: started) else {
                    throw RemoteShellPreparationFailure.deadlineExhausted
                }
                try await Self.stageRemoteFile(
                    Data(body.utf8),
                    remotePath: path,
                    target: target,
                    limits: limits,
                    connection: connection,
                    budget: budget,
                    cancellation: cancellation
                )
                commandLine = "exec /bin/sh \(Self.shellQuote(path))"
            } else {
                commandLine = body
            }

            guard let budget = Self.remainingBudget(request.deadline, since: started) else {
                throw RemoteShellPreparationFailure.deadlineExhausted
            }
            guard connection.isConnected else {
                await Self.cleanupRemoteFiles(stagedPaths, connection: connection)
                return .notStarted(
                    reason: "The SSH connection disconnected before dispatch; nothing was executed and no fallback backend was used.")
            }
            let result: SSHStreamExecResult
            do {
                result = try await connection.executeStreaming(
                    commandLine,
                    deadline: budget,
                    cancellation: cancellation,
                    maxPreviewBytes: previewLimit,
                    onOutput: { channel, data in
                        collector.append(channel, data)
                        try log.append(data)
                    }
                )
            } catch let failure as SSHStreamExecFailure {
                await Self.cleanupRemoteFiles(stagedPaths, connection: connection)
                return Self.mapStreamFailure(
                    failure,
                    dispatched: true,
                    collector: collector,
                    log: log,
                    jobID: jobID,
                    started: started
                )
            } catch is CancellationError {
                await Self.cleanupRemoteFiles(stagedPaths, connection: connection)
                return .outcomeUnknown(jobID: jobID,
                    message: "The SSH connection closed after dispatch. The remote operation may still be running; inspect the saved output at \(log.url.path) before retrying.")
            } catch {
                await Self.cleanupRemoteFiles(stagedPaths, connection: connection)
                return .outcomeUnknown(
                    jobID: jobID,
                    message: "The SSH stream failed after the command was dispatched: \(Self.safe(error)). The command may have run; inspect the saved output at \(log.url.path) and do not rerun it.")
            }

            await Self.cleanupRemoteFiles(stagedPaths, connection: connection)

            if let handler = sync.handler {
                do {
                    try await handler(target, .afterRun, cancellation)
                } catch {
                    return .outcomeUnknown(
                        jobID: jobID,
                        message: "The remote command finished with exit code \(result.exitCode), but workspace synchronization failed: \(Self.safe(error)). Its full output is saved at \(log.url.path); do not rerun the command. Retry the file sync from the saved job.")
                }
            }

            var stderr = String(decoding: result.stderrPreview, as: UTF8.self)
            if result.stdoutTruncated || result.stderrTruncated {
                if !stderr.isEmpty { stderr += "\n" }
                stderr += "Full remote output: \(log.url.path)"
            }
            let durationMs = Self.milliseconds(started.duration(to: .now))
            return .exited(
                code: result.exitCode,
                stdout: String(decoding: result.stdoutPreview, as: UTF8.self),
                stderr: stderr,
                truncated: result.stdoutTruncated,
                stderrTruncated: result.stderrTruncated,
                durationMs: durationMs
            )
        } catch let failure as RemoteShellPreparationFailure {
            await Self.cleanupRemoteFiles(stagedPaths, connection: connection)
            switch failure {
            case .deadlineExhausted:
                return .timedOut(
                    partialStdout: "",
                    partialStderr: "The execution deadline was exhausted while preparing the remote command; the command was not dispatched. Full remote output: \(log.url.path)",
                    durationMs: Self.milliseconds(started.duration(to: .now))
                )
            case .stagingFailed(let detail):
                return .notStarted(
                    reason: "The remote command could not be staged inside the pinned task root: \(detail). The command was not dispatched and nothing ran on a fallback backend.")
            }
        } catch FloeError.cancelled {
            await Self.cleanupRemoteFiles(stagedPaths, connection: connection)
            return .cancelled
        } catch is CancellationError {
            await Self.cleanupRemoteFiles(stagedPaths, connection: connection)
            return .cancelled
        } catch {
            await Self.cleanupRemoteFiles(stagedPaths, connection: connection)
            return .failed(message: "The remote command could not be prepared: \(Self.safe(error))")
        }
    }

    // MARK: Target-bound PTY

    public func openSession(
        _ request: ShellOpenRequest,
        target: SSHShellTarget,
        cancellation: CancellationToken?
    ) async throws -> ShellOpenResult {
        guard let environmentID = request.toolEnvironment?.id,
              environmentID == target.environmentID else {
            throw FloeError.validationFailed("The trusted SSH target does not match the selected environment")
        }
        if cancellation?.isCancelled == true || Task.isCancelled { throw FloeError.cancelled }
        guard !request.command.contains("\0") else {
            throw FloeError.validationFailed("The SSH terminal command contains NUL")
        }
        guard sessions.count < limits.maximumSessions else {
            throw FloeError.validationFailed("Close an existing SSH terminal before opening another")
        }
        guard sessions[request.sessionID] == nil else {
            throw FloeError.validationFailed("This SSH terminal id is already open")
        }
        if let reason = Self.environmentValidationFailure(request.environment) {
            throw FloeError.validationFailed(reason)
        }
        let directory: String
        do {
            directory = try Self.remoteDirectory(root: target.remoteTaskRoot, cwd: request.cwd)
        } catch {
            throw FloeError.validationFailed("The remote working directory is invalid: \(Self.safe(error))")
        }
        if let handler = sync.handler {
            do {
                try await handler(target, .beforeOpen, cancellation)
            } catch {
                if cancellation?.isCancelled == true || Task.isCancelled { throw FloeError.cancelled }
                throw FloeError.syncUnavailable(
                    "Workspace synchronization before opening the SSH terminal failed: \(Self.safe(error))")
            }
        }
        if cancellation?.isCancelled == true || Task.isCancelled { throw FloeError.cancelled }
        let connection: any SSHRemoteShellConnection
        do {
            connection = try await sessionFactory(target)
        } catch {
            if cancellation?.isCancelled == true || Task.isCancelled { throw FloeError.cancelled }
            throw FloeError.validationFailed(
                "The selected SSH host \(target.hostID.uuidString) could not be connected: \(Self.safe(error))")
        }
        guard connection.isConnected else {
            await connection.close()
            throw FloeError.validationFailed(
                "The selected SSH host \(target.hostID.uuidString) is not connected")
        }
        let pty: any SSHRemoteShellPTY
        do {
            pty = try await connection.openRemotePTY(
                term: "xterm-256color",
                columns: max(20, min(request.columns, 500)),
                rows: max(5, min(request.rows, 200))
            )
        } catch {
            await connection.close()
            if cancellation?.isCancelled == true || Task.isCancelled { throw FloeError.cancelled }
            throw FloeError.validationFailed("The SSH terminal could not be opened: \(Self.safe(error))")
        }
        if cancellation?.isCancelled == true || Task.isCancelled {
            await pty.close()
            await connection.close()
            throw FloeError.cancelled
        }
        let sessionID = request.sessionID
        sessions[sessionID] = Session(
            target: target,
            connection: connection,
            pty: pty,
            buffer: Data(),
            alive: true,
            failure: nil,
            bytesRead: 0,
            bytesWritten: 0,
            reader: nil
        )
        let reader = Task { [weak self, pty] in
            do {
                for try await chunk in pty.output {
                    await self?.appendOutput(sessionID: sessionID, chunk: chunk)
                }
                await self?.markSessionDead(sessionID: sessionID, failure: nil)
            } catch {
                await self?.markSessionDead(
                    sessionID: sessionID,
                    failure: SecretRedactor.redact(error.localizedDescription))
            }
        }
        if var stored = sessions[sessionID] {
            stored.reader = reader
            sessions[sessionID] = stored
        }

        if !request.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // The remote login shell may be zsh/bash/sh or even fish/csh, so
            // do not inject POSIX `export` syntax into it. `env` carries the
            // trusted facts and the requested variables for the command's
            // /bin/sh child; `cd` and `exec` are accepted by the common shells.
            let assignments = Self.environmentAssignments(
                Self.trustedEnvironment(target)
                    .merging(Self.sanitizedRequestEnvironment(request.environment)) { trusted, _ in trusted }
            )
            let bootstrap = "cd \(Self.shellQuote(directory)) || exit 126; "
                + "exec /usr/bin/env \(assignments) /bin/sh -c \(Self.shellQuote(request.command))\n"
            do {
                try await pty.write(Data(bootstrap.utf8))
                addBytesWritten(sessionID: sessionID, count: bootstrap.utf8.count)
            } catch {
                await closeSession(sessionID: sessionID)
                if cancellation?.isCancelled == true || Task.isCancelled { throw FloeError.cancelled }
                throw FloeError.validationFailed("The SSH terminal command could not be started: \(Self.safe(error))")
            }
        } else {
            // Keep the real interactive shell (its own startup files and
            // prompt); only position it at the task root. No POSIX-only
            // export syntax is injected into an unknown login shell.
            let bootstrap = "cd \(Self.shellQuote(directory))\n"
            do {
                try await pty.write(Data(bootstrap.utf8))
                addBytesWritten(sessionID: sessionID, count: bootstrap.utf8.count)
            } catch {
                await closeSession(sessionID: sessionID)
                if cancellation?.isCancelled == true || Task.isCancelled { throw FloeError.cancelled }
                throw FloeError.validationFailed("The SSH terminal could not be positioned at the task root: \(Self.safe(error))")
            }
        }

        let initial = await waitForInitialOutput(sessionID: sessionID, waitMs: 400, maxBytes: 16 * 1024)
        if cancellation?.isCancelled == true || Task.isCancelled {
            await closeSession(sessionID: sessionID)
            throw FloeError.cancelled
        }
        let alive = sessions[sessionID]?.alive ?? false
        if !alive { await closeSession(sessionID: sessionID) }
        return ShellOpenResult(
            sessionID: sessionID,
            initialOutput: String(decoding: initial, as: UTF8.self),
            alive: alive,
            terminalOutput: initial
        )
    }

    public func exchangeSession(
        _ request: ShellExchangeRequest,
        target: SSHShellTarget,
        cancellation: CancellationToken?
    ) async throws -> ShellExchangeResult {
        guard let session = sessions[request.sessionID], session.target == target else {
            throw FloeError.notFound("SSH terminal session for this target")
        }
        if cancellation?.isCancelled == true { throw FloeError.cancelled }
        if let input = request.input, !input.isEmpty {
            let bytes = Data(input.utf8)
            switch input {
            case "\u{03}":
                do {
                    try await session.pty.write(Data([0x03]))
                    addBytesWritten(sessionID: request.sessionID, count: 1)
                } catch {
                    markSessionDead(sessionID: request.sessionID, failure: Self.safe(error))
                }
            case "\u{04}":
                do {
                    try await session.pty.write(Data([0x04]))
                    addBytesWritten(sessionID: request.sessionID, count: 1)
                } catch {
                    markSessionDead(sessionID: request.sessionID, failure: Self.safe(error))
                }
            default:
                do {
                    try await session.pty.write(bytes)
                    addBytesWritten(sessionID: request.sessionID, count: bytes.count)
                } catch {
                    markSessionDead(sessionID: request.sessionID, failure: Self.safe(error))
                }
            }
        }
        let waitMs = max(0, min(request.waitMs, 30_000))
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(waitMs))
        while ContinuousClock.now < deadline {
            if cancellation?.isCancelled == true { throw FloeError.cancelled }
            guard let current = sessions[request.sessionID] else {
                throw FloeError.notFound("SSH terminal session")
            }
            if !current.buffer.isEmpty || !current.alive { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        guard var current = sessions[request.sessionID] else {
            throw FloeError.notFound("SSH terminal session")
        }
        let limit = max(1, min(request.maxBytes, 262_144))
        let data = Data(current.buffer.prefix(limit))
        current.buffer.removeFirst(data.count)
        sessions[request.sessionID] = current
        return ShellExchangeResult(
            output: String(decoding: data, as: UTF8.self),
            alive: current.alive,
            exitCode: nil,
            terminalOutput: data,
            failure: current.failure,
            bytesRead: current.bytesRead,
            bytesWritten: current.bytesWritten
        )
    }

    // MARK: Session bookkeeping (actor-isolated)

    private func appendOutput(sessionID: String, chunk: Data) {
        guard var session = sessions[sessionID] else { return }
        session.bytesRead += chunk.count
        session.buffer.append(chunk)
        if session.buffer.count > limits.ptyBufferBytes {
            session.buffer = Data(session.buffer.suffix(limits.ptyBufferBytes))
        }
        session.alive = true
        sessions[sessionID] = session
    }

    private func markSessionDead(sessionID: String, failure: String?) {
        guard var session = sessions[sessionID] else { return }
        session.alive = false
        if let failure, session.failure == nil { session.failure = failure }
        sessions[sessionID] = session
    }

    private func addBytesWritten(sessionID: String, count: Int) {
        guard var session = sessions[sessionID] else { return }
        session.bytesWritten += count
        sessions[sessionID] = session
    }

    private func waitForInitialOutput(sessionID: String, waitMs: Int, maxBytes: Int) async -> Data {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(max(0, waitMs)))
        while ContinuousClock.now < deadline {
            guard let session = sessions[sessionID] else { return Data() }
            if !session.buffer.isEmpty || !session.alive { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        guard var session = sessions[sessionID] else { return Data() }
        let data = Data(session.buffer.prefix(max(0, maxBytes)))
        session.buffer.removeFirst(data.count)
        sessions[sessionID] = session
        return data
    }

    // MARK: Result mapping

    private static func mapStreamFailure(
        _ failure: SSHStreamExecFailure,
        dispatched: Bool,
        collector: RemoteShellPreviewCollector,
        log: RemoteShellOutputLog,
        jobID: String,
        started: ContinuousClock.Instant
    ) -> ShellRunOutcome {
        let durationMs = milliseconds(started.duration(to: .now))
        let snapshot = collector.snapshot()
        let note = "Full remote output: \(log.url.path)"
        switch failure {
        case .timedOut:
            if !dispatched {
                return .timedOut(partialStdout: "", partialStderr: "The deadline expired before remote dispatch. \(note)", durationMs: durationMs)
            }
            return .outcomeUnknown(jobID: jobID,
                message: "The SSH deadline expired after dispatch. Closing the connection does not prove the remote process stopped. Inspect the saved output before retrying. \(note)")
        case .cancelled:
            if !dispatched { return .cancelled }
            return .outcomeUnknown(jobID: jobID,
                message: "Cancellation closed SSH after dispatch; remote termination is unconfirmed. Inspect the saved output before retrying. \(note)")
        case .interrupted(let detail):
            if !dispatched {
                return .notStarted(
                    reason: "The SSH connection failed before dispatch: \(detail). Nothing ran on a fallback backend.")
            }
            return .outcomeUnknown(
                jobID: jobID,
                message: "The SSH connection was interrupted after the command was dispatched: \(detail). The command may have run; inspect the saved output at \(log.url.path) and do not rerun it.")
        case .sinkFailed(let detail):
            if !dispatched {
                return .notStarted(
                    reason: "The remote output could not be saved before dispatch: \(detail). Nothing ran on a fallback backend.")
            }
            return .outcomeUnknown(
                jobID: jobID,
                message: "The command may have run, but its full output could not be saved: \(detail). Inspect the SSH host and the saved output at \(log.url.path); do not rerun the command.")
        }
    }

    // MARK: Remote command construction

    /// The native shell service merges its own local defaults into every run
    /// (PATH/HOME/TMPDIR/PS1 plus Python paths). Those are hints for the iOS
    /// substrate, not the remote host: exporting them would point a remote
    /// command at paths that do not exist there. They are ignored rather than
    /// rejected, because the service supplied them without model intent.
    private static let localOnlyEnvironmentKeys: Set<String> = [
        "HOME", "TMPDIR", "PATH", "PYTHONHOME", "PYTHONPATH", "PS1"
    ]

    private static func isLocalOnlyEnvironmentKey(_ key: String) -> Bool {
        localOnlyEnvironmentKeys.contains(key)
            || key.hasPrefix("DYLD_")
            || key.hasPrefix("LD_")
    }

    private static func environmentValidationFailure(_ environment: [String: String]) -> String? {
        let relevant = environment.filter { !isLocalOnlyEnvironmentKey($0.key) }
        // The native service merges a handful of its own defaults (TERM,
        // LANG, LC_ALL) after the tool's 32-variable validation, so allow
        // that headroom without widening the tool contract.
        guard relevant.count <= 40 else { return "Too many environment variables for the remote shell" }
        for (key, value) in relevant {
            guard key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil,
                  !value.contains("\0"),
                  value.utf8.count <= 16 * 1024 else {
                return "Invalid remote shell environment variable '\(key)'"
            }
        }
        return nil
    }

    /// Model-supplied values are never an authority for target facts. Every
    /// `FLOE_*` key and every local-shell-only default is removed; the trusted
    /// facts are exported afterwards.
    private static func sanitizedRequestEnvironment(_ environment: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in environment {
            guard !key.hasPrefix("FLOE_"),
                  !isLocalOnlyEnvironmentKey(key),
                  !value.contains("\0") else { continue }
            result[key] = value
        }
        return result
    }

    private static func trustedEnvironment(_ target: SSHShellTarget) -> [String: String] {
        [
            "FLOE_ENVIRONMENT_ID": target.environmentID,
            "FLOE_EXECUTION_BACKEND": "ssh",
            "FLOE_REMOTE_TASK_ROOT": target.remoteTaskRoot,
            "FLOE_TARGET_GENERATION": target.generation
        ]
    }

    private static func environmentExports(trusted environment: [String: String]) -> String {
        environment
            .sorted { $0.key < $1.key }
            .map { "export \($0.key)=\(shellQuote($0.value));" }
            .joined(separator: " ") + (environment.isEmpty ? "" : " ")
    }

    private static func environmentAssignments(_ environment: [String: String]) -> String {
        environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(shellQuote($0.value))" }
            .joined(separator: " ")
    }

    private static func wrapperScript(
        directory: String,
        command: String,
        requestEnvironment: [String: String],
        trustedEnvironment: [String: String],
        stdinPath: String?,
        scriptPath: String?
    ) -> String {
        var lines: [String] = []
        lines.append(environmentExports(trusted: trustedEnvironment).trimmingCharacters(in: .whitespaces))
        if !requestEnvironment.isEmpty {
            lines.append(environmentExports(trusted: requestEnvironment).trimmingCharacters(in: .whitespaces))
        }
        lines.append("cd \(shellQuote(directory)) || exit 126;")
        lines.append("export PATH=\"$FLOE_REMOTE_TASK_ROOT/.floe-env/bin:$FLOE_REMOTE_TASK_ROOT/.floe-node/node_modules/.bin:$PATH\";")
        lines.append("export NODE_PATH=\"$FLOE_REMOTE_TASK_ROOT/.floe-node/node_modules${NODE_PATH:+:$NODE_PATH}\";")
        var run = "/bin/sh -c \(shellQuote(command))"
        if let stdinPath { run += " < \(shellQuote(stdinPath))" }
        lines.append(run)
        lines.append("_floe_status=$?;")
        var cleanup: [String] = []
        if let stdinPath { cleanup.append(shellQuote(stdinPath)) }
        if let scriptPath { cleanup.append(shellQuote(scriptPath)) }
        if !cleanup.isEmpty {
            lines.append("rm -f \(cleanup.joined(separator: " "));")
        }
        lines.append("exit $_floe_status")
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static func remoteDirectory(root: String, cwd: String) throws -> String {
        let relative = cwd.isEmpty ? "." : cwd
        guard !relative.hasPrefix("/"),
              !relative.hasPrefix("~"),
              !relative.contains("\0") else {
            throw FloeError.validationFailed("cwd must be a remote task-relative path")
        }
        let parts = relative.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.contains(where: { String($0) == ".." }) else {
            throw FloeError.validationFailed("cwd must not traverse outside the remote task root")
        }
        let cleaned = parts.filter { String($0) != "." }
        guard !cleaned.isEmpty else { return root }
        return root + "/" + cleaned.joined(separator: "/")
    }

    private static func stagingPath(
        target: SSHShellTarget,
        suffix: String,
        limits: RemoteEnvironmentShellLimits
    ) -> String {
        target.remoteTaskRoot
            + "/" + limits.stagingDirectoryName
            + "/" + UUID().uuidString.lowercased() + suffix
    }

    private static func stageRemoteFile(
        _ data: Data,
        remotePath: String,
        target: SSHShellTarget,
        limits: RemoteEnvironmentShellLimits,
        connection: any SSHRemoteShellConnection,
        budget: SSHStreamExecDeadline,
        cancellation: CancellationToken?
    ) async throws {
        let base64 = data.base64EncodedString()
        var chunks: [String] = []
        var index = base64.startIndex
        while index < base64.endIndex {
            let end = base64.index(index, offsetBy: limits.stagingChunkBytes, limitedBy: base64.endIndex)
                ?? base64.endIndex
            chunks.append(String(base64[index..<end]))
            index = end
        }
        let directory = target.remoteTaskRoot + "/" + limits.stagingDirectoryName
        let b64Path = remotePath + ".b64"
        let firstChunk = chunks.first ?? ""
        let create = "umask 077; "
            + "if [ -L \(shellQuote(directory)) ]; then exit 74; fi; "
            + "if [ -e \(shellQuote(directory)) ] && [ ! -d \(shellQuote(directory)) ]; then exit 75; fi; "
            + "mkdir -p \(shellQuote(directory)) || exit 76; "
            + "if [ -L \(shellQuote(b64Path)) ]; then exit 77; fi; "
            + "if [ -e \(shellQuote(b64Path)) ]; then exit 77; fi; "
            + ": > \(shellQuote(b64Path)) || exit 77; "
            + "printf '%s' \(shellQuote(firstChunk)) >> \(shellQuote(b64Path)) || exit 78"
        try await runStagingCommand(create, connection: connection, budget: budget, cancellation: cancellation)
        for chunk in chunks.dropFirst() {
            let append = "printf '%s' \(shellQuote(chunk)) >> \(shellQuote(b64Path)) || exit 78"
            try await runStagingCommand(append, connection: connection, budget: budget, cancellation: cancellation)
        }
        let finish = "if [ -L \(shellQuote(remotePath)) ]; then rm -f \(shellQuote(b64Path)); exit 81; fi; "
            + "if base64 -d < \(shellQuote(b64Path)) > \(shellQuote(remotePath)) 2>/dev/null; then :; "
            + "elif base64 -D < \(shellQuote(b64Path)) > \(shellQuote(remotePath)) 2>/dev/null; then :; "
            + "else rm -f \(shellQuote(b64Path)); exit 79; fi; "
            + "rm -f \(shellQuote(b64Path)); [ -f \(shellQuote(remotePath)) ] || exit 80"
        try await runStagingCommand(finish, connection: connection, budget: budget, cancellation: cancellation)
    }

    private static func runStagingCommand(
        _ command: String,
        connection: any SSHRemoteShellConnection,
        budget: SSHStreamExecDeadline,
        cancellation: CancellationToken?
    ) async throws {
        do {
            let result = try await connection.executeStreaming(
                command,
                deadline: budget,
                cancellation: cancellation,
                maxPreviewBytes: 16 * 1024,
                onOutput: { _, _ in }
            )
            guard result.exitCode == 0 else {
                let data = result.stderrPreview.isEmpty ? result.stdoutPreview : result.stderrPreview
                let detail = String(decoding: data, as: UTF8.self)
                throw RemoteShellPreparationFailure.stagingFailed(
                    "staging command exited \(result.exitCode): \(SecretRedactor.redact(String(detail.prefix(512))))")
            }
        } catch let failure as SSHStreamExecFailure {
            switch failure {
            case .timedOut:
                throw RemoteShellPreparationFailure.deadlineExhausted
            case .cancelled:
                throw FloeError.cancelled
            case .interrupted(let detail):
                throw RemoteShellPreparationFailure.stagingFailed("staging transport failed: \(detail)")
            case .sinkFailed(let detail):
                throw RemoteShellPreparationFailure.stagingFailed("staging output could not be saved: \(detail)")
            }
        } catch is CancellationError {
            throw FloeError.cancelled
        } catch {
            throw RemoteShellPreparationFailure.stagingFailed(Self.safe(error))
        }
    }

    private static func cleanupRemoteFiles(
        _ paths: [String],
        connection: any SSHRemoteShellConnection
    ) async {
        guard !paths.isEmpty else { return }
        let unique = Array(Set(paths)).sorted()
        let command = "rm -f " + unique.map { shellQuote($0) }.joined(separator: " ")
        _ = try? await connection.executeStreaming(
            command,
            deadline: .seconds(15),
            cancellation: nil,
            maxPreviewBytes: 4096,
            onOutput: { _, _ in }
        )
    }

    private static func remainingBudget(
        _ budget: ShellExecutionDeadline,
        since started: ContinuousClock.Instant
    ) -> SSHStreamExecDeadline? {
        switch budget {
        case .unlimited:
            return .unlimited
        case .seconds(let total):
            let elapsed = started.duration(to: .now)
            let elapsedSeconds = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
            let remaining = total - elapsedSeconds
            guard remaining > 0 else { return nil }
            return .seconds(remaining)
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func safe(_ error: Error) -> String {
        SecretRedactor.redact(error.localizedDescription)
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int(clamping: parts.seconds) * 1000
            + Int(parts.attoseconds / 1_000_000_000_000_000)
    }
}

private enum RemoteShellPreparationFailure: Error, Sendable {
    case deadlineExhausted
    case stagingFailed(String)
}

// MARK: - Full-output log and bounded preview

/// The App-owned full output log. The sink sees every byte; only the preview
/// collector is bounded in memory.
private final class RemoteShellOutputLog: @unchecked Sendable {
    let url: URL
    private let handle: FileHandle
    private let lock = NSLock()
    private var closed = false

    private init(url: URL, handle: FileHandle) {
        self.url = url
        self.handle = handle
    }

    static func create(root: URL, jobID: String) throws -> RemoteShellOutputLog {
        let directory = root.appendingPathComponent(".floe/terminal", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(jobID + ".log")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw FloeError.validationFailed("The remote output log could not be created")
        }
        return RemoteShellOutputLog(url: url, handle: try FileHandle(forWritingTo: url))
    }

    func append(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw FloeError.internalError("The remote output log is closed") }
        try handle.write(contentsOf: data)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        try? handle.close()
    }
}

private final class RemoteShellPreviewCollector: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private var used = 0
    private var stdoutBytes: Int64 = 0
    private var stderrBytes: Int64 = 0
    private var stdoutTruncated = false
    private var stderrTruncated = false

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func append(_ channel: SSHStreamChannel, _ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        switch channel {
        case .stdout:
            stdoutBytes += Int64(data.count)
            Self.append(
                data, to: &stdout, limit: limit, used: &used,
                truncated: &stdoutTruncated)
        case .stderr:
            stderrBytes += Int64(data.count)
            Self.append(
                data, to: &stderr, limit: limit, used: &used,
                truncated: &stderrTruncated)
        }
    }

    func snapshot() -> SSHStreamExecResult {
        lock.lock()
        defer { lock.unlock() }
        return SSHStreamExecResult(
            exitCode: 0,
            stdoutPreview: stdout,
            stderrPreview: stderr,
            stdoutBytes: stdoutBytes,
            stderrBytes: stderrBytes,
            stdoutTruncated: stdoutTruncated,
            stderrTruncated: stderrTruncated
        )
    }

    private static func append(
        _ data: Data,
        to preview: inout Data,
        limit: Int,
        used: inout Int,
        truncated: inout Bool
    ) {
        let remaining = max(0, limit - used)
        guard remaining > 0 else {
            truncated = true
            return
        }
        let accepted = data.prefix(remaining)
        preview.append(contentsOf: accepted)
        used += accepted.count
        if accepted.count < data.count { truncated = true }
    }
}

// MARK: - Router

/// Routes by the trusted environment id only. `defaultBackend` is the whole
/// existing non-SSH path (Linux guest plus the Mac bridge); it is reached only
/// for `.notSSH`. A selected SSH environment never falls back.
public actor RemoteEnvironmentShellRouter: LocalShellBackend {
    private let defaultBackend: any LocalShellBackend
    private let sshBackend: RemoteEnvironmentShellBackend
    private let resolver: SSHShellTargetResolver
    private var frozenSessions: [String: SSHShellTarget] = [:]

    public init(
        defaultBackend: any LocalShellBackend,
        sshBackend: RemoteEnvironmentShellBackend,
        resolver: @escaping SSHShellTargetResolver
    ) {
        self.defaultBackend = defaultBackend
        self.sshBackend = sshBackend
        self.resolver = resolver
    }

    public init(
        defaultBackend: any LocalShellBackend,
        resolver: @escaping SSHShellTargetResolver,
        sessionFactory: @escaping SSHShellSessionFactory,
        sync: RemoteWorkspaceSyncCallbacks = .none,
        limits: RemoteEnvironmentShellLimits = RemoteEnvironmentShellLimits(),
        outputRoot: URL? = nil
    ) {
        self.defaultBackend = defaultBackend
        self.resolver = resolver
        self.sshBackend = RemoteEnvironmentShellBackend(
            resolver: resolver,
            sessionFactory: sessionFactory,
            sync: sync,
            limits: limits,
            outputRoot: outputRoot
        )
    }

    public nonisolated func normalizedRunDeadline(
        _ requested: ShellExecutionDeadline
    ) -> ShellExecutionDeadline {
        // Preserve the existing default path's documented floor so the tool
        // receipt and the actually enforced deadline stay equal. The SSH path
        // then also honors that small floor; `.unlimited` is never changed.
        defaultBackend.normalizedRunDeadline(requested)
    }

    public func targetFacts(environmentID: String) async -> SSHShellTargetFacts? {
        await sshBackend.targetFacts(environmentID: environmentID)
    }

    public func run(
        _ request: ShellRunRequest,
        cancellation: CancellationToken?
    ) async -> ShellRunOutcome {
        guard let environmentID = request.toolEnvironment?.id else {
            return await defaultBackend.run(request, cancellation: cancellation)
        }
        switch await resolution(for: environmentID) {
        case .notSSH:
            return await defaultBackend.run(request, cancellation: cancellation)
        case .unavailable(_, let reason):
            return .failed(message: reason)
        case .ssh(let target):
            return await sshBackend.run(request, target: target, cancellation: cancellation)
        }
    }

    public func openSession(
        _ request: ShellOpenRequest,
        cancellation: CancellationToken?
    ) async throws -> ShellOpenResult {
        guard let environmentID = request.toolEnvironment?.id else {
            return try await defaultBackend.openSession(request, cancellation: cancellation)
        }
        switch await resolution(for: environmentID) {
        case .notSSH:
            return try await defaultBackend.openSession(request, cancellation: cancellation)
        case .unavailable(_, let reason):
            throw FloeError.validationFailed(reason)
        case .ssh(let target):
            guard frozenSessions[request.sessionID] == nil else {
                throw FloeError.validationFailed(
                    "This terminal id is already open; nothing was started")
            }
            frozenSessions[request.sessionID] = target
            do {
                let result = try await sshBackend.openSession(
                    request, target: target, cancellation: cancellation)
                if !result.alive {
                    frozenSessions.removeValue(forKey: request.sessionID)
                    await sshBackend.closeSession(sessionID: request.sessionID)
                }
                return result
            } catch {
                frozenSessions.removeValue(forKey: request.sessionID)
                throw error
            }
        }
    }

    public func exchangeSession(
        _ request: ShellExchangeRequest,
        cancellation: CancellationToken?
    ) async throws -> ShellExchangeResult {
        guard let target = frozenSessions[request.sessionID] else {
            return try await defaultBackend.exchangeSession(request, cancellation: cancellation)
        }
        try await requireCurrent(target, sessionID: request.sessionID)
        return try await sshBackend.exchangeSession(
            request, target: target, cancellation: cancellation)
    }

    public func closeSession(sessionID: String) async {
        if frozenSessions.removeValue(forKey: sessionID) != nil {
            await sshBackend.closeSession(sessionID: sessionID)
            return
        }
        await defaultBackend.closeSession(sessionID: sessionID)
    }

    public func signalSession(sessionID: String, signal: ShellSignal) async {
        guard let target = frozenSessions[sessionID] else {
            await defaultBackend.signalSession(sessionID: sessionID, signal: signal)
            return
        }
        guard await stillCurrent(target) else {
            await dropFrozenSession(sessionID: sessionID)
            return
        }
        await sshBackend.signalSession(sessionID: sessionID, signal: signal)
    }

    public func resizeSession(sessionID: String, columns: Int, rows: Int) async {
        guard let target = frozenSessions[sessionID] else {
            await defaultBackend.resizeSession(sessionID: sessionID, columns: columns, rows: rows)
            return
        }
        guard await stillCurrent(target) else {
            await dropFrozenSession(sessionID: sessionID)
            return
        }
        await sshBackend.resizeSession(sessionID: sessionID, columns: columns, rows: rows)
    }

    private func resolution(for environmentID: String) async -> SSHShellTargetResolution {
        let resolved = await resolver(environmentID)
        if case .ssh(let target) = resolved, target.environmentID != environmentID {
            return .unavailable(
                environmentID: environmentID,
                reason: "The trusted SSH target does not match the selected environment. Nothing ran on a fallback backend.")
        }
        return resolved
    }

    private func stillCurrent(_ target: SSHShellTarget) async -> Bool {
        let resolved = await resolution(for: target.environmentID)
        if case .ssh(let current) = resolved { return current == target }
        return false
    }

    private func requireCurrent(_ target: SSHShellTarget, sessionID: String) async throws {
        switch await resolution(for: target.environmentID) {
        case .ssh(let current) where current == target:
            return
        case .ssh(let current):
            await dropFrozenSession(sessionID: sessionID)
            throw FloeError.validationFailed(
                "This SSH terminal belongs to an earlier environment generation (\(target.generation)); the environment is now generation \(current.generation). Reopen the terminal. The old session was closed and its output was not routed to the new target.")
        case .unavailable(_, let reason):
            await dropFrozenSession(sessionID: sessionID)
            throw FloeError.validationFailed(
                "The pinned SSH target is unavailable: \(reason). The old terminal was closed; nothing ran on the local Linux or Mac backend.")
        case .notSSH:
            await dropFrozenSession(sessionID: sessionID)
            throw FloeError.validationFailed(
                "The environment is no longer an SSH environment. The old terminal was closed; nothing ran on a different backend.")
        }
    }

    private func dropFrozenSession(sessionID: String) async {
        frozenSessions.removeValue(forKey: sessionID)
        await sshBackend.closeSession(sessionID: sessionID)
    }
}
