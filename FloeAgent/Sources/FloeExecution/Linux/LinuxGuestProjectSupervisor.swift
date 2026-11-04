// FloeExecution — typed host client for the resident Linux project supervisor
// (protocol 4, control console).
//
// The ARM64 guest runs one trusted supervisor (floe-supervisord, started by
// init) on the control console (/dev/hvc0). It owns project lifecycle:
// per-project overlay rootfs, cgroup trees, private project mount views and
// one UNMODIFIED protocol-3 floe-exec runner per project on its own virtio
// console. The control console speaks the versioned protocol-4 frames from
// `floe_project_supervisor.h`:
//
//   host -> guest: HELLO / PROJOPEN(+CHUNK,RUN) / PROJCLOSE / PROJDROP /
//                  PROJSTAT / TASKKILL / LEASE / PING
//   guest -> host: CAPS / BEGIN / OUT / ERR / END / (BEGIN+ERR+END failure) /
//                  EVENT <project> <generation> <kind> <detail>
//
// This file is the typed host half. It deliberately reuses
// `LinuxGuestCommandChannel` for everything wire-shaped: the single console
// reader, the 0x1e frame router, per-token demux streams, the serialized
// writer, the base64 CHUNK/RUN codec, the u32 field-table payload codec, the
// ControlParser and every existing bound/cancellation rule. It adds NO second
// framer and NO second execution tool; the project data channels keep using
// the same channel class in its ordinary protocol-3 role, byte-stable.
//
// Contract highlights enforced here (mirroring the guest):
//   * projectID/taskID/generation are validated immutable wrappers; the
//     grammar is exactly floe_project_id_valid / floe_task_id_valid /
//     floe_generation_valid, so an input can never inject a frame terminator
//     or a path component.
//   * PROJOPEN roots are caller-supplied, already-authorized absolute
//     printable-ASCII paths (<=255 bytes, the guest struct bound). No
//     credential ever rides a frame; the guest re-validates baseRootfs by
//     equality against its init-owned root.
//   * exit 3/125/126/127 are explicit typed errors, never success.
//   * the open console index is returned only after a positive END 0 ack,
//     and only when the ack's project/generation match the request.
//   * capacity (projects/tasks/sessions) and net readiness come from the
//     guest CAPS answer, never from host constants.
//   * cancelling one control waiter fails only that waiter's token stream;
//     no raw interrupt-all and no cross-project signal is ever sent. A
//     PROJOPEN whose outcome is not learned (cancel/timeout/console loss) is
//     reported as `openOutcomeUncertain` — the project may exist; reconcile
//     with status()/drop() before reopening.
//   * EVENT delivery is fenced by the channel router generation captured at
//     install/reconnect: notices from an older boot are dropped, and channel
//     close/reboot finishes pending callers' streams.
//
// Source-only lane: compile/integration acceptance lives with the primary
// owner (unified Swift 6 build + FloeExecutionTests + real guest).

import Foundation
import FloeCore
import FloeTools

// MARK: - Validated identity

/// Validated project label. Grammar is exactly the guest's
/// `floe_project_id_valid`: first byte [A-Za-z0-9], then up to 63 more of
/// [A-Za-z0-9._-], the substring ".." always rejected, printable ASCII only.
/// Because the alphabet excludes 0x1e/newline/space, a validated ID can never
/// inject a frame terminator; the guest builds real paths only after the
/// same validation.
public struct LinuxGuestProjectID: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let maximumUTF8Bytes = 64

    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard Self.isValid(rawValue) else {
            throw LinuxGuestProjectSupervisorError.invalidIdentity(
                field: "projectID",
                detail: "must be 1...\(Self.maximumUTF8Bytes) bytes: [A-Za-z0-9] first, then [A-Za-z0-9._-]; '..' is always rejected"
            )
        }
        self.rawValue = rawValue
    }

    /// Byte-exact mirror of the guest validator (a label, never a path).
    public static func isValid(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= maximumUTF8Bytes else { return false }
        for (index, byte) in bytes.enumerated() {
            let alphanumeric = (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A)
                || (byte >= 0x30 && byte <= 0x39)
            if alphanumeric { continue }
            if index > 0 && (byte == 0x2E || byte == 0x5F || byte == 0x2D) { continue }
            return false
        }
        // ".." is the one dangerous label pattern even inside a validated
        // directory: reject it outright (same rule as the guest).
        return !value.contains("..")
    }

    public var description: String { rawValue }
    public var debugDescription: String { rawValue }
}

/// Validated task label for TASKKILL. Same grammar as the projectID with the
/// runner-token width; mirrors `floe_task_id_valid`.
public struct LinuxGuestProjectTaskID: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let maximumUTF8Bytes = 96

    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard Self.isValid(rawValue) else {
            throw LinuxGuestProjectSupervisorError.invalidIdentity(
                field: "taskID",
                detail: "must be 1...\(Self.maximumUTF8Bytes) bytes: [A-Za-z0-9] first, then [A-Za-z0-9._-]; '..' is always rejected"
            )
        }
        self.rawValue = rawValue
    }

    public static func isValid(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= maximumUTF8Bytes else { return false }
        for (index, byte) in bytes.enumerated() {
            let alphanumeric = (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A)
                || (byte >= 0x30 && byte <= 0x39)
            if alphanumeric { continue }
            if index > 0 && (byte == 0x2E || byte == 0x5F || byte == 0x2D) { continue }
            return false
        }
        return !value.contains("..")
    }

    public var description: String { rawValue }
    public var debugDescription: String { rawValue }
}

