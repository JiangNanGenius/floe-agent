// FloeAndroidShellTools — Android platform mirror of the ORIGINAL
// FloeAgent/Sources/FloeExecution/Shell/LocalShellBackend.swift.
// Every statement is byte-equal to the original except the deltas below.
// The ORIGINAL file stays linked unmodified wherever its dependencies exist;
// this mirror exists ONLY because two exclusions/inclusions are required on
// Android (documented here and delivered to Main in
// Local/Private/android-g03-20261022/r2/shell-port/SOURCE_READY.json; Main
// appends the shared PROVENANCE.md entry during assembly — this lane does
// not edit that file):
//
//   D1 (narrow documented platform delta, per job-1bd4fcce5eca4856): the
//      iOS guest-shape handoff section — `ShellGuestRunShapeIntent`,
//      `ShellGuestRunShapeError` and `ShellGuestRunShapeCenter` — is
//      EXCLUDED. It routes Virtualization-framework vCPU/RAM descriptor
//      shapes through `GuestResourceRequest`/`GuestRunEntryShapePlan`/
//      `GuestReleaseShapePolicy`, none of which exist on Android: the
//      PRoot engine has no per-start VM shape, component selection,
//      paths or leases are NOT caller/model fields, and the runtime-UID
//      authority owns environment/lease identity (RuntimeKernel /
//      FloeAndroidLinuxAuthority). Nothing in the `LocalShellBackend`
//      protocol, the run/open/exchange DTOs or `UnavailableShellBackend`
//      referenced those helpers, so extraction preserves every common
//      semantic byte-for-byte. No dependency is fabricated.
//   D2 (additive Android owner threading): `ShellRunRequest` and
//      `ShellOpenRequest` gain ONE optional trailing-initialized field
//      `conversationID: UUID?` each. The ORIGINAL DTO lacks the owner
//      field the engine `shell.start` payload requires (strict fields
//      projectID/runID/conversationID/environmentID); the narrow mirror
//      carries it explicitly from the original service/context
//      (ToolContext.conversationID — a runtime-issued identity the model
//      can never mint), never inferred from arbitrary session text.
//      runID/toolEnvironment survive unchanged exactly as in the
//      original; existing original call sites compile untouched because
//      the new parameters default to nil and append after every original
//      parameter. `ShellRunRequest` additionally carries a
//      `trackingHook: LinuxShellCallTrackingHook?` (D2b): the trusted
//      Core facade injects it from `LocalShellService` so the owned-work
//      ledger (FacadeToolWorkCoordinator) sees REAL dispatch starts and
//      lease-release settlement; it is never model-supplied and has no
//      effect when absent (the standalone original semantics: the call
//      simply runs untracked).
//   D3 (header only): the file banner names this module. The ios_system
//      sentence is replaced by the Android engine sentence; the
//      backend-agnostic contract itself is unchanged.
//
// See docs/ARCHITECTURE_LOCAL_SHELL.md: the agent-facing shell tools are
// backend-agnostic. The Android App injects the mailbox-backed
// `AndroidLinuxShellBackend` (runtime engine transport) from the
// composition root; tests and previews use fakes.

import Foundation
import FloeCore
import FloeTools

// MARK: - Trusted owned-work tracking hook (D2b)

/// Injected by the trusted Core facade (RuntimeFacadeLinuxBindings) into
/// `LocalShellService`; the service stamps it on every `ShellRunRequest` it
/// builds from the ORIGINAL trusted `ToolContext`. Model code can never
/// supply or clear it. `onDispatch` runs immediately BEFORE the backend
/// dispatch and returns the settlement closure the service calls after the
/// REAL backend return + journal record — so the FacadeToolWorkCoordinator
/// ledger attaches before the awaited work and detaches only on a settled
/// dispatch (lease-release reconciliation stays owned inside the backend/
/// facade, never here). When a configured hook refuses ownership (nil
/// receipt), LocalShellService refuses dispatch; an absent hook keeps the
/// original standalone service behavior.
public struct LinuxShellCallTrackingHook: Sendable {
    public let onDispatch: @Sendable (ToolContext) async -> (@Sendable () -> Void)?

