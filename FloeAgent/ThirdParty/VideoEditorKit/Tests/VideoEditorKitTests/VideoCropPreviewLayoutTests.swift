import CoreGraphics
import Testing

@testable import VideoEditorKit

@Suite("VideoCropPreviewLayoutTests")
struct VideoCropPreviewLayoutTests {

    @Test
    func fullPresetRectKeepsViewportAndContentAligned() throws {
        let referenceSize = CGSize(width: 400, height: 200)
        let freeformRect = VideoEditingConfiguration.FreeformRect(
            x: 0.25,
            y: 0,
            width: 0.5,
            height: 1
        )

        let layout = try #require(
            VideoCropPreviewLayout(
                freeformRect: freeformRect,
                in: referenceSize
            )
        )

        #expect(layout.sourceRect == CGRect(x: 100, y: 0, width: 200, height: 200))
        #expect(layout.presetSourceRect == CGRect(x: 100, y: 0, width: 200, height: 200))
        #expect(layout.viewportRect == CGRect(x: 100, y: 0, width: 200, height: 200))
        #expect(abs(layout.contentScale - 1) < 0.0001)
        #expect(abs(layout.contentOffset.width) < 0.0001)
        #expect(abs(layout.contentOffset.height) < 0.0001)
    }

    @Test
    func fullFramePortraitPresetOnNativePortraitVideoKeepsViewportAtFullSize() throws {
        let referenceSize = CGSize(width: 1080, height: 1920)
        let freeformRect = VideoEditingConfiguration.FreeformRect(
            x: 0,
            y: 0,
            width: 1,
            height: 1
        )

        let layout = try #require(
            VideoCropPreviewLayout(
                freeformRect: freeformRect,
                in: referenceSize
            )
        )

        #expect(layout.sourceRect == CGRect(x: 0, y: 0, width: 1080, height: 1920))
        #expect(layout.presetSourceRect == CGRect(origin: .zero, size: referenceSize))
        #expect(layout.viewportRect == CGRect(origin: .zero, size: referenceSize))
        #expect(abs(layout.contentScale - 1) < 0.0001)
        #expect(abs(layout.contentOffset.width) < 0.0001)
        #expect(abs(layout.contentOffset.height) < 0.0001)
    }

    @Test
    func reducedCropRectKeepsTheViewportFixedAndScalesTheContent() throws {
        let referenceSize = CGSize(width: 400, height: 200)
        let freeformRect = VideoEditingConfiguration.FreeformRect(
            x: 0.375,
            y: 0.125,
            width: 0.25,
            height: 0.5
        )

        let layout = try #require(
            VideoCropPreviewLayout(
                freeformRect: freeformRect,
                in: referenceSize
            )
        )

        #expect(layout.sourceRect == CGRect(x: 150, y: 25, width: 100, height: 100))
        #expect(layout.presetSourceRect == CGRect(x: 100, y: 0, width: 200, height: 200))
        #expect(layout.viewportRect == CGRect(x: 100, y: 0, width: 200, height: 200))
        #expect(abs(layout.contentScale - 2) < 0.0001)
        #expect(abs(layout.contentOffset.width + 200) < 0.0001)
        #expect(abs(layout.contentOffset.height + 50) < 0.0001)
    }

    @Test
    func customViewportSizeSeparatesSourceAndViewportCoordinateSpaces() throws {
        let sourceSize = CGSize(width: 400, height: 200)
        let freeformRect = VideoEditingConfiguration.FreeformRect(
            x: 0.375,
            y: 0.125,
            width: 0.25,
            height: 0.5
        )

        let layout = try #require(
            VideoCropPreviewLayout(
                freeformRect: freeformRect,
                sourceSize: sourceSize,
                viewportSize: CGSize(width: 240, height: 240)
            )
        )

        #expect(layout.sourceRect == CGRect(x: 150, y: 25, width: 100, height: 100))
        #expect(layout.presetSourceRect == CGRect(x: 100, y: 0, width: 200, height: 200))
        #expect(layout.viewportRect == CGRect(x: 0, y: 0, width: 240, height: 240))
        #expect(abs(layout.contentScale - 2.4) < 0.0001)
        #expect(abs(layout.contentOffset.width + 360) < 0.0001)
        #expect(abs(layout.contentOffset.height + 60) < 0.0001)
    }

    @Test
    func customViewportCanUseStableReferenceCoordinatesAndASmallerRenderedContentSize() throws {
        let referenceSize = CGSize(width: 1920, height: 1080)
        let freeformRect = VideoEditingConfiguration.FreeformRect(
            x: 0.341796875,
            y: 0,
            width: 0.31640625,
            height: 1
        )

        let layout = try #require(
            VideoCropPreviewLayout(
                freeformRect: freeformRect,
                referenceSize: referenceSize,
                contentSize: CGSize(width: 320, height: 180),
                viewportSize: CGSize(width: 202.5, height: 360)
            )
        )

        #expect(layout.sourceRect == CGRect(x: 656.25, y: 0, width: 607.5, height: 1080))
        #expect(layout.presetSourceRect == CGRect(x: 656.25, y: 0, width: 607.5, height: 1080))
        #expect(layout.viewportRect == CGRect(x: 0, y: 0, width: 202.5, height: 360))
        #expect(abs(layout.referenceScale - 0.3333333333) < 0.0001)
        #expect(abs(layout.contentScale - 2) < 0.0001)
        #expect(abs(layout.contentOffset.width + 218.75) < 0.0001)
        #expect(abs(layout.contentOffset.height) < 0.0001)
    }

    @Test
    func gestureTranslationIsConvertedBackToSourceCoordinates() throws {
        let referenceSize = CGSize(width: 400, height: 200)
        let freeformRect = VideoEditingConfiguration.FreeformRect(
            x: 0.375,
            y: 0.125,
            width: 0.25,
            height: 0.5
        )

        let layout = try #require(
            VideoCropPreviewLayout(
                freeformRect: freeformRect,
                in: referenceSize
            )
        )

        let sourceTranslation = layout.sourceTranslation(
            for: CGSize(width: 40, height: -20)
        )

        #expect(abs(sourceTranslation.width + 20) < 0.0001)
        #expect(abs(sourceTranslation.height - 10) < 0.0001)
    }

    @Test
    func gestureTranslationUsesReferenceCoordinatesWhenViewportUsesASmallerRenderedContentSize() throws {
        let freeformRect = VideoEditingConfiguration.FreeformRect(
            x: 0.341796875,
            y: 0,
            width: 0.31640625,
            height: 1
        )

        let layout = try #require(
            VideoCropPreviewLayout(
                freeformRect: freeformRect,
                referenceSize: CGSize(width: 1920, height: 1080),
                contentSize: CGSize(width: 320, height: 180),
                viewportSize: CGSize(width: 202.5, height: 360)
            )
        )

        let sourceTranslation = layout.sourceTranslation(
            for: CGSize(width: 40, height: -20)
        )

        #expect(abs(sourceTranslation.width + 120) < 0.0001)
        #expect(abs(sourceTranslation.height - 60) < 0.0001)
    }

    @Test
    func gestureTranslationUsesTheViewportScaleWhenViewportSizeIsCustom() throws {
        let sourceSize = CGSize(width: 400, height: 200)
        let freeformRect = VideoEditingConfiguration.FreeformRect(
            x: 0.375,
            y: 0.125,
            width: 0.25,
            height: 0.5
        )

        let layout = try #require(
            VideoCropPreviewLayout(
                freeformRect: freeformRect,
                sourceSize: sourceSize,
                viewportSize: CGSize(width: 240, height: 240)
            )
        )

        let sourceTranslation = layout.sourceTranslation(
            for: CGSize(width: 48, height: -24)
        )

        #expect(abs(sourceTranslation.width + 20) < 0.0001)
        #expect(abs(sourceTranslation.height - 10) < 0.0001)
    }

    @Test
    func overflowingRectIsClampedToTheVisibleSourceArea() throws {
        let sourceSize = CGSize(width: 1000, height: 500)
        let freeformRect = VideoEditingConfiguration.FreeformRect(
            x: 0.8,
            y: 0.1,
            width: 0.4,
            height: 0.8
        )

        let layout = try #require(
            VideoCropPreviewLayout(
                freeformRect: freeformRect,
                in: sourceSize
            )
        )

        #expect(layout.sourceRect == CGRect(x: 800, y: 50, width: 200, height: 400))
        #expect(layout.presetSourceRect == CGRect(x: 250, y: 0, width: 500, height: 500))
    }

}