/// Project generation: strict decimal u64 text (1...20 digits, no sign, no
/// space). "0" is a real generation. The guest `floe_generation_valid` is a
/// digit/width-only grammar (any 1...24-digit decimal, a superset of u64);
/// the host is deliberately stricter and only represents u64 values because
/// the host mints generations — verified against the guest validators by
/// qualification/identity_cross_check.py.
public struct LinuxGuestProjectGeneration: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    /// Guest FLOE_MAX_GENERATION bound; the host limits further to u64 text.
    public static let maximumUTF8Bytes = 20

    public let rawValue: String
    public let value: UInt64

    public init(_ rawValue: String) throws {
        let bytes = Array(rawValue.utf8)
        guard !bytes.isEmpty,
              bytes.count <= Self.maximumUTF8Bytes,
              bytes.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
              let value = UInt64(rawValue) else {
            throw LinuxGuestProjectSupervisorError.invalidIdentity(
                field: "generation",
                detail: "must be 1...20 decimal digits (a u64 text form); '0' is accepted, signs and spaces are not"
            )
        }
        self.rawValue = rawValue
        self.value = value
    }

    public var description: String { rawValue }
    public var debugDescription: String { rawValue }
}

/// A host-reserved native share slot and its authorized in-project directory.
/// Slot N always owns tag floe-ws-N and data console hvc(N+1).
public struct LinuxGuestProjectWorkspaceMount: Sendable, Equatable {
    public let directory: String
    public let shareSlot: Int
    public let environmentShare: Bool
    public let cacheShare: Bool

    public init(directory: String, shareSlot: Int, environmentShare: Bool = false, cacheShare: Bool = false) throws {
        try LinuxGuestProjectSupervisor.validateRoot(directory, field: "workspaceDir", allowEmpty: true)
        guard (0..<8).contains(shareSlot) else {
            throw LinuxGuestProjectSupervisorError.invalidIdentity(
                field: "shareSlot", detail: "must name a reserved native slot in 0...7")
        }
        self.directory = directory
        self.shareSlot = shareSlot
        self.environmentShare = environmentShare
        self.cacheShare = cacheShare
    }

    func payloadFields(baseRootfs: String) -> [String] {
        let fields = [baseRootfs, directory, String(shareSlot)]
        return environmentShare || cacheShare
            ? fields + [environmentShare ? "1" : "0", cacheShare ? "1" : "0"] : fields
    }
}

// MARK: - Errors

/// Typed error vocabulary for the supervisor control channel. Exit codes
/// reuse the runner vocabulary and are never mapped to success:
/// 3 unknown projectID/generation/taskID, 125 table full / malformed
/// identity / malformed payload, 126 setup failure (mount/chroot/cgroup),
/// 127 refused (already open, lease held, drop while open, liveness record,
/// base rootfs mismatch).
public enum LinuxGuestProjectSupervisorError: Error, LocalizedError, Sendable, Equatable {
    case invalidIdentity(field: String, detail: String)
    case invalidRoot(field: String, detail: String)
    /// The console did not answer HELLO/CAPS, or the CAPS answer is not
    /// protocol 4 (this is a data-channel runner or an old supervisor).
    case supervisorUnavailable(foundCapabilities: String?)
    /// The guest answered positively but the bounded text cannot be parsed.
    case malformedResponse(exchange: String, detail: String)
    /// A positive ack named a different project/generation than requested;
    /// the newer connection is never mutated by a stale response.
    case responseIdentityMismatch(exchange: String, expectedProject: String, expectedGeneration: String, found: String)
    case unknownProject(projectID: String, generation: String)
    case tableFull(detail: String)
    case setupFailed(detail: String)
    case refused(detail: String)
    case unexpectedExit(exchange: String, code: Int32, detail: String)
    /// PROJOPEN was cancelled, timed out, or the console died before the
    /// guest acked: the project may or may not exist. Reconcile with
    /// status()/drop() before reopening; never claim "uncreated".
    case openOutcomeUncertain(projectID: String, generation: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .invalidIdentity(let field, let detail):
            return "Invalid supervisor \(field): \(detail)"
        case .invalidRoot(let field, let detail):
            return "Invalid supervisor \(field): \(detail)"
        case .supervisorUnavailable(let found):
            let detail = found.map { " (guest reported: \($0))" } ?? " (the guest did not answer capability negotiation)"
            return "This Linux guest console does not speak supervisor protocol 4\(detail). Use the control console (/dev/hvc0) of a guest image with floe-supervisord."
        case .malformedResponse(let exchange, let detail):
            return "The supervisor \(exchange) answer could not be parsed: \(detail)"
        case .responseIdentityMismatch(let exchange, let expectedProject, let expectedGeneration, let found):
            return "The supervisor \(exchange) answer named '\(found)' but the request was \(expectedProject) generation \(expectedGeneration); the response was discarded"
        case .unknownProject(let projectID, let generation):
            return "The supervisor does not know project \(projectID) at generation \(generation)"
        case .tableFull(let detail):
            return "The supervisor project table is full or the request was malformed: \(detail)"
        case .setupFailed(let detail):
            return "The supervisor could not set up the project (mount/chroot/cgroup/roots): \(detail)"
        case .refused(let detail):
            return "The supervisor refused the request: \(detail)"
        case .unexpectedExit(let exchange, let code, let detail):
            return "The supervisor \(exchange) exchange ended with unexpected exit \(code): \(detail)"
        case .openOutcomeUncertain(let projectID, let generation, let reason):
            return "PROJOPEN for \(projectID) generation \(generation) did not reach a definite outcome (\(reason)). The project may exist; run PROJSTAT and PROJDROP to reconcile before reopening."
        }
    }
}

