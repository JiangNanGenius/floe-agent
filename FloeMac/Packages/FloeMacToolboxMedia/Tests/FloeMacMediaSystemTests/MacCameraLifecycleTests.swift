import XCTest
import AVFoundation
import CoreImage
import FloeMacMediaCore
@testable import FloeMacMediaSystem

private final class OrderedCameraAuthorizer: MacMediaAuthorizing, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<MacMediaAuthorization, Never>] = []
    func authorization(for kind: MacMediaKind) -> MacMediaAuthorization { .notDetermined }
    func requestAuthorization(for kind: MacMediaKind) async -> MacMediaAuthorization {
        await withCheckedContinuation { continuation in
            lock.withLock { continuations.append(continuation) }
        }
    }
    var pendingCount: Int { lock.withLock { continuations.count } }
    func resumeFirst(_ value: MacMediaAuthorization) {
        let next = lock.withLock { continuations.removeFirst() }
        next.resume(returning: value)
    }
}

private final class CameraGateEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func append(_ value: String) { lock.withLock { items.append(value) } }
    var snapshot: [String] { lock.withLock { items } }
}

final class MacCameraStartGateTests: XCTestCase {
    func testStopDuringConfigurationPreventsHardwareStart() {
        let gate = MacCameraStartGate()
        let entered = DispatchSemaphore(value: 0)
        let continueConfiguration = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let events = CameraGateEvents()
        gate.begin(token: 1)
        DispatchQueue.global().async {
            entered.signal()
            _ = continueConfiguration.wait(timeout: .now() + 2)
            _ = gate.startIfActive(token: 1) { events.append("start") }
            finished.signal()
        }
        let reachedConfiguration = entered.wait(timeout: .now() + 2)
        gate.end()
        continueConfiguration.signal()
        let completed = finished.wait(timeout: .now() + 2)
        XCTAssertEqual(reachedConfiguration, .success)
        XCTAssertEqual(completed, .success)
        XCTAssertEqual(events.snapshot, [])
        gate.begin(token: 2)
        XCTAssertFalse(gate.startIfActive(token: 1) { events.append("stale-start") })
        XCTAssertTrue(gate.startIfActive(token: 2) { events.append("new-start") })
        XCTAssertEqual(events.snapshot, ["new-start"])
    }

    func testStopDoesNotWaitForAlreadyEnteredHardwareStart() {
        let gate = MacCameraStartGate()
        let enteredStart = DispatchSemaphore(value: 0)
        let continueStart = DispatchSemaphore(value: 0)
        let attemptedStop = DispatchSemaphore(value: 0)
        let finishedStop = DispatchSemaphore(value: 0)
        let events = CameraGateEvents()
        gate.begin(token: 1)
        DispatchQueue.global().async {
            _ = gate.startIfActive(token: 1) {
                events.append("start-entered")
                enteredStart.signal()
                _ = continueStart.wait(timeout: .now() + 2)
                events.append("start-returned")
            }
        }
        let started = enteredStart.wait(timeout: .now() + 2)
        DispatchQueue.global().async {
            attemptedStop.signal()
            gate.end()
            events.append("stop-returned")
            finishedStop.signal()
        }
        let stopAttempted = attemptedStop.wait(timeout: .now() + 2)
        let earlyStop = finishedStop.wait(timeout: .now() + 1)
        continueStart.signal()
        let stopped = earlyStop == .success ? earlyStop : finishedStop.wait(timeout: .now() + 2)
        XCTAssertEqual(started, .success)
        XCTAssertEqual(stopAttempted, .success)
        XCTAssertEqual(earlyStop, .success)
        XCTAssertEqual(stopped, .success)
        XCTAssertEqual(Array(events.snapshot.prefix(2)), ["start-entered", "stop-returned"])
        XCTAssertFalse(gate.startIfActive(token: 1) { events.append("late-start") })
    }
}

