import SwiftUI

/// The main SwiftUI entry point for embedding the VideoEditorKit editor in a host app.
///
/// Create it with a `VideoEditorSession` when you need asynchronous source loading or resume
/// behavior, or use one of the convenience initializers when you already have a local file URL.
@MainActor
public struct VideoEditorView: View {

    // MARK: - Environments

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    // MARK: - States

    @State private var editorViewModel = EditorViewModel()
    @State private var exportLifecycleState: ExportLifecycleState = .active
    @State private var cancelConfirmationState: VideoEditorCancelConfirmationState?
    @State private var manualSaveCoordinator = VideoEditorManualSaveCoordinator()
    @State private var lastSavedVideo: SavedVideo?
    @State private var manualSaveTask: Task<Void, Never>?
    @State private var videoPlayer = VideoPlayerManager()

    // MARK: - Public Properties

    /// The manual-save payload emitted by the editor.
    public typealias SavedVideo = VideoEditorKit.SavedVideo
    /// The host-controlled source and restore payload for one editing run.
    public typealias Session = VideoEditorSession
    /// Callback bundle invoked as the user edits, dismisses, and exports content.
    public typealias Callbacks = VideoEditorCallbacks
    /// Runtime configuration that controls tool visibility, export options, and integrations.
    public typealias Configuration = VideoEditorConfiguration
    /// Export-only watermark configuration exposed through the editor namespace.
    public typealias WatermarkConfiguration = VideoWatermarkConfiguration
    /// Export-only watermark corner exposed through the editor namespace.
    public typealias WatermarkPosition = VideoWatermarkPosition

    // MARK: - Body

    public var body: some View {
        @Bindable var bindablePresentationState = editorViewModel.presentationState

        VideoEditorShellView(
            title,
            session: session,
            callbacks: callbacks,
            onCancel: requestEditorDismissal,
            onBootstrapStateChanged: syncPlayerLoadState,
            cancelAction: { onCancel in
                cancelToolbarAction(onCancel: onCancel)
            },
            secondaryAction: {
                exportToolbarAction
            },
            primaryAction: {
                saveToolbarAction
            }
        ) { availableSize, resolvedSourceVideoURL in
            VideoEditorLoadedView(
                availableSize: availableSize,
                resolvedSourceVideoURL: resolvedSourceVideoURL,
                isPlaybackFocused: videoPlayer.isPlaybackFocusActive,
                onLoad: bootstrapEditorContent
            ) {
                PlayerHolderView(
                    editorViewModel,
                    videoPlayer: videoPlayer
                )
            } controlsContent: {
                VideoEditorTrimSectionView(
                    editorViewModel,
                    videoPlayer: videoPlayer
                )
            } toolsContent: {
                ToolsSectionView(
                    videoPlayer,
                    editorVM: editorViewModel,
                    configuration: configuration
                )
            }
            .safeAreaPadding(.horizontal)
            .safeAreaPadding(.top)
            .disabled(manualSaveCoordinator.isSaving)
        }
        .onDisappear(perform: handleDisappear)
        .onChange(of: scenePhase) { _, newScenePhase in
            handleScenePhaseChange(newScenePhase)
        }
        .task(id: scenePhase) {
            handleScenePhaseChange(scenePhase)
        }
        .dynamicSheet(
            isPresented: $bindablePresentationState.showVideoQualitySheet,
            initialHeight: 420
        ) {
            exportSheetContent
        }
        .fullScreenCover(isPresented: $bindablePresentationState.showRecordView) {
            RecordVideoView(handleRecordedVideo)
        }
        .onChange(of: videoPlayer.isPlaybackFocusActive) { _, isPlaybackFocusActive in
            handlePlaybackLockChange(isPlaybackFocusActive)
        }
        .onChange(of: editorViewModel.presentationState.editingConfigurationRevision) { _, _ in
            handleEditingConfigurationChange()
        }
        .onChange(of: configuration.tools) { _, newValue in
            editorViewModel.setToolAvailability(newValue)
        }
        .onChange(of: configuration.maximumVideoDuration) { _, newValue in
            Self.handleMaximumVideoDurationChange(
                newValue,
                editorViewModel: editorViewModel,
                videoPlayer: videoPlayer
            )
        }
    }

