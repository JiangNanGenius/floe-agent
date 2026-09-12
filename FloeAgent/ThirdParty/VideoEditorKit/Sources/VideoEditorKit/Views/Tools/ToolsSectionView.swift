import SwiftUI

struct ToolsSectionView: View {

    // MARK: - States

    @State private var draftState = EditorToolDraftState()
    @State private var draftPresentationTool: ToolEnum?

    // MARK: - Body

    var body: some View {
        let currentVideo = editorViewModel.currentVideo
        let cropPresentationSummary = editorViewModel.cropPresentationSummary
        let transcriptDocument = editorViewModel.transcriptDocument
        let selectedTool = editorViewModel.presentationState.selectedTool
        let draftPresentationState = EditorToolbarItemDraftPresentationState(
            selectedTool: draftPresentationTool == selectedTool ? selectedTool : nil,
            draftState: draftState,
            selectedPreset: cropPresentationSummary.selectedPreset,
            transcriptDraftDocument: editorViewModel.transcriptDraftDocument
        )

        VideoEditorToolsTrayView(
            selectedTool: selectedToolBinding,
            initialSheetHeight: VideoEditorToolSheetPresentationPolicy.initialSheetHeight(for:)
        ) {
            PagedToolsRow(configuration.tools) { tool in
                toolbarItemPresentation(
                    for: tool,
                    currentVideo: currentVideo,
                    cropPresentationSummary: cropPresentationSummary,
                    transcriptDocument: transcriptDocument,
                    draftPresentationState: draftPresentationState
                )
            } action: { toolAvailability in
                handleToolTap(toolAvailability)
            }
        } sheetContent: { tool in
            toolSheet(tool)
        }
        .onChange(of: editorViewModel.currentVideo) { _, newValue in
            if newValue == nil {
                selectedToolBinding.wrappedValue = nil
            }
            editorViewModel.handleCurrentVideoChange(
                newValue,
                videoPlayer: videoPlayer
            )
        }
    }

    // MARK: - Private Properties

    private let videoPlayer: VideoPlayerManager
    private let editorViewModel: EditorViewModel
    private let configuration: VideoEditorView.Configuration

    // MARK: - Initializer

    init(
        _ videoPlayer: VideoPlayerManager,
        editorVM: EditorViewModel,
        configuration: VideoEditorView.Configuration
    ) {
        self.videoPlayer = videoPlayer
        self.editorViewModel = editorVM
        self.configuration = configuration
    }

}

extension ToolsSectionView {

    private func toolSheet(_ tool: ToolEnum) -> some View {
        VideoEditorToolSheetView(
            title: tool.title,
            contentInteraction: VideoEditorToolSheetPresentationPolicy.contentInteraction(for: tool),
            onClose: {
                editorViewModel.closeSelectedTool()
            },
            onReset: {
                draftState = HostedVideoEditorToolActionCoordinator.reset(
                    tool,
                    currentDraftState: draftState,
                    editorViewModel: editorViewModel,
                    videoPlayer: videoPlayer
                )
            },
            onAppear: {
                draftState = HostedVideoEditorToolActionCoordinator.loadDraftState(
                    for: tool,
                    currentState: draftState,
                    editorViewModel: editorViewModel
                )
                draftPresentationTool = tool
            },
            content: {
                if editorViewModel.currentVideo != nil {
                    VideoEditorToolContentView(
                        tool: tool,
                        draftState: $draftState,
                        editorViewModel: editorViewModel,
                        videoPlayer: videoPlayer
                    )
                } else {
                    EmptyView()
                }
            },
            footer: {
                sheetFooter(tool)
            }
        )
    }

}

extension ToolsSectionView {

    // MARK: - Private Properties

    private var selectedToolBinding: Binding<ToolEnum?> {
        Binding(
            get: { editorViewModel.presentationState.selectedTool },
            set: { newValue in
                if let newValue {
                    editorViewModel.selectTool(newValue)
                } else {
                    editorViewModel.closeSelectedTool()
                }
            }
        )
    }

    // MARK: - Private Methods

