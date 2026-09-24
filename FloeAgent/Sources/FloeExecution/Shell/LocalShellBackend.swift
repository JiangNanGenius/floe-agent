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
        toolEnvironment: ToolEnvironment? = nil
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
        toolEnvironment: ToolEnvironment? = nil
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
    /// Cumulative bytes read from the session's output descriptor. Zero after
    /// an interactive prompt means the program never wrote anything, which is
    /// different from output that was drained but not returned.
    public var bytesRead: Int
    /// Cumulative bytes accepted onto the session's input descriptor.
    public var bytesWritten: Int

    public init(output: String, alive: Bool, exitCode: Int32? = nil, terminalOutput: Data? = nil, bytesRead: Int = 0, bytesWritten: Int = 0) {
        self.output = output
        self.alive = alive
        self.exitCode = exitCode
        self.terminalOutput = terminalOutput
        self.bytesRead = bytesRead
        self.bytesWritten = bytesWritten
    }
}

public enum ShellSignal: String, Sendable {
    case interrupt = "INT"
    case terminate = "TERM"
    case kill = "KILL"
}

// MARK: - Guest run shape handoff

/// One logical run's accepted guest start shape: the typed request the run
/// entry resolved plus the downgrade policy that governs it.
///
/// The run entry (`GuestRunEntryShapePlanner`) resolves a user selection
/// against the release gate, the verified image's SMP proof and the connected
/// dispatch path. A refused selection produces no effective request at all, so
/// no intent can be registered for it and no start can boot "one hart instead"
/// of an explicit dual choice.
public struct ShellGuestRunShapeIntent: Sendable, Equatable {
    /// The Linux environment whose next start carries this shape.
    public var environmentID: String
    /// The logical run that registered the intent (the shell session owner's
    /// run identity). Only a start made for this exact run may claim it.
    public var runID: String
    /// The typed request (vCPUs + RAM + origin) the entry resolved.
    public var request: GuestResourceRequest
    /// How the guest start must treat the request: `.strict` for an explicit
    /// user selection, `.authorized` for an automatic plan's recorded
    /// single-hart downgrade.
    public var downgrade: GuestShapeDowngradePolicy
    /// The entry selection that produced the request (diagnostics/provenance).
    public var selection: GuestRunEntryShapeSelection
    public var recordedAt: Date

    public init(
        environmentID: String,
        runID: String,
        request: GuestResourceRequest,
        downgrade: GuestShapeDowngradePolicy,
        selection: GuestRunEntryShapeSelection,
        recordedAt: Date = Date()
    ) {
        self.environmentID = environmentID
        self.runID = runID
        self.request = request
        self.downgrade = downgrade
        self.selection = selection
        self.recordedAt = recordedAt
    }

    /// The intent an accepted run-entry plan must register, or nil when the
    /// plan is refused. A refused selection has no effective request, so
    /// nothing may be registered and nothing may start.
    public static func from(
        plan: GuestRunEntryShapePlan,
        environmentID: String,
        runID: String,
        recordedAt: Date = Date()
    ) -> ShellGuestRunShapeIntent? {
        guard plan.isRunnable, let request = plan.effectiveRequest else { return nil }
        return ShellGuestRunShapeIntent(
            environmentID: environmentID,
            runID: runID,
            request: request,
            downgrade: plan.downgrade,
            selection: plan.selection,
            recordedAt: recordedAt
        )
    }
}

/// Why a run's accepted guest shape could not be delivered by the start path.
/// Every case refuses the run WITHOUT touching the environment's guest.
public enum ShellGuestRunShapeError: Error, LocalizedError, Equatable, Sendable {
    /// Another run's start already holds this environment's shape claim (a
    /// guest start is in flight). The claim is never overwritten; this run is
    /// failed visibly instead of starting at an unrequested shape.
    case startAlreadyInProgress(environmentID: String)
    /// The run asked for an explicit shape while the environment's guest is
    /// ALREADY RUNNING at a different core count. A running VM's shape is
    /// fixed at create time and is never silently reshaped or restarted.
    case runningGuestShapeMismatch(environmentID: String, requestedVCPUs: Int, runningVCPUs: Int)
    /// The run asked for an explicit shape and a guest is running, but the
    /// granted count could not be read from the runtime's own session table.
    /// Fail closed instead of assuming the request matches.
    case runningGuestShapeUnknown(environmentID: String, requestedVCPUs: Int)

