import Foundation
import Testing

@testable import VideoEditorKit

@MainActor
@Suite("ExporterViewModelTests", .serialized)
struct ExporterViewModelTests {

    // MARK: - Public Methods

    @Test
    func initialStateReflectsAnIdleExporter() {
        let viewModel = ExporterViewModel(Video.mock)

        #expect(viewModel.renderState == .unknown)
        #expect(viewModel.isInteractionDisabled == false)
        #expect(viewModel.canExportVideo)
        #expect(viewModel.shouldShowLoadingView == false)
        #expect(viewModel.shouldShowFailureMessage == false)
        #expect(viewModel.showAlert == false)
        #expect(viewModel.exportProgress == 0)
        #expect(viewModel.progressText == "0%")
        #expect(viewModel.exportActionTitle == "Export")
        #expect(viewModel.selectedQuality == .original)
    }

    @Test
    func renderStateTransitionsDriveUiFlagsAndProgressLifecycle() {
        let viewModel = ExporterViewModel(Video.mock)
        let exportedVideo = ExportedVideo(
            URL(fileURLWithPath: "/tmp/exported.mp4"),
            width: 1920,
            height: 1080,
            duration: 12,
            fileSize: 512
        )

        viewModel.renderState = .loading

        #expect(viewModel.isInteractionDisabled)
        #expect(viewModel.canCancelExport)
        #expect(viewModel.shouldShowLoadingView)
        #expect(viewModel.showAlert == false)
        #expect(viewModel.exportProgress == 0)

        viewModel.exportProgress = 0.48
        viewModel.renderState = .loaded(exportedVideo)

        #expect(viewModel.exportProgress == 1)
        #expect(viewModel.shouldShowLoadingView == false)
        #expect(viewModel.showAlert == false)

        viewModel.exportProgress = 0.8
        viewModel.renderState = .failed(ExporterError.failed)

        #expect(viewModel.exportProgress == 0)
        #expect(viewModel.shouldShowFailureMessage)
        #expect(viewModel.showAlert)
        #expect(viewModel.exportActionTitle == "Try Again")
        #expect(viewModel.errorMessage == "The video could not be exported. Please try again.")
    }

    @Test
    func qualitySelectionUpdatesTheCurrentExportQuality() {
        let viewModel = ExporterViewModel(Video.mock)

        viewModel.selectQuality(.medium)

        #expect(viewModel.isSelectedQuality(.medium))
        #expect(viewModel.selectedQuality == .medium)
    }

    @Test
    func blockedPremiumExportDefaultsToOriginalQuality() {
        let viewModel = ExporterViewModel(
            Video.mock,
            exportQualities: [
                .enabled(.low),
                .blocked(.medium),
                .blocked(.high),
            ]
        )

        #expect(viewModel.selectedQuality == .original)
        #expect(viewModel.canExportVideo)
    }

    @Test
    func blockedQualitySelectionDoesNotOverrideTheCurrentEnabledQuality() {
        let viewModel = ExporterViewModel(
            Video.mock,
            exportQualities: [
                .blocked(.high),
                .enabled(.medium),
                .enabled(.low),
            ]
        )

        #expect(viewModel.selectedQuality == .original)

        viewModel.selectQuality(.high)

        #expect(viewModel.selectedQuality == .original)
        #expect(viewModel.isSelectedQuality(.original))
    }

    @Test
    func progressTextUsesPercentFormatting() {
        let viewModel = ExporterViewModel(Video.mock)

        viewModel.exportProgress = 0.23

        #expect(viewModel.progressText == "23%")
    }

