import Foundation
import SwiftUI
import Testing

@testable import VideoEditorKit

@Suite("VideoEditingThumbnailRendererTests")
struct VideoEditingThumbnailRendererTests {

    // MARK: - Public Methods

    @Test
    func makeThumbnailDataFallsBackToTheTrimLowerBoundFrameWhenNoCurrentTimeIsAvailable() async throws {
        let videoURL = try await TestFixtures.createTemporaryVideo(
            size: CGSize(width: 80, height: 40),
            frameCount: 60,
            framesPerSecond: 30,
            drawFrame: { context, size, frameIndex in
                let color = frameIndex < 30 ? UIColor.systemRed : UIColor.systemBlue
                context.setFillColor(color.cgColor)
                context.fill(CGRect(origin: .zero, size: size))
            }
        )

        let editingConfiguration = VideoEditingConfiguration(
            trim: .init(lowerBound: 1.2, upperBound: 2.0)
        )

        defer { FileManager.default.removeIfExists(for: videoURL) }

        let thumbnailData = await VideoEditingThumbnailRenderer.makeThumbnailData(
            sourceVideoURL: videoURL,
            editingConfiguration: editingConfiguration,
            maximumSize: CGSize(width: 80, height: 80)
        )

        let thumbnailImage = try #require(thumbnailData.flatMap(UIImage.init(data:)))
        let sampledColor = try #require(
            thumbnailImage.sampledColor(
                at: CGPoint(
                    x: thumbnailImage.size.width / 2,
                    y: thumbnailImage.size.height / 2
                )
            )
        )