/// Never opens an input. Its serial queue models a hardware start that can
/// finish only after the test has requested stop or restart.
private final class ControlledCameraHardware: MacCameraHardwareControlling, @unchecked Sendable {
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "floe.test.camera.control")
    private let lock = NSLock()
    private let startGate = MacCameraStartGate()
    private let firstStartRelease = DispatchSemaphore(value: 0)
    private var starts = 0
    private var stops = 0
    private var ends = 0
    private var pendingPhoto: CheckedContinuation<Data, Error>?
    private let firstResult: Result<MacCameraHardware.Capabilities, MacMediaFailure>
    private let capabilities: MacCameraHardware.Capabilities

    init(failFirst: Bool, supportsQRCode: Bool = true) {
        let value = MacCameraHardware.Capabilities(name: "fixture", maximumZoom: 1,
                                                   supportsTorch: false, supportsFocus: false,
                                                   supportsQRCode: supportsQRCode)
        capabilities = value
        firstResult = failFirst ? .failure(.noDevice) : .success(value)
    }
    var startCount: Int { lock.withLock { starts } }
    var stopCount: Int { lock.withLock { stops } }
    var endCount: Int { lock.withLock { ends } }
    var hasPendingPhoto: Bool { lock.withLock { pendingPhoto != nil } }
    func unblockFirstStart() { firstStartRelease.signal() }
    func begin(token: UInt64) { startGate.begin(token: token) }
    func end() { startGate.end(); lock.withLock { ends += 1 } }
    func latestFrame() -> CIImage? { nil }
    func setTorch(on: Bool) -> Bool { false }
    func setFocus(devicePoint: CGPoint) {}
    func capturePage(token: UInt64) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { pendingPhoto = continuation }
        }
    }
    func cancelPendingPhotos() {
        let continuation = lock.withLock { () -> CheckedContinuation<Data, Error>? in
            defer { pendingPhoto = nil }
            return pendingPhoto
        }
        continuation?.resume(throwing: MacMediaFailure.captureFailed("cancelled"))
    }
    func startOnQueue(token: UInt64) -> Result<MacCameraHardware.Capabilities, MacMediaFailure> {
        guard startGate.isActive(token: token) else { return .failure(.captureFailed("cancelled")) }
        let attempt = lock.withLock { starts += 1; return starts }
        if attempt == 1 {
            guard firstStartRelease.wait(timeout: .now() + 5) == .success else {
                return .failure(.engine("fixture-timeout"))
            }
            guard startGate.isActive(token: token) else { return .failure(.captureFailed("cancelled")) }
            return firstResult
        }
        return .success(capabilities)
    }
    func stopAndWait() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                lock.withLock { stops += 1 }
                continuation.resume()
            }
        }
    }
}

private final class PhotoEntryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiter: CheckedContinuation<Void, Never>?
    private var reached = false
    private var released = false
    var entered: Bool { lock.withLock { reached } }
    func wait() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                reached = true
                if released { return true }
                waiter = continuation
                return false
            }
            if shouldResume { continuation.resume() }
        }
    }
    func release() {
        let continuation = lock.withLock {
            released = true
            let value = waiter
            waiter = nil
            return value
        }
        continuation?.resume()
    }
}

