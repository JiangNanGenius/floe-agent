// FloeExecution — TinyEMU RV64 guest runtime (production Linux backend).
//
// Bridges the FloeTinyEMU C target (pinned TinyEMU 2019-12-21, interpreted
// RISC-V) into the Linux guest contract. The machine runs its slices on one
// dedicated thread; console input is queued through the adapter, console
// output arrives on a bounded AsyncStream. Engine patch 0006 made slirp
// per-instance state explicit: each guest gets its own slirp instance, so
// multiple guests run concurrently (bounded by the registry's admission
// reservations) and one stuck guest never blocks another's stop, timeout
// or cancellation.
//
// 9p shares are passed straight to FloeVMConfig.shares; the guest mounts them
// by tag. Host→guest forwarding uses the adapter's slirp hostfwd API
// (floe_vm_hostfwd_add/remove, pinned adapter revision aeccdf1b) so a guest
// localService port becomes reachable on the host loopback address.

import Foundation
import FloeCore
import FloeTools

#if canImport(FloeTinyEMU)
import FloeTinyEMU

/// Console output sink reachable from the C callback. The AsyncStream
/// continuation is thread-safe; the stream is bounded so a guest that floods
/// the console cannot grow host memory without bound.
final class TinyEMUConsoleSink: @unchecked Sendable {
    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var finished = false

    init(continuation: AsyncStream<Data>.Continuation) {
        self.continuation = continuation
    }

    func append(_ data: Data) {
        lock.lock()
        let isFinished = finished
        lock.unlock()
        guard !isFinished else { return }
        continuation.yield(data)
    }

    func finish() {
        lock.lock()
        let wasFinished = finished
        finished = true
        lock.unlock()
        guard !wasFinished else { return }
        continuation.finish()
    }
}

/// Carries the VM pointer across the run thread's @Sendable closure.
private final class TinyEMUVMHandle: @unchecked Sendable {
    let pointer: OpaquePointer
    init(_ pointer: OpaquePointer) { self.pointer = pointer }
}

/// One running TinyEMU guest. `start()` creates the VM and its run thread;
/// `stop()` requests the run loop to end, waits for it, then destroys the VM.
public final class TinyEMUGuestMachine: LinuxGuestConsoleTransport, @unchecked Sendable {
    public static let consoleChunkLimit = 256
    /// How long `stop()` waits for the run loop to leave its last slice
    /// before refusing to destroy the VM. Internal so focused lifecycle
    /// checks can shorten it; production keeps the 10 s bound.
    var runLoopExitTimeout: TimeInterval = 10

    /// How long `write()` retries a full input ring before failing the write.
    /// Internal so focused lifecycle checks can shorten it; production keeps
    /// the 30 s bound.
    var consoleInputDeadline: TimeInterval = 30

    /// Default guest console: hvc0 with the Floe guest runner as init target.
    /// The image manifest may override this; `effectiveCmdline` appends the
    /// runner init when the manifest does not name one, so a verified image
    /// always enters the FLOE-EXEC channel.
    public static let defaultCmdline = "console=hvc0 root=/dev/vda rw loglevel=4 init=" + LinuxGuestImage.runnerGuestPath

    public let environmentID: String
    private let image: LinuxGuestImage
    private let descriptor: LinuxGuestEnvironmentDescriptor
    private let ramMB: Int
    private let consoleStream: AsyncStream<Data>
    private let sink: TinyEMUConsoleSink
    private let lock = NSLock()
    private var exited = false
    private var vm: OpaquePointer?
    private var thread: Thread?
    private var stopRequested = false
    private var running = false

