import CoreGraphics
import Testing

@testable import VideoEditorKit

@Suite("VideoCanvasPinchPanGesturePolicyTests")
struct VideoCanvasPinchPanGesturePolicyTests {

    // MARK: - Public Methods

    @Test
    func pinchTranslationUsesCurrentCentroidRelativeToStartCentroid() {
        let translation = VideoCanvasPinchPanGesturePolicy.translation(
            from: CGPoint(x: 120, y: 180),
            to: CGPoint(x: 148, y: 153)
        )

        #expect(abs(translation.width - 28) < 0.0001)
        #expect(abs(translation.height + 27) < 0.0001)
    }

    @Test
    func pinchTranslationIgnoresNonFiniteCoordinates() {
        let translation = VideoCanvasPinchPanGesturePolicy.translation(
            from: CGPoint(x: CGFloat.nan, y: 180),
            to: CGPoint(x: 148, y: CGFloat.infinity)
        )

        #expect(translation == .zero)
    }

}
