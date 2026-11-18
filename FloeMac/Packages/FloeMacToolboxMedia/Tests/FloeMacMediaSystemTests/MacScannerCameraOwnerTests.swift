import XCTest
import AVFoundation
import CoreImage
import FloeMacMediaCore
@testable import FloeMacMediaSystem

private actor ScannerPhotoGate {
    private var entered = false
    private var waiter: CheckedContinuation<Data, Never>?
    var isEntered: Bool { entered }
    func capture() async -> Data {
        entered = true
        return await withCheckedContinuation { waiter = $0 }
    }
    func finish(_ data: Data) { waiter?.resume(returning: data); waiter = nil }
}

private final class ScannerFakeHardware: MacCameraHardwareControlling, @unchecked Sendable {
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "floe.test.scanner.owner")
    let gate: ScannerPhotoGate
    private let lock = NSLock()
    private var running = false
    private var starts = 0
    init(gate: ScannerPhotoGate) { self.gate = gate }
    var captureIsRunning: Bool { lock.withLock { running } }
    var startCount: Int { lock.withLock { starts } }
    func begin(token: UInt64) {}
    func end() {}
    func latestFrame() -> CIImage? { nil }
    func setTorch(on: Bool) -> Bool { false }
    func setFocus(devicePoint: CGPoint) {}
    func capturePage(token: UInt64) async throws -> Data { await gate.capture() }
    func cancelPendingPhotos() {}
    func startOnQueue(token: UInt64) -> Result<MacCameraHardware.Capabilities, MacMediaFailure> {
        lock.withLock { running = true; starts += 1 }
        return .success(.init(name: "fixture", maximumZoom: 1, supportsTorch: false,
                              supportsFocus: false, supportsQRCode: true))
    }
    func stopAndWait() async { lock.withLock { running = false } }
}

@MainActor
final class MacScannerCameraOwnerTests: XCTestCase {
    private func waitFor(_ predicate: @escaping () async -> Bool) async -> Bool {
        for _ in 0..<250 { if await predicate() { return true }; try? await Task.sleep(for: .milliseconds(10)) }
        return await predicate()
    }

    func testSinglePresentationNoAutoStartAndQuitAdmission() async throws {
        let registry = MacCameraRegistry(), broker = MacDeviceLeaseBroker()
        let draft = MacScannerDraftOwner(), gate = ScannerPhotoGate()
        var hardware: [ScannerFakeHardware] = []
        let owner = MacScannerCameraOwner(draft: draft, registry: registry) {
            let fake = ScannerFakeHardware(gate: gate); hardware.append(fake)
            let camera = MacCameraController(authorizer: MacFixedAuthorizer(statuses: [.camera: .authorized]),
                broker: broker, hardware: fake, relay: MacCodeRelay(), deviceProbe: { true })
            camera.attachRegistry(registry); _ = registry.register(camera)
            return camera
        }
        let first = try XCTUnwrap(owner.appear { true })
        XCTAssertNil(owner.appear { true }, "another presentation cannot steal the camera")
        XCTAssertEqual(hardware[0].startCount, 0)
        let started = await owner.start(ticket: first)
        XCTAssertTrue(started)
        owner.disappear(ticket: UUID())
        XCTAssertNotNil(owner.camera)
        owner.disappear(ticket: first)
        let second = try XCTUnwrap(owner.appear { true })
        owner.disappear(ticket: first)
        XCTAssertNotNil(owner.camera, "stale close cannot stop the new surface")
        let secondStarted = await owner.start(ticket: second)
        XCTAssertTrue(secondStarted)
        draft.beginTermination()
        XCTAssertTrue(registry.beginTerminationPreparation())
        let staleStart = await owner.start(ticket: second)
        XCTAssertFalse(staleStart)
        XCTAssertNil(owner.appear { true })
        let stopped = await registry.waitForAllStopped()
        XCTAssertTrue(stopped)
        draft.cancelTermination(); registry.cancelTerminationPreparation()
        let restored = try XCTUnwrap(owner.appear { true })
        XCTAssertNotEqual(restored, second)
        owner.disappear(ticket: restored)
        let drained = await registry.retryRetiredStops()
        XCTAssertTrue(drained)
    }

