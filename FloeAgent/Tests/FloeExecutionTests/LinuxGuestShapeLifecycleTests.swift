// FloeExecutionTests — shape/RAM change vs stop lifecycle races.
//
// The pinned engine cannot resize a live guest, so a shape change is a
// stop → apply → restart sequence that suspends at several awaits. These
// tests pin the contract that a stop landing while that sequence is suspended
// always wins: the resuming change may never restart the old handle, rebook a
// reservation it no longer owns, overwrite a replacement session or claim a
// clean save. Every interleaving is driven by explicit barriers plus registry
// state predicates — no sleep decides an outcome.

import Foundation
import XCTest
import FloeCore
import FloeTools
@testable import FloeExecution

// MARK: - deterministic barriers

/// Rendezvous gate: `arriveAndWait` counts an arrival and parks until the test
/// opens the gate; `awaitArrival` lets the test wait for that arrival.
private final class LifecycleGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var arrivals = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

    var arrivalCount: Int { lock.withLock { arrivals } }
    var isOpen: Bool { lock.withLock { opened } }

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

    /// Synchronous helper: NSLock must not be taken directly in an async context.
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

    /// Synchronous helper: NSLock must not be taken directly in an async context.
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

/// Runs one shape change and returns its error (nil on success). File scope so
/// the driving tasks capture only sendable values.
private func shapeChangeError(
    _ registry: TinyEMULinuxGuestRegistry, environmentID: String, ramMB: Int, vcpus: Int
) async -> Error? {
    do {
        try await registry.setShape(environmentID: environmentID, ramMB: ramMB, vcpus: vcpus)
        return nil
    } catch {
        return error
    }
}

/// Runs one RAM-only retier and returns its error (nil on success).
private func retierError(
    _ registry: TinyEMULinuxGuestRegistry, environmentID: String, ramMB: Int
) async -> Error? {
    do {
        try await registry.setMemoryTier(environmentID: environmentID, ramMB: ramMB)
        return nil
    } catch {
        return error
    }
}

// MARK: - scripted guest session

/// Scripted shape-aware guest session. Every lifecycle step is an explicit
/// hook the test can park on, and every call is counted so a stale operation
/// that restarts an old handle is visible.
private final class ShapeGuestSession: @unchecked Sendable {
    private let lock = NSLock()
    private var running: Bool
    private var ramMB: Int?
    private var vcpus: Int?
    private var startAttempts = 0
    private var startCount = 0
    private var stopCount = 0
    private var closeCount = 0
    private var appliedRAM: [Int] = []
    private var appliedVCPUs: [Int] = []
    private var failNextStart = false
    private var parkInStop = false
    private var parkInStart = false
    private var parkIsRunning = false
    private var isRunningParks = 0

    let stopGate = LifecycleGate()
    let startGate = LifecycleGate()
    let isRunningGate = LifecycleGate()

    init(running: Bool, ramMB: Int?, vcpus: Int?) {
        self.running = running
        self.ramMB = ramMB
        self.vcpus = vcpus
    }

    var isRunningFlag: Bool { lock.withLock { running } }
    var starts: Int { lock.withLock { startCount } }
    var startAttemptsCount: Int { lock.withLock { startAttempts } }
    var stops: Int { lock.withLock { stopCount } }
    var closes: Int { lock.withLock { closeCount } }
    var currentRAMMB: Int? { lock.withLock { ramMB } }
    var currentVCPUs: Int? { lock.withLock { vcpus } }
    var appliedRAMMB: [Int] { lock.withLock { appliedRAM } }
    var appliedVCPUCounts: [Int] { lock.withLock { appliedVCPUs } }
    var isRunningParkCount: Int { lock.withLock { isRunningParks } }

    /// The next engine stop parks (the reshape is paused inside the stop).
    func parkNextStop() { lock.withLock { parkInStop = true } }
    /// The next engine start parks (the reshape is paused inside the restart).
    func parkNextStart() { lock.withLock { parkInStart = true } }
    /// The next liveness read returns the state captured at call entry and
    /// then parks: a stale read delivered late.
    func parkNextIsRunning() { lock.withLock { parkIsRunning = true } }
    /// The next engine start records the attempt and then throws.
    func failNextStartCall() { lock.withLock { failNextStart = true } }

    func makeHandle(console: TestLinuxGuestConsole) -> LinuxGuestSessionHandle {
        LinuxGuestSessionHandle(
            transport: console,
            start: { [self] in
                try await performStart()
            },
            stop: { [self] in
                if consume(&parkInStop) { await stopGate.arriveAndWait() }
                recordStop()
            },
            close: { [self] in
                if consume(&parkInStop) { await stopGate.arriveAndWait() }
                recordClose()
            },
            isRunning: { [self] in
                let captured = isRunningFlag
                if consume(&parkIsRunning) {
                    lock.withLock { isRunningParks += 1 }
                    await isRunningGate.arriveAndWait()
                }
                return captured
            },
            addForward: { _ in },
            removeForward: { _ in },
            setRAMMB: { [self] mb in
                lock.withLock {
                    appliedRAM.append(mb)
                    ramMB = mb
                }
            },
            setVCPUs: { [self] count in
                lock.withLock {
                    appliedVCPUs.append(count)
                    vcpus = count
                }
            }
        )
    }

