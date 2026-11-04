// ARM64GuestMachine.swift — the native Swift machine adapter for the
// embedded ARM64 C ABI (floe_arm64emu.h, ABI v2).
//
// Lifecycle contract implemented here:
//   * One worker thread owns create → slice loop → wait_event → destroy.
//     Slices are cooperative and <= 100 ms of host time; the slice reason is
//     honored (BUDGET continue, PARKED park until deadline/event, OUTPUT_FULL
//     wait for drain room, CANCELLED exit when the sticky stop is set,
//     GUEST_OFF/GUEST_FAULT terminal).
//   * Stop is sticky: request_stop is the engine's thread-safe wake and
//     interrupts native parking; the owner then awaits the actual worker
//     join before any resource closes. A new start can never race the old
//     stopped generation: every start takes a fresh generation and stale
//     operations/callbacks are fenced with .staleGeneration.
//   * Destroy is only ever called by the worker after the run loop has
//     exited; a BUSY from destroy is an engine invariant break and surfaces
//     as an error, never as success.
//   * Closing ONE console detaches only that channel (stream finished,
//     channel drained); the machine and its sibling channels keep running.
//     Actual shared-machine shutdown is explicit via stop().
//
// This class is the component boundary: self-contained (Foundation + the
// real C ABI module), no registry/factory wiring — the later cutover adds a
// session factory that constructs this machine behind the existing
// LinuxGuestSessionCreating seam.

import Foundation
import FloeARM64Engine

/// Exclusive right to run the process-wide single live machine. The engine
/// allows ONE live Machine; the token makes that ownership explicit in the
/// app service instead of a hidden static. Tests and future multi-slot
/// engines create their own tokens.
public struct ARM64MachineOwnership: Sendable {
    public let label: String
    public init(label: String) {
        self.label = label
    }
}

/// Published machine state for owners (registry/UI).
public enum ARM64MachineState: Sendable, Equatable {
    case idle
    case starting
    case running
    case stopping
    case stopped
    case failed(String)
}

/// Cumulative engine statistics snapshot (floe_ae_stats).
public struct ARM64MachineSnapshot: Sendable, Equatable {
    public var stateRaw: UInt32
    public var instructions: UInt64
    public var sliceCalls: UInt64
    public var parkWaits: UInt64
    public var wakeSequence: UInt64
    public var inputQueued: UInt64
    public var outputQueued: UInt64
    public var diagnosticsDropped: UInt64
    public var ramBytes: UInt64
    public var supportedVCPUs: UInt32
    public var activeSlice: UInt32
    public var lastError: Int32
    public var resetCount: UInt64
}

/// Network/device snapshot (floe_ae_net_info).
public struct ARM64NetworkSnapshot: Sendable, Equatable {
    public var networkEnabled: Bool
    public var dnsAvailable: Bool
    public var dnsServerIPv4: String?
    public var forwardCount: UInt32
    public var activeTCP: UInt32
    public var activeUDP: UInt32
    public var shareCount: UInt32
    public var consoleCount: UInt32
    public var rxFrames: UInt64
    public var txFrames: UInt64
    public var rxRefused: UInt64
}

/// Attach/detach state of one project share slot (floe_ae_share_info).
public enum ARM64ShareState: Sendable, Equatable {
    case detached
    case attached
    case draining
    case unknown(UInt32)
}

public struct ARM64ShareInfo: Sendable, Equatable {
    public var state: ARM64ShareState
    public var readOnly: Bool
    public var slot: UInt32
    public var generation: UInt32
    public var openFids: UInt32
    public var guestUID: UInt32
    public var guestGID: UInt32
    public var mountTag: String
}

/// Worker-exclusive progress. Cancellation is carried by ResumeOnce's lock;
/// offset and deadline are touched only between slices by the one worker.
private final class ARM64QueuedProgress: @unchecked Sendable {
    var started = false
    var offset = 0
    let deadline: Date
    init(timeout: TimeInterval) { deadline = Date().addingTimeInterval(timeout) }
}

public final class ARM64GuestMachine: @unchecked Sendable {
    /// Cooperative per-slice host budget: never above the 100 ms ABI bound.
    public static let sliceBudgetNanoseconds: UInt64 = 100_000_000
    /// Per-slice instruction budget (engine cap is 100M).
    public static let sliceBudgetInstructions: UInt64 = 20_000_000
    /// Maximum time stop() awaits the worker join before leaving the machine
    /// running (deliberately NOT destroying under a live slice).
    public var stopTimeout: TimeInterval = 10

