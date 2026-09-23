// FloeExecutionTests — managed guest service lifecycle + real runtime identity.
//
// Two production seams are pinned here:
//
//  * `LinuxGuestLocalServiceSupervisor` reports lifecycle transitions exactly
//    once per owned handle: an explicit host stop is marked as such (never a
//    crash alert), a confirmed guest-side end is an unexpected stop with no
//    invented exit code, a probe that could not verify emits nothing and keeps
//    the handle owned, and a stop landing during an in-flight probe wins over
//    the stale probe answer. Forward cleanup happens on a confirmed exit.
//  * `TinyEMULinuxGuestRegistry.runtimeIdentity`/`runtimeStates` expose the
//    runtime owner's own per-session runtimeID and per-start launch
//    generation, so the metrics sampler reads a real identity that rotates on
//    restart (and resets its delta baselines) instead of a placeholder.
//
// The registry tests drive the real registry over scripted session and
// Runtime v2 seams — the code under test is the production path.

import Foundation
import XCTest
import FloeCore
import FloeTools
@testable import FloeExecution

// MARK: - deterministic barrier

/// Rendezvous gate: `arriveAndWait` counts an arrival and parks until the test
/// opens the gate; `awaitArrival` lets the test wait for that arrival. No
/// sleep decides an outcome.
private final class ServiceProbeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var arrivals = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

    var arrivalCount: Int { lock.withLock { arrivals } }

    func arriveAndWait() async {
        markArrival()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            park(continuation)
        }
    }

    func awaitArrival() async {
        if lock.withLock({ arrivals > 0 }) { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            registerArrivalWaiter(continuation)
        }
    }

    private func park(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if opened {
            lock.unlock()
            continuation.resume()
            return
        }
        waiters.append(continuation)
        lock.unlock()
    }

    private func registerArrivalWaiter(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if arrivals > 0 {
            lock.unlock()
            continuation.resume()
            return
        }
        arrivalWaiters.append(continuation)
        lock.unlock()
    }

    private func markArrival() {
        lock.lock()
        arrivals += 1
        let pending = arrivalWaiters
        arrivalWaiters = []
        lock.unlock()
        for continuation in pending { continuation.resume() }
    }

    func open() {
        lock.lock()
        opened = true
        let pending = waiters
        waiters = []
        lock.unlock()
        for continuation in pending { continuation.resume() }
    }
}

/// Bounded state-driven wait: the predicate is the mechanism; the deadline is
/// only a safety bound so a broken implementation fails instead of hanging.
private func waitUntil(
    timeout: Duration = .seconds(10),
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await condition()
}

private actor ServiceEventCollector {
    private(set) var events: [LinuxGuestLocalServiceLifecycleEvent] = []
    var count: Int { events.count }
    func append(_ event: LinuxGuestLocalServiceLifecycleEvent) { events.append(event) }
    func reasons() -> [LinuxGuestLocalServiceStopReason] { events.map(\.reason) }
    func first() -> LinuxGuestLocalServiceLifecycleEvent? { events.first }
}

// MARK: - scripted supervisor host

/// Scripted `LinuxGuestLocalServiceHosting`: every probe behavior the
/// lifecycle contract needs (alive/dead, a throw, a park) is an explicit knob.
private final class ScriptedServiceHost: LinuxGuestLocalServiceHosting, @unchecked Sendable {
    private let lock = NSLock()
    private var alive = true
    private var supportsGuest = true
    private var probeError: Error?
    private var parkNextProbe = false
    private var killCount = 0
    private var addedForwards: [LinuxGuestServiceForward] = []
    private var removedForwards: [LinuxGuestServiceForward] = []
    let descriptor: LinuxGuestEnvironmentDescriptor
    let probeGate = ServiceProbeGate()

    init(descriptor: LinuxGuestEnvironmentDescriptor) {
        self.descriptor = descriptor
    }

    var forwardCount: Int { lock.withLock { addedForwards.count - removedForwards.count } }
    var killed: Int { lock.withLock { killCount } }

    func markDead() { lock.withLock { alive = false } }
    func setSupportsGuest(_ value: Bool) { lock.withLock { supportsGuest = value } }
    func failNextProbe(_ error: Error) { lock.withLock { probeError = error } }
    func parkNextProbeCall() { lock.withLock { parkNextProbe = true } }

