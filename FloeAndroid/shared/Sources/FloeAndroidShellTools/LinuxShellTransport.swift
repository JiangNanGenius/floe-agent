// FloeAndroidShellTools — typed Android Linux-engine shell transport seam.
//
// Android-owned (job-1bd4fcce5eca4856). This is the ONLY surface the shell
// backend uses to reach the runtime-UID Linux engine. It is a small typed,
// Sendable, async protocol; the concrete implementation lives in
// FloeAndroidCore (`MailboxLinuxShellTransport` over `LinuxShellMailbox`) and
// the Kotlin host pumps it to the runtime component with the frozen
// `RuntimeWire` v1 exchange (fixed-channel exact-signature Binder). Nothing
// here shells out to a host command, parses `sh` locally, or talks to the
// Binder itself: the backend consumes the injected transport, never raw host
// commands, and model code never sees these types.
//
// Engine reality (RuntimeWire.VERSION1, <=64 KiB standard JSON; the actual
// Kotlin `RuntimeConnection`/`RuntimeKernel` sources are authoritative):
// * Slow controls (`shell.start`, `shell.input`, `shell.resize`) return a
//   transient `{requestID, state:"queued"}` receipt; the HOST pump polls
//   `request.status` -> `completed.result` / `failed.code` before settling a
//   mailbox ticket. `shell.poll` is a direct memory-only snapshot.
//   `shell.cancel` answers `{state:"stop_requested"}` and is only a stop
//   REQUEST until `leaseReleased` with the real terminal.
// * `shell.start` payload strict fields: projectID UUID, runID UUID,
//   conversationID optional UUID, environmentID optional, command <=16 KiB,
//   cwd workspace-relative, env optional object (<=32 entries, key regex
//   [A-Za-z_][A-Za-z0-9_]{0,63}, no PROOT_*/FLOE_* keys, no HOME/TMPDIR
//   override because the authority owns them, no NUL, <=32 KiB total
//   key+value bytes), rows/columns, timeoutSeconds, and the optional
//   platform-owned `stdinDelivery` closed set "pty"|"pipe" (ABSENT means
//   "pty"; a null is never sent; an unknown value refuses the start before
//   the lease is acquired — only the trusted one-shot run adapter may set
//   "pipe"). Returns sessionID (the engine lease id) and environmentID.
// * `shell.poll` payload sessionID, cursor, maxBytes<=16384 returns base64
//   MERGED PTY output, cursor, gapBytes, more, droppedBytes, state,
//   leaseReleased, cancelled, stopReason (fixed service code:
//   "timeout" | "user-stop" | "start-binding-failed" when the terminal was
//   a stop) and exitCode/termSig/waitErrno once terminal. There is NO
//   stdout/stderr split: merged output may legitimately contain both, and
//   the backend keeps stdout and stderr honest (merged bytes reported as
//   output, stderr empty, never a fabricated split). A CANCELLED remote is
//   not an exited process: the stop reason decides the honest outcome and
//   ownership stays until `leaseReleased` proves the real stop.
// * Stdin rides base64 pages <=16 KiB with acceptedBytes/partial results.
//   Delivery has TWO engine descriptor modes chosen only by the platform
//   `stdinDelivery` start field: "pty" (default; interactive input where
//   the canonical-mode Ctrl-D 0x04 byte is the line discipline's EOF, the
//   unchanged legacy path) and "pipe" (one-shot job runs: the child's fd0
//   is a dedicated pipe while stdout/stderr stay on the PTY slave; the
//   ONLY EOF source is the engine closing the write end, commanded by an
//   EMPTY `shell.input` page whose reply carries
//   `stdinEof:"closed"|"closed-idempotent"|"failed"|"rejected"`; a 0x04
//   byte in pipe stdin is ordinary DATA, never an EOF emulation; and EOF
//   is NOT an exit — settlement still requires `leaseReleased` with the
//   real terminal fields).
// * Component selection, paths, leases and native completion are NOT
//   caller/model fields; the engine's runtime-UID authority owns them.
// * Only the EXPLICIT caller `env` map rides this wire (validated against
//   the engine bounds before send, carried unchanged). The Main process
//   environment and any stored credentials are NEVER injected here.
// * Identity strings: owner UUIDs (projectID/runID/conversationID) ride in
//   Swift canonical form (uppercase) UNCHANGED. Normalizing the lowercase
//   transient interface/control UUIDs (RuntimeWire request IDs) is the
//   trusted host adapter's job; owner IDs must never be altered there.
//
// The wire JSON <-> typed mapping is owned by the Core transport; this file
// defines the vocabulary only.

