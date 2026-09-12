//
//  Video.swift
//  VideoEditorKit
//
//  Created by Adriano Souza Costa on 23.03.2026.
//

import AVKit
import SwiftUI

struct Video: Identifiable, @unchecked Sendable {

    // MARK: - Public Properties

    var id: UUID = UUID()
    var url: URL
    var asset: AVAsset
    let originalDuration: Double
    var rangeDuration: ClosedRange<Double>
    var thumbnailsImages = [ThumbnailImage]()
    var rate: Float = 1.0
    var rotation: Double = 0
    var presentationSize: CGSize = .zero
    var frameSize: CGSize = .zero
    var geometrySize: CGSize = .zero
    var isMirror: Bool = false
    var toolsApplied = [Int]()
    var colorAdjusts = ColorAdjusts()
    var videoFrames: VideoFrames? = nil
    var audio: Audio?
    var volume: Float = 1.0
    var hasRecordedAudio: Bool {
        audio != nil
    }

    var timelineDuration: Double {
        guard rate.isFinite, rate > 0 else { return originalDuration }
        return originalDuration / Double(rate)
    }

    var outputRangeDuration: ClosedRange<Double> {
        PlaybackTimeMapping.scaledTimelineRange(
            sourceRange: rangeDuration,
            rate: rate,
            originalDuration: originalDuration
        )
    }

    var totalDuration: Double {
        outputRangeDuration.upperBound - outputRangeDuration.lowerBound
    }

    @MainActor
    static let mock: Video = .init(
        url: URL(fileURLWithPath: "/tmp/mock-video.mp4"),
        rangeDuration: 0...250
    )

    static func load(from url: URL) async -> Video {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration).seconds) ?? .zero
        let resolvedDuration = duration.isFinite ? duration : .zero
        let presentationSize = await asset.presentationSize() ?? .zero
        return Video(
            url: url, asset: asset, originalDuration: resolvedDuration,
            rangeDuration: .zero...resolvedDuration,
            presentationSize: presentationSize)
    }

    // MARK: - Initializers

    init(
        url: URL,
        asset: AVAsset,
        originalDuration: Double,
        rangeDuration: ClosedRange<Double>,
        rate: Float = 1.0,
        rotation: Double = 0,
        presentationSize: CGSize = .zero
    ) {
        self.url = url
        self.asset = asset
        self.originalDuration = originalDuration
        self.rangeDuration = rangeDuration
        self.rate = rate
        self.rotation = rotation
        self.presentationSize = presentationSize
    }

    init(url: URL) {
        self.init(
            url: url,
            asset: AVURLAsset(url: url),
            originalDuration: .zero,
            rangeDuration: .zero ... .zero
        )
    }

    init(url: URL, rangeDuration: ClosedRange<Double>, rate: Float = 1.0, rotation: Double = 0) {
        let asset = AVURLAsset(url: url)
        let originalDuration = max(rangeDuration.upperBound, .zero)

        self.init(
            url: url,
            asset: asset,
            originalDuration: originalDuration,
            rangeDuration: rangeDuration,
            rate: rate,
            rotation: rotation
        )
    }

    // MARK: - Public Methods

    func makeThumbnails(
        containerSize: CGSize,
        displayScale: CGFloat = 1
    ) async -> [ThumbnailImage] {
        let imagesCount = thumbnailCount(for: containerSize)

        guard imagesCount > 0 else { return [] }

        let timestamps = thumbnailTimestamps(imagesCount: imagesCount)
        let resolvedDisplayScale = max(displayScale, 1)

        let maximumSize = CGSize(
            width: max((containerSize.width / CGFloat(imagesCount)) * resolvedDisplayScale, 1),
            height: max(containerSize.height * resolvedDisplayScale, 1)
        )

        let images = await asset.generateImages(
            at: timestamps,
            maximumSize: maximumSize
        )

        return images.map { ThumbnailImage(image: $0) }
    }

    func isAppliedTool(for tool: ToolEnum) -> Bool {
        toolsApplied.contains(tool.rawValue)
    }

    func thumbnailCount(for containerSize: CGSize) -> Int {
        let usableWidth = max(containerSize.width - 32, 1)
        let count = Int(ceil(usableWidth / Double(70 / 1.5)))

        return max(count, 1)
    }

    mutating func updateRate(_ rate: Float) {
        guard rate.isFinite, rate > 0 else { return }

        self.rate = rate
    }

    mutating func resetRangeDuration() {
        rangeDuration = 0...originalDuration
    }

    mutating func resetRate() {
        updateRate(1.0)
    }

    mutating func rotate() {
        rotation = rotation.nextAngle()
    }

    mutating func appliedTool(for tool: ToolEnum) {
        if !isAppliedTool(for: tool) {
            toolsApplied.append(tool.rawValue)
        }
    }

    mutating func setVolume(_ value: Float) {
        volume = value
    }

    mutating func removeTool(for tool: ToolEnum) {
        if isAppliedTool(for: tool) {
            toolsApplied.removeAll(where: { $0 == tool.rawValue })
        }
    }

    func timelineTimePreservingSourcePosition(_ timelineTime: Double, fromRate previousRate: Float)
        -> Double
    {
        PlaybackTimeMapping.timelineTimePreservingSourcePosition(
            timelineTime: timelineTime,
            previousRate: previousRate,
            newRate: rate,
            newRange: outputRangeDuration,
            originalDuration: originalDuration
        )
    }

    // MARK: - Private Methods

    private func thumbnailTimestamps(imagesCount: Int) -> [Double] {
        guard imagesCount > 0 else { return [] }
        guard originalDuration > 0 else { return Array(repeating: .zero, count: imagesCount) }

        let step = originalDuration / Double(imagesCount)

        return (0..<imagesCount).map { index in
            let midpoint = (Double(index) + 0.5) * step
            return min(midpoint, max(originalDuration - 0.001, .zero))
        }
    }

}

extension Video: Equatable {

    // MARK: - Public Methods

    static func == (lhs: Video, rhs: Video) -> Bool {
        lhs.id == rhs.id
    }

}

extension Double {

    // MARK: - Public Methods

    func nextAngle() -> Double {
        var next = Int(self) + 90
        if next >= 360 {
            next = 0
        } else if next < 0 {
            next = 360 - abs(next % 360)
        }
        return Double(next)
    }

}

struct ThumbnailImage: Identifiable, @unchecked Sendable {

    // MARK: - Public Properties

    var id: UUID = UUID()
    var image: UIImage?

    // MARK: - Initializer

    init(image: UIImage? = nil) {
        self.image = image
    }

}

struct VideoFrames {

    // MARK: - Public Properties

    var scaleValue: Double = 0
    var frameColor: Color = Color(uiColor: .systemBackground)
    var scale: Double {
        1 - scaleValue
    }

    var isActive: Bool {
        scaleValue > 0
    }

    // MARK: - Public Methods

    mutating func reset() {
        scaleValue = 0
        frameColor = Color(uiColor: .systemBackground)
    }

}