    public let ownership: ARM64MachineOwnership
    private let config: ARM64MachineConfig
    private let headroomProbe: @Sendable () -> Int?

    private let stateLock = NSLock()
    private var stateValue: ARM64MachineState = .idle
    private var stopRequestedFlag = false
    private var workerThread: Thread?
    /// Monotonic start/stop generation; fences operations and callbacks.
    private var generation: UInt64 = 0
    private var workerExit: ARM64MachineExit?
    /// Live engine handle while the worker runs; only the worker writes it.
    private var engineHandle: floe_ae_handle = 0

    private let ioQueue = ARM64IOQueue()
    private var consoleTransports: [UInt32: ARM64ConsoleTransport] = [:]
    private var consoleEpochs: [UInt32: UInt64] = [:]
    private var consoleEventHandler: @Sendable (UInt32, ARM64ChannelEvent) -> Void = { _, _ in }
    private var diagnosticsEventHandler: @Sendable (ARM64DiagnosticTap.Event) -> Void = { _ in }
    private var diagnosticsTap: ARM64DiagnosticTap?

    public init(ownership: ARM64MachineOwnership, config: ARM64MachineConfig,
                headroomProbe: (@Sendable () -> Int?)? = nil) throws {
        self.ownership = ownership
        self.config = try config.validated()
        self.headroomProbe = headroomProbe ?? { RuntimeProcessHeadroom.availableBytes() }
    }

    private func checkHeadroom() throws {
        let required = RuntimeProcessHeadroom.requiredBytes(guestRAMMiB: config.ramMiB,
            hostOverheadMiB: 64, futureReserveMiB: 256)
        if let available = headroomProbe(), available < required {
            throw ARM64MachineError.createFailed(code: Int32(FLOE_AE_NOMEM),
                detail: "Not enough memory for the shared runtime; stop other work or choose less memory")
        }
    }

    // MARK: - State

