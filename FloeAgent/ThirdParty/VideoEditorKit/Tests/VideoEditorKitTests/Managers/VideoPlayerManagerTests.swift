import AVFoundation
import CoreImage
import Foundation
import Testing

@testable import VideoEditorKit

@MainActor
@Suite("VideoPlayerManagerTests", .serialized)
struct VideoPlayerManagerTests {

    // MARK: - Public Methods

    @Test
    func initialStateStartsIdle() {
        let manager = VideoPlayerManager()

        #expect(manager.currentTime == 0)
        #expect(manager.loadState == .unknown)
        #expect(manager.isPlaying == false)
        if case .reset = manager.scrubState {
            #expect(Bool(true))
        } else {
            Issue.record("Expected scrubState to start at .reset.")
        }
    }

    @Test
    func loadStateLoadedResetsPlaybackStateAndLoadsTheRequestedURL() async throws {
        let manager = VideoPlayerManager()
        let videoURL = try await TestFixtures.createTemporaryVideo()
        defer { FileManager.default.removeIfExists(for: videoURL) }

        manager.currentTime = 42
        manager.loadState = .loaded(videoURL)

        let currentAssetURL = (manager.videoPlayer.currentItem?.asset as? AVURLAsset)?.url

        #expect(manager.currentTime == 0)
        #expect(currentAssetURL == videoURL)
    }

    @Test
    func loadStateLoadedKeepsTheSameVideoPlayerInstance() async throws {
        let manager = VideoPlayerManager()
        let initialPlayerID = ObjectIdentifier(manager.videoPlayer)
        let firstVideoURL = try await TestFixtures.createTemporaryVideo(color: .systemBlue)
        let secondVideoURL = try await TestFixtures.createTemporaryVideo(color: .systemGreen)
        defer {
            FileManager.default.removeIfExists(for: firstVideoURL)
            FileManager.default.removeIfExists(for: secondVideoURL)
        }

        manager.loadState = .loaded(firstVideoURL)
        manager.loadState = .loaded(secondVideoURL)

        #expect(ObjectIdentifier(manager.videoPlayer) == initialPlayerID)
        #expect((manager.videoPlayer.currentItem?.asset as? AVURLAsset)?.url == secondVideoURL)
    }

    @Test
    func setAudioNilClearsTheAuxiliaryPlayerItem() throws {
        let manager = VideoPlayerManager()
        let audioURL = try TestFixtures.createTemporaryAudio()
        defer { FileManager.default.removeIfExists(for: audioURL) }

        manager.setAudio(audioURL)
        #expect((manager.audioPlayer.currentItem?.asset as? AVURLAsset)?.url == audioURL)

        manager.setAudio(nil)

        #expect(manager.audioPlayer.currentItem == nil)
    }

    @Test
    func setAudioKeepsTheSameAuxiliaryPlayerInstance() throws {
        let manager = VideoPlayerManager()
        let initialPlayerID = ObjectIdentifier(manager.audioPlayer)
        let firstAudioURL = try TestFixtures.createTemporaryAudio()
        let secondAudioURL = try TestFixtures.createTemporaryAudio()
        defer {
            FileManager.default.removeIfExists(for: firstAudioURL)
            FileManager.default.removeIfExists(for: secondAudioURL)
        }

        manager.setAudio(firstAudioURL)
        manager.setAudio(secondAudioURL)
        manager.setAudio(nil)

        #expect(ObjectIdentifier(manager.audioPlayer) == initialPlayerID)
        #expect(manager.audioPlayer.currentItem == nil)
    }

    @Test
    func setAudioWithTheSameURLDoesNotReplaceTheCurrentItem() throws {
        let manager = VideoPlayerManager()
        let audioURL = try TestFixtures.createTemporaryAudio()
        defer { FileManager.default.removeIfExists(for: audioURL) }

        manager.setAudio(audioURL)
        let currentItem = try #require(manager.audioPlayer.currentItem)

        manager.setAudio(audioURL)

        #expect(manager.audioPlayer.currentItem === currentItem)
    }