    init(
        descriptor: LinuxGuestEnvironmentDescriptor,
        image: LinuxGuestImage,
        limits: LinuxGuestLimits
    ) throws {
        self.environmentID = descriptor.id
        self.descriptor = descriptor
        self.image = image
        self.ramMB = limits.clampedRAMMB(descriptor.ramMB)
        var continuation: AsyncStream<Data>.Continuation!
        self.consoleStream = AsyncStream(bufferingPolicy: .bufferingNewest(Self.consoleChunkLimit)) {
            continuation = $0
        }
        self.sink = TinyEMUConsoleSink(continuation: continuation)
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    /// Creates the VM and starts the run loop thread. Idempotent while the
    /// guest is running.
    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard vm == nil else { return }

        let sharePlan = Array(descriptor.shares.prefix(Int(FLOE_VM_MAX_SHARES)))
        guard sharePlan.allSatisfy({ FileManager.default.fileExists(atPath: $0.hostDirectory.path) }) else {
            throw LinuxGuestError.invalidConfiguration("every 9p share host directory must exist")
        }

        var cStrings: [UnsafeMutablePointer<CChar>?] = []
        for share in sharePlan {
            cStrings.append(strdup(share.tag))
            cStrings.append(strdup(share.hostDirectory.path))
        }
        defer { for pointer in cStrings { free(pointer) } }

        var config = FloeVMConfig()
        config.ram_mb = UInt64(ramMB)
        config.disk_rw = image.diskReadWrite ? 1 : 0
        config.net_enable = descriptor.networkEnabled ? 1 : 0
        config.share_count = Int32(sharePlan.count)
        withUnsafeMutablePointer(to: &config.shares) { pointer in
            pointer.withMemoryRebound(to: FloeVMShare.self, capacity: Int(FLOE_VM_MAX_SHARES)) { shares in
                for index in 0..<sharePlan.count {
                    shares[index].tag = UnsafePointer(cStrings[index * 2])
                    shares[index].host_dir = UnsafePointer(cStrings[index * 2 + 1])
                }
            }
        }

        let created: OpaquePointer? = Self.withOptionalCString(image.biosPath) { bios in
            Self.withOptionalCString(image.kernelPath) { kernel in
                Self.withOptionalCString(image.initrdPath) { initrd in
                    Self.withOptionalCString(image.diskPath) { disk in
                        Self.withOptionalCString(image.effectiveCmdline) { cmdline in
                            var local = config
                            local.bios_path = bios
                            local.kernel_path = kernel
                            local.initrd_path = initrd
                            local.disk_path = disk
                            local.cmdline = cmdline
                            return floe_vm_create(
                                &local,
                                Self.consoleCallback,
                                Unmanaged.passUnretained(sink).toOpaque()
                            )
                        }
                    }
                }
            }
        }
        guard let created else {
            throw LinuxGuestError.startFailed("floe_vm_create returned NULL; see engine diagnostics")
        }

        let handle = TinyEMUVMHandle(created)
        let thread = Thread { [self] in
            runLoop(handle.pointer)
        }
        thread.name = "floe.tinyemu.guest"
        thread.stackSize = 512 * 1024
        self.vm = created
        self.thread = thread
        self.stopRequested = false
        // Reset the whole lifecycle: a restarted machine must never let a
        // later stop() observe the previous run's exit flag and destroy a VM
        // whose run thread is still executing.
        self.exited = false
        self.running = true
        thread.start()
    }

