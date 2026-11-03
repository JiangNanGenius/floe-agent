// SPDX-License-Identifier: MPL-2.0
//
// C02 — real model-command SSH execution adapter.
//
// This is the missing bridge between the ordinary task authority and the
// already-qualified C05 SSH transport. It does NOT call the host-only
// `floe.remote/9` UI channel, does NOT spawn a host `ssh` process and does
// NOT use a guest-language fallback. A model command reaches the configured
// host only through:
//
//   C02ExecutionTargetDomain (pinned target + run pin + task policy)
//     -> C02SSHExecutionAuthorization
//     -> this adapter
//     -> SSHTransportConnecting / SSHSessionTransport (FloeSSH/Citadel)
//     -> one owned exec channel with bounded streamed output
//
// Trust rules:
//   * credentials and host keys come only from the existing
//     RemoteHostStore / approved credential gateway;
//   * a changed or first-use key is surfaced as a typed challenge and is
//     never silently trusted; approval is a fresh explicit host-key write;
//   * VNC/TCP/BLE profiles are not execution environments;
//   * a supplied session id alone grants nothing: an explicit rebind grant
//     carrying the exact task/target revision/root epoch/owner token is
//     required.
//
// Outcome rules:
//   * `.remoteExited` is the only proof that the remote command ended; a
//     local channel close or transport failure after dispatch is
//     `.unknownRemoteState` and is never replayed or reported as "stopped";
//   * receipts use the existing run/tool-call identity and are persisted
//     before dispatch; the receipt ledger is not a second job registry and
//     owns no processor/state machine.
import Foundation
import FloeCore
import FloeTools
import FloePersistence
import FloeSSH

// MARK: - Authorization

/// Minted only by `C02ExecutionTargetDomain` after fresh ownership,
/// permission, target and run-pin checks. Not Codable and not model-mintable.
public struct C02SSHExecutionAuthorization: Sendable, Equatable {
    public var taskID: UUID
    public var runID: UUID
    public var target: C02ExecutionTarget
    public var targetRevision: Int64
    public var rootEpoch: UInt64
    /// Per-authorization owner token. A stored session is reachable only by
    /// the same token; a call that merely knows the session id is refused.
    public var ownerToken: String
    public var sessionID: String?
    public var sessionOwnerToken: String?
    public var approvedHostKeyFingerprint: String?
    public var permissionGrantID: UUID
    public var issuedAt: Date
    public var expiresAt: Date

    public init(
        taskID: UUID,
        runID: UUID,
        target: C02ExecutionTarget,
        targetRevision: Int64,
        rootEpoch: UInt64,
        ownerToken: String,
        sessionID: String? = nil,
        sessionOwnerToken: String? = nil,
        approvedHostKeyFingerprint: String? = nil,
        permissionGrantID: UUID,
        issuedAt: Date,
        expiresAt: Date
    ) {
        self.taskID = taskID
        self.runID = runID
        self.target = target
        self.targetRevision = targetRevision
        self.rootEpoch = rootEpoch
        self.ownerToken = ownerToken
        self.sessionID = sessionID
        self.sessionOwnerToken = sessionOwnerToken
        self.approvedHostKeyFingerprint = approvedHostKeyFingerprint
        self.permissionGrantID = permissionGrantID
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }

    public func validate(now: Date, pin: C02RunTargetPin?) throws {
        guard now < expiresAt else {
            throw C02SSHAdapterError.authorizationExpired
        }
        guard target.kind == .ssh, let remote = target.remote else {
            throw C02SSHAdapterError.targetMismatch
        }
        do {
            try target.validate()
        } catch {
            throw C02SSHAdapterError.invalidAuthorization("target")
        }
        guard target.taskID == taskID,
              target.revision == targetRevision,
              remote.hostID != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) else {
            throw C02SSHAdapterError.targetMismatch
        }
        guard (8...128).contains(ownerToken.utf8.count), !ownerToken.contains("\0") else {
            throw C02SSHAdapterError.invalidAuthorization("ownerToken")
        }
        guard let pin,
              pin.targetRevision == targetRevision,
              pin.environmentID == target.environmentID,
              pin.taskID == taskID,
              pin.rootEpoch == rootEpoch else {
            throw C02SSHAdapterError.runPinMismatch
        }
        if let sessionID {
            guard let sessionOwnerToken,
                  (8...128).contains(sessionOwnerToken.utf8.count) else {
                throw C02SSHAdapterError.sessionRebindRefused
            }
            _ = sessionID
        }
    }
}

// MARK: - Request / result

public struct C02SSHExecutionRequest: Sendable, Equatable {
    /// Stable existing operation identity. For a job it is the job identity;
    /// for a foreground call it is derived from run + tool call. It is never
    /// a second remote-task registry.
    public var operationID: String
    public var authorization: C02SSHExecutionAuthorization
    public var command: String
    public var cwd: String
    public var environment: [String: String]
    public var stdin: String?
    public var timeout: TimeInterval
    public var maxOutputBytes: Int
    public var cancellation: CancellationToken

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.operationID == rhs.operationID && lhs.authorization == rhs.authorization &&
        lhs.command == rhs.command && lhs.cwd == rhs.cwd && lhs.environment == rhs.environment &&
        lhs.stdin == rhs.stdin && lhs.timeout == rhs.timeout &&
        lhs.maxOutputBytes == rhs.maxOutputBytes && lhs.cancellation === rhs.cancellation
    }

    public init(
        operationID: String,
        authorization: C02SSHExecutionAuthorization,
        command: String,
        cwd: String = ".",
        environment: [String: String] = [:],
        stdin: String? = nil,
        timeout: TimeInterval,
        maxOutputBytes: Int,
        cancellation: CancellationToken
    ) {
        self.operationID = operationID
        self.authorization = authorization
        self.command = command
        self.cwd = cwd
        self.environment = environment
        self.stdin = stdin
        self.timeout = timeout
        self.maxOutputBytes = maxOutputBytes
        self.cancellation = cancellation
    }
}

