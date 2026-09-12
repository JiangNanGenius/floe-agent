import AVFoundation
import CoreGraphics
import CoreImage
import SwiftUI
import Testing

@testable import VideoEditorKit

@Suite("VideoEditorTests", .serialized)
struct VideoEditorTests {

    // MARK: - Public Methods

    @Test
    func resolvedCropRectConvertsNormalizedGeometryIntoRenderCoordinates() {
        let cropRect = VideoEditor.resolvedCropRect(
            for: .init(
                x: 0.1,
                y: 0.2,
                width: 0.5,
                height: 0.4
            ),
            in: CGSize(width: 1000, height: 500)
        )

        #expect(cropRect == CGRect(x: 100, y: 100, width: 500, height: 200))
    }

    @Test
    func resolvedCropRectClampsOutOfBoundsValuesToTheVisibleFrame() {
        let cropRect = VideoEditor.resolvedCropRect(
            for: .init(
                x: -0.2,
                y: 0.85,
                width: 1.4,
                height: 0.5
            ),
            in: CGSize(width: 1000, height: 500)
        )

        #expect(cropRect == CGRect(x: 0, y: 424, width: 1000, height: 76))
    }

    @Test
    func watermarkLayoutSizesWidthFromLargestRenderDimensionAndPreservesAspectRatio() {
        let frame = VideoWatermarkLayout.frame(
            renderSize: CGSize(width: 1920, height: 1080),
            imageSize: CGSize(width: 120, height: 48),
            position: .topLeading
        )

        #expect(abs(frame.minX - 16) < 0.0001)
        #expect(abs(frame.minY - 16) < 0.0001)
        #expect(abs(frame.width - 307.2) < 0.0001)
        #expect(abs(frame.height - 122.88) < 0.0001)
    }

    @Test
    func watermarkLayoutUsesTopTrailingPadding() {
        let frame = VideoWatermarkLayout.frame(
            renderSize: CGSize(width: 1920, height: 1080),
            imageSize: CGSize(width: 120, height: 48),
            position: .topTrailing
        )

        #expect(abs(frame.minX - 1596.8) < 0.0001)
        #expect(abs(frame.minY - 16) < 0.0001)
        #expect(abs(frame.width - 307.2) < 0.0001)
        #expect(abs(frame.height - 122.88) < 0.0001)
    }

    @Test
    func watermarkLayoutUsesBottomLeadingPadding() {
        let frame = VideoWatermarkLayout.frame(
            renderSize: CGSize(width: 1920, height: 1080),
            imageSize: CGSize(width: 120, height: 48),
            position: .bottomLeading
        )

        #expect(abs(frame.minX - 16) < 0.0001)
        #expect(abs(frame.minY - 941.12) < 0.0001)
        #expect(abs(frame.width - 307.2) < 0.0001)
        #expect(abs(frame.height - 122.88) < 0.0001)
    }

    @Test
    func watermarkLayoutUsesBottomTrailingPadding() {
        let frame = VideoWatermarkLayout.frame(
            renderSize: CGSize(width: 1920, height: 1080),
            imageSize: CGSize(width: 120, height: 48),
            position: .bottomTrailing
        )

        #expect(abs(frame.minX - 1596.8) < 0.0001)
        #expect(abs(frame.minY - 941.12) < 0.0001)
        #expect(abs(frame.width - 307.2) < 0.0001)
        #expect(abs(frame.height - 122.88) < 0.0001)
    }

    @Test
    func watermarkLayoutUsesHeightWhenItIsTheLargestRenderDimension() {
        let frame = VideoWatermarkLayout.frame(
            renderSize: CGSize(width: 1080, height: 1920),
            imageSize: CGSize(width: 100, height: 50),
            position: .topTrailing
        )

        #expect(abs(frame.minX - 756.8) < 0.0001)
        #expect(abs(frame.minY - 16) < 0.0001)
        #expect(abs(frame.width - 307.2) < 0.0001)
        #expect(abs(frame.height - 153.6) < 0.0001)
    }

    @Test
    func watermarkLayoutKeepsPortraitWatermarkAspectRatio() {
        let frame = VideoWatermarkLayout.frame(
            renderSize: CGSize(width: 1000, height: 500),
            imageSize: CGSize(width: 80, height: 160),
            position: .bottomTrailing
        )

        #expect(abs(frame.minX - 824) < 0.0001)
        #expect(abs(frame.minY - 164) < 0.0001)
        #expect(abs(frame.width - 160) < 0.0001)
        #expect(abs(frame.height - 320) < 0.0001)
    }

    @Test
    @MainActor
    func watermarkRenderRequestRasterizesImagesWithoutCGImage() {
        let ciImage = CIImage(color: CIColor(red: 0, green: 0, blue: 1, alpha: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 20, height: 10))
        let image = UIImage(ciImage: ciImage)
        let request = VideoWatermarkRenderRequest(
            VideoWatermarkConfiguration(
                image: image,
                position: .bottomLeading
            )
        )

        #expect(image.cgImage == nil)
        #expect(request?.imageSize == CGSize(width: 20, height: 10))
        #expect(request?.image.width == 20)
        #expect(request?.image.height == 10)
    }

    @Test
    @MainActor
    func watermarkRenderRequestUsesShareOpacity() {
        let image = TestFixtures.makeSolidImage(
            size: CGSize(width: 20, height: 10),
            scale: 1
        )
        let request = VideoWatermarkRenderRequest(
            VideoWatermarkConfiguration(
                image: image,
                position: .bottomTrailing
            )
        )

        #expect(request?.opacity == 0.4)
    }

    @Test
    @MainActor
    func watermarkRenderRequestRejectsZeroSizedImages() {
        let configuration = VideoWatermarkConfiguration(
            image: UIImage(),
            position: .topLeading
        )

        #expect(configuration.isRenderableWatermark == false)
        #expect(VideoWatermarkRenderRequest(configuration) == nil)
    }

    @Test
    func resolvedOutputRenderLayoutUsesPresetAspectRatioWithoutSocialDestination() {
        let configuration = VideoEditingConfiguration(
            crop: .init(
                freeformRect: .init(
                    x: 0.275,
                    y: 0,
                    width: 0.45,
                    height: 1
                )
            )
        )

        let layout = VideoEditor.resolvedOutputRenderLayout(
            for: CGSize(width: 1920, height: 1080),
            editingConfiguration: configuration
        )

        #expect(layout == .portrait)
    }

