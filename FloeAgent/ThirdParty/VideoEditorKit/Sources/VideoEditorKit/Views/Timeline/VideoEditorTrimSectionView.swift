//
//  VideoEditorTrimSectionView.swift
//  VideoEditorKit
//
//  Created by Codex on 09.04.2026.
//

import SwiftUI

@MainActor
struct VideoEditorTrimSectionView: View {

    // MARK: - Environments

    @Environment(\.displayScale) private var displayScale

    // MARK: - Private Properties

    private let editorViewModel: EditorViewModel
    private let videoPlayer: VideoPlayerManager

    // MARK: - Body

    var body: some View {
        @Bindable var bindableEditorViewModel = editorViewModel
        @Bindable var bindableVideoPlayer = videoPlayer

        if let video = editorViewModel.currentVideo {
            ThumbnailsSliderView(
                $bindableVideoPlayer.currentTime,
                video: $bindableEditorViewModel.currentVideo,
                isPlaying: videoPlayer.isPlaying,
                isChangeState: video.isAppliedTool(for: .cut),
                maximumSelectionDuration: editorViewModel.maximumTrimDuration(for: video),
                onPlayPauseTapped: handlePlayPauseTap,
                onChangeTimeValue: handleTrimRangeChange,
                onRequestThumbnails: requestThumbnails,
                onTrimRangeInteractionStarted: {
                    videoPlayer.beginPlaybackInteraction()
                },
                onTrimRangeInteractionEnded: { time, range in
                    videoPlayer.endPlaybackInteraction(
                        resumeAt: time,
                        in: range
                    )
                },
                onPlaybackScrubStarted: { range in
                    videoPlayer.beginScrubbing(in: range)
                },
                onPlaybackScrubChanged: { time, range in
                    videoPlayer.scrub(
                        to: time,
                        in: range
                    )
                },
                onPlaybackScrubEnded: { time, range in
                    videoPlayer.endScrubbing(
                        at: time,
                        in: range
                    )
                }
            )
        }
    }

    // MARK: - Initializer

    init(
        _ editorViewModel: EditorViewModel,
        videoPlayer: VideoPlayerManager
    ) {
        self.editorViewModel = editorViewModel
        self.videoPlayer = videoPlayer
    }

    // MARK: - Private Methods

    private func handlePlayPauseTap() {
        guard let video = editorViewModel.currentVideo else { return }
        videoPlayer.action(video)
    }

    private func handleTrimRangeChange(_ newRange: ClosedRange<Double>) {
        videoPlayer.updatePlaybackRange(newRange)
        editorViewModel.setCut()
    }

    private func requestThumbnails(_ size: CGSize) {
        editorViewModel.refreshThumbnailsIfNeeded(
            containerSize: size,
            displayScale: displayScale
        )
    }

}

#Preview {
    VideoEditorTrimSectionView(
        EditorViewModel(),
        videoPlayer: VideoPlayerManager()
    )
    .padding()
}
