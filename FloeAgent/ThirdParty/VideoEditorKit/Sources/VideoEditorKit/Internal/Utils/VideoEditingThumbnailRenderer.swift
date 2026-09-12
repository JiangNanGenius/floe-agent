//
//  VideoEditingThumbnailRenderer.swift
//  VideoEditorKit
//
//  Created by Codex on 02.04.2026.
//

import AVFoundation
import CoreImage
import Foundation
import SwiftUI

@MainActor
enum VideoEditingThumbnailRenderer {

    // MARK: - Private Properties

    private static let ciContext = CIContext()

    private enum Constants {
        static let defaultMaximumSize = CGSize(width: 720, height: 720)
        static let minimumCanvasDimension: CGFloat = 2
        static let thumbnailCompressionQuality: CGFloat = 0.85
    }

    // MARK: - Public Methods

    static func makeThumbnailData(
        sourceVideoURL: URL,
        editingConfiguration: VideoEditingConfiguration,
        maximumSize: CGSize = Constants.defaultMaximumSize
    ) async -> Data? {
        guard
            let renderedImage = await makeThumbnailImage(
                sourceVideoURL: sourceVideoURL,
                editingConfiguration: editingConfiguration,
                maximumSize: maximumSize
            )
        else {
            return nil
        }

        return renderedImage.jpegData(
            compressionQuality: Constants.thumbnailCompressionQuality
        )
    }

    static func makeThumbnailImage(
        sourceVideoURL: URL,
        editingConfiguration: VideoEditingConfiguration,
        maximumSize: CGSize = Constants.defaultMaximumSize
    ) async -> UIImage? {
        let asset = AVURLAsset(url: sourceVideoURL)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let timestamp = VideoEditingThumbnailTimestampResolver.sourceAssetTimestamp(
            for: editingConfiguration,
            originalDuration: duration
        )
        let captureSize = resolvedCaptureSize(for: maximumSize)

        guard
            let sourceFrame = await asset.generateImage(
                at: timestamp,
                maximumSize: captureSize,
                requiresExactFrame: true
            )
        else {
            return nil
        }

        let adjustedFrame = applyColorAdjustsIfNeeded(
            to: sourceFrame,
            editingConfiguration: editingConfiguration
        )

        return renderVisibleFrame(
            adjustedFrame,
            editingConfiguration: editingConfiguration,
            maximumSize: maximumSize
        )
    }

    // MARK: - Private Methods

    private static func resolvedCaptureSize(
        for maximumSize: CGSize
    ) -> CGSize {
        let resolvedMaximumDimension = max(
            max(maximumSize.width, maximumSize.height),
            Constants.defaultMaximumSize.width
        )

        return CGSize(
            width: resolvedMaximumDimension * 2,
            height: resolvedMaximumDimension * 2
        )
    }

    private static func applyColorAdjustsIfNeeded(
        to image: UIImage,
        editingConfiguration: VideoEditingConfiguration
    ) -> UIImage {
        let colorAdjusts = ColorAdjusts(
            brightness: editingConfiguration.adjusts.brightness,
            contrast: editingConfiguration.adjusts.contrast,
            saturation: editingConfiguration.adjusts.saturation
        )

        guard colorAdjusts.isIdentity == false else { return image }
        guard let ciImage = CIImage(image: image) else { return image }
        guard let filter = Helpers.createColorAdjustsFilter(colorAdjusts) else { return image }

        filter.setValue(ciImage, forKey: kCIInputImageKey)

        guard
            let outputImage = filter.outputImage,
            let cgImage = ciContext.createCGImage(
                outputImage,
                from: outputImage.extent
            )
        else {
            return image
        }

        return UIImage(cgImage: cgImage).normalizedForDisplay()
    }

    private static func renderVisibleFrame(
        _ image: UIImage,
        editingConfiguration: VideoEditingConfiguration,
        maximumSize: CGSize
    ) -> UIImage? {
        let sourceSize = image.size
        guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }

        let mappingActor = VideoCanvasMappingActor()
        let request = makeCanvasRenderRequest(
            sourceSize: sourceSize,
            editingConfiguration: editingConfiguration,
            mappingActor: mappingActor
        )
        let exportMapping = mappingActor.makeExportMapping(request: request)
        let outputSize = fittedThumbnailSize(
            exportMapping.renderSize,
            maximumSize: maximumSize
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        format.scale = 1

        let renderer = UIGraphicsImageRenderer(
            size: outputSize,
            format: format
        )

        return renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: outputSize))

            let cgContext = context.cgContext
            cgContext.interpolationQuality = .high
            cgContext.scaleBy(
                x: outputSize.width / max(exportMapping.renderSize.width, 1),
                y: outputSize.height / max(exportMapping.renderSize.height, 1)
            )
            cgContext.concatenate(exportMapping.contentTransform)

            image.draw(
                in: CGRect(
                    origin: .zero,
                    size: sourceSize
                )
            )
        }
    }

    private static func makeCanvasRenderRequest(
        sourceSize: CGSize,
        editingConfiguration: VideoEditingConfiguration,
        mappingActor: VideoCanvasMappingActor
    ) -> VideoCanvasRenderRequest {
        let snapshot = resolvedCanvasSnapshot(
            for: sourceSize,
            editingConfiguration: editingConfiguration,
            mappingActor: mappingActor
        )

        return mappingActor.makeRenderRequest(
            source: VideoCanvasSourceDescriptor(
                naturalSize: sourceSize,
                preferredTransform: .identity,
                userRotationDegrees: editingConfiguration.crop.rotationDegrees,
                isMirrored: editingConfiguration.crop.isMirrored
            ),
            snapshot: snapshot
        )
    }

    private static func resolvedCanvasSnapshot(
        for sourcePresentationSize: CGSize,
        editingConfiguration: VideoEditingConfiguration,
        mappingActor: VideoCanvasMappingActor
    ) -> VideoCanvasSnapshot {
        let storedSnapshot = editingConfiguration.canvas.snapshot
        if storedSnapshot != .initial {
            return storedSnapshot
        }

        let preset = resolvedCanvasPreset(
            for: sourcePresentationSize,
            editingConfiguration: editingConfiguration
        )
        let resolvedPreset = mappingActor.resolvePreset(
            preset,
            naturalSize: sourcePresentationSize,
            freeCanvasSize: storedSnapshot.freeCanvasSize
        )

        var snapshot = VideoCanvasSnapshot(
            preset: preset,
            freeCanvasSize: resolvedPreset.exportSize,
            transform: .identity,
            showsSafeAreaOverlay: false
        )

        snapshot.transform = mappingActor.snapshotTransform(
            fromLegacyFreeformRect: editingConfiguration.crop.freeformRect,
            referenceSize: sourcePresentationSize,
            exportSize: resolvedPreset.exportSize
        )

        return snapshot
    }

    private static func resolvedCanvasPreset(
        for sourceSize: CGSize,
        editingConfiguration: VideoEditingConfiguration
    ) -> VideoCanvasPreset {
        let storedPreset = editingConfiguration.canvas.snapshot.preset
        if storedPreset != .original {
            return storedPreset
        }

        if let socialVideoDestination = editingConfiguration.presentation.socialVideoDestination {
            return .social(platform: socialVideoDestination.socialPlatform)
        }

        guard let freeformRect = editingConfiguration.crop.freeformRect else {
            return .original
        }

        let clampedAspectRatio = resolvedLegacyCanvasAspectRatio(
            freeformRect: freeformRect,
            sourceSize: sourceSize
        )

        for preset in VideoCropFormatPreset.editorPresets {
            guard let aspectRatio = preset.aspectRatio else { continue }
            guard let clampedAspectRatio else { continue }
            if abs(clampedAspectRatio - aspectRatio) < 0.001 {
                return VideoCanvasPreset.fromLegacySelection(
                    preset: preset,
                    socialVideoDestination: nil
                )
            }
        }

        let cropRect = VideoEditor.resolvedCropRect(
            for: freeformRect,
            in: sourceSize
        )

        return .custom(
            width: max(Int(cropRect.width.rounded()), Int(Constants.minimumCanvasDimension)),
            height: max(Int(cropRect.height.rounded()), Int(Constants.minimumCanvasDimension))
        )
    }

    private static func resolvedLegacyCanvasAspectRatio(
        freeformRect: VideoEditingConfiguration.FreeformRect,
        sourceSize: CGSize
    ) -> CGFloat? {
        let cropRect = VideoEditor.resolvedCropRect(
            for: freeformRect,
            in: sourceSize
        )

        guard cropRect.width > 0, cropRect.height > 0 else { return nil }
        return cropRect.width / cropRect.height
    }

    private static func fittedThumbnailSize(
        _ size: CGSize,
        maximumSize: CGSize
    ) -> CGSize {
        guard size.width > 0, size.height > 0 else {
            return Constants.defaultMaximumSize
        }

        guard maximumSize.width > 0, maximumSize.height > 0 else {
            return size
        }

        let scale = min(
            maximumSize.width / size.width,
            maximumSize.height / size.height,
            1
        )

        return CGSize(
            width: max(size.width * scale, Constants.minimumCanvasDimension),
            height: max(size.height * scale, Constants.minimumCanvasDimension)
        )
    }

}
