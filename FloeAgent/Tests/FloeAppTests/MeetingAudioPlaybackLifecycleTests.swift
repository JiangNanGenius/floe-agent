// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import AVFoundation
import Foundation
import Observation
import Testing
@testable import FloeApp

/// Real players/items and the production NotificationCenter observers. Empty
/// compositions have no media tracks; these tests never call play(), activate
/// an audio session, request permission, or read a recording.
@MainActor @Suite("Meeting playback observation lifecycle", .serialized)
struct MeetingAudioPlaybackLifecycleTests {
    private struct PlayerFixture {
        let player: AVPlayer
        let item: AVPlayerItem
        let duration: Double

        init(duration: Double) {
            let composition = AVMutableComposition()
            composition.insertEmptyTimeRange(CMTimeRange(start: .zero,
                duration: CMTime(seconds: duration + 60, preferredTimescale: 600)))
            item = AVPlayerItem(asset: composition)
            item.forwardPlaybackEndTime = CMTime(seconds: duration, preferredTimescale: 600)
            player = AVPlayer(playerItem: item)
            player.isMuted = true
            player.volume = 0
            self.duration = duration
        }
    }

    private final class DeliveryProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var delivered = 0
        var count: Int { lock.withLock { delivered } }
        func noteDelivery() { lock.withLock { delivered += 1 } }
    }

    /// A second real observer acknowledges synchronous notification delivery
    /// before the test switches players. The positive-control model below
    /// separately proves the production end Task actually reached MainActor.
    private func observeDelivery(of item: AVPlayerItem, probe: DeliveryProbe) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
            object: item, queue: .main) { _ in probe.noteDelivery() }
    }

    private func mainQueueTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func requireEndDelivered(to model: MeetingAudioPlaybackModel, duration: Double) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while model.currentTime != duration, ContinuousClock.now < deadline {
            await mainQueueTurn()
        }
        try #require(model.currentTime == duration,
            "The actual production end observer did not settle; the negative lifecycle assertion would be inconclusive")
        // Complete the main-queue -> MainActor hop after the live control's
        // callback. No timer or arbitrary sleep substitutes for that receipt.
        await mainQueueTurn()
        await mainQueueTurn()
    }

    @Test("An old item's queued end cannot move a newly attached player to its end")
    func queuedOldItemEndCannotAdvanceReplacementPlayer() async throws {
        let old = PlayerFixture(duration: 11), replacement = PlayerFixture(duration: 29)
        let model = MeetingAudioPlaybackModel(), liveControl = MeetingAudioPlaybackModel()
        defer { model.detach(); liveControl.detach() }
        model.attach(to: old.player)
        liveControl.attach(to: old.player)
        try #require(model.canSeek && model.duration == old.duration)
        let probe = DeliveryProbe(), token = observeDelivery(of: old.item, probe: probe)
        defer { NotificationCenter.default.removeObserver(token) }

        // No await between post and attach: the observer has queued its Task,
        // while this actor turn still owns the old-to-new attachment change.
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: old.item)
        try #require(probe.count == 1, "The old-item notification was not delivered before replacement")
        model.attach(to: replacement.player)
        try #require(model.canSeek && model.duration == replacement.duration)
        try #require(model.currentTime == 0)
        // Latch even a transient mutation: a later legitimate time=0 update
        // must not hide the stale end having first jumped the new playhead.
        let replacementMutations = DeliveryProbe()
        withObservationTracking {
            _ = model.currentTime
        } onChange: {
            replacementMutations.noteDelivery()
        }

        try await requireEndDelivered(to: liveControl, duration: old.duration)
        #expect(replacementMutations.count == 0)
        #expect(model.currentTime == 0)
        #expect(model.displayTime == 0)
        #expect(model.duration == replacement.duration)
        #expect(!model.isPlaying)
        #expect(replacement.player.currentTime().seconds == 0)

        // A missing/broken replacement observer must not let the stale-item
        // assertion pass: this actual current-item notification must work.
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: replacement.item)
        try await requireEndDelivered(to: model, duration: replacement.duration)
    }

    @Test("The current item's real end notification commits duration and ends scrubbing")
    func currentItemEndNotificationCommitsDuration() async throws {
        let fixture = PlayerFixture(duration: 17)
        let model = MeetingAudioPlaybackModel()
        defer { model.detach() }
        model.attach(to: fixture.player)
        try #require(model.canSeek && model.duration == fixture.duration)
        model.beginScrubbing()
        model.updateScrub(4)
        try #require(model.isScrubbing && model.displayTime == 4)
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: fixture.item)
        try await requireEndDelivered(to: model, duration: fixture.duration)
        #expect(model.displayTime == fixture.duration)
        #expect(!model.isScrubbing)
        #expect(!model.isPlaying)
        #expect(model.positionText == model.durationText)
        // The callback changed model state; it did not play or seek the item.
        #expect(fixture.player.rate == 0)
        #expect(fixture.player.currentTime().seconds == 0)
    }

    @Test("Detach fences queued and later item ends and leaves no retained model")
    func detachFencesLateEndsAndReleasesModel() async throws {
        let fixture = PlayerFixture(duration: 13)
        var model: MeetingAudioPlaybackModel? = MeetingAudioPlaybackModel()
        weak var releasedModel = model
        let liveControl = MeetingAudioPlaybackModel()
        defer { model?.detach(); liveControl.detach() }
        model?.attach(to: fixture.player)
        liveControl.attach(to: fixture.player)
        try #require(model?.canSeek == true)
        let probe = DeliveryProbe(), token = observeDelivery(of: fixture.item, probe: probe)
        defer { NotificationCenter.default.removeObserver(token) }

        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: fixture.item)
        try #require(probe.count == 1)
        model?.detach()
        try await requireEndDelivered(to: liveControl, duration: fixture.duration)
        #expect(model?.currentTime == 0 && model?.duration == 0 && model?.displayTime == 0)
        #expect(model?.canSeek == false && model?.isPlaying == false && model?.isScrubbing == false)

        // Exercise a notification posted after removal, with a fresh positive
        // control receipt so an absent delivery cannot masquerade as fencing.
        liveControl.detach()
        liveControl.attach(to: fixture.player)
        try #require(liveControl.currentTime == 0)
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: fixture.item)
        try #require(probe.count == 2)
        try await requireEndDelivered(to: liveControl, duration: fixture.duration)
        #expect(model?.currentTime == 0 && model?.duration == 0 && model?.canSeek == false)
        model = nil
        await mainQueueTurn()
        #expect(releasedModel == nil)
        #expect(fixture.player.rate == 0)
    }

    @Test("The transport exposes a measured timeline and clamps both skips")
    func transportTimelineAndSkipsRespectDuration() async throws {
        let fixture = PlayerFixture(duration: 65)
        let model = MeetingAudioPlaybackModel()
        defer { model.detach() }
        model.attach(to: fixture.player)
        try #require(model.canSeek)
        #expect(model.duration == 65)
        #expect(model.positionText == "00:00")
        #expect(model.durationText == "01:05")
        #expect(model.accessibilityPosition == "00:00 / 01:05")
        model.skip(by: 100)
        #expect(model.displayTime == 65)
        #expect(model.positionText == "01:05")
        model.skip(by: -100)
        #expect(model.displayTime == 0)
        #expect(model.positionText == "00:00")
    }

    @Test("A player with no item still offers close and an honest unknown timeline")
    func emptyPlayerIsNotPresentedAsSeekable() {
        let model = MeetingAudioPlaybackModel()
        defer { model.detach() }
        model.attach(to: AVPlayer())
        #expect(!model.canSeek)
        #expect(model.duration == 0)
        #expect(model.durationText == "--:--")
        #expect(model.positionText == "00:00")
        model.beginScrubbing()
        model.updateScrub(10)
        #expect(model.displayTime == 0)
        #expect(!model.isScrubbing)
    }

    @Test("Backgrounding ends a scrub without committing a new position")
    func backgroundingEndsScrub() async throws {
        let fixture = PlayerFixture(duration: 40)
        let model = MeetingAudioPlaybackModel()
        defer { model.detach() }
        model.attach(to: fixture.player)
        try #require(model.canSeek)
        model.beginScrubbing()
        model.updateScrub(12)
        #expect(model.isScrubbing && model.displayTime == 12)
        model.pauseForBackground()
        #expect(!model.isScrubbing)
        #expect(model.displayTime == model.currentTime)
        #expect(model.currentTime == 0)
    }
}