    @Test
    func syncPlaybackStateRemapsCurrentTimeAndCopiesTrackVolumes() throws {
        let manager = VideoPlayerManager()
        let audioURL = try TestFixtures.createTemporaryAudio()
        defer { FileManager.default.removeIfExists(for: audioURL) }

        manager.currentTime = 60

        var video = Video.mock
        video.rangeDuration = 20...80
        video.rate = 2
        video.volume = 0.4
        video.audio = Audio(url: audioURL, duration: 5, volume: 0.7)

        manager.syncPlaybackState(with: video)

        #expect(abs(manager.currentTime - 30) < 0.0001)
        #expect(abs(Double(manager.videoPlayer.volume) - 0.4) < 0.0001)
        #expect(abs(Double(manager.audioPlayer.volume) - 0.7) < 0.0001)
        #expect((manager.audioPlayer.currentItem?.asset as? AVURLAsset)?.url == audioURL)
    }

    @Test
    func updatePlaybackRangeClampsCurrentTimeIntoTheNewRange() {
        let manager = VideoPlayerManager()
        var video = Video.mock
        video.rangeDuration = 0...100
        manager.syncPlaybackState(with: video)

        manager.currentTime = 95
        manager.updatePlaybackRange(20...80)

        #expect(abs(manager.currentTime - 80) < 0.0001)
    }

    @Test
    func scrubbingStateTracksBeginMoveAndEndOperations() {
        let manager = VideoPlayerManager()
        var video = Video.mock
        video.rangeDuration = 0...100
        manager.syncPlaybackState(with: video)

        manager.beginScrubbing(in: 20...80)
        if case .scrubStarted = manager.scrubState {
            #expect(Bool(true))
        } else {
            Issue.record("Expected scrubState to move to .scrubStarted.")
        }

        manager.scrub(to: 90, in: 20...80)
        #expect(abs(manager.currentTime - 80) < 0.0001)

        manager.endScrubbing(at: 10, in: 20...80)
        #expect(abs(manager.currentTime - 20) < 0.0001)

        if case .scrubEnded(let seekTime) = manager.scrubState {
            #expect(abs(seekTime - 20) < 0.0001)
        } else {
            Issue.record("Expected scrubState to end with the clamped seek time.")
        }
    }

    @Test
    func actionRestartsFromRangeStartWhenTimelineIsAtTheEnd() async throws {
        let manager = VideoPlayerManager()
        let videoURL = try await TestFixtures.createTemporaryVideo(frameCount: 60)
        defer { FileManager.default.removeIfExists(for: videoURL) }

        let video = await Video.load(from: videoURL)

        manager.loadState = .loaded(videoURL)
        manager.syncPlaybackState(with: video)
        manager.currentTime = video.outputRangeDuration.upperBound

        await seek(
            player: manager.videoPlayer,
            to: max(video.originalDuration - 0.02, 0)
        )

        manager.action(video)

        #expect(abs(manager.currentTime - video.outputRangeDuration.lowerBound) < 0.0001)
    }

    @Test
    func actionMarksPlaybackAsActiveImmediatelyWhenStartingPlayback() async throws {
        let manager = VideoPlayerManager()
        let videoURL = try await TestFixtures.createTemporaryVideo(frameCount: 60)
        defer { FileManager.default.removeIfExists(for: videoURL) }

        let video = await Video.load(from: videoURL)

        manager.loadState = .loaded(videoURL)
        manager.syncPlaybackState(with: video)

        manager.action(video)

        #expect(manager.isPlaybackFocusActive)
        #expect(manager.isPlaying)
    }

