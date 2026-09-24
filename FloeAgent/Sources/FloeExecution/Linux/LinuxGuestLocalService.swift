// FloeExecution — persistent services inside a Linux environment.
//
// `exec.localService` in a Linux environment is one detached process in that
// environment's guest. The host half is this supervisor plus the runner
// frames implemented in LinuxGuestCommandChannel:
//
//   host → \x1eFLOE-SPAWN <token> <payloadBytes> <chunkCount> + CHUNKs + RUN
//          payload = [cwd, logPath, argv...]
//   guest → \x1eFLOE-PID <token> <pid> then \x1eFLOE-END <token> 0
//   host → \x1eFLOE-KILL <token> <pid> / \x1eFLOE-ALIVE <token> <pid>
//   guest → \x1eFLOE-END <token> 0 (alive/killed) or 3 (unknown pid)
//
// stdout and stderr are appended by the guest to a log file inside the
// environment's 9p share, so the host reads live logs from the same file and
// never keeps a console pipe open for a service that outlives a reply. Ports
// are published with the engine's slirp host forwarding
// (`floe_vm_hostfwd_add`), which is why a guest service is reachable on
// 127.0.0.1 exactly like a native one.

import Foundation
import FloeCore
import FloeTools

public enum LinuxGuestLocalServiceRuntime: String, Sendable, Codable, CaseIterable {
    case node
    case python
}

public struct LinuxGuestLocalServiceRequest: Sendable {
    /// Host path of the entry script; must be inside the workspace or the
    /// environment layer (mapped to the guest's 9p mount).
    public var entry: String
    public var runtime: LinuxGuestLocalServiceRuntime
    public var arguments: [String]
    /// Host path of the working directory; nil keeps the guest default
    /// (`/workspace` when the share is mounted).
    public var workingDirectory: String?
    public var port: Int
    /// Host path of the service log; must be inside a shared directory so the
    /// guest writes and the host tail read the same file.
    public var logFile: URL
    public var environment: [String: String]

    public init(
        entry: String,
        runtime: LinuxGuestLocalServiceRuntime,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        port: Int,
        logFile: URL,
        environment: [String: String] = [:]
    ) {
        self.entry = entry
        self.runtime = runtime
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.port = port
        self.logFile = logFile
        self.environment = environment
    }
}

public struct LinuxGuestLocalServiceHandle: Sendable, Equatable {
    public var token: String
    public var environmentID: String
    public var runtime: LinuxGuestLocalServiceRuntime
    public var pid: Int32
    public var port: Int
    public var forward: LinuxGuestServiceForward
    public var logHostPath: String
    public var logGuestPath: String
    public var startedAt: Date

    public init(
        token: String,
        environmentID: String,
        runtime: LinuxGuestLocalServiceRuntime,
        pid: Int32,
        port: Int,
        forward: LinuxGuestServiceForward,
        logHostPath: String,
        logGuestPath: String,
        startedAt: Date
    ) {
        self.token = token
        self.environmentID = environmentID
        self.runtime = runtime
        self.pid = pid
        self.port = port
        self.forward = forward
        self.logHostPath = logHostPath
        self.logGuestPath = logGuestPath
        self.startedAt = startedAt
    }
}

public struct LinuxGuestLocalServiceSnapshot: Sendable, Equatable {
    /// starting | running | stopped | failed | unavailable | notFound
    ///
    /// `unavailable` is the honest answer when the supervision probe itself
    /// failed: the process is NOT confirmed dead (a transient guest/console
    /// error must never be reported as an exit), so the handle stays owned and
    /// a later probe can confirm the real state.
    public var state: String
    public var pid: Int32?
    public var alive: Bool
    public var stdout: String
    public var stderr: String
    public var truncated: Bool
    public var logBytes: Int64
    public var lastError: String?

    public init(
        state: String,
        pid: Int32? = nil,
        alive: Bool = false,
        stdout: String = "",
        stderr: String = "",
        truncated: Bool = false,
        logBytes: Int64 = 0,
        lastError: String? = nil
    ) {
        self.state = state
        self.pid = pid
        self.alive = alive
        self.stdout = stdout
        self.stderr = stderr
        self.truncated = truncated
        self.logBytes = logBytes
        self.lastError = lastError
    }
}

/// The guest-side operations the supervisor needs. The registry implements
/// this; tests can script it.
public protocol LinuxGuestLocalServiceHosting: LinuxCommandRunning {
    func guestDescriptor(environmentID: String) async -> LinuxGuestEnvironmentDescriptor?
    func guestSpawn(
        environmentID: String,
        argv: [String],
        workingDirectory: String?,
        logPath: String,
        timeout: TimeInterval,
        cancellation: CancellationToken?
    ) async throws -> Int32
    func guestServiceAlive(environmentID: String, pid: Int32, timeout: TimeInterval) async throws -> Bool
    func guestKillService(environmentID: String, pid: Int32, timeout: TimeInterval) async throws -> Bool
    func guestEnsureForward(environmentID: String, forward: LinuxGuestServiceForward) async throws
    func guestRemoveForward(environmentID: String, forward: LinuxGuestServiceForward) async
    /// Directory for the supervisor's durable pending-terminal store, or nil
    /// (the default for scripted/ephemeral hosts) for an in-memory store.
    /// The production registry points at the app's own support directory, so
    /// an observed end that no consumer acknowledged yet survives an app
    /// relaunch and is replayed instead of being lost.
    var localServiceTerminalStoreDirectory: URL? { get }
}