        #expect(sampledColor.blueComponent > 0.55)
        #expect(sampledColor.redComponent < 0.45)
    }

    @Test
    func makeThumbnailDataIgnoresTheCurrentTimelineFrameWhenGeneratingSourceThumbnails() async throws {
        let videoURL = try await TestFixtures.createTemporaryVideo(
            size: CGSize(width: 80, height: 40),
            frameCount: 60,
            framesPerSecond: 30,
            drawFrame: { context, size, frameIndex in
                let color = frameIndex < 30 ? UIColor.systemRed : UIColor.systemBlue
                context.setFillColor(color.cgColor)
                context.fill(CGRect(origin: .zero, size: size))
            }
        )
        let editingConfiguration = VideoEditingConfiguration(
            trim: .init(lowerBound: 0.2, upperBound: 2.0),
            playback: .init(
                rate: 1,
                videoVolume: 1,
                currentTimelineTime: 1.2
            )
        )

        defer { FileManager.default.removeIfExists(for: videoURL) }

        let thumbnailData = await VideoEditingThumbnailRenderer.makeThumbnailData(
            sourceVideoURL: videoURL,
            editingConfiguration: editingConfiguration,
            maximumSize: CGSize(width: 80, height: 80)
        )
        let thumbnailImage = try #require(thumbnailData.flatMap(UIImage.init(data:)))
        let sampledColor = try #require(
            thumbnailImage.sampledColor(
                at: CGPoint(
                    x: thumbnailImage.size.width / 2,
                    y: thumbnailImage.size.height / 2
                )
            )
        )

        #expect(sampledColor.redComponent > 0.55)
        #expect(sampledColor.blueComponent < 0.45)
    }

    @Test
    func makeThumbnailDataStillUsesTheTrimStartWhenPlaybackRateChanges() async throws {
        let videoURL = try await TestFixtures.createTemporaryVideo(
            size: CGSize(width: 80, height: 40),
            frameCount: 60,
            framesPerSecond: 30,
            drawFrame: { context, size, frameIndex in
                let color = frameIndex < 30 ? UIColor.systemRed : UIColor.systemBlue
                context.setFillColor(color.cgColor)
                context.fill(CGRect(origin: .zero, size: size))
            }
        )
        let editingConfiguration = VideoEditingConfiguration(
            trim: .init(lowerBound: 0, upperBound: 2.0),
            playback: .init(
                rate: 2,
                videoVolume: 1,
                currentTimelineTime: 0.6
            )
        )

        defer { FileManager.default.removeIfExists(for: videoURL) }

        let thumbnailData = await VideoEditingThumbnailRenderer.makeThumbnailData(
            sourceVideoURL: videoURL,
            editingConfiguration: editingConfiguration,
            maximumSize: CGSize(width: 80, height: 80)
        )
        let thumbnailImage = try #require(thumbnailData.flatMap(UIImage.init(data:)))
        let sampledColor = try #require(
            thumbnailImage.sampledColor(
                at: CGPoint(
                    x: thumbnailImage.size.width / 2,
                    y: thumbnailImage.size.height / 2
                )
            )
        )

        #expect(sampledColor.redComponent > 0.55)
        #expect(sampledColor.blueComponent < 0.45)
    }

    @Test
    func makeThumbnailDataUsesTheFreeformCropVisibleRegion() async throws {
        let videoURL = try await TestFixtures.createTemporaryVideo(
            size: CGSize(width: 80, height: 40),
            frameCount: 30,
            drawFrame: { context, size, _ in
                context.setFillColor(UIColor.systemRed.cgColor)
                context.fill(
                    CGRect(
                        x: 0,
                        y: 0,
                        width: size.width / 2,
                        height: size.height
                    )
                )

                context.setFillColor(UIColor.systemBlue.cgColor)
                context.fill(
                    CGRect(
                        x: size.width / 2,
                        y: 0,
                        width: size.width / 2,
                        height: size.height
                    )
                )
            }
        )

        defer { FileManager.default.removeIfExists(for: videoURL) }

        let leftThumbnail = await makeThumbnailImage(
            sourceVideoURL: videoURL,
            freeformRect: .init(
                x: 0,
                y: 0,
                width: 0.5,
                height: 1
            )
        )
        let rightThumbnail = await makeThumbnailImage(
            sourceVideoURL: videoURL,
            freeformRect: .init(
                x: 0.5,
                y: 0,
                width: 0.5,
                height: 1
            )
        )

        let leftColor = try #require(
            leftThumbnail?.sampledColor(
                at: CGPoint(
                    x: (leftThumbnail?.size.width ?? 0) / 2,
                    y: (leftThumbnail?.size.height ?? 0) / 2
                )
            )
        )
        let rightColor = try #require(
            rightThumbnail?.sampledColor(
                at: CGPoint(
                    x: (rightThumbnail?.size.width ?? 0) / 2,
                    y: (rightThumbnail?.size.height ?? 0) / 2
                )
            )
        )

        #expect(leftColor.redComponent > leftColor.blueComponent)
        #expect(rightColor.blueComponent > rightColor.redComponent)
    }

    @Test
    func makeThumbnailDataAppliesPersistedCanvasOffset() async throws {
        let videoURL = try await TestFixtures.createTemporaryVideo(
            size: CGSize(width: 80, height: 40),
            frameCount: 30,
            drawFrame: { context, size, _ in
                context.setFillColor(UIColor.systemRed.cgColor)
                context.fill(
                    CGRect(
                        x: 0,
                        y: 0,
                        width: size.width / 2,
                        height: size.height
                    )
                )

                context.setFillColor(UIColor.systemBlue.cgColor)
                context.fill(
                    CGRect(
                        x: size.width / 2,
                        y: 0,
                        width: size.width / 2,
                        height: size.height
                    )
                )
            }
        )

        defer { FileManager.default.removeIfExists(for: videoURL) }

        let leftShiftedThumbnail = await makeThumbnailImage(
            sourceVideoURL: videoURL,
            canvasTransform: .init(
                normalizedOffset: CGPoint(x: 0.25, y: 0),
                zoom: 1,
                rotationRadians: 0
            )
        )
        let rightShiftedThumbnail = await makeThumbnailImage(
            sourceVideoURL: videoURL,
            canvasTransform: .init(
                normalizedOffset: CGPoint(x: -0.25, y: 0),
                zoom: 1,
                rotationRadians: 0
            )
        )

        let leftShiftedColor = try #require(
            leftShiftedThumbnail?.sampledColor(
                at: CGPoint(
                    x: (leftShiftedThumbnail?.size.width ?? 0) / 2,
                    y: (leftShiftedThumbnail?.size.height ?? 0) / 2
                )
            )
        )
        let rightShiftedColor = try #require(
            rightShiftedThumbnail?.sampledColor(
                at: CGPoint(
                    x: (rightShiftedThumbnail?.size.width ?? 0) / 2,
                    y: (rightShiftedThumbnail?.size.height ?? 0) / 2
                )
            )
        )

        #expect(leftShiftedColor.redComponent > leftShiftedColor.blueComponent)
        #expect(rightShiftedColor.blueComponent > rightShiftedColor.redComponent)
    }

    // MARK: - Private Methods

    private func makeThumbnailImage(
        sourceVideoURL: URL,
        freeformRect: VideoEditingConfiguration.FreeformRect
    ) async -> UIImage? {
        let editingConfiguration = VideoEditingConfiguration(
            crop: .init(
                rotationDegrees: 0,
                isMirrored: false,
                freeformRect: freeformRect
            )
        )

        let thumbnailData = await VideoEditingThumbnailRenderer.makeThumbnailData(
            sourceVideoURL: sourceVideoURL,
            editingConfiguration: editingConfiguration,
            maximumSize: CGSize(width: 80, height: 80)
        )

        return thumbnailData.flatMap(UIImage.init(data:))
    }

    private func makeThumbnailImage(
        sourceVideoURL: URL,
        canvasTransform: VideoCanvasTransform
    ) async -> UIImage? {
        let editingConfiguration = VideoEditingConfiguration(
            canvas: .init(
                snapshot: .init(
                    preset: .custom(width: 80, height: 80),
                    freeCanvasSize: CGSize(width: 80, height: 80),
                    transform: canvasTransform
                )
            )
        )

        let thumbnailData = await VideoEditingThumbnailRenderer.makeThumbnailData(
            sourceVideoURL: sourceVideoURL,
            editingConfiguration: editingConfiguration,
            maximumSize: CGSize(width: 80, height: 80)
        )

        return thumbnailData.flatMap(UIImage.init(data:))
    }

}

private struct SampledColor {

    // MARK: - Public Properties

    let redComponent: CGFloat
    let greenComponent: CGFloat
    let blueComponent: CGFloat
    let alphaComponent: CGFloat

}

extension UIImage {

    // MARK: - Private Methods

    fileprivate func sampledColor(
        at point: CGPoint
    ) -> SampledColor? {
        guard let cgImage else { return nil }

        let clampedPoint = CGPoint(
            x: min(max(point.x, 0), max(size.width - 1, 0)),
            y: min(max(point.y, 0), max(size.height - 1, 0))
        )
        let pixel = UnsafeMutablePointer<UInt8>.allocate(capacity: 4)
        defer { pixel.deallocate() }

        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: pixel,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return nil
        }

        context.translateBy(x: -clampedPoint.x, y: clampedPoint.y - size.height + 1)
        context.draw(
            cgImage,
            in: CGRect(
                origin: .zero,
                size: size
            )
        )

        let red = CGFloat(pixel[0]) / 255
        let green = CGFloat(pixel[1]) / 255
        let blue = CGFloat(pixel[2]) / 255
        let alpha = CGFloat(pixel[3]) / 255

        return SampledColor(
            redComponent: red,
            greenComponent: green,
            blueComponent: blue,
            alphaComponent: alpha
        )
    }

}
