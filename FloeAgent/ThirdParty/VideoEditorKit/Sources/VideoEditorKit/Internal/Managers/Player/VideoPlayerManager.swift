//
//  VideoPlayerManager.swift
//  VideoEditorKit
//
//  Created by Adriano Souza Costa on 23.03.2026.
//

import AVKit
import Combine
@preconcurrency import CoreImage
import Foundation
import Observation
import PhotosUI
import SwiftUI

struct VideoPlayerManagerDependencies: Sendable {

    // MARK: - Public Properties

    let makeVideoComposition: @Sendable (AVAsset, ColorAdjusts) async throws -> AVVideoComposition

    static let live = Self(
        makeVideoComposition: { asset, colorAdjusts in
            try await asset.makeVideoComposition(applying: colorAdjusts)
        }
    )

}

@MainActor
@Observable
final class VideoPlayerManager {

    // MARK: - Public Properties

    var currentTime: Double = .zero

    @ObservationIgnored
    private(set) var videoPlayer = AVPlayer()

    @ObservationIgnored
    private(set) var audioPlayer = AVPlayer()

    private(set) var isPlaying = false
    private(set) var isPlaybackFocusActive = false
    private(set) var isPreviewReadyForDisplay = false

    var loadState: LoadState = .unknown {
        didSet {
            guard loadState != oldValue else { return }
            handleLoadStateChange(loadState)
        }
    }

    var scrubState: PlayerScrubState = .reset

    // MARK: - Private Properties

    @ObservationIgnored
    private var isSetAudio = false

    @ObservationIgnored
    private var statusCancellable: AnyCancellable?

    @ObservationIgnored
    private var itemStatusCancellable: AnyCancellable?

    @ObservationIgnored
    private var timeObserver: Any?

    @ObservationIgnored
    private var currentDurationRange: ClosedRange<Double>?

    @ObservationIgnored
    private var currentPlaybackRate: Float = 1

    @ObservationIgnored
    private var currentOriginalDuration: Double = .zero

    @ObservationIgnored
    private var endPlaybackObserver: NSObjectProtocol?

    @ObservationIgnored
    private var adjustsCompositionTask: Task<Void, Never>?

    @ObservationIgnored
    private var pendingPlaybackTask: Task<Void, Never>?

    @ObservationIgnored
    private var previewColorAdjusts = ColorAdjusts()

    @ObservationIgnored
    private var appliedAdjustsSignature: String?

    @ObservationIgnored
    private var appliedAdjustsItemID: ObjectIdentifier?

    @ObservationIgnored
    private var loadedVideoURL: URL?

    @ObservationIgnored
    private var loadedAudioURL: URL?

    @ObservationIgnored
    private var adjustsCompositionGeneration = 0

    @ObservationIgnored
    private var playbackInteractionDepth = 0

    @ObservationIgnored
    private var shouldResumeAfterPlaybackInteraction = false

    private let playbackRestartTolerance = 0.05
    private let dependencies: VideoPlayerManagerDependencies

    // MARK: - Initializer

    init(_ dependencies: VideoPlayerManagerDependencies = .live) {
        self.dependencies = dependencies
    }

    // MARK: - Public Methods

    func action(_ video: Video) {
        syncPlaybackState(with: video)

        if isPlaying {
            pause()
        } else {
            isPlaybackFocusActive = true
            play()
        }
    }

    func syncPlaybackState(with video: Video, previousRate: Float? = nil) {
        let referenceRate = normalizedPlaybackRate(previousRate ?? currentPlaybackRate)

        currentDurationRange = video.outputRangeDuration
        currentPlaybackRate = normalizedPlaybackRate(video.rate)
        currentOriginalDuration = max(video.originalDuration, .zero)

        setAudio(video.audio?.url)

        videoPlayer.volume = video.volume
        audioPlayer.volume = video.audio?.volume ?? 1

        let clampedTime = video.timelineTimePreservingSourcePosition(
            currentTime,
            fromRate: referenceRate
        )

        currentTime = clampedTime

        guard !isPlaying else { return }

        seek(sourceTime(forTimelineTime: clampedTime), player: videoPlayer)
        if isSetAudio {
            seek(sourceTime(forTimelineTime: clampedTime), player: audioPlayer)
        }
    }

