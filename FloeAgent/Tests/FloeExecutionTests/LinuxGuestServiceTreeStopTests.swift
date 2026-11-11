import Foundation
import XCTest
import FloeCore
import FloeTools
@testable import FloeExecution

/// Real channel framing over a deterministic producer. No Linux VM starts.
private final class TreeStopConsole: LinuxGuestConsoleTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let stream: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let capability: String
    private var terminal = false
    private var aliveExit: Int32?
    private var kills = 0
    private var probes = 0
    private var spawns = 0

    init(capability: String = "serviceTree=cgroup-v1") {
        self.capability = capability
        (stream, continuation) = AsyncStream.makeStream()
    }

    var killCount: Int { lock.withLock { kills } }
    var probeCount: Int { lock.withLock { probes } }
    var spawnCount: Int { lock.withLock { spawns } }
    func endTree() { lock.withLock { terminal = true } }
    func makeTreeLive() { lock.withLock { terminal = false; aliveExit = nil } }
    func failQueries() { lock.withLock { aliveExit = 7 } }
    func output() async -> AsyncStream<Data> { stream }
    func close() async { continuation.finish() }

    func write(_ bytes: [UInt8]) async throws {
        for part in String(decoding: bytes, as: UTF8.self).split(separator: "\u{1e}") {
            let fields = part.split(whereSeparator: { $0 == " " || $0 == "\n" })
            guard fields.count >= 2 else { continue }
            let name = String(fields[0]), token = String(fields[1])
            switch name {
            case "FLOE-HELLO":
                send("FLOE-CAPS \(token) runner=2.2.0 protocol=3 maxCommands=8 maxSessions=4 env=1 net=up \(capability)")
                send("FLOE-END \(token) 0")
            case "FLOE-RUN":
                if token.hasPrefix("ctl-") { send("FLOE-PID \(token) 4242") }
                else { send("FLOE-BEGIN \(token)"); send("FLOE-OUT \(token)") }
                send("FLOE-END \(token) 0")
            case "FLOE-EXEC", "FLOE-EXECENV":
                // Startup loopback provisioning uses the real inline EXEC
                // fast path, not the chunked SPAWN/RUN assembler.
                if fields.count == 3 {
                    send("FLOE-BEGIN \(token)"); send("FLOE-OUT \(token)")
                    continuation.yield(Data("FLOE_LOOPBACK=skipped-already-healthy\n".utf8))
                    send("FLOE-END \(token) 0")
                }
            case "FLOE-KILL":
                lock.withLock { kills += 1 }
                send("FLOE-END \(token) 0") // ACK deliberately leaves the tree alive.
            case "FLOE-SPAWN":
                lock.withLock { spawns += 1 }
            case "FLOE-ALIVE":
                let exit: Int32 = lock.withLock { probes += 1; return aliveExit ?? (terminal ? 3 : 0) }
                send("FLOE-END \(token) \(exit)")
            default: break
            }
        }
    }

    private func send(_ frame: String) { continuation.yield(Data(("\u{1e}" + frame + "\u{1e}").utf8)) }
}

private final class TreeStopMachine: @unchecked Sendable {
    let console: TreeStopConsole
    private let lock = NSLock()
    private var running = false
    private var forwards: Set<UInt16> = []
    private var refuseForward = false

    init(capability: String = "serviceTree=cgroup-v1") { console = TreeStopConsole(capability: capability) }
    var isRunning: Bool { lock.withLock { running } }
    var forwardCount: Int { lock.withLock { forwards.count } }
    func start() { lock.withLock { running = true } }
    func close() { lock.withLock { running = false; forwards.removeAll() } }
    func failForward() { lock.withLock { refuseForward = true } }
    func add(_ forward: LinuxGuestServiceForward) throws {
        try lock.withLock {
            if refuseForward { throw LinuxGuestError.consoleUnavailable("scripted forward failure") }
            forwards.insert(forward.hostPort)
        }
    }
    func remove(_ forward: LinuxGuestServiceForward) { lock.withLock { _ = forwards.remove(forward.hostPort) } }
}

