// SPDX-License-Identifier: MPL-2.0
import XCTest
@testable import FloeMeetings
@testable import FloeMeetingsAV

/// W7 continuous live-recognition core: the live lease lifecycle (trusted
/// same-capture tail vs revoked generations), coverage-based duplicate
/// fencing, request-domain media-time accounting, and the 16 kHz resampler.
final class ContinuousLiveTranscriptionTests: XCTestCase {
    var dbURL: URL!
    private var database: MeetingDatabase!

    override func tearDown() {
        if let dbURL { TestServices.cleanup(dbURL) }
    }

    private func makeService() async throws -> (MeetingService, MeetingID) {
        dbURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("floe-meetings-tests-\(UUID().uuidString).sqlite")
        database = try MeetingDatabase(path: dbURL.path)
        let service = MeetingService(database: database)
        let meeting = try await service.createMeeting(title: "Continuous live")
        return (service, meeting)
    }

    private func startLiveCapture(
        _ service: MeetingService,
        meeting: MeetingID,
        backend: FakeCaptureBackend = FakeCaptureBackend()
    ) async throws -> CaptureSessionID {
        try await service.startCapture(meeting: meeting, backend: backend,
            configuration: .init(directory: URL(fileURLWithPath: NSTemporaryDirectory())))
    }

    // MARK: - Coverage map

    func testCoverageMapCoalescesAndReports() throws {
        var map = MeetingCoverageMap()
        XCTAssertTrue(map.isEmpty)
        try map.commit(MediaTimeRange(start: 2, end: 3))
        try map.commit(MediaTimeRange(start: 0, end: 1))
        try map.commit(MediaTimeRange(start: 0.9995, end: 2.5))
        XCTAssertEqual(map.intervals.count, 1, "overlapping and adjacent spans coalesce")
        XCTAssertEqual(map.intervals.first?.start ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(map.intervals.first?.end ?? -1, 3, accuracy: 0.0001)
        XCTAssertEqual(map.coveredThrough ?? -1, 3, accuracy: 0.0001)
        XCTAssertTrue(try map.isCovered(MediaTimeRange(start: 0.2, end: 2.8)))
        XCTAssertFalse(try map.isCovered(MediaTimeRange(start: 3, end: 4)))
        XCTAssertTrue(try map.overlaps(MediaTimeRange(start: 2.9, end: 3.5)))
        XCTAssertFalse(try map.overlaps(MediaTimeRange(start: 3.001, end: 4)))
        let gaps = try map.uncoveredSubranges(of: MediaTimeRange(start: 0.5, end: 5))
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps.first?.start ?? -1, 3, accuracy: 0.0001)
        XCTAssertThrowsError(try map.commit(MediaTimeRange(start: 4, end: 4))) { _ in }
    }

    func testCoverageMapPreservesGapsBetweenDurableRows() throws {
        var map = MeetingCoverageMap()
        try map.commit(MediaTimeRange(start: 3, end: 4))
        try map.commit(MediaTimeRange(start: 0, end: 1))
        XCTAssertEqual(map.intervals, [
            try MediaTimeRange(start: 0, end: 1),
            try MediaTimeRange(start: 3, end: 4),
        ])
        let range = try MediaTimeRange(start: 0, end: 5)
        XCTAssertFalse(map.isCovered(range), "durable rows do not cover the audio between them")
        XCTAssertEqual(map.uncoveredSubranges(of: range), [
            try MediaTimeRange(start: 1, end: 3),
            try MediaTimeRange(start: 4, end: 5),
        ])
        try map.commit(MediaTimeRange(start: 1, end: 3))
        XCTAssertEqual(map.intervals, [try MediaTimeRange(start: 0, end: 4)],
                       "a real bridging row may coalesce the adjacent durable spans")
    }

    // MARK: - Request-domain accounting

    func testDomainAccountingMapsWireTimeToMediaTime() throws {
        var domain = MeetingLiveASRDomain(
            scope: UUID(), sourceSampleRate: 48_000,
            startFrame: 96_000, wireLimitBytes: 40_000)
        XCTAssertEqual(domain.startMediaSeconds, 2, accuracy: 0.0001)
        domain.account(frameCount: 24_000, wireBytes: 16_000) // 0.5s source, 0.5s wire
        XCTAssertEqual(domain.fedMediaSeconds, 0.5, accuracy: 0.0001)
        XCTAssertEqual(domain.fedWireSeconds, 0.5, accuracy: 0.0001)
        XCTAssertFalse(domain.willExceed(wireBytes: 1_000))
        XCTAssertFalse(domain.willExceed(wireBytes: 23_000))
        XCTAssertTrue(domain.willExceed(wireBytes: 24_000))
        XCTAssertEqual(domain.mediaSeconds(wireMilliseconds: 250), 2.25, accuracy: 0.0001)
        XCTAssertEqual(domain.mediaSeconds(wireMilliseconds: 90_000), 2.5,
                       accuracy: 0.0001, "offsets beyond the fed span clamp to the fed wire end")
        var rotated = MeetingLiveASRDomain(
            scope: UUID(), sourceSampleRate: 48_000,
            startFrame: 96_000 + 48_000, wireLimitBytes: 10_000)
        rotated.account(frameCount: 24_000, wireBytes: 16_000)
        XCTAssertEqual(rotated.startMediaSeconds, 3, accuracy: 0.0001,
                       "a rotated domain continues media time at its first accepted frame")
    }

