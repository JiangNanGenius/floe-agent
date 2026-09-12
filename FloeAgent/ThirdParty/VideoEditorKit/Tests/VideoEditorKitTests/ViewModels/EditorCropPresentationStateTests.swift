import Testing

@testable import VideoEditorKit

@Suite("EditorCropPresentationStateTests")
struct EditorCropPresentationStateTests {

    // MARK: - Public Methods

    @Test
    @MainActor
    func applyRestoresTheFullCropEditingState() {
        let state = EditorCropPresentationState()
        let snapshot = VideoCanvasSnapshot(
            preset: .story,
            freeCanvasSize: .init(width: 300, height: 500),
            transform: .init(
                normalizedOffset: .init(x: 18, y: -12),
                zoom: 1.2
            ),
            showsSafeAreaOverlay: true
        )
        let editingState = EditorCropEditingState(
            freeformRect: .init(
                x: 0.1,
                y: 0.2,
                width: 0.7,
                height: 0.6
            ),
            socialVideoDestination: .youtubeShorts,
            showsSafeAreaOverlay: true,
            canvasSnapshot: snapshot
        )

        state.apply(editingState)

        #expect(state.freeformRect == editingState.freeformRect)
        #expect(state.socialVideoDestination == .youtubeShorts)
        #expect(state.showsSafeAreaOverlay == true)
        #expect(state.canvasEditorState.snapshot() == snapshot)
        #expect(state.editingState == editingState)
    }

    @Test
    @MainActor
    func shouldShowCropOverlayTracksActiveRectOrCanvasTransform() {
        let state = EditorCropPresentationState()

        #expect(state.shouldShowCropOverlay == false)

        state.freeformRect = .init(
            x: 0.1,
            y: 0.1,
            width: 0.8,
            height: 0.8
        )

        #expect(state.shouldShowCropOverlay == true)

        state.freeformRect = nil
        state.canvasEditorState.restore(
            .init(
                preset: .free,
                freeCanvasSize: .zero,
                transform: .init(zoom: 1.1),
                showsSafeAreaOverlay: false
            )
        )

        #expect(state.shouldShowCropOverlay == true)
    }

}
