import CoreGraphics
import Testing

@testable import VideoEditorKit

@Suite("VideoCanvasPreviewViewTests")
struct VideoCanvasPreviewViewTests {

    // MARK: - Public Methods

    @Test
    func externalTransformChangeCancelsAnActiveInteraction() {
        let shouldCancel = VideoCanvasInteractionCancellationPolicy.shouldCancelInteraction(
            isInteractionActive: true,
            baselineTransform: .init(
                normalizedOffset: CGPoint(x: 0.2, y: -0.1),
                zoom: 1.4,
                rotationRadians: 0.2
            ),
            incomingTransform: .identity
        )

        #expect(shouldCancel)
    }

    @Test
    func unchangedTransformDoesNotCancelTheCurrentInteraction() {
        let baselineTransform = VideoCanvasTransform(
            normalizedOffset: CGPoint(x: 0.2, y: -0.1),
            zoom: 1.4,
            rotationRadians: 0.2
        )
        let shouldCancel = VideoCanvasInteractionCancellationPolicy.shouldCancelInteraction(
            isInteractionActive: true,
            baselineTransform: baselineTransform,
            incomingTransform: baselineTransform
        )

        #expect(shouldCancel == false)
    }

    @Test
    func inactiveInteractionIgnoresIncomingTransformChanges() {
        let shouldCancel = VideoCanvasInteractionCancellationPolicy.shouldCancelInteraction(
            isInteractionActive: false,
            baselineTransform: .init(
                normalizedOffset: CGPoint(x: 0.2, y: -0.1),
                zoom: 1.4,
                rotationRadians: 0.2
            ),
            incomingTransform: .identity
        )

        #expect(shouldCancel == false)
    }
}
