//
//  AVAssets+Ext.swift
//  VideoEditorKit
//
//  Created by Adriano Souza Costa on 23.03.2026.
//

import AVKit
import Foundation
import SwiftUI

extension AVAsset {

    // MARK: - Public Properties

    struct TrimError: Error {

        let description: String
        let underlyingError: Error?

        init(_ description: String, underlyingError: Error? = nil) {
            self.description = "TrimVideo: " + description
            self.underlyingError = underlyingError
        }

    }

    // MARK: - Public Methods

    func generateImage(
        at second: Double,
        maximumSize: CGSize = .zero,
        requiresExactFrame: Bool = false
    ) async -> UIImage? {
        if let first = await generateImages(
            at: [second],
            maximumSize: maximumSize,
            requiresExactFrame: requiresExactFrame
        ).first {
            first
        } else {
            nil
        }
    }

    func generateImages(
        at seconds: [Double],
        maximumSize: CGSize = .zero,
        requiresExactFrame: Bool = false
    ) async -> [UIImage?] {
        guard !seconds.isEmpty else { return [] }

        let imageGenerator = AVAssetImageGenerator(asset: self)
        imageGenerator.appliesPreferredTrackTransform = true

        if requiresExactFrame {
            imageGenerator.requestedTimeToleranceBefore = .zero
            imageGenerator.requestedTimeToleranceAfter = .zero
        }

        if maximumSize != .zero {
            imageGenerator.maximumSize = maximumSize
        }

        let requestedTimes = seconds.map {
            NSValue(
                time: CMTime(
                    seconds: max($0, .zero),
                    preferredTimescale: 600
                )
            )
        }

        let requestedTimeIndexes = Dictionary(
            uniqueKeysWithValues: requestedTimes.enumerated().map { index, value in
                (value.timeValue.cacheKey, index)
            }
        )

        let state = ThumbnailGenerationState(
            requestedCount: requestedTimes.count,
            requestedTimeIndexes: requestedTimeIndexes
        )

        return await withCheckedContinuation { continuation in
            imageGenerator.generateCGImagesAsynchronously(forTimes: requestedTimes) {
                requestedTime, image, _, result, _ in
                let resolvedImage: UIImage?

                if result == .succeeded, let image {
                    resolvedImage = UIImage(cgImage: image).normalizedForDisplay()
                } else {
                    resolvedImage = nil
                }

                if let images = state.store(
                    resolvedImage,
                    for: requestedTime.cacheKey
                ) {
                    continuation.resume(returning: images)
                }
            }
        }
    }

    func naturalSize() async -> CGSize? {
        guard let tracks = try? await loadTracks(withMediaType: .video) else { return nil }
        guard let track = tracks.first else { return nil }
        guard let size = try? await track.load(.naturalSize) else { return nil }
        return size
    }

    func presentationSize() async -> CGSize? {
        guard let tracks = try? await loadTracks(withMediaType: .video) else { return nil }
        guard let track = tracks.first else { return nil }
        guard let naturalSize = try? await track.load(.naturalSize) else { return nil }
        guard let preferredTransform = try? await track.load(.preferredTransform) else { return nil }

        let transformedSize = naturalSize.applying(preferredTransform)
        let resolvedSize = CGSize(
            width: abs(transformedSize.width),
            height: abs(transformedSize.height)
        )

        guard resolvedSize.width > 0, resolvedSize.height > 0 else {
            return naturalSize
        }

        return resolvedSize
    }

    func adjustVideoSize(to viewSize: CGSize, rotationAngle: Double = 0) async -> CGSize? {
        guard viewSize.width > 0, viewSize.height > 0 else { return nil }
        guard let assetSize = await self.presentationSize() else { return nil }

        let normalizedAngle = Int(rotationAngle) % 180
        let fittedAssetSize: CGSize

        if normalizedAngle == 0 {
            fittedAssetSize = assetSize
        } else {
            fittedAssetSize = CGSize(width: assetSize.height, height: assetSize.width)
        }

        let widthScale = viewSize.width / fittedAssetSize.width
        let heightScale = viewSize.height / fittedAssetSize.height
        let scale = min(widthScale, heightScale)

        return CGSize(
            width: fittedAssetSize.width * scale,
            height: fittedAssetSize.height * scale
        )
    }

}

private final class ThumbnailGenerationState: @unchecked Sendable {

    private let requestedCount: Int
    private let requestedTimeIndexes: [String: Int]
    private let lock = NSLock()
    private var images: [UIImage?]
    private var completedCount = 0

    init(
        requestedCount: Int,
        requestedTimeIndexes: [String: Int]
    ) {
        self.requestedCount = requestedCount
        self.requestedTimeIndexes = requestedTimeIndexes
        self.images = [UIImage?](repeating: nil, count: requestedCount)
    }

    func store(
        _ image: UIImage?,
        for requestedTimeKey: String
    ) -> [UIImage?]? {
        lock.lock()
        defer { lock.unlock() }

        if let index = requestedTimeIndexes[requestedTimeKey] {
            images[index] = image
        }

        completedCount += 1

        guard completedCount == requestedCount else {
            return nil
        }

        return images
    }

}

extension CMTime {

    fileprivate var cacheKey: String {
        "\(value):\(timescale):\(epoch)"
    }

}
