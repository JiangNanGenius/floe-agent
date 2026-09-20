// FloeExecution — TinyEMU RV64 guest runtime (production Linux backend).
//
// Bridges the FloeTinyEMU C target (pinned TinyEMU 2019-12-21, interpreted
// RISC-V) into the Linux guest contract. The machine runs its slices on one
// dedicated thread; console input is queued through the adapter, console
// output arrives on a bounded AsyncStream. The engine links one process-wide
// slirp instance, so only one guest exists at a time (the registry enforces
// this) and no two VMs share the adapter thread pool.
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
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []
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
        self.running = true
        thread.start()
    }

    public func write(_ bytes: [UInt8]) async throws {
        guard !bytes.isEmpty else { return }
        let (machine, isRunning) = snapshotForConsoleWrite()
        guard isRunning, let machine else {
            throw LinuxGuestError.notRunning(environmentID: environmentID)
        }
        let queued = bytes.withUnsafeBufferPointer { buffer -> Int32 in
            floe_vm_console_input(machine, buffer.baseAddress, Int32(buffer.count))
        }
        guard queued > 0 else {
            throw LinuxGuestError.consoleUnavailable("the guest console rejected \(bytes.count) input bytes")
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
    public func stop() async {
        let thread = beginStop()

        if thread != nil {
            let didExit = await waitForRunLoopExit(timeout: 3)
            if !didExit {
                // Destroying a VM while a slice is executing would be a data
                // race; keeping the (already stopping) VM is the safe choice.
                FloeLogger(category: .tools).error(
                    "TinyEMU guest \(environmentID) run loop did not exit; VM not destroyed"
                )
                abandonRunThread()
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
        let (machine, isRunning) = snapshotForConsoleWrite()
        guard isRunning, let machine else {
            throw LinuxGuestError.notRunning(environmentID: environmentID)
        }
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
        // guest_ipv4 = 0 selects the guest's DHCP address (10.0.2.15).
        let result = floe_vm_hostfwd_add(
            machine,
            forward.isUDP ? 1 : 0,
            hostIPv4,
            Int32(forward.hostPort),
            0,
            Int32(forward.guestPort)
        )
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
        let (machine, _) = snapshotForConsoleWrite()
        guard let machine, let hostIPv4 = Self.hostByteOrderIPv4(forward.hostAddress) else { return }
        _ = floe_vm_hostfwd_remove(
            machine,
            forward.isUDP ? 1 : 0,
            hostIPv4,
            Int32(forward.hostPort)
        )
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

    private func snapshotForConsoleWrite() -> (OpaquePointer?, Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (vm, running)
    }

    private func beginStop() -> Thread? {
        lock.lock()
        defer { lock.unlock() }
        stopRequested = true
        return thread
    }

    private func abandonRunThread() {
        lock.lock()
        defer { lock.unlock() }
        thread = nil
        running = false
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
        let waiters = exitWaiters
        exitWaiters = []
        lock.unlock()
        for waiter in waiters { waiter.resume() }
    }

    /// Waits for the run loop to leave its last slice. The slice budget is
    /// 10 ms, so this resolves quickly; the timeout only guards an engine
    /// hang, in which case the VM is deliberately not destroyed.
    private func waitForRunLoopExit(timeout: TimeInterval) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await self.exitSignal(); return true }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    private func exitSignal() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if exited {
                lock.unlock()
                continuation.resume()
                return
            }
            exitWaiters.append(continuation)
            lock.unlock()
        }
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