private final class TreeStopFactory: LinuxGuestSessionCreating, @unchecked Sendable {
    private let lock = NSLock()
    private var machines: [TreeStopMachine]
    init(_ machines: [TreeStopMachine]) { self.machines = machines }
    func makeSession(descriptor: LinuxGuestEnvironmentDescriptor, image: LinuxGuestImage,
        limits: LinuxGuestLimits) throws -> LinuxGuestSessionHandle {
        let machine = lock.withLock { machines.count > 1 ? machines.removeFirst() : machines[0] }
        return LinuxGuestSessionHandle(transport: machine.console, start: { machine.start() },
            stop: { machine.close() }, close: { machine.close() }, isRunning: { machine.isRunning },
            addForward: { try machine.add($0) }, removeForward: { machine.remove($0) })
    }
}

private final class TreeStopEnvironment: LinuxGuestEnvironmentProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: LinuxGuestEnvironmentDescriptor
    init(descriptor: LinuxGuestEnvironmentDescriptor) { self.descriptor = descriptor }
    func refuseNewWork() { lock.withLock { descriptor.imageResolutionFailure = "scripted image resolution unavailable" } }
    func linuxGuestEnvironment(id: String) async -> LinuxGuestEnvironmentDescriptor? {
        lock.withLock { id == descriptor.id ? descriptor : nil }
    }
}
private struct TreeStopImage: LinuxGuestImageResolving {
    let image: LinuxGuestImage
    func linuxGuestImage(id: String) async -> LinuxGuestImage? { id == image.id ? image : nil }
}

private struct TreeStopFixture {
    let root: URL
    let registry: LinuxGuestRegistry
    let supervisor: LinuxGuestLocalServiceSupervisor
    let provider: TreeStopEnvironment
    let environmentID = "tree-stop-owned"

    init(_ machines: [TreeStopMachine]) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("floe-tree-stop-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bios = root.appendingPathComponent("bios")
        try Data("bios".utf8).write(to: bios)
        try Data("echo owned".utf8).write(to: root.appendingPathComponent("entry.sh"))
        let image = LinuxGuestImage(id: "tree-test-image", biosPath: bios.path, qualified: true,
            qualificationEvidence: "scripted service-tree contract", qualificationRun: "tree-test",
            artifacts: [LinuxGuestImageArtifact(role: .bios, path: bios.path,
                sha512: FloeDigest.sha512Hex(Data("bios".utf8)), bytes: 4)])
        let descriptor = LinuxGuestEnvironmentDescriptor(id: environmentID, ownerID: "tree-owner",
            shares: [LinuxGuestShare(tag: LinuxGuestShare.environmentTag, hostDirectory: root)], imageID: image.id)
        provider = TreeStopEnvironment(descriptor: descriptor)
        registry = LinuxGuestRegistry(environments: provider,
            images: TreeStopImage(image: image), limits: LinuxGuestLimits(maxCommandTimeout: 2, runnerProbeTimeout: 1),
            factory: TreeStopFactory(machines))
        supervisor = LinuxGuestLocalServiceSupervisor(host: registry)
    }

    func start(port: Int = 8271) async throws -> LinuxGuestLocalServiceHandle {
        _ = try await registry.start(environmentID: environmentID, taskID: "owned-test")
        return try await supervisor.startLocalService(environmentID: environmentID,
            request: LinuxGuestLocalServiceRequest(entry: root.appendingPathComponent("entry.sh").path,
                runtime: .shell, port: port, logFile: root.appendingPathComponent("service.log")), cancellation: nil)
    }
    func close() async {
        await registry.stop(environmentID: environmentID)
        await supervisor.environmentDidStop(environmentID: environmentID)
        try? FileManager.default.removeItem(at: root)
    }
}