    /// Writes the whole frame or throws. `floe_vm_console_input` queues as
    /// many bytes as fit in the engine's 64 KiB input ring and returns that
    /// count ("ring full: drop remainder, caller may retry"), so a partial
    /// accept must be retried until every byte is queued: accepting a prefix
    /// and returning would leave a frame's tail to be delivered after other
    /// writers' bytes, corrupting the guest's line framing. The pointer is
    /// used while the lock is held, so stop()/destroy cannot free the VM
    /// between reading the pointer and the C call.
    public func write(_ bytes: [UInt8]) async throws {
        guard !bytes.isEmpty else { return }
        let deadline = ContinuousClock.now.advanced(by: .seconds(consoleInputDeadline))
        var offset = 0
        while offset < bytes.count {
            let queued = withRunningMachine { machine -> Int32 in
                bytes.withUnsafeBufferPointer { buffer in
                    floe_vm_console_input(
                        machine,
                        buffer.baseAddress!.advanced(by: offset),
                        Int32(bytes.count - offset)
                    )
                }
            }
            guard let queued else {
                throw LinuxGuestError.notRunning(environmentID: environmentID)
            }
            guard queued >= 0 else {
                throw LinuxGuestError.consoleUnavailable("the guest console rejected \(bytes.count - offset) input bytes")
            }
            if queued > 0 {
                offset += min(Int(queued), bytes.count - offset)
                continue
            }
            // Ring full: the guest drains it during run slices. Retry with a
            // finite deadline instead of silently truncating the frame.
            guard ContinuousClock.now < deadline else {
                throw LinuxGuestError.consoleUnavailable(
                    "guest console input queue stayed full for \(Int(consoleInputDeadline))s; refusing to truncate a \(bytes.count) byte frame"
                )
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    public func output() async -> AsyncStream<Data> {
        consoleStream
    }

    public func close() async {
        await stop()
        sink.finish()
    }

    /// Stops the run loop and destroys the VM. Safe to call repeatedly.
    /// Truthful: `isRunning` stays true until the run thread has left its
    /// last slice; only then is the VM destroyed and the state cleared, so a
    /// later start() always boots from the (preserved) disk, never from a
    /// half-stopped machine.
    public func stop() async {
        let thread = beginStop()

        if thread != nil {
            let timeout = runLoopExitTimeout
            let didExit = await waitForRunLoopExit(timeout: timeout)
            if !didExit {
                // Destroying a VM while a slice is executing would be a data
                // race; keeping the (already stopping) VM is the safe
                // choice. State is reported honestly: isRunning stays true
                // and the owner must reset the whole registry session.
                FloeLogger(category: .tools).error(
                    "TinyEMU guest \(environmentID) run loop did not exit within \(Int(timeout))s; VM not destroyed (state: still running)"
                )
                return
            }
        }

        if let machine = finishStop() {
            floe_vm_destroy(machine)
        }
    }

    // MARK: host→guest service forwarding

    /// Registers a host→guest TCP/UDP forward through slirp. The adapter
    /// removes every forward registered by this VM when it is destroyed.
    public func addForward(_ forward: LinuxGuestServiceForward) throws {
        guard descriptor.networkEnabled else {
            throw LinuxGuestError.serviceForwardingUnavailable(
                "guest \(environmentID) was started without networking; host forwarding needs slirp"
            )
        }
        guard let hostIPv4 = Self.hostByteOrderIPv4(forward.hostAddress) else {
            throw LinuxGuestError.invalidConfiguration(
                "host address must be a dotted IPv4 address, got '\(forward.hostAddress)'"
            )
        }
        // guest_ipv4 = 0 selects the guest's DHCP address (10.0.2.15). The
        // pointer is used under the lock so it cannot be destroyed midway.
        let result = withRunningMachine { machine -> Int32 in
            floe_vm_hostfwd_add(
                machine,
                forward.isUDP ? 1 : 0,
                hostIPv4,
                Int32(forward.hostPort),
                0,
                Int32(forward.guestPort)
            )
        }
        guard let result else {
            throw LinuxGuestError.notRunning(environmentID: environmentID)
        }
        guard result == 0 else {
            throw LinuxGuestError.serviceForwardingUnavailable(
                "the engine rejected \(forward.hostAddress):\(forward.hostPort) → guest port \(forward.guestPort)"
            )
        }
        FloeLogger(category: .tools).info(
            "Linux guest forward \(forward.hostAddress):\(forward.hostPort) → guest \(forward.guestPort) udp=\(forward.isUDP)"
        )
    }

    public func removeForward(_ forward: LinuxGuestServiceForward) throws {
        guard let hostIPv4 = Self.hostByteOrderIPv4(forward.hostAddress) else { return }
        withRunningMachine { machine in
            _ = floe_vm_hostfwd_remove(
                machine,
                forward.isUDP ? 1 : 0,
                hostIPv4,
                Int32(forward.hostPort)
            )
        }
    }

    /// slirp takes IPv4 addresses in host byte order (127.0.0.1 = 0x7F000001).
    static func hostByteOrderIPv4(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".").map(String.init)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard let octet = UInt32(part), octet <= 255 else { return nil }
            value = (value << 8) | octet
        }
        return value
    }

    /// Runs `body` with the live VM pointer while the lock is held, so
    /// `finishStop()` can never destroy the VM between the pointer read and
    /// the C call. Returns nil when the machine is not running.
    private func withRunningMachine<T>(_ body: (OpaquePointer) throws -> T) rethrows -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard running, let machine = vm else { return nil }
        return try body(machine)
    }