    func supports(environmentID: String) async -> Bool { lock.withLock { supportsGuest } }
    func ownsLinuxEnvironment(environmentID: String) async -> Bool { true }

    func run(
        environmentID: String,
        argv: [String],
        workingDirectory: String?,
        standardInput: String?,
        timeout: TimeInterval,
        maxOutputBytes: Int,
        cancellation: CancellationToken?
    ) async throws -> LinuxCommandResult {
        LinuxCommandResult(stdout: "", stderr: "", exitCode: 0)
    }

    func guestDescriptor(environmentID: String) async -> LinuxGuestEnvironmentDescriptor? { descriptor }

    func guestSpawn(
        environmentID: String,
        argv: [String],
        workingDirectory: String?,
        logPath: String,
        timeout: TimeInterval,
        cancellation: CancellationToken?
    ) async throws -> Int32 {
        4242
    }

    func guestServiceAlive(environmentID: String, pid: Int32, timeout: TimeInterval) async throws -> Bool {
        let shouldPark = lock.withLock {
            let value = parkNextProbe
            parkNextProbe = false
            return value
        }
        if shouldPark { await probeGate.arriveAndWait() }
        // Read the liveness and the one-shot error AFTER any park: a stop that
        // landed while the probe was in flight must be visible to the resumed
        // probe, and a transient error must not poison later probes.
        if let error = lock.withLock({ let value = probeError; probeError = nil; return value }) {
            throw error
        }
        return lock.withLock { alive }
    }

    func guestKillService(environmentID: String, pid: Int32, timeout: TimeInterval) async throws -> Bool {
        lock.withLock {
            killCount += 1
            let wasAlive = alive
            alive = false
            return wasAlive
        }
    }

    func guestEnsureForward(environmentID: String, forward: LinuxGuestServiceForward) async throws {
        lock.withLock { addedForwards.append(forward) }
    }

    func guestRemoveForward(environmentID: String, forward: LinuxGuestServiceForward) async {
        lock.withLock { removedForwards.append(forward) }
    }
}

// MARK: - supervisor fixtures

private func serviceFixtureRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("floe-service-lifecycle-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("services", isDirectory: true),
        withIntermediateDirectories: true
    )
    try Data("console.log('hi')".utf8).write(to: root.appendingPathComponent("app.js"))
    try Data("log line\n".utf8).write(to: root.appendingPathComponent("services/job.log"))
    return root
}

private func serviceRequest(root: URL, port: Int) -> LinuxGuestLocalServiceRequest {
    LinuxGuestLocalServiceRequest(
        entry: root.appendingPathComponent("app.js").path,
        runtime: .node,
        port: port,
        logFile: root.appendingPathComponent("services/job.log")
    )
}

private func serviceDescriptor(id: String, root: URL) -> LinuxGuestEnvironmentDescriptor {
    LinuxGuestEnvironmentDescriptor(
        id: id,
        ownerID: "owner",
        shares: [LinuxGuestShare(tag: LinuxGuestShare.environmentTag, hostDirectory: root)],
        imageID: "service-image"
    )
}

// MARK: - registry identity fixtures