    func setAudio(_ url: URL?) {
        guard let url else {
            isSetAudio = false
            loadedAudioURL = nil
            audioPlayer.pause()
            audioPlayer.replaceCurrentItem(with: nil)
            return
        }

        guard loadedAudioURL != url || audioPlayer.currentItem == nil else {
            isSetAudio = true
            return
        }

        audioPlayer.replaceCurrentItem(with: AVPlayerItem(url: url))
        loadedAudioURL = url
        isSetAudio = true
    }

    func pause(
        maintainingPlaybackFocus: Bool = false
    ) {
        pendingPlaybackTask?.cancel()
        pendingPlaybackTask = nil

        videoPlayer.pause()

        if isSetAudio { audioPlayer.pause() }

        isPlaying = false
        isPlaybackFocusActive = maintainingPlaybackFocus
        syncCurrentTimeFromPlayer()
    }

    func setVolume(_ isVideo: Bool, value: Float) {
        pause()

        if isVideo {
            videoPlayer.volume = value
        } else {
            audioPlayer.volume = value
        }
    }

    func updatePlaybackRange(_ range: ClosedRange<Double>) {
        currentDurationRange = range

        let playbackTime = videoPlayer.currentTime().seconds
        let referenceTime = playbackTime.isFinite ? timelineTime(fromSourceTime: playbackTime) : currentTime
        let clampedTime = referenceTime.clamped(to: range)

        currentTime = clampedTime

        guard !playbackTime.isFinite || abs(referenceTime - clampedTime) > 0.01 else { return }

        seek(sourceTime(forTimelineTime: clampedTime), player: videoPlayer)
        if isSetAudio {
            seek(sourceTime(forTimelineTime: clampedTime), player: audioPlayer)
        }
    }

    func beginPlaybackInteraction() {
        if playbackInteractionDepth == 0 {
            shouldResumeAfterPlaybackInteraction = isPlaying
        }

        playbackInteractionDepth += 1
        pause(
            maintainingPlaybackFocus: shouldResumeAfterPlaybackInteraction
        )
    }

    func endPlaybackInteraction(
        resumeAt time: Double? = nil,
        in range: ClosedRange<Double>? = nil
    ) {
        if let range {
            currentDurationRange = range
        }

        if let time {
            let clampedTime = clampedInteractionTime(
                time,
                in: range ?? currentDurationRange
            )
            currentTime = clampedTime

            seek(sourceTime(forTimelineTime: clampedTime), player: videoPlayer)

            if isSetAudio {
                seek(sourceTime(forTimelineTime: clampedTime), player: audioPlayer)
            }
        }

        guard playbackInteractionDepth > 0 else { return }
        playbackInteractionDepth -= 1

        guard playbackInteractionDepth == 0 else { return }

        let shouldResume = shouldResumeAfterPlaybackInteraction
        shouldResumeAfterPlaybackInteraction = false

        guard shouldResume else {
            isPlaybackFocusActive = false
            return
        }

        isPlaybackFocusActive = true

        play()
    }

    func beginScrubbing(in range: ClosedRange<Double>) {
        currentDurationRange = range
        scrubState = .scrubStarted
        beginPlaybackInteraction()
    }

    func scrub(to time: Double, in range: ClosedRange<Double>) {
        currentDurationRange = range

        let clampedTime = time.clamped(to: range)

        currentTime = clampedTime
        seek(sourceTime(forTimelineTime: clampedTime), player: videoPlayer)

        if isSetAudio {
            seek(sourceTime(forTimelineTime: clampedTime), player: audioPlayer)
        }
    }

