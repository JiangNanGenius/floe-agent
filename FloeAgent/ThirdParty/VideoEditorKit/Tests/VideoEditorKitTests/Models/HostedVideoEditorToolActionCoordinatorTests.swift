import CoreGraphics
import Foundation
import Testing

@testable import VideoEditorKit

@MainActor
@Suite("HostedVideoEditorToolActionCoordinatorTests", .serialized)
struct HostedToolActionTests {

    // MARK: - Public Methods

    @Test
    func blockedToolTapNotifiesTheHostWithoutChangingSelection() {
        let editorViewModel = EditorViewModel()
        var blockedTool: ToolEnum?

        HostedVideoEditorToolActionCoordinator.handleToolTap(
            .blocked(.adjusts),
            configuration: .init(
                onBlockedToolTap: { blockedTool = $0 }
            ),
            editorViewModel: editorViewModel
        )

        #expect(blockedTool == .adjusts)
        #expect(editorViewModel.presentationState.selectedTool == nil)
    }

    @Test
    func loadingTranscriptDraftStatePreparesTheDraftDocument() {
        let editorViewModel = EditorViewModel()
        let document = TranscriptDocument(
            segments: [],
            overlayPosition: .bottom,
            overlaySize: .medium
        )
        editorViewModel.currentVideo = Video.mock
        editorViewModel.transcriptDocument = document
        editorViewModel.transcriptDraftDocument = nil

        let draftState = HostedVideoEditorToolActionCoordinator.loadDraftState(
            for: .transcript,
            currentState: .init(),
            editorViewModel: editorViewModel
        )

        #expect(draftState == .init())
        #expect(editorViewModel.transcriptDraftDocument == document)
    }

    @Test
    func applyingAudioDraftCommitsTrackVolumesAndClosesTheSheet() {
        let editorViewModel = EditorViewModel()
        var video = Video.mock
        video.volume = 0.8
        video.audio = Audio(
            url: URL(fileURLWithPath: "/tmp/recorded.m4a"),
            duration: 12,
            volume: 0.35
        )
        editorViewModel.currentVideo = video
        editorViewModel.presentationState.selectedTool = .audio
        editorViewModel.presentationState.selectedAudioTrack = .video

        var draftState = EditorToolDraftState()
        draftState.audioDraft = .init(
            selectedTrack: .recorded,
            videoVolume: 0.55,
            recordedVolume: 0.7
        )

        HostedVideoEditorToolActionCoordinator.apply(
            .audio,
            draftState: draftState,
            editorViewModel: editorViewModel,
            videoPlayer: VideoPlayerManager()
        )

        #expect(editorViewModel.currentVideo?.volume == 0.55)
        #expect(editorViewModel.currentVideo?.audio?.volume == 0.7)
        #expect(editorViewModel.presentationState.selectedAudioTrack == .recorded)
        #expect(editorViewModel.presentationState.selectedTool == nil)
    }

    @Test
    func selectingPresetAppliesImmediatelyAndClosesTheSheet() {
        let editorViewModel = EditorViewModel()
        var video = Video.mock
        video.presentationSize = CGSize(width: 1920, height: 1080)
        editorViewModel.currentVideo = video
        editorViewModel.presentationState.selectedTool = .presets

        let draftState = HostedVideoEditorToolActionCoordinator.selectPreset(
            .portrait4x5,
            currentDraftState: .init(),
            editorViewModel: editorViewModel
        )

        #expect(draftState.presetDraft == .portrait4x5)
        #expect(editorViewModel.cropPresentationSummary.selectedPreset == .portrait4x5)
        #expect(editorViewModel.presentationState.selectedTool == nil)
    }

    @Test
    func selectingSpeedAppliesImmediatelyAndClosesTheSheet() {
        let editorViewModel = EditorViewModel()
        let videoPlayer = VideoPlayerManager()
        editorViewModel.currentVideo = Video.mock
        editorViewModel.presentationState.selectedTool = .speed

        let draftState = HostedVideoEditorToolActionCoordinator.selectSpeed(
            3,
            currentDraftState: .init(),
            editorViewModel: editorViewModel,
            videoPlayer: videoPlayer
        )

        #expect(draftState.speedDraft == 3)
        #expect(editorViewModel.currentVideo?.rate == 3)
        #expect(editorViewModel.presentationState.selectedTool == nil)
    }