private actor ScriptedIdentityV2Integrator: LinuxGuestRuntimeV2Integrating {
    let root: URL
    let expandedRoot: URL

    init(root: URL, expandedRoot: URL) {
        self.root = root
        self.expandedRoot = expandedRoot
    }

    func acquireSlot(environmentID: String, runtimeID: String, requestedMB: Int) async throws -> RuntimeV2Admission {
        RuntimeV2Admission(runtimeID: runtimeID, ramMB: requestedMB, downgraded: false)
    }

    func acquireShape(
        environmentID: String,
        runtimeID: String,
        request: GuestResourceRequest,
        imageSMPCapable: Bool,
        downgrade: GuestShapeDowngradePolicy
    ) async throws -> LinuxGuestShapeAdmission {
        LinuxGuestShapeAdmission(
            runtimeID: runtimeID,
            ramMB: request.memory.mb,
            vcpus: request.vcpus.count,
            downgraded: false
        )
    }

    func imageSMPCapable(imageID: String) async -> Bool { true }
    func planReshape(environmentID: String, ramMB: Int, vcpus: Int, currentVCPUs: Int) async throws {}
    func confirmReshape(environmentID: String, ramMB: Int, vcpus: Int) async {}
    func planRetier(environmentID: String, ramMB: Int) async throws {}
    func confirmTier(environmentID: String, ramMB: Int) async {}

    func prepareWorkingDisk(
        environmentID: String,
        runtimeID: String,
        imageID: String,
        legacyWritableDirectory: URL?,
        targetCapacityBytes: Int64
    ) async throws -> RuntimeV2WorkingDisk {
        let url = root.appendingPathComponent("disk-\(UUID().uuidString).img")
        FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 0, count: 1024))
        return RuntimeV2WorkingDisk(diskURL: url, capacityBytes: 1024)
    }

    func environmentDataDirectory(environmentID: String) async throws -> URL {
        let url = root.appendingPathComponent("data/\(environmentID)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func completeStop(environmentID: String, runtimeID: String, imageID: String, clean: Bool) async {}
    func completeStopResult(
        environmentID: String,
        runtimeID: String,
        imageID: String,
        clean: Bool
    ) async -> RuntimeV2StopOutcome {
        .captured(generation: 1)
    }

    func releaseSlot(environmentID: String, runtimeID: String) async {}
    func expandedImageDirectory(imageID: String) async throws -> URL { expandedRoot }
    func isImageVerified(imageID: String) async -> Bool { true }
    func isImageVerifiedWithoutMigration(imageID: String) async -> Bool { true }
    func recordedRunnerCapabilities(environmentID: String) async -> String? { nil }
    func recordRunnerCapabilities(_ capabilities: String, environmentID: String) async {}
    func workingDiskCapacityBytes(environmentID: String, runtimeID: String) async -> Int64? { 1024 }
    func queuedStarts() async -> Int { 0 }
}

/// Qualified image whose artifacts are relative to the verified expanded
/// directory, exactly like the Runtime v2 boot path consumes.
private func identityImage(id: String, directory: URL) throws -> LinuxGuestImage {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let bios = Data("bios".utf8)
    try bios.write(to: directory.appendingPathComponent("bbl64.bin"))
    return LinuxGuestImage(
        id: id,
        biosPath: "bbl64.bin",
        qualified: true,
        qualificationEvidence: "identity lifecycle test \(UUID().uuidString)",
        qualificationRun: "identity-run-1",
        artifacts: [
            LinuxGuestImageArtifact(
                role: .bios,
                path: "bbl64.bin",
                sha512: FloeDigest.sha512Hex(bios),
                bytes: Int64(bios.count)
            )
        ]
    )
}

private func identityDescriptor(id: String, imageID: String) -> LinuxGuestEnvironmentDescriptor {
    LinuxGuestEnvironmentDescriptor(id: id, ownerID: "owner", imageID: imageID)
}

private func caps(_ token: String) -> [Data] {
    [Data("\u{1e}FLOE-CAPS \(token) runner=2.0.0 protocol=3 maxCommands=8 maxSessions=4\u{1e}\u{1e}FLOE-END \(token) 0\u{1e}".utf8)]
}

private func reply(_ token: String) -> [Data] {
    var data = Data()
    data.append(Data("\u{1e}FLOE-BEGIN \(token)\u{1e}\u{1e}FLOE-OUT \(token)\u{1e}".utf8))
    data.append(Data("\u{1e}FLOE-END \(token) 0\u{1e}".utf8))
    return [data]
}

/// Scripted `/proc` reader for the sampler identity test. Counters are
/// controllable so the test can distinguish "delta computed" from "baseline
/// reset" deterministically.
private final class ScriptedProcRunner: LinuxCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var busy: UInt64
    private var idle: UInt64
    let coreCount: Int

    init(coreCount: Int, busy: UInt64, idle: UInt64) {
        self.coreCount = coreCount
        self.busy = busy
        self.idle = idle
    }

    func advance(busy: UInt64, idle: UInt64) {
        lock.withLock {
            self.busy = busy
            self.idle = idle
        }
    }

    func supports(environmentID: String) async -> Bool { true }

    func run(
        environmentID: String,
        argv: [String],
        workingDirectory: String?,
        standardInput: String?,
        timeout: TimeInterval,
        maxOutputBytes: Int,
        cancellation: CancellationToken?
    ) async throws -> LinuxCommandResult {
        let (b, i) = lock.withLock { (busy, idle) }
        var stat = "cpu  \(b) 0 \(b) \(i) 0 0 0 0 0 0\n"
        for index in 0..<coreCount {
            stat += "cpu\(index) 50 0 50 \(i / 2) 0 0 0 0 0 0\n"
        }
        let meminfo = "MemTotal:       2048000 kB\nMemFree:        1024000 kB\nMemAvailable:   1024000 kB\n"
        let netdev = "Inter-|   Receive                                                |  Transmit\n face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed\n    lo: 1024 1 0 0 0 0 0 0 1024 1 0 0 0 0 0 0\n"
        let composite = [stat, meminfo, netdev, "Linux 6.1.0-test"]
            .joined(separator: "@@FLOE@@")
        return LinuxCommandResult(stdout: composite, stderr: "", exitCode: 0)
    }
}