    @Test
    func exportUsesSelectedQualityAndPublishesTheRenderedVideo() async {
        let sourceURL = URL(fileURLWithPath: "/tmp/source-for-selected-quality.mp4")
        let expectedURL = URL(fileURLWithPath: "/tmp/selected-quality-export.mp4")
        let expectedVideo = ExportedVideo(
            expectedURL,
            width: 1280,
            height: 720,
            duration: 8,
            fileSize: 256
        )
        let editingConfiguration = VideoEditingConfiguration(
            trim: .init(lowerBound: 1, upperBound: 7)
        )
        let tracker = ExportRenderCallTracker()
        var video = Video.mock
        video.url = sourceURL
        let viewModel = ExporterViewModel(
            video,
            editingConfiguration: editingConfiguration,
            renderVideo: { video, configuration, quality, _, _ in
                await tracker.record(
                    sourceURL: video.url,
                    editingConfiguration: configuration,
                    quality: quality
                )
                return expectedURL
            },
            loadExportedVideo: { _ in expectedVideo }
        )

        viewModel.selectQuality(.medium)

        viewModel.exportVideo { exportedVideo in
            Task {
                await tracker.recordExportedVideo(exportedVideo)
            }
        }

        await tracker.waitUntilExportedVideoIsRecorded()

        #expect(await tracker.sourceURLs == [sourceURL])
        #expect(await tracker.editingConfigurations == [editingConfiguration])
        #expect(await tracker.qualities == [.medium])
        #expect(await tracker.exportedVideo == expectedVideo)
        #expect(viewModel.renderState == .loaded(expectedVideo))
    }

    @Test
    func exportWithoutManualQualitySelectionUsesOriginalByDefault() async {
        let expectedURL = URL(fileURLWithPath: "/tmp/default-original-export.mp4")
        let expectedVideo = ExportedVideo(
            expectedURL,
            width: 1920,
            height: 1080,
            duration: 8,
            fileSize: 512
        )
        let preparationProbe = ExportPreparationProbe()
        let tracker = ExportRenderCallTracker()
        let viewModel = ExporterViewModel(
            Video.mock,
            renderVideo: { video, configuration, quality, _, _ in
                await tracker.record(
                    sourceURL: video.url,
                    editingConfiguration: configuration,
                    quality: quality
                )
                return expectedURL
            },
            loadExportedVideo: { _ in expectedVideo }
        )

        viewModel.exportVideo(
            preparingExport: { quality in
                await preparationProbe.prepare(for: quality)
            },
            onExported: { exportedVideo in
                Task {
                    await tracker.recordExportedVideo(exportedVideo)
                }
            }
        )

        await preparationProbe.waitUntilPrepareStarted()
        await preparationProbe.resumePreparation(result: true)
        await tracker.waitUntilExportedVideoIsRecorded()

        #expect(await preparationProbe.qualities == [.original])
        #expect(await tracker.qualities == [.original])
        #expect(await tracker.exportedVideo == expectedVideo)
    }

    @Test
    func exportKeepsTheSelectedQualityFromTheStartOfPreparation() async {
        let expectedURL = URL(fileURLWithPath: "/tmp/snapshotted-quality-export.mp4")
        let expectedVideo = ExportedVideo(
            expectedURL,
            width: 1280,
            height: 720,
            duration: 8,
            fileSize: 256
        )
        let preparationProbe = ExportPreparationProbe()
        let tracker = ExportRenderCallTracker()
        let viewModel = ExporterViewModel(
            Video.mock,
            renderVideo: { video, configuration, quality, _, _ in
                await tracker.record(
                    sourceURL: video.url,
                    editingConfiguration: configuration,
                    quality: quality
                )
                return expectedURL
            },
            loadExportedVideo: { _ in expectedVideo }
        )

        viewModel.selectQuality(.medium)
        viewModel.exportVideo(
            preparingExport: { quality in
                await preparationProbe.prepare(for: quality)
            },
            onExported: { exportedVideo in
                Task {
                    await tracker.recordExportedVideo(exportedVideo)
                }
            }
        )

        await preparationProbe.waitUntilPrepareStarted()
        viewModel.selectQuality(.low)
        await preparationProbe.resumePreparation(result: true)
        await tracker.waitUntilExportedVideoIsRecorded()

        #expect(viewModel.selectedQuality == .medium)
        #expect(await preparationProbe.qualities == [.medium])
        #expect(await tracker.qualities == [.medium])
        #expect(await tracker.exportedVideo == expectedVideo)
    }

