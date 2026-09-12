//
//  VideoEditorLayoutResolver.swift
//  VideoEditorKit
//
//  Created by Codex on 01.04.2026.
//

import CoreGraphics
import Foundation

struct VideoEditorCropPreviewCanvas: Equatable, Sendable {

    // MARK: - Public Properties

    let referenceSize: CGSize
    let contentSize: CGSize
    let viewportSize: CGSize

}

struct VideoEditorLayoutResolver {

    // MARK: - Private Properties

    private enum Constants {
        static let minimumPlayerHeight: CGFloat = 220
        static let playerHeightRatio = 0.40
        static let playerHorizontalInset: CGFloat = 32
    }

    // MARK: - Public Methods

    static func playerContainerSize(in availableSize: CGSize) -> CGSize {
        CGSize(
            width: max(availableSize.width - Constants.playerHorizontalInset, 1),
            height: max(
                Constants.minimumPlayerHeight,
                availableSize.height * Constants.playerHeightRatio
            )
        )
    }

    static func resolvedPlayerDisplaySize(
        for video: Video,
        in containerSize: CGSize
    ) -> CGSize {
        let fallbackSize = CGSize(
            width: max(containerSize.width, 1),
            height: max(containerSize.height, 1)
        )

        let baseSize = rotatedBaseSize(for: video)
        guard baseSize.width > 0, baseSize.height > 0 else { return fallbackSize }

        return fittedSize(baseSize, in: fallbackSize)
    }

    static func resolvedCropReferenceSize(
        for video: Video,
        fallbackContainerSize: CGSize
    ) -> CGSize {
        let resolvedSize = rotatedBaseSize(for: video)
        if resolvedSize.width > 0, resolvedSize.height > 0 {
            return resolvedSize
        }

        if video.geometrySize.width > 0, video.geometrySize.height > 0 {
            return video.geometrySize
        }

        if video.frameSize.width > 0, video.frameSize.height > 0 {
            return video.frameSize
        }

        let fittedPreviewSize = resolvedPlayerDisplaySize(
            for: video,
            in: fallbackContainerSize
        )
        guard fittedPreviewSize.width > 0, fittedPreviewSize.height > 0 else {
            return CGSize(
                width: max(fallbackContainerSize.width, 1),
                height: max(fallbackContainerSize.height, 1)
            )
        }

        return fittedPreviewSize
    }

    static func resolvedCropPreviewCanvas(
        for video: Video,
        freeformRect: VideoEditingConfiguration.FreeformRect?,
        in containerSize: CGSize,
        fallbackContainerSize: CGSize
    ) -> VideoEditorCropPreviewCanvas {
        let fallbackSize = CGSize(
            width: max(containerSize.width, 1),
            height: max(containerSize.height, 1)
        )
        let referenceSize = resolvedCropReferenceSize(
            for: video,
            fallbackContainerSize: fallbackContainerSize
        )
        let contentSize = fittedSize(referenceSize, in: fallbackSize)

        guard
            let aspectRatio = activeCropViewportAspectRatio(
                freeformRect: freeformRect,
                referenceSize: referenceSize
            )
        else {
            return .init(
                referenceSize: referenceSize,
                contentSize: contentSize,
                viewportSize: contentSize
            )
        }

        let viewportSize = fittedAspectSize(
            for: aspectRatio,
            in: containerSize
        )

        guard viewportSize.width > 0, viewportSize.height > 0 else {
            return .init(
                referenceSize: referenceSize,
                contentSize: contentSize,
                viewportSize: contentSize
            )
        }

        return .init(
            referenceSize: referenceSize,
            contentSize: contentSize,
            viewportSize: viewportSize
        )
    }

    // MARK: - Private Methods

    private static func activeCropViewportAspectRatio(
        freeformRect: VideoEditingConfiguration.FreeformRect?,
        referenceSize: CGSize
    ) -> CGFloat? {
        guard
            let previewLayout = VideoCropPreviewLayout(
                freeformRect: freeformRect,
                in: referenceSize
            ),
            previewLayout.presetSourceRect.width > 0,
            previewLayout.presetSourceRect.height > 0
        else { return nil }

        return previewLayout.presetSourceRect.width / previewLayout.presetSourceRect.height
    }

    private static func rotatedBaseSize(for video: Video) -> CGSize {
        let baseSize: CGSize

        if video.presentationSize.width > 0, video.presentationSize.height > 0 {
            baseSize = video.presentationSize
        } else {
            baseSize = video.frameSize
        }

        guard baseSize.width > 0, baseSize.height > 0 else { return .zero }

        let normalizedRotation = abs(Int(video.rotation)) % 180

        if normalizedRotation == 90 {
            return CGSize(width: baseSize.height, height: baseSize.width)
        }

        return baseSize
    }

    private static func fittedSize(
        _ size: CGSize,
        in bounds: CGSize
    ) -> CGSize {
        guard size.width > 0, size.height > 0 else { return bounds }
        guard bounds.width > 0, bounds.height > 0 else { return size }

        let widthScale = bounds.width / size.width
        let heightScale = bounds.height / size.height
        let scale = min(widthScale, heightScale, 1)

        return CGSize(
            width: size.width * scale,
            height: size.height * scale
        )
    }

    private static func fittedAspectSize(
        for aspectRatio: CGFloat,
        in bounds: CGSize
    ) -> CGSize {
        guard aspectRatio > 0 else { return .zero }
        guard bounds.width > 0, bounds.height > 0 else { return .zero }

        let boundsAspectRatio = bounds.width / bounds.height

        if boundsAspectRatio > aspectRatio {
            let height = bounds.height
            return CGSize(
                width: height * aspectRatio,
                height: height
            )
        }

        let width = bounds.width
        return CGSize(
            width: width,
            height: width / aspectRatio
        )
    }

}