    func testDomainAccountingIncludesResamplerFlushWithoutInventingSourceFrames() {
        var domain = MeetingLiveASRDomain(
            sourceSampleRate: 16_000, startFrame: 0, wireLimitBytes: 1_000_000)
        domain.account(frameCount: 160, wireBytes: 308)
        domain.account(frameCount: 0, wireBytes: 12)
        XCTAssertEqual(domain.framesFed, 160)
        XCTAssertEqual(domain.wireBytes, 320)
        XCTAssertEqual(domain.fedMediaSeconds, 0.01, accuracy: 0.000001)
        XCTAssertEqual(domain.fedWireSeconds, 0.01, accuracy: 0.000001)
        XCTAssertEqual(domain.mediaSeconds(wireMilliseconds: 10), 0.01, accuracy: 0.000001,
                       "a genuine short finish tail must not be clamped before its fed wire end")
    }

    // MARK: - Resampler

    func testDownsamplerHalvesBurstsIdenticallyToOnePush() throws {
        var single = try MeetingPCMDownsampler(targetSampleRate: 16_000)
        var split = try MeetingPCMDownsampler(targetSampleRate: 16_000)
        let rate: Double = 48_000
        var source = Data()
        for index in 0..<48_000 {
            var value = Float(sin(Double(index) * .pi * 2 * 220 / rate)) * 0.4
            withUnsafeBytes(of: &value) { source.append(contentsOf: $0) }
        }
        let whole = try single.push(source, sourceSampleRate: rate)
        let half = source.count / 2
        let first = try split.push(source[0..<half], sourceSampleRate: rate)
        let second = try split.push(source[half...], sourceSampleRate: rate)
        var combined = Data()
        combined.append(first)
        combined.append(second)
        // ~1 s of 16 kHz PCM16, within the FIR group-delay trim.
        XCTAssertEqual(whole.count, 32_000, accuracy: 64)
        XCTAssertEqual(combined, whole, "cross-push convolution is phase continuous")
        let wholeTail = single.flush()
        let splitTail = split.flush()
        XCTAssertEqual(splitTail, wholeTail, "the flushed tail is deterministic too")
        XCTAssertLessThanOrEqual(wholeTail.count, 256)
        // In-band amplitude survives the low-pass within tolerance.
        let peak = whole.withUnsafeBytes { raw -> Float in
            let samples = raw.bindMemory(to: Int16.self)
            return (0..<samples.count).reduce(0) { max($0, abs(Float(samples[$1]) / 32_767)) }
        }
        XCTAssertEqual(peak, 0.4, accuracy: 0.05)
    }

    /// Real anti-aliasing: source content above the target Nyquist band must
    /// be rejected, not folded into the recognition band as an alias.
    func testDownsamplerRejectsAboveNyquistContent() throws {
        var resampler = try MeetingPCMDownsampler(targetSampleRate: 16_000)
        let rate: Double = 48_000
        var source = Data()
        for index in 0..<48_000 {
            var value = Float(sin(Double(index) * .pi * 2 * 12_000 / rate)) * 0.4
            withUnsafeBytes(of: &value) { source.append(contentsOf: $0) }
        }
        let output = try resampler.push(source, sourceSampleRate: rate) + resampler.flush()
        let rms = output.withUnsafeBytes { raw -> Float in
            let samples = raw.bindMemory(to: Int16.self)
            guard samples.count > 0 else { return 0 }
            var energy: Float = 0
            for index in 0..<samples.count { energy += pow(Float(samples[index]) / 32_767, 2) }
            return sqrt(energy / Float(samples.count))
        }
        XCTAssertLessThan(rms / 0.4, 0.2, "12 kHz input at a 8 kHz Nyquist target must be strongly attenuated")
    }

    func testDownsamplerRejectsInvalidInput() throws {
        var resampler = try MeetingPCMDownsampler()
        XCTAssertThrowsError(try resampler.push(Data([1, 2, 3]), sourceSampleRate: 44_100)) { _ in }
        XCTAssertThrowsError(try resampler.push(Data(), sourceSampleRate: 1_000)) { _ in }
        XCTAssertThrowsError(try MeetingPCMDownsampler(targetSampleRate: 96_000)) { _ in }
    }

    // MARK: - Lease lifecycle

    func testBeginRequiresAnActiveLiveCapture() async throws {
        let (service, meeting) = try await makeService()
        let imported = try await TestServices.importedSession(service, meeting: meeting)
        do {
            _ = try await service.beginLiveTranscription(meeting: meeting, session: imported)
            XCTFail("a file-analysis session must never host a live lease")
        } catch LiveTranscriptionError.invalidSession { }
    }