// MARK: - tests

final class LinuxGuestLocalServiceTests: XCTestCase {

    private func makeStartedService(
        environmentID: String
    ) async throws -> (supervisor: LinuxGuestLocalServiceSupervisor, host: ScriptedServiceHost, handle: LinuxGuestLocalServiceHandle) {
        let root = try serviceFixtureRoot()
        let host = ScriptedServiceHost(descriptor: serviceDescriptor(id: environmentID, root: root))
        let supervisor = LinuxGuestLocalServiceSupervisor(host: host)
        let handle = try await supervisor.startLocalService(
            environmentID: environmentID,
            request: serviceRequest(root: root, port: 8123),
            cancellation: nil
        )
        let forwards = host.forwardCount
        XCTAssertEqual(forwards, 1, "a started service publishes exactly one forward")
        return (supervisor, host, handle)
    }

    private func makeIdentityRegistry(
        environmentIDs: [String],
        root: URL
    ) throws -> (registry: TinyEMULinuxGuestRegistry, image: LinuxGuestImage) {
        let expandedRoot = root.appendingPathComponent("expanded", isDirectory: true)
        try FileManager.default.createDirectory(at: expandedRoot, withIntermediateDirectories: true)
        let image = try identityImage(id: "identity-image", directory: expandedRoot)
        var descriptors: [String: LinuxGuestEnvironmentDescriptor] = [:]
        for id in environmentIDs {
            descriptors[id] = identityDescriptor(id: id, imageID: image.id)
        }
        let registry = TinyEMULinuxGuestRegistry(
            environments: FakeEnvironmentProvider(descriptors: descriptors),
            images: FakeImageResolver(images: [image.id: image]),
            limits: .standard,
            factory: FakeSessionFactory(ledger: FakeSessionLedger()) { _, token in
                token.hasPrefix("hello-") ? caps(token) : reply(token)
            },
            runtimeV2: ScriptedIdentityV2Integrator(root: root, expandedRoot: expandedRoot)
        )
        return (registry, image)
    }

    // MARK: supervisor lifecycle

    func testExplicitStopIsReportedAsHostStopAndNeverAsAnObservedExit() async throws {
        let environmentID = "env-service-\(UUID().uuidString)"
        let (supervisor, host, handle) = try await makeStartedService(environmentID: environmentID)
        let collector = ServiceEventCollector()
        let stream = await supervisor.localServiceLifecycleEvents()
        let consumer = Task { for await event in stream { await collector.append(event) } }
        defer { consumer.cancel() }

        await supervisor.stopLocalService(handle)
        let delivered = await waitUntil { await collector.count == 1 }
        XCTAssertTrue(delivered)
        let reasons = await collector.reasons()
        XCTAssertEqual(reasons, [.hostStopRequested])
        XCTAssertEqual(host.killed, 1)
        XCTAssertEqual(host.forwardCount, 0)

        // The explicit stop consumed the handle: a later probe is notFound and
        // adds no lifecycle event.
        let snapshot = await supervisor.localServiceSnapshot(handle)
        XCTAssertEqual(snapshot.state, "notFound")
        try? await Task.sleep(for: .milliseconds(30))
        let count = await collector.count
        let emitted = await supervisor.emittedLifecycleEventCount
        XCTAssertEqual(count, 1)
        XCTAssertEqual(emitted, 1)
    }