    private func performStart() async throws {
        lock.withLock { startAttempts += 1 }
        if consume(&parkInStart) { await startGate.arriveAndWait() }
        if consume(&failNextStart) {
            throw LinuxGuestError.startFailed("scripted reshape restart failure")
        }
        lock.withLock {
            startCount += 1
            running = true
        }
    }

    private func recordStop() {
        lock.withLock {
            stopCount += 1
            running = false
        }
    }

    private func recordClose() {
        lock.withLock {
            closeCount += 1
            running = false
        }
    }

    private func consume(_ flag: inout Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let value = flag
        flag = false
        return value
    }
}

private final class ShapeSessionBook: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [ShapeGuestSession] = []

    func append(_ session: ShapeGuestSession) { lock.withLock { sessions.append(session) } }
    var all: [ShapeGuestSession] { lock.withLock { sessions } }
    var latest: ShapeGuestSession? { all.last }
}

private struct ShapeSessionFactory: LinuxGuestSessionCreating {
    let book: ShapeSessionBook
    let handler: @Sendable (String, String) -> [Data]

    func makeSession(
        descriptor: LinuxGuestEnvironmentDescriptor,
        image: LinuxGuestImage,
        limits: LinuxGuestLimits
    ) throws -> LinuxGuestSessionHandle {
        let session = ShapeGuestSession(
            running: false,
            ramMB: limits.clampedRAMMB(descriptor.ramMB),
            vcpus: descriptor.vcpus ?? 1
        )
        let console = TestLinuxGuestConsole { token in handler(descriptor.id, token) }
        book.append(session)
        return session.makeHandle(console: console)
    }
}

// MARK: - scripted Runtime v2 substrate

/// Records the exact Runtime v2 calls the registry makes and lets the test park
/// the budget plan (`planReshape`/`planRetier`) inside the lifecycle lock.
private actor ShapeV2Integrator: LinuxGuestRuntimeV2Integrating, LinuxGuestRuntimeV2StopOutcomeReporting {
    private let expandedRoot: URL
    private let root: URL
    private let planGate: LifecycleGate?
    private let stopOutcome: RuntimeV2StopOutcome
    private let workingDiskError: Error?
    private(set) var events: [String] = []

    init(
        expandedRoot: URL,
        root: URL,
        planGate: LifecycleGate? = nil,
        stopOutcome: RuntimeV2StopOutcome = .captured(generation: 1),
        workingDiskError: Error? = nil
    ) {
        self.expandedRoot = expandedRoot
        self.root = root
        self.planGate = planGate
        self.stopOutcome = stopOutcome
        self.workingDiskError = workingDiskError
    }

    func acquireSlot(environmentID: String, runtimeID: String, requestedMB: Int) async throws -> RuntimeV2Admission {
        events.append("acquireSlot:\(environmentID)")
        return RuntimeV2Admission(runtimeID: runtimeID, ramMB: requestedMB, downgraded: false)
    }

    func acquireShape(
        environmentID: String, runtimeID: String,
        request: GuestResourceRequest, imageSMPCapable: Bool,
        downgrade: GuestShapeDowngradePolicy
    ) async throws -> LinuxGuestShapeAdmission {
        events.append("acquire:\(environmentID)")
        return LinuxGuestShapeAdmission(
            runtimeID: runtimeID,
            ramMB: request.memory.mb,
            vcpus: request.vcpus.count,
            downgraded: false
        )
    }

    func imageSMPCapable(imageID: String) async -> Bool { true }

    func planReshape(
        environmentID: String, ramMB: Int, vcpus: Int, currentVCPUs: Int
    ) async throws {
        events.append("planReshape:\(environmentID):\(ramMB):\(vcpus)")
        if let planGate { await planGate.arriveAndWait() }
    }

    func confirmReshape(environmentID: String, ramMB: Int, vcpus: Int) async {
        events.append("confirmReshape:\(environmentID):\(ramMB):\(vcpus)")
    }

    func planRetier(environmentID: String, ramMB: Int) async throws {
        events.append("planRetier:\(environmentID):\(ramMB)")
        if let planGate { await planGate.arriveAndWait() }
    }

    func confirmTier(environmentID: String, ramMB: Int) async {
        events.append("confirmTier:\(environmentID):\(ramMB)")
    }

    func prepareWorkingDisk(
        environmentID: String, runtimeID: String, imageID: String,
        legacyWritableDirectory: URL?, targetCapacityBytes: Int64
    ) async throws -> RuntimeV2WorkingDisk {
        events.append("disk:\(environmentID)")
        if let workingDiskError { throw workingDiskError }
        let url = root.appendingPathComponent("shape-\(runtimeID).img")
        FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 0, count: 1024))
        return RuntimeV2WorkingDisk(diskURL: url, capacityBytes: 1024)
    }

    func environmentDataDirectory(environmentID: String) async throws -> URL {
        events.append("data:\(environmentID)")
        let url = root.appendingPathComponent("shape-data/\(environmentID)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func completeStop(environmentID: String, runtimeID: String, imageID: String, clean: Bool) async {
        events.append("completeStop:\(environmentID):\(clean)")
    }

    func completeStopResult(
        environmentID: String, runtimeID: String, imageID: String, clean: Bool
    ) async -> RuntimeV2StopOutcome {
        events.append("stopResult:\(environmentID):\(clean)")
        return stopOutcome
    }

    func releaseSlot(environmentID: String, runtimeID: String) async {
        events.append("release:\(environmentID)")
    }

    func expandedImageDirectory(imageID: String) async throws -> URL { expandedRoot }
    func isImageVerified(imageID: String) async -> Bool { true }
    func isImageVerifiedWithoutMigration(imageID: String) async -> Bool { true }
    func recordedRunnerCapabilities(environmentID: String) async -> String? { nil }
    func recordRunnerCapabilities(_ capabilities: String, environmentID: String) async {}
    func workingDiskCapacityBytes(environmentID: String, runtimeID: String) async -> Int64? { 1024 }
    func queuedStarts() async -> Int { 0 }
}