import Foundation
import FloeCore

// MARK: - Typed requests and replies

/// The engine's closed `shell.start` `stdinDelivery` value set
/// (`LinuxRuntimeOperations.start`: absent key defaults to "pty", unknown
/// values refuse the start BEFORE the lease is acquired). Only the trusted
/// platform Swift adapter selects a mode; no model, env or tool string can.
public enum LinuxShellStdinDelivery: String, Sendable, Equatable {
    /// Legacy interactive reality: the child's stdin is the PTY slave;
    /// canonical-mode input, Ctrl-D (0x04) is the line discipline's EOF,
    /// Ctrl-C (0x03) raises SIGINT. Interactive `openSession` stays here
    /// (the request field is nil so the wire key is OMITTED entirely).
    case pty
    /// Descriptor-level one-shot pipe: the child's fd0 is a dedicated pipe
    /// read end while stdout/stderr remain on the PTY slave. The only EOF
    /// source is the engine-side close of the write end, commanded by one
    /// empty `shell.input` page (`stdinEof` reply). A 0x04 byte is ordinary
    /// stdin data here — never an EOF emulation. EOF is not an exit and
    /// never releases the lease.
    case pipe
}

public struct LinuxShellStartRequest: Sendable, Equatable {
    /// Stable project identity derived from the TRUSTED canonical ORIGINAL
    /// Core workspace root (see `LinuxShellProjectMapping`). Not random,
    /// never "first project", never a temp fallback.
    public var projectID: UUID
    /// The original runtime-issued run identity, carried unchanged.
    public var runID: UUID
    /// The runtime-issued conversation identity from the trusted
    /// ToolContext, carried unchanged (optional on the engine wire; nil
    /// stays absent — never guessed from session text).
    public var conversationID: UUID?
    /// The resolved environment identity from the original lease/context,
    /// carried unchanged (optional; nil lets the engine authority resolve).
    public var environmentID: String?
    public var command: String
    /// Workspace-relative cwd ("." = workspace root), validated upstream.
    public var cwd: String
    /// Explicit per-run caller environment, carried UNCHANGED through the
    /// typed request/mailbox when the engine bounds allow it (<=32 entries,
    /// engine key shape, no PROOT_*/FLOE_* keys, no HOME/TMPDIR override —
    /// the authority owns them — no NUL, <=32 KiB combined bytes). The
    /// backend validates these bounds and fails closed on a breach instead
    /// of silently dropping entries; the Main process environment and any
    /// stored credentials never ride here.
    public var environment: [String: String]
    public var rows: Int
    public var columns: Int
    public var timeoutSeconds: Double
    public var hostToolCallID: String?
    /// Engine stdin delivery mode for this start. nil OMITS the wire key so
    /// the engine defaults to the legacy "pty" input path — interactive
    /// `openSession` MUST stay nil. Only the trusted platform one-shot run
    /// adapter sets `.pipe`; it is never model-, env- or string-selected.
    public var stdinDelivery: LinuxShellStdinDelivery?

    public init(projectID: UUID, runID: UUID, conversationID: UUID?,
                environmentID: String?, command: String, cwd: String,
                environment: [String: String] = [:],
                rows: Int, columns: Int, timeoutSeconds: Double, hostToolCallID: String? = nil,
                stdinDelivery: LinuxShellStdinDelivery? = nil) {
        self.projectID = projectID
        self.runID = runID
        self.conversationID = conversationID
        self.environmentID = environmentID
        self.command = command
        self.cwd = cwd
        self.environment = environment
        self.rows = rows
        self.columns = columns
        self.timeoutSeconds = timeoutSeconds
        self.hostToolCallID = hostToolCallID
        self.stdinDelivery = stdinDelivery
    }

    /// The engine's own `shell.start` env bounds (authoritative source:
    /// runtimeapp/LinuxRuntimeOperations.kt `start`). A breach is refused
    /// locally (fail closed), never silently truncated or dropped.
    public static let maximumEnvironmentEntries = 32
    public static let maximumEnvironmentBytes = 32_768

