import XCTest
import AVFoundation
import CoreImage
import FloeMacMediaCore
@testable import FloeMacMediaSystem

private final class RefusingScannerHardware: MacCameraHardwareControlling, @unchecked Sendable {
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "floe.test.camera.unconfirmed-stop")
    private let lock = NSLock()
    private var live = false
    private var attempts = 0
    private var starts = 0
    private var retryWaiter: CheckedContinuation<Void, Never>?
    private var retryReleased = false
    var captureIsRunning: Bool { lock.withLock { live } }
    var stopAttempts: Int { lock.withLock { attempts } }
    var startCount: Int { lock.withLock { starts } }
    func begin(token: UInt64) {}
    func end() {}
    func latestFrame() -> CIImage? { nil }
    func setTorch(on: Bool) -> Bool { false }
    func setFocus(devicePoint: CGPoint) {}
    func capturePage(token: UInt64) async throws -> Data { throw MacMediaFailure.captureFailed("unused") }
    func cancelPendingPhotos() {}
    func startOnQueue(token: UInt64) -> Result<MacCameraHardware.Capabilities, MacMediaFailure> {
        lock.withLock { live = true; starts += 1 }
        return .success(.init(name: "fixture", maximumZoom: 1, supportsTorch: false,
                              supportsFocus: false, supportsQRCode: false))
    }
    func stopAndWait() async {
        let n = lock.withLock { attempts += 1; return attempts }
        guard n > 1 else { return }
        await withCheckedContinuation { continuation in
            let resume = lock.withLock {
                if retryReleased { return true }
                retryWaiter = continuation
                return false
            }
            if resume { continuation.resume() }
        }
        lock.withLock { live = false }
    }
    func releaseRetry() {
        let waiter = lock.withLock {
            retryReleased = true
            let value = retryWaiter
            retryWaiter = nil
            return value
        }
        waiter?.resume()
    }
}


@MainActor
final class MacCameraRetryIntegrationTests: XCTestCase {
    private func waitUntil(_ predicate: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<300 { if predicate() { return true }; try? await Task.sleep(for: .milliseconds(10)) }; return predicate()
    }

    func testVisibleUnconfirmedStopShowsRetryAndHoldsLeaseUntilRestartConfirms() async {
        let registry = MacCameraRegistry(), broker = MacDeviceLeaseBroker()
        let hardware = RefusingScannerHardware()
        let camera = MacCameraController(authorizer: MacFixedAuthorizer(statuses: [.camera: .authorized]),
            broker: broker, hardware: hardware, relay: MacCodeRelay(), deviceProbe: { true })
        camera.attachRegistry(registry)
        XCTAssertTrue(registry.register(camera))
        defer { hardware.releaseRetry(); camera.closeForWindow() }
        let started = await camera.start()
        guard started else { return XCTFail("fixture camera did not start") }
        let held = broker.activeLease
        XCTAssertNotNil(held)
        camera.stop() // ordinary in-window stop, not retirement or quit
        guard await waitUntil({ hardware.stopAttempts == 1 }) else { return XCTFail("stop was not attempted") }
        // Wait until the completed stop operation publishes its state; on the
        // old implementation it remains .starting and exposes no retry.
        guard await waitUntil({ camera.surface == .failed }) else {
            return XCTFail("unconfirmed in-window stop must expose Retry")
        }
        XCTAssertEqual(broker.activeLease, held)
        let retry = Task { await camera.restart() }
        guard await waitUntil({ hardware.stopAttempts >= 2 }) else {
            hardware.releaseRetry(); _ = await retry.value
            return XCTFail("Retry must request the old owner's real stop")
        }
        XCTAssertEqual(broker.activeLease, held)
        XCTAssertEqual(hardware.startCount, 1, "must not start before stop confirmation")
        hardware.releaseRetry()
        let restarted = await retry.value
        XCTAssertTrue(restarted)
        XCTAssertEqual(hardware.startCount, 2)
        XCTAssertTrue(camera.running)
        camera.closeForWindow()
        let stopped = await camera.waitUntilStopped()
        XCTAssertTrue(stopped)
    }

    func testMagnifierRapidReopenCannotStartAfterSecondDisappearWhileOldStopIsPending() async {
        let registry = MacCameraRegistry(), broker = MacDeviceLeaseBroker()
        var hardware: [RefusingScannerHardware] = []
        let owner = MacMagnifierOwner(registry: registry) {
            let item = RefusingScannerHardware(); hardware.append(item)
            let camera = MacCameraController(authorizer: MacFixedAuthorizer(statuses: [.camera: .authorized]),
                broker: broker, hardware: item, relay: MacCodeRelay(), deviceProbe: { true })
            camera.attachRegistry(registry); _ = registry.register(camera)
            return camera
        }
        owner.appear { true }
        guard let first = owner.startTicket() else { return XCTFail("missing first ticket") }
        let firstStarted = await owner.start(ticket: first)
        XCTAssertTrue(firstStarted)
        owner.disappear()
        guard await waitUntil({ hardware[0].stopAttempts >= 2 }) else {
            hardware[0].releaseRetry(); return XCTFail("old stop did not block")
        }
        owner.appear { true }
        guard let second = owner.startTicket() else { hardware[0].releaseRetry(); return XCTFail("missing second ticket") }
        let queued = Task { await owner.start(ticket: second) }
        await Task.yield()
        owner.disappear()
        hardware[0].releaseRetry()
        let queuedStarted = await queued.value
        XCTAssertFalse(queuedStarted)
        XCTAssertEqual(hardware.count, 2)
        XCTAssertEqual(hardware[1].startCount, 0)
        let drained = await registry.retryRetiredStops()
        XCTAssertTrue(drained)
    }

    func testMagnifierQuitFenceRejectsOldTicketAndRestoresFreshCameraAfterCancellation() async {
        let registry = MacCameraRegistry(), broker = MacDeviceLeaseBroker()
        var hardware: [RefusingScannerHardware] = []
        let owner = MacMagnifierOwner(registry: registry) {
            let item = RefusingScannerHardware(); item.releaseRetry(); hardware.append(item)
            let camera = MacCameraController(authorizer: MacFixedAuthorizer(statuses: [.camera: .authorized]),
                broker: broker, hardware: item, relay: MacCodeRelay(), deviceProbe: { true })
            camera.attachRegistry(registry); _ = registry.register(camera)
            return camera
        }
        owner.appear { true }
        guard let stale = owner.startTicket() else { return XCTFail("missing ticket") }
        XCTAssertTrue(registry.beginTerminationPreparation())
        XCTAssertNil(owner.startTicket())
        let rejectedDuringQuit = await owner.start(ticket: stale)
        XCTAssertFalse(rejectedDuringQuit)
        let drainedForQuit = await registry.waitForAllStopped()
        XCTAssertTrue(drainedForQuit)
        registry.cancelTerminationPreparation()
        owner.terminationCancelled()
        let rejectedOldTicket = await owner.start(ticket: stale)
        XCTAssertFalse(rejectedOldTicket)
        guard let fresh = owner.startTicket() else { return XCTFail("missing restored ticket") }
        let freshStarted = await owner.start(ticket: fresh)
        XCTAssertTrue(freshStarted)
        XCTAssertEqual(hardware[0].startCount, 0)
        XCTAssertEqual(hardware[1].startCount, 1)
        owner.windowClosed()
        XCTAssertNil(owner.startTicket())
        owner.windowReopened()
        XCTAssertNotNil(owner.startTicket())
        owner.disappear()
        let drained = await registry.retryRetiredStops()
        XCTAssertTrue(drained)
    }

}
