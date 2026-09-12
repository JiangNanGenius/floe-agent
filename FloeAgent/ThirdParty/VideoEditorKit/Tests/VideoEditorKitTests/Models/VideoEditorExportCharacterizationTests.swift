import CoreGraphics
import Foundation
import Testing

@testable import VideoEditorKit

@Suite("VideoEditorExportCharacterizationTests", .serialized)
struct VideoEditorExportCharacterizationTests {

    // MARK: - Public Methods

    @Test
    func resolvedExportProfileScalesBaseExportResolutionAcrossQualities() {
        let video = makeVideo()
        let resolvedRenderSizes = renderSizes(
            for: video,
            editingConfiguration: .initial
        )

        #expect(resolvedRenderSizes[.low] == VideoQuality.low.size)
        #expect(resolvedRenderSizes[.medium] == VideoQuality.medium.size)
        #expect(resolvedRenderSizes[.high] == VideoQuality.high.size)
    }

    @Test
    func originalExportUsesSourceRenderSizeAndNativeFrameDurationFallback() {
        let sourceSize = CGSize(width: 720, height: 1280)
        let profile = VideoEditor.resolvedRenderProfile(
            for: sourceSize,
            editingConfiguration: .initial,
            intent: .export(.original),
            isSimulatorEnvironment: true
        )

        #expect(profile.renderSize == sourceSize)
        #expect(profile.frameDuration.seconds == 1.0 / 30.0)
    }

    @Test
    func resolvedExportProfileScalesCanvasPresetExportsAcrossQualities() {
        let video = makeVideo()
        let editingConfiguration = VideoEditingConfiguration(
            canvas: .init(
                snapshot: .init(
                    preset: .facebookPost,
                    freeCanvasSize: CGSize(width: 1080, height: 1350)
                )
            )
        )
        let resolvedRenderSizes = renderSizes(
            for: video,
            editingConfiguration: editingConfiguration
        )

        #expect(resolvedRenderSizes[.low] == CGSize(width: 480, height: 600))
        #expect(resolvedRenderSizes[.medium] == CGSize(width: 720, height: 900))
        #expect(resolvedRenderSizes[.high] == CGSize(width: 1080, height: 1350))
    }

    // MARK: - Private Methods

    private func makeVideo() -> Video {
        let url = URL(fileURLWithPath: "/tmp/export-characterization.mp4")

        return Video(
            url: url,
            asset: .init(url: url),
            originalDuration: 1,
            rangeDuration: 0...1,
            presentationSize: CGSize(width: 640, height: 360)
        )
    }

    private func renderSizes(
        for video: Video,
        editingConfiguration: VideoEditingConfiguration
    ) -> [VideoQuality: CGSize] {
        var renderSizes = [VideoQuality: CGSize]()

        for quality in VideoQuality.allCases {
            let exportProfile = VideoEditor.resolvedExportProfile(
                for: video,
                editingConfiguration: editingConfiguration,
                videoQuality: quality
            )
            renderSizes[quality] = exportProfile.renderSize
        }

        return renderSizes
    }
}