    public var errorDescription: String? {
        switch self {
        case .startAlreadyInProgress(let environmentID):
            return "another guest start is already in progress for environment \(environmentID); this run was refused before anything started (retry once it finishes)"
        case .runningGuestShapeMismatch(let environmentID, let requestedVCPUs, let runningVCPUs):
            return "environment \(environmentID) already has a guest running with \(runningVCPUs) core(s); the requested \(requestedVCPUs) core(s) were refused and the running guest was not reshaped (stop the guest to start it at another shape)"
        case .runningGuestShapeUnknown(let environmentID, let requestedVCPUs):
            return "environment \(environmentID) already has a guest running but its granted core count could not be read; the explicit \(requestedVCPUs)-core request was refused instead of assuming a match"
        }
    }
}

/// The run-entry → guest-start shape handoff table.
///
/// The IDE registers one intent per logical run immediately before it opens
/// the run's session. `FloePlatformServices` claims it for the start that
/// belongs to the same run, then arms it (exclusively, per environment) for
/// the descriptor resolution that start performs: the app's Linux environment
/// provider reads `armedIntent` while it builds the descriptor supplied to the
/// guest start, so the typed vCPU/RAM shape reaches the registry and pool
/// instead of a hardcoded single-hart default.
///
/// Honesty and concurrency rules:
///  * Pending intents are keyed by (environmentID, runID): two sessions of the
///    same environment each hold their own intent, so registering one never
///    overwrites — and never silently loses — another run's explicit choice.
///  * The armed claim is EXCLUSIVE per environment. A second run that tries to
///    start the same environment while another run's claim is armed is refused
///    with `ShellGuestRunShapeError.startAlreadyInProgress`; it never
///    overwrites the armed value, so the in-flight start's descriptor
///    resolution can only ever read its own run's shape (a concurrent
///    read-only status/ownership probe reads the same value and discards it).
///  * The claim applies the release gate BEFORE any start call. An
///    unqualified explicit request (two harts under the single-hart production
///    release) throws `GuestReleaseShapeError.unsupportedReleaseVCPUCount`,
///    arms nothing and drops the intent, so a refused dual selection can never
///    silently become a one-hart boot.
///  * A failed start keeps the run's pending intent (`finishClaim(consumed:
///    false)`): the app's image-preparation retry re-claims the SAME shape
///    instead of falling back to the worker default. Only a completed start
///    consumes it, and the registering run always clears its own intent.
///  * This build's descriptor channel carries count + RAM only: the pool
///    reconstructs the origin as `.environmentPolicy` (strict) for a descriptor
///    value. That is why an explicit selection is `.strict` here too, and why
///    an automatic plan's authorized downgrade is resolved and recorded at the
///    entry (its request already sits at the authorized floor) rather than
///    being delegated to the pool.
public final class ShellGuestRunShapeCenter: @unchecked Sendable {
    public struct Configuration: Sendable, Equatable {
        /// How long an unclaimed intent stays valid. Deliberately short: the
        /// controller registers the intent immediately before opening the run.
        public var intentLifetime: TimeInterval

        public init(intentLifetime: TimeInterval = 120) {
            self.intentLifetime = max(1, min(intentLifetime, 900))
        }
    }

    private struct RunKey: Hashable {
        let environmentID: String
        let runID: String
    }

