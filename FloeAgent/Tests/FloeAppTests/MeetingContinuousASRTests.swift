// SPDX-License-Identifier: MPL-2.0
// W7 continuous live recognition — App-level coordinator candidate tests.
//
// Verification status: this file is part of the W7 predevelopment scope but
// is NOT yet wired into the FloeAppTests or FloePredevelopmentTests target
// (project.yml lists every test file explicitly and this lane may not edit
// project.yml). Add
//   - path: Tests/FloeAppTests/MeetingContinuousASRTests.swift
// next to MeetingSpeakerIntegrationTests.swift and regenerate the project.
// Until then it compiles out on macOS (UIKit gate) and the covered logic is
// validated by the FloeMeetings module tests
// (ContinuousLiveTranscriptionTests) plus provider tests
// (VolcengineASRTests utterance separation).
#if canImport(UIKit)
import Foundation
import Testing
import AVFoundation
import FloeCore
import FloeMeetings
import FloeMeetingsAV
@testable import FloeApp

@Suite("Meeting continuous live recognition")
@MainActor
struct MeetingContinuousASRTests {
    private struct Fixture {
        let root: URL
        let service: MeetingService
        let meetingID: MeetingID
        let captureSession: CaptureSessionID
        let adapter: MeetingFakeLiveAdapter
        let asr: MeetingContinuousASR
    }