    @Test
    func resolvedOutputRenderSizeScalesFacebookPostPresetExportsToTheSelectedQuality() {
        let configuration = VideoEditingConfiguration(
            crop: .init(
                freeformRect: .init(
                    x: 0.275,
                    y: 0,
                    width: 0.45,
                    height: 1
                )
            )
        )

        let renderSize = VideoEditor.resolvedOutputRenderSize(
            for: CGSize(width: 1920, height: 1080),
            editingConfiguration: configuration,
            videoQuality: .medium
        )

        #expect(renderSize == CGSize(width: 720, height: 900))
    }

    @Test
    func resolvedCropRectSharesTheSameVisibleGeometryAsThePreviewLayout() throws {
        let sourceSize = CGSize(width: 1000, height: 500)
        let freeformRect = VideoEditingConfiguration.FreeformRect(
            x: 0.8,
            y: 0.1,
            width: 0.4,
            height: 0.8
        )
        let previewLayout = try #require(
            VideoCropPreviewLayout(
                freeformRect: freeformRect,
                in: sourceSize
            )
        )

        let cropRect = VideoEditor.resolvedCropRect(
            for: freeformRect,
            in: sourceSize
        )

        #expect(cropRect == previewLayout.sourceRect)
    }

    @Test
    func resolvedOutputRenderLayoutUsesTheClampedPreviewGeometryWhenCropOverflowsTheSource() {
        let configuration = VideoEditingConfiguration(
            crop: .init(
                freeformRect: .init(
                    x: 0.8,
                    y: 0.1,
                    width: 0.4,
                    height: 0.8
                )
            )
        )

        let layout = VideoEditor.resolvedOutputRenderLayout(
            for: CGSize(width: 1000, height: 500),
            editingConfiguration: configuration
        )

        #expect(layout == .portrait)
    }

    @Test
    func resolvedOutputRenderSizeScalesPersistedCanvasPresetDimensionsToTheSelectedQuality() {
        let configuration = VideoEditingConfiguration(
            canvas: .init(
                snapshot: .init(
                    preset: .facebookPost,
                    freeCanvasSize: CGSize(width: 1080, height: 1350)
                )
            )
        )

        let renderSize = VideoEditor.resolvedOutputRenderSize(
            for: CGSize(width: 1920, height: 1080),
            editingConfiguration: configuration,
            videoQuality: .low
        )

        #expect(renderSize == CGSize(width: 480, height: 600))
    }

    @Test
    func resolvedExportProfileSharesTheCanvasRenderSizeForTheSelectedQuality() {
        let video = Video(
            url: URL(fileURLWithPath: "/tmp/export-profile.mp4"),
            asset: AVURLAsset(url: URL(fileURLWithPath: "/tmp/export-profile.mp4")),
            originalDuration: 12,
            rangeDuration: 0...12,
            presentationSize: CGSize(width: 1920, height: 1080)
        )
        let configuration = VideoEditingConfiguration(
            canvas: .init(
                snapshot: .init(
                    preset: .facebookPost,
                    freeCanvasSize: CGSize(width: 1080, height: 1350)
                )
            )
        )

        let exportProfile = VideoEditor.resolvedExportProfile(
            for: video,
            editingConfiguration: configuration,
            videoQuality: .medium
        )

        #expect(exportProfile.renderSize == CGSize(width: 720, height: 900))
    }

    @Test
    func resolvedSaveNativeRenderProfileUsesCanvasSizeWhilePreservingSourceFrameRate() {
        let profile = VideoEditor.resolvedRenderProfile(
            for: CGSize(width: 1920, height: 1080),
            editingConfiguration: VideoEditingConfiguration(
                canvas: .init(
                    snapshot: .init(
                        preset: .facebookPost,
                        freeCanvasSize: CGSize(width: 1080, height: 1350)
                    )
                )
            ),
            intent: .saveNative(sourceFrameRate: 23.976),
            isSimulatorEnvironment: true
        )

        #expect(profile.intent == .saveNative(sourceFrameRate: 23.976))
        #expect(profile.renderSize == CGSize(width: 1080, height: 1350))
        #expect(abs(profile.frameDuration.seconds - (1 / 23.976)) < 0.0001)
        #expect(profile.renderPresetName == AVAssetExportPresetHighestQuality)
        #expect(profile.passthroughPresetName == AVAssetExportPresetPassthrough)
    }

    @Test
    func resolvedSaveNativeRenderProfileKeepsSourceSizeWhenCanvasIsIdentity() {
        let profile = VideoEditor.resolvedRenderProfile(
            for: CGSize(width: 1920, height: 1080),
            editingConfiguration: .initial,
            intent: .saveNative(sourceFrameRate: 24),
            isSimulatorEnvironment: true
        )

        #expect(profile.renderSize == CGSize(width: 1920, height: 1080))
        #expect(abs(profile.frameDuration.seconds - (1 / 24.0)) < 0.0001)
    }

    @Test
    func startRenderSaveNativeProducesCanvasSizedVideoForPresetEdits() async throws {
        let url = try await TestFixtures.createTemporaryVideo(
            size: CGSize(width: 160, height: 90),
            frameCount: 12,
            framesPerSecond: 24
        )
        defer { FileManager.default.removeIfExists(for: url) }

        let video = await Video.load(from: url)
        let editingConfiguration = VideoEditingConfiguration(
            canvas: .init(
                snapshot: .init(
                    preset: .custom(width: 108, height: 135),
                    freeCanvasSize: CGSize(width: 108, height: 135),
                    transform: .init(
                        normalizedOffset: CGPoint(x: 0.15, y: 0),
                        zoom: 1.2,
                        rotationRadians: 0
                    )
                )
            )
        )

        let savedURL = try await VideoEditor.startRender(
            video: video,
            editingConfiguration: editingConfiguration,
            renderIntent: .saveNative(sourceFrameRate: 24)
        )
        defer { FileManager.default.removeIfExists(for: savedURL) }

        let savedAsset = AVURLAsset(url: savedURL)
        let savedSize = try #require(await savedAsset.presentationSize())

        #expect(savedSize == CGSize(width: 108, height: 136))
    }

    @Test
    func exportRenderAppliesWatermarkAtTopLeadingPadding() async throws {
        let sourceURL = try await TestFixtures.createTemporaryVideo(
            size: CGSize(width: 96, height: 64),
            frameCount: 6,
            framesPerSecond: 30,
            color: .systemRed
        )
        defer { FileManager.default.removeIfExists(for: sourceURL) }

        let video = await Video.load(from: sourceURL)
        let watermarkImage = TestFixtures.makeSolidImage(
            size: CGSize(width: 12, height: 10),
            color: .systemBlue,
            scale: 1
        )
        let watermark = await VideoWatermarkRenderRequest(
            VideoWatermarkConfiguration(
                image: watermarkImage,
                position: .topLeading
            )
        )

        let exportedURL = try await VideoEditor.startRender(
            video: video,
            editingConfiguration: .initial,
            videoQuality: .original,
            watermark: watermark
        )
        defer { FileManager.default.removeIfExists(for: exportedURL) }

        let asset = AVURLAsset(url: exportedURL)
        let renderedImage = try #require(
            await asset.generateImage(
                at: 0,
                maximumSize: CGSize(width: 96, height: 64),
                requiresExactFrame: true
            )?.cgImage
        )

        #expect(renderedPixel(in: renderedImage, x: 20, y: 20)?.isMostlyBlue == true)
    }

    @Test
    func exportRenderAppliesWatermarkAtBottomTrailingPadding() async throws {
        let sourceURL = try await TestFixtures.createTemporaryVideo(
            size: CGSize(width: 96, height: 64),
            frameCount: 6,
            framesPerSecond: 30,
            color: .systemRed
        )
        defer { FileManager.default.removeIfExists(for: sourceURL) }

        let video = await Video.load(from: sourceURL)
        let watermarkImage = TestFixtures.makeSolidImage(
            size: CGSize(width: 12, height: 10),
            color: .systemBlue,
            scale: 1
        )
        let watermark = await VideoWatermarkRenderRequest(
            VideoWatermarkConfiguration(
                image: watermarkImage,
                position: .bottomTrailing
            )
        )

        let exportedURL = try await VideoEditor.startRender(
            video: video,
            editingConfiguration: .initial,
            videoQuality: .original,
            watermark: watermark
        )
        defer { FileManager.default.removeIfExists(for: exportedURL) }

        let asset = AVURLAsset(url: exportedURL)
        let renderedImage = try #require(
            await asset.generateImage(
                at: 0,
                maximumSize: CGSize(width: 96, height: 64),
                requiresExactFrame: true
            )?.cgImage
        )

        #expect(renderedPixel(in: renderedImage, x: 74, y: 44)?.isMostlyBlue == true)
    }

    @Test
    func resolvedSaveNativeRenderProfileFallsBackToThirtyFPSWhenSourceFrameRateIsInvalid() {
        let profile = VideoEditor.resolvedRenderProfile(
            for: CGSize(width: 1080, height: 1920),
            editingConfiguration: .initial,
            intent: .saveNative(sourceFrameRate: 0),
            isSimulatorEnvironment: true
        )

        #expect(profile.renderSize == CGSize(width: 1080, height: 1920))
        #expect(profile.frameDuration == CMTime(seconds: 1 / 30, preferredTimescale: 600))
    }

    @Test
    func resolvedSourceFrameRateLoadsNominalFrameRateFromTheVideoAsset() async throws {
        let url = try await TestFixtures.createTemporaryVideo(
            frameCount: 48,
            framesPerSecond: 24
        )
        let asset = AVURLAsset(url: url)

        let frameRate = await VideoEditor.resolvedSourceFrameRate(for: asset)

        #expect(frameRate == 24)
    }

    @Test
    func canIntegrateAdjustsIntoBaseRenderForNativeIdentityOutput() async throws {
        let size = CGSize(width: 48, height: 24)
        let url = try await TestFixtures.createTemporaryVideo(size: size)
        let video = Video(
            url: url,
            asset: AVURLAsset(url: url),
            originalDuration: 1,
            rangeDuration: 0...1,
            presentationSize: size
        )
        let exportProfile = VideoEditor.resolvedExportProfile(
            for: video,
            editingConfiguration: .initial,
            videoQuality: .original,
            isSimulatorEnvironment: true
        )

        let canIntegrate = await VideoEditor.canIntegrateAdjustsIntoBaseRender(
            video: video,
            editingConfiguration: .initial,
            exportProfile: exportProfile
        )

        #expect(canIntegrate)
    }

    @Test
    func canIntegrateAdjustsIntoBaseRenderRejectsScaledOutputs() async throws {
        let size = CGSize(width: 48, height: 24)
        let url = try await TestFixtures.createTemporaryVideo(size: size)
        let video = Video(
            url: url,
            asset: AVURLAsset(url: url),
            originalDuration: 1,
            rangeDuration: 0...1,
            presentationSize: size
        )
        let scaledProfile = VideoEditor.ExportProfile(
            quality: .medium,
            renderSize: CGSize(width: 96, height: 48),
            frameDuration: CMTime(seconds: 1 / 30, preferredTimescale: 600),
            renderPresetName: AVAssetExportPresetHighestQuality,
            passthroughPresetName: AVAssetExportPresetPassthrough
        )

        let canIntegrate = await VideoEditor.canIntegrateAdjustsIntoBaseRender(
            video: video,
            editingConfiguration: .initial,
            exportProfile: scaledProfile
        )

        #expect(canIntegrate == false)
    }

    @Test
    func resolvedExportRenderProfileKeepsSelectedQualityRules() {
        let profile = VideoEditor.resolvedRenderProfile(
            for: CGSize(width: 1920, height: 1080),
            editingConfiguration: VideoEditingConfiguration(
                canvas: .init(
                    snapshot: .init(
                        preset: .facebookPost,
                        freeCanvasSize: CGSize(width: 1080, height: 1350)
                    )
                )
            ),
            intent: .export(.medium),
            isSimulatorEnvironment: true
        )

        #expect(profile.intent == .export(.medium))
        #expect(profile.renderSize == CGSize(width: 720, height: 900))
        #expect(profile.frameDuration == CMTime(seconds: 1 / 30, preferredTimescale: 600))
    }

    @Test
    func resolvedOutputRenderLayoutUsesCanvasPresetOrientationWhenPersisted() {
        let configuration = VideoEditingConfiguration(
            canvas: .init(
                snapshot: .init(
                    preset: .custom(width: 1080, height: 1080),
                    freeCanvasSize: CGSize(width: 1080, height: 1080)
                )
            )
        )

        let layout = VideoEditor.resolvedOutputRenderLayout(
            for: CGSize(width: 1920, height: 1080),
            editingConfiguration: configuration
        )

        #expect(layout == .landscape)
    }

    @Test
    func resolvedExportPresetNameUsesARealRenderPresetForVideoCompositionOnSimulator() {
        let presetName = VideoEditor.resolvedExportPresetName(
            videoQuality: .low,
            appliesVideoComposition: true,
            isSimulatorEnvironment: true
        )

        #expect(presetName == AVAssetExportPresetHighestQuality)
    }

    @Test
    func resolvedExportPresetNameKeepsPassthroughAvailableOnlyWithoutRenderingStages() {
        let presetName = VideoEditor.resolvedExportPresetName(
            videoQuality: .high,
            appliesVideoComposition: false,
            isSimulatorEnvironment: true
        )

        #expect(presetName == AVAssetExportPresetPassthrough)
    }

    @Test
    func resolvedRenderStagesAbsorbCanvasIntoTheBaseStageWhenCanvasRenderingIsActive() {
        let stages = VideoEditor.resolvedRenderStages(
            usesAdjustsStage: true,
            usesTranscriptStage: true,
            usesCropStage: true,
            usesWatermarkStage: false
        )

        #expect(stages == [.base, .adjusts, .transcript])
    }

    @Test
    func resolvedRenderStagesKeepsTranscriptImmediatelyAfterAdjustsWhenCanvasRenderingIsDisabled() {
        let stages = VideoEditor.resolvedRenderStages(
            usesAdjustsStage: true,
            usesTranscriptStage: true,
            usesCropStage: false,
            usesWatermarkStage: false
        )

        #expect(stages == [.base, .adjusts, .transcript])
    }

    @Test
    func resolvedRenderStagesAppliesWatermarkAsTheFinalStage() {
        let stages = VideoEditor.resolvedRenderStages(
            usesAdjustsStage: true,
            usesTranscriptStage: true,
            usesCropStage: false,
            usesWatermarkStage: true
        )

        #expect(stages == [.base, .adjusts, .transcript, .watermark])
    }

    @Test
    func resolvedTranscriptRenderBatchesSplitLargeWordRunsWithoutChangingOrder() {
        let firstSegment = VideoEditor.TranscriptRenderSegment(
            text: "one",
            timeRange: 0...1,
            style: .defaultCaptionStyle,
            words: (0..<20).map { index in
                VideoEditor.TranscriptRenderWord(
                    id: UUID(),
                    text: "w\(index)",
                    timeRange: Double(index)...Double(index + 1)
                )
            }
        )
        let secondSegment = VideoEditor.TranscriptRenderSegment(
            text: "two",
            timeRange: 1...2,
            style: .defaultCaptionStyle,
            words: (20..<40).map { index in
                VideoEditor.TranscriptRenderWord(
                    id: UUID(),
                    text: "w\(index)",
                    timeRange: Double(index)...Double(index + 1)
                )
            }
        )
        let thirdSegment = VideoEditor.TranscriptRenderSegment(
            text: "fallback",
            timeRange: 2...3,
            style: .defaultCaptionStyle,
            words: []
        )
        let renderUnits = VideoEditor.resolvedTranscriptRenderUnits(
            from: [firstSegment, secondSegment, thirdSegment]
        )

        let batches = VideoEditor.resolvedTranscriptRenderBatches(
            from: renderUnits
        )

        #expect(batches.count == 2)
        #expect(batches[0].count == 32)
        #expect(batches[1].count == 9)
        #expect(
            batches.flatMap { $0.map(\.text) }
                == renderUnits.map(\.text)
        )
    }

    @Test
    func requiresTranscriptStageOnlyWhenALoadedTimelineSegmentExists() {
        let loadedConfiguration = VideoEditingConfiguration(
            transcript: .init(
                featureState: .loaded,
                document: TranscriptDocument(
                    segments: [
                        EditableTranscriptSegment(
                            id: UUID(),
                            timeMapping: .init(
                                sourceStartTime: 4,
                                sourceEndTime: 8,
                                timelineStartTime: 2,
                                timelineEndTime: 6
                            ),
                            originalText: "Hello",
                            editedText: "Hello"
                        )
                    ]
                )
            )
        )
        let missingTimelineConfiguration = VideoEditingConfiguration(
            transcript: .init(
                featureState: .loaded,
                document: TranscriptDocument(
                    segments: [
                        EditableTranscriptSegment(
                            id: UUID(),
                            timeMapping: .init(
                                sourceStartTime: 4,
                                sourceEndTime: 8,
                                timelineStartTime: nil,
                                timelineEndTime: nil
                            ),
                            originalText: "Hello",
                            editedText: "Hello"
                        )
                    ]
                )
            )
        )

        #expect(VideoEditor.requiresTranscriptStage(loadedConfiguration))
        #expect(VideoEditor.requiresTranscriptStage(missingTimelineConfiguration) == false)
    }

    @Test
    func resolvedTranscriptRenderSegmentsUseTheDefaultStyleAndKeepRenderableWords() {
        let transcriptDocument = TranscriptDocument(
            segments: [
                EditableTranscriptSegment(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 4,
                        sourceEndTime: 8,
                        timelineStartTime: 2,
                        timelineEndTime: 6
                    ),
                    originalText: "hello world",
                    editedText: "hello world",
                    words: [
                        EditableTranscriptWord(
                            id: UUID(),
                            timeMapping: .init(
                                sourceStartTime: 4,
                                sourceEndTime: 5,
                                timelineStartTime: 2,
                                timelineEndTime: 3
                            ),
                            originalText: "hello",
                            editedText: "hello"
                        ),
                        EditableTranscriptWord(
                            id: UUID(),
                            timeMapping: .init(
                                sourceStartTime: 5,
                                sourceEndTime: 6,
                                timelineStartTime: 3,
                                timelineEndTime: 4
                            ),
                            originalText: "world",
                            editedText: "world"
                        ),
                    ]
                )
            ]
        )

        let renderSegments = VideoEditor.resolvedTranscriptRenderSegments(
            from: transcriptDocument
        )

        #expect(renderSegments.count == 1)
        #expect(renderSegments.first?.style.name == "Default")
        #expect(renderSegments.first?.style.fontWeight == .semibold)
        #expect(renderSegments.first?.style.hasStroke == true)
        #expect(
            renderSegments.first?.style.strokeColor
                == .init(
                    red: 0,
                    green: 0,
                    blue: 0,
                    alpha: 1
                )
        )
        #expect(renderSegments.first?.words.map(\.text) == ["hello", "world"])
        #expect(renderSegments.first?.words.count == transcriptDocument.segments.first?.words.count)
    }

    @Test
    func resolvedTranscriptRenderSegmentsForExportNormalizesTrimmedTimelineToZero() throws {
        let firstWordID = UUID()
        let secondWordID = UUID()
        let transcriptDocument = TranscriptDocument(
            segments: [
                EditableTranscriptSegment(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 10,
                        sourceEndTime: 12,
                        timelineStartTime: 5,
                        timelineEndTime: 6
                    ),
                    originalText: "hello world",
                    editedText: "hello world",
                    words: [
                        EditableTranscriptWord(
                            id: firstWordID,
                            timeMapping: .init(
                                sourceStartTime: 10,
                                sourceEndTime: 11,
                                timelineStartTime: 5,
                                timelineEndTime: 5.5
                            ),
                            originalText: "hello",
                            editedText: "hello"
                        ),
                        EditableTranscriptWord(
                            id: secondWordID,
                            timeMapping: .init(
                                sourceStartTime: 11,
                                sourceEndTime: 12,
                                timelineStartTime: 5.5,
                                timelineEndTime: 6
                            ),
                            originalText: "world",
                            editedText: "world"
                        ),
                    ]
                )
            ]
        )
        let editingConfiguration = VideoEditingConfiguration(
            trim: .init(
                lowerBound: 10,
                upperBound: 12
            ),
            playback: .init(
                rate: 2
            )
        )

        let renderSegment = try #require(
            VideoEditor.resolvedTranscriptRenderSegmentsForExport(
                from: transcriptDocument,
                editingConfiguration: editingConfiguration
            ).first
        )

        #expect(renderSegment.timeRange == 0...1)
        #expect(renderSegment.words.map(\.id) == [firstWordID, secondWordID])
        #expect(renderSegment.words.map(\.timeRange) == [0...0.5, 0.5...1])
    }

    @Test
    func resolvedTranscriptVisibilityAnimationTurnsOnImmediatelyAtSegmentStart() {
        let animation = VideoEditor.resolvedTranscriptVisibilityAnimation(
            for: 2.0...3.0
        )

        #expect((animation.values as? [NSNumber])?.map(\.doubleValue) == [0, 1, 1, 0])
        #expect(animation.keyTimes?.map(\.doubleValue) == [0, 0.0001, 0.999, 1])
    }

    @Test
    func resolvedActiveWordTimelineStatesInsertHiddenStatesOnlyAcrossRealGaps() {
        let renderUnits: [VideoEditor.TranscriptRenderUnit] = [
            .init(
                text: "alpha",
                timeRange: 0...0.8,
                style: .defaultCaptionStyle,
                mode: .activeWord
            ),
            .init(
                text: "beta",
                timeRange: 0.8...1.4,
                style: .defaultCaptionStyle,
                mode: .activeWord
            ),
            .init(
                text: "gamma",
                timeRange: 2.0...2.6,
                style: .defaultCaptionStyle,
                mode: .activeWord
            ),
        ]

        let timelineStates = VideoEditor.resolvedActiveWordTimelineStates(
            from: renderUnits,
            overlayPosition: .bottom,
            overlaySize: .medium,
            renderSize: CGSize(width: 1080, height: 1920)
        )

        #expect(timelineStates.map(\.time) == [0, 0.8, 1.4, 2.0, 2.6])
        #expect(timelineStates.map(\.text) == ["alpha", "beta", nil, "gamma", nil])
    }

    @Test
    func resolvedActiveWordTimelineStatesUseTheFullAvailableCaptionWidthForSingleWords() throws {
        let renderUnits: [VideoEditor.TranscriptRenderUnit] = [
            .init(
                text: "Edmure,",
                timeRange: 0...1,
                style: .defaultCaptionStyle,
                mode: .activeWord
            )
        ]

        let timelineState = try #require(
            VideoEditor.resolvedActiveWordTimelineStates(
                from: renderUnits,
                overlayPosition: .bottom,
                overlaySize: .medium,
                renderSize: CGSize(width: 1080, height: 1920)
            ).first
        )

        #expect(timelineState.text == "Edmure,")
        #expect(abs(timelineState.frame.minX - 16) < 0.0001)
        #expect(abs((1080 - timelineState.frame.maxX) - 16) < 0.0001)
        #expect(abs(timelineState.frame.width - 1048) < 0.0001)
        #expect(abs(timelineState.textFrame.width - 984) < 0.0001)
        #expect(abs(timelineState.frame.midX - 540) < 0.0001)
        #expect(abs((1920 - timelineState.frame.maxY) - 135) < 0.0001)
    }

    @Test
    func resolvedActiveWordRasterLayoutKeepsCenteredAlignmentWhileReducingTheExportFrame() throws {
        let timelineState = VideoEditor.TranscriptActiveWordTimelineState(
            time: 0,
            text: "Edmure,",
            frame: CGRect(x: 16, y: 1733, width: 1048, height: 52),
            textFrame: CGRect(x: 48, y: 1765, width: 984, height: 20),
            fontSize: 20,
            style: .defaultCaptionStyle
        )

        let rasterLayout = try #require(
            VideoEditor.resolvedActiveWordRasterLayout(
                for: timelineState,
                text: "Edmure,"
            )
        )

        #expect(rasterLayout.frame.width < timelineState.frame.width)
        #expect(abs(rasterLayout.frame.midX - timelineState.frame.midX) < 0.0001)
        #expect(rasterLayout.textFrame.width < timelineState.textFrame.width)
        #expect(abs(rasterLayout.textFrame.midX - timelineState.textFrame.midX) < 0.0001)
    }

    @Test
    func resolvedActiveWordRasterLayoutReturnsNilForHiddenStates() {
        let timelineState = VideoEditor.TranscriptActiveWordTimelineState(
            time: 1,
            text: nil,
            frame: .zero,
            textFrame: .zero,
            fontSize: 0,
            style: .defaultCaptionStyle
        )

        let rasterLayout = VideoEditor.resolvedActiveWordRasterLayout(
            for: timelineState,
            text: "unused"
        )

        #expect(rasterLayout == nil)
    }

    @Test
    func resolvedTranscriptRenderSegmentsKeepTimedWordBlocksWhenEditedTextIsHeavilyRewritten() {
        let transcriptDocument = TranscriptDocument(
            segments: [
                EditableTranscriptSegment(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 4,
                        sourceEndTime: 8,
                        timelineStartTime: 2,
                        timelineEndTime: 6
                    ),
                    originalText: "hello world",
                    editedText: "greetings brave world",
                    words: [
                        EditableTranscriptWord(
                            id: UUID(),
                            timeMapping: .init(
                                sourceStartTime: 4,
                                sourceEndTime: 5,
                                timelineStartTime: 2,
                                timelineEndTime: 3
                            ),
                            originalText: "hello",
                            editedText: "hello"
                        ),
                        EditableTranscriptWord(
                            id: UUID(),
                            timeMapping: .init(
                                sourceStartTime: 5,
                                sourceEndTime: 6,
                                timelineStartTime: 3,
                                timelineEndTime: 4
                            ),
                            originalText: "world",
                            editedText: "world"
                        ),
                    ]
                )
            ]
        )

        let renderSegments = VideoEditor.resolvedTranscriptRenderSegments(
            from: transcriptDocument
        )

        #expect(renderSegments.count == 1)
        #expect(renderSegments.first?.words.map(\.text) == ["greetings brave", "world"])
    }

    @Test
    func resolvedTranscriptRenderSegmentsReconcileStandalonePunctuationIntoRenderableWords() {
        let firstWordID = UUID()
        let secondWordID = UUID()
        let transcriptDocument = TranscriptDocument(
            segments: [
                EditableTranscriptSegment(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 4,
                        sourceEndTime: 8,
                        timelineStartTime: 2,
                        timelineEndTime: 6
                    ),
                    originalText: "hello world",
                    editedText: "\" Hello , world !",
                    words: [
                        EditableTranscriptWord(
                            id: firstWordID,
                            timeMapping: .init(
                                sourceStartTime: 4,
                                sourceEndTime: 5,
                                timelineStartTime: 2,
                                timelineEndTime: 3
                            ),
                            originalText: "hello",
                            editedText: "hello"
                        ),
                        EditableTranscriptWord(
                            id: secondWordID,
                            timeMapping: .init(
                                sourceStartTime: 5,
                                sourceEndTime: 6,
                                timelineStartTime: 3,
                                timelineEndTime: 4
                            ),
                            originalText: "world",
                            editedText: "world"
                        ),
                    ]
                )
            ]
        )

        let renderSegments = VideoEditor.resolvedTranscriptRenderSegments(
            from: transcriptDocument
        )

        #expect(renderSegments.count == 1)
        #expect(renderSegments.first?.words.map(\.id) == [firstWordID, secondWordID])
        #expect(renderSegments.first?.words.map(\.text) == ["\"Hello,", "world!"])
    }

    @Test
    func resolvedTranscriptRenderSegmentsKeepRenderableWordBlocksWhenTheTextGainsAnInsertedWord() {
        let transcriptDocument = TranscriptDocument(
            segments: [
                EditableTranscriptSegment(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 4,
                        sourceEndTime: 8,
                        timelineStartTime: 2,
                        timelineEndTime: 6
                    ),
                    originalText: "hello world",
                    editedText: "hello brave world",
                    words: [
                        EditableTranscriptWord(
                            id: UUID(),
                            timeMapping: .init(
                                sourceStartTime: 4,
                                sourceEndTime: 5,
                                timelineStartTime: 2,
                                timelineEndTime: 3
                            ),
                            originalText: "hello",
                            editedText: "hello"
                        ),
                        EditableTranscriptWord(
                            id: UUID(),
                            timeMapping: .init(
                                sourceStartTime: 5,
                                sourceEndTime: 6,
                                timelineStartTime: 3,
                                timelineEndTime: 4
                            ),
                            originalText: "world",
                            editedText: "world"
                        ),
                    ]
                )
            ]
        )

        let renderSegments = VideoEditor.resolvedTranscriptRenderSegments(
            from: transcriptDocument
        )

        #expect(renderSegments.count == 1)
        #expect(renderSegments.first?.words.map(\.text) == ["hello brave", "world"])
    }

    @Test
    func resolvedTranscriptRenderSegmentsKeepManualCaptionsAsTimedBlocks() {
        let transcriptDocument = TranscriptDocument(
            segments: [
                EditableTranscriptSegment(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 4,
                        sourceEndTime: 8,
                        timelineStartTime: 2,
                        timelineEndTime: 6
                    ),
                    originalText: "hello world",
                    editedText: "greetings brave world"
                )
            ]
        )

        let renderSegments = VideoEditor.resolvedTranscriptRenderSegments(
            from: transcriptDocument
        )
        #expect(renderSegments.count == 1)
        #expect(renderSegments.first?.words.isEmpty == true)
        #expect(renderSegments.first?.text == "greetings brave world")
        #expect(renderSegments.first?.timeRange == 2...6)
    }

    @Test
    func resolvedTranscriptRenderSegmentsPreserveTimelineRangesPerWordForExportHighlighting() throws {
        let firstWordID = UUID()
        let secondWordID = UUID()
        let thirdWordID = UUID()
        let segment = EditableTranscriptSegment(
            id: UUID(),
            timeMapping: .init(
                sourceStartTime: 10,
                sourceEndTime: 13,
                timelineStartTime: 2,
                timelineEndTime: 5
            ),
            originalText: "alpha beta gamma",
            editedText: "alpha beta gamma",
            words: [
                EditableTranscriptWord(
                    id: firstWordID,
                    timeMapping: .init(
                        sourceStartTime: 10,
                        sourceEndTime: 11,
                        timelineStartTime: 2.0,
                        timelineEndTime: 2.8
                    ),
                    originalText: "alpha",
                    editedText: "alpha"
                ),
                EditableTranscriptWord(
                    id: secondWordID,
                    timeMapping: .init(
                        sourceStartTime: 11,
                        sourceEndTime: 12,
                        timelineStartTime: 2.8,
                        timelineEndTime: 3.7
                    ),
                    originalText: "beta",
                    editedText: "beta"
                ),
                EditableTranscriptWord(
                    id: thirdWordID,
                    timeMapping: .init(
                        sourceStartTime: 12,
                        sourceEndTime: 13,
                        timelineStartTime: 3.7,
                        timelineEndTime: 5.0
                    ),
                    originalText: "gamma",
                    editedText: "gamma"
                ),
            ]
        )
        let transcriptDocument = TranscriptDocument(
            segments: [segment]
        )

        let renderSegment = try #require(
            VideoEditor.resolvedTranscriptRenderSegments(
                from: transcriptDocument
            ).first
        )

        #expect(renderSegment.words.map(\.id) == [firstWordID, secondWordID, thirdWordID])
        #expect(renderSegment.words.map(\.timeRange) == [2.0...2.8, 2.8...3.7, 3.7...5.0])
    }

    @Test
    func resolvedTranscriptRenderSegmentsMatchTheEditorWordLayoutOrderForWrappedCaptions() throws {
        let segment = EditableTranscriptSegment(
            id: UUID(),
            timeMapping: .init(
                sourceStartTime: 0,
                sourceEndTime: 4,
                timelineStartTime: 0,
                timelineEndTime: 4
            ),
            originalText: "one two three four five six seven eight",
            editedText: "one two three four five six seven eight",
            words: [
                EditableTranscriptWord(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 0, sourceEndTime: 0.5, timelineStartTime: 0, timelineEndTime: 0.5
                    ),
                    originalText: "one",
                    editedText: "one"
                ),
                EditableTranscriptWord(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 0.5, sourceEndTime: 1, timelineStartTime: 0.5, timelineEndTime: 1
                    ),
                    originalText: "two",
                    editedText: "two"
                ),
                EditableTranscriptWord(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 1, sourceEndTime: 1.5, timelineStartTime: 1, timelineEndTime: 1.5
                    ),
                    originalText: "three",
                    editedText: "three"
                ),
                EditableTranscriptWord(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 1.5, sourceEndTime: 2, timelineStartTime: 1.5, timelineEndTime: 2
                    ),
                    originalText: "four",
                    editedText: "four"
                ),
                EditableTranscriptWord(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 2, sourceEndTime: 2.5, timelineStartTime: 2, timelineEndTime: 2.5
                    ),
                    originalText: "five",
                    editedText: "five"
                ),
                EditableTranscriptWord(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 2.5, sourceEndTime: 3, timelineStartTime: 2.5, timelineEndTime: 3
                    ),
                    originalText: "six",
                    editedText: "six"
                ),
                EditableTranscriptWord(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 3, sourceEndTime: 3.5, timelineStartTime: 3, timelineEndTime: 3.5
                    ),
                    originalText: "seven",
                    editedText: "seven"
                ),
                EditableTranscriptWord(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 3.5, sourceEndTime: 4, timelineStartTime: 3.5, timelineEndTime: 4
                    ),
                    originalText: "eight",
                    editedText: "eight"
                ),
            ]
        )
        let transcriptDocument = TranscriptDocument(
            segments: [segment]
        )

        let renderSegment = try #require(
            VideoEditor.resolvedTranscriptRenderSegments(
                from: transcriptDocument
            ).first
        )
        let layout = TranscriptOverlayLayoutResolver.resolve(
            videoWidth: 320,
            videoHeight: 568,
            selectedPosition: .bottom,
            selectedSize: .medium,
            segment: segment
        )

        #expect(renderSegment.words.count == layout.wordLayouts.count)
        #expect(renderSegment.words.map(\.id) == layout.wordLayouts.map(\.wordID))
        #expect(renderSegment.words.map(\.text) == layout.wordLayouts.map(\.text))
    }

    @Test
    func resolvedTranscriptExportSegmentsRemainRenderableWhenTheVideoIsCropped() throws {
        let transcriptDocument = TranscriptDocument(
            segments: [
                EditableTranscriptSegment(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 0,
                        sourceEndTime: 1.5,
                        timelineStartTime: 0,
                        timelineEndTime: 1.5
                    ),
                    originalText: "MMMMMMMMMMMMMMMMMMMMMMMM",
                    editedText: "MMMMMMMMMMMMMMMMMMMMMMMM"
                )
            ],
            overlayPosition: .center,
            overlaySize: .large
        )
        let croppedConfiguration = VideoEditingConfiguration(
            crop: .init(
                freeformRect: .init(
                    x: 0.25,
                    y: 0,
                    width: 0.5,
                    height: 1
                )
            ),
            transcript: .init(
                featureState: .loaded,
                document: transcriptDocument
            )
        )
        let renderSegment = try #require(
            VideoEditor.resolvedTranscriptRenderSegmentsForExport(
                from: transcriptDocument,
                editingConfiguration: croppedConfiguration
            ).first
        )
        let renderSize = VideoEditor.resolvedOutputRenderSize(
            for: CGSize(width: 160, height: 90),
            editingConfiguration: croppedConfiguration,
            videoQuality: .low
        )
        let stages = VideoEditor.resolvedRenderStages(
            usesAdjustsStage: false,
            usesTranscriptStage: VideoEditor.requiresTranscriptStage(croppedConfiguration),
            usesCropStage: true,
            usesWatermarkStage: false
        )

        #expect(renderSegment.text == "MMMMMMMMMMMMMMMMMMMMMMMM")
        #expect(renderSegment.timeRange == 0...1.5)
        #expect(renderSegment.words.map(\.text) == ["MMMMMMMMMMMMMMMMMMMMMMMM"])
        #expect(renderSize == CGSize(width: 80, height: 90))
        #expect(stages == [.base, .transcript])
    }

    @Test
    func resolvedActiveWordTranscriptExportUnitsRemainRenderableWhenTheVideoIsCropped() throws {
        let wordID = UUID()
        let transcriptDocument = TranscriptDocument(
            segments: [
                EditableTranscriptSegment(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 0,
                        sourceEndTime: 1.5,
                        timelineStartTime: 0,
                        timelineEndTime: 1.5
                    ),
                    originalText: "MMMMMMMMMMMMMMMM",
                    editedText: "MMMMMMMMMMMMMMMM",
                    words: [
                        EditableTranscriptWord(
                            id: wordID,
                            timeMapping: .init(
                                sourceStartTime: 0,
                                sourceEndTime: 1.5,
                                timelineStartTime: 0,
                                timelineEndTime: 1.5
                            ),
                            originalText: "MMMMMMMMMMMMMMMM",
                            editedText: "MMMMMMMMMMMMMMMM"
                        )
                    ]
                )
            ],
            overlayPosition: .center,
            overlaySize: .large
        )
        let croppedConfiguration = VideoEditingConfiguration(
            crop: .init(
                freeformRect: .init(
                    x: 0.25,
                    y: 0,
                    width: 0.5,
                    height: 1
                )
            ),
            transcript: .init(
                featureState: .loaded,
                document: transcriptDocument
            )
        )
        let renderSegments = VideoEditor.resolvedTranscriptRenderSegmentsForExport(
            from: transcriptDocument,
            editingConfiguration: croppedConfiguration
        )
        let renderUnits = VideoEditor.resolvedTranscriptRenderUnits(
            from: renderSegments
        )
        let timelineStates = VideoEditor.resolvedActiveWordTimelineStates(
            from: renderUnits,
            overlayPosition: transcriptDocument.overlayPosition,
            overlaySize: transcriptDocument.overlaySize,
            renderSize: CGSize(width: 480, height: 540)
        )
        let renderSegment = try #require(renderSegments.first)
        let renderUnit = try #require(renderUnits.first)
        let visibleState = try #require(timelineStates.first { !$0.isHidden })

        #expect(renderSegment.words.map(\.id) == [wordID])
        #expect(renderUnit.mode == .activeWord)
        #expect(renderUnit.text == "MMMMMMMMMMMMMMMM")
        #expect(renderUnit.timeRange == 0...1.5)
        #expect(visibleState.text == "MMMMMMMMMMMMMMMM")
        #expect(visibleState.frame.width > 0)
        #expect(visibleState.frame.height > 0)
    }

    @Test
    func resolvedTranscriptExportSegmentsNormalizeTrimmedTimelineToTheExportStart() throws {
        let transcriptDocument = TranscriptDocument(
            segments: [
                EditableTranscriptSegment(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 2,
                        sourceEndTime: 3,
                        timelineStartTime: 2,
                        timelineEndTime: 3
                    ),
                    originalText: "MMMMMMMMMMMMMMMMMMMMMMMM",
                    editedText: "MMMMMMMMMMMMMMMMMMMMMMMM"
                )
            ],
            overlayPosition: .center,
            overlaySize: .large
        )
        let configuration = VideoEditingConfiguration(
            trim: .init(
                lowerBound: 2,
                upperBound: 3
            ),
            transcript: .init(
                featureState: .loaded,
                document: transcriptDocument
            )
        )
        let renderSegment = try #require(
            VideoEditor.resolvedTranscriptRenderSegmentsForExport(
                from: transcriptDocument,
                editingConfiguration: configuration
            ).first
        )

        #expect(renderSegment.text == "MMMMMMMMMMMMMMMMMMMMMMMM")
        #expect(renderSegment.timeRange == 0...1)
        #expect(VideoEditor.requiresTranscriptStage(configuration))
    }

}