    @Test
    func updatingAudioVolumeAppliesImmediatelyAndOnlyClosesWhenFinishingInteraction() {
        let editorViewModel = EditorViewModel()
        let videoPlayer = VideoPlayerManager()
        var video = Video.mock
        video.audio = Audio(
            url: URL(fileURLWithPath: "/tmp/audio-immediate.m4a"),
            duration: 6,
            volume: 0.4
        )
        editorViewModel.currentVideo = video
        editorViewModel.presentationState.selectedTool = .audio

        var draftState = EditorToolDraftState()
        draftState.audioDraft = AudioToolDraft(
            selectedTrack: .recorded,
            videoVolume: 1,
            recordedVolume: 0.4
        )

        draftState = HostedVideoEditorToolActionCoordinator.selectAudioTrack(
            .recorded,
            currentDraftState: draftState,
            editorViewModel: editorViewModel
        )
        draftState = HostedVideoEditorToolActionCoordinator.updateAudioVolume(
            0.7,
            currentDraftState: draftState,
            editorViewModel: editorViewModel,
            videoPlayer: videoPlayer
        )

        #expect(draftState.audioDraft.recordedVolume == 0.7)
        #expect(editorViewModel.currentVideo?.audio?.volume == 0.7)
        #expect(editorViewModel.presentationState.selectedTool == .audio)

        HostedVideoEditorToolActionCoordinator.finishAudioEditing(
            editorViewModel: editorViewModel
        )

        #expect(editorViewModel.presentationState.selectedTool == nil)
    }

    @Test
    func updatingAdjustsAppliesImmediatelyWithoutClosingTheSheet() {
        let editorViewModel = EditorViewModel()
        let videoPlayer = VideoPlayerManager()
        editorViewModel.currentVideo = Video.mock
        editorViewModel.presentationState.selectedTool = .adjusts

        let adjusts = ColorAdjusts(
            brightness: 0.2,
            contrast: -0.1,
            saturation: 0.3
        )
        let draftState = HostedVideoEditorToolActionCoordinator.updateAdjusts(
            adjusts,
            currentDraftState: .init(),
            editorViewModel: editorViewModel,
            videoPlayer: videoPlayer
        )

        #expect(draftState.adjustsDraft == adjusts)
        #expect(editorViewModel.currentVideo?.colorAdjusts == adjusts)
        #expect(editorViewModel.presentationState.selectedTool == .adjusts)
    }

    @Test
    func resettingAudioAfterApplyingAVolumeChangeClearsTheToolbarPresentationImmediately() {
        let editorViewModel = EditorViewModel(
            .init(
                loadVideo: { await Video.load(from: $0) },
                makeThumbnails: { video, containerSize, displayScale in
                    await video.makeThumbnails(
                        containerSize: containerSize,
                        displayScale: displayScale
                    )
                },
                sleep: { _ in }
            )
        )
        let videoPlayer = VideoPlayerManager()
        editorViewModel.currentVideo = Video.mock
        editorViewModel.presentationState.selectedTool = .audio
        editorViewModel.presentationState.selectedAudioTrack = .video

        var draftState = EditorToolDraftState()
        draftState.audioDraft.videoVolume = 0.5

        HostedVideoEditorToolActionCoordinator.apply(
            .audio,
            draftState: draftState,
            editorViewModel: editorViewModel,
            videoPlayer: videoPlayer
        )

        #expect(editorViewModel.currentVideo?.volume == 0.5)
        #expect(editorViewModel.currentVideo?.isAppliedTool(for: .audio) == true)

        editorViewModel.presentationState.selectedTool = .audio

        _ = HostedVideoEditorToolActionCoordinator.reset(
            .audio,
            currentDraftState: draftState,
            editorViewModel: editorViewModel,
            videoPlayer: videoPlayer
        )

        #expect(editorViewModel.currentVideo?.volume == 1.0)
        #expect(editorViewModel.currentVideo?.isAppliedTool(for: .audio) == false)

        let presentation = EditorToolbarItemPresentationResolver.resolve(
            for: .audio,
            video: editorViewModel.currentVideo,
            cropPresentationSummary: nil,
            transcriptDocument: nil
        )

        #expect(presentation.isApplied == false)
        #expect(presentation.subtitle == nil)
    }

    @Test
    func resettingTranscriptClearsDocumentsAndClosesTheSheet() {
        let editorViewModel = EditorViewModel()
        let document = TranscriptDocument(
            segments: [],
            overlayPosition: .top,
            overlaySize: .large
        )
        editorViewModel.currentVideo = Video.mock
        editorViewModel.presentationState.selectedTool = .transcript
        editorViewModel.transcriptState = .loaded
        editorViewModel.transcriptDocument = document
        editorViewModel.transcriptDraftDocument = document

        let draftState = HostedVideoEditorToolActionCoordinator.reset(
            .transcript,
            currentDraftState: .init(),
            editorViewModel: editorViewModel,
            videoPlayer: VideoPlayerManager()
        )

        #expect(draftState == .init())
        #expect(editorViewModel.transcriptDocument == nil)
        #expect(editorViewModel.transcriptDraftDocument == nil)
        #expect(editorViewModel.presentationState.selectedTool == nil)
    }

}