    func testObservedExitIsSurfacedOnceAndCleansUpTheForward() async throws {
        let environmentID = "env-service-\(UUID().uuidString)"
        let (supervisor, host, handle) = try await makeStartedService(environmentID: environmentID)
        let collector = ServiceEventCollector()
        let stream = await supervisor.localServiceLifecycleEvents()
        let consumer = Task { for await event in stream { await collector.append(event) } }
        defer { consumer.cancel() }

        host.markDead()
        let first = await supervisor.localServiceSnapshot(handle)
        XCTAssertEqual(first.state, "stopped")
        let delivered = await waitUntil { await collector.count == 1 }
        XCTAssertTrue(delivered)
        let reasons = await collector.reasons()
        XCTAssertEqual(reasons, [.processExited])
        let event = await collector.first()
        XCTAssertEqual(event?.handle.token, handle.token)
        XCTAssertEqual(event?.handle.environmentID, environmentID)
        XCTAssertEqual(event?.handle.port, 8123)
        XCTAssertEqual(event?.observedAt, event?.observedAt)
        // Confirmed exit drops the published forward.
        XCTAssertEqual(host.forwardCount, 0)

        // Repeated probes of the same handle never surface a second end.
        let second = await supervisor.localServiceSnapshot(handle)
        XCTAssertEqual(second.state, "notFound")
        try? await Task.sleep(for: .milliseconds(30))
        let count = await collector.count
        let emitted = await supervisor.emittedLifecycleEventCount
        XCTAssertEqual(count, 1)
        XCTAssertEqual(emitted, 1)
    }

    func testTransientProbeErrorKeepsTheHandleOwnedAndEmitsNothing() async throws {
        let environmentID = "env-service-\(UUID().uuidString)"
        let (supervisor, host, handle) = try await makeStartedService(environmentID: environmentID)
        let collector = ServiceEventCollector()
        let stream = await supervisor.localServiceLifecycleEvents()
        let consumer = Task { for await event in stream { await collector.append(event) } }
        defer { consumer.cancel() }

        host.failNextProbe(LinuxGuestError.notRunning(environmentID: environmentID))
        let unavailable = await supervisor.localServiceSnapshot(handle)
        XCTAssertEqual(unavailable.state, "unavailable")
        let owned = await supervisor.activeServiceCount
        XCTAssertEqual(owned, 1, "an unverified probe must not release the handle")
        try? await Task.sleep(for: .milliseconds(30))
        let countAfterError = await collector.count
        XCTAssertEqual(countAfterError, 0, "a transient probe error must not alert")

        // The service is still owned and a later probe answers truthfully.
        let running = await supervisor.localServiceSnapshot(handle)
        XCTAssertEqual(running.state, "running")
        let countAfterRecovery = await collector.count
        XCTAssertEqual(countAfterRecovery, 0)
    }

    func testStopDuringInFlightProbeWinsAndEmitsNoStaleFailure() async throws {
        let environmentID = "env-service-\(UUID().uuidString)"
        let (supervisor, host, handle) = try await makeStartedService(environmentID: environmentID)
        let collector = ServiceEventCollector()
        let stream = await supervisor.localServiceLifecycleEvents()
        let consumer = Task { for await event in stream { await collector.append(event) } }
        defer { consumer.cancel() }

        host.parkNextProbeCall()
        let probe = Task { await supervisor.localServiceSnapshot(handle) }
        await host.probeGate.awaitArrival()
        // The host stop lands while the probe is suspended; the probe then
        // observes the killed process and must not report an unexpected end.
        await supervisor.stopLocalService(handle)
        host.probeGate.open()
        let snapshot = await probe.value
        XCTAssertEqual(snapshot.state, "stopped")
        let delivered = await waitUntil { await collector.count == 1 }
        XCTAssertTrue(delivered)
        let reasons = await collector.reasons()
        XCTAssertEqual(reasons, [.hostStopRequested])
        let emitted = await supervisor.emittedLifecycleEventCount
        XCTAssertEqual(emitted, 1)
    }

    func testEnvironmentGoneIsSurfacedOnceAndExplicitTeardownIsNot() async throws {
        let environmentID = "env-service-\(UUID().uuidString)"
        let (supervisor, host, handle) = try await makeStartedService(environmentID: environmentID)
        let collector = ServiceEventCollector()
        let stream = await supervisor.localServiceLifecycleEvents()
        let consumer = Task { for await event in stream { await collector.append(event) } }
        defer { consumer.cancel() }

        // An environment that vanished without a stop routed through the
        // supervisor is an observed end (identity preserved, no exit code).
        host.setSupportsGuest(false)
        let snapshot = await supervisor.localServiceSnapshot(handle)
        XCTAssertEqual(snapshot.state, "stopped")
        let delivered = await waitUntil { await collector.count == 1 }
        XCTAssertTrue(delivered)
        let reasons = await collector.reasons()
        XCTAssertEqual(reasons, [.environmentGone])
        let emitted = await supervisor.emittedLifecycleEventCount
        XCTAssertEqual(emitted, 1)

        let second = await supervisor.localServiceSnapshot(handle)
        XCTAssertEqual(second.state, "notFound")
        let count = await collector.count
        XCTAssertEqual(count, 1)
    }