    private func fixture(
        limitBytes: Int64 = MeetingContinuousASR.domainWireLimitBytes,
        startEngine: Bool = true
    ) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-continuous-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let service = MeetingService(database: try MeetingDatabase(path: root.appendingPathComponent("meeting.sqlite").path))
        let meetingID = try await service.createMeeting(title: "Continuous")
        let adapter = MeetingFakeLiveAdapter()
        let route = MeetingLiveTranscriptionRoute(
            profile: .volcengine(billingRoute: .agentPlan),
            credential: "synthetic-plan-key",
            adapter: adapter)
        let asr = MeetingContinuousASR(
            meetingID: meetingID, service: service, route: route,
            domainWireLimitBytes: limitBytes,
            onChange: {}, onDiagnostic: { _ in })
        let session = try await service.startCapture(meeting: meetingID, backend: MeetingFakeCaptureBackend(),
            configuration: .init(directory: root.appendingPathComponent("Recordings")))
        if startEngine { await asr.start(captureSession: session) }
        return Fixture(root: root, service: service, meetingID: meetingID,
                       captureSession: session, adapter: adapter, asr: asr)
    }

    private func sineFrame(seconds: Double, rate: Double = 16_000) throws -> MeetingPCMFrame {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * rate)))
        buffer.frameLength = AVAudioFrameCount(seconds * rate)
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<Int(seconds * rate) {
            samples[index] = Float(sin(Double(index) * .pi * 2 * 220 / rate)) * 0.2
        }
        return try MeetingPCMFrame(copying: buffer)
    }

    /// The acceptance core at the App seam: one continuous session, one
    /// request domain, utterances committed with true speakers across the
    /// storage chunk boundaries.
    @Test func continuousSessionKeepsSpeakersAcrossChunkBoundaries() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let frame = try sineFrame(seconds: 1)
        for _ in 0..<12 { fixture.asr.offer(frame) }
        let domain = try await fixture.adapter.onlyDomain()
        try await domain.deliverFinal(utterances: [
            .init(startMilliseconds: 0, endMilliseconds: 4_500, text: "first chunk words", speaker: "1"),
            .init(startMilliseconds: 5_000, endMilliseconds: 8_000, text: "second chunk words", speaker: "2"),
            .init(startMilliseconds: 8_500, endMilliseconds: 11_000, text: "back to the first voice", speaker: "1"),
        ])
        await fixture.asr.captureDidStop()
        await fixture.asr.waitUntilFinished()

        let rows = try await fixture.service.transcript(meeting: fixture.meetingID)
        #expect(rows.count == 3)
        #expect(rows.map(\.range) == [
            try MediaTimeRange(start: 0, end: 4.5),
            try MediaTimeRange(start: 5, end: 8),
            try MediaTimeRange(start: 8.5, end: 11),
        ], "multiple queued PCM batches retain their exact original timeline")
        let speakers = try await fixture.service.speakers(meeting: fixture.meetingID)
        #expect(speakers.count == 2, "two labels in ONE request domain are two people")
        let attributed = Dictionary(grouping: rows, by: { $0.speakerID })
        #expect(attributed.values.map(\.count).sorted() == [1, 2])
        #expect(fixture.adapter.openedSessionCount == 1, "one continuous request, not per-chunk requests")
    }

    /// Rotation at the wire budget mints a new request domain: media time is
    /// continuous, but the same numeric label is a new person until merged.
    @Test func rotationContinuesMediaTimeWithANewSpeakerScope() async throws {
        // 40_000 bytes ≈ 1.25 s of 16 kHz PCM16: the first second fits, the
        // second frame rotates the domain.
        let fixture = try await fixture(limitBytes: 40_000)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let frame = try sineFrame(seconds: 1)
        fixture.asr.offer(frame)
        let first = try await fixture.adapter.domain(at: 0)
        try await first.deliverFinal(utterances: [
            .init(startMilliseconds: 0, endMilliseconds: 900, text: "alpha", speaker: "1"),
        ])
        fixture.asr.offer(frame)
        let second = try await fixture.adapter.domain(at: 1)
        try await second.deliverFinal(utterances: [
            .init(startMilliseconds: 0, endMilliseconds: 900, text: "beta", speaker: "1"),
        ])
        await fixture.asr.captureDidStop()
        await fixture.asr.waitUntilFinished()

        let rows = try await fixture.service.transcript(meeting: fixture.meetingID)
        try #require(rows.count == 2)
        #expect(rows[0].range == (try MediaTimeRange(start: 0, end: 0.9)))
        #expect(rows[1].range == (try MediaTimeRange(start: 1, end: 1.9)),
                "rotation starts at the next queued batch's true original frame")
        #expect(rows[0].speakerID != rows[1].speakerID,
                "the rotated request restarts numbering; label 1 is a new person")
    }

    @Test func cancellationLeavesNoRowsAndNoLateWrites() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.asr.offer(try sineFrame(seconds: 1))
        let domain = try await fixture.adapter.onlyDomain()
        await fixture.asr.cancelAndWait()
        try await domain.deliverFinal(utterances: [
            .init(startMilliseconds: 0, endMilliseconds: 900, text: "too late", speaker: "1"),
        ])
        let rows = try await fixture.service.transcript(meeting: fixture.meetingID)
        #expect(rows.isEmpty, "a cancelled session accepts no late live finals")
    }

    @Test func overflowKeepsTheOriginalTimeGapForFallback() async throws {
        let fixture = try await fixture(startEngine: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let frame = try sineFrame(seconds: 0.01)
        let batches = MeetingContinuousASR.frameBufferCapacity + 2
        for _ in 0..<batches { fixture.asr.offer(frame) }
        #expect(fixture.asr.metricsSnapshot.droppedFrames == 2)
        await fixture.asr.start(captureSession: fixture.captureSession)
        // The overflowing buffered domain is sealed/discarded before any
        // feed. Wait for that deterministic rotation, then offer real audio.
        let afterOverflow = try await fixture.adapter.domain(at: 1)
        fixture.asr.offer(frame)
        try await afterOverflow.deliverFinal(utterances: [
            .init(startMilliseconds: 0, endMilliseconds: 10,
                  text: "after the real gap", speaker: "1"),
        ])
        await fixture.asr.captureDidStop()
        await fixture.asr.waitUntilFinished()
        let rows = try await fixture.service.transcript(meeting: fixture.meetingID)
        let row = try #require(rows.first)
        #expect(rows.count == 1)
        let expectedStart = Double(batches) * 0.01
        #expect(abs(row.range.start - expectedStart) < 0.0001,
                "discarded and refused batches remain a real gap in the original timeline")
        #expect(abs(row.range.end - (expectedStart + 0.01)) < 0.0001)
        var coverage = MeetingCoverageMap()
        for span in fixture.asr.coveredSnapshot() { try coverage.commit(span) }
        #expect(coverage.uncoveredSubranges(of: try MediaTimeRange(start: 0, end: row.range.end))
                == [try MediaTimeRange(start: 0, end: expectedStart)])
    }

    /// A rejected 0–5 live utterance only overlaps the durable 0–1 row.
    /// Its 1–5 remainder must remain uncovered and use the actual WAV
    /// subrange fallback, with the returned sentence kept whole.
    @Test func rejectedLiveOverlapLeavesRealAudioGapForFallback() async throws {
        try await assertRejectedLiveOverlapKeepsRealAudioGap(chunkStart: 0)
    }

    @Test func rejectedLiveOverlapInLaterChunkUsesLocalExtractionAndGlobalAdoption() async throws {
        try await assertRejectedLiveOverlapKeepsRealAudioGap(chunkStart: 10)
    }

    private func assertRejectedLiveOverlapKeepsRealAudioGap(chunkStart: Double) async throws {
        let fixture = try await fixture(startEngine: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let chunkRange = try MediaTimeRange(start: chunkStart, end: chunkStart + 5)
        let gapRange = try MediaTimeRange(start: chunkStart + 1, end: chunkStart + 5)
        let lease = try await fixture.service.beginLiveTranscription(
            meeting: fixture.meetingID, session: fixture.captureSession)
        _ = try await fixture.service.commitLiveFinal(lease, text: "already saved",
            range: MediaTimeRange(start: chunkStart, end: chunkStart + 1), utteranceKey: "existing|0|1000")
        var domain = MeetingLiveASRDomain(
            sourceSampleRate: 16_000, startFrame: Int64(chunkStart * 16_000), wireLimitBytes: 1_000_000)
        domain.account(frameCount: 80_000, wireBytes: 160_000)
        let event = ASRLiveEvent.final(turnID: domain.scope, itemID: nil,
            transcript: "blocked live sentence", utterances: [
                .init(startMilliseconds: 0, endMilliseconds: 5_000,
                      text: "blocked live sentence", speaker: nil),
            ], sequence: 1)
        await fixture.asr.commitFinal(event, domain: domain, lease: lease)
        #expect(fixture.asr.coveredSnapshot().isEmpty,
                "a nil insert must never mark the requested 0–5 span durable")
        let beforeRows = try await fixture.service.committedSegments(
            meeting: fixture.meetingID, original: fixture.captureSession)
        var reserved = MeetingCoverageMap()
        for row in beforeRows { try reserved.commit(row.range) }
        let gaps = reserved.uncoveredSubranges(of: chunkRange)
        #expect(gaps == [gapRange])

        let writer = try MeetingPCMChunkRecorder(
            configuration: .init(directory: fixture.root.appendingPathComponent("Recordings")),
            session: fixture.captureSession, chunkSeconds: 10)
        let frame = try sineFrame(seconds: 1)
        for _ in 0..<5 { _ = try await writer.append(frame) }
        let finished = try await writer.finish()
        let chunk = try #require(finished)
        var calls = 0
        let queue = try MeetingLiveTranscription(
            meetingID: fixture.meetingID, root: fixture.root, service: fixture.service,
            transcribeChunk: { file, _ in
                calls += 1
                #expect(file.pathExtension == "wav")
                #expect(file.path.contains(".live-subranges/"))
                let audio = try await AudioFileProbe.durationRange(file)
                #expect(abs(audio.duration - 4) < 0.02,
                        "the provider receives the actual uncovered 1–5 seconds")
                return .init(segments: [.init(start: 0, end: 4,
                    text: "the complete fallback sentence", words: [], speaker: nil)], language: "en")
            }, onChange: {})
        queue.liveGate = { (active: false, coverage: fixture.asr.coveredSnapshot()) }
        queue.enqueue(session: fixture.captureSession, file: chunk.file, range: chunkRange)
        await queue.waitUntilIdle()
        #expect(calls == 1 && queue.unfinishedCount == 0)
        let rows = try await fixture.service.transcript(meeting: fixture.meetingID)
        let recovered = try #require(rows.first { $0.text == "the complete fallback sentence" })
        #expect(rows.count == 2)
        #expect(recovered.range == gapRange,
                "file-local audio extraction must retain the original media coordinate on adoption")
        await fixture.service.endLiveTranscription(lease)
        _ = try await fixture.service.cancelCapture()
    }

    @Test func partialGapExtractionFailureRetainsUnfinishedWorkForRetry() async throws {
        let fixture = try await fixture(startEngine: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let lease = try await fixture.service.beginLiveTranscription(
            meeting: fixture.meetingID, session: fixture.captureSession)
        _ = try await fixture.service.commitLiveFinal(lease, text: "already saved",
            range: MediaTimeRange(start: 0, end: 1), utteranceKey: "existing|0|1000")
        let damaged = fixture.root.appendingPathComponent("damaged-chunk.m4a")
        try Data([0]).write(to: damaged)
        var calls = 0
        let queue = try MeetingLiveTranscription(
            meetingID: fixture.meetingID, root: fixture.root, service: fixture.service,
            transcribeChunk: { file, _ in
                calls += 1
                let audio = try await AudioFileProbe.durationRange(file)
                #expect(abs(audio.duration - 4) < 0.02)
                return .init(segments: [.init(start: 0, end: 4,
                    text: "recovered on retry", words: [], speaker: nil)], language: "en")
            }, onChange: {})
        queue.enqueue(session: fixture.captureSession, file: damaged,
                      range: try MediaTimeRange(start: 0, end: 5))
        await queue.waitUntilIdle()
        #expect(calls == 0)
        #expect(queue.unfinishedCount == 1 && queue.failedCount == 1 && queue.requiresRetry,
                "failed extraction retains the gap instead of completing an empty request plan")
        let beforeRetry = try await fixture.service.transcript(meeting: fixture.meetingID)
        #expect(beforeRetry.count == 1)

        // Restore real audio at the retained queue path, then use the normal
        // retry action. The original row still reserves exactly 0–1 seconds.
        let writer = try MeetingPCMChunkRecorder(
            configuration: .init(directory: fixture.root.appendingPathComponent("Recordings")),
            session: fixture.captureSession, chunkSeconds: 10)
        let frame = try sineFrame(seconds: 1)
        for _ in 0..<5 { _ = try await writer.append(frame) }
        let finished = try await writer.finish()
        let repaired = try #require(finished)
        try FileManager.default.removeItem(at: damaged)
        try FileManager.default.copyItem(at: repaired.file, to: damaged)
        queue.retryUnfinished()
        await queue.waitUntilIdle()
        #expect(calls == 1 && queue.unfinishedCount == 0 && queue.failedCount == 0 && !queue.requiresRetry)
        let rows = try await fixture.service.transcript(meeting: fixture.meetingID)
        let recoveredRange = try MediaTimeRange(start: 1, end: 5)
        #expect(rows.count == 2)
        #expect(rows.contains { $0.text == "recovered on retry"
            && $0.range == recoveredRange })
        await fixture.service.endLiveTranscription(lease)
        _ = try await fixture.service.cancelCapture()
    }
}