    func endScrubbing(at time: Double, in range: ClosedRange<Double>) {
        currentDurationRange = range

        let clampedTime = time.clamped(to: range)

        currentTime = clampedTime
        scrubState = .scrubEnded(clampedTime)
        endPlaybackInteraction(
            resumeAt: clampedTime,
            in: range
        )
    }

    // MARK: - Private Methods

    private func handleLoadStateChange(_ loadState: LoadState) {
        switch loadState {
        case .loaded(let url):
            isPreviewReadyForDisplay = false
            pause()
            cleanupObservers()
            currentDurationRange = nil
            currentPlaybackRate = 1
            currentOriginalDuration = .zero
            currentTime = .zero

            let previousLoadedVideoURL = loadedVideoURL
            loadedVideoURL = url

            if previousLoadedVideoURL != url || videoPlayer.currentItem == nil {
                videoPlayer.replaceCurrentItem(with: AVPlayerItem(url: url))
            } else if (videoPlayer.currentItem?.asset as? AVURLAsset)?.url != url {
                videoPlayer.replaceCurrentItem(with: AVPlayerItem(url: url))
            }

            startStatusSubscriptions()
            appliedAdjustsItemID = nil
            applyCurrentColorAdjustsComposition()
        case .failed, .loading, .unknown:
            isPreviewReadyForDisplay = false
        }
    }

    private func startStatusSubscriptions() {
        statusCancellable?.cancel()
        statusCancellable = videoPlayer.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self = self else { return }
                switch status {
                case .playing:
                    self.isPlaying = true
                    self.isPlaybackFocusActive = true
                    self.startTimer()
                case .paused:
                    self.isPlaying = false
                case .waitingToPlayAtSpecifiedRate:
                    break
                @unknown default:
                    break
                }
            }

