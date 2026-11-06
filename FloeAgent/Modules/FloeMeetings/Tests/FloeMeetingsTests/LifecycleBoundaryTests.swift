// SPDX-License-Identifier: MPL-2.0
import XCTest
@testable import FloeMeetings

final class LifecycleBoundaryTests: XCTestCase {
    private var config: CaptureConfiguration {
        .init(directory: URL(fileURLWithPath: NSTemporaryDirectory()), stopTimeout: 0.05)
    }

    func testHungStopIsBoundedAndRetainsPhysicalOwnerUntilCallReturns() async throws {
        let controller = MeetingCaptureController()
        let gate = TestGate()
        let backend = SuspendedCaptureBackend(stop: gate)
        let session = CaptureSessionID()
        try await controller.start(session: session, configuration: config, backend: backend) { _ in }
        let outcome = try await controller.stop().get()
        XCTAssertEqual(outcome.stopReason, .timeout)
        let cleanupStarted = await TestWait.until { await backend.cancelEntered }
        XCTAssertTrue(cleanupStarted)
        do {
            try await controller.start(session: CaptureSessionID(), configuration: config, backend: FakeCaptureBackend()) { _ in }
            XCTFail("physical owner was released while its stop call was suspended")
        } catch MeetingError.captureAlreadyActive(let owner) { XCTAssertEqual(owner, session) }
        let repeated = try await controller.stop().get()
        XCTAssertEqual(repeated, outcome)
        await gate.release()
        let released = await TestWait.until { await controller.activeSession == nil }
        XCTAssertTrue(released)
        let cached = try await controller.stop().get()
        XCTAssertEqual(cached, outcome)
    }

    func testCancelDuringBeginCannotLetOldBackendStartAfterReplacement() async throws {
        let controller = MeetingCaptureController()
        let gate = TestGate()
        let backend = SuspendedCaptureBackend(begin: gate)
        let session = CaptureSessionID()
        let configuration = config
        let start = Task { () -> Bool in
            do { try await controller.start(session: session, configuration: configuration, backend: backend) { _ in }; return true }
            catch { return false }
        }
        let entered = await TestWait.until { await backend.beginEntered }
        XCTAssertTrue(entered)
        let cancel = Task { await controller.cancel() }
        let fenced = await TestWait.until { await controller.isCleaningUp }
        XCTAssertTrue(fenced)
        do {
            try await controller.start(session: CaptureSessionID(), configuration: config, backend: FakeCaptureBackend()) { _ in }
            XCTFail("replacement began before old begin completed")
        } catch MeetingError.captureAlreadyActive { }
        await gate.release()
        let startSucceeded = await start.value
        XCTAssertFalse(startSucceeded)
        let cancelled = await cancel.value
        XCTAssertEqual(cancelled, session)
        let released = await controller.activeSession
        XCTAssertNil(released)
    }

    func testCancelDuringStopResumesStopButBlocksReplacementUntilRelease() async throws {
        let controller = MeetingCaptureController()
        let gate = TestGate()
        let backend = SuspendedCaptureBackend(stop: gate)
        let session = CaptureSessionID()
        var configuration = config; configuration.stopTimeout = 2
        try await controller.start(session: session, configuration: configuration, backend: backend) { _ in }
        let stop = Task { await controller.stop() }
        let entered = await TestWait.until { await backend.stopEntered }
        XCTAssertTrue(entered)
        let cancel = Task { await controller.cancel() }
        let stopped = try await stop.value.get()
        XCTAssertEqual(stopped.state, .cancelled)
        let owner = await controller.activeSession
        XCTAssertEqual(owner, session)
        await gate.release()
        let cancelled = await cancel.value
        XCTAssertEqual(cancelled, session)
    }
}
