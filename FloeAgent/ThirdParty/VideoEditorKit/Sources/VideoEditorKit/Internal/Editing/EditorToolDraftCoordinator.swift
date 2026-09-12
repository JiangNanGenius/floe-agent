import Foundation

struct EditorToolDraftState: Equatable {

    // MARK: - Public Properties

    var speedDraft = 1.0
    var adjustsDraft = ColorAdjusts()
    var presetDraft: VideoCropFormatPreset = .original
    var audioDraft = AudioToolDraft()

}

struct EditorToolDraftCoordinator {

    enum ResetMode: Equatable {
        case standard
        case animated
        case transcript
    }

    // MARK: - Public Methods

    static func loadedDraftState(
        for tool: ToolEnum,
        currentState: EditorToolDraftState,
        video: Video,
        selectedTrack: VideoEditingConfiguration.SelectedTrack,
        selectedPreset: VideoCropFormatPreset
    ) -> EditorToolDraftState {
        var updatedState = currentState

        switch tool {
        case .speed:
            updatedState.speedDraft = Double(video.rate)
        case .presets:
            updatedState.presetDraft = selectedPreset
        case .audio:
            updatedState.audioDraft = AudioToolDraft(
                video: video,
                selectedTrack: selectedTrack
            )
        case .adjusts:
            updatedState.adjustsDraft = video.colorAdjusts
        case .transcript, .cut:
            break
        }

        return updatedState
    }

    static func canApply(
        _ tool: ToolEnum,
        video: Video,
        draftState: EditorToolDraftState,
        selectedTrack: VideoEditingConfiguration.SelectedTrack,
        selectedPreset: VideoCropFormatPreset,
        transcriptState: TranscriptFeatureState,
        transcriptDraftDocument: TranscriptDocument?,
        transcriptDocument: TranscriptDocument?
    ) -> Bool {
        switch tool {
        case .speed:
            return abs(Double(video.rate) - draftState.speedDraft) > 0.001
        case .presets:
            return selectedPreset != draftState.presetDraft
        case .audio:
            return draftState.audioDraft
                != AudioToolDraft(
                    video: video,
                    selectedTrack: selectedTrack
                )
        case .adjusts:
            return video.colorAdjusts != draftState.adjustsDraft
        case .transcript:
            return transcriptState == .loaded
                && transcriptDraftDocument != transcriptDocument
        case .cut:
            return false
        }
    }

    static func resetMode(for tool: ToolEnum) -> ResetMode {
        switch tool {
        case .presets:
            .animated
        case .transcript:
            .transcript
        case .speed, .audio, .adjusts, .cut:
            .standard
        }
    }

    static func shouldPrepareTranscriptDraft(for tool: ToolEnum) -> Bool {
        tool == .transcript
    }

}