        itemStatusCancellable?.cancel()
        itemStatusCancellable = videoPlayer.currentItem?.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.isPreviewReadyForDisplay = status == .readyToPlay
            }
        isPreviewReadyForDisplay = videoPlayer.currentItem?.status == .readyToPlay
    }

    private func play() {
        AVAudioSession.sharedInstance().configurePlaybackSession()

        pendingPlaybackTask?.cancel()

        var startTime = currentTime

        if let currentDurationRange {
            let currentPlaybackTime = timelineTime(fromSourceTime: videoPlayer.currentTime().seconds)
            let targetTime = currentTime.clamped(to: currentDurationRange)
            let isAtOrPastRangeEnd =
                targetTime >= (currentDurationRange.upperBound - playbackRestartTolerance)
                || (currentPlaybackTime.isFinite
                    && currentPlaybackTime >= (currentDurationRange.upperBound - playbackRestartTolerance))
            let shouldSeekToRangeStart =
                !currentPlaybackTime.isFinite
                || !currentDurationRange.contains(targetTime)
                || currentPlaybackTime < currentDurationRange.lowerBound
                || isAtOrPastRangeEnd

            if shouldSeekToRangeStart {
                startTime = currentDurationRange.lowerBound
            } else {
                startTime = targetTime
            }
        }

        currentTime = startTime
        isPlaying = true

        let playbackStartTime = startTime

        pendingPlaybackTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let sourcePlaybackTime = self.sourceTime(forTimelineTime: playbackStartTime)

            await self.seek(sourcePlaybackTime, player: self.videoPlayer)

            if self.isSetAudio {
                await self.seek(sourcePlaybackTime, player: self.audioPlayer)
            }

            guard !Task.isCancelled else { return }

            self.videoPlayer.play()

            if self.isSetAudio {
                self.audioPlayer.play()
                self.audioPlayer.rate = self.currentPlaybackRate
            }

            self.videoPlayer.rate = self.currentPlaybackRate
            self.registerPlaybackObserverIfNeeded()
            self.pendingPlaybackTask = nil
        }
    }

    private func seek(_ seconds: Double, player: AVPlayer) {
        player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    private func seek(_ seconds: Double, player: AVPlayer) async {
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

    private func startTimer() {
        removeTimeObserver()

        let interval = CMTimeMake(value: 1, timescale: 30)

        timeObserver = videoPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) {
            [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if self.isPlaying {
                    let playbackTime = time.seconds
                    let resolvedTime = self.resolvedCurrentTime(from: playbackTime)

                    if let currentDurationRange = self.currentDurationRange,
                        playbackTime >= self.sourceTime(forTimelineTime: currentDurationRange.upperBound)
                    {
                        self.currentTime = currentDurationRange.upperBound
                        self.pause()
                        return
                    }

                    switch self.scrubState {
                    case .reset:
                        self.currentTime = resolvedTime
                    case .scrubEnded:
                        self.scrubState = .reset
                    case .scrubStarted:
                        break
                    }
                }
            }
        }
    }

    private func registerPlaybackObserverIfNeeded() {
        removeEndPlaybackObserver()

        guard let currentDurationRange,
            videoPlayer.currentItem?.duration.seconds ?? 0
                >= sourceTime(forTimelineTime: currentDurationRange.upperBound)
        else {
            return
        }

        endPlaybackObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: videoPlayer.currentItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.playerDidFinishPlaying()
            }
        }
    }

    private func playerDidFinishPlaying() {
        let restartTime = currentDurationRange?.lowerBound ?? .zero

        pause()

        seek(sourceTime(forTimelineTime: restartTime), player: videoPlayer)

        if isSetAudio {
            seek(sourceTime(forTimelineTime: restartTime), player: audioPlayer)
        }

        currentTime = restartTime
    }

    private func removeTimeObserver() {
        if let timeObserver = timeObserver {
            videoPlayer.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }

    private func removeEndPlaybackObserver() {
        if let endPlaybackObserver {
            NotificationCenter.default.removeObserver(endPlaybackObserver)
            self.endPlaybackObserver = nil
        }
    }

    private func cleanupObservers() {
        pendingPlaybackTask?.cancel()
        pendingPlaybackTask = nil
        removeTimeObserver()
        removeEndPlaybackObserver()
        statusCancellable?.cancel()
        statusCancellable = nil
        itemStatusCancellable?.cancel()
        itemStatusCancellable = nil
        adjustsCompositionTask?.cancel()
        adjustsCompositionTask = nil
    }

    private func resolvedCurrentTime(from playbackTime: Double) -> Double {
        guard playbackTime.isFinite else {
            return currentDurationRange.map { currentTime.clamped(to: $0) } ?? currentTime
        }

        let timelinePlaybackTime = timelineTime(fromSourceTime: playbackTime)

        guard let currentDurationRange else { return timelinePlaybackTime }

        return timelinePlaybackTime.clamped(to: currentDurationRange)
    }

    private func syncCurrentTimeFromPlayer() {
        currentTime = resolvedCurrentTime(from: videoPlayer.currentTime().seconds)
    }

    private func normalizedPlaybackRate(_ rate: Float) -> Float {
        guard rate.isFinite, rate > 0 else { return 1 }
        return rate
    }

    private func clampedInteractionTime(
        _ time: Double,
        in range: ClosedRange<Double>?
    ) -> Double {
        guard let range else { return time }
        return time.clamped(to: range)
    }

    private func sourceTime(forTimelineTime time: Double) -> Double {
        PlaybackTimeMapping.sourceTime(
            forTimelineTime: time,
            rate: currentPlaybackRate,
            originalDuration: currentOriginalDuration
        )
    }

    private func timelineTime(fromSourceTime time: Double) -> Double {
        PlaybackTimeMapping.timelineTime(
            fromSourceTime: time,
            rate: currentPlaybackRate
        )
    }

}

extension VideoPlayerManager {

    // MARK: - Public Methods

