//
//  VideoAudioToolView.swift
//  VideoEditorKit
//
//  Created by Adriano Souza Costa on 23.03.2026.
//

import SwiftUI

struct AudioToolDraft: Equatable {

    // MARK: - Public Properties

    var selectedTrack: VideoEditingConfiguration.SelectedTrack = .video
    var videoVolume: Float = 1
    var recordedVolume: Float = 1

    var selectedTrackVolume: Float {
        get {
            switch selectedTrack {
            case .video:
                videoVolume
            case .recorded:
                recordedVolume
            }
        }
        set {
            switch selectedTrack {
            case .video:
                videoVolume = newValue
            case .recorded:
                recordedVolume = newValue
            }
        }
    }

    // MARK: - Initializer

    init(
        selectedTrack: VideoEditingConfiguration.SelectedTrack = .video,
        videoVolume: Float = 1,
        recordedVolume: Float = 1
    ) {
        self.selectedTrack = selectedTrack
        self.videoVolume = videoVolume
        self.recordedVolume = recordedVolume
    }

    init(
        video: Video?,
        selectedTrack: VideoEditingConfiguration.SelectedTrack
    ) {
        self.init(
            selectedTrack: selectedTrack,
            videoVolume: video?.volume ?? 1,
            recordedVolume: video?.audio?.volume ?? 1
        )
    }

}

struct VideoAudioToolView: View {

    // MARK: - Public Properties

    let draft: AudioToolDraft

    // MARK: - Body

    var body: some View {
        let currentVolume = draft.selectedTrackVolume

        VStack(alignment: .leading, spacing: 16) {
            if hasRecordedAudioTrack {
                Picker(VideoEditorStrings.audioTrack, selection: selectedTrackBinding) {
                    ForEach(VideoEditingConfiguration.SelectedTrack.allCases) { track in
                        Text(track.title).tag(track)
                    }
                }
                .pickerStyle(.segmented)
            }

            HStack {
                Image(systemName: currentVolume > 0 ? "speaker.wave.2.fill" : "speaker.slash.fill")
                Slider(
                    value: selectedTrackVolumeBinding,
                    in: 0...1,
                    label: {
                        Text(VideoEditorStrings.toolAudio)
                    },
                    onEditingChanged: handleVolumeEditingChanged
                )
                .tint(Theme.accent)
                Text("\(Int(currentVolume * 100))")
            }
            .font(.caption)
        }
        .safeAreaPadding()
    }

    // MARK: - Private Properties

    private let hasRecordedAudioTrack: Bool
    private let onSelectTrack: (VideoEditingConfiguration.SelectedTrack) -> Void
    private let onChangeVolume: (Float) -> Void
    private let onFinishVolumeChange: () -> Void

    private var selectedTrackBinding: Binding<VideoEditingConfiguration.SelectedTrack> {
        Binding(
            get: { draft.selectedTrack },
            set: { newTrack in
                onSelectTrack(newTrack)
            }
        )
    }

    private var selectedTrackVolumeBinding: Binding<Double> {
        Binding(
            get: { Double(draft.selectedTrackVolume) },
            set: { newValue in
                onChangeVolume(Float(newValue))
            }
        )
    }

    // MARK: - Initializer

    init(
        draft: AudioToolDraft,
        hasRecordedAudioTrack: Bool,
        onSelectTrack: @escaping (VideoEditingConfiguration.SelectedTrack) -> Void,
        onChangeVolume: @escaping (Float) -> Void,
        onFinishVolumeChange: @escaping () -> Void
    ) {
        self.draft = draft
        self.hasRecordedAudioTrack = hasRecordedAudioTrack
        self.onSelectTrack = onSelectTrack
        self.onChangeVolume = onChangeVolume
        self.onFinishVolumeChange = onFinishVolumeChange
    }

}

extension VideoAudioToolView {

    // MARK: - Private Methods

    private func handleVolumeEditingChanged(_ isEditing: Bool) {
        guard !isEditing else { return }
        onFinishVolumeChange()
    }

}

#Preview {
    VideoAudioToolView(
        draft:
            .init(
                selectedTrack: .recorded,
                videoVolume: 1,
                recordedVolume: 0.35
            ),
        hasRecordedAudioTrack: true,
        onSelectTrack: { _ in },
        onChangeVolume: { _ in },
        onFinishVolumeChange: {}
    )
}
