// SPDX-License-Identifier: MPL-2.0
import XCTest
@testable import FloeMeetings

final class OwnedIngestionRegressionTests: XCTestCase {
    func testRejectedSecondStartCreatesNoGhostSessionAndFailedStartIsDurable() async throws {
        let (service, url) = try TestServices.makeService()
        defer { TestServices.cleanup(url) }
        let first = try await service.createMeeting(title: "First")
        let second = try await service.createMeeting(title: "Second")
        let config = CaptureConfiguration(directory: URL(fileURLWithPath: NSTemporaryDirectory()))
        _ = try await service.startCapture(meeting: first, backend: FakeCaptureBackend(), configuration: config)
        do {
            _ = try await service.startCapture(meeting: second, backend: FakeCaptureBackend(), configuration: config)
            XCTFail("second capture was accepted")
        } catch MeetingError.captureAlreadyActive { }
        let ghost = try await service.sessions(meeting: second)
        XCTAssertTrue(ghost.isEmpty)
        _ = try await service.cancelCapture()
        do {
            _ = try await service.startCapture(meeting: second, backend: SuspendedCaptureBackend(failBegin: true), configuration: config)
            XCTFail("failing backend reported successful start")
        } catch MeetingError.captureBackendFailed { }
        let snapshot = try await service.meeting(second)
        let sessions = try await service.sessions(meeting: second)
        XCTAssertEqual(snapshot.status, .draft)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.state, .failed)
    }

    func testCancelledSessionRejectsLateRecognizerResultsAndPersistsStatus() async throws {
        let (service, url) = try TestServices.makeService()
        defer { TestServices.cleanup(url) }
        let meeting = try await service.createMeeting(title: "Cancel")
        let session = try await service.startCapture(meeting: meeting, backend: FakeCaptureBackend(),
            configuration: .init(directory: URL(fileURLWithPath: NSTemporaryDirectory())))
        _ = try await service.beginPartial(meeting: meeting, session: session, text: "unfinished")
        _ = try await service.cancelCapture()
        do {
            _ = try await service.appendFinal(meeting: meeting, session: session, text: "late",
                                               range: MediaTimeRange(start: 0, end: 1))
            XCTFail("late final resurrected cancelled session")
        } catch MeetingError.captureSessionEnded { }
        do {
            _ = try await service.beginPartial(meeting: meeting, session: session, text: "late partial")
            XCTFail("late partial resurrected cancelled session")
        } catch MeetingError.captureSessionEnded { }
        let partials = await service.currentPartials(meeting: meeting)
        let transcript = try await service.transcript(meeting: meeting)
        let snapshot = try await service.meeting(meeting)
        XCTAssertTrue(partials.isEmpty)
        XCTAssertTrue(transcript.isEmpty)
        XCTAssertEqual(snapshot.status, .cancelled)
    }

    func testTimeoutFinalizesMeetingAndOldCallbacksCannotClearNewPartials() async throws {
        let (service, url) = try TestServices.makeService()
        defer { TestServices.cleanup(url) }
        let meeting = try await service.createMeeting(title: "Timeout")
        let backend = FakeCaptureBackend(); backend.flushOnRequestStop = false
        let config = CaptureConfiguration(directory: URL(fileURLWithPath: NSTemporaryDirectory()), stopTimeout: 0.05)
        let old = try await service.startCapture(meeting: meeting, backend: backend, configuration: config)
        _ = try await service.beginPartial(meeting: meeting, session: old, text: "old")
        let outcome = try await service.stopCapture()
        XCTAssertEqual(outcome.stopReason, .timeout)
        let finished = try await service.meeting(meeting)
        XCTAssertEqual(finished.status, .finished)
        let released = await TestWait.until { await service.activeCaptureSession == nil }
        XCTAssertTrue(released)
        let fresh = try await service.startCapture(meeting: meeting, backend: FakeCaptureBackend(), configuration: config)
        let partial = try await service.beginPartial(meeting: meeting, session: fresh, text: "new")
        backend.emit(.stopped(session: old, reason: .userStopped))
        backend.emit(.failed(session: old, message: "late"))
        // Queue a read behind the controller/service event tasks.
        try await Task.sleep(nanoseconds: 30_000_000)
        let current = await service.currentPartials(meeting: meeting)
        let snapshot = try await service.meeting(meeting)
        XCTAssertEqual(current.map(\.id), [partial])
        XCTAssertEqual(snapshot.status, .capturing)
        _ = try await service.cancelCapture()
    }

    func testCrossMeetingSessionIsRejectedAndCommitKeepsIDAfterFailure() async throws {
        let (service, url) = try TestServices.makeService()
        defer { TestServices.cleanup(url) }
        let meeting = try await service.createMeeting(title: "A")
        let other = try await service.createMeeting(title: "B")
        let session = try await TestServices.importedSession(service, meeting: meeting)
        do {
            _ = try await service.appendFinal(meeting: other, session: session, text: "wrong owner",
                                              range: MediaTimeRange(start: 0, end: 1))
            XCTFail("cross-meeting session was accepted")
        } catch MeetingError.sessionNotFound { }
        let partial = try await service.beginPartial(meeting: meeting, session: session, text: "keep me")
        var invalid = try MediaTimeRange(start: 0, end: 1); invalid.end = .infinity
        do {
            _ = try await service.commitPartial(partial, meeting: meeting, range: invalid)
            XCTFail("invalid media range was saved")
        } catch MeetingError.invalidTimeRange { }
        let retained = await service.currentPartials(meeting: meeting)
        XCTAssertEqual(retained.map(\.id), [partial])
        let final = try await service.commitPartial(partial, meeting: meeting, range: MediaTimeRange(start: 0, end: 1))
        XCTAssertEqual(final.id, partial)
        XCTAssertEqual(final.text, "keep me")
    }

    func testOrdinalIsAllocatedDurablyAfterReopen() async throws {
        let (service, url) = try TestServices.makeService()
        defer { TestServices.cleanup(url) }
        let meeting = try await service.createMeeting(title: "Reopen")
        let session = try await TestServices.importedSession(service, meeting: meeting)
        let range = try MediaTimeRange(start: 0, end: 1)
        let first = try await service.appendFinal(meeting: meeting, session: session, text: "first", range: range)
        let reopened = MeetingService(database: try MeetingDatabase(path: url.path))
        let second = try await reopened.appendFinal(meeting: meeting, session: session, text: "second", range: range)
        XCTAssertEqual(second.ordinal, first.ordinal + 1)
        let transcript = try await reopened.transcript(meeting: meeting)
        XCTAssertEqual(transcript.map(\.text), ["first", "second"])
    }

    func testSeparateRecordingsDoNotInterleaveTheirIndependentMediaClocks() async throws {
        let (service, url) = try TestServices.makeService()
        defer { TestServices.cleanup(url) }
        let meeting = try await service.createMeeting(title: "Two recordings")
        let first = try await TestServices.importedSession(service, meeting: meeting)
        let second = try await TestServices.importedSession(service, meeting: meeting)
        _ = try await service.appendFinal(meeting: meeting, session: first, text: "earlier recording",
                                          range: MediaTimeRange(start: 50, end: 51))
        _ = try await service.appendFinal(meeting: meeting, session: second, text: "later recording",
                                          range: MediaTimeRange(start: 0, end: 1))
        let transcript = try await service.transcript(meeting: meeting)
        XCTAssertEqual(transcript.map(\.sessionID), [first, second])
    }
}
