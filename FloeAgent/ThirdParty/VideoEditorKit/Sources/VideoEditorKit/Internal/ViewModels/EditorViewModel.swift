//
//  EditorViewModel.swift
//  VideoEditorKit
//
//  Created by Adriano Souza Costa on 23.03.2026.
//

import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class EditorViewModel {

    struct Dependencies {

        // MARK: - Public Properties

        static let live = Self(
            loadVideo: { await Video.load(from: $0) },
            makeThumbnails: { video, containerSize, displayScale in
                await video.makeThumbnails(
                    containerSize: containerSize,
                    displayScale: displayScale
                )
            },
            sleep: { try await Task.sleep(for: $0) }
        )

        let loadVideo: @Sendable (URL) async -> Video
        let makeThumbnails: @Sendable (Video, CGSize, CGFloat) async -> [ThumbnailImage]
        let sleep: @Sendable (Duration) async throws -> Void

    }

    struct ThumbnailLoadRequest: Equatable, Sendable {

        // MARK: - Public Properties

        let videoID: UUID
        let generation: Int

    }

    private enum Constants {
        static let numericTolerance = 0.001
        static let exportPresentationDelay = Duration.milliseconds(200)
        static let toolResetDelay = Duration.milliseconds(100)
    }

    // MARK: - Public Properties

    let presentationState = EditorPresentationState()
    let cropPresentationState = EditorCropPresentationState()

    var currentVideo: Video?
    var frames = VideoFrames()
    var transcriptState: TranscriptFeatureState = .idle
    var transcriptFeatureState: TranscriptFeaturePersistenceState = .idle
    var transcriptDocument: TranscriptDocument?
    var transcriptDraftDocument: TranscriptDocument?

    var hasCurrentVideo: Bool {
        currentVideo != nil
    }

    var isTranscriptionAvailable: Bool {
        transcriptionProvider != nil
    }

    var exportVideo: Video? {
        EditorSessionCoordinator.exportVideo(
            currentVideo: currentVideo,
            isQualitySheetPresented: presentationState.showVideoQualitySheet
        )
    }

    var isMirrorEnabled: Bool {
        currentVideo?.isMirror ?? false
    }

    var cropRotation: Double {
        get { currentVideo?.rotation ?? 0 }
        set { setRotation(newValue) }
    }

    var cropPresentationSummary: EditorCropPresentationSummary {
        cropPresentationSummary()
    }

    // MARK: - Public Methods

    func cropPresentationSummary(
        isPlaybackFocused: Bool = false
    ) -> EditorCropPresentationSummary {
        EditorCropPresentationResolver.makeSummary(
            state: cropEditingState,
            video: currentVideo,
            fallbackContainerSize: lastPlayerContainerSize,
            isPlaybackFocused: isPlaybackFocused
        )
    }

    // MARK: - Private Properties

    private let dependencies: Dependencies
    private let taskCoordinator: EditorTaskCoordinator

    private var enabledTools = Set(ToolEnum.all)
    private var hasLoadedSourceVideo = false
    private var lastPlayerContainerSize = CGSize(width: 1, height: 220)
    private var lastThumbnailDisplayScale: CGFloat = 1
    private var maximumVideoDuration: Double?
    private var pendingEditingConfiguration: VideoEditingConfiguration?
    private var preferredTranscriptLocale: String?
    private var transcriptAvailabilityError: TranscriptError?
    private var transcriptionAvailabilityTask: Task<Void, Never>?
    private var transcriptionComponent: (any VideoTranscriptionComponentProtocol)?
    private var transcriptionProvider: (any VideoTranscriptionProvider)?

    // MARK: - Initializer

    init(_ dependencies: Dependencies = .live) {
        self.dependencies = dependencies
        taskCoordinator = EditorTaskCoordinator(dependencies.sleep)
    }

    // MARK: - Public Methods

    func setNewVideo(
        _ url: URL,
        containerSize: CGSize,
        videoPlayer: VideoPlayerManager? = nil
    ) {
        invalidateThumbnailRequests()
        cancelActiveTranscription()
        cancelPendingToolResetTasks()
        currentVideo = nil
        transcriptDraftDocument = nil
        lastPlayerContainerSize = containerSize
        syncTranscriptRuntimeState()

        taskCoordinator.replaceLoadVideoTask { [weak self] in
            guard let self else { return }

            var video = await dependencies.loadVideo(url)
            guard !Task.isCancelled else { return }

            applyPendingEditingConfiguration(
                to: &video,
                containerSize: containerSize
            )

            frames = video.videoFrames ?? VideoFrames()
            currentVideo = video
            remapTranscriptDocumentIfNeeded()

            await self.restorePendingEditingPresentationState()
            guard !Task.isCancelled else { return }

            loadThumbnails(
                for: video,
                containerSize: containerSize,
                displayScale: self.lastThumbnailDisplayScale
            )
            let initialTimelineTime = videoPlayer?.currentTime
            videoPlayer?.loadState = .loaded(url)
            if let initialTimelineTime {
                videoPlayer?.currentTime = initialTimelineTime
            }
            videoPlayer?.syncPlaybackState(with: video)
            markEditingConfigurationChanged()
        }
    }

    func setToolAvailability(_ tools: [ToolAvailability]) {
        enabledTools = EditorToolSelectionCoordinator.enabledTools(
            from: tools
        )

        let previousSelection = presentationState.selectedTool
        presentationState.selectedTool = EditorToolSelectionCoordinator.resolvedSelection(
            currentSelection: presentationState.selectedTool,
            enabledTools: enabledTools
        )

        if previousSelection != presentationState.selectedTool {
            markEditingConfigurationChanged()
        }
    }

    func setMaximumVideoDuration(_ maximumVideoDuration: Double?) {
        let normalizedMaximumDuration = EditorDurationLimitCoordinator.normalizedMaximumDuration(
            maximumVideoDuration
        )

        guard self.maximumVideoDuration != normalizedMaximumDuration else {
            return
        }

        self.maximumVideoDuration = normalizedMaximumDuration

        guard var currentVideo else { return }

        let previousRangeDuration = currentVideo.rangeDuration
        EditorDurationLimitCoordinator.applyDurationLimit(
            to: &currentVideo,
            maximumDuration: normalizedMaximumDuration
        )

        guard currentVideo.rangeDuration != previousRangeDuration else {
            return
        }

        self.currentVideo = currentVideo
        remapTranscriptDocumentIfNeeded()
        markEditingConfigurationChanged()
    }

    func maximumTrimDuration(
        for video: Video
    ) -> Double? {
        EditorDurationLimitCoordinator.resolvedMaximumTrimDuration(
            originalDuration: video.originalDuration,
            maximumDuration: maximumVideoDuration
        )
    }

    func refreshThumbnailsIfNeeded(
        containerSize: CGSize,
        displayScale: CGFloat = 1
    ) {
        lastPlayerContainerSize = containerSize
        lastThumbnailDisplayScale = displayScale

        guard let video = currentVideo else { return }
        guard containerSize.width > 0, containerSize.height > 0 else { return }

        let expectedCount = video.thumbnailCount(for: containerSize)

        guard expectedCount > 0 else { return }

        let expectedThumbnailWidth = max(
            (containerSize.width / CGFloat(expectedCount)) * max(displayScale, 1),
            1
        )

        let isMissingThumbnails = video.thumbnailsImages.isEmpty
        let needsResize = video.thumbnailsImages.count != expectedCount
        let hasLowResolutionThumbnails =
            (video.thumbnailsImages.first?.image?.size.width ?? 0) < expectedThumbnailWidth

        guard isMissingThumbnails || needsResize || hasLowResolutionThumbnails else { return }

        loadThumbnails(
            for: video,
            containerSize: containerSize,
            displayScale: displayScale
        )
    }

    // MARK: - Private Methods

    private func loadThumbnails(
        for video: Video,
        containerSize: CGSize,
        displayScale: CGFloat
    ) {
        let request = taskCoordinator.makeThumbnailLoadRequest(
            for: video.id
        )

        taskCoordinator.runThumbnailLoad(
            request: request,
            operation: { [dependencies] in
                await dependencies.makeThumbnails(video, containerSize, displayScale)
            },
            apply: { [weak self] thumbnails, request in
                self?.applyLoadedThumbnails(
                    thumbnails,
                    for: request
                )
            }
        )
    }

    func applyLoadedThumbnails(
        _ thumbnails: [ThumbnailImage],
        for request: ThumbnailLoadRequest
    ) {
        guard
            taskCoordinator.acceptsThumbnailLoadRequest(
                request,
                currentVideoID: currentVideo?.id
            )
        else { return }

        currentVideo?.thumbnailsImages = thumbnails
    }

    private func invalidateThumbnailRequests() {
        taskCoordinator.cancelThumbnailRequests()
    }

    private func cancelPendingToolReset(
        for tool: ToolEnum
    ) {
        taskCoordinator.cancelPendingToolReset(for: tool)
    }

    private func cancelPendingToolResetTasks() {
        taskCoordinator.cancelPendingToolResetTasks()
    }

    private func schedulePendingToolReset(
        for tool: ToolEnum
    ) {
        taskCoordinator.schedulePendingToolReset(
            for: tool,
            after: Constants.toolResetDelay
        ) { [weak self] in
            guard let self else { return }

            updateCurrentVideo { currentVideo in
                currentVideo.removeTool(for: tool)
            }
            markEditingConfigurationChanged()
        }
    }

    func setFrameColor(_ color: Color) {
        guard EditorAppearanceEditingCoordinator.setFrameColor(color, in: &frames) else { return }
        syncFramesState()
    }

    func setFrameScale(_ scaleValue: Double) {
        guard EditorAppearanceEditingCoordinator.setFrameScale(scaleValue, in: &frames) else { return }
        syncFramesState()
    }

    func setAdjusts(_ adjusts: ColorAdjusts) {
        guard var currentVideo else { return }
        cancelPendingToolReset(for: .adjusts)

        guard
            EditorAppearanceEditingCoordinator.setAdjusts(
                adjusts,
                in: &currentVideo
            )
        else { return }

        self.currentVideo = currentVideo
        remapTranscriptDocumentIfNeeded()
        markEditingConfigurationChanged()
    }

    func updateRate(rate: Float) {
        cancelPendingToolReset(for: .speed)
        guard var currentVideo else { return }

        EditorPlaybackEditingCoordinator.updateRate(
            rate,
            in: &currentVideo,
            selectedTool: presentationState.selectedTool
        )
        self.currentVideo = currentVideo
        remapTranscriptDocumentIfNeeded()
        markEditingConfigurationChanged()
    }

    func setCut() {
        guard var currentVideo else { return }
        cancelPendingToolReset(for: .cut)

        EditorPlaybackEditingCoordinator.syncCutToolState(
            in: &currentVideo,
            tolerance: Constants.numericTolerance
        )
        self.currentVideo = currentVideo
        remapTranscriptDocumentIfNeeded()
        markEditingConfigurationChanged()
    }

    func resetCut() {
        cancelPendingToolReset(for: .cut)
        guard var currentVideo else { return }

        EditorPlaybackEditingCoordinator.resetCut(
            in: &currentVideo
        )
        self.currentVideo = currentVideo
        remapTranscriptDocumentIfNeeded()
        markEditingConfigurationChanged()
    }

    func rotate() {
        cancelPendingToolReset(for: .presets)
        guard var currentVideo else { return }

        EditorPlaybackEditingCoordinator.rotate(
            in: &currentVideo,
            selectedTool: presentationState.selectedTool
        )
        self.currentVideo = currentVideo
        markEditingConfigurationChanged()
    }

    func setRotation(_ rotation: Double) {
        cancelPendingToolReset(for: .presets)
        guard var currentVideo else { return }
        guard
            EditorPlaybackEditingCoordinator.setRotation(
                rotation,
                in: &currentVideo,
                selectedTool: presentationState.selectedTool
            )
        else { return }

        self.currentVideo = currentVideo
        markEditingConfigurationChanged()
    }

    func toggleMirror() {
        cancelPendingToolReset(for: .presets)
        guard var currentVideo else { return }

        EditorPlaybackEditingCoordinator.toggleMirror(
            in: &currentVideo,
            selectedTool: presentationState.selectedTool
        )
        self.currentVideo = currentVideo
        markEditingConfigurationChanged()
    }

    func setCropFreeformRect(_ rect: VideoEditingConfiguration.FreeformRect?) {
        guard cropPresentationState.freeformRect != rect else { return }
        cancelPendingToolReset(for: .presets)
        cropPresentationState.freeformRect = rect
        syncCropToolState()
        markEditingConfigurationChanged()
    }

    func selectCropFormat(_ preset: VideoCropFormatPreset) {
        cancelPendingToolReset(for: .presets)

        let previousSelectedTool = presentationState.selectedTool
        let previousCropState = cropEditingState

        guard let referenceSize = currentCropReferenceSize() else { return }

        let nextCropState = EditorCropEditingCoordinator.selectingCropFormat(
            preset,
            from: previousCropState,
            referenceSize: referenceSize
        )

        guard let nextCropState else { return }

        applyCropEditingState(nextCropState)
        presentationState.selectedTool = nil
        syncCropToolState()

        let status = previousSelectedTool != presentationState.selectedTool || previousCropState != nextCropState

        guard status else { return }

        markEditingConfigurationChanged()
    }

    func selectSocialVideoDestination(
        _ destination: VideoEditingConfiguration.SocialVideoDestination
    ) {
        cancelPendingToolReset(for: .presets)
        let previousCropState = cropEditingState

        guard let referenceSize = currentCropReferenceSize() else { return }

        let nextCropState = EditorCropEditingCoordinator.selectingSocialVideoDestination(
            destination,
            from: previousCropState,
            referenceSize: referenceSize
        )

        guard let nextCropState else { return }

        applyCropEditingState(nextCropState)
        syncCropToolState()

        guard previousCropState != nextCropState else { return }

        markEditingConfigurationChanged()
    }

    func setAudio(_ audio: Audio) {
        cancelPendingToolReset(for: .audio)
        guard var currentVideo else { return }

        presentationState.selectedAudioTrack = EditorAudioEditingCoordinator.setRecordedAudio(
            audio,
            in: &currentVideo
        )
        self.currentVideo = currentVideo
        markEditingConfigurationChanged()
    }

    func removeAudio() {
        guard let url = currentVideo?.audio?.url else { return }
        guard var currentVideo else { return }
        cancelPendingToolReset(for: .audio)
        FileManager.default.removeIfExists(for: url)
        presentationState.selectedAudioTrack = EditorAudioEditingCoordinator.removeRecordedAudio(
            from: &currentVideo,
            selectedTool: presentationState.selectedTool
        )
        self.currentVideo = currentVideo
        markEditingConfigurationChanged()
    }

    func reset(
        _ tool: ToolEnum,
        videoPlayer: VideoPlayerManager
    ) {
        switch tool {
        case .cut:
            resetToolCut()
        case .speed:
            resetToolSpeed(videoPlayer: videoPlayer)
        case .presets:
            resetToolPresets()
        case .audio:
            resetToolAudio(videoPlayer: videoPlayer)
        case .adjusts:
            resetToolAdjusts(videoPlayer: videoPlayer)
        case .transcript:
            resetTranscript()
        }

        markEditingConfigurationChanged()

        schedulePendingToolReset(for: tool)
    }

    func selectTool(_ tool: ToolEnum) {
        guard
            let selectedTool = EditorToolSelectionCoordinator.selectTool(
                tool,
                enabledTools: enabledTools
            )
        else { return }

        presentationState.selectedTool = selectedTool
        markEditingConfigurationChanged()
    }

    func closeSelectedTool() {
        presentationState.selectedTool = EditorToolSelectionCoordinator.closeSelectedTool()
        markEditingConfigurationChanged()
    }

    func handleCurrentVideoChange(
        _ video: Video?,
        videoPlayer: VideoPlayerManager
    ) {
        guard let video else { return }
        frames = EditorAppearanceEditingCoordinator.framesState(from: video)
        videoPlayer.syncPlaybackState(with: video)
        videoPlayer.setColorAdjusts(video.colorAdjusts)
    }

    func resolvedPlayerDisplaySize(for video: Video, in containerSize: CGSize) -> CGSize {
        VideoEditorLayoutResolver.resolvedPlayerDisplaySize(
            for: video,
            in: containerSize
        )
    }

    func resolvedCropPreviewCanvas(
        for video: Video,
        in containerSize: CGSize
    ) -> VideoEditorCropPreviewCanvas {
        VideoEditorLayoutResolver.resolvedCropPreviewCanvas(
            for: video,
            freeformRect: cropPresentationState.freeformRect,
            in: containerSize,
            fallbackContainerSize: lastPlayerContainerSize
        )
    }

    func updateCurrentVideoLayout(
        to size: CGSize
    ) {
        guard var currentVideo else { return }

        let didChangeFrameSize = currentVideo.frameSize != size
        let didChangeGeometrySize = currentVideo.geometrySize != size

        guard didChangeFrameSize || didChangeGeometrySize else { return }

        currentVideo.frameSize = size
        currentVideo.geometrySize = size

        self.currentVideo = currentVideo
    }

    func handleRateChange(_ rate: Float, videoPlayer: VideoPlayerManager) {
        let previousRate = currentVideo?.rate ?? 1
        videoPlayer.pause()
        updateRate(rate: rate)
        if let currentVideo {
            videoPlayer.syncPlaybackState(with: currentVideo, previousRate: previousRate)
        }
    }

    func removeAudio(using videoPlayer: VideoPlayerManager) {
        videoPlayer.pause()
        removeAudio()
    }

    func selectAudioTrack(_ track: VideoEditingConfiguration.SelectedTrack) {
        let previousTrack = presentationState.selectedAudioTrack
        presentationState.selectedAudioTrack = EditorAudioEditingCoordinator.selectedTrack(
            track,
            hasRecordedAudioTrack: hasRecordedAudioTrack
        )

        if previousTrack != presentationState.selectedAudioTrack {
            markEditingConfigurationChanged()
        }
    }

    var hasRecordedAudioTrack: Bool {
        currentVideo?.audio != nil
    }

    func updateSelectedTrackVolume(_ value: Float, videoPlayer: VideoPlayerManager) {
        cancelPendingToolReset(for: .audio)
        guard var currentVideo else { return }

        EditorAudioEditingCoordinator.updateSelectedTrackVolume(
            value,
            in: &currentVideo,
            selectedTrack: presentationState.selectedAudioTrack
        )
        self.currentVideo = currentVideo

        videoPlayer.setVolume(presentationState.selectedAudioTrack == .video, value: value)
        markEditingConfigurationChanged()
    }

    func selectedTrackVolume() -> Float {
        EditorAudioEditingCoordinator.selectedTrackVolume(
            in: currentVideo,
            selectedTrack: presentationState.selectedAudioTrack
        )
    }

    private func syncFramesState() {
        guard var currentVideo else { return }
        EditorAppearanceEditingCoordinator.syncFrames(
            frames,
            into: &currentVideo
        )
        self.currentVideo = currentVideo
        markEditingConfigurationChanged()
    }

    func setSourceVideoIfNeeded(
        _ sourceVideoURL: URL?,
        editingConfiguration: VideoEditingConfiguration? = nil,
        availableSize: CGSize,
        videoPlayer: VideoPlayerManager
    ) {
        guard
            let bootstrap = EditorSessionCoordinator.beginSourceVideoSession(
                sourceVideoURL: sourceVideoURL,
                editingConfiguration: editingConfiguration,
                availableSize: availableSize,
                hasLoadedSourceVideo: hasLoadedSourceVideo,
                containerSizeResolver: playerContainerSize(in:)
            )
        else {
            lastPlayerContainerSize = playerContainerSize(in: availableSize)
            return
        }

        lastPlayerContainerSize = bootstrap.containerSize
        hasLoadedSourceVideo = true
        prepareEditingConfigurationForInitialLoad(
            bootstrap.editingConfiguration,
            videoPlayer: videoPlayer
        )
        videoPlayer.loadState = .loading
        setNewVideo(
            bootstrap.sourceVideoURL,
            containerSize: bootstrap.containerSize,
            videoPlayer: videoPlayer
        )
    }

    func handleRecordedVideo(_ url: URL, videoPlayer: VideoPlayerManager) {
        let recordedVideoSession = EditorSessionCoordinator.recordedVideoSession(url)
        hasLoadedSourceVideo = recordedVideoSession.hasLoadedSourceVideo
        presentationState.selectedAudioTrack = recordedVideoSession.selectedAudioTrack
        videoPlayer.loadState = .loading
        setNewVideo(
            url,
            containerSize: lastPlayerContainerSize,
            videoPlayer: videoPlayer
        )
    }

    func presentExporter() {
        presentationState.selectedTool = nil
        markEditingConfigurationChanged()
        taskCoordinator.scheduleExporterPresentation(
            after: Constants.exportPresentationDelay
        ) { [weak self] in
            guard let self else { return }
            presentationState.showVideoQualitySheet = true
        }
    }

    func configureTranscription(
        provider: (any VideoTranscriptionProvider)?,
        preferredLocale: String? = nil
    ) {
        transcriptionAvailabilityTask?.cancel()
        transcriptionProvider = provider
        transcriptionComponent = provider as? any VideoTranscriptionComponentProtocol
        preferredTranscriptLocale = preferredLocale
        transcriptAvailabilityError = nil

        syncTranscriptRuntimeState()
        probeTranscriptAvailabilityIfNeeded()
    }

    func transcribeCurrentVideo() {
        guard let transcriptionProvider else {
            applyTranscriptFailure(.providerNotConfigured)
            return
        }

        guard let currentVideo, currentVideo.url.isFileURL else {
            applyTranscriptFailure(.invalidVideoSource)
            return
        }

        let input = VideoTranscriptionInput(
            assetIdentifier: currentVideo.url.absoluteString,
            source: .fileURL(currentVideo.url),
            preferredLocale: preferredTranscriptLocale
        )
        let transcriptionComponent = self.transcriptionComponent

        taskCoordinator.replaceTranscriptionTask { [weak self] token in
            guard let self else { return }

            do {
                let result = try await performTranscription(
                    input: input,
                    provider: transcriptionProvider,
                    component: transcriptionComponent
                )
                guard taskCoordinator.acceptsTranscriptionTask(token) else { return }

                guard !result.segments.isEmpty else {
                    applyTranscriptFailure(.emptyResult)
                    return
                }

                guard let currentVideo = self.currentVideo else {
                    applyTranscriptFailure(.invalidVideoSource)
                    return
                }

                let document = EditorTranscriptMappingCoordinator.makeDocument(
                    from: result,
                    trimRange: currentVideo.rangeDuration,
                    playbackRate: currentVideo.rate
                )
                applyTranscriptSuccess(document)
            } catch {
                guard taskCoordinator.acceptsTranscriptionTask(token) else { return }
                await applyTranscriptionFailure(
                    error,
                    using: transcriptionComponent
                )
            }
        }
    }

    func cancelDeferredTasks() {
        cancelActiveTranscription()
        taskCoordinator.cancelDeferredTasks()
    }

    func currentEditingConfiguration(currentTimelineTime: Double? = nil) -> VideoEditingConfiguration? {
        EditorSessionCoordinator.currentEditingConfiguration(
            from: currentVideo,
            frames: frames,
            freeformRect: cropPresentationState.freeformRect,
            canvasSnapshot: cropPresentationState.canvasEditorState.snapshot(),
            selectedAudioTrack: presentationState.selectedAudioTrack,
            transcriptFeatureState: transcriptFeatureState,
            transcriptDocument: transcriptDocument,
            selectedTool: presentationState.selectedTool,
            socialVideoDestination: cropPresentationState.socialVideoDestination,
            showsSafeAreaGuides: false,
            currentTimelineTime: currentTimelineTime
        )
    }

    func videoCanvasSource(for video: Video) -> VideoCanvasSourceDescriptor {
        VideoCanvasSourceDescriptor(
            naturalSize: resolvedCropReferenceSize(for: video),
            preferredTransform: .identity,
            userRotationDegrees: video.rotation,
            isMirrored: video.isMirror
        )
    }

    func handleCanvasPreviewChange() {
        cancelPendingToolReset(for: .presets)
        syncCropToolState()
        markEditingConfigurationChanged()
    }

    func resetCanvasTransform() {
        cropPresentationState.canvasEditorState.resetTransform()
        handleCanvasPreviewChange()
    }

    func activeTranscriptSegment(
        at timelineTime: Double
    ) -> EditableTranscriptSegment? {
        effectiveTranscriptDocument?.segments.first {
            guard let timelineRange = $0.timeMapping.timelineRange else { return false }
            return timelineRange.contains(timelineTime)
        }
    }

    func activeTranscriptWord(
        at timelineTime: Double
    ) -> EditableTranscriptWord? {
        guard let activeSegment = activeTranscriptSegment(at: timelineTime) else {
            return nil
        }

        return TranscriptWordEditingCoordinator.resolvedWords(
            for: activeSegment
        ).first(where: {
            guard let timelineRange = $0.timeMapping.timelineRange else { return false }
            return timelineTime >= timelineRange.lowerBound && timelineTime < timelineRange.upperBound
        })
    }

    func exportEditingConfiguration(
        currentTimelineTime: Double? = nil
    ) -> VideoEditingConfiguration? {
        EditorSessionCoordinator.currentEditingConfiguration(
            from: currentVideo,
            frames: frames,
            freeformRect: cropPresentationState.freeformRect,
            canvasSnapshot: cropPresentationState.canvasEditorState.snapshot(),
            selectedAudioTrack: presentationState.selectedAudioTrack,
            transcriptFeatureState: transcriptFeatureState,
            transcriptDocument: effectiveTranscriptDocument,
            selectedTool: presentationState.selectedTool,
            socialVideoDestination: cropPresentationState.socialVideoDestination,
            showsSafeAreaGuides: false,
            currentTimelineTime: currentTimelineTime
        )
    }

    func updateTranscriptOverlayPosition(
        _ position: TranscriptOverlayPosition
    ) {
        updateTranscriptDraftDocument { transcriptDocument in
            guard transcriptDocument.overlayPosition != position else { return false }
            transcriptDocument.overlayPosition = position
            return true
        }
    }

    func updateTranscriptOverlaySize(
        _ size: TranscriptOverlaySize
    ) {
        updateTranscriptDraftDocument { transcriptDocument in
            guard transcriptDocument.overlaySize != size else { return false }
            transcriptDocument.overlaySize = size
            return true
        }
    }

    func playerContainerSize(in availableSize: CGSize) -> CGSize {
        VideoEditorLayoutResolver.playerContainerSize(
            in: availableSize
        )
    }

    func prepareEditingConfigurationForInitialLoad(
        _ editingConfiguration: VideoEditingConfiguration?,
        videoPlayer _: VideoPlayerManager
    ) {
        let preparedState = EditorInitialLoadCoordinator.prepare(
            editingConfiguration
        )

        pendingEditingConfiguration = preparedState.pendingEditingConfiguration
        presentationState.selectedTool = preparedState.selectedTool
        presentationState.selectedAudioTrack = preparedState.selectedAudioTrack
        cropPresentationState.apply(preparedState.cropEditingState)
        transcriptFeatureState = preparedState.transcriptFeatureState
        transcriptDocument = preparedState.transcriptDocument
        transcriptDraftDocument = preparedState.transcriptDocument
        syncTranscriptRuntimeState()
    }

    func setTranscriptDocument(
        _ document: TranscriptDocument?,
        featureState: TranscriptFeaturePersistenceState = .loaded
    ) {
        transcriptFeatureState = document == nil ? .idle : featureState
        transcriptDocument = document
        transcriptDraftDocument = document
        remapTranscriptDocumentIfNeeded()
        syncTranscriptAppliedToolState()
        syncTranscriptRuntimeState()
        markEditingConfigurationChanged()
    }

    func updateTranscriptSegmentText(
        _ text: String,
        segmentID: UUID
    ) {
        updateTranscriptDraftDocument { transcriptDocument in
            guard let segmentIndex = transcriptDocument.segments.firstIndex(where: { $0.id == segmentID }) else {
                return false
            }

            guard transcriptDocument.segments[segmentIndex].editedText != text else { return false }

            transcriptDocument.segments[segmentIndex].editedText = text
            if let reconciledWords = TranscriptWordEditingCoordinator.reconcileWords(
                transcriptDocument.segments[segmentIndex].words,
                with: text
            ) {
                transcriptDocument.segments[segmentIndex].words = reconciledWords
            }
            return true
        }
    }

    func revertTranscriptSegmentText(
        segmentID: UUID
    ) {
        updateTranscriptDraftDocument { transcriptDocument in
            guard let segmentIndex = transcriptDocument.segments.firstIndex(where: { $0.id == segmentID }) else {
                return false
            }

            guard transcriptDocument.segments[segmentIndex].isEdited else { return false }

            transcriptDocument.segments[segmentIndex].revertEdits()
            return true
        }
    }

    func prepareTranscriptDraft() {
        transcriptDraftDocument = transcriptDocument
        syncTranscriptRuntimeState()
    }

    func prepareTranscriptDraftIfNeeded() {
        guard transcriptDraftDocument == nil else { return }

        transcriptDraftDocument = transcriptDocument
        syncTranscriptRuntimeState()
    }

    func applyTranscriptChanges() {
        transcriptDocument = transcriptDraftDocument
        transcriptFeatureState = transcriptDocument == nil ? .idle : .loaded
        syncTranscriptAppliedToolState()
        syncTranscriptRuntimeState()
        markEditingConfigurationChanged()
    }

    func resetTranscript() {
        cancelActiveTranscription()
        transcriptFeatureState = .idle
        transcriptState = .idle
        transcriptDocument = nil
        transcriptDraftDocument = nil
        syncTranscriptAppliedToolState()
        markEditingConfigurationChanged()
    }

    func applyPendingEditingConfiguration(
        to video: inout Video,
        containerSize: CGSize = .zero
    ) {
        EditorInitialLoadCoordinator.applyPendingEditingConfiguration(
            pendingEditingConfiguration,
            to: &video,
            containerSize: containerSize,
            maximumDuration: maximumVideoDuration
        ) { [self] video, containerSize in
            resolvedPlayerDisplaySize(
                for: video,
                in: containerSize
            )
        }
    }

    func restorePendingEditingPresentationState() async {
        guard
            let restoredState = await EditorInitialLoadCoordinator.restorePendingEditingPresentationState(
                from: pendingEditingConfiguration,
                referenceSize: currentCropReferenceSize() ?? .zero,
                hasRecordedAudioTrack: currentVideo?.audio != nil,
                enabledTools: enabledTools
            )
        else {
            return
        }

        applyCropEditingState(restoredState.cropEditingState)
        presentationState.selectedAudioTrack = restoredState.selectedAudioTrack
        presentationState.selectedTool = restoredState.selectedTool
        remapTranscriptDocumentIfNeeded()
        syncTranscriptRuntimeState()

        pendingEditingConfiguration = nil
    }

    // MARK: - Private Properties

    private var effectiveTranscriptDocument: TranscriptDocument? {
        transcriptDraftDocument ?? transcriptDocument
    }

    // MARK: - Private Methods

    private func syncCropToolState() {
        guard let currentVideo else { return }

        let shouldApplyPresetTool = HostEditorCropEditingCoordinator.shouldApplyPresetTool(
            for: currentVideo,
            state: cropEditingState
        )

        updateCurrentVideo { currentVideo in
            if shouldApplyPresetTool {
                currentVideo.appliedTool(for: .presets)
            } else {
                currentVideo.removeTool(for: .presets)
            }
        }
    }

    private func currentCropReferenceSize() -> CGSize? {
        guard let currentVideo else { return nil }
        return VideoEditorLayoutResolver.resolvedCropReferenceSize(
            for: currentVideo,
            fallbackContainerSize: lastPlayerContainerSize
        )
    }

    private func resolvedCropReferenceSize(for video: Video) -> CGSize {
        VideoEditorLayoutResolver.resolvedCropReferenceSize(
            for: video,
            fallbackContainerSize: lastPlayerContainerSize
        )
    }

    private func resetToolCut() {
        guard var currentVideo else { return }

        EditorPlaybackEditingCoordinator.restoreDefaultCut(
            in: &currentVideo
        )
        self.currentVideo = currentVideo
        remapTranscriptDocumentIfNeeded()
    }

    private func resetToolSpeed(videoPlayer: VideoPlayerManager) {
        let previousRate = currentVideo?.rate ?? 1
        videoPlayer.pause()
        guard var currentVideo else { return }

        EditorPlaybackEditingCoordinator.restoreDefaultRate(
            in: &currentVideo
        )
        self.currentVideo = currentVideo
        remapTranscriptDocumentIfNeeded()
        videoPlayer.syncPlaybackState(with: currentVideo, previousRate: previousRate)
    }

    private func resetToolPresets() {
        updateCurrentVideo { currentVideo in
            currentVideo.rotation = 0
            currentVideo.isMirror = false
        }
        applyCropEditingState(.initial)
    }

    private func resetToolAudio(videoPlayer: VideoPlayerManager) {
        presentationState.selectedAudioTrack = .video

        if currentVideo?.audio != nil {
            removeAudio(using: videoPlayer)
            return
        }

        updateCurrentVideo { currentVideo in
            currentVideo.setVolume(1.0)
            currentVideo.removeTool(for: .audio)
        }
        videoPlayer.setVolume(true, value: 1.0)
    }

    private func resetToolAdjusts(videoPlayer: VideoPlayerManager) {
        guard var currentVideo else { return }
        guard
            EditorAppearanceEditingCoordinator.restoreDefaultAdjusts(
                in: &currentVideo
            )
        else { return }

        self.currentVideo = currentVideo
        videoPlayer.clearColorAdjusts()
    }

    private var cropEditingState: EditorCropEditingState {
        cropPresentationState.editingState
    }

    private func applyCropEditingState(_ state: EditorCropEditingState) {
        cropPresentationState.apply(state)
    }

    private func remapTranscriptDocumentIfNeeded() {
        guard let currentVideo else { return }

        transcriptDocument = EditorTranscriptRemappingCoordinator.remap(
            transcriptDocument,
            trimRange: currentVideo.rangeDuration,
            playbackRate: currentVideo.rate
        )
        transcriptDraftDocument = EditorTranscriptRemappingCoordinator.remap(
            transcriptDraftDocument,
            trimRange: currentVideo.rangeDuration,
            playbackRate: currentVideo.rate
        )
    }

    private func updateCurrentVideo(
        _ update: (inout Video) -> Void
    ) {
        guard var currentVideo else { return }
        update(&currentVideo)
        self.currentVideo = currentVideo
    }

    private func cancelActiveTranscription() {
        taskCoordinator.cancelTranscriptionTask()

        guard let transcriptionComponent else { return }

        Task {
            await transcriptionComponent.cancelCurrentTranscription()
        }
    }

    private func performTranscription(
        input: VideoTranscriptionInput,
        provider: any VideoTranscriptionProvider,
        component: (any VideoTranscriptionComponentProtocol)?
    ) async throws -> VideoTranscriptionResult {
        guard let component else {
            transcriptState = .loading
            return try await provider.transcribeVideo(input: input)
        }

        let loadingObserverTask = Task { [weak self] in
            while !Task.isCancelled {
                let runtimeState = await component.state
                self?.applyRuntimeTranscriptState(runtimeState)

                guard runtimeState == .idle else { return }

                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        defer {
            loadingObserverTask.cancel()
        }

        let transcriptionResult = try await provider.transcribeVideo(input: input)
        await refreshTranscriptState(using: component)
        return transcriptionResult
    }

    private func applyTranscriptSuccess(_ document: TranscriptDocument) {
        transcriptDraftDocument = document
        transcriptState = .loaded
    }

    private func applyTranscriptFailure(
        _ error: TranscriptError,
        runtimeState: TranscriptFeatureState? = nil
    ) {
        transcriptState = runtimeState ?? .failed(error)
    }

    private func applyTranscriptionFailure(
        _ error: Error,
        using component: (any VideoTranscriptionComponentProtocol)?
    ) async {
        let runtimeState = await runtimeTranscriptState(using: component)
        let transcriptError = resolvedTranscriptError(
            from: error,
            runtimeState: runtimeState
        )
        applyTranscriptFailure(
            transcriptError,
            runtimeState: runtimeState
        )
    }

    private func refreshTranscriptState(
        using component: any VideoTranscriptionComponentProtocol
    ) async {
        transcriptState = await component.state
    }

    private func applyRuntimeTranscriptState(
        _ state: TranscriptFeatureState
    ) {
        transcriptState = state
    }

    private func runtimeTranscriptState(
        using component: (any VideoTranscriptionComponentProtocol)?
    ) async -> TranscriptFeatureState? {
        guard let component else { return nil }
        return await component.state
    }

    private func resolvedTranscriptError(
        from error: Error,
        runtimeState: TranscriptFeatureState?
    ) -> TranscriptError {
        if case .failed(let transcriptError) = runtimeState {
            return transcriptError
        }

        return switch error {
        case let transcriptError as TranscriptError:
            transcriptError
        case is CancellationError:
            TranscriptError.cancelled
        default:
            TranscriptError.providerFailure(message: error.localizedDescription)
        }
    }

    private func syncTranscriptRuntimeState() {
        switch transcriptFeatureState {
        case .idle:
            if let transcriptAvailabilityError,
                transcriptDraftDocument == nil
            {
                transcriptState = .failed(transcriptAvailabilityError)
            } else {
                transcriptState = transcriptDraftDocument == nil ? .idle : .loaded
            }
        case .loaded:
            transcriptState = transcriptDocument == nil ? .idle : .loaded
        case .failed:
            transcriptState = .failed(
                .providerFailure(message: VideoEditorStrings.transcriptPreviousRequestFailed)
            )
        }
    }

    private func probeTranscriptAvailabilityIfNeeded() {
        guard let transcriptionComponent else { return }

        let preferredLocale = preferredTranscriptLocale
        transcriptionAvailabilityTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let availabilityError = await transcriptionComponent.availabilityError(
                preferredLocale: preferredLocale
            )
            guard !Task.isCancelled else { return }

            transcriptAvailabilityError = availabilityError

            guard transcriptState != .loading else { return }
            syncTranscriptRuntimeState()
        }
    }

    private func updateTranscriptDraftDocument(
        _ transform: (inout TranscriptDocument) -> Bool
    ) {
        guard var transcriptDraftDocument else { return }
        guard transform(&transcriptDraftDocument) else { return }

        self.transcriptDraftDocument = transcriptDraftDocument
    }

    private func syncTranscriptAppliedToolState() {
        guard var currentVideo else { return }

        if transcriptFeatureState == .loaded, transcriptDocument != nil {
            currentVideo.appliedTool(for: .transcript)
        } else {
            currentVideo.removeTool(for: .transcript)
        }

        self.currentVideo = currentVideo
    }

    private func markEditingConfigurationChanged() {
        presentationState.markEditingConfigurationChanged()
    }

}
