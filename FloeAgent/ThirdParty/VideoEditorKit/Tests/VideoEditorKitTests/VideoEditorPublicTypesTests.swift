import Foundation
import SwiftUI
import Testing

@testable import VideoEditorKit

@Suite("VideoEditorPublicTypesTests")
struct VideoEditorPublicTypesTests {

    @Test
    func videoEditorViewNamespaceExposesBoundaryTypes() {
        let url = URL(fileURLWithPath: "/tmp/video.mp4")
        let session = VideoEditorView.Session(
            sourceVideoURL: url,
            editingConfiguration: .initial
        )
        let savedVideo = VideoEditorView.SavedVideo(
            url,
            originalVideoURL: url,
            editingConfiguration: .initial,
            metadata: .init(
                url,
                width: 1920,
                height: 1080,
                duration: 1,
                fileSize: 1024
            )
        )
        let configuration = VideoEditorView.Configuration.allToolsEnabled
        let callbacks = VideoEditorView.Callbacks()

        #expect(session.sourceVideoURL == url)
        #expect(savedVideo.originalVideoURL == url)
        #expect(savedVideo.metadata.url == url)
        #expect(configuration.tools == VideoEditorConfiguration.allToolsEnabled.tools)
        #expect(configuration.transcription == nil)
        callbacks.onDismissed?()
    }

    @Test
    func sessionResolvesTheExpectedConvenienceValues() {
        let url = URL(fileURLWithPath: "/tmp/video.mp4")
        let preparedOriginalExportVideo = ExportedVideo(
            URL(fileURLWithPath: "/tmp/saved.mp4"),
            width: 1920,
            height: 1080,
            duration: 10,
            fileSize: 2048
        )
        let session = VideoEditorSession(
            source: .fileURL(url),
            editingConfiguration: .initial,
            preparedOriginalExportVideo: preparedOriginalExportVideo
        )

        #expect(session.sourceVideoURL == url)
        #expect(session.bootstrapTaskIdentifier == "file:\(url.absoluteString)")
        #expect(session.preparedOriginalExportVideo == preparedOriginalExportVideo)
        #expect(session.preparedOriginalExportEditingConfiguration == .initial)
    }

    @Test
    func sessionTracksTheSnapshotThatProducedThePreparedOriginalExport() {
        let url = URL(fileURLWithPath: "/tmp/video.mp4")
        let editingConfiguration = VideoEditingConfiguration(
            trim: .init(lowerBound: 1, upperBound: 6)
        )
        let preparedOriginalExportVideo = ExportedVideo(
            URL(fileURLWithPath: "/tmp/saved.mp4"),
            width: 1920,
            height: 1080,
            duration: 10,
            fileSize: 2048
        )
        let session = VideoEditorSession(
            source: .fileURL(url),
            editingConfiguration: editingConfiguration,
            preparedOriginalExportVideo: preparedOriginalExportVideo
        )

        #expect(session.preparedOriginalExportEditingConfiguration == editingConfiguration)
    }

    @Test
    func configurationSortsToolsAndExportQualitiesByOrder() {
        let configuration = VideoEditorConfiguration(
            tools: [
                .enabled(.speed, order: 4),
                .enabled(.audio, order: 2),
                .enabled(.presets, order: 1),
            ],
            exportQualities: [
                .enabled(.low, order: 2),
                .enabled(.high, order: 0),
                .enabled(.medium, order: 1),
            ]
        )

        #expect(configuration.tools.map(\.tool) == [.presets, .audio, .speed])
        #expect(configuration.exportQualities.map(\.quality) == [.high, .medium, .low, .original])
    }

    @Test
    func exportQualitiesAlwaysIncludeEnabledOriginalLast() {
        let configuration = VideoEditorConfiguration(
            exportQualities: [
                .blocked(.original),
                .blocked(.high),
                .enabled(.low),
            ]
        )

        #expect(configuration.exportQualities.last?.quality == .original)
        #expect(configuration.isEnabled(.original))
        #expect(configuration.isBlocked(.original) == false)
    }