    func testTailCommitsAfterNormalStopUntilLeaseCloses() async throws {
        let (service, meeting) = try await makeService()
        let session = try await startLiveCapture(service, meeting: meeting)
        let lease = try await service.beginLiveTranscription(meeting: meeting, session: session)
        try await service.updateLivePartial(lease, text: "partial words")
        let partialsAfterUpdate = await service.currentPartials(meeting: meeting)
        XCTAssertEqual(partialsAfterUpdate.count, 1)

        let speaker = try await service.resolveEngineSpeaker(
            meeting: meeting, scope: lease.id.uuidString, label: "1")
        _ = try await service.commitLiveFinal(lease, text: "spoken before stop",
            range: MediaTimeRange(start: 0, end: 1.5), speaker: speaker, language: "en")
        _ = try await service.stopCapture()

        // Normal stop: the genuine finish tail of THIS capture/request is
        // still accepted while the lease drains.
        _ = try await service.commitLiveFinal(lease, text: "stop tail",
            range: MediaTimeRange(start: 1.5, end: 2.2), speaker: speaker, language: "en")
        // Partial updates no longer flow once stopped.
        do {
            try await service.updateLivePartial(lease, text: "late partial")
            XCTFail("partial updates must not flow after stop")
        } catch LiveTranscriptionError.leaseRevoked { }

        await service.endLiveTranscription(lease)
        do {
            _ = try await service.commitLiveFinal(lease, text: "after close",
                range: MediaTimeRange(start: 3, end: 4), speaker: speaker)
            XCTFail("commits after endLiveTranscription must be rejected")
        } catch LiveTranscriptionError.unknownLease { }

        let rows = try await service.transcript(meeting: meeting)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first?.sessionID, session, "live finals belong to the original capture")
        let partialsAfterTail = await service.currentPartials(meeting: meeting)
        XCTAssertTrue(partialsAfterTail.isEmpty,
                      "the committed final supersedes the visible partial")
    }

    func testCancelRevokesLeaseAndDropsPartials() async throws {
        let (service, meeting) = try await makeService()
        let session = try await startLiveCapture(service, meeting: meeting)
        let lease = try await service.beginLiveTranscription(meeting: meeting, session: session)
        try await service.updateLivePartial(lease, text: "unfinished")
        _ = try await service.cancelCapture()
        do {
            _ = try await service.commitLiveFinal(lease, text: "late",
                range: MediaTimeRange(start: 0, end: 1))
            XCTFail("cancelled capture must reject late live finals")
        } catch LiveTranscriptionError.leaseRevoked { }
        let partialsAfterCancel = await service.currentPartials(meeting: meeting)
        XCTAssertTrue(partialsAfterCancel.isEmpty)
        let transcriptAfterCancel = try await service.transcript(meeting: meeting)
        XCTAssertTrue(transcriptAfterCancel.isEmpty)
    }

    func testReplacementLeaseRevokesThePreviousGeneration() async throws {
        let (service, meeting) = try await makeService()
        let session = try await startLiveCapture(service, meeting: meeting)
        let first = try await service.beginLiveTranscription(meeting: meeting, session: session)
        let second = try await service.beginLiveTranscription(meeting: meeting, session: session)
        do {
            _ = try await service.commitLiveFinal(first, text: "stale generation",
                range: MediaTimeRange(start: 0, end: 1))
            XCTFail("a replaced coordinator generation must not write")
        } catch LiveTranscriptionError.unknownLease { }
        let speaker = try await service.resolveEngineSpeaker(
            meeting: meeting, scope: second.id.uuidString, label: "1")
        let saved = try await service.commitLiveFinal(second, text: "fresh generation",
            range: MediaTimeRange(start: 0, end: 1), speaker: speaker)
        XCTAssertNotNil(saved)
    }

    // These barriers pause the real DB entrypoint before its permit/SQL
    // transaction. No sleeps or lock-held callbacks choose the interleaving.
    func testInFlightCommitIsFencedByReplacementLease() async throws {
        let (service, meeting) = try await makeService()
        let session = try await startLiveCapture(service, meeting: meeting)
        let first = try await service.beginLiveTranscription(meeting: meeting, session: session)
        let gate = LiveCommitBarrier()
        await database.setBeforeLiveTranscriptCommit { await gate.enter() }
        let pending = Task {
            try await service.commitLiveFinal(first, text: "stale generation",
                range: MediaTimeRange(start: 0, end: 1), utteranceKey: "old|0|1000")
        }
        await gate.waitUntilEntered()
        let replacement = try await service.beginLiveTranscription(meeting: meeting, session: session)
        await gate.release()
        do {
            _ = try await pending.value
            XCTFail("the already-issued old final must not write after replacement")
        } catch LiveTranscriptionError.leaseRevoked { }
        let rowsBeforeReplacement = try await service.transcript(meeting: meeting)
        XCTAssertTrue(rowsBeforeReplacement.isEmpty)
        let saved = try await service.commitLiveFinal(replacement, text: "replacement",
            range: MediaTimeRange(start: 0, end: 1), utteranceKey: "new|0|1000")
        XCTAssertNotNil(saved, "the new generation still owns write authority")
    }

    func testInFlightKeylessCommitIsFencedByLeaseEnd() async throws {
        let (service, meeting) = try await makeService()
        let session = try await startLiveCapture(service, meeting: meeting)
        let lease = try await service.beginLiveTranscription(meeting: meeting, session: session)
        let gate = LiveCommitBarrier()
        await database.setBeforeLiveTranscriptCommit { await gate.enter() }
        let pending = Task {
            try await service.commitLiveFinal(lease, text: "already issued",
                range: MediaTimeRange(start: 0, end: 1))
        }
        await gate.waitUntilEntered()
        await service.endLiveTranscription(lease)
        await gate.release()
        do {
            _ = try await pending.value
            XCTFail("ending a lease must fence its keyless in-flight final")
        } catch LiveTranscriptionError.leaseRevoked { }
        let rows = try await service.transcript(meeting: meeting)
        XCTAssertTrue(rows.isEmpty)
    }

    func testInFlightCommitIsFencedByCaptureCancel() async throws {
        let (service, meeting) = try await makeService()
        let session = try await startLiveCapture(service, meeting: meeting)
        let lease = try await service.beginLiveTranscription(meeting: meeting, session: session)
        let gate = LiveCommitBarrier()
        await database.setBeforeLiveTranscriptCommit { await gate.enter() }
        let pending = Task {
            try await service.commitLiveFinal(lease, text: "already issued",
                range: MediaTimeRange(start: 0, end: 1), utteranceKey: "cancel|0|1000")
        }
        await gate.waitUntilEntered()
        _ = try await service.cancelCapture()
        await gate.release()
        do {
            _ = try await pending.value
            XCTFail("capture cancellation must fence a final already inside its DB call")
        } catch LiveTranscriptionError.leaseRevoked { }
        let rows = try await service.transcript(meeting: meeting)
        XCTAssertTrue(rows.isEmpty)
    }

    func testInFlightDrainingCommitIsFencedByCancelEarlyReturn() async throws {
        let (service, meeting) = try await makeService()
        let session = try await startLiveCapture(service, meeting: meeting)
        let lease = try await service.beginLiveTranscription(meeting: meeting, session: session)
        _ = try await service.stopCapture()
        let gate = LiveCommitBarrier()
        await database.setBeforeLiveTranscriptCommit { await gate.enter() }
        let pending = Task {
            try await service.commitLiveFinal(lease, text: "draining tail",
                range: MediaTimeRange(start: 0, end: 1), utteranceKey: "draining|0|1000")
        }
        await gate.waitUntilEntered()
        let cancelled = try await service.cancelCapture()
        XCTAssertNil(cancelled, "the stopped controller takes its early-return cancellation path")
        await gate.release()
        do {
            _ = try await pending.value
            XCTFail("an epoch bump must revoke an already-issued draining final too")
        } catch LiveTranscriptionError.leaseRevoked { }
        let rows = try await service.transcript(meeting: meeting)
        XCTAssertTrue(rows.isEmpty)
    }

    func testInFlightCommitRetainsAuthorityAcrossNormalStop() async throws {
        let (service, meeting) = try await makeService()
        let session = try await startLiveCapture(service, meeting: meeting)
        let lease = try await service.beginLiveTranscription(meeting: meeting, session: session)
        let gate = LiveCommitBarrier()
        await database.setBeforeLiveTranscriptCommit { await gate.enter() }
        let pending = Task {
            try await service.commitLiveFinal(lease, text: "genuine finish tail",
                range: MediaTimeRange(start: 0, end: 1), utteranceKey: "tail|0|1000")
        }
        await gate.waitUntilEntered()
        _ = try await service.stopCapture()
        await gate.release()
        let saved = try await pending.value
        XCTAssertNotNil(saved, "normal stop drains instead of revoking the permit")
        let rows = try await service.transcript(meeting: meeting)
        XCTAssertEqual(rows.map(\.text), ["genuine finish tail"])
    }

    func testOverlappingCommitIsSkippedNotDuplicatedAndCorrectionSurvives() async throws {
        let (service, meeting) = try await makeService()
        let session = try await startLiveCapture(service, meeting: meeting)
        let lease = try await service.beginLiveTranscription(meeting: meeting, session: session)
        let speaker = try await service.resolveEngineSpeaker(
            meeting: meeting, scope: lease.id.uuidString, label: "1")
        let first = try await service.commitLiveFinal(lease, text: "original words",
            range: MediaTimeRange(start: 0, end: 1), speaker: speaker)
        let duplicate = try await service.commitLiveFinal(lease, text: "original words",
            range: MediaTimeRange(start: 0.2, end: 0.9), speaker: speaker)
        XCTAssertNil(duplicate, "an overlapping replay is a no-op, never a second row")
        let abutting = try await service.commitLiveFinal(lease, text: "next words",
            range: MediaTimeRange(start: 1, end: 2), speaker: speaker)
        XCTAssertNotNil(abutting, "exactly abutting utterances are not duplicates")

        let corrected = try XCTUnwrap(first)
        _ = try await service.correctSegment(corrected.id, meeting: meeting, newText: "user corrected")
        let lateOverlap = try await service.commitLiveFinal(lease, text: "stale overlap",
            range: MediaTimeRange(start: 0.5, end: 1.5), speaker: speaker)
        XCTAssertNil(lateOverlap)
        let rows = try await service.transcript(meeting: meeting)
        XCTAssertEqual(rows.count, 2)
        let kept = try XCTUnwrap(rows.first(where: { $0.id == corrected.id }))
        XCTAssertEqual(kept.text, "user corrected")
        XCTAssertEqual(kept.originalText, "original words")
    }

    /// The acceptance core: ONE request domain (one lease) keeps speaker
    /// identities truthful ACROSS storage chunk boundaries — the same numeric
    /// label observed in two different finalized chunks is one person.
    func testSingleDomainKeepsSpeakerIdentityAcrossStorageChunks() async throws {
        let (service, meeting) = try await makeService()
        let backend = FakeCaptureBackend()
        let session = try await startLiveCapture(service, meeting: meeting, backend: backend)
        let lease = try await service.beginLiveTranscription(meeting: meeting, session: session)

        // Two storage chunks finalize mid-capture; the live domain ignores
        // the boundaries — it is fed the same PCM stream end to end.
        backend.emit(.chunkFinalized(session: session, file: URL(fileURLWithPath: "/tmp/a.m4a"),
                                     range: try MediaTimeRange(start: 0, end: 5)))
        backend.emit(.chunkFinalized(session: session, file: URL(fileURLWithPath: "/tmp/b.m4a"),
                                     range: try MediaTimeRange(start: 5, end: 10)))
        let scope = lease.id.uuidString
        let one = try await service.resolveEngineSpeaker(meeting: meeting, scope: scope, label: "1")
        let two = try await service.resolveEngineSpeaker(meeting: meeting, scope: scope, label: "2")
        _ = try await service.commitLiveFinal(lease, text: "hello", range: MediaTimeRange(start: 0.5, end: 1.8), speaker: one)
        _ = try await service.commitLiveFinal(lease, text: "hi there", range: MediaTimeRange(start: 2.0, end: 3.4), speaker: two)
        _ = try await service.commitLiveFinal(lease, text: "second chunk same speaker", range: MediaTimeRange(start: 6.2, end: 8.0), speaker: one)
        _ = try await service.stopCapture()

        let rows = try await service.transcript(meeting: meeting)
        XCTAssertEqual(rows.count, 3)
        let speakers = try await service.speakers(meeting: meeting)
        XCTAssertEqual(speakers.count, 2, "two labels in one request domain are two people, not four")
        let bySpeaker = Dictionary(grouping: rows, by: { $0.speakerID })
        XCTAssertEqual(bySpeaker[one]?.count, 2)
        XCTAssertEqual(bySpeaker[two]?.count, 1)

        // Reopen: rows, speakers and the per-request binding persist.
        let reopened = MeetingService(database: try MeetingDatabase(path: dbURL.path))
        let reopenedRows = try await reopened.transcript(meeting: meeting)
        XCTAssertEqual(reopenedRows.count, 3)
        let reopenedSpeakers = try await reopened.speakers(meeting: meeting)
        XCTAssertEqual(reopenedSpeakers.count, 2)
        let resolvedAgain = try await reopened.resolveEngineSpeaker(meeting: meeting, scope: scope, label: "1")
        XCTAssertEqual(resolvedAgain, one, "the same request scope rebinds to the same speaker after reopen")
    }

    /// A NEW capture (pause/resume or reconnect of the whole recording) is a
    /// new request domain: the same numeric label must bind a new speaker.
    func testNewCaptureIsANewSpeakerDomain() async throws {
        let (service, meeting) = try await makeService()
        let first = try await startLiveCapture(service, meeting: meeting)
        let firstLease = try await service.beginLiveTranscription(meeting: meeting, session: first)
        let firstSpeaker = try await service.resolveEngineSpeaker(
            meeting: meeting, scope: firstLease.id.uuidString, label: "1")
        _ = try await service.stopCapture()

        let second = try await startLiveCapture(service, meeting: meeting)
        let secondLease = try await service.beginLiveTranscription(meeting: meeting, session: second)
        let secondSpeaker = try await service.resolveEngineSpeaker(
            meeting: meeting, scope: secondLease.id.uuidString, label: "1")
        XCTAssertNotEqual(firstSpeaker, secondSpeaker,
                          "the resumed recording is a new request domain; label 1 is a new person until merged")
    }

    // MARK: - Root review: lineage-bound duplicate fencing

    /// Two originals of ONE meeting can occupy identical time ranges with
    /// different content; duplicate fencing is scoped to one original's
    /// trusted lineage and must never cross originals.
    func testTwoOriginalsAtSameTimesDoNotFenceEachOther() async throws {
        let (service, meeting) = try await makeService()
        let a = try await startLiveCapture(service, meeting: meeting)
        let leaseA = try await service.beginLiveTranscription(meeting: meeting, session: a)
        let speakerA = try await service.resolveEngineSpeaker(
            meeting: meeting, scope: leaseA.id.uuidString, label: "1")
        _ = try await service.commitLiveFinal(leaseA, text: "alpha words",
            range: MediaTimeRange(start: 0, end: 2), speaker: speakerA,
            utteranceKey: "\(leaseA.id.uuidString)|0|2000")
        _ = try await service.stopCapture()

        let b = try await startLiveCapture(service, meeting: meeting)
        let leaseB = try await service.beginLiveTranscription(meeting: meeting, session: b)
        let speakerB = try await service.resolveEngineSpeaker(
            meeting: meeting, scope: leaseB.id.uuidString, label: "1")
        let committed = try await service.commitLiveFinal(leaseB, text: "beta words",
            range: MediaTimeRange(start: 0, end: 2), speaker: speakerB,
            utteranceKey: "\(leaseB.id.uuidString)|0|2000")
        XCTAssertNotNil(committed, "the second original at the same times is a different lineage")
        let rows = try await service.transcript(meeting: meeting)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.text)), ["alpha words", "beta words"])
    }

    /// Chunk analysis rows are explicitly linked to their original at import
    /// time; the link both fences the live tail of that original and scopes
    /// the App-side reserved-range query.
    func testAnalysisLineageBindsChunkRowsToTheirOriginal() async throws {
        let (service, meeting) = try await makeService()
        let a = try await startLiveCapture(service, meeting: meeting)
        let leaseA = try await service.beginLiveTranscription(meeting: meeting, session: a)
        _ = try await service.stopCapture()
        // A chunk analysis session of original A already committed (the file
        // path ran before the tail in a reopen scenario).
        let chunkFile = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("chunk-\(UUID()).m4a")
        try Data([0]).write(to: chunkFile)
        let chunkA = try await service.importFile(meeting: meeting, file: chunkFile,
            kind: .importedAudio, origin: a) { _ in try MediaTimeRange(start: 0, end: 5) }
        _ = try await service.appendFinal(meeting: meeting, session: chunkA,
            text: "file covered", range: MediaTimeRange(start: 0, end: 2), speaker: nil)
        // The live tail of A overlapping the chunk row of A is fenced —
        // both through the keyless overlap fence and the keyed upsert fence
        // (the coordinator's normal path).
        let dup = try await service.commitLiveFinal(leaseA, text: "same time",
            range: MediaTimeRange(start: 0, end: 2))
        XCTAssertNil(dup)
        let keyedDup = try await service.commitLiveFinal(leaseA, text: "same time keyed",
            range: MediaTimeRange(start: 0, end: 2),
            utteranceKey: "\(leaseA.id.uuidString)|0|2000")
        XCTAssertNil(keyedDup)
        // The second original at the same time is NOT fenced by A's rows.
        let b = try await startLiveCapture(service, meeting: meeting)
        let leaseB = try await service.beginLiveTranscription(meeting: meeting, session: b)
        let committed = try await service.commitLiveFinal(leaseB, text: "b words",
            range: MediaTimeRange(start: 0, end: 2))
        XCTAssertNotNil(committed)
        // Reserved-range queries are lineage-scoped on both originals.
        let lineageA = try await service.committedSegments(meeting: meeting, original: a)
        XCTAssertEqual(lineageA.count, 1)
        let lineageB = try await service.committedSegments(meeting: meeting, original: b)
        XCTAssertEqual(lineageB.count, 1)
    }

    // MARK: - Root review: utterance identity vs duplicates

    /// One trusted request domain + one stable utterance identity: a revised
    /// final ADOPTS in the same transaction; the user's own text/speaker
    /// corrections always win; a different key overlapping the span is a
    /// no-op, never a second row.
    func testUtteranceKeyAdoptsRevisionButNeverUserCorrections() async throws {
        let (service, meeting) = try await makeService()
        let session = try await startLiveCapture(service, meeting: meeting)
        let lease = try await service.beginLiveTranscription(meeting: meeting, session: session)
        let scope = lease.id.uuidString
        let speakerOne = try await service.resolveEngineSpeaker(meeting: meeting, scope: scope, label: "1")
        let key = "\(scope)|0|2000"
        let first = try await service.commitLiveFinal(lease, text: "draft words",
            range: MediaTimeRange(start: 0, end: 2), speaker: speakerOne, utteranceKey: key)
        let row = try XCTUnwrap(first)
        let revised = try await service.commitLiveFinal(lease, text: "revised words",
            range: MediaTimeRange(start: 0, end: 2), speaker: speakerOne, utteranceKey: key)
        XCTAssertEqual(revised?.id, row.id, "same key keeps the same segment identity")
        XCTAssertEqual(revised?.text, "revised words")
        let transcriptRows = try await service.transcript(meeting: meeting)
        XCTAssertEqual(transcriptRows.count, 1)

        _ = try await service.correctSegment(row.id, meeting: meeting, newText: "user text")
        let afterText = try await service.commitLiveFinal(lease, text: "engine again",
            range: MediaTimeRange(start: 0, end: 2), speaker: speakerOne, utteranceKey: key)
        XCTAssertEqual(afterText?.text, "user text", "a user text correction is never overwritten")

        let speakerTwo = try await service.resolveEngineSpeaker(meeting: meeting, scope: scope, label: "2")
        _ = try await service.reassignSegmentSpeaker(row.id, meeting: meeting, speaker: speakerTwo)
        let afterSpeaker = try await service.commitLiveFinal(lease, text: "engine speaker",
            range: MediaTimeRange(start: 0, end: 2), speaker: speakerOne, utteranceKey: key)
        XCTAssertEqual(afterSpeaker?.speakerID, speakerTwo, "a user speaker correction is never overwritten")
        let adoptedRows = try await service.transcript(meeting: meeting)
        XCTAssertEqual(adoptedRows.count, 1)

        // A different request domain's utterance at the same span: no row.
        let other = try await service.commitLiveFinal(lease, text: "other domain",
            range: MediaTimeRange(start: 0, end: 2), speaker: speakerOne,
            utteranceKey: "another-scope|0|2000")
        XCTAssertNil(other)
        let fencedRows = try await service.transcript(meeting: meeting)
        XCTAssertEqual(fencedRows.count, 1)
    }

    /// A same-key provider revision may change an anonymous attribution, but
    /// must retain identities the user established by rename or merge. Cover
    /// both ends and an intermediate link of a merge chain without relying
    /// on the separate per-row speakerCorrected flag.
    func testSameKeyRevisionPreservesNamedAndMergedAttributionWhileAnonymousCanChange() async throws {
        let (service, meeting) = try await makeService()
        let session = try await startLiveCapture(service, meeting: meeting)
        let lease = try await service.beginLiveTranscription(meeting: meeting, session: session)
        let scope = lease.id.uuidString
        var speakers: [String: SpeakerID] = [:]
        for label in ["named", "source", "middle", "target", "anonymous", "provider revision"] {
            let speaker = try await service.resolveEngineSpeaker(meeting: meeting, scope: scope, label: label)
            speakers[label] = try XCTUnwrap(speaker)
        }
        let initial: [(key: String, speaker: SpeakerID, start: Double)] = [
            ("named", try XCTUnwrap(speakers["named"]), 0),
            ("source", try XCTUnwrap(speakers["source"]), 1),
            ("middle", try XCTUnwrap(speakers["middle"]), 2),
            ("target", try XCTUnwrap(speakers["target"]), 3),
            ("anonymous", try XCTUnwrap(speakers["anonymous"]), 4),
        ]
        var originalRows: [String: TranscriptSegment] = [:]
        for item in initial {
            let saved = try await service.commitLiveFinal(lease, text: item.key + " draft",
                range: MediaTimeRange(start: item.start, end: item.start + 1),
                speaker: item.speaker, utteranceKey: item.key)
            originalRows[item.key] = try XCTUnwrap(saved)
        }
        let named = try XCTUnwrap(speakers["named"])
        let source = try XCTUnwrap(speakers["source"])
        let middle = try XCTUnwrap(speakers["middle"])
        let target = try XCTUnwrap(speakers["target"])
        let incoming = try XCTUnwrap(speakers["provider revision"])
        try await service.renameSpeaker(named, meeting: meeting, to: "Alice", byUser: true)
        try await service.mergeSpeaker(source, into: middle, meeting: meeting)
        try await service.mergeSpeaker(middle, into: target, meeting: meeting)

        for item in initial {
            let original = try XCTUnwrap(originalRows[item.key])
            let revised = try await service.commitLiveFinal(lease, text: item.key + " revised",
                range: original.range, speaker: incoming, utteranceKey: item.key)
            XCTAssertEqual(revised?.id, original.id)
            XCTAssertEqual(revised?.text, item.key + " revised", "text revisions still adopt normally")
            XCTAssertEqual(revised?.speakerID, item.key == "anonymous" ? incoming : item.speaker,
                           "only anonymous attribution may follow a provider speaker revision")
        }
        _ = try await service.stopCapture()
        await service.endLiveTranscription(lease)

        let reopened = MeetingService(database: try MeetingDatabase(path: dbURL.path))
        let rows = try await reopened.transcript(meeting: meeting)
        XCTAssertEqual(rows.count, initial.count)
        XCTAssertTrue(rows.allSatisfy { !$0.speakerCorrected }, "rename/merge protection is distinct from row correction")
        for item in initial {
            let original = try XCTUnwrap(originalRows[item.key])
            let row = try XCTUnwrap(rows.first { $0.id == original.id })
            XCTAssertEqual(row.speakerID, item.key == "anonymous" ? incoming : item.speaker,
                           "established attribution survives reopen")
        }
        let resolvedSource = try await reopened.resolveSpeaker(source, meeting: meeting)
        let resolvedMiddle = try await reopened.resolveSpeaker(middle, meeting: meeting)
        XCTAssertEqual(resolvedSource, target)
        XCTAssertEqual(resolvedMiddle, target)
        let namedSpeakers = try await reopened.speakers(meeting: meeting)
        XCTAssertTrue(namedSpeakers.contains { $0.id == named && $0.userNamed && $0.label == "Alice" })
    }

    /// The duplicate fence and write share one transaction while the permit
    /// is held: concurrent duplicate commits cannot both insert.
    func testConcurrentDuplicateCommitsProduceOneRow() async throws {
        let (service, meeting) = try await makeService()
        let session = try await startLiveCapture(service, meeting: meeting)
        let lease = try await service.beginLiveTranscription(meeting: meeting, session: session)
        let scope = lease.id.uuidString
        let speaker = try await service.resolveEngineSpeaker(meeting: meeting, scope: scope, label: "1")
        let results = try await withThrowingTaskGroup(of: TranscriptSegment?.self) { group in
            for index in 0..<8 {
                group.addTask {
                    try await service.commitLiveFinal(lease, text: "words \(index)",
                        range: MediaTimeRange(start: 0, end: 2), speaker: speaker,
                        utteranceKey: "\(scope)|0|2000")
                }
            }
            var collected: [TranscriptSegment?] = []
            for try await result in group { collected.append(result) }
            return collected
        }
        let concurrentRows = try await service.transcript(meeting: meeting)
        XCTAssertEqual(concurrentRows.count, 1,
                       "transactional fencing must not allow duplicate rows")
        XCTAssertEqual(results.compactMap { $0 }.count, 8, "every caller gets the adopted segment back")
    }

    /// Normal stop → draining accepts the genuine tail; a LATER explicit
    /// cancel (meeting deletion path) revokes the draining lease — the
    /// early-return capture path must not leak it.
    func testDrainingTailIsRevokedByLaterCancel() async throws {
        let (service, meeting) = try await makeService()
        let session = try await startLiveCapture(service, meeting: meeting)
        let lease = try await service.beginLiveTranscription(meeting: meeting, session: session)
        _ = try await service.stopCapture()
        let tail = try await service.commitLiveFinal(lease, text: "tail",
            range: MediaTimeRange(start: 0, end: 1))
        XCTAssertNotNil(tail)
        _ = try await service.cancelCapture()
        do {
            _ = try await service.commitLiveFinal(lease, text: "late",
                range: MediaTimeRange(start: 1, end: 2))
            XCTFail("cancel after stop must revoke the draining lease")
        } catch LiveTranscriptionError.leaseRevoked { }
        let rows = try await service.transcript(meeting: meeting)
        XCTAssertEqual(rows.count, 1)
    }

    // MARK: - Root review: user-established attribution survives adoption

    /// A user RENAMED speaker and a MERGE chain are user-established
    /// attribution: the canonical pass from a DIFFERENT request id must not
    /// replace them with new anonymous labels, and the protection persists
    /// across reopen.
    func testNamedAndMergedAttributionSurvivesCanonicalAdoptionFromAnotherRequest() async throws {
        let (service, meeting) = try await makeService()
        let original = try await startLiveCapture(service, meeting: meeting)
        let lease = try await service.beginLiveTranscription(meeting: meeting, session: original)
        let scope = lease.id.uuidString
        let one = try await service.resolveEngineSpeaker(meeting: meeting, scope: scope, label: "1")
        let two = try await service.resolveEngineSpeaker(meeting: meeting, scope: scope, label: "2")
        let resolvedOne = try XCTUnwrap(one)
        let resolvedTwo = try XCTUnwrap(two)
        _ = try await service.commitLiveFinal(lease, text: "first",
            range: MediaTimeRange(start: 0, end: 2), speaker: resolvedOne)
        _ = try await service.commitLiveFinal(lease, text: "second",
            range: MediaTimeRange(start: 2, end: 4), speaker: resolvedTwo)
        _ = try await service.stopCapture()
        try await service.renameSpeaker(resolvedOne, meeting: meeting, to: "Alice", byUser: true)
        try await service.mergeSpeaker(resolvedTwo, into: resolvedOne, meeting: meeting)

        // Whole-file canonical pass from an INDEPENDENT request domain.
        let analysisFile = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("whole-\(UUID()).m4a")
        try Data([0]).write(to: analysisFile)
        let target = try await service.importFile(meeting: meeting, file: analysisFile,
            kind: .importedAudio, origin: original) { _ in try MediaTimeRange(start: 0, end: 4) }
        let newRequest = UUID().uuidString
        let anon = try await service.resolveEngineSpeaker(meeting: meeting, scope: newRequest, label: "1")
        let outcome = try await service.reconcileCanonicalTranscription(
            meeting: meeting,
            analysisSessions: [original, target],
            target: target,
            inputs: [
                .init(startSeconds: 0, endSeconds: 2, text: "canonical one", speakerID: anon),
                .init(startSeconds: 2, endSeconds: 4, text: "canonical two", speakerID: anon),
            ])
        XCTAssertEqual(outcome.adopted, 2,
                       "uncorrected text may still adopt the canonical engine revision")
        XCTAssertEqual(outcome.preserved, 0)
        let rows = try await service.transcript(meeting: meeting)
        XCTAssertEqual(Set(rows.map(\.text)), ["canonical one", "canonical two"])
        for row in rows {
            let speaker = try await service.resolveSpeaker(row.speakerID!, meeting: meeting)
            XCTAssertEqual(speaker, resolvedOne, "user-established attribution is not replaced by a new request")
        }

        let reopened = MeetingService(database: try MeetingDatabase(path: dbURL.path))
        let reopenedRows = try await reopened.transcript(meeting: meeting)
        XCTAssertEqual(reopenedRows.count, 2)
        for row in reopenedRows {
            let speaker = try await reopened.resolveSpeaker(row.speakerID!, meeting: meeting)
            XCTAssertEqual(speaker, resolvedOne, "the protection persists across reopen")
        }
        let alice = try await reopened.speakers(meeting: meeting)
        XCTAssertTrue(alice.first { $0.id == resolvedOne }?.userNamed == true)
    }

    /// A v5-era database upgrades to v6: existing rows keep NULL lineage and
    /// NULL live keys and behave exactly as before.
    func testV5DatabaseUpgradesToV6KeepingExistingRows() async throws {
        let (service, meeting) = try await makeService()
        let original = try await startLiveCapture(service, meeting: meeting)
        let lease = try await service.beginLiveTranscription(meeting: meeting, session: original)
        _ = try await service.commitLiveFinal(lease, text: "live row",
            range: MediaTimeRange(start: 0, end: 2), speaker: nil)
        _ = try await service.stopCapture()
        let fixture = try MeetingDatabase(path: dbURL.path)
        try await fixture.pool.write { db in
            try db.execute(sql: "DROP INDEX IF EXISTS capture_sessions_origin")
            try db.execute(sql: "DROP INDEX IF EXISTS transcript_segments_livekey")
            try db.execute(sql: "ALTER TABLE capture_sessions DROP COLUMN originSessionID")
            try db.execute(sql: "ALTER TABLE transcript_segments DROP COLUMN liveKey")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v6-continuous-live-lineage'")
        }
        let reopened = MeetingService(database: try MeetingDatabase(path: dbURL.path))
        let rows = try await reopened.transcript(meeting: meeting)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].text, "live row")
        // New seams work on upgraded rows: lineage resolves to the original.
        let lineage = try await reopened.committedSegments(meeting: meeting, original: original)
        XCTAssertEqual(lineage.count, 1)
    }
}

private actor LiveCommitBarrier {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if !released {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
    }

    func waitUntilEntered() async {
        if !entered {
            await withCheckedContinuation { entryWaiters.append($0) }
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
