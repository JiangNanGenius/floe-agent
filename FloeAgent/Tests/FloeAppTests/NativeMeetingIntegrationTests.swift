// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import AVFoundation
import FloeMeetings
import FloeMeetingsAV
@testable import FloeApp

@Suite("Personal meeting storage")
struct NativeMeetingIntegrationTests {
    @Test func createdMeetingSurvivesTheStagingMoveAndReopensInTheNativeService() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-library-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let content = PersonalContentService(root: root)
        let record = try await content.create(kind: .meeting, title: "Meeting original")
        let library = try await content.library()
        let location = try await library.resolve(record.id)
        let database = try MeetingDatabase(path: location.url.appendingPathComponent("Meeting/meeting.sqlite").path)
        let service = MeetingService(database: database)
        let meeting = try await service.meeting(MeetingID(record.id))
        #expect(meeting.title == record.title)
        _ = try await service.addNote(meeting: meeting.id, body: "Original manual note")
        let todo = try await service.addTodo(meeting: meeting.id, text: "Review source", origin: .user)
        _ = try await service.updateTodo(todo.id, meeting: meeting.id, status: .done)
        let another = MeetingService(database: try MeetingDatabase(path: location.url.appendingPathComponent("Meeting/meeting.sqlite").path))
        #expect(try await another.notes(meeting: meeting.id).map(\.body) == ["Original manual note"])
        #expect(try await another.todos(meeting: meeting.id).first?.status == .done)
        #expect(try await another.meeting(meeting.id).id.rawValue == record.id)
    }
}