    public init(onDispatch: @escaping @Sendable (ToolContext) async -> (@Sendable () -> Void)?) {
        self.onDispatch = onDispatch
    }
}

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
    /// Bounded wait for the engine's process-wide run gate. A command that
    /// cannot start inside this window is reported as not-started, never as an
    /// execution timeout. It does not consume `timeout`.
    public var gateTimeout: TimeInterval
    /// Combined stdout/stderr cap in bytes.
    public var maxOutputBytes: Int
    /// Stable session identity; backends that keep per-session state use it.
    public var sessionID: String
    public var runID: UUID?
    public var toolEnvironment: ToolEnvironment?
    // D2: Android-only additive owner field (see file header).
    /// Runtime-issued conversation identity, carried unchanged from the
    /// trusted `ToolContext`. Model code can never set this: it is threaded
    /// by the ORIGINAL service path (LocalShellService.run builds the
    /// request from `context.conversationID`). On Android it maps 1:1 to the
    /// engine `shell.start` payload's optional `conversationID` field; nil
    /// stays nil (the engine treats it as an absent owner field, never as a
    /// guessed value).
    public var conversationID: UUID?
    /// D2b: facade-injected owned-work ledger hook; never model-supplied.
    public var trackingHook: LinuxShellCallTrackingHook?
    /// Trusted call owner for Core-only receipt reconciliation (never model input).
    public var toolCallID: String?

    public init(
        command: String,
        cwd: String,
        rootURL: URL,
        environment: [String: String] = [:],
        stdin: String? = nil,
        timeout: TimeInterval = 10,
        gateTimeout: TimeInterval = 5,
        maxOutputBytes: Int = 64 * 1024,
        sessionID: String,
        runID: UUID? = nil,
        toolEnvironment: ToolEnvironment? = nil,
        conversationID: UUID? = nil,
        trackingHook: LinuxShellCallTrackingHook? = nil,
        toolCallID: String? = nil
    ) {
        self.command = command
        self.cwd = cwd
        self.rootURL = rootURL
        self.environment = environment
        self.stdin = stdin
        self.timeout = timeout
        self.gateTimeout = gateTimeout
        self.maxOutputBytes = maxOutputBytes
        self.sessionID = sessionID
        self.runID = runID
        self.toolEnvironment = toolEnvironment
        self.conversationID = conversationID
        self.trackingHook = trackingHook
        self.toolCallID = toolCallID
    }
}

