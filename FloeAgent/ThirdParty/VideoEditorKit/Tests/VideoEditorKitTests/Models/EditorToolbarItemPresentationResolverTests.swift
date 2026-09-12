import Foundation
import Testing

@testable import VideoEditorKit

@Suite("EditorToolbarItemPresentationResolverTests")
struct ToolbarItemPresentationTests {

    // MARK: - Public Methods

    @Test
    func speedToolUsesTheAppliedRateAsSubtitle() {
        let video = video(
            appliedTool: .speed,
            rate: 1.4
        )
        let expectedSubtitle =
            "\(Float(1.4).formatted(.number.precision(.fractionLength(1))))x"

        let presentation = EditorToolbarItemPresentationResolver.resolve(
            for: .speed,
            video: video,
            cropPresentationSummary: nil,
            transcriptDocument: nil
        )

        #expect(presentation.isApplied)
        #expect(presentation.title == "Speed")
        #expect(presentation.subtitle == expectedSubtitle)
    }

    @Test
    func presetsToolDescribesTheSelectedPresetAndAspectRatio() {
        let video = video(appliedTool: .presets)
        let cropPresentationSummary = EditorCropPresentationSummary(
            selectedPreset: .vertical9x16,
            socialVideoDestination: nil,
            shouldShowCropOverlay: true,
            isCropOverlayInteractive: true,
            shouldUseCropPresetSpotlight: true,
            shouldShowCropPresetBadge: true,
            shouldShowCanvasResetButton: false,
            badgeTitle: "Social",
            badgeDimension: "9:16",
            badgeText: "Social • 9:16"
        )

        let presentation = EditorToolbarItemPresentationResolver.resolve(
            for: .presets,
            video: video,
            cropPresentationSummary: cropPresentationSummary,
            transcriptDocument: nil
        )

        #expect(presentation.isApplied)
        #expect(presentation.subtitle == "Social 9:16")
    }

    @Test
    func audioToolPrefersTheRecordedTrackWhenItExists() {
        var video = video(appliedTool: .audio)
        video.audio = Audio(
            url: URL(fileURLWithPath: "/tmp/recorded-audio.m4a"),
            duration: 8,
            volume: 0.35
        )

        let presentation = EditorToolbarItemPresentationResolver.resolve(
            for: .audio,
            video: video,
            cropPresentationSummary: nil,
            transcriptDocument: nil
        )

        #expect(presentation.isApplied)
        #expect(presentation.subtitle == "35%")
    }

    @Test
    func audioToolShowsOnlyTheVideoTrackPercentageWhenNoRecordingExists() {
        var video = video(appliedTool: .audio)
        video.volume = 0.33

        let presentation = EditorToolbarItemPresentationResolver.resolve(
            for: .audio,
            video: video,
            cropPresentationSummary: nil,
            transcriptDocument: nil
        )

        #expect(presentation.isApplied)
        #expect(presentation.subtitle == "33%")
    }

    @Test
    func audioToolIgnoresAStaleAppliedFlagWhenTheAudioStateIsBackAtDefault() {
        let presentation = EditorToolbarItemPresentationResolver.resolve(
            for: .audio,
            video: video(appliedTool: .audio),
            cropPresentationSummary: nil,
            transcriptDocument: nil
        )

        #expect(presentation.isApplied == false)
        #expect(presentation.subtitle == nil)
    }

    @Test
    func speedToolIgnoresAStaleAppliedFlagWhenPlaybackRateIsBackAtDefault() {
        let presentation = EditorToolbarItemPresentationResolver.resolve(
            for: .speed,
            video: video(appliedTool: .speed),
            cropPresentationSummary: nil,
            transcriptDocument: nil
        )

        #expect(presentation.isApplied == false)
        #expect(presentation.subtitle == nil)
    }

    @Test
    func adjustsToolIgnoresAStaleAppliedFlagWhenAllAdjustmentsAreReset() {
        let presentation = EditorToolbarItemPresentationResolver.resolve(
            for: .adjusts,
            video: video(appliedTool: .adjusts),
            cropPresentationSummary: nil,
            transcriptDocument: nil
        )

        #expect(presentation.isApplied == false)
        #expect(presentation.subtitle == nil)
    }

    @Test
    func presetsToolIgnoresAStaleAppliedFlagWhenTheCropSummaryIsOriginal() {
        let presentation = EditorToolbarItemPresentationResolver.resolve(
            for: .presets,
            video: video(appliedTool: .presets),
            cropPresentationSummary: originalCropPresentationSummary(),
            transcriptDocument: nil
        )

        #expect(presentation.isApplied == false)
        #expect(presentation.subtitle == nil)
    }

    @Test
    func adjustsToolReportsHowManyControlsAreChanged() {
        var video = video(appliedTool: .adjusts)
        video.colorAdjusts = .init(
            brightness: 0.2,
            contrast: -0.15,
            saturation: 0
        )

        let presentation = EditorToolbarItemPresentationResolver.resolve(
            for: .adjusts,
            video: video,
            cropPresentationSummary: nil,
            transcriptDocument: nil
        )

        #expect(presentation.isApplied)
        #expect(presentation.subtitle == "2 adjustments")
    }

