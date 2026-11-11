// SPDX-License-Identifier: MPL-2.0
import XCTest
#if canImport(AVFoundation)
import AVFoundation
import FloeMeetingsAV
#endif
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

#if canImport(AVFoundation)
extension MeetingServiceCaptureTests {
    func testPauseBoundaryFinalizesEarlyWithoutLosingOriginalOrTail() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("pause-chunks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let writer = try MeetingPCMChunkRecorder(configuration: .init(directory: directory), session: CaptureSessionID(), chunkSeconds: 3)
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 5120))
        buffer.frameLength = 5120
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<5120 { samples[index] = 0.125 }
        let frame = try MeetingPCMFrame(copying: buffer)
        XCTAssertEqual(frame.rms, 0.125, accuracy: 0.00001)
        var chunks: [MeetingPCMChunk] = []
        for index in 0..<5 {
            if let chunk = try await writer.append(frame, endOfUtterance: index == 3) { chunks.append(chunk) }
        }
        if let tail = try await writer.finish() { chunks.append(tail) }
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].range.start, 0, accuracy: 0.0001)
        XCTAssertEqual(chunks[0].range.end, 1.28, accuracy: 0.0001)
        XCTAssertEqual(chunks[1].range.start, 1.28, accuracy: 0.0001)
        XCTAssertEqual(chunks[1].range.end, 1.6, accuracy: 0.0001)
        let originalURL = await writer.originalURL
        let original = try AVAudioFile(forReading: originalURL)
        XCTAssertEqual(original.length, 25_600, "every source sample, including the pause and stop tail, stays in the lossless original")
        XCTAssertEqual(original.processingFormat.sampleRate, 16_000)
    }
}
#endif
