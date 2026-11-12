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
}
#endif
