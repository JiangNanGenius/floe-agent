// FloeExecution — Local shell backend contract.
// See docs/ARCHITECTURE_LOCAL_SHELL.md: the agent-facing shell tools are
// backend-agnostic. The App Store build injects an ios_system-backed
// implementation from the app target; tests and previews use fakes.

import Foundation
import FloeCore
import FloeTools

/// One bounded, non-interactive shell invocation.
public struct ShellRunRequest: Sendable {
    /// Shell command string. Pipelines, redirections and globs are resolved
    /// by the backend's shell engine (libshell/dash in production).
    public var command: String
    /// Virtual working directory, workspace-relative (`"."` = root).
    public var cwd: String
    /// Workspace root for relative paths; native commands share the App process.
    public var rootURL: URL
    /// Additional environment exported for this run only.
    public var environment: [String: String]
    /// Optional stdin content (≤256 KiB enforced by the tool).
    public var stdin: String?
    /// Wall-clock timeout in seconds.
    public var timeout: TimeInterval
    /// Combined stdout/stderr cap in bytes.
    public var maxOutputBytes: Int
    /// Stable session identity; backends that keep per-session state use it.
    public var sessionID: String
    public var runID: UUID?
    public var toolEnvironment: ToolEnvironment?

    public init(
        command: String,
        cwd: String,
        rootURL: URL,
        environment: [String: String] = [:],
        stdin: String? = nil,
        timeout: TimeInterval = 10,
        maxOutputBytes: Int = 64 * 1024,
        sessionID: String,
        runID: UUID? = nil,
        toolEnvironment: ToolEnvironment? = nil
    ) {
        self.command = command
        self.cwd = cwd
        self.rootURL = rootURL
        self.environment = environment
        self.stdin = stdin
        self.timeout = timeout
        self.maxOutputBytes = maxOutputBytes
        self.sessionID = sessionID
        self.runID = runID
        self.toolEnvironment = toolEnvironment
    }
}

/// Terminal outcome of one shell run. Never throws: the tool wrapper maps
/// every case into `ToolExecutionOutput`.
public enum ShellRunOutcome: Sendable, Equatable {
    case exited(
        code: Int32,
        stdout: String,
        stderr: String,
        truncated: Bool,
        stderrTruncated: Bool,
        durationMs: Int
    )
    case timedOut(partialStdout: String, partialStderr: String, durationMs: Int)
    case cancelled
    /// The backend could not start the command (missing engine, session
    /// bookkeeping failure). Distinct from a non-zero command exit.
    case failed(message: String)
}

/// Opens a long-lived interactive session (a shell prompt or a program that
/// reads stdin over time).
public struct ShellOpenRequest: Sendable {
    /// Empty selects the backend's interactive shell (usually `sh`).
    public var command: String
    public var cwd: String
    public var rootURL: URL
    public var environment: [String: String]
    public var columns: Int
    public var rows: Int
    public var sessionID: String
    public var runID: UUID?
    public var toolEnvironment: ToolEnvironment?

    public init(
        command: String = "",
        cwd: String = ".",
        rootURL: URL,
        environment: [String: String] = [:],
        columns: Int = 80,
        rows: Int = 24,
        sessionID: String,
        runID: UUID? = nil,
        toolEnvironment: ToolEnvironment? = nil
    ) {
        self.command = command
        self.cwd = cwd
        self.rootURL = rootURL
        self.environment = environment
        self.columns = columns
        self.rows = rows
        self.sessionID = sessionID
        self.runID = runID
        self.toolEnvironment = toolEnvironment
    }
}

public struct ShellOpenResult: Sendable, Equatable {
    public var sessionID: String
    public var initialOutput: String
    public var terminalOutput: Data?
    public var alive: Bool

    public init(sessionID: String, initialOutput: String, alive: Bool, terminalOutput: Data? = nil) {
        self.sessionID = sessionID
        self.initialOutput = initialOutput
        self.terminalOutput = terminalOutput
        self.alive = alive
    }
}

public struct ShellExchangeRequest: Sendable {
    public var sessionID: String
    /// UTF-8 input. `\u{03}` is Ctrl-C for shells that map it to SIGINT.
    public var input: String?
    public var waitMs: Int
    public var maxBytes: Int

    public init(sessionID: String, input: String?, waitMs: Int, maxBytes: Int) {
        self.sessionID = sessionID
        self.input = input
        self.waitMs = waitMs
        self.maxBytes = maxBytes
    }
}

public struct ShellExchangeResult: Sendable, Equatable {
    public var output: String
    public var terminalOutput: Data?
    public var alive: Bool
    public var exitCode: Int32?

    public init(output: String, alive: Bool, exitCode: Int32? = nil, terminalOutput: Data? = nil) {
        self.output = output
        self.terminalOutput = terminalOutput
        self.alive = alive
        self.exitCode = exitCode
    }
}

public enum ShellSignal: String, Sendable {
    case interrupt = "INT"
    case terminate = "TERM"
    case kill = "KILL"
}

/// Backend seam. Production = ios_system (app target); tests = fakes.
public protocol LocalShellBackend: Sendable {
    func run(_ request: ShellRunRequest, cancellation: CancellationToken?) async -> ShellRunOutcome

    func openSession(_ request: ShellOpenRequest, cancellation: CancellationToken?) async throws -> ShellOpenResult
    func exchangeSession(_ request: ShellExchangeRequest, cancellation: CancellationToken?) async throws -> ShellExchangeResult
    func closeSession(sessionID: String) async
    func signalSession(sessionID: String, signal: ShellSignal) async
    func resizeSession(sessionID: String, columns: Int, rows: Int) async
}

public extension LocalShellBackend {
    func signalSession(sessionID: String, signal: ShellSignal) async {}
    func resizeSession(sessionID: String, columns: Int, rows: Int) async {}
}

/// Honest failure when the app has not injected a shell engine (for example
/// a build without the ios_system frameworks). Tools stay unavailable rather
/// than pretending a command ran.
public struct UnavailableShellBackend: LocalShellBackend {
    public let reason: String

    public init(reason: String = "The on-device shell engine is not available in this build") {
        self.reason = reason
    }

    public func run(_ request: ShellRunRequest, cancellation: CancellationToken?) async -> ShellRunOutcome {
        .failed(message: reason)
    }

    public func openSession(_ request: ShellOpenRequest, cancellation: CancellationToken?) async throws -> ShellOpenResult {
        throw FloeError.invalidConfiguration(reason)
    }

    public func exchangeSession(_ request: ShellExchangeRequest, cancellation: CancellationToken?) async throws -> ShellExchangeResult {
        throw FloeError.invalidConfiguration(reason)
    }

    public func closeSession(sessionID: String) async {}
}
