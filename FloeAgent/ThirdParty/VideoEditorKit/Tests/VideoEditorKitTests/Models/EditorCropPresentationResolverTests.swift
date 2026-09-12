import Foundation
import Testing

@testable import VideoEditorKit

@Suite("EditorCropPresentationResolverTests")
struct EditorCropPresentationResolverTests {

    // MARK: - Public Methods

    @Test
    @MainActor
    func originalSummaryUsesTheVideoSourceDimensionsForTheBadge() {
        var video = Video.mock
        video.presentationSize = CGSize(width: 1920, height: 1080)

        let summary = EditorCropPresentationResolver.makeSummary(
            state: .initial,
            video: video,
            fallbackContainerSize: CGSize(width: 320, height: 240)
        )

        #expect(summary.selectedPreset == .original)
        #expect(summary.shouldShowCropOverlay == false)
        #expect(summary.isCropOverlayInteractive)
        #expect(summary.shouldShowCropPresetBadge == false)
        #expect(summary.shouldShowCanvasResetButton == false)
        #expect(summary.badgeTitle == "Original")
        #expect(summary.badgeDimension == "1920x1080")
        #expect(summary.badgeText == "Original • 1920x1080")
    }

    @Test
    @MainActor
    func socialSummaryKeepsTheSocialBadgeCopyWithoutSafeAreaChrome() {
        let summary = EditorCropPresentationResolver.makeSummary(
            state: .init(
                freeformRect: .init(
                    x: 0.34,
                    y: 0,
                    width: 0.32,
                    height: 1
                ),
                socialVideoDestination: .youtubeShorts,
                showsSafeAreaOverlay: true,
                canvasSnapshot: .init(
                    preset: .social(platform: .youtubeShorts),
                    freeCanvasSize: CGSize(width: 1080, height: 1920),
                    transform: .identity,
                    showsSafeAreaOverlay: true
                )
            ),
            video: nil,
            fallbackContainerSize: CGSize(width: 320, height: 240)
        )

        #expect(summary.selectedPreset == .vertical9x16)
        #expect(summary.isCropFormatSelected(.vertical9x16))
        #expect(summary.isSocialVideoDestinationSelected(.youtubeShorts))
        #expect(summary.shouldShowCropOverlay)
        #expect(summary.isCropOverlayInteractive)
        #expect(summary.shouldUseCropPresetSpotlight)
        #expect(summary.shouldShowCropPresetBadge)
        #expect(summary.badgeTitle == "Social")
        #expect(summary.badgeDimension == "9:16")
        #expect(summary.badgeText == "Social • 9:16")
    }

    @Test
    @MainActor
    func transformedOriginalSummaryShowsTheCanvasResetButton() {
        var video = Video.mock
        video.presentationSize = CGSize(width: 1920, height: 1080)

        let summary = EditorCropPresentationResolver.makeSummary(
            state: .init(
                canvasSnapshot: .init(
                    preset: .original,
                    transform: .init(
                        normalizedOffset: CGPoint(x: 0.12, y: -0.08),
                        zoom: 1.35
                    )
                )
            ),
            video: video,
            fallbackContainerSize: CGSize(width: 320, height: 240)
        )

        #expect(summary.selectedPreset == .original)
        #expect(summary.shouldShowCropOverlay)
        #expect(summary.isCropOverlayInteractive)
        #expect(summary.shouldShowCanvasResetButton)
        #expect(summary.shouldShowCropPresetBadge == false)
    }

    @Test
    @MainActor
    func socialSummaryStillResolvesThePresetEvenWhenLegacyGuideStateIsPresent() {
        let summary = EditorCropPresentationResolver.makeSummary(
            state: .init(
                freeformRect: .init(
                    x: 0.275,
                    y: 0,
                    width: 0.45,
                    height: 1
                ),
                socialVideoDestination: .instagramReels,
                showsSafeAreaOverlay: false,
                canvasSnapshot: .init(
                    preset: .social(platform: .instagram),
                    freeCanvasSize: CGSize(width: 1080, height: 1920),
                    transform: .identity,
                    showsSafeAreaOverlay: false
                )
            ),
            video: nil,
            fallbackContainerSize: CGSize(width: 320, height: 240)
        )

        #expect(summary.selectedPreset == .vertical9x16)
        #expect(summary.shouldShowCropPresetBadge)
        #expect(summary.badgeText == "Social • 9:16")
    }

    @Test
    @MainActor
    func nonSocialPresetsExposeNameAndDimensionSeparatelyForTheBadge() {
        var video = Video.mock
        video.presentationSize = CGSize(width: 1920, height: 1080)

        let summary = EditorCropPresentationResolver.makeSummary(
            state: .init(
                freeformRect: .init(
                    x: 0.275,
                    y: 0,
                    width: 0.45,
                    height: 1
                ),
                canvasSnapshot: .init(
                    preset: .facebookPost,
                    freeCanvasSize: CGSize(width: 1080, height: 1350),
                    transform: .identity,
                    showsSafeAreaOverlay: false
                )
            ),
            video: video,
            fallbackContainerSize: CGSize(width: 320, height: 240)
        )

        #expect(summary.selectedPreset == .portrait4x5)
        #expect(summary.badgeTitle == "Portrait")
        #expect(summary.badgeDimension == "4:5")
        #expect(summary.badgeText == "Portrait • 4:5")
    }

    @Test
    @MainActor
    func playbackFocusHidesOverlayChromeWhileKeepingCropInteractionsAvailable() {
        let summary = EditorCropPresentationResolver.makeSummary(
            state: .init(
                freeformRect: .init(
                    x: 0.34,
                    y: 0,
                    width: 0.32,
                    height: 1
                ),
                socialVideoDestination: .instagramReels,
                showsSafeAreaOverlay: true,
                canvasSnapshot: .init(
                    preset: .social(platform: .instagram),
                    freeCanvasSize: CGSize(width: 1080, height: 1920),
                    transform: .init(
                        normalizedOffset: CGPoint(x: 0.12, y: -0.08),
                        zoom: 1.2
                    ),
                    showsSafeAreaOverlay: true
                )
            ),
            video: nil,
            fallbackContainerSize: CGSize(width: 320, height: 240),
            isPlaybackFocused: true
        )

        #expect(summary.selectedPreset == .vertical9x16)
        #expect(summary.isCropOverlayInteractive)
        #expect(summary.shouldShowCropPresetBadge == false)
        #expect(summary.shouldShowCanvasResetButton == false)
    }

}