    @Test
    func exportVideoRunsPreparationBeforeRenderingAndKeepsOneLoadingState() async {
        let expectedURL = URL(fileURLWithPath: "/tmp/prepared-export.mp4")
        let expectedVideo = ExportedVideo(
            expectedURL,
            width: 1280,
            height: 720,
            duration: 8,
            fileSize: 256
        )
        let preparationProbe = ExportPreparationProbe()
        let tracker = ExportRetryTracker()
        let viewModel = ExporterViewModel(
            Video.mock,
            renderVideo: { _, _, _, _, _ in
                _ = await tracker.recordRenderCall()
                return expectedURL
            },
            loadExportedVideo: { _ in expectedVideo }
        )

        viewModel.exportVideo(
            showsSavingBeforeExport: true,
            preparingExport: { _ in
                await preparationProbe.prepare()
            },
            onExported: { exportedVideo in
                Task {
                    await tracker.recordExportedVideo(exportedVideo)
                }
            }
        )

        await preparationProbe.waitUntilPrepareStarted()

        #expect(viewModel.renderState == .loading)
        #expect(viewModel.shouldShowLoadingView)
        #expect(viewModel.isSavingBeforeExport)
        #expect(await tracker.renderCallCount == 0)

        await preparationProbe.resumePreparation(result: true)
        await tracker.waitUntilExportedVideoIsRecorded()

        #expect(await preparationProbe.prepareCallCount == 1)
        #expect(await tracker.renderCallCount == 1)
        #expect(await tracker.exportedVideo == expectedVideo)
        #expect(viewModel.isSavingBeforeExport == false)
        #expect(viewModel.renderState == .loaded(expectedVideo))
    }

    @Test
    func exportVideoStopsBeforeRenderingWhenPreparationFails() async {
        let preparationProbe = ExportPreparationProbe()
        let tracker = ExportRetryTracker()
        let viewModel = ExporterViewModel(
            Video.mock,
            renderVideo: { _, _, _, _, _ in
                _ = await tracker.recordRenderCall()
                return URL(fileURLWithPath: "/tmp/should-not-render.mp4")
            }
        )

        viewModel.exportVideo(
            preparingExport: { _ in
                await preparationProbe.prepare()
            },
            onExported: { exportedVideo in
                Task {
                    await tracker.recordExportedVideo(exportedVideo)
                }
            }
        )

        await preparationProbe.waitUntilPrepareStarted()
        await preparationProbe.resumePreparation(result: false)

        for _ in 0..<20 where viewModel.renderState == .loading {
            await Task.yield()
        }

        #expect(await preparationProbe.prepareCallCount == 1)
        #expect(await tracker.renderCallCount == 0)
        #expect(await tracker.exportedVideo == nil)
        #expect(viewModel.isSavingBeforeExport == false)
        #expect(viewModel.renderState == .unknown)
    }

    @Test
    func exportVideoDoesNotShowSavingTitleWhenPreparationDoesNotRequireSave() async {
        let preparationProbe = ExportPreparationProbe()
        let viewModel = ExporterViewModel(
            Video.mock,
            renderVideo: { _, _, _, _, _ in
                URL(fileURLWithPath: "/tmp/export.mp4")
            }
        )

        viewModel.exportVideo(
            showsSavingBeforeExport: false,
            preparingExport: { _ in
                await preparationProbe.prepare()
            },
            onExported: { _ in }
        )

        await preparationProbe.waitUntilPrepareStarted()

        #expect(viewModel.renderState == .loading)
        #expect(viewModel.isSavingBeforeExport == false)

        viewModel.cancelExport()
        await preparationProbe.resumePreparation(result: false)
    }

