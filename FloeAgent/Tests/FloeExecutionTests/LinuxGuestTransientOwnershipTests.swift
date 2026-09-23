// FloeExecutionTests — F3 logical-run ownership and scoped transient release.
//
// The end-to-end shape under test is the real production path minus the
// App-target routing shim:
//
//   exec.shell (run R) -> guest cold start owned by R -> tool command ->
//   tool result, guest stays running -> the SAME run needs the heavy runtime
//   for its continuation -> `beginLocalInferenceSession(requestingRunID: R)`
//   -> the shared bridge probe reports the guest with real registry facts ->
//   the arbiter releases R's own TRANSIENT tool guest WITHOUT a user decision
//   -> the registry flushes/closes/releases before the model may map weights.
//
// Everything below is the real `TinyEMULinuxGuestRegistry`, the real
// `TinyEMULinuxCommandService` and a real `HeavyRuntimeArbiter`; only the
// TinyEMU machine is scripted (the same FakeSessionFactory pattern the other
// LinuxGuestBackend tests use). The tests also pin the protection rules: a
// user-started guest, another run's guest, a live service, a requested
// forward, an in-flight command and a stop-quarantined guest all keep the
// explicit decision path and are never destroyed silently.

import Foundation
import XCTest
import FloeCore
import FloeTools
@testable import FloeExecution

// MARK: - scripted session lifecycle

/// Records scripted session lifecycle events so a release/quarantine is
/// directly observable. `stopsOnClose` models a truthful engine: a stuck
/// session keeps running (its stop budget elapsed), which is what the
/// quarantine contract must preserve.
final class F3SessionBook: @unchecked Sendable {
    private let lock = NSLock()
    private var running: Set<String> = []
    private var started: [String] = []
    private var stopped: [String] = []
    private var consoles: [String: TestLinuxGuestConsole] = [:]

    /// A session was created (before `start` runs): only the console exists.
    func recordCreated(environmentID: String, console: TestLinuxGuestConsole) {
        lock.lock()
        consoles[environmentID] = console
        lock.unlock()
    }

    /// The engine actually started the VM.
    func markStarted(environmentID: String) {
        lock.lock()
        started.append(environmentID)
        running.insert(environmentID)
        lock.unlock()
    }

    /// The engine stopped (or was asked to stop and really stopped) the VM.
    func recordStop(environmentID: String) {
        lock.lock()
        stopped.append(environmentID)
        running.remove(environmentID)
        lock.unlock()
    }

    var startedEnvironmentIDs: [String] { lock.withLock { started } }
    var stoppedEnvironmentIDs: [String] { lock.withLock { stopped } }
    func isRunning(_ environmentID: String) -> Bool { lock.withLock { running.contains(environmentID) } }
    func console(for environmentID: String) -> TestLinuxGuestConsole? {
        lock.withLock { consoles[environmentID] }
    }
}

struct F3SessionFactory: LinuxGuestSessionCreating {
    let book: F3SessionBook
    var stopsOnClose: Bool = true
    var startError: Error?
    let handler: @Sendable (String, String) -> [Data]

    func makeSession(
        descriptor: LinuxGuestEnvironmentDescriptor,
        image: LinuxGuestImage,
        limits: LinuxGuestLimits
    ) throws -> LinuxGuestSessionHandle {
        if let startError { throw startError }
        let console = TestLinuxGuestConsole { token in
            handler(descriptor.id, token)
        }
        book.recordCreated(environmentID: descriptor.id, console: console)
        let book = self.book
        let stopsOnClose = self.stopsOnClose
        let environmentID = descriptor.id
        return LinuxGuestSessionHandle(
            transport: console,
            start: { book.markStarted(environmentID: environmentID) },
            stop: {
                // A truthful engine stops; the stuck fixture keeps the VM
                // running, exactly like a stop that exceeded its budget.
                if stopsOnClose { book.recordStop(environmentID: environmentID) }
            },
            close: {
                if stopsOnClose { book.recordStop(environmentID: environmentID) }
            },
            isRunning: { book.isRunning(environmentID) },
            addForward: { _ in },
            removeForward: { _ in }
        )
    }
}

