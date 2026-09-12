import CoreGraphics
import Testing

@testable import VideoEditorKit

@Suite("VideoEditingPresentationStateResolverTests")
struct VideoEditingPresentationResolverTests {

    // MARK: - Public Methods

    @Test
    func selectedCropPresetPrefersExplicitCanvasPresetMapping() {
        let selectedPreset = VideoEditingPresentationStateResolver.selectedCropPreset(
            canvasPreset: .facebookPost,
            freeformRect: nil,
            referenceSize: CGSize(width: 1920, height: 1080)
        )

        #expect(selectedPreset == .portrait4x5)
    }

    @Test
    func resolveFiltersUnavailableToolsAndMissingRecordedAudio() async {
        let resolvedState = await VideoEditingPresentationStateResolver.resolve(
            from: VideoEditingConfiguration(
                audio: .init(selectedTrack: .recorded),
                presentation: .init(.audio)
            ),
            referenceSize: CGSize(width: 1920, height: 1080),
            hasRecordedAudioTrack: false,
            enabledTools: Set([.adjusts, .presets])
        )

        #expect(resolvedState.selectedAudioTrack == .video)
        #expect(resolvedState.selectedTool == nil)
    }

    @Test
    func resolveCanvasSnapshotSynthesizesLegacySocialPresetState() async {
        let resolvedSnapshot = await VideoEditingPresentationStateResolver.resolveCanvasSnapshot(
            from: VideoEditingConfiguration(
                crop: .init(
                    freeformRect: .init(
                        x: 0.341796875,
                        y: 0,
                        width: 0.31640625,
                        height: 1
                    )
                ),
                presentation: .init(
                    socialVideoDestination: .tikTok,
                    showsSafeAreaGuides: true
                )
            ),
            referenceSize: CGSize(width: 1920, height: 1080)
        )

        #expect(resolvedSnapshot.preset == .social(platform: .tiktok))
        #expect(resolvedSnapshot.showsSafeAreaOverlay == false)
        #expect(resolvedSnapshot.transform == .identity)
        #expect(resolvedSnapshot.freeCanvasSize == CGSize(width: 1080, height: 1920))
    }

    @Test
    func resolveCanvasSnapshotReturnsPersistedSnapshotVerbatim() async {
        let persistedSnapshot = VideoCanvasSnapshot(
            preset: .facebookPost,
            freeCanvasSize: CGSize(width: 1080, height: 1350),
            transform: .init(
                normalizedOffset: CGPoint(x: 0.2, y: -0.1),
                zoom: 1.3,
                rotationRadians: 0.4
            ),
            showsSafeAreaOverlay: false
        )

        let resolvedSnapshot = await VideoEditingPresentationStateResolver.resolveCanvasSnapshot(
            from: VideoEditingConfiguration(
                canvas: .init(snapshot: persistedSnapshot),
                presentation: .init(
                    socialVideoDestination: .instagramReels,
                    showsSafeAreaGuides: true
                )
            ),
            referenceSize: CGSize(width: 1920, height: 1080)
        )

        #expect(resolvedSnapshot == persistedSnapshot)
    }

    @Test
    func selectedLegacyCropPresetReturnsOriginalWhenThereIsNoLegacyRect() {
        let preset = VideoEditingPresentationStateResolver.selectedLegacyCropPreset(
            from: nil,
            referenceSize: CGSize(width: 1920, height: 1080)
        )

        #expect(preset == .original)
    }

    @Test
    func selectedLegacyCropPresetFallsBackToVerticalForUnknownAspectRatios() {
        let preset = VideoEditingPresentationStateResolver.selectedLegacyCropPreset(
            from: .init(
                x: 0.1,
                y: 0.1,
                width: 0.23,
                height: 0.2
            ),
            referenceSize: CGSize(width: 1920, height: 1080)
        )

        #expect(preset == .vertical9x16)
    }

    @Test
    func resolvePreservesEnabledToolAndRecordedTrackWhenTheyAreAvailable() async {
        let resolvedState = await VideoEditingPresentationStateResolver.resolve(
            from: VideoEditingConfiguration(
                audio: .init(selectedTrack: .recorded),
                presentation: .init(.audio)
            ),
            referenceSize: CGSize(width: 1920, height: 1080),
            hasRecordedAudioTrack: true,
            enabledTools: Set([.audio, .presets])
        )

        #expect(resolvedState.selectedAudioTrack == .recorded)
        #expect(resolvedState.selectedTool == .audio)
    }

    @Test
    func resolveDoesNotRestoreTranscriptAsTheInitiallyOpenedTool() async {
        let resolvedState = await VideoEditingPresentationStateResolver.resolve(
            from: VideoEditingConfiguration(
                presentation: .init(.transcript)
            ),
            referenceSize: CGSize(width: 1920, height: 1080),
            hasRecordedAudioTrack: false,
            enabledTools: Set([.transcript, .audio])
        )

        #expect(resolvedState.selectedTool == nil)
    }

}