    @Test
    func originalQualityUsesPreparedSavedVideoWithoutRenderingAgain() async {
        let savedURL = URL(fileURLWithPath: "/tmp/prepared-original-export.mp4")
        let savedVideo = ExportedVideo(
            savedURL,
            width: 1920,
            height: 1080,
            duration: 8,
            fileSize: 512
        )
        let tracker = ExportRetryTracker()
        let preparationProbe = ExportOriginalPreparationProbe(savedVideo)
        let viewModel = ExporterViewModel(
            Video.mock,
            renderVideo: { _, _, _, _, _ in
                _ = await tracker.recordRenderCall()
                return URL(fileURLWithPath: "/tmp/should-not-render-original.mp4")
            }
        )

        viewModel.selectQuality(.original)
        viewModel.exportVideo(
            showsSavingBeforeExport: true,
            preparingExport: { quality in
                await preparationProbe.prepare(for: quality)
            },
            onExported: { exportedVideo in
                Task {
                    await tracker.recordExportedVideo(exportedVideo)
                }
            }
        )

        await tracker.waitUntilExportedVideoIsRecorded()

        #expect(await preparationProbe.qualities == [.original])
        #expect(await tracker.renderCallCount == 0)
        #expect(await tracker.exportedVideo == savedVideo)
        #expect(viewModel.isSavingBeforeExport == false)
        #expect(viewModel.renderState == .loaded(savedVideo))
        #expect(viewModel.exportProgress == 1)
    }

    @Test
    func failedExportCanBeRetriedWithoutRecreatingTheViewModel() async {
        let expectedURL = URL(fileURLWithPath: "/tmp/retried-export.mp4")
        let expectedVideo = ExportedVideo(
            expectedURL,
            width: 1280,
            height: 720,
            duration: 10,
            fileSize: 1024
        )
        let tracker = ExportRetryTracker()
        let viewModel = ExporterViewModel(
            Video.mock,
            renderVideo: { _, _, _, _, onProgress in
                let renderCallCount = await tracker.recordRenderCall()
                await onProgress?(0.23)

                if renderCallCount == 1 {
                    throw ExporterError.failed
                }

                await onProgress?(1)
                return expectedURL
            },
            loadExportedVideo: { _ in expectedVideo }
        )

        let firstResult = await viewModel.export()

        #expect(firstResult == nil)
        #expect(viewModel.shouldShowFailureMessage)
        #expect(viewModel.showAlert)
        #expect(viewModel.exportProgress == 0)

        viewModel.retryExport { url in
            Task {
                await tracker.recordExportedVideo(url)
            }
        }

        await tracker.waitUntilExportedVideoIsRecorded()

        #expect(await tracker.renderCallCount == 2)
        #expect(await tracker.exportedVideo == expectedVideo)
        #expect(viewModel.renderState == .loaded(expectedVideo))
        #expect(viewModel.exportProgress == 1)
    }

    @Test
    func retryExportClearsAlertAndReentersLoadingImmediately() async {
        let tracker = ExportRetryTracker()
        let viewModel = ExporterViewModel(
            Video.mock,
            renderVideo: { _, _, _, _, _ in
                _ = await tracker.recordRenderCall()

                do {
                    try await Task.sleep(for: .milliseconds(100))
                    return URL(fileURLWithPath: "/tmp/retry-loading.mp4")
                } catch {
                    throw error
                }
            },
            loadExportedVideo: { url in
                ExportedVideo(
                    url,
                    width: 1280,
                    height: 720,
                    duration: 8,
                    fileSize: 256
                )
            }
        )

        viewModel.renderState = .failed(ExporterError.failed)
        #expect(viewModel.showAlert)

        viewModel.retryExport { _ in }

        #expect(viewModel.showAlert == false)
        #expect(viewModel.renderState == .loading)
        #expect(viewModel.shouldShowLoadingView)

        viewModel.cancelExport()
    }

