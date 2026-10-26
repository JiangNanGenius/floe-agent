// FloeExecutionTests — per-boot guest loopback startup provisioning.
//
// These tests pin the registry seam with the same scripted-console harness as
// LinuxGuestBackendTests: no guest image, no engine, no host networking. They
// prove the one-shot repair frame is issued exactly once per real boot before
// the session registers, that every outcome is recorded without ever failing
// the start or writing `lastErrors`, that a poisoned provisioning frame
// abandons the boot under the existing channel contract, that warm starts and
// joined concurrent starts never re-provision, and that a pending stop during
// the frame honours the existing abandonment contract.

import Foundation
import XCTest
import FloeCore
import FloeTools
@testable import FloeExecution

final class LinuxGuestLoopbackProvisioningTests: XCTestCase {
    /// The healthy-skip marker occurs once in the trusted script. Counting
    /// it in the host-written EXEC stream counts frames; procfs paths occur
    /// several times within a single frame and cannot identify boot count.
    private let loopbackSignature = "FLOE_LOOPBACK=skipped-already-healthy"

    /// Explicit open/close gate for the provisioning reply. The scripted
    /// guest can answer HELLO immediately but holds the provisioning frame
    /// until the test has observed the registry state it needs, so the
    /// "not registered yet" assertion cannot race a fast scripted reply.
    private final class ProvisionGate: @unchecked Sendable {
        private let lock = NSLock()
        private var opened = false

        func open() {
            lock.lock(); opened = true; lock.unlock()
        }