private actor MeetingFakeCaptureBackend: MeetingCaptureBackend {
    func begin(session: CaptureSessionID, configuration: CaptureConfiguration,
               sink: @escaping @Sendable (CaptureEvent) -> Void) async throws {
        sink(.started(session: session))
    }
    func requestStop() async {
        // The real backend finishes its pump before emitting stopped; the
        // coordinator test drives captureDidStop explicitly.
    }
    func cancel() async {}
}

/// Scripted live adapter: `endUtterance()` answers with the domain's scripted
/// final, exactly like the real SAUC endpoint answers the documented final
/// packet after is_last.
private final class MeetingFakeLiveAdapter: ASRLiveTranscribing, @unchecked Sendable {
    final class ScriptedDomain {
        let request: ASRLiveSessionRequest
        let box = MeetingFakeEventBox()
        init(request: ASRLiveSessionRequest) { self.request = request }
    }
    final class MeetingFakeEventBox: @unchecked Sendable {
        let lock = NSLock()
        var pendingFinal: ASRLiveEvent?
    }
    final class MeetingFakeSession: ASRLiveSession, @unchecked Sendable {
        nonisolated let turnID: UUID
        nonisolated let events: ASRBoundedEventStream<ASRLiveEvent>
        private let domain: ScriptedDomain
        private var fed = 0
        init(domain: ScriptedDomain) {
            self.domain = domain
            self.turnID = domain.request.turnID
            self.events = ASRBoundedEventStream(capacity: 64)
        }
        func feed(_ audio: Data) async throws { fed += audio.count }
        func endUtterance() async throws {
            guard fed > 0 else { throw ASRTranscriptionError.emptyResult }
            let pending = domain.box.lock.withLock { domain.box.pendingFinal }
            // Match the real adapter: enqueue the lossless final BEFORE
            // closing the stream. A fire-and-forget send can arrive after
            // finish(), reject the final and leave the coordinator waiting.
            try await events.send(.final(
                turnID: turnID, itemID: turnID.uuidString, transcript: pending?.text ?? "final",
                speaker: pending?.speaker, utterances: pending?.utterances ?? [], sequence: 1))
            events.finish()
        }
        func finish() async throws {}
        func cancel() async { events.abandon(throwing: CancellationError()) }
    }