/// Models an already-owned service from the earlier consumer. New SPAWN is
/// deliberately unavailable here: the negative regression drives the real
/// old-capability channel's state/join boundary and preserves owner/forward
/// assertions without bypassing the new production admission check.
private actor LegacyTreeStopHost: LinuxGuestLocalServiceHosting {
    let descriptor: LinuxGuestEnvironmentDescriptor
    let channel: LinuxGuestCommandChannel
    private let receipt: LinuxGuestServiceProcessReceipt
    private var controlGeneration: UInt64 = 0
    private var runtimeEnded = false
    private var ownsForward = false
    var forwardCount: Int { ownsForward ? 1 : 0 }

    init(root: URL, environmentID: String, channel: LinuxGuestCommandChannel) {
        descriptor = LinuxGuestEnvironmentDescriptor(id: environmentID, ownerID: "legacy-owner",
            shares: [LinuxGuestShare(tag: LinuxGuestShare.environmentTag, hostDirectory: root)], imageID: "old-image")
        receipt = LinuxGuestServiceProcessReceipt(environmentID: environmentID, generation: 1, pid: 4242)
        self.channel = channel
    }
    func endRuntime() { runtimeEnded = true }
    func supports(environmentID: String) async -> Bool { !runtimeEnded }
    func ownsLinuxEnvironment(environmentID: String) async -> Bool { environmentID == descriptor.id }
    func guestDescriptor(environmentID: String) async -> LinuxGuestEnvironmentDescriptor? { descriptor }
    func run(environmentID: String, argv: [String], workingDirectory: String?, standardInput: String?,
        timeout: TimeInterval, maxOutputBytes: Int, cancellation: CancellationToken?) async throws -> LinuxCommandResult {
        throw LinuxGuestError.consoleUnavailable("not part of this pre-existing-owner fixture")
    }
    func guestSpawn(environmentID: String, argv: [String], workingDirectory: String?, logPath: String,
        timeout: TimeInterval, cancellation: CancellationToken?) async throws -> Int32 {
        throw LinuxGuestError.consoleUnavailable("this fixture cannot start new legacy services")
    }
    func guestSpawnOwnedService(environmentID: String, argv: [String], workingDirectory: String?, logPath: String,
        timeout: TimeInterval, cancellation: CancellationToken?) async throws -> LinuxGuestServiceProcessReceipt {
        controlGeneration = await channel.serviceControlGeneration
        return receipt // Seed an existing owner; no SPAWN is sent.
    }
    func guestServiceAlive(environmentID: String, pid: Int32, timeout: TimeInterval) async throws -> Bool {
        try await channel.serviceTreeAlive(pid: pid, generation: controlGeneration, timeout: timeout)
    }
    func guestKillService(environmentID: String, pid: Int32, timeout: TimeInterval) async throws -> Bool {
        try await channel.killServiceAndJoin(pid: pid, generation: controlGeneration, timeout: timeout)
    }
    func guestOwnedServiceState(_ process: LinuxGuestServiceProcessReceipt, timeout: TimeInterval) async throws -> LinuxGuestServiceProcessState {
        if runtimeEnded { return .environmentGone }
        return try await guestServiceAlive(environmentID: process.environmentID, pid: process.pid, timeout: timeout) ? .running : .exited
    }
    func guestStopOwnedService(_ process: LinuxGuestServiceProcessReceipt, timeout: TimeInterval) async throws -> Bool {
        if runtimeEnded { return true }
        return try await guestKillService(environmentID: process.environmentID, pid: process.pid, timeout: timeout)
    }
    func guestEnsureForward(environmentID: String, forward: LinuxGuestServiceForward) async throws { ownsForward = true }
    func guestRemoveForward(environmentID: String, forward: LinuxGuestServiceForward) async { ownsForward = false }
    func guestEnsureOwnedServiceForward(_ process: LinuxGuestServiceProcessReceipt, forward: LinuxGuestServiceForward) async throws { ownsForward = true }
    func guestReleaseOwnedService(_ process: LinuxGuestServiceProcessReceipt, forward: LinuxGuestServiceForward) async -> Bool {
        guard runtimeEnded else { return false }
        ownsForward = false
        return true
    }
}

private func treeWait(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await condition()
}