// MARK: - Structured results

/// Supervisor capability answer (protocol 4). Every field is a guest
/// returned value from CAPS — the host never fabricates capacity or net
/// readiness, and derives its project ceiling from `maximumProjects`.
public struct LinuxGuestProjectSupervisorCapabilities: Sendable, Equatable {
    /// Guest build constants from `floe_project_supervisor.h`; the
    /// authoritative runtime capacity is the CAPS-parsed value.
    public static let guestMaximumProjects = 8
    public static let guestMaximumProjectTasks = 8
    public static let guestMaximumProjectSessions = 4

    public let runner: String
    public let protocolVersion: Int
    public let maximumProjects: Int
    public let maximumProjectTasks: Int
    public let maximumProjectSessions: Int
    public let baseRootfs: String
    public let stateRoot: String
    public let network: NetworkState

    public enum NetworkState: String, Sendable, Equatable {
        case up
        case partial
        case down
    }
}

/// Positive PROJOPEN ack (END 0). `consoleIndex` exists only after the
/// supervisor reported the project active with its allocated console.
public struct LinuxGuestProjectOpenResult: Sendable, Equatable {
    public let projectID: LinuxGuestProjectID
    public let generation: LinuxGuestProjectGeneration
    /// The supervisor-allocated virtio console (hvcN) for the project's
    /// data channel.
    public let consoleIndex: Int
    public let root: String
    public var shareSlot: Int { consoleIndex - 1 }
    public let workspace: String
}

public enum LinuxGuestProjectState: String, Sendable, Equatable {
    case active
    case opening
    case closing
    case recovered
}

/// One PROJSTAT row.
public struct LinuxGuestProjectRecord: Sendable, Equatable {
    public let projectID: LinuxGuestProjectID
    public let generation: LinuxGuestProjectGeneration
    public let state: LinuxGuestProjectState
    public let consoleIndex: Int
    public let runnerPID: Int
    public let leaseHeld: Bool
}

/// One asynchronous EVENT notice. EVENT never carries command output; the
/// host treats it like FAILED for liveness decisions.
public struct LinuxGuestProjectEvent: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case runnerDied = "runner-died"
        case taskUnreaped = "task-unreaped"
        case leaseExpired = "lease-expired"
        case recovered
        case closed
    }

    public let projectID: LinuxGuestProjectID
    public let generation: LinuxGuestProjectGeneration
    public let kind: Kind
    /// "-" from the guest means "no detail"; stored as an empty string.
    public let detail: String

    /// Router-side parse of one EVENT frame argument string
    /// `<projectID> <generation> <kind> <detail...>`. Malformed identities
    /// and unknown kinds are dropped (the pump counts them); a missing
    /// detail is tolerated ("-").
    static func parse(_ arguments: String) -> LinuxGuestProjectEvent? {
        let parts = arguments.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        let projectText = String(parts[0])
        let generationText = String(parts[1])
        let kindText = String(parts[2])
        guard LinuxGuestProjectID.isValid(projectText),
              let generation = try? LinuxGuestProjectGeneration(generationText),
              let kind = Kind(rawValue: kindText) else {
            return nil
        }
        let detail = parts.count > 3 ? String(parts[3]) : ""
        return LinuxGuestProjectEvent(
            projectID: try! LinuxGuestProjectID(projectText),
            generation: generation,
            kind: kind,
            detail: detail == "-" ? "" : detail
        )
    }
}

// MARK: - Control exchange outcome

/// The bounded result of one control exchange. Nonzero exits are returned,
/// not thrown: each typed call maps them (3 means different things for
/// TASKKILL vs PROJCLOSE). Throws are reserved for transport failure,
/// cancellation/timeout and framing errors.
struct LinuxGuestSupervisorControlOutcome: Sendable, Equatable {
    var exit: Int32
    /// Bounded guest text (PROJSTAT rows, failure reasons); the existing
    /// ControlParser cap applies (64 KiB).
    var text: String
    var capabilities: String?
}

// MARK: - Channel extension (same-module, reuses the single reader/writer)

