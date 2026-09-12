import CoreGraphics
import Testing

@testable import VideoEditorKit

@MainActor
@Suite("VideoEditorLayoutResolverTests", .serialized)
struct VideoEditorLayoutResolverTests {

    // MARK: - Public Methods

    @Test
    func resolvedCropPreviewCanvasSeparatesReferenceAndViewportSizingForPresets() {
        var video = Video.mock
        video.presentationSize = CGSize(width: 1920, height: 1080)

        let previewCanvas = VideoEditorLayoutResolver.resolvedCropPreviewCanvas(
            for: video,
            freeformRect: .init(
                x: 0.341796875,
                y: 0,
                width: 0.31640625,
                height: 1
            ),
            in: CGSize(width: 320, height: 360),
            fallbackContainerSize: CGSize(width: 320, height: 220)
        )

        #expect(abs(previewCanvas.referenceSize.width - 1920) < 0.0001)
        #expect(abs(previewCanvas.referenceSize.height - 1080) < 0.0001)
        #expect(abs(previewCanvas.contentSize.width - 320) < 0.0001)
        #expect(abs(previewCanvas.contentSize.height - 180) < 0.0001)
        #expect(abs(previewCanvas.viewportSize.width - 202.5) < 0.0001)
        #expect(abs(previewCanvas.viewportSize.height - 360) < 0.0001)
    }

    @Test
    func resolvedCropReferenceSizeFallsBackToFittedDisplayGeometry() {
        var video = Video.mock
        video.frameSize = .zero
        video.geometrySize = .zero
        video.presentationSize = .zero
        video.rotation = 90

        let referenceSize = VideoEditorLayoutResolver.resolvedCropReferenceSize(
            for: video,
            fallbackContainerSize: CGSize(width: 320, height: 220)
        )

        #expect(abs(referenceSize.width - 320) < 0.0001)
        #expect(abs(referenceSize.height - 220) < 0.0001)
    }

    @Test
    func resolvedPlayerDisplaySizeFallsBackToTheContainerWhenTheVideoHasNoBaseSize() {
        var video = Video.mock
        video.presentationSize = .zero
        video.frameSize = .zero

        let displaySize = VideoEditorLayoutResolver.resolvedPlayerDisplaySize(
            for: video,
            in: CGSize(width: 320, height: 240)
        )

        #expect(displaySize == CGSize(width: 320, height: 240))
    }

    @Test
    func resolvedCropReferenceSizePrefersTheRotatedPresentationSize() {
        var video = Video.mock
        video.presentationSize = CGSize(width: 1920, height: 1080)
        video.geometrySize = CGSize(width: 300, height: 500)
        video.rotation = 90

        let referenceSize = VideoEditorLayoutResolver.resolvedCropReferenceSize(
            for: video,
            fallbackContainerSize: CGSize(width: 320, height: 220)
        )

        #expect(referenceSize == CGSize(width: 1080, height: 1920))
    }

}