/// Models photo submission blocking on the same serial queue as stop.
private final class BlockedPhotoHardware: MacCameraHardwareControlling, @unchecked Sendable {
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "floe.test.camera.blocked-photo")
    private let admission = MacPhotoAdmission()
    private let lock = NSLock()
    private let releaseSubmit = DispatchSemaphore(value: 0)
    private let entryGate: PhotoEntryGate?
    private var submitted = false
    private var submissions = 0
    private var stopped = false
    var submitEntered: Bool { lock.withLock { submitted } }
    var submitCount: Int { lock.withLock { submissions } }
    var didStop: Bool { lock.withLock { stopped } }
    init(entryGate: PhotoEntryGate? = nil) { self.entryGate = entryGate }
    func unblockSubmit() { releaseSubmit.signal() }
    func begin(token: UInt64) { admission.begin(token: token); admission.enable() }
    func end() { admission.end() }
    func startOnQueue(token: UInt64) -> Result<MacCameraHardware.Capabilities, MacMediaFailure> {
        .success(.init(name: "fixture", maximumZoom: 1, supportsTorch: false, supportsFocus: false, supportsQRCode: true))
    }
    func stopAndWait() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in lock.withLock { stopped = true }; continuation.resume() }
        }
    }
    func latestFrame() -> CIImage? { nil }
    func setTorch(on: Bool) -> Bool { false }
    func setFocus(devicePoint: CGPoint) {}
    func capturePage(token: UInt64) async throws -> Data {
        if let entryGate { await entryGate.wait() }
        let broker = MacPhotoCaptureBroker()
        guard admission.register(broker, token: token) else { throw MacMediaFailure.captureFailed("not-running") }
        defer { admission.remove(broker) }
        return try await broker.capture { [self] broker in
            queue.async { [self] in
                guard admission.contains(broker, token: token) else { broker.cancel(); return }
                broker.submitIfPending {
                    lock.withLock { submitted = true; submissions += 1 }
                    _ = releaseSubmit.wait(timeout: .now() + 5)
                    broker.recordProcessing(.success(Data([1])))
                    broker.finishCapture(error: nil)
                }
            }
        }
    }
    func cancelPendingPhotos() { admission.cancelPending() }
}

@MainActor
final class MacCameraLifecycleTests: XCTestCase {
    private func waitUntil(_ predicate: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }

    func testTerminalWithoutProcessingCompletesSuccessAndErrorPaths() async {
        for hasError in [false, true] {
            let lifetime = MacPhotoCaptureLifetime(maximum: 1)
            let photo = MacPhotoCaptureBroker(lifetime: lifetime)
            let capture = Task { try await photo.capture { $0.submitIfPending {} } }
            guard await waitUntil({ lifetime.count == 1 }) else {
                photo.cancel(); _ = try? await capture.value
                return XCTFail("photo was not submitted")
            }
            let error = hasError ? NSError(domain: "floe.fixture", code: 7) : nil
            photo.finishCapture(error: error)
            do { _ = try await capture.value; XCTFail("missing processing must fail") }
            catch {
                guard case .some(.captureFailed(_)) = error as? MacMediaFailure else {
                    return XCTFail("expected photo failure: \(error)")
                }
            }
            XCTAssertEqual(lifetime.count, 0)
        }
    }

    func testProcessingSuccessThenTerminalErrorFails() async {
        let lifetime = MacPhotoCaptureLifetime(maximum: 1)
        let photo = MacPhotoCaptureBroker(lifetime: lifetime)
        let capture = Task { try await photo.capture { $0.submitIfPending {} } }
        guard await waitUntil({ lifetime.count == 1 }) else {
            photo.cancel(); _ = try? await capture.value
            return XCTFail("photo was not submitted")
        }
        photo.recordProcessing(.success(Data([42])))
        XCTAssertEqual(lifetime.count, 1)
        photo.finishCapture(error: NSError(domain: "floe.fixture", code: 9))
        do { _ = try await capture.value; XCTFail("terminal failure must override processing") }
        catch {
            guard case .some(.captureFailed(let message)) = error as? MacMediaFailure else {
                return XCTFail("expected terminal failure: \(error)")
            }
            XCTAssertTrue(message.contains("floe.fixture"))
        }
        photo.recordProcessing(.success(Data([43])))
        XCTAssertEqual(lifetime.count, 0)
    }

    func testProcessingFailureThenTerminalSuccessFails() async {
        let lifetime = MacPhotoCaptureLifetime(maximum: 1)
        let photo = MacPhotoCaptureBroker(lifetime: lifetime)
        let capture = Task { try await photo.capture { $0.submitIfPending {} } }
        guard await waitUntil({ lifetime.count == 1 }) else {
            photo.cancel(); _ = try? await capture.value
            return XCTFail("photo was not submitted")
        }
        photo.recordProcessing(.failure(MacMediaFailure.captureFailed("fixture-processing")))
        photo.finishCapture(error: nil)
        do { _ = try await capture.value; XCTFail("processing failure must be preserved") }
        catch { XCTAssertEqual(error as? MacMediaFailure, .captureFailed("fixture-processing")) }
        XCTAssertEqual(lifetime.count, 0)
    }

