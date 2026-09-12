//
//  EditorSessionCoordinator.swift
//  VideoEditorKit
//
//  Created by Codex on 01.04.2026.
//

import Foundation

struct EditorSessionCoordinator {

    struct SourceVideoBootstrap: Equatable {

        // MARK: - Public Properties

        let sourceVideoURL: URL
        let editingConfiguration: VideoEditingConfiguration?
        let containerSize: CGSize

    }

    struct RecordedVideoSession: Equatable {

        // MARK: - Public Properties

        let hasLoadedSourceVideo: Bool
        let selectedAudioTrack: VideoEditingConfiguration.SelectedTrack
        let playerLoadState: LoadState

    }

    // MARK: - Public Methods

    static func beginSourceVideoSession(
        sourceVideoURL: URL?,
        editingConfiguration: VideoEditingConfiguration?,
        availableSize: CGSize,
        hasLoadedSourceVideo: Bool,
        containerSizeResolver: (CGSize) -> CGSize
    ) -> SourceVideoBootstrap? {
        guard !hasLoadedSourceVideo, let sourceVideoURL else { return nil }

        return .init(
            sourceVideoURL: sourceVideoURL,
            editingConfiguration: editingConfiguration,
            containerSize: containerSizeResolver(availableSize)
        )
    }

    static func recordedVideoSession(
        _ url: URL
    ) -> RecordedVideoSession {
        .init(
            hasLoadedSourceVideo: true,
            selectedAudioTrack: .video,
            playerLoadState: .loaded(url)
        )
    }

    static func exportVideo(
        currentVideo: Video?,
        isQualitySheetPresented: Bool
    ) -> Video? {
        guard isQualitySheetPresented else { return nil }
        return currentVideo
    }

    static func currentEditingConfiguration(
        from currentVideo: Video?,
        frames: VideoFrames,
        freeformRect: VideoEditingConfiguration.FreeformRect?,
        canvasSnapshot: VideoCanvasSnapshot,
        selectedAudioTrack: VideoEditingConfiguration.SelectedTrack,
        transcriptFeatureState: TranscriptFeaturePersistenceState,
        transcriptDocument: TranscriptDocument?,
        selectedTool: ToolEnum?,
        socialVideoDestination: VideoEditingConfiguration.SocialVideoDestination?,
        showsSafeAreaGuides: Bool,
        currentTimelineTime: Double?
    ) -> VideoEditingConfiguration? {
        guard let currentVideo else { return nil }

        let configurationVideo = EditorAppearanceEditingCoordinator.configurationVideo(
            from: currentVideo,
            frames: frames
        )

        return VideoEditingConfigurationMapper.makeConfiguration(
            from: configurationVideo,
            freeformRect: freeformRect,
            canvasSnapshot: canvasSnapshot,
            selectedAudioTrack: selectedAudioTrack,
            transcriptFeatureState: transcriptFeatureState,
            transcriptDocument: transcriptDocument,
            selectedTool: selectedTool,
            socialVideoDestination: socialVideoDestination,
            showsSafeAreaGuides: showsSafeAreaGuides,
            currentTimelineTime: currentTimelineTime
        )
    }

}