    /// Returns nil when the map is sendable, otherwise the first refusal.
    public static func environmentRefusal(_ env: [String: String]) -> String? {
        if env.count > maximumEnvironmentEntries {
            return "env exceeds the engine's \(maximumEnvironmentEntries)-entry bound"
        }
        var bytes = 0
        for (key, value) in env {
            if key.range(of: "^[A-Za-z_][A-Za-z0-9_]{0,63}$", options: .regularExpression) == nil {
                return "env key violates the engine key shape"
            }
            if key.hasPrefix("PROOT_") || key.hasPrefix("FLOE_") {
                return "env key '\(key)' is reserved by the runtime authority"
            }
            if key == "HOME" || key == "TMPDIR" {
                return "env key '\(key)' is owned by the runtime authority"
            }
            if key.contains("\0") || value.contains("\0") {
                return "env contains NUL"
            }
            bytes += key.utf8.count + value.utf8.count
            if bytes > maximumEnvironmentBytes {
                return "env exceeds the engine's 32 KiB combined bound"
            }
        }
        return nil
    }
}

public struct LinuxShellStartReply: Sendable, Equatable {
    /// The engine session identity == the runtime lease id.
    public var sessionID: String
    public var environmentID: String
    public init(sessionID: String, environmentID: String) {
        self.sessionID = sessionID
        self.environmentID = environmentID
    }
}

public struct LinuxShellPollRequest: Sendable, Equatable {
    public var sessionID: String
    public var cursor: UInt64
    /// Engine ceiling 16384 bytes (base64 page <= 64 KiB wire).
    public var maxBytes: Int

    public init(sessionID: String, cursor: UInt64, maxBytes: Int) {
        self.sessionID = sessionID
        self.cursor = cursor
        self.maxBytes = maxBytes
    }
}

/// Engine PTY lifecycle states (`JobState.name.lowercase()` plus the
/// transport-side `lease_retained` truth published by poll).
public enum LinuxShellSessionState: Sendable, Equatable {
    case running
    case cancelling
    /// The root reap or whole-UID census could not be proven: the lease is
    /// NOT releasable. Never treated as stopped.
    case leaseRetained
    /// Whole-UID quiescence proven; the terminal was delivered exactly once.
    case terminated
    /// A state string the transport does not recognize: preserved raw and
    /// handled as "not terminal" (fail closed, never invented).
    case unknown(raw: String)

    public init(raw: String) {
        switch raw {
        case "running": self = .running
        case "cancelling": self = .cancelling
        case "lease_retained": self = .leaseRetained
        case "terminated": self = .terminated
        default: self = .unknown(raw: raw)
        }
    }

    public var isTerminalQuiescent: Bool { self == .terminated }
}

public struct LinuxShellPollReply: Sendable, Equatable {
    public var sessionID: String
    /// MERGED PTY output bytes for this cursor window (stdout and stderr
    /// are NOT split by the engine; honest empty stderr stays empty).
    public var mergedOutput: Data
    public var cursor: UInt64
    /// Bytes skipped because the caller's cursor lagged the engine ring.
    public var gapBytes: Int
    public var more: Bool
    /// Cumulative bytes the engine ring had to drop (unread overflow).
    public var droppedBytes: Int
    public var state: LinuxShellSessionState
    public var leaseReleased: Bool
    /// Engine truth: the terminal came from a proven STOP (Cancelled
    /// terminal), not from the process exiting on its own. A stopped
    /// remote is NOT an exited process.
    public var cancelled: Bool
    /// Fixed engine service code for a cancelled terminal
    /// ("timeout" | "user-stop" | "start-binding-failed" today; unknown
    /// codes ride through unchanged and are never invented).
    public var stopReason: String?
    /// Real engine terminal fields, present ONLY when the engine has
    /// actually reaped the root child. EOF is never an exit (no fabricated
    /// values).
    public var exitCode: Int32?
    public var termSig: Int32?
    public var waitErrno: Int32?
    /// File exchange settles separately from process/lease termination.
    public var workspaceStatus: String?
    public var workspaceRecoveryRef: String?

    public init(sessionID: String, mergedOutput: Data, cursor: UInt64,
                gapBytes: Int, more: Bool, droppedBytes: Int,
                state: LinuxShellSessionState, leaseReleased: Bool,
                cancelled: Bool = false, stopReason: String? = nil,
                exitCode: Int32? = nil, termSig: Int32? = nil, waitErrno: Int32? = nil,
                workspaceStatus: String? = nil, workspaceRecoveryRef: String? = nil) {
        self.sessionID = sessionID
        self.mergedOutput = mergedOutput
        self.cursor = cursor
        self.gapBytes = gapBytes
        self.more = more
        self.droppedBytes = droppedBytes
        self.state = state
        self.leaseReleased = leaseReleased
        self.cancelled = cancelled
        self.stopReason = stopReason
        self.exitCode = exitCode
        self.termSig = termSig
        self.waitErrno = waitErrno
        self.workspaceStatus = workspaceStatus
        self.workspaceRecoveryRef = workspaceRecoveryRef
    }
}