extension LinuxGuestCommandChannel {
    /// One typed supervisor control exchange on its own token. Identical
    /// discipline to the production SPAWN/KILL/ALIVE control path: the
    /// exchange consumes only its own token's demux stream, the writer is
    /// the channel-wide serialized send, and a timeout/cancellation fails
    /// ONLY this token's stream — no raw interrupt-all, no other project is
    /// ever signaled. Chunked payloads use the existing base64 CHUNK/RUN
    /// codec and the guest's envelope bound.
    func supervisorControlExchange(
        name: String,
        arguments: [String] = [],
        payload: Data? = nil,
        payloadHeaderExtraArguments: [String] = [],
        timeout: TimeInterval,
        cancellation: CancellationToken?
    ) async throws -> LinuxGuestSupervisorControlOutcome {
        try Task.checkCancellation()
        if cancellation?.isCancelled == true { throw FloeError.cancelled }
        guard !isPoisoned else {
            throw LinuxGuestError.consoleUnavailable(
                "the guest channel was poisoned by an earlier command whose outcome is unknown; reset the guest before issuing supervisor control frames"
            )
        }
        guard !closed else {
            throw LinuxGuestError.consoleUnavailable("the guest channel is closed")
        }
        try await ensureNegotiated()
        guard let capabilityPayload = negotiatedRunnerCapabilityPayload,
              let capabilities = LinuxGuestProjectSupervisor.parseCapabilities(capabilityPayload),
              capabilities.protocolVersion == LinuxGuestProjectSupervisor.requiredProtocol else {
            throw LinuxGuestProjectSupervisorError.supervisorUnavailable(
                foundCapabilities: negotiatedRunnerCapabilityPayload
            )
        }
        try Task.checkCancellation()
        if cancellation?.isCancelled == true { throw FloeError.cancelled }
        let token = "sup-" + UUID().uuidString
        let tokenStream = LinuxGuestTokenStream()
        // Fail-closed duplicate contract identical to run()/performControl:
        // the throw lands before the defer, so a refused registration never
        // unregisters the active token it collided with.
        try registerToken(token, stream: tokenStream)
        defer { unregisterToken(token) }

        let frames: [Data]
        if let payload {
            frames = LinuxGuestFraming.payloadHeader(
                name, token: token, payload: payload, extraArguments: payloadHeaderExtraArguments
            )
        } else {
            frames = [LinuxGuestFraming.controlLine(name, token: token, arguments: arguments)]
        }

        // Deadline and cooperative cancellation fail only this waiter's
        // stream (control tokens own no process group; interrupt is never
        // sent). Buffered chunks still win over the failure, matching the
        // token-stream contract.
        let timeoutTask = Task {
            try? await Task.sleep(for: .milliseconds(Int64(max(0.001, timeout) * 1000)))
            guard !Task.isCancelled else { return }
            await tokenStream.fail(LinuxGuestError.timedOut(seconds: timeout))
        }
        defer { timeoutTask.cancel() }

        let cancellationTask = Task {
            while !Task.isCancelled {
                if cancellation?.isCancelled == true {
                    await tokenStream.fail(FloeError.cancelled)
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { cancellationTask.cancel() }

        try await send(frames)

        var parser = LinuxGuestFraming.ControlParser(token: token)
        while true {
            guard let chunk = await tokenStream.next() else {
                if let failure = await tokenStream.takeFailure() {
                    throw failure
                }
                throw LinuxGuestError.consoleUnavailable(
                    "guest console closed before the \(name) exchange completed"
                )
            }
            switch parser.feed(chunk) {
            case .needMore:
                continue
            case .finished(let exit):
                return LinuxGuestSupervisorControlOutcome(
                    exit: exit, text: parser.textString, capabilities: parser.capabilities
                )
            }
        }
    }
}

// MARK: - Event pump (generation fence)

/// Delivers EVENT notices to the client's stream. The router generation the
/// observer was installed under is the fence: notices from an older boot
/// (before reconnect()) are dropped and counted, never delivered into a
/// newer connection. Malformed notices are dropped and counted too.
/// Internal (not private) so the focused regressions can drive the fence
/// directly; production callers use `LinuxGuestProjectSupervisor.events()`.
actor LinuxGuestSupervisorEventPump {
    private var continuation: AsyncStream<LinuxGuestProjectEvent>.Continuation?
    private var expectedGeneration: UInt64
    private(set) var droppedEventCount = 0

    init(expectedGeneration: UInt64) {
        self.expectedGeneration = expectedGeneration
    }

    func install(_ continuation: AsyncStream<LinuxGuestProjectEvent>.Continuation) {
        self.continuation?.finish()
        self.continuation = continuation
    }

    func setExpectedGeneration(_ generation: UInt64) {
        expectedGeneration = generation
    }

    func onEvent(arguments: String, generation: UInt64) {
        guard generation == expectedGeneration else {
            droppedEventCount += 1
            return
        }
        guard let event = LinuxGuestProjectEvent.parse(arguments) else {
            droppedEventCount += 1
            return
        }
        guard let continuation else { droppedEventCount += 1; return }
        switch continuation.yield(event) {
        case .enqueued(_): break
        case .dropped(_), .terminated: droppedEventCount += 1
        @unknown default: droppedEventCount += 1
        }
    }

    func finish() {
        continuation?.finish()
        continuation = nil
    }
}

// MARK: - Supervisor client

/// Typed host client for one supervisor control console. It owns exactly
/// one `LinuxGuestCommandChannel`; the channel's single router task owns the
/// transport reader, so project data channels (protocol 3, one per project)
/// stay separate consoles/channels.
public actor LinuxGuestProjectSupervisor {
    /// The supervisor answers CAPS with protocol=4; data channels answer 3.
    public static let requiredProtocol = 4
    /// Guest struct bound for the PROJOPEN roots (g_base/g_state are char[256]).
    static let maximumRootUTF8Bytes = 255

    private let channel: LinuxGuestCommandChannel
    private let limits: LinuxGuestLimits
    private let eventBufferLimit: Int
    private let eventPump: LinuxGuestSupervisorEventPump
    private var eventObserverInstalled = false

    public init(
        transport: any LinuxGuestConsoleTransport,
        limits: LinuxGuestLimits = .standard,
        eventBufferLimit: Int = 256
    ) {
        self.channel = LinuxGuestCommandChannel(transport: transport, limits: limits)
        self.limits = limits
        self.eventBufferLimit = max(1, eventBufferLimit)
        self.eventPump = LinuxGuestSupervisorEventPump(expectedGeneration: 0)
    }

    // MARK: events

    /// Bounded stream of asynchronous EVENT notices. Installation of the
    /// channel observer is lazy and idempotent.
    public func events() async -> AsyncStream<LinuxGuestProjectEvent> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: LinuxGuestProjectEvent.self,
            bufferingPolicy: .bufferingNewest(eventBufferLimit)
        )
        await eventPump.install(continuation)
        return stream
    }

    /// Re-arms EVENT delivery after a guest reboot: re-captures the router
    /// generation fence so notices from the new boot flow again. Call after
    /// the owner repaired/rebooted the resident machine.
    public func reconnect() async {
        await ensureEventObserverInstalled(force: true)
    }

    public func close() async {
        if eventObserverInstalled {
            await channel.installSupervisorEventObserver(nil)
            eventObserverInstalled = false
        }
        await eventPump.finish()
        await channel.close()
    }

    private func ensureEventObserverInstalled(force: Bool = false) async {
        guard !eventObserverInstalled || force else { return }
        let pump = eventPump
        let generation = await channel.installSupervisorEventObserver { arguments, eventGeneration in
            Task { await pump.onEvent(arguments: arguments, generation: eventGeneration) }
        }
        await eventPump.setExpectedGeneration(generation)
        eventObserverInstalled = true
    }

    /// Diagnostic/test seam: notices dropped by the generation fence or the
    /// identity validation, counted and never silently lost.
    func droppedEventCount() async -> Int {
        await eventPump.droppedEventCount
    }

    // MARK: capability negotiation

    /// HELLO -> CAPS, requiring the protocol-4 supervisor answer. Every
    /// returned field is a guest value; capacity for the resident machine
    /// derives from `maximumProjects`, never a host constant.
    public func capabilities(timeout: TimeInterval = 10) async throws -> LinuxGuestProjectSupervisorCapabilities {
        await ensureEventObserverInstalled()
        guard let payload = try await channel.probeCapabilities(
            timeout: limits.clampedTimeout(timeout), requireCurrentProtocol: false
        ) else {
            throw LinuxGuestProjectSupervisorError.supervisorUnavailable(foundCapabilities: nil)
        }
        guard let capabilities = Self.parseCapabilities(payload) else {
            throw LinuxGuestProjectSupervisorError.supervisorUnavailable(foundCapabilities: payload)
        }
        guard capabilities.protocolVersion == Self.requiredProtocol else {
            throw LinuxGuestProjectSupervisorError.supervisorUnavailable(foundCapabilities: payload)
        }
        return capabilities
    }

    static func parseCapabilities(_ payload: String) -> LinuxGuestProjectSupervisorCapabilities? {
        var runner: String?
        var protocolVersion: Int?
        var projects: Int?
        var tasks: Int?
        var sessions: Int?
        var base: String?
        var state: String?
        var net: String?
        for field in payload.split(separator: " ") {
            if field.hasPrefix("runner=") {
                runner = String(field.dropFirst("runner=".count))
            } else if field.hasPrefix("protocol="), let value = Int(field.dropFirst("protocol=".count)) {
                protocolVersion = value
            } else if field.hasPrefix("projects="), let value = Int(field.dropFirst("projects=".count)) {
                projects = value
            } else if field.hasPrefix("tasks="), let value = Int(field.dropFirst("tasks=".count)) {
                tasks = value
            } else if field.hasPrefix("sessions="), let value = Int(field.dropFirst("sessions=".count)) {
                sessions = value
            } else if field.hasPrefix("base=") {
                base = String(field.dropFirst("base=".count))
            } else if field.hasPrefix("state=") {
                state = String(field.dropFirst("state=".count))
            } else if field.hasPrefix("net=") {
                net = String(field.dropFirst("net=".count))
            }
        }
        guard let runner, let protocolVersion,
              let projects, let tasks, let sessions,
              let base, let state, let net,
              (1...8).contains(projects), (1...8).contains(tasks), (1...4).contains(sessions),
              let network = LinuxGuestProjectSupervisorCapabilities.NetworkState(rawValue: net),
              (try? validateRoot(base, field: "base", allowEmpty: false)) != nil,
              (try? validateRoot(state, field: "state", allowEmpty: false)) != nil else {
            return nil
        }
        return LinuxGuestProjectSupervisorCapabilities(
            runner: runner,
            protocolVersion: protocolVersion,
            maximumProjects: projects,
            maximumProjectTasks: tasks,
            maximumProjectSessions: sessions,
            baseRootfs: base,
            stateRoot: state,
            network: network
        )
    }

    // MARK: project lifecycle

    /// PROJOPEN: mounts the per-project overlay rootfs and the reserved
    /// workspace share + console and spawns the project's runner. `baseRootfs` must be
    /// the supervisor-configured immutable base (the guest compares by
    /// equality); the workspace is an in-project absolute path or empty for
    /// the project home. Both are caller-supplied, already-authorized
    /// absolute paths — never model-tool arguments.
    ///
    /// Returns the allocated console index only after the guest acked END 0
    /// and the ack names this exact project/generation.
    public func open(
        projectID: LinuxGuestProjectID,
        generation: LinuxGuestProjectGeneration,
        baseRootfs: String,
        workspaceDir: String,
        shareSlot: Int,
        timeout: TimeInterval = 60,
        cancellation: CancellationToken? = nil
    ) async throws -> LinuxGuestProjectOpenResult {
        try await open(
            projectID: projectID,
            generation: generation,
            baseRootfs: baseRootfs,
            workspace: LinuxGuestProjectWorkspaceMount(directory: workspaceDir, shareSlot: shareSlot),
            timeout: timeout,
            cancellation: cancellation
        )
    }

    /// PROJOPEN with the extensible workspace mount descriptor.
    public func open(
        projectID: LinuxGuestProjectID,
        generation: LinuxGuestProjectGeneration,
        baseRootfs: String,
        workspace: LinuxGuestProjectWorkspaceMount,
        timeout: TimeInterval = 60,
        cancellation: CancellationToken? = nil
    ) async throws -> LinuxGuestProjectOpenResult {
        await ensureEventObserverInstalled()
        try Self.validateRoot(baseRootfs, field: "baseRootfs", allowEmpty: false)
        // The guest requires [baseRootfs, workspaceDir, nativeShareSlot].
        let payload = LinuxGuestFraming.projectControlPayload(
            fields: workspace.payloadFields(baseRootfs: baseRootfs)
        )
        guard payload.count <= limits.maxEnvelopeBytes else {
            throw LinuxGuestProjectSupervisorError.invalidRoot(
                field: "baseRootfs/workspaceDir",
                detail: "payload is \(payload.count) bytes; the supervisor reassembles at most \(limits.maxEnvelopeBytes)"
            )
        }
        do {
            let outcome = try await channel.supervisorControlExchange(
                name: "PROJOPEN",
                payload: payload,
                payloadHeaderExtraArguments: [projectID.rawValue, generation.rawValue],
                timeout: limits.clampedTimeout(timeout),
                cancellation: cancellation
            )
            switch outcome.exit {
            case 0:
                do {
                    return try Self.parseOpenAck(outcome.text, projectID: projectID, generation: generation, shareSlot: workspace.shareSlot)
                } catch {
                    // A successful guest-side open with an invalid receipt is
                    // still possibly live. Retain its share/lease until the
                    // owner reconciles PROJSTAT; never reuse the slot blindly.
                    throw LinuxGuestProjectSupervisorError.openOutcomeUncertain(
                        projectID: projectID.rawValue,
                        generation: generation.rawValue,
                        reason: String(describing: error)
                    )
                }
            case 3:
                throw LinuxGuestProjectSupervisorError.unknownProject(
                    projectID: projectID.rawValue, generation: generation.rawValue
                )
            case 125:
                throw LinuxGuestProjectSupervisorError.tableFull(detail: outcome.text)
            case 126:
                throw LinuxGuestProjectSupervisorError.setupFailed(detail: outcome.text)
            case 127:
                throw LinuxGuestProjectSupervisorError.refused(detail: outcome.text)
            default:
                throw LinuxGuestProjectSupervisorError.unexpectedExit(
                    exchange: "PROJOPEN", code: outcome.exit, detail: outcome.text
                )
            }
        } catch let error as LinuxGuestProjectSupervisorError {
            throw error
        } catch {
            // Cancellation, timeout or console loss before the ack: the
            // project may exist. Never claim "uncreated"; hand the caller an
            // explicit uncertain-outcome error for PROJSTAT/PROJDROP
            // reconciliation.
            throw LinuxGuestProjectSupervisorError.openOutcomeUncertain(
                projectID: projectID.rawValue,
                generation: generation.rawValue,
                reason: String(describing: error)
            )
        }
    }

    /// PROJCLOSE: kills the project's tasks + runner and unmounts the
    /// runtime view; overlay data persists. A held lease refuses with 127.
    public func close(
        projectID: LinuxGuestProjectID,
        generation: LinuxGuestProjectGeneration,
        timeout: TimeInterval = 30,
        cancellation: CancellationToken? = nil
    ) async throws {
        await ensureEventObserverInstalled()
        let outcome = try await channel.supervisorControlExchange(
            name: "PROJCLOSE",
            arguments: [projectID.rawValue, generation.rawValue],
            timeout: limits.clampedTimeout(timeout),
            cancellation: cancellation
        )
        switch outcome.exit {
        case 0:
            return
        case 3:
            throw LinuxGuestProjectSupervisorError.unknownProject(
                projectID: projectID.rawValue, generation: generation.rawValue
            )
        case 125:
            throw LinuxGuestProjectSupervisorError.tableFull(detail: outcome.text)
        case 126:
            throw LinuxGuestProjectSupervisorError.setupFailed(detail: outcome.text)
        case 127:
            throw LinuxGuestProjectSupervisorError.refused(detail: outcome.text)
        default:
            throw LinuxGuestProjectSupervisorError.unexpectedExit(
                exchange: "PROJCLOSE", code: outcome.exit, detail: outcome.text
            )
        }
    }

    /// PROJDROP: deletes the project state dir after a successful close.
    /// Refused (127) while the project is open or a liveness record exists.
    public func drop(
        projectID: LinuxGuestProjectID,
        generation: LinuxGuestProjectGeneration,
        timeout: TimeInterval = 30,
        cancellation: CancellationToken? = nil
    ) async throws {
        await ensureEventObserverInstalled()
        let outcome = try await channel.supervisorControlExchange(
            name: "PROJDROP",
            arguments: [projectID.rawValue, generation.rawValue],
            timeout: limits.clampedTimeout(timeout),
            cancellation: cancellation
        )
        switch outcome.exit {
        case 0:
            return
        case 3:
            throw LinuxGuestProjectSupervisorError.unknownProject(
                projectID: projectID.rawValue, generation: generation.rawValue
            )
        case 125:
            throw LinuxGuestProjectSupervisorError.tableFull(detail: outcome.text)
        case 126:
            throw LinuxGuestProjectSupervisorError.setupFailed(detail: outcome.text)
        case 127:
            throw LinuxGuestProjectSupervisorError.refused(detail: outcome.text)
        default:
            throw LinuxGuestProjectSupervisorError.unexpectedExit(
                exchange: "PROJDROP", code: outcome.exit, detail: outcome.text
            )
        }
    }

    /// PROJSTAT: one record per open project (active/opening/closing/
    /// recovered), with the allocated console and lease state.
    public func status(
        timeout: TimeInterval = 10,
        cancellation: CancellationToken? = nil
    ) async throws -> [LinuxGuestProjectRecord] {
        await ensureEventObserverInstalled()
        let outcome = try await channel.supervisorControlExchange(
            name: "PROJSTAT",
            timeout: limits.clampedTimeout(timeout),
            cancellation: cancellation
        )
        switch outcome.exit {
        case 0:
            return try Self.parseStatus(outcome.text)
        case 125:
            throw LinuxGuestProjectSupervisorError.tableFull(detail: outcome.text)
        case 126:
            throw LinuxGuestProjectSupervisorError.setupFailed(detail: outcome.text)
        default:
            throw LinuxGuestProjectSupervisorError.unexpectedExit(
                exchange: "PROJSTAT", code: outcome.exit, detail: outcome.text
            )
        }
    }

    /// TASKKILL: cgroup.kill of one task in the project. Returns false when
    /// the guest reports the task/project unknown (nothing was killed).
    @discardableResult
    public func killTask(
        projectID: LinuxGuestProjectID,
        generation: LinuxGuestProjectGeneration,
        taskID: LinuxGuestProjectTaskID,
        timeout: TimeInterval = 15,
        cancellation: CancellationToken? = nil
    ) async throws -> Bool {
        await ensureEventObserverInstalled()
        let outcome = try await channel.supervisorControlExchange(
            name: "TASKKILL",
            arguments: [projectID.rawValue, generation.rawValue, taskID.rawValue],
            timeout: limits.clampedTimeout(timeout),
            cancellation: cancellation
        )
        switch outcome.exit {
        case 0:
            return true
        case 3:
            return false
        case 125:
            throw LinuxGuestProjectSupervisorError.tableFull(detail: outcome.text)
        case 126:
            throw LinuxGuestProjectSupervisorError.setupFailed(detail: outcome.text)
        case 127:
            throw LinuxGuestProjectSupervisorError.refused(detail: outcome.text)
        default:
            throw LinuxGuestProjectSupervisorError.unexpectedExit(
                exchange: "TASKKILL", code: outcome.exit, detail: outcome.text
            )
        }
    }

    /// LEASE renew: records `leaseID` on the project (bounded 10 min guest
    /// lifetime, renewed on each call). 127 means held by another holder.
    public func renewLease(
        projectID: LinuxGuestProjectID,
        generation: LinuxGuestProjectGeneration,
        leaseID: String,
        timeout: TimeInterval = 15,
        cancellation: CancellationToken? = nil
    ) async throws {
        await ensureEventObserverInstalled()
        try Self.validateLeaseID(leaseID)
        let outcome = try await channel.supervisorControlExchange(
            name: "LEASE",
            arguments: [projectID.rawValue, generation.rawValue, "renew", leaseID],
            timeout: limits.clampedTimeout(timeout),
            cancellation: cancellation
        )
        switch outcome.exit {
        case 0:
            return
        case 3:
            throw LinuxGuestProjectSupervisorError.unknownProject(
                projectID: projectID.rawValue, generation: generation.rawValue
            )
        case 125:
            throw LinuxGuestProjectSupervisorError.tableFull(detail: outcome.text)
        case 126:
            throw LinuxGuestProjectSupervisorError.setupFailed(detail: outcome.text)
        case 127:
            throw LinuxGuestProjectSupervisorError.refused(detail: outcome.text)
        default:
            throw LinuxGuestProjectSupervisorError.unexpectedExit(
                exchange: "LEASE renew", code: outcome.exit, detail: outcome.text
            )
        }
    }

    /// LEASE release. Returns false when this holder holds nothing (END 3).
    @discardableResult
    public func releaseLease(
        projectID: LinuxGuestProjectID,
        generation: LinuxGuestProjectGeneration,
        leaseID: String,
        timeout: TimeInterval = 15,
        cancellation: CancellationToken? = nil
    ) async throws -> Bool {
        await ensureEventObserverInstalled()
        try Self.validateLeaseID(leaseID)
        let outcome = try await channel.supervisorControlExchange(
            name: "LEASE",
            arguments: [projectID.rawValue, generation.rawValue, "release", leaseID],
            timeout: limits.clampedTimeout(timeout),
            cancellation: cancellation
        )
        switch outcome.exit {
        case 0:
            return true
        case 3:
            return false
        case 125:
            throw LinuxGuestProjectSupervisorError.tableFull(detail: outcome.text)
        case 126:
            throw LinuxGuestProjectSupervisorError.setupFailed(detail: outcome.text)
        case 127:
            throw LinuxGuestProjectSupervisorError.refused(detail: outcome.text)
        default:
            throw LinuxGuestProjectSupervisorError.unexpectedExit(
                exchange: "LEASE release", code: outcome.exit, detail: outcome.text
            )
        }
    }

    /// PING: supervisor liveness (END 0).
    public func ping(
        timeout: TimeInterval = 10,
        cancellation: CancellationToken? = nil
    ) async throws {
        await ensureEventObserverInstalled()
        let outcome = try await channel.supervisorControlExchange(
            name: "PING",
            timeout: limits.clampedTimeout(timeout),
            cancellation: cancellation
        )
        switch outcome.exit {
        case 0:
            return
        default:
            throw LinuxGuestProjectSupervisorError.unexpectedExit(
                exchange: "PING", code: outcome.exit, detail: outcome.text
            )
        }
    }

    // MARK: parsing + validation helpers

    /// PROJOPEN ack line:
    /// `project=<id> generation=<gen> console=hvc<N> root=<path> workspace=<path> share=floe-ws`.
    /// Roots are validated printable ASCII without spaces, so a plain token
    /// split is exact. A positive ack naming another project/generation is
    /// discarded as a stale response.
    static func parseOpenAck(
        _ text: String,
        projectID: LinuxGuestProjectID,
        generation: LinuxGuestProjectGeneration,
        shareSlot: Int
    ) throws -> LinuxGuestProjectOpenResult {
        var fields: [String: String] = [:]
        // Parse the last non-empty line (the ack row).
        guard let line = text.split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            throw LinuxGuestProjectSupervisorError.malformedResponse(
                exchange: "PROJOPEN", detail: "END 0 carried no project line"
            )
        }
        for token in line.split(separator: " ") {
            guard let equal = token.firstIndex(of: "=") else {
                throw LinuxGuestProjectSupervisorError.malformedResponse(
                    exchange: "PROJOPEN", detail: "unexpected token '\(token)'"
                )
            }
            fields[String(token[..<equal])] = String(token[token.index(after: equal)...])
        }
        guard let projectText = fields["project"], projectText == projectID.rawValue,
              let generationText = fields["generation"], generationText == generation.rawValue else {
            throw LinuxGuestProjectSupervisorError.responseIdentityMismatch(
                exchange: "PROJOPEN",
                expectedProject: projectID.rawValue,
                expectedGeneration: generation.rawValue,
                found: "project=\(fields["project"] ?? "?") generation=\(fields["generation"] ?? "?")"
            )
        }
        guard let consoleText = fields["console"], consoleText.hasPrefix("hvc"),
              let consoleIndex = Int(consoleText.dropFirst("hvc".count)), consoleIndex == shareSlot + 1,
              let root = fields["root"], !root.isEmpty,
              let workspace = fields["workspace"], fields["share"] == "floe-ws" else {
            throw LinuxGuestProjectSupervisorError.malformedResponse(
                exchange: "PROJOPEN", detail: "ack line does not match the reserved console or shared workspace: \(line)"
            )
        }
        try validateRoot(root, field: "root", allowEmpty: false)
        try validateRoot(workspace, field: "workspace", allowEmpty: false)
        return LinuxGuestProjectOpenResult(
            projectID: projectID,
            generation: generation,
            consoleIndex: consoleIndex,
            root: root,
            workspace: workspace
        )
    }