    func testLatePhotoCannotEnterReopenedDraft() async throws {
        let registry = MacCameraRegistry(), broker = MacDeviceLeaseBroker()
        let draft = MacScannerDraftOwner(), gate = ScannerPhotoGate()
        let owner = MacScannerCameraOwner(draft: draft, registry: registry) {
            let camera = MacCameraController(authorizer: MacFixedAuthorizer(statuses: [.camera: .authorized]),
                broker: broker, hardware: ScannerFakeHardware(gate: gate), relay: MacCodeRelay(), deviceProbe: { true })
            camera.attachRegistry(registry); _ = registry.register(camera)
            return camera
        }
        let old = try XCTUnwrap(owner.appear { true })
        let started = await owner.start(ticket: old)
        XCTAssertTrue(started)
        let photo = Task { try await owner.capturePage(ticket: old) }
        let entered = await waitFor { await gate.isEntered }
        guard entered else { await gate.finish(Data()); _ = try? await photo.value; return XCTFail("capture did not start") }
        owner.disappear(ticket: old)
        let fresh = try XCTUnwrap(owner.appear { true })
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/aXcAAAAASUVORK5CYII="))
        await gate.finish(png)
        do { try await photo.value; XCTFail("stale photo unexpectedly admitted") } catch { }
        XCTAssertTrue(draft.pages.isEmpty)
        owner.disappear(ticket: fresh)
        let drained = await registry.retryRetiredStops()
        XCTAssertTrue(drained)
    }

    func testCancelledQuitReopensWithFreshSurfaceAndPreservedCodes() async throws {
        let registry = MacCameraRegistry(), broker = MacDeviceLeaseBroker()
        let draft = MacScannerDraftOwner(), gate = ScannerPhotoGate()
        let owner = MacScannerCameraOwner(draft: draft, registry: registry) {
            let camera = MacCameraController(authorizer: MacFixedAuthorizer(statuses: [.camera: .authorized]),
                broker: broker, hardware: ScannerFakeHardware(gate: gate), relay: MacCodeRelay(), deviceProbe: { true })
            camera.attachRegistry(registry); _ = registry.register(camera)
            return camera
        }
        let old = try XCTUnwrap(owner.appear { true })
        try draft.acceptLiveCodes([MacCapturedCode(payload: "first", symbology: "QR")], ticket: old)
        draft.beginTermination()
        XCTAssertTrue(registry.beginTerminationPreparation())
        let stopped = await registry.waitForAllStopped()
        XCTAssertTrue(stopped)
        draft.cancelTermination(); registry.cancelTerminationPreparation()
        let fresh = try XCTUnwrap(owner.appear { true })
        XCTAssertNotEqual(old, fresh)
        XCTAssertEqual(draft.results.map(\.payload), ["first"])
        XCTAssertThrowsError(try draft.acceptLiveCodes([MacCapturedCode(payload: "stale", symbology: "QR")], ticket: old))
        try draft.acceptLiveCodes([MacCapturedCode(payload: "second", symbology: "QR")], ticket: fresh)
        XCTAssertEqual(draft.results.map(\.payload), ["first", "second"])
        owner.disappear(ticket: fresh)
        let drained = await registry.retryRetiredStops()
        XCTAssertTrue(drained)
    }

    func testOverlappingVisibleSurfaceAutomaticallyAcquiresAfterPreviousDisappears() async throws {
        let registry = MacCameraRegistry(), broker = MacDeviceLeaseBroker()
        let draft = MacScannerDraftOwner(), gate = ScannerPhotoGate()
        var hardware: [ScannerFakeHardware] = []
        let owner = MacScannerCameraOwner(draft: draft, registry: registry) {
            let fake = ScannerFakeHardware(gate: gate); hardware.append(fake)
            let camera = MacCameraController(authorizer: MacFixedAuthorizer(statuses: [.camera: .authorized]),
                broker: broker, hardware: fake, relay: MacCodeRelay(), deviceProbe: { true })
            camera.attachRegistry(registry); _ = registry.register(camera)
            return camera
        }
        let first = MacScannerSurfaceLease(owner: owner), second = MacScannerSurfaceLease(owner: owner)
        first.appear { true }
        let old = try XCTUnwrap(first.ticket)
        try draft.acceptLiveCodes([MacCapturedCode(payload: "kept", symbology: "QR")], ticket: old)
        second.appear { true }
        XCTAssertNil(second.ticket)
        first.disappear()
        let newTicket = try XCTUnwrap(second.ticket, "visible waiting surface must be awakened")
        XCTAssertNotEqual(old, newTicket)
        XCTAssertEqual(draft.results.map(\.payload), ["kept"])
        XCTAssertNil(first.camera)
        XCTAssertEqual(hardware.map(\.startCount), [0, 0], "handoff must not start camera")
        second.disappear()
        let drained = await registry.retryRetiredStops()
        XCTAssertTrue(drained)
    }

