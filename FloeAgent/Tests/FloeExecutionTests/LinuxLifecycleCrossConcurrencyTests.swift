// FloeExecutionTests — cross-concurrency between lifecycle hard restart and a
// direct shell-style guest start on the REAL registry.
//
// The integration review required that serialization/state gating for a
// stop→start window live on the shared service/lease path — not only on the
// lifecycle actor's own busy set — so that a parameterless exec.shell (a direct
// registry start) cannot re-own the environment while a hard restart is between
// its stop and its start. Two interleavings are covered deterministically:
//
//  * inside the old engine's stop (the registry's teardown gate), and
//  * after the stop is fully complete and before the replacement start, via
//    the manager's restart-window barrier (the window this suite previously
//    did not cover).
//
// Both prove the concurrent direct start is refused and boots nothing; after
// the restart exactly one fresh guest runs at the requested shape.

import Foundation
import XCTest
import FloeCore
import FloeTools
@testable import FloeExecution

// MARK: - one-shot gate

private final class SimpleGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Synchronous helper: NSLock must not be taken in an async context.
    private func park(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if open {
            lock.unlock()
            continuation.resume()
            return
        }
        waiters.append(continuation)
        lock.unlock()
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            park(continuation)
        }
    }

    func release() {
        lock.lock()
        open = true
        let pending = waiters
        waiters = []
        lock.unlock()
        for continuation in pending { continuation.resume() }
    }
}

// MARK: - parkable engine + factory

private final class ParkEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    var startCount = 0
    var stopCount = 0
    /// When true the NEXT start throws (a scripted replacement-start failure).
    private var failNextStart = false
    /// When true a stop never clears the running flag (a scripted engine that
    /// survives its stop budget; the registry must quarantine it).
    private var survivesStop = false
    /// When non-nil the next engine stop parks until the gate is released.
    private var parkStopGate: SimpleGate?

    func performStart() async throws {
        let shouldFail: Bool = lock.withLock {
            if failNextStart {
                failNextStart = false
                return true
            }
            startCount += 1
            running = true
            return false
        }
        if shouldFail {
            throw LinuxGuestError.startFailed("scripted replacement start failure")
        }
    }

    /// Synchronous helper: NSLock must not be taken in an async context.
    private func beginStop() -> SimpleGate? {
        lock.lock()
        stopCount += 1
        if !survivesStop { running = false }
        let gate = parkStopGate
        parkStopGate = nil
        lock.unlock()
        return gate
    }

    func parkNextStop(_ gate: SimpleGate) {
        lock.withLock { parkStopGate = gate }
    }

    func failNextStartAttempt() {
        lock.withLock { failNextStart = true }
    }

    func surviveEveryStop() {
        lock.withLock { survivesStop = true; running = true }
    }

    func performStop() async {
        let gate = beginStop()
        if let gate { await gate.wait() }
    }

    var isRunning: Bool { lock.withLock { running } }
    var starts: Int { lock.withLock { startCount } }
    var stops: Int { lock.withLock { stopCount } }
}

private final class EngineBook: @unchecked Sendable {
    private let lock = NSLock()
    private var engines: [ParkEngine] = []
    /// Consumed by the next session factory call: the new engine fails its
    /// first start (a scripted replacement-start failure).
    private var failNextStart = false

    func append(_ engine: ParkEngine) { lock.withLock { engines.append(engine) } }
    var all: [ParkEngine] { lock.withLock { engines } }

    func armNextStartFailure() { lock.withLock { failNextStart = true } }

    func consumeStartFailure() -> Bool {
        lock.withLock {
            let armed = failNextStart
            failNextStart = false
            return armed
        }
    }
}

private struct ParkSessionFactory: LinuxGuestSessionCreating {
    let book: EngineBook