    public let configuration: Configuration
    private let lock = NSLock()
    /// (environmentID, runID) → intent registered by a run entry, not yet
    /// consumed.
    private var pending: [RunKey: ShellGuestRunShapeIntent] = [:]
    /// environmentID → the exclusive claim armed for the start in flight.
    private var armed: [String: ShellGuestRunShapeIntent] = [:]
    /// A claimed run may spend longer than `intentLifetime` downloading its
    /// first image before retrying. Its owner clears the intent when the run
    /// ends, so expiry must not silently turn that retry into a default boot.
    private var retryProtectedRuns: Set<RunKey> = []

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Registers (or replaces) the intent of exactly this run. Another run's
    /// pending intent for the same environment is untouched.
    public func register(_ intent: ShellGuestRunShapeIntent) {
        lock.withLock {
            pruneExpiredLocked(now: Date())
            let key = RunKey(environmentID: intent.environmentID, runID: intent.runID)
            retryProtectedRuns.remove(key)
            pending[key] = intent
        }
    }

    /// Drops the intent of exactly this run; another run's intent (and another
    /// environment) is untouched.
    public func clear(environmentID: String, runID: String) {
        lock.withLock {
            let key = RunKey(environmentID: environmentID, runID: runID)
            pending.removeValue(forKey: key)
            retryProtectedRuns.remove(key)
            if armed[environmentID]?.runID == runID { armed.removeValue(forKey: environmentID) }
        }
    }

    /// The still-fresh intent for one run, without claiming it. An expired
    /// intent answers nil and is dropped so it can never shape a later start.
    public func intent(
        environmentID: String,
        runID: String,
        now: Date = Date()
    ) -> ShellGuestRunShapeIntent? {
        lock.withLock {
            let key = RunKey(environmentID: environmentID, runID: runID)
            guard let candidate = pending[key] else { return nil }
            let age = now.timeIntervalSince(candidate.recordedAt)
            guard retryProtectedRuns.contains(key) || age <= configuration.intentLifetime else {
                pending.removeValue(forKey: key)
                return nil
            }
            return candidate
        }
    }

    /// Claims the run's pending intent for the start it is about to make and
    /// arms it exclusively for that start's descriptor resolution.
    ///
    /// The pending intent is deliberately NOT removed here: a start that fails
    /// before booting (for example an unqualified image that the caller
    /// prepares and retries) must be able to re-claim the same shape.
    /// `finishClaim(consumed: true)` retires it after a completed start.
    ///
    /// - Throws `ShellGuestRunShapeError.startAlreadyInProgress` when another
    ///   run's claim is armed for this environment.
    /// - Throws the typed release error for an unqualified request; the
    ///   refused intent is dropped and nothing is armed.
    @discardableResult
    public func claimForStart(
        environmentID: String,
        runID: String,
        releasePolicy: GuestReleaseShapePolicy = .production,
        now: Date = Date()
    ) throws -> ShellGuestRunShapeIntent? {
        guard let claimed = intent(environmentID: environmentID, runID: runID, now: now) else {
            return nil
        }
        guard releasePolicy.supports(claimed.request.vcpus) else {
            lock.withLock {
                let key = RunKey(environmentID: environmentID, runID: runID)
                pending.removeValue(forKey: key)
                retryProtectedRuns.remove(key)
            }
            throw GuestReleaseShapeError.unsupportedReleaseVCPUCount(
                requested: claimed.request.vcpus.count,
                releaseMaximum: releasePolicy.maximumSupportedVCPUs
            )
        }
        try lock.withLock {
            if let active = armed[environmentID], active.runID != runID {
                throw ShellGuestRunShapeError.startAlreadyInProgress(environmentID: environmentID)
            }
            armed[environmentID] = claimed
            retryProtectedRuns.insert(RunKey(environmentID: environmentID, runID: runID))
        }
        return claimed
    }