    func testExplicitTeardownAheadOfGuestLossNeverLooksUnexpected() async throws {
        let environmentID = "env-service-\(UUID().uuidString)"
        let (supervisor, host, handle) = try await makeStartedService(environmentID: environmentID)
        let collector = ServiceEventCollector()
        let stream = await supervisor.localServiceLifecycleEvents()
        let consumer = Task { for await event in stream { await collector.append(event) } }
        defer { consumer.cancel() }

        // Environment teardown stops its services first, then the guest goes
        // away. The stale probe afterwards must not invent an unexpected end.
        await supervisor.stopLocalServices(environmentID: environmentID)
        host.setSupportsGuest(false)
        _ = await supervisor.localServiceSnapshot(handle)
        try? await Task.sleep(for: .milliseconds(30))
        let reasons = await collector.reasons()
        XCTAssertEqual(reasons, [.hostStopRequested])
        let emitted = await supervisor.emittedLifecycleEventCount
        XCTAssertEqual(emitted, 1)
    }

    func testCancelledObserverIsReleasedAndStopsReceiving() async throws {
        let environmentID = "env-service-\(UUID().uuidString)"
        let (supervisor, _, handle) = try await makeStartedService(environmentID: environmentID)
        let collector = ServiceEventCollector()
        let stream = await supervisor.localServiceLifecycleEvents()
        let consumer = Task { for await event in stream { await collector.append(event) } }
        let registered = await waitUntil { await supervisor.lifecycleObserverCount == 1 }
        XCTAssertTrue(registered)

        consumer.cancel()
        let released = await waitUntil { await supervisor.lifecycleObserverCount == 0 }
        XCTAssertTrue(released, "a cancelled observer must release its slot")
        // Lifecycle work continues safely without observers.
        await supervisor.stopLocalService(handle)
        let emitted = await supervisor.emittedLifecycleEventCount
        XCTAssertEqual(emitted, 1)
        let count = await collector.count
        XCTAssertEqual(count, 0)
    }

    // MARK: real runtime identity / rotation

    func testTwoRunningGuestsExposeDistinctRealIdentityAndGrantedShape() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let (registry, _) = try makeIdentityRegistry(environmentIDs: ["env-a", "env-b"], root: root)

        _ = try await registry.start(environmentID: "env-a", taskID: nil)
        _ = try await registry.start(environmentID: "env-b", taskID: nil)

        let states = await registry.runtimeStates()
        XCTAssertEqual(states.map(\.environmentID), ["env-a", "env-b"])
        XCTAssertTrue(states.allSatisfy(\.running))
        let runtimeIDs = states.compactMap(\.identity.runtimeID)
        XCTAssertEqual(runtimeIDs.count, 2, "the Runtime v2 path must expose a real runtimeID per session")
        XCTAssertEqual(Set(runtimeIDs).count, 2, "two VMs never share one runtimeID")
        let generations = states.compactMap(\.identity.launchGeneration)
        XCTAssertEqual(generations.count, 2, "every session carries its real per-start generation")
        XCTAssertEqual(Set(generations).count, 2)
        XCTAssertTrue(states.allSatisfy { $0.vcpus == 1 }, "granted vCPU shape is reported, not inferred")
        XCTAssertTrue(states.allSatisfy { $0.ramMB > 0 })