public extension LinuxGuestLocalServiceHosting {
    var localServiceTerminalStoreDirectory: URL? { nil }
}

/// Why a supervised guest service is no longer running, exactly as the host
/// observed it. The guest protocol answers liveness only (`FLOE-ALIVE` →
/// alive/unknown-pid) and carries no exit status, so the supervisor never
/// invents a crash cause and never invents an exit code: an observed end
/// without an explicit host stop is reported as `processExited`, which
/// consumers must label as an unexpected stop rather than a crash.
public enum LinuxGuestLocalServiceStopReason: Sendable, Equatable {
    /// The guest reported the supervised pid is no longer alive.
    case processExited
    /// The environment no longer runs a guest; the service disappeared with
    /// it. No host stop was routed through the supervisor first.
    case environmentGone
    /// The host explicitly stopped the service (tool cancel, job cancel,
    /// environment stop/delete, app teardown). This is an expected end and
    /// must never be surfaced as a service failure.
    case hostStopRequested

    /// Explicit host stops are the only reason a consumer may treat as
    /// expected; every other reason is an observed end without a stop order.
    public var isExplicitHostStop: Bool { self == .hostStopRequested }
}

extension LinuxGuestLocalServiceStopReason {
    /// Stable name used by the pending-store records. Payload-free enum with
    /// raw-value semantics, kept separate from any public Codable story.
    var persistenceName: String {
        switch self {
        case .processExited: "processExited"
        case .environmentGone: "environmentGone"
        case .hostStopRequested: "hostStopRequested"
        }
    }

    init?(persistenceName: String) {
        switch persistenceName {
        case "processExited": self = .processExited
        case "environmentGone": self = .environmentGone
        case "hostStopRequested": self = .hostStopRequested
        default: return nil
        }
    }
}

/// One observed lifecycle transition of a managed guest service. Carries the
/// exact handle so a consumer reports the real environment/service identity
/// (environment, runtime, pid, port, start time) instead of reconstructing it
/// from UI state.
public struct LinuxGuestLocalServiceLifecycleEvent: Sendable, Equatable {
    public var handle: LinuxGuestLocalServiceHandle
    public var reason: LinuxGuestLocalServiceStopReason
    public var observedAt: Date

    public init(
        handle: LinuxGuestLocalServiceHandle,
        reason: LinuxGuestLocalServiceStopReason,
        observedAt: Date = Date()
    ) {
        self.handle = handle
        self.reason = reason
        self.observedAt = observedAt
    }
}

/// Lifecycle-reporting seam consumed by the app's durable terminal pipeline.
/// Deliberately separate from `LinuxGuestLocalServiceControlling` so existing
/// scripted conformers stay source-compatible. It is a real protocol
/// requirement (not an extension default): the production facade implements
/// it, and callers must not rely on a defaulted method that static dispatch
/// would answer through an existential.
///
/// Delivery contract: `localServiceLifecycleEvents()` carries every observed
/// end (`processExited`/`environmentGone`) that has not been acknowledged as
/// accepted by the app's durable pipeline; a consumer must call
/// `acknowledgeLocalServiceLifecycleEvent(_:)` after it accepted the event
/// (durably enqueued it, or knowingly dropped it by policy) so the next
/// pending event can be delivered. At most one event is in flight per
/// consumer, so a slow consumer can never have an event silently displaced.
/// Unacknowledged events stay in the bounded persistent store and are
/// replayed to the next observer (including after an app relaunch).
public protocol LinuxGuestLocalServiceLifecycleReporting: Sendable {
    func localServiceLifecycleEvents() async -> AsyncStream<LinuxGuestLocalServiceLifecycleEvent>
    /// Acknowledges that the consumer accepted `event`, releasing the bounded
    /// delivery slot and dropping the event from the persistent store. Safe to
    /// call repeatedly and for events the consumer never saw (idempotent).
    func acknowledgeLocalServiceLifecycleEvent(_ event: LinuxGuestLocalServiceLifecycleEvent) async
}

public extension LinuxGuestLocalServiceLifecycleReporting {
    /// Source-compatible default for observers that do not run the app's
    /// durable pipeline; the production facade overrides it with the real
    /// store.
    func acknowledgeLocalServiceLifecycleEvent(_ event: LinuxGuestLocalServiceLifecycleEvent) async {}
}