@Suite("Meeting transcript draft presentation", .serialized)
struct MeetingTranscriptDraftPresentationTests {
    private func fragment(_ text: String, start: Double? = 0, end: Double? = 1,
                          id: UUID = UUID(), final: Bool = true,
                          meetingID: UUID, sessionID: UUID) -> MeetingTranscriptFragment {
        .init(id: id, meetingID: meetingID, sessionID: sessionID, speakerID: nil,
              start: start, end: end, text: text, isFinal: final)
    }

    @Test("Live partial revisions never become confirmed bubbles")
    func confirmedTranscriptIgnoresLiveDraft() {
        let meetingID = UUID(), sessionID = UUID()
        let first = fragment("First sentence.", start: 0, end: 1,
                             meetingID: meetingID, sessionID: sessionID)
        let draftID = UUID()
        let old = fragment("Hel", start: nil, end: nil, id: draftID, final: false,
                           meetingID: meetingID, sessionID: sessionID)
        let new = fragment("Hello", start: nil, end: nil, id: draftID, final: false,
                           meetingID: meetingID, sessionID: sessionID)
        let confirmed = MeetingTranscriptPresentation.confirmedBubbles([first, old, new])
        #expect(confirmed.count == 1)
        #expect(confirmed.first?.text == "First sentence.")
        #expect(confirmed.first?.hasLiveTail == false)
        let revised = MeetingTranscriptPresentation.confirmedBubbles([first, new])
        #expect(revised == confirmed)
        // The general projection still keeps a live tail for callers that
        // explicitly choose to render it; only the confirmed API is stable.
        let withDraft = MeetingTranscriptPresentation.bubbles([first, old, new])
        #expect(withDraft.count == 1)
        #expect(withDraft.first?.hasLiveTail == true)
        #expect(withDraft.first?.text == "First sentence. Hello")
        // A draft from another capture must remain separate, even within the
        // same meeting. Do not weaken that production ownership boundary to
        // make a fixture with random per-fragment sessions coalesce.
        let anotherCapture = fragment("Other recording", start: nil, end: nil, final: false,
                                      meetingID: meetingID, sessionID: UUID())
        let isolated = MeetingTranscriptPresentation.bubbles([first, anotherCapture])
        #expect(isolated.count == 2)
        #expect(isolated.first?.hasLiveTail == false)
        #expect(isolated.last?.hasLiveTail == true)
    }

