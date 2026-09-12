//
//  HostedVideoEditorPlayerStageCoordinator.swift
//  VideoEditorKit
//
//  Created by Codex on 09.04.2026.
//

import CoreGraphics
import Foundation

@MainActor
enum HostedVideoEditorPlayerStageCoordinator {

    struct LoadingPlaceholderPresentation: Equatable, Sendable {

        // MARK: - Public Properties

        let aspectRatio: CGFloat
        let usesKnownVideoDimensions: Bool

    }

    struct TranscriptOverlayContext: Equatable {

        // MARK: - Public Properties

        let transcriptDocument: TranscriptDocument
        let activeSegment: EditableTranscriptSegment
        let activeWordID: UUID?
        let layoutID: String

    }

    // MARK: - Public Methods

    static func presentationState(
        for loadState: LoadState
    ) -> VideoEditorPlayerStageState {
        presentationState(
            for: loadState,
            isPreviewReadyForDisplay: true
        )
    }

    static func presentationState(
        for loadState: LoadState,
        isPreviewReadyForDisplay: Bool
    ) -> VideoEditorPlayerStageState {
        switch loadState {
        case .unknown:
            .unknown
        case .loading:
            .loading
        case .loaded:
            isPreviewReadyForDisplay ? .loaded : .loading
        case .failed:
            .failed
        }
    }

    static func loadingPlaceholderPresentation(
        source: VideoCanvasSourceDescriptor?
    ) -> LoadingPlaceholderPresentation {
        guard let source else {
            return .init(
                aspectRatio: fallbackLoadingPlaceholderAspectRatio,
                usesKnownVideoDimensions: false
            )
        }

        let presentationSize = source.resolvedPresentationSize

        guard presentationSize.width > 0, presentationSize.height > 0 else {
            return .init(
                aspectRatio: fallbackLoadingPlaceholderAspectRatio,
                usesKnownVideoDimensions: false
            )
        }

        return .init(
            aspectRatio: presentationSize.width / presentationSize.height,
            usesKnownVideoDimensions: true
        )
    }

    static func canvasEditorState(
        editorViewModel: EditorViewModel
    ) -> VideoCanvasEditorState? {
        guard editorViewModel.currentVideo != nil else { return nil }
        return editorViewModel.cropPresentationState.canvasEditorState
    }

    static func canvasSource(
        editorViewModel: EditorViewModel
    ) -> VideoCanvasSourceDescriptor? {
        guard let video = editorViewModel.currentVideo else { return nil }
        return editorViewModel.videoCanvasSource(for: video)
    }

    static func cropPresentationSummary(
        editorViewModel: EditorViewModel,
        isPlaybackFocused: Bool
    ) -> EditorCropPresentationSummary {
        editorViewModel.cropPresentationSummary(
            isPlaybackFocused: isPlaybackFocused
        )
    }

    static func playerLayoutID(
        editorViewModel: EditorViewModel
    ) -> String? {
        guard let video = editorViewModel.currentVideo else { return nil }

        let canvasState = editorViewModel.cropPresentationState.canvasEditorState

        return [
            video.id.uuidString,
            String(Int(video.rotation.rounded())),
            String(describing: canvasState.preset),
            String(Int(canvasState.freeCanvasSize.width.rounded())),
            String(Int(canvasState.freeCanvasSize.height.rounded())),
        ].joined(separator: "-")
    }

    static func transcriptOverlayContext(
        editorViewModel: EditorViewModel,
        currentTimelineTime: Double
    ) -> TranscriptOverlayContext? {
        guard editorViewModel.transcriptState == .loaded else { return nil }
        guard
            let transcriptDocument = editorViewModel.transcriptDraftDocument
                ?? editorViewModel.transcriptDocument
        else {
            return nil
        }
        guard
            let activeSegment = editorViewModel.activeTranscriptSegment(
                at: currentTimelineTime
            )
        else {
            return nil
        }

        let activeWordID = editorViewModel.activeTranscriptWord(
            at: currentTimelineTime
        )?.id

        return .init(
            transcriptDocument: transcriptDocument,
            activeSegment: activeSegment,
            activeWordID: activeWordID,
            layoutID: transcriptOverlayLayoutID(
                transcriptDocument: transcriptDocument,
                canvasState: editorViewModel.cropPresentationState.canvasEditorState
            )
        )
    }

    static func syncVideoLayout(
        _ canvasLayout: VideoCanvasLayout,
        editorViewModel: EditorViewModel
    ) {
        guard let video = editorViewModel.currentVideo else { return }
        let size = canvasLayout.previewCanvasSize

        guard size.width > 0, size.height > 0 else { return }
        guard editorViewModel.currentVideo?.id == video.id else { return }

        editorViewModel.updateCurrentVideoLayout(
            to: size
        )
    }

    // MARK: - Private Methods

    private static var fallbackLoadingPlaceholderAspectRatio: CGFloat {
        16.0 / 9.0
    }

    private static func transcriptOverlayLayoutID(
        transcriptDocument: TranscriptDocument,
        canvasState: VideoCanvasEditorState
    ) -> String {
        [
            String(describing: canvasState.preset),
            String(Int(canvasState.freeCanvasSize.width.rounded())),
            String(Int(canvasState.freeCanvasSize.height.rounded())),
            String(describing: transcriptDocument.overlayPosition),
            String(describing: transcriptDocument.overlaySize),
        ].joined(separator: "-")
    }

}