    @Test
    func transcriptToolDescribesOverlayPositionAndSize() {
        let video = video(appliedTool: .transcript)
        let transcriptDocument = TranscriptDocument(
            segments: [],
            overlayPosition: .bottom,
            overlaySize: .medium
        )

        let presentation = EditorToolbarItemPresentationResolver.resolve(
            for: .transcript,
            video: video,
            cropPresentationSummary: nil,
            transcriptDocument: transcriptDocument
        )

        #expect(presentation.isApplied)
        #expect(presentation.subtitle == "B/M")
    }

    @Test
    func unappliedToolsDoNotShowASubtitle() {
        let presentation = EditorToolbarItemPresentationResolver.resolve(
            for: .presets,
            video: nil,
            cropPresentationSummary: nil,
            transcriptDocument: nil
        )

        #expect(presentation.isApplied == false)
        #expect(presentation.subtitle == nil)
    }

    @Test
    func activeSpeedDraftUpdatesTheToolbarPresentationBeforeApply() {
        var draftState = EditorToolDraftState()
        draftState.speedDraft = 1.6

        let presentation = EditorToolbarItemPresentationResolver.resolve(
            for: .speed,
            video: unappliedVideo(),
            cropPresentationSummary: nil,
            transcriptDocument: nil,
            draftPresentationState: draftPresentationState(
                selectedTool: .speed,
                draftState: draftState
            )
        )

        #expect(presentation.isApplied)
        #expect(presentation.subtitle == VideoEditorStrings.toolbarSpeedSubtitle(1.6))
    }

    @Test
    func activePresetDraftUpdatesTheToolbarPresentationBeforeApply() {
        var draftState = EditorToolDraftState()
        draftState.presetDraft = .portrait4x5

        let presentation = EditorToolbarItemPresentationResolver.resolve(
            for: .presets,
            video: unappliedVideo(),
            cropPresentationSummary: nil,
            transcriptDocument: nil,
            draftPresentationState: draftPresentationState(
                selectedTool: .presets,
                draftState: draftState
            )
        )

        #expect(presentation.isApplied)
        #expect(presentation.subtitle == "Portrait 4:5")
    }

    @Test
    func activeAudioDraftUpdatesTheToolbarPresentationBeforeApply() {
        var draftState = EditorToolDraftState()
        draftState.audioDraft.videoVolume = 0.2

        let presentation = EditorToolbarItemPresentationResolver.resolve(
            for: .audio,
            video: unappliedVideo(),
            cropPresentationSummary: nil,
            transcriptDocument: nil,
            draftPresentationState: draftPresentationState(
                selectedTool: .audio,
                draftState: draftState
            )
        )

        #expect(presentation.isApplied)
        #expect(presentation.subtitle == "20%")
    }

    @Test
    func activeAdjustsDraftUpdatesTheToolbarPresentationBeforeApply() {
        var draftState = EditorToolDraftState()
        draftState.adjustsDraft = .init(
            brightness: 0.2,
            contrast: -0.1,
            saturation: 0
        )

        let presentation = EditorToolbarItemPresentationResolver.resolve(
            for: .adjusts,
            video: unappliedVideo(),
            cropPresentationSummary: nil,
            transcriptDocument: nil,
            draftPresentationState: draftPresentationState(
                selectedTool: .adjusts,
                draftState: draftState
            )
        )

        #expect(presentation.isApplied)
        #expect(presentation.subtitle == "2 adjustments")
    }

    // MARK: - Private Methods

    private func draftPresentationState(
        selectedTool: ToolEnum,
        draftState: EditorToolDraftState,
        selectedPreset: VideoCropFormatPreset = .original,
        transcriptDraftDocument: TranscriptDocument? = nil
    ) -> EditorToolbarItemDraftPresentationState {
        .init(
            selectedTool: selectedTool,
            draftState: draftState,
            selectedPreset: selectedPreset,
            transcriptDraftDocument: transcriptDraftDocument
        )
    }

    private func video(
        appliedTool: ToolEnum,
        rate: Float = 1
    ) -> Video {
        var video = Video(
            url: URL(fileURLWithPath: "/tmp/editor-toolbar-video.mp4"),
            rangeDuration: 0...12,
            rate: rate
        )
        video.appliedTool(for: appliedTool)
        return video
    }

    private func unappliedVideo() -> Video {
        Video(
            url: URL(fileURLWithPath: "/tmp/editor-toolbar-video.mp4"),
            rangeDuration: 0...12
        )
    }

    private func originalCropPresentationSummary() -> EditorCropPresentationSummary {
        .init(
            selectedPreset: .original,
            socialVideoDestination: nil,
            shouldShowCropOverlay: false,
            isCropOverlayInteractive: true,
            shouldUseCropPresetSpotlight: false,
            shouldShowCropPresetBadge: false,
            shouldShowCanvasResetButton: false,
            badgeTitle: "Original",
            badgeDimension: "1920x1080",
            badgeText: "Original • 1920x1080"
        )
    }

}
