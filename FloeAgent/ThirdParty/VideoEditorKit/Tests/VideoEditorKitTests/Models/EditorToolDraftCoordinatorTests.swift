import Foundation
import Testing

@testable import VideoEditorKit

@MainActor
@Suite("EditorToolDraftCoordinatorTests", .serialized)
struct EditorToolDraftCoordinatorTests {

    // MARK: - Public Methods

    @Test
    func loadDraftStateCopiesCommittedVideoValuesForAudioAndAdjusts() {
        var video = Video.mock
        video.volume = 0.45
        video.audio = Audio(
            url: URL(fileURLWithPath: "/tmp/audio.m4a"),
            duration: 8,
            volume: 0.35
        )
        video.colorAdjusts = .init(
            brightness: 0.2,
            contrast: -0.1,
            saturation: 0.15
        )

        var state = EditorToolDraftState()
        state.speedDraft = 1.8

        state = EditorToolDraftCoordinator.loadedDraftState(
            for: .audio,
            currentState: state,
            video: video,
            selectedTrack: .recorded,
            selectedPreset: .square1x1
        )
        state = EditorToolDraftCoordinator.loadedDraftState(
            for: .adjusts,
            currentState: state,
            video: video,
            selectedTrack: .recorded,
            selectedPreset: .square1x1
        )

        #expect(state.audioDraft == AudioToolDraft(video: video, selectedTrack: .recorded))
        #expect(state.adjustsDraft == video.colorAdjusts)
        #expect(state.speedDraft == 1.8)
    }

    @Test
    func canApplyDetectsPendingPresetAndTranscriptChanges() {
        let video = Video.mock
        let transcriptDocument = TranscriptDocument(
            segments: [],
            overlayPosition: .bottom,
            overlaySize: .medium
        )
        let transcriptDraftDocument = TranscriptDocument(
            segments: [],
            overlayPosition: .top,
            overlaySize: .large
        )

        var presetState = EditorToolDraftState()
        presetState.presetDraft = .portrait4x5

        let canApplyPreset = EditorToolDraftCoordinator.canApply(
            .presets,
            video: video,
            draftState: presetState,
            selectedTrack: .video,
            selectedPreset: .original,
            transcriptState: .idle,
            transcriptDraftDocument: nil,
            transcriptDocument: nil
        )

        let canApplyTranscript = EditorToolDraftCoordinator.canApply(
            .transcript,
            video: video,
            draftState: .init(),
            selectedTrack: .video,
            selectedPreset: .original,
            transcriptState: .loaded,
            transcriptDraftDocument: transcriptDraftDocument,
            transcriptDocument: transcriptDocument
        )

        #expect(canApplyPreset)
        #expect(canApplyTranscript)
    }

    @Test
    func resetModeMatchesTheExpectedToolBehavior() {
        #expect(EditorToolDraftCoordinator.resetMode(for: .presets) == .animated)
        #expect(EditorToolDraftCoordinator.resetMode(for: .transcript) == .transcript)
        #expect(EditorToolDraftCoordinator.resetMode(for: .audio) == .standard)
    }

    @Test
    func transcriptDraftPreparationIsOnlyRequiredForTranscriptTool() {
        #expect(EditorToolDraftCoordinator.shouldPrepareTranscriptDraft(for: .transcript))
        #expect(!EditorToolDraftCoordinator.shouldPrepareTranscriptDraft(for: .speed))
    }

}