/// Consumed by the app's `exec.localService` job runner when the environment
/// is a Linux guest.
public protocol LinuxGuestLocalServiceControlling: Sendable {
    func startLocalService(
        environmentID: String,
        request: LinuxGuestLocalServiceRequest,
        cancellation: CancellationToken?
    ) async throws -> LinuxGuestLocalServiceHandle
    func localServiceSnapshot(_ handle: LinuxGuestLocalServiceHandle) async -> LinuxGuestLocalServiceSnapshot
    func stopLocalService(_ handle: LinuxGuestLocalServiceHandle) async
    /// Stops every service of one environment (environment stop/delete).
    func stopLocalServices(environmentID: String) async
    /// Number of managed services currently recorded for one environment.
    func activeLocalServiceCount(environmentID: String) async -> Int
}

public extension LinuxGuestLocalServiceControlling {
    func activeLocalServiceCount(environmentID: String) async -> Int { 0 }
}

public actor LinuxGuestLocalServiceSupervisor: LinuxGuestLocalServiceControlling, LinuxGuestLocalServiceLifecycleReporting {
    /// One stream slot per observer, and exactly one event in flight per
    /// observer: the next event is only yielded after the consumer
    /// acknowledged the previous one, so `bufferingNewest(1)` can never
    /// silently discard a pending observed end. Reliability comes from the
    /// acknowledged pending store below, not from a wider buffer.
    public static let lifecycleStreamBufferBound = 1
    /// Hard bound for the acknowledged pending store. Reaching it means a
    /// consumer stopped acknowledging for far longer than the app's own
    /// observer ever does; the oldest record is then evicted with a counted,
    /// logged diagnostic instead of silently growing (or silently dropping).
    public static let maximumPendingTerminalEvents = 256
    private let host: any LinuxGuestLocalServiceHosting
    private let limits: LinuxGuestLimits
    private let maxLogTailBytes: Int
    private var active: [String: LinuxGuestLocalServiceHandle] = [:]
    private var lifecycleObservers: [UUID: LifecycleObservation] = [:]
    private var lifecycleDeliveryTasks: [UUID: Task<Void, Never>] = [:]
    /// One parked delivery wait per observer (ack, new pending event, removal).
    private var lifecycleDeliveryWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// Acknowledged pending store: every observed end that no consumer accepted
    /// yet, oldest first. Persisted when the host offers a directory, so an
    /// unacknowledged end survives a relaunch and is replayed instead of
    /// being lost. A repeated probe of the same handle never adds a second
    /// entry (keys are per-start tokens).
    private var pendingTerminalEvents: [LinuxGuestLocalServiceLifecycleEvent] = []
    /// Where `pendingTerminalEvents` is persisted; nil keeps it in memory.
    private let terminalStoreURL: URL?
    /// Terminal events evicted at the store bound (never silent).
    public private(set) var droppedTerminalEventCount = 0
    /// Monotonic per-environment lifecycle epoch. Every environment-level stop
    /// bumps it before doing anything else, so a service start that crossed an
    /// await can detect that its guest is gone (or replaced) and must not
    /// publish a handle for it.
    private var serviceStartEpochs: [String: UInt64] = [:]
    /// Starts currently crossing their awaits, per environment, so an
    /// environment stop can wait for them to settle (and clean up their
    /// spawned process/forward) before the VM teardown proceeds.
    private var pendingServiceStarts: [String: [UUID]] = [:]
    private var pendingServiceStartWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    /// Latest emitted event and a monotonic count for diagnostics/tests. Only
    /// transitions of handles the supervisor still owned are emitted, so a
    /// repeated probe of an already-reported exit adds nothing.
    public private(set) var lastLifecycleEvent: LinuxGuestLocalServiceLifecycleEvent?
    public private(set) var emittedLifecycleEventCount = 0
    public var lifecycleObserverCount: Int { lifecycleObservers.count }
    /// Handles currently owned (running or not yet confirmed exited).
    public var activeServiceCount: Int { active.count }
    /// Observed ends waiting for a consumer acknowledgement.
    public var pendingTerminalEventCount: Int { pendingTerminalEvents.count }

    public init(
        host: any LinuxGuestLocalServiceHosting,
        limits: LinuxGuestLimits = .standard,
        maxLogTailBytes: Int = 8_000
    ) {
        self.host = host
        self.limits = limits
        self.maxLogTailBytes = max(1024, maxLogTailBytes)
        let directory = host.localServiceTerminalStoreDirectory
        self.terminalStoreURL = directory?.appendingPathComponent(Self.terminalStoreFileName)
        self.pendingTerminalEvents = Self.loadPendingTerminalEvents(from: terminalStoreURL)
    }

    /// One consumer of the lifecycle stream plus the single durable end it has
    /// been handed but not acknowledged yet.
    private struct LifecycleObservation {
        var continuation: AsyncStream<LinuxGuestLocalServiceLifecycleEvent>.Continuation
        var inFlightToken: String?
    }

    // MARK: - lifecycle reporting

    /// Acknowledged lifecycle stream. Every observed end is delivered exactly
    /// once per accepted consumer and stays in the bounded store until the
    /// consumer acknowledges it; an unacknowledged end is replayed to the next
    /// observer (including after a relaunch). Explicit host stops are
    /// transient notices: they are never stored and are never yielded while a
    /// durable end is in flight, so a burst of expected stops can neither
    /// displace nor lose a real observed end. A probe that could not verify
    /// liveness emits nothing and keeps the handle owned, so a transient
    /// console error neither declares the process dead nor leaks repeated
    /// alerts.
    public func localServiceLifecycleEvents() async -> AsyncStream<LinuxGuestLocalServiceLifecycleEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(Self.lifecycleStreamBufferBound)) { continuation in
            let token = UUID()
            lifecycleObservers[token] = LifecycleObservation(continuation: continuation)
            startLifecycleDelivery(observer: token)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeLifecycleObserver(token) }
            }
        }
    }

    /// Releases the delivery slot and drops the event from the pending store.
    /// Acknowledging an event that is not pending (already accepted by another
    /// consumer, or never seen) is a no-op, so repeated delivery is
    /// idempotent.
    public func acknowledgeLocalServiceLifecycleEvent(
        _ event: LinuxGuestLocalServiceLifecycleEvent
    ) async {
        let key = event.handle.token
        if let index = pendingTerminalEvents.firstIndex(where: { $0.handle.token == key }) {
            pendingTerminalEvents.remove(at: index)
            persistPendingTerminalEvents()
        }
        for (token, var observation) in lifecycleObservers where observation.inFlightToken == key {
            observation.inFlightToken = nil
            lifecycleObservers[token] = observation
            signalLifecycleDelivery(observer: token)
        }
    }

    private func removeLifecycleObserver(_ token: UUID) {
        // An event yielded but not acknowledged stays in the store: it is
        // replayed to the observer that comes next instead of being lost.
        lifecycleObservers.removeValue(forKey: token)
        lifecycleDeliveryTasks.removeValue(forKey: token)?.cancel()
        signalLifecycleDelivery(observer: token)
    }

    /// One delivery loop per observer: yield the oldest pending end, wait for
    /// its acknowledgement, then continue. Nothing is yielded while an earlier
    /// end is unacknowledged, so the single stream slot is never overflowed.
    private func startLifecycleDelivery(observer token: UUID) {
        guard lifecycleDeliveryTasks[token] == nil else { return }
        lifecycleDeliveryTasks[token] = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard let event = await self.nextPendingTerminalEvent(for: token) else { return }
                guard let continuation = await self.lifecycleContinuation(for: token) else { return }
                _ = continuation.yield(event)
            }
        }
    }

    private func nextPendingTerminalEvent(
        for token: UUID
    ) async -> LinuxGuestLocalServiceLifecycleEvent? {
        while true {
            guard let observation = lifecycleObservers[token] else { return nil }
            if observation.inFlightToken != nil {
                await waitForLifecycleDeliverySignal(observer: token)
                continue
            }
            guard let head = pendingTerminalEvents.first else {
                await waitForLifecycleDeliverySignal(observer: token)
                continue
            }
            lifecycleObservers[token]?.inFlightToken = head.handle.token
            return head
        }
    }

    private func lifecycleContinuation(
        for token: UUID
    ) -> AsyncStream<LinuxGuestLocalServiceLifecycleEvent>.Continuation? {
        lifecycleObservers[token]?.continuation
    }

    private func waitForLifecycleDeliverySignal(observer token: UUID) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lifecycleDeliveryWaiters[token] = continuation
        }
    }

    private func signalLifecycleDelivery(observer token: UUID) {
        lifecycleDeliveryWaiters.removeValue(forKey: token)?.resume()
    }

    private func emitLifecycleEvent(
        handle: LinuxGuestLocalServiceHandle,
        reason: LinuxGuestLocalServiceStopReason,
        at observedAt: Date = Date()
    ) {
        let event = LinuxGuestLocalServiceLifecycleEvent(
            handle: handle,
            reason: reason,
            observedAt: observedAt
        )
        lastLifecycleEvent = event
        emittedLifecycleEventCount += 1
        guard !reason.isExplicitHostStop else {
            // Expected end: a transient notice for an attached consumer, never
            // a stored entry and never yielded while a durable observed end is
            // in flight (which would displace it in the single-slot stream).
            for observation in lifecycleObservers.values where observation.inFlightToken == nil {
                _ = observation.continuation.yield(event)
            }
            return
        }
        guard !pendingTerminalEvents.contains(where: { $0.handle.token == event.handle.token }) else {
            return
        }
        pendingTerminalEvents.append(event)
        if pendingTerminalEvents.count > Self.maximumPendingTerminalEvents {
            let dropped = pendingTerminalEvents.removeFirst()
            droppedTerminalEventCount += 1
            FloeLogger(category: .tools).error(
                "linuxServiceTerminalDropped environment=\(dropped.handle.environmentID) pid=\(dropped.handle.pid) pending=\(Self.maximumPendingTerminalEvents) consumerStoppedAcknowledging=true"
            )
        }
        persistPendingTerminalEvents()
        for token in lifecycleObservers.keys {
            signalLifecycleDelivery(observer: token)
        }
    }

    // MARK: - pending terminal store persistence

    private static let terminalStoreFileName = "pending-terminal-events.json"

    /// One persisted observed end. Written as a plain record so the store
    /// survives app relaunches and is human-inspectable; the reason is stored
    /// as its stable case name (an explicit host stop is never persisted).
    private struct PersistedTerminalEvent: Codable, Equatable {
        var environmentID: String
        var token: String
        var runtime: String
        var pid: Int32
        var port: Int
        var forwardHostAddress: String
        var forwardHostPort: UInt16
        var forwardGuestPort: UInt16
        var forwardIsUDP: Bool
        var logHostPath: String
        var logGuestPath: String
        var startedAt: Date
        var reason: String
        var observedAt: Date

        init(event: LinuxGuestLocalServiceLifecycleEvent) {
            let handle = event.handle
            self.environmentID = handle.environmentID
            self.token = handle.token
            self.runtime = handle.runtime.rawValue
            self.pid = handle.pid
            self.port = handle.port
            self.forwardHostAddress = handle.forward.hostAddress
            self.forwardHostPort = handle.forward.hostPort
            self.forwardGuestPort = handle.forward.guestPort
            self.forwardIsUDP = handle.forward.isUDP
            self.logHostPath = handle.logHostPath
            self.logGuestPath = handle.logGuestPath
            self.startedAt = handle.startedAt
            self.reason = event.reason.persistenceName
            self.observedAt = event.observedAt
        }

        var event: LinuxGuestLocalServiceLifecycleEvent? {
            guard let runtime = LinuxGuestLocalServiceRuntime(rawValue: runtime) else { return nil }
            guard let reason = LinuxGuestLocalServiceStopReason(persistenceName: reason) else { return nil }
            return LinuxGuestLocalServiceLifecycleEvent(
                handle: LinuxGuestLocalServiceHandle(
                    token: token,
                    environmentID: environmentID,
                    runtime: runtime,
                    pid: pid,
                    port: port,
                    forward: LinuxGuestServiceForward(
                        hostAddress: forwardHostAddress,
                        hostPort: forwardHostPort,
                        guestPort: forwardGuestPort,
                        isUDP: forwardIsUDP
                    ),
                    logHostPath: logHostPath,
                    logGuestPath: logGuestPath,
                    startedAt: startedAt
                ),
                reason: reason,
                observedAt: observedAt
            )
        }
    }

    private static func loadPendingTerminalEvents(from url: URL?) -> [LinuxGuestLocalServiceLifecycleEvent] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        guard let records = try? JSONDecoder().decode([PersistedTerminalEvent].self, from: data) else {
            return []
        }
        let events = records.compactMap(\.event)
        let bound = maximumPendingTerminalEvents
        return events.count > bound ? Array(events.suffix(bound)) : events
    }

    private func persistPendingTerminalEvents() {
        guard let url = terminalStoreURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let records = pendingTerminalEvents.map(PersistedTerminalEvent.init(event:))
            try JSONEncoder().encode(records).write(to: url, options: .atomic)
        } catch {
            // Persistence is an extra recovery path; the in-memory store still
            // replays to any observer in this process. Never fail the
            // transition over it.
            FloeLogger(category: .tools).error(
                "linuxServiceTerminalStoreUnavailable error=\(error.localizedDescription)"
            )
        }
    }

    // MARK: - environment stop / start epoch

    /// Registers an in-flight start and returns the environment epoch it must
    /// still observe when it publishes its handle.
    private func beginServiceStart(environmentID: String, token: UUID) -> UInt64 {
        pendingServiceStarts[environmentID, default: []].append(token)
        return serviceStartEpochs[environmentID, default: 0]
    }

    private func finishServiceStart(environmentID: String, token: UUID) {
        guard var tokens = pendingServiceStarts[environmentID] else { return }
        tokens.removeAll { $0 == token }
        if tokens.isEmpty {
            pendingServiceStarts.removeValue(forKey: environmentID)
            for waiter in pendingServiceStartWaiters.removeValue(forKey: environmentID) ?? [] {
                waiter.resume()
            }
        } else {
            pendingServiceStarts[environmentID] = tokens
        }
    }

    /// The environment's current service-start epoch (diagnostics/tests). A
    /// start may only publish while its captured epoch is unchanged.
    func serviceStartEpoch(environmentID: String) -> UInt64 {
        serviceStartEpochs[environmentID, default: 0]
    }

    /// Number of starts currently crossing their awaits (diagnostics/tests).
    func pendingServiceStartCount(environmentID: String) -> Int {
        pendingServiceStarts[environmentID]?.count ?? 0
    }

    private func requireServiceStartEpoch(environmentID: String, epoch: UInt64) throws {
        guard serviceStartEpochs[environmentID, default: 0] == epoch else {
            throw LinuxGuestError.notRunning(environmentID: environmentID)
        }
    }

    private func waitForPendingServiceStarts(environmentID: String) async {
        while pendingServiceStarts[environmentID]?.isEmpty == false {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                pendingServiceStartWaiters[environmentID, default: []].append(continuation)
            }
        }
    }

    /// Cleanup for a start that discovered the environment was stopped while
    /// it crossed an await: the guest is gone (or replaced), so the spawned
    /// process is killed and the just-published forward is withdrawn before
    /// the start fails. A forward that was never added is removed idempotently.
    private func abandonSpawnedService(
        environmentID: String,
        pid: Int32,
        forward: LinuxGuestServiceForward
    ) async {
        _ = try? await host.guestKillService(environmentID: environmentID, pid: pid, timeout: 10)
        await host.guestRemoveForward(environmentID: environmentID, forward: forward)
        FloeLogger(category: .tools).info(
            "Linux guest service start abandoned environment=\(environmentID) pid=\(pid) reason=environmentStopped"
        )
    }

    public func startLocalService(
        environmentID: String,
        request: LinuxGuestLocalServiceRequest,
        cancellation: CancellationToken?
    ) async throws -> LinuxGuestLocalServiceHandle {
        // A start crosses several awaits (provisioning, spawn, forward) before
        // it owns a handle. Register it against the environment's stop epoch
        // so an environment stop that lands meanwhile invalidates it instead
        // of letting it publish a handle for a guest that no longer exists.
        let startToken = UUID()
        let startEpoch = beginServiceStart(environmentID: environmentID, token: startToken)
        defer { finishServiceStart(environmentID: environmentID, token: startToken) }
        guard let descriptor = await host.guestDescriptor(environmentID: environmentID) else {
            throw LinuxGuestError.notOwned(environmentID: environmentID)
        }
        guard await host.supports(environmentID: environmentID) else {
            throw LinuxGuestError.notRunning(environmentID: environmentID)
        }
        guard (1024...65535).contains(request.port) else {
            throw LinuxGuestError.invalidConfiguration("service port must be 1024..65535")
        }
        let pathMap = LinuxGuestPathMap(shares: descriptor.shares)
        guard let entryGuest = pathMap.guestPath(forHostPath: request.entry) else {
            throw LinuxGuestError.invalidConfiguration("the service entry script must be inside the environment workspace or layer")
        }
        guard let logGuest = pathMap.guestPath(forHostPath: request.logFile.path) else {
            throw LinuxGuestError.invalidConfiguration("the service log must be inside the environment workspace or layer")
        }
        let workingGuest: String?
        if let workingDirectory = request.workingDirectory {
            // A provided working directory must map; silently keeping the
            // guest default would run the service somewhere else than the
            // caller asked for.
            guard let mapped = pathMap.guestPath(forHostPath: workingDirectory) else {
                throw LinuxGuestError.invalidConfiguration("the service working directory must be inside the environment workspace or layer")
            }
            workingGuest = mapped
        } else {
            workingGuest = nil
        }

        var command: [String]
        switch request.runtime {
        case .python:
            let python = try await LinuxGuestPythonProvisioner.shared.ensure(
                environmentID: environmentID,
                runner: host,
                cancellation: cancellation
            )
            command = [python.pythonPath, entryGuest] + request.arguments
        case .node:
            command = ["node", entryGuest] + request.arguments
        }

        var variables = request.environment
        variables["PORT"] = String(request.port)
        variables["FLOE_SERVICE_PORT"] = String(request.port)
        variables["FLOE_ENVIRONMENT_ID"] = environmentID
        variables["PYTHONUNBUFFERED"] = "1"
        // Environment-level Node packages are the ones the package UI and the
        // managed installer write; a service must resolve them the same way
        // the guest shell does (PATH for bins, NODE_PATH for require).
        variables["NODE_PATH"] = LinuxGuestNodeEnvironment.guestNodeModules
        let inheritedPath = variables["PATH"] ?? ""
        variables["PATH"] = LinuxGuestNodeEnvironment.guestBin + ":"
            + LinuxGuestPythonEnvironment.guestVenvPath + "/bin:"
            + (inheritedPath.isEmpty ? LinuxGuestNodeEnvironment.defaultGuestPath : inheritedPath)
        // The environment layer's home/tmp exist as soon as the environment is
        // prepared (the coordinator creates them); a service that writes a
        // cache/config must not inherit a host path.
        if variables["HOME"] == nil { variables["HOME"] = LinuxGuestMountPoint.environment + "/home" }
        if variables["TMPDIR"] == nil { variables["TMPDIR"] = LinuxGuestMountPoint.environment + "/tmp" }
        if let injected = LinuxGuestEnvironmentEncoding.argv(variables) {
            command = ["env"] + injected + command
        }

        // Nothing has been spawned yet: if the environment was stopped while
        // this start was provisioning, fail before creating a process in a
        // guest that is gone.
        try requireServiceStartEpoch(environmentID: environmentID, epoch: startEpoch)

        let pid = try await host.guestSpawn(
            environmentID: environmentID,
            argv: command,
            workingDirectory: workingGuest,
            logPath: logGuest,
            timeout: limits.clampedTimeout(nil),
            cancellation: cancellation
        )

        let forward = LinuxGuestServiceForward(
            hostAddress: "127.0.0.1",
            hostPort: UInt16(request.port),
            guestPort: UInt16(request.port)
        )
        do {
            try await host.guestEnsureForward(environmentID: environmentID, forward: forward)
        } catch {
            // A service nobody can reach is a leak: kill it before reporting.
            _ = try? await host.guestKillService(environmentID: environmentID, pid: pid, timeout: 10)
            throw error
        }

        // Synchronous re-check with no await in between: an environment stop
        // that claimed this environment while the start crossed its awaits
        // wins. The spawned process and the just-published forward are cleaned
        // up so the stop leaves no orphan behind, and no handle is published.
        guard serviceStartEpochs[environmentID, default: 0] == startEpoch else {
            await abandonSpawnedService(environmentID: environmentID, pid: pid, forward: forward)
            throw LinuxGuestError.notRunning(environmentID: environmentID)
        }

        let handle = LinuxGuestLocalServiceHandle(
            token: UUID().uuidString,
            environmentID: environmentID,
            runtime: request.runtime,
            pid: pid,
            port: request.port,
            forward: forward,
            logHostPath: request.logFile.path,
            logGuestPath: logGuest,
            startedAt: Date()
        )
        active[handle.token] = handle
        FloeLogger(category: .tools).info(
            "Linux guest service started environment=\(environmentID) pid=\(pid) port=\(request.port) runtime=\(request.runtime.rawValue)"
        )
        return handle
    }

    public func localServiceSnapshot(_ handle: LinuxGuestLocalServiceHandle) async -> LinuxGuestLocalServiceSnapshot {
        guard active[handle.token] != nil else {
            return LinuxGuestLocalServiceSnapshot(state: "notFound", pid: handle.pid)
        }
        // A stopped guest takes its services with it; report that as stopped
        // instead of an error so the job can finish honestly.
        guard await host.supports(environmentID: handle.environmentID) else {
            // Revalidate after the await: an explicit stop may have claimed
            // this handle while the guest state was being read. A handle the
            // host already stopped is not an unexpected end.
            guard active.removeValue(forKey: handle.token) != nil else {
                let tail = Self.readLogTail(handle.logHostPath, maxBytes: maxLogTailBytes)
                return LinuxGuestLocalServiceSnapshot(
                    state: "stopped",
                    pid: handle.pid,
                    alive: false,
                    stdout: tail.text,
                    truncated: tail.truncated,
                    logBytes: tail.bytes
                )
            }
            // The environment went away without a stop routed through this
            // supervisor. Surface it once with the real identity; the cause
            // stays "the environment is gone" because the guest is not
            // readable any more.
            await host.guestRemoveForward(environmentID: handle.environmentID, forward: handle.forward)
            emitLifecycleEvent(handle: handle, reason: .environmentGone)
            let tail = Self.readLogTail(handle.logHostPath, maxBytes: maxLogTailBytes)
            return LinuxGuestLocalServiceSnapshot(
                state: "stopped",
                pid: handle.pid,
                alive: false,
                stdout: tail.text,
                truncated: tail.truncated,
                logBytes: tail.bytes,
                lastError: LinuxGuestError.notRunning(environmentID: handle.environmentID).localizedDescription
            )
        }
        let alive: Bool
        do {
            alive = try await host.guestServiceAlive(environmentID: handle.environmentID, pid: handle.pid, timeout: 10)
        } catch {
            // Could not verify liveness. A transient console/guest error is
            // NOT a confirmed exit: keep the handle owned so a later probe
            // can decide, and answer "unavailable" instead of claiming the
            // process failed. No lifecycle event is emitted.
            return LinuxGuestLocalServiceSnapshot(
                state: "unavailable",
                pid: handle.pid,
                alive: false,
                lastError: error.localizedDescription
            )
        }
        if !alive {
            // Revalidate after the await: an explicit stop that landed while
            // the probe was in flight owns this end, and a stale probe result
            // must never emit a failure event.
            guard active.removeValue(forKey: handle.token) != nil else {
                let tail = Self.readLogTail(handle.logHostPath, maxBytes: maxLogTailBytes)
                return LinuxGuestLocalServiceSnapshot(
                    state: "stopped",
                    pid: handle.pid,
                    alive: false,
                    stdout: tail.text,
                    truncated: tail.truncated,
                    logBytes: tail.bytes
                )
            }
            // Confirmed exit: drop the published port forward first so a dead
            // service is not reachable, then report the end exactly once.
            await host.guestRemoveForward(environmentID: handle.environmentID, forward: handle.forward)
            emitLifecycleEvent(handle: handle, reason: .processExited)
            let tail = Self.readLogTail(handle.logHostPath, maxBytes: maxLogTailBytes)
            return LinuxGuestLocalServiceSnapshot(
                state: "stopped",
                pid: handle.pid,
                alive: false,
                stdout: tail.text,
                truncated: tail.truncated,
                logBytes: tail.bytes
            )
        }
        let tail = Self.readLogTail(handle.logHostPath, maxBytes: maxLogTailBytes)
        return LinuxGuestLocalServiceSnapshot(
            state: "running",
            pid: handle.pid,
            alive: true,
            stdout: tail.text,
            truncated: tail.truncated,
            logBytes: tail.bytes
        )
    }

    public func stopLocalService(_ handle: LinuxGuestLocalServiceHandle) async {
        // Explicit stop: the handle only produces a lifecycle event when this
        // supervisor still owned it. Killing is still attempted for a handle
        // that was already released (idempotent guest KILL).
        let wasOwned = active.removeValue(forKey: handle.token) != nil
        if wasOwned {
            emitLifecycleEvent(handle: handle, reason: .hostStopRequested)
        }
        _ = try? await host.guestKillService(environmentID: handle.environmentID, pid: handle.pid, timeout: 15)
        await host.guestRemoveForward(environmentID: handle.environmentID, forward: handle.forward)
    }

    public func stopLocalServices(environmentID: String) async {
        // This is the environment-level stop: invalidate every in-flight start
        // for the environment FIRST (synchronously, before any await), then
        // wait for those starts to settle so their spawned processes and
        // forwards are cleaned up before the VM teardown runs. A start that
        // landed while this stop was already running captures the new epoch
        // and is expected to fail against the stopping guest on its own.
        serviceStartEpochs[environmentID, default: 0] &+= 1
        await waitForPendingServiceStarts(environmentID: environmentID)
        let owned = active.values.filter { $0.environmentID == environmentID }
        for handle in owned {
            await stopLocalService(handle)
        }
    }

    /// Called by the environment stop path after the VM is really gone.
    /// Any service start that still crossed the stop is invalidated, and a
    /// handle that managed to publish is released as an explicit host stop
    /// (the environment stop ended it), so no dead service is ever kept or
    /// alerted as an unexpected end.
    public func environmentDidStop(environmentID: String) async {
        serviceStartEpochs[environmentID, default: 0] &+= 1
        await waitForPendingServiceStarts(environmentID: environmentID)
        let owned = active.values.filter { $0.environmentID == environmentID }
        for handle in owned {
            await stopLocalService(handle)
        }
    }

    public func activeLocalServiceCount(environmentID: String) async -> Int {
        active.values.lazy.filter { $0.environmentID == environmentID }.count
    }

    /// Used on app teardown: every guest is about to be destroyed.
    public func stopAllLocalServices() async {
        for environmentID in Array(pendingServiceStarts.keys) {
            serviceStartEpochs[environmentID, default: 0] &+= 1
        }
        for environmentID in Array(pendingServiceStarts.keys) {
            await waitForPendingServiceStarts(environmentID: environmentID)
        }
        let owned = Array(active.values)
        for handle in owned {
            await stopLocalService(handle)
        }
    }

    /// `env KEY=VALUE …` prefix. Keys are validated so a hostile environment
    /// dictionary cannot smuggle argv/console framing.
    static func environmentArgv(_ variables: [String: String]) -> [String]? {
        LinuxGuestEnvironmentEncoding.argv(variables)
    }

    private struct LogTail {
        var text: String
        var bytes: Int64
        var truncated: Bool
    }

    /// Bounded tail read: the host sees the guest's appended log immediately
    /// because both sides use the same 9p file.
    private static func readLogTail(_ path: String, maxBytes: Int) -> LogTail {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return LogTail(text: "", bytes: 0, truncated: false)
        }
        defer { try? handle.close() }
        let size = Int64((try? handle.seekToEnd()) ?? 0)
        let start = max(0, size - Int64(maxBytes))
        try? handle.seek(toOffset: UInt64(start))
        let data = (try? handle.readToEnd()) ?? Data()
        let redacted = SecretRedactor.redact(String(decoding: data, as: UTF8.self))
        return LogTail(text: redacted, bytes: size, truncated: size > Int64(maxBytes))
    }
}