    @Test
    func playbackInteractionResumesPlaybackWhenTheVideoWasPlaying() async throws {
        let manager = VideoPlayerManager()
        let videoURL = try await TestFixtures.createTemporaryVideo(frameCount: 60)
        defer { FileManager.default.removeIfExists(for: videoURL) }

        let video = await Video.load(from: videoURL)

        manager.loadState = .loaded(videoURL)
        manager.syncPlaybackState(with: video)
        manager.action(video)
        try await waitForPlaybackState(of: manager, isPlaying: true)
        #expect(manager.isPlaybackFocusActive)

        manager.beginPlaybackInteraction()

        #expect(manager.isPlaying == false)
        #expect(manager.isPlaybackFocusActive)

        manager.endPlaybackInteraction()

        try await waitForPlaybackState(of: manager, isPlaying: true)
        #expect(manager.isPlaying)
        #expect(manager.isPlaybackFocusActive)
    }

    @Test
    func playbackInteractionKeepsPlaybackPausedWhenTheVideoWasAlreadyStopped() async throws {
        let manager = VideoPlayerManager()
        let videoURL = try await TestFixtures.createTemporaryVideo(frameCount: 60)
        defer { FileManager.default.removeIfExists(for: videoURL) }

        let video = await Video.load(from: videoURL)

        manager.loadState = .loaded(videoURL)
        manager.syncPlaybackState(with: video)

        manager.beginPlaybackInteraction()
        manager.endPlaybackInteraction()

        try await waitForPlaybackState(of: manager, isPlaying: false)
        #expect(manager.isPlaying == false)
        #expect(manager.isPlaybackFocusActive == false)
    }

    @Test
    func endScrubbingResumesPlaybackFromTheChosenTimeWhenPlaybackWasActive() async throws {
        let manager = VideoPlayerManager()
        let videoURL = try await TestFixtures.createTemporaryVideo(frameCount: 60)
        defer { FileManager.default.removeIfExists(for: videoURL) }

        let video = await Video.load(from: videoURL)
        let scrubRange = 0.2...1.2
        let scrubbedTime = 0.8

        manager.loadState = .loaded(videoURL)
        manager.syncPlaybackState(with: video)
        manager.action(video)
        try await waitForPlaybackState(of: manager, isPlaying: true)

        manager.beginScrubbing(in: scrubRange)
        #expect(manager.isPlaying == false)

        manager.endScrubbing(at: scrubbedTime, in: scrubRange)

        try await waitForPlaybackState(of: manager, isPlaying: true)
        #expect(abs(manager.currentTime - scrubbedTime) < 0.001)
    }

    @Test
    func setVolumeUpdatesTheChosenPlayer() throws {
        let manager = VideoPlayerManager()
        let audioURL = try TestFixtures.createTemporaryAudio()
        defer { FileManager.default.removeIfExists(for: audioURL) }

        manager.setAudio(audioURL)
        manager.setVolume(true, value: 0.25)
        manager.setVolume(false, value: 0.75)

        #expect(abs(Double(manager.videoPlayer.volume) - 0.25) < 0.0001)
        #expect(abs(Double(manager.audioPlayer.volume) - 0.75) < 0.0001)
        #expect(manager.isPlaying == false)
    }

    @Test
    func colorAdjustsControlsAreSafeToCallForLoadedItems() async throws {
        let manager = VideoPlayerManager()
        let videoURL = try await TestFixtures.createTemporaryVideo()
        defer { FileManager.default.removeIfExists(for: videoURL) }

        manager.loadState = .loaded(videoURL)
        manager.setColorAdjusts(
            ColorAdjusts(brightness: 0.1, contrast: 0.2, saturation: 0.3)
        )
        manager.clearColorAdjusts()

        #expect((manager.videoPlayer.currentItem?.asset as? AVURLAsset)?.url == videoURL)
    }

