import XCTest
import FloeMacMediaCore

@MainActor
final class MacDeviceLeaseTests: XCTestCase {
    func testSingleLeaseAcrossWindows() {
        let broker = MacDeviceLeaseBroker()
        let firstWindow = UUID()
        let secondWindow = UUID()
        guard let lease = broker.acquire(.camera, owner: firstWindow) else {
            return XCTFail("first acquisition should succeed")
        }
        XCTAssertNil(broker.acquire(.camera, owner: secondWindow))
        XCTAssertTrue(broker.owns(lease))
        XCTAssertTrue(broker.isBusy(for: secondWindow))
        XCTAssertFalse(broker.isBusy(for: firstWindow))
        XCTAssertEqual(broker.activeLease(for: .camera), lease)
    }

    func testStaleReleaseCannotDisturbNewOwner() {
        let broker = MacDeviceLeaseBroker()
        let firstOwner = UUID()
        let secondOwner = UUID()
        guard let first = broker.acquire(.microphone, owner: firstOwner) else {
            return XCTFail("first acquisition should succeed")
        }
        XCTAssertFalse(broker.releaseAll(owner: secondOwner))
        XCTAssertTrue(broker.release(first))
        guard let second = broker.acquire(.microphone, owner: secondOwner) else {
            return XCTFail("second acquisition should succeed")
        }
        XCTAssertFalse(broker.release(first))
        XCTAssertEqual(broker.activeLease, second)
        XCTAssertTrue(broker.owns(second))
        XCTAssertTrue(broker.releaseAll(owner: secondOwner))
        XCTAssertNil(broker.activeLease)
    }

    func testGenerationIncreasesForEveryAcquisition() {
        let broker = MacDeviceLeaseBroker()
        guard let first = broker.acquire(.camera, owner: UUID()) else {
            return XCTFail("first acquisition should succeed")
        }
        broker.release(first)
        guard let second = broker.acquire(.camera, owner: UUID()) else {
            return XCTFail("second acquisition should succeed")
        }
        XCTAssertGreaterThan(second.generation, first.generation)
        XCTAssertNotEqual(first.id, second.id)
    }
}

final class MacCameraSurfaceTests: XCTestCase {
    func testNoLeaseDefaultsToIdle() {
        XCTAssertEqual(MacCameraSurfaceResolver.surface(for: MacCameraInputs()), .idle)
    }

    func testLeaseConflictIsVisibleBeforeAnyLease() {
        var inputs = MacCameraInputs()
        inputs.leaseConflict = true
        XCTAssertEqual(MacCameraSurfaceResolver.surface(for: inputs), .busy)
    }

    func testDeniedPermissionIsVisibleWithoutLease() {
        var inputs = MacCameraInputs()
        inputs.authorization = .denied
        XCTAssertEqual(MacCameraSurfaceResolver.surface(for: inputs), .denied)
        inputs.authorization = .restricted
        XCTAssertEqual(MacCameraSurfaceResolver.surface(for: inputs), .denied)
        inputs.authorization = .unavailable
        XCTAssertEqual(MacCameraSurfaceResolver.surface(for: inputs), .denied)
    }

    func testProbeFailureAndEngineFailureStayVisible() {
        var inputs = MacCameraInputs()
        inputs.deviceProbeFailed = true
        XCTAssertEqual(MacCameraSurfaceResolver.surface(for: inputs), .noDevice)

        var failed = MacCameraInputs()
        failed.issue = .failed("camera-input")
        XCTAssertEqual(MacCameraSurfaceResolver.surface(for: failed), .failed)
    }

    func testHeldLeaseOrderingMatchesIOSPrecedence() {
        var inputs = MacCameraInputs(holdsLease: true, authorization: .authorized, deviceAvailable: true)
        XCTAssertEqual(MacCameraSurfaceResolver.surface(for: inputs), .starting)

        inputs.running = true
        XCTAssertEqual(MacCameraSurfaceResolver.surface(for: inputs), .running)

        inputs.frozen = true
        XCTAssertEqual(MacCameraSurfaceResolver.surface(for: inputs), .frozen)

        inputs.issue = .inUseByAnotherApplication
        XCTAssertEqual(MacCameraSurfaceResolver.surface(for: inputs), .busy)

        inputs.issue = .interrupted
        XCTAssertEqual(MacCameraSurfaceResolver.surface(for: inputs), .interrupted)

        inputs.issue = .failed("runtime")
        XCTAssertEqual(MacCameraSurfaceResolver.surface(for: inputs), .failed)

        inputs.issue = .none
        inputs.deviceAvailable = false
        XCTAssertEqual(MacCameraSurfaceResolver.surface(for: inputs), .noDevice)

        inputs.deviceAvailable = true
        inputs.authorization = .denied
        XCTAssertEqual(MacCameraSurfaceResolver.surface(for: inputs), .denied)
    }
}