    @Test
    func repeatedFailuresStillTriggerFailureFeedbackAfterARetry() async {
        let tracker = ExportRetryTracker()
        let viewModel = ExporterViewModel(
            Video.mock,
            renderVideo: { _, _, _, _, _ in
                _ = await tracker.recordRenderCall()
                throw ExporterError.failed
            }
        )

        let firstResult = await viewModel.export()

        #expect(firstResult == nil)
        #expect(viewModel.showAlert)
        #expect(viewModel.shouldShowFailureMessage)

        viewModel.retryExport { _ in }

        for _ in 0..<20 where viewModel.renderState == .loading {
            await Task.yield()
        }

        #expect(await tracker.renderCallCount == 2)
        #expect(viewModel.showAlert)
        #expect(viewModel.shouldShowFailureMessage)
        #expect(viewModel.renderState.id == ExporterViewModel.ExportState.failed(ExporterError.failed).id)
    }

    @Test
    func cancelExportResetsTheSheetStateWithoutShowingFailureFeedback() async {
        let tracker = ExportRetryTracker()
        let viewModel = ExporterViewModel(
            Video.mock,
            renderVideo: { _, _, _, _, _ in
                _ = await tracker.recordRenderCall()

                do {
                    try await Task.sleep(for: .seconds(5))
                    return URL(fileURLWithPath: "/tmp/should-not-complete.mp4")
                } catch {
                    throw error
                }
            }
        )

        viewModel.exportVideo { exportedVideo in
            Task {
                await tracker.recordExportedVideo(exportedVideo)
            }
        }

        for _ in 0..<20 where await tracker.renderCallCount == 0 {
            await Task.yield()
        }

        #expect(viewModel.renderState == .loading)

        viewModel.cancelExport()

        for _ in 0..<20 where viewModel.renderState != .unknown {
            await Task.yield()
        }

        #expect(viewModel.renderState == .unknown)
        #expect(viewModel.showAlert == false)
        #expect(viewModel.exportProgress == 0)
        #expect(viewModel.canCancelExport == false)
        #expect(await tracker.exportedVideo == nil)
    }

    @Test
    func activeLifecycleStateKeepsAnActiveExportRunning() async {
        let tracker = ExportRetryTracker()
        let viewModel = ExporterViewModel(
            Video.mock,
            renderVideo: { _, _, _, _, _ in
                _ = await tracker.recordRenderCall()

                do {
                    try await Task.sleep(for: .seconds(5))
                    return URL(fileURLWithPath: "/tmp/background-short-export.mp4")
                } catch {
                    throw error
                }
            }
        )

        viewModel.exportVideo { exportedVideo in
            Task {
                await tracker.recordExportedVideo(exportedVideo)
            }
        }

        for _ in 0..<20 where await tracker.renderCallCount == 0 {
            await Task.yield()
        }

        viewModel.handleLifecycleStateChange(.active)

        #expect(viewModel.renderState == .loading)
        #expect(viewModel.showAlert == false)
        #expect(await tracker.exportedVideo == nil)

        viewModel.cancelExport()
    }

    @Test
    func inactiveLifecycleStateKeepsAnActiveExportRunning() async {
        let tracker = ExportRetryTracker()
        let viewModel = ExporterViewModel(
            Video.mock,
            renderVideo: { _, _, _, _, _ in
                _ = await tracker.recordRenderCall()

                do {
                    try await Task.sleep(for: .seconds(5))
                    return URL(fileURLWithPath: "/tmp/background-expired-export.mp4")
                } catch {
                    throw error
                }
            }
        )

        viewModel.exportVideo { exportedVideo in
            Task {
                await tracker.recordExportedVideo(exportedVideo)
            }
        }

        for _ in 0..<20 where await tracker.renderCallCount == 0 {
            await Task.yield()
        }

        viewModel.handleLifecycleStateChange(.inactive)

        #expect(viewModel.renderState == .loading)
        #expect(viewModel.showAlert == false)
        #expect(await tracker.exportedVideo == nil)

        viewModel.cancelExport()
    }

