// SPDX-License-Identifier: MPL-2.0
import XCTest
import GRDB
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

// Directed recording identity/migration contracts; no microphone or provider.
extension MeetingServiceCaptureTests {
    func testPausedRecordingContinuationAndExplicitStopUseAtomicTakeIdentity() async throws {
        let (service, file) = try TestServices.makeService(); dbURL = file
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("take-" + UUID().uuidString)
        let meeting = try await service.createMeeting(title: "One recording")
        let first = try await service.startCapture(meeting: meeting, backend: FakeCaptureBackend(), configuration: .init(directory: directory))
        _ = try await service.pauseCapture()
        let paused = try await service.recordingTakes(meeting: meeting)
        XCTAssertEqual(paused.count, 1); XCTAssertEqual(paused[0].state, .paused)
        let second = try await service.startCapture(meeting: meeting, backend: FakeCaptureBackend(), configuration: .init(directory: directory),
                                                    continuingRecording: paused[0].id)
        _ = try await service.stopCapture()
        let finished = try await service.recordingTakes(meeting: meeting)
        XCTAssertEqual(finished[0].id, first.rawValue)
        XCTAssertEqual(finished[0].parts.map(\.id), [first, second])
        XCTAssertEqual(finished[0].parts.map(\.partOrdinal), [0, 1])
        XCTAssertEqual(finished[0].state, .finished)
        _ = try await service.startCapture(meeting: meeting, backend: FakeCaptureBackend(), configuration: .init(directory: directory))
        _ = try await service.stopCapture()
        let next = try await service.recordingTakes(meeting: meeting)
        XCTAssertEqual(next.count, 2); XCTAssertNotEqual(next[0].id, next[1].id)
    }

    func testPausedTakeReopensWithoutWriterAndRejectsForeignOrFinishedContinuation() async throws {
        let (service, file) = try TestServices.makeService(); dbURL = file
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("take-reopen-" + UUID().uuidString)
        let meeting = try await service.createMeeting(title: "Owner")
        let first = try await service.startCapture(meeting: meeting, backend: FakeCaptureBackend(), configuration: .init(directory: directory))
        _ = try await service.pauseCapture()
        let reopened = MeetingService(database: try MeetingDatabase(path: file.path))
        let active = await reopened.activeCaptureSession; XCTAssertNil(active)
        let takes = try await reopened.recordingTakes(meeting: meeting)
        XCTAssertEqual(takes[0].state, .paused)
        let foreign = try await reopened.createMeeting(title: "Other meeting")
        do {
            _ = try await reopened.startCapture(meeting: foreign, backend: FakeCaptureBackend(), configuration: .init(directory: directory), continuingRecording: first.rawValue)
            XCTFail("Cross-meeting continuation must fail before inserting a capture")
        } catch { }
        let foreignRows = try await reopened.sessions(meeting: foreign); XCTAssertTrue(foreignRows.isEmpty)
        try await reopened.finishPausedRecording(first.rawValue, meeting: meeting)
        do {
            _ = try await reopened.startCapture(meeting: meeting, backend: FakeCaptureBackend(), configuration: .init(directory: directory), continuingRecording: first.rawValue)
            XCTFail("Explicitly finished recording must not be reopened as a continuation")
        } catch { }
        let originals = try await reopened.sessions(meeting: meeting); XCTAssertEqual(originals.map(\.id), [first])
    }