    private func beginStop() -> Thread? {
        lock.lock()
        defer { lock.unlock() }
        stopRequested = true
        return thread
    }

    private func finishStop() -> OpaquePointer? {
        lock.lock()
        defer { lock.unlock() }
        let machine = vm
        vm = nil
        thread = nil
        running = false
        return machine
    }

    private func runLoop(_ machine: OpaquePointer) {
        while true {
            lock.lock()
            let stop = stopRequested
            lock.unlock()
            if stop { break }
            let result = floe_vm_run_slice(machine, 10)
            if result != 0 { break }
        }
        lock.lock()
        running = false
        exited = true
        lock.unlock()
    }

    /// Waits for the run loop to leave its last slice. The slice budget is
    /// 10 ms, so this resolves quickly; the timeout only guards an engine
    /// hang, in which case the VM is deliberately not destroyed.
    ///
    /// Deliberately a bounded poll instead of a continuation race: a task
    /// group that awaited a checked continuation here could not be cancelled
    /// by the losing sleep branch (the continuation is only resumed by the
    /// run loop), so a timeout used to leave the stop path hanging forever.
    /// Polling the exit flag is cancellation-safe and can never outlive the
    /// deadline by more than one sleep quantum.
    private func waitForRunLoopExit(timeout: TimeInterval) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while true {
            if hasExited() { return true }
            if ContinuousClock.now >= deadline { return false }
            do {
                try await Task.sleep(for: .milliseconds(5))
            } catch {
                // Cancelled: return the truthful state immediately instead of
                // spinning through the remaining deadline (a cancelled
                // Task.sleep returns instantly, so `try?` would busy-loop).
                return hasExited()
            }
        }
    }

    /// Synchronous helper: NSLock must not be taken directly in an async
    /// context.
    private func hasExited() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return exited
    }

    private static func withOptionalCString<R>(
        _ string: String?,
        _ body: (UnsafePointer<CChar>?) throws -> R
    ) rethrows -> R {
        guard let string else { return try body(nil) }
        return try string.withCString(body)
    }

    private static let consoleCallback: FloeVMConsoleOutFn = { opaque, data, length in
        guard let opaque, let data, length > 0 else { return }
        let sink = Unmanaged<TinyEMUConsoleSink>.fromOpaque(opaque).takeUnretainedValue()
        sink.append(Data(bytes: data, count: Int(length)))
    }
}

/// Production session factory: creates the machine and hands back the
/// lifecycle closures the registry uses.
public struct TinyEMUGuestSessionFactory: Sendable {
    public init() {}

    public func makeSession(
        descriptor: LinuxGuestEnvironmentDescriptor,
        image: LinuxGuestImage,
        limits: LinuxGuestLimits
    ) throws -> LinuxGuestSessionHandle {
        let machine = try TinyEMUGuestMachine(descriptor: descriptor, image: image, limits: limits)
        return LinuxGuestSessionHandle(
            transport: machine,
            start: { try machine.start() },
            stop: { await machine.stop() },
            close: { await machine.close() },
            isRunning: { machine.isRunning },
            addForward: { try machine.addForward($0) },
            removeForward: { try machine.removeForward($0) }
        )
    }
}

#else

/// Platforms without the vendored engine cannot run a guest; ownership and
/// commands still fail honestly instead of reporting a fake Linux runtime.
public struct TinyEMUGuestSessionFactory: Sendable {
    public init() {}

    public func makeSession(
        descriptor: LinuxGuestEnvironmentDescriptor,
        image: LinuxGuestImage,
        limits: LinuxGuestLimits
    ) throws -> LinuxGuestSessionHandle {
        throw LinuxGuestError.consoleUnavailable("this platform does not build the FloeTinyEMU engine")
    }
}

#endif