    public var state: ARM64MachineState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stateValue
    }

    public var currentGeneration: UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return generation
    }

    /// Sticky stop; also delivered to the engine via request_stop so a
    /// parked worker wakes immediately.
    public func requestStop() {
        stateLock.lock()
        stopRequestedFlag = true
        let handle = engineHandle
        stateLock.unlock()
        guard handle != 0 else { return }
        // floe_ae_request_stop is documented thread-safe and wakes native
        // parking. A destroy racing this turn it into STALE — harmless,
        // the worker is already exiting.
        _ = floe_ae_request_stop(handle)
    }

    // MARK: - Worker entry

    /// Starts the worker thread. Idempotent while running; a fresh start
    /// after a confirmed stop/failure is a new generation.
    public func start() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        let allowed: Bool
        switch stateValue { case .idle, .stopped, .failed: allowed = true; default: allowed = false }
        guard allowed, engineHandle == 0, workerThread?.isFinished != false else {
            throw ARM64MachineError.engineBusy("start() requires idle/stopped/failed, got \(stateValue)")
        }
        try checkHeadroom()
        generation &+= 1
        let myGeneration = generation
        ioQueue.begin(generation: myGeneration)
        stopRequestedFlag = false
        workerExit = nil
        consoleTransports.removeAll(keepingCapacity: false)
        consoleEpochs.removeAll(keepingCapacity: false)
        diagnosticsTap = nil
        stateValue = .starting
        let thread = Thread { [self] in
            self.workerMain(generation: myGeneration)
        }
        thread.name = "floe.arm64.machine.\(ownership.label)"
        thread.stackSize = 1 * 1024 * 1024
        workerThread = thread
        thread.start()
    }

    /// Stops the machine: sticky stop, engine wake, await the ACTUAL worker
    /// join, then report the exit. On join timeout the machine is
    /// intentionally left running (destroying under a slice is the one
    /// outcome this adapter must never produce).
    @discardableResult
    public func stop() async -> ARM64StopOutcome {
        let initial = stateLock.withLock {
            stopRequestedFlag = true
            return (workerThread, engineHandle)
        }
        if initial.1 != 0 { _ = floe_ae_request_stop(initial.1) }
        guard let thread = initial.0 else { return .stopped(.stopped) }
        let deadline = Date().addingTimeInterval(stopTimeout)
        while !thread.isFinished, Date() < deadline {
            // A cancelled caller never spins or claims a completed join.
            if Task.isCancelled { return .timeoutStillRunning }
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard thread.isFinished else { return .timeoutStillRunning }
        return stateLock.withLock {
            guard engineHandle == 0 else { return .timeoutStillRunning }
            let exit = workerExit ?? .stopped
            workerThread = nil
            stateValue = .stopped
            return .stopped(exit)
        }
    }

    // MARK: - Consoles

    /// Per-channel event callback. The owner maps terminal events to closing
    /// THAT project/console; the machine never stops itself.
    public func setConsoleEventHandler(_ handler: @escaping @Sendable (UInt32, ARM64ChannelEvent) -> Void) {
        stateLock.lock()
        consoleEventHandler = handler
        let consoles = consoleTransports
        stateLock.unlock()
        for (channel, transport) in consoles {
            transport.setEventForwarder { event in handler(channel, event) }
        }
    }

    /// Returns the transport for one console channel (0 = PL011, 1...N =
    /// virtio-consoles). Available once the worker has created the machine.
    public func consoleTransport(channel: UInt32) throws -> ARM64ConsoleTransport {
        stateLock.lock()
        let transport = consoleTransports[channel]
        stateLock.unlock()
        guard let transport else {
            throw ARM64MachineError.channelUnavailable(channel)
        }
        return transport
    }

    /// Only the resident owner calls this after PROJCLOSE has acknowledged
    /// the previous runner's exit. Native and Swift buffered bytes are
    /// discarded together, and old transports can never enter the new slot.
    public func renewProjectConsole(channel: UInt32) async throws -> ARM64ConsoleTransport {
        guard channel >= 2 else { throw ARM64MachineError.channelUnavailable(channel) }
        return try await enqueueOperation { [self] handle, token in
            let code = floe_ae_channel_reset(handle, channel)
            guard code == FLOE_AE_OK else {
                token.resume(throwing: ARM64MachineError.engineBusy("channel_reset: \(ARM64EngineCode.name(code))")); return
            }
            let old = stateLock.withLock { consoleTransports[channel] }
            old?.machineStopped()
            let identity = stateLock.withLock {
                let epoch = (consoleEpochs[channel] ?? 0) &+ 1
                consoleEpochs[channel] = epoch
                return (generation, epoch)
            }
            let fresh = makeTransport(channel: channel, generation: identity.0, epoch: identity.1)
            stateLock.withLock { consoleTransports[channel] = fresh }
            token.resume(returning: fresh)
        }
    }

    /// Bounded diagnostics stream + honest dropped-diagnostic accounting.
    public func diagnostics() -> ARM64DiagnosticTap {
        stateLock.withLock {
        if let diagnosticsTap { return diagnosticsTap }
        let created = ARM64DiagnosticTap { [weak self] event in
            guard let self else { return }
            self.stateLock.lock()
            let handler = self.diagnosticsEventHandler
            self.stateLock.unlock()
            handler(event)
        }
        diagnosticsTap = created
        return created
        }
    }

    public func setDiagnosticsEventHandler(_ handler: @escaping @Sendable (ARM64DiagnosticTap.Event) -> Void) {
        stateLock.lock()
        diagnosticsEventHandler = handler
        stateLock.unlock()
    }

    // MARK: - Engine operations (queued between slices)

    /// Current cumulative snapshot; runs between slices on the worker.
    public func snapshot() async throws -> ARM64MachineSnapshot {
        try await enqueueOperation { handle, token in
            var stats = floe_ae_stats()
            memset(&stats, 0, MemoryLayout<floe_ae_stats>.size)
            stats.struct_size = UInt32(MemoryLayout<floe_ae_stats>.size)
            let code = floe_ae_get_stats(handle, &stats)
            guard code == FLOE_AE_OK else {
                token.resume(throwing: ARM64MachineError.engineBusy("get_stats: \(ARM64EngineCode.name(code))"))
                return
            }
            token.resume(returning: ARM64MachineSnapshot(
                stateRaw: stats.state,
                instructions: stats.instructions,
                sliceCalls: stats.slice_calls,
                parkWaits: stats.park_waits,
                wakeSequence: stats.wake_sequence,
                inputQueued: stats.input_queued,
                outputQueued: stats.output_queued,
                diagnosticsDropped: stats.diagnostic_dropped,
                ramBytes: stats.ram_bytes,
                supportedVCPUs: stats.supported_vcpus,
                activeSlice: stats.active_slice,
                lastError: stats.last_error,
                resetCount: stats.reset_count
            ))
        }
    }

    /// Network/device snapshot; runs between slices (kept ordered with
    /// forward add/remove by the same queue).
    public func networkSnapshot() async throws -> ARM64NetworkSnapshot {
        try await enqueueOperation { handle, token in
            var info = floe_ae_net_info()
            memset(&info, 0, MemoryLayout<floe_ae_net_info>.size)
            info.struct_size = UInt32(MemoryLayout<floe_ae_net_info>.size)
            let code = floe_ae_net_get_info(handle, &info)
            guard code == FLOE_AE_OK else {
                token.resume(throwing: ARM64MachineError.engineBusy("net_get_info: \(ARM64EngineCode.name(code))"))
                return
            }
            token.resume(returning: ARM64NetworkSnapshot(
                networkEnabled: info.network_enabled != 0,
                dnsAvailable: info.dns_available != 0,
                dnsServerIPv4: Self.dottedQuad(info.dns_server),
                forwardCount: info.forward_count,
                activeTCP: info.active_tcp,
                activeUDP: info.active_udp,
                shareCount: info.share_count,
                consoleCount: info.console_count,
                rxFrames: info.rx_frames,
                txFrames: info.tx_frames,
                rxRefused: info.rx_refused
            ))
        }
    }

    /// Real winsize push: the next guest-visible poll raises the virtio
    /// config-change interrupt; no SIGWINCH, no host terminal management.
    public func setWindowSize(channel: UInt32, cols: UInt16, rows: UInt16) async throws {
        let _: Void = try await enqueueOperation { handle, token in
            let code = floe_ae_channel_set_winsize(handle, channel, cols, rows)
            guard code == FLOE_AE_OK else {
                token.resume(throwing: ARM64MachineError.engineBusy("set_winsize: \(ARM64EngineCode.name(code))"))
                return
            }
            token.resume()
        }
    }

    /// Reads back the channel geometry the guest will observe.
    public func windowSize(channel: UInt32) async throws -> (cols: UInt16, rows: UInt16) {
        try await enqueueOperation { handle, token in
            var cols = UInt16(0)
            var rows = UInt16(0)
            let code = floe_ae_channel_get_winsize(handle, channel, &cols, &rows)
            guard code == FLOE_AE_OK else {
                token.resume(throwing: ARM64MachineError.engineBusy("get_winsize: \(ARM64EngineCode.name(code))"))
                return
            }
            token.resume(returning: (cols, rows))
        }
    }

    /// Live forward add (network must be enabled at create). Quiescence-gated
    /// by the frozen ABI: runs between slices on the worker, retries BUSY.
    /// Engine errors surface honestly: UNSUPPORTED (no device), IO (bind
    /// failure, e.g. EADDRINUSE), INVALID (bad rule).
    public func addForward(_ rule: ARM64NetForwardRule) async throws {
        try await enqueueOperationWithRetry { handle, token in
            var staged = floe_ae_net_forward()
            memset(&staged, 0, MemoryLayout<floe_ae_net_forward>.size)
            staged.struct_size = UInt32(MemoryLayout<floe_ae_net_forward>.size)
            staged.is_udp = rule.isUDP ? 1 : 0
            staged.host_port = rule.hostPort
            staged.guest_port = rule.guestPort
            let code = floe_ae_net_forward_add(handle, &staged)
            guard code == FLOE_AE_OK else {
                token.resume(throwing: ARM64MachineError.engineBusy("forward_add: \(ARM64EngineCode.name(code))"))
                return true // terminal: do not retry
            }
            token.resume()
            return true
        }
    }

    public func removeForward(isUDP: Bool, hostPort: UInt32) async throws {
        try await enqueueOperationWithRetry { handle, token in
            let code = floe_ae_net_forward_remove(handle, isUDP ? 1 : 0, hostPort)
            guard code == FLOE_AE_OK else {
                token.resume(throwing: ARM64MachineError.engineBusy("forward_remove: \(ARM64EngineCode.name(code))"))
                return true
            }
            token.resume()
            return true
        }
    }

    // MARK: - Live project-share lifecycle (frozen ABI)

    /// hvc0 is the supervisor control console (channel 1).
    public static let controlChannel: UInt32 = 1
    /// hvc(i+1) is project i's data console: channel = project + 2.
    public static func projectChannel(_ projectIndex: Int) -> UInt32 {
        UInt32(projectIndex) + 2
    }
    /// Project i uses share slot i (0...FLOE_AE_MAX_SHARES-1).
    public static func projectShareSlot(_ projectIndex: Int) -> UInt32 {
        UInt32(projectIndex)
    }

    /// Attaches a new host root to a share slot. Requires machine
    /// quiescence (guaranteed structurally: the op runs between slices) and
    /// retries FLOE_AE_BUSY. `mountTag` must equal the slot's fixed tag
    /// (create-time shares set it; an unconfigured slot's default is
    /// "floe-ws-<slot>"). Generation fences make every guest fid created
    /// under the previous root ESTALE on next use.
    public func attachShare(
        slot: UInt32,
        hostPath: String,
        mountTag: String,
        readOnly: Bool,
        guestUID: UInt32 = 0,
        guestGID: UInt32 = 0
    ) async throws {
        try await enqueueOperationWithRetry { handle, token in
            var staged = floe_ae_share_config()
            memset(&staged, 0, MemoryLayout<floe_ae_share_config>.size)
            staged.struct_size = UInt32(MemoryLayout<floe_ae_share_config>.size)
            let path = hostPath
            let tag = mountTag
            return path.withCString { pathPointer in
                tag.withCString { tagPointer in
                    staged.host_path = pathPointer
                    staged.mount_tag = tagPointer
                    staged.read_only = readOnly ? 1 : 0
                    staged.guest_uid = guestUID
                    staged.guest_gid = guestGID
                    let code = floe_ae_share_attach(handle, slot, &staged)
                    if code == FLOE_AE_BUSY {
                        return false // quiescence race: retry between slices
                    }
                    guard code == FLOE_AE_OK else {
                        token.resume(throwing: ARM64MachineError.engineBusy(
                            "share_attach slot \(slot): \(ARM64EngineCode.name(code))"
                        ))
                        return true
                    }
                    token.resume()
                    return true
                }
            }
        }
    }

    /// Detaches a share slot. Without force, refuses BUSY while the guest
    /// holds open host handles (retry surfaces to the caller as an honest
    /// engineBusy). With force, the engine drains immediately: handles
    /// close, fids invalidate, the guest sees ESTALE/ENODEV afterwards.
    public func detachShare(slot: UInt32, force: Bool) async throws {
        try await enqueueOperationWithRetry { handle, token in
            let code = floe_ae_share_detach(handle, slot, force ? UInt32(FLOE_AE_SHARE_FORCE) : 0)
            if code == FLOE_AE_BUSY && !force {
                return false // guest holds open handles: one bounded retry round
            }
            guard code == FLOE_AE_OK else {
                token.resume(throwing: ARM64MachineError.engineBusy(
                    "share_detach slot \(slot): \(ARM64EngineCode.name(code))"
                ))
                return true
            }
            token.resume()
            return true
        }
    }

    /// Read-only share slot snapshot; safe anytime, still queued so it
    /// observes a consistent point between slices.
    public func shareInfo(slot: UInt32) async throws -> ARM64ShareInfo {
        try await enqueueOperation { handle, token in
            var info = floe_ae_share_info()
            memset(&info, 0, MemoryLayout<floe_ae_share_info>.size)
            info.struct_size = UInt32(MemoryLayout<floe_ae_share_info>.size)
            let code = floe_ae_share_get_info(handle, slot, &info)
            guard code == FLOE_AE_OK else {
                token.resume(throwing: ARM64MachineError.engineBusy(
                    "share_get_info slot \(slot): \(ARM64EngineCode.name(code))"
                ))
                return
            }
            let state: ARM64ShareState
            switch info.state {
            case UInt32(FLOE_AE_SHARE_DETACHED): state = .detached
            case UInt32(FLOE_AE_SHARE_ATTACHED): state = .attached
            case UInt32(FLOE_AE_SHARE_DRAINING): state = .draining
            default: state = .unknown(info.state)
            }
            let tag = withUnsafePointer(to: &info.mount_tag) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: 128) {
                    String(cString: $0)
                }
            }
            token.resume(returning: ARM64ShareInfo(
                state: state,
                readOnly: info.read_only != 0,
                slot: info.slot,
                generation: info.generation,
                openFids: info.open_fids,
                guestUID: info.guest_uid,
                guestGID: info.guest_gid,
                mountTag: tag
            ))
        }
    }

    /// Enqueues a whole-frame console write for one channel. The worker runs
    /// the partial-accept retention loop between slices; a stop/detach/
    /// cancellation fences the remainder (never executed later).
    func enqueueConsoleWrite(
        channel: UInt32, bytes: [UInt8], generation myGeneration: UInt64, consoleEpoch: UInt64,
        deadline: TimeInterval, token: ResumeOnce<Void>
    ) {
        let progress = ARM64QueuedProgress(timeout: deadline)
        ioQueue.enqueue(ARM64IOOperation(generation: myGeneration, lane: channel,
            fail: { token.resume(throwing: $0) }) { [self] handle in
            guard stateLock.withLock({ consoleEpochs[channel] == consoleEpoch }) else {
                token.resume(throwing: ARM64MachineError.staleGeneration); return true
            }
            if token.isCancelled {
                if progress.offset > 0 { consoleTransports[channel]?.inputFailed() }
                return true
            }
            if !progress.started { guard token.claim() else { return true }; progress.started = true }
            guard isCurrentGeneration(myGeneration) else { token.resume(throwing: ARM64MachineError.staleGeneration); return true }
            guard !stopRequested(), Date() < progress.deadline else {
                if progress.offset > 0 { consoleTransports[channel]?.inputFailed() }
                token.resume(throwing: ARM64MachineError.writeIncomplete(channel: channel, accepted: progress.offset, requested: bytes.count))
                return true
            }
            var accepted = 0
            let code = bytes.withUnsafeBufferPointer { buffer in
                floe_ae_channel_write(handle, channel, buffer.baseAddress!.advanced(by: progress.offset), bytes.count - progress.offset, &accepted)
            }
            guard code == FLOE_AE_OK else { token.resume(throwing: ARM64MachineError.engineBusy("channel_write: \(ARM64EngineCode.name(code))")); return true }
            progress.offset += accepted
            if progress.offset == bytes.count { token.resume(); return true }
            // Ring full: yield to a guest slice before retaining the remainder.
            return false
        })
        notifyWorker()
    }

    private func enqueueOperation<T: Sendable>(
        _ body: @escaping @Sendable (floe_ae_handle, ResumeOnce<T>) -> Void
    ) async throws -> T {
        try Task.checkCancellation()
        let myGeneration = currentGeneration
        guard isCurrentGeneration(myGeneration) else { throw ARM64MachineError.notRunning }
        let token = ResumeOnce<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                token.attach(continuation)
                ioQueue.enqueue(ARM64IOOperation(generation: myGeneration,
                    fail: { token.resume(throwing: $0) }) { handle in
                    guard token.claim() else { return true }
                    body(handle, token)
                    return true
                })
                notifyWorker()
            }
        } onCancel: { token.cancel(throwing: CancellationError()); self.notifyWorker() }
    }

    // Device mutations run at a quiescent point. BUSY here means an owned
    // resource (e.g. a mounted share), not a concurrent slice: the lifecycle
    // owner must reconcile it before explicitly retrying.
    private func enqueueOperationWithRetry(
        _ body: @escaping @Sendable (floe_ae_handle, ResumeOnce<Void>) -> Bool
    ) async throws {
        try await enqueueOperation { handle, token in
            if !body(handle, token) {
                token.resume(throwing: ARM64MachineError.engineBusy("resource is still in use"))
            }
        }
    }

    private func notifyWorker() {
        let handle = stateLock.withLock { engineHandle }
        if handle != 0 { _ = floe_ae_notify(handle) }
    }

    private func isCurrentGeneration(_ value: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return value == generation && (stateValue == .running || stateValue == .starting)
    }

    // MARK: - Worker

    private func workerMain(generation myGeneration: UInt64) {
        var exit: ARM64MachineExit = .stopped
        do {
            try config.verifyAssetDigests()
            if stopRequested() { throw ARM64MachineError.notRunning }
            let staged = ARM64StagedConfig(config)
            var handle: floe_ae_handle = 0
            var configCopy = staged.cConfig
            // Asset verification can take time. Recheck at the actual native
            // allocation boundary, including a real zero on physical devices.
            try checkHeadroom()
            let createCode = withExtendedLifetime(staged) {
                withUnsafePointer(to: &configCopy) { pointer in
                    pointer.withMemoryRebound(to: floe_ae_config.self, capacity: 1) { base in
                        floe_ae_create(base, &handle)
                    }
                }
            }
            guard createCode == FLOE_AE_OK else {
                throw ARM64MachineError.createFailed(
                    code: createCode,
                    detail: "floe_ae_create refused the staged config (one live machine per process is engine-enforced)"
                )
            }
            stateLock.lock()
            engineHandle = handle
            stateLock.unlock()
            installConsoles(handle: handle, generation: myGeneration)
            stateLock.withLock { stateValue = .running }

            exit = runSliceLoop(handle: handle, generation: myGeneration)

            let destroyCode = floe_ae_destroy(handle)
            if destroyCode != FLOE_AE_OK && destroyCode != FLOE_AE_STALE {
                // BUSY here means the engine saw activity after the run loop
                // exited — an invariant break, reported, never success.
                stateLock.lock()
                stateValue = .failed("destroy: \(ARM64EngineCode.name(destroyCode))")
                workerExit = .guestFault(destroyCode)
                stateLock.unlock()
                exit = .guestFault(destroyCode)
            } else {
                stateLock.withLock { engineHandle = 0 }
            }
        } catch let error as ARM64MachineError {
            stateLock.lock()
            if case .createFailed(let code, _) = error {
                exit = .createFailed(code: code)
            }
            stateValue = .failed("\(error)")
            stateLock.unlock()
        } catch {
            stateLock.lock()
            stateValue = .failed("\(error)")
            stateLock.unlock()
        }
        stateLock.lock()
        workerExit = exit
        if stateValue == .running || stateValue == .starting { stateValue = .stopped }
        let consoles = Array(consoleTransports.values)
        let tap = diagnosticsTap
        stateLock.unlock()
        ioQueue.failAll(ARM64MachineError.notRunning)
        for transport in consoles { transport.machineStopped() }
        tap?.machineStopped()
    }

    /// The cooperative slice loop. Only this worker ever calls run_slice or
    /// wait_event for the handle.
    private func runSliceLoop(handle: floe_ae_handle, generation myGeneration: UInt64) -> ARM64MachineExit {
        var wakeSequence: UInt64 = 0
        while true {
            if stopRequested() { return .stopped }

            var slice = floe_ae_slice()
            memset(&slice, 0, MemoryLayout<floe_ae_slice>.size)
            slice.struct_size = UInt32(MemoryLayout<floe_ae_slice>.size)
            let code = floe_ae_run_slice(
                handle,
                Self.sliceBudgetNanoseconds,
                Self.sliceBudgetInstructions,
                &slice
            )
            wakeSequence = slice.wake_sequence
            if code != FLOE_AE_OK {
                // Engine-level fault: FAULT return ↔ FAILED state.
                return .guestFault(code)
            }

            drainConsoles(handle: handle, generation: myGeneration)
            drainDiagnostics(handle: handle, generation: myGeneration)
            runQueuedOperations(handle: handle, generation: myGeneration)

            switch slice.reason {
            case UInt32(FLOE_AE_BUDGET):
                continue
            case UInt32(FLOE_AE_PARKED):
                if stopRequested() { return .stopped }
                var newSequence: UInt64 = 0
                _ = floe_ae_wait_event(
                    handle,
                    wakeSequence,
                    parkWaitNanoseconds(deadline: slice.next_deadline_ns),
                    &newSequence
                )
            case UInt32(FLOE_AE_OUTPUT_FULL):
                // Output rings full: the drains above just made room; park
                // briefly to avoid a busy spin. A terminated consumer has
                // already surfaced through its owner callback.
                if stopRequested() { return .stopped }
                continue
            case UInt32(FLOE_AE_CANCELLED):
                // Engine consumed the sticky stop.
                return .stopped
            case UInt32(FLOE_AE_GUEST_OFF):
                return .guestPoweredOff
            case UInt32(FLOE_AE_GUEST_FAULT):
                return .guestFault(slice.state == UInt32(FLOE_AE_FAILED) ? Int32(FLOE_AE_FAULT) : 0)
            default:
                continue
            }
        }
    }

    /// Parked wait bounded by the engine's own next deadline (never above
    /// the 60 s ABI cap). UINT64_MAX means no timer — use the cap so stop
    /// latency and op latency stay bounded.
    private func parkWaitNanoseconds(deadline: UInt64) -> UInt64 {
        guard deadline != UInt64.max else { return 60_000_000_000 }
        return min(deadline, 60_000_000_000)
    }

    private func stopRequested() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopRequestedFlag
    }

    // MARK: - Consoles + diagnostics (worker side)

    private func installConsoles(handle: floe_ae_handle, generation myGeneration: UInt64) {
        var count: UInt32 = 0
        guard floe_ae_channel_count(handle, &count) == FLOE_AE_OK, count > 0 else { return }
        for channel in 0..<count {
            let transport = makeTransport(channel: channel, generation: myGeneration, epoch: 1)
            stateLock.withLock {
                consoleEpochs[channel] = 1
                consoleTransports[channel] = transport
            }
        }
    }

    private func makeTransport(channel: UInt32, generation myGeneration: UInt64, epoch: UInt64) -> ARM64ConsoleTransport {
            let forwarder: @Sendable (ARM64ChannelEvent) -> Void = { [weak self] event in
                guard let self, self.currentGeneration == myGeneration,
                      self.stateLock.withLock({ self.consoleEpochs[channel] == epoch }) else { return }
                self.stateLock.lock()
                let handler = self.consoleEventHandler
                self.stateLock.unlock()
                handler(channel, event)
            }
            let transport = ARM64ConsoleTransport(
                channel: channel,
                enqueueWrite: { [weak self] bytes, generation, deadline, token in
                    guard let self else {
                        token.resume(throwing: ARM64MachineError.notRunning)
                        return
                    }
                    self.enqueueConsoleWrite(
                        channel: channel,
                        bytes: bytes,
                        generation: generation,
                        consoleEpoch: epoch,
                        deadline: deadline,
                        token: token
                    )
                },
                currentGeneration: { myGeneration },
                isMachineRunning: { [weak self] in
                    guard let self else { return false }
                    self.stateLock.lock()
                    defer { self.stateLock.unlock() }
                    return self.stateValue == .running && self.generation == myGeneration
                        && self.consoleEpochs[channel] == epoch
                },
                wakeWorker: { [weak self] in
                    guard let self, self.currentGeneration == myGeneration else { return }
                    self.notifyWorker()
                },
                onEvent: forwarder
            )
            return transport
    }

    /// Between-slice drain for every live console. Each channel reads at most
    /// what its consumer-side buffer can take, INDEPENDENTLY: a full channel
    /// A is skipped (its bytes stay in the engine ring) while channel B
    /// drains normally.
    private func drainConsoles(handle: floe_ae_handle, generation myGeneration: UInt64) {
        stateLock.lock()
        let transports = consoleTransports
        stateLock.unlock()
        for (channel, transport) in transports.sorted(by: { $0.key < $1.key }) {
            guard transport.beginNativeDrain(generation: myGeneration) else { continue }
            let chunkSize = transport.preferredReadChunk
            var buffer = [UInt8](repeating: 0, count: chunkSize)
            var totalRead = 0
            while transport.hasConsumerCapacity {
                var readCount = 0
                let code = buffer.withUnsafeMutableBufferPointer { pointer in
                    floe_ae_channel_read(
                        handle,
                        channel,
                        pointer.baseAddress,
                        pointer.count,
                        &readCount
                    )
                }
                guard code == FLOE_AE_OK, readCount > 0 else { break }
                transport.appendNativeBytes(Data(buffer[0..<readCount]), generation: myGeneration)
                totalRead += readCount
                if readCount < chunkSize { break }
            }
            transport.endNativeDrain(totalBytes: totalRead)
        }
    }

    private func drainDiagnostics(handle: floe_ae_handle, generation myGeneration: UInt64) {
        guard let tap = stateLock.withLock({ diagnosticsTap }),
              tap.beginNativeDrain(generation: myGeneration) else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while tap.hasConsumerCapacity {
            var readCount = 0
            let code = buffer.withUnsafeMutableBufferPointer { pointer in
                floe_ae_diagnostic_read(handle, pointer.baseAddress, pointer.count, &readCount)
            }
            guard code == FLOE_AE_OK, readCount > 0 else { break }
            tap.appendNativeBytes(Data(buffer[0..<readCount]), generation: myGeneration)
        }
        var stats = floe_ae_stats()
        stats.struct_size = UInt32(MemoryLayout<floe_ae_stats>.size)
        if floe_ae_get_stats(handle, &stats) == FLOE_AE_OK {
            tap.endNativeDrain(engineDroppedDelta: tap.observeEngineDropped(stats.diagnostic_dropped))
        }
    }

    private func runQueuedOperations(handle: floe_ae_handle, generation myGeneration: UInt64) {
        var pending: [ARM64IOOperation] = []
        var blockedLanes = Set<UInt32>()
        for operation in ioQueue.drain() {
            guard operation.generation == myGeneration else {
                operation.fail(ARM64MachineError.staleGeneration); ioQueue.completed(); continue
            }
            if let lane = operation.lane, blockedLanes.contains(lane) { pending.append(operation); continue }
            if !operation.step(handle) {
                pending.append(operation)
                if let lane = operation.lane { blockedLanes.insert(lane) }
            } else { ioQueue.completed() }
        }
        ioQueue.prepend(pending)
    }

    // MARK: - Helpers

    static func dottedQuad(_ hostOrder: UInt32) -> String? {
        guard hostOrder != 0 else { return nil }
        return "\(hostOrder >> 24 & 0xFF).\(hostOrder >> 16 & 0xFF).\(hostOrder >> 8 & 0xFF).\(hostOrder & 0xFF)"
    }
}