    func testProcessingSuccessWaitsForTerminalSuccess() async {
        let lifetime = MacPhotoCaptureLifetime(maximum: 1)
        let photo = MacPhotoCaptureBroker(lifetime: lifetime)
        var finished = false
        let capture = Task { @MainActor in
            defer { finished = true }
            return try await photo.capture { $0.submitIfPending {} }
        }
        guard await waitUntil({ lifetime.count == 1 }) else {
            photo.cancel(); _ = try? await capture.value
            return XCTFail("photo was not submitted")
        }
        photo.recordProcessing(.success(Data([42])))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(finished, "processing alone must not complete capture")
        XCTAssertEqual(lifetime.count, 1)
        photo.finishCapture(error: nil)
        let result = try? await capture.value
        XCTAssertEqual(result, Data([42]))
        XCTAssertEqual(lifetime.count, 0)
    }

    func testStopCancelsWaiterButRetainsDelegateUntilTerminal() async {
        let lifetime = MacPhotoCaptureLifetime(maximum: 1)
        let admission = MacPhotoAdmission()
        admission.enable()
        admission.begin(token: 1)
        weak var weakPhoto: MacPhotoCaptureBroker?
        do {
            let submitted = MacPhotoCaptureBroker(lifetime: lifetime)
            weakPhoto = submitted
            XCTAssertTrue(admission.register(submitted, token: 1))
            let capture = Task { try await submitted.capture { $0.submitIfPending {} } }
            guard await waitUntil({ lifetime.count == 1 }) else {
                submitted.cancel(); _ = try? await capture.value
                return XCTFail("photo was not submitted")
            }
            admission.end()
            do { _ = try await capture.value; XCTFail("stop must cancel the waiter") }
            catch { XCTAssertEqual(error as? MacMediaFailure, .captureFailed("cancelled")) }
        }
        XCTAssertNotNil(weakPhoto)
        XCTAssertEqual(lifetime.count, 1)
        weakPhoto?.recordProcessing(.success(Data([1])))
        XCTAssertEqual(lifetime.count, 1)
        weakPhoto?.finishCapture(error: nil)
        weakPhoto?.recordProcessing(.success(Data([2])))
        XCTAssertEqual(lifetime.count, 0)
        XCTAssertNil(weakPhoto)
    }

    func testOutstandingLimitRejectsAndTerminalReleasesCapacity() async {
        let lifetime = MacPhotoCaptureLifetime(maximum: 1)
        let first = MacPhotoCaptureBroker(lifetime: lifetime)
        let firstTask = Task { try await first.capture { $0.submitIfPending {} } }
        guard await waitUntil({ lifetime.count == 1 }) else {
            first.cancel(); _ = try? await firstTask.value
            return XCTFail("first photo was not submitted")
        }
        let second = MacPhotoCaptureBroker(lifetime: lifetime)
        let events = CameraGateEvents()
        let secondTask = Task { try await second.capture { $0.submitIfPending { events.append("submitted") } } }
        do { _ = try await secondTask.value; XCTFail("full capacity must reject") }
        catch { XCTAssertEqual(error as? MacMediaFailure, .captureFailed("photo-capacity")) }
        XCTAssertTrue(events.snapshot.isEmpty)
        XCTAssertEqual(lifetime.count, 1)
        first.finishCapture(error: nil)
        _ = try? await firstTask.value
        XCTAssertEqual(lifetime.count, 0)
        let third = MacPhotoCaptureBroker(lifetime: lifetime)
        let thirdTask = Task { try await third.capture { $0.submitIfPending {} } }
        guard await waitUntil({ lifetime.count == 1 }) else {
            third.cancel(); _ = try? await thirdTask.value
            return XCTFail("capacity was not recovered")
        }
        third.finishCapture(error: nil)
        _ = try? await thirdTask.value
        XCTAssertEqual(lifetime.count, 0)
    }