public enum C02SSHStopProof: String, Sendable, Equatable, Codable {
    /// The remote command returned its real exit status.
    case remoteExited
    /// Only the local channel/session closed. The remote process may still
    /// be running; callers must not claim it stopped.
    case localChannelClosed
    /// The transport failed or the deadline fired after dispatch and the
    /// remote state is unknown. Never replay automatically.
    case unknownRemoteState
}

public enum C02SSHExecutionState: Sendable, Equatable {
    case exited(Int32)
    case timedOut
    case cancelled
    case outcomeUnknown(String)

    public var exitStatus: Int32 {
        switch self {
        case .exited(let code): return code
        case .timedOut: return 124
        case .cancelled: return 130
        case .outcomeUnknown: return 125
        }
    }

    public var isUnknown: Bool {
        if case .outcomeUnknown = self { return true }
        return false
    }
}

public struct C02SSHExecutionResult: Sendable, Equatable {
    public var state: C02SSHExecutionState
    public var stdout: String
    public var stderr: String
    public var stdoutBytes: Int64
    public var stderrBytes: Int64
    public var truncated: Bool
    public var durationMs: Int
    public var dispatched: Bool
    public var stopProof: C02SSHStopProof
    public var receiptPersisted: Bool
    public var receiptState: C02RemoteCommandReceipt.State?

    public init(
        state: C02SSHExecutionState,
        stdout: String,
        stderr: String,
        stdoutBytes: Int64,
        stderrBytes: Int64,
        truncated: Bool,
        durationMs: Int,
        dispatched: Bool,
        stopProof: C02SSHStopProof,
        receiptPersisted: Bool,
        receiptState: C02RemoteCommandReceipt.State?
    ) {
        self.state = state
        self.stdout = stdout
        self.stderr = stderr
        self.stdoutBytes = stdoutBytes
        self.stderrBytes = stderrBytes
        self.truncated = truncated
        self.durationMs = durationMs
        self.dispatched = dispatched
        self.stopProof = stopProof
        self.receiptPersisted = receiptPersisted
        self.receiptState = receiptState
    }

    /// Bounded, secret-free model-facing summary. It states the actual
    /// remote-state proof so a disconnect is never presented as a stop.
    public var summary: String {
        var text = "transport=ssh target=remote"
        switch state {
        case .exited(let code):
            text += " exit=\(code) stopProof=remoteExited"
        case .timedOut:
            text += " exit=124 status=timedOut remoteState=unknown stopProof=unknownRemoteState"
        case .cancelled:
            text += " exit=130 status=cancelled remoteState=unknown stopProof=localChannelClosed"
        case .outcomeUnknown(let reason):
            text += " exit=125 status=outcomeUnknown remoteState=unknown reason=\(reason) stopProof=unknownRemoteState"
        }
        text += " durationMs=\(durationMs) stdoutBytes=\(stdoutBytes) stderrBytes=\(stderrBytes)"
        if truncated { text += " truncated" }
        if !receiptPersisted { text += " receipt=unpersisted" }
        if !stdout.isEmpty {
            text += "\n--- output (remote stdout) ---\n\(SecretRedactor.redact(stdout))"
        }
        if !stderr.isEmpty {
            text += "\n--- remote stderr ---\n\(SecretRedactor.redact(stderr))"
        }
        return text
    }
}

// MARK: - Errors

public enum C02SSHAdapterError: Error, Sendable, Equatable {
    case invalidAuthorization(String)
    case authorizationExpired
    case targetMismatch
    case runPinMismatch
    case permissionDenied
    case hostNotFound
    case hostNotExecutionEnvironment
    case sshNotConfigured
    case credentialUnavailable
    case connectionFailed(String)
    case notStarted(String)
    case hostKeyApprovalRequired(C02RemoteHostKeyChallenge)
    case hostKeyChanged(C02RemoteHostKeyChallenge)
    case sessionRebindRefused
    case sessionLimit
    case invalidCommand(String)
    case receiptUnavailable
    case cancelled

    public var code: String {
        switch self {
        case .invalidAuthorization(let field): return "invalidAuthorization:\(field)"
        case .authorizationExpired: return "authorizationExpired"
        case .targetMismatch: return "targetMismatch"
        case .runPinMismatch: return "runPinMismatch"
        case .permissionDenied: return "permissionDenied"
        case .hostNotFound: return "hostNotFound"
        case .hostNotExecutionEnvironment: return "hostNotExecutionEnvironment"
        case .sshNotConfigured: return "sshNotConfigured"
        case .credentialUnavailable: return "credentialUnavailable"
        case .connectionFailed: return "connectionFailed"
        case .notStarted: return "notStarted"
        case .hostKeyApprovalRequired: return "hostKeyApprovalRequired"
        case .hostKeyChanged: return "hostKeyChanged"
        case .sessionRebindRefused: return "sessionRebindRefused"
        case .sessionLimit: return "sessionLimit"
        case .invalidCommand: return "invalidCommand"
        case .receiptUnavailable: return "receiptUnavailable"
        case .cancelled: return "cancelled"
        }
    }