// MARK: - scripted Runtime v2 substrate (flush ordering)

/// Records the Runtime v2 calls the release path makes, so the test can prove
/// the working disk is flushed/captured and the slot released BEFORE the model
/// is handed the heavy runtime.
private actor F3RuntimeV2Recorder: LinuxGuestRuntimeV2Integrating {
    private let expandedRoot: URL
    private let root: URL
    private let order: F3OrderLog?
    private(set) var events: [String] = []

    init(expandedRoot: URL, root: URL, order: F3OrderLog? = nil) {
        self.expandedRoot = expandedRoot
        self.root = root
        self.order = order
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

    func planReshape(environmentID: String, ramMB: Int, vcpus: Int, currentVCPUs: Int) async throws {}
    func confirmReshape(environmentID: String, ramMB: Int, vcpus: Int) async {}
    func planRetier(environmentID: String, ramMB: Int) async throws {}
    func confirmTier(environmentID: String, ramMB: Int) async {}

    func prepareWorkingDisk(
        environmentID: String, runtimeID: String, imageID: String,
        legacyWritableDirectory: URL?, targetCapacityBytes: Int64
    ) async throws -> RuntimeV2WorkingDisk {
        events.append("prepareWorkingDisk:\(environmentID)")
        let url = root.appendingPathComponent("f3-\(runtimeID).img")
        FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 0, count: 1024))
        return RuntimeV2WorkingDisk(diskURL: url, capacityBytes: 1024)
    }

    func environmentDataDirectory(environmentID: String) async throws -> URL {
        let url = root.appendingPathComponent("f3-data/\(environmentID)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func completeStop(environmentID: String, runtimeID: String, imageID: String, clean: Bool) async {
        events.append("completeStop:\(environmentID):\(clean)")
    }

    func completeStopResult(
        environmentID: String, runtimeID: String, imageID: String, clean: Bool
    ) async -> RuntimeV2StopOutcome {
        events.append("flush:\(environmentID):\(clean)")
        order?.append("flush:\(environmentID):\(clean)")
        return .captured(generation: 1)
    }

    func releaseSlot(environmentID: String, runtimeID: String) async {
        events.append("releaseSlot:\(environmentID)")
        order?.append("releaseSlot:\(environmentID)")
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

private let f3RunConsoleHandler: @Sendable (String, String) -> [Data] = { _, token in
    token.hasPrefix("hello-") ? f3Caps(token) : f3Reply(token: token)
}

private func f3Descriptor(id: String, imageID: String = "f3-image") -> LinuxGuestEnvironmentDescriptor {
    LinuxGuestEnvironmentDescriptor(id: id, ownerID: "owner", imageID: imageID)
}

private func f3ExpandedImageRoot() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("floe-f3-v2-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let bios = Data("bios".utf8)
    try bios.write(to: directory.appendingPathComponent("bbl64.bin"))
    return directory
}

private func f3V2Image(directory: URL, id: String = "f3-image") -> LinuxGuestImage {
    let bios = Data("bios".utf8)
    return LinuxGuestImage(
        id: id,
        biosPath: "bbl64.bin",
        qualified: true,
        qualificationEvidence: "f3 transient ownership test \(UUID().uuidString)",
        qualificationRun: "f3-run-1",
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

private func f3LegacyImage(id: String = "f3-image") -> LinuxGuestImage {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("floe-f3-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let bios = directory.appendingPathComponent("bbl64.bin")
    let contents = Data("bios".utf8)
    FileManager.default.createFile(atPath: bios.path, contents: contents)
    return LinuxGuestImage(
        id: id,
        biosPath: bios.path,
        qualified: true,
        qualificationEvidence: "f3 transient ownership test \(UUID().uuidString)",
        qualificationRun: "f3-run-1",
        artifacts: [
            LinuxGuestImageArtifact(
                role: .bios,
                path: bios.path,
                sha512: FloeDigest.sha512Hex(contents),
                bytes: Int64(contents.count)
            )
        ]
    )
}

private func f3Caps(_ token: String) -> [Data] {
    [Data("\u{1e}FLOE-CAPS \(token) runner=2.0.0 protocol=3 maxCommands=8 maxSessions=4\u{1e}\u{1e}FLOE-END \(token) 0\u{1e}".utf8)]
}

private func f3Reply(token: String, stdout: String = "tool-ok", stderr: String = "", exit: Int32 = 0) -> [Data] {
    var data = Data()
    data.append(Data("\u{1e}FLOE-BEGIN \(token)\u{1e}\u{1e}FLOE-OUT \(token)\u{1e}".utf8))
    data.append(Data(stdout.utf8))
    if !stderr.isEmpty {
        data.append(Data("\u{1e}FLOE-ERR \(token)\u{1e}".utf8))
        data.append(Data(stderr.utf8))
    }
    data.append(Data("\u{1e}FLOE-END \(token) \(exit)\u{1e}".utf8))
    return [data]
}

private final class F3OrderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func append(_ item: String) { lock.withLock { items.append(item) } }
    var events: [String] { lock.withLock { items } }
}

private final class F3Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

/// Async gate so a scoped release can be parked deterministically while the
/// test cancels the waiting request.
final class F3Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if opened {
                lock.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func open() {
        lock.lock()
        opened = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

private func f3WaitUntil(
    timeout: Duration = .seconds(3),
    interval: Duration = .milliseconds(5),
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: interval)
    }
    return await condition()
}

// MARK: - tests

final class LinuxGuestTransientOwnershipTests: XCTestCase {
    private struct Harness {
        let registry: TinyEMULinuxGuestRegistry
        let service: TinyEMULinuxCommandService
        let book: F3SessionBook
        let arbiter: HeavyRuntimeArbiter
        let order: F3OrderLog
        let decisions: F3Counter
        let recorder: F3RuntimeV2Recorder

        /// Wires the arbiter exactly like the production AppEnvironment:
        /// the shared FloeExecution bridge for probe/stopper/releaser.
        func configureArbiter() {
            let service = self.service
            let arbiter = self.arbiter
            let order = self.order
            let decisions = self.decisions
            arbiter.configure(
                activityProbe: LinuxGuestRuntimeArbiterBridge.activityProbe(
                    service: service, arbiter: arbiter
                ),
                guestStopper: LinuxGuestRuntimeArbiterBridge.guestStopper(service: service),
                decisionHandler: { _ in
                    decisions.increment()
                    return .deferLocalModel
                },
                transientGuestReleaser: LinuxGuestRuntimeArbiterBridge.transientGuestReleaser(
                    service: service,
                    onReleased: { environmentID in order.append("released:\(environmentID)") }
                ),
                settleInterval: .milliseconds(5),
                settleTimeout: .milliseconds(600)
            )
        }
    }

    private func makeHarness(
        environmentIDs: [String],
        stopsOnClose: Bool = true,
        startError: Error? = nil,
        useRuntimeV2: Bool = false,
        handler: @escaping @Sendable (String, String) -> [Data] = f3RunConsoleHandler
    ) throws -> Harness {
        let book = F3SessionBook()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-f3-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let factory = F3SessionFactory(
            book: book, stopsOnClose: stopsOnClose, startError: startError, handler: handler
        )
        let order = F3OrderLog()
        let recorder: F3RuntimeV2Recorder
        let images: [String: LinuxGuestImage]
        let runtimeV2: (any LinuxGuestRuntimeV2Integrating)?
        if useRuntimeV2 {
            let expanded = try f3ExpandedImageRoot()
            recorder = F3RuntimeV2Recorder(expandedRoot: expanded, root: root, order: order)
            runtimeV2 = recorder
            images = ["f3-image": f3V2Image(directory: expanded)]
        } else {
            recorder = F3RuntimeV2Recorder(expandedRoot: root, root: root)
            runtimeV2 = nil
            images = ["f3-image": f3LegacyImage()]
        }
        let registry = TinyEMULinuxGuestRegistry(
            environments: FakeEnvironmentProvider(
                descriptors: Dictionary(uniqueKeysWithValues: environmentIDs.map {
                    ($0, f3Descriptor(id: $0))
                })
            ),
            images: FakeImageResolver(images: images),
            limits: .standard,
            factory: factory,
            runtimeV2: runtimeV2
        )
        let service = TinyEMULinuxCommandService(registry: registry)
        let harness = Harness(
            registry: registry,
            service: service,
            book: book,
            arbiter: HeavyRuntimeArbiter(),
            order: order,
            decisions: F3Counter(),
            recorder: recorder
        )
        harness.configureArbiter()
        return harness
    }

    /// The acceptance path: run R's shell tool leaves its guest running; the
    /// next local generation of R is admitted without a user decision, and the
    /// registry flush/close/release all happen before the model may load.
    func testOwnTransientToolGuestIsAutoReleasedBeforeModelLoad() async throws {
        let harness = try makeHarness(environmentIDs: ["env-1"], useRuntimeV2: true)
        let runID = UUID()
        let service = harness.service
        let arbiter = harness.arbiter

        // The tool's cold start records this run as the guest owner; the tool
        // command then completes and the guest intentionally stays running.
        let started = try await service.startGuest(environmentID: "env-1", taskID: runID.uuidString)
        XCTAssertTrue(started)
        let result = try await service.run(
            environmentID: "env-1",
            argv: ["/bin/sh", "-c", "echo tool-ok"],
            workingDirectory: nil,
            standardInput: nil,
            timeout: 5,
            maxOutputBytes: 4096,
            cancellation: nil
        )
        XCTAssertEqual(result.stdout, "tool-ok")

        // The production probe after the shell is NONEMPTY and reports the
        // real ownership facts (this is exactly what the empty F2 test probe
        // missed).
        let probe = await arbiter.linuxActivity()
        XCTAssertEqual(probe.guestEnvironmentIDs, ["env-1"])
        XCTAssertEqual(probe.guests.count, 1)
        XCTAssertEqual(probe.guests.first?.ownerRunID, runID.uuidString)
        XCTAssertEqual(probe.guests.first?.isTransientToolGuest, true)
        XCTAssertTrue(probe.localServices.isEmpty)

        // The continuation: no decision handler, scoped release, and the model
        // only gets permission after the flush/close/release happened.
        let activity = try await arbiter.beginLocalInferenceSession(requestingRunID: runID)
        harness.order.append("modelLoad")
        XCTAssertEqual(activity.guestEnvironmentIDs, ["env-1"])
        XCTAssertEqual(harness.decisions.count, 0, "the run's own transient guest must not ask the user")
        XCTAssertEqual(arbiter.autoReleaseAttemptCount, 1)
        XCTAssertEqual(arbiter.autoReleasedGuestCount, 1)
        XCTAssertEqual(arbiter.stoppedGuestCount, 0)
        XCTAssertEqual(harness.order.events, ["flush:env-1:true", "releaseSlot:env-1", "released:env-1", "modelLoad"])
        XCTAssertEqual(harness.book.stoppedEnvironmentIDs, ["env-1"])

        let running = await service.guestIsRunning(environmentID: "env-1")
        XCTAssertFalse(running, "the released transient guest is really stopped")
        let reservations = await service.environmentsWithGuestActivity()
        XCTAssertTrue(reservations.isEmpty, "the admission reservation was released")
        let v2Events = await harness.recorder.events
        XCTAssertTrue(v2Events.contains("flush:env-1:true"))
        arbiter.endLocalInferenceSession()
    }

    /// The release waits for the run's own in-flight command (bounded) instead
    /// of closing the console under it, and then releases.
    func testReleaseWaitsForOwnedCommandThenReleases() async throws {
        let harness = try makeHarness(
            environmentIDs: ["env-1"],
            handler: { _, token in token.hasPrefix("hello-") ? f3Caps(token) : [] }
        )
        let runID = UUID()
        let service = harness.service

        _ = try await service.startGuest(environmentID: "env-1", taskID: runID.uuidString)
        let console = try XCTUnwrap(harness.book.console(for: "env-1"))
        let command = Task {
            try await service.run(
                environmentID: "env-1",
                argv: ["/bin/sh", "-c", "sleep 1"],
                workingDirectory: nil,
                standardInput: nil,
                timeout: 10,
                maxOutputBytes: 4096,
                cancellation: nil
            )
        }
        // The command reached the console: the release must not tear the guest
        // down under it.
        let commandStarted = await f3WaitUntil {
            !TestLinuxGuestConsole.tokens(in: console.written, name: "EXEC").isEmpty
        }
        XCTAssertTrue(commandStarted)

        let refused = await harness.registry.releaseTransientGuest(
            environmentID: "env-1",
            expectedOwnerRunID: runID.uuidString,
            commandDrainTimeout: .milliseconds(150)
        )
        guard case .refused(let reason) = refused else {
            return XCTFail("an in-flight owned command must refuse the release, got \(refused)")
        }
        XCTAssertTrue(reason.contains("still running"), reason)
        XCTAssertTrue(harness.book.isRunning("env-1"), "nothing is destroyed while its command runs")

        // Let the command finish, then the same release succeeds.
        let token = try XCTUnwrap(TestLinuxGuestConsole.tokens(in: console.written, name: "EXEC").first)
        console.push(f3Reply(token: token, stdout: "done"))
        let result = try await command.value
        XCTAssertEqual(result.stdout, "done")

        let outcome = await service.releaseTransientGuest(
            environmentID: "env-1", expectedOwnerRunID: runID.uuidString
        )
        XCTAssertEqual(outcome, .released)
        XCTAssertTrue(harness.book.stoppedEnvironmentIDs.contains("env-1"))
    }

    /// A user-started guest has no owner run: it is never auto-released.
    func testUserStartedGuestIsRefused() async throws {
        let harness = try makeHarness(environmentIDs: ["env-1"])
        let runID = UUID()
        let service = harness.service

        _ = try await service.startGuest(environmentID: "env-1", taskID: nil)
        let details = await service.guestActivityDetails()
        let detail = try XCTUnwrap(details.first)
        XCTAssertNil(detail.ownerRunID)
        XCTAssertFalse(detail.isTransientToolGuest)

        let outcome = await service.releaseTransientGuest(
            environmentID: "env-1", expectedOwnerRunID: runID.uuidString
        )
        guard case .refused = outcome else {
            return XCTFail("a user-started guest must be refused, got \(outcome)")
        }
        let running = await service.guestIsRunning(environmentID: "env-1")
        XCTAssertTrue(running, "the user's guest is still running")
    }

    /// Another run's guest keeps the explicit decision path: the arbiter
    /// neither releases it nor asks for a confirmed stop before the user
    /// answers, and a deferred answer leaves both guests untouched.
    func testForeignGuestKeepsExplicitDecisionAndNothingIsStopped() async throws {
        let harness = try makeHarness(environmentIDs: ["env-own", "env-other"])
        let requestingRun = UUID()
        let otherRun = UUID()
        let service = harness.service
        let arbiter = harness.arbiter

        _ = try await service.startGuest(environmentID: "env-own", taskID: requestingRun.uuidString)
        _ = try await service.startGuest(environmentID: "env-other", taskID: otherRun.uuidString)

        do {
            _ = try await arbiter.beginLocalInferenceSession(requestingRunID: requestingRun)
            XCTFail("a foreign guest must defer the local request")
        } catch {
            XCTAssertEqual(error as? HeavyRuntimeArbiter.ArbiterError, .deferredByCaller)
        }
        XCTAssertEqual(harness.decisions.count, 1, "the conflict was presented to the user")
        XCTAssertEqual(arbiter.autoReleaseAttemptCount, 0)
        XCTAssertEqual(arbiter.autoReleasedGuestCount, 0)
        XCTAssertEqual(arbiter.stoppedGuestCount, 0)
        XCTAssertEqual(harness.book.stoppedEnvironmentIDs, [], "a declined decision stops nothing")
        let ownRunning = await service.guestIsRunning(environmentID: "env-own")
        let otherRunning = await service.guestIsRunning(environmentID: "env-other")
        XCTAssertTrue(ownRunning)
        XCTAssertTrue(otherRunning)
    }

    /// A live managed service keeps the guest persistent: the scoped release
    /// refuses and the arbiter still asks the user.
    func testManagedServiceRefusesScopedRelease() async throws {
        // SPAWN is answered by hand (the manual PID frame below), so the
        // scripted runner must not auto-reply to control tokens.
        let harness = try makeHarness(
            environmentIDs: ["env-1"],
            handler: { _, token in
                token.hasPrefix("hello-") ? f3Caps(token) : (token.hasPrefix("ctl-") ? [] : f3Reply(token: token))
            }
        )
        let runID = UUID()
        let service = harness.service
        let arbiter = harness.arbiter

        _ = try await service.startGuest(environmentID: "env-1", taskID: runID.uuidString)
        // A service spawned in this guest makes it non-transient (the registry
        // records the pid).
        let console = try XCTUnwrap(harness.book.console(for: "env-1"))
        let spawn = Task {
            try await harness.registry.guestSpawn(
                environmentID: "env-1",
                argv: ["python3", "app.py"],
                workingDirectory: nil,
                logPath: "/tmp/job.log",
                timeout: 5,
                cancellation: nil
            )
        }
        let spawnReachedConsole = await f3WaitUntil {
            !TestLinuxGuestConsole.tokens(in: console.written, name: "SPAWN").isEmpty
        }
        XCTAssertTrue(spawnReachedConsole)
        let token = try XCTUnwrap(TestLinuxGuestConsole.tokens(in: console.written, name: "SPAWN").first)
        console.push([Data("\u{1e}FLOE-PID \(token) 4242\u{1e}\u{1e}FLOE-END \(token) 0\u{1e}".utf8)])
        _ = try await spawn.value

        let serviceDetails = await service.guestActivityDetails()
        let detail = try XCTUnwrap(serviceDetails.first)
        XCTAssertEqual(detail.activeServiceCount, 1)
        XCTAssertFalse(detail.isTransientToolGuest)

        let outcome = await service.releaseTransientGuest(
            environmentID: "env-1", expectedOwnerRunID: runID.uuidString
        )
        guard case .refused(let reason) = outcome else {
            return XCTFail("a guest with a managed service must be refused, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("service"), reason)

        do {
            _ = try await arbiter.beginLocalInferenceSession(requestingRunID: runID)
            XCTFail("persistent work must keep the explicit decision")
        } catch {
            XCTAssertEqual(error as? HeavyRuntimeArbiter.ArbiterError, .deferredByCaller)
        }
        XCTAssertEqual(harness.decisions.count, 1)
        XCTAssertEqual(arbiter.autoReleasedGuestCount, 0)
        let running = await service.guestIsRunning(environmentID: "env-1")
        XCTAssertTrue(running)
    }

    /// A requested host forward is persistent intent: no scoped release.
    func testRequestedForwardRefusesScopedRelease() async throws {
        let harness = try makeHarness(environmentIDs: ["env-1"])
        let runID = UUID()
        let service = harness.service

        _ = try await service.startGuest(environmentID: "env-1", taskID: runID.uuidString)
        try await service.forwardService(
            environmentID: "env-1",
            forward: LinuxGuestServiceForward(hostAddress: "127.0.0.1", hostPort: 8123, guestPort: 8123)
        )
        let forwardDetails = await service.guestActivityDetails()
        let detail = try XCTUnwrap(forwardDetails.first)
        XCTAssertEqual(detail.requestedForwardCount, 1)
        XCTAssertFalse(detail.isTransientToolGuest)

        let outcome = await service.releaseTransientGuest(
            environmentID: "env-1", expectedOwnerRunID: runID.uuidString
        )
        guard case .refused = outcome else {
            return XCTFail("a forwarded guest must be refused, got \(outcome)")
        }
        let running = await service.guestIsRunning(environmentID: "env-1")
        XCTAssertTrue(running)
    }

    /// A stop that does not actually stop the VM quarantines it: the release
    /// reports that truthfully, the guest stays owned and running, and the
    /// arbiter keeps the explicit decision instead of overlapping the model.
    func testStopFailureQuarantinesAndKeepsExplicitDecision() async throws {
        let harness = try makeHarness(environmentIDs: ["env-1"], stopsOnClose: false)
        let runID = UUID()
        let service = harness.service
        let arbiter = harness.arbiter

        _ = try await service.startGuest(environmentID: "env-1", taskID: runID.uuidString)
        let outcome = await service.releaseTransientGuest(
            environmentID: "env-1", expectedOwnerRunID: runID.uuidString
        )
        guard case .stopFailedQuarantined = outcome else {
            return XCTFail("a guest that refuses to stop must be quarantined, got \(outcome)")
        }
        let running = await service.guestIsRunning(environmentID: "env-1")
        XCTAssertTrue(running, "the quarantined VM is retained truthfully")
        let reservations = await service.environmentsWithGuestActivity()
        XCTAssertEqual(reservations, ["env-1"], "the quarantine keeps its admission slot")
        let quarantineDetails = await service.guestActivityDetails()
        let detail = try XCTUnwrap(quarantineDetails.first)
        XCTAssertTrue(detail.quarantined)
        XCTAssertFalse(detail.isTransientToolGuest)

        do {
            _ = try await arbiter.beginLocalInferenceSession(requestingRunID: runID)
            XCTFail("a quarantined guest must never be overlapped by the model")
        } catch {
            XCTAssertEqual(error as? HeavyRuntimeArbiter.ArbiterError, .deferredByCaller)
        }
        XCTAssertEqual(harness.decisions.count, 1)
        XCTAssertEqual(arbiter.autoReleasedGuestCount, 0)

        // The quarantine is recoverable through the ordinary stop path: once
        // the engine really stops, the environment is free again.
        harness.book.recordStop(environmentID: "env-1")
        await service.stopGuest(environmentID: "env-1")
        let afterStop = await service.environmentsWithGuestActivity()
        XCTAssertTrue(afterStop.isEmpty)
    }

    /// A failed cold start leaves no phantom guest: the tool reports the
    /// engine's honest error and the registry owns nothing, so the next model
    /// generation has no conflict to resolve.
    func testFailedStartLeavesNoPhantomGuest() async throws {
        let harness = try makeHarness(
            environmentIDs: ["env-1"],
            startError: LinuxGuestError.startFailed("scripted engine refusal")
        )
        let runID = UUID()
        let service = harness.service

        do {
            _ = try await service.startGuest(environmentID: "env-1", taskID: runID.uuidString)
            XCTFail("the scripted engine refuses to start")
        } catch {
            // expected: honest start failure
        }
        let reservations = await service.environmentsWithGuestActivity()
        XCTAssertTrue(reservations.isEmpty, "nothing is owned after a failed start")
        let details = await service.guestActivityDetails()
        XCTAssertTrue(details.isEmpty)
        let probe = await harness.arbiter.linuxActivity()
        XCTAssertTrue(probe.isEmpty)
        // The continuation proceeds without any conflict decision.
        _ = try await harness.arbiter.beginLocalInferenceSession(requestingRunID: runID)
        XCTAssertEqual(harness.decisions.count, 0)
        harness.arbiter.endLocalInferenceSession()
    }

    /// A release aimed at the wrong owner (or a stale run) never touches the
    /// guest, even when the facts themselves are transient.
    func testWrongOwnerIsRefused() async throws {
        let harness = try makeHarness(environmentIDs: ["env-1"])
        let runID = UUID()
        let service = harness.service

        _ = try await service.startGuest(environmentID: "env-1", taskID: runID.uuidString)
        let outcome = await service.releaseTransientGuest(
            environmentID: "env-1", expectedOwnerRunID: UUID().uuidString
        )
        guard case .refused = outcome else {
            return XCTFail("a mismatched owner must be refused, got \(outcome)")
        }
        let running = await service.guestIsRunning(environmentID: "env-1")
        XCTAssertTrue(running)
    }

    /// Cancelling the local continuation while its scoped release is in flight
    /// leaves no half state: the real registry finishes the release, the
    /// caller's session accounting returns to zero, and the next generation
    /// sees a clean, empty probe.
    func testCancelledContinuationLeavesNoHalfState() async throws {
        let harness = try makeHarness(environmentIDs: ["env-1"])
        let runID = UUID()
        let service = harness.service
        let arbiter = harness.arbiter
        let gate = F3Gate()
        let releaseStarted = F3Counter()
        arbiter.configure(
            activityProbe: LinuxGuestRuntimeArbiterBridge.activityProbe(
                service: service, arbiter: arbiter
            ),
            guestStopper: LinuxGuestRuntimeArbiterBridge.guestStopper(service: service),
            decisionHandler: { _ in
                harness.decisions.increment()
                return .deferLocalModel
            },
            transientGuestReleaser: { activity in
                releaseStarted.increment()
                await gate.wait()
                _ = await LinuxGuestRuntimeArbiterBridge.transientGuestReleaser(service: service)(activity)
            },
            settleInterval: .milliseconds(5),
            settleTimeout: .milliseconds(600)
        )
        _ = try await service.startGuest(environmentID: "env-1", taskID: runID.uuidString)

        let request = Task {
            try await arbiter.beginLocalInferenceSession(requestingRunID: runID)
        }
        let started = await f3WaitUntil { releaseStarted.count == 1 }
        XCTAssertTrue(started)
        request.cancel()
        gate.open()
        _ = try? await request.value
        // Caller contract on cancellation: end the model session.
        arbiter.endLocalInferenceSession()
        XCTAssertFalse(arbiter.isLocalInferenceActive)
        let reservations = await service.environmentsWithGuestActivity()
        XCTAssertTrue(reservations.isEmpty, "the release really finished")
        XCTAssertEqual(harness.decisions.count, 0)

        // The next generation is admitted over an empty probe with no conflict.
        let activity = try await arbiter.beginLocalInferenceSession(requestingRunID: runID)
        XCTAssertTrue(activity.isEmpty)
        XCTAssertEqual(harness.decisions.count, 0)
        arbiter.endLocalInferenceSession()
    }

    /// An admitted-but-not-yet-registered start is never auto-released: the
    /// probe reports it without ownership facts, so it keeps the explicit
    /// decision even when a run-owned transient guest exists.
    func testAdmittedPendingStartIsNeverAutoReleased() async throws {
        let harness = try makeHarness(environmentIDs: ["env-1"])
        let runID = UUID()
        let service = harness.service
        let arbiter = harness.arbiter
        _ = try await service.startGuest(environmentID: "env-1", taskID: runID.uuidString)
        // The other environment's start was admitted by the arbiter and is
        // racing to publish its reservation.
        try await arbiter.waitForLocalInferenceIdle(registeringStart: "env-starting")
        XCTAssertEqual(arbiter.pendingLinuxStartEnvironmentIDs, ["env-starting"])

        do {
            _ = try await arbiter.beginLocalInferenceSession(requestingRunID: runID)
            XCTFail("a starting VM must keep the explicit decision")
        } catch {
            XCTAssertEqual(error as? HeavyRuntimeArbiter.ArbiterError, .deferredByCaller)
        }
        XCTAssertEqual(harness.decisions.count, 1)
        XCTAssertEqual(arbiter.autoReleaseAttemptCount, 0)
        XCTAssertEqual(arbiter.autoReleasedGuestCount, 0)
        let running = await service.guestIsRunning(environmentID: "env-1")
        XCTAssertTrue(running, "the own guest is untouched while the decision is pending")
        arbiter.releaseLinuxStart(environmentID: "env-starting")
    }
}