    func testCancelledBeforeSubmissionUsesNoCapacity() async {
        let lifetime = MacPhotoCaptureLifetime(maximum: 1)
        let photo = MacPhotoCaptureBroker(lifetime: lifetime)
        photo.cancel()
        let capture = Task { try await photo.capture { $0.submitIfPending {} } }
        do { _ = try await capture.value; XCTFail("cancelled request must fail") }
        catch { XCTAssertEqual(error as? MacMediaFailure, .captureFailed("cancelled")) }
        XCTAssertEqual(lifetime.count, 0)
    }

    func testOldPhotoCallCannotRegisterAfterNewGeneration() {
        let admission = MacPhotoAdmission()
        admission.enable()
        admission.begin(token: 1)
        admission.end()
        admission.begin(token: 2)
        let old = MacPhotoCaptureBroker(), current = MacPhotoCaptureBroker()
        XCTAssertFalse(admission.register(old, token: 1))
        XCTAssertTrue(admission.register(current, token: 2))
        XCTAssertFalse(admission.contains(old, token: 1))
        XCTAssertTrue(admission.contains(current, token: 2))
        admission.end()
    }

    func testOldControllerPhotoCallCannotSubmitAfterRestart() async {
        let broker = MacDeviceLeaseBroker()
        let entryGate = PhotoEntryGate()
        let hardware = BlockedPhotoHardware(entryGate: entryGate)
        let camera = MacCameraController(
            authorizer: MacFixedAuthorizer(statuses: [.camera: .authorized]),
            broker: broker, hardware: hardware, relay: MacCodeRelay(), deviceProbe: { true }
        )
        let started = await camera.start()
        guard started else { return XCTFail("camera did not start") }
        let oldLease = broker.activeLease
        let oldCapture = Task { try await camera.capturePage() }
        guard await waitUntil({ entryGate.entered }) else {
            entryGate.release(); camera.stop(); return XCTFail("photo admission gate was not reached")
        }
        camera.stop()
        guard await waitUntil({ broker.activeLease == nil }) else {
            entryGate.release(); return XCTFail("old hardware stop did not release lease")
        }
        let restarted = await camera.start()
        guard restarted else { entryGate.release(); camera.stop(); return XCTFail("camera did not restart") }
        let newLease = broker.activeLease
        XCTAssertNotNil(newLease)
        XCTAssertNotEqual(oldLease, newLease)
        entryGate.release()
        do { _ = try await oldCapture.value; XCTFail("old photo call unexpectedly succeeded") }
        catch { XCTAssertEqual(error as? MacMediaFailure, .captureFailed("not-running")) }
        XCTAssertEqual(hardware.submitCount, 0)
        XCTAssertEqual(broker.activeLease, newLease)
        XCTAssertTrue(camera.running)
        camera.stop()
        let released = await waitUntil { broker.activeLease == nil }
        XCTAssertTrue(released)
    }

    func testBlockedPhotoSubmitDoesNotBlockStopAndLeaseWaitsForDeviceQueue() async {
        let broker = MacDeviceLeaseBroker()
        let hardware = BlockedPhotoHardware()
        let camera = MacCameraController(
            authorizer: MacFixedAuthorizer(statuses: [.camera: .authorized]),
            broker: broker, hardware: hardware, relay: MacCodeRelay(), deviceProbe: { true }
        )
        let started = await camera.start()
        guard started else { return XCTFail("camera did not start") }
        let capture = Task { try await camera.capturePage() }
        guard await waitUntil({ hardware.submitEntered }) else {
            hardware.unblockSubmit(); camera.stop(); return XCTFail("submit was not reached")
        }
        let held = broker.activeLease
        let before = ContinuousClock.now
        camera.stop()
        XCTAssertLessThan(before.duration(to: .now), .seconds(1))
        do { _ = try await capture.value; XCTFail("cancelled photo returned data") }
        catch { XCTAssertEqual(error as? MacMediaFailure, .captureFailed("cancelled")) }
        XCTAssertEqual(broker.activeLease, held)
        XCTAssertFalse(hardware.didStop)
        hardware.unblockSubmit()
        let released = await waitUntil { broker.activeLease == nil }
        XCTAssertTrue(released)
        XCTAssertTrue(hardware.didStop)
    }

