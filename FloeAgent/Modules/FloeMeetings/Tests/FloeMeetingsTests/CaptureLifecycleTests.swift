// SPDX-License-Identifier: MPL-2.0
import XCTest
@testable import FloeMeetings

final class CaptureLifecycleTests: XCTestCase {
    func testStopAwaitsBackendFlushAndIsIdempotent() async throws {
        let controller = MeetingCaptureController()
        let backend = FakeCaptureBackend()
        backend.flushOnRequestStop = false
        let session = CaptureSessionID()
        let config = CaptureConfiguration(directory: URL(fileURLWithPath: NSTemporaryDirectory()), stopTimeout: 2)
        let log = EventLog()
        try await controller.start(session: session, configuration: config, backend: backend) { event in
            Task { await log.append(event) }
        }

        XCTAssertFalse(backend.stopRequested)

        async let first: Result<MeetingCaptureController.Outcome, MeetingError> = controller.stop()
        async let second: Result<MeetingCaptureController.Outcome, MeetingError> = controller.stop()

        let flushStarted = await TestWait.until { @Sendable in backend.stopRequested }
        XCTAssertTrue(flushStarted)
        backend.emit(.stopped(session: session, reason: .userStopped))

        let outcomes = try await [first, second].map { result -> MeetingCaptureController.Outcome in
            switch result {
            case .success(let outcome): return outcome
            case .failure(let error): throw error
            }
        }
        XCTAssertEqual(outcomes[0].session, session)
        XCTAssertEqual(outcomes[0].state, .stopped)
        XCTAssertEqual(outcomes[0].stopReason, .userStopped)
        XCTAssertEqual(outcomes[0], outcomes[1])
        XCTAssertTrue(backend.stopRequested)
    }

    func testStopWithoutActiveCaptureFails() async {
        let controller = MeetingCaptureController()
        let result = await controller.stop()
        guard case .failure(.noActiveCapture) = result else {
            XCTFail("expected noActiveCapture, got \(result)")
            return
        }
    }

    func testStopTimeoutKeepsPartialDataAndReportsTimeout() async throws {
        let controller = MeetingCaptureController()
        let backend = FakeCaptureBackend()
        backend.flushOnRequestStop = false
        let session = CaptureSessionID()
        let config = CaptureConfiguration(directory: URL(fileURLWithPath: NSTemporaryDirectory()), stopTimeout: 0.05)
        try await controller.start(session: session, configuration: config, backend: backend) { _ in }

        let outcome = try await controller.stop().get()
        XCTAssertEqual(outcome.session, session)
        XCTAssertEqual(outcome.state, .stopped)
        XCTAssertEqual(outcome.stopReason, .timeout)

        // The backend's late stopped event must be dropped by the fence and
        // must not touch a later session.
        backend.emit(.stopped(session: session, reason: .userStopped))
        let released = await TestWait.until { await controller.activeSession == nil }
        XCTAssertTrue(released, "timeout must request backend release")
        let lateSession = CaptureSessionID()
        try await controller.start(session: lateSession, configuration: config, backend: backend) { _ in }
        let active = await controller.activeSession
        XCTAssertEqual(active, lateSession)
    }

    func testCancelIsIdempotentAndManufacturesNoFinal() async throws {
        let controller = MeetingCaptureController()
        let backend = FakeCaptureBackend()
        let session = CaptureSessionID()
        let config = CaptureConfiguration(directory: URL(fileURLWithPath: NSTemporaryDirectory()))
        let log = EventLog()
        try await controller.start(session: session, configuration: config, backend: backend) { event in
            Task { await log.append(event) }
        }
        let firstCancel = await controller.cancel()
        XCTAssertEqual(firstCancel, session)
        let secondCancel = await controller.cancel()
        XCTAssertNil(secondCancel)
        XCTAssertEqual(backend.cancelCount, 1)

        // Late events after cancel are fenced out: no stopped, no chunk. The
        // started event may legitimately win or lose the race with cancel
        // (it is dropped if cancel completes first), so only terminal and
        // chunk events are asserted here.
        backend.emit(.stopped(session: session, reason: .userStopped))
        backend.emit(.chunkFinalized(session: session, file: URL(fileURLWithPath: "/tmp/x"), range: MediaTimeRange(uncheckedStart: 0, end: 1)))
        try? await Task.sleep(nanoseconds: 50_000_000)
        let events = await log.events
        let fencedCount = events.filter { event in
            if case .stopped = event { return true }
            if case .chunkFinalized = event { return true }
            return false
        }.count
        XCTAssertEqual(fencedCount, 0)
    }

    func testEventsFromPreviousGenerationNeverReachNewSession() async throws {
        let controller = MeetingCaptureController()
        let backendA = FakeCaptureBackend()
        let backendB = FakeCaptureBackend()
        let config = CaptureConfiguration(directory: URL(fileURLWithPath: NSTemporaryDirectory()))
        let sessionA = CaptureSessionID()
        let sessionB = CaptureSessionID()
        let log = EventLog()
        try await controller.start(session: sessionA, configuration: config, backend: backendA) { event in
            Task { await log.append(event) }
        }
        // Hold A's events; end A.
        _ = await controller.cancel()
        try await controller.start(session: sessionB, configuration: config, backend: backendB) { event in
            Task { await log.append(event) }
        }
        // A fires a late chunk for its own (old) session id → dropped.
        await backendA.emit(.chunkFinalized(session: sessionA, file: URL(fileURLWithPath: "/tmp/a"), range: MediaTimeRange(uncheckedStart: 0, end: 1)))
        // B's event is delivered.
        await backendB.emit(.chunkFinalized(session: sessionB, file: URL(fileURLWithPath: "/tmp/b"), range: MediaTimeRange(uncheckedStart: 0, end: 1)))
        try? await Task.sleep(nanoseconds: 50_000_000)

        let events = await log.events
        var chunks: [CaptureSessionID] = []
        for event in events {
            if case .chunkFinalized(let s, _, _) = event { chunks.append(s) }
        }
        XCTAssertEqual(chunks, [sessionB])
    }

    func testStartWhileActiveThrows() async throws {
        let controller = MeetingCaptureController()
        let config = CaptureConfiguration(directory: URL(fileURLWithPath: NSTemporaryDirectory()))
        let first = CaptureSessionID()
        try await controller.start(session: first, configuration: config, backend: FakeCaptureBackend()) { _ in }
        do {
            try await controller.start(session: CaptureSessionID(), configuration: config, backend: FakeCaptureBackend()) { _ in }
            XCTFail("expected captureAlreadyActive")
        } catch MeetingError.captureAlreadyActive(let session) {
            XCTAssertEqual(session, first)
        }
    }
}