@Suite("Meeting live transcription recovery")
@MainActor
struct MeetingLiveTranscriptionRecoveryTests {
    private struct Fixture {
        let root: URL
        let service: MeetingService
        let meetingID: MeetingID
        let original: CaptureSessionID
        let chunks: [MeetingPCMChunk]
    }

    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-live-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let service = MeetingService(database: try MeetingDatabase(path: root.appendingPathComponent("meeting.sqlite").path))
        let meetingID = try await service.createMeeting(title: "Live recovery")
        let writer = try MeetingPCMChunkRecorder(configuration: .init(directory: root.appendingPathComponent("Recordings")),
            session: CaptureSessionID(), chunkSeconds: 3)
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<16_000 { samples[index] = Float(sin(Double(index) * .pi * 440 / 8_000)) * 0.05 }
        let frame = try MeetingPCMFrame(copying: buffer)
        var chunks: [MeetingPCMChunk] = []
        for _ in 0..<4 {
            if let chunk = try await writer.append(frame) { chunks.append(chunk) }
        }
        if let tail = try await writer.finish() { chunks.append(tail) }
        let originalURL = await writer.originalURL
        let original = try await service.importFile(meeting: meetingID, file: originalURL,
            kind: .importedAudio, duration: AudioFileProbe.durationRange)
        return Fixture(root: root, service: service, meetingID: meetingID, original: original, chunks: chunks)
    }

    @Test func busyDecoderWaitsThenCommitsTheActualOffsetAndDoesNotReplayAfterReopen() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var calls = 0
        let queue = try MeetingLiveTranscription(meetingID: fixture.meetingID, root: fixture.root, service: fixture.service,
            transcribeChunk: { _, _ in
                calls += 1
                if calls == 1 { throw AssistantAudioError.transcriptionBusy }
                return .init(segments: [.init(start: 0, end: 0.5, text: "Actual source", words: [])], language: "en")
            }, retryDelay: { _ in }, onChange: {})
        let tail = try #require(fixture.chunks.last)
        #expect(tail.range.start == 3)
        queue.enqueue(session: fixture.original, file: tail.file, range: tail.range)
        await queue.waitUntilIdle()
        #expect(calls == 2 && !queue.requiresRetry && !queue.isWorking)
        #expect(queue.chunks.first?.state == .complete)
        let saved = try await fixture.service.transcript(meeting: fixture.meetingID)
        #expect(saved.count == 1 && saved.first?.range.start == 3 && saved.first?.range.end == 3.5)
        let segment = try #require(saved.first)
        _ = try await fixture.service.correctSegment(segment.id, meeting: fixture.meetingID, newText: "User correction")
        let reopenedService = MeetingService(database: try MeetingDatabase(path: fixture.root.appendingPathComponent("meeting.sqlite").path))
        let reopened = try MeetingLiveTranscription(meetingID: fixture.meetingID, root: fixture.root, service: reopenedService,
            transcribeChunk: { _, _ in
                Issue.record("A completed chunk must not run again")
                return .init(segments: [], language: nil)
            }, onChange: {})
        reopened.retryUnfinished()
        await reopened.waitUntilIdle()
        let reread = try await reopenedService.transcript(meeting: fixture.meetingID)
        #expect(reread.count == 1 && reread.first?.text == "User correction")
    }

    @Test func unavailableServiceRetainsTheRemainingQueueUntilAnExplicitConfigurationChange() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var ready = false
        var calls = 0
        let queue = try MeetingLiveTranscription(meetingID: fixture.meetingID, root: fixture.root, service: fixture.service,
            transcribeChunk: { _, _ in
                calls += 1
                guard ready else { throw AssistantAudioError.serviceUnavailable("fixture") }
                return .init(segments: [.init(start: 0, end: 0.5, text: "Recovered", words: [])], language: "en")
            }, onChange: {})
        for chunk in fixture.chunks { queue.enqueue(session: fixture.original, file: chunk.file, range: chunk.range) }
        await queue.waitUntilIdle()
        #expect(calls == 1 && queue.requiresRetry && queue.failedCount == 1 && queue.pendingCount == 1)
        #expect(try await fixture.service.transcript(meeting: fixture.meetingID).isEmpty)
        ready = true
        queue.configure(enabled: true, serviceID: "new-service", resumeUnfinished: true)
        await queue.waitUntilIdle()
        #expect(calls == 3 && queue.unfinishedCount == 0 && !queue.requiresRetry)
        #expect(try await fixture.service.transcript(meeting: fixture.meetingID).count == 2)
    }

    @Test func cancellationJoinsTheBusyWaitAndPreservesLaterAudioWithoutDecodingIt() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (waiting, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        var calls = 0
        let queue = try MeetingLiveTranscription(meetingID: fixture.meetingID, root: fixture.root, service: fixture.service,
            transcribeChunk: { _, _ in calls += 1; throw AssistantAudioError.transcriptionBusy },
            retryDelay: { _ in
                continuation.yield(())
                try await Task.sleep(for: .seconds(60))
            }, onChange: {})
        let first = try #require(fixture.chunks.first)
        queue.enqueue(session: fixture.original, file: first.file, range: first.range)
        var iterator = waiting.makeAsyncIterator()
        _ = await iterator.next()
        await queue.cancelAndWait()
        let tail = try #require(fixture.chunks.last)
        queue.enqueue(session: fixture.original, file: tail.file, range: tail.range)
        await queue.waitUntilIdle()
        #expect(calls == 1 && !queue.enabled && !queue.isWorking && queue.chunks.count == 2)
        #expect(try await fixture.service.transcript(meeting: fixture.meetingID).isEmpty)
        #expect(fixture.chunks.allSatisfy { FileManager.default.fileExists(atPath: $0.file.path) })
        continuation.finish()
    }

    @Test func silentChunkCompletesWithoutCreatingTranscriptText() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let queue = try MeetingLiveTranscription(meetingID: fixture.meetingID, root: fixture.root, service: fixture.service,
            transcribeChunk: { _, _ in .init(segments: [], language: nil) }, onChange: {})
        let chunk = try #require(fixture.chunks.first)
        queue.enqueue(session: fixture.original, file: chunk.file, range: chunk.range)
        await queue.waitUntilIdle()
        #expect(queue.chunks.first?.state == .complete && queue.diagnostic == nil && !queue.requiresRetry)
        #expect(try await fixture.service.transcript(meeting: fixture.meetingID).isEmpty)
    }
}
#endif