// MARK: - fixtures

private func shapeDescriptor(id: String, imageID: String = "shape-image") -> LinuxGuestEnvironmentDescriptor {
    LinuxGuestEnvironmentDescriptor(id: id, ownerID: "owner", imageID: imageID)
}

private func shapeImage(id: String = "shape-image") -> LinuxGuestImage {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("floe-shape-test-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let bios = directory.appendingPathComponent("bbl64.bin")
    let contents = Data("bios".utf8)
    FileManager.default.createFile(atPath: bios.path, contents: contents)
    return LinuxGuestImage(
        id: id,
        biosPath: bios.path,
        qualified: true,
        qualificationEvidence: "shape lifecycle test \(UUID().uuidString)",
        qualificationRun: "shape-run-1",
        artifacts: [
            LinuxGuestImageArtifact(
                role: .bios, path: bios.path,
                sha512: FloeDigest.sha512Hex(contents), bytes: Int64(contents.count)
            )
        ]
    )
}

/// A minimal qualified image whose artifact path is relative to the verified
/// expanded directory, exactly like the Runtime v2 boot path consumes.
private func shapeV2Image(id: String, directory: URL) throws -> LinuxGuestImage {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let bios = Data("bios".utf8)
    try bios.write(to: directory.appendingPathComponent("bbl64.bin"))
    return LinuxGuestImage(
        id: id,
        biosPath: "bbl64.bin",
        qualified: true,
        qualificationRun: "shape-lifecycle-tests",
        artifacts: [
            LinuxGuestImageArtifact(
                role: .bios, path: "bbl64.bin",
                sha512: FloeDigest.sha512Hex(bios), bytes: Int64(bios.count)
            )
        ]
    )
}

private func shapeCaps(_ token: String) -> [Data] {
    [Data("\u{1e}FLOE-CAPS \(token) runner=2.0.0 protocol=3 maxCommands=8 maxSessions=4\u{1e}\u{1e}FLOE-END \(token) 0\u{1e}".utf8)]
}

private func shapeOKReply(_ token: String) -> [Data] {
    var data = Data()
    data.append(Data("\u{1e}FLOE-BEGIN \(token)\u{1e}\u{1e}FLOE-OUT \(token)\u{1e}".utf8))
    data.append(Data("\u{1e}FLOE-END \(token) 0\u{1e}".utf8))
    return [data]
}

// MARK: - tests

final class LinuxGuestShapeLifecycleTests: XCTestCase {
    private func makeRegistry(
        environmentID: String,
        images: [String: LinuxGuestImage],
        factory: any LinuxGuestSessionCreating,
        runtimeV2: (any LinuxGuestRuntimeV2Integrating)? = nil
    ) -> TinyEMULinuxGuestRegistry {
        TinyEMULinuxGuestRegistry(
            environments: FakeEnvironmentProvider(descriptors: [
                environmentID: shapeDescriptor(id: environmentID, imageID: images.keys.first ?? "shape-image")
            ]),
            images: FakeImageResolver(images: images),
            limits: .standard,
            factory: factory,
            runtimeV2: runtimeV2
        )
    }

    private func makeLegacyRegistry(
        environmentID: String,
        book: ShapeSessionBook
    ) -> TinyEMULinuxGuestRegistry {
        makeRegistry(
            environmentID: environmentID,
            images: ["shape-image": shapeImage()],
            factory: ShapeSessionFactory(book: book) { _, token in
                token.hasPrefix("hello-") ? shapeCaps(token) : shapeOKReply(token)
            }
        )
    }

    private func awaitTeardownRegistered(
        _ registry: TinyEMULinuxGuestRegistry, environmentID: String
    ) async -> Bool {
        await waitUntil {
            (await registry.lifecycleDiagnostics(environmentID: environmentID)).teardownInFlight
        }
    }

    private func assertGuestBusy(_ error: Error?, file: StaticString = #filePath, line: UInt = #line) {
        guard let error = error as? LinuxGuestError else {
            return XCTFail("expected a LinuxGuestError, got \(String(describing: error))", file: file, line: line)
        }
        guard case .guestBusy = error else {
            return XCTFail("expected guestBusy, got \(error)", file: file, line: line)
        }
    }

    private func assertNotRunning(_ error: Error?, file: StaticString = #filePath, line: UInt = #line) {
        guard let error = error as? LinuxGuestError else {
            return XCTFail("expected a LinuxGuestError, got \(String(describing: error))", file: file, line: line)
        }
        guard case .notRunning = error else {
            return XCTFail("expected notRunning, got \(error)", file: file, line: line)
        }
    }

    /// Reshape parked inside the engine stop, then a stop lands: the stop owns
    /// the teardown and the resuming reshape must not restart the old handle
    /// or rebook anything.
    func testReshapeParkedInEngineStopCannotRestartAfterStop() async throws {
        let environmentID = "env-shape-stop"
        let book = ShapeSessionBook()
        let registry = makeLegacyRegistry(environmentID: environmentID, book: book)
        let started = try await registry.start(environmentID: environmentID, taskID: "task-1")
        XCTAssertTrue(started)
        guard let session = book.latest else { return XCTFail("no session was created") }
        XCTAssertEqual(session.starts, 1)
        XCTAssertEqual(session.currentRAMMB, 256)

        session.parkNextStop()
        let reshape = Task { await shapeChangeError(registry, environmentID: environmentID, ramMB: 512, vcpus: 1) }
        let enteredStop = await waitUntil { session.stopGate.arrivalCount == 1 }
        XCTAssertTrue(enteredStop, "the reshape did not reach the engine stop")
        let parkedInShapeChange = await waitUntil {
            (await registry.lifecycleDiagnostics(environmentID: environmentID)).shapeChangeInFlight
        }
        XCTAssertTrue(parkedInShapeChange, "the reshape does not own the lifecycle lock")

        let stop = Task { await registry.stop(environmentID: environmentID) }
        let teardownRegistered = await awaitTeardownRegistered(registry, environmentID: environmentID)
        XCTAssertTrue(teardownRegistered, "the stop did not register a teardown")

        session.stopGate.open()
        await stop.value
        let error = await reshape.value
        assertGuestBusy(error)

        let running = await registry.status(environmentID: environmentID).running
        XCTAssertFalse(running)
        XCTAssertEqual(session.starts, 1, "the stale reshape restarted the released handle")
        XCTAssertEqual(session.stops, 1, "exactly the reshape's own stop ran")
        XCTAssertEqual(session.closes, 1, "the teardown closed the handle exactly once")
        XCTAssertEqual(session.appliedRAMMB, [], "the reshape applied a tier after the stop won")
        let activeGuests = await registry.activeGuestCount
        let reserved = await registry.reservedGuestRAMMB
        XCTAssertEqual(activeGuests, 0)
        XCTAssertEqual(reserved, 0)
        let identity = await registry.runtimeIdentity(environmentID: environmentID)
        XCTAssertNil(identity.runtimeID, "a released handle was re-registered as the runtime identity")
        let supports = await registry.supports(environmentID: environmentID)
        XCTAssertFalse(supports)
    }

    /// RAM-only retier parked inside the engine stop, then a stop lands: same
    /// contract through `setMemoryTier`.
    func testRetierParkedInEngineStopCannotRestartAfterStop() async throws {
        let environmentID = "env-retier-stop"
        let book = ShapeSessionBook()
        let registry = makeLegacyRegistry(environmentID: environmentID, book: book)
        let started = try await registry.start(environmentID: environmentID, taskID: "task-1")
        XCTAssertTrue(started)
        guard let session = book.latest else { return XCTFail("no session was created") }

        session.parkNextStop()
        let retier = Task { await retierError(registry, environmentID: environmentID, ramMB: 768) }
        let enteredStop = await waitUntil { session.stopGate.arrivalCount == 1 }
        XCTAssertTrue(enteredStop, "the retier did not reach the engine stop")

        let stop = Task { await registry.stop(environmentID: environmentID) }
        let teardownRegistered = await awaitTeardownRegistered(registry, environmentID: environmentID)
        XCTAssertTrue(teardownRegistered, "the stop did not register a teardown")

        session.stopGate.open()
        await stop.value
        let error = await retier.value
        assertGuestBusy(error)

        let running = await registry.status(environmentID: environmentID).running
        XCTAssertFalse(running)
        XCTAssertEqual(session.starts, 1, "the stale retier restarted the released handle")
        XCTAssertEqual(session.stops, 1)
        XCTAssertEqual(session.appliedRAMMB, [], "the retier applied a tier after the stop won")
        let activeGuests = await registry.activeGuestCount
        XCTAssertEqual(activeGuests, 0)
    }

    /// A task cancelled before the disruption leaves the guest running and the
    /// recorded shape untouched.
    func testCancelledShapeChangeBeforeDisruptionLeavesGuestUntouched() async throws {
        let environmentID = "env-shape-cancelled"
        let book = ShapeSessionBook()
        let registry = makeLegacyRegistry(environmentID: environmentID, book: book)
        _ = try await registry.start(environmentID: environmentID, taskID: "task-1")
        guard let session = book.latest else { return XCTFail("no session was created") }

        session.parkNextIsRunning()
        let reshape = Task { await shapeChangeError(registry, environmentID: environmentID, ramMB: 512, vcpus: 1) }
        let parked = await waitUntil { session.isRunningParkCount == 1 }
        XCTAssertTrue(parked, "the reshape did not reach the identity probe")
        reshape.cancel()
        session.isRunningGate.open()

        let error = await reshape.value
        guard let reshapeError = error else {
            return XCTFail("cancelling the shape change must not leave it reported as applied")
        }
        XCTAssertTrue(reshapeError is CancellationError, "expected cancellation, got \(reshapeError)")
        XCTAssertTrue(session.isRunningFlag, "cancellation must not disturb the running guest")
        XCTAssertEqual(session.stops, 0)
        XCTAssertEqual(session.starts, 1)
        XCTAssertEqual(session.appliedRAMMB, [])
        let reserved = await registry.reservedGuestRAMMB
        XCTAssertEqual(reserved, 256)
        let supports = await registry.supports(environmentID: environmentID)
        XCTAssertTrue(supports, "the session was not retained across the failed reshape")
    }

    /// A failed restart restores the previous shape and keeps the session.
    func testFailedRestartRollsBackShapeAndKeepsSession() async throws {
        let environmentID = "env-shape-rollback"
        let book = ShapeSessionBook()
        let registry = makeLegacyRegistry(environmentID: environmentID, book: book)
        _ = try await registry.start(environmentID: environmentID, taskID: "task-1")
        guard let session = book.latest else { return XCTFail("no session was created") }

        session.failNextStartCall()
        let error = await shapeChangeError(registry, environmentID: environmentID, ramMB: 512, vcpus: 1)
        guard let guestError = error as? LinuxGuestError, case .startFailed = guestError else {
            return XCTFail("expected the scripted restart failure, got \(String(describing: error))")
        }
        XCTAssertTrue(session.isRunningFlag, "the rollback did not bring the guest back")
        XCTAssertEqual(session.appliedRAMMB, [512, 256], "the rollback did not restore the previous tier")
        XCTAssertEqual(session.starts, 2, "initial start + rollback restart")
        XCTAssertEqual(session.startAttemptsCount, 3, "initial + failed reshape restart + rollback")
        let status = await registry.status(environmentID: environmentID)
        XCTAssertTrue(status.running)
        XCTAssertEqual(status.ramMB, 256, "the recorded shape drifted after the failed restart")
        let reserved = await registry.reservedGuestRAMMB
        XCTAssertEqual(reserved, 256)
        let supports = await registry.supports(environmentID: environmentID)
        XCTAssertTrue(supports)
    }

    /// A failed restart with a stop already registered must not resurrect the
    /// guest: the rollback restart is skipped and the stop owns the handle.
    func testFailedRestartDoesNotResurrectWhenStopIsRegistered() async throws {
        let environmentID = "env-shape-failed-stop"
        let book = ShapeSessionBook()
        let registry = makeLegacyRegistry(environmentID: environmentID, book: book)
        _ = try await registry.start(environmentID: environmentID, taskID: "task-1")
        guard let session = book.latest else { return XCTFail("no session was created") }

        session.parkNextStart()
        session.failNextStartCall()
        let reshape = Task { await shapeChangeError(registry, environmentID: environmentID, ramMB: 512, vcpus: 1) }
        let restartEntered = await waitUntil { session.startAttemptsCount == 2 }
        XCTAssertTrue(restartEntered, "the reshape did not enter its restart")

        let stop = Task { await registry.stop(environmentID: environmentID) }
        let teardownRegistered = await awaitTeardownRegistered(registry, environmentID: environmentID)
        XCTAssertTrue(teardownRegistered, "the stop did not register a teardown")

        session.startGate.open()
        let error = await reshape.value
        guard let guestError = error as? LinuxGuestError, case .startFailed = guestError else {
            return XCTFail("expected the scripted restart failure, got \(String(describing: error))")
        }
        await stop.value
        XCTAssertFalse(session.isRunningFlag)
        XCTAssertEqual(session.starts, 1, "the rollback restarted the guest after a registered stop")
        XCTAssertEqual(session.appliedRAMMB, [512, 256])
        let activeGuests = await registry.activeGuestCount
        XCTAssertEqual(activeGuests, 0)
    }

    /// A start attempted while a shape change owns the environment is refused
    /// instead of booting a second VM or fighting the pending restart; the
    /// change itself still completes normally once nothing else intervenes.
    func testStartIsRefusedWhileShapeChangeOwnsTheEnvironment() async throws {
        let environmentID = "env-shape-start"
        let book = ShapeSessionBook()
        let registry = makeLegacyRegistry(environmentID: environmentID, book: book)
        _ = try await registry.start(environmentID: environmentID, taskID: "task-1")
        guard let session = book.latest else { return XCTFail("no session was created") }

        session.parkNextStop()
        let reshape = Task { await shapeChangeError(registry, environmentID: environmentID, ramMB: 512, vcpus: 1) }
        let enteredStop = await waitUntil { session.stopGate.arrivalCount == 1 }
        XCTAssertTrue(enteredStop, "the reshape did not reach the engine stop")

        do {
            _ = try await registry.start(environmentID: environmentID, taskID: "task-2")
            XCTFail("a start must not slip into a shape change's stop/restart window")
        } catch let error as LinuxGuestError {
            guard case .guestBusy = error else {
                return XCTFail("expected guestBusy, got \(error)")
            }
        }
        XCTAssertEqual(session.startAttemptsCount, 1, "the refused start still booted something")
        XCTAssertEqual(book.all.count, 1, "the refused start created a second handle")

        session.stopGate.open()
        let error = await reshape.value
        XCTAssertNil(error, "the reshape failed without any teardown: \(String(describing: error))")
        XCTAssertTrue(session.isRunningFlag)
        XCTAssertEqual(session.starts, 2, "the completed reshape restarted the handle")
        XCTAssertEqual(session.currentRAMMB, 512)
        let status = await registry.status(environmentID: environmentID)
        XCTAssertTrue(status.running)
        XCTAssertEqual(status.ramMB, 512)
        let reserved = await registry.reservedGuestRAMMB
        XCTAssertEqual(reserved, 512)
    }

    /// A stop plus a replacement start that completes while a stale reshape
    /// waits: the stale reshape must never touch the replacement session.
    func testStaleShapeChangeCannotMutateReplacementSession() async throws {
        let environmentID = "env-shape-replaced"
        let book = ShapeSessionBook()
        let registry = makeLegacyRegistry(environmentID: environmentID, book: book)
        _ = try await registry.start(environmentID: environmentID, taskID: "task-1")
        guard let first = book.latest else { return XCTFail("no session was created") }

        first.parkNextIsRunning()
        let reshape = Task { await shapeChangeError(registry, environmentID: environmentID, ramMB: 512, vcpus: 1) }
        let parked = await waitUntil { first.isRunningParkCount == 1 }
        XCTAssertTrue(parked, "the reshape did not reach the identity probe")

        // The old guest is stopped and a replacement session is booted while
        // the stale change is still waiting for its stale probe to return.
        await registry.stop(environmentID: environmentID)
        XCTAssertFalse(first.isRunningFlag)
        _ = try await registry.start(environmentID: environmentID, taskID: "task-2")
        guard let second = book.latest, second !== first else {
            return XCTFail("a replacement session was not created")
        }
        XCTAssertEqual(second.starts, 1)

        first.isRunningGate.open()
        let error = await reshape.value
        assertNotRunning(error)

        XCTAssertTrue(second.isRunningFlag, "the stale reshape stopped or mutated the replacement")
        XCTAssertEqual(second.starts, 1)
        XCTAssertEqual(second.currentRAMMB, 256)
        XCTAssertEqual(first.starts, 1, "the stale reshape restarted the old handle")
        XCTAssertEqual(first.appliedRAMMB, [])
        let status = await registry.status(environmentID: environmentID)
        XCTAssertTrue(status.running)
        XCTAssertEqual(status.ramMB, 256)
        let reserved = await registry.reservedGuestRAMMB
        XCTAssertEqual(reserved, 256)
        let supports = await registry.supports(environmentID: environmentID)
        XCTAssertTrue(supports, "the replacement session is no longer the owned one")
    }

    /// Runtime v2: a stop registered while `planReshape` is parked must be the
    /// only stop; the reshape never confirms or releases anything.
    func testRuntimeV2ReshapeParkedInPlanAbortsWithoutConfirming() async throws {
        let environmentID = "env-v2-plan"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-shape-v2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let expanded = root.appendingPathComponent("expanded", isDirectory: true)
        let image = try shapeV2Image(id: "shape-v2-image", directory: expanded)
        let planGate = LifecycleGate()
        let integrator = ShapeV2Integrator(expandedRoot: expanded, root: root, planGate: planGate)
        let book = ShapeSessionBook()
        let registry = makeRegistry(
            environmentID: environmentID,
            images: [image.id: image],
            factory: ShapeSessionFactory(book: book) { _, token in
                token.hasPrefix("hello-") ? shapeCaps(token) : shapeOKReply(token)
            },
            runtimeV2: integrator
        )
        _ = try await registry.start(environmentID: environmentID, taskID: "task-1")
        guard let session = book.latest else { return XCTFail("no session was created") }

        let reshape = Task { await shapeChangeError(registry, environmentID: environmentID, ramMB: 512, vcpus: 2) }
        await planGate.awaitArrival()
        let planned = await waitUntil { await integrator.events.contains("planReshape:\(environmentID):512:2") }
        XCTAssertTrue(planned)

        let stop = Task { await registry.stop(environmentID: environmentID) }
        let teardownRegistered = await awaitTeardownRegistered(registry, environmentID: environmentID)
        XCTAssertTrue(teardownRegistered, "the stop did not register a teardown")

        planGate.open()
        let error = await reshape.value
        assertGuestBusy(error)
        await stop.value

        let events = await integrator.events
        XCTAssertEqual(
            events,
            [
                "acquire:\(environmentID)", "disk:\(environmentID)", "data:\(environmentID)",
                "planReshape:\(environmentID):512:2",
                "stopResult:\(environmentID):true", "release:\(environmentID)",
            ],
            "unexpected Runtime v2 call order: \(events)"
        )
        XCTAssertFalse(events.contains { $0.hasPrefix("confirm") }, "the stale reshape confirmed a shape")
        XCTAssertEqual(session.starts, 1, "the reshape restarted the handle")
        XCTAssertEqual(session.stops, 0)
        let running = await registry.status(environmentID: environmentID).running
        XCTAssertFalse(running)
        let reserved = await registry.reservedGuestRAMMB
        XCTAssertEqual(reserved, 0)
    }

    /// Runtime v2 RAM retier parked in `planRetier`: same contract through the
    /// RAM-only seam, no tier confirm after the stop.
    func testRuntimeV2RetierParkedInPlanAbortsWithoutConfirmingTier() async throws {
        let environmentID = "env-v2-retier"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-retier-v2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let expanded = root.appendingPathComponent("expanded", isDirectory: true)
        let image = try shapeV2Image(id: "shape-retier-image", directory: expanded)
        let planGate = LifecycleGate()
        let integrator = ShapeV2Integrator(expandedRoot: expanded, root: root, planGate: planGate)
        let book = ShapeSessionBook()
        let registry = makeRegistry(
            environmentID: environmentID,
            images: [image.id: image],
            factory: ShapeSessionFactory(book: book) { _, token in
                token.hasPrefix("hello-") ? shapeCaps(token) : shapeOKReply(token)
            },
            runtimeV2: integrator
        )
        _ = try await registry.start(environmentID: environmentID, taskID: "task-1")
        guard let session = book.latest else { return XCTFail("no session was created") }

        let retier = Task { await retierError(registry, environmentID: environmentID, ramMB: 768) }
        await planGate.awaitArrival()
        let planned = await waitUntil { await integrator.events.contains("planRetier:\(environmentID):768") }
        XCTAssertTrue(planned)

        let stop = Task { await registry.stop(environmentID: environmentID) }
        let teardownRegistered = await awaitTeardownRegistered(registry, environmentID: environmentID)
        XCTAssertTrue(teardownRegistered, "the stop did not register a teardown")

        planGate.open()
        let error = await retier.value
        assertGuestBusy(error)
        await stop.value

        let events = await integrator.events
        XCTAssertEqual(
            events,
            [
                "acquire:\(environmentID)", "disk:\(environmentID)", "data:\(environmentID)",
                "planRetier:\(environmentID):768",
                "stopResult:\(environmentID):true", "release:\(environmentID)",
            ],
            "unexpected Runtime v2 call order: \(events)"
        )
        XCTAssertFalse(events.contains { $0.hasPrefix("confirm") })
        XCTAssertEqual(session.starts, 1)
        XCTAssertEqual(session.stops, 0)
        XCTAssertEqual(session.appliedRAMMB, [])
        let reserved = await registry.reservedGuestRAMMB
        XCTAssertEqual(reserved, 0)
    }

    /// Runtime v2: the destructive teardown (delta capture, lease and pool-slot
    /// release) never overlaps an in-flight reshape restart. A stop registered
    /// while the restart is parked must not capture/release the working disk
    /// until the restart returned and the reshape aborted.
    func testRuntimeV2StopWaitsForInFlightRestartBeforeReleasingDiskAndLease() async throws {
        let environmentID = "env-v2-restart"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-restart-v2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let expanded = root.appendingPathComponent("expanded", isDirectory: true)
        let image = try shapeV2Image(id: "shape-restart-image", directory: expanded)
        let integrator = ShapeV2Integrator(expandedRoot: expanded, root: root)
        let book = ShapeSessionBook()
        let registry = makeRegistry(
            environmentID: environmentID,
            images: [image.id: image],
            factory: ShapeSessionFactory(book: book) { _, token in
                token.hasPrefix("hello-") ? shapeCaps(token) : shapeOKReply(token)
            },
            runtimeV2: integrator
        )
        _ = try await registry.start(environmentID: environmentID, taskID: "task-1")
        guard let session = book.latest else { return XCTFail("no session was created") }

        session.parkNextStart()
        let reshape = Task { await shapeChangeError(registry, environmentID: environmentID, ramMB: 512, vcpus: 2) }
        let restartEntered = await waitUntil { session.startAttemptsCount == 2 }
        XCTAssertTrue(restartEntered, "the reshape did not enter its restart")

        let stop = Task { await registry.stop(environmentID: environmentID) }
        let teardownRegistered = await awaitTeardownRegistered(registry, environmentID: environmentID)
        XCTAssertTrue(teardownRegistered, "the stop did not register a teardown")

        // The restore is still in flight: the stop must not have captured the
        // delta, released the lease or freed the pool slot yet.
        let eventsWhileParked = await integrator.events
        XCTAssertFalse(
            eventsWhileParked.contains { $0.hasPrefix("stop") || $0.hasPrefix("release") },
            "the teardown released the disk/lease while the reshape restart was in flight: \(eventsWhileParked)"
        )

        session.startGate.open()
        let error = await reshape.value
        assertGuestBusy(error)
        await stop.value

        let events = await integrator.events
        let destructive = events.filter { $0.hasPrefix("stop") || $0.hasPrefix("release") }
        XCTAssertEqual(destructive, ["stopResult:\(environmentID):true", "release:\(environmentID)"])
        XCTAssertEqual(session.starts, 2, "initial start + completed restart owned by the stop")
        XCTAssertFalse(session.isRunningFlag)
        let reserved = await registry.reservedGuestRAMMB
        XCTAssertEqual(reserved, 0)
    }

    /// C2's result-carrying stop is consumed: a retained-for-repair capture is
    /// never reported as a clean, saved shutdown.
    func testRetainedForRepairStopIsNeverReportedClean() async throws {
        let environmentID = "env-v2-repair"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-repair-v2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let expanded = root.appendingPathComponent("expanded", isDirectory: true)
        let image = try shapeV2Image(id: "shape-repair-image", directory: expanded)
        let integrator = ShapeV2Integrator(
            expandedRoot: expanded, root: root,
            stopOutcome: .retainedForRepair(reason: "capture refused: base digest mismatch")
        )
        let book = ShapeSessionBook()
        let registry = makeRegistry(
            environmentID: environmentID,
            images: [image.id: image],
            factory: ShapeSessionFactory(book: book) { _, token in
                token.hasPrefix("hello-") ? shapeCaps(token) : shapeOKReply(token)
            },
            runtimeV2: integrator
        )
        _ = try await registry.start(environmentID: environmentID, taskID: "task-1")
        guard let session = book.latest else { return XCTFail("no session was created") }

        await registry.stop(environmentID: environmentID)

        let events = await integrator.events
        XCTAssertEqual(Array(events.suffix(2)), ["stopResult:\(environmentID):true", "release:\(environmentID)"])
        let status = await registry.status(environmentID: environmentID)
        XCTAssertFalse(status.running)
        guard let lastError = status.lastError else {
            return XCTFail("a refused capture was reported without any error state")
        }
        XCTAssertTrue(
            lastError.contains("could NOT be saved"),
            "the refused capture was smoothed over: \(lastError)"
        )
        let reserved = await registry.reservedGuestRAMMB
        XCTAssertEqual(reserved, 0, "the arbiter slot is released by the actual stop")
        XCTAssertEqual(session.starts, 1)
    }

    /// The same result consumption holds for startup error cleanup.
    func testStartupCleanupConsumesStopResult() async throws {
        let environmentID = "env-v2-startup-repair"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-startup-repair-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let expanded = root.appendingPathComponent("expanded", isDirectory: true)
        let image = try shapeV2Image(id: "shape-startup-image", directory: expanded)
        let integrator = ShapeV2Integrator(
            expandedRoot: expanded, root: root,
            stopOutcome: .retainedForRepair(reason: "boot disk capture refused"),
            workingDiskError: LinuxGuestError.invalidConfiguration("scripted working disk failure")
        )
        let book = ShapeSessionBook()
        let registry = makeRegistry(
            environmentID: environmentID,
            images: [image.id: image],
            factory: ShapeSessionFactory(book: book) { _, token in
                // The failure lands after admission and before any VM boot, so
                // the start's cleanup owns the stop-outcome consumption.
                token.hasPrefix("hello-") ? shapeCaps(token) : shapeOKReply(token)
            },
            runtimeV2: integrator
        )

        do {
            _ = try await registry.start(environmentID: environmentID, taskID: "task-1")
            XCTFail("a start whose runner never answers must fail")
        } catch {
            // expected: the runner upgrade/handshake failed
        }
        let status = await registry.status(environmentID: environmentID)
        XCTAssertFalse(status.running)
        guard let lastError = status.lastError else {
            return XCTFail("a refused capture during startup cleanup was reported without any error state")
        }
        XCTAssertTrue(
            lastError.contains("could NOT be saved"),
            "the refused capture was smoothed over: \(lastError)"
        )
        let reserved = await registry.reservedGuestRAMMB
        XCTAssertEqual(reserved, 0)
    }
}