    func testInterruptedOriginalRecoversAsPausedSameTakeAndCanContinue() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("take-interrupt-" + UUID().uuidString + ".sqlite")
        dbURL = file
        let database = try MeetingDatabase(path: file.path)
        let service = MeetingService(database: database)
        let meeting = try await service.createMeeting(title: "Interrupted")
        let original = CaptureSessionSnapshot(meetingID: meeting, kind: .liveRecording, state: .capturing, startedAt: Date())
        try await database.insertLiveSession(original, continuing: nil)
        let recovered = try await service.recoverInterruptedLiveCapture(original.id, meeting: meeting, originalAvailable: true)
        XCTAssertTrue(recovered)
        let takes = try await service.recordingTakes(meeting: meeting)
        XCTAssertEqual(takes[0].id, original.id.rawValue); XCTAssertEqual(takes[0].state, .paused)
        XCTAssertEqual(takes[0].parts[0].stopReason, .recovered)
        let active = await service.activeCaptureSession; XCTAssertNil(active)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("take-recovered-" + UUID().uuidString)
        let resumed = try await service.startCapture(meeting: meeting, backend: FakeCaptureBackend(), configuration: .init(directory: directory), continuingRecording: takes[0].id)
        _ = try await service.stopCapture()
        let result = try await service.recordingTakes(meeting: meeting)
        XCTAssertEqual(result[0].parts.map(\.id), [original.id, resumed])
    }

    func testTimeoutNeverPersistsPausedTakeOrClaimsACompleteStop() async throws {
        let (service, file) = try TestServices.makeService(); dbURL = file
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("take-timeout-" + UUID().uuidString)
        let meeting = try await service.createMeeting(title: "Timeout")
        let backend = FakeCaptureBackend(); backend.flushOnRequestStop = false
        _ = try await service.startCapture(meeting: meeting, backend: backend, configuration: .init(directory: directory, stopTimeout: 0.01))
        let result = try await service.pauseCapture()
        XCTAssertEqual(result.stopReason, .timeout)
        let takes = try await service.recordingTakes(meeting: meeting)
        XCTAssertEqual(takes[0].state, .finished)
        XCTAssertEqual(takes[0].parts[0].stopReason, .timeout)
    }

    func testAnalysisOriginAndUserImportNamePersistWithoutPromotingAnalysis() async throws {
        let (service, file) = try TestServices.makeService(); dbURL = file
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("take-origin-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audio = directory.appendingPathComponent("source.wav"); try Data([1, 2, 3, 4]).write(to: audio)
        let meeting = try await service.createMeeting(title: "Origin")
        let original = try await service.importFile(meeting: meeting, file: audio, kind: .importedAudio, displayName: "采访原音.wav") { _ in
            MediaTimeRange(uncheckedStart: 0, end: 12)
        }
        let analysis = try await service.importFile(meeting: meeting, file: audio, kind: .importedAudio, origin: original) { _ in
            MediaTimeRange(uncheckedStart: 0, end: 3)
        }
        let foreign = try await service.createMeeting(title: "Foreign")
        do {
            _ = try await service.importFile(meeting: foreign, file: audio, kind: .importedAudio, origin: original) { _ in
                MediaTimeRange(uncheckedStart: 0, end: 1)
            }
            XCTFail("Foreign analysis must not acquire an origin")
        } catch { }
        let reopened = MeetingService(database: try MeetingDatabase(path: file.path))
        let rows = try await reopened.sessions(meeting: meeting)
        XCTAssertEqual(rows.first(where: { $0.id == analysis })?.originSessionID, original)
        XCTAssertEqual(rows.first(where: { $0.id == original })?.displayName, "采访原音.wav")
        let takes = try await reopened.recordingTakes(meeting: meeting); XCTAssertTrue(takes.isEmpty)
        let foreignRows = try await reopened.sessions(meeting: foreign); XCTAssertTrue(foreignRows.isEmpty)
    }

    func testV6ProjectMigrationKeepsEachOriginalSeparateAndPreservesAnalysisOrigin() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("take-v6-" + UUID().uuidString + ".sqlite")
        dbURL = file
        let meeting = MeetingID(), first = CaptureSessionID(), second = CaptureSessionID(), analysis = CaptureSessionID()
        let old = try DatabaseQueue(path: file.path)
        try await old.write { db in
            // Exact legacy columns used by v7; migration markers ensure the
            // actual production migrator runs v7 against existing v6 rows.
            try db.execute(sql: """
                CREATE TABLE grdb_migrations(identifier TEXT NOT NULL PRIMARY KEY);
                INSERT INTO grdb_migrations VALUES ('v1'), ('v2-import-duration'), ('v3-speaker-bindings'),
                    ('v4-segment-speaker-correction'), ('v5-canonical-transcript-history'), ('v6-continuous-live-lineage');
                CREATE TABLE meetings(id TEXT PRIMARY KEY, title TEXT NOT NULL, status TEXT NOT NULL,
                    capabilitiesJSON TEXT NOT NULL, createdAt DATETIME NOT NULL, updatedAt DATETIME NOT NULL);
                CREATE TABLE capture_sessions(id TEXT PRIMARY KEY, meetingID TEXT NOT NULL, kind TEXT NOT NULL,
                    state TEXT NOT NULL, directory TEXT, sourceFile TEXT, startedAt DATETIME, endedAt DATETIME,
                    stopReason TEXT, durationSeconds DOUBLE, originSessionID TEXT);
                """)
            let caps = try MeetingRecordCodec.json(MeetingProcessingCapabilities.unavailable)
            try db.execute(sql: "INSERT INTO meetings VALUES (?, 'Legacy', 'finished', ?, ?, ?)", arguments: [meeting.description, caps, Date(), Date()])
            for id in [first, second] {
                try db.execute(sql: "INSERT INTO capture_sessions(id,meetingID,kind,state,startedAt) VALUES (?,?,'liveRecording','stopped',?)",
                               arguments: [id.description, meeting.description, Date(timeIntervalSince1970: 100)])
            }
            try db.execute(sql: "INSERT INTO capture_sessions(id,meetingID,kind,state,sourceFile,originSessionID) VALUES (?,?,'importedAudio','stopped','/legacy/chunk.m4a',?)",
                           arguments: [analysis.description, meeting.description, first.description])
        }
        let service = MeetingService(database: try MeetingDatabase(path: file.path))
        let takes = try await service.recordingTakes(meeting: meeting)
        XCTAssertEqual(Set(takes.map(\.id)), Set([first.rawValue, second.rawValue]))
        XCTAssertTrue(takes.allSatisfy { $0.parts.count == 1 && $0.state == .finished })
        let rows = try await service.sessions(meeting: meeting)
        XCTAssertEqual(rows.first(where: { $0.id == analysis })?.originSessionID, first)
        XCTAssertNil(rows.first(where: { $0.id == analysis })?.recordingID)
        XCTAssertTrue(rows.allSatisfy { $0.state == .stopped })
    }
}
