import Testing

@testable import VideoEditorKit

@MainActor
@Suite("VideoEditorManualSaveCoordinatorTests")
struct VideoEditorManualSaveCoordinatorTests {

    // MARK: - Public Methods

    @Test
    func baselineStartsCleanAfterInitialLoad() {
        let coordinator = VideoEditorManualSaveCoordinator()
        let configuration = VideoEditingConfiguration(
            trim: .init(lowerBound: 1, upperBound: 8)
        )

        coordinator.resetBaseline(to: configuration)

        #expect(coordinator.hasUnsavedChanges == false)
    }

    @Test
    func meaningfulEditingChangeEnablesUnsavedChanges() {
        let coordinator = VideoEditorManualSaveCoordinator()
        let configuration = VideoEditingConfiguration(
            trim: .init(lowerBound: 1, upperBound: 8)
        )
        let editedConfiguration = VideoEditingConfiguration(
            trim: .init(lowerBound: 2, upperBound: 7)
        )

        coordinator.resetBaseline(to: configuration)
        coordinator.updateCurrentEditingConfiguration(editedConfiguration)

        #expect(coordinator.hasUnsavedChanges)
    }

    @Test
    func transientOnlyChangesDoNotEnableUnsavedChanges() {
        let coordinator = VideoEditorManualSaveCoordinator()
        let baseline = VideoEditingConfiguration(
            trim: .init(lowerBound: 1, upperBound: 8),
            playback: .init(
                rate: 1.25,
                videoVolume: 0.7,
                currentTimelineTime: 2
            ),
            audio: .init(selectedTrack: .recorded),
            presentation: .init(
                .adjusts,
                socialVideoDestination: .tikTok,
                showsSafeAreaGuides: true
            )
        )
        var transientChange = baseline
        transientChange.playback.currentTimelineTime = 6
        transientChange.audio.selectedTrack = .video
        transientChange.presentation.selectedTool = nil
        transientChange.presentation.showsSafeAreaGuides = false
        transientChange.canvas.snapshot.showsSafeAreaOverlay = false

        coordinator.resetBaseline(to: baseline)
        coordinator.updateCurrentEditingConfiguration(transientChange)

        #expect(coordinator.hasUnsavedChanges == false)
    }

    @Test
    func markSavedClearsUnsavedChangesAndMovesTheBaseline() {
        let coordinator = VideoEditorManualSaveCoordinator()
        let baseline = VideoEditingConfiguration(
            trim: .init(lowerBound: 1, upperBound: 8)
        )
        let savedConfiguration = VideoEditingConfiguration(
            trim: .init(lowerBound: 2, upperBound: 7)
        )

        coordinator.resetBaseline(to: baseline)
        coordinator.updateCurrentEditingConfiguration(savedConfiguration)
        #expect(coordinator.hasUnsavedChanges)

        coordinator.markSaved(savedConfiguration)
        coordinator.updateCurrentEditingConfiguration(savedConfiguration)

        #expect(coordinator.hasUnsavedChanges == false)
    }

    @Test
    func resetClearsPendingStateUntilANewBaselineIsLoaded() {
        let coordinator = VideoEditorManualSaveCoordinator()
        let baseline = VideoEditingConfiguration(
            trim: .init(lowerBound: 1, upperBound: 8)
        )
        let editedConfiguration = VideoEditingConfiguration(
            trim: .init(lowerBound: 2, upperBound: 7)
        )

        coordinator.resetBaseline(to: baseline)
        coordinator.updateCurrentEditingConfiguration(editedConfiguration)
        #expect(coordinator.hasUnsavedChanges)

        coordinator.reset()

        #expect(coordinator.hasUnsavedChanges == false)
    }

    @Test
    func resetBaselineIfNeededKeepsAnExistingBaseline() {
        let coordinator = VideoEditorManualSaveCoordinator()
        let originalBaseline = VideoEditingConfiguration(
            trim: .init(lowerBound: 1, upperBound: 8)
        )
        let replacementBaseline = VideoEditingConfiguration(
            trim: .init(lowerBound: 2, upperBound: 7)
        )

        coordinator.resetBaseline(to: originalBaseline)
        coordinator.resetBaselineIfNeeded(to: replacementBaseline)
        coordinator.updateCurrentEditingConfiguration(replacementBaseline)

        #expect(coordinator.hasUnsavedChanges)
    }

}
