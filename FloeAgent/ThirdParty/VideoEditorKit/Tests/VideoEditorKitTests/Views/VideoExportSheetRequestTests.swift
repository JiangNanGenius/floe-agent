import Foundation
import Testing

@testable import VideoEditorKit

@Suite("VideoExportSheetRequestTests")
struct VideoExportSheetRequestTests {

    // MARK: - Public Methods

    @Test
    func requestDefaultsToTheSourceURLIdentityAndInitialEditingConfiguration() {
        let url = URL(fileURLWithPath: "/tmp/source.mp4")
        let request = VideoExportSheetRequest(sourceVideoURL: url)

        #expect(request.id == url.absoluteString)
        #expect(request.sourceVideoURL == url)
        #expect(request.sourceMetadata == nil)
        #expect(request.editingConfiguration == .initial)
        #expect(request.preparedOriginalExportVideo == nil)
        #expect(request.preparedOriginalExportEditingConfiguration == nil)
    }

    @Test
    func requestStoresSourceMetadataForImmediateSheetPresentation() {
        let metadata = VideoExportSheetSourceMetadata(
            width: 1920,
            height: 1080,
            duration: 8
        )
        let request = VideoExportSheetRequest(
            sourceVideoURL: URL(fileURLWithPath: "/tmp/source.mp4"),
            sourceMetadata: metadata
        )

        #expect(request.sourceMetadata == metadata)
    }

    @Test
    func sourceResolverUsesMetadataWithoutLoadingTheAsset() async {
        let sourceURL = URL(fileURLWithPath: "/tmp/source.mp4")
        let metadata = VideoExportSheetSourceMetadata(
            width: 1920,
            height: 1080,
            duration: 8
        )
        let request = VideoExportSheetRequest(
            sourceVideoURL: sourceURL,
            sourceMetadata: metadata
        )
        let probe = VideoLoadProbe()

        let video = await VideoExportSheetSourceResolver.video(
            for: request,
            loadVideo: { url in
                await probe.record(url)
                return Video(url: url)
            }
        )

        #expect(video.url == sourceURL)
        #expect(video.originalDuration == 8)
        #expect(video.rangeDuration == 0...8)
        #expect(video.presentationSize == CGSize(width: 1920, height: 1080))
        #expect(await probe.loadedURLs.isEmpty)
    }

    @Test
    func requestKeepsThePreparedOriginalConfigurationOnlyWhenPreparedVideoExists() {
        let url = URL(fileURLWithPath: "/tmp/source.mp4")
        let preparedVideo = ExportedVideo(
            URL(fileURLWithPath: "/tmp/prepared.mp4"),
            width: 1920,
            height: 1080,
            duration: 8,
            fileSize: 1024
        )
        let editingConfiguration = VideoEditingConfiguration(
            trim: .init(lowerBound: 1, upperBound: 6)
        )

        let request = VideoExportSheetRequest(
            id: "project-1",
            sourceVideoURL: url,
            editingConfiguration: editingConfiguration,
            preparedOriginalExportVideo: preparedVideo
        )

        #expect(request.id == "project-1")
        #expect(request.preparedOriginalExportVideo == preparedVideo)
        #expect(request.preparedOriginalExportEditingConfiguration == editingConfiguration)
    }

    @Test
    func requestUsesTheExplicitPreparedOriginalConfigurationWhenProvided() {
        let sourceURL = URL(fileURLWithPath: "/tmp/source.mp4")
        let preparedVideo = ExportedVideo(
            URL(fileURLWithPath: "/tmp/prepared.mp4"),
            width: 1920,
            height: 1080,
            duration: 8,
            fileSize: 1024
        )
        let editingConfiguration = VideoEditingConfiguration(
            trim: .init(lowerBound: 1, upperBound: 6)
        )
        let preparedConfiguration = VideoEditingConfiguration(
            trim: .init(lowerBound: 2, upperBound: 5)
        )

        let request = VideoExportSheetRequest(
            sourceVideoURL: sourceURL,
            editingConfiguration: editingConfiguration,
            preparedOriginalExportVideo: preparedVideo,
            preparedOriginalExportEditingConfiguration: preparedConfiguration
        )

        #expect(request.preparedOriginalExportEditingConfiguration == preparedConfiguration)
    }

