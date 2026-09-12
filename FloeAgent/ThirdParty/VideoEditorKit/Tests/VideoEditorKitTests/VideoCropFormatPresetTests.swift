import CoreGraphics
import Testing

@testable import VideoEditorKit

@Suite("VideoCropFormatPresetTests")
struct VideoCropFormatPresetTests {

    @Test
    func originalPresetDoesNotCreateACropRect() {
        let cropRect = VideoCropFormatPreset.original.makeFreeformRect(
            for: CGSize(width: 1920, height: 1080)
        )

        #expect(cropRect == nil)
    }

    @Test
    func presetsExposeDisplayNamesAndDimensionsIndependently() {
        #expect(VideoCropFormatPreset.original.title == "Original")
        #expect(VideoCropFormatPreset.original.dimensionTitle == "Source")
        #expect(VideoCropFormatPreset.vertical9x16.title == "Social")
        #expect(VideoCropFormatPreset.vertical9x16.dimensionTitle == "9:16")
        #expect(VideoCropFormatPreset.square1x1.title == "Square")
        #expect(VideoCropFormatPreset.square1x1.dimensionTitle == "1:1")
        #expect(VideoCropFormatPreset.portrait4x5.title == "Portrait")
        #expect(VideoCropFormatPreset.portrait4x5.dimensionTitle == "4:5")
        #expect(VideoCropFormatPreset.landscape16x9.title == "Landscape")
        #expect(VideoCropFormatPreset.landscape16x9.dimensionTitle == "16:9")
    }

    @Test
    func verticalPresetCreatesCentered9x16CropForLandscapeVideo() throws {
        let cropRect = try #require(
            VideoCropFormatPreset.vertical9x16.makeFreeformRect(
                for: CGSize(width: 1920, height: 1080)
            )
        )

        #expect(abs(cropRect.x - 0.341796875) < 0.0001)
        #expect(abs(cropRect.y - 0) < 0.0001)
        #expect(abs(cropRect.width - 0.31640625) < 0.0001)
        #expect(abs(cropRect.height - 1) < 0.0001)
    }

    @Test
    func verticalPresetMatchesItsGeneratedCropRect() {
        let referenceSize = CGSize(width: 1920, height: 1080)
        let cropRect = VideoCropFormatPreset.vertical9x16.makeFreeformRect(
            for: referenceSize
        )

        #expect(
            VideoCropFormatPreset.vertical9x16.matches(
                cropRect,
                in: referenceSize
            )
        )
    }

    @Test
    func verticalPresetMatchesFullFrameOnNativeVerticalVideo() {
        let referenceSize = CGSize(width: 1080, height: 1920)
        let cropRect = VideoEditingConfiguration.FreeformRect(
            x: 0,
            y: 0,
            width: 1,
            height: 1
        )

        #expect(
            VideoCropFormatPreset.vertical9x16.matches(
                cropRect,
                in: referenceSize
            )
        )
    }

    @Test
    func squarePresetCreatesCentered1x1CropForLandscapeVideo() throws {
        let cropRect = try #require(
            VideoCropFormatPreset.square1x1.makeFreeformRect(
                for: CGSize(width: 1920, height: 1080)
            )
        )

        #expect(abs(cropRect.x - 0.21875) < 0.0001)
        #expect(abs(cropRect.y - 0) < 0.0001)
        #expect(abs(cropRect.width - 0.5625) < 0.0001)
        #expect(abs(cropRect.height - 1) < 0.0001)
    }

    @Test
    func portraitPresetCreatesCentered4x5CropForLandscapeVideo() throws {
        let cropRect = try #require(
            VideoCropFormatPreset.portrait4x5.makeFreeformRect(
                for: CGSize(width: 1920, height: 1080)
            )
        )

        #expect(abs(cropRect.x - 0.275) < 0.0001)
        #expect(abs(cropRect.y - 0) < 0.0001)
        #expect(abs(cropRect.width - 0.45) < 0.0001)
        #expect(abs(cropRect.height - 1) < 0.0001)
    }

    @Test
    func landscapePresetMatchesFullFrameOnNativeLandscapeVideo() {
        let referenceSize = CGSize(width: 1920, height: 1080)
        let cropRect = VideoEditingConfiguration.FreeformRect(
            x: 0,
            y: 0,
            width: 1,
            height: 1
        )

        #expect(
            VideoCropFormatPreset.landscape16x9.matches(
                cropRect,
                in: referenceSize
            )
        )
    }

    @Test
    func resizingPresetRectWithPinchOutZoomsInWhileKeepingThePresetAspectRatio() throws {
        let referenceSize = CGSize(width: 1920, height: 1080)
        let initialRect = try #require(
            VideoCropFormatPreset.vertical9x16.makeFreeformRect(
                for: referenceSize
            )
        )

        let resizedRect = try #require(
            VideoCropFormatPreset.resizedRect(
                matching: initialRect,
                in: referenceSize,
                magnification: 1.5
            )
        )

        #expect(resizedRect.width < initialRect.width)
        #expect(resizedRect.height < initialRect.height)
        #expect(
            VideoCropFormatPreset.vertical9x16.matches(
                resizedRect,
                in: referenceSize
            )
        )
    }

    @Test
    func resettingPresetRectRestoresTheFullPresetCanvas() throws {
        let referenceSize = CGSize(width: 1920, height: 1080)
        let initialRect = try #require(
            VideoCropFormatPreset.vertical9x16.makeFreeformRect(
                for: referenceSize
            )
        )
        let resizedRect = try #require(
            VideoCropFormatPreset.resizedRect(
                matching: initialRect,
                in: referenceSize,
                magnification: 1.6
            )
        )

        let resetRect = VideoCropFormatPreset.resetRect(
            matching: resizedRect,
            in: referenceSize
        )

        #expect(resetRect == initialRect)
    }

}