    func testStopReturnsWhileStartIsBlockedAndLeaseWaitsForHardwareStop() async {
        let broker = MacDeviceLeaseBroker()
        let hardware = ControlledCameraHardware(failFirst: false)
        let camera = MacCameraController(
            authorizer: MacFixedAuthorizer(statuses: [.camera: .authorized]),
            broker: broker, hardware: hardware, relay: MacCodeRelay(), deviceProbe: { true }
        )
        let start = Task { await camera.start() }
        guard await waitUntil({ hardware.startCount == 1 }) else { hardware.unblockFirstStart(); return XCTFail("start not reached") }
        let heldLease = broker.activeLease
        let before = ContinuousClock.now
        camera.stop()
        let elapsed = before.duration(to: .now)
        XCTAssertLessThan(elapsed, .seconds(1))
        XCTAssertNotNil(heldLease)
        XCTAssertEqual(broker.activeLease, heldLease)
        XCTAssertEqual(hardware.stopCount, 0)
        hardware.unblockFirstStart()
        let started = await start.value
        XCTAssertFalse(started)
        let released = await waitUntil { broker.activeLease == nil }
        XCTAssertTrue(released)
        XCTAssertEqual(hardware.stopCount, 1)
    }

    func testPermissionReturningAfterInvisibilityDoesNotStartCamera() async {
        let broker = MacDeviceLeaseBroker()
        let hardware = ControlledCameraHardware(failFirst: false)
        let authorizer = OrderedCameraAuthorizer()
        var visible = true
        let camera = MacCameraController(authorizer: authorizer, broker: broker,
            hardware: hardware, relay: MacCodeRelay(), deviceProbe: { true }, captureAvailability: { visible })
        let start = Task { await camera.start() }
        guard await waitUntil({ authorizer.pendingCount == 1 }) else { return XCTFail("permission not reached") }
        visible = false
        authorizer.resumeFirst(.authorized)
        let started = await start.value
        XCTAssertFalse(started)
        XCTAssertEqual(hardware.startCount, 0)
        XCTAssertNil(broker.activeLease)
    }

    func testRestartDoesNotStartWhenVisibilityIsLostDuringStop() async {
        let broker = MacDeviceLeaseBroker()
        let hardware = ControlledCameraHardware(failFirst: false)
        var visible = true
        let camera = MacCameraController(authorizer: MacFixedAuthorizer(statuses: [.camera: .authorized]),
            broker: broker, hardware: hardware, relay: MacCodeRelay(), deviceProbe: { true }, captureAvailability: { visible })
        let start = Task { await camera.start() }
        guard await waitUntil({ hardware.startCount == 1 }) else { hardware.unblockFirstStart(); return XCTFail("start not reached") }
        let restart = Task { await camera.restart() }
        guard await waitUntil({ hardware.endCount > 0 }) else { hardware.unblockFirstStart(); return XCTFail("stop not reached") }
        visible = false
        hardware.unblockFirstStart()
        _ = await start.value
        let restarted = await restart.value
        XCTAssertFalse(restarted)
        XCTAssertEqual(hardware.startCount, 1)
        let released = await waitUntil { broker.activeLease == nil }
        XCTAssertTrue(released)
    }