    /// Consumes the run's intent when the environment's guest is ALREADY
    /// RUNNING: no start will resolve a descriptor, so nothing is armed and the
    /// intent cannot shape a later unrelated start. The caller still has to
    /// decide whether the running shape matches an explicit request.
    @discardableResult
    public func resolveForRunningGuest(
        environmentID: String,
        runID: String,
        releasePolicy: GuestReleaseShapePolicy = .production,
        now: Date = Date()
    ) throws -> ShellGuestRunShapeIntent? {
        guard let resolved = intent(environmentID: environmentID, runID: runID, now: now) else {
            return nil
        }
        guard releasePolicy.supports(resolved.request.vcpus) else {
            lock.withLock {
                let key = RunKey(environmentID: environmentID, runID: runID)
                pending.removeValue(forKey: key)
                retryProtectedRuns.remove(key)
            }
            throw GuestReleaseShapeError.unsupportedReleaseVCPUCount(
                requested: resolved.request.vcpus.count,
                releaseMaximum: releasePolicy.maximumSupportedVCPUs
            )
        }
        lock.withLock {
            let key = RunKey(environmentID: environmentID, runID: runID)
            pending.removeValue(forKey: key)
            retryProtectedRuns.remove(key)
        }
        return resolved
    }

    /// Ends one claim. `consumed: true` retires the intent (the start it was
    /// claimed for ran); `consumed: false` keeps it for a retry of the same run
    /// and only drops the arm, so a failed start never silently loses the
    /// run's shape.
    public func finishClaim(
        environmentID: String,
        intent claimed: ShellGuestRunShapeIntent?,
        consumed: Bool
    ) {
        guard let claimed else { return }
        lock.withLock {
            if armed[environmentID] == claimed { armed.removeValue(forKey: environmentID) }
            if consumed {
                let key = RunKey(environmentID: environmentID, runID: claimed.runID)
                pending.removeValue(forKey: key)
                retryProtectedRuns.remove(key)
            }
        }
    }

    /// The armed value the run's descriptor resolution reads. Read-only on
    /// purpose: a concurrent status/ownership probe must not consume what the
    /// start in flight still needs, and the exclusive claim guarantees it can
    /// only ever be the start's own run.
    public func armedIntent(environmentID: String) -> ShellGuestRunShapeIntent? {
        lock.withLock { armed[environmentID] }
    }

    /// The typed refusal for an EXPLICIT request against the core count an
    /// already-running guest was granted, or nil when the request may reuse the
    /// running guest as-is.
    ///
    /// `runningVCPUs == nil` means the granted count could not be read while a
    /// guest is known to be running: fail closed instead of assuming a match.
    /// An automatic plan never refuses here — it reuses whatever shape the
    /// guest already has (a running VM is never reshaped or restarted by a
    /// run).
    public static func runningGuestRefusal(
        requestedVCPUs: GuestVCPUCount,
        selection: GuestRunEntryShapeSelection,
        environmentID: String,
        runningVCPUs: Int?
    ) -> ShellGuestRunShapeError? {
        guard selection != .automatic else { return nil }
        guard let runningVCPUs else {
            return .runningGuestShapeUnknown(
                environmentID: environmentID, requestedVCPUs: requestedVCPUs.count
            )
        }
        guard runningVCPUs == requestedVCPUs.count else {
            return .runningGuestShapeMismatch(
                environmentID: environmentID,
                requestedVCPUs: requestedVCPUs.count,
                runningVCPUs: runningVCPUs
            )
        }
        return nil
    }

    /// Drops every pending and armed intent (tests, shutdown hygiene).
    public func clearAll() {
        lock.withLock {
            pending.removeAll()
            armed.removeAll()
            retryProtectedRuns.removeAll()
        }
    }

    public var pendingCount: Int { lock.withLock { pending.count } }
    public var armedCount: Int { lock.withLock { armed.count } }

    private func pruneExpiredLocked(now: Date) {
        let expired = pending.filter {
            !retryProtectedRuns.contains($0.key)
                && now.timeIntervalSince($0.value.recordedAt) > configuration.intentLifetime
        }
        for key in expired.keys { pending.removeValue(forKey: key) }
    }
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