    @Test
    func shortInactiveInterruptionDoesNotCancelWhenReturningActive() async {
        let tracker = ExportRetryTracker()
        let dateProvider = LifecycleDateProvider(.init(timeIntervalSinceReferenceDate: 0))
        let viewModel = ExporterViewModel(
            Video.mock,
            renderVideo: { _, _, _, _, _ in
                _ = await tracker.recordRenderCall()

                do {
                    try await Task.sleep(for: .seconds(5))
                    return URL(fileURLWithPath: "/tmp/short-inactive-export.mp4")
                } catch {
                    throw error
                }
            },
            lifecycleNow: dateProvider.currentDate
        )

        viewModel.exportVideo { exportedVideo in
            Task {
                await tracker.recordExportedVideo(exportedVideo)
            }
        }

        for _ in 0..<20 where await tracker.renderCallCount == 0 {
            await Task.yield()
        }

        viewModel.handleLifecycleStateChange(.inactive)
        dateProvider.advance(by: 0.5)
        viewModel.handleLifecycleStateChange(.active)

        #expect(viewModel.renderState == .loading)
        #expect(viewModel.showAlert == false)
        #expect(await tracker.exportedVideo == nil)

        viewModel.cancelExport()
    }

    @Test
    func longInactiveInterruptionCancelsWhenReturningActive() async {
        let tracker = ExportRetryTracker()
        let dateProvider = LifecycleDateProvider(.init(timeIntervalSinceReferenceDate: 0))
        let viewModel = ExporterViewModel(
            Video.mock,
            renderVideo: { _, _, _, _, _ in
                _ = await tracker.recordRenderCall()

                do {
                    try await Task.sleep(for: .seconds(5))
                    return URL(fileURLWithPath: "/tmp/long-inactive-export.mp4")
                } catch {
                    throw error
                }
            },
            lifecycleNow: dateProvider.currentDate
        )

        viewModel.exportVideo { exportedVideo in
            Task {
                await tracker.recordExportedVideo(exportedVideo)
            }
        }

        for _ in 0..<20 where await tracker.renderCallCount == 0 {
            await Task.yield()
        }

        viewModel.handleLifecycleStateChange(.inactive)
        dateProvider.advance(by: 2)
        viewModel.handleLifecycleStateChange(.active)

        for _ in 0..<20 where viewModel.renderState == .loading {
            await Task.yield()
        }

        #expect(viewModel.shouldShowFailureMessage)
        #expect(viewModel.showAlert)
        #expect(
            viewModel.errorMessage
                == "The export was cancelled because the app moved to the background. Please try again."
        )
        #expect(await tracker.exportedVideo == nil)
    }

    @Test
    func backgroundLifecycleStateCancelsExportWithRecoverableFailure() async {
        let tracker = ExportRetryTracker()
        let viewModel = ExporterViewModel(
            Video.mock,
            renderVideo: { _, _, _, _, _ in
                _ = await tracker.recordRenderCall()

                do {
                    try await Task.sleep(for: .seconds(5))
                    return URL(fileURLWithPath: "/tmp/background-cancelled-export.mp4")
                } catch {
                    throw error
                }
            }
        )

        viewModel.exportVideo { exportedVideo in
            Task {
                await tracker.recordExportedVideo(exportedVideo)
            }
        }

        for _ in 0..<20 where await tracker.renderCallCount == 0 {
            await Task.yield()
        }

        viewModel.handleLifecycleStateChange(.background)

        for _ in 0..<20 where viewModel.renderState == .loading {
            await Task.yield()
        }

        #expect(viewModel.shouldShowFailureMessage)
        #expect(viewModel.showAlert)
        #expect(viewModel.canCancelExport == false)
        #expect(
            viewModel.errorMessage
                == "The export was cancelled because the app moved to the background. Please try again."
        )
        #expect(await tracker.exportedVideo == nil)
    }

    @Test
    func retryAfterBackgroundInterruptionStartsANewExport() async {
        let expectedURL = URL(fileURLWithPath: "/tmp/retried-background-export.mp4")
        let expectedVideo = ExportedVideo(
            expectedURL,
            width: 1280,
            height: 720,
            duration: 8,
            fileSize: 256
        )
        let tracker = ExportRetryTracker()
        let viewModel = ExporterViewModel(
            Video.mock,
            renderVideo: { _, _, _, _, _ in
                let renderCallCount = await tracker.recordRenderCall()

                if renderCallCount == 1 {
                    do {
                        try await Task.sleep(for: .seconds(5))
                    } catch {
                        throw error
                    }
                }

                return expectedURL
            },
            loadExportedVideo: { _ in expectedVideo }
        )

        viewModel.exportVideo { exportedVideo in
            Task {
                await tracker.recordExportedVideo(exportedVideo)
            }
        }

        for _ in 0..<20 where await tracker.renderCallCount == 0 {
            await Task.yield()
        }

        viewModel.handleLifecycleStateChange(.background)

        for _ in 0..<20 where viewModel.renderState == .loading {
            await Task.yield()
        }

        #expect(viewModel.shouldShowFailureMessage)

        viewModel.retryExport { exportedVideo in
            Task {
                await tracker.recordExportedVideo(exportedVideo)
            }
        }

        for _ in 0..<20 where await tracker.exportedVideo != expectedVideo {
            await Task.yield()
        }

        #expect(await tracker.renderCallCount == 2)
        #expect(await tracker.exportedVideo == expectedVideo)
        #expect(viewModel.renderState == .loaded(expectedVideo))
        #expect(viewModel.exportProgress == 1)
    }

    @Test
    func exportPassesEditingConfigurationToRenderer() async {
        let expectedURL = URL(fileURLWithPath: "/tmp/crop-forwarded-export.mp4")
        let editingConfiguration = VideoEditingConfiguration(
            crop: .init(
                rotationDegrees: 0,
                isMirrored: false,
                freeformRect: .init(
                    x: 0.1,
                    y: 0.2,
                    width: 0.6,
                    height: 0.5
                )
            )
        )
        let tracker = ExportConfigurationTracker()
        let viewModel = ExporterViewModel(
            Video.mock,
            editingConfiguration: editingConfiguration,
            renderVideo: { _, configuration, _, _, _ in
                await tracker.record(configuration)
                return expectedURL
            },
            loadExportedVideo: { url in
                ExportedVideo(
                    url,
                    width: 1280,
                    height: 720,
                    duration: 8,
                    fileSize: 256
                )
            }
        )

        _ = await viewModel.export()

        #expect(await tracker.editingConfiguration == editingConfiguration)
    }

    @Test
    func exportPassesWatermarkToRenderer() async {
        let expectedURL = URL(fileURLWithPath: "/tmp/watermarked-export.mp4")
        let expectedVideo = ExportedVideo(
            expectedURL,
            width: 1280,
            height: 720,
            duration: 8,
            fileSize: 256
        )
        let image = TestFixtures.makeSolidImage(
            size: CGSize(width: 32, height: 18),
            scale: 1
        )
        let watermark = VideoWatermarkConfiguration(
            image: image,
            position: .topTrailing
        )
        let tracker = ExportWatermarkTracker()
        let viewModel = ExporterViewModel(
            Video.mock,
            watermark: watermark,
            renderVideo: { _, _, _, watermark, _ in
                await tracker.record(watermark)
                return expectedURL
            },
            loadExportedVideo: { _ in expectedVideo }
        )

        viewModel.exportVideo { exportedVideo in
            Task {
                await tracker.recordExportedVideo(exportedVideo)
            }
        }

        await tracker.waitUntilExportedVideoIsRecorded()

        #expect(await tracker.imageSizes == [CGSize(width: 32, height: 18)])
        #expect(await tracker.positions == [.topTrailing])
        #expect(await tracker.exportedVideo == expectedVideo)
    }

}

