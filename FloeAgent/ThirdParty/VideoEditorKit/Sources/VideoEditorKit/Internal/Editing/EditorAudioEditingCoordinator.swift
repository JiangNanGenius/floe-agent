//
//  EditorAudioEditingCoordinator.swift
//  VideoEditorKit
//
//  Created by Codex on 01.04.2026.
//

struct EditorAudioEditingCoordinator {

    // MARK: - Public Methods

    static func selectedTrack(
        _ requestedTrack: VideoEditingConfiguration.SelectedTrack,
        hasRecordedAudioTrack: Bool
    ) -> VideoEditingConfiguration.SelectedTrack {
        if requestedTrack == .recorded, !hasRecordedAudioTrack {
            return .video
        }

        return requestedTrack
    }

    static func selectedTrackVolume(
        in video: Video?,
        selectedTrack: VideoEditingConfiguration.SelectedTrack
    ) -> Float {
        guard let video else { return 1.0 }

        if selectedTrack == .video {
            return video.volume
        }

        return video.audio?.volume ?? 1.0
    }

    static func setRecordedAudio(
        _ audio: Audio,
        in video: inout Video
    ) -> VideoEditingConfiguration.SelectedTrack {
        video.audio = audio
        video.appliedTool(for: .audio)
        return .recorded
    }

    static func removeRecordedAudio(
        from video: inout Video,
        selectedTool: ToolEnum?
    ) -> VideoEditingConfiguration.SelectedTrack {
        video.audio = nil

        if selectedTool == .audio {
            video.removeTool(for: .audio)
        } else {
            syncAudioToolState(for: &video)
        }

        return .video
    }

    static func updateSelectedTrackVolume(
        _ value: Float,
        in video: inout Video,
        selectedTrack: VideoEditingConfiguration.SelectedTrack
    ) {
        if selectedTrack == .video {
            video.setVolume(value)
        } else {
            video.audio?.setVolume(value)
        }

        syncAudioToolState(for: &video)
    }

    static func syncAudioToolState(
        for video: inout Video
    ) {
        let hasRecordedAudio = video.audio != nil
        let hasAdjustedVideoVolume = abs(video.volume - 1.0) > 0.001

        if hasRecordedAudio || hasAdjustedVideoVolume {
            video.appliedTool(for: .audio)
        } else {
            video.removeTool(for: .audio)
        }
    }

}