    public var message: String {
        switch self {
        case .invalidAuthorization(let field): return "The SSH execution authorization is invalid: \(field)"
        case .authorizationExpired: return "The SSH execution authorization expired."
        case .targetMismatch: return "The execution target does not match this authorization."
        case .runPinMismatch: return "The run is not pinned to this execution target."
        case .permissionDenied: return "Remote execution is not permitted for this task."
        case .hostNotFound: return "The configured SSH host no longer exists."
        case .hostNotExecutionEnvironment: return "The selected host is not configured as an SSH execution environment."
        case .sshNotConfigured: return "The configured host has no SSH connection."
        case .credentialUnavailable: return "The SSH credential is unavailable."
        case .connectionFailed(let reason): return "The SSH connection failed: \(reason)"
        case .notStarted(let reason): return "The remote command was not started: \(reason)"
        case .hostKeyApprovalRequired: return "Confirm the SSH host key before using this host."
        case .hostKeyChanged: return "The SSH host key changed. The stored key was not replaced."
        case .sessionRebindRefused: return "The supplied session cannot be reused without a fresh explicit rebind."
        case .sessionLimit: return "Too many SSH execution sessions are open."
        case .invalidCommand(let reason): return "The remote command is invalid: \(reason)"
        case .receiptUnavailable: return "The remote operation receipt could not be recorded."
        case .cancelled: return "The remote command was cancelled."
        }
    }

    /// Secret-free detail for diagnostics. Never remote prose, command text
    /// or a credential.
    public var diagnosticDetail: String? {
        switch self {
        case .connectionFailed(let reason), .notStarted(let reason), .invalidCommand(let reason):
            return String(SecretRedactor.redact(reason).prefix(240))
        default:
            return nil
        }
    }
}

// MARK: - Production store seams

public protocol C02RunTargetPinProviding: Sendable {
    func runPin(runID: UUID) async throws -> C02RunTargetPin?
}

public protocol C02RemoteCommandReceiptStoring: Sendable {
    func recordReceipt(_ receipt: C02RemoteCommandReceipt) async throws -> C02RemoteCommandReceipt
}

extension C02SQLiteExecutionTargetStore: C02RunTargetPinProviding {}
extension C02SQLiteExecutionTargetStore: C02RemoteCommandReceiptStoring {}

// MARK: - Command construction

/// Builds ONE POSIX remote command with an explicit root/cwd/environment.
/// Everything model-supplied is single-quoted; the root is the trusted task
/// root from the pinned target, never a model-selected absolute path.
public enum C02RemoteCommandBuilder {
    public static let maximumCommandBytes = 16 * 1_024
    public static let maximumStdinBytes = 256 * 1_024
    public static let maximumEnvironmentEntries = 32
    public static let maximumEnvironmentBytes = 8 * 1_024

    public static func build(
        command: String,
        remoteRootPath: String,
        cwd: String,
        environment: [String: String],
        stdin: String?,
        operatingSystem: String
    ) throws -> String {
        guard !command.contains("\0") else {
            throw C02SSHAdapterError.invalidCommand("nul")
        }
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              command.utf8.count <= maximumCommandBytes else {
            throw C02SSHAdapterError.invalidCommand("size")
        }
        guard C02ExecutionTarget.isValidRemoteRoot(remoteRootPath) else {
            throw C02SSHAdapterError.invalidCommand("remoteRoot")
        }
        let relative = try validateRelativeCwd(cwd)
        guard environment.count <= maximumEnvironmentEntries else {
            throw C02SSHAdapterError.invalidCommand("environmentCount")
        }
        var environmentBytes = 0
        var pairs: [String] = []
        for key in environment.keys.sorted() {
            guard isValidEnvironmentKey(key) else {
                throw C02SSHAdapterError.invalidCommand("environmentKey")
            }
            let value = environment[key] ?? ""
            guard !value.contains("\0"), !value.contains("\n"), !value.contains("\r") else {
                throw C02SSHAdapterError.invalidCommand("environmentValue")
            }
            environmentBytes += key.utf8.count + value.utf8.count + 1
            pairs.append(shellQuote("\(key)=\(value)"))
        }
        guard environmentBytes <= maximumEnvironmentBytes else {
            throw C02SSHAdapterError.invalidCommand("environmentSize")
        }
        let stdinPayload: String?
        if let stdin, !stdin.isEmpty {
            let bytes = Data(stdin.utf8)
            guard bytes.count <= maximumStdinBytes else {
                throw C02SSHAdapterError.invalidCommand("stdinSize")
            }
            stdinPayload = bytes.base64EncodedString()
        } else {
            stdinPayload = nil
        }
        let directory = "umask 077 && mkdir -p \(shellQuote(remoteRootPath))"
            + " && cd \(shellQuote(remoteRootPath))"
            + (relative == "." ? "" : " && cd \(shellQuote(relative))")
        let runner = pairs.isEmpty
            ? "/bin/sh -lc \(shellQuote(command))"
            : "env \(pairs.joined(separator: " ")) /bin/sh -lc \(shellQuote(command))"
        guard let stdinPayload else {
            return "\(directory) && \(runner)"
        }
        let decoder = operatingSystem == "macos" ? "base64 -D" : "base64 -d"
        return "\(directory) && printf %s \(shellQuote(stdinPayload)) | \(decoder) | \(runner)"
    }