    @Test
    func setColorAdjustsAppliesPreviewCompositionToTheCurrentItem() async throws {
        let manager = VideoPlayerManager()
        let videoURL = try await TestFixtures.createTemporaryVideo()
        defer { FileManager.default.removeIfExists(for: videoURL) }

        manager.loadState = .loaded(videoURL)
        manager.setColorAdjusts(
            ColorAdjusts(brightness: 0.1, contrast: 0.2, saturation: 0.3)
        )

        for _ in 0..<50 where manager.videoPlayer.currentItem?.videoComposition == nil {
            try? await Task.sleep(for: .milliseconds(20))
        }

        #expect(manager.videoPlayer.currentItem?.videoComposition != nil)

        manager.clearColorAdjusts()

        #expect(manager.videoPlayer.currentItem?.videoComposition == nil)
    }

    @Test
    func setColorAdjustsStartsPreviewCompositionImmediately() async throws {
        let compositionRecorder = CompositionBuildRecorder()
        let manager = VideoPlayerManager(
            VideoPlayerManagerDependencies(
                makeVideoComposition: { asset, colorAdjusts in
                    await compositionRecorder.recordBuild()
                    return try await asset.makeVideoComposition(applying: colorAdjusts)
                }
            )
        )
        let videoURL = try await TestFixtures.createTemporaryVideo()
        defer { FileManager.default.removeIfExists(for: videoURL) }

        manager.loadState = .loaded(videoURL)
        manager.setColorAdjusts(ColorAdjusts(brightness: 0.1))

        for _ in 0..<20 where await compositionRecorder.buildCount() == 0 {
            try? await Task.sleep(for: .milliseconds(20))
        }

        #expect(await compositionRecorder.buildCount() == 1)
    }

    @Test
    func clearingColorAdjustsPreventsAnOutdatedPreviewCompositionFromBeingApplied() async throws {
        let compositionContinuation = CompositionContinuation()
        let manager = VideoPlayerManager(
            VideoPlayerManagerDependencies(
                makeVideoComposition: { asset, colorAdjusts in
                    await compositionContinuation.markBuildStarted()
                    await compositionContinuation.waitForResume()
                    return try await asset.makeVideoComposition(applying: colorAdjusts)
                }
            )
        )
        let videoURL = try await TestFixtures.createTemporaryVideo()
        defer { FileManager.default.removeIfExists(for: videoURL) }

        manager.loadState = .loaded(videoURL)
        manager.setColorAdjusts(ColorAdjusts(brightness: 0.2))
        await compositionContinuation.waitUntilStarted()
        manager.clearColorAdjusts()
        await compositionContinuation.resume()

        try? await Task.sleep(for: .milliseconds(80))

        #expect(manager.videoPlayer.currentItem?.videoComposition == nil)
    }

}

private func seek(player: AVPlayer, to seconds: Double) async {
    await withCheckedContinuation { continuation in
        player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { _ in
            continuation.resume()
        }
    }
}

@MainActor
private func waitForPlaybackState(
    of manager: VideoPlayerManager,
    isPlaying expectedIsPlaying: Bool
) async throws {
    for _ in 0..<60 where manager.isPlaying != expectedIsPlaying {
        try await Task.sleep(for: .milliseconds(20))
    }

    #expect(manager.isPlaying == expectedIsPlaying)
}

private actor CompositionBuildRecorder {

    // MARK: - Private Properties

    private var builds = 0

    // MARK: - Public Methods

    func recordBuild() {
        builds += 1
    }

    func buildCount() -> Int {
        builds
    }

}

private actor CompositionContinuation {

    // MARK: - Private Properties

    private var hasStarted = false
    private var hasResumed = false
    private var resumeContinuation: CheckedContinuation<Void, Never>?
    private var startContinuation: CheckedContinuation<Void, Never>?

    // MARK: - Public Methods

    func markBuildStarted() {
        hasStarted = true
        startContinuation?.resume()
        startContinuation = nil
    }

    func waitUntilStarted() async {
        guard hasStarted == false else { return }

        await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
    }

    func waitForResume() async {
        guard hasResumed == false else { return }

        await withCheckedContinuation { continuation in
            resumeContinuation = continuation
        }
    }

    func resume() {
        hasResumed = true
        resumeContinuation?.resume()
        resumeContinuation = nil
    }

}
