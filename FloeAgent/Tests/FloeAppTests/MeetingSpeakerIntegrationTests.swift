// SPDX-License-Identifier: MPL-2.0
// W7 speaker attribution — real producer → two-level adapter → meeting
// passthrough at the App live-queue seam.
//
// Verification status: this file is part of the W7 predevelopment scope but
// is NOT yet wired into the FloeAppTests target (project.yml lists every
// test file explicitly and this lane may not edit project.yml). Add
//   - path: Tests/FloeAppTests/MeetingSpeakerIntegrationTests.swift
// under the FloeAppTests sources (next to NativeMeetingIntegrationTests.swift)
// and regenerate the project to enable it. Until then it compiles out on
// macOS (UIKit gate) and is validated by review plus the FloeMeetings module
// tests in SpeakerAttributionTests.swift.
#if canImport(UIKit)
import Foundation
import Testing
import AVFoundation
import FloeCore
import FloeMeetings
import FloeMeetingsAV
@testable import FloeApp

@Suite("Meeting speaker attribution pipeline")
@MainActor
struct MeetingSpeakerIntegrationTests {
    private struct Fixture {
        let root: URL
        let service: MeetingService
        let meetingID: MeetingID
        let original: CaptureSessionID
        let chunks: [MeetingPCMChunk]
    }

    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-speakers-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let service = MeetingService(database: try MeetingDatabase(path: root.appendingPathComponent("meeting.sqlite").path))
        let meetingID = try await service.createMeeting(title: "Speaker pipeline")
        let writer = try MeetingPCMChunkRecorder(
            configuration: .init(directory: root.appendingPathComponent("Recordings")),
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

    @Test func assembledFileKeepsIndependentRequestDomains() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sources = try await fixture.service.sessions(meeting: fixture.meetingID)
        let original = try #require(sources.first { $0.id == fixture.original })
        let path = try #require(original.sourceFile)
        let result = try await CloudASRFilePipeline.transcribe(
            fileURL: URL(fileURLWithPath: path), profile: .openAICompatible(),
            adapter: MeetingNumberedASRAdapter(), credential: "synthetic-test-value",
            language: .automatic, requiresTiming: true, maximumChunkSeconds: 2,
            enableSpeakerAttribution: true)
        #expect(result.segments.count == 4)
        #expect(result.segments.allSatisfy { $0.speaker == "1" })
        let scopes = result.segments.compactMap(\.recognitionRequestID)
        try #require(scopes.count == 4)
        #expect(Set(scopes).count == 2,
                "each actual chunk request owns a different speaker domain")
        #expect(scopes[0] == scopes[1] && scopes[2] == scopes[3])
        let decoded = try JSONDecoder().decode([ASRTranscriptionSegment].self,
            from: JSONEncoder().encode(result.segments))
        #expect(decoded == result.segments)
    }

    /// Root's W7 boundary: two INDEPENDENT chunk requests of the same
    /// original recording both returning the numeric label "1" must NOT be
    /// merged into one speaker. Identity may only be established per real
    /// recognition request; the user merges afterwards if they wish.
    @Test func independentChunkRequestsWithTheSameNumericLabelDoNotMerge() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var calls = 0
        let queue = try MeetingLiveTranscription(meetingID: fixture.meetingID, root: fixture.root, service: fixture.service,
            transcribeChunk: { _, _ in
                calls += 1
                // Every provider request restarts its numbering at "1" — the
                // honest two-speaker meeting where each chunk observed one
                // voice still arrives as label "1" per request.
                return .init(segments: [.init(start: 0, end: 0.5, text: "words \(calls)", words: [], speaker: "1")], language: "en")
            }, onChange: {})
        let first = try #require(fixture.chunks.first)
        let last = try #require(fixture.chunks.last)
        queue.enqueue(session: fixture.original, file: first.file, range: first.range)
        queue.enqueue(session: fixture.original, file: last.file, range: last.range)
        await queue.waitUntilIdle()
        #expect(calls == 2 && queue.unfinishedCount == 0)

        let segments = try await fixture.service.transcript(meeting: fixture.meetingID)
        #expect(segments.count == 2)
        let speakers = try await fixture.service.speakers(meeting: fixture.meetingID)
        #expect(speakers.count == 2,
                "the same number from two independent requests is two people until the user merges")
        #expect(Set(segments.compactMap(\.speakerID)).count == 2)
        #expect(speakers.allSatisfy { !$0.userNamed })
    }

    /// A retry is a NEW provider request: the retried attempt's labels bind
    /// in their own domain, never to the failed attempt's mapping.
    @Test func retriedChunkIsANewRequestWithItsOwnSpeakerDomain() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var attempt = 0
        let queue = try MeetingLiveTranscription(meetingID: fixture.meetingID, root: fixture.root, service: fixture.service,
            transcribeChunk: { _, _ in
                attempt += 1
                if attempt == 1 { throw AssistantAudioError.transcriptionBusy }
                // Retry produces slightly different timing and the same
                // numeric label "1" — an independent observation.
                return .init(segments: [.init(start: 0.1, end: 0.6, text: "retried words", words: [], speaker: "1")], language: "en")
            }, retryDelay: { _ in }, onChange: {})
        let chunk = try #require(fixture.chunks.first)
        queue.enqueue(session: fixture.original, file: chunk.file, range: chunk.range)
        await queue.waitUntilIdle()
        #expect(attempt == 2 && queue.unfinishedCount == 0)
        let segments = try await fixture.service.transcript(meeting: fixture.meetingID)
        // Only the retry's segment commits (the busy attempt produced none).
        #expect(segments.count == 1)
        #expect(segments.first?.speakerID != nil)
        #expect(try await fixture.service.speakers(meeting: fixture.meetingID).count == 1)
    }

    /// Rename and merge persist through queue + service reopen, and a
    /// completed chunk never re-commits (no duplicate text, no resurrected
    /// engine attribution over the user's merge).
    @Test func renameAndMergeSurviveReopenAndNeverResurrect() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = try #require(fixture.chunks.first)
        let last = try #require(fixture.chunks.last)
        let queue = try MeetingLiveTranscription(meetingID: fixture.meetingID, root: fixture.root, service: fixture.service,
            transcribeChunk: { _, _ in
                .init(segments: [.init(start: 0, end: 0.5, text: "voice", words: [], speaker: "1")], language: "en")
            }, onChange: {})
        queue.enqueue(session: fixture.original, file: first.file, range: first.range)
        queue.enqueue(session: fixture.original, file: last.file, range: last.range)
        await queue.waitUntilIdle()
        var speakers = try await fixture.service.speakers(meeting: fixture.meetingID)
        #expect(speakers.count == 2)
        let keep = try #require(speakers.first)
        let fold = try #require(speakers.last)
        try await fixture.service.renameSpeaker(keep.id, meeting: fixture.meetingID, to: "Alice", byUser: true)
        try await fixture.service.mergeSpeaker(fold.id, into: keep.id, meeting: fixture.meetingID)

        let reopenedService = MeetingService(database: try MeetingDatabase(path: fixture.root.appendingPathComponent("meeting.sqlite").path))
        let reopenedQueue = try MeetingLiveTranscription(meetingID: fixture.meetingID, root: fixture.root, service: reopenedService,
            transcribeChunk: { _, _ in
                Issue.record("A completed chunk must not run again")
                return .init(segments: [], language: nil)
            }, onChange: {})
        reopenedQueue.retryUnfinished()
        await reopenedQueue.waitUntilIdle()

        speakers = try await reopenedService.speakers(meeting: fixture.meetingID)
        let alice = try #require(speakers.first { $0.id == keep.id })
        #expect(alice.label == "Alice" && alice.userNamed)
        #expect(speakers.first { $0.id == fold.id }?.mergedInto == keep.id)
        let segments = try await reopenedService.transcript(meeting: fixture.meetingID)
        #expect(segments.count == 2)
        var resolved: [SpeakerID] = []
        for segment in segments {
            if let speaker = segment.speakerID {
                resolved.append(try await reopenedService.resolveSpeaker(speaker, meeting: fixture.meetingID))
            }
        }
        #expect(Set(resolved) == [keep.id],
                "both independent-request speakers resolve to the merged identity after the user's merge")
        #expect(try await reopenedService.resolveSpeaker(fold.id, meeting: fixture.meetingID) == keep.id)
    }
}

private struct MeetingNumberedASRAdapter: ASRTranscribing {
    func transcribe(_ request: ASRTranscriptionRequest, credential: String) async throws -> ASRTranscriptionResult {
        ASRTranscriptionResult(text: "one two", segments: [
            .init(start: 0, end: 0.5, text: "one", speaker: "1"),
            .init(start: 0.5, end: 1, text: "two", speaker: "1")], timing: .providerSegments)
    }
}
#endif