    public static func validateRelativeCwd(_ cwd: String) throws -> String {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "." { return "." }
        guard !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~"),
              !trimmed.contains("\0"), !trimmed.contains("\n"),
              !trimmed.contains("\r"), trimmed.utf8.count <= 1_024 else {
            throw C02SSHAdapterError.invalidCommand("cwd")
        }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0 == ".." || $0.isEmpty }) else {
            throw C02SSHAdapterError.invalidCommand("cwd")
        }
        return trimmed
    }

    public static func isValidEnvironmentKey(_ key: String) -> Bool {
        guard (1...64).contains(key.utf8.count),
              let first = key.utf8.first else { return false }
        func isAlpha(_ byte: UInt8) -> Bool {
            (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
        }
        guard isAlpha(first) || first == 95 else { return false }
        return key.utf8.allSatisfy { byte in
            isAlpha(byte) || (byte >= 48 && byte <= 57) || byte == 95
        }
    }

    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Bounded output

actor C02SSHOutputCollector {
    struct Snapshot: Sendable, Equatable {
        var stdout: String
        var stderr: String
        var stdoutBytes: Int64
        var stderrBytes: Int64
        var truncated: Bool
    }

    private let limit: Int
    private var stdout = ""
    private var stderr = ""
    private var stdoutBytes: Int64 = 0
    private var stderrBytes: Int64 = 0
    private var stored = 0
    private var truncated = false

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func append(_ channel: SSHStreamChannel, _ data: Data) {
        switch channel {
        case .stdout:
            stdoutBytes += Int64(data.count)
            let accepted = append(data, to: &stdout)
            stored += accepted
        case .stderr:
            stderrBytes += Int64(data.count)
            let accepted = append(data, to: &stderr)
            stored += accepted
        }
    }

    private func append(_ data: Data, to target: inout String) -> Int {
        let remaining = max(0, limit - stored)
        guard remaining > 0 else {
            truncated = true
            return 0
        }
        let accepted = data.prefix(remaining)
        target += String(decoding: accepted, as: UTF8.self)
        if accepted.count < data.count { truncated = true }
        return accepted.count
    }

    func snapshot() -> Snapshot {
        Snapshot(
            stdout: stdout,
            stderr: stderr,
            stdoutBytes: stdoutBytes,
            stderrBytes: stderrBytes,
            truncated: truncated
        )
    }
}

private enum C02SSHExecRace: Sendable {
    case exited(Int32)
    case deadline
    case cancelled
    case streamEnded
    case streamFailed(String)
}

// MARK: - Adapter limits

public struct C02SSHAdapterLimits: Sendable, Equatable {
    public var maximumSessions: Int
    public var maximumSessionsPerTask: Int
    public var maximumCommandBytes: Int
    public var maximumOutputBytes: Int
    public var defaultTimeout: TimeInterval
    public var maximumTimeout: TimeInterval

    public init(
        maximumSessions: Int = 4,
        maximumSessionsPerTask: Int = 2,
        maximumCommandBytes: Int = 16 * 1_024,
        maximumOutputBytes: Int = 256 * 1_024,
        defaultTimeout: TimeInterval = 10,
        maximumTimeout: TimeInterval = 600
    ) {
        self.maximumSessions = max(1, min(maximumSessions, 8))
        self.maximumSessionsPerTask = max(1, min(maximumSessionsPerTask, 4))
        self.maximumCommandBytes = max(1_024, min(maximumCommandBytes, 64 * 1_024))
        self.maximumOutputBytes = max(1_024, min(maximumOutputBytes, 512 * 1_024))
        self.defaultTimeout = max(0.05, min(defaultTimeout, 120))
        self.maximumTimeout = max(self.defaultTimeout, min(maximumTimeout, 600))
    }
}

// MARK: - Stored session

private struct C02SSHSession {
    var id: String
    var taskID: UUID
    var targetRevision: Int64
    var environmentID: String
    var hostID: UUID
    var rootEpoch: UInt64
    var ownerToken: String
    var transport: any SSHSessionTransport
    var createdAt: Date
    var lastUsedAt: Date
    var activeOperations: Int
}

// MARK: - Adapter

public actor C02SSHExecutionAdapter: C02RemoteTargetProbing {
    private let hostStore: RemoteHostStore
    private let connectorFactory: @Sendable (UInt64) async throws -> any SSHTransportConnecting
    private let credentialResolver: SSHCredentialResolver
    private let pins: any C02RunTargetPinProviding
    private let receipts: any C02RemoteCommandReceiptStoring
    private let liveEpoch: (@Sendable () -> UInt64?)?
    private let now: @Sendable () -> Date
    private let limits: C02SSHAdapterLimits
    private var sessions: [String: C02SSHSession] = [:]

    public init(
        hostStore: RemoteHostStore,
        connectorFactory: @escaping @Sendable (UInt64) async throws -> any SSHTransportConnecting,
        credentialResolver: @escaping SSHCredentialResolver,
        pins: any C02RunTargetPinProviding,
        receipts: any C02RemoteCommandReceiptStoring,
        liveEpoch: (@Sendable () -> UInt64?)? = nil,
        limits: C02SSHAdapterLimits = C02SSHAdapterLimits(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.hostStore = hostStore
        self.connectorFactory = connectorFactory
        self.credentialResolver = credentialResolver
        self.pins = pins
        self.receipts = receipts
        self.liveEpoch = liveEpoch
        self.limits = limits
        self.now = now
    }

    public func activeSessionCount() -> Int { sessions.count }

    public func sessionIDs(taskID: UUID) -> [String] {
        sessions.values.filter { $0.taskID == taskID }.map(\.id).sorted()
    }

    // MARK: Probe (read-only)

    public func probeRemote(
        hostID: UUID,
        taskID: UUID,
        expectedFingerprint: String?
    ) async throws -> C02RemoteEnvironmentFacts {
        let profile = try await profile(hostID: hostID)
        guard profile.isRemoteExecutionEnvironment else {
            throw C02SSHAdapterError.hostNotExecutionEnvironment
        }
        guard profile.auth != .none else {
            throw C02SSHAdapterError.sshNotConfigured
        }
        let authorization = C02SSHExecutionAuthorization(
            taskID: taskID,
            runID: UUID(),
            target: C02ExecutionTarget(
                taskID: taskID,
                revision: 1,
                kind: .ssh,
                environmentID: C02RemoteEnvironmentID.make(
                    hostID: hostID, remoteRootPath: "/"),
                projectID: nil,
                workspaceID: UUID(),
                shellRootHash: String(repeating: "a", count: 64),
                engineOwnerHash: String(repeating: "b", count: 64),
                rootEpoch: 1,
                remote: C02RemoteEnvironmentFacts(
                    hostID: hostID, remoteRootPath: "/", operatingSystem: "linux",
                    architecture: "unknown", runtimeGeneration: "probe"),
                provenance: .explicitUserSelection,
                createdAt: now(), updatedAt: now()),
            targetRevision: 1,
            rootEpoch: 1,
            ownerToken: UUID().uuidString,
            sessionID: nil,
            sessionOwnerToken: nil,
            approvedHostKeyFingerprint: expectedFingerprint,
            permissionGrantID: UUID(),
            issuedAt: now(),
            expiresAt: now().addingTimeInterval(60)
        )
        let session = try await connect(
            profile: profile,
            authorization: authorization,
            expectedFingerprint: expectedFingerprint
        )
        defer { Task { await session.close() } }
        let command = """
        printf 'FLOE_SYSTEM='; uname -s; \
        printf 'FLOE_ARCH='; uname -m; \
        printf 'FLOE_HOME='; (cd "$HOME" && pwd -P); \
        printf 'FLOE_ID='; (sed -n 's/^ID=//p' /etc/os-release 2>/dev/null | head -n 1); \
        printf 'FLOE_BOOT='; (cat /proc/sys/kernel/random/boot_id 2>/dev/null || sysctl -n kern.boottime 2>/dev/null || true)
        """
        let result = await runOnce(
            transport: session,
            command: command,
            timeout: 15,
            maxOutputBytes: 64 * 1_024,
            cancellation: CancellationToken()
        )
        guard result.state.isExited, result.state.exitStatus == 0, !result.truncated else {
            throw C02SSHAdapterError.connectionFailed("probeFailed")
        }
        var values: [String: String] = [:]
        for line in result.stdout.components(separatedBy: .newlines) {
            if let index = line.firstIndex(of: "=") {
                values[String(line[..<index])] = String(line[line.index(after: index)...])
            }
        }
        guard let system = values["FLOE_SYSTEM"],
              let architecture = values["FLOE_ARCH"],
              let home = values["FLOE_HOME"],
              let boot = values["FLOE_BOOT"],
              system == "Linux" || system == "Darwin",
              C02ExecutionTarget.isValidRemoteRoot(home),
              !boot.isEmpty else {
            throw C02SSHAdapterError.connectionFailed("probeUnrecognised")
        }
        guard let root = C02RemoteEnvironmentID.defaultTaskRoot(home: home, taskID: taskID) else {
            throw C02SSHAdapterError.connectionFailed("probeHome")
        }
        return C02RemoteEnvironmentFacts(
            hostID: hostID,
            remoteRootPath: root,
            operatingSystem: system == "Darwin" ? "macos" : "linux",
            architecture: architecture,
            runtimeGeneration: String(boot.prefix(256)),
            distribution: values["FLOE_ID"],
            hostKeyFingerprintSHA256: expectedFingerprint
        )
    }

    // MARK: Execute

    public func execute(_ request: C02SSHExecutionRequest) async throws -> C02SSHExecutionResult {
        let started = now()
        let authorization = request.authorization
        let pin = try await pins.runPin(runID: authorization.runID)
        do {
            try authorization.validate(now: started, pin: pin)
        } catch let error as C02SSHAdapterError {
            throw error
        }
        guard C02RemoteCommandReceipt.isValidOperationID(request.operationID) else {
            throw C02SSHAdapterError.invalidAuthorization("operationID")
        }
        guard request.command.utf8.count <= limits.maximumCommandBytes else {
            throw C02SSHAdapterError.invalidCommand("size")
        }
        guard let remote = authorization.target.remote else {
            throw C02SSHAdapterError.targetMismatch
        }
        if let liveEpoch, liveEpoch() != authorization.rootEpoch {
            throw C02SSHAdapterError.authorizationExpired
        }
        let requestedTimeout = request.timeout.isFinite && request.timeout > 0
            ? request.timeout : limits.defaultTimeout
        let timeout = max(0.05, min(requestedTimeout, limits.maximumTimeout))
        let outputLimit = max(1, min(request.maxOutputBytes, limits.maximumOutputBytes))
        let script = try C02RemoteCommandBuilder.build(
            command: request.command,
            remoteRootPath: remote.remoteRootPath,
            cwd: request.cwd,
            environment: request.environment,
            stdin: request.stdin,
            operatingSystem: remote.operatingSystem
        )
        let profile = try await profile(hostID: remote.hostID)
        guard profile.isRemoteExecutionEnvironment else {
            throw C02SSHAdapterError.hostNotExecutionEnvironment
        }
        guard profile.auth != .none else {
            throw C02SSHAdapterError.sshNotConfigured
        }
        let session: C02SSHSession
        do {
            session = try await acquireSession(
                profile: profile,
                authorization: authorization,
                expectedFingerprint: authorization.approvedHostKeyFingerprint
            )
        } catch let error as C02SSHAdapterError {
            throw error
        }
        if request.cancellation.isCancelled {
            throw C02SSHAdapterError.cancelled
        }
        let receipt = C02RemoteCommandReceipt(
            operationID: request.operationID,
            taskID: authorization.taskID,
            runID: authorization.runID,
            toolCallID: nil,
            targetRevision: authorization.targetRevision,
            rootEpoch: authorization.rootEpoch,
            hostID: remote.hostID,
            commandSHA256: FloeDigest.sha256Hex(Data(request.command.utf8)),
            state: .dispatched,
            exitCode: nil,
            startedAt: started,
            updatedAt: started,
            detailCode: nil
        )
        do {
            _ = try await receipts.recordReceipt(receipt)
        } catch {
            throw C02SSHAdapterError.receiptUnavailable
        }
        let exec: any SSHSessionExec
        do {
            exec = try await session.transport.openExec(script)
        } catch {
            // No channel was opened: nothing was dispatched. Close the
            // pre-dispatch receipt as `notStarted`, never as an exit/unknown.
            let now = self.now()
            _ = try? await receipts.recordReceipt(C02RemoteCommandReceipt(
                operationID: request.operationID,
                taskID: authorization.taskID,
                runID: authorization.runID,
                toolCallID: nil,
                targetRevision: authorization.targetRevision,
                rootEpoch: authorization.rootEpoch,
                hostID: remote.hostID,
                commandSHA256: receipt.commandSHA256,
                state: .notStarted,
                exitCode: nil,
                startedAt: started,
                updatedAt: now,
                detailCode: "channelNotOpened"
            ))
            throw C02SSHAdapterError.notStarted(
                String(SecretRedactor.redact(error.localizedDescription).prefix(240)))
        }
        markActive(sessionID: session.id, delta: 1)
        let collector = C02SSHOutputCollector(limit: outputLimit)
        let race = await Self.raceExec(
            exec: exec,
            collector: collector,
            timeout: timeout,
            cancellation: request.cancellation
        )
        exec.cancel()
        markActive(sessionID: session.id, delta: -1)
        let snapshot = await collector.snapshot()
        let durationMs = max(0, Int(now().timeIntervalSince(started) * 1_000))
        let state: C02SSHExecutionState
        let stopProof: C02SSHStopProof
        let receiptState: C02RemoteCommandReceipt.State
        let detail: String?
        switch race {
        case .exited(let code):
            state = .exited(code)
            stopProof = .remoteExited
            receiptState = .exited
            detail = nil
        case .deadline:
            state = .timedOut
            stopProof = .unknownRemoteState
            receiptState = .timedOut
            detail = "remoteProcessStateUnknown"
        case .cancelled:
            state = .cancelled
            stopProof = .localChannelClosed
            receiptState = .cancelled
            detail = "remoteProcessStateUnknown"
        case .streamEnded:
            state = .outcomeUnknown("streamEndedWithoutExit")
            stopProof = .unknownRemoteState
            receiptState = .outcomeUnknown
            detail = "streamEndedWithoutExit"
        case .streamFailed(let reason):
            state = .outcomeUnknown(reason)
            stopProof = .unknownRemoteState
            receiptState = .outcomeUnknown
            detail = "streamFailed"
        }
        if !session.transport.isConnected {
            removeSession(id: session.id)
        }
        var persisted = true
        do {
            _ = try await receipts.recordReceipt(C02RemoteCommandReceipt(
                operationID: request.operationID,
                taskID: authorization.taskID,
                runID: authorization.runID,
                toolCallID: nil,
                targetRevision: authorization.targetRevision,
                rootEpoch: authorization.rootEpoch,
                hostID: remote.hostID,
                commandSHA256: receipt.commandSHA256,
                state: receiptState,
                exitCode: state.exitStatus,
                startedAt: started,
                updatedAt: now(),
                detailCode: detail
            ))
        } catch {
            persisted = false
        }
        return C02SSHExecutionResult(
            state: state,
            stdout: snapshot.stdout,
            stderr: snapshot.stderr,
            stdoutBytes: snapshot.stdoutBytes,
            stderrBytes: snapshot.stderrBytes,
            truncated: snapshot.truncated,
            durationMs: durationMs,
            dispatched: true,
            stopProof: stopProof,
            receiptPersisted: persisted,
            receiptState: receiptState
        )
    }

    public func closeSession(id: String) async {
        guard let session = sessions.removeValue(forKey: id) else { return }
        await session.transport.close()
    }

    public func closeSessions(taskID: UUID, targetRevision: Int64, rootEpoch: UInt64) async {
        let ids = sessions.values.filter {
            $0.taskID == taskID && $0.targetRevision == targetRevision
                && $0.rootEpoch == rootEpoch && $0.activeOperations == 0
        }.map(\.id)
        for id in ids { await closeSession(id: id) }
    }

    public func closeAll() async {
        let values = Array(sessions.values)
        sessions.removeAll()
        for session in values { await session.transport.close() }
    }

    // MARK: Connection / session ownership

    private func profile(hostID: UUID) async throws -> RemoteHostProfile {
        let stored: RemoteHostStore.StoredHost
        do {
            guard let row = try await hostStore.host(id: hostID) else {
                throw C02SSHAdapterError.hostNotFound
            }
            stored = row
        } catch let error as C02SSHAdapterError {
            throw error
        } catch {
            throw C02SSHAdapterError.hostNotFound
        }
        do {
            let profile = try RemoteHostProfile(stored: stored)
            try profile.validate()
            return profile
        } catch {
            throw C02SSHAdapterError.hostNotExecutionEnvironment
        }
    }

    private func acquireSession(
        profile: RemoteHostProfile,
        authorization: C02SSHExecutionAuthorization,
        expectedFingerprint: String?
    ) async throws -> C02SSHSession {
        if let requested = authorization.sessionID {
            guard let stored = sessions[requested],
                  stored.ownerToken == authorization.sessionOwnerToken,
                  stored.taskID == authorization.taskID,
                  stored.targetRevision == authorization.targetRevision,
                  stored.environmentID == authorization.target.environmentID,
                  stored.hostID == profile.id,
                  stored.rootEpoch == authorization.rootEpoch,
                  stored.transport.isConnected else {
                throw C02SSHAdapterError.sessionRebindRefused
            }
            var reused = stored
            reused.lastUsedAt = now()
            sessions[requested] = reused
            return reused
        }
        // Reuse only an already-owned session for the exact same task/target
        // revision/root epoch. A caller cannot request a foreign session.
        if let existing = sessions.values.first(where: {
            $0.taskID == authorization.taskID
                && $0.targetRevision == authorization.targetRevision
                && $0.environmentID == authorization.target.environmentID
                && $0.hostID == profile.id
                && $0.rootEpoch == authorization.rootEpoch
                && $0.ownerToken == authorization.ownerToken
                && $0.transport.isConnected
        }) {
            var reused = existing
            reused.lastUsedAt = now()
            sessions[existing.id] = reused
            return reused
        }
        let perTask = sessions.values.filter { $0.taskID == authorization.taskID }.count
        guard sessions.count < limits.maximumSessions,
              perTask < limits.maximumSessionsPerTask else {
            throw C02SSHAdapterError.sessionLimit
        }
        let transport = try await connect(
            profile: profile,
            authorization: authorization,
            expectedFingerprint: expectedFingerprint
        )
        let session = C02SSHSession(
            id: UUID().uuidString.lowercased(),
            taskID: authorization.taskID,
            targetRevision: authorization.targetRevision,
            environmentID: authorization.target.environmentID,
            hostID: profile.id,
            rootEpoch: authorization.rootEpoch,
            ownerToken: authorization.ownerToken,
            transport: transport,
            createdAt: now(),
            lastUsedAt: now(),
            activeOperations: 0
        )
        sessions[session.id] = session
        return session
    }

    private func connect(
        profile: RemoteHostProfile,
        authorization: C02SSHExecutionAuthorization,
        expectedFingerprint: String?
    ) async throws -> any SSHSessionTransport {
        let connector: any SSHTransportConnecting
        do {
            connector = try await connectorFactory(authorization.rootEpoch)
        } catch {
            throw C02SSHAdapterError.connectionFailed("connectorUnavailable")
        }
        let box = C02HostKeyBox()
        do {
            return try await connector.connectTransport(
                profile: profile,
                credentialResolver: credentialResolver,
                hostKeyDecision: { challenge in
                    box.record(challenge)
                    guard let expectedFingerprint else { return false }
                    return SSHHostKeyFingerprint.normalize(expectedFingerprint)
                        == SSHHostKeyFingerprint.normalize(challenge.fingerprintSHA256)
                }
            )
        } catch let error as SSHConnectionError {
            switch error {
            case .hostKeyRejected(let challenge):
                throw C02SSHAdapterError.hostKeyApprovalRequired(
                    Self.challenge(
                        challenge, taskID: authorization.taskID,
                        expected: nil, kind: .firstUse, now: now()))
            case .hostKeyChanged(let expected, let received, let challenge):
                _ = received
                throw C02SSHAdapterError.hostKeyChanged(
                    Self.challenge(
                        challenge, taskID: authorization.taskID,
                        expected: expected, kind: .changed, now: now()))
            case .invalidCredential, .authenticationFailed:
                throw C02SSHAdapterError.credentialUnavailable
            case .sshNotConfigured:
                throw C02SSHAdapterError.sshNotConfigured
            default:
                throw C02SSHAdapterError.connectionFailed(error.category.rawValue)
            }
        } catch {
            throw C02SSHAdapterError.connectionFailed(
                String(SecretRedactor.redact(error.localizedDescription).prefix(240)))
        }
    }

    private func markActive(sessionID: String, delta: Int) {
        guard var session = sessions[sessionID] else { return }
        session.activeOperations = max(0, session.activeOperations + delta)
        sessions[sessionID] = session
    }

    private func removeSession(id: String) {
        sessions.removeValue(forKey: id)
    }

    private static func challenge(
        _ challenge: HostKeyChallenge,
        taskID: UUID,
        expected: String?,
        kind: C02RemoteHostKeyChallenge.Kind,
        now: Date
    ) -> C02RemoteHostKeyChallenge {
        C02RemoteHostKeyChallenge(
            taskID: taskID,
            hostID: challenge.hostID,
            address: challenge.address,
            port: challenge.port,
            keyType: challenge.keyType,
            fingerprintSHA256: challenge.fingerprintSHA256,
            expectedFingerprintSHA256: expected,
            kind: kind,
            createdAt: now,
            expiresAt: now.addingTimeInterval(
                C02ExecutionTargetWire.hostKeyChallengeLifetime)
        )
    }

    // MARK: One bounded command (probe/shared)

    private func runOnce(
        transport: any SSHSessionTransport,
        command: String,
        timeout: TimeInterval,
        maxOutputBytes: Int,
        cancellation: CancellationToken
    ) async -> C02SSHExecutionResult {
        let started = now()
        let exec: any SSHSessionExec
        do {
            exec = try await transport.openExec(command)
        } catch {
            return C02SSHExecutionResult(
                state: .outcomeUnknown("notStarted"),
                stdout: "", stderr: "",
                stdoutBytes: 0, stderrBytes: 0, truncated: false,
                durationMs: 0, dispatched: false,
                stopProof: .unknownRemoteState,
                receiptPersisted: false, receiptState: nil)
        }
        let collector = C02SSHOutputCollector(limit: maxOutputBytes)
        let race = await Self.raceExec(
            exec: exec, collector: collector,
            timeout: timeout, cancellation: cancellation)
        exec.cancel()
        let snapshot = await collector.snapshot()
        let state: C02SSHExecutionState
        switch race {
        case .exited(let code): state = .exited(code)
        case .deadline: state = .timedOut
        case .cancelled: state = .cancelled
        case .streamEnded: state = .outcomeUnknown("streamEnded")
        case .streamFailed(let reason): state = .outcomeUnknown(reason)
        }
        return C02SSHExecutionResult(
            state: state,
            stdout: snapshot.stdout,
            stderr: snapshot.stderr,
            stdoutBytes: snapshot.stdoutBytes,
            stderrBytes: snapshot.stderrBytes,
            truncated: snapshot.truncated,
            durationMs: max(0, Int(now().timeIntervalSince(started) * 1_000)),
            dispatched: true,
            stopProof: state.isExited ? .remoteExited : .unknownRemoteState,
            receiptPersisted: false,
            receiptState: nil
        )
    }

    private static func raceExec(
        exec: any SSHSessionExec,
        collector: C02SSHOutputCollector,
        timeout: TimeInterval,
        cancellation: CancellationToken
    ) async -> C02SSHExecRace {
        await withTaskGroup(of: C02SSHExecRace.self) { group in
            group.addTask {
                do {
                    for try await event in exec.events {
                        switch event {
                        case .stdout(let data):
                            await collector.append(.stdout, data)
                        case .stderr(let data):
                            await collector.append(.stderr, data)
                        case .exited(let code):
                            return .exited(code)
                        }
                    }
                    return .streamEnded
                } catch {
                    return .streamFailed(
                        String(SecretRedactor.redact(error.localizedDescription).prefix(160)))
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(max(0.05, timeout)))
                return .deadline
            }
            if !cancellation.isCancelled {
                group.addTask {
                    while !Task.isCancelled && !cancellation.isCancelled {
                        try? await Task.sleep(for: .milliseconds(25))
                    }
                    guard !Task.isCancelled else { return .streamEnded }
                    return .cancelled
                }
            }
            let first = await group.next() ?? .streamEnded
            group.cancelAll()
            return first
        }
    }
}

private final class C02HostKeyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: HostKeyChallenge?
    func record(_ challenge: HostKeyChallenge) {
        lock.lock(); value = challenge; lock.unlock()
    }
    func read() -> HostKeyChallenge? {
        lock.lock(); defer { lock.unlock() }; return value
    }
}

private extension C02SSHExecutionState {
    var isExited: Bool {
        if case .exited = self { return true }
        return false
    }
}
