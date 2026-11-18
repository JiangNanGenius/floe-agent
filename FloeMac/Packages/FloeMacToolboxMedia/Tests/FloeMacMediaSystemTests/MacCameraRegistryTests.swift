import FloeMacMediaCore
import Foundation
@testable import FloeMacMediaSystem
import XCTest

@MainActor
private final class RegisteredFakeCamera: MacScannerCaptureOwning {
    let name: String
    private(set) var closeCount = 0
    private(set) var waitCount = 0
    private(set) var completedWaitCount = 0
    var reportsStopped = false
    var waitUntilReleased = false
    private var pending: [CheckedContinuation<Void, Never>] = []

    init(_ name: String) { self.name = name }
    func closeForWindow() { closeCount += 1 }
    func waitUntilStopped() async -> Bool {
        waitCount += 1
        if waitUntilReleased { await withCheckedContinuation { pending.append($0) } }
        completedWaitCount += 1
        return reportsStopped
    }
    func release(stopped: Bool) {
        reportsStopped = stopped
        waitUntilReleased = false
        let values = pending; pending.removeAll()
        for value in values { value.resume() }
    }
}

@MainActor
final class MacCameraRegistryTests: XCTestCase {
    private func eventually(_ predicate: @MainActor () -> Bool) async -> Bool {
        let limit = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < limit {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }

    func testQuitFencesScannerMagnifierAndQRBeforeAwaitingAllOwners() async throws {
        let registry = MacCameraRegistry()
        let scanner = RegisteredFakeCamera("scanner"), magnifier = RegisteredFakeCamera("magnifier")
        let qr = RegisteredFakeCamera("qr")
        let all = [scanner, magnifier, qr]
        for camera in all {
            camera.waitUntilReleased = true
            XCTAssertTrue(registry.register(camera))
            XCTAssertTrue(registry.admit(camera))
        }
        let epoch = registry.cameraEpoch
        XCTAssertTrue(registry.beginTerminationPreparation())
        XCTAssertTrue(all.allSatisfy { $0.closeCount == 1 })
        let extra = RegisteredFakeCamera("late")
        XCTAssertFalse(registry.register(extra))
        XCTAssertEqual(extra.closeCount, 1)
        XCTAssertFalse(registry.admit(scanner))
        var waitFinished = false
        let stopped = Task { let result = await registry.waitForAllStopped(); waitFinished = true; return result }
        guard await eventually({ all.allSatisfy { $0.waitCount > 0 } }) else {
            for camera in all { camera.release(stopped: true) }
            _ = await stopped.value
            return XCTFail("all registered cameras must begin draining")
        }
        XCTAssertFalse(waitFinished, "quit cannot finish while all three stops are gated")
        scanner.release(stopped: true)
        guard await eventually({ scanner.completedWaitCount == 1 }) else {
            qr.release(stopped: true); magnifier.release(stopped: true)
            _ = await stopped.value
            return XCTFail("scanner stop did not finish")
        }
        XCTAssertFalse(waitFinished, "quit cannot finish while QR and magnifier remain")
        qr.release(stopped: true)
        guard await eventually({ qr.completedWaitCount == 1 }) else {
            magnifier.release(stopped: true)
            _ = await stopped.value
            return XCTFail("QR stop did not finish")
        }
        XCTAssertFalse(waitFinished, "quit cannot finish while magnifier remains")
        magnifier.release(stopped: true)
        let confirmed = await stopped.value
        XCTAssertTrue(confirmed)
        registry.cancelTerminationPreparation()
        XCTAssertNotEqual(registry.cameraEpoch, epoch)
        let fresh = RegisteredFakeCamera("fresh")
        XCTAssertTrue(registry.register(fresh))
    }

    func testCancellingQuitWhileStopDrainsCannotApproveOldPreparation() async {
        let registry = MacCameraRegistry(), camera = RegisteredFakeCamera("delayed")
        camera.waitUntilReleased = true
        XCTAssertTrue(registry.register(camera))
        XCTAssertTrue(registry.admit(camera))
        XCTAssertTrue(registry.beginTerminationPreparation())
        let waiting = Task { await registry.waitForAllStopped() }
        guard await eventually({ camera.waitCount > 0 }) else {
            camera.release(stopped: true)
            _ = await waiting.value
            return XCTFail("stop wait not entered")
        }
        registry.cancelTerminationPreparation()
        camera.release(stopped: true)
        let oldResult = await waiting.value
        XCTAssertFalse(oldResult)
        let fresh = RegisteredFakeCamera("new epoch")
        XCTAssertTrue(registry.register(fresh))
    }

    func testIdleEntriesAreWeakButAdmittedControllersAreRetained() {
        let registry = MacCameraRegistry()
        var idle: RegisteredFakeCamera? = RegisteredFakeCamera("idle")
        weak var weakIdle = idle
        XCTAssertTrue(registry.register(idle!))
        idle = nil
        XCTAssertNil(weakIdle)
        var active: RegisteredFakeCamera? = RegisteredFakeCamera("active")
        weak var weakActive = active
        XCTAssertTrue(registry.register(active!))
        XCTAssertTrue(registry.admit(active!))
        active = nil
        XCTAssertNotNil(weakActive)
        XCTAssertTrue(registry.beginTerminationPreparation())
        weakActive?.reportsStopped = true
    }

    func testRetiredUnconfirmedOwnerStaysRetainedUntilExplicitRetry() async {
        let registry = MacCameraRegistry()
        let camera = RegisteredFakeCamera("old scanner")
        XCTAssertTrue(registry.register(camera))
        XCTAssertTrue(registry.admit(camera))
        registry.retire(camera)
        guard await eventually({ camera.waitCount > 0 }) else { return XCTFail("retired stop not attempted") }
        XCTAssertEqual(registry.retainedUnconfirmedCount, 1)
        let first = await registry.retryRetiredStops()
        XCTAssertFalse(first)
        XCTAssertEqual(registry.retainedUnconfirmedCount, 1)
        camera.reportsStopped = true
        let retry = await registry.retryRetiredStops()
        XCTAssertTrue(retry)
        XCTAssertEqual(registry.retainedUnconfirmedCount, 0)
    }
}