    /// PROJSTAT rows:
    /// `project=<id> generation=<gen> state=<s> console=hvc<N> runner=<pid> lease=held|free`.
    static func parseStatus(_ text: String) throws -> [LinuxGuestProjectRecord] {
        var records: [LinuxGuestProjectRecord] = []
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            var fields: [String: String] = [:]
            for token in line.split(separator: " ") {
                guard let equal = token.firstIndex(of: "=") else {
                    throw LinuxGuestProjectSupervisorError.malformedResponse(
                        exchange: "PROJSTAT", detail: "unexpected token '\(token)' in '\(line)'"
                    )
                }
                fields[String(token[..<equal])] = String(token[token.index(after: equal)...])
            }
            guard let projectText = fields["project"],
                  let projectID = try? LinuxGuestProjectID(projectText),
                  let generationText = fields["generation"],
                  let generation = try? LinuxGuestProjectGeneration(generationText),
                  let stateText = fields["state"],
                  let state = LinuxGuestProjectState(rawValue: stateText),
                  let consoleText = fields["console"], consoleText.hasPrefix("hvc"),
                  let consoleIndex = Int(consoleText.dropFirst("hvc".count)),
                  let runnerText = fields["runner"], let runnerPID = Int(runnerText),
                  let leaseText = fields["lease"] else {
                throw LinuxGuestProjectSupervisorError.malformedResponse(
                    exchange: "PROJSTAT", detail: "row is missing fields: \(line)"
                )
            }
            records.append(LinuxGuestProjectRecord(
                projectID: projectID,
                generation: generation,
                state: state,
                consoleIndex: consoleIndex,
                runnerPID: runnerPID,
                leaseHeld: leaseText == "held"
            ))
        }
        return records
    }

    /// PROJOPEN roots: absolute, printable ASCII without spaces or control
    /// bytes (so they can never carry a frame terminator), within the guest
    /// struct bound (char[256]).
    static func validateRoot(_ value: String, field: String, allowEmpty: Bool) throws {
        if value.isEmpty {
            if allowEmpty { return }
            throw LinuxGuestProjectSupervisorError.invalidRoot(field: field, detail: "must not be empty")
        }
        let bytes = Array(value.utf8)
        guard bytes.count <= maximumRootUTF8Bytes else {
            throw LinuxGuestProjectSupervisorError.invalidRoot(
                field: field, detail: "is \(bytes.count) bytes; the supervisor bound is \(maximumRootUTF8Bytes)"
            )
        }
        guard bytes.allSatisfy({ $0 >= 0x21 && $0 <= 0x7e }) else {
            throw LinuxGuestProjectSupervisorError.invalidRoot(
                field: field, detail: "must be printable ASCII without spaces or control bytes"
            )
        }
        guard value.hasPrefix("/") else {
            throw LinuxGuestProjectSupervisorError.invalidRoot(field: field, detail: "must be an absolute path")
        }
    }

    /// Lease IDs ride a frame argument: the guest bound is the console
    /// token (FLOE_CTRL_MAX_TOKEN = 96, printable, no spaces).
    static func validateLeaseID(_ leaseID: String) throws {
        guard LinuxGuestFraming.isValidGuestToken(leaseID) else {
            throw LinuxGuestProjectSupervisorError.invalidIdentity(
                field: "leaseID",
                detail: "must be 1...\(LinuxGuestFraming.maxTokenBytes) printable-ASCII bytes without spaces (the console token bound)"
            )
        }
    }
}