public struct LinuxShellInputRequest: Sendable, Equatable {
    public var sessionID: String
    /// One stdin chunk; the transport splits larger writes into <=16384-byte
    /// base64 engine pages.
    public var bytes: Data
    public init(sessionID: String, bytes: Data) {
        self.sessionID = sessionID
        self.bytes = bytes
    }
}

public struct LinuxShellInputReply: Sendable, Equatable {
    public var acceptedBytes: Int
    /// Engine ring/watermark backpressure: partial acceptance, retry later.
    /// Never applies to the EOF command page (zero bytes are not data).
    public var partial: Bool
    /// Non-zero when the engine's stdin write failed (StdinWrite.Failed), or
    /// the close failed on an EOF command (`stdinEof == "failed"`);
    /// `acceptedBytes` keeps what was already written. Never a silent success.
    public var errnoCode: Int32?
    /// Additive engine EOF state carried ONLY by the reply to an EMPTY
    /// `shell.input` page on a one-shot pipe session
    /// (`LinuxRuntimeOperations.input`): "closed" | "closed-idempotent" |
    /// "failed" | "rejected". nil on data pages and on replies from a
    /// transport that has not decoded the field (unknown-key tolerance
    /// stays; the value is never invented).
    public var stdinEof: String?
    /// The engine's bounded rejection reason when `stdinEof == "rejected"`
    /// (additive `reason` key on the same reply, e.g. the job already left
    /// RUNNING and the lifecycle owns the write end). nil otherwise.
    public var stdinEofReason: String?

    public init(acceptedBytes: Int, partial: Bool = false, errnoCode: Int32? = nil,
                stdinEof: String? = nil, stdinEofReason: String? = nil) {
        self.acceptedBytes = acceptedBytes
        self.partial = partial
        self.errnoCode = errnoCode
        self.stdinEof = stdinEof
        self.stdinEofReason = stdinEofReason
    }
}

public struct LinuxShellResizeRequest: Sendable, Equatable {
    public var sessionID: String
    public var rows: Int
    public var columns: Int
    public init(sessionID: String, rows: Int, columns: Int) {
        self.sessionID = sessionID
        self.rows = rows
        self.columns = columns
    }
}

public struct LinuxShellResizeReply: Sendable, Equatable {
    public var resized: Bool
    public init(resized: Bool) { self.resized = resized }
}

public struct LinuxShellCancelRequest: Sendable, Equatable {
    /// EXACT engine session id. The engine refuses a stale cancellation
    /// from stopping another workload.
    public var sessionID: String
    public init(sessionID: String) { self.sessionID = sessionID }
}

public struct LinuxShellCancelReply: Sendable, Equatable {
    /// "stop_requested" — only a REQUEST. The caller keeps ownership until
    /// a poll proves `leaseReleased` with the real terminal (EOF != exit).
    public var state: String
    public init(state: String) { self.state = state }
}

// MARK: - Typed transport errors

/// Honest fail-closed transport refusals. No case ever means "assume it ran":
/// the backend maps these to `ShellRunOutcome.failed` / typed throws and the
/// original policy/journal path records them.
public enum LinuxShellTransportError: Error, Equatable, Sendable {
    /// No accepted host epoch / the mailbox is not bound: the engine
    /// transport was never configured. (Default state.)
    case notBound
    /// Mailbox bounds exceeded (queued live tickets): back-pressure, the
    /// request definitely did not reach the engine.
    case saturated
    /// The typed request could not fit the frozen 64 KiB wire bound.
    case payloadTooLarge
    /// The engine settled the request failed with this bounded code
    /// (for example "operation_failed"); the engine never reflects command
    /// lines, paths or output into codes.
    case remoteFailed(code: String)
    /// The reply frame could not be decoded: ownership reconciliation rules
    /// apply (the backend must not assume a stop or an exit).
    case replyMalformed
    /// The mailbox generation was replaced/fenced (Binder death, runtime
    /// stop): work is NOT replayed and running leases stay unreconciled.
    case hostFenced
    /// The bounded local wait budget expired. A QUEUED request provably
    /// never reached the host; a CLAIMED request may still run remotely —
    /// the caller must retain ownership for reconciliation and never treat
    /// this as a stop, an exit, or a not-started.
    case waitBudgetExpired
}

// MARK: - Transport seam