        // The single-environment provider agrees with the state table.
        let identity = await registry.runtimeIdentity(environmentID: "env-a")
        XCTAssertEqual(identity, states[0].identity)
    }

    func testRestartRotatesRuntimeIdentityAndStoppedIsNotDeleted() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-identity-restart-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let (registry, _) = try makeIdentityRegistry(environmentIDs: ["env-a", "env-b"], root: root)

        _ = try await registry.start(environmentID: "env-a", taskID: nil)
        _ = try await registry.start(environmentID: "env-b", taskID: nil)
        let first = await registry.runtimeIdentity(environmentID: "env-a")
        let otherGeneration = await registry.runtimeIdentity(environmentID: "env-b").launchGeneration

        await registry.stop(environmentID: "env-a")
        // Stopped is not deleted: the environment is still owned, but its
        // identity is gone instead of keeping a stale token.
        let owns = await registry.owns(environmentID: "env-a")
        XCTAssertTrue(owns)
        let stoppedIdentity = await registry.runtimeIdentity(environmentID: "env-a")
        XCTAssertEqual(stoppedIdentity, LinuxGuestRuntimeIdentity())
        let remaining = await registry.runtimeStates().map(\.environmentID)
        XCTAssertEqual(remaining, ["env-b"])

        _ = try await registry.start(environmentID: "env-a", taskID: nil)
        let second = await registry.runtimeIdentity(environmentID: "env-a")
        XCTAssertNotNil(second.runtimeID)
        XCTAssertNotEqual(second.runtimeID, first.runtimeID, "a restart gets a fresh runtimeID")
        guard let firstGeneration = first.launchGeneration, let newGeneration = second.launchGeneration else {
            return XCTFail("restart identity must carry a real launch generation")
        }
        XCTAssertGreaterThan(newGeneration, firstGeneration, "the launch generation advances on restart")
        // The untouched environment keeps its identity across the other VM's
        // restart.
        let untouched = await registry.runtimeIdentity(environmentID: "env-b").launchGeneration
        XCTAssertEqual(untouched, otherGeneration)
    }

    func testSamplerReadsTheRealRuntimeIdentityAndResetsAcrossRestart() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-sampler-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let (registry, _) = try makeIdentityRegistry(environmentIDs: ["env-sampler"], root: root)
        _ = try await registry.start(environmentID: "env-sampler", taskID: nil)
        let runningIdentity = await registry.runtimeIdentity(environmentID: "env-sampler")
        XCTAssertNotNil(runningIdentity.launchGeneration)

        let runner = ScriptedProcRunner(coreCount: 2, busy: 100, idle: 800)
        let sampler = LinuxGuestMetricsSampler(
            environmentID: "env-sampler",
            commandRunner: runner,
            runtimeIdentityProvider: { id in
                await registry.runtimeIdentity(environmentID: id)
            }
        )
        let first = await sampler.sampleRuntime()
        XCTAssertTrue(first.guestReadSucceeded)
        XCTAssertEqual(first.guestCoreCount, 2)
        XCTAssertEqual(first.kernelVersion, "Linux 6.1.0-test")
        XCTAssertEqual(first.runtimeIdentity, runningIdentity, "the sampler carries the runtime owner's identity")
        XCTAssertNil(first.guestCPUFraction, "the first sample has no delta baseline")

        // Same boot, advanced counters: a real delta is computed.
        runner.advance(busy: 500, idle: 1600)
        let second = await sampler.sampleRuntime()
        XCTAssertNotNil(second.guestCPUFraction, "a live boot computes a CPU delta")

        // Restart the guest: the identity must rotate, and the first sample of
        // the new boot must not compute a CPU delta across two boots.
        await registry.stop(environmentID: "env-sampler")
        _ = try await registry.start(environmentID: "env-sampler", taskID: nil)
        let restartedIdentity = await registry.runtimeIdentity(environmentID: "env-sampler")
        XCTAssertNotEqual(restartedIdentity, runningIdentity)
        runner.advance(busy: 1200, idle: 3000)
        let restarted = await sampler.sampleRuntime()
        XCTAssertEqual(restarted.runtimeIdentity, restartedIdentity, "the sampler follows the new launch")
        XCTAssertNil(
            restarted.guestCPUFraction,
            "an identity change resets the delta baseline instead of pairing two boots"
        )

        // The new boot's own deltas work again.
        runner.advance(busy: 1800, idle: 4000)
        let afterRestart = await sampler.sampleRuntime()
        XCTAssertNotNil(afterRestart.guestCPUFraction, "deltas resume within the new boot")
    }

    func testActiveSessionCountIsRealZeroWhenOwnedAndNilWhenUnknown() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-sessions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let (registry, _) = try makeIdentityRegistry(environmentIDs: ["env-sessions"], root: root)
        let owned = await registry.activeSessionCount(environmentID: "env-sessions")
        XCTAssertEqual(owned, 0, "an owned environment with no terminal session is a real zero")
        let unknown = await registry.activeSessionCount(environmentID: "env-unknown")
        XCTAssertNil(unknown, "an unowned environment is unknown, never a fabricated zero")
    }
}