    @Test("Live draft rejects replacement/control text without altering real speech")
    func liveDraftIsAReadableProjection() {
        #expect(MeetingTranscriptPresentation.liveDraft("  hello  ") == "hello")
        #expect(MeetingTranscriptPresentation.liveDraft("你好，世界") == "你好，世界")
        #expect(MeetingTranscriptPresentation.liveDraft("\u{FFFD}") == nil)
        #expect(MeetingTranscriptPresentation.liveDraft("\u{0}hello") == nil)
        #expect(MeetingTranscriptPresentation.liveDraft("...") == nil)
        #expect(MeetingTranscriptPresentation.liveDraft("   ") == nil)
        #expect(MeetingTranscriptPresentation.liveDraft(nil) == nil)
    }
}
#endif

#if canImport(UIKit)
import FloeMeetings
import FloeMeetingsAV

@MainActor @Suite("Meeting continuous recording materials", .serialized)
struct MeetingRecordingMaterialsTests {
    /// Writes through the production continuous-original/chunk recorder, with
    /// synthetic PCM only. No microphone, provider or audio-session activation.
    private actor PCMBackend: MeetingCaptureBackend {
        let seconds: Int
        let value: Float
        var writer: MeetingPCMChunkRecorder?
        var session: CaptureSessionID?
        var sink: (@Sendable (CaptureEvent) -> Void)?
        private(set) var chunks: [MeetingPCMChunk] = []
        init(seconds: Int, value: Float) { self.seconds = seconds; self.value = value }
        func begin(session: CaptureSessionID, configuration: CaptureConfiguration,
                   sink: @escaping @Sendable (CaptureEvent) -> Void) async throws {
            self.session = session; self.sink = sink
            let writer = try MeetingPCMChunkRecorder(configuration: configuration, session: session, chunkSeconds: 3)
            self.writer = writer
            let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
            buffer.frameLength = 16_000
            let data = try #require(buffer.floatChannelData?[0])
            for index in 0..<16_000 { data[index] = value }
            let frame = try MeetingPCMFrame(copying: buffer)
            sink(.started(session: session))
            for _ in 0..<seconds {
                if let chunk = try await writer.append(frame) {
                    chunks.append(chunk); sink(.chunkFinalized(session: session, file: chunk.file, range: chunk.range))
                }
            }
        }
        func requestStop() async {
            guard let writer, let session, let sink else { return }
            do {
                if let chunk = try await writer.finish() {
                    chunks.append(chunk); sink(.chunkFinalized(session: session, file: chunk.file, range: chunk.range))
                }
                self.writer = nil
                sink(.stopped(session: session, reason: .userStopped))
            } catch { sink(.failed(session: session, message: error.localizedDescription)) }
        }
        func cancel() async { await writer?.cancel(); writer = nil }
    }