    // MARK: - Private Properties

    private let title: String?
    private let session: Session
    private let configuration: Configuration
    private let callbacks: Callbacks

    @ViewBuilder
    private var exportSheetContent: some View {
        if let video = editorViewModel.currentVideo {
            VideoExporterContainerView(
                lifecycleState: $exportLifecycleState,
                video: video,
                editingConfiguration: resolvedExportEditingConfiguration,
                exportQualities: configuration.exportQualities,
                watermark: configuration.watermark,
                prepareForExport: prepareCurrentExport,
                shouldShowSavingBeforeExport: { _ in manualSaveCoordinator.hasUnsavedChanges },
                onBlockedQualityTap: configuration.notifyBlockedExportQualityTap(for:),
                onExported: { exportedVideo in
                    Self.handleExportedVideo(
                        exportedVideo,
                        videoPlayer: videoPlayer,
                        callbacks: callbacks
                    )
                }
            )
        }
    }

    private var resolvedExportEditingConfiguration: VideoEditingConfiguration {
        editorViewModel.exportEditingConfiguration() ?? .initial
    }

    private var canSaveCurrentEdit: Bool {
        Self.canPresentManualSaveAction(
            hasLoadedVideo: editorViewModel.currentVideo != nil,
            hasUnsavedChanges: manualSaveCoordinator.hasUnsavedChanges,
            isSaving: manualSaveCoordinator.isSaving
        )
    }

    private var cancelConfirmationBinding: Binding<Bool> {
        .init(
            get: { cancelConfirmationState != nil },
            set: { isPresented in
                guard isPresented == false else { return }
                cancelConfirmationState = nil
            }
        )
    }