/// Small typed async transport the Android shell backend consumes. The Core
/// mailbox implements it; tests inject deterministic fakes. Model code and
/// raw host commands can never reach an engine through this seam.
public protocol LinuxShellTransport: Sendable {
    func shellStart(_ request: LinuxShellStartRequest) async throws -> LinuxShellStartReply
    func shellPoll(_ request: LinuxShellPollRequest) async throws -> LinuxShellPollReply
    func shellInput(_ request: LinuxShellInputRequest) async throws -> LinuxShellInputReply
    func shellResize(_ request: LinuxShellResizeRequest) async throws -> LinuxShellResizeReply
    func shellCancel(_ request: LinuxShellCancelRequest) async throws -> LinuxShellCancelReply
}

// MARK: - Readiness (explicit injected qualification; default fail closed)

/// The ACTUAL capability answer for running Linux shell work on this
/// device: dedicated runtime UID + bound engine transport + qualified
/// rootfs + qualified Core->engine workspace mapping + lease authority.
/// "installed" or "connected" alone is NEVER sufficient, and a temporary
/// chat never forces this true.
public protocol LinuxShellReadiness: Sendable {
    var isQualifiedForLinuxShell: Bool { get }
    /// Honest preparation/selection guidance surfaced when unqualified
    /// (the description's promise: a missing or non-Linux environment
    /// fails with guidance and never falls back to a host interpreter).
    var refusalGuidance: String { get }
}

/// The compiled default: unconfigured/not-qualified fail closed.
public struct UnqualifiedLinuxShellReadiness: LinuxShellReadiness {
    public init() {}
    public var isQualifiedForLinuxShell: Bool { false }
    public var refusalGuidance: String {
        "status=engineUnqualified reason=linuxShellNotQualified\nThe Linux engine workspace/lease capability is not qualified on this device yet. Nothing was executed and no host interpreter was used; open the runtime setup and complete installation/qualification, then retry."
    }
}

// MARK: - Stable project mapping (no new mapping DB)

/// Explicit stable project mapping for the engine `shell.start` payload:
/// the UUID is derived from SHA256 of the TRUSTED canonical ORIGINAL Core
/// workspace root path. Deterministic, never random, never "first project",
/// never a temp fallback; nothing is stored in a mapping DB.
public enum LinuxShellProjectMapping {
    public static func projectID(forCanonicalCoreWorkspaceRoot rootURL: URL) -> UUID {
        let canonical = rootURL.resolvingSymlinksInPath().standardizedFileURL
        let hex = FloeDigest.sha256Hex(Data(canonical.path.utf8))
        return uuid(fromHexPrefix: hex)
    }

    /// The 9P/workspace SHARE is a Main integration concern: the engine
    /// workspace is physically distinct from the Core workspace and files
    /// are only visible after real import/export mapping/sync (readiness).
    private static func uuid(fromHexPrefix hex: String) -> UUID {
        let digits = Array(hex.prefix(32))
        func group(_ start: Int, _ count: Int) -> UInt32 {
            var value: UInt32 = 0
            for character in digits[start..<min(start + count, digits.count)] {
                value = value &<< 4
                if let nibble = character.hexDigitValue { value |= UInt32(nibble) }
            }
            return value
        }
        // G03-native-integration compile repair 1: uuid_t requires SIXTEEN
        // UInt8 elements. The previous 11-tuple both failed to typecheck and
        // silently truncated the first three groups (24+16+16 bits lost).
        // Every hex digit of the 32-digit SHA256 prefix now maps to exactly
        // one UUID byte, in order, preserving the documented determinism.
        return UUID(uuid: (
            UInt8(truncatingIfNeeded: group(0, 2)), UInt8(truncatingIfNeeded: group(2, 2)),
            UInt8(truncatingIfNeeded: group(4, 2)), UInt8(truncatingIfNeeded: group(6, 2)),
            UInt8(truncatingIfNeeded: group(8, 2)), UInt8(truncatingIfNeeded: group(10, 2)),
            UInt8(truncatingIfNeeded: group(12, 2)), UInt8(truncatingIfNeeded: group(14, 2)),
            UInt8(truncatingIfNeeded: group(16, 2)), UInt8(truncatingIfNeeded: group(18, 2)),
            UInt8(truncatingIfNeeded: group(20, 2)), UInt8(truncatingIfNeeded: group(22, 2)),
            UInt8(truncatingIfNeeded: group(24, 2)), UInt8(truncatingIfNeeded: group(26, 2)),
            UInt8(truncatingIfNeeded: group(28, 2)), UInt8(truncatingIfNeeded: group(30, 2))
        ))
    }
}