    func testDisappearedWaitingSurfaceIsNotReopenedOnRelease() async throws {
        let registry = MacCameraRegistry(), broker = MacDeviceLeaseBroker()
        let gate = ScannerPhotoGate(), draft = MacScannerDraftOwner()
        var made = 0
        let owner = MacScannerCameraOwner(draft: draft, registry: registry) {
            made += 1
            let camera = MacCameraController(authorizer: MacFixedAuthorizer(statuses: [.camera: .authorized]),
                broker: broker, hardware: ScannerFakeHardware(gate: gate), relay: MacCodeRelay(), deviceProbe: { true })
            camera.attachRegistry(registry); _ = registry.register(camera)
            return camera
        }
        let first = MacScannerSurfaceLease(owner: owner), second = MacScannerSurfaceLease(owner: owner)
        first.appear { true }; second.appear { true }
        XCTAssertNil(second.ticket)
        second.disappear()
        first.disappear()
        XCTAssertNil(second.ticket)
        XCTAssertEqual(made, 1, "a dismissed waiter must not recreate a controller")
        let drained = await registry.retryRetiredStops()
        XCTAssertTrue(drained)
    }

    func testReentrantWaiterCannotBeOverwrittenByThirdSurfaceAfterQuitCancellation() async throws {
        let registry = MacCameraRegistry(), broker = MacDeviceLeaseBroker()
        let gate = ScannerPhotoGate(), draft = MacScannerDraftOwner()
        var hardware: [ScannerFakeHardware] = []
        let owner = MacScannerCameraOwner(draft: draft, registry: registry) {
            let fake = ScannerFakeHardware(gate: gate); hardware.append(fake)
            let camera = MacCameraController(authorizer: MacFixedAuthorizer(statuses: [.camera: .authorized]),
                broker: broker, hardware: fake, relay: MacCodeRelay(), deviceProbe: { true })
            camera.attachRegistry(registry); _ = registry.register(camera)
            return camera
        }
        let first = MacScannerSurfaceLease(owner: owner)
        let waiting = MacScannerSurfaceLease(owner: owner)
        let third = MacScannerSurfaceLease(owner: owner)
        first.appear { true }
        let old = try XCTUnwrap(first.ticket)
        try draft.acceptLiveCodes([MacCapturedCode(payload: "retained", symbology: "QR")], ticket: old)
        waiting.appear { true }
        XCTAssertNil(waiting.ticket)
        draft.beginTermination()
        XCTAssertTrue(registry.beginTerminationPreparation())
        let stopped = await registry.waitForAllStopped()
        XCTAssertTrue(stopped)
        draft.cancelTermination(); registry.cancelTerminationPreparation()

        // Third's appear retires the stale first controller. That operation
        // synchronously wakes waiting, which must keep the controller it gets.
        third.appear { true }
        let waitingTicket = try XCTUnwrap(waiting.ticket)
        XCTAssertNil(third.ticket)
        XCTAssertTrue(draft.isCurrentSurface(waitingTicket))
        XCTAssertNotNil(waiting.camera)
        XCTAssertNil(first.camera)
        XCTAssertEqual(draft.results.map(\.payload), ["retained"])
        XCTAssertTrue(hardware.allSatisfy { $0.startCount == 0 })

        first.disappear()
        XCTAssertEqual(waiting.ticket, waitingTicket, "stale first close must not revoke waiter")
        waiting.disappear()
        let thirdTicket = try XCTUnwrap(third.ticket, "third acquires after waiting leaves")
        XCTAssertTrue(draft.isCurrentSurface(thirdTicket))
        third.disappear()
        let drained = await registry.retryRetiredStops()
        XCTAssertTrue(drained)
    }
}