    @ViewBuilder
    private var exportToolbarAction: some View {
        if editorViewModel.currentVideo != nil {
            Button(action: presentExporter) {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel(VideoEditorStrings.export)
            .videoEditorToolbarActionButtonStyle(VideoEditorToolbarActionLayout.exportButtonStyle)
            .disabled(manualSaveCoordinator.isSaving)
        }
    }

    @ViewBuilder
    private var saveToolbarAction: some View {
        let presentation = Self.manualSaveActionPresentation(
            hasLoadedVideo: editorViewModel.currentVideo != nil,
            hasUnsavedChanges: manualSaveCoordinator.hasUnsavedChanges,
            isSaving: manualSaveCoordinator.isSaving
        )

        if presentation != .hidden {
            Button(action: saveCurrentEdit) {
                Group {
                    if presentation == .loading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: presentation.systemImageName)
                    }
                }
                .foregroundStyle(.white)
            }
            .accessibilityLabel(VideoEditorStrings.save)
            .videoEditorToolbarActionButtonStyle(VideoEditorToolbarActionLayout.saveButtonStyle)
            .disabled(presentation != .enabled)
        }
    }

    // MARK: - Initializer

    /// Creates the editor from an explicit session object.
    public init(
        _ title: String? = nil,
        session: Session,
        configuration: Configuration = .init(),
        callbacks: Callbacks = .init()
    ) {
        self.title = title
        self.session = session
        self.configuration = configuration
        self.callbacks = callbacks
    }

    /// Creates the editor from a session source and an optional restore snapshot.
    public init(
        _ title: String? = nil,
        source: Session.Source? = nil,
        editingConfiguration: VideoEditingConfiguration? = nil,
        configuration: Configuration = .init(),
        onSavedVideo: @escaping (SavedVideo) -> Void = { _ in },
        onSourceVideoResolved: @escaping (URL) -> Void = { _ in },
        onDismissed: (() -> Void)? = nil,
        onExportedVideoURL: @escaping (URL) -> Void = { _ in }
    ) {
        self.init(
            title,
            session: .init(
                source: source,
                editingConfiguration: editingConfiguration
            ),
            configuration: configuration,
            callbacks: .init(
                onSavedVideo: onSavedVideo,
                onSourceVideoResolved: onSourceVideoResolved,
                onDismissed: onDismissed,
                onExportedVideoURL: onExportedVideoURL
            )
        )
    }

    /// Creates the editor directly from a local source file URL.
    public init(
        _ title: String? = nil,
        sourceVideoURL: URL?,
        editingConfiguration: VideoEditingConfiguration? = nil,
        configuration: Configuration = .init(),
        onSavedVideo: @escaping (SavedVideo) -> Void = { _ in },
        onSourceVideoResolved: @escaping (URL) -> Void = { _ in },
        onDismissed: (() -> Void)? = nil,
        onExportedVideoURL: @escaping (URL) -> Void = { _ in }
    ) {
        self.init(
            title,
            source: sourceVideoURL.map { .fileURL($0) },
            editingConfiguration: editingConfiguration,
            configuration: configuration,
            onSavedVideo: onSavedVideo,
            onSourceVideoResolved: onSourceVideoResolved,
            onDismissed: onDismissed,
            onExportedVideoURL: onExportedVideoURL
        )
    }

    // MARK: - Private Methods

    private func bootstrapEditorContent(
        _ availableSize: CGSize,
        _ resolvedSourceVideoURL: URL
    ) {
        Self.bootstrapEditorContent(
            availableSize: availableSize,
            resolvedSourceVideoURL: resolvedSourceVideoURL,
            sessionEditingConfiguration: session.editingConfiguration,
            configuration: configuration,
            editorViewModel: editorViewModel,
            videoPlayer: videoPlayer
        )
    }

    @ViewBuilder
    private func cancelToolbarAction(onCancel: @escaping () -> Void) -> some View {
        Button(VideoEditorStrings.cancel, action: onCancel)
            .confirmationDialog(
                VideoEditorStrings.unsavedChangesAlertTitle,
                isPresented: cancelConfirmationBinding,
                titleVisibility: .visible,
                presenting: cancelConfirmationState
            ) { _ in
                Button(VideoEditorStrings.save, action: saveChangesAndDismiss)

                Button(VideoEditorStrings.discardUnsavedChanges, role: .destructive) {
                    discardChangesAndDismiss()
                }

                Button(VideoEditorStrings.cancel, role: .cancel) {
                    cancelConfirmationState = nil
                }
            } message: { _ in
                Text(VideoEditorStrings.unsavedChangesAlertMessage)
            }
    }

    private func handlePlaybackLockChange(_ isPlaybackFocusActive: Bool) {
        guard isPlaybackFocusActive else { return }
        editorViewModel.closeSelectedTool()
    }

    private func requestEditorDismissal() {
        Self.handleCancelRequest(
            hasUnsavedChanges: manualSaveCoordinator.hasUnsavedChanges,
            isSaving: manualSaveCoordinator.isSaving,
            cancelSave: cancelCurrentManualSave,
            presentConfirmation: { state in
                cancelConfirmationState = state
            },
            dismiss: dismissEditorImmediately
        )
    }

    private func dismissEditorImmediately() {
        Self.dismissEditor(
            callbacks: callbacks,
            dismiss: dismiss.callAsFunction
        )
    }

    private func presentExporter() {
        guard manualSaveTask == nil else { return }

        Task {
            await Self.prepareExporterPresentation(
                editorViewModel: editorViewModel,
                fallbackSourceVideoURL: session.sourceVideoURL,
                manualSaveCoordinator: manualSaveCoordinator,
                videoPlayer: videoPlayer,
                callbacks: callbacks
            )
        }
    }

    private func saveCurrentEdit() {
        Self.handleManualSaveRequest(
            hasUnsavedChanges: manualSaveCoordinator.hasUnsavedChanges,
            isSaving: manualSaveCoordinator.isSaving,
            saveChanges: {
                startManualSaveTask { savedVideo in
                    Self.completeManualSaveInteraction(
                        savedVideo,
                        dismiss: dismissEditorImmediately
                    )
                }
            },
            dismiss: dismissEditorImmediately
        )
    }

    @discardableResult
    private func performCurrentManualSave() async -> SavedVideo? {
        let savedVideo = await Self.performManualSave(
            editorViewModel: editorViewModel,
            fallbackSourceVideoURL: session.sourceVideoURL,
            manualSaveCoordinator: manualSaveCoordinator,
            callbacks: callbacks
        )

        if savedVideo != nil {
            lastSavedVideo = savedVideo
        }

        return savedVideo
    }

    private func prepareCurrentExport(
        _ selectedQuality: VideoQuality
    ) async -> ExporterViewModel.ExportPreparationResult {
        await Self.exportPreparationResult(
            selectedQuality: selectedQuality,
            hasUnsavedChanges: manualSaveCoordinator.hasUnsavedChanges,
            currentEditingConfiguration: editorViewModel.currentEditingConfiguration(),
            lastSavedVideo: lastSavedVideo,
            preparedOriginalExportVideo: session.preparedOriginalExportVideo,
            preparedOriginalExportEditingConfiguration: session.preparedOriginalExportEditingConfiguration,
            loadedOriginalVideo: loadedOriginalExportVideo,
            hasWatermark: configuration.watermark?.isRenderableWatermark == true,
            saveCurrentEdit: performCurrentManualSave
        )
    }

    private func handleEditingConfigurationChange() {
        Self.handleEditingConfigurationChange(
            editorViewModel: editorViewModel,
            manualSaveCoordinator: manualSaveCoordinator
        )
    }

    private func saveChangesAndDismiss() {
        cancelConfirmationState = nil
        startManualSaveTask { savedVideo in
            Self.completeManualSaveInteraction(
                savedVideo,
                dismiss: dismissEditorImmediately
            )
        }
    }

    private func discardChangesAndDismiss() {
        cancelConfirmationState = nil
        manualSaveCoordinator.reset()
        dismissEditorImmediately()
    }

    private func handleRecordedVideo(_ url: URL) {
        manualSaveCoordinator.reset()
        lastSavedVideo = nil
        Self.handleRecordedVideo(
            url,
            editorViewModel: editorViewModel,
            videoPlayer: videoPlayer
        )
    }

    private func handleScenePhaseChange(_ scenePhase: ScenePhase) {
        exportLifecycleState = .init(scenePhase: scenePhase)
    }

    private func handleDisappear() {
        manualSaveTask?.cancel()
        Self.handleDisappear(editorViewModel: editorViewModel)
    }

    private func startManualSaveTask(
        onSuccess: @escaping (SavedVideo) -> Void
    ) {
        guard manualSaveTask == nil else { return }

        manualSaveTask = Task {
            defer {
                manualSaveTask = nil
            }

            guard let savedVideo = await performCurrentManualSave() else { return }
            guard Task.isCancelled == false else { return }

            onSuccess(savedVideo)
        }
    }

    private func cancelCurrentManualSave() {
        manualSaveTask?.cancel()
        manualSaveTask = nil
        manualSaveCoordinator.failSaving(
            currentEditingConfiguration: editorViewModel.currentEditingConfiguration()
        )
    }

    private func syncPlayerLoadState(
        for bootstrapState: VideoEditorSessionBootstrapCoordinator.BootstrapState
    ) {
        if case .loaded = bootstrapState {
            manualSaveCoordinator.reset()
        }

        videoPlayer.loadState = Self.resolvedPlayerLoadState(
            for: bootstrapState,
            currentVideoURL: editorViewModel.currentVideo?.url
        )
    }

}

extension VideoEditorView {

    // MARK: - Private Properties

    private var loadedOriginalExportVideo: ExportedVideo? {
        guard let video = editorViewModel.currentVideo else { return nil }

        return ExportedVideo(
            video.url,
            width: max(video.presentationSize.width, 0),
            height: max(video.presentationSize.height, 0),
            duration: max(video.originalDuration, 0),
            fileSize: resolvedFileSize(for: video.url)
        )
    }

    // MARK: - Private Methods

    private func resolvedFileSize(for url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path())
        let sizeValue = attributes?[.size] as? NSNumber
        return max(sizeValue?.int64Value ?? 0, 0)
    }

}

#Preview {
    let previewVideoURL = Bundle.module.url(
        forResource: "preview",
        withExtension: "mp4"
    )

    Group {
        if let previewVideoURL {
            VideoEditorView(
                "Preview",
                sourceVideoURL: previewVideoURL
            )
        } else {
            ContentUnavailableView(
                VideoEditorStrings.previewVideoMissingTitle,
                systemImage: "video.slash",
                description: Text(VideoEditorStrings.previewVideoMissingDescription)
            )
        }
    }
}