    private let lock = NSLock()
    private var domains: [ScriptedDomain] = []
    private var domainWaiters: [Int: [CheckedContinuation<MeetingFakeDomainHandle, Never>]] = [:]

    var openedSessionCount: Int {
        lock.lock(); defer { lock.unlock() }
        return domains.count
    }

    func startLiveSession(_ request: ASRLiveSessionRequest, credential: String) async throws -> any ASRLiveSession {
        let domain = ScriptedDomain(request: request)
        let waiters = lock.withLock {
            let index = domains.count
            domains.append(domain)
            return domainWaiters.removeValue(forKey: index) ?? []
        }
        let handle = MeetingFakeDomainHandle(box: domain.box)
        for waiter in waiters { waiter.resume(returning: handle) }
        return MeetingFakeSession(domain: domain)
    }

    func domain(at index: Int) async throws -> MeetingFakeDomainHandle {
        await withCheckedContinuation { continuation in
            let handle: MeetingFakeDomainHandle? = lock.withLock {
                if domains.indices.contains(index) {
                    return MeetingFakeDomainHandle(box: domains[index].box)
                }
                domainWaiters[index, default: []].append(continuation)
                return nil
            }
            if let handle { continuation.resume(returning: handle) }
        }
    }

    func onlyDomain() async throws -> MeetingFakeDomainHandle {
        try await domain(at: 0)
    }
}

private struct MeetingFakeDomainHandle: Sendable {
    let box: MeetingFakeLiveAdapter.MeetingFakeEventBox
    func deliverFinal(utterances: [ASRLiveUtterance]) async throws {
        box.lock.withLock {
            box.pendingFinal = ASRLiveEvent.final(
                turnID: UUID(), itemID: nil, transcript: "final",
                speaker: nil, utterances: utterances, sequence: 1)
        }
    }
}
#endif
