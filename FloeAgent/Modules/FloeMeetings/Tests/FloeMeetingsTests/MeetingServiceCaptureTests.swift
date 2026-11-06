// SPDX-License-Identifier: MPL-2.0
import XCTest
@testable import FloeMeetings

final class MeetingServiceCaptureTests: XCTestCase {
    var dbURL: URL!
    var directory: URL!

    override func tearDown() {
        if let dbURL { TestServices.cleanup(dbURL) }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testCaptureSessionLifecyclePersists() async throws {
        let (service, url) = try TestServices.makeService()
        dbURL = url
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("capture-\(UUID().uuidString)")
        let meeting = try await service.createMeeting(title: "Standup")

        let backend = FakeCaptureBackend()
        let session = try await service.startCapture(
            meeting: meeting,
            backend: backend,
            configuration: CaptureConfiguration(kind: .liveRecording, directory: directory)
        )
        var snapshot = try await service.meeting(meeting)
        XCTAssertEqual(snapshot.status, .capturing)

        let outcome = try await service.stopCapture()
        XCTAssertEqual(outcome.session, session)
        XCTAssertEqual(outcome.state, .stopped)
        XCTAssertEqual(outcome.stopReason, .userStopped)

        snapshot = try await service.meeting(meeting)
        XCTAssertEqual(snapshot.status, .finished)

        let database = try MeetingDatabase(path: url.path)
        let reopened = MeetingService(database: database)
        let sessions = try await reopened.sessions(meeting: meeting)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.state, .stopped)
        XCTAssertEqual(sessions.first?.kind, .liveRecording)
    }

    func testCancelCaptureMarksSessionCancelledAndDropsPartials() async throws {
        let (service, url) = try TestServices.makeService()
        dbURL = url
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("capture-\(UUID().uuidString)")
        let meeting = try await service.createMeeting(title: "Cancel")
        let backend = FakeCaptureBackend()
        let session = try await service.startCapture(
            meeting: meeting,
            backend: backend,
            configuration: CaptureConfiguration(directory: directory)
        )
        let partial = try await service.beginPartial(meeting: meeting, session: session, text: "draft")
        _ = partial

        let cancelled = try await service.cancelCapture()
        XCTAssertEqual(cancelled, session)
        // Idempotent second cancel.
        let secondCancel = try await service.cancelCapture()
        XCTAssertNil(secondCancel)
        // Partials are fenced away without being persisted.
        let remainingPartials = await service.currentPartials(meeting: meeting)
        XCTAssertEqual(remainingPartials, [])

        let sessions = try await service.sessions(meeting: meeting)
        XCTAssertEqual(sessions.first?.state, .cancelled)
        let transcript = try await service.transcript(meeting: meeting)
        XCTAssertEqual(transcript, [])
    }

    func testImportFileRegistersFinishedSession() async throws {
        let (service, url) = try TestServices.makeService()
        dbURL = url
        let meeting = try await service.createMeeting(title: "Import")
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("import-\(UUID().uuidString).m4a")
        try Data([0, 1, 2, 3]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let session = try await service.importFile(meeting: meeting, file: file, kind: .importedAudio) { _ in
            MediaTimeRange(uncheckedStart: 0, end: 90)
        }
        let sessions = try await service.sessions(meeting: meeting)
        XCTAssertEqual(sessions.first?.id, session)
        XCTAssertEqual(sessions.first?.state, .stopped)
        XCTAssertEqual(sessions.first?.sourceFile, file.path)

        do {
            _ = try await service.importFile(meeting: meeting, file: URL(fileURLWithPath: "/no/such/file.m4a"), kind: .importedAudio) { _ in
                MediaTimeRange(uncheckedStart: 0, end: 1)
            }
            XCTFail("expected importedFileUnavailable")
        } catch MeetingError.importedFileUnavailable {
            // expected
        }
    }
}