final class LinuxGuestServiceTreeStopTests: XCTestCase {
    func testSpawnRejectsOldOrAmbiguousTreeCapabilityBeforeDispatchAndAcceptsExactCapability() async throws {
        for capability in ["", "serviceTree=process-group-v1", "serviceTree=unavailable",
                           "serviceTree=cgroup-v1 serviceTree=cgroup-v1",
                           "serviceTree=cgroup-v1 serviceTree=process-group-v1"] {
            let console = TreeStopConsole(capability: capability)
            let channel = LinuxGuestCommandChannel(transport: console)
            do {
                _ = try await channel.spawnService(argv: ["/bin/sh", "owned.sh"], logPath: "/dev/null", timeout: 2)
                XCTFail("legacy or ambiguous capability must refuse before SPAWN")
            } catch let error as FloeError {
                guard case .validationFailed(let message) = error else { throw error }
                XCTAssertEqual(message, NSLocalizedString("linux_service.update_required", bundle: .main,
                    value: "Update the Linux component, then try again.", comment: ""))
                XCTAssertFalse(message.contains("serviceTree="))
            }
            XCTAssertEqual(console.spawnCount, 0)
            await channel.close()
        }
        let machine = TreeStopMachine(), fixture = try TreeStopFixture([machine])
        let handle = try await fixture.start()
        let state = await fixture.supervisor.localServiceSnapshot(handle)
        XCTAssertEqual(machine.console.spawnCount, 1)
        XCTAssertEqual(state.state, "running"); XCTAssertTrue(state.alive)
        XCTAssertEqual(machine.forwardCount, 1)
        await fixture.close()
    }
    func testOnlyExactCgroupCapabilityProvesWholeTree() {
        for value in [nil, "runner=2.2.0 protocol=3", "serviceTree=process-group-v1",
                      "serviceTree=unavailable", "serviceTree=cgroup-v1 serviceTree=process-group-v1"] {
            XCTAssertFalse(LinuxGuestFraming.supportsWholeServiceTree(capabilities: value))
        }
        XCTAssertTrue(LinuxGuestFraming.supportsWholeServiceTree(capabilities: "runner=2.2.0 protocol=3 serviceTree=cgroup-v1"))
    }

    func testKillAckKeepsServiceForwardAndLifecycleUntilWholeTreeTerminal() async throws {
        let machine = TreeStopMachine(), fixture = try TreeStopFixture([machine])
        let handle = try await fixture.start()
        let stop = Task { await fixture.supervisor.stopLocalService(handle) }
        let sawProbe = await treeWait { machine.console.killCount == 1 && machine.console.probeCount > 0 }
        XCTAssertTrue(sawProbe)
        let before = await fixture.supervisor.activeServiceCount
        let eventsBefore = await fixture.supervisor.emittedLifecycleEventCount
        let snapshot = await fixture.supervisor.localServiceSnapshot(handle)
        XCTAssertEqual(before, 1); XCTAssertEqual(eventsBefore, 0); XCTAssertEqual(machine.forwardCount, 1)
        XCTAssertEqual(snapshot.state, "stopping"); XCTAssertTrue(snapshot.alive)
        machine.console.endTree()
        await stop.value
        let after = await fixture.supervisor.activeServiceCount
        let event = await fixture.supervisor.lastLifecycleEvent
        let activity = await fixture.registry.guestActivityDetails()
        XCTAssertEqual(after, 0); XCTAssertEqual(machine.forwardCount, 0)
        XCTAssertEqual(event?.reason, .hostStopRequested)
        XCTAssertEqual(activity.first?.activeServiceCount, 0)
        await fixture.close()
    }

    func testOldOrNonCgroupRunnerNeverReleasesOnLeaderOnlyReply() async throws {
        for capability in ["", "serviceTree=process-group-v1", "serviceTree=unavailable"] {
            let machine = TreeStopMachine(capability: capability), fixture = try TreeStopFixture([machine])
            let channel = LinuxGuestCommandChannel(transport: machine.console)
            let host = LegacyTreeStopHost(root: fixture.root, environmentID: fixture.environmentID, channel: channel)
            let supervisor = LinuxGuestLocalServiceSupervisor(host: host)
            let handle = try await supervisor.startLocalService(environmentID: fixture.environmentID,
                request: LinuxGuestLocalServiceRequest(entry: fixture.root.appendingPathComponent("entry.sh").path,
                    runtime: .shell, port: 8271, logFile: fixture.root.appendingPathComponent("service.log")), cancellation: nil)
            machine.console.endTree() // Old ALIVE 3 is deliberately insufficient.
            await supervisor.stopLocalService(handle)
            let state = await supervisor.localServiceSnapshot(handle)
            let count = await supervisor.activeServiceCount
            let events = await supervisor.emittedLifecycleEventCount
            let forwardCount = await host.forwardCount
            XCTAssertEqual(state.state, "unavailable"); XCTAssertEqual(count, 1)
            XCTAssertEqual(events, 0); XCTAssertEqual(forwardCount, 1); XCTAssertEqual(machine.console.killCount, 0)
            XCTAssertEqual(machine.console.spawnCount, 0, "existing-owner fixture never uses the newly gated SPAWN")
            await host.endRuntime()
            await supervisor.environmentDidStop(environmentID: fixture.environmentID)
            let released = await supervisor.activeServiceCount
            XCTAssertEqual(released, 0)
            await channel.close()
            await fixture.close()
        }
    }