    private func canApply(_ tool: ToolEnum) -> Bool {
        HostedVideoEditorToolActionCoordinator.canApply(
            tool,
            draftState: draftState,
            editorViewModel: editorViewModel
        )
    }

    private func toolbarItemPresentation(
        for tool: ToolEnum,
        currentVideo: Video?,
        cropPresentationSummary: EditorCropPresentationSummary,
        transcriptDocument: TranscriptDocument?,
        draftPresentationState: EditorToolbarItemDraftPresentationState
    ) -> EditorToolbarItemPresentation {
        EditorToolbarItemPresentationResolver.resolve(
            for: tool,
            video: currentVideo,
            cropPresentationSummary: cropPresentationSummary,
            transcriptDocument: transcriptDocument,
            draftPresentationState: draftPresentationState
        )
    }

    private func handleToolTap(_ toolAvailability: ToolAvailability) {
        draftPresentationTool = nil
        HostedVideoEditorToolActionCoordinator.handleToolTap(
            toolAvailability,
            configuration: configuration,
            editorViewModel: editorViewModel
        )
    }

    private func applyFooter(_ tool: ToolEnum) -> some View {
        let isEnabled = canApply(tool)

        return PrimaryActionButton(
            title: VideoEditorStrings.apply,
            isEnabled: isEnabled
        ) {
            applyTool(tool)
        }
    }

    private func applyTool(_ tool: ToolEnum) {
        HostedVideoEditorToolActionCoordinator.apply(
            tool,
            draftState: draftState,
            editorViewModel: editorViewModel,
            videoPlayer: videoPlayer
        )
    }

    @ViewBuilder
    private func sheetFooter(_ tool: ToolEnum) -> some View {
        switch tool {
        case .transcript:
            transcriptFooter
        case .cut, .speed, .presets, .audio, .adjusts:
            EmptyView()
        }
    }

    @ViewBuilder
    private var transcriptFooter: some View {
        if let action = TranscriptToolFooterActionResolver.resolve(
            isTranscriptionAvailable: editorViewModel.isTranscriptionAvailable,
            transcriptState: editorViewModel.transcriptState,
            document: editorViewModel.transcriptDraftDocument
        ) {
            switch action {
            case .transcribe:
                PrimaryActionButton(title: action.title) {
                    editorViewModel.transcribeCurrentVideo()
                }
            case .retry:
                PrimaryActionButton(title: action.title) {
                    editorViewModel.transcribeCurrentVideo()
                }
            case .apply:
                applyFooter(.transcript)
            }
        }
    }

}

#Preview {
    ToolsSectionViewPreviewHost()
        .padding(.vertical, 24)
        .background(Theme.rootBackground)
}

#Preview("Audio Tool Selected") {
    ToolsSectionViewPreviewHost(initialTool: .audio)
        .padding(.vertical, 24)
        .background(Theme.rootBackground)
}

@MainActor
private struct ToolsSectionViewPreviewHost: View {

    // MARK: - States

    @State private var editorViewModel: EditorViewModel
    @State private var videoPlayer: VideoPlayerManager

    // MARK: - Private Properties

    private let configuration: VideoEditorView.Configuration

    // MARK: - Body

    var body: some View {
        ToolsSectionView(
            videoPlayer,
            editorVM: editorViewModel,
            configuration: configuration
        )
    }

    // MARK: - Initializer

    init(initialTool: ToolEnum? = nil) {
        let editorViewModel = EditorViewModel()
        let videoPlayer = VideoPlayerManager()
        var video = Video.mock

        video.presentationSize = CGSize(width: 1080, height: 1920)
        video.geometrySize = CGSize(width: 1080, height: 1920)
        video.frameSize = CGSize(width: 1080, height: 1920)

        editorViewModel.currentVideo = video
        editorViewModel.handleCurrentVideoChange(
            video,
            videoPlayer: videoPlayer
        )

        if let initialTool {
            editorViewModel.selectTool(initialTool)
        }

        _editorViewModel = State(initialValue: editorViewModel)
        _videoPlayer = State(initialValue: videoPlayer)
        configuration = .init(
            tools: ToolAvailability.enabled(ToolEnum.all)
        )
    }
}