private struct RenderedPixel {

    // MARK: - Public Properties

    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8

    var isMostlyBlue: Bool {
        blue > 160 && red < 120 && green < 160 && alpha > 180
    }

}

private func renderedPixel(
    in image: CGImage,
    x: Int,
    y: Int
) -> RenderedPixel? {
    guard x >= 0, y >= 0, x < image.width, y < image.height else { return nil }
    guard let dataProviderData = image.dataProvider?.data else { return nil }
    guard let data = CFDataGetBytePtr(dataProviderData) else { return nil }

    let bytesPerPixel = max(image.bitsPerPixel / 8, 1)
    let offset = (y * image.bytesPerRow) + (x * bytesPerPixel)
    guard offset + 3 < CFDataGetLength(dataProviderData) else { return nil }

    return RenderedPixel(
        red: data[offset],
        green: data[offset + 1],
        blue: data[offset + 2],
        alpha: data[offset + 3]
    )
}

extension VideoEditorTests {
    @Test @MainActor
    func floeChineseCaptionIsBurnedIntoExportOnlyWithinItsTimeRange() async throws {
        let source = try await TestFixtures.createTemporaryVideo(
            size: CGSize(width: 320, height: 180), frameCount: 60,
            framesPerSecond: 30, color: .red)
        defer { FileManager.default.removeIfExists(for: source) }
        let document = TranscriptDocument(segments: [
            .init(id: UUID(), timeMapping: .init(sourceStartTime: 0.5, sourceEndTime: 1.4),
                  originalText: "中文字幕 Floe", editedText: "中文字幕 Floe")
        ])
        let mapped = EditorTranscriptRemappingCoordinator.remap(document, trimRange: 0...2, playbackRate: 1)
        let configuration = VideoEditingConfiguration(trim: .init(lowerBound: 0, upperBound: 2), transcript: .init(featureState: .loaded, document: mapped))
        let video = await Video.load(from: source)
        let rendered = try await VideoEditor.startRender(video: video, editingConfiguration: configuration, videoQuality: .original)
        defer { FileManager.default.removeIfExists(for: rendered) }
        let asset = AVURLAsset(url: rendered)
        let directory = URL.documentsDirectory.appendingPathComponent("FloeVideoEditorEvidence", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copy = directory.appendingPathComponent("chinese-caption.mp4")
        FileManager.default.removeIfExists(for: copy)
        try FileManager.default.copyItem(at: rendered, to: copy)
        var counts: [Int] = []
        for (label, time) in [("before", 0.1), ("during", 0.9), ("after", 1.7)] {
            let image = try #require(await asset.generateImage(at: time, maximumSize: CGSize(width: 320, height: 180), requiresExactFrame: true))
            let cg = try #require(image.cgImage)
            var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            let count = bytes.withUnsafeMutableBytes { storage -> Int in
                let context = CGContext(data: storage.baseAddress, width: cg.width, height: cg.height,
                    bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
                let pixels = storage.bindMemory(to: UInt8.self)
                return stride(from: 0, to: pixels.count, by: 4).filter {
                    pixels[$0] > 180 && pixels[$0 + 1] > 180 && pixels[$0 + 2] > 180
                }.count
            }
            counts.append(count)
            try image.pngData()?.write(to: directory.appendingPathComponent(label + ".png"))
        }
        #expect(counts[1] > 30)
        #expect(counts[0] < 10)
        #expect(counts[2] < 10)
        try JSONEncoder().encode(counts).write(to: directory.appendingPathComponent("white-pixels-before-during-after.json"))
    }
}