private actor ExportRetryTracker {

    // MARK: - Private Properties

    private(set) var renderCallCount = 0
    private(set) var exportedVideo: ExportedVideo?

    // MARK: - Public Methods

    func recordRenderCall() -> Int {
        renderCallCount += 1
        return renderCallCount
    }

    func recordExportedVideo(_ video: ExportedVideo) {
        exportedVideo = video
    }

    func waitUntilExportedVideoIsRecorded() async {
        while exportedVideo == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

}

private actor ExportPreparationProbe {

    // MARK: - Private Properties

    private var prepareCount = 0
    private(set) var qualities = [VideoQuality]()
    private var continuations = [CheckedContinuation<ExporterViewModel.ExportPreparationResult, Never>]()

    // MARK: - Public Properties

    var prepareCallCount: Int {
        prepareCount
    }

    // MARK: - Public Methods

    func prepare() async -> ExporterViewModel.ExportPreparationResult {
        prepareCount += 1
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func prepare(for quality: VideoQuality) async -> ExporterViewModel.ExportPreparationResult {
        qualities.append(quality)
        return await prepare()
    }

    func waitUntilPrepareStarted() async {
        while prepareCount == 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func resumePreparation(result: Bool) {
        guard continuations.isEmpty == false else { return }
        continuations.removeFirst().resume(returning: result ? .render : .cancelled)
    }

}

private actor ExportOriginalPreparationProbe {

    // MARK: - Private Properties

    private let preparedVideo: ExportedVideo
    private(set) var qualities = [VideoQuality]()

    // MARK: - Initializer

    init(_ preparedVideo: ExportedVideo) {
        self.preparedVideo = preparedVideo
    }

    // MARK: - Public Methods

    func prepare(for quality: VideoQuality) -> ExporterViewModel.ExportPreparationResult {
        qualities.append(quality)
        return .usePreparedVideo(preparedVideo)
    }

}

private actor ExportConfigurationTracker {

    // MARK: - Private Properties

    private(set) var editingConfiguration: VideoEditingConfiguration?

    // MARK: - Public Methods

    func record(_ configuration: VideoEditingConfiguration) {
        editingConfiguration = configuration
    }

}

private actor ExportWatermarkTracker {

    // MARK: - Private Properties

    private(set) var imageSizes = [CGSize]()
    private(set) var positions = [VideoWatermarkPosition]()
    private(set) var exportedVideo: ExportedVideo?

    // MARK: - Public Methods

    func record(_ watermark: VideoWatermarkRenderRequest?) {
        guard let watermark else { return }
        imageSizes.append(watermark.imageSize)
        positions.append(watermark.position)
    }

    func recordExportedVideo(_ video: ExportedVideo) {
        exportedVideo = video
    }

    func waitUntilExportedVideoIsRecorded() async {
        while exportedVideo == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

}

private actor ExportRenderCallTracker {

    // MARK: - Private Properties

    private(set) var sourceURLs = [URL]()
    private(set) var editingConfigurations = [VideoEditingConfiguration]()
    private(set) var qualities = [VideoQuality]()
    private(set) var exportedVideo: ExportedVideo?

    // MARK: - Public Methods

    func record(
        sourceURL: URL,
        editingConfiguration: VideoEditingConfiguration,
        quality: VideoQuality
    ) {
        sourceURLs.append(sourceURL)
        editingConfigurations.append(editingConfiguration)
        qualities.append(quality)
    }

    func recordExportedVideo(_ video: ExportedVideo) {
        exportedVideo = video
    }

    func waitUntilExportedVideoIsRecorded() async {
        while exportedVideo == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

}

private final class LifecycleDateProvider: @unchecked Sendable {

    // MARK: - Private Properties

    private var date: Date

    // MARK: - Initializer

    init(_ date: Date) {
        self.date = date
    }

    // MARK: - Public Methods

    func currentDate() -> Date {
        date
    }

    func advance(by timeInterval: TimeInterval) {
        date = date.addingTimeInterval(timeInterval)
    }

}