        func wait(timeout: TimeInterval = 5) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            lock.lock()
            while !opened {
                guard Date() < deadline else { lock.unlock(); return false }
                lock.unlock()
                Thread.sleep(forTimeInterval: 0.002)
                lock.lock()
            }
            lock.unlock()
            return true
        }
    }

    /// Scripted console that also records every console it creates, so a
    /// stop → start boot pair can be counted per engine instance.
    private final class RecordingFactory: LinuxGuestSessionCreating, @unchecked Sendable {
        private let lock = NSLock()
        private var created: [TestLinuxGuestConsole] = []
        let handler: @Sendable (String, String) -> [Data]

        init(handler: @escaping @Sendable (String, String) -> [Data]) {
            self.handler = handler
        }

        var consoles: [TestLinuxGuestConsole] {
            lock.lock(); defer { lock.unlock() }
            return created
        }

        func makeSession(
            descriptor: LinuxGuestEnvironmentDescriptor,
            image: LinuxGuestImage,
            limits: LinuxGuestLimits
        ) throws -> LinuxGuestSessionHandle {
            let console = TestLinuxGuestConsole { token in
                self.handler(descriptor.id, token)
            }
            lock.lock(); created.append(console); lock.unlock()
            let state = FakeSessionState()
            return LinuxGuestSessionHandle(
                transport: console,
                start: { await state.didStart() },
                stop: { await state.didStop() },
                close: { await state.didStop() },
                isRunning: { await state.running },
                addForward: { _ in },
                removeForward: { _ in }
            )
        }
    }

    private func makeRegistry(
        descriptors: [String: LinuxGuestEnvironmentDescriptor],
        factory: RecordingFactory
    ) -> TinyEMULinuxGuestRegistry {
        TinyEMULinuxGuestRegistry(
            environments: FakeEnvironmentProvider(descriptors: descriptors),
            images: FakeImageResolver(images: ["test-image": makeImage()]),
            limits: .standard,
            factory: factory
        )
    }

    private func provisioningFrameCount(_ console: TestLinuxGuestConsole) -> Int {
        String(decoding: console.written, as: UTF8.self)
            .components(separatedBy: loopbackSignature).count - 1
    }

    /// Waits until the first engine's provisioning frame is on the wire and
    /// returns that console.
    private func awaitProvisioningFrame(
        _ factory: RecordingFactory, timeout: TimeInterval = 5
    ) async throws -> TestLinuxGuestConsole {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let consoles = factory.consoles
            if let console = consoles.first, provisioningFrameCount(console) > 0 {
                return console
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw LinuxGuestError.invalidConfiguration("provisioning frame was not dispatched")
    }

    func testProvisioningFrameRunsOncePerBootBeforeRegistration() async throws {
        let gate = ProvisionGate()
        let factory = RecordingFactory { _, token in
            if token.hasPrefix("hello-") { return caps(token) }
            // Hold the provisioning frame until the test observed the
            // registry state; a fast scripted reply would race the check.
            _ = gate.wait()
            return reply(token, stdout: "FLOE_LOOPBACK=provisioned\n", stderr: "", exit: 0)
        }
        let registry = makeRegistry(descriptors: ["env-1": makeDescriptor(id: "env-1")], factory: factory)
        let startTask = Task { try await registry.start(environmentID: "env-1", taskID: nil) }
        let console = try await awaitProvisioningFrame(factory)
        // While the provisioning frame is held on the wire the session must
        // not be registered yet: no workload can observe an unprovisioned
        // "ready" guest, and no stop can tear a half-registered session down.
        let supportedDuringProvisioning = await registry.supports(environmentID: "env-1")
        XCTAssertFalse(
            supportedDuringProvisioning,
            "the session must register only after the loopback provisioning frame"
        )
        gate.open()
        let started = try await startTask.value
        XCTAssertTrue(started)
        let supportedAfter = await registry.supports(environmentID: "env-1")
        XCTAssertTrue(supportedAfter)
        let outcome = await registry.loopbackProvisioningOutcome(environmentID: "env-1")
        XCTAssertEqual(outcome, .provisioned)
        XCTAssertEqual(provisioningFrameCount(console), 1, "exactly one frame per real boot")
        let status = await registry.status(environmentID: "env-1")
        XCTAssertNil(status.lastError, "loopback provisioning must never surface as a guest error")
        // The workload path is unchanged after the frame.
        let result = try await registry.run(
            environmentID: "env-1", argv: ["echo", "hi"], workingDirectory: nil,
            standardInput: nil, timeout: 5, maxOutputBytes: 4096, cancellation: nil
        )
        XCTAssertEqual(result.exitCode, 0)
        await registry.stop(environmentID: "env-1")
    }

    func testAlreadyHealthyGuestSkipsRepair() async throws {
        let factory = RecordingFactory { _, token in
            token.hasPrefix("hello-")
                ? caps(token)
                : reply(token, stdout: "FLOE_LOOPBACK=skipped-already-healthy\n", stderr: "", exit: 0)
        }
        let registry = makeRegistry(descriptors: ["env-1": makeDescriptor(id: "env-1")], factory: factory)
        let started = try await registry.start(environmentID: "env-1", taskID: nil)
        XCTAssertTrue(started)
        let outcome = await registry.loopbackProvisioningOutcome(environmentID: "env-1")
        XCTAssertEqual(outcome, .skippedAlreadyHealthy)
        XCTAssertEqual(provisioningFrameCount(factory.consoles[0]), 1)
        let status = await registry.status(environmentID: "env-1")
        XCTAssertNil(status.lastError)
        await registry.stop(environmentID: "env-1")
    }

    func testMissingToolsFailHonestlyWithoutFailingStart() async throws {
        let factory = RecordingFactory { _, token in
            token.hasPrefix("hello-")
                ? caps(token)
                : reply(token, stdout: "FLOE_LOOPBACK=failed-no-tool\n", stderr: "", exit: 0)
        }
        let registry = makeRegistry(descriptors: ["env-1": makeDescriptor(id: "env-1")], factory: factory)
        let started = try await registry.start(environmentID: "env-1", taskID: nil)
        XCTAssertTrue(started, "a degraded loopback must never fail the start")
        let outcome = await registry.loopbackProvisioningOutcome(environmentID: "env-1")
        XCTAssertEqual(outcome, .failedNoProvisioningTool)
        let status = await registry.status(environmentID: "env-1")
        XCTAssertNil(status.lastError, "the degradation is logged, never reported as a guest error")
        let supported = await registry.supports(environmentID: "env-1")
        XCTAssertTrue(supported, "the generic guest shell stays usable when repair tools are absent")
        let result = try await registry.run(
            environmentID: "env-1", argv: ["echo", "hi"], workingDirectory: nil,
            standardInput: nil, timeout: 5, maxOutputBytes: 4096, cancellation: nil
        )
        XCTAssertEqual(result.exitCode, 0, "non-loopback workloads stay usable")
        await registry.stop(environmentID: "env-1")
    }

    func testUnrecognizedReplyIsRecordedButStartSucceeds() async throws {
        // Scripted consoles that predate this feature answer every EXEC with a
        // generic payload and no marker; that must stay a successful start.
        let factory = RecordingFactory { _, token in
            token.hasPrefix("hello-") ? caps(token) : reply(token, stdout: "hi", stderr: "oops", exit: 0)
        }
        let registry = makeRegistry(descriptors: ["env-1": makeDescriptor(id: "env-1")], factory: factory)
        let started = try await registry.start(environmentID: "env-1", taskID: nil)
        XCTAssertTrue(started)
        let outcome = await registry.loopbackProvisioningOutcome(environmentID: "env-1")
        XCTAssertEqual(outcome, .failedUnrecognized)
        let status = await registry.status(environmentID: "env-1")
        XCTAssertNil(status.lastError)
        await registry.stop(environmentID: "env-1")
    }

    func testNonzeroExitWithSuccessMarkerIsNotAccepted() async throws {
        // A success marker on a nonzero exit (or conflicting markers) must
        // never be read as provisioned — the frame did not run as written.
        let factory = RecordingFactory { _, token in
            token.hasPrefix("hello-")
                ? caps(token)
                : reply(token, stdout: "FLOE_LOOPBACK=provisioned\n", stderr: "boom", exit: 1)
        }
        let registry = makeRegistry(descriptors: ["env-1": makeDescriptor(id: "env-1")], factory: factory)
        let started = try await registry.start(environmentID: "env-1", taskID: nil)
        XCTAssertTrue(started)
        let outcome = await registry.loopbackProvisioningOutcome(environmentID: "env-1")
        XCTAssertEqual(outcome, .failedUnrecognized)
        await registry.stop(environmentID: "env-1")
    }

    func testConflictingMarkersAreNotAccepted() async throws {
        let factory = RecordingFactory { _, token in
            token.hasPrefix("hello-")
                ? caps(token)
                : reply(token, stdout: "FLOE_LOOPBACK=provisioned\nFLOE_LOOPBACK=failed-still-down\n",
                        stderr: "", exit: 0)
        }
        let registry = makeRegistry(descriptors: ["env-1": makeDescriptor(id: "env-1")], factory: factory)
        let started = try await registry.start(environmentID: "env-1", taskID: nil)
        XCTAssertTrue(started)
        let outcome = await registry.loopbackProvisioningOutcome(environmentID: "env-1")
        XCTAssertEqual(outcome, .failedUnrecognized)
        await registry.stop(environmentID: "env-1")
    }

    func testPoisonedProvisioningFrameAbandonsBootUnderChannelContract() async throws {
        // A guest FAILED leaves the single console in an unknown state; the
        // channel is never reused, so the boot is abandoned instead of
        // registering a session whose every later command would throw.
        let factory = RecordingFactory { _, token in
            if token.hasPrefix("hello-") { return caps(token) }
            return [Data("\u{1e}FLOE-FAILED \(token) unreaped\u{1e}".utf8)]
        }
        let registry = makeRegistry(descriptors: ["env-1": makeDescriptor(id: "env-1")], factory: factory)
        do {
            _ = try await registry.start(environmentID: "env-1", taskID: nil)
            XCTFail("a poisoned provisioning frame must abandon the boot")
        } catch let error as LinuxGuestError {
            guard case .consoleUnavailable = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
        let supported = await registry.supports(environmentID: "env-1")
        XCTAssertFalse(supported)
        let status = await registry.status(environmentID: "env-1")
        XCTAssertFalse(status.running)
    }

    func testWarmSecondStartDoesNotReprovision() async throws {
        let factory = RecordingFactory { _, token in
            token.hasPrefix("hello-")
                ? caps(token)
                : reply(token, stdout: "FLOE_LOOPBACK=provisioned\n", stderr: "", exit: 0)
        }
        let registry = makeRegistry(descriptors: ["env-1": makeDescriptor(id: "env-1")], factory: factory)
        _ = try await registry.start(environmentID: "env-1", taskID: nil)
        let second = try await registry.start(environmentID: "env-1", taskID: nil)
        XCTAssertTrue(second, "a warm start reuses the running session")
        XCTAssertEqual(factory.consoles.count, 1, "no second engine was created")
        XCTAssertEqual(provisioningFrameCount(factory.consoles[0]), 1)
        await registry.stop(environmentID: "env-1")
    }

    func testStopThenStartReprovisionsForTheNewBoot() async throws {
        let factory = RecordingFactory { _, token in
            token.hasPrefix("hello-")
                ? caps(token)
                : reply(token, stdout: "FLOE_LOOPBACK=provisioned\n", stderr: "", exit: 0)
        }
        let registry = makeRegistry(descriptors: ["env-1": makeDescriptor(id: "env-1")], factory: factory)
        _ = try await registry.start(environmentID: "env-1", taskID: nil)
        await registry.stop(environmentID: "env-1")
        _ = try await registry.start(environmentID: "env-1", taskID: nil)
        XCTAssertEqual(factory.consoles.count, 2, "the stop → start pair booted a fresh engine")
        XCTAssertEqual(provisioningFrameCount(factory.consoles[0]), 1, "first boot provisioned once")
        XCTAssertEqual(provisioningFrameCount(factory.consoles[1]), 1, "the new boot re-provisioned once")
        let outcome = await registry.loopbackProvisioningOutcome(environmentID: "env-1")
        XCTAssertEqual(outcome, .provisioned)
        await registry.stop(environmentID: "env-1")
    }

    func testConcurrentStartsOfSameEnvironmentProvisionExactlyOnce() async throws {
        // Two racing starts of one environment join the single in-flight boot
        // (sharedStarts): one engine, one provisioning frame, both callers
        // answered true.
        let factory = RecordingFactory { _, token in
            token.hasPrefix("hello-")
                ? caps(token)
                : reply(token, stdout: "FLOE_LOOPBACK=provisioned\n", stderr: "", exit: 0)
        }
        let registry = makeRegistry(descriptors: ["env-1": makeDescriptor(id: "env-1")], factory: factory)
        async let first: Bool = registry.start(environmentID: "env-1", taskID: nil)
        async let second: Bool = registry.start(environmentID: "env-1", taskID: nil)
        let (startedFirst, startedSecond) = try await (first, second)
        XCTAssertTrue(startedFirst)
        XCTAssertTrue(startedSecond)
        XCTAssertEqual(factory.consoles.count, 1, "concurrent starts must share the single boot")
        XCTAssertEqual(provisioningFrameCount(factory.consoles[0]), 1)
        await registry.stop(environmentID: "env-1")
    }

    func testTwoEnvironmentsProvisionIndependentlyAndConcurrently() async throws {
        let factory = RecordingFactory { _, token in
            token.hasPrefix("hello-")
                ? caps(token)
                : reply(token, stdout: "FLOE_LOOPBACK=provisioned\n", stderr: "", exit: 0)
        }
        let registry = makeRegistry(
            descriptors: [
                "env-1": makeDescriptor(id: "env-1"),
                "env-2": makeDescriptor(id: "env-2"),
            ],
            factory: factory
        )
        async let first: Bool = registry.start(environmentID: "env-1", taskID: nil)
        async let second: Bool = registry.start(environmentID: "env-2", taskID: nil)
        let (startedFirst, startedSecond) = try await (first, second)
        XCTAssertTrue(startedFirst)
        XCTAssertTrue(startedSecond)
        XCTAssertEqual(factory.consoles.count, 2)
        XCTAssertEqual(provisioningFrameCount(factory.consoles[0]), 1)
        XCTAssertEqual(provisioningFrameCount(factory.consoles[1]), 1)
        let outcomeOne = await registry.loopbackProvisioningOutcome(environmentID: "env-1")
        let outcomeTwo = await registry.loopbackProvisioningOutcome(environmentID: "env-2")
        XCTAssertEqual(outcomeOne, .provisioned)
        XCTAssertEqual(outcomeTwo, .provisioned)
        await registry.stop(environmentID: "env-1")
        await registry.stop(environmentID: "env-2")
    }

    func testPendingStopDuringProvisioningAbandonsBoot() async throws {
        // A stop that lands while the provisioning frame is held must own the
        // same teardown contract as a stop during the runner-upgrade window:
        // the boot is abandoned and no half-registered guest survives.
        let gate = ProvisionGate()
        let factory = RecordingFactory { _, token in
            if token.hasPrefix("hello-") { return caps(token) }
            _ = gate.wait()
            return reply(token, stdout: "FLOE_LOOPBACK=provisioned\n", stderr: "", exit: 0)
        }
        let registry = makeRegistry(descriptors: ["env-1": makeDescriptor(id: "env-1")], factory: factory)
        let startTask = Task { try await registry.start(environmentID: "env-1", taskID: nil) }
        _ = try await awaitProvisioningFrame(factory)
        await registry.stop(environmentID: "env-1")
        gate.open()
        do {
            _ = try await startTask.value
            XCTFail("a pending stop during provisioning must abandon the boot")
        } catch {
            // The start fails with the engine's honest stop/cancellation reason.
        }
        let supported = await registry.supports(environmentID: "env-1")
        XCTAssertFalse(supported)
        let status = await registry.status(environmentID: "env-1")
        XCTAssertFalse(status.running)
        // The environment boots cleanly afterwards.
        let restarted = try await registry.start(environmentID: "env-1", taskID: nil)
        XCTAssertTrue(restarted)
        let outcome = await registry.loopbackProvisioningOutcome(environmentID: "env-1")
        XCTAssertEqual(outcome, .provisioned)
        await registry.stop(environmentID: "env-1")
    }
    func testIncompleteOrMangledReplyCannotDeclareReadiness() {
        for invalid in [
            "FLOE_LOOPBACK=provisioned-but-not-ready\n",
            "prefixFLOE_LOOPBACK=provisioned\n",
            "FLOE_LOOPBACK=provisioned\n[output truncated]",
            "FLOE_LOOPBACK=provisioned\nFLOE",
        ] {
            let result = LinuxCommandResult(stdout: invalid, stderr: "", exitCode: 0)
            XCTAssertEqual(LinuxGuestLoopbackProvisioning.outcome(from: result), .failedUnrecognized)
        }
    }

}