    func testAlreadyCancelledAuthorizedStartDoesNotAcquireOrOpenHardware() async {
        let broker = MacDeviceLeaseBroker()
        let hardware = ControlledCameraHardware(failFirst: false)
        let camera = MacCameraController(
            authorizer: MacFixedAuthorizer(statuses: [.camera: .authorized]),
            broker: broker, hardware: hardware, relay: MacCodeRelay(), deviceProbe: { true }
        )
        let start = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await camera.start()
        }
        let started = await start.value
        XCTAssertFalse(started)
        XCTAssertNil(broker.activeLease)
        XCTAssertEqual(hardware.startCount, 0)
        XCTAssertFalse(camera.running)
    }

    func testTwoControllersCannotHandoffUntilHardwareStops() async {
        let broker = MacDeviceLeaseBroker()
        let firstHardware = ControlledCameraHardware(failFirst: false)
        let secondHardware = ControlledCameraHardware(failFirst: false)
        let authorizer = MacFixedAuthorizer(statuses: [.camera: .authorized])
        let first = MacCameraController(authorizer: authorizer, broker: broker,
                                        hardware: firstHardware, relay: MacCodeRelay(), deviceProbe: { true })
        let second = MacCameraController(authorizer: authorizer, broker: broker,
                                         hardware: secondHardware, relay: MacCodeRelay(), deviceProbe: { true })
        let old = Task { await first.start() }
        let entered = await waitUntil { firstHardware.startCount == 1 }
        guard entered else { firstHardware.unblockFirstStart(); return XCTFail("first start never entered") }
        let oldLease = broker.activeLease
        first.stop()
        let blocked = await second.start()
        XCTAssertFalse(blocked)
        XCTAssertTrue(second.leaseConflict)
        XCTAssertEqual(secondHardware.startCount, 0)
        XCTAssertEqual(broker.activeLease, oldLease)
        firstHardware.unblockFirstStart()
        _ = await old.value
        let released = await waitUntil { broker.activeLease == nil }
        guard released else { return XCTFail("first lease was not released after stop") }
        secondHardware.unblockFirstStart()
        let restarted = await second.start()
        XCTAssertTrue(restarted)
        XCTAssertEqual(second.lease, broker.activeLease)
        second.stop()
        let secondReleased = await waitUntil { broker.activeLease == nil }
        XCTAssertTrue(secondReleased)
    }

    func testQRCodeCapabilityTracksConfiguredHardwareAndStops() async {
        for supported in [false, true] {
            let broker = MacDeviceLeaseBroker()
            let hardware = ControlledCameraHardware(failFirst: false, supportsQRCode: supported)
            hardware.unblockFirstStart()
            let camera = MacCameraController(
                authorizer: MacFixedAuthorizer(statuses: [.camera: .authorized]),
                broker: broker, hardware: hardware, relay: MacCodeRelay(), deviceProbe: { true }
            )
            let started = await camera.start()
            XCTAssertTrue(started)
            XCTAssertEqual(camera.supportsQRCode, supported)
            camera.stop()
            XCTAssertFalse(camera.supportsQRCode)
            let released = await waitUntil { broker.activeLease == nil }
            XCTAssertTrue(released)
        }
    }

    private func exerciseStopAndRestart(failFirst: Bool) async {
        let broker = MacDeviceLeaseBroker()
        let hardware = ControlledCameraHardware(failFirst: failFirst)
        let relay = MacCodeRelay()
        let camera = MacCameraController(
            authorizer: MacFixedAuthorizer(statuses: [.camera: .authorized]),
            broker: broker, hardware: hardware, relay: relay, deviceProbe: { true }
        )
        let old = Task { await camera.start() }
        let entered = await waitUntil { hardware.startCount == 1 }
        guard entered else { hardware.unblockFirstStart(); return XCTFail("first start never entered") }
        let oldLease = broker.activeLease
        XCTAssertNotNil(oldLease)
        camera.stop()
        XCTAssertEqual(broker.activeLease, oldLease, "lease remains held until physical stop completes")
        XCTAssertNil(broker.acquire(.camera, owner: UUID()), "another window cannot enter while stopping")
        let restart = Task { await camera.restart() }
        await Task.yield()
        XCTAssertEqual(hardware.startCount, 1, "restart must wait for the old hardware stop")
        hardware.unblockFirstStart()
        let oldResult = await old.value
        let restarted = await restart.value
        XCTAssertFalse(oldResult)
        XCTAssertTrue(restarted)
        XCTAssertTrue(camera.running)
        XCTAssertNotNil(camera.lease)
        XCTAssertEqual(camera.lease, broker.activeLease)
        XCTAssertNotEqual(camera.lease, oldLease)
        XCTAssertEqual(hardware.stopCount, 1)
        camera.stop()
        let released = await waitUntil { broker.activeLease == nil }
        XCTAssertTrue(released)
        XCTAssertFalse(camera.running)
    }

    func testStaleSuccessfulStartCannotStopRestart() async {
        await exerciseStopAndRestart(failFirst: false)
    }

    func testStaleFailedStartCannotReleaseRestart() async {
        await exerciseStopAndRestart(failFirst: true)
    }

    func testStalePermissionCannotClearNewPrompt() async {
        let broker = MacDeviceLeaseBroker()
        let hardware = ControlledCameraHardware(failFirst: false)
        let authorizer = OrderedCameraAuthorizer()
        let camera = MacCameraController(authorizer: authorizer, broker: broker,
                                         hardware: hardware, relay: MacCodeRelay(), deviceProbe: { true })
        let old = Task { await camera.start() }
        let firstPending = await waitUntil { authorizer.pendingCount == 1 }
        guard firstPending else { return XCTFail("first prompt was not reached") }
        camera.stop()
        let stopped = await waitUntil { hardware.stopCount == 1 }
        guard stopped else { return XCTFail("stop did not complete") }
        let next = Task { await camera.start() }
        let secondPending = await waitUntil { authorizer.pendingCount == 2 }
        guard secondPending else { return XCTFail("second prompt was not reached") }
        authorizer.resumeFirst(.authorized)
        let oldResult = await old.value
        XCTAssertFalse(oldResult)
        XCTAssertTrue(camera.awaitingPermissionPrompt)
        XCTAssertNil(camera.lease)
        hardware.unblockFirstStart()
        authorizer.resumeFirst(.authorized)
        let newResult = await next.value
        XCTAssertTrue(newResult)
        XCTAssertTrue(camera.running)
        XCTAssertEqual(camera.lease, broker.activeLease)
        camera.stop()
        let released = await waitUntil { broker.activeLease == nil }
        XCTAssertTrue(released)
    }

    func testInterruptionStopsHardwareBeforeReleasingLease() async {
        let broker = MacDeviceLeaseBroker()
        let hardware = ControlledCameraHardware(failFirst: false)
        hardware.unblockFirstStart()
        let camera = MacCameraController(
            authorizer: MacFixedAuthorizer(statuses: [.camera: .authorized]),
            broker: broker, hardware: hardware, relay: MacCodeRelay(), deviceProbe: { true }
        )
        let started = await camera.start()
        XCTAssertTrue(started)
        NotificationCenter.default.post(name: AVCaptureSession.wasInterruptedNotification,
                                        object: hardware.session)
        let released = await waitUntil { broker.activeLease == nil }
        XCTAssertTrue(released)
        XCTAssertFalse(camera.running)
        XCTAssertEqual(camera.issue, .interrupted)
        XCTAssertEqual(hardware.stopCount, 1)
    }

    func testClosingCameraCancelsAnOutstandingPhoto() async {
        let broker = MacDeviceLeaseBroker()
        let hardware = ControlledCameraHardware(failFirst: false)
        hardware.unblockFirstStart()
        let camera = MacCameraController(
            authorizer: MacFixedAuthorizer(statuses: [.camera: .authorized]),
            broker: broker, hardware: hardware, relay: MacCodeRelay(), deviceProbe: { true }
        )
        let started = await camera.start()
        XCTAssertTrue(started)
        let capture = Task { try await camera.capturePage() }
        let pending = await waitUntil { hardware.hasPendingPhoto }
        guard pending else { camera.stop(); return XCTFail("photo request did not start") }
        camera.stop()
        do {
            _ = try await capture.value
            XCTFail("closing the camera must not return a photo")
        } catch {
            XCTAssertEqual(error as? MacMediaFailure, .captureFailed("cancelled"))
        }
        let released = await waitUntil { broker.activeLease == nil }
        XCTAssertTrue(released)
    }
}