    func testFailedQueryAndCancelledStopRetainRetryableOwner() async throws {
        let machine = TreeStopMachine(), fixture = try TreeStopFixture([machine])
        let handle = try await fixture.start()
        machine.console.failQueries()
        await fixture.supervisor.stopLocalService(handle)
        let failed = await fixture.supervisor.localServiceSnapshot(handle)
        XCTAssertEqual(failed.state, "unavailable"); XCTAssertEqual(machine.forwardCount, 1)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await fixture.supervisor.stopLocalService(handle)
        }
        await cancelled.value
        let active = await fixture.supervisor.activeServiceCount
        let emitted = await fixture.supervisor.emittedLifecycleEventCount
        XCTAssertEqual(active, 1); XCTAssertEqual(emitted, 0)
        machine.console.makeTreeLive()
        machine.console.endTree()
        await fixture.supervisor.stopLocalService(handle)
        let ended = await fixture.supervisor.activeServiceCount
        XCTAssertEqual(ended, 0); XCTAssertEqual(machine.forwardCount, 0)
        await fixture.close()
    }

    func testJoinTimeoutDoesNotRemoveRegistryOwnershipAndRetryWorks() async throws {
        let machine = TreeStopMachine(), fixture = try TreeStopFixture([machine])
        _ = try await fixture.registry.start(environmentID: fixture.environmentID, taskID: "owned-test")
        let process = try await fixture.registry.guestSpawnOwnedService(environmentID: fixture.environmentID,
            argv: ["/bin/sh", "-c", "sleep 60"], workingDirectory: nil, logPath: "/dev/null", timeout: 2, cancellation: nil)
        do {
            _ = try await fixture.registry.guestStopOwnedService(process, timeout: 1)
            XCTFail("KILL ACK without terminal proof must time out")
        } catch { }
        let activity = await fixture.registry.guestActivityDetails()
        XCTAssertEqual(activity.first?.activeServiceCount, 1)
        machine.console.endTree()
        let confirmed = try await fixture.registry.guestStopOwnedService(process, timeout: 1)
        XCTAssertTrue(confirmed)
        let released = await fixture.registry.guestReleaseOwnedService(process,
            forward: LinuxGuestServiceForward(hostPort: 0, guestPort: 0))
        XCTAssertTrue(released)
        await fixture.close()
    }

    func testWorkAdmissionFailureIsNotRuntimeDeath() async throws {
        let machine = TreeStopMachine(), fixture = try TreeStopFixture([machine])
        let handle = try await fixture.start()
        fixture.provider.refuseNewWork()
        let acceptsNewWork = await fixture.registry.supports(environmentID: fixture.environmentID)
        XCTAssertFalse(acceptsNewWork); XCTAssertTrue(machine.isRunning)
        let snapshot = await fixture.supervisor.localServiceSnapshot(handle)
        let active = await fixture.supervisor.activeServiceCount
        let events = await fixture.supervisor.emittedLifecycleEventCount
        XCTAssertEqual(snapshot.state, "running"); XCTAssertTrue(snapshot.alive)
        XCTAssertEqual(active, 1); XCTAssertEqual(events, 0); XCTAssertEqual(machine.forwardCount, 1)
        await fixture.close()
    }

    func testCancellationAfterKillAckKeepsOwnerUntilRetryConfirmsTree() async throws {
        let machine = TreeStopMachine(), fixture = try TreeStopFixture([machine])
        let handle = try await fixture.start()
        let stop = Task { await fixture.supervisor.stopLocalService(handle) }
        let sawProbe = await treeWait { machine.console.killCount == 1 && machine.console.probeCount > 0 }
        XCTAssertTrue(sawProbe)
        stop.cancel()
        await stop.value
        let active = await fixture.supervisor.activeServiceCount
        let events = await fixture.supervisor.emittedLifecycleEventCount
        let activity = await fixture.registry.guestActivityDetails()
        XCTAssertEqual(active, 1); XCTAssertEqual(events, 0); XCTAssertEqual(machine.forwardCount, 1)
        XCTAssertEqual(activity.first?.activeServiceCount, 1)
        machine.console.endTree()
        await fixture.supervisor.stopLocalService(handle)
        let ended = await fixture.supervisor.activeServiceCount
        XCTAssertEqual(ended, 0)
        await fixture.close()
    }

    func testRestartReusedPIDCannotReceiveOldKillOrForwardRemoval() async throws {
        let first = TreeStopMachine(), second = TreeStopMachine()
        let fixture = try TreeStopFixture([first, second])
        let old = try await fixture.start()
        await fixture.registry.stop(environmentID: fixture.environmentID)
        let fresh = try await fixture.start()
        XCTAssertEqual(old.pid, fresh.pid) // Deliberate PID reuse in the next boot.
        await fixture.supervisor.stopLocalService(old)
        let snapshot = await fixture.supervisor.localServiceSnapshot(fresh)
        XCTAssertEqual(snapshot.state, "running"); XCTAssertTrue(snapshot.alive)
        XCTAssertEqual(second.console.killCount, 0); XCTAssertEqual(second.forwardCount, 1)
        let activity = await fixture.registry.guestActivityDetails()
        XCTAssertEqual(activity.first?.activeServiceCount, 1)
        await fixture.close()
    }

    func testSameBootPIDReuseKeepsTheNewSpawnReferenceOwned() async throws {
        let machine = TreeStopMachine(), fixture = try TreeStopFixture([machine])
        _ = try await fixture.registry.start(environmentID: fixture.environmentID, taskID: "owned-test")
        let old = try await fixture.registry.guestSpawnOwnedService(environmentID: fixture.environmentID,
            argv: ["old"], workingDirectory: nil, logPath: "/dev/null", timeout: 2, cancellation: nil)
        machine.console.endTree()
        let oldState = try await fixture.registry.guestOwnedServiceState(old, timeout: 1)
        XCTAssertEqual(oldState, .exited)
        machine.console.makeTreeLive()
        let fresh = try await fixture.registry.guestSpawnOwnedService(environmentID: fixture.environmentID,
            argv: ["fresh"], workingDirectory: nil, logPath: "/dev/null", timeout: 2, cancellation: nil)
        XCTAssertEqual(old.pid, fresh.pid); XCTAssertNotEqual(old.reference, fresh.reference)
        let released = await fixture.registry.guestReleaseOwnedService(old,
            forward: LinuxGuestServiceForward(hostPort: 0, guestPort: 0))
        XCTAssertTrue(released)
        let activity = await fixture.registry.guestActivityDetails()
        XCTAssertEqual(activity.first?.activeServiceCount, 1)
        let state = try await fixture.registry.guestOwnedServiceState(fresh, timeout: 1)
        XCTAssertEqual(state, .running)
        await fixture.close()
    }

    func testFailedForwardReturnsRetainedHandleWhenCleanupCannotBeProved() async throws {
        let machine = TreeStopMachine()
        machine.failForward()
        machine.console.failQueries()
        let fixture = try TreeStopFixture([machine])
        let handle = try await fixture.start()
        let snapshot = await fixture.supervisor.localServiceSnapshot(handle)
        let count = await fixture.supervisor.activeServiceCount
        XCTAssertEqual(count, 1); XCTAssertEqual(snapshot.state, "unavailable")
        let activity = await fixture.registry.guestActivityDetails()
        XCTAssertEqual(activity.first?.activeServiceCount, 1)
        await fixture.close()
    }
}