    private func decodedSamples(_ asset: AVAsset) async throws -> [Int16] {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1
        ])
        try #require(reader.canAdd(output)); reader.add(output)
        try #require(reader.startReading())
        var samples: [Int16] = []
        while let buffer = output.copyNextSampleBuffer() {
            let block = try #require(CMSampleBufferGetDataBuffer(buffer))
            let count = CMBlockBufferGetDataLength(block)
            try #require(count <= 1_048_576 && count.isMultiple(of: 2))
            var bytes = [UInt8](repeating: 0, count: count)
            let code = bytes.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: $0.baseAddress!)
            }
            try #require(code == kCMBlockBufferNoErr)
            for index in stride(from: 0, to: count, by: 2) {
                samples.append(Int16(bitPattern: UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8))
            }
            try #require(samples.count <= 100_000)
        }
        try #require(reader.status == .completed)
        return samples
    }

    @Test("Pause/resume originals reopen as one decoded, gap-free, seekable recording")
    func realOriginalsPauseResumePersistAndPlayOneMeasuredTimeline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-materials-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("meeting.sqlite")
        let service = MeetingService(database: try MeetingDatabase(path: file.path))
        let meeting = try await service.createMeeting(title: "Continuous original")
        let configuration = CaptureConfiguration(directory: root.appendingPathComponent("Recordings"))
        let firstBackend = PCMBackend(seconds: 2, value: 0.125), secondBackend = PCMBackend(seconds: 3, value: -0.25)
        let first = try await service.startCapture(meeting: meeting, backend: firstBackend, configuration: configuration)
        _ = try await service.pauseCapture()
        let second = try await service.startCapture(meeting: meeting, backend: secondBackend, configuration: configuration,
                                                   continuingRecording: first.rawValue)
        _ = try await service.stopCapture()
        let firstChunks = await firstBackend.chunks
        let chunk = try #require(firstChunks.first)
        let analysis = try await service.importFile(meeting: meeting, file: chunk.file, kind: .importedAudio,
                                                   origin: first, duration: AudioFileProbe.durationRange)
        for session in [first, second] {
            let original = try MeetingPCMChunkRecorder.originalURL(configuration: configuration, session: session)
            let range = try await AudioFileProbe.durationRange(original)
            try await service.recordCapturedDuration(range.end - range.start, session: session, meeting: meeting)
        }
        let reopened = MeetingService(database: try MeetingDatabase(path: file.path))
        let takes = try await reopened.recordingTakes(meeting: meeting)
        let rows = try await reopened.sessions(meeting: meeting)
        let materials = MeetingRecordingMaterial.project(takes: takes, visibleSources: rows)
        try #require(materials.count == 1)
        #expect(materials[0].parts.map(\.id) == [first, second])
        #expect(materials[0].parts.map(\.durationSeconds) == [2, 3])
        #expect(materials[0].canPlay && materials[0].state == .finished)
        #expect(!materials.flatMap(\.parts).contains { $0.id == analysis })
        #expect(!materials[0].title.contains(first.description))
        let sources = try materials[0].parts.map {
            MeetingRecordingPlayback.Source(session: $0.id,
                file: try MeetingPCMChunkRecorder.originalURL(configuration: configuration, session: $0.id))
        }
        let before = try sources.map { try Data(contentsOf: $0.file) }
        let prepared = try await MeetingRecordingPlayback.prepare(sources: sources, root: root)
        let duration = try await prepared.item.asset.load(.duration).seconds
        #expect(abs(duration - 5) < 0.005)
        #expect(abs(prepared.timeline.duration - 5) < 0.005)
        #expect(abs(try #require(prepared.timeline.time(session: second, localTime: 1)) - 3) < 0.005)
        let location = try #require(prepared.timeline.capture(at: 4.5))
        #expect(location.session == second && abs(location.time - 2.5) < 0.005)
        let decoded = try await decodedSamples(prepared.item.asset)
        try #require(abs(decoded.count - 80_000) <= 16)
        #expect(decoded.prefix(1_000).allSatisfy { $0 > 3_000 })
        #expect(decoded.suffix(1_000).allSatisfy { $0 < -6_000 })
        #expect(decoded.filter { abs(Int($0)) < 100 }.count <= 16, "There must be no inserted pause gap")
        #expect(try sources.map { try Data(contentsOf: $0.file) } == before)
    }

    @Test("Missing part fails full playback; cancellation, retry and originals remain real")
    func missingPartCannotBecomeShortFullPlaybackAndRetryPreservesOriginals() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-missing-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        let values = try #require(buffer.floatChannelData?[0])
        for index in 0..<16_000 { values[index] = 0.125 }
        var sources: [MeetingRecordingPlayback.Source] = []
        for index in 0..<3 {
            let file = root.appendingPathComponent("original-\(index).wav")
            do { let writer = try AVAudioFile(forWriting: file, settings: format.settings); try writer.write(from: buffer) }
            sources.append(.init(session: CaptureSessionID(), file: file))
        }
        let originalBytes = try sources.map { try Data(contentsOf: $0.file) }
        try FileManager.default.removeItem(at: sources[1].file)
        do {
            _ = try await MeetingRecordingPlayback.prepare(sources: sources, root: root)
            Issue.record("Missing middle original must not silently produce a shorter full recording")
        } catch { }
        #expect(try Data(contentsOf: sources[0].file) == originalBytes[0])
        #expect(try Data(contentsOf: sources[2].file) == originalBytes[2])
        let single = try await MeetingRecordingPlayback.prepare(sources: [sources[0]], root: root)
        #expect(abs(single.timeline.duration - 1) < 0.005)
        try originalBytes[1].write(to: sources[1].file)
        let cancelled = Task { try await MeetingRecordingPlayback.prepare(sources: sources, root: root) }
        cancelled.cancel()
        do { _ = try await cancelled.value; Issue.record("Cancelled preparation must not publish a player") }
        catch is CancellationError { }
        let retried = try await MeetingRecordingPlayback.prepare(sources: sources, root: root)
        #expect(abs(retried.timeline.duration - 3) < 0.005)
        #expect(try sources.map { try Data(contentsOf: $0.file) } == originalBytes)
    }
}
#endif
