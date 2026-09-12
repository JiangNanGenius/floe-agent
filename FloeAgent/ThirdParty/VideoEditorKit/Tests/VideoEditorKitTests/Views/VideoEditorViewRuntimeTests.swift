import Foundation
import Testing

@testable import VideoEditorKit

@MainActor
@Suite("VideoEditorViewRuntimeTests", .serialized)
struct VideoEditorViewRuntimeTests {

    // MARK: - Public Methods

    @Test
    func resolvedPlayerLoadStateKeepsBootstrapLoadingUntilTheHostVideoMatches() throws {
        let sourceURL = try TestFixtures.createTemporaryFile(fileExtension: "mp4")

        defer { FileManager.default.removeIfExists(for: sourceURL) }

        #expect(
            VideoEditorView.resolvedPlayerLoadState(
                for: .loaded(sourceURL),
                currentVideoURL: nil
            ) == .loading
        )
        #expect(
            VideoEditorView.resolvedPlayerLoadState(
                for: .loaded(sourceURL),
                currentVideoURL: sourceURL
            ) == .loaded(sourceURL)
        )
    }

    @Test
    func handleMaximumVideoDurationChangeClampsTheLoadedRangeAndPlayerTime() {
        let editorViewModel = EditorViewModel()
        let videoPlayer = VideoPlayerManager()
        var video = Video.mock
        video.rangeDuration = 0...250
        editorViewModel.currentVideo = video
        videoPlayer.currentTime = 120

        VideoEditorView.handleMaximumVideoDurationChange(
            60,
            editorViewModel: editorViewModel,
            videoPlayer: videoPlayer
        )

        #expect(editorViewModel.currentVideo?.rangeDuration == 0...60)
        #expect(videoPlayer.currentTime == 60)
    }

    @Test
    func dismissEditorPublishesDismissalWithoutEditingConfigurationAndCallsDismiss() {
        let editorViewModel = EditorViewModel()
        editorViewModel.currentVideo = Video.mock
        let dismissalRecorder = DismissalRecorder()
        var didCallCallback = false

        VideoEditorView.dismissEditor(
            callbacks: .init(
                onDismissed: {
                    didCallCallback = true
                }
            ),
            dismiss: {
                dismissalRecorder.record()
            }
        )

        #expect(didCallCallback)
        #expect(dismissalRecorder.count == 1)
    }

    @Test
    func handleExportedVideoPausesPlaybackAndPublishesTheExportURL() {
        let videoPlayer = VideoPlayerManager()
        let exportedURL = URL(fileURLWithPath: "/tmp/exported.mp4")
        var publishedURL: URL?

        VideoEditorView.handleExportedVideo(
            .init(
                exportedURL,
                width: 0,
                height: 0,
                duration: 0,
                fileSize: 0
            ),
            videoPlayer: videoPlayer,
            callbacks: .init(
                onExportedVideoURL: { publishedURL = $0 }
            )
        )

        #expect(videoPlayer.isPlaying == false)
        #expect(publishedURL == exportedURL)
    }

    @Test
    func canPresentManualSaveActionRequiresLoadedVideoOnly() {
        #expect(
            VideoEditorView.canPresentManualSaveAction(
                hasLoadedVideo: false,
                hasUnsavedChanges: true
            ) == false
        )
        #expect(
            VideoEditorView.canPresentManualSaveAction(
                hasLoadedVideo: true,
                hasUnsavedChanges: false
            )
        )
        #expect(
            VideoEditorView.canPresentManualSaveAction(
                hasLoadedVideo: true,
                hasUnsavedChanges: true
            )
        )
        #expect(
            VideoEditorView.canPresentManualSaveAction(
                hasLoadedVideo: true,
                hasUnsavedChanges: true,
                isSaving: true
            ) == false
        )
    }

    @Test
    func manualSaveActionPresentationStaysEnabledWhenThereAreNoUnsavedChanges() {
        #expect(
            VideoEditorView.manualSaveActionPresentation(
                hasLoadedVideo: true,
                hasUnsavedChanges: false,
                isSaving: false
            ) == .enabled
        )
    }

    @Test
    func manualSaveActionPresentationShowsProgressWhileSaving() {
        #expect(
            VideoEditorView.manualSaveActionPresentation(
                hasLoadedVideo: true,
                hasUnsavedChanges: true,
                isSaving: true
            ) == .loading
        )
    }

    @Test
    func manualSaveActionPresentationUsesTheSystemCheckmarkSymbol() {
        #expect(VideoEditorManualSaveActionPresentation.enabled.systemImageName == "checkmark")
        #expect(VideoEditorManualSaveActionPresentation.disabled.systemImageName == "checkmark")
    }

    @Test
    func manualSaveRequestDismissesImmediatelyWhenThereAreNoUnsavedChanges() {
        let dismissalRecorder = DismissalRecorder()
        var didStartSave = false

        VideoEditorView.handleManualSaveRequest(
            hasUnsavedChanges: false,
            isSaving: false,
            saveChanges: {
                didStartSave = true
            },
            dismiss: {
                dismissalRecorder.record()
            }
        )

        #expect(didStartSave == false)
        #expect(dismissalRecorder.count == 1)
    }

    @Test
    func manualSaveRequestStartsSaveWhenThereAreUnsavedChanges() {
        let dismissalRecorder = DismissalRecorder()
        var didStartSave = false

        VideoEditorView.handleManualSaveRequest(
            hasUnsavedChanges: true,
            isSaving: false,
            saveChanges: {
                didStartSave = true
            },
            dismiss: {
                dismissalRecorder.record()
            }
        )

        #expect(didStartSave)
        #expect(dismissalRecorder.isEmpty)
    }

    @Test
    func cancelRequestDismissesImmediatelyWhenThereAreNoUnsavedChanges() {
        let dismissalRecorder = DismissalRecorder()
        var confirmationState: VideoEditorCancelConfirmationState?

        VideoEditorView.handleCancelRequest(
            hasUnsavedChanges: false,
            presentConfirmation: { confirmationState = $0 },
            dismiss: {
                dismissalRecorder.record()
            }
        )

        #expect(confirmationState == nil)
        #expect(dismissalRecorder.count == 1)
    }

    @Test
    func cancelRequestCancelsTheCurrentSaveInsteadOfPresentingUnsavedChanges() {
        let dismissalRecorder = DismissalRecorder()
        var confirmationState: VideoEditorCancelConfirmationState?
        var didCancelSave = false

        VideoEditorView.handleCancelRequest(
            hasUnsavedChanges: true,
            isSaving: true,
            cancelSave: {
                didCancelSave = true
            },
            presentConfirmation: { confirmationState = $0 },
            dismiss: {
                dismissalRecorder.record()
            }
        )

        #expect(didCancelSave)
        #expect(confirmationState == nil)
        #expect(dismissalRecorder.isEmpty)
    }

    @Test
    func cancelRequestPresentsConfirmationWhenThereAreUnsavedChanges() {
        let dismissalRecorder = DismissalRecorder()
        var confirmationState: VideoEditorCancelConfirmationState?

        VideoEditorView.handleCancelRequest(
            hasUnsavedChanges: true,
            presentConfirmation: { confirmationState = $0 },
            dismiss: {
                dismissalRecorder.record()
            }
        )

        #expect(confirmationState == .unsavedChanges)
        #expect(dismissalRecorder.isEmpty)
    }

    @Test
    func cancelToolbarActionPresentsUnsavedChangesAsButtonAttachedConfirmationDialog() throws {
        let sourceURL = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/VideoEditorKit/Views/Editor/VideoEditorView.swift")
        let source = try String(contentsOf: sourceURL)
        let actionStart = try #require(source.range(of: "private func cancelToolbarAction"))
        let actionEnd = try #require(
            source[actionStart.lowerBound...].range(of: "\n    private func handlePlaybackLockChange")
        )
        let actionSource = source[actionStart.lowerBound..<actionEnd.lowerBound]

        #expect(actionSource.contains("Button(VideoEditorStrings.cancel, action: onCancel)"))
        #expect(actionSource.contains(".confirmationDialog("))
        #expect(actionSource.contains(".alert(") == false)
    }

    @Test
    func completedManualSaveDismissesTheEditor() {
        let savedVideoURL = URL(filePath: "/tmp/saved.mp4")
        let originalVideoURL = URL(filePath: "/tmp/original.mp4")
        let dismissalRecorder = DismissalRecorder()
        let savedVideo = SavedVideo(
            savedVideoURL,
            originalVideoURL: originalVideoURL,
            editingConfiguration: .init(),
            metadata: .init(
                savedVideoURL,
                width: 1920,
                height: 1080,
                duration: 10,
                fileSize: 1024
            )
        )

        let didComplete = VideoEditorView.completeManualSaveInteraction(
            savedVideo,
            dismiss: {
                dismissalRecorder.record()
            }
        )

        #expect(didComplete)
        #expect(dismissalRecorder.count == 1)
    }

    @Test
    func failedManualSaveDoesNotDismissTheEditor() {
        let dismissalRecorder = DismissalRecorder()

        let didComplete = VideoEditorView.completeManualSaveInteraction(
            nil,
            dismiss: {
                dismissalRecorder.record()
            }
        )

        #expect(didComplete == false)
        #expect(dismissalRecorder.isEmpty)
    }

    @Test
    func syncManualSaveStateStartsCleanForTheFirstLoadedConfiguration() {
        let editorViewModel = EditorViewModel()
        let coordinator = VideoEditorManualSaveCoordinator()
        var video = Video.mock
        video.rangeDuration = 1...8
        editorViewModel.currentVideo = video

        VideoEditorView.syncManualSaveState(
            editorViewModel: editorViewModel,
            manualSaveCoordinator: coordinator
        )

        #expect(coordinator.hasUnsavedChanges == false)
    }

    @Test
    func syncManualSaveStateMarksMeaningfulEditsAsUnsavedAfterBaselineExists() {
        let editorViewModel = EditorViewModel()
        let coordinator = VideoEditorManualSaveCoordinator()
        var video = Video.mock
        video.rangeDuration = 1...8
        editorViewModel.currentVideo = video

        VideoEditorView.syncManualSaveState(
            editorViewModel: editorViewModel,
            manualSaveCoordinator: coordinator
        )

        video.rangeDuration = 2...7
        editorViewModel.currentVideo = video
        VideoEditorView.syncManualSaveState(
            editorViewModel: editorViewModel,
            manualSaveCoordinator: coordinator
        )

        #expect(coordinator.hasUnsavedChanges)
    }

    @Test
    func editingConfigurationChangeTracksUnsavedChangesWithoutPublishingCallbacks() {
        let editorViewModel = EditorViewModel()
        let manualSaveCoordinator = VideoEditorManualSaveCoordinator()
        var video = Video.mock
        video.rangeDuration = 1...8
        editorViewModel.currentVideo = video

        VideoEditorView.handleEditingConfigurationChange(
            editorViewModel: editorViewModel,
            manualSaveCoordinator: manualSaveCoordinator
        )

        video.rangeDuration = 2...7
        editorViewModel.currentVideo = video
        VideoEditorView.handleEditingConfigurationChange(
            editorViewModel: editorViewModel,
            manualSaveCoordinator: manualSaveCoordinator
        )

        #expect(manualSaveCoordinator.hasUnsavedChanges)
    }

    @Test
    func performManualSaveRendersEditedCopyPublishesOnlySavedVideoAndClearsUnsavedChanges() async throws {
        let sourceVideoURL = try TestFixtures.createTemporaryFile(fileExtension: "mp4")
        let savedVideoURL = try TestFixtures.createTemporaryFile(fileExtension: "mp4")
        let thumbnailData = Data([7, 8, 9])
        let renderRecorder = ManualSaveRenderRecorder()
        let savedVideoRecorder = SavedVideoRecorder()
        let manualSaveRenderer = VideoEditorManualSaveRenderer(
            .init(
                renderEditedVideo: { video, editingConfiguration, _ in
                    await renderRecorder.record(
                        videoURL: video.url,
                        editingConfiguration: editingConfiguration
                    )
                    return savedVideoURL
                },
                loadSavedMetadata: { url in
                    ExportedVideo(
                        url,
                        width: 1920,
                        height: 1080,
                        duration: 4,
                        fileSize: 1024
                    )
                },
                makeThumbnailData: { receivedURL in
                    #expect(receivedURL == savedVideoURL)
                    return thumbnailData
                }
            )
        )
        let manualSaveCoordinator = VideoEditorManualSaveCoordinator()
        let editorViewModel = EditorViewModel()
        var video = Video.mock
        video.url = sourceVideoURL
        video.rangeDuration = 1...8
        editorViewModel.currentVideo = video

        VideoEditorView.handleEditingConfigurationChange(
            editorViewModel: editorViewModel,
            manualSaveCoordinator: manualSaveCoordinator
        )

        video.rangeDuration = 2...7
        editorViewModel.currentVideo = video
        VideoEditorView.handleEditingConfigurationChange(
            editorViewModel: editorViewModel,
            manualSaveCoordinator: manualSaveCoordinator
        )

        let savedVideo = await VideoEditorView.performManualSave(
            editorViewModel: editorViewModel,
            fallbackSourceVideoURL: sourceVideoURL,
            manualSaveCoordinator: manualSaveCoordinator,
            manualSaveRenderer: manualSaveRenderer,
            callbacks: .init(
                onSavedVideo: { savedVideo in
                    Task {
                        await savedVideoRecorder.record(savedVideo)
                    }
                }
            )
        )

        let recordedSavedVideo = await savedVideoRecorder.waitForFirstValue()
        let renderRequest = await renderRecorder.waitForFirstValue()

        #expect(savedVideo?.url == savedVideoURL)
        #expect(recordedSavedVideo.url == savedVideoURL)
        #expect(recordedSavedVideo.originalVideoURL == sourceVideoURL)
        #expect(recordedSavedVideo.editingConfiguration.trim.lowerBound == 2)
        #expect(recordedSavedVideo.thumbnailData == thumbnailData)
        #expect(renderRequest.videoURL == sourceVideoURL)
        #expect(renderRequest.editingConfiguration.trim.lowerBound == 2)
        #expect(manualSaveCoordinator.hasUnsavedChanges == false)
        #expect(manualSaveCoordinator.isSaving == false)
    }

    @Test
    func originalExportWithUnsavedChangesUsesTheSavedEditedVideoAsExportOutput() async {
        let savedVideoURL = URL(filePath: "/tmp/saved-original-export.mp4")
        let originalVideoURL = URL(filePath: "/tmp/original-export-source.mp4")
        let expectedSavedVideo = SavedVideo(
            savedVideoURL,
            originalVideoURL: originalVideoURL,
            editingConfiguration: .init(trim: .init(lowerBound: 2, upperBound: 7)),
            metadata: .init(
                savedVideoURL,
                width: 1920,
                height: 1080,
                duration: 5,
                fileSize: 1024
            )
        )

        let result = await VideoEditorView.exportPreparationResult(
            selectedQuality: .original,
            hasUnsavedChanges: true,
            currentEditingConfiguration: expectedSavedVideo.editingConfiguration,
            lastSavedVideo: nil,
            preparedOriginalExportVideo: nil,
            loadedOriginalVideo: nil,
            hasWatermark: false,
            saveCurrentEdit: {
                expectedSavedVideo
            }
        )

        #expect(result == .usePreparedVideo(expectedSavedVideo.metadata))
    }

    @Test
    func originalExportReusesTheLastSavedVideoWhenThereAreNoPendingChanges() async {
        let savedVideoURL = URL(filePath: "/tmp/current-saved-original-export.mp4")
        let editingConfiguration = VideoEditingConfiguration(
            trim: .init(lowerBound: 1, upperBound: 6)
        )
        let lastSavedVideo = SavedVideo(
            savedVideoURL,
            originalVideoURL: URL(filePath: "/tmp/original.mp4"),
            editingConfiguration: editingConfiguration,
            metadata: .init(
                savedVideoURL,
                width: 1080,
                height: 1920,
                duration: 5,
                fileSize: 2048
            )
        )

        let result = await VideoEditorView.exportPreparationResult(
            selectedQuality: .original,
            hasUnsavedChanges: false,
            currentEditingConfiguration: editingConfiguration,
            lastSavedVideo: lastSavedVideo,
            preparedOriginalExportVideo: nil,
            loadedOriginalVideo: nil,
            hasWatermark: false,
            saveCurrentEdit: {
                nil
            }
        )

        #expect(result == .usePreparedVideo(lastSavedVideo.metadata))
    }

    @Test
    func originalExportRendersLastSavedVideoWhenWatermarkExists() async {
        let savedVideoURL = URL(filePath: "/tmp/watermarked-last-saved-original-export.mp4")
        let editingConfiguration = VideoEditingConfiguration(
            trim: .init(lowerBound: 1, upperBound: 6)
        )
        let lastSavedVideo = SavedVideo(
            savedVideoURL,
            originalVideoURL: URL(filePath: "/tmp/original.mp4"),
            editingConfiguration: editingConfiguration,
            metadata: .init(
                savedVideoURL,
                width: 1080,
                height: 1920,
                duration: 5,
                fileSize: 2048
            )
        )

        let result = await VideoEditorView.exportPreparationResult(
            selectedQuality: .original,
            hasUnsavedChanges: false,
            currentEditingConfiguration: editingConfiguration,
            lastSavedVideo: lastSavedVideo,
            preparedOriginalExportVideo: nil,
            loadedOriginalVideo: nil,
            hasWatermark: true,
            saveCurrentEdit: {
                nil
            }
        )

        #expect(result == .render)
    }

    @Test
    func originalExportReusesSessionPreparedVideoWhenThereAreNoPendingChanges() async {
        let preparedOriginalExportVideo = ExportedVideo(
            URL(filePath: "/tmp/session-prepared-original-export.mp4"),
            width: 1920,
            height: 1080,
            duration: 10,
            fileSize: 4096
        )

        let result = await VideoEditorView.exportPreparationResult(
            selectedQuality: .original,
            hasUnsavedChanges: false,
            currentEditingConfiguration: .init(trim: .init(lowerBound: 1, upperBound: 6)),
            lastSavedVideo: nil,
            preparedOriginalExportVideo: preparedOriginalExportVideo,
            preparedOriginalExportEditingConfiguration: .init(trim: .init(lowerBound: 1, upperBound: 6)),
            loadedOriginalVideo: nil,
            hasWatermark: false,
            saveCurrentEdit: {
                nil
            }
        )

        #expect(result == .usePreparedVideo(preparedOriginalExportVideo))
    }

    @Test
    func originalExportRendersSessionPreparedVideoWhenWatermarkExists() async {
        let preparedOriginalExportVideo = ExportedVideo(
            URL(filePath: "/tmp/watermarked-session-prepared-original-export.mp4"),
            width: 1920,
            height: 1080,
            duration: 10,
            fileSize: 4096
        )

        let result = await VideoEditorView.exportPreparationResult(
            selectedQuality: .original,
            hasUnsavedChanges: false,
            currentEditingConfiguration: .init(trim: .init(lowerBound: 1, upperBound: 6)),
            lastSavedVideo: nil,
            preparedOriginalExportVideo: preparedOriginalExportVideo,
            preparedOriginalExportEditingConfiguration: .init(trim: .init(lowerBound: 1, upperBound: 6)),
            loadedOriginalVideo: nil,
            hasWatermark: true,
            saveCurrentEdit: {
                nil
            }
        )

        #expect(result == .render)
    }

    @Test
    func originalExportIgnoresSessionPreparedVideoWhenTheSnapshotDoesNotMatch() async {
        let preparedOriginalExportVideo = ExportedVideo(
            URL(filePath: "/tmp/stale-session-prepared-original-export.mp4"),
            width: 1920,
            height: 1080,
            duration: 10,
            fileSize: 4096
        )

        let result = await VideoEditorView.exportPreparationResult(
            selectedQuality: .original,
            hasUnsavedChanges: false,
            currentEditingConfiguration: .init(trim: .init(lowerBound: 1, upperBound: 6)),
            lastSavedVideo: nil,
            preparedOriginalExportVideo: preparedOriginalExportVideo,
            preparedOriginalExportEditingConfiguration: .init(trim: .init(lowerBound: 2, upperBound: 6)),
            loadedOriginalVideo: nil,
            hasWatermark: false,
            saveCurrentEdit: {
                nil
            }
        )

        #expect(result == .render)
    }

    @Test
    func originalExportUsesLoadedVideoWhenThereAreNoChangesAndNoPreparedSave() async {
        let loadedOriginalVideo = ExportedVideo(
            URL(filePath: "/tmp/loaded-original-export.mp4"),
            width: 1080,
            height: 1920,
            duration: 8,
            fileSize: 2048
        )

        let result = await VideoEditorView.exportPreparationResult(
            selectedQuality: .original,
            hasUnsavedChanges: false,
            currentEditingConfiguration: .initial,
            lastSavedVideo: nil,
            preparedOriginalExportVideo: nil,
            loadedOriginalVideo: loadedOriginalVideo,
            hasWatermark: false,
            saveCurrentEdit: {
                nil
            }
        )

        #expect(result == .usePreparedVideo(loadedOriginalVideo))
    }

    @Test
    func originalExportRendersLoadedVideoWhenWatermarkExists() async {
        let loadedOriginalVideo = ExportedVideo(
            URL(filePath: "/tmp/watermarked-loaded-original-export.mp4"),
            width: 1080,
            height: 1920,
            duration: 8,
            fileSize: 2048
        )

        let result = await VideoEditorView.exportPreparationResult(
            selectedQuality: .original,
            hasUnsavedChanges: false,
            currentEditingConfiguration: .initial,
            lastSavedVideo: nil,
            preparedOriginalExportVideo: nil,
            loadedOriginalVideo: loadedOriginalVideo,
            hasWatermark: true,
            saveCurrentEdit: {
                nil
            }
        )

        #expect(result == .render)
    }

    @Test
    func originalExportWithUnsavedChangesSavesAndRendersWhenWatermarkExists() async {
        let savedVideoURL = URL(filePath: "/tmp/watermarked-unsaved-original-export.mp4")
        let originalVideoURL = URL(filePath: "/tmp/watermarked-unsaved-source.mp4")
        let expectedSavedVideo = SavedVideo(
            savedVideoURL,
            originalVideoURL: originalVideoURL,
            editingConfiguration: .init(trim: .init(lowerBound: 2, upperBound: 7)),
            metadata: .init(
                savedVideoURL,
                width: 1920,
                height: 1080,
                duration: 5,
                fileSize: 1024
            )
        )
        var saveCallCount = 0

        let result = await VideoEditorView.exportPreparationResult(
            selectedQuality: .original,
            hasUnsavedChanges: true,
            currentEditingConfiguration: expectedSavedVideo.editingConfiguration,
            lastSavedVideo: nil,
            preparedOriginalExportVideo: nil,
            loadedOriginalVideo: nil,
            hasWatermark: true,
            saveCurrentEdit: {
                saveCallCount += 1
                return expectedSavedVideo
            }
        )

        #expect(result == .render)
        #expect(saveCallCount == 1)
    }

    @Test
    func scaledExportStillSavesFirstAndThenRendersTheSelectedResolution() async {
        let savedVideoURL = URL(filePath: "/tmp/saved-before-scaled-export.mp4")
        let savedVideo = SavedVideo(
            savedVideoURL,
            originalVideoURL: URL(filePath: "/tmp/original.mp4"),
            editingConfiguration: .init(),
            metadata: .init(
                savedVideoURL,
                width: 1920,
                height: 1080,
                duration: 5,
                fileSize: 1024
            )
        )

        let result = await VideoEditorView.exportPreparationResult(
            selectedQuality: .medium,
            hasUnsavedChanges: true,
            currentEditingConfiguration: savedVideo.editingConfiguration,
            lastSavedVideo: nil,
            preparedOriginalExportVideo: nil,
            loadedOriginalVideo: nil,
            hasWatermark: false,
            saveCurrentEdit: {
                savedVideo
            }
        )

        #expect(result == .render)
    }

    @Test
    func presentExporterPausesPlaybackAndPresentsTheQualitySheet() async throws {
        let editorViewModel = EditorViewModel()
        let videoPlayer = VideoPlayerManager()

        editorViewModel.currentVideo = Video.mock
        videoPlayer.pause(maintainingPlaybackFocus: true)

        VideoEditorView.presentExporter(
            editorViewModel: editorViewModel,
            videoPlayer: videoPlayer
        )

        #expect(videoPlayer.isPlaybackFocusActive == false)

        for _ in 0..<40 where editorViewModel.presentationState.showVideoQualitySheet == false {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(editorViewModel.presentationState.showVideoQualitySheet)
    }

    @Test
    func prepareExporterPresentationOpensQualitySheetBeforeSavingPendingChanges() async throws {
        let sourceVideoURL = try TestFixtures.createTemporaryFile(fileExtension: "mp4")
        let savedVideoURL = try TestFixtures.createTemporaryFile(fileExtension: "mp4")
        let renderProbe = ManualSaveRenderProbe()
        let manualSaveRenderer = VideoEditorManualSaveRenderer(
            .init(
                renderEditedVideo: { video, editingConfiguration, _ in
                    await renderProbe.render(
                        video: video,
                        editingConfiguration: editingConfiguration,
                        savedVideoURL: savedVideoURL
                    )
                },
                loadSavedMetadata: { url in
                    ExportedVideo(
                        url,
                        width: 1280,
                        height: 720,
                        duration: 3,
                        fileSize: 2048
                    )
                },
                makeThumbnailData: { _ in nil }
            )
        )
        let editorViewModel = EditorViewModel()
        let manualSaveCoordinator = VideoEditorManualSaveCoordinator()
        let videoPlayer = VideoPlayerManager()
        var video = Video.mock
        video.url = sourceVideoURL
        video.rangeDuration = 1...8
        editorViewModel.currentVideo = video
        videoPlayer.pause(maintainingPlaybackFocus: true)

        VideoEditorView.handleEditingConfigurationChange(
            editorViewModel: editorViewModel,
            manualSaveCoordinator: manualSaveCoordinator
        )

        video.rangeDuration = 2...7
        editorViewModel.currentVideo = video
        VideoEditorView.handleEditingConfigurationChange(
            editorViewModel: editorViewModel,
            manualSaveCoordinator: manualSaveCoordinator
        )

        await VideoEditorView.prepareExporterPresentation(
            editorViewModel: editorViewModel,
            fallbackSourceVideoURL: sourceVideoURL,
            manualSaveCoordinator: manualSaveCoordinator,
            manualSaveRenderer: manualSaveRenderer,
            videoPlayer: videoPlayer,
            callbacks: .init()
        )

        for _ in 0..<40 where editorViewModel.presentationState.showVideoQualitySheet == false {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(await renderProbe.renderCallCount == 0)
        #expect(manualSaveCoordinator.hasUnsavedChanges)
        #expect(videoPlayer.isPlaybackFocusActive == false)
        #expect(editorViewModel.presentationState.showVideoQualitySheet)
    }

}

@MainActor
private final class DismissalRecorder {

    // MARK: - Private Properties

    private(set) var count = 0
    private var didRecord = false

    var isEmpty: Bool {
        didRecord == false
    }

    // MARK: - Public Methods

    func record() {
        didRecord = true
        count += 1
    }

}

private struct ManualSaveRenderRequest: Sendable {

    // MARK: - Public Properties

    let videoURL: URL
    let editingConfiguration: VideoEditingConfiguration

}

private actor ManualSaveRenderRecorder {

    // MARK: - Private Properties

    private var requests = [ManualSaveRenderRequest]()

    // MARK: - Public Methods

    func record(
        videoURL: URL,
        editingConfiguration: VideoEditingConfiguration
    ) {
        requests.append(
            .init(
                videoURL: videoURL,
                editingConfiguration: editingConfiguration
            )
        )
    }

    func waitForFirstValue() async -> ManualSaveRenderRequest {
        while requests.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }

        return requests[0]
    }

}

private actor ManualSaveRenderProbe {

    // MARK: - Private Properties

    private var renderCount = 0
    private var continuations = [CheckedContinuation<Void, Never>]()

    // MARK: - Public Properties

    var renderCallCount: Int {
        renderCount
    }

    // MARK: - Public Methods

    func render(
        video: Video,
        editingConfiguration: VideoEditingConfiguration,
        savedVideoURL: URL
    ) async -> URL {
        _ = video
        _ = editingConfiguration
        renderCount += 1
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }

        return savedVideoURL
    }

    func waitUntilCount(is expectedCount: Int) async {
        while renderCount < expectedCount {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func resumeNext() {
        guard continuations.isEmpty == false else { return }
        continuations.removeFirst().resume()
    }

}

private actor SavedVideoRecorder {

    // MARK: - Private Properties

    private var values = [SavedVideo]()

    // MARK: - Public Methods

    func record(_ value: SavedVideo) {
        values.append(value)
    }

    func waitForFirstValue() async -> SavedVideo {
        while values.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }

        return values[0]
    }

}