    func setColorAdjusts(_ colorAdjusts: ColorAdjusts?) {
        previewColorAdjusts = colorAdjusts ?? .init()
        applyCurrentColorAdjustsComposition()
    }

    func clearColorAdjusts() {
        guard !previewColorAdjusts.isIdentity || adjustsCompositionTask != nil else { return }

        previewColorAdjusts = .init()
        applyCurrentColorAdjustsComposition()
    }

    // MARK: - Private Methods

    private func applyCurrentColorAdjustsComposition() {
        adjustsCompositionTask?.cancel()
        adjustsCompositionGeneration += 1

        let generation = adjustsCompositionGeneration

        guard let currentItem = videoPlayer.currentItem else {
            appliedAdjustsSignature = nil
            appliedAdjustsItemID = nil
            return
        }

        let currentItemID = ObjectIdentifier(currentItem)
        let signature = currentColorAdjustsSignature()

        if signature == nil {
            guard appliedAdjustsSignature != nil || appliedAdjustsItemID != currentItemID else {
                return
            }

            pause()

            currentItem.videoComposition = nil
            refreshCurrentVideoFrame()
            appliedAdjustsSignature = nil
            appliedAdjustsItemID = currentItemID

            return
        }

        guard appliedAdjustsSignature != signature || appliedAdjustsItemID != currentItemID else {
            return
        }

        let colorAdjusts = previewColorAdjusts

        pause()

        adjustsCompositionTask = Task { [weak self] in
            guard
                let self,
                let composition = try? await self.dependencies.makeVideoComposition(
                    currentItem.asset,
                    colorAdjusts
                )
            else {
                return
            }

            await MainActor.run {
                guard self.adjustsCompositionGeneration == generation else { return }
                guard self.videoPlayer.currentItem === currentItem else { return }
                currentItem.videoComposition = composition
                self.refreshCurrentVideoFrame()
                self.appliedAdjustsSignature = signature
                self.appliedAdjustsItemID = currentItemID
            }
        }
    }

    private func refreshCurrentVideoFrame() {
        let currentPlaybackTime = videoPlayer.currentTime().seconds
        let resolvedTime =
            currentPlaybackTime.isFinite
            ? currentPlaybackTime
            : sourceTime(forTimelineTime: currentTime)

        seek(resolvedTime, player: videoPlayer)
    }

    private func currentColorAdjustsSignature() -> String? {
        guard !previewColorAdjusts.isIdentity else { return nil }

        return [
            String(previewColorAdjusts.brightness),
            String(previewColorAdjusts.contrast),
            String(previewColorAdjusts.saturation),
        ]
        .joined(separator: "|")
    }

}

extension AVAsset {

    // MARK: - Public Methods

    func makeVideoComposition(applying colorAdjusts: ColorAdjusts) async throws -> AVVideoComposition {
        try await makeVideoComposition(
            filterChain: Helpers.createColorAdjustsFilters(colorAdjusts: colorAdjusts)
        )
    }

    func makeVideoComposition(applying filters: [CIFilter]) async throws -> AVVideoComposition {
        try await makeVideoComposition(filterChain: filters)
    }

    // MARK: - Private Methods

    private func makeVideoComposition(
        filterChain filters: [CIFilter]
    ) async throws -> AVVideoComposition {
        try await withCheckedThrowingContinuation { continuation in
            AVVideoComposition.videoComposition(
                with: self,
                applyingCIFiltersWithHandler: { request in

                    let source = request.sourceImage
                    var output = source

                    for filter in filters {
                        filter.setValue(output, forKey: kCIInputImageKey)
                        if let image = filter.outputImage {
                            output = image
                        }
                    }

                    request.finish(with: output, context: nil)
                },
                completionHandler: { composition, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let composition {
                        continuation.resume(returning: composition)
                    } else {
                        continuation.resume(throwing: VideoCompositionError.creationFailed)
                    }
                })
        }
    }

}
