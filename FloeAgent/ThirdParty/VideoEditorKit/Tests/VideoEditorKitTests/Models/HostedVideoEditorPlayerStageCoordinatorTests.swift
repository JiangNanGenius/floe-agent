import Foundation
import Testing

@testable import VideoEditorKit

@MainActor
@Suite("HostedVideoEditorPlayerStageCoordinatorTests", .serialized)
struct HostedPlayerStageTests {

    // MARK: - Public Methods

    @Test
    func presentationStateMapsEachHostLoadState() {
        #expect(
            HostedVideoEditorPlayerStageCoordinator.presentationState(
                for: .unknown
            ) == .unknown
        )
        #expect(
            HostedVideoEditorPlayerStageCoordinator.presentationState(
                for: .loading
            ) == .loading
        )
        #expect(
            HostedVideoEditorPlayerStageCoordinator.presentationState(
                for: .loaded(URL(fileURLWithPath: "/tmp/video.mp4"))
            ) == .loaded
        )
        #expect(
            HostedVideoEditorPlayerStageCoordinator.presentationState(
                for: .failed
            ) == .failed
        )
    }

    @Test
    func loadedPlayerStateKeepsLoadingUntilTheFirstFrameIsReady() {
        let url = URL(fileURLWithPath: "/tmp/video.mp4")

        #expect(
            HostedVideoEditorPlayerStageCoordinator.presentationState(
                for: .loaded(url),
                isPreviewReadyForDisplay: false
            ) == .loading
        )
        #expect(
            HostedVideoEditorPlayerStageCoordinator.presentationState(
                for: .loaded(url),
                isPreviewReadyForDisplay: true
            ) == .loaded
        )
    }

    @Test
    func loadingPlaceholderUsesKnownSourceAspectRatioWhenAvailable() {
        let presentation = HostedVideoEditorPlayerStageCoordinator.loadingPlaceholderPresentation(
            source: .init(
                naturalSize: CGSize(width: 1080, height: 1920),
                preferredTransform: .identity,
                userRotationDegrees: 0,
                isMirrored: false
            )
        )

        #expect(presentation.usesKnownVideoDimensions)
        #expect(abs(presentation.aspectRatio - 0.5625) < 0.0001)
    }

    @Test
    func loadingPlaceholderFallsBackToWidescreenWhenDimensionsAreUnavailable() {
        let presentation = HostedVideoEditorPlayerStageCoordinator.loadingPlaceholderPresentation(
            source: nil
        )

        #expect(presentation.usesKnownVideoDimensions == false)
        #expect(abs(presentation.aspectRatio - (16.0 / 9.0)) < 0.0001)
    }

    @Test
    func playerLayoutIDUsesTheCurrentVideoAndCanvasState() {
        let editorViewModel = EditorViewModel()
        var video = Video.mock
        video.rotation = 90
        editorViewModel.currentVideo = video
        editorViewModel.cropPresentationState.canvasEditorState.restore(
            .init(
                preset: .facebookPost,
                freeCanvasSize: CGSize(width: 1080, height: 1350),
                transform: .identity,
                showsSafeAreaOverlay: false
            )
        )

        let layoutID = HostedVideoEditorPlayerStageCoordinator.playerLayoutID(
            editorViewModel: editorViewModel
        )

        #expect(layoutID?.contains(video.id.uuidString) == true)
        #expect(layoutID?.contains("90") == true)
        #expect(layoutID?.contains("1080") == true)
        #expect(layoutID?.contains("1350") == true)
    }

    @Test
    func transcriptOverlayContextReturnsTheActiveSegmentAndLayoutIdentity() {
        let editorViewModel = EditorViewModel()
        var video = Video.mock
        video.rangeDuration = 0...10
        editorViewModel.currentVideo = video
        editorViewModel.transcriptState = .loaded
        editorViewModel.cropPresentationState.canvasEditorState.restore(
            .init(
                preset: .facebookPost,
                freeCanvasSize: CGSize(width: 1080, height: 1350),
                transform: .identity,
                showsSafeAreaOverlay: false
            )
        )

        let activeWordID = UUID()
        let document = TranscriptDocument(
            segments: [
                .init(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 0,
                        sourceEndTime: 4,
                        timelineStartTime: 0,
                        timelineEndTime: 4
                    ),
                    originalText: "hello world",
                    editedText: "hello world",
                    words: [
                        .init(
                            id: activeWordID,
                            timeMapping: .init(
                                sourceStartTime: 1,
                                sourceEndTime: 2,
                                timelineStartTime: 1,
                                timelineEndTime: 2
                            ),
                            originalText: "hello",
                            editedText: "hello"
                        )
                    ]
                )
            ],
            overlayPosition: .top,
            overlaySize: .large
        )
        editorViewModel.transcriptDocument = document
        editorViewModel.transcriptDraftDocument = document

        let context = HostedVideoEditorPlayerStageCoordinator.transcriptOverlayContext(
            editorViewModel: editorViewModel,
            currentTimelineTime: 1.5
        )

        #expect(context?.transcriptDocument == document)
        #expect(context?.activeSegment.editedText == "hello world")
        #expect(context?.activeWordID == activeWordID)
        #expect(context?.layoutID.contains("top") == true)
        #expect(context?.layoutID.contains("large") == true)
    }

}
