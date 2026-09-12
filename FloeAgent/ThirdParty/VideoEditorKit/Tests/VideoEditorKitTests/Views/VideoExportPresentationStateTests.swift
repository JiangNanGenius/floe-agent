import Testing

@testable import VideoEditorKit

@Suite("VideoExportPresentationStateTests")
struct VideoExportPresentationStateTests {

    @Test
    func idleStateKeepsTheExportButtonInItsDefaultMode() {
        let state = VideoExportPresentationState(
            selectedQuality: .medium,
            exportProgress: 0,
            progressText: "0%",
            errorMessage: "",
            actionTitle: "Export",
            isInteractionDisabled: false,
            canExportVideo: true,
            canCancelExport: false,
            shouldShowLoadingView: false,
            shouldShowFailureMessage: false
        )

        #expect(state.isExporting == false)
        #expect(state.exportButtonTitle == "Export")
        #expect(state.exportButtonProgress == 0)
        #expect(state.shouldShowCancelAction == false)
    }

    @Test
    func loadingStateMovesProgressIntoTheButtonAndShowsCancel() {
        let state = VideoExportPresentationState(
            selectedQuality: .high,
            exportProgress: 0.42,
            progressText: "42%",
            errorMessage: "",
            actionTitle: "Export",
            isInteractionDisabled: true,
            canExportVideo: false,
            canCancelExport: true,
            shouldShowLoadingView: true,
            shouldShowFailureMessage: false
        )

        #expect(state.isExporting)
        #expect(state.exportButtonTitle == "Exporting 42%")
        #expect(state.exportButtonProgress == 0.42)
        #expect(state.shouldShowCancelAction)
    }

    @Test
    func savingBeforeExportShowsSavingTitleInTheExportButton() {
        let state = VideoExportPresentationState(
            selectedQuality: .high,
            exportProgress: 0,
            progressText: "0%",
            errorMessage: "",
            actionTitle: "Export",
            isInteractionDisabled: true,
            canExportVideo: false,
            canCancelExport: true,
            shouldShowLoadingView: true,
            shouldShowFailureMessage: false,
            isSavingBeforeExport: true
        )

        #expect(state.isExporting)
        #expect(state.exportButtonTitle == "Saving video...")
        #expect(state.exportButtonProgress == 0)
        #expect(state.shouldShowCancelAction)
    }

    @Test
    func exportButtonProgressIsClampedToTheExpectedRange() {
        let overComplete = VideoExportPresentationState(
            selectedQuality: .low,
            exportProgress: 1.7,
            progressText: "170%",
            errorMessage: "",
            actionTitle: "Export",
            isInteractionDisabled: true,
            canExportVideo: false,
            canCancelExport: true,
            shouldShowLoadingView: true,
            shouldShowFailureMessage: false
        )
        let underComplete = VideoExportPresentationState(
            selectedQuality: .low,
            exportProgress: -0.2,
            progressText: "-20%",
            errorMessage: "",
            actionTitle: "Export",
            isInteractionDisabled: true,
            canExportVideo: false,
            canCancelExport: true,
            shouldShowLoadingView: true,
            shouldShowFailureMessage: false
        )

        #expect(overComplete.exportButtonProgress == 1)
        #expect(underComplete.exportButtonProgress == 0)
    }

    @Test
    func qualityPresentationAlwaysShowsOriginalLastAndAvailable() {
        let options = ExportQualityPresentationResolver.optionPresentations(
            for: [
                .blocked(.high),
                .enabled(.low),
            ],
            selectedQuality: .original
        )

        let original = options.last

        #expect(options.map(\.quality) == [.high, .low, .original])
        #expect(original?.quality == .original)
        #expect(original?.isSelected == true)
        #expect(original?.isBlocked == false)
        #expect(original?.shouldNotifyBlockedTap == false)
        #expect(original?.accessibilityLabel == "Original")
        #expect(original?.accessibilityValue == "Selected")
        #expect(original?.accessibilityHint == "Double-tap to select this export quality.")
        #expect(original?.accessibilityIdentifier == "export-quality--1")
    }

    @Test
    func qualityPresentationDoesNotTreatBlockedOriginalAsPremium() {
        let options = ExportQualityPresentationResolver.optionPresentations(
            for: [
                .blocked(.original),
                .blocked(.high),
            ],
            selectedQuality: .low
        )
        let original = options.first(where: { $0.quality == .original })
        let high = options.first(where: { $0.quality == .high })

        #expect(original?.isBlocked == false)
        #expect(original?.accessibilityValue == "Available")
        #expect(original?.shouldNotifyBlockedTap == false)
        #expect(high?.isBlocked == true)
        #expect(high?.accessibilityValue == "Locked")
        #expect(high?.shouldNotifyBlockedTap == true)
    }

    @Test
    func qualitySubtitlesCanWrapForLocalizedCopy() {
        let options = ExportQualityPresentationResolver.optionPresentations(
            for: ExportQualityAvailability.allEnabled,
            selectedQuality: .original
        )
        let original = options.first(where: { $0.quality == .original })
        let high = options.first(where: { $0.quality == .high })

        #expect(original?.subtitleLineLimit == nil)
        #expect(high?.subtitleLineLimit == 2)
    }

}