    @Test
    func configurationNormalizesTheMaximumVideoDuration() {
        let validConfiguration = VideoEditorConfiguration(
            maximumVideoDuration: 45
        )
        let invalidConfiguration = VideoEditorConfiguration(
            maximumVideoDuration: 0
        )

        #expect(validConfiguration.maximumVideoDuration == 45)
        #expect(invalidConfiguration.maximumVideoDuration == nil)
    }

    @Test
    func configurationDefaultsToNoWatermark() {
        let configuration = VideoEditorConfiguration()

        #expect(configuration.watermark == nil)
    }

    @Test
    func configurationStoresOptionalWatermarkPolicy() {
        let image = TestFixtures.makeSolidImage(
            size: CGSize(width: 40, height: 20),
            scale: 1
        )
        let watermark = VideoWatermarkConfiguration(
            image: image,
            position: .bottomTrailing
        )
        let configuration = VideoEditorConfiguration(
            watermark: watermark
        )

        #expect(configuration.watermark?.image.size == CGSize(width: 40, height: 20))
        #expect(configuration.watermark?.position == .bottomTrailing)
    }

    @Test
    func videoEditorViewNamespaceExposesWatermarkConfigurationTypes() {
        let image = TestFixtures.makeSolidImage(
            size: CGSize(width: 24, height: 12),
            scale: 1
        )
        let watermark = VideoEditorView.WatermarkConfiguration(
            image: image,
            position: .topLeading
        )
        let configuration = VideoEditorView.Configuration(
            watermark: watermark
        )

        #expect(configuration.watermark?.image.size == CGSize(width: 24, height: 12))
        #expect(configuration.watermark?.position == .topLeading)
    }

    @Test
    func savedVideoCarriesTheManualSavePayload() {
        let savedURL = URL(fileURLWithPath: "/tmp/saved.mp4")
        let originalURL = URL(fileURLWithPath: "/tmp/original.mp4")
        let configuration = VideoEditingConfiguration(
            playback: .init(rate: 2)
        )
        let metadata = ExportedVideo(
            savedURL,
            width: 1280,
            height: 720,
            duration: 8,
            fileSize: 2048
        )
        let savedVideo = SavedVideo(
            savedURL,
            originalVideoURL: originalURL,
            editingConfiguration: configuration,
            thumbnailData: Data([4, 5, 6]),
            metadata: metadata
        )

        #expect(savedVideo.url == savedURL)
        #expect(savedVideo.originalVideoURL == originalURL)
        #expect(savedVideo.editingConfiguration == configuration)
        #expect(savedVideo.thumbnailData == Data([4, 5, 6]))
        #expect(savedVideo.metadata == metadata)
    }

    @Test
    func callbacksExposeManualSaveDismissAndExportHandlersSeparately() {
        let savedURL = URL(fileURLWithPath: "/tmp/saved.mp4")
        let exportedURL = URL(fileURLWithPath: "/tmp/exported.mp4")
        var capturedSavedVideo: SavedVideo?
        var didDismiss = false
        var capturedExportedURL: URL?
        let callbacks = VideoEditorCallbacks(
            onSavedVideo: { capturedSavedVideo = $0 },
            onDismissed: { didDismiss = true },
            onExportedVideoURL: { capturedExportedURL = $0 }
        )
        let savedVideo = SavedVideo(
            savedURL,
            originalVideoURL: URL(fileURLWithPath: "/tmp/original.mp4"),
            editingConfiguration: .initial,
            metadata: .init(
                savedURL,
                width: 640,
                height: 480,
                duration: 3,
                fileSize: 512
            )
        )

        callbacks.onSavedVideo(savedVideo)
        callbacks.onDismissed?()
        callbacks.onExportedVideoURL(exportedURL)

        #expect(capturedSavedVideo == savedVideo)
        #expect(didDismiss)
        #expect(capturedExportedURL == exportedURL)
    }

    @Test
    func dismissedCallbackIsOptional() {
        let callbacks = VideoEditorCallbacks()

        #expect(callbacks.onDismissed == nil)
    }

}