    @Test
    func defaultPreparationUsesPreparedOriginalWhenTheConfigurationMatches() {
        let preparedVideo = ExportedVideo(
            URL(fileURLWithPath: "/tmp/prepared.mp4"),
            width: 1920,
            height: 1080,
            duration: 8,
            fileSize: 1024
        )
        let editingConfiguration = VideoEditingConfiguration(
            trim: .init(lowerBound: 1, upperBound: 6)
        )
        let request = VideoExportSheetRequest(
            sourceVideoURL: URL(fileURLWithPath: "/tmp/source.mp4"),
            editingConfiguration: editingConfiguration,
            preparedOriginalExportVideo: preparedVideo,
            preparedOriginalExportEditingConfiguration: editingConfiguration
        )

        let result = VideoExportSheetPreparationResolver.preparationResult(
            selectedQuality: .original,
            request: request,
            loadedOriginalVideo: nil,
            hasWatermark: false
        )

        #expect(result == .usePreparedVideo(preparedVideo))
    }

    @Test
    func defaultPreparationRendersPreparedOriginalWhenWatermarkExists() {
        let preparedVideo = ExportedVideo(
            URL(fileURLWithPath: "/tmp/prepared.mp4"),
            width: 1920,
            height: 1080,
            duration: 8,
            fileSize: 1024
        )
        let editingConfiguration = VideoEditingConfiguration(
            trim: .init(lowerBound: 1, upperBound: 6)
        )
        let request = VideoExportSheetRequest(
            sourceVideoURL: URL(fileURLWithPath: "/tmp/source.mp4"),
            editingConfiguration: editingConfiguration,
            preparedOriginalExportVideo: preparedVideo,
            preparedOriginalExportEditingConfiguration: editingConfiguration
        )

        let result = VideoExportSheetPreparationResolver.preparationResult(
            selectedQuality: .original,
            request: request,
            loadedOriginalVideo: nil,
            hasWatermark: true
        )

        #expect(result == .render)
    }

    @Test
    func defaultPreparationRendersWhenPreparedOriginalConfigurationDiffers() {
        let preparedVideo = ExportedVideo(
            URL(fileURLWithPath: "/tmp/prepared.mp4"),
            width: 1920,
            height: 1080,
            duration: 8,
            fileSize: 1024
        )
        let request = VideoExportSheetRequest(
            sourceVideoURL: URL(fileURLWithPath: "/tmp/source.mp4"),
            editingConfiguration: VideoEditingConfiguration(
                trim: .init(lowerBound: 1, upperBound: 6)
            ),
            preparedOriginalExportVideo: preparedVideo,
            preparedOriginalExportEditingConfiguration: VideoEditingConfiguration(
                trim: .init(lowerBound: 2, upperBound: 6)
            )
        )

        let result = VideoExportSheetPreparationResolver.preparationResult(
            selectedQuality: .original,
            request: request,
            loadedOriginalVideo: nil,
            hasWatermark: false
        )

        #expect(result == .render)
    }

    @Test
    func defaultPreparationUsesLoadedOriginalForInitialOriginalExport() {
        let loadedOriginal = ExportedVideo(
            URL(fileURLWithPath: "/tmp/source.mp4"),
            width: 1920,
            height: 1080,
            duration: 8,
            fileSize: 1024
        )
        let request = VideoExportSheetRequest(
            sourceVideoURL: loadedOriginal.url,
            editingConfiguration: .initial
        )

        let result = VideoExportSheetPreparationResolver.preparationResult(
            selectedQuality: .original,
            request: request,
            loadedOriginalVideo: loadedOriginal,
            hasWatermark: false
        )

        #expect(result == .usePreparedVideo(loadedOriginal))
    }

    @Test
    func defaultPreparationRendersLoadedOriginalWhenWatermarkExists() {
        let loadedOriginal = ExportedVideo(
            URL(fileURLWithPath: "/tmp/source.mp4"),
            width: 1920,
            height: 1080,
            duration: 8,
            fileSize: 1024
        )
        let request = VideoExportSheetRequest(
            sourceVideoURL: loadedOriginal.url,
            editingConfiguration: .initial
        )

        let result = VideoExportSheetPreparationResolver.preparationResult(
            selectedQuality: .original,
            request: request,
            loadedOriginalVideo: loadedOriginal,
            hasWatermark: true
        )

        #expect(result == .render)
    }

    @Test
    func defaultPreparationRendersNonOriginalQualities() {
        let loadedOriginal = ExportedVideo(
            URL(fileURLWithPath: "/tmp/source.mp4"),
            width: 1920,
            height: 1080,
            duration: 8,
            fileSize: 1024
        )
        let request = VideoExportSheetRequest(
            sourceVideoURL: loadedOriginal.url,
            editingConfiguration: .initial
        )

        let result = VideoExportSheetPreparationResolver.preparationResult(
            selectedQuality: .low,
            request: request,
            loadedOriginalVideo: loadedOriginal,
            hasWatermark: false
        )

        #expect(result == .render)
    }

}

private actor VideoLoadProbe {

    // MARK: - Private Properties

    private(set) var loadedURLs = [URL]()

    // MARK: - Public Methods

    func record(_ url: URL) {
        loadedURLs.append(url)
    }

}