    func makeSession(
        descriptor: LinuxGuestEnvironmentDescriptor,
        image: LinuxGuestImage,
        limits: LinuxGuestLimits
    ) throws -> LinuxGuestSessionHandle {
        let engine = ParkEngine()
        if book.consumeStartFailure() {
            engine.failNextStartAttempt()
        }
        book.append(engine)
        let console = TestLinuxGuestConsole()
        return LinuxGuestSessionHandle(
            transport: console,
            start: { try await engine.performStart() },
            stop: { await engine.performStop() },
            close: { await engine.performStop() },
            isRunning: { engine.isRunning },
            addForward: { _ in },
            removeForward: { _ in }
        )
    }
}

private func qualifiedImage() -> LinuxGuestImage {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("floe-cross-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let bios = directory.appendingPathComponent("bbl64.bin")
    let contents = Data("bios".utf8)
    FileManager.default.createFile(atPath: bios.path, contents: contents)
    return LinuxGuestImage(
        id: "cross-image",
        biosPath: bios.path,
        qualified: true,
        qualificationEvidence: "cross concurrency \(UUID().uuidString)",
        qualificationRun: "cross-run-1",
        artifacts: [
            LinuxGuestImageArtifact(
                role: .bios, path: bios.path,
                sha512: FloeDigest.sha512Hex(contents), bytes: Int64(contents.count)
            )
        ]
    )
}

final class LinuxLifecycleCrossConcurrencyTests: XCTestCase {
    private let environmentID = "env-cross"

    private func makeRegistry(book: EngineBook, environmentID: String? = nil) -> TinyEMULinuxGuestRegistry {
        let id = environmentID ?? self.environmentID
        let image = qualifiedImage()
        return TinyEMULinuxGuestRegistry(
            environments: FakeEnvironmentProvider(descriptors: [
                id: LinuxGuestEnvironmentDescriptor(
                    id: id, ownerID: "owner", imageID: image.id
                )
            ]),
            images: FakeImageResolver(images: [image.id: image]),
            limits: .standard,
            factory: ParkSessionFactory(book: book)
        )
    }

    /// A direct shell-style start landing while the hard restart is inside its
    /// stop is refused by the shared registry (stop in progress) and never
    /// boots; after the restart, exactly one fresh guest is running.
    func testDirectStartRefusedWhileHardRestartStopping() async throws {
        // Local copy: the Task closures below must capture a value, not the
        // XCTestCase instance through the property.
        let environmentID = "env-cross"
        let book = EngineBook()
        let registry = makeRegistry(book: book)
        let service = TinyEMULinuxCommandService(registry: registry)
        let manager = LinuxGuestLifecycleManager(controller: service)

        // Boot the original guest.
        _ = try await registry.start(environmentID: environmentID, taskID: nil)
        let oldEngine = try XCTUnwrap(book.all.first)
        XCTAssertEqual(book.all.count, 1)

        // Arm the old engine so the hard restart's stop parks, then start the
        // hard restart and wait until the registry published its teardown.
        let stopGate = SimpleGate()
        oldEngine.parkNextStop(stopGate)
        let restartTask = Task {
            try await manager.hardRestart(environmentID: environmentID, config: .init())
        }

        // Wait until the old engine's stop actually entered (stopCount bumped)
        // — i.e. the registry's teardownsInFlight gate is published.
        try await waitUntil { oldEngine.stops == 1 }
        try await Task.sleep(nanoseconds: 20_000_000)

        // A direct shell-style start now: must be refused by the shared
        // registry, not blocked by the lifecycle actor (it bypasses the
        // manager entirely).
        let directStart = Task {
            try await registry.start(environmentID: environmentID, taskID: "shell")
        }
        let directError = await directStart.result
        guard case .failure(let error) = directError else {
            return XCTFail("direct start must be refused during a stop")
        }
        guard let guestError = error as? LinuxGuestError,
              case .stopFailed = guestError else {
            return XCTFail("expected a stop-in-progress refusal, got \(error)")
        }

        // Release the parked stop; the hard restart completes with a new guest.
        stopGate.release()
        let receipt = try await restartTask.value
        XCTAssertEqual(receipt.phase, .running)
        XCTAssertFalse(receipt.reused)
        XCTAssertEqual(book.all.count, 2, "a fresh engine must have been created")
        let newEngine = try XCTUnwrap(book.all.last)
        XCTAssertTrue(newEngine.isRunning)
        XCTAssertEqual(newEngine.starts, 1)
        XCTAssertFalse(oldEngine === newEngine)
        let finalSupports = await registry.supports(environmentID: environmentID)
        XCTAssertTrue(finalSupports)
    }

    /// The real race found by the integration review: after the old instance's
    /// stop is fully complete (session removed, teardown markers and lifecycle
    /// release done) and before the restart's replacement start begins. The
    /// manager's restart-window barrier parks exactly there. A direct
    /// shell-style start, execute, terminal and shape change must all be
    /// refused by the shared registry, and the completed restart must run at
    /// the requested shape with exactly one replacement engine.
    func testDirectStartRefusedBetweenRestartStopAndStart() async throws {
        let environmentID = "env-cross-window"
        let book = EngineBook()
        let registry = makeRegistry(book: book, environmentID: environmentID)
        let service = TinyEMULinuxCommandService(registry: registry)
        let manager = LinuxGuestLifecycleManager(
            controller: service, stopVerificationTimeout: 1
        )

        // Boot the original guest.
        _ = try await registry.start(environmentID: environmentID, taskID: nil)
        let oldEngine = try XCTUnwrap(book.all.first)
        XCTAssertTrue(oldEngine.isRunning)
        XCTAssertEqual(book.all.count, 1)

        // Park the hard restart after its stop is complete and before its
        // replacement start.
        let arrived = SimpleGate()
        let release = SimpleGate()
        await manager.setRestartWindowBarrier {
            arrived.release()
            await release.wait()
        }
        let restartTask = Task {
            try await manager.hardRestart(
                environmentID: environmentID, config: .init(vcpus: 1, memoryMB: 512)
            )
        }

        // Barrier reached: the old engine stopped and no replacement engine
        // exists yet.
        await arrived.wait()
        XCTAssertEqual(book.all.count, 1, "the replacement started before the window was tested")
        XCTAssertFalse(oldEngine.isRunning)
        XCTAssertEqual(oldEngine.stops, 1)

        // A direct shell-style start must be refused by the shared registry,
        // not slip in behind the manager.
        do {
            _ = try await registry.start(environmentID: environmentID, taskID: "shell")
            return XCTFail("a direct start must not own the environment inside the restart window")
        } catch let error as LinuxGuestError {
            guard case .guestBusy = error else {
                return XCTFail("expected guestBusy for the direct start, got \(error)")
            }
        }

        // A direct execute must not attach to (or boot) anything.
        do {
            _ = try await registry.run(
                environmentID: environmentID,
                argv: ["/bin/echo", "hip"],
                workingDirectory: nil,
                standardInput: nil,
                timeout: 5,
                maxOutputBytes: 1024,
                cancellation: nil
            )
            return XCTFail("a direct execute must not run inside the restart window")
        } catch let error as LinuxGuestError {
            guard case .guestBusy = error else {
                return XCTFail("expected guestBusy for the direct execute, got \(error)")
            }
        }

        // A direct terminal and a shape change must not preempt either.
        do {
            try await registry.openSession(
                environmentID: environmentID,
                sessionID: "sess-window",
                argv: ["/bin/sh"],
                workingDirectory: nil,
                columns: 80,
                rows: 24
            )
            return XCTFail("a terminal must not open inside the restart window")
        } catch let error as LinuxGuestError {
            guard case .guestBusy = error else {
                return XCTFail("expected guestBusy for openSession, got \(error)")
            }
        }
        do {
            try await registry.setShape(environmentID: environmentID, ramMB: 768, vcpus: 1)
            return XCTFail("a shape change must not preempt the restart")
        } catch let error as LinuxGuestError {
            guard case .guestBusy = error else {
                return XCTFail("expected guestBusy for setShape, got \(error)")
            }
        }

        // No refused call booted a guest: still exactly the original engine.
        XCTAssertEqual(book.all.count, 1)

        // Release the window: the restart completes at the requested shape.
        release.release()
        let receipt = try await restartTask.value
        XCTAssertEqual(receipt.phase, .running)
        XCTAssertFalse(receipt.reused)
        XCTAssertEqual(receipt.actualVCPUs, 1)
        XCTAssertEqual(receipt.actualMemoryMB, 512, "the receipt did not report the shape really booted")
        XCTAssertEqual(book.all.count, 2, "exactly one replacement engine must exist")
        let newEngine = try XCTUnwrap(book.all.last)
        XCTAssertTrue(newEngine.isRunning)
        XCTAssertEqual(newEngine.starts, 1)
        XCTAssertFalse(oldEngine === newEngine)
        let states = await registry.runtimeStates()
        XCTAssertEqual(states.count, 1)
        XCTAssertEqual(states.first?.ramMB, 512)
        XCTAssertEqual(states.first?.vcpus, 1)
        let finalSupports = await registry.supports(environmentID: environmentID)
        XCTAssertTrue(finalSupports)
    }

    /// A replacement start that fails must release the shared transaction:
    /// after the failure, a direct start owns the environment again and the
    /// registry reports no lingering transaction/reshape ownership. The
    /// failure is honest (no success receipt was produced for a guest that
    /// never booted).
    func testFailedReplacementStartReleasesSharedTransaction() async throws {
        let environmentID = "env-cross-fail"
        let book = EngineBook()
        let registry = makeRegistry(book: book, environmentID: environmentID)
        let service = TinyEMULinuxCommandService(registry: registry)
        let manager = LinuxGuestLifecycleManager(
            controller: service, stopVerificationTimeout: 1
        )

        _ = try await registry.start(environmentID: environmentID, taskID: nil)
        let oldEngine = try XCTUnwrap(book.all.first)

        let arrived = SimpleGate()
        let release = SimpleGate()
        await manager.setRestartWindowBarrier {
            arrived.release()
            await release.wait()
        }
        book.armNextStartFailure()
        let restartTask = Task {
            try await manager.hardRestart(environmentID: environmentID, config: .init())
        }

        await arrived.wait()
        XCTAssertFalse(oldEngine.isRunning)
        release.release()
        do {
            _ = try await restartTask.value
            XCTFail("a replacement start that failed must not report success")
        } catch let error as LinuxGuestLifecycleError {
            guard case .capabilityUnsupported = error else {
                return XCTFail("expected capabilityUnsupported, got \(error)")
            }
        }

        // The transaction (and the shape-change ownership it reuses) is gone:
        // a direct start boots normally afterwards.
        let diagnostics = await registry.lifecycleDiagnostics(environmentID: environmentID)
        XCTAssertFalse(diagnostics.transactionInFlight)
        XCTAssertFalse(diagnostics.shapeChangeInFlight)
        let supports = await registry.supports(environmentID: environmentID)
        XCTAssertFalse(supports)
        _ = try await registry.start(environmentID: environmentID, taskID: "shell")
        let replacement = try XCTUnwrap(book.all.last)
        XCTAssertTrue(replacement.isRunning)
        XCTAssertEqual(book.all.count, 3, "old + scripted failed replacement + direct replacement")
    }

    /// A stop that the engine never confirms quarantines the guest, releases
    /// the shared transaction (no deadlock for later recovery) and keeps the
    /// quarantine: a direct start is still refused until a later stop really
    /// succeeds.
    func testUnconfirmedStopKeepsQuarantineAndReleasesTransaction() async throws {
        let environmentID = "env-cross-quarantine"
        let book = EngineBook()
        let registry = makeRegistry(book: book, environmentID: environmentID)
        let service = TinyEMULinuxCommandService(registry: registry)
        let manager = LinuxGuestLifecycleManager(
            controller: service, stopVerificationTimeout: 0.2
        )

        _ = try await registry.start(environmentID: environmentID, taskID: nil)
        let oldEngine = try XCTUnwrap(book.all.first)
        oldEngine.surviveEveryStop()

        do {
            _ = try await manager.hardRestart(environmentID: environmentID, config: .init())
            XCTFail("an unconfirmed stop must not report a successful restart")
        } catch let error as LinuxGuestLifecycleError {
            guard case .stopFailedQuarantined = error else {
                return XCTFail("expected stopFailedQuarantined, got \(error)")
            }
        }

        // The guest survived; the transaction is released (begin works again)
        // but the quarantine refuses a direct start.
        XCTAssertTrue(oldEngine.isRunning)
        let diagnostics = await registry.lifecycleDiagnostics(environmentID: environmentID)
        XCTAssertFalse(diagnostics.transactionInFlight)
        let recoveryToken = try await registry.beginLifecycleTransaction(environmentID: environmentID)
        await registry.endLifecycleTransaction(environmentID: environmentID, token: recoveryToken)
        do {
            _ = try await registry.start(environmentID: environmentID, taskID: "shell")
            XCTFail("a quarantined guest must not be replaced by a new start")
        } catch let error as LinuxGuestError {
            guard case .stopFailed = error else {
                return XCTFail("expected the quarantine refusal, got \(error)")
            }
        }
        XCTAssertEqual(book.all.count, 1, "the quarantine booted a second engine")
    }

    /// A hard restart refused by a narrower release ceiling (dual core) is
    /// refused before any disruption AND releases the shared transaction: the
    /// running guest is untouched and a later direct start still reuses it.
    /// (Production now qualifies two harts; the narrow test policy pins the
    /// refusal path.)
    func testReleaseGateRefusalReleasesTransactionWithoutDisruption() async throws {
        let environmentID = "env-cross-dual"
        let book = EngineBook()
        let registry = makeRegistry(book: book, environmentID: environmentID)
        let service = TinyEMULinuxCommandService(registry: registry)
        let manager = LinuxGuestLifecycleManager(
            controller: service,
            releasePolicy: GuestReleaseShapePolicy.internalSyntheticTesting(
                maximumSupportedVCPUs: 1, provenance: "LinuxLifecycleCrossConcurrencyTests narrow ceiling"
            ),
            stopVerificationTimeout: 1
        )

        _ = try await registry.start(environmentID: environmentID, taskID: nil)
        let engine = try XCTUnwrap(book.all.first)

        do {
            _ = try await manager.hardRestart(
                environmentID: environmentID, config: .init(vcpus: 2)
            )
            XCTFail("a dual-core restart must be refused by the release gate")
        } catch let error as LinuxGuestLifecycleError {
            guard case .capabilityUnsupported = error else {
                return XCTFail("expected capabilityUnsupported, got \(error)")
            }
        }

        XCTAssertTrue(engine.isRunning, "the release-gate refusal disrupted the running guest")
        XCTAssertEqual(engine.stops, 0)
        XCTAssertEqual(book.all.count, 1)
        let diagnostics = await registry.lifecycleDiagnostics(environmentID: environmentID)
        XCTAssertFalse(diagnostics.transactionInFlight)
        XCTAssertFalse(diagnostics.shapeChangeInFlight)
        _ = try await registry.start(environmentID: environmentID, taskID: "shell")
        XCTAssertEqual(book.all.count, 1, "the direct start booted a second engine instead of reusing")
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @Sendable () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        if await condition() { return }
        XCTFail("condition not met before timeout")
    }
}
