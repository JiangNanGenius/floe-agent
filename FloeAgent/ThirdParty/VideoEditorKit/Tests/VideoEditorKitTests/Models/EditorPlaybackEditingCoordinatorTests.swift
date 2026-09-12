import Testing

@testable import VideoEditorKit

@Suite("EditorPlaybackEditingCoordinatorTests", .serialized)
struct EditorPlaybackEditingCoordinatorTests {

    // MARK: - Public Methods

    @Test
    func minimumTrimDurationResolvesToOneSecondForLongVideos() {
        #expect(EditorPlaybackEditingCoordinator.minimumTrimDuration(for: 12) == 1)
    }

    @Test
    func minimumTrimDurationClampsToTheVideoDurationForShortVideos() {
        #expect(EditorPlaybackEditingCoordinator.minimumTrimDuration(for: 0.75) == 0.75)
        #expect(EditorPlaybackEditingCoordinator.minimumTrimDuration(for: -1) == 0)
    }

    @Test
    @MainActor
    func updateRateAppliesTheSelectedToolToTheVideo() {
        var video = Video.mock

        EditorPlaybackEditingCoordinator.updateRate(
            1.75,
            in: &video,
            selectedTool: .speed
        )

        #expect(abs(Double(video.rate) - 1.75) < 0.0001)
        #expect(video.isAppliedTool(for: .speed) == true)
    }

    @Test
    @MainActor
    func syncCutToolStateTracksWhetherTheRangeIsTrimmed() {
        var video = Video.mock
        video.rangeDuration = 12...80

        EditorPlaybackEditingCoordinator.syncCutToolState(
            in: &video,
            tolerance: 0.001
        )

        #expect(video.isAppliedTool(for: .cut) == true)

        video.rangeDuration = 0...video.originalDuration

        EditorPlaybackEditingCoordinator.syncCutToolState(
            in: &video,
            tolerance: 0.001
        )

        #expect(video.isAppliedTool(for: .cut) == false)
    }

    @Test
    @MainActor
    func rotateAndMirrorApplyThePresetToolWhenItIsSelected() {
        var video = Video.mock

        EditorPlaybackEditingCoordinator.rotate(
            in: &video,
            selectedTool: .presets
        )
        EditorPlaybackEditingCoordinator.toggleMirror(
            in: &video,
            selectedTool: .presets
        )

        #expect(video.rotation == 90)
        #expect(video.isMirror == true)
        #expect(video.isAppliedTool(for: .presets) == true)
    }

    @Test
    @MainActor
    func restoringPlaybackDefaultsKeepsTheAppliedToolsUntilDeferredCleanup() {
        var video = Video.mock
        video.rangeDuration = 20...80
        video.rate = 1.75
        video.appliedTool(for: .cut)
        video.appliedTool(for: .speed)

        EditorPlaybackEditingCoordinator.restoreDefaultCut(in: &video)
        EditorPlaybackEditingCoordinator.restoreDefaultRate(in: &video)

        #expect(video.rangeDuration == 0...250)
        #expect(abs(Double(video.rate) - 1.0) < 0.0001)
        #expect(video.isAppliedTool(for: .cut) == true)
        #expect(video.isAppliedTool(for: .speed) == true)
    }

}