/// One dispatch's terminal outcome TOGETHER with the bounded phase
/// composition the backend measured for EXACTLY that dispatch (G07.1
/// terminal04). The pair is produced inside one backend call, so a concurrent
/// or reentrant dispatch can never substitute its own timing: journal
/// attribution is atomic with the outcome it describes. `phaseTimings` is nil
/// when the backend does not measure timing (or measured nothing for this
/// call).
public struct ShellRunReport: Sendable, Equatable {
    public var outcome: ShellRunOutcome
    public var phaseTimings: String?
    public init(outcome: ShellRunOutcome, phaseTimings: String?) {
        self.outcome = outcome
        self.phaseTimings = phaseTimings
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
    /// The engine could not start the command because another worker still
    /// owns the process-wide runtime gate. Distinct from `timedOut`: nothing
    /// of this command ran, and no partial output exists.
    case notStarted(reason: String)
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
    /// Bounded wait for the engine's process-wide run gate before the session
    /// may start. A session and a one-shot command can never use the engine
    /// concurrently; an open that cannot acquire the gate in this window is
    /// rejected instead of entering the engine alongside another worker.
    public var gateTimeout: TimeInterval
    public var sessionID: String
    public var runID: UUID?
    public var toolEnvironment: ToolEnvironment?
    // D2: Android-only additive owner field (see file header).
    /// Runtime-issued conversation identity carried unchanged from the
    /// trusted session-open caller (`ToolContext.conversationID` threaded
    /// through `ShellSessionCenter.open`). Never inferred from session text.
    public var conversationID: UUID?
    /// G04-R2 (Main contract 2026-10-25): native-issued identity of the LIVE
    /// conversation workspace-operation lease that authorizes THIS UI open
    /// (interactive terminal / LSP only). Trusted session-open caller only —
    /// never a model value, never inferred from session text. nil keeps the
    /// ORIGINAL grant route byte-for-byte for every other open.
    public var workspaceOperationID: UUID?
    /// UI terminals surface an installation card instead of downloading during open.
    public var prepareLinuxIfMissing: Bool

    public init(
        command: String = "",
        cwd: String = ".",
        rootURL: URL,
        environment: [String: String] = [:],
        columns: Int = 80,
        rows: Int = 24,
        gateTimeout: TimeInterval = 5,
        sessionID: String,
        runID: UUID? = nil,
        toolEnvironment: ToolEnvironment? = nil,
        conversationID: UUID? = nil,
        workspaceOperationID: UUID? = nil,
        prepareLinuxIfMissing: Bool = true
    ) {
        self.command = command
        self.cwd = cwd
        self.rootURL = rootURL
        self.environment = environment
        self.columns = columns
        self.rows = rows
        self.gateTimeout = gateTimeout
        self.sessionID = sessionID
        self.runID = runID
        self.toolEnvironment = toolEnvironment
        self.conversationID = conversationID
        self.workspaceOperationID = workspaceOperationID
        self.prepareLinuxIfMissing = prepareLinuxIfMissing
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
    /// UTF-8 input written to the session's stdin as-is (a pipe, not a PTY):
    /// line-oriented programs execute a command only once it ends with "\n".
    /// An input of exactly "\u{03}" is routed to cooperative interruption
    /// (SIGINT semantics) instead of being written, and exactly "\u{04}"
    /// closes stdin (real EOF).
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
    /// Engine truth: this terminal came from a PROVEN STOP (Cancelled), not a
    /// process that exited on its own. A stopped session is not an "exited"
    /// one even when the cancelled terminal carries an exit code.
    public var cancelled: Bool
    /// Recoverable session failure text (e.g. unread-output overflow): the
    /// session ended deliberately; the owner surfaces this and the user can
    /// reconnect to continue.
    public var failure: String?
    /// Cumulative bytes read from the session's output descriptor. Zero after
    /// an interactive prompt means the program never wrote anything, which is
    /// different from output that was drained but not returned.
    public var bytesRead: Int
    /// Cumulative bytes accepted onto the session's input descriptor.
    public var bytesWritten: Int
    /// The runtime's OWN workspace export result for this released session
    /// (`synced`/`conflict`/`aborted`/`error`/`unknown`). The engine publishes
    /// `leaseReleased` only AFTER its whole-UID stop proof and export, so a
    /// released page carries the real receipt. nil means no receipt was
    /// observed (unknown) — never a synthesized success.
    public var workspaceStatus: String?

    public init(output: String, alive: Bool, exitCode: Int32? = nil, cancelled: Bool = false, terminalOutput: Data? = nil, failure: String? = nil, bytesRead: Int = 0, bytesWritten: Int = 0, workspaceStatus: String? = nil) {
        self.output = output
        self.alive = alive
        self.exitCode = exitCode
        self.cancelled = cancelled
        self.terminalOutput = terminalOutput
        self.failure = failure
        self.bytesRead = bytesRead
        self.bytesWritten = bytesWritten
        self.workspaceStatus = workspaceStatus
    }
}

public enum ShellSignal: String, Sendable {
    case interrupt = "INT"
    case terminate = "TERM"
    case kill = "KILL"
}

/// Backend seam. Production = the mailbox-backed runtime-UID Linux engine
/// (`AndroidLinuxShellBackend`, this module); tests = fakes. The iOS
/// `UnavailableShellBackend` below stays the honest no-engine answer.
public protocol LocalShellBackend: Sendable {
    func run(_ request: ShellRunRequest, cancellation: CancellationToken?) async -> ShellRunOutcome

    func openSession(_ request: ShellOpenRequest, cancellation: CancellationToken?) async throws -> ShellOpenResult
    func exchangeSession(_ request: ShellExchangeRequest, cancellation: CancellationToken?) async throws -> ShellExchangeResult
    func closeSession(sessionID: String) async
    func signalSession(sessionID: String, signal: ShellSignal) async
    func resizeSession(sessionID: String, columns: Int, rows: Int) async
    /// Requests the engine's owned stop while the CALLER keeps observing the
    /// SAME session entry to its real terminal. Unlike `signalSession(...,
    /// .terminate)` the production implementation schedules NO detached
    /// reconciliation, so the caller's own exchange receives the released
    /// terminal together with the runtime workspace export receipt.
    func requestStopForSettlement(sessionID: String) async
    /// G07.1 terminal04: the SAME one-shot run, returned atomically with the
    /// bounded phase composition measured FOR THAT CALL. Journal attribution
    /// must use this (never a "last" global: backends are reentrant).
    func runReportingPhases(_ request: ShellRunRequest,
                            cancellation: CancellationToken?) async -> ShellRunReport
}

public extension LocalShellBackend {
    func signalSession(sessionID: String, signal: ShellSignal) async {}
    func resizeSession(sessionID: String, columns: Int, rows: Int) async {}
    /// Default keeps the historical signal semantics for test/fake backends;
    /// the production backend overrides it to preserve the caller's poll.
    func requestStopForSettlement(sessionID: String) async {
        await signalSession(sessionID: sessionID, signal: .terminate)
    }
    /// Default: run once and report no phase composition. The outcome is the
    /// backend's real answer; only the optional timing is absent.
    func runReportingPhases(_ request: ShellRunRequest,
                            cancellation: CancellationToken?) async -> ShellRunReport {
        ShellRunReport(outcome: await run(request, cancellation: cancellation),
                       phaseTimings: nil)
    }
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
